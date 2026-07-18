import AppKit

/// A minimal, plain-AppKit preferences window: two "click to record a new
/// shortcut" buttons. No XIB, no SwiftUI — kept consistent with the rest of
/// the app and small enough not to need either.
final class PreferencesWindowController: NSWindowController {
    private enum HotkeyTarget {
        case saveClip
        case saveFull
    }

    var onHotkeyChanged: (() -> Void)?

    private var saveClipButton: NSButton!
    private var saveFullButton: NSButton!
    private var recordingMonitor: Any?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Snapshot Preferences"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildContent()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window
        )
    }

    func show() {
        refreshLabels()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let clipLabel = NSTextField(labelWithString: "Save Clip:")
        let fullLabel = NSTextField(labelWithString: "Save Full Length:")
        saveClipButton = NSButton(title: "", target: self, action: #selector(startRecordingClipHotkey))
        saveFullButton = NSButton(title: "", target: self, action: #selector(startRecordingFullHotkey))

        let hint = NSTextField(wrappingLabelWithString: "Click a shortcut, then press a new key combo (needs at least one modifier key). Esc cancels.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [clipLabel, saveClipButton!],
            [fullLabel, saveFullButton!]
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 12

        let stack = NSStackView(views: [grid, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    private func refreshLabels() {
        saveClipButton.title = Settings.saveClipHotkey.displayString
        saveFullButton.title = Settings.saveFullLengthHotkey.displayString
    }

    @objc private func startRecordingClipHotkey() { beginRecording(for: .saveClip) }
    @objc private func startRecordingFullHotkey() { beginRecording(for: .saveFull) }

    private func beginRecording(for target: HotkeyTarget) {
        let button = target == .saveClip ? saveClipButton! : saveFullButton!
        button.title = "Press new shortcut\u{2026}"
        button.isEnabled = false

        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        print("Snapshot: began recording new combo for \(target)")
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            print("Snapshot: recorder saw keyCode=\(event.keyCode) rawModifiers=\(event.modifierFlags.rawValue)")

            if event.keyCode == 53 { // Escape cancels, no change committed
                print("Snapshot: recording cancelled (Escape)")
                self.endRecording(button: button)
                return nil
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !modifiers.isEmpty else {
                print("Snapshot: ignored bare keypress with no modifiers, still recording")
                return nil // swallow bare keypresses; keep waiting for a real combo
            }

            let combo = KeyCombo(keyCode: event.keyCode, modifiers: modifiers)
            let other = target == .saveClip ? Settings.saveFullLengthHotkey : Settings.saveClipHotkey
            guard combo != other else {
                print("Snapshot: rejected \(combo.displayString), collides with the other hotkey")
                self.endRecording(button: button)
                let alert = NSAlert()
                alert.messageText = "Shortcut already in use"
                alert.informativeText = "\(combo.displayString) is already assigned to the other action."
                alert.runModal()
                return nil
            }

            switch target {
            case .saveClip: Settings.saveClipHotkey = combo
            case .saveFull: Settings.saveFullLengthHotkey = combo
            }
            print("Snapshot: committed \(target) = \(combo.displayString); saveClipHotkey now reads \(Settings.saveClipHotkey.displayString), saveFullLengthHotkey now reads \(Settings.saveFullLengthHotkey.displayString)")
            self.endRecording(button: button)
            self.onHotkeyChanged?()
            return nil
        }
    }

    private func endRecording(button: NSButton) {
        if let recordingMonitor {
            NSEvent.removeMonitor(recordingMonitor)
            self.recordingMonitor = nil
        }
        button.isEnabled = true
        refreshLabels()
    }

    @objc private func windowWillClose() {
        if let recordingMonitor {
            NSEvent.removeMonitor(recordingMonitor)
            self.recordingMonitor = nil
        }
    }
}
