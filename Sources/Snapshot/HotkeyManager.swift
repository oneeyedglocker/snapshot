import AppKit

/// Global hotkey via NSEvent monitors. This needs the app to be trusted for
/// Accessibility (System Settings > Privacy & Security > Accessibility) —
/// without that, the global monitor silently never fires while another app
/// (e.g. the game) has focus.
final class HotkeyManager {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let onTrigger: () -> Void

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
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
        guard event.keyCode == Settings.hotkeyKeyCode else { return }
        let relevantFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard relevantFlags == Settings.hotkeyModifiers else { return }
        onTrigger()
    }

    deinit {
        stop()
    }
}
