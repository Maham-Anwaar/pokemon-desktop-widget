import Cocoa
import WebKit
import IOKit.ps
import ServiceManagement

// MARK: - Paths and settings

let configURL = baseDir.appendingPathComponent("config.json")

struct Settings {
    var name: String
    var city: String
    var latitude: Double
    var longitude: Double
    var accent: String
    var keepOnDesktop: Bool
    var useGitHub: Bool
    var shinyOdds: Int
    var size: String

    static let sizes: [(key: String, title: String, size: NSSize)] = [
        ("large", "Large  (560 × 470)", NSSize(width: 560, height: 470)),
        ("medium", "Medium  (748 × 190)", NSSize(width: 748, height: 190)),
        ("small", "Small  (170 × 170)", NSSize(width: 170, height: 170)),
        ("mini", "Mini route  (320 × 64)", NSSize(width: 320, height: 64)),
    ]
    var pixelSize: NSSize { Settings.sizes.first { $0.key == size }?.size ?? Settings.sizes[0].size }

    static func load() -> Settings {
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
        var s = Settings(name: first.uppercased(), city: "London", latitude: 51.5072, longitude: -0.1276,
                         accent: "#FFCB05", keepOnDesktop: true, useGitHub: true, shinyOdds: 64, size: "large")
        var missingKey = false
        if let data = try? Data(contentsOf: configURL),
           let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let v = d["name"] as? String { s.name = v }
            if let v = d["city"] as? String { s.city = v }
            if let v = d["latitude"] as? Double { s.latitude = v }
            if let v = d["longitude"] as? Double { s.longitude = v }
            if let v = d["accent"] as? String { s.accent = v }
            if let v = d["keepOnDesktop"] as? Bool { s.keepOnDesktop = v }
            if let v = d["useGitHub"] as? Bool { s.useGitHub = v }
            if let v = d["shinyOdds"] as? Int { s.shinyOdds = max(1, v) } else { missingKey = true }
            if let v = d["size"] as? String, sizes.contains(where: { $0.key == v }) { s.size = v } else { missingKey = true }
        } else {
            missingKey = true
        }
        if missingKey { s.save() }
        return s
    }

    func save() {
        let d: [String: Any] = ["name": name, "city": city, "latitude": latitude, "longitude": longitude,
                                "accent": accent, "keepOnDesktop": keepOnDesktop, "useGitHub": useGitHub,
                                "shinyOdds": shinyOdds, "size": size]
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) {
            try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
            try? data.write(to: configURL)
        }
    }
}

// MARK: - Shell helper

@discardableResult
func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let deadline = Date().addingTimeInterval(timeout)
    let data = out.fileHandleForReading.readDataToEndOfFile()
    while p.isRunning && Date() < deadline { usleep(20_000) }
    if p.isRunning { p.terminate(); return nil }
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
}

func findExecutable(_ name: String) -> String? {
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
        let p = "\(dir)/\(name)"
        if fm.isExecutableFile(atPath: p) { return p }
    }
    return nil
}

// MARK: - System vitals

final class Vitals {
    private var lastTicks: [UInt32]?
    private(set) var model = "MAC"

    init() {
        DispatchQueue.global(qos: .utility).async {
            if let out = run("/usr/sbin/system_profiler", ["SPHardwareDataType"]),
               let line = out.split(separator: "\n").first(where: { $0.contains("Model Name:") }) {
                let name = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "Mac"
                self.model = name.uppercased()
            }
        }
    }

    func memoryFreePct() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return 0 }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let anon = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = anon > purgeable ? anon - purgeable : 0
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * UInt64(pageSize)
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return max(0, min(100, 100 * (1 - Double(used) / total)))
    }

    func cpuPct() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return 0 }
        let t = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3] // user, system, idle, nice
        defer { lastTicks = t }
        guard let l = lastTicks else { return 0 }
        let d = zip(t, l).map { Double($0 &- $1) }
        let total = d.reduce(0, +)
        return total > 0 ? 100 * (total - d[2]) / total : 0
    }

    func diskUsedPct() -> Double {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity, total > 0,
              let avail = v.volumeAvailableCapacityForImportantUsage else { return 0 }
        return 100 * (1 - Double(avail) / Double(total))
    }

    func batteryPct() -> Int? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            if let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
               let cur = d[kIOPSCurrentCapacityKey] as? Int,
               let mx = d[kIOPSMaxCapacityKey] as? Int, mx > 0 {
                return cur * 100 / mx
            }
        }
        return nil
    }

    func snapshot() -> [String: Any] {
        // "Level" is days since the Mac last restarted.
        let level = Int(ProcessInfo.processInfo.systemUptime / 86400) + 1
        var s: [String: Any] = ["memFree": memoryFreePct(), "cpu": cpuPct(), "disk": diskUsedPct(),
                                "model": model, "level": level]
        s["battery"] = batteryPct() ?? NSNull()
        return s
    }
}

