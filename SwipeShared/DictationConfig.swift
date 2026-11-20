import Foundation

/// Shared identifiers and cross-process constants used by both the `Swipe` host app
/// and the `SwipeKeyboard` app extension.
///
/// Update `appGroupID` here AND in both `.entitlements` files if you change your
/// signing team or bundle identifier prefix in Xcode.
public enum DictationConfig {
    public static let appGroupID = "group.com.roy.raunak.Swipe"
    public static let urlScheme = "swipe"
    public static let dictateHost = "dictate"

    public static var dictateURL: URL {
        URL(string: "\(urlScheme)://\(dictateHost)")!
    }

    /// How long after the host app's last heartbeat the keyboard considers the
    /// background audio session warm (allowing zero-app-switch start/stop).
    public static let warmSessionHeartbeatTTL: TimeInterval = 8.0

    /// Number of audio level bars shared between the host app and keyboard UI.
    public static let waveformBarCount = 16

    public enum DarwinNotification {
        public static let prefix = "com.roy.raunak.Swipe.darwin."
        public static let startDictation = prefix + "startDictation"
        public static let stopDictation = prefix + "stopDictation"
        public static let cancelDictation = prefix + "cancelDictation"
        public static let stateDidChange = prefix + "stateDidChange"
    }

    public enum StorageKey {
        public static let snapshot = "swipe.dictation.snapshot.v1"
        public static let pendingCommand = "swipe.dictation.pendingCommand.v1"
        public static let settings = "swipe.dictation.settings.v1"
        public static let history = "swipe.dictation.history.v1"
    }
}
