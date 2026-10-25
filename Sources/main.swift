import AppKit
import ScreenCaptureKit
import ServiceManagement

// macOS keeps full screen windows below the notch. A green-button click instead moves the
// window to a notch-free virtual display the size of the built-in one and takes it full
// screen there. On the panel, a full screen window of this app's own stands in for it, in a
// Space of its own like any full screen window, and shows that display edge to edge.
// Nothing runs until a window goes full screen.

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

private func windows(of pid: pid_t) -> [AXUIElement] {
    value(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
}

private func isStandardWindow(_ window: AXUIElement) -> Bool {
    value(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
}

private func isFullScreen(_ window: AXUIElement) -> Bool {
    value(window, "AXFullScreen") as? Bool == true
}

private func setFullScreen(_ window: AXUIElement, _ on: Bool) {
    AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, (on ? kCFBooleanTrue : kCFBooleanFalse)!)
}

@_silgen_name("_AXUIElementGetWindow")
private func axWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

private func windowID(of window: AXUIElement) -> CGWindowID {
    var id: CGWindowID = 0
    return axWindowID(window, &id) == .success ? id : 0
}

/// Hands a window the keyboard, along with its app.
private func focus(_ window: AXUIElement, pid: pid_t) {
    NSRunningApplication(processIdentifier: pid)?.activate()
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
}

private func isFocused(_ window: AXUIElement, pid: pid_t) -> Bool {
    element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute).map { CFEqual($0, window) } ?? false
}

/// Moves a window and makes sure it stays there, since a window still animating can snap back.
private func place(_ window: AXUIElement, at point: CGPoint) async {
    for _ in 0..<25 {
        move(window, to: point)
        try? await Task.sleep(for: .milliseconds(40))
        if let origin = frame(of: window)?.origin, abs(origin.x - point.x) < 2, abs(origin.y - point.y) < 2 { return }
    }
}

/// Leaves full screen, asking again if the window is still animating in, then waits out the animation.
private func leaveFullScreen(_ window: AXUIElement) async {
    for attempt in 0..<30 where isFullScreen(window) {
        if attempt % 5 == 0 { setFullScreen(window, false) }
        try? await Task.sleep(for: .milliseconds(100))
    }
    try? await Task.sleep(for: .milliseconds(600))
}

// MARK: - Geometry

private extension NSScreen {
    var displayID: CGDirectDisplayID { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0 }
    static var notched: NSScreen? { screens.first { $0.safeAreaInsets.top > 0 } }
}

private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
private func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }

/// A rect in global display coordinates (top-left origin) in AppKit's (bottom-left origin).
private func appKit(_ rect: CGRect) -> NSRect {
    NSRect(x: rect.minX, y: (NSScreen.screens.first?.frame.height ?? 0) - rect.maxY, width: rect.width, height: rect.height)
}

private func pointer() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

private func warp(_ point: CGPoint) {
    CGWarpMouseCursorPosition(point)
    CGAssociateMouseAndMouseCursorPosition(1)
}

/// Windows of every app that sit within `bounds`, by owner.
private func windowOwners(in bounds: CGRect) -> Set<pid_t> {
    let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return Set(windows.compactMap { info in
        guard info[kCGWindowLayer as String] as? Int == 0, let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let rect = (info[kCGWindowBounds as String] as! CFDictionary?).flatMap(CGRect.init(dictionaryRepresentation:)),
              rect.intersects(bounds) else { return nil }
        return pid
    })
}

// MARK: - Spaces

private let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
private let connection = dlsym(skyLight, "SLSMainConnectionID").map { unsafeBitCast($0, to: (@convention(c) () -> Int32).self)() } ?? 0
private let copySpacesForWindows = dlsym(skyLight, "SLSCopySpacesForWindows")
    .map { unsafeBitCast($0, to: (@convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?).self) }
private let copyManagedDisplaySpaces = dlsym(skyLight, "SLSCopyManagedDisplaySpaces")
    .map { unsafeBitCast($0, to: (@convention(c) (Int32) -> Unmanaged<CFArray>?).self) }

/// The Spaces any of the windows are on.
private func spaces(of windows: [CGWindowID]) -> Set<Int> {
    Set(copySpacesForWindows?(connection, 7, windows as CFArray)?.takeRetainedValue() as? [Int] ?? [])
}

/// The Spaces of a display.
private func spaces(on display: CGDirectDisplayID) -> Set<Int> {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
          let id = CFUUIDCreateString(nil, uuid) as String?,
          let displays = copyManagedDisplaySpaces?(connection)?.takeRetainedValue() as? [[String: Any]],
          let match = displays.first(where: { $0["Display Identifier"] as? String == id }) else { return [] }
    return Set((match["Spaces"] as? [[String: Any]] ?? []).compactMap { $0["ManagedSpaceID"] as? Int })
}