// MARK: - Data sources

func monthInfo(_ now: Date) -> (info: [String: Any], first: Date, days: Int, today: Int) {
    let cal = Calendar.current
    let comps = cal.dateComponents([.year, .month, .day], from: now)
    let first = cal.date(from: DateComponents(year: comps.year, month: comps.month, day: 1))!
    let days = cal.range(of: .day, in: .month, for: now)!.count
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "MMMM yyyy"
    let label = fmt.string(from: now).uppercased()
    fmt.dateFormat = "MMMM"
    let long = fmt.string(from: now)
    fmt.dateFormat = "MMM"
    let short = fmt.string(from: now)
    fmt.dateFormat = "yyyy-MM"
    let ym = fmt.string(from: now)
    let info: [String: Any] = ["label": label, "long": long, "short": short, "days": days, "today": comps.day!, "ym": ym,
                               "firstWeekday": cal.component(.weekday, from: first) - 1]
    return (info, first, days, comps.day!)
}

func isoDay(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
}

/// One weather code that sums up a day.
/// Open-Meteo's daily code is the *worst* hour (one drizzly hour makes the whole day "rain"),
/// so use the most common daytime weather instead, and only call it wet when rain is likely:
/// at least a 50% chance, or 1 mm or more (past days have no chance figure, just the amount).
func typicalWeather(worst: Int, daytime: [Int], rainMM: Double, rainChance: Double?) -> Int {
    let wetCode = 51   // drizzle, rain, snow and storms are all 51 and up
    let rainLikely = (rainChance ?? 0) >= 50 || rainMM >= 1
    if worst >= wetCode && rainLikely { return worst }
    let dry = daytime.filter { $0 < wetCode }
    guard !dry.isEmpty else { return rainLikely ? worst : 3 }   // no dry daytime hours: call it overcast
    var counts: [Int: Int] = [:]
    for c in dry { counts[c, default: 0] += 1 }
    // Most common daytime weather; on a tie, the cloudier of the two.
    return counts.max { a, b in a.value == b.value ? a.key < b.key : a.value < b.value }!.key
}

func fetchWeather(_ s: Settings, completion: @escaping ([String: Any]?) -> Void) {
    let now = Date()
    let m = monthInfo(now)
    let cal = Calendar.current
    // From the 1st of this month through the furthest forecast day (14 days out, may cross into next month).
    let end = cal.date(byAdding: .day, value: 14, to: cal.startOfDay(for: now))!
    var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
    c.queryItems = [
        .init(name: "latitude", value: String(s.latitude)),
        .init(name: "longitude", value: String(s.longitude)),
        .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,wind_speed_10m_max,precipitation_sum,precipitation_probability_max"),
        .init(name: "hourly", value: "weather_code"),
        .init(name: "current", value: "temperature_2m,weather_code,wind_speed_10m"),
        .init(name: "timezone", value: "auto"),
        .init(name: "start_date", value: isoDay(m.first)),
        .init(name: "end_date", value: isoDay(end)),
    ]
    URLSession.shared.dataTask(with: c.url!) { data, _, _ in
        guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daily = j["daily"] as? [String: Any],
              let times = daily["time"] as? [String] else { completion(nil); return }
        let codes = daily["weather_code"] as? [Any] ?? []
        let hi = daily["temperature_2m_max"] as? [Any] ?? []
        let lo = daily["temperature_2m_min"] as? [Any] ?? []
        let wind = daily["wind_speed_10m_max"] as? [Any] ?? []
        let rainSum = daily["precipitation_sum"] as? [Any] ?? []
        let rainChance = daily["precipitation_probability_max"] as? [Any] ?? []

        // Daytime (7 AM–7 PM) hourly weather codes for each day.
        var daytime: [String: [Int]] = [:]
        if let hourly = j["hourly"] as? [String: Any],
           let hTimes = hourly["time"] as? [String], let hCodes = hourly["weather_code"] as? [Any] {
            for (i, t) in hTimes.enumerated() where i < hCodes.count {
                guard let code = hCodes[i] as? Double, let hour = Int(t.dropFirst(11).prefix(2)), (7..<19).contains(hour) else { continue }
                daytime[String(t.prefix(10)), default: []].append(Int(code))
            }
        }

        var days: [String: Any] = [:]
        for (i, t) in times.enumerated() {
            guard i < codes.count, let worst = codes[i] as? Double,
                  let h = hi[i] as? Double, let l = lo[i] as? Double else { continue }
            let mm = (i < rainSum.count ? rainSum[i] as? Double : nil) ?? 0
            let chance = i < rainChance.count ? rainChance[i] as? Double : nil
            let code = typicalWeather(worst: Int(worst), daytime: daytime[t] ?? [], rainMM: mm, rainChance: chance)
            days[t] = [Double(code), h, l, (i < wind.count ? wind[i] as? Double : nil) ?? 0]   // keyed "yyyy-MM-dd"
        }
        var result: [String: Any] = ["days": days]
        if let cur = j["current"] as? [String: Any], let temp = cur["temperature_2m"] as? Double,
           let code = cur["weather_code"] as? Double {
            result["current"] = ["temp": temp, "code": code, "wind": cur["wind_speed_10m"] as? Double ?? 0]
        }
        completion(result)
    }.resume()
}

