import AppKit
import ScreenCaptureKit
import ServiceManagement
import UniformTypeIdentifiers

// macOS keeps full screen windows below the notch. A green-button click instead moves
// the window to a notch-free virtual display the size of the built-in one, takes it
// full screen there, and shows that display on the built-in panel edge to edge.
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

/// Moves a window and makes sure it stays there, since a window still animating can snap back.
private func place(_ window: AXUIElement, at point: CGPoint) async {
    var settled = 0
    for _ in 0..<30 where settled < 2 {
        if let origin = frame(of: window)?.origin, abs(origin.x - point.x) < 2, abs(origin.y - point.y) < 2 {
            settled += 1
        } else {
            settled = 0
            move(window, to: point)
        }
        try? await Task.sleep(for: .milliseconds(80))
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

private func missionControlIsOpen() -> Bool {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.contains { $0[kCGWindowName as String] as? String == "ExposeShieldWindow" }
}

// MARK: - Overlay

/// A window that stays exactly where it's put, menu bar or not, even when displays come and go.
final class PinnedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Two windows over the built-in panel: a band over the menu bar, and the rest below it at the
/// Dock's level, so Notification Center banners still show on top as they do over full screen.
/// Each holds a still picture (for transitions), a zooming window picture, and the live picture.
@MainActor
final class Overlay {
    let panel: CGRect
    let frame: NSRect
    private let windows: [NSWindow]
    private let frames: [NSRect]
    private var stills: [CALayer] = []
    private var zooms: [CALayer] = []
    private var lives: [CALayer] = []
    private(set) var isShown = false
    private var holding = false

    init(screen: NSScreen) {
        panel = CGDisplayBounds(screen.displayID)
        frame = screen.frame
        let full = screen.frame
        let band = full.maxY - screen.visibleFrame.maxY
        let parts = [(NSRect(x: full.minX, y: full.maxY - band, width: full.width, height: band), NSWindow.Level.statusBar),
                     (NSRect(x: full.minX, y: full.minY, width: full.width, height: full.height - band),
                      NSWindow.Level(Int(CGWindowLevelForKey(.dockWindow))))]
        frames = parts.map(\.0)
        windows = parts.map { rect, level in
            let window = PinnedWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = level
            window.backgroundColor = .black
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.contentView = NSView()
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.masksToBounds = true
            window.setFrame(rect, display: false)
            return window
        }
        let quiet: [String: CAAction] = ["contents": NSNull(), "opacity": NSNull(), "bounds": NSNull(),
                                         "position": NSNull(), "contentsRect": NSNull()]
        for window in windows {
            // Each window shows its slice of one full-screen picture.
            let container = CALayer()
            container.actions = quiet
            container.frame = CGRect(x: full.minX - window.frame.minX, y: full.minY - window.frame.minY, width: full.width, height: full.height)
            container.backgroundColor = .black
            for list in [\Overlay.stills, \Overlay.zooms, \Overlay.lives] {
                let layer = CALayer()
                layer.actions = quiet
                layer.frame = container.bounds
                layer.contentsGravity = .resize
                container.addSublayer(layer)
                self[keyPath: list].append(layer)
            }
            window.contentView?.layer?.addSublayer(container)
        }
    }

    /// A rect in global display coordinates, as a rect in the picture.
    private func picture(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - panel.minX, y: panel.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Puts the windows back exactly over the panel.
    func repin() {
        zip(windows, frames).forEach { $0.setFrame($1, display: false) }
    }

    private func order(_ alpha: CGFloat) {
        // A zero-length animation also cancels a fade still running.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            windows.forEach { $0.animator().alphaValue = alpha }
        }
        repin()
        windows.forEach { $0.orderFrontRegardless() }
        isShown = true
    }

    /// Covers the panel with a picture of itself, so nothing changes on screen.
    func freeze(_ image: CGImage) {
        holding = false
        CATransaction.begin()
        for layer in stills { layer.contents = image; layer.opacity = 1 }
        for layer in zooms { layer.opacity = 0 }
        for layer in lives { layer.opacity = 0 }
        CATransaction.commit()
        order(1)
    }

    /// Grows the window's picture to fill the screen while everything around it fades to black.
    func zoom(from rect: CGRect, image: CGImage) {
        let start = picture(rect)
        let full = CGRect(origin: .zero, size: panel.size)
        let crop = CGRect(x: start.minX / full.width, y: start.minY / full.height,
                          width: start.width / full.width, height: start.height / full.height)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.3, 0, 0.1, 1))
        for (zoom, still) in zip(zooms, stills) {
            zoom.contents = image
            zoom.contentsRect = crop
            zoom.opacity = 1
            zoom.frame = full
            for (key, from, to) in [("bounds", NSValue(rect: CGRect(origin: .zero, size: start.size)), NSValue(rect: CGRect(origin: .zero, size: full.size))),
                                    ("position", NSValue(point: CGPoint(x: start.midX, y: start.midY)), NSValue(point: CGPoint(x: full.midX, y: full.midY)))] {
                let animation = CABasicAnimation(keyPath: key)
                animation.fromValue = from
                animation.toValue = to
                zoom.add(animation, forKey: key)
            }
            still.opacity = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            still.add(fade, forKey: "opacity")
        }
        CATransaction.commit()
    }

    func setLive(_ surface: IOSurface) {
        guard !holding else { return }
        for layer in lives { layer.contents = surface }
    }

    /// Stops following the live picture, keeping the last frame.
    func hold() { holding = true }

    /// Cross-fades from the transition pictures to the live one.
    func goLive() {
        holding = false
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setCompletionBlock { [stills, zooms] in
            for layer in stills + zooms { layer.contents = nil; layer.opacity = 0 }
        }
        for layer in lives {
            layer.opacity = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            layer.add(fade, forKey: "opacity")
        }
        CATransaction.commit()
    }

    func fadeIn() {
        guard !isShown || windows[0].alphaValue < 1 else { return }
        holding = false
        CATransaction.begin()
        for layer in lives { layer.opacity = 1 }
        for layer in stills + zooms { layer.opacity = 0 }
        CATransaction.commit()
        if !isShown { order(0) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            windows.forEach { $0.animator().alphaValue = 1 }
        }
    }

    func fadeOut() {
        guard isShown else { return }
        isShown = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            windows.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Shown again meanwhile.
                guard let self, !self.isShown else { return }
                self.windows.forEach { $0.orderOut(nil) }
                for layer in self.stills + self.zooms { layer.contents = nil; layer.opacity = 0 }
                self.lives.forEach { $0.opacity = 1 }
            }
        })
    }

    func hideNow() {
        isShown = false
        windows.forEach { $0.orderOut(nil) }
    }

    /// Lets go of every picture once there's nothing left to show.
    func clear() {
        guard !isShown else { return }
        for layer in stills + zooms + lives { layer.contents = nil }
    }
}

