import AppKit
import ScreenCaptureKit
import ServiceManagement

// macOS keeps full screen windows below the notch. Instead, a green-button click
// moves the window to a notch-free virtual display the size of the built-in one,
// takes it full screen there, and shows that display on the built-in panel edge
// to edge. Nothing runs until a window goes full screen.

// MARK: - Accessibility

private let systemWide = AXUIElementCreateSystemWide()

private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
}

private func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

private func frame(of element: AXUIElement) -> CGRect? {
    guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute) else { return nil }
    var rect = CGRect.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &rect.origin)
    AXValueGetValue(size as! AXValue, .cgSize, &rect.size)
    return rect
}

private func move(_ window: AXUIElement, to point: CGPoint) {
    var point = point
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &point)!)
}

private func isFullScreen(_ window: AXUIElement) -> Bool {
    value(window, "AXFullScreen") as? Bool == true
}

private func setFullScreen(_ window: AXUIElement, _ on: Bool) {
    AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, (on ? kCFBooleanTrue : kCFBooleanFalse)!)
}

private extension NSScreen {
    var displayID: CGDirectDisplayID { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0 }
    static var notched: NSScreen? { screens.first { $0.safeAreaInsets.top > 0 } }
}

private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
private func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }

private func pointer() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

private func warp(_ point: CGPoint) {
    CGWarpMouseCursorPosition(point)
    CGAssociateMouseAndMouseCursorPosition(1)
}

// MARK: - Stage

/// A notch-free virtual display, mirrored onto the built-in panel while a full screen app is in front.
@MainActor
final class Stage: NSObject, SCStreamOutput {
    let bounds: CGRect
    let panel: CGRect
    private let display: CGVirtualDisplay
    private let windows: [NSWindow]
    private let layers: [CALayer]
    private var stream: SCStream?
    private var latest: CMSampleBuffer?
    private var fence: CFMachPort?