/// Daily GitHub contribution counts (same numbers as the green squares on your profile).
func fetchContributions() -> [String: Int]? {
    guard let gh = findExecutable("gh") else { return nil }
    let q = "query{viewer{contributionsCollection{contributionCalendar{weeks{contributionDays{date contributionCount}}}}}}"
    guard let out = run(gh, ["api", "graphql", "-f", "query=\(q)"]),
          let j = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
          let weeks = ((((j["data"] as? [String: Any])?["viewer"] as? [String: Any])?["contributionsCollection"] as? [String: Any])?["contributionCalendar"] as? [String: Any])?["weeks"] as? [[String: Any]]
    else { return nil }
    var map: [String: Int] = [:]
    for w in weeks {
        for d in (w["contributionDays"] as? [[String: Any]]) ?? [] {
            if let date = d["date"] as? String, let n = d["contributionCount"] as? Int { map[date] = n }
        }
    }
    return map
}

func commitSummary(_ map: [String: Int], now: Date) -> [String: Any] {
    let cal = Calendar.current
    let m = monthInfo(now)
    let today = cal.startOfDay(for: now)
    let byDay = (0..<m.today).map { map[isoDay(cal.date(byAdding: .day, value: $0, to: m.first)!)] ?? 0 }
    let last7 = (1...7).reversed().map { map[isoDay(cal.date(byAdding: .day, value: -$0, to: today)!)] ?? 0 }
    // Streak: consecutive days with contributions, ending today (or yesterday if today has none yet).
    var day = today
    if (map[isoDay(day)] ?? 0) == 0 { day = cal.date(byAdding: .day, value: -1, to: day)! }
    var streak = 0
    while (map[isoDay(day)] ?? 0) > 0 {
        streak += 1
        day = cal.date(byAdding: .day, value: -1, to: day)!
    }
    return ["byDay": byDay, "last7": last7, "streak": streak]
}

// MARK: - Shiny log

let shinyLogURL = baseDir.appendingPathComponent("shinies.json")

/// Every shiny you've spotted: [{"dex": 25, "date": "2026-11-15T01:41:22Z"}, …]
func loadShinyLog() -> [[String: Any]] {
    guard let data = try? Data(contentsOf: shinyLogURL),
          let a = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return a
}

func appendShiny(_ dex: Int) -> [[String: Any]] {
    var log = loadShinyLog()
    log.append(["dex": dex, "date": ISO8601DateFormatter().string(from: Date())])
    if let data = try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted]) {
        try? data.write(to: shinyLogURL)
    }
    return log
}

// MARK: - Web view plumbing

