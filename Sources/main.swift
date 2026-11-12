// RapidTab — a minimal, fast Option+Tab window switcher.
//
// Design goals:
//  * Switching is the priority. The target window is focused the instant Option is released,
//    using the same private SkyLight calls as a mouse click, before anything else happens.
//  * Thumbnails are never captured on the hot path. After you leave a window, it is captured
//    in the background and cached, so the next time the switcher opens it just draws a cached image.
//  * A quick Option+Tab tap (released within ~120ms) flips to the previous window without
//    drawing any UI at all.

import AppKit
import ApplicationServices
import ScreenCaptureKit
import ServiceManagement

// MARK: - Private API, resolved at runtime (no private framework linking needed)

enum Priv {
    typealias SetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    typealias PostEventFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    typealias GetPSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    static let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    static func sym<T>(_ name: String, _ type: T.Type) -> T? {
        var p: UnsafeMutableRawPointer? = nil
        if let h = skylight { p = dlsym(h, name) }
        if p == nil { p = dlsym(rtldDefault, name) }
        guard let ptr = p else { return nil }
        return unsafeBitCast(ptr, to: type)
    }

    static let setFront = sym("_SLPSSetFrontProcessWithOptions", SetFrontFn.self)
    static let postEvent = sym("SLPSPostEventRecordTo", PostEventFn.self)
    static let axGetWindow = sym("_AXUIElementGetWindow", AXGetWindowFn.self)
    static let getPSN = sym("GetProcessForPID", GetPSNFn.self)
}

// MARK: - Window model

struct WinInfo {
    let wid: CGWindowID
    let pid: pid_t
    let title: String
    let appName: String
}

let ourPid = ProcessInfo.processInfo.processIdentifier

/// Front-to-back list of normal app windows on the current Space. Takes a few ms.
func currentWindows() -> [WinInfo] {
    let regular = Set(NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
        .map { $0.processIdentifier })
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] else { return [] }
    var out: [WinInfo] = []
    for d in list {
        guard (d[kCGWindowLayer as String] as? Int) == 0,
              let widNum = d[kCGWindowNumber as String] as? Int,
              let pidNum = d[kCGWindowOwnerPID as String] as? Int else { continue }
        let pid = pid_t(pidNum)
        guard pid != ourPid, regular.contains(pid) else { continue }
        if let alpha = d[kCGWindowAlpha as String] as? Double, alpha < 0.01 { continue }
        if let bd = d[kCGWindowBounds as String] as? NSDictionary,
           let r = CGRect(dictionaryRepresentation: bd),
           r.width < 60 || r.height < 40 { continue }
        out.append(WinInfo(wid: CGWindowID(widNum),
                           pid: pid,
                           title: d[kCGWindowName as String] as? String ?? "",
                           appName: d[kCGWindowOwnerName as String] as? String ?? ""))
    }
    return out
}

// MARK: - Focusing

let axQueue = DispatchQueue(label: "rapidtab.ax", qos: .userInteractive)

func focusWindow(_ w: WinInfo) {
    var psn = ProcessSerialNumber()
    var ok = false
    if let getPSN = Priv.getPSN, let setFront = Priv.setFront, getPSN(w.pid, &psn) == noErr {
        ok = setFront(&psn, w.wid, 0x200) == 0   // 0x200 = kCPSUserGenerated
        if ok, let post = Priv.postEvent { makeKeyWindow(&psn, w.wid, post) }
    }
    if !ok { NSRunningApplication(processIdentifier: w.pid)?.activate() }

    // Raise the specific window via Accessibility, off the main thread (can block on slow apps).
    let pid = w.pid, wid = w.wid
    axQueue.async {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let wins = value as? [AXUIElement], let getWin = Priv.axGetWindow else { return }
        for axw in wins {
            var id: CGWindowID = 0
            if getWin(axw, &id) == .success, id == wid {
                AXUIElementPerformAction(axw, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(axw, kAXMainAttribute as CFString, kCFBooleanTrue)
                break
            }
        }
    }
}

/// Makes the window key, the way a real click does. Same SkyLight event-record technique used by AltTab and yabai.
func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ wid: CGWindowID, _ post: Priv.PostEventFn) {
    var bytes = [UInt8](repeating: 0, count: 0xf8)
    bytes[0x04] = 0xf8
    bytes[0x3a] = 0x10
    var w = wid
    withUnsafeBytes(of: &w) { raw in for i in 0..<4 { bytes[0x3c + i] = raw[i] } }
    for i in 0..<0x10 { bytes[0x20 + i] = 0xff }
    var p = psn
    bytes[0x08] = 0x01
    bytes.withUnsafeMutableBufferPointer { _ = post(&p, $0.baseAddress!) }
    bytes[0x08] = 0x02
    bytes.withUnsafeMutableBufferPointer { _ = post(&p, $0.baseAddress!) }
}