    static func open(on screen: NSScreen) async -> Stage? {
        guard let mode = CGDisplayCopyDisplayMode(screen.displayID) else { return nil }
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = .main
        descriptor.name = "True Full Screen"
        descriptor.maxPixelsWide = UInt32(mode.pixelWidth)
        descriptor.maxPixelsHigh = UInt32(mode.pixelHeight)
        descriptor.sizeInMillimeters = CGDisplayScreenSize(screen.displayID)
        descriptor.vendorID = 0x5446
        descriptor.productID = 0x4653
        descriptor.serialNum = 1
        // Display P3, like the panel.
        descriptor.redPrimary = CGPoint(x: 0.680, y: 0.320)
        descriptor.greenPrimary = CGPoint(x: 0.265, y: 0.690)
        descriptor.bluePrimary = CGPoint(x: 0.150, y: 0.060)
        descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [CGVirtualDisplayMode(width: UInt32(mode.width), height: UInt32(mode.height), refreshRate: mode.refreshRate)]
        guard let display = CGVirtualDisplay(descriptor: descriptor), display.apply(settings) else { return nil }

        let id = display.displayID
        var target: SCDisplay?
        for _ in 0..<50 where target == nil {
            try? await Task.sleep(for: .milliseconds(20))
            guard NSScreen.screens.contains(where: { $0.displayID == id }) else { continue }
            target = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays.first { $0.displayID == id }
        }
        guard let target else { return nil }

        // Touch the other displays only at a corner, so the pointer stays on whichever side it's put.
        let others = NSScreen.screens.filter { $0.displayID != id }.reduce(CGRect.null) { $0.union(CGDisplayBounds($1.displayID)) }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayOrigin(config, id, Int32(others.maxX), Int32(others.maxY))
        CGCompleteDisplayConfiguration(config, .forSession)

        let stage = Stage(display: display, screen: screen)
        let configuration = SCStreamConfiguration()
        configuration.width = mode.pixelWidth
        configuration.height = mode.pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(mode.refreshRate, 60)))
        configuration.showsCursor = true
        configuration.queueDepth = 3
        configuration.colorSpaceName = CGColorSpace.displayP3
        let stream = SCStream(filter: SCContentFilter(display: target, excludingWindows: []), configuration: configuration, delegate: nil)
        guard (try? stream.addStreamOutput(stage, type: .screen, sampleHandlerQueue: .main)) != nil,
              (try? await stream.startCapture()) != nil else { return nil }
        stage.stream = stream
        return stage
    }

    private init(display: CGVirtualDisplay, screen: NSScreen) {
        self.display = display
        bounds = CGDisplayBounds(display.displayID)
        panel = CGDisplayBounds(screen.displayID)
        // The menu bar band sits just above the menu bar. The rest sits at the Dock's level,
        // below Notification Center, so banners still show on top, as they do over normal full screen.
        let full = screen.frame
        let band = full.maxY - screen.visibleFrame.maxY
        let parts = [(NSRect(x: full.minX, y: full.maxY - band, width: full.width, height: band), NSWindow.Level.statusBar),
                     (NSRect(x: full.minX, y: full.minY, width: full.width, height: full.height - band),
                      NSWindow.Level(Int(CGWindowLevelForKey(.dockWindow))))]
        windows = parts.map { frame, level in
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = level
            window.backgroundColor = .black
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.contentView = NSView()
            window.contentView?.wantsLayer = true
            window.setFrame(frame, display: false)
            return window
        }
        // Each window shows its slice of the whole picture.
        layers = windows.map { window in
            let layer = CALayer()
            layer.actions = ["contents": NSNull()]
            layer.frame = CGRect(x: full.minX - window.frame.minX, y: full.minY - window.frame.minY, width: full.width, height: full.height)
            window.contentView?.layer?.masksToBounds = true
            window.contentView?.layer?.addSublayer(layer)
            return layer
        }
        super.init()

        let moves: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        fence = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                  eventsOfInterest: moves.reduce(0) { $0 | 1 << $1.rawValue },
                                  callback: fenceCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let fence {
            CGEvent.tapEnable(tap: fence, enable: false)
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, fence, 0), .commonModes)
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let pixels = buffer.imageBuffer, let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue() else { return }
        MainActor.assumeIsolated {
            latest = buffer
            layers.forEach { $0.contents = surface }
        }
    }

    /// Shows the virtual display on the panel and moves the pointer over to it, or the reverse.
    func show(_ on: Bool) {
        guard on != isVisible else { return }
        let point = pointer()
        if on {
            windows.forEach { $0.orderFrontRegardless() }
            if !bounds.contains(point) {
                warp(panel.contains(point) ? point - panel.origin + bounds.origin : CGPoint(x: bounds.midX, y: bounds.midY))
            }
        } else {
            windows.forEach { $0.orderOut(nil) }
            if bounds.contains(point) { warp(point - bounds.origin + panel.origin) }
        }
        if let fence { CGEvent.tapEnable(tap: fence, enable: on) }
    }

    private var isVisible: Bool { windows[0].isVisible }

    /// Keeps the pointer on the virtual display while it's shown.
    fileprivate func keep(_ point: CGPoint) {
        guard isVisible, !bounds.contains(point) else { return }
        warp(CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1), y: min(max(point.y, bounds.minY), bounds.maxY - 1)))
    }

    /// Whether the app has a window showing on the virtual display.
    func isShowing(_ pid: pid_t) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid, info[kCGWindowLayer as String] as? Int == 0,
                  let rect = (info[kCGWindowBounds as String] as! CFDictionary?).flatMap(CGRect.init(dictionaryRepresentation:)) else { return false }
            return rect.intersects(bounds)
        }
    }

    func close() {
        show(false)
        if let fence { CFMachPortInvalidate(fence) }
        try? stream?.removeStreamOutput(self, type: .screen)
        stream?.stopCapture()
        stream = nil
        windows.forEach { $0.close() }
    }
}

private let fenceCallback: CGEventTapCallBack = { _, _, event, info in
    let stage = Unmanaged<Stage>.fromOpaque(info!).takeUnretainedValue()
    MainActor.assumeIsolated { stage.keep(event.location) }
    return Unmanaged.passUnretained(event)
}

private let clickCallback: CGEventTapCallBack = { _, type, event, info in
    let controller = Unmanaged<Controller>.fromOpaque(info!).takeUnretainedValue()
    return MainActor.assumeIsolated { controller.swallow(type, event) } ? nil : Unmanaged.passUnretained(event)
}

// MARK: - Menu bar glyph

/// A screen with a notch, solid when on.
private func glyph(on: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
        let notch = NSBezierPath(roundedRect: NSRect(x: 7, y: 11.5, width: 6, height: 4), xRadius: 1.25, yRadius: 1.25)
        if on {
            NSBezierPath(roundedRect: NSRect(x: 1, y: 2, width: 18, height: 12.5), xRadius: 2.5, yRadius: 2.5).fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            notch.fill()
        } else {
            let screen = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 2.75, width: 16.5, height: 11), xRadius: 2, yRadius: 2)
            screen.lineWidth = 1.5
            screen.stroke()
            notch.fill()
        }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "True Full Screen"
    return image
}

