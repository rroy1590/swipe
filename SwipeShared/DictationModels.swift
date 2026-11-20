import Foundation

public enum DictationPhase: String, Codable, Equatable, Sendable {
    /// No active recording; host app may still be armed in the background.
    case idle
    /// Keyboard requested a cold-start handoff to the host app.
    case launchingHost
    /// Host app is actively streaming microphone audio into `SFSpeechRecognizer`.
    case listening
    /// Recording stopped; waiting for the final transcription pass to settle.
    case processing
    /// Final transcript is ready for the keyboard to insert.
    case ready
    /// Recoverable error (missing permission, speech engine unavailable, etc.).
    case error
}

public enum DictationCommandAction: String, Codable, Equatable, Sendable {
    case start
    case stop
    case cancel
}

public struct DictationCommand: Codable, Equatable, Sendable {
    public let id: UUID
    public let action: DictationCommandAction
    public let timestamp: Date

    public init(id: UUID = UUID(), action: DictationCommandAction, timestamp: Date = Date()) {
        self.id = id
        self.action = action
        self.timestamp = timestamp
    }
}

/// Shared state snapshot written by the host app and observed by the keyboard extension.
public struct DictationSnapshot: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let phase: DictationPhase
    public let partialText: String
    public let finalText: String
    /// Normalized 0.0...1.0 bar heights for live waveform rendering.
    public let audioLevels: [Float]
    public let errorMessage: String?
    /// Indicates whether the host app is keeping a warm background audio session alive.
    public let hostArmed: Bool
    /// Timestamp of the host app's most recent heartbeat.
    public let hostHeartbeatAt: Date?
    public let isOnDevice: Bool
    public let updatedAt: Date

    public init(
        sessionID: UUID = UUID(),
        phase: DictationPhase = .idle,
        partialText: String = "",
        finalText: String = "",
        audioLevels: [Float] = Array(repeating: 0.08, count: DictationConfig.waveformBarCount),
        errorMessage: String? = nil,
        hostArmed: Bool = false,
        hostHeartbeatAt: Date? = nil,
        isOnDevice: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.phase = phase
        self.partialText = partialText
        self.finalText = finalText
        self.audioLevels = audioLevels
        self.errorMessage = errorMessage
        self.hostArmed = hostArmed
        self.hostHeartbeatAt = hostHeartbeatAt
        self.isOnDevice = isOnDevice
        self.updatedAt = updatedAt
    }

    /// Returns true if the host app is actively armed and reported a recent heartbeat,
    /// meaning the keyboard can start/stop dictation in-place without an app switch.
    public func isHostSessionWarm(now: Date = Date()) -> Bool {
        guard hostArmed, let heartbeat = hostHeartbeatAt else { return false }
        return now.timeIntervalSince(heartbeat) <= DictationConfig.warmSessionHeartbeatTTL
    }
}

public struct DictationSettings: Codable, Equatable, Sendable {
    public var preferOnDeviceRecognition: Bool
    public var autoCapitalize: Bool
    public var smartPunctuationTidy: Bool
    public var keepWarmInBackground: Bool
    public var localeIdentifier: String

    public init(
        preferOnDeviceRecognition: Bool = true,
        autoCapitalize: Bool = true,
        smartPunctuationTidy: Bool = true,
        keepWarmInBackground: Bool = true,
        localeIdentifier: String = Locale.current.identifier
    ) {
        self.preferOnDeviceRecognition = preferOnDeviceRecognition
        self.autoCapitalize = autoCapitalize
        self.smartPunctuationTidy = smartPunctuationTidy
        self.keepWarmInBackground = keepWarmInBackground
        self.localeIdentifier = localeIdentifier
    }
}

public struct DictationHistoryItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let createdAt: Date
    public let durationSeconds: TimeInterval
    public let isOnDevice: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        durationSeconds: TimeInterval,
        isOnDevice: Bool
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.isOnDevice = isOnDevice
    }
}