// MARK: - Stage

/// A notch-free virtual display the size of the built-in one, and its live picture.
@MainActor
final class Stage: NSObject, SCStreamOutput {
    let bounds: CGRect
    let panel: CGRect
    let id: CGDirectDisplayID
    private var display: CGVirtualDisplay?
    private weak var overlay: Overlay?
    private var stream: SCStream?
    private var latest: CMSampleBuffer?
    private var lastFrame = Date.distantPast
    private var fence: CFMachPort?
    private var backdrop: NSWindow?
    private var wallpapers = 0
    private var confined = false

    static func open(on screen: NSScreen, overlay: Overlay) async -> Stage? {
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
                descriptor.serialNum = 1
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
            if let twin = NSScreen.screens.first(where: { $0.displayID == id }) {
                // Same wallpaper, so the way out of full screen looks like the desktop it returns to.
                if let url = NSWorkspace.shared.desktopImageURL(for: screen), NSWorkspace.shared.desktopImageURL(for: twin) != url {
                    try? NSWorkspace.shared.setDesktopImageURL(url, for: twin, options: NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:])
                }
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

        let stage = Stage(display: display, panel: CGDisplayBounds(screen.displayID), overlay: overlay)
        if let twin = NSScreen.screens.first(where: { $0.displayID == id }) {
            let backdrop = PinnedWindow(contentRect: twin.frame, styleMask: .borderless, backing: .buffered, defer: false)
            backdrop.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            backdrop.backgroundColor = .clear
            backdrop.ignoresMouseEvents = true
            backdrop.isReleasedWhenClosed = false
            backdrop.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            backdrop.contentView = NSView()
            backdrop.contentView?.wantsLayer = true
            backdrop.contentView?.layer?.contentsGravity = .resize
            backdrop.setFrame(twin.frame, display: false)
            backdrop.orderFrontRegardless()
            stage.backdrop = backdrop
        }
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

    private init(display: CGVirtualDisplay, panel: CGRect, overlay: Overlay) {
        self.display = display
        self.panel = panel
        self.overlay = overlay
        id = display.displayID
        bounds = CGDisplayBounds(display.displayID)
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
            lastFrame = Date()
            overlay?.setLive(surface)
        }
    }

