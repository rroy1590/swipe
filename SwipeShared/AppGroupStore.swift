import Foundation

/// App Group persistence layer shared between the `Swipe` host app and `SwipeKeyboard`.
public final class AppGroupStore: @unchecked Sendable {
    public static let shared = AppGroupStore()

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    public init(suiteName: String = DictationConfig.appGroupID) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func readSnapshot() -> DictationSnapshot {
        lock.lock()
        defer { lock.unlock() }

        guard let data = defaults.data(forKey: DictationConfig.StorageKey.snapshot),
              let decoded = try? decoder.decode(DictationSnapshot.self, from: data) else {
            return DictationSnapshot()
        }
        return decoded
    }

    public func writeSnapshot(_ snapshot: DictationSnapshot) {
        lock.lock()
        if let data = try? encoder.encode(snapshot) {
            defaults.set(data, forKey: DictationConfig.StorageKey.snapshot)
        }
        lock.unlock()
    }

    public func writeCommand(_ command: DictationCommand) {
        lock.lock()
        if let data = try? encoder.encode(command) {
            defaults.set(data, forKey: DictationConfig.StorageKey.pendingCommand)
        }
        lock.unlock()
    }

    public func consumeCommand() -> DictationCommand? {
        lock.lock()
        defer { lock.unlock() }

        guard let data = defaults.data(forKey: DictationConfig.StorageKey.pendingCommand),
              let decoded = try? decoder.decode(DictationCommand.self, from: data) else {
            return nil
        }
        defaults.removeObject(forKey: DictationConfig.StorageKey.pendingCommand)
        return decoded
    }

    public func readSettings() -> DictationSettings {
        lock.lock()
        defer { lock.unlock() }

        guard let data = defaults.data(forKey: DictationConfig.StorageKey.settings),
              let decoded = try? decoder.decode(DictationSettings.self, from: data) else {
            return DictationSettings()
        }
        return decoded
    }

    public func writeSettings(_ settings: DictationSettings) {
        lock.lock()
        if let data = try? encoder.encode(settings) {
            defaults.set(data, forKey: DictationConfig.StorageKey.settings)
        }
        lock.unlock()
    }

    public func readHistory() -> [DictationHistoryItem] {
        lock.lock()
        defer { lock.unlock() }

        guard let data = defaults.data(forKey: DictationConfig.StorageKey.history),
              let decoded = try? decoder.decode([DictationHistoryItem].self, from: data) else {
            return []
        }
        return decoded
    }

    public func appendHistory(_ item: DictationHistoryItem, limit: Int = 25) {
        lock.lock()
        defer { lock.unlock() }

        var existing: [DictationHistoryItem] = []
        if let data = defaults.data(forKey: DictationConfig.StorageKey.history),
           let decoded = try? decoder.decode([DictationHistoryItem].self, from: data) {
            existing = decoded
        }
        existing.insert(item, at: 0)
        if existing.count > limit {
            existing = Array(existing.prefix(limit))
        }
        if let data = try? encoder.encode(existing) {
            defaults.set(data, forKey: DictationConfig.StorageKey.history)
        }
    }

    public func clearHistory() {
        lock.lock()
        defaults.removeObject(forKey: DictationConfig.StorageKey.history)
        lock.unlock()
    }
}

/// Formats raw speech transcripts so they blend naturally at the current cursor position.
public enum TranscriptFormatter {
    public static func formatForInsertion(
        rawTranscript: String,
        contextBeforeInput: String?,
        settings: DictationSettings
    ) -> String {
        var text = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        if settings.smartPunctuationTidy {
            text = tidyTranscript(text)
        }

        let context = contextBeforeInput ?? ""
        let shouldCapitalize = settings.autoCapitalize && isAtSentenceStart(context: context)
        if shouldCapitalize, let first = text.first, first.isLetter {
            text = String(first).uppercased() + text.dropFirst()
        } else if !shouldCapitalize, let first = text.first, first.isUppercase, !startsWithStandaloneI(text) {
            // Avoid mid-sentence accidental capitalization when continuing an existing clause.
            text = String(first).lowercased() + text.dropFirst()
        }

        let needsLeadingSpace = requiresLeadingSpace(context: context, incoming: text)
        return needsLeadingSpace ? " " + text : text
    }

    static func tidyTranscript(_ input: String) -> String {
        var result = input

        // Collapse duplicate spaces created by incremental recognition edits.
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        // Remove space before terminal punctuation if speech recognition emitted one.
        for mark in [".", ",", "!", "?", ";", ":"] {
            result = result.replacingOccurrences(of: " \(mark)", with: mark)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isAtSentenceStart(context: String) -> Bool {
        let trimmed = context.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        guard let last = trimmed.last else { return true }
        return last == "." || last == "!" || last == "?" || last == "\n"
    }

    static func requiresLeadingSpace(context: String, incoming: String) -> Bool {
        guard let last = context.last, let firstIncoming = incoming.first else {
            return false
        }
        if last.isWhitespace || last.isNewline { return false }
        if "([{\"'“‘/-".contains(last) { return false }
        if ".,!?;:)]}".contains(firstIncoming) { return false }
        return true
    }

    private static func startsWithStandaloneI(_ text: String) -> Bool {
        text == "I" || text.hasPrefix("I ") || text.hasPrefix("I'") || text.hasPrefix("I’")
    }
}
