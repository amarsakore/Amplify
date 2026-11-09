import SwiftUI
import AppKit
import Observation

@main
struct AmplifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

/// Borderless panel that can take key focus (for hover/escape) without activating the app.
final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: GlassPanel!
    private var hosting: NSHostingView<AnyView>!
    private var clickMonitor: Any?
    private let audio = AudioController.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            snapshot(to: CommandLine.arguments[i + 1])
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--latency"), i + 1 < CommandLine.arguments.count {
            let lines = TapEngine.probeLatency(seconds: 3)
            try? lines.joined(separator: "\n").write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
            exit(0)
        }
        audio.launch()
        setUpStatusItem()
        setUpPanel()
        trackIcon()
        if let i = CommandLine.arguments.firstIndex(of: "--clicktest"), i + 1 < CommandLine.arguments.count {
            runClickTest(log: CommandLine.arguments[i + 1])
        }
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showPanel()
                if CommandLine.arguments.contains("--settings") { PanelState.shared.showSettings = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let v = self.panel.contentView,
                          let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    if let i = CommandLine.arguments.firstIndex(of: "--show"), i + 1 < CommandLine.arguments.count {
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { audio.shutdown() }

    // MARK: Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func trackIcon() {
        withObservationTracking {
            let name = audio.menuIcon
            statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Amplify")
        } onChange: {
            Task { @MainActor [weak self] in self?.trackIcon() }
        }
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showContextMenu(); return }
        panel.isVisible ? hidePanel() : showPanel()
    }

    private func showContextMenu() {
        hidePanel()
        let menu = NSMenu()
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = audio.launchAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Amplify", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleLogin() { audio.launchAtLogin.toggle() }

    // MARK: Glass panel

    private func setUpPanel() {
        panel = GlassPanel(contentRect: .zero,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The window-server shadow is computed from the rectangular window and shows up as a
        // hard square outline, so draw our own rounded shadow instead.
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        hosting = NSHostingView(rootView: AnyView(
            PanelView(onDismiss: { [weak self] in self?.hidePanel() },
                      onSizeChange: { [weak self] in self?.contentSizeChanged($0) })
                .environment(audio)))

        // No safe-area insets: otherwise SwiftUI pads the content and it overflows the glass.
        hosting.safeAreaRegions = []
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = Self.corner
            g.style = .regular
            g.contentView = hosting
            glass = g
        } else {
            // Older macOS: the frosted material used by system popovers and Control Center.
            let v = NSVisualEffectView()
            v.material = .popover
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = Self.corner
            v.layer?.cornerCurve = .continuous
            v.layer?.masksToBounds = true
            hosting.frame = v.bounds
            v.addSubview(hosting)
            glass = v
        }
        glass.autoresizingMask = [.width, .height]
        hosting.autoresizingMask = [.width, .height]

        shadow = NSView()
        shadow.wantsLayer = true
        shadow.layer?.shadowColor = NSColor.black.cgColor
        shadow.layer?.shadowOpacity = 0.22
        shadow.layer?.shadowRadius = 14
        shadow.layer?.shadowOffset = CGSize(width: 0, height: -4)

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = .clear
        root.addSubview(shadow)
        root.addSubview(glass)
        panel.contentView = root
    }

    private static let corner: CGFloat = 16
    private static let margin: CGFloat = 24   // transparent room around the glass for the shadow
    private var glass: NSView!
    private var shadow: NSView!

    /// Latest SwiftUI content size, reported live by PanelView.
    private var contentSize = NSSize(width: 230, height: 200)

    private func contentSizeChanged(_ size: CGSize) {
        let new = NSSize(width: ceil(size.width), height: ceil(size.height))
        guard new != contentSize else { return }
        contentSize = new
        // Resize on the next run-loop turn: resizing the window while SwiftUI is still
        // handling the click leaves the button's gesture state stuck (later clicks are ignored).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.layoutPanel(animated: true)
        }
    }

    /// Sizes the panel to the content, pinned just under the status item (grows downward).
    private func layoutPanel(animated: Bool = false) {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let size = contentSize
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let y = anchor.minY - size.height - 6
        let m = Self.margin
        let frame = NSRect(x: x - m, y: y - m, width: size.width + 2 * m, height: size.height + 2 * m)
        let inner = NSRect(x: m, y: m, width: size.width, height: size.height)
        if animated {
            // Top edge stays put; the bottom edge slides, so sections fold in place.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
            glass.frame = inner
            hosting.frame = NSRect(origin: .zero, size: inner.size)
        }
        shadow.frame = inner
        shadow.layer?.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: inner.size),
                                          cornerWidth: Self.corner, cornerHeight: Self.corner, transform: nil)
        // Mask out the inside so the shadow never darkens the glass itself.
        let mask = CAShapeLayer()
        let ring = CGMutablePath()
        ring.addRect(CGRect(origin: .zero, size: inner.size).insetBy(dx: -m, dy: -m))
        ring.addRoundedRect(in: CGRect(origin: .zero, size: inner.size), cornerWidth: Self.corner, cornerHeight: Self.corner)
        mask.path = ring
        mask.fillRule = .evenOdd
        shadow.layer?.mask = mask
    }

    private func showPanel() {
        PanelState.shared.showSettings = false
        hosting.layoutSubtreeIfNeeded()
        layoutPanel()

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        }
    }

    private func hidePanel() {
        guard panel?.isVisible == true else { return }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        PanelState.shared.hovered = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { self.panel.orderOut(nil) }
        }
    }

    // MARK: Debug click test (sends real mouse events through the window to the gear button)

    private func runClickTest(log path: String) {
        var lines: [String] = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.showPanel()
            let gearFromTop = self.contentSize.height - 16   // gear centre measured from the top
            @MainActor func click(_ n: Int) {
                guard n < 4 else {
                    try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                    exit(0)
                }
                let m = Self.margin
                let pt = NSPoint(x: m + self.contentSize.width - 18, y: m + self.contentSize.height - gearFromTop)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: self.panel.windowNumber, context: nil, eventNumber: n,
                                                  clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                        self.panel.sendEvent(e)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated {
                    lines.append("click \(n + 1): settings=\(PanelState.shared.showSettings) height=\(self.contentSize.height) window=\(self.panel.frame.height)")
                    click(n + 1)
                } }
            }
            click(0)
        }
    }

    // MARK: Debug snapshot

    private func snapshot(to path: String) {
        let view = PanelView(onDismiss: {}, onSizeChange: { _ in }).environment(audio)
            .background(LinearGradient(colors: [Color(red: 0.32, green: 0.42, blue: 0.62),
                                                Color(red: 0.55, green: 0.48, blue: 0.5)],
                                       startPoint: .top, endPoint: .bottom))
            .clipShape(.rect(cornerRadius: 16))
            .environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
