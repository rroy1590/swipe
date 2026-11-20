import AVFoundation
import Foundation
import Speech

/// Manages microphone capture, on-device `SFSpeechRecognizer` transcription,
/// background warm-session lifecycle, and App Group / Darwin IPC synchronization
/// with the `SwipeKeyboard` extension.
@MainActor
final class DictationEngine: ObservableObject {
    @Published private(set) var phase: DictationPhase = .idle
    @Published private(set) var partialText: String = ""
    @Published private(set) var finalText: String = ""
    @Published private(set) var audioLevels: [Float] = Array(repeating: 0.08, count: DictationConfig.waveformBarCount)
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBackgroundArmed: Bool = false
    @Published private(set) var isOnDeviceSupported: Bool = false
    @Published private(set) var micPermission: AVAudioApplication.recordPermission = AVAudioApplication.shared.recordPermission
    @Published private(set) var speechPermission: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
    @Published var settings: DictationSettings
    @Published private(set) var history: [DictationHistoryItem]

    /// Set when the host app was launched via `swipe://dictate` so the UI can guide
    /// the user back to their previous app while recording continues in the background.
    @Published var launchedFromKeyboardBanner: Bool = false

    private let store: AppGroupStore
    private let bridge: DarwinNotificationBridge

    private var audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var currentSessionID = UUID()
    private var recordingStartedAt: Date?
    private var lastLevelPublishAt: Date = .distantPast
    private var isTapInstalled = false

    private var heartbeatTimer: Timer?
    private var autoDisarmTimer: Timer?
    private let observerBag: DarwinObserverBag

    /// Automatically disarm idle background audio after 10 minutes to preserve battery.
    private let autoDisarmInterval: TimeInterval = 600

    init(
        store: AppGroupStore = .shared,
        bridge: DarwinNotificationBridge = .shared
    ) {
        self.store = store
        self.bridge = bridge
        self.observerBag = DarwinObserverBag(bridge: bridge)
        self.settings = store.readSettings()
        self.history = store.readHistory()

        configureRecognizer()
        registerDarwinObservers()
        refreshPermissions()
    }

    // MARK: - Permissions

    func refreshPermissions() {
        micPermission = AVAudioApplication.shared.recordPermission
        speechPermission = SFSpeechRecognizer.authorizationStatus()
        configureRecognizer()
    }

