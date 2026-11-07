import Cocoa
import IOKit.hid
import ServiceManagement

let razerVID = 0x1532
let minDPI = 100
let fallbackMax = 16000   // used only when the connected mouse isn't in the table below

// Max DPI per model, matched against the product name macOS reports (longest match wins).
// nil = model recognised but max not verified. Add your own mouse here if it shows "unknown".
let knownMax: [(String, Int?)] = [
    ("basilisk v3 35k", 35000),
    ("basilisk v3 pro", 30000),
    ("basilisk v3 x", 18000),
    ("basilisk v3", 26000),
    ("pro click v2", nil),
    ("pro click mini", nil),
    ("pro click", 16000)          // Pro Click V1
]

func knownMaxDPI(for name: String) -> Int? {
    let n = name.lowercased()
    let hit = knownMax.filter { n.contains($0.0) }.max(by: { $0.0.count < $1.0.count })
    return hit?.1
}

struct Preset: Codable { var name: String; var dpi: Int }
struct State: Codable {
    var presets: [Preset]
    var active: Int?              // legacy, kept so old presets.json still loads
    var activeBy: [String: Int]?  // last DPI per mouse model
    var showIcon: Bool?           // menu bar: mouse icon (default on)
    var showDPI: Bool?            // menu bar: DPI number (default on)
    var showBattery: Bool?        // menu bar: battery % (default on)
}

// Everything the app can read from the mouse
struct Info {
    var name = "Not found"
    var pid: Int?
    var transport = "—"
    var maxDPI: Int?
    var battery: Int?
    var charging: Bool?
    var dpi: Int?
    var stages: [Int] = []
    var poll: Int?
    var firmware: String?
    var serial: String?
}

// MARK: - Persistence (~/Library/Application Support/DPIBar/presets.json)
final class Store {
    let url: URL
    var state: State
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DPIBar")
        // One-time migration: copy presets from the old "RazerDPI" folder if it exists
        let old = base.appendingPathComponent("RazerDPI")
        if !FileManager.default.fileExists(atPath: dir.path),
           FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.copyItem(at: old, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("presets.json")
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(State.self, from: d) {
            state = s
        } else {
            state = State(presets: [Preset(name: "Low", dpi: 800),
                                    Preset(name: "Medium", dpi: 1600),
                                    Preset(name: "High", dpi: 3200)], active: nil)
        }
    }
    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        if let d = try? enc.encode(state) { try? d.write(to: url) }
    }
}

// MARK: - Razer HID protocol (90-byte feature reports)
var onAttach: (() -> Void)?

final class Razer {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    var txCache: UInt8?
    var unsupported = Set<String>()   // commands the mouse didn't answer (skipped until re-plug / Refresh)
    var lastCount = -1
    var lastName = ""

