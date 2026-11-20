import Foundation
import UIKit

enum KeyboardLayoutMode {
    case letters
    case numbers
    case symbols
}

enum ShiftState {
    case lowercase
    case shifted
    case capsLock
}

@MainActor
final class KeyboardViewModel: ObservableObject {
    @Published var layoutMode: KeyboardLayoutMode = .letters
    @Published var shiftState: ShiftState = .shifted
    @Published var hasFullAccess: Bool = false
    @Published var needsInputModeSwitchKey: Bool = true

    @Published private(set) var snapshot: DictationSnapshot = DictationSnapshot()
    @Published var showKeysWhileDictating: Bool = false
    @Published private(set) var lastInsertedDictationCount: Int = 0
    @Published var inlineNotice: String?

    private let proxyProvider: () -> UITextDocumentProxy?
    private let nextInputModeHandler: () -> Void
    private let openURLHandler: (URL) -> Void
    private let store: AppGroupStore
    private let bridge: DarwinNotificationBridge

    private var stateObserverToken: UUID?
    private var heartbeatPollTimer: Timer?
    private var backspaceRepeatTimer: Timer?
    private var lastShiftTapAt: Date = .distantPast
    private var lastSpaceTapAt: Date = .distantPast
    private var consumedSessionID: UUID?

    init(
        proxyProvider: @escaping () -> UITextDocumentProxy?,
        nextInputModeHandler: @escaping () -> Void,
        openURLHandler: @escaping (URL) -> Void,
        store: AppGroupStore = .shared,
        bridge: DarwinNotificationBridge = .shared
    ) {
        self.proxyProvider = proxyProvider
        self.nextInputModeHandler = nextInputModeHandler
        self.openURLHandler = openURLHandler
        self.store = store
        self.bridge = bridge
    }

    // MARK: - Lifecycle

