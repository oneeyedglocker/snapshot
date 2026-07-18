import AppKit

/// A small, click-through, always-on-top toast for on-screen feedback (e.g.
/// "Clip saved") — the menu bar icon flash is too easy to miss while
/// heads-down in a game, so this puts a brief confirmation over the game
/// itself instead.
final class OverlayHUD {
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func show(text: String, systemSymbolName: String, tintColor: NSColor) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        guard let background = panel.contentView,
              let imageView = background.subviews.compactMap({ $0 as? NSImageView }).first,
              let label = background.subviews.compactMap({ $0 as? NSTextField }).first
        else { return }

        label.stringValue = text
        imageView.image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)
        imageView.contentTintColor = tintColor

        positionPanel(panel)

        hideWorkItem?.cancel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: workItem)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false

        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 220, height: 44))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        let imageView = NSImageView(frame: NSRect(x: 14, y: 12, width: 20, height: 20))
        imageView.imageScaling = .scaleProportionallyUpOrDown

        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 42, y: 12, width: 164, height: 20)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false

        background.addSubview(imageView)
        background.addSubview(label)
        panel.contentView = background

        return panel
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 24
        let frame = panel.frame
        let origin = NSPoint(
            x: screen.visibleFrame.maxX - frame.width - margin,
            y: screen.visibleFrame.maxY - frame.height - margin
        )
        panel.setFrameOrigin(origin)
    }
}