// MARK: - Thumbnail cache (captured lazily, after you leave a window)

final class ThumbCache {
    static let shared = ThumbCache()
    var images: [CGWindowID: NSImage] = [:]       // main thread only
    private var lastCapture: [CGWindowID: Date] = [:]
    var icons: [pid_t: NSImage] = [:]

    func icon(for pid: pid_t) -> NSImage {
        if let i = icons[pid] { return i }
        let i = NSRunningApplication(processIdentifier: pid)?.icon ?? NSImage(named: NSImage.applicationIconName)!
        icons[pid] = i
        return i
    }

    func capture(_ wid: CGWindowID) {
        guard CGPreflightScreenCaptureAccess() else { return }
        if let t = lastCapture[wid], Date().timeIntervalSince(t) < 1.0 { return }
        lastCapture[wid] = Date()
        Task.detached(priority: .utility) {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard let w = content.windows.first(where: { $0.windowID == wid }) else { return }
                let img = try await ThumbCache.snap(w)
                await MainActor.run { ThumbCache.shared.store(img, for: wid) }
            } catch {
                // Window gone, or no permission: just keep the app icon fallback.
            }
        }
    }

    static func snap(_ w: SCWindow) async throws -> NSImage {
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let cfg = SCStreamConfiguration()
        let scale = min(1.0, 640.0 / max(w.frame.width, 1))
        cfg.width = max(1, Int(w.frame.width * scale))
        cfg.height = max(1, Int(w.frame.height * scale))
        cfg.showsCursor = false
        let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    func store(_ img: NSImage, for wid: CGWindowID) {
        if images.count > 300 { images.removeAll() }
        images[wid] = img
    }

    // MARK: Background sweep — snapshots every window, one at a time, at background priority.

    private var sweeping = false
    private var sweepTimer: Timer?

    func startBackgroundRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.sweep() }
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in self.sweep() }
        sweepTimer?.tolerance = 30   // let macOS batch it with other wakeups
    }

    func sweep() {
        guard !sweeping, CGPreflightScreenCaptureAccess() else { return }
        sweeping = true
        let targets = currentWindows().map { $0.wid }
        Task.detached(priority: .background) {
            if let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) {
                var byId: [CGWindowID: SCWindow] = [:]
                for w in content.windows { byId[w.windowID] = w }
                let alive = Set(byId.keys)
                await MainActor.run {
                    // Drop thumbnails of windows that no longer exist.
                    let cache = ThumbCache.shared
                    cache.images = cache.images.filter { alive.contains($0.key) }
                }
                for wid in targets {
                    guard let w = byId[wid] else { continue }
                    if let img = try? await ThumbCache.snap(w) {
                        await MainActor.run { ThumbCache.shared.store(img, for: wid) }
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)   // spread the work out
                }
            }
            await MainActor.run { ThumbCache.shared.sweeping = false }
        }
    }
}

// MARK: - UI

final class SwitcherView: NSView {
    var items: [WinInfo] = []
    var selected = 0
    var onClick: ((Int) -> Void)?

    let baseW: CGFloat = 220, baseH: CGFloat = 170, pad: CGFloat = 12
    private var tileW: CGFloat = 220, tileH: CGFloat = 170
    private var cols = 1

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var layoutCount = 0                       // tiles per full page (keeps size fixed across pages)
    var pageInfo: (page: Int, count: Int)?    // nil when everything fits on one page
    let footerH: CGFloat = 20

    /// Picks an even-looking grid (fewest gaps in the last row) and shrinks tiles until it fits.
    func fittingSize(maxWidth: CGFloat, maxHeight: CGFloat) -> NSSize {
        let n = max(1, layoutCount)
        let footer = pageInfo == nil ? 0 : footerH
        var scale: CGFloat = 1
        while true {
            tileW = baseW * scale; tileH = baseH * scale
            let maxCols = max(1, min(n, Int((maxWidth - pad) / (tileW + pad))))
            let minCols = min(maxCols, Int(Double(n).squareRoot().rounded(.up)))
            var best = maxCols, bestEmpty = Int.max
            for c in stride(from: maxCols, through: minCols, by: -1) {
                let empty = ((n + c - 1) / c) * c - n
                if empty < bestEmpty { best = c; bestEmpty = empty }
            }
            cols = best
            let rows = (n + cols - 1) / cols
            let size = NSSize(width: pad + CGFloat(cols) * (tileW + pad),
                              height: pad + CGFloat(rows) * (tileH + pad) + footer)
            if size.height <= maxHeight || scale < 0.35 { return size }
            scale *= 0.9
        }
    }