/// Whether Mission Control is up: its bar of Spaces, which comes first, or the shield behind it.
private func missionControlIsOpen() -> Bool {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.contains { ["Spaces Bar", "ExposeShieldWindow"].contains($0[kCGWindowName as String] as? String ?? "") }
}

private typealias CreateImage = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?

/// The older way to picture a window: gone from the SDK, but a third of the time of
/// ScreenCaptureKit's, which counts right after a click.
private let createImage = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage").map { unsafeBitCast($0, to: CreateImage.self) }

/// A window on its own, as a picture.
private func picture(of id: CGWindowID) async -> CGImage? {
    guard id != 0 else { return nil }
    // Just this window, without its shadow, at full resolution.
    if let image = createImage?(.null, CGWindowListOption.optionIncludingWindow.rawValue, id,
                                CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue)?.takeRetainedValue() {
        return image
    }
    guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
          let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
    let scale = NSScreen.notched?.backingScaleFactor ?? 2
    let configuration = SCStreamConfiguration()
    configuration.width = Int(window.frame.width * scale)
    configuration.height = Int(window.frame.height * scale)
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true
    configuration.colorSpaceName = CGColorSpace.displayP3
    return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                       configuration: configuration)
}

// MARK: - Stand-in

/// A window that stays exactly where it's put, menu bar or not.
final class PinnedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private let quiet: [String: CAAction] = ["contents": NSNull(), "opacity": NSNull(), "bounds": NSNull(),
                                         "position": NSNull(), "frame": NSNull()]

/// This app's own full screen window on the panel, standing in for a window on the stage. It gets
/// a Space of its own like any full screen window, so Spaces, swipes and Mission Control treat it as
/// one, and shows the stage edge to edge. On the way in and out it shows a still of the window
/// instead, growing out of and shrinking back to where the window sits.
@MainActor
final class StandIn: NSObject, NSWindowDelegate {
    let window: PinnedWindow
    private let full: NSRect
    private var home: NSRect
    private let still = CALayer()
    private let live = CALayer()
    /// Over the strip beside the notch, should macOS keep even this window below it.
    private var band: PinnedWindow?
    private let bandLive = CALayer()
    /// The frame on show, kept so the stream can't reuse it while it's still up.
    private var frame: CMSampleBuffer?
    private(set) var isLive = false
    private var transition: CheckedContinuation<Bool, Never>?

    init(screen: NSScreen, over rect: CGRect, image: CGImage?, title: String) {
        full = screen.frame
        home = appKit(rect)
        window = PinnedWindow(contentRect: home, styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.collectionBehavior = [.fullScreenPrimary]
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.backgroundColor = .black
        window.delegate = self
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = .black
        view.layer?.masksToBounds = true
        window.contentView = view
        for layer in [live, still] {
            layer.actions = quiet
            layer.frame = view.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            view.layer?.addSublayer(layer)
        }
        live.contentsGravity = .resize
        live.opacity = 0
        still.contentsGravity = .resizeAspect
        still.contents = image
        window.setFrame(home, display: false)
        // Right over the window it stands in for.
        window.orderFrontRegardless()
    }

    var isFullScreen: Bool { window.styleMask.contains(.fullScreen) }

    /// Whether the panel is showing its Space.
    var isCurrent: Bool { isFullScreen && window.isOnActiveSpace }

    /// Takes it full screen, growing out of the window it covers. Returns whether it got there.
    func enter() async -> Bool {
        await withCheckedContinuation { done in
            transition = done
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finish(false) }
        }
    }

