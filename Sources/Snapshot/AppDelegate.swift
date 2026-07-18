import AppKit
import CoreGraphics
import ScreenCaptureKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let captureEngine = CaptureEngine()
    private lazy var statusBar = StatusBarController()
    private lazy var hotkeyManager = HotkeyManager { [weak self] in self?.saveClip() }

    private var currentTarget: CaptureTarget?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            showPermissionAlert()
            return
        }

        captureEngine.onStreamStopped = { [weak self] error in
            DispatchQueue.main.async {
                self?.statusBar.setRecording(false, targetName: nil)
                if let error {
                    print("Snapshot: capture stopped with error: \(error)")
                }
            }
        }

        statusBar.onSelectApp = { [weak self] app in self?.select(target: .app(app)) }
        statusBar.onSelectDisplay = { [weak self] display in self?.select(target: .display(display)) }
        statusBar.onToggleRecording = { [weak self] in self?.toggleRecording() }
        statusBar.onSaveNow = { [weak self] in self?.saveClip() }
        statusBar.onRefreshTargets = { [weak self] in self?.refreshTargets(autoStart: false) }
        statusBar.onQuit = { NSApp.terminate(nil) }

        hotkeyManager.start()
        refreshTargets(autoStart: true)
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
                print("Snapshot: failed to list capture targets: \(error)")
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

    private func saveClip() {
        guard captureEngine.isRunning else { return }
        Task {
            let video = await captureEngine.videoBuffer.snapshot()
            let audio = await captureEngine.audioBuffer.snapshot()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let url = Settings.outputDirectory.appendingPathComponent("Clip \(formatter.string(from: Date())).mp4")

            ClipExporter.export(video: video, audio: audio, to: url) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let savedURL):
                        print("Snapshot: saved clip to \(savedURL.path)")
                        self?.statusBar.flashSaved()
                    case .failure(let error):
                        print("Snapshot: export failed: \(error)")
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
