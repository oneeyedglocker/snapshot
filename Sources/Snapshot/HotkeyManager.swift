import AppKit

/// Dispatches global hotkeys to registered actions by id, via NSEvent
/// monitors. Needs the app to be trusted for Accessibility (System Settings
/// > Privacy & Security > Accessibility) — without that, the global monitor
/// silently never fires while another app (e.g. the game) has focus.
final class HotkeyManager {
    private struct Registration {
        var combo: KeyCombo
        let action: () -> Void
    }

    private var registrations: [String: Registration] = [:]
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func register(id: String, combo: KeyCombo, action: @escaping () -> Void) {
        registrations[id] = Registration(combo: combo, action: action)
    }

    func updateBinding(id: String, combo: KeyCombo) {
        registrations[id]?.combo = combo
    }

    func start() {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        let combo = KeyCombo(keyCode: event.keyCode, modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        for registration in registrations.values where registration.combo == combo {
            registration.action()
        }
    }

    deinit {
        stop()
    }
}