    /// Shrinks it back out of full screen to where its window goes.
    func leave(to rect: CGRect) async -> Bool {
        home = appKit(rect)
        isLive = false
        guard isFullScreen else { return true }
        return await withCheckedContinuation { done in
            transition = done
            window.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finish(false) }
        }
    }

    /// Brings its Space up on the panel. Only the older call does that from behind another app.
    func reveal() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func finish(_ done: Bool) {
        transition?.resume(returning: done)
        transition = nil
    }

    func setLive(_ buffer: CMSampleBuffer) {
        guard isLive, let pixels = buffer.imageBuffer, let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue() else { return }
        frame = buffer
        live.contents = surface
        bandLive.contents = surface
    }

    /// Fades in the window's own picture, as it is out of full screen, for the end of the way out.
    func land(_ image: CGImage) {
        still.contents = image
        still.contentsGravity = .resize
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        still.opacity = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        still.add(fade, forKey: "opacity")
        CATransaction.commit()
    }

    /// Keeps the last frame, while the stage shows something that isn't the window.
    func hold() { isLive = false }

    /// Shows the window's own picture instead, in case the last frame caught something else.
    func cover(_ image: CGImage) {
        guard !isLive else { return }
        still.contents = image
        still.contentsGravity = .resize
        still.opacity = 1
    }

    /// Follows the stage again, cross-fading from the still the first time.
    func goLive() {
        guard !isLive else { return }
        isLive = true
        guard still.opacity > 0 else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setCompletionBlock { [still] in still.contents = nil }
        live.opacity = 1
        still.opacity = 0
        for (layer, from, to) in [(live, 0, 1), (still, 1, 0)] {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = to
            layer.add(fade, forKey: "opacity")
        }
        CATransaction.commit()
    }

    func close() {
        isLive = false
        finish(false)
        band?.orderOut(nil)
        window.orderOut(nil)
        window.close()
        for layer in [still, live, bandLive] { layer.contents = nil }
        frame = nil
    }

    // MARK: Full screen

    func window(_ window: NSWindow, willUseFullScreenContentSize proposedSize: NSSize) -> NSSize { full.size }

    func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? { [window] }

    func window(_ window: NSWindow, startCustomAnimationToEnterFullScreenOn screen: NSScreen, withDuration duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.1, 1)
            window.animator().setFrame(full, display: true)
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        if window.frame != full { window.setFrame(full, display: true) }
        if window.frame.maxY < full.maxY - 1 { addBand() }
        finish(true)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) { finish(false) }

    func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? { [window] }

    func window(_ window: NSWindow, startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval) {
        if let band {
            band.orderOut(nil)
            live.frame = window.contentView?.bounds ?? live.frame
            live.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.1, 1)
            window.animator().setFrame(home, display: true)
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) { finish(true) }

    func windowDidFailToExitFullScreen(_ window: NSWindow) { finish(false) }

    /// Covers the strip beside the notch with the top of the picture, the window the rest.
    private func addBand() {
        let rect = NSRect(x: full.minX, y: window.frame.maxY, width: full.width, height: full.maxY - window.frame.maxY)
        let band = PinnedWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        band.backgroundColor = .black
        band.hasShadow = false
        band.ignoresMouseEvents = true
        band.isReleasedWhenClosed = false
        band.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        band.contentView = NSView()
        band.contentView?.wantsLayer = true
        band.contentView?.layer?.masksToBounds = true
        bandLive.actions = quiet
        bandLive.contentsGravity = .resize
        bandLive.frame = CGRect(x: 0, y: full.minY - rect.minY, width: full.width, height: full.height)
        band.contentView?.layer?.addSublayer(bandLive)
        window.addChildWindow(band, ordered: .above)
        band.setFrame(rect, display: false)
        live.autoresizingMask = []
        live.frame = CGRect(x: 0, y: full.minY - window.frame.minY, width: full.width, height: full.height)
        self.band = band
    }
}

// MARK: - Stage

/// Private event fields: what kind of gesture an event is part of, and how far along it is.
private let gestureKind = CGEventField(rawValue: 110)!
private let gesturePhase = CGEventField(rawValue: 132)!
private let dockSwipe: Int64 = 23

/// A notch-free virtual display the size of the built-in one, and its live picture.
@MainActor
final class Stage: NSObject, SCStreamOutput {
    let bounds: CGRect
    let panel: CGRect
    let panelID: CGDirectDisplayID
    let id: CGDirectDisplayID
    var onFrame: ((CMSampleBuffer) -> Void)?
    /// A system swipe (Spaces, Mission Control) starting or ending.
    var onSwipe: ((Bool) -> Void)?
    private var display: CGVirtualDisplay?
    private var stream: SCStream?
    private var latest: CMSampleBuffer?
    private var lastFrame = Date.distantPast
    private var fence: CFMachPort?
    private var swipes: CFMachPort?
    /// Whether the pointer belongs on the stage (true) or must stay off it (false).
    private var confined = false
    private var swiping = false
    private var lastSwipe = Date.distantPast
    private var quietUntil = Date.distantPast
    private let others: [CGRect]

