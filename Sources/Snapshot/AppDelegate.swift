import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let saveClipHotkeyID = "saveClip"
    private static let saveFullHotkeyID = "saveFull"

    private let captureEngine = CaptureEngine()
    private lazy var statusBar = StatusBarController()
    private let hotkeyManager = HotkeyManager()
    private let overlay = OverlayHUD()
    private lazy var preferencesWindowController: PreferencesWindowController = {
        let controller = PreferencesWindowController()
        controller.onHotkeyChanged = { [weak self] in
            guard let self else { return }
            hotkeyManager.updateBinding(id: Self.saveClipHotkeyID, combo: Settings.saveClipHotkey)
            hotkeyManager.updateBinding(id: Self.saveFullHotkeyID, combo: Settings.saveFullLengthHotkey)
            statusBar.refreshMenu()
        }
        return controller
    }()

    private var currentTarget: CaptureTarget?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            showPermissionAlert()
            return
        }

        // Unlike Screen Recording, macOS won't prompt for Accessibility on
        // its own just because NSEvent.addGlobalMonitorForEvents is called —
        // it silently never fires until the app is trusted. Ask explicitly
        // so the hotkey has a chance of working without the user having to
        // discover the Accessibility pane themselves.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)

        captureEngine.onStreamStopped = { [weak self] error in
            DispatchQueue.main.async {
                self?.statusBar.setRecording(false, targetName: nil)
                if let error {
                    NSLog("%@", "Snapshot: capture stopped with error: \(error)")
                }
            }
        }

        statusBar.onSelectApp = { [weak self] app in self?.select(target: .app(app)) }
        statusBar.onSelectDisplay = { [weak self] display in self?.select(target: .display(display)) }
        statusBar.onToggleRecording = { [weak self] in self?.toggleRecording() }
        statusBar.onSaveNow = { [weak self] in self?.saveClip(lengthSeconds: Settings.exportSeconds) }
        statusBar.onSaveFullLengthNow = { [weak self] in self?.saveClip(lengthSeconds: self?.fullClipLengthSeconds ?? Settings.exportSeconds) }
        statusBar.onRefreshTargets = { [weak self] in self?.refreshTargets(autoStart: false) }
        statusBar.onSelectClipLength = { [weak self] seconds in self?.setClipLength(seconds) }
        statusBar.onOpenPreferences = { [weak self] in self?.preferencesWindowController.show() }
        statusBar.onQuit = { NSApp.terminate(nil) }

        hotkeyManager.register(id: Self.saveClipHotkeyID, combo: Settings.saveClipHotkey) { [weak self] in
            self?.saveClip(lengthSeconds: Settings.exportSeconds)
        }
        hotkeyManager.register(id: Self.saveFullHotkeyID, combo: Settings.saveFullLengthHotkey) { [weak self] in
            self?.saveClip(lengthSeconds: self?.fullClipLengthSeconds ?? Settings.exportSeconds)
        }
        hotkeyManager.start()
        refreshTargets(autoStart: true)
        observeAppLifecycle()
    }

    /// Watches for the preferred target app launching/quitting, so recording
    /// starts the moment you open WoW and stops when you close it — no need
    /// to remember to click Start/Stop.
    private func observeAppLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(runningAppDidLaunch(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(runningAppDidTerminate(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    @objc private func runningAppDidLaunch(_ notification: Notification) {
        guard !captureEngine.isRunning,
              let launched = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              isPreferredTarget(launched) else { return }
        attemptAutoStartAfterLaunch(attempt: 1)
    }

    private func isPreferredTarget(_ app: NSRunningApplication) -> Bool {
        if let saved = Settings.savedTarget, saved.kind == .app {
            return app.bundleIdentifier == saved.identifier
        }
        return (app.localizedName ?? "").localizedCaseInsensitiveContains("World of Warcraft")
    }

    /// ScreenCaptureKit won't list the app's window until it's actually
    /// created one, which can lag a few seconds behind process launch
    /// (loading screens, launcher handoff), so retry a few times.
    private func attemptAutoStartAfterLaunch(attempt: Int) {
        let delay: TimeInterval = attempt == 1 ? 3 : 6
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !captureEngine.isRunning else { return }
            Task {
                do {
                    let targets = try await CaptureEngine.availableTargets()
                    await MainActor.run {
                        self.statusBar.update(targets: targets)
                        self.tryAutoStart(with: targets)
                    }
                } catch {
                    NSLog("%@", "Snapshot: auto-start after launch failed to list targets: \(error)")
                }
                let stillNotRunning = await MainActor.run { !self.captureEngine.isRunning }
                if stillNotRunning, attempt < 3 {
                    self.attemptAutoStartAfterLaunch(attempt: attempt + 1)
                }
            }
        }
    }

    @objc private func runningAppDidTerminate(_ notification: Notification) {
        guard captureEngine.isRunning,
              case .app(let recordingApp)? = currentTarget,
              let terminated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              terminated.bundleIdentifier == recordingApp.bundleIdentifier else { return }
        Task {
            await captureEngine.stop()
            await MainActor.run { statusBar.setRecording(false, targetName: nil) }
        }
    }

    private var fullClipLengthSeconds: Double {
        Double(Settings.availableClipLengths.max() ?? Int(Settings.exportSeconds))
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.stop()
        Task { await captureEngine.stop() }
    }

    private func refreshTargets(autoStart: Bool) {
        Task {
            do {
                let targets = try await CaptureEngine.availableTargets()
                await MainActor.run { statusBar.update(targets: targets) }
                if autoStart {
                    tryAutoStart(with: targets)
                }
            } catch {
                NSLog("%@", "Snapshot: failed to list capture targets: \(error)")
            }
        }
    }

    /// Prefer whatever the user picked last time; if that target's gone
    /// (app quit, display unplugged), fall back to a friendly guess at WoW.
    private func tryAutoStart(with targets: AvailableTargets) {
        if let saved = Settings.savedTarget {
            switch saved.kind {
            case .app:
                if let app = targets.apps.first(where: { $0.bundleIdentifier == saved.identifier }) {
                    select(target: .app(app))
                    return
                }
            case .display:
                if let display = targets.displays.first(where: { String($0.displayID) == saved.identifier }) {
                    select(target: .display(display))
                    return
                }
            }
        }
        if let wow = targets.apps.first(where: { $0.applicationName.localizedCaseInsensitiveContains("World of Warcraft") }) {
            select(target: .app(wow))
        }
    }

    private func select(target: CaptureTarget) {
        currentTarget = target
        switch target {
        case .app(let app):
            Settings.savedTarget = PersistedTarget(kind: .app, identifier: app.bundleIdentifier, displayName: app.applicationName)
        case .display(let display):
            Settings.savedTarget = PersistedTarget(kind: .display, identifier: String(display.displayID), displayName: target.displayName)
        }
        startRecording()
    }

    private func setClipLength(_ seconds: Int) {
        Settings.exportSeconds = Double(seconds)
        statusBar.setClipLength(seconds)
    }

    private func toggleRecording() {
        if captureEngine.isRunning {
            Task {
                await captureEngine.stop()
                await MainActor.run { statusBar.setRecording(false, targetName: nil) }
            }
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard let currentTarget else { return }
        Task {
            do {
                try await captureEngine.start(target: currentTarget)
                await MainActor.run { statusBar.setRecording(true, targetName: currentTarget.displayName) }
            } catch {
                await MainActor.run {
                    statusBar.setRecording(false, targetName: nil)
                    let alert = NSAlert()
                    alert.messageText = "Couldn't start recording"
                    alert.informativeText = "\(error)"
                    alert.runModal()
                }
            }
        }
    }

    private func saveClip(lengthSeconds: Double) {
        guard captureEngine.isRunning else { return }
        Task {
            let video = await captureEngine.videoBuffer.snapshot()
            let audio = await captureEngine.audioBuffer.snapshot()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let url = Settings.outputDirectory.appendingPathComponent("Clip \(formatter.string(from: Date())).mp4")

            ClipExporter.export(video: video, audio: audio, lengthSeconds: lengthSeconds, to: url) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let savedURL):
                        NSLog("%@", "Snapshot: saved clip to \(savedURL.path)")
                        self?.statusBar.flashSaved()
                        self?.overlay.show(text: "Clip saved", systemSymbolName: "checkmark.circle.fill", tintColor: .systemGreen)
                    case .failure(let error):
                        NSLog("%@", "Snapshot: export failed: \(error)")
                        self?.overlay.show(text: "Save failed", systemSymbolName: "xmark.circle.fill", tintColor: .systemRed)
                    }
                }
            }
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = "Snapshot needs Screen Recording access. Open System Settings \u{2192} Privacy & Security \u{2192} Screen Recording, enable Snapshot, then relaunch the app."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        NSApp.terminate(nil)
    }
}
