import Cocoa
import WebKit
import ServiceManagement

// Pokémon Roam: a crowd of pixel Pokémon living on your whole screen. Each display gets a
// transparent, click-through window; walkers stroll along the bottom (just above the Dock) and
// flyers cross the sky. They can't take clicks, so they react to where your cursor is instead.

let roamConfigURL = baseDir.appendingPathComponent("roam.json")

struct RoamSettings: Codable {
    var count = 15          // Pokémon across all displays
    var scale = 2           // sprite pixels per screen point
    var onTop = true        // above your windows (false: on the desktop, behind them)
    var paused = false

    static func load() -> RoamSettings {
        guard let data = try? Data(contentsOf: roamConfigURL),
              let s = try? JSONDecoder().decode(RoamSettings.self, from: data) else { return RoamSettings() }
        return s
    }
    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? enc.encode(self).write(to: roamConfigURL)
    }
}

final class RoamWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One display's window and page.
final class Stage: NSObject, WKScriptMessageHandler {
    let screen: NSScreen
    let window: RoamWindow
    let web: WKWebView
    var ready = false
    var onReady: ((Stage) -> Void)?

    init(screen: NSScreen) {
        self.screen = screen
        window = RoamWindow(contentRect: screen.visibleFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(SchemeHandler(), forURLScheme: "pw")
        web = WKWebView(frame: NSRect(origin: .zero, size: screen.visibleFrame.size), configuration: cfg)
        super.init()
        cfg.userContentController.add(self, name: "native")
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        window.contentView = web
        window.setFrame(screen.visibleFrame, display: false)
        web.load(URLRequest(url: URL(string: "pw://app/roam.html")!))
        window.orderFrontRegardless()
    }

    func setLevel(onTop: Bool) {
        window.level = onTop ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    func call(_ fn: String, _ obj: Any) {
        guard ready, let data = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.roam && roam.\(fn)(\(json))")
    }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["type"] as? String == "ready" else { return }
        ready = true
        onReady?(self)
    }

    func close() {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "native")
        window.orderOut(nil)
        window.close()
    }
}

final class RoamApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var settings = RoamSettings.load()
    var stages: [Stage] = []
    var sprites: [String: Any]?
    var status: NSStatusItem!
    var lastMouse = NSPoint(x: -1, y: -1)

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        DispatchQueue.global(qos: .userInitiated).async {
            let s: [String: Any] = [
                "normal": loadWalkData(spritesDir.appendingPathComponent("walk"), animDir: spritesDir.appendingPathComponent("anim")),
                "shiny": loadWalkData(spritesDir.appendingPathComponent("shiny/walk"), animDir: spritesDir.appendingPathComponent("shiny/anim")),
                "names": Dictionary(uniqueKeysWithValues: (1...386).map { (String($0), displayName($0)) }),
            ]
            DispatchQueue.main.async {
                self.sprites = s
                self.stages.filter { $0.ready }.forEach { self.start($0) }
            }
        }
        buildStages()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.buildStages()
        }
        // The windows ignore the mouse, so the cursor's position is passed in for them to react to.
        Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.trackMouse() }
    }

    // MARK: Stages (one per display)

    func buildStages() {
        stages.forEach { $0.close() }
        stages = NSScreen.screens.map { screen in
            let st = Stage(screen: screen)
            st.setLevel(onTop: settings.onTop)
            st.onReady = { [weak self] st in self?.start(st) }
            return st
        }
    }

    /// How many of the Pokémon each display gets, by its width.
    func share(_ st: Stage) -> Int {
        let total = stages.reduce(0.0) { $0 + $1.screen.visibleFrame.width }
        guard total > 0 else { return settings.count }
        return max(1, Int((Double(settings.count) * st.screen.visibleFrame.width / total).rounded()))
    }

    func start(_ st: Stage) {
        guard let sprites else { return }
        var setup = sprites
        setup["count"] = share(st)
        setup["scale"] = settings.scale
        setup["paused"] = settings.paused
        st.call("setup", setup)
    }

    func trackMouse() {
        let p = NSEvent.mouseLocation
        guard p != lastMouse else { return }
        lastMouse = p
        for st in stages where st.ready {
            let f = st.window.frame
            if f.contains(p) {
                st.call("mouse", ["x": p.x - f.minX, "y": f.maxY - p.y])   // page coordinates: origin top-left
            } else {
                st.call("mouse", NSNull())
            }
        }
    }

    // MARK: Menu bar

    func buildMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "pawprint", accessibilityDescription: "Pokémon Roam")
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ sel: Selector, _ tag: Int = 0, on: Bool = false) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            i.tag = tag
            i.state = on ? .on : .off
            return i
        }
        menu.addItem(item("New faces", #selector(shuffle)))
        menu.addItem(item(settings.paused ? "Resume" : "Pause", #selector(togglePause)))
        menu.addItem(.separator())
        let countItem = NSMenuItem(title: "How many", action: nil, keyEquivalent: "")
        let counts = NSMenu()
        for c in [5, 10, 15, 20, 30] { counts.addItem(item("\(c)", #selector(setCount(_:)), c, on: settings.count == c)) }
        countItem.submenu = counts
        menu.addItem(countItem)
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sizes = NSMenu()
        for (t, s) in [("Small", 1), ("Medium", 2), ("Large", 3)] { sizes.addItem(item(t, #selector(setScale(_:)), s, on: settings.scale == s)) }
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)
        menu.addItem(item("Above windows", #selector(toggleOnTop), on: settings.onTop))
        menu.addItem(item("Open at login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(item("Quit Pokémon Roam", #selector(quit)))
    }

    @objc func shuffle() { stages.forEach { $0.call("shuffle", NSNull()) } }
    @objc func togglePause() {
        settings.paused.toggle(); settings.save()
        stages.forEach { $0.call("pause", settings.paused) }
    }
    @objc func setCount(_ sender: NSMenuItem) {
        settings.count = sender.tag; settings.save()
        stages.forEach { $0.call("setCount", share($0)) }
    }
    @objc func setScale(_ sender: NSMenuItem) {
        settings.scale = sender.tag; settings.save()
        stages.forEach { $0.call("setScale", settings.scale) }
    }
    @objc func toggleOnTop() {
        settings.onTop.toggle(); settings.save()
        stages.forEach { $0.setLevel(onTop: settings.onTop) }
    }
    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
    }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let roamApp = RoamApp()
app.delegate = roamApp
app.run()