    init() {
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: razerVID] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, _ in onAttach?() }, nil)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func devices() -> [IOHIDDevice] {
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return Array(set)
    }

    func prop(_ dev: IOHIDDevice, _ key: String) -> Any? {
        IOHIDDeviceGetProperty(dev, key as CFString)
    }

    func packet(tx: UInt8, cls: UInt8, id: UInt8, size: UInt8, args: [UInt8]) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 90)
        p[1] = tx; p[5] = size; p[6] = cls; p[7] = id
        for (i, a) in args.enumerated() { p[8 + i] = a }
        var crc: UInt8 = 0
        for i in 2..<88 { crc ^= p[i] }
        p[88] = crc
        return p
    }

    func transact(_ dev: IOHIDDevice, _ pkt: [UInt8]) -> [UInt8]? {
        let r = pkt.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 0, $0.baseAddress!, 90)
        }
        guard r == kIOReturnSuccess else { return nil }
        // The buffer must be exactly 90 bytes (the interface's max feature report size);
        // 91 makes IOKit fail with 0xE0005000. The mouse can need a moment to answer.
        for delay in [UInt32(30_000), 120_000] {
            usleep(delay)
            var buf = [UInt8](repeating: 0, count: 90)
            var len: CFIndex = 90
            if IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 0, &buf, &len) == kIOReturnSuccess, len >= 90 {
                return buf
            }
        }
        return nil
    }

    // Only the interface with 90-byte feature reports takes Razer commands
    func controlDevices() -> [IOHIDDevice] {
        let all = devices()
        let ctl = all.filter { (prop($0, "MaxFeatureReportSize") as? Int) == 90 }
        return ctl.isEmpty ? all : ctl
    }

    func send(cls: UInt8, id: UInt8, size: UInt8, args: [UInt8]) -> [UInt8]? {
        // Once one transaction id has worked, only use that one (a failing command then fails fast)
        let txs: [UInt8] = txCache.map { [$0] } ?? [0x1F, 0xFF, 0x3F]
        for dev in controlDevices() {
            guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
            defer { IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone)) }
            for tx in txs {
                if let r = transact(dev, packet(tx: tx, cls: cls, id: id, size: size, args: args)),
                   r[0] == 0x02 {              // 0x02 = command successful
                    txCache = tx
                    return r
                }
            }
        }
        return nil
    }

    // A read command that remembers if the mouse doesn't support it
    func query(_ key: String, cls: UInt8, id: UInt8, size: UInt8, args: [UInt8] = []) -> [UInt8]? {
        if unsupported.contains(key) { return nil }
        if let r = send(cls: cls, id: id, size: size, args: args) { return r }
        unsupported.insert(key)
        return nil
    }

    // Light read of just the current DPI, cheap enough to poll every second.
    // Uses send() directly so one failed read doesn't mark "dpi" as unsupported.
    func readDPI() -> Int? {
        guard txCache != nil, !devices().isEmpty,
              let r = send(cls: 0x04, id: 0x85, size: 0x07, args: [0x00]) else { return nil }
        return Int(r[9]) << 8 | Int(r[10])
    }

    func setDPI(_ dpi: Int) -> Bool {
        let hi = UInt8(dpi >> 8), lo = UInt8(dpi & 0xFF)
        // 0x00 = don't store in onboard memory
        return send(cls: 0x04, id: 0x05, size: 0x07, args: [0x00, hi, lo, hi, lo, 0, 0]) != nil
    }

    func readInfo() -> Info {
        var i = Info()
        let devs = devices()
        if devs.count != lastCount { unsupported.removeAll(); lastCount = devs.count }
        guard !devs.isEmpty else { return i }

        // Identify the device from IOKit properties (works on any connection type)
        let main = devs.first(where: {
            (prop($0, kIOHIDPrimaryUsagePageKey) as? Int) == 1 && (prop($0, kIOHIDPrimaryUsageKey) as? Int) == 2
        }) ?? devs[0]
        i.name = (prop(main, kIOHIDProductKey) as? String) ?? "Razer device"
        i.pid = prop(main, kIOHIDProductIDKey) as? Int
        i.transport = (prop(main, kIOHIDTransportKey) as? String) ?? "—"
        i.maxDPI = knownMaxDPI(for: i.name)
        if i.name != lastName {          // a different mouse: its transaction id may differ
            txCache = nil
            unsupported.removeAll()
            lastName = i.name
        }

        // Commands (OpenRazer protocol). Each one that fails is skipped next time.
        if let r = query("dpi", cls: 0x04, id: 0x85, size: 0x07, args: [0x00]) {
            i.dpi = Int(r[9]) << 8 | Int(r[10])
        }
        if let r = query("stages", cls: 0x04, id: 0x86, size: 0x26, args: [0x00]) {
            let n = min(Int(r[9]), 5)
            for k in 0..<n {
                let b = 10 + k * 7
                if b + 2 < 90 {
                    let v = Int(r[b + 1]) << 8 | Int(r[b + 2])
                    if v > 0 { i.stages.append(v) }
                }
            }
        }
        if let r = query("bat", cls: 0x07, id: 0x80, size: 0x02) {
            i.battery = Int((Double(r[9]) / 255.0 * 100.0).rounded())
        }
        if let r = query("chg", cls: 0x07, id: 0x84, size: 0x02) {
            i.charging = (r[9] == 1)
        }
        if let r = query("poll", cls: 0x00, id: 0x85, size: 0x01) {
            switch r[8] { case 1: i.poll = 1000; case 2: i.poll = 500; case 8: i.poll = 125; default: break }
        }
        if let r = query("fw", cls: 0x00, id: 0x81, size: 0x02) {
            i.firmware = "\(r[8]).\(r[9])"
        }
        if let r = query("serial", cls: 0x00, id: 0x82, size: 0x16) {
            let bytes = r[8..<30].prefix(while: { $0 >= 0x20 && $0 < 0x7F })
            let s = String(decoding: bytes, as: UTF8.self)
            if !s.isEmpty { i.serial = s }
        }
        return i
    }

    var deviceCount: Int { devices().count }

    // Dumps every HID interface and the raw result of a "get DPI" command on each,
    // so we can see exactly where the mouse accepts or rejects it.
    func diagnostics() -> String {
        func hex(_ v: Int32) -> String { "0x" + String(UInt32(bitPattern: v), radix: 16, uppercase: true) }
        var out = "DPIBar diagnostics\n"
        let devs = devices()
        out += "HID interfaces: \(devs.count)\n"
        for (n, dev) in devs.enumerated() {
            let name = (prop(dev, kIOHIDProductKey) as? String) ?? "?"
            let pid = (prop(dev, kIOHIDProductIDKey) as? Int) ?? 0
            let page = (prop(dev, kIOHIDPrimaryUsagePageKey) as? Int) ?? -1
            let usage = (prop(dev, kIOHIDPrimaryUsageKey) as? Int) ?? -1
            let tr = (prop(dev, kIOHIDTransportKey) as? String) ?? "?"
            let feat = (prop(dev, "MaxFeatureReportSize") as? Int) ?? -1
            let o = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            out += "\n#\(n) \(name) pid=0x\(String(pid, radix: 16, uppercase: true)) transport=\(tr) usagePage=\(page) usage=\(usage) maxFeatureReport=\(feat) open=\(hex(o))\n"
            guard o == kIOReturnSuccess else { continue }
            for tx in [UInt8(0x1F), 0xFF, 0x3F] {
                let pkt = packet(tx: tx, cls: 0x04, id: 0x85, size: 0x07, args: [0x00])
                let s = pkt.withUnsafeBufferPointer {
                    IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 0, $0.baseAddress!, 90)
                }
                usleep(150_000)
                var buf = [UInt8](repeating: 0, count: 90)
                var len: CFIndex = 90
                let g = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 0, &buf, &len)
                let bytes = buf.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
                out += "  tx 0x\(String(tx, radix: 16, uppercase: true)): set=\(hex(s)) get=\(hex(g)) len=\(len) first16=[\(bytes)]\n"
            }
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        return out
    }
}