// MARK: - App

/// AppKit asks LaunchServices for this app's own notch setting at launch, which
/// loads ~40 MB of settings for every installed app. This app never goes full screen.
final class Application: NSApplication {
    @objc(getValue:forSafeApertureCompatibilityURLResourceKey:)
    func safeApertureValue(_ value: UnsafeMutableRawPointer?, key: AnyObject?) -> Bool { false }
}

@MainActor
final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private struct Target {
        let pid: pid_t
        let window: AXUIElement
        let home: CGPoint
        let parked: CGPoint
        var leaving = false
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let defaults = UserDefaults.standard
    private var targets: [Target] = []
    private var entering: [AXUIElement] = []
    private var ignored: [AXUIElement] = []
    private var stage: Stage?
    private var opening = false
    private var tap: CFMachPort?
    private var swallowMouseUp = false

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    private var excluded: Set<String> {
        get { Set(defaults.stringArray(forKey: "excluded") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "excluded") }
    }

    private var allowed: Bool { AXIsProcessTrusted() && CGPreflightScreenCaptureAccess() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !defaults.bool(forKey: "setUp") {
            defaults.set(true, forKey: "setUp")
            try? SMAppService.mainApp.register()
        }
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        installTap()

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.image = glyph(on: enabled)

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(self, selector: #selector(update), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(accessibilityChanged), name: NSNotification.Name("com.apple.accessibility.api"), object: nil)
    }

    /// Hands full screen windows back to the panel before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !targets.isEmpty else { return .terminateNow }
        targets.forEach { setFullScreen($0.window, false) }
        Task {
            for _ in 0..<60 where !targets.isEmpty {
                update()
                try? await Task.sleep(for: .milliseconds(50))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        item.button?.performClick(nil)
        return false
    }

    @objc private func accessibilityChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.installTap() }
    }

    private func installTap() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let clicks: [CGEventType] = [.leftMouseDown, .leftMouseUp]
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: clicks.reduce(0) { $0 | 1 << $1.rawValue },
                                callback: clickCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap { CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes) }
    }

    // MARK: Full screen

    /// Takes over green-button clicks on the notched display. Returns true to swallow the event.
    fileprivate func swallow(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseUp where swallowMouseUp:
            swallowMouseUp = false
            return true
        case .leftMouseDown:
            // Windows that can't be moved get the app's own full screen.
            guard let (window, pid) = greenButtonWindow(at: event), !ignored.contains(where: { CFEqual($0, window) }) else { return false }
            swallowMouseUp = true
            Task { await enter(window, pid: pid) }
            return true
        default:
            break
        }
        return false
    }

    private func greenButtonWindow(at event: CGEvent) -> (AXUIElement, pid_t)? {
        let point = event.location
        var hit: AXUIElement?
        var pid: pid_t = 0
        guard enabled, !event.flags.contains(.maskAlternate), let screen = NSScreen.notched,
              CGDisplayBounds(screen.displayID).contains(point),
              AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success, let hit
        else { return nil }
        let window = element(hit, kAXWindowAttribute) ?? hit
        guard let button = element(window, kAXFullScreenButtonAttribute), frame(of: button)?.contains(point) == true,
              AXUIElementGetPid(window, &pid) == .success, pid != getpid(), !isFullScreen(window),
              let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, !excluded.contains(id),
              CGPreflightScreenCaptureAccess() else { return nil }
        return (window, pid)
    }

    /// Windows already handled, on their way, or left alone because they couldn't be moved.
    private func isBusy(_ window: AXUIElement) -> Bool {
        [targets.map(\.window), entering, ignored].contains { $0.contains { CFEqual($0, window) } }
    }

    private func enter(_ window: AXUIElement, pid: pid_t) async {
        guard !isBusy(window), !isFullScreen(window), let home = frame(of: window)?.origin else { return }
        entering.append(window)
        defer { entering.removeAll { CFEqual($0, window) } }
        guard let stage = await openStage() else {
            ignored.append(window)
            return setFullScreen(window, true)
        }
        let parked = home - stage.panel.origin + stage.bounds.origin
        for _ in 0..<2 where frame(of: window).map({ !stage.bounds.contains($0.origin) }) ?? false {
            move(window, to: parked)
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard let moved = frame(of: window)?.origin, stage.bounds.contains(moved) else {
            // The app won't move, so it gets plain full screen.
            ignored.append(window)
            move(window, to: home)
            setFullScreen(window, true)
            return update()
        }
        targets.append(Target(pid: pid, window: window, home: home, parked: parked))
        setFullScreen(window, true)
        update()
    }

    private func openStage() async -> Stage? {
        while opening { try? await Task.sleep(for: .milliseconds(20)) }
        if let stage { return stage }
        guard let screen = NSScreen.notched else { return nil }
        opening = true
        stage = await Stage.open(on: screen)
        opening = false
        return stage
    }

    /// Windows that went full screen another way (keyboard, menu) are moved over too.
    private func adoptFullScreenWindow() {
        guard enabled, allowed, let screen = NSScreen.notched, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid(), let id = app.bundleIdentifier, !excluded.contains(id),
              let window = element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
              !isBusy(window), isFullScreen(window), let origin = frame(of: window)?.origin, CGDisplayBounds(screen.displayID).contains(origin)
        else { return }
        entering.append(window)
        Task {
            // Leaving is ignored while the app is still animating in, so keep asking.
            for attempt in 0..<30 where isFullScreen(window) {
                if attempt % 5 == 0 { setFullScreen(window, false) }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(300))
            entering.removeAll { CFEqual($0, window) }
            await enter(window, pid: app.processIdentifier)
        }
    }

    /// Brings a window back to the panel once it has left full screen on the virtual display.
    private func bringHome(_ target: Target) async {
        for _ in 0..<40 {
            if let origin = frame(of: target.window)?.origin, abs(origin.x - target.parked.x) < 1, abs(origin.y - target.parked.y) < 1 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        move(target.window, to: target.home)
        targets.removeAll { CFEqual($0.window, target.window) }
        update()
    }

    @objc private func update() {
        targets.removeAll { frame(of: $0.window) == nil }
        for index in targets.indices where !targets[index].leaving && !isFullScreen(targets[index].window) {
            targets[index].leaving = true
            let target = targets[index]
            Task { await bringHome(target) }
        }
        adoptFullScreenWindow()

        guard let stage, entering.isEmpty || !targets.isEmpty else { return }
        // A window moved to another display from its green button menu stays there.
        for target in targets where !target.leaving && frame(of: target.window).map({ !$0.intersects(stage.bounds) }) == true {
            ignored.append(target.window)
            targets.removeAll { CFEqual($0.window, target.window) }
        }
        if targets.isEmpty {
            stage.close()
            self.stage = nil
        } else if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            stage.show(targets.contains { $0.pid == front } && stage.isShowing(front))
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add("True Full Screen", #selector(toggleEnabled), on: enabled, to: menu)

        let apps = NSMenuItem(title: "Apps", action: nil, keyEquivalent: "")
        apps.submenu = appsMenu()
        apps.isEnabled = enabled
        menu.addItem(apps)

        if !AXIsProcessTrusted() { add("Allow Accessibility…", #selector(openAccessibility), on: false, to: menu) }
        if !CGPreflightScreenCaptureAccess() { add("Allow Screen Recording…", #selector(openScreenRecording), on: false, to: menu) }

        menu.addItem(.separator())
        add("Launch at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled, to: menu)
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate), keyEquivalent: "q")
    }

    private func appsMenu() -> NSMenu {
        var names: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier else { continue }
            names[id] = app.localizedName ?? id
        }
        for id in excluded where names[id] == nil {
            names[id] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) } ?? id
        }

        let menu = NSMenu()
        for (id, name) in names.sorted(by: { $0.value.localizedStandardCompare($1.value) == .orderedAscending }) {
            add(name, #selector(toggleApp), on: !excluded.contains(id), to: menu).representedObject = id
        }
        return menu
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, on: Bool, to menu: NSMenu) -> NSMenuItem {
        let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.state = on ? .on : .off
        return entry
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        item.button?.image = glyph(on: enabled)
        if !enabled { targets.forEach { setFullScreen($0.window, false) } }
    }

    @objc private func toggleApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if excluded.contains(id) { excluded.remove(id) } else { excluded.insert(id) }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        if service.status == .enabled { try? service.unregister() } else { try? service.register() }
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openScreenRecording() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}

MainActor.assumeIsolated {
    let application = Application.shared
    let controller = Controller()
    application.delegate = controller
    application.run()
}
