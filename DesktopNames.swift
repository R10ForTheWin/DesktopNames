// DesktopNames — give your macOS desktops (Spaces) real names.
// Shows the current desktop's name in the menu bar, and paints name labels
// over the "Desktop N" titles in Mission Control (no SIP changes needed).

import Cocoa
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Private SkyLight calls (read-only; safe with SIP on)

@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray

struct Space {
    let key: String        // stable key used to store the name
    let number: Int        // "Desktop N" number on its display
    let isCurrent: Bool
}

struct DisplaySpaces {
    let displayID: String  // display UUID, or "Main"
    let spaces: [Space]
}

func logLine(_ s: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DesktopNames.log")
    let line = "\(Date()) \(s)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

func readSpaces() -> [DisplaySpaces] {
    guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] else { return [] }
    var result: [DisplaySpaces] = []
    for (di, d) in displays.enumerated() {
        let displayID = d["Display Identifier"] as? String ?? "display\(di)"
        let current = (d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
        var spaces: [Space] = []
        var n = 0
        for s in d["Spaces"] as? [[String: Any]] ?? [] {
            guard (s["type"] as? Int ?? 0) == 0 else { continue } // skip full-screen apps
            n += 1
            let sid = s["ManagedSpaceID"] as? Int ?? -1
            var uuid = s["uuid"] as? String ?? ""
            if uuid.isEmpty { uuid = "first-desktop-\(displayID)" } // the original desktop has no uuid
            spaces.append(Space(key: uuid, number: n, isCurrent: sid == current))
        }
        result.append(DisplaySpaces(displayID: displayID, spaces: spaces))
    }
    return result
}

// MARK: - Name storage

enum Names {
    static let defaultsKey = "spaceNames"
    static func get(_ key: String) -> String? {
        let n = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String])?[key]
        return (n?.isEmpty ?? true) ? nil : n
    }
    static func set(_ key: String, _ name: String?) {
        var all = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        all[key] = name
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }
}

/// Optional background image per desktop, shown behind its name in Mission Control.
enum LabelImages {
    static let defaultsKey = "spaceImages"
    static var cache: [String: NSImage] = [:]
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DesktopNames/Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func get(_ key: String) -> NSImage? {
        if let i = cache[key] { return i }
        guard let file = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String])?[key],
              let img = NSImage(contentsOf: dir.appendingPathComponent(file)) else { return nil }
        cache[key] = img
        return img
    }
    /// Copies a small version of the image into Application Support so the original can move.
    static func set(_ key: String, from url: URL?) {
        var all = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        cache[key] = nil
        guard let url, let src = NSImage(contentsOf: url) else {
            all[key] = nil; UserDefaults.standard.set(all, forKey: defaultsKey); return
        }
        let w: CGFloat = 800, h = w * src.size.height / max(src.size.width, 1)
        let small = NSImage(size: NSSize(width: w, height: h))
        small.lockFocus(); src.draw(in: NSRect(x: 0, y: 0, width: w, height: h)); small.unlockFocus()
        guard let tiff = small.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }
        let file = "\(key).jpg"
        try? data.write(to: dir.appendingPathComponent(file))
        all[key] = file
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }
}

// MARK: - Accessibility helpers