    /// Shows a picture of the panel's desktop behind everything on the stage, so going in and
    /// out of full screen there looks like it does on the panel.
    func setBackdrop(_ image: CGImage) {
        backdrop?.contentView?.layer?.contents = image
        // The wallpaper too, since it's what slides by when Spaces change.
        guard let twin = NSScreen.screens.first(where: { CGDisplayBounds($0.displayID) == bounds }),
              let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "TrueFullScreen") else { return }
        wallpapers += 1
        // Alternating names, so macOS notices the change.
        let url = folder.appendingPathComponent("Desktop \(wallpapers % 2).heic")
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let file = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(file, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(file) else { return }
            await MainActor.run {
                try? NSWorkspace.shared.setDesktopImageURL(url, for: twin, options: [.imageScaling: NSImageScaling.scaleAxesIndependently.rawValue, .allowClipping: true])
            }
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
        // Events already on their way still reach the fence, so it has to know to stand down.
        confined = on
        if let fence { CGEvent.tapEnable(tap: fence, enable: on) }
        let point = pointer()
        if on, !bounds.contains(point) {
            warp(panel.contains(point) ? point - panel.origin + bounds.origin : CGPoint(x: bounds.midX, y: bounds.midY))
        } else if !on, bounds.contains(point) {
            warp(point - bounds.origin + panel.origin)
        }
    }