    static func open(on screen: NSScreen, serial: UInt32) async -> Stage? {
        guard let mode = CGDisplayCopyDisplayMode(screen.displayID) else { return nil }
        let (width, height, pixelWidth, pixelHeight, refreshRate) = (mode.width, mode.height, mode.pixelWidth, mode.pixelHeight, mode.refreshRate)
        let size = CGDisplayScreenSize(screen.displayID)
        // Created off the main thread, which it would otherwise hold up, and every click with it.
        let queue = DispatchQueue(label: "TrueFullScreen.display")
        let made: CGVirtualDisplay? = await withCheckedContinuation { done in
            queue.async {
                let descriptor = CGVirtualDisplayDescriptor()
                descriptor.queue = queue
                descriptor.name = "True Full Screen"
                descriptor.maxPixelsWide = UInt32(pixelWidth)
                descriptor.maxPixelsHigh = UInt32(pixelHeight)
                descriptor.sizeInMillimeters = size
                descriptor.vendorID = 0x5446
                descriptor.productID = 0x4653
                descriptor.serialNum = serial
                // Display P3, like the panel.
                descriptor.redPrimary = CGPoint(x: 0.680, y: 0.320)
                descriptor.greenPrimary = CGPoint(x: 0.265, y: 0.690)
                descriptor.bluePrimary = CGPoint(x: 0.150, y: 0.060)
                descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
                let settings = CGVirtualDisplaySettings()
                settings.hiDPI = 1
                settings.modes = [CGVirtualDisplayMode(width: UInt32(width), height: UInt32(height),
                                                       refreshRate: refreshRate, transferFunction: 0)]
                let display = CGVirtualDisplay(descriptor: descriptor)
                done.resume(returning: display?.apply(settings) == true ? display : nil)
            }
        }
        guard let display = made else { return nil }

        let id = display.displayID
        var target: SCDisplay?
        for _ in 0..<100 where target == nil {
            if NSScreen.screens.contains(where: { $0.displayID == id }) {
                target = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays.first { $0.displayID == id }
            }
            if target == nil { try? await Task.sleep(for: .milliseconds(10)) }
        }
        guard let target else { return nil }

        // Touch the other displays only at a corner, so the pointer stays on whichever side it's put.
        let others = NSScreen.screens.filter { $0.displayID != id }.reduce(CGRect.null) { $0.union(CGDisplayBounds($1.displayID)) }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayOrigin(config, id, Int32(others.maxX), Int32(others.maxY))
        CGCompleteDisplayConfiguration(config, .forSession)

        let stage = Stage(display: display, panel: screen.displayID)
        let configuration = SCStreamConfiguration()
        configuration.width = mode.pixelWidth
        configuration.height = mode.pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(mode.refreshRate, 60)))
        configuration.showsCursor = true
        configuration.queueDepth = 3
        configuration.colorSpaceName = CGColorSpace.displayP3
        let stream = SCStream(filter: SCContentFilter(display: target, excludingWindows: []), configuration: configuration, delegate: nil)
        guard (try? stream.addStreamOutput(stage, type: .screen, sampleHandlerQueue: .main)) != nil,
              (try? await stream.startCapture()) != nil else {
            stage.close()
            return nil
        }
        stage.stream = stream
        // macOS marks every display while it's being captured. The panel shows its own mark, so
        // leave the stage's out of the picture rather than show two.
        let bounds = stage.bounds
        Task { [weak stage] in
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let stream = stage?.stream else { return }
                let windows = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).windows
                let marks = windows?.filter { $0.title == "StatusIndicator" && $0.frame.intersects(bounds) } ?? []
                guard !marks.isEmpty else { continue }
                try? await stream.updateContentFilter(SCContentFilter(display: target, excludingWindows: marks))
                return
            }
        }
        return stage
    }

    private init(display: CGVirtualDisplay, panel: CGDirectDisplayID) {
        self.display = display
        panelID = panel
        self.panel = CGDisplayBounds(panel)
        id = display.displayID
        bounds = CGDisplayBounds(display.displayID)
        others = NSScreen.screens.map { CGDisplayBounds($0.displayID) }.filter { $0 != CGDisplayBounds(display.displayID) }
        super.init()
        let moves: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        fence = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                  eventsOfInterest: moves.reduce(0) { $0 | 1 << $1.rawValue },
                                  callback: fenceCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        // Gesture events, among them the system's swipes.
        swipes = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                   eventsOfInterest: 1 << 29 | 1 << 30 | 1 << 31,
                                   callback: swipeCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        for tap in [fence, swipes].compactMap({ $0 }) {
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.imageBuffer != nil else { return }
        MainActor.assumeIsolated {
            latest = buffer
            lastFrame = Date()
            onFrame?(buffer)
        }
    }

    /// Waits for whatever is animating on the display to finish.
    func settle(atLeast: Duration, atMost: Duration) async {
        let start = ContinuousClock.now
        try? await Task.sleep(for: atLeast)
        while ContinuousClock.now - start < atMost, Date().timeIntervalSince(lastFrame) < 0.08 {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Moves the pointer onto the display and keeps it there, or back to the same spot on the panel.
    func hold(pointer on: Bool) {
        confined = on
        let point = pointer()
        if on, !bounds.contains(point) {
            move(to: panel.contains(point) ? point - panel.origin + bounds.origin : CGPoint(x: bounds.midX, y: bounds.midY))
        } else if !on, bounds.contains(point) {
            move(to: point - bounds.origin + panel.origin)
        }
    }

    private func move(to point: CGPoint) {
        warp(point)
        // Events from before the move still carry the old spot.
        quietUntil = Date().addingTimeInterval(0.08)
    }

    /// The stage touches the other displays at a corner, which the pointer could slip through:
    /// keep it on the stage while it's in front, and off it otherwise.
    fileprivate func keep(_ point: CGPoint) {
        guard Date() >= quietUntil else { return }
        if confined, !bounds.contains(point) {
            move(to: clamp(point, into: bounds))
        } else if !confined, bounds.contains(point) {
            let display = others.min { distance(point, to: $0) < distance(point, to: $1) } ?? panel
            move(to: clamp(point, into: display))
        }
    }

    /// The system's swipes go to the display under the pointer, which is this one while it's in
    /// front. Point them at the panel instead, so its Spaces move as they would anyway.
    fileprivate func route(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let swipes { CGEvent.tapEnable(tap: swipes, enable: true) }
            return
        }
        guard event.getIntegerValueField(gestureKind) == dockSwipe else { return }
        if !swiping, confined {
            swiping = true
            hold(pointer: false)
            onSwipe?(true)
            watchSwipe()
        }
        guard swiping else { return }
        lastSwipe = Date()
        if bounds.contains(event.location) { event.location = event.location - bounds.origin + panel.origin }
        // Ended, or cancelled.
        if event.getIntegerValueField(gesturePhase) & (4 | 8) != 0 { endSwipe() }
    }

    /// Ends a swipe whose end never came through.
    private func watchSwipe() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, swiping else { return }
            if Date().timeIntervalSince(lastSwipe) > 1 { endSwipe() } else { watchSwipe() }
        }
    }

    private func endSwipe() {
        guard swiping else { return }
        swiping = false
        onSwipe?(false)
    }

    private func clamp(_ point: CGPoint, into rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX - 1), y: min(max(point.y, rect.minY), rect.maxY - 1))
    }

    private func distance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let near = clamp(point, into: rect)
        return hypot(point.x - near.x, point.y - near.y)
    }

    /// Whether an app window still belongs to one of the display's Spaces, even one already moved
    /// off it: macOS moves a window's Space over a moment after the window itself.
    var holdsWindows: Bool {
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = windows.compactMap { info -> CGWindowID? in
            guard info[kCGWindowLayer as String] as? Int == 0, let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular else { return nil }
            return info[kCGWindowNumber as String] as? CGWindowID
        }
        return !spaces(of: ids).isDisjoint(with: spaces(on: id))
    }

    /// Whether a window is showing on the display.
    func isShowing(_ window: CGWindowID) -> Bool {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, window) as? [[String: Any]])?.first,
              info[kCGWindowIsOnscreen as String] as? Bool == true,
              let rect = (info[kCGWindowBounds as String] as! CFDictionary?).flatMap(CGRect.init(dictionaryRepresentation:)) else { return false }
        return rect.intersects(bounds)
    }

    func close() {
        hold(pointer: false)
        for tap in [fence, swipes].compactMap({ $0 }) { CFMachPortInvalidate(tap) }
        fence = nil
        swipes = nil
        onFrame = nil
        onSwipe = nil
        try? stream?.removeStreamOutput(self, type: .screen)
        stream?.stopCapture()
        stream = nil
        latest = nil
        // The display goes away with its last reference, whatever still holds on to the stage.
        display = nil
    }
}

