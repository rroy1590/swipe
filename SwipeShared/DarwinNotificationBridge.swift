import CoreFoundation
import Foundation

/// Thin, memory-safe wrapper around Darwin notifications (`CFNotificationCenterGetDarwinNotifyCenter`)
/// for instant, zero-polling signaling between the `Swipe` host app and `SwipeKeyboard` extension.
public final class DarwinNotificationBridge: @unchecked Sendable {
    public static let shared = DarwinNotificationBridge()

    private let lock = NSLock()
    private var handlers: [String: [UUID: @Sendable () -> Void]] = [:]

    private init() {}

    /// Posts a cross-process Darwin notification immediately.
    public func post(_ name: String) {
        let cfName = CFNotificationName(name as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            cfName,
            nil,
            nil,
            true
        )
    }

    /// Registers a callback for a Darwin notification name. Returns a token that can be passed
    /// to `removeObserver(token:name:)` when tearing down.
    @discardableResult
    public func addObserver(for name: String, handler: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        let shouldRegisterWithSystem = (handlers[name]?.isEmpty ?? true)
        var bucket = handlers[name] ?? [:]
        bucket[token] = handler
        handlers[name] = bucket
        lock.unlock()

        if shouldRegisterWithSystem {
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterAddObserver(
                center,
                Unmanaged.passUnretained(self).toOpaque(),
                DarwinNotificationBridge.callback,
                name as CFString,
                nil,
                .deliverImmediately
            )
        }

        return token
    }

    public func removeObserver(token: UUID, for name: String) {
        lock.lock()
        handlers[name]?[token] = nil
        let shouldUnregisterFromSystem = (handlers[name]?.isEmpty ?? true)
        if shouldUnregisterFromSystem {
            handlers[name] = nil
        }
        lock.unlock()

        if shouldUnregisterFromSystem {
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterRemoveObserver(
                center,
                Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName(name as CFString),
                nil
            )
        }
    }

    private func handleNotification(named name: String) {
        lock.lock()
        let callbacks = handlers[name].map { Array($0.values) } ?? []
        lock.unlock()

        for callback in callbacks {
            callback()
        }
    }

    private static let callback: CFNotificationCallback = { _, observer, cfName, _, _ in
        guard let observer, let cfName else { return }
        let bridge = Unmanaged<DarwinNotificationBridge>.fromOpaque(observer).takeUnretainedValue()
        let name = cfName.rawValue as String
        bridge.handleNotification(named: name)
    }
}

/// Automatically unregisters Darwin notification observers when deallocated,
/// avoiding actor-isolation warnings in `@MainActor` `deinit` implementations.
public final class DarwinObserverBag: @unchecked Sendable {
    private let bridge: DarwinNotificationBridge
    private let lock = NSLock()
    private var entries: [(UUID, String)] = []

    public init(bridge: DarwinNotificationBridge = .shared) {
        self.bridge = bridge
    }

    public func observe(_ name: String, handler: @escaping @Sendable () -> Void) {
        let token = bridge.addObserver(for: name, handler: handler)
        lock.lock()
        entries.append((token, name))
        lock.unlock()
    }

    public func removeAll() {
        lock.lock()
        let current = entries
        entries.removeAll()
        lock.unlock()

        for (token, name) in current {
            bridge.removeObserver(token: token, for: name)
        }
    }

    deinit {
        removeAll()
    }
}