    fileprivate func keep(_ point: CGPoint) {
        guard confined, !bounds.contains(point) else { return }
        let edge = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1), y: min(max(point.y, bounds.minY), bounds.maxY - 1))
        // Events from just before the pointer moved over still carry its spot on the panel.
        let stale = panel.contains(point) && hypot(point.x - edge.x, point.y - edge.y) > 8
        warp(stale ? point - panel.origin + bounds.origin : edge)
    }

    /// Whether the app has a window showing on the display.
    func isShowing(_ pid: pid_t) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid, info[kCGWindowLayer as String] as? Int == 0,
                  let rect = (info[kCGWindowBounds as String] as! CFDictionary?).flatMap(CGRect.init(dictionaryRepresentation:)) else { return false }
            return rect.intersects(bounds)
        }
    }

    func close() {
        hold(pointer: false)
        if let fence { CFMachPortInvalidate(fence) }
        try? stream?.removeStreamOutput(self, type: .screen)
        stream?.stopCapture()
        stream = nil
        latest = nil
        backdrop?.contentView?.layer?.contents = nil
        backdrop?.close()
        // The display goes away with its last reference, whatever still holds on to the stage.
        display = nil
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

/// WindowServer events for windows appearing and disappearing, Mission Control's among them.
private let windowEvents: [UInt32] = [1325, 1326, 1508]

private typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void

private let windowServerEvent: NotifyProc = { _, _, _, info in
    guard let info else { return }
    let controller = Unmanaged<Controller>.fromOpaque(info).takeUnretainedValue()
    DispatchQueue.main.async { MainActor.assumeIsolated { controller.exposeActive() } }
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
        let app: String?
        let window: AXUIElement
        let home: CGRect
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
    private var closing = false
    private var overlay: Overlay?
    private var tap: CFMachPort?
    private var swallowMouseUp = false
    private var missionControl = false
    private var lastExposeCheck = Date.distantPast
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

    private var allowed: Bool { AXIsProcessTrusted() && CGPreflightScreenCaptureAccess() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            return NSApp.terminate(nil)
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
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(self, selector: #selector(update), name: name, object: nil)
        }
        workspace.addObserver(self, selector: #selector(launched), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(accessibilityChanged), name: NSNotification.Name("com.apple.accessibility.api"), object: nil)

        // Mission Control isn't announced anywhere public; its windows coming and going give it away.
        let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        if let connection = dlsym(skyLight, "SLSMainConnectionID"), let register = dlsym(skyLight, "SLSRegisterConnectionNotifyProc") {
            typealias Main = @convention(c) () -> Int32
            typealias Register = @convention(c) (Int32, NotifyProc, UInt32, UnsafeMutableRawPointer?) -> Int32
            let register = unsafeBitCast(register, to: Register.self)
            let connection = unsafeBitCast(connection, to: Main.self)()
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
        overlay?.repin()
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

    private func overlay(for screen: NSScreen) -> Overlay {
        if let overlay, overlay.frame == screen.frame, overlay.panel == CGDisplayBounds(screen.displayID) { return overlay }
        overlay?.hideNow()
        let made = Overlay(screen: screen)
        overlay = made
        return made
    }

    /// What the panel shows right now, without this app's own windows.
    private func snapshot(of screen: NSScreen) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return nil }
        let mine = content.applications.filter { $0.processID == getpid() }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
        configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
        configuration.showsCursor = false
        configuration.colorSpaceName = CGColorSpace.displayP3
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Moves a window to the stage and takes it full screen there, behind a picture of the
    /// screen whose window grows to fill it, so nothing blinks or jumps along the way.
    private func takeOver(_ window: AXUIElement, pid: pid_t) async {
        guard !isBusy(window), let screen = NSScreen.notched, let start = frame(of: window) else { return }
        entering.append(window)
        defer { entering.removeAll { CFEqual($0, window) } }
        let overlay = overlay(for: screen)
        async let opened = openStage(on: screen, overlay: overlay)
        if let image = await snapshot(of: screen) {
            overlay.freeze(image)
            overlay.zoom(from: start, image: image)
        }
        // Already in the app's own full screen (keyboard, menu): leave it out of sight first.
        if isFullScreen(window) { await leaveFullScreen(window) }
        if let app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, let home = homes.removeValue(forKey: app) {
            move(window, to: home.origin)
        }
        guard let stage = await opened, let home = frame(of: window) else { return giveUp(window) }
        let parked = home.origin - stage.panel.origin + stage.bounds.origin
        for _ in 0..<3 where frame(of: window).map({ !stage.bounds.contains($0.origin) }) ?? false {
            move(window, to: parked)
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let moved = frame(of: window)?.origin, stage.bounds.contains(moved) else {
            move(window, to: home.origin)
            return giveUp(window)
        }
        targets.append(Target(pid: pid, app: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                              window: window, home: home, parked: parked))
        setFullScreen(window, true)
        await stage.settle(atLeast: .milliseconds(450), atMost: .milliseconds(1300))
        overlay.goLive()
        entering.removeAll { CFEqual($0, window) }
        update()
        refreshBackdrop()
    }

    /// The panel's desktop, as it is now, behind everything on the stage.
    private func refreshBackdrop() {
        guard let screen = NSScreen.notched else { return }
        Task {
            if let image = await snapshot(of: screen) { stage?.setBackdrop(image) }
        }
    }

    /// The app won't move, so it gets plain full screen.
    private func giveUp(_ window: AXUIElement) {
        ignored.append(window)
        setFullScreen(window, true)
        overlay?.fadeOut()
        entering.removeAll { CFEqual($0, window) }
        update()
    }

    private func openStage(on screen: NSScreen, overlay: Overlay) async -> Stage? {
        while opening || closing { try? await Task.sleep(for: .milliseconds(10)) }
        if let stage { return stage }
        opening = true
        stage = await Stage.open(on: screen, overlay: overlay)
        opening = false
        return stage
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

    /// Brings a window back to the panel once it has left full screen on the stage.
    private func bringHome(_ target: Target) async {
        // Let the way out play on screen, then swap in the real window underneath the last frame.
        await stage?.settle(atLeast: .milliseconds(100), atMost: .milliseconds(1000))
        overlay?.hold()
        await place(target.window, at: target.home.origin)
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
        overlay?.fadeOut()
        stage.hold(pointer: false)
        Task {
            var tries = 0
            while tries < 25, sweep(stage) {
                tries += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
            stage.close()
            let id = stage.id
            if self.stage === stage { self.stage = nil }
            // Wait for it to be gone, so a new one never overlaps it.
            for _ in 0..<40 where CGDisplayIsOnline(id) != 0 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            overlay?.clear()
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

    @objc private func update() {
        for target in targets where frame(of: target.window) == nil && NSRunningApplication(processIdentifier: target.pid) == nil {
            if let app = target.app { homes[app] = target.home }
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
            targets.removeAll { CFEqual($0.window, target.window) }
        }
        sweep(stage)
        if targets.isEmpty { return close(stage) }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let show = !missionControl && targets.contains { $0.pid == front } && front.map(stage.isShowing) == true
        if show, overlay?.isShown == false { refreshBackdrop() }
        if show { overlay?.fadeIn() } else { overlay?.fadeOut() }
        stage.hold(pointer: show)
    }

    // MARK: Mission Control

    /// Mission Control shows the panel's own Spaces, so step aside while it's open.
    fileprivate func exposeActive() {
        guard stage != nil, !missionControl, Date().timeIntervalSince(lastExposeCheck) > 0.2 else { return }
        lastExposeCheck = Date()
        guard missionControlIsOpen() else { return }
        missionControl = true
        overlay?.hideNow()
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