private let fenceCallback: CGEventTapCallBack = { _, _, event, info in
    let stage = Unmanaged<Stage>.fromOpaque(info!).takeUnretainedValue()
    MainActor.assumeIsolated { stage.keep(event.location) }
    return Unmanaged.passUnretained(event)
}

private let swipeCallback: CGEventTapCallBack = { _, type, event, info in
    let stage = Unmanaged<Stage>.fromOpaque(info!).takeUnretainedValue()
    MainActor.assumeIsolated { stage.route(type, event) }
    return Unmanaged.passUnretained(event)
}

private let clickCallback: CGEventTapCallBack = { _, type, event, info in
    let controller = Unmanaged<Controller>.fromOpaque(info!).takeUnretainedValue()
    return MainActor.assumeIsolated { controller.swallow(type, event) } ? nil : Unmanaged.passUnretained(event)
}

/// WindowServer events for windows appearing and disappearing, Mission Control's among them.
private let windowEvents: [UInt32] = [1325, 1326, 1508]

private typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void

private let windowServerEvent: NotifyProc = { _, _, _, info in
    guard let info else { return }
    let controller = Unmanaged<Controller>.fromOpaque(info).takeUnretainedValue()
    DispatchQueue.main.async { MainActor.assumeIsolated { controller.windowsChanged() } }
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

/// AppKit asks LaunchServices for this app's own notch setting at launch, which loads ~40 MB of
/// settings for every installed app. The answer is always no: its full screen windows fill the panel.
final class Application: NSApplication {
    @objc(getValue:forSafeApertureCompatibilityURLResourceKey:)
    func safeApertureValue(_ value: UnsafeMutableRawPointer?, key: AnyObject?) -> Bool { false }
}

@MainActor
final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private struct Target {
        let pid: pid_t
        let app: String?
        let window: AXUIElement
        let id: CGWindowID
        let home: CGRect
        let standIn: StandIn
        var leaving = false
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let defaults = UserDefaults.standard
    private var targets: [Target] = []
    private var entering: [AXUIElement] = []
    private var ignored: [AXUIElement] = []
    private var stage: Stage?
    private var opening = false
    private var closing = false
    private var tap: CFMachPort?
    private var swallowMouseUp = false
    private var missionControl = false
    private var swiping = false
    private var checking = false
    private var missionControlTimer: Timer?
    /// Where windows were when their app quit in full screen, by bundle ID, to put them back on relaunch.
    private var homes: [String: CGRect] = [:]
    private var termination: DispatchSourceSignal?

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    private var excluded: Set<String> {
        get { Set(defaults.stringArray(forKey: "excluded") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "excluded") }
    }

    /// Which virtual display to make. A new one whenever the last didn't go away cleanly, so
    /// macOS never has windows or Spaces of an old one to put back on it.
    private var serial: UInt32 { UInt32(2 + defaults.integer(forKey: "retired")) }

    private func retireDisplay() {
        defaults.set(defaults.integer(forKey: "retired") + 1, forKey: "retired")
    }

    private var allowed: Bool { AXIsProcessTrusted() && CGPreflightScreenCaptureAccess() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            return NSApp.terminate(nil)
        }
        if defaults.bool(forKey: "staged") {
            retireDisplay()
            defaults.set(false, forKey: "staged")
        }
        rescueWindows()
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

        // A plain kill quits properly too, so full screen windows get handed back.
        signal(SIGTERM, SIG_IGN)
        termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        // Not from inside this main-queue block, which quitting needs free to hand windows back.
        termination?.setEventHandler { NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0) }
        termination?.resume()

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.image = glyph(on: enabled)

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(self, selector: #selector(update), name: name, object: nil)
        }
        workspace.addObserver(self, selector: #selector(activated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(launched), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(accessibilityChanged), name: NSNotification.Name("com.apple.accessibility.api"), object: nil)

        // Mission Control isn't announced anywhere public; its windows coming and going give it away.
        if let register = dlsym(skyLight, "SLSRegisterConnectionNotifyProc") {
            typealias Register = @convention(c) (Int32, NotifyProc, UInt32, UnsafeMutableRawPointer?) -> Int32
            let register = unsafeBitCast(register, to: Register.self)
            for event in windowEvents {
                _ = register(connection, windowServerEvent, event, Unmanaged.passUnretained(self).toOpaque())
            }
        }
    }

    /// Windows of regular apps left beyond every display, where a stage was when this app last
    /// stopped without cleaning up, go back to the same spot on the panel.
    private func rescueWindows() {
        guard AXIsProcessTrusted(), let screen = NSScreen.notched else { return }
        let panel = CGDisplayBounds(screen.displayID)
        let all = NSScreen.screens.reduce(CGRect.null) { $0.union(CGDisplayBounds($1.displayID)) }
        let lost = CGRect(x: all.maxX, y: all.maxY, width: panel.width, height: panel.height)
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            for window in windows(of: app.processIdentifier) {
                guard isStandardWindow(window),
                      let rect = frame(of: window), lost.contains(rect.origin), !rect.intersects(all) else { continue }
                move(window, to: rect.origin - lost.origin + panel.origin)
            }
        }
    }

    /// Hands full screen windows back to the panel before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard stage != nil else { return .terminateNow }
        targets.forEach { setFullScreen($0.window, false) }
        Task {
            for _ in 0..<100 where stage != nil {
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

    @objc private func screensChanged() {
        // The panel went away (lid closed). With nothing left to show the stage on, macOS would move
        // every window and Space onto it, so take it down at once.
        guard let stage, CGDisplayIsOnline(stage.panelID) == 0 || CGDisplayBounds(stage.panelID) != stage.panel else { return }
        for target in targets {
            setFullScreen(target.window, false)
            target.standIn.close()
        }
        targets.removeAll()
        stage.close()
        if self.stage === stage { self.stage = nil }
        retireDisplay()
        defaults.set(false, forKey: "staged")
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
            Task { await takeOver(window, pid: pid) }
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

    /// Moves a window to the stage and takes it full screen there, while its stand-in grows out of
    /// it into a full screen Space on the panel, so nothing blinks or jumps along the way.
    private func takeOver(_ window: AXUIElement, pid: pid_t) async {
        guard !isBusy(window), let screen = NSScreen.notched else { return }
        entering.append(window)
        defer { entering.removeAll { CFEqual($0, window) } }
        let app = NSRunningApplication(processIdentifier: pid)
        // Already in the app's own full screen (keyboard, menu): come out of it first.
        if isFullScreen(window) { await leaveFullScreen(window) }
        if let id = app?.bundleIdentifier, let home = homes.removeValue(forKey: id) { await place(window, at: home.origin) }
        guard let home = frame(of: window) else { return }
        let id = windowID(of: window)
        let standIn = StandIn(screen: screen, over: home, image: await picture(of: id), title: app?.localizedName ?? "")
        // The way in plays first, since a display coming online meanwhile would stall it. The
        // window stays behind, on the Space it slides away with.
        guard await standIn.enter(), let stage = await openStage(on: screen) else {
            standIn.close()
            return giveUp(window)
        }
        await place(window, at: home.origin - stage.panel.origin + stage.bounds.origin)
        guard let moved = frame(of: window)?.origin, stage.bounds.contains(moved) else {
            move(window, to: home.origin)
            standIn.close()
            return giveUp(window)
        }
        targets.append(Target(pid: pid, app: app?.bundleIdentifier, window: window, id: id, home: home, standIn: standIn))
        setFullScreen(window, true)
        // Its way into full screen there plays out of sight.
        await stage.settle(atLeast: .milliseconds(450), atMost: .milliseconds(700))
        entering.removeAll { CFEqual($0, window) }
        if standIn.isCurrent { focus(window, pid: pid) }
        update()
    }

    /// The app won't move, so it gets plain full screen.
    private func giveUp(_ window: AXUIElement) {
        ignored.append(window)
        setFullScreen(window, true)
        entering.removeAll { CFEqual($0, window) }
        update()
    }

    private func openStage(on screen: NSScreen) async -> Stage? {
        while opening || closing { try? await Task.sleep(for: .milliseconds(10)) }
        if let stage { return stage }
        opening = true
        defer { opening = false }
        guard let made = await Stage.open(on: screen, serial: serial) else { return nil }
        made.onFrame = { [weak self] buffer in self?.targets.forEach { $0.standIn.setLive(buffer) } }
        made.onSwipe = { [weak self] on in self?.swiped(on) }
        defaults.set(true, forKey: "staged")
        stage = made
        return made
    }

    /// Windows that went full screen another way (keyboard, menu, relaunch) are moved over too,
    /// once their own animation is done.
    private func adoptFullScreenWindow() {
        guard enabled, allowed, let screen = NSScreen.notched, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid(), let id = app.bundleIdentifier, !excluded.contains(id),
              let window = element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
              !isBusy(window), isFullScreen(window), let origin = frame(of: window)?.origin, CGDisplayBounds(screen.displayID).contains(origin)
        else { return }
        entering.append(window)
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            entering.removeAll { CFEqual($0, window) }
            await takeOver(window, pid: app.processIdentifier)
        }
    }

    /// Brings a window back to the panel once it has left full screen on the stage. Its stand-in
    /// shrinks back to where the window goes meanwhile, ending on a picture of it.
    private func bringHome(_ target: Target) async {
        target.standIn.hold()
        stage?.hold(pointer: false)
        async let left = target.standIn.leave(to: target.home)
        for _ in 0..<30 {
            if let size = frame(of: target.window)?.size, abs(size.width - target.home.width) < 2,
               abs(size.height - target.home.height) < 2 { break }
            try? await Task.sleep(for: .milliseconds(30))
        }
        if let image = await picture(of: target.id) { target.standIn.land(image) }
        _ = await left
        await place(target.window, at: target.home.origin)
        if let stage {
            for _ in 0..<50 where !spaces(of: [target.id]).isDisjoint(with: spaces(on: stage.id)) {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        // On no Space at all, it couldn't be seen or reached: a trip to the Dock puts it on the current one.
        if spaces(of: [target.id]).isEmpty {
            AXUIElementSetAttributeValue(target.window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            try? await Task.sleep(for: .milliseconds(300))
            AXUIElementSetAttributeValue(target.window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        focus(target.window, pid: target.pid)
        target.standIn.close()
        targets.removeAll { CFEqual($0.window, target.window) }
        update()
    }

    /// Moves windows that ended up on the stage without going full screen back to the panel.
    /// Returns whether any were found.
    @discardableResult
    private func sweep(_ stage: Stage) -> Bool {
        var found = false
        // Only ordinary app windows that are mostly on the stage: other apps keep helper windows
        // out of sight beyond the displays on purpose.
        for pid in windowOwners(in: stage.bounds) where NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular {
            for window in windows(of: pid) where isStandardWindow(window) {
                guard !isBusy(window), let rect = frame(of: window), stage.bounds.contains(CGPoint(x: rect.midX, y: rect.midY)) else { continue }
                found = true
                if isFullScreen(window) {
                    setFullScreen(window, false)
                } else {
                    move(window, to: rect.origin - stage.bounds.origin + stage.panel.origin)
                }
            }
        }
        return found
    }

    /// Takes the stage down, once nothing is left on it: a window on a display that disappears
    /// can end up nowhere.
    private func close(_ stage: Stage) {
        guard !closing else { return }
        closing = true
        stage.hold(pointer: false)
        Task {
            var tries = 0
            while tries < 25, sweep(stage) || stage.holdsWindows {
                tries += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
            stage.close()
            let id = stage.id
            if self.stage === stage { self.stage = nil }
            defaults.set(false, forKey: "staged")
            // Wait for it to be gone, so a new one never overlaps it.
            for _ in 0..<40 where CGDisplayIsOnline(id) != 0 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            closing = false
        }
    }

    @objc private func launched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let id = app.bundleIdentifier, let home = homes[id] else { return }
        // A window that was full screen when its app quit comes back where it was.
        Task {
            for _ in 0..<20 where homes[id] != nil {
                try? await Task.sleep(for: .milliseconds(250))
                for window in windows(of: app.processIdentifier) {
                    guard !isBusy(window), !isFullScreen(window), let rect = frame(of: window),
                          abs(rect.width - home.width) < 2, abs(rect.height - home.height) < 2 else { continue }
                    if rect.origin != home.origin { move(window, to: home.origin) }
                    homes[id] = nil
                }
            }
            homes[id] = nil
        }
    }

    @objc private func activated(_ notification: Notification) {
        // Switched to from elsewhere (⌘Tab, the Dock): its Space comes up, as any full screen app's does.
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           !missionControl, !swiping,
           let target = targets.first(where: { $0.pid == app.processIdentifier && !$0.leaving && isFocused($0.window, pid: $0.pid) }),
           !target.standIn.isCurrent {
            target.standIn.reveal()
        }
        update()
    }

    @objc private func update() {
        for target in targets where frame(of: target.window) == nil {
            // Closed, or its app quit: its Space goes with it.
            if NSRunningApplication(processIdentifier: target.pid) == nil, let app = target.app { homes[app] = target.home }
            target.standIn.close()
        }
        targets.removeAll { frame(of: $0.window) == nil }
        for index in targets.indices where !targets[index].leaving && !isFullScreen(targets[index].window) {
            targets[index].leaving = true
            let target = targets[index]
            Task { await bringHome(target) }
        }
        adoptFullScreenWindow()

        guard let stage, entering.isEmpty, !closing else { return }
        // A window moved to another display from its green button menu stays there.
        for target in targets where !target.leaving && frame(of: target.window).map({ !$0.intersects(stage.bounds) }) == true {
            ignored.append(target.window)
            target.standIn.close()
            targets.removeAll { CFEqual($0.window, target.window) }
        }
        sweep(stage)
        if targets.isEmpty { return close(stage) }

        // The stage is shown only while it shows the window: a Space change or Mission Control
        // there is never seen.
        var live: Target?
        if !missionControl, !swiping, let current = targets.first(where: { !$0.leaving && $0.standIn.isCurrent }) {
            // Its Space coming up hands the keyboard to this app: pass it on.
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() || !stage.isShowing(current.id) {
                focus(current.window, pid: current.pid)
            }
            if stage.isShowing(current.id) { live = current }
        }
        for target in targets {
            if let live, CFEqual(live.window, target.window) { target.standIn.goLive() } else { target.standIn.hold() }
        }
        stage.hold(pointer: live != nil)
    }

    private func swiped(_ on: Bool) {
        swiping = on
        if on {
            targets.forEach { $0.standIn.hold() }
        } else {
            // Once the Space it led to has come up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.update() }
        }
    }

    // MARK: Mission Control

    /// Mission Control shows the panel's Spaces, the stand-ins' among them, so let the pointer
    /// go there and keep the stage's own Mission Control out of the picture.
    fileprivate func windowsChanged() {
        guard !checking, !missionControl, !closing, targets.contains(where: \.standIn.isLive) else { return }
        // One look per burst of window changes.
        checking = true
        DispatchQueue.main.async { [self] in
            checking = false
            guard !missionControl, missionControlIsOpen() else { return }
            missionControlOpened()
        }
    }

    private func missionControlOpened() {
        missionControl = true
        for target in targets where target.standIn.isLive {
            target.standIn.hold()
            Task { if let image = await picture(of: target.id) { target.standIn.cover(image) } }
        }
        stage?.hold(pointer: false)
        missionControlTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMissionControl() }
        }
    }

    private func checkMissionControl() {
        guard !missionControlIsOpen() else { return }
        missionControl = false
        missionControlTimer?.invalidate()
        missionControlTimer = nil
        update()
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