    func tileRect(_ i: Int) -> NSRect {
        let c = i % cols, r = i / cols
        return NSRect(x: pad + CGFloat(c) * (tileW + pad), y: pad + CGFloat(r) * (tileH + pad),
                      width: tileW, height: tileH)
    }

    override func draw(_ dirtyRect: NSRect) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: para,
        ]
        for (i, it) in items.enumerated() {
            let r = tileRect(i)
            if i == selected {
                NSColor.controlAccentColor.withAlphaComponent(0.45).setFill()
                NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
            }
            let thumbArea = NSRect(x: r.minX + 8, y: r.minY + 8, width: r.width - 16, height: r.height - 40)
            if let img = ThumbCache.shared.images[it.wid] {
                let s = img.size
                let k = min(thumbArea.width / s.width, thumbArea.height / s.height)
                let dw = s.width * k, dh = s.height * k
                let dst = NSRect(x: thumbArea.midX - dw / 2, y: thumbArea.midY - dh / 2, width: dw, height: dh)
                img.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: [.interpolation: NSImageInterpolation.medium.rawValue])
            } else {
                let sz: CGFloat = 72
                let dst = NSRect(x: thumbArea.midX - sz / 2, y: thumbArea.midY - sz / 2, width: sz, height: sz)
                ThumbCache.shared.icon(for: it.pid).draw(in: dst, from: .zero, operation: .sourceOver,
                                                         fraction: 1, respectFlipped: true, hints: nil)
            }
            let iconRect = NSRect(x: r.minX + 8, y: r.maxY - 28, width: 20, height: 20)
            ThumbCache.shared.icon(for: it.pid).draw(in: iconRect, from: .zero, operation: .sourceOver,
                                                     fraction: 1, respectFlipped: true, hints: nil)
            let label = it.title.isEmpty ? it.appName : it.title
            (label as NSString).draw(with: NSRect(x: r.minX + 34, y: r.maxY - 26, width: r.width - 42, height: 18),
                                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                     attributes: attrs)
        }
        if let pi = pageInfo {
            // Page dots along the bottom.
            let d: CGFloat = 6, gap: CGFloat = 8
            let total = CGFloat(pi.count) * d + CGFloat(pi.count - 1) * gap
            var x = bounds.midX - total / 2
            let y = bounds.maxY - pad / 2 - footerH / 2 - d / 2
            for p in 0..<pi.count {
                NSColor.white.withAlphaComponent(p == pi.page ? 0.95 : 0.3).setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: d, height: d)).fill()
                x += d + gap
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = items.indices.first(where: { tileRect($0).contains(p) }) { onClick?(i) }
    }
}

final class SwitcherPanel: NSPanel {
    let view = SwitcherView()
    private let fx = NSVisualEffectView()

    init() {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        fx.material = .hudWindow
        fx.state = .active
        fx.blendingMode = .behindWindow
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 16
        fx.layer?.masksToBounds = true
        fx.addSubview(view)
        contentView = fx
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // All windows are reachable, shown a page of `perPage` at a time.
    var perPage = 16
    private var page = 0
    private var all: [WinInfo] = []
    var offset: Int { page * perPage }
    private var pageCount: Int { max(1, (all.count + perPage - 1) / perPage) }

    private func updatePage(selected: Int) {
        page = selected / perPage
        view.items = Array(all[offset..<min(all.count, offset + perPage)])
        view.selected = selected - offset
        view.pageInfo = pageCount > 1 ? (page, pageCount) : nil
    }

    func show(_ items: [WinInfo], selected: Int) {
        all = items
        view.layoutCount = min(all.count, perPage)
        updatePage(selected: selected)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        let size = view.fittingSize(maxWidth: vf.width * 0.9, maxHeight: vf.height * 0.9)
        let frame = NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2,
                           width: size.width, height: size.height)
        setFrame(frame, display: false)
        fx.frame = NSRect(origin: .zero, size: size)
        view.frame = fx.bounds
        view.needsDisplay = true
        orderFrontRegardless()
    }

    func select(_ i: Int) {
        updatePage(selected: i)
        view.needsDisplay = true
    }
}