// MARK: - Menu bar app
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    let razer = Razer()
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var debounce: DispatchWorkItem?
    var info = Info()
    var head: NSMenuItem?
    var presetItems: [NSMenuItem] = []
    var readoutItems: [NSMenuItem] = []
    var timer: Timer?
    var fastTimer: Timer?
    // Menu bar icon: uses MenuIcon.png from the app's Resources if present, else the mouse symbol
    let mouseIcon: NSImage? = {
        if let url = Bundle.main.url(forResource: "MenuIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 18, height: 18)   // menu bar icon size in points
            img.isTemplate = true                      // macOS tints it for light/dark mode
            return img
        }
        return NSImage(systemSymbolName: "computermouse", accessibilityDescription: "DPI")
    }()

    // Menu bar display options (defaults = everything shown, as before)
    var showIcon: Bool { store.state.showIcon ?? true }
    var showDPI: Bool { store.state.showDPI ?? true }
    var showBattery: Bool { store.state.showBattery ?? true }

    // Per-mouse helpers: the limit and the remembered DPI follow whichever mouse is connected
    var currentMax: Int { info.maxDPI ?? fallbackMax }
    var devKey: String? { info.name == "Not found" ? nil : info.name }
    var savedActive: Int? { devKey.flatMap { store.state.activeBy?[$0] } }
    func remember(_ dpi: Int) {
        guard let k = devKey else { return }
        var m = store.state.activeBy ?? [:]
        m[k] = dpi
        store.state.activeBy = m
        store.save()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "DPI")
        }
        // macOS blocks opening keyboard/mouse HID devices without Input Monitoring; ask explicitly
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        onAttach = { [weak self] in
            guard let self = self else { return }
            self.debounce?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.razer.unsupported.removeAll()
                self.refresh()   // identify the mouse first, so its own limit and saved DPI are used
                if let dpi = self.savedActive { self.apply(dpi, silent: true) }
            }
            self.debounce = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
        }
        info = razer.readInfo()
        if let cur = info.dpi { remember(cur) }
        rebuild()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        // Fast poll so the bar follows the mouse's own DPI button
        fastTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.pollDPI() }
    }

    // Cheap DPI-only check; updates the bar only when the value actually changed
    func pollDPI() {
        guard info.dpi != nil,                    // skip if this mouse never reported a DPI (e.g. Bluetooth)
              let dpi = razer.readDPI(), dpi != info.dpi else { return }
        info.dpi = dpi
        remember(dpi)
        updateUI()
    }

    // Re-read the mouse and update labels in place (safe while the menu is open)
    func refresh(full: Bool = false, allowRebuild: Bool = true) {
        if full { razer.unsupported.removeAll() }
        let oldMax = currentMax
        info = razer.readInfo()
        if allowRebuild && currentMax != oldMax {
            rebuild()        // different mouse: rebuild so only presets it supports are listed
        } else {
            updateUI()
        }
    }

    func inputAccess() -> String {
        let s = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if s == kIOHIDAccessTypeGranted { return "granted" }
        if s == kIOHIDAccessTypeDenied { return "DENIED — see System Settings" }
        return "not asked yet"
    }

    func readoutLines() -> [String] {
        var pidText = ""
        if let p = info.pid { pidText = String(format: " (0x%04X)", p) }
        var bat = "n/a"
        if let b = info.battery { bat = "\(b)%" + (info.charging == true ? " (charging)" : "") }
        else if info.charging == true { bat = "charging" }
        var conn = info.transport
        if conn.lowercased().contains("bluetooth") { conn += " — DPI control not supported" }
        return [
            "Mouse: \(info.name)\(pidText)",
            "Connection: \(conn)",
            "Battery: \(bat)",
            "DPI: \(info.dpi.map(String.init) ?? "n/a")",
            "Max DPI: \(info.maxDPI.map(String.init) ?? "unknown (limit \(fallbackMax) used)")",
            "DPI stages: \(info.stages.isEmpty ? "n/a" : info.stages.map(String.init).joined(separator: " · "))",
            "Polling rate: \(info.poll.map { "\($0) Hz" } ?? "n/a")",
            "Firmware: \(info.firmware ?? "n/a")",
            "Serial: \(info.serial ?? "n/a")",
            "Input Monitoring: \(inputAccess())"
        ]
    }

    func updateUI() {
        let cur = info.dpi ?? savedActive
        var parts: [String] = []
        if showDPI, let c = cur { parts.append("\(c)") }
        if showBattery, let b = info.battery { parts.append("\(b)%") }
        // Never leave the bar empty: if there's no text to show, fall back to the icon
        let iconOn = showIcon || parts.isEmpty
        statusItem.button?.image = iconOn ? mouseIcon : nil
        let text = parts.joined(separator: " · ")
        statusItem.button?.title = (iconOn && !text.isEmpty) ? " " + text : text
        head?.title = cur.map { "Active: \($0) DPI" } ?? "DPI unknown"
        let lines = readoutLines()
        for (i, line) in lines.enumerated() where i < readoutItems.count { readoutItems[i].title = line }
        for it in presetItems where it.tag < store.state.presets.count {
            let p = store.state.presets[it.tag]
            it.title = "\(p.name) — \(p.dpi) DPI"
            it.state = (p.dpi == cur) ? .on : .off
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusItem.menu { refresh(allowRebuild: false) }
    }

    func rebuild() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        presetItems = []
        readoutItems = []

        let h = NSMenuItem(title: "DPI unknown", action: nil, keyEquivalent: "")
        h.isEnabled = false
        head = h
        menu.addItem(h)
        menu.addItem(.separator())

        // Presets above this mouse's maximum are not created at all
        for (i, p) in store.state.presets.enumerated() where p.dpi <= currentMax {
            let n = presetItems.count + 1
            let item = NSMenuItem(title: "\(p.name) — \(p.dpi) DPI", action: #selector(selectPreset(_:)), keyEquivalent: n <= 9 ? "\(n)" : "")
            item.target = self
            item.tag = i                      // index into store.state.presets
            presetItems.append(item)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let add = NSMenuItem(title: "Add Preset…", action: #selector(addPreset), keyEquivalent: "n")
        add.target = self
        menu.addItem(add)

        let del = NSMenuItem(title: "Delete Preset", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (i, p) in store.state.presets.enumerated() where p.dpi <= currentMax {
            let it = NSMenuItem(title: "\(p.name) (\(p.dpi))", action: #selector(deletePreset(_:)), keyEquivalent: "")
            it.target = self; it.tag = i
            sub.addItem(it)
        }
        del.submenu = sub
        menu.addItem(del)
        menu.addItem(.separator())

        // Readouts
        let title = NSMenuItem(title: "Mouse info", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        for _ in 0..<readoutLines().count {
            let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            it.isEnabled = false
            it.indentationLevel = 1
            readoutItems.append(it)
            menu.addItem(it)
        }
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshAll), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let copy = NSMenuItem(title: "Copy readout", action: #selector(copyReadout), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        let diag = NSMenuItem(title: "Run diagnostics (copies to clipboard)", action: #selector(runDiagnostics), keyEquivalent: "")
        diag.target = self
        menu.addItem(diag)
        menu.addItem(.separator())

        let disp = NSMenuItem(title: "Menu Bar Shows", action: nil, keyEquivalent: "")
        let dsub = NSMenu()
        for (tag, title, on) in [(0, "Mouse icon", showIcon), (1, "DPI", showDPI), (2, "Battery %", showBattery)] {
            let it = NSMenuItem(title: title, action: #selector(toggleDisplay(_:)), keyEquivalent: "")
            it.target = self; it.tag = tag
            it.state = on ? .on : .off
            dsub.addItem(it)
        }
        disp.submenu = dsub
        menu.addItem(disp)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        updateUI()
    }

    func apply(_ dpi: Int, silent: Bool = false) {
        if dpi > currentMax {
            if !silent {
                NSApp.activate(ignoringOtherApps: true)
                let a = NSAlert()
                a.messageText = "Above this mouse's maximum"
                a.informativeText = "\(info.name) supports up to \(currentMax) DPI."
                a.runModal()
            }
            updateUI()
            return
        }
        if razer.setDPI(dpi) {
            remember(dpi)
            info.dpi = dpi
        } else if !silent {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Couldn't change DPI"
            a.informativeText = "No Razer device accepted the command. Use a USB cable or the 2.4 GHz dongle (Bluetooth isn't supported), and allow this app under System Settings → Privacy & Security → Input Monitoring."
            a.runModal()
        }
        rebuild()
    }

    @objc func selectPreset(_ s: NSMenuItem) { apply(store.state.presets[s.tag].dpi) }

    @objc func deletePreset(_ s: NSMenuItem) {
        store.state.presets.remove(at: s.tag); store.save(); rebuild()
    }

    @objc func refreshAll() { refresh(full: true) }

    @objc func runDiagnostics() {
        let text = razer.diagnostics() + "\n" + readoutLines().joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Diagnostics copied"
        a.informativeText = "Paste it into a new issue on GitHub (⌘V)."
        a.runModal()
    }

    @objc func copyReadout() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(readoutLines().joined(separator: "\n"), forType: .string)
    }

    @objc func addPreset() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "New DPI preset"
        alert.informativeText = "DPI range for \(devKey ?? "this mouse"): \(minDPI)–\(currentMax)"
        alert.addButton(withTitle: "Save & Apply")
        alert.addButton(withTitle: "Cancel")
        let name = NSTextField(frame: NSRect(x: 0, y: 30, width: 240, height: 24))
        name.placeholderString = "Name (e.g. Gaming)"
        let dpi = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        dpi.placeholderString = "DPI (e.g. 1600)"
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 58))
        v.addSubview(name); v.addSubview(dpi)
        alert.accessoryView = v
        alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn,
              let val = Int(dpi.stringValue.trimmingCharacters(in: .whitespaces)),
              (minDPI...currentMax).contains(val) else { return }
        let n = name.stringValue.isEmpty ? "Preset \(val)" : name.stringValue
        store.state.presets.append(Preset(name: n, dpi: val))
        store.save()
        apply(val)
    }

    @objc func toggleDisplay(_ s: NSMenuItem) {
        switch s.tag {
        case 0: store.state.showIcon = !showIcon
        case 1: store.state.showDPI = !showDPI
        default: store.state.showBattery = !showBattery
        }
        if !showIcon && !showDPI && !showBattery { store.state.showIcon = true }   // keep something visible
        store.save()
        rebuild()
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("Login item error: \(error)") }
        rebuild()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