    func onAppear() {
        refreshSnapshot()
        refreshAutoShift()

        if stateObserverToken == nil {
            stateObserverToken = bridge.addObserver(for: DictationConfig.DarwinNotification.stateDidChange) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.refreshSnapshot()
                }
            }
        }

        heartbeatPollTimer?.invalidate()
        heartbeatPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSnapshot()
            }
        }
    }

    func onDisappear() {
        stopBackspaceRepeat()
        heartbeatPollTimer?.invalidate()
        heartbeatPollTimer = nil

        if let token = stateObserverToken {
            bridge.removeObserver(token: token, for: DictationConfig.DarwinNotification.stateDidChange)
            stateObserverToken = nil
        }
    }

    // MARK: - Computed State

    var isHostSessionWarm: Bool {
        snapshot.isHostSessionWarm()
    }

    var isDictating: Bool {
        snapshot.phase == .listening || snapshot.phase == .processing || snapshot.phase == .launchingHost
    }

    var shouldShowDictationOverlay: Bool {
        isDictating && !showKeysWhileDictating
    }

    var letterRows: [[String]] {
        let base = [
            ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
            ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
            ["z", "x", "c", "v", "b", "n", "m"]
        ]
        if shiftState == .lowercase {
            return base
        }
        return base.map { row in row.map { $0.uppercased() } }
    }

    var numberRows: [[String]] {
        [
            ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
            ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
            [".", ",", "?", "!", "'"]
        ]
    }

    var symbolRows: [[String]] {
        [
            ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
            ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
            [".", ",", "?", "!", "'"]
        ]
    }

    // MARK: - Typing Actions

    func insertCharacter(_ text: String) {
        guard let proxy = proxyProvider() else { return }
        proxy.insertText(text)
        lastInsertedDictationCount = 0
        inlineNotice = nil

        if shiftState == .shifted {
            shiftState = .lowercase
        }
        if layoutMode != .letters && [".", "!", "?"].contains(text) {
            layoutMode = .letters
            shiftState = .shifted
        }
    }

    func tapSpace() {
        guard let proxy = proxyProvider() else { return }
        let now = Date()

        // Double-tap space inserts ". " when following a word character.
        if now.timeIntervalSince(lastSpaceTapAt) < 0.35,
           let before = proxy.documentContextBeforeInput,
           before.hasSuffix(" "),
           before.count >= 2 {
            let previousIndex = before.index(before.endIndex, offsetBy: -2)
            if before[previousIndex].isLetter || before[previousIndex].isNumber {
                proxy.deleteBackward()
                proxy.insertText(". ")
                lastSpaceTapAt = .distantPast
                refreshAutoShift()
                return
            }
        }

        proxy.insertText(" ")
        lastSpaceTapAt = now
        lastInsertedDictationCount = 0
        if layoutMode != .letters {
            layoutMode = .letters
        }
        refreshAutoShift()
    }

    func tapReturn() {
        proxyProvider()?.insertText("\n")
        lastInsertedDictationCount = 0
        refreshAutoShift()
    }

    func tapBackspace() {
        proxyProvider()?.deleteBackward()
        if lastInsertedDictationCount > 0 {
            lastInsertedDictationCount -= 1
        }
        refreshAutoShift()
    }

    func startBackspaceRepeat() {
        tapBackspace()
        backspaceRepeatTimer?.invalidate()
        backspaceRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.085, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tapBackspace()
            }
        }
    }

    func stopBackspaceRepeat() {
        backspaceRepeatTimer?.invalidate()
        backspaceRepeatTimer = nil
    }

    func tapShift() {
        let now = Date()
        switch shiftState {
        case .lowercase:
            shiftState = .shifted
        case .shifted:
            if now.timeIntervalSince(lastShiftTapAt) < 0.35 {
                shiftState = .capsLock
            } else {
                shiftState = .lowercase
            }
        case .capsLock:
            shiftState = .lowercase
        }
        lastShiftTapAt = now
    }

    func toggleModeKey() {
        layoutMode = (layoutMode == .letters) ? .numbers : .letters
    }

    func toggleSymbolsKey() {
        layoutMode = (layoutMode == .symbols) ? .numbers : .symbols
    }

    func advanceInputMode() {
        nextInputModeHandler()
    }

    func undoLastDictation() {
        guard lastInsertedDictationCount > 0, let proxy = proxyProvider() else { return }
        for _ in 0..<lastInsertedDictationCount {
            proxy.deleteBackward()
        }
        lastInsertedDictationCount = 0
        refreshAutoShift()
    }

    func refreshAutoShift() {
        guard shiftState != .capsLock else { return }
        let context = proxyProvider()?.documentContextBeforeInput ?? ""
        shiftState = TranscriptFormatter.isAtSentenceStart(context: context) ? .shifted : .lowercase
    }

    // MARK: - Dictation Actions

    func toggleDictation() {
        inlineNotice = nil

        guard hasFullAccess else {
            inlineNotice = "Enable Allow Full Access in Settings → Keyboards → Swipe."
            return
        }

        if snapshot.phase == .listening {
            stopDictation()
            return
        }

        if snapshot.phase == .processing {
            return
        }

        showKeysWhileDictating = false

        if isHostSessionWarm {
            // Zero-app-switch path: host app is already warm in the background.
            bridge.post(DictationConfig.DarwinNotification.startDictation)
        } else {
            // Cold-start path: launch host app once via swipe://dictate to arm audio.
            store.writeCommand(DictationCommand(action: .start))
            snapshot = DictationSnapshot(
                sessionID: UUID(),
                phase: .launchingHost,
                hostArmed: false,
                updatedAt: Date()
            )
            openURLHandler(DictationConfig.dictateURL)
        }
    }

    func stopDictation() {
        bridge.post(DictationConfig.DarwinNotification.stopDictation)
    }

    func cancelDictation() {
        showKeysWhileDictating = false
        bridge.post(DictationConfig.DarwinNotification.cancelDictation)
        if snapshot.phase == .launchingHost {
            snapshot = DictationSnapshot(phase: .idle)
        }
    }

    // MARK: - App Group Snapshot Sync

    private func refreshSnapshot() {
        let latest = store.readSnapshot()
        snapshot = latest

        if latest.phase == .error, let message = latest.errorMessage {
            inlineNotice = message
        }

        if latest.phase == .ready,
           !latest.finalText.isEmpty,
           consumedSessionID != latest.sessionID {
            consumedSessionID = latest.sessionID
            commitDictatedText(latest.finalText)
        }
    }

    private func commitDictatedText(_ rawTranscript: String) {
        guard let proxy = proxyProvider() else { return }
        let settings = store.readSettings()
        let formatted = TranscriptFormatter.formatForInsertion(
            rawTranscript: rawTranscript,
            contextBeforeInput: proxy.documentContextBeforeInput,
            settings: settings
        )
        guard !formatted.isEmpty else { return }

        proxy.insertText(formatted)
        lastInsertedDictationCount = formatted.count
        showKeysWhileDictating = false
        refreshAutoShift()
    }
}
