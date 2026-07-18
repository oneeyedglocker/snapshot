import AppKit
import ScreenCaptureKit

/// The whole UI: a menu bar icon and a menu. No dock icon, no windows.
final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    private var apps: [SCRunningApplication] = []
    private var displays: [SCDisplay] = []
    private var isRecording = false
    private var currentTargetName: String?

    var onSelectApp: ((SCRunningApplication) -> Void)?
    var onSelectDisplay: ((SCDisplay) -> Void)?
    var onToggleRecording: (() -> Void)?
    var onSaveNow: (() -> Void)?
    var onRefreshTargets: (() -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Snapshot")
        statusItem.menu = buildMenu()
    }

    func update(targets: AvailableTargets) {
        apps = targets.apps.sorted { $0.applicationName < $1.applicationName }
        displays = targets.displays
        statusItem.menu = buildMenu()
    }

    func setRecording(_ recording: Bool, targetName: String?) {
        isRecording = recording
        currentTargetName = targetName
        statusItem.button?.image = NSImage(
            systemSymbolName: recording ? "record.circle.fill" : "record.circle",
            accessibilityDescription: nil
        )
        statusItem.menu = buildMenu()
    }

    func flashSaved() {
        let original = statusItem.button?.image
        statusItem.button?.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.statusItem.button?.image = original
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let statusLabel = NSMenuItem(
            title: isRecording ? "Recording: \(currentTargetName ?? "unknown")" : "Not recording",
            action: nil,
            keyEquivalent: ""
        )
        statusLabel.isEnabled = false
        menu.addItem(statusLabel)
        menu.addItem(.separator())

        let targetMenu = NSMenu()
        for app in apps {
            let item = NSMenuItem(title: app.applicationName, action: #selector(selectAppMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            targetMenu.addItem(item)
        }
        if !apps.isEmpty, !displays.isEmpty {
            targetMenu.addItem(.separator())
        }
        for display in displays {
            let item = NSMenuItem(
                title: "Display \(display.displayID) (\(display.width)\u{d7}\(display.height))",
                action: #selector(selectDisplayMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = display
            targetMenu.addItem(item)
        }
        if targetMenu.items.isEmpty {
            targetMenu.addItem(NSMenuItem(title: "No targets found", action: nil, keyEquivalent: ""))
        }
        let targetItem = NSMenuItem(title: "Capture Target", action: nil, keyEquivalent: "")
        targetItem.submenu = targetMenu
        menu.addItem(targetItem)

        let refreshItem = NSMenuItem(title: "Refresh Target List", action: #selector(refreshTargets), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(.separator())

        let toggleItem = NSMenuItem(
            title: isRecording ? "Stop Recording" : "Start Recording",
            action: #selector(toggleRecording),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let saveItem = NSMenuItem(title: "Save Last 30s Now (\u{2318}\u{21e7}R)", action: #selector(saveNow), keyEquivalent: "")
        saveItem.target = self
        saveItem.isEnabled = isRecording
        menu.addItem(saveItem)
        menu.addItem(.separator())

        let folderItem = NSMenuItem(title: "Show Clips Folder", action: #selector(revealOutputFolder), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Snapshot", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func selectAppMenuItem(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? SCRunningApplication else { return }
        onSelectApp?(app)
    }

    @objc private func selectDisplayMenuItem(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? SCDisplay else { return }
        onSelectDisplay?(display)
    }

    @objc private func toggleRecording() { onToggleRecording?() }
    @objc private func saveNow() { onSaveNow?() }
    @objc private func refreshTargets() { onRefreshTargets?() }
    @objc private func quit() { onQuit?() }

    @objc private func revealOutputFolder() {
        NSWorkspace.shared.open(Settings.outputDirectory)
    }
}