    func requestMicrophonePermission() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        micPermission = granted ? .granted : .denied
    }

    func requestSpeechPermission() async {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authStatus in
                continuation.resume(returning: authStatus)
            }
        }
        speechPermission = status
        configureRecognizer()
    }

    var hasAllPermissions: Bool {
        micPermission == .granted && speechPermission == .authorized
    }

    // MARK: - Settings & History

    func saveSettings() {
        store.writeSettings(settings)
        configureRecognizer()
        if !settings.keepWarmInBackground && phase == .idle && isBackgroundArmed {
            disarmBackgroundSession()
        }
    }

    func clearHistory() {
        store.clearHistory()
        history = []
    }

    // MARK: - Deep Link Entry (`swipe://dictate`)

    func handleDeepLink(_ url: URL) {
        guard url.scheme == DictationConfig.urlScheme,
              url.host == DictationConfig.dictateHost else {
            return
        }

        launchedFromKeyboardBanner = true
        _ = store.consumeCommand()

        Task {
            if !hasAllPermissions {
                await requestMicrophonePermission()
                await requestSpeechPermission()
            }
            if hasAllPermissions {
                startDictation()
            } else {
                publishError("Grant Microphone and Speech Recognition permissions in Swipe first.")
            }
        }
    }

    // MARK: - Dictation Lifecycle

    func startDictation() {
        guard phase != .listening else { return }

        refreshPermissions()
        guard micPermission == .granted else {
            publishError("Microphone access is not granted. Enable it in Swipe.")
            return
        }
        guard speechPermission == .authorized else {
            publishError("Speech recognition is not authorized. Enable it in Swipe.")
            return
        }

        configureRecognizer()
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            publishError("Apple Speech recognizer is currently unavailable on this device.")
            return
        }

        teardownRecognitionTask()
        autoDisarmTimer?.invalidate()

        currentSessionID = UUID()
        recordingStartedAt = Date()
        partialText = ""
        finalText = ""
        errorMessage = nil

        do {
            try ensureAudioEngineRunning()

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            let useOnDevice = settings.preferOnDeviceRecognition && recognizer.supportsOnDeviceRecognition
            request.requiresOnDeviceRecognition = useOnDevice
            self.recognitionRequest = request

            phase = .listening
            isBackgroundArmed = true
            startHeartbeatTimer()
            publishSnapshot(isOnDevice: useOnDevice)

            let sessionID = currentSessionID
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self, self.currentSessionID == sessionID else { return }

                    if let result {
                        let transcript = result.bestTranscription.formattedString
                        self.partialText = transcript
                        if result.isFinal {
                            self.finalizeSession(with: transcript, isOnDevice: useOnDevice)
                            return
                        } else {
                            self.publishSnapshot(isOnDevice: useOnDevice)
                        }
                    }

                    if let error {
                        // If stopDictation() already triggered endAudio(), prefer the latest partial text
                        // instead of surfacing a cancellation error.
                        if self.phase == .processing || !self.partialText.isEmpty {
                            self.finalizeSession(with: self.partialText, isOnDevice: useOnDevice)
                        } else if self.phase == .listening {
                            self.publishError(error.localizedDescription)
                            self.finishAudioAfterSession()
                        }
                    }
                }
            }
        } catch {
            publishError("Audio session failed: \(error.localizedDescription)")
            disarmBackgroundSession()
        }
    }

    func stopDictation() {
        guard phase == .listening else { return }

        phase = .processing
        publishSnapshot(isOnDevice: isOnDeviceSupported && settings.preferOnDeviceRecognition)
        recognitionRequest?.endAudio()

        // Fallback safety net: if Apple Speech doesn't emit `isFinal` within 1.2s,
        // commit the best partial transcript so the keyboard never stalls.
        let sessionID = currentSessionID
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.currentSessionID == sessionID, self.phase == .processing else { return }
            self.finalizeSession(
                with: self.partialText,
                isOnDevice: self.isOnDeviceSupported && self.settings.preferOnDeviceRecognition
            )
        }
    }

    func cancelDictation() {
        teardownRecognitionTask()
        partialText = ""
        finalText = ""
        errorMessage = nil
        audioLevels = Array(repeating: 0.08, count: DictationConfig.waveformBarCount)
        phase = .idle
        finishAudioAfterSession()
        publishSnapshot(isOnDevice: isOnDeviceSupported && settings.preferOnDeviceRecognition)
    }

    func armBackgroundSession() {
        guard hasAllPermissions else {
            publishError("Grant Microphone and Speech permissions first.")
            return
        }
        do {
            try ensureAudioEngineRunning()
            isBackgroundArmed = true
            startHeartbeatTimer()
            scheduleAutoDisarm()
            publishSnapshot(isOnDevice: isOnDeviceSupported && settings.preferOnDeviceRecognition)
        } catch {
            publishError("Unable to arm background audio: \(error.localizedDescription)")
        }
    }

    func disarmBackgroundSession() {
        teardownRecognitionTask()
        stopAudioEngine()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        autoDisarmTimer?.invalidate()
        autoDisarmTimer = nil
        isBackgroundArmed = false
        launchedFromKeyboardBanner = false
        if phase == .listening || phase == .processing {
            phase = .idle
        }
        audioLevels = Array(repeating: 0.08, count: DictationConfig.waveformBarCount)
        publishSnapshot(isOnDevice: isOnDeviceSupported && settings.preferOnDeviceRecognition)
    }

    // MARK: - Internal Audio & Speech Wiring

    private func configureRecognizer() {
        let locale = Locale(identifier: settings.localeIdentifier)
        let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        speechRecognizer = recognizer
        isOnDeviceSupported = recognizer?.supportsOnDeviceRecognition ?? false
    }

    private func ensureAudioEngineRunning() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        if !isTapInstalled {
            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.handleAudioBuffer(buffer)
            }
            isTapInstalled = true
        }

        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }
    }

    private func stopAudioEngine() {
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Only forward audio into SFSpeechRecognizer while actively listening.
        // When armed in idle standby, buffers are discarded with near-zero CPU.
        guard let request = recognitionRequest else { return }
        request.append(buffer)

        let level = Self.normalizedRMSLevel(from: buffer)
        Task { @MainActor [weak self] in
            guard let self, self.phase == .listening else { return }
            self.pushWaveformLevel(level)
        }
    }

    private static func normalizedRMSLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0.08 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0.08 }

        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameLength))
        // Convert RMS amplitude to a smooth 0.08...1.0 visual scale in decibels.
        let db = 20 * log10(max(rms, 1e-5))
        let normalized = (db + 52) / 42
        return min(max(normalized, 0.08), 1.0)
    }

    private func pushWaveformLevel(_ level: Float) {
        var next = audioLevels
        if next.count >= DictationConfig.waveformBarCount {
            next.removeFirst()
        }
        next.append(level)
        audioLevels = next

        let now = Date()
        if now.timeIntervalSince(lastLevelPublishAt) >= 0.08 {
            lastLevelPublishAt = now
            publishSnapshot(isOnDevice: isOnDeviceSupported && settings.preferOnDeviceRecognition)
        }
    }

    private func finalizeSession(with transcript: String, isOnDevice: Bool) {
        teardownRecognitionTask()

        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        finalText = cleaned
        partialText = cleaned
        audioLevels = Array(repeating: 0.08, count: DictationConfig.waveformBarCount)

        if !cleaned.isEmpty {
            let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            let item = DictationHistoryItem(
                text: cleaned,
                durationSeconds: max(duration, 0.1),
                isOnDevice: isOnDevice
            )
            store.appendHistory(item)
            history = store.readHistory()
            phase = .ready
        } else {
            phase = .idle
        }

        finishAudioAfterSession()
        publishSnapshot(isOnDevice: isOnDevice)
    }

    private func finishAudioAfterSession() {
        if settings.keepWarmInBackground {
            isBackgroundArmed = true
            startHeartbeatTimer()
            scheduleAutoDisarm()
        } else {
            disarmBackgroundSession()
        }
    }

    private func teardownRecognitionTask() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    private func publishError(_ message: String) {
        teardownRecognitionTask()
        errorMessage = message
        phase = .error
        publishSnapshot(isOnDevice: isOnDeviceSupported && settings.preferOnDeviceRecognition)
    }

    private func publishSnapshot(isOnDevice: Bool) {
        let snapshot = DictationSnapshot(
            sessionID: currentSessionID,
            phase: phase,
            partialText: partialText,
            finalText: finalText,
            audioLevels: audioLevels,
            errorMessage: errorMessage,
            hostArmed: isBackgroundArmed,
            hostHeartbeatAt: isBackgroundArmed ? Date() : nil,
            isOnDevice: isOnDevice,
            updatedAt: Date()
        )
        store.writeSnapshot(snapshot)
        bridge.post(DictationConfig.DarwinNotification.stateDidChange)
    }

    private func startHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isBackgroundArmed else { return }
                self.publishSnapshot(isOnDevice: self.isOnDeviceSupported && self.settings.preferOnDeviceRecognition)
            }
        }
    }

    private func scheduleAutoDisarm() {
        autoDisarmTimer?.invalidate()
        autoDisarmTimer = Timer.scheduledTimer(withTimeInterval: autoDisarmInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.phase != .listening else { return }
                self.disarmBackgroundSession()
            }
        }
    }

    // MARK: - Darwin IPC Observers (Keyboard -> Host App)

    private func registerDarwinObservers() {
        observerBag.observe(DictationConfig.DarwinNotification.startDictation) { [weak self] in
            Task { @MainActor [weak self] in
                self?.startDictation()
            }
        }
        observerBag.observe(DictationConfig.DarwinNotification.stopDictation) { [weak self] in
            Task { @MainActor [weak self] in
                self?.stopDictation()
            }
        }
        observerBag.observe(DictationConfig.DarwinNotification.cancelDictation) { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelDictation()
            }
        }
    }
}