func ax(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func axChildren(_ e: AXUIElement) -> [AXUIElement] { ax(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func axString(_ e: AXUIElement, _ a: String) -> String { ax(e, a) as? String ?? "" }
func axFrame(_ e: AXUIElement) -> CGRect? {
    guard let p = ax(e, kAXPositionAttribute), let s = ax(e, kAXSizeAttribute) else { return nil }
    var pos = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pos)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: pos, size: size)
}

func dumpTree(_ e: AXUIElement, _ depth: Int = 0, into out: inout String, maxDepth: Int = 9) {
    guard depth <= maxDepth else { return }
    let f = axFrame(e).map { "\($0)" } ?? ""
    out += String(repeating: "  ", count: depth)
        + "\(axString(e, kAXRoleAttribute)) id=\(axString(e, kAXIdentifierAttribute)) title=\(axString(e, kAXTitleAttribute)) desc=\(axString(e, kAXDescriptionAttribute)) \(f)\n"
    for c in axChildren(e) { dumpTree(c, depth + 1, into: &out, maxDepth: maxDepth) }
}

/// A "Desktop N" label currently visible in Mission Control.
struct MCLabel {
    let number: Int
    let frame: CGRect      // AX coordinates (top-left origin)
    let selected: Bool
}

final class MissionControlReader {
    private var dockApp: AXUIElement?
    private var dumpedOnce = false
    private var loggedKids = false
    private var loggedLabels = false
    private var treeDumps = 0
    var openedAt: Date?

    private func dock() -> AXUIElement? {
        if let d = dockApp { return d }
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else { return nil }
        dockApp = AXUIElementCreateApplication(pid)
        return dockApp
    }

    /// Returns nil when Mission Control is closed; otherwise label groups per display (keyed by display frame).
    func read() -> [(displayFrame: CGRect?, labels: [MCLabel])]? {
        guard let dock = dock() else { return nil }
        let kids = axChildren(dock)
        if kids.isEmpty { dockApp = nil; return nil } // Dock may have restarted
        // Mission Control shows up as an extra Dock child (id "mc" on older macOS).
        let extra = kids.filter { axString($0, kAXRoleAttribute) != (kAXListRole as String) }
        if !extra.isEmpty && !loggedKids {
            loggedKids = true
            var s = ""; for k in kids { dumpTree(k, 0, into: &s, maxDepth: 1) }
            logLine("Dock children while something extra is open:\n\(s)")
        }
        guard let mc = kids.first(where: { axString($0, kAXIdentifierAttribute) == "mc" }) ?? extra.first else { return nil }

        var groups: [(CGRect?, [MCLabel])] = []
        var anyFound = false
        func walk(_ e: AXUIElement, displayFrame: CGRect?) {
            var df = displayFrame
            if axString(e, kAXIdentifierAttribute) == "mc.display" { df = axFrame(e) }
            if axString(e, kAXIdentifierAttribute) == "mc.spaces.list" {
                var labels: [MCLabel] = []
                for b in axChildren(e) {
                    let text = [axString(b, kAXTitleAttribute), axString(b, kAXDescriptionAttribute)]
                        .first(where: { !$0.isEmpty }) ?? ""
                    guard let num = desktopNumber(text), let f = axFrame(b) else { continue }
                    let sel = (ax(b, kAXSelectedAttribute) as? Bool) ?? false
                    var fr = f
                    // macOS 26 reports the collapsed bar's labels above the screen (y < 0)
                    // while drawing them ~37pt down; pull them back onto the visible bar.
                    let top = df?.minY ?? 0
                    if fr.minY < top { fr.origin.y = top + 37 }
                    labels.append(MCLabel(number: num, frame: fr, selected: sel))
                }
                if !labels.isEmpty { anyFound = true; groups.append((df, labels)) }
                return
            }
            for c in axChildren(e) { walk(c, displayFrame: df) }
        }
        walk(mc, displayFrame: nil)

        if openedAt == nil { openedAt = Date() }
        if treeDumps < 3, Date().timeIntervalSince(openedAt!) > 1.2 {
            treeDumps += 1; openedAt = .distantFuture
            var s = ""; dumpTree(mc, into: &s)
            logLine("Mission Control tree:\n\(s)")
        }

        if !anyFound && !dumpedOnce {
            dumpedOnce = true
            var s = ""; dumpTree(mc, into: &s)
            logLine("Mission Control open but no desktop labels found. Tree:\n\(s)")
        }
        if anyFound && !loggedLabels {
            loggedLabels = true
            logLine("Found labels: " + groups.map { g in g.1.map { "#\($0.number)@\($0.frame)\($0.selected ? "*" : "")" }.joined(separator: " ") }.joined(separator: " | "))
        }
        return groups
    }

    private func desktopNumber(_ text: String) -> Int? {
        // "Desktop 5" (English) — also accept any "<word> <number>" for other languages.
        let parts = text.split(separator: " ")
        guard parts.count >= 2, let n = Int(parts.last!) else { return nil }
        return n
    }
}

// MARK: - Overlay labels

final class LabelWindow: NSPanel {
    let field = NSTextField(labelWithString: "")
    let bg = NSVisualEffectView()
    let imageLayer = CALayer()
    let dimLayer = CALayer()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 8
        bg.layer?.masksToBounds = true
        bg.appearance = NSAppearance(named: .darkAqua)
        contentView = bg

        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        dimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        bg.layer?.insertSublayer(imageLayer, at: 0)
        bg.layer?.insertSublayer(dimLayer, above: imageLayer)

        field.alignment = .center
        field.textColor = .white
        field.lineBreakMode = .byTruncatingTail
        bg.addSubview(field)
    }

    func show(text: String, image: NSImage?, axFrame: CGRect, selected: Bool) {
        // AX uses top-left origin on the primary screen; Cocoa uses bottom-left.
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let fontSize = max(11, min(18, axFrame.height * 0.55))
        field.font = .systemFont(ofSize: fontSize, weight: selected ? .semibold : .medium)
        field.stringValue = text
        let textW = field.intrinsicContentSize.width + 24
        let w = max(axFrame.width, textW)
        let h = max(axFrame.height, fontSize + 10)
        let x = axFrame.midX - w / 2
        let y = primaryH - axFrame.midY - h / 2
        setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        imageLayer.frame = bounds; dimLayer.frame = bounds
        if let image {
            imageLayer.contents = image
            imageLayer.isHidden = false; dimLayer.isHidden = false
            bg.layer?.backgroundColor = NSColor.clear.cgColor
            bg.layer?.borderWidth = selected ? 2 : 0
            bg.layer?.borderColor = NSColor.white.cgColor
        } else {
            imageLayer.isHidden = true; dimLayer.isHidden = true
            bg.layer?.borderWidth = 0
            bg.layer?.backgroundColor = (selected ? NSColor.controlAccentColor.withAlphaComponent(0.85)
                                                  : NSColor.black.withAlphaComponent(0.35)).cgColor
        }
        CATransaction.commit()
        field.shadow = { let sh = NSShadow(); sh.shadowColor = .black.withAlphaComponent(0.6); sh.shadowBlurRadius = 2; sh.shadowOffset = .zero; return sh }()
        let fh = field.intrinsicContentSize.height
        field.frame = NSRect(x: 6, y: (h - fh) / 2, width: w - 12, height: fh)
        orderFrontRegardless()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let reader = MissionControlReader()
    var labelWindows: [LabelWindow] = []
    var timer: Timer?
    var mcOpen = false

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem.autosaveName = "DesktopNamesStatusItem"
        statusItem.behavior = []
        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu
        updateTitle()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            logLine("Waiting for Accessibility permission")
        }
        scheduleTick(interval: 0.25)
    }

    func scheduleTick(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = interval * 0.2
    }

    @objc func spaceChanged() { updateTitle() }

    /// Opening the app again (Finder, Spotlight, Launchpad) pops the menu at the mouse,
    /// so it's reachable even when the menu bar item is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMenuAtMouse(); return false
    }

    func showMenuAtMouse() {
        guard let menu = statusItem.menu else { return }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
    }

    func currentSpace() -> Space? {
        let all = readSpaces()
        // Prefer the display under the mouse / main screen; fall back to the first.
        let mainID = NSScreen.main.flatMap { displayUUID(for: $0) }
        let d = all.first(where: { $0.displayID == mainID }) ?? all.first
        return d?.spaces.first(where: { $0.isCurrent })
    }

    func updateTitle() {
        guard let s = currentSpace() else { statusItem.button?.title = "•"; return }
        // Keep the menu bar item compact so it isn't pushed behind the notch.
        let full = Names.get(s.key)
        var text = full ?? "\(s.number)"
        let maxChars = 10
        if text.count > maxChars { text = String(text.prefix(maxChars - 1)).trimmingCharacters(in: .whitespaces) + "…" }
        statusItem.button?.attributedTitle = NSAttributedString(
            string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
        statusItem.button?.toolTip = full.map { "Desktop \(s.number): \($0)" } ?? "Desktop \(s.number)"
    }

    func displayUUID(for screen: NSScreen) -> String? {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(num.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Find the spaces list for the display that contains an AX-coordinate rect.
    func spacesFor(axRect: CGRect?, all: [DisplaySpaces]) -> [Space] {
        if all.count == 1 { return all[0].spaces }
        if let r = axRect {
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            let p = NSPoint(x: r.midX, y: primaryH - r.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }),
               let id = displayUUID(for: screen),
               let d = all.first(where: { $0.displayID == id }) { return d.spaces }
        }
        return all.first?.spaces ?? []
    }

    var lastTrusted: Bool?

    func tick() {
        let trusted = AXIsProcessTrusted()
        if trusted != lastTrusted { lastTrusted = trusted; logLine("Accessibility trusted: \(trusted)") }
        guard trusted, let groups = reader.read() else {
            if mcOpen { mcOpen = false; reader.openedAt = nil; hideLabels(); scheduleTick(interval: 0.25); updateTitle() }
            return
        }
        if !mcOpen { mcOpen = true; scheduleTick(interval: 1.0 / 30.0) } // follow animations smoothly
        let all = readSpaces()
        var i = 0
        for g in groups {
            let spaces = spacesFor(axRect: g.displayFrame ?? g.labels.first?.frame, all: all)
            for label in g.labels {
                guard label.number - 1 < spaces.count else { continue }
                let key = spaces[label.number - 1].key
                let name = Names.get(key), image = LabelImages.get(key)
                guard name != nil || image != nil else { continue }
                if i >= labelWindows.count { labelWindows.append(LabelWindow()) }
                labelWindows[i].show(text: name ?? "Desktop \(label.number)", image: image,
                                     axFrame: label.frame, selected: label.selected)
                i += 1
            }
        }
        for w in labelWindows[i...] { w.orderOut(nil) }
    }

    func hideLabels() { labelWindows.forEach { $0.orderOut(nil) } }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let all = readSpaces()
        for (di, d) in all.enumerated() {
            if all.count > 1 { menu.addItem(.sectionHeader(title: "Display \(di + 1)")) }
            for s in d.spaces {
                let name = Names.get(s.key)
                let title = name.map { "\(s.number)  \($0)" } ?? "\(s.number)  Desktop \(s.number)"
                let item = NSMenuItem(title: title, action: #selector(renameItem(_:)), keyEquivalent: "")
                item.representedObject = s.key
                item.toolTip = "Click to rename"
                item.state = s.isCurrent ? .on : .off
                item.target = self
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let rc = NSMenuItem(title: "Rename Current Desktop…", action: #selector(renameCurrent), keyEquivalent: "r")
        rc.target = self; menu.addItem(rc)
        let si = NSMenuItem(title: "Set Label Image for Current Desktop…", action: #selector(setImageCurrent), keyEquivalent: "")
        si.target = self; menu.addItem(si)
        if let s = currentSpace(), LabelImages.get(s.key) != nil {
            let ri = NSMenuItem(title: "Remove Label Image for Current Desktop", action: #selector(removeImageCurrent), keyEquivalent: "")
            ri.target = self; menu.addItem(ri)
        }
        menu.addItem(.separator())
        if !AXIsProcessTrusted() {
            let ax = NSMenuItem(title: "⚠︎ Grant Accessibility Permission…", action: #selector(openAXSettings), keyEquivalent: "")
            ax.target = self; menu.addItem(ax)
        }
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let log = NSMenuItem(title: "Show Log", action: #selector(showLog), keyEquivalent: "")
        log.target = self; menu.addItem(log)
        menu.addItem(NSMenuItem(title: "Quit DesktopNames", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func renameItem(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        rename(key: key, label: sender.title)
    }

    @objc func renameCurrent() {
        guard let s = currentSpace() else { return }
        rename(key: s.key, label: "Desktop \(s.number)")
    }

    func rename(key: String, label: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Name this desktop"
        alert.informativeText = "Leave empty to go back to the default number."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = Names.get(key) ?? ""
        input.placeholderString = "e.g. Email, Work, Music"
        alert.accessoryView = input
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        if alert.runModal() == .alertFirstButtonReturn {
            let v = input.stringValue.trimmingCharacters(in: .whitespaces)
            Names.set(key, v.isEmpty ? nil : v)
            updateTitle()
        }
    }

    @objc func setImageCurrent() {
        guard let s = currentSpace() else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a background image for this desktop's label in Mission Control"
        if panel.runModal() == .OK, let url = panel.url { LabelImages.set(s.key, from: url) }
    }

    @objc func removeImageCurrent() {
        guard let s = currentSpace() else { return }
        LabelImages.set(s.key, from: nil)
    }

    @objc func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { logLine("Login item error: \(error)") }
    }

    @objc func showLog() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DesktopNames.log")
        if !FileManager.default.fileExists(atPath: url.path) { logLine("Log created") }
        NSWorkspace.shared.open(url)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
