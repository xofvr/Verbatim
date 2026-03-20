import AppKit
import Carbon.HIToolbox
import Shared
import os.log

private let logger = Logger(subsystem: "farhan.verbatim", category: "DoubleTapClient")

@MainActor
final class LiveDoubleTapRuntime {
    private var localMonitor: Any?
    private var globalMonitor: Any?

    private var configuredKey: DoubleTapKey?
    private var interval: TimeInterval = 0.4
    private var onKeyDown: (@Sendable () -> Void)?
    private var onKeyUp: (@Sendable () -> Void)?

    private var lastTapUpAt: Date?
    private var isHoldActive = false

    func start(
        key: DoubleTapKey,
        interval: TimeInterval,
        onKeyDown: @escaping @Sendable () -> Void,
        onKeyUp: @escaping @Sendable () -> Void
    ) {
        stop()
        self.configuredKey = key
        self.interval = interval
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
        self.lastTapUpAt = nil
        self.isHoldActive = false
        logger.info("Starting double-tap monitor. keyCode=\(key.keyCode, privacy: .public), isModifier=\(key.isModifier, privacy: .public), interval=\(interval, privacy: .public)")
        installEventMonitors()
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        configuredKey = nil
        onKeyDown = nil
        onKeyUp = nil
        lastTapUpAt = nil
        isHoldActive = false
    }

    private func installEventMonitors() {
        let mask: NSEvent.EventTypeMask = configuredKey?.isModifier == true
            ? [.flagsChanged]
            : [.keyDown, .keyUp]

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }

        logger.info("Double-tap NSEvent monitors installed. hasLocal=\(self.localMonitor != nil, privacy: .public), hasGlobal=\(self.globalMonitor != nil, privacy: .public)")
    }

    private func handle(_ event: NSEvent) {
        guard let key = configuredKey else { return }
        let now = Date()

        if key.isModifier {
            guard event.type == .flagsChanged else { return }
            guard Int(event.keyCode) == key.keyCode else { return }

            let flags = cgEventFlags(from: event.modifierFlags)
            let isDown = isModifierDown(flags: flags, keyCode: key.keyCode)
            handleTransition(isDown: isDown, now: now)
            return
        }

        guard Int(event.keyCode) == key.keyCode else { return }
        guard event.isARepeat == false else { return }
        handleTransition(isDown: event.type == .keyDown, now: now)
    }

    private func handleTransition(isDown: Bool, now: Date) {
        if isDown {
            guard !isHoldActive else { return }
            guard let lastTapUpAt else { return }
            guard now.timeIntervalSince(lastTapUpAt) <= interval else { return }

            self.lastTapUpAt = nil
            isHoldActive = true
            logger.info("Double-tap hold detected")
            onKeyDown?()
            return
        }

        lastTapUpAt = now

        guard isHoldActive else { return }
        isHoldActive = false
        logger.info("Double-tap hold released")
        onKeyUp?()
    }

    private func isModifierDown(flags: CGEventFlags, keyCode: Int) -> Bool {
        switch keyCode {
        case kVK_Command, kVK_RightCommand:
            return flags.contains(.maskCommand)
        case kVK_Shift, kVK_RightShift:
            return flags.contains(.maskShift)
        case kVK_Option, kVK_RightOption:
            return flags.contains(.maskAlternate)
        case kVK_Control, kVK_RightControl:
            return flags.contains(.maskControl)
        case kVK_Function:
            return flags.contains(.maskSecondaryFn)
        default:
            return false
        }
    }

    private func cgEventFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var cgFlags: CGEventFlags = []
        if flags.contains(.command) { cgFlags.insert(.maskCommand) }
        if flags.contains(.shift) { cgFlags.insert(.maskShift) }
        if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if flags.contains(.control) { cgFlags.insert(.maskControl) }
        if flags.contains(.function) { cgFlags.insert(.maskSecondaryFn) }
        return cgFlags
    }
}

@MainActor
enum LiveDoubleTapRuntimeContainer {
    static let shared = LiveDoubleTapRuntime()
}