final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class WidgetWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    var settings = Settings.load()
    var window: WidgetWindow!
    var web: WidgetWebView!
    var status: NSStatusItem!
    var shinyItem: NSMenuItem!
    let vitals = Vitals()
    var weather: [String: Any]?
    var weatherError = false
    var commits: [String: Int]?
    var ready = false
    var currentDay = isoDay(Date())
    var timers: [Timer] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildWindow()
        buildMenu()

        timers.append(Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.pushSystem() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.refreshWeather() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in self?.refreshCommits() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let d = isoDay(Date())
            if d != self.currentDay { self.currentDay = d; self.refreshAll() }
        })
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshAll()
        }
        refreshAll()
    }

    func buildWindow() {
        let size = settings.pixelSize
        window = WidgetWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        applyLevel()

        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(SchemeHandler(), forURLScheme: "pw")
        cfg.userContentController.add(self, name: "native")
        web = WidgetWebView(frame: NSRect(origin: .zero, size: size), configuration: cfg)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        window.contentView = web
        web.load(URLRequest(url: URL(string: "pw://app/widget.html")!))

        if window.setFrameUsingName("PokemonWidget") {
            // The saved frame may be from another size: keep its top-left corner, use the current size.
            let f = window.frame
            window.setFrame(NSRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height), display: false)
        } else if let screen = NSScreen.main {
            let v = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: v.maxX - size.width - 24, y: v.maxY - size.height - 24))
        }
        window.setFrameAutosaveName("PokemonWidget")
        window.orderFrontRegardless()
    }

    func applyLevel() {
        window.level = settings.keepOnDesktop
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            : .floating
    }

    // MARK: Menu bar

    func buildMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Pokémon widget")
        let menu = NSMenu()
        menu.addItem(item("Shuffle Pokémon", #selector(shuffle)))
        menu.addItem(item("Summon a shiny", #selector(summonShiny)))
        menu.addItem(item("Refresh", #selector(refreshAllAction)))
        menu.addItem(.separator())
        shinyItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        shinyItem.submenu = NSMenu()
        menu.addItem(shinyItem)
        updateShinyMenu(loadShinyLog())
        menu.addItem(.separator())
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for s in Settings.sizes {
            let mi = item(s.title, #selector(pickSize(_:)))
            mi.representedObject = s.key
            mi.state = s.key == settings.size ? .on : .off
            sizeMenu.addItem(mi)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        let desk = item("Keep on desktop", #selector(toggleDesktop))
        desk.state = settings.keepOnDesktop ? .on : .off
        menu.addItem(desk)
        let login = item("Open at login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Reset position", #selector(resetPosition)))
        menu.addItem(.separator())
        menu.addItem(item("Edit settings…", #selector(openSettings)))
        menu.addItem(item("Open sprites folder", #selector(openSprites)))
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit)))
        status.menu = menu
    }

    func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc func shuffle() { web.evaluateJavaScript("window.pw && pw.shuffle()") }
    @objc func summonShiny() { web.evaluateJavaScript("window.pw && pw.summonShiny()") }

    @objc func pickSize(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        sender.menu?.items.forEach { $0.state = ($0.representedObject as? String) == key ? .on : .off }
        settings.size = key
        settings.save()
        applySize()
    }

    func applySize() {
        let s = settings.pixelSize
        let f = window.frame
        var r = NSRect(x: f.minX, y: f.maxY - s.height, width: s.width, height: s.height)
        if let v = (window.screen ?? NSScreen.main)?.visibleFrame {   // keep it on screen
            r.origin.x = min(max(r.minX, v.minX), v.maxX - r.width)
            r.origin.y = min(max(r.minY, v.minY), v.maxY - r.height)
        }
        window.setFrame(r, display: true)
        send("pw.setSize", settings.size)
    }

    func updateShinyMenu(_ log: [[String: Any]]) {
        shinyItem.title = "Shinies spotted: \(log.count)"
        let sub = NSMenu()
        if log.isEmpty {
            let none = NSMenuItem(title: "None yet. Keep watching the route", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        } else {
            let iso = ISO8601DateFormatter()
            let f = DateFormatter()
            f.dateFormat = "d MMM, h:mm a"
            for e in log.suffix(15).reversed() {
                let dex = e["dex"] as? Int ?? 0
                let when = (e["date"] as? String).flatMap { iso.date(from: $0) }.map { f.string(from: $0) } ?? ""
                let mi = NSMenuItem(title: "✦ \(displayName(dex))  ·  \(when)", action: nil, keyEquivalent: "")
                mi.isEnabled = false
                sub.addItem(mi)
            }
            let unique = Set(log.compactMap { $0["dex"] as? Int }).count
            sub.addItem(.separator())
            let total = NSMenuItem(title: "\(unique) different Pokémon", action: nil, keyEquivalent: "")
            total.isEnabled = false
            sub.addItem(total)
        }
        shinyItem.submenu = sub
    }
    @objc func refreshAllAction() {
        settings = Settings.load()
        applyLevel()
        applySize()
        status.menu?.items.first { $0.title == "Size" }?.submenu?.items.forEach {
            $0.state = ($0.representedObject as? String) == settings.size ? .on : .off
        }
        refreshAll()
    }
    @objc func toggleDesktop(_ sender: NSMenuItem) {
        settings.keepOnDesktop.toggle()
        settings.save()
        sender.state = settings.keepOnDesktop ? .on : .off
        applyLevel()
    }
    @objc func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change Open at login"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    @objc func resetPosition() {
        guard let v = NSScreen.main?.visibleFrame else { return }
        window.setFrameOrigin(NSPoint(x: v.maxX - window.frame.width - 24, y: v.maxY - window.frame.height - 24))
    }
    @objc func openSettings() { settings.save(); NSWorkspace.shared.open(configURL) }
    @objc func openSprites() { NSWorkspace.shared.open(spritesDir) }
    @objc func quit() { NSApp.terminate(nil) }

    // MARK: Data

    func refreshAll() {
        refreshWeather()
        refreshCommits()
        pushAll()
    }

    func refreshWeather() {
        fetchWeather(settings) { [weak self] w in
            DispatchQueue.main.async {
                guard let self else { return }
                if let w { self.weather = w; self.weatherError = false } else { self.weatherError = true }
                self.pushAll()
            }
        }
    }

    func refreshCommits() {
        guard settings.useGitHub else { commits = nil; pushAll(); return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let c = fetchContributions()
            DispatchQueue.main.async {
                guard let self else { return }
                if let c { self.commits = c }
                self.pushAll()
            }
        }
    }

    func dateLine() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE d MMM"
        return f.string(from: Date()) + " · " + settings.city
    }

    /// "SUN 15 NOV"
    func dateShort() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE d MMM"
        return f.string(from: Date()).uppercased()
    }

    /// Today plus the next 6 days: [{key: "2026-11-15", letter: "S", today: true}, …]
    func upcoming() -> [[String: Any]] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let letters = ["S", "M", "T", "W", "T", "F", "S"]
        return (0..<7).map {
            let d = cal.date(byAdding: .day, value: $0, to: today)!
            return ["key": isoDay(d), "letter": letters[cal.component(.weekday, from: d) - 1], "today": $0 == 0]
        }
    }

    func pushAll() {
        guard ready else { return }
        let now = Date()
        var d: [String: Any] = [
            "name": settings.name, "dateLine": dateLine(), "accent": settings.accent, "shinyOdds": settings.shinyOdds,
            "size": settings.size, "dateShort": dateShort(), "upcoming": upcoming(),
            "month": monthInfo(now).info, "system": vitals.snapshot(), "weatherError": weatherError,
        ]
        if let weather { d["weather"] = weather }
        if let commits { d["commits"] = commitSummary(commits, now: now) }
        send("pw.update", d)
    }

    func pushSystem() {
        guard ready else { return }
        send("pw.system", vitals.snapshot())
    }

    func send(_ fn: String, _ obj: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.pw && \(fn)(\(json))")
    }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            _ = vitals.cpuPct()
            pushAll()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let w: [String: Any] = [
                    "normal": loadWalkData(spritesDir.appendingPathComponent("walk"),
                                           animDir: spritesDir.appendingPathComponent("anim")),
                    "shiny": loadWalkData(spritesDir.appendingPathComponent("shiny/walk"),
                                          animDir: spritesDir.appendingPathComponent("shiny/anim")),
                    "names": Dictionary(uniqueKeysWithValues: (1...386).map { (String($0), displayName($0)) }),
                    "evolutions": loadEvolutions(),
                ]
                DispatchQueue.main.async { self?.send("pw.setWalk", w) }
            }
        case "shiny":
            if let dex = body["dex"] as? Int { updateShinyMenu(appendShiny(dex)) }
        case "drag":
            if let e = NSApp.currentEvent, e.type == .leftMouseDown || e.type == .leftMouseDragged {
                window.performDrag(with: e)
            }
        default: break
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