// MARK: - Switcher state machine + event tap

final class Switcher {
    static let shared = Switcher()

    var tap: CFMachPort?
    let panel = SwitcherPanel()
    private var active = false
    private var windows: [WinInfo] = []
    private var selected = 0
    private var showWork: DispatchWorkItem?
    private var lastFront: WinInfo?

    let showDelay: TimeInterval = 0.12
    let maxItems = 16

    init() {
        panel.view.onClick = { [weak self] i in
            guard let self, self.active else { return }
            self.selected = self.panel.offset + i
            self.commit()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Covers switches made by clicking, Cmd+Tab, etc: capture the window you just left.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.noteFrontChanged() }
        }
        lastFront = currentWindows().first
    }

    func noteFrontChanged() {
        guard let front = currentWindows().first else { return }
        if let prev = lastFront, prev.wid != front.wid { ThumbCache.shared.capture(prev.wid) }
        lastFront = front
    }

    func startTap() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, _ in Switcher.shared.handle(type, event) },
            userInfo: nil) else { return false }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        return true
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return pass
        }
        let flags = event.flags
        switch type {
        case .flagsChanged:
            if active && !flags.contains(.maskAlternate) { commit(); return pass }
            // While the switcher is open, tapping Shift (left 56 / right 60) steps backwards.
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if active && (code == 56 || code == 60) && flags.contains(.maskShift) { step(-1) }
            return pass
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let opt = flags.contains(.maskAlternate)
            let shift = flags.contains(.maskShift)
            let other = flags.contains(.maskCommand) || flags.contains(.maskControl)
            if code == 48 && opt && !other {          // Tab
                // Tab always moves forward once open; backwards is Shift on its own.
                if active { step(1) } else { begin(reverse: shift) }
                return nil
            }
            if active {
                switch code {
                case 53: cancel()                     // Esc
                case 123, 126: step(-1)               // Left / Up
                case 124, 125: step(1)                // Right / Down
                case 36, 49: commit()                 // Return / Space
                default: break
                }
                return nil
            }
            return pass
        case .keyUp:
            return active ? nil : pass
        default:
            return pass
        }
    }

    private func begin(reverse: Bool) {
        // Front-to-back order == most recently used. All are kept; the panel shows a sliding subset.
        windows = currentWindows()
        panel.perPage = maxItems
        guard !windows.isEmpty else { return }
        // If the frontmost app has no window on screen, the top window is "elsewhere" — start at it.
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let startIdx = (windows[0].pid == frontPid && windows.count > 1) ? 1 : 0
        selected = reverse ? windows.count - 1 : startIdx
        active = true
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active else { return }
            self.panel.show(self.windows, selected: self.selected)
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
    }

    private func step(_ d: Int) {
        guard !windows.isEmpty else { return }
        selected = (selected + d + windows.count) % windows.count
        if panel.isVisible { panel.select(selected) }
    }

    private func commit() {
        guard active else { return }
        active = false
        showWork?.cancel()
        let target = windows[selected]
        let left = windows[0]
        focusWindow(target)                  // 1. switch first
        panel.orderOut(nil)
        if left.wid != target.wid {          // 2. then, in the background, capture what you left
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                ThumbCache.shared.capture(left.wid)
            }
        }
        lastFront = target
    }

    private func cancel() {
        active = false
        showWork?.cancel()
        panel.orderOut(nil)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var retryTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⌥⇥"
        let menu = NSMenu()
        menu.addItem(withTitle: "RapidTab", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        loginItem = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Accessibility Settings…", action: #selector(openAX), keyEquivalent: "")
        menu.addItem(withTitle: "Open Screen Recording Settings…", action: #selector(openSR), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu

        // Turn on launch-at-login automatically the first time; the menu item can turn it off.
        let d = UserDefaults.standard
        if !d.bool(forKey: "didAutoEnableLogin") {
            try? SMAppService.mainApp.register()
            d.set(true, forKey: "didAutoEnableLogin")
        }
        refreshLoginItem()

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }

        _ = Switcher.shared
        ThumbCache.shared.startBackgroundRefresh()
        if !Switcher.shared.startTap() {
            statusItem.button?.title = "⌥⇥ ⚠︎"
            retryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
                if Switcher.shared.startTap() {
                    t.invalidate()
                    self?.statusItem.button?.title = "⌥⇥"
                }
            }
        }
    }

    var loginItem: NSMenuItem!

    func refreshLoginItem() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
        refreshLoginItem()
    }

    @objc func openAX() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func openSR() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
