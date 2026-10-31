import AppKit
import ScreenCaptureKit
import ServiceManagement
import os

// macOS keeps full screen windows below the notch. A green-button click instead moves the
// window to a notch-free virtual display the size of the built-in one and takes it full
// screen there. On the panel, a full screen window of this app's own stands in for it, in a
// Space of its own like any full screen window, and shows that display edge to edge.
// Nothing runs until a window goes full screen. Clicks, the pointer and the picture each run on
// a thread of their own: the main thread asks apps about their windows, and a busy app can keep
// it waiting.

/// What it decided and why, for Console: `log stream --predicate 'subsystem == "io.github.mason363.TrueFullScreen"'`.
private let logger = Logger(subsystem: "io.github.mason363.TrueFullScreen", category: "state")

private func note(_ message: String) { logger.notice("\(message, privacy: .public)") }

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

/// Whether a window is full screen, or nil while its app is too busy to say.
private func fullScreen(_ window: AXUIElement) -> Bool? {
    var value: CFTypeRef?
    switch AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) {
    case .success: return value as? Bool ?? false
    case .cannotComplete: return nil
    default: return false
    }
}

private func isFullScreen(_ window: AXUIElement) -> Bool { fullScreen(window) == true }

private func setFullScreen(_ window: AXUIElement, _ on: Bool) {
    AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, (on ? kCFBooleanTrue : kCFBooleanFalse)!)
}

private func setSize(_ window: AXUIElement, _ size: CGSize) {
    var size = size
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
}

private func isSettable(_ window: AXUIElement, _ attribute: String) -> Bool {
    var settable: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(window, attribute as CFString, &settable) == .success && settable.boolValue
}

/// Whether a window is gone, closed or with its app, as against its app being too busy to answer.
private func isGone(_ window: AXUIElement, of pid: pid_t) -> Bool {
    var role: CFTypeRef?
    return kill(pid, 0) != 0 && errno == ESRCH
        || AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .invalidUIElement
}

/// Whether a window keeps a size of its own across or down, as System Settings does its width. Its
/// app is asked for a point less, or more where that doesn't take, and then for its size back: the
/// only way to tell, since its limits aren't to be had otherwise.
private func keepsItsSize(_ window: AXUIElement) -> Bool {
    guard let size = frame(of: window)?.size else { return false }
    func takes(_ asked: CGSize) -> (across: Bool, down: Bool) {
        setSize(window, asked)
        let now = frame(of: window)?.size ?? size
        return (abs(now.width - size.width) >= 0.5, abs(now.height - size.height) >= 0.5)
    }
    var (across, down) = takes(CGSize(width: size.width - 1, height: size.height - 1))
    if !across || !down {
        // Already as small as it goes that way, perhaps.
        let more = takes(CGSize(width: size.width + (across ? 0 : 1), height: size.height + (down ? 0 : 1)))
        (across, down) = (across || more.across, down || more.down)
    }
    setSize(window, size)
    return !across || !down
}

/// Sizes and places a window, checking it took, since an app may adjust either. One that keeps to a
/// size of its own, as System Settings does its width, is left at it once it stops changing.
private func fit(_ window: AXUIElement, into rect: CGRect) async {
    var last: CGRect?
    for _ in 0..<10 {
        setSize(window, rect.size)
        move(window, to: rect.origin)
        setSize(window, rect.size)
        try? await Task.sleep(for: .milliseconds(40))
        guard let now = frame(of: window) else { continue }
        if abs(now.minX - rect.minX) < 2, abs(now.minY - rect.minY) < 2,
           (abs(now.width - rect.width) < 2 && abs(now.height - rect.height) < 2) || now == last { return }
        last = now
    }
}

@_silgen_name("_AXUIElementGetWindow")
private func axWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

private func windowID(of window: AXUIElement) -> CGWindowID {
    var id: CGWindowID = 0
    return axWindowID(window, &id) == .success ? id : 0
}

@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func axRemoteElement(_ token: CFData) -> Unmanaged<AXUIElement>?

/// A window of an app by its number, even in a Space that isn't showing, which the app's own list
/// of windows leaves out: its elements are tried one by one, as window switchers do.
private func hiddenWindow(_ id: CGWindowID, of pid: pid_t) -> AXUIElement? {
    var token = Data(count: 20)
    token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
    token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
    for element: UInt64 in 0..<2000 {
        token.replaceSubrange(12..<20, with: withUnsafeBytes(of: element) { Data($0) })
        if let window = axRemoteElement(token as CFData)?.takeRetainedValue(), windowID(of: window) == id { return window }
    }
    return nil
}

/// Hands a window the keyboard, along with its app. Through Accessibility too, which works from
/// behind another app, where asking the app to come forward may not. Asked on a queue of its own,
/// in order: an app still busy going full screen can take a while to answer.
private func focus(_ window: AXUIElement, pid: pid_t) {
    NSRunningApplication(processIdentifier: pid)?.activate()
    focusing.async {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
}

private let focusing = DispatchQueue(label: "TrueFullScreen.focus", qos: .userInteractive)

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

/// Asks an app something off the main thread, which draws the stand-ins' way in and out and would
/// stall while an app busy moving its window took its time to answer.
private func apart<Result>(_ body: () -> Result) async -> Result { body() }

/// Returns once an app answers, which it does from its main thread, so once it's through whatever
/// reached it before. Asked off the main thread here, which a slow app would otherwise hold up.
private func caughtUp(_ pid: pid_t) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 2)
            _ = value(app, kAXFocusedWindowAttribute)
            done.resume()
        }
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

/// Takes a window full screen and waits until it is, by its button if it can't be asked directly.
/// Returns whether it went.
private func goFullScreen(_ window: AXUIElement) async -> Bool {
    if isSettable(window, "AXFullScreen") {
        setFullScreen(window, true)
    } else if let button = element(window, kAXFullScreenButtonAttribute) {
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    } else {
        return false
    }
    for _ in 0..<60 {
        if isFullScreen(window) { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

/// Takes a window out of full screen if it's in it, and waits until it's out.
private func outOfFullScreen(_ window: AXUIElement) async {
    guard fullScreen(window) == true else { return }
    setFullScreen(window, false)
    for _ in 0..<60 where fullScreen(window) != false {
        try? await Task.sleep(for: .milliseconds(50))
    }
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
    NSRect(x: rect.minX, y: CGDisplayBounds(CGMainDisplayID()).height - rect.maxY, width: rect.width, height: rect.height)
}

private func pointer() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

private func activeDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

private func warp(_ point: CGPoint) {
    CGWarpMouseCursorPosition(point)
    CGAssociateMouseAndMouseCursorPosition(1)
}

private func clamp(_ point: CGPoint, into rect: CGRect) -> CGPoint {
    CGPoint(x: min(max(point.x, rect.minX), rect.maxX - 1), y: min(max(point.y, rect.minY), rect.maxY - 1))
}

private func distance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
    let near = clamp(point, into: rect)
    return hypot(point.x - near.x, point.y - near.y)
}

private func windowBounds(_ info: [String: Any]) -> CGRect? {
    (info[kCGWindowBounds as String] as! CFDictionary?).flatMap(CGRect.init(dictionaryRepresentation:))
}

/// Whether a point is where a window's buttons sit: at the top left of the frontmost ordinary
/// window under it. Most clicks are nowhere near, and need no app asked about them.
private func nearWindowButtons(_ point: CGPoint) -> Bool {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for info in windows where info[kCGWindowLayer as String] as? Int == 0 && (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 {
        guard let rect = windowBounds(info), rect.contains(point) else { continue }
        return point.x - rect.minX < 120 && point.y - rect.minY < 80
    }
    return false
}

/// Closes the tiling menu macOS brings up under a green button the pointer rests on, if it's up: the
/// button's click, taken over here, never reaches it, so it would stay open. Asked of one of its
/// items, the only part of it that answers.
private func closeTilingMenu() {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    guard let rect = windows.first(where: { $0[kCGWindowOwnerName as String] as? String == "ThemeWidgetControlViewService" }).flatMap(windowBounds)
    else { return }
    for fraction in [0.5, 0.25, 0.75] {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(rect.midX), Float(rect.minY + rect.height * fraction), &hit) == .success,
              let hit, value(hit, kAXRoleAttribute) as? String == kAXMenuItemRole else { continue }
        AXUIElementPerformAction(hit, kAXCancelAction as CFString)
        return
    }
}

/// A value shared between threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func callAsFunction<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

// MARK: - Spaces

private let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
private let connection = dlsym(skyLight, "SLSMainConnectionID").map { unsafeBitCast($0, to: (@convention(c) () -> Int32).self)() } ?? 0
private let copySpacesForWindows = dlsym(skyLight, "SLSCopySpacesForWindows")
    .map { unsafeBitCast($0, to: (@convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?).self) }
private let copyManagedDisplaySpaces = dlsym(skyLight, "SLSCopyManagedDisplaySpaces")
    .map { unsafeBitCast($0, to: (@convention(c) (Int32) -> Unmanaged<CFArray>?).self) }
/// Moves and fades this app's own windows in the window server directly, from any thread.
private let moveWindow = dlsym(skyLight, "SLSMoveWindow")
    .map { unsafeBitCast($0, to: (@convention(c) (Int32, UInt32, UnsafeMutablePointer<CGPoint>) -> Int32).self) }
private let setWindowAlpha = dlsym(skyLight, "SLSSetWindowAlpha")
    .map { unsafeBitCast($0, to: (@convention(c) (Int32, UInt32, Float) -> Int32).self) }
private let managedDisplayCurrentSpace = dlsym(skyLight, "SLSManagedDisplayGetCurrentSpace")
    .map { unsafeBitCast($0, to: (@convention(c) (Int32, CFString) -> UInt64).self) }
private let managedDisplayIsAnimating = dlsym(skyLight, "SLSManagedDisplayIsAnimating")
    .map { unsafeBitCast($0, to: (@convention(c) (Int32, CFString) -> Bool).self) }

/// The Spaces any of the windows are on.
private func spaces(of windows: [CGWindowID]) -> Set<Int> {
    Set(copySpacesForWindows?(connection, 7, windows as CFArray)?.takeRetainedValue() as? [Int] ?? [])
}

private func identifier(of display: CGDirectDisplayID) -> String? {
    CGDisplayCreateUUIDFromDisplayID(display).flatMap { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String? }
}

/// The Spaces of a display.
private func spaces(on display: CGDirectDisplayID) -> Set<Int> {
    guard let id = identifier(of: display),
          let displays = copyManagedDisplaySpaces?(connection)?.takeRetainedValue() as? [[String: Any]],
          let match = displays.first(where: { $0["Display Identifier"] as? String == id }) else { return [] }
    return Set((match["Spaces"] as? [[String: Any]] ?? []).compactMap { $0["ManagedSpaceID"] as? Int })
}

/// The Space a display is showing, as the window server has it, which is right even partway
/// through a switch, as asking a window whether it's on the active Space isn't. Asked directly,
/// a few microseconds each time, so it's never a moment out of date.
private func currentSpace(on display: CGDirectDisplayID) -> Int? {
    guard let id = identifier(of: display) else { return nil }
    if let managedDisplayCurrentSpace {
        let space = managedDisplayCurrentSpace(connection, id as CFString)
        return space == 0 ? nil : Int(space)
    }
    guard let displays = copyManagedDisplaySpaces?(connection)?.takeRetainedValue() as? [[String: Any]],
          let match = displays.first(where: { $0["Display Identifier"] as? String == id }) else { return nil }
    return (match["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
}

/// Whether a display is partway through moving between Spaces: its picture then shows the move.
private func isSwitchingSpaces(_ display: CGDirectDisplayID) -> Bool {
    guard let managedDisplayIsAnimating, let id = identifier(of: display) else { return false }
    return managedDisplayIsAnimating(connection, id as CFString)
}

/// Waits for a window moved to a display to join one of its Spaces, which macOS does a moment
/// after the move. Until then the window is in none, and an app taken full screen meanwhile can go
/// down with it. `before` is where it was, for when the display's own Spaces can't be read: then a
/// Space it wasn't in before will do. Returns whether it joined.
private func settled(_ window: CGWindowID, on display: CGDirectDisplayID, from before: Set<Int>) async -> Bool {
    guard window != 0 else {
        try? await Task.sleep(for: .milliseconds(150))
        return true
    }
    for _ in 0..<200 {
        let now = spaces(of: [window]), there = spaces(on: display)
        if there.isEmpty ? !now.isEmpty && now.isDisjoint(with: before) : !now.isDisjoint(with: there) { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

/// Whether Mission Control is up: its bar of Spaces, which comes first, or the shield behind it.
private func missionControlIsOpen() -> Bool {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.contains { ["Spaces Bar", "ExposeShieldWindow"].contains($0[kCGWindowName as String] as? String ?? "") }
}

/// Where a full screen Space on the panel is while Mission Control zooms it: its backdrop goes along.
private func fullScreenBackdrop(on panel: CGRect) -> (frame: CGRect, id: CGWindowID)? {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    for info in windows where info[kCGWindowName as String] as? String == "Fullscreen Backdrop" {
        guard let frame = windowBounds(info), let id = info[kCGWindowNumber as String] as? CGWindowID,
              panel.contains(CGPoint(x: frame.midX, y: frame.midY)) else { continue }
        return (frame, id)
    }
    return nil
}

private typealias CreateImage = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?

/// The older way to picture a window: gone from the SDK, but a third of the time of
/// ScreenCaptureKit's, which counts right after a click.
private let createImage = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage").map { unsafeBitCast($0, to: CreateImage.self) }

/// A window on its own, as a picture.
/// `quick` to ask the quick way only, to ask again soon.
private func picture(of id: CGWindowID, quick: Bool = false) async -> CGImage? {
    guard id != 0 else { return nil }
    // Just this window, without its shadow, at full resolution.
    if let image = createImage?(.null, CGWindowListOption.optionIncludingWindow.rawValue, id,
                                CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue)?.takeRetainedValue() {
        return image
    }
    guard !quick else { return nil }
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

/// The drawn part of a picture of a window just made smaller (points, at `scale` pixels each), which
/// can still come back the size it was: AppKit draws into the old surface from its bottom left until
/// it gets a new one, leaving the rest clear.
private func trimmed(_ image: CGImage, to size: CGSize, scale: CGFloat) -> CGImage {
    let (width, height) = (Int((size.width * scale).rounded()), Int((size.height * scale).rounded()))
    guard width > 0, height > 0, image.width >= width, image.height >= height,
          image.width - width > Int(scale) || image.height - height > Int(scale) else { return image }
    /// How many clear pixels come first along the middle of the picture, from its top or its left.
    func clear(down: Bool) -> Int {
        let length = down ? image.height : image.width
        guard let context = CGContext(data: nil, width: down ? 1 : length, height: down ? length : 1, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        context.draw(image, in: CGRect(x: down ? -CGFloat(image.width / 2) : 0, y: down ? 0 : -CGFloat(image.height / 2),
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return (0..<length).first { data[down ? $0 * context.bytesPerRow + 3 : $0 * 4 + 3] > 0 } ?? 0
    }
    let (x, y) = (min(clear(down: false), image.width - width), min(clear(down: true), image.height - height))
    return image.cropping(to: CGRect(x: x, y: y, width: width, height: height)) ?? image
}

// MARK: - Threads

/// A thread with a run loop of its own, for event taps: every event waits on its tap's answer,
/// so a tap must never wait on the main thread.
private func runLoopThread(_ name: String) -> CFRunLoop {
    let loop = Locked<CFRunLoop?>(nil)
    let ready = DispatchSemaphore(value: 0)
    let thread = Thread {
        loop { $0 = CFRunLoopGetCurrent() }
        // Something to wait on while there's no tap.
        var context = CFRunLoopSourceContext()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFRunLoopSourceCreate(nil, 0, &context), .commonModes)
        ready.signal()
        CFRunLoopRun()
    }
    thread.name = name
    thread.qualityOfService = .userInteractive
    thread.start()
    ready.wait()
    return loop { $0! }
}

private let clickLoop = runLoopThread("TrueFullScreen.clicks")
private let pointerLoop = runLoopThread("TrueFullScreen.pointer")

private func add(_ taps: [CFMachPort], to loop: CFRunLoop) {
    for tap in taps { CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes) }
    CFRunLoopWakeUp(loop)
}

/// Stops taps on their own thread, so none is partway through a callback, then lets go of what
/// they called back into, on the main thread, where its windows must go if they go with it.
private func remove(_ taps: [CFMachPort], from loop: CFRunLoop, releasing owner: Unmanaged<AnyObject>) {
    CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
        taps.forEach(CFMachPortInvalidate)
        DispatchQueue.main.async { owner.release() }
    }
    CFRunLoopWakeUp(loop)
}

// MARK: - Picture

/// Where a stand-in shows the stage, and the frame on show there, kept so the stream can't reuse
/// it while it's up.
final class Sink: @unchecked Sendable {
    let layers: [CALayer]
    fileprivate var frame: CMSampleBuffer?

    init(_ layers: [CALayer]) { self.layers = layers }
}

/// The stage's live picture, put straight onto the layers of whichever stand-in follows it, on the
/// stream's own queue.
final class Feed: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CMSampleBuffer?
    private var sinks: [Sink] = []
    /// The panel's colors, to show frames in.
    private let panel: CGColorSpace?
    /// Whether frames show as they are: tagged with the stage's profile, Core Animation reads it
    /// afresh for every frame, and the stage's colors are the panel's anyway. The stream's queue's.
    private var untag: Bool?

    init(panel: CGColorSpace?) { self.panel = panel }

    func publish(_ buffer: CMSampleBuffer) {
        guard let surface = surface(of: buffer) else { return }
        if untag == nil { untag = matchesPanel(surface) }
        if untag == true { IOSurfaceRemoveValue(surface, "IOSurfaceColorSpace" as CFString) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lock.lock()
        latest = buffer
        for sink in sinks { show(buffer, surface, on: sink) }
        lock.unlock()
        CATransaction.commit()
    }

    /// Follows the stage there. A frame only comes when something changes, so one new there starts on
    /// the last; one back keeps its own until the next, the last having likely caught another window.
    func attach(_ sink: Sink) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lock.lock()
        if !sinks.contains(where: { $0 === sink }) { sinks.append(sink) }
        if sink.frame == nil, let latest, let surface = surface(of: latest) { show(latest, surface, on: sink) }
        lock.unlock()
        CATransaction.commit()
    }

    /// Stops following there, keeping the frame on show.
    func detach(_ sink: Sink) {
        lock.lock()
        sinks.removeAll { $0 === sink }
        lock.unlock()
    }

    func clear() {
        lock.lock()
        latest = nil
        sinks.removeAll()
        lock.unlock()
    }

    /// Whether the frames' colors come out the same on the panel, converted or not.
    private func matchesPanel(_ surface: IOSurfaceRef) -> Bool {
        guard let panel, let data = IOSurfaceCopyValue(surface, "IOSurfaceColorSpace" as CFString),
              CFGetTypeID(data) == CFDataGetTypeID(), let stage = CGColorSpace(iccData: data as! CFData) else { return false }
        let samples: [[CGFloat]] = [[0.02, 0.02, 0.02], [0.12, 0.12, 0.12], [0.5, 0.5, 0.5], [0.9, 0.2, 0.1], [0.1, 0.7, 0.3], [0.2, 0.3, 0.95]]
        let same = samples.allSatisfy { rgb in
            guard let color = CGColor(colorSpace: stage, components: rgb + [1]),
                  let shown = color.converted(to: panel, intent: .relativeColorimetric, options: nil)?.components else { return false }
            return zip(rgb, shown).allSatisfy { abs($0 - $1) < 0.0015 }
        }
        note("frames: \(IOSurfaceGetPixelFormat(surface)), \(same ? "shown as they are" : "converted to the panel's colors")")
        return same
    }

    private func surface(of buffer: CMSampleBuffer) -> IOSurfaceRef? {
        buffer.imageBuffer.flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() }
    }

    private func show(_ buffer: CMSampleBuffer, _ surface: IOSurfaceRef, on sink: Sink) {
        sink.frame = buffer
        for layer in sink.layers { layer.contents = surface }
    }
}

// MARK: - Stand-in

/// A window that stays exactly where it's put, menu bar or not.
final class PinnedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// A picture as big as it fits in a rect, from its top left corner, where a window's content stays as
/// the window is resized. In AppKit's coordinates.
private func fromTopLeft(_ size: CGSize, in rect: CGRect) -> CGRect {
    let scale = min(rect.width / size.width, rect.height / size.height)
    return CGRect(x: rect.minX, y: rect.maxY - size.height * scale, width: size.width * scale, height: size.height * scale)
}

private let quiet: [String: CAAction] = ["contents": NSNull(), "opacity": NSNull(), "bounds": NSNull(),
                                         "position": NSNull(), "frame": NSNull(), "backgroundColor": NSNull(), "mask": NSNull()]

/// This app's own full screen window on the panel, standing in for a window on the stage. It gets
/// a Space of its own like any full screen window, so Spaces, swipes and Mission Control treat it as
/// one, and shows the stage 1:1. macOS keeps it below the notch, under a black menu bar strip, so a
/// band above that strip shows the top of the picture. On the way in and out it shows a still of
/// the window instead, growing out of and shrinking back to where the window sits.
@MainActor
final class StandIn: NSObject, NSWindowDelegate {
    let window: PinnedWindow
    let full: NSRect
    private let panelID: CGDirectDisplayID
    /// Where macOS lets a full screen window be: below the notch.
    private var safe: NSRect
    private var home: NSRect
    /// Black, as full screen is, but clear while it's the size of the window: the app's rounded
    /// corners, whatever their radius, then show what's behind them, as the window's own do.
    private let backdrop = CALayer()
    private let still = CALayer()
    private let live = CALayer()
    private let band: PinnedWindow
    private let bandLive = CALayer()
    private let sink: Sink
    private weak var feed: Feed?
    private(set) var isLive = false
    private var transition: CheckedContinuation<Bool, Never>?
    private var transitions = 0
    /// Where the stage's picture lands on the panel. The window shows its part of it 1:1, the band the top.
    var picture: NSRect { didSet { if picture != oldValue { layout() } } }
    /// Where the window sits in the stage's picture, from its top left, for one that's sized there
    /// rather than full screen: its still goes there as it fades into the picture.
    var lands: CGRect?
    private let stillSize: CGSize?

    init(screen: NSScreen, over rect: CGRect, image: CGImage?, title: String, feed: Feed) {
        full = screen.frame
        panelID = screen.displayID
        safe = full
        picture = full
        home = appKit(rect)
        stillSize = image.map { CGSize(width: $0.width, height: $0.height) }
        sink = Sink([live, bandLive])
        self.feed = feed
        band = PinnedWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window = PinnedWindow(contentRect: home, styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.titlebarSeparatorStyle = .none
        hideTitleBar()
        window.collectionBehavior = [.fullScreenPrimary]
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.delegate = self
        let view = NSView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        window.contentView = view
        // Right over the window to begin with, and the same: clear around its picture.
        showBehind(true)
        backdrop.backgroundColor = .black
        backdrop.isOpaque = true
        for layer in [backdrop, live, still] {
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

        // Both in the panel's own colors, which the stage's are too, so the picture shows unconverted.
        // (The strip's own compositing still rounds dark grays there a level.)
        window.colorSpace = screen.colorSpace
        band.colorSpace = screen.colorSpace
        // Above the menu bar strip macOS puts over full screen windows, in this one's Space.
        band.level = .statusBar
        band.backgroundColor = .black
        band.hasShadow = false
        band.ignoresMouseEvents = true
        band.isReleasedWhenClosed = false
        band.animationBehavior = .none
        band.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        band.isOpaque = true
        band.contentView = NSView()
        band.contentView?.wantsLayer = true
        band.contentView?.layer?.backgroundColor = .black
        band.contentView?.layer?.isOpaque = true
        band.contentView?.layer?.masksToBounds = true
        bandLive.isOpaque = true
        live.isOpaque = true
        bandLive.actions = quiet
        bandLive.contentsGravity = .resize
        band.contentView?.layer?.addSublayer(bandLive)
        // Right over the window it stands in for.
        window.orderFrontRegardless()
    }

    var isFullScreen: Bool { window.styleMask.contains(.fullScreen) }

    /// Whether the panel is showing its Space.
    var isCurrent: Bool { isFullScreen && isIn(currentSpace(on: panelID)) }

    /// Whether it's full screen in one of these Spaces.
    func isIn(anyOf theirs: Set<Int>) -> Bool {
        isFullScreen && !spaces(of: [CGWindowID(window.windowNumber)]).isDisjoint(with: theirs)
    }

    /// Whether a window of this one's is in a Space.
    private func isIn(_ space: Int?, _ which: NSWindow? = nil) -> Bool {
        guard let space else { return false }
        return spaces(of: [CGWindowID((which ?? window).windowNumber)]).contains(space)
    }

    /// Takes it full screen, growing out of the window it covers. Returns whether it got there.
    func enter() async -> Bool {
        await withCheckedContinuation { done in
            start(done)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.toggleFullScreen(nil)
        }
    }

    /// Shrinks it back out of full screen to where its window goes.
    func leave(to rect: CGRect) async -> Bool {
        home = appKit(rect)
        hold()
        guard isFullScreen else { return true }
        // Still on its way in: let that finish first, so neither transition is left hanging.
        while transition != nil { try? await Task.sleep(for: .milliseconds(20)) }
        return await withCheckedContinuation { done in
            start(done)
            // In front first, so it stays in sight all the way home as the Spaces change behind it, as a
            // window leaving full screen does: the front app's windows are the ones lifted over the change.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.toggleFullScreen(nil)
        }
    }

    /// How many stand-ins are on their way in or out of full screen, an animation the main thread draws.
    private(set) static var moving = 0
    /// Called once none is.
    static var onStill: (() -> Void)?

    /// Waits on a transition, giving up after a while: only on this one, not one that comes after.
    private func start(_ done: CheckedContinuation<Bool, Never>) {
        if transition == nil { Self.moving += 1 }
        transition = done
        transitions += 1
        let current = transitions
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.transitions == current { self?.finish(false) }
        }
    }

    /// Brings its Space up on the panel. Only the older call does that from behind another app.
    func reveal() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func finish(_ done: Bool) {
        guard let transition else { return }
        self.transition = nil
        transition.resume(returning: done)
        Self.moving -= 1
        if Self.moving == 0 { DispatchQueue.main.async { Self.onStill?() } }
    }

    /// Fades in the window's own picture, as it is out of full screen, for the end of the way out.
    /// Once it's in, nothing else shows around its rounded corners. Returns how long that takes: the
    /// window waits to take its place until then, and its picture can only be had near the end.
    @discardableResult
    func land(_ image: CGImage) -> TimeInterval {
        let duration = 0.12
        still.contents = image
        still.contentsGravity = .resize
        still.backgroundColor = nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.still.opacity == 1, !self.isLive else { return }
                // A window sized there still shows a little of its full screen size below its own
                // picture, on its way to its own size: that goes gently rather than all at once.
                if self.moving != nil {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 1
                    fade.toValue = 0
                    fade.duration = 0.2
                    self.live.add(fade, forKey: "opacity")
                }
                self.live.opacity = 0
                self.showBehind(true)
            }
        }
        still.opacity = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        still.add(fade, forKey: "opacity")
        CATransaction.commit()
        return duration
    }

    /// Clears the window around its picture, or makes it solid black, as it is in full screen.
    private func showBehind(_ on: Bool) {
        window.isOpaque = !on
        window.backgroundColor = on ? .clear : .black
        backdrop.opacity = on ? 0 : 1
    }

    /// Keeps the last frame, while the stage shows something that isn't the window. The band stays,
    /// in this window's Space, so the top is there whenever the Space is.
    func hold() {
        guard isLive else { return }
        isLive = false
        feed?.detach(sink)
    }

    /// Whether a window is in front of it on the screen.
    func isCovered(by id: CGWindowID) -> Bool {
        guard id != 0, window.isVisible else { return true }
        let above = CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] ?? []
        return above.contains { $0[kCGWindowNumber as String] as? CGWindowID == id }
    }

    /// Hides the band, for Mission Control, which would show it over everything, or shows it again
    /// as Mission Control lands back in its Space. Left in its Space either way.
    func showBand(_ on: Bool) {
        band.alphaValue = on ? 1 : 0
    }

    /// Puts the band over the strip above the window, where displays coming and going don't leave it.
    func pin() {
        let strip = NSRect(x: full.minX, y: window.frame.maxY, width: full.width, height: full.maxY - window.frame.maxY)
        guard isFullScreen, strip.height > 0 else { return }
        if band.frame != strip {
            band.setFrame(strip, display: false)
            band.colorSpace = window.screen?.colorSpace
        }
        layout()
    }

    private func layout() {
        guard isFullScreen, shrinking == nil, moving == nil else { return }
        live.autoresizingMask = []
        let inWindow = picture.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        let inBand = picture.offsetBy(dx: -band.frame.minX, dy: -band.frame.minY)
        if live.frame != inWindow { live.frame = inWindow }
        if bandLive.frame != inBand { bandLive.frame = inBand }
    }

    /// Follows the stage again, cross-fading from the still the first time.
    func goLive() {
        showBand(true)
        pin()
        // Ordered in while its Space is up, which puts it in that Space, and only then: one that
        // ended up in another stand-in's Space would show this one's picture there.
        let space = currentSpace(on: panelID)
        if band.isVisible, !isIn(space, band), isIn(space) { band.orderOut(nil) }
        if !band.isVisible, window.frame.maxY < full.maxY, isIn(space) { band.orderFrontRegardless() }
        guard !isLive else { return }
        isLive = true
        if isFullScreen, !window.isOpaque { showBehind(false) }
        feed?.attach(sink)
        guard still.opacity > 0 else {
            live.opacity = 1
            return
        }
        // The still fades out over the picture, there in full beneath it from the start: both fading
        // at once would let the black behind them show through, a quarter of it halfway.
        still.backgroundColor = .black
        live.opacity = 1
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setCompletionBlock { [still] in
            still.contents = nil
            still.backgroundColor = nil
            still.contentsGravity = .resizeAspect
            still.frame = still.superlayer?.bounds ?? still.frame
            still.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        }
        // From as big as it fits to just where the window is, as macOS's own way into full screen
        // does, rather than fading over it at another size.
        if let lands, let stillSize, stillSize.width > 0, stillSize.height > 0 {
            let bounds = still.frame
            let scale = min(bounds.width / stillSize.width, bounds.height / stillSize.height)
            let from = CGRect(x: bounds.midX - stillSize.width * scale / 2, y: bounds.midY - stillSize.height * scale / 2,
                              width: stillSize.width * scale, height: stillSize.height * scale)
            let to = fromTopLeft(stillSize, in: CGRect(x: live.frame.minX + lands.minX, y: live.frame.maxY - lands.maxY,
                                                       width: lands.width, height: lands.height))
            still.autoresizingMask = []
            still.contentsGravity = .resize
            still.frame = to
            let size = CABasicAnimation(keyPath: "bounds.size")
            size.fromValue = NSValue(size: from.size)
            size.toValue = NSValue(size: to.size)
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: CGPoint(x: from.midX, y: from.midY))
            move.toValue = NSValue(point: CGPoint(x: to.midX, y: to.midY))
            // There well before it's faded, so the two pictures line up for most of the fade.
            for animation in [size, move] { animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.1, 1) }
            still.add(size, forKey: "bounds.size")
            still.add(move, forKey: "position")
        }
        still.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        still.add(fade, forKey: "opacity")
        CATransaction.commit()
    }

    func close() {
        hold()
        finish(false)
        band.close()
        window.orderOut(nil)
        window.close()
        for layer in [still, live, bandLive] { layer.contents = nil }
        sink.frame = nil
    }

    // MARK: Full screen

    func window(_ window: NSWindow, willUseFullScreenContentSize proposedSize: NSSize) -> NSSize {
        safe.size = proposedSize
        return proposedSize
    }

    func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? { [window] }

    func window(_ window: NSWindow, startCustomAnimationToEnterFullScreenOn screen: NSScreen, withDuration duration: TimeInterval) {
        enterDuration = duration
        // Black comes in around the picture as it starts to grow: only its very first frames are
        // the size of the window.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = duration / 4
        backdrop.opacity = 1
        backdrop.add(fade, forKey: "opacity")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.1, 1)
            window.animator().setFrame(safe, display: true)
        }
    }

    /// How long the way in took, for the log.
    private(set) var enterDuration: TimeInterval = 0

    func windowDidEnterFullScreen(_ notification: Notification) {
        hideTitleBar()
        showBehind(false)
        layout()
        finish(true)
    }

    /// The title bar a window needs to go full screen, kept out of sight: in full screen it would come
    /// down with the menu bar whenever the pointer reached the top of the panel, empty.
    private func hideTitleBar() {
        window.standardWindowButton(.closeButton)?.superview?.superview?.alphaValue = 0
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) { finish(false) }

    func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? { [window] }

    func window(_ window: NSWindow, startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval) {
        // The strip above goes dark, as a full screen window's does on its way out.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = min(0.15, duration / 2)
            band.animator().alphaValue = 0
        }, completionHandler: { [band] in band.orderOut(nil) })
        // The picture shrinks with the window from just where it is, the part that showed above the
        // window staying above it, so its first frame on the way out is its last one in full screen.
        let bounds = window.contentView?.bounds ?? .zero
        live.autoresizingMask = []
        still.frame = bounds
        still.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        if let lands, lands.width > 0, lands.height > 0 {
            // A window sized there goes from just where it is in the picture to where it goes, by itself:
            // the black of full screen behind it gives way to the desktop, as it does for any window.
            let rect = CGRect(x: live.frame.minX + lands.minX, y: live.frame.maxY - lands.maxY, width: lands.width, height: lands.height)
            moving = (rect.offsetBy(dx: window.frame.minX, dy: window.frame.minY), window.frame)
            let mask = CALayer()
            mask.actions = quiet
            mask.backgroundColor = .black
            live.mask = mask
            still.autoresizingMask = []
            showBehind(true)
            follow()
        } else if bounds.width > 0, bounds.height > 0 {
            shrinking = CGRect(x: live.frame.minX / bounds.width, y: live.frame.minY / bounds.height,
                               width: live.frame.width / bounds.width, height: live.frame.height / bounds.height)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.1, 1)
            window.animator().setFrame(home, display: true)
        }
    }

    /// Where the picture sits in the window on the way out, as a share of the window's size.
    private var shrinking: CGRect?
    /// On the way out of a window sized there, where it started on the screen, and where the stand-in did.
    private var moving: (from: NSRect, start: NSRect)?

    func windowDidResize(_ notification: Notification) {
        if moving != nil { return follow() }
        guard let shrinking, let bounds = window.contentView?.bounds else { return }
        live.frame = CGRect(x: shrinking.minX * bounds.width, y: shrinking.minY * bounds.height,
                            width: shrinking.width * bounds.width, height: shrinking.height * bounds.height)
    }

    /// Puts the window's picture, and only that, as far along its way home as the stand-in is along its own.
    private func follow() {
        guard let moving, let lands else { return }
        let (start, now) = (moving.start, window.frame)
        let span = max(abs(home.width - start.width), abs(home.height - start.height))
        let done = span < 1 ? 1 : max(abs(now.width - start.width), abs(now.height - start.height)) / span
        let rect = NSRect(x: moving.from.minX + (home.minX - moving.from.minX) * done - now.minX,
                          y: moving.from.minY + (home.minY - moving.from.minY) * done - now.minY,
                          width: moving.from.width + (home.width - moving.from.width) * done,
                          height: moving.from.height + (home.height - moving.from.height) * done)
        // Both pictures keep their shape, from the top left, where the window's content stays as its size
        // changes: the one from the stage covering the way, cut to it, its own one fitting in it.
        let scale = max(rect.width / lands.width, rect.height / lands.height)
        live.frame = CGRect(x: rect.minX - lands.minX * scale, y: rect.maxY + lands.minY * scale - picture.height * scale,
                            width: picture.width * scale, height: picture.height * scale)
        live.mask?.frame = rect.offsetBy(dx: -live.frame.minX, dy: -live.frame.minY)
        still.frame = stillSize.map { fromTopLeft($0, in: rect) } ?? rect
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        shrinking = nil
        moving = nil
        live.mask = nil
        // Back among the desktop's windows, in front of them, where the window it stands in for comes
        // back: its app's other windows would otherwise cover it until that one does.
        window.orderFrontRegardless()
        finish(true)
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) { finish(false) }
}

// MARK: - Pointer

private let currentCursorSeed = dlsym(skyLight, "SLSCurrentCursorSeed").map { unsafeBitCast($0, to: (@convention(c) () -> UInt32).self) }
private let cursorIsVisible = dlsym(dlopen(nil, RTLD_NOW), "CGCursorIsVisible").map { unsafeBitCast($0, to: (@convention(c) () -> UInt32).self) }
private let getCursorScale = dlsym(skyLight, "SLSGetCursorScale")
    .map { unsafeBitCast($0, to: (@convention(c) (Int32, UnsafeMutablePointer<Float>) -> Int32).self) }

/// The pointer, drawn on the panel where it is on the stage, as soon as it moves: the stage's own
/// picture of it would trail a few frames behind. It's moved from the pointer thread straight
/// through the window server, so it keeps up with the hand whatever the main thread is doing.
final class Sprite: @unchecked Sendable {
    private let window: PinnedWindow
    private let view = NSImageView()
    private let lock = NSLock()
    private var id: UInt32 = 0
    private var hotSpot = CGPoint.zero
    private var spot = CGPoint.zero
    /// Wanted on show, and hidden by the system, as it does while typing.
    private var wanted = false
    private var hidden = false
    private var alpha: Float = -1
    /// The look on show, by the system's count of pointer changes, and whether the main thread has
    /// been asked to take on a newer one, or the pointer thread to look again in a moment.
    private var seed = UInt32.max
    private var asked = false
    private var looking = false
    // The main thread's.
    private var timer: Timer?

    @MainActor init() {
        window = PinnedWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(.cursorWindow)) - 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // Unseen until it's been put where the pointer is.
        window.alphaValue = 0
        view.imageScaling = .scaleAxesIndependently
        window.contentView = view
    }

    /// Puts it up to follow the pointer, or takes it down.
    @MainActor func run(_ on: Bool) {
        if on, timer == nil {
            lock.lock()
            seed = .max
            asked = false
            hidden = cursorIsVisible?() == 0
            lock.unlock()
            refresh()
            window.orderFrontRegardless()
            lock.lock()
            id = UInt32(window.windowNumber)
            alpha = -1
            lock.unlock()
            apply()
            // Its look can change while it stands still too: typing hides it, apps swap it.
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.look() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !on, timer != nil {
            timer?.invalidate()
            timer = nil
            window.orderOut(nil)
            lock.lock()
            id = 0
            wanted = false
            lock.unlock()
        }
    }

    /// Shows it at a spot on the panel, in global display coordinates. From any thread.
    func show(at point: CGPoint) {
        lock.lock()
        spot = point
        wanted = true
        if hidden, cursorIsVisible?() != 0 { hidden = false }
        var origin = point - hotSpot
        if id != 0 { _ = moveWindow?(connection, id, &origin) }
        applyLocked()
        lock.unlock()
        // Moved onto something with a pointer of its own, a link or text, say.
        look()
        lookSoon()
    }

    func hide() {
        lock.lock()
        wanted = false
        applyLocked()
        lock.unlock()
    }

    private func apply() {
        lock.lock()
        applyLocked()
        lock.unlock()
    }

    private func applyLocked() {
        let target: Float = wanted && !hidden ? 1 : 0
        guard id != 0, target != alpha else { return }
        alpha = target
        _ = setWindowAlpha?(connection, id, target)
    }

    /// Follows the pointer's visibility, and has the main thread take on a new look. From any
    /// thread, as often as it likes: both questions take microseconds.
    func look() {
        lock.lock()
        defer { lock.unlock() }
        guard id != 0 else { return }
        hidden = cursorIsVisible?() == 0
        applyLocked()
        guard !asked, let current = currentCursorSeed?(), current != seed else { return }
        asked = true
        DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh() } }
    }

    /// Looks again in a moment: an app changes the pointer once it has the event that moved it, and
    /// hides it once it has a key.
    func lookSoon() {
        lock.lock()
        guard id != 0, !looking else { return lock.unlock() }
        looking = true
        lock.unlock()
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(12)) { [self] in
            lock.lock()
            looking = false
            lock.unlock()
            look()
        }
    }

    /// Takes on the pointer's current look and size.
    @MainActor private func refresh() {
        lock.lock()
        asked = false
        // Counted before it's read: a change in between is seen next time.
        let current = currentCursorSeed?() ?? 0
        let changed = current != seed
        seed = current
        lock.unlock()
        guard changed else { return }
        let cursor = NSCursor.currentSystem ?? .arrow
        var scale: Float = 1
        _ = getCursorScale?(connection, &scale)
        let factor = CGFloat(max(scale, 1))
        let size = CGSize(width: cursor.image.size.width * factor, height: cursor.image.size.height * factor)
        view.image = cursor.image
        lock.lock()
        hotSpot = CGPoint(x: cursor.hotSpot.x * factor, y: cursor.hotSpot.y * factor)
        let origin = spot - hotSpot
        lock.unlock()
        // AppKit moves it back to where it last put it, which the window server knows better by now.
        window.setFrame(appKit(CGRect(origin: origin, size: size)), display: true)
    }
}

// MARK: - Fence

/// Private event fields: what kind of gesture an event is part of, and how far along it is.
private let gestureKind = CGEventField(rawValue: 110)!
private let gesturePhase = CGEventField(rawValue: 132)!
private let gestureMotion = CGEventField(rawValue: 123)!
private let dockSwipe: Int64 = 23
private let vertical: Int64 = 2
private let titleBarHeight: CGFloat = 28
/// Keys for Mission Control, App Exposé and moving between Spaces: its own key, and ⌃ with an
/// arrow or a number.
private let missionControlKey: Int64 = 160
private let shortcutModifiers: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift]

/// The keyboard shortcuts for Mission Control, App Exposé and Spaces that are switched on, as key
/// code and modifiers: the user's own where they've changed them, macOS's otherwise. Others with
/// the same keys (⌃1 in Xcode, ⌃← in a text field) are left alone.
private func spaceShortcuts() -> Set<Int64> {
    let control = Int64(CGEventFlags.maskControl.rawValue)
    // Mission Control, App Exposé, a Space left and right, then Desktops 1 to 9, which start off.
    var defaults: [Int: (code: Int64, modifiers: Int64, on: Bool)] = [32: (126, control, true), 33: (125, control, true),
                                                                     79: (123, control, true), 81: (124, control, true)]
    for (index, code) in [18, 19, 20, 21, 23, 22, 26, 28, 25].enumerated() { defaults[118 + index] = (Int64(code), control, false) }
    let saved = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any] ?? [:]
    var keys: Set<Int64> = []
    for (id, standard) in defaults {
        let entry = saved[String(id)] as? [String: Any]
        guard entry?["enabled"] as? Bool ?? standard.on else { continue }
        let parameters = (entry?["value"] as? [String: Any])?["parameters"] as? [Int64]
        let code = parameters.map { $0.count > 1 ? $0[1] : standard.code } ?? standard.code
        let modifiers = parameters.map { $0.count > 2 ? $0[2] : standard.modifiers } ?? standard.modifiers
        keys.insert(code << 32 | modifiers & Int64(shortcutModifiers.rawValue))
    }
    return keys
}

@MainActor
protocol FenceDelegate: AnyObject {
    /// The picture moved: the menu bar of a stage for windows sized to fill came or went.
    func fenceMovedPicture()
    /// A system swipe started (true) or ended (false), and whether it's up or down.
    func fenceSwiped(_ started: Bool, vertical: Bool)
    /// ⌃⌘F, for a window sized to fill.
    func fenceExitKey()
    /// A key for Mission Control or App Exposé (`overview`), or for moving between Spaces.
    func fenceSystemKey(overview: Bool)
}

/// Keeps the pointer where it belongs while a stage is up: on the stage while a stand-in follows it,
/// drawn on the panel, and off it otherwise. Points the system's swipes at the panel. It runs on the
/// pointer thread, and the main thread tells it what to hold to.
final class Fence: @unchecked Sendable {
    let panel: CGRect
    let bounds: CGRect
    let sprite: Sprite
    /// The main thread's.
    weak var delegate: FenceDelegate?
    private let others: [CGRect]
    private let shortcuts = spaceShortcuts()
    private let lock = NSLock()
    private var taps: [CFMachPort] = []
    /// The main thread's.
    private var installed = false
    /// After a key for Mission Control or Spaces, the pointer stays on the panel until it's clear
    /// what the key did: the main thread hears of the key a moment later.
    private var releasedUntil: CFAbsoluteTime = 0
    /// Whether the pointer belongs on the stage (true) or must stay off it (false).
    private var confined = false
    /// Where something else is over the stand-in on the panel (a notification, an alert): the
    /// pointer goes there instead of through it to the stage.
    private var openings: [CGRect] = []
    private var visiting = false
    /// How far down the stage the panel's picture starts: below the menu bar, where a window sized
    /// to fill sits. 0 for full screen windows.
    private var top: CGFloat = 0
    /// Where the picture starts right now: at the very top while the menu bar is out.
    private var offset: CGFloat = 0
    private var quietUntil: CFAbsoluteTime = 0
    private var movedTo = CGPoint.zero
    private var swiping = false
    private var lastSwipe: CFAbsoluteTime = 0
    private var exitArmed = false

    @MainActor init(panel: CGRect, bounds: CGRect, others: [CGRect]) {
        self.panel = panel
        self.bounds = bounds
        self.others = others
        sprite = Sprite()
    }

    @MainActor func install() {
        guard !installed else { return }
        installed = true
        let moves: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let info = Unmanaged.passRetained(self).toOpaque()
        // Pointer moves, as they happen; gestures, the system's swipes among them; keys.
        let made = [(CGEventTapPlacement.tailAppendEventTap, CGEventTapOptions.listenOnly, moves.reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }),
                    (.headInsertEventTap, .defaultTap, 1 << 29 | 1 << 30 | 1 << 31),
                    (.headInsertEventTap, .defaultTap, 1 << CGEventType.keyDown.rawValue)].compactMap {
            CGEvent.tapCreate(tap: .cgSessionEventTap, place: $0.0, options: $0.1, eventsOfInterest: $0.2,
                              callback: fenceCallback, userInfo: info)
        }
        lock.lock()
        taps = made
        lock.unlock()
        add(made, to: pointerLoop)
    }

    @MainActor func uninstall() {
        guard installed else { return }
        installed = false
        lock.lock()
        let taps = taps
        self.taps = []
        lock.unlock()
        remove(taps, from: pointerLoop, releasing: Unmanaged.passUnretained(self as AnyObject))
    }

    fileprivate func reenable() {
        lock.lock()
        taps.forEach { CGEvent.tapEnable(tap: $0, enable: true) }
        lock.unlock()
    }

    var isConfined: Bool { locked { confined } }

    var offsetNow: CGFloat { locked { offset } }

    func setTop(_ value: CGFloat) { locked { top = value; offset = value } }

    func setOpenings(_ rects: [CGRect]) { locked { openings = rects } }

    /// Arms ⌃⌘F, while a window sized to fill is in front.
    func armExit(_ on: Bool) { locked { exitArmed = on } }

    /// The part of the stage the panel shows.
    var shown: CGRect { locked { shownLocked } }

    private var shownLocked: CGRect { CGRect(x: bounds.minX, y: bounds.minY + offset, width: panel.width, height: panel.height) }

    private func locked<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func onPanel(_ point: CGPoint) -> CGPoint { point - shownLocked.origin + panel.origin }
    private func onStage(_ point: CGPoint) -> CGPoint { point - panel.origin + shownLocked.origin }

    private func warpLocked(_ point: CGPoint) {
        warp(point)
        // Events from before the move still carry the old spot.
        quietUntil = CFAbsoluteTimeGetCurrent() + 0.08
        movedTo = point
    }

    /// Moves the pointer onto the stage and keeps it there, or back to the same spot on the panel.
    /// Not onto it during a swipe, or just after a key for Mission Control or Spaces.
    func hold(_ on: Bool) {
        lock.lock()
        if on, swiping || CFAbsoluteTimeGetCurrent() < releasedUntil {
            lock.unlock()
            return
        }
        confined = on
        let point = pointer()
        if on, visiting, panel.contains(point), openings.contains(where: { $0.contains(point) }) {
            lock.unlock()
            return
        }
        visiting = false
        var spot = point
        if on, !shownLocked.contains(point) {
            spot = panel.contains(point) ? onStage(point) : CGPoint(x: shownLocked.midX, y: shownLocked.midY)
            warpLocked(spot)
        } else if !on, bounds.contains(point) {
            warpLocked(clamp(onPanel(point), into: panel))
        }
        let onPanel = onPanel(spot)
        // Away from the stage's top edge, its menu bar goes, and with it the view of it.
        let menuBarGone = !on && offset != top
        if menuBarGone { offset = top }
        lock.unlock()
        if on { sprite.show(at: onPanel) } else { sprite.hide() }
        if menuBarGone { notify { $0.fenceMovedPicture() } }
    }

    /// The stage touches the other displays at a corner, which the pointer could slip through:
    /// keep it on the stage while it's in front, and off it otherwise.
    fileprivate func moved(_ point: CGPoint) {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        if confined, !visiting, top > 0, now >= quietUntil, let to = revealMenuBar(point) {
            let spot = onPanel(to)
            lock.unlock()
            sprite.show(at: spot)
            notify { $0.fenceMovedPicture() }
            return
        }
        var show: CGPoint?
        var hide = false
        // Just after a move, only events from around the new spot are current.
        if confined, shownLocked.contains(point), !visiting, now >= quietUntil || hypot(point.x - movedTo.x, point.y - movedTo.y) < 60 {
            show = onPanel(point)
        }
        if now >= quietUntil {
            if confined, shownLocked.contains(point) {
                let spot = onPanel(point)
                visiting = openings.contains { $0.contains(spot) }
                if visiting {
                    show = nil
                    hide = true
                    warpLocked(spot)
                }
            } else if confined, visiting, panel.contains(point) {
                if !openings.contains(where: { $0.contains(point) }) {
                    visiting = false
                    warpLocked(onStage(point))
                    show = point
                }
            } else if confined {
                let to = clamp(point, into: shownLocked)
                warpLocked(to)
                if !visiting { show = onPanel(to) }
            } else if bounds.contains(point) {
                let display = others.min { distance(point, to: $0) < distance(point, to: $1) } ?? panel
                warpLocked(clamp(point, into: display))
            }
        }
        lock.unlock()
        if hide { sprite.hide() } else if let show { sprite.show(at: show) }
    }

    /// A window sized to fill sits below the stage's menu bar, out of the picture. Pushing past the
    /// top edge brings the menu bar in, as over full screen windows, until the pointer moves well
    /// below it again. The pointer keeps its spot on the panel either way. Returns where it went.
    private func revealMenuBar(_ point: CGPoint) -> CGPoint? {
        if offset > 0, point.y < shownLocked.minY, bounds.contains(point) {
            offset = 0
            let to = CGPoint(x: point.x, y: bounds.minY)
            warpLocked(to)
            return to
        } else if offset == 0, point.y > bounds.minY + top + titleBarHeight + 24 {
            offset = top
            let to = CGPoint(x: point.x, y: point.y + top)
            warpLocked(to)
            return to
        }
        return nil
    }

    /// The system's swipes go to the display under the pointer, which is the stage while it's in
    /// front. Point them at the panel instead, so its Spaces move as they would anyway.
    fileprivate func gesture(_ event: CGEvent) {
        guard event.getIntegerValueField(gestureKind) == dockSwipe else { return }
        lock.lock()
        var started: Bool?
        if !swiping, confined {
            swiping = true
            started = event.getIntegerValueField(gestureMotion) == vertical
        }
        guard swiping else {
            lock.unlock()
            return
        }
        lastSwipe = CFAbsoluteTimeGetCurrent()
        if bounds.contains(event.location) { event.location = onPanel(event.location) }
        // Ended, or cancelled.
        let ended = event.getIntegerValueField(gesturePhase) & (4 | 8) != 0
        if ended { swiping = false }
        lock.unlock()
        if let started {
            // The pointer goes to the panel, where the Dock looks for it.
            hold(false)
            notify { $0.fenceSwiped(true, vertical: started) }
            if !ended { watchSwipe() }
        }
        if ended { notify { $0.fenceSwiped(false, vertical: false) } }
    }

    /// Ends a swipe whose end never came through.
    private func watchSwipe() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            lock.lock()
            guard swiping else { return lock.unlock() }
            let stale = CFAbsoluteTimeGetCurrent() - lastSwipe > 1
            if stale { swiping = false }
            lock.unlock()
            if stale { MainActor.assumeIsolated { delegate?.fenceSwiped(false, vertical: false) } } else { watchSwipe() }
        }
    }

    /// Returns true to swallow the key.
    fileprivate func key(_ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let modifiers = event.flags.intersection(shortcutModifiers)
        lock.lock()
        let confined = confined, armed = exitArmed
        lock.unlock()
        // Typing hides the pointer.
        if confined { sprite.lookSoon() }
        // ⌃⌘F, the way out of full screen, which a window sized to fill has none of.
        if armed, modifiers == [.maskControl, .maskCommand], code == 3 {
            notify { $0.fenceExitKey() }
            return true
        }
        // Mission Control and Spaces act where the pointer is, and the stage would show them: the
        // pointer goes to the panel before they act.
        if confined, code == missionControlKey || shortcuts.contains(code << 32 | Int64(modifiers.rawValue)) {
            lock.lock()
            releasedUntil = CFAbsoluteTimeGetCurrent() + 0.6
            lock.unlock()
            hold(false)
            let overview = code == missionControlKey || code == 125 || code == 126
            notify { $0.fenceSystemKey(overview: overview) }
        }
        return false
    }

    private func notify(_ body: @escaping @MainActor (FenceDelegate) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let delegate = self.delegate { body(delegate) }
            }
        }
    }
}

private let fenceCallback: CGEventTapCallBack = { _, type, event, info in
    let fence = Unmanaged<Fence>.fromOpaque(info!).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        fence.reenable()
    case .keyDown:
        if fence.key(event) { return nil }
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
        fence.moved(event.location)
    default:
        fence.gesture(event)
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - Stage

/// A notch-free virtual display the size of the built-in one, and its live picture.
@MainActor
final class Stage: NSObject, SCStreamOutput, FenceDelegate {
    let bounds: CGRect
    let panel: CGRect
    let panelID: CGDirectDisplayID
    let id: CGDirectDisplayID
    /// Room above the panel's height, for windows that can't go full screen: macOS keeps them below
    /// this display's menu bar. 0 for windows that go full screen here.
    let extra: CGFloat
    let fence: Fence
    let feed: Feed
    /// How far down the stage the panel's picture starts: below the menu bar, where such a window sits.
    var top: CGFloat = 0 { didSet { fence.setTop(top) } }
    /// Where the picture starts right now: at the very top while the menu bar is out.
    var offset: CGFloat { fence.offsetNow }
    var onOffset: (() -> Void)?
    var onSwipe: ((Bool, Bool) -> Void)?
    var onExitKey: (() -> Void)?
    var onSystemKey: ((Bool) -> Void)?
    private let pixels: CGSize
    private let refreshRate: Double
    private var display: CGVirtualDisplay?
    private var stream: SCStream?
    /// The live picture starting, and whether it did.
    private(set) var capturing: Task<Bool, Never>?
    private var configuration: SCStreamConfiguration?
    private var interval = CMTime.zero
    private let frames = DispatchQueue(label: "TrueFullScreen.frames", qos: .userInteractive)

    static func open(on screen: NSScreen, serial: UInt32, extra: Int) async -> Stage? {
        guard let mode = CGDisplayCopyDisplayMode(screen.displayID) else { return nil }
        let scale = mode.pixelHeight / mode.height
        let (width, height, pixelWidth, pixelHeight, refreshRate) = (mode.width, mode.height + extra, mode.pixelWidth, mode.pixelHeight + extra * scale, mode.refreshRate)
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
        for _ in 0..<500 where CGDisplayIsActive(id) == 0 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        guard CGDisplayIsActive(id) != 0 else { return nil }

        // Touch the other displays only at a corner, so the pointer stays on whichever side it's put.
        // macOS remembers the spot, so after the first time it's already there.
        let others = activeDisplays().filter { $0 != id }.reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
        if CGDisplayBounds(id).origin != CGPoint(x: others.maxX, y: others.maxY) {
            var config: CGDisplayConfigRef?
            CGBeginDisplayConfiguration(&config)
            CGConfigureDisplayOrigin(config, id, Int32(others.maxX), Int32(others.maxY))
            CGCompleteDisplayConfiguration(config, .forSession)
        }
        // In place once it has a Space of its own: a stand-in can start growing then, the display no
        // longer moving anything about. Apps learn of it a while later.
        for _ in 0..<500 where currentSpace(on: id) == nil {
            try? await Task.sleep(for: .milliseconds(2))
        }

        let stage = Stage(display: display, panel: screen.displayID, extra: CGFloat(extra),
                          pixels: CGSize(width: pixelWidth, height: pixelHeight), refreshRate: refreshRate)
        // Capture gets going meanwhile: it isn't needed until the window is full screen there.
        stage.startCapture()
        return stage
    }

    private init(display: CGVirtualDisplay, panel: CGDirectDisplayID, extra: CGFloat, pixels: CGSize, refreshRate: Double) {
        self.display = display
        self.extra = extra
        self.pixels = pixels
        self.refreshRate = refreshRate
        panelID = panel
        self.panel = CGDisplayBounds(panel)
        id = display.displayID
        bounds = CGDisplayBounds(display.displayID)
        fence = Fence(panel: self.panel, bounds: bounds, others: activeDisplays().filter { $0 != display.displayID }.map(CGDisplayBounds))
        feed = Feed(panel: NSScreen.screens.first { $0.displayID == panel }?.colorSpace?.cgColorSpace)
        super.init()
        fence.delegate = self
        fence.install()
        // Every app learns of the display in its own time; this one knowing it, in place, is the earliest.
        let id = id
        known = Task {
            for _ in 0..<500 where !NSScreen.screens.contains(where: { $0.displayID == id && $0.frame == appKit(CGDisplayBounds(id)) }) {
                try? await Task.sleep(for: .milliseconds(2))
            }
            return .now
        }
    }

    /// When this app learned of the display.
    private var known: Task<ContinuousClock.Instant, Never>?

    /// Starts the live picture, unless it's running already.
    func startCapture() {
        guard capturing == nil else { return }
        capturing = Task { await capture() }
    }

    /// Stops the live picture, and with it macOS's recording mark.
    func stopCapture() {
        capturing?.cancel()
        capturing = nil
        let stream = stream
        self.stream = nil
        if let stream {
            try? stream.removeStreamOutput(self, type: .screen)
            stream.stopCapture()
        }
        // A stand-in on its way out keeps the frame it shows.
        feed.clear()
    }

    /// Starts the live picture. Returns whether it did.
    private func capture() async -> Bool {
        var target: SCDisplay?
        var windows: [SCWindow] = []
        for _ in 0..<100 where target == nil {
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            target = content?.displays.first { $0.displayID == id }
            windows = content?.windows ?? []
            if target == nil { try? await Task.sleep(for: .milliseconds(10)) }
        }
        guard let target, display != nil, !Task.isCancelled else { return false }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixels.width)
        configuration.height = Int(pixels.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(refreshRate, 60)))
        interval = configuration.minimumFrameInterval
        // The pointer is drawn on the panel directly, sooner than a frame could show it.
        configuration.showsCursor = false
        // Each stand-in not following the stage keeps the frame it shows, so a few windows in true
        // full screen at once still leave the stream frames to draw into.
        configuration.queueDepth = 4
        // Full color at every pixel, left in the stage's own colors, which are the panel's. Converting
        // them to Display P3 and back shifts dark grays a level, and the default, 4:2:0 video, halves
        // color detail.
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        self.configuration = configuration
        // The display's own desktop stays out of the picture: a window that doesn't fill it shows on
        // black, as in full screen, whatever the wallpaper. And macOS marks every display while it's
        // being captured: the panel shows its own mark, so the stage's stays out rather than show two.
        let bounds = bounds
        let desktop = Int(CGWindowLevelForKey(.desktopIconWindow))
        let leftOut = { (windows: [SCWindow]) in
            windows.filter { $0.frame.intersects(bounds) && ($0.windowLayer <= desktop || $0.title == "StatusIndicator") }
        }
        let excluded = leftOut(windows)
        let stream = SCStream(filter: SCContentFilter(display: target, excludingWindows: excluded), configuration: configuration, delegate: nil)
        guard (try? stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frames)) != nil,
              (try? await stream.startCapture()) != nil else {
            note("capture didn't start")
            return false
        }
        // Taken down or stopped meanwhile.
        guard display != nil, !Task.isCancelled else {
            try? await stream.stopCapture()
            return false
        }
        self.stream = stream
        // The mark, and anything of the desktop, can come a moment after the display does.
        Task { [weak self] in
            var left = excluded
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let stream = self?.stream else { return }
                let now = leftOut((try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).windows) ?? [])
                let new = now.filter { window in !left.contains { $0.windowID == window.windowID } }
                if !new.isEmpty {
                    left += new
                    try? await stream.updateContentFilter(SCContentFilter(display: target, excludingWindows: left))
                }
                if left.contains(where: { $0.title == "StatusIndicator" }) { return }
            }
        }
        return true
    }

    /// Waits until an app has surely caught up with the display coming online: a window landing on
    /// a display its app doesn't know yet can bring the app down.
    func settle(_ pid: pid_t) async {
        let born = await known?.value ?? .now
        try? await Task.sleep(until: born.advanced(by: .milliseconds(300)), clock: .continuous)
        await caughtUp(pid)
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        feed.publish(buffer)
    }

    /// The part of the stage the panel shows.
    var shown: CGRect { fence.shown }

    /// Whether the display is partway through moving between Spaces, which its picture would show.
    var isSwitching: Bool { isSwitchingSpaces(id) }

    /// Whether the display is all the way in a window's Space. The Space it shows changes only once
    /// a move there is through, whatever brought it about; the window server says it's moving only
    /// for some.
    func hasArrived(at window: CGWindowID) -> Bool {
        guard !isSwitching else { return false }
        let theirs = spaces(of: [window])
        guard let space = currentSpace(on: id), !theirs.isEmpty else { return true }
        return theirs.contains(space)
    }

    /// Where a window sized to fill goes: below the stage's menu bar, whether that's out or not.
    var fill: CGRect { CGRect(x: bounds.minX, y: bounds.minY + top, width: panel.width, height: panel.height) }

    /// Where a window that can't grow to fill goes: in the middle of where it would, on whole points.
    func centered(_ size: CGSize) -> CGPoint {
        CGPoint(x: fill.minX + max(0, ((fill.width - size.width) / 2).rounded()), y: fill.minY + max(0, ((fill.height - size.height) / 2).rounded()))
    }

    /// Where the stage's picture lands on a panel with the given frame, in AppKit's coordinates.
    func picture(over full: NSRect) -> NSRect {
        NSRect(x: full.minX, y: full.maxY + offset - bounds.height, width: bounds.width, height: bounds.height)
    }

    var isConfined: Bool { fence.isConfined }

    /// Moves the pointer onto the display and keeps it there, drawn on the panel, or back to the same
    /// spot on the panel.
    func hold(pointer on: Bool) {
        if on { fence.sprite.run(true) }
        fence.hold(on)
        if !on { fence.sprite.run(false) }
    }

    /// Slows capture to a trickle while nothing of the stage shows (Mission Control), sparing the
    /// work while the system animates, or brings it back to full speed.
    func idle(_ on: Bool) {
        guard let stream, let configuration else { return }
        configuration.minimumFrameInterval = on ? CMTime(value: 1, timescale: 2) : interval
        stream.updateConfiguration(configuration) { _ in }
    }

    /// Whether an app window still belongs to one of the display's Spaces, even one already moved
    /// off it: macOS moves a window's Space over a moment after the window itself.
    var holdsWindows: Bool { !holders.isEmpty }

    /// The app windows in the display's Spaces, by app, for the log.
    var holders: [String] {
        let theirs = spaces(on: id)
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { info -> String? in
            guard info[kCGWindowLayer as String] as? Int == 0, let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  let id = info[kCGWindowNumber as String] as? CGWindowID, !spaces(of: [id]).isDisjoint(with: theirs) else { return nil }
            return "\(app.bundleIdentifier ?? "?") \(id)"
        }
    }

    /// Whether the Dock is on the display: brought there from the bottom edge while in true full
    /// screen, it stays until it's brought somewhere else, or the display goes.
    var holdsDock: Bool {
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { info in
            info[kCGWindowOwnerName as String] as? String == "Dock" && info[kCGWindowName as String] as? String == "Dock"
                && windowBounds(info)?.intersects(bounds) == true
        }
    }

    /// Whether a window is showing on the display.
    func isShowing(_ window: CGWindowID) -> Bool {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, window) as? [[String: Any]])?.first,
              info[kCGWindowIsOnscreen as String] as? Bool == true, let rect = windowBounds(info) else { return false }
        return rect.intersects(bounds)
    }

    /// Takes it down. Once only: the lid closing can get here while it's already on its way out.
    func close() {
        guard display != nil else { return }
        hold(pointer: false)
        fence.uninstall()
        onOffset = nil
        onSwipe = nil
        onExitKey = nil
        onSystemKey = nil
        stopCapture()
        feed.clear()
        // The display goes away with its last reference, whatever still holds on to the stage.
        display = nil
    }

    // MARK: Fence

    func fenceMovedPicture() { onOffset?() }
    func fenceSwiped(_ started: Bool, vertical: Bool) { onSwipe?(started, vertical) }
    func fenceExitKey() { onExitKey?() }
    func fenceSystemKey(overview: Bool) { onSystemKey?(overview) }
}

// MARK: - Clicks

/// Watches for green-button clicks on the panel, on a thread of its own: every click on the Mac
/// waits for the answer, so it must never wait on anything else.
final class Clicks: @unchecked Sendable {
    struct State {
        var enabled = true
        var excluded: Set<String> = []
        /// Windows that get the app's own full screen.
        var ignored: [AXUIElement] = []
        /// Windows sized to fill the stage, whose green button brings them back.
        var sized: [AXUIElement] = []
        var panel: CGRect?
    }

    let state = Locked(State())
    /// Called on the main thread: a window to take over, its app, and whether it's sized to fill.
    var onTakeOver: ((AXUIElement, pid_t, Bool) -> Void)?
    var onLeave: ((AXUIElement) -> Void)?
    private var tap: CFMachPort?
    /// The click thread's.
    private var swallowMouseUp = false

    func install() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let clicks: [CGEventType] = [.leftMouseDown, .leftMouseUp]
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: clicks.reduce(0) { $0 | 1 << $1.rawValue },
                                callback: clickCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap { add([tap], to: clickLoop) }
    }

    /// Takes over green-button clicks on the notched display. Returns true to swallow the event.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseUp where swallowMouseUp:
            swallowMouseUp = false
            return true
        case .leftMouseDown:
            let state = state { $0 }
            let point = event.location
            // The green button of a window sized to fill the stage, which can't leave full screen on its own,
            // and its yellow one, which does nothing there, as in full screen.
            if !state.sized.isEmpty, nearWindowButtons(point) {
                let on = { (window: AXUIElement, button: String) in element(window, button).flatMap(frame(of:))?.contains(point) == true }
                if let window = state.sized.first(where: { on($0, kAXZoomButtonAttribute) }) {
                    swallowMouseUp = true
                    DispatchQueue.main.async { self.onLeave?(window) }
                    return true
                }
                if state.sized.contains(where: { on($0, kAXMinimizeButtonAttribute) }) {
                    swallowMouseUp = true
                    return true
                }
            }
            // Windows that can't be moved get the app's own full screen.
            guard let (window, pid, sized) = greenButtonWindow(at: event, state) else { return false }
            swallowMouseUp = true
            DispatchQueue.main.async { self.onTakeOver?(window, pid, sized) }
            return true
        default:
            break
        }
        return false
    }

    /// The window whose green button is under the click, and whether that button only zooms it, the
    /// window having no full screen of its own (Photoshop's): such a window is sized to fill instead.
    private func greenButtonWindow(at event: CGEvent, _ state: State) -> (AXUIElement, pid_t, Bool)? {
        let point = event.location
        var hit: AXUIElement?
        var pid: pid_t = 0
        guard state.enabled, !event.flags.contains(.maskAlternate), let panel = state.panel, panel.contains(point),
              nearWindowButtons(point),
              AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success, let hit
        else { return nil }
        let window = element(hit, kAXWindowAttribute) ?? hit
        let fullScreenButton = element(window, kAXFullScreenButtonAttribute)
        let sized = fullScreenButton == nil
        guard let button = fullScreenButton ?? element(window, kAXZoomButtonAttribute), frame(of: button)?.contains(point) == true,
              !sized || isStandardWindow(window) && isSettable(window, kAXSizeAttribute),
              !state.ignored.contains(where: { CFEqual($0, window) }),
              AXUIElementGetPid(window, &pid) == .success, pid != getpid(), !isFullScreen(window),
              let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, !state.excluded.contains(id),
              CGPreflightScreenCaptureAccess() else { return nil }
        return (window, pid, sized)
    }
}

private let clickCallback: CGEventTapCallBack = { _, type, event, info in
    let clicks = Unmanaged<Clicks>.fromOpaque(info!).takeUnretainedValue()
    return clicks.handle(type, event) ? nil : Unmanaged.passUnretained(event)
}

/// WindowServer events for windows appearing and disappearing, Mission Control's among them.
private let windowEvents: [UInt32] = [1325, 1326, 1508]

private typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void

private let windowServerEvent: NotifyProc = { _, _, _, info in
    guard let info else { return }
    let controller = Unmanaged<Controller>.fromOpaque(info).takeUnretainedValue()
    DispatchQueue.main.async { MainActor.assumeIsolated { controller.windowsChanged() } }
}

/// A target's window moved, resized, closed or retitled, or its app's focus moved.
private let accessibilityEvent: AXObserverCallback = { _, element, notification, info in
    guard let info else { return }
    let controller = Unmanaged<Controller>.fromOpaque(info).takeUnretainedValue()
    let resized = notification as String == kAXResizedNotification
    let focusMoved = notification as String == kAXFocusedWindowChangedNotification
    var pid: pid_t = 0
    if focusMoved { AXUIElementGetPid(element, &pid) }
    MainActor.assumeIsolated {
        // A full screen window resizes as it starts out of full screen: the picture holds still at once.
        if resized { controller.resized(element) }
        if focusMoved { controller.focusMoved(in: pid) }
        controller.soon()
    }
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
        /// A window that can't go full screen, sized to fill the stage below its menu bar instead.
        let sized: Bool
        /// Full screen there, or sized to fill: until then, its state is its way in, not a way out.
        var ready = false
        var leaving = false

        @MainActor func close() {
            standIn.close()
        }
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let defaults = UserDefaults.standard
    private let clicks = Clicks()
    private var targets: [Target] = [] { didSet { publish() } }
    private var entering: [AXUIElement] = []
    private var ignored: [AXUIElement] = [] { didSet { publish() } }
    private var stage: Stage?
    private var opening = false { didSet { if !opening { stageSettled() } } }
    private var closing = false { didSet { if !closing { stageSettled() } } }
    /// Waiting for the stage to be through coming or going.
    private var settling: [CheckedContinuation<Void, Never>] = []
    /// The stage on its way out wanted again (true), or in the way of a new one (false).
    private var wanted: Bool?
    /// The wait on its way out, cut short when it's wanted again.
    private var lingering: Task<Void, Never>?
    private var terminating = false
    private var missionControl = false
    private var swiping = false
    private var checking = false
    private var checkDue = false
    private var nextLook = DispatchTime(uptimeNanoseconds: 0)
    private var lookDue = false
    private var updateDue = false
    private var pending = false
    private var missionControlTimer: Timer?
    private var missionControlSince = Date.distantPast
    /// When Mission Control's windows were last seen gone, while it's thought up.
    private var missionControlGone: Date?
    /// Following Mission Control's zoom back into a full screen Space, and when it landed there.
    private var landing: Task<Void, Never>?
    private var landed: Date?
    /// A key for Mission Control or Spaces was pressed: the picture holds still until it's clear
    /// what it did.
    private var heldUntil = Date.distantPast
    /// A stand-in whose Space is on its way up, until when: nothing is handed back to the one before.
    private var revealing: (window: AXUIElement, until: Date)?
    private var nextFocus = Date.distantPast
    private var lastFocus: (window: AXUIElement, at: Date)?
    private var nextSweep = Date.distantPast
    /// Since when the stage has been moving between Spaces, and whether a look is due once it's through.
    private var switchingSince: Date?
    private var followDue = false
    /// Windows on the stage being looked for, and ones that couldn't be found, until when.
    private var rescuing: Set<CGWindowID> = []
    private var unfound: [CGWindowID: Date] = [:]
    private var lastLive: CGWindowID?
    private var heartbeat: Timer?
    private var observers: [pid_t: AXObserver] = [:]
    /// Where windows were when their app quit in full screen, by bundle ID, to put them back on relaunch.
    private var homes: [String: CGRect] = [:]
    private var termination: DispatchSourceSignal?

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled"); publish() }
    }

    private var excluded: Set<String> {
        get { Set(defaults.stringArray(forKey: "excluded") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "excluded"); publish() }
    }

    /// The virtual display stays once made, so going into true full screen needn't wait for one, nor
    /// for apps to catch up with it.
    private var keepsReady: Bool {
        get { defaults.bool(forKey: "ready") }
        set { defaults.set(newValue, forKey: "ready") }
    }

    /// Apps whose windows go into true full screen as they open.
    private var always: Set<String> {
        get { Set(defaults.stringArray(forKey: "always") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "always") }
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
        clicks.onTakeOver = { [weak self] window, pid, sized in
            Self.closeTilingMenuSoon()
            MainActor.assumeIsolated { _ = Task { await self?.takeOver(window, pid: pid, sized: sized) } }
        }
        clicks.onLeave = { [weak self] window in
            Self.closeTilingMenuSoon()
            MainActor.assumeIsolated { self?.leave(window, "green button") }
        }
        StandIn.onStill = { [weak self] in
            MainActor.assumeIsolated {
                if self?.updateDue == true { self?.update() }
            }
        }
        publish()
        clicks.install()

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

        getReady()

        // Mission Control isn't announced anywhere public; its windows coming and going give it away.
        if let register = dlsym(skyLight, "SLSRegisterConnectionNotifyProc") {
            typealias Register = @convention(c) (Int32, NotifyProc, UInt32, UnsafeMutableRawPointer?) -> Int32
            let register = unsafeBitCast(register, to: Register.self)
            for event in windowEvents {
                _ = register(connection, windowServerEvent, event, Unmanaged.passUnretained(self).toOpaque())
            }
        }
    }

    /// Makes the virtual display, if it's to be kept ready and there's none, and lets it wait there.
    private func getReady() {
        guard keepsReady, enabled, allowed, stage == nil, !opening, !closing, !terminating, let screen = NSScreen.notched else { return }
        Task {
            guard let made = await openStage(on: screen, sized: false), targets.isEmpty, entering.isEmpty else { return }
            note("virtual display \(made.id) kept ready")
            close(made)
        }
    }

    /// Closes macOS's tiling menu, now and as it may still come up for a moment after the click.
    private nonisolated static func closeTilingMenuSoon() {
        for delay in [0.0, 0.5, 1.0] {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { closeTilingMenu() }
        }
    }

    /// Tells the click thread what it needs to know.
    private func publish() {
        let panel = NSScreen.notched.map { CGDisplayBounds($0.displayID) }
        let (enabled, excluded, ignored) = (enabled, excluded, ignored)
        let sized = targets.filter { $0.sized && !$0.leaving }.map(\.window)
        clicks.state {
            $0.enabled = enabled
            $0.excluded = excluded
            $0.ignored = ignored
            $0.sized = sized
            $0.panel = panel
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
        guard stage != nil || opening || !entering.isEmpty else { return .terminateNow }
        terminating = true
        Task {
            // A window on its way over gets there first, so it's handed back with the rest.
            for _ in 0..<60 where opening || !entering.isEmpty {
                try? await Task.sleep(for: .milliseconds(50))
            }
            targets.forEach { release($0.window) }
            // Until the stage is down, every window off it first.
            for _ in 0..<240 where stage != nil || closing {
                update()
                try? await Task.sleep(for: .milliseconds(50))
            }
            stage?.close()
            note("quit")
            // Written before going, or the next launch takes this for an unclean stop and makes the
            // display anew, which macOS then remembers as one more display.
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            sender.reply(toApplicationShouldTerminate: true)
            // Everything's handed back by now: nothing is left to hold up going.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        item.button?.performClick(nil)
        return false
    }

    @objc private func screensChanged() {
        publish()
        targets.forEach { $0.standIn.pin() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.getReady() }
        // The panel went away (lid closed). With nothing left to show the stage on, macOS would move
        // every window and Space onto it, so take it down at once.
        guard let stage, CGDisplayIsOnline(stage.panelID) == 0 || CGDisplayBounds(stage.panelID) != stage.panel else { return }
        for target in targets {
            if target.sized { setSize(target.window, target.home.size) } else { setFullScreen(target.window, false) }
            drop(target, "panel gone")
        }
        beat(false)
        stage.close()
        if self.stage === stage { self.stage = nil }
        retireDisplay()
        defaults.set(false, forKey: "staged")
    }

    @objc private func accessibilityChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.clicks.install() }
    }

    // MARK: Full screen

    /// Windows already handled, on their way, or left alone because they couldn't be moved.
    private func isBusy(_ window: AXUIElement) -> Bool {
        [targets.map(\.window), entering, ignored].contains { $0.contains { CFEqual($0, window) } }
    }

    /// Moves a window to the stage and takes it full screen there, while its stand-in grows out of
    /// it into a full screen Space on the panel, so nothing blinks or jumps along the way.
    private func takeOver(_ window: AXUIElement, pid: pid_t, sized: Bool) async {
        guard !terminating, !isBusy(window), let screen = NSScreen.notched else { return }
        entering.append(window)
        defer { entering.removeAll { CFEqual($0, window) } }
        let clicked = ContinuousClock.now
        let elapsed = { "\(Int(clicked.duration(to: .now) / .milliseconds(1))) ms" }
        let app = NSRunningApplication(processIdentifier: pid)
        // One that keeps a size of its own, as System Settings does its width, isn't meant to cover the
        // screen, and has what matters along its top, where the notch would be: its green button does
        // what it always does, now and from then on.
        if sized, await apart({ keepsItsSize(window) }) {
            note("leave \(app?.bundleIdentifier ?? "?") its own zoom: it keeps its size")
            ignored.append(window)
            element(window, kAXZoomButtonAttribute).map { _ = AXUIElementPerformAction($0, kAXPressAction as CFString) }
            return
        }
        note("take over \(app?.bundleIdentifier ?? "?")\(sized ? ", sized to fill" : "")")
        // Already in the app's own full screen (keyboard, menu): come out of it first.
        if isFullScreen(window) { await leaveFullScreen(window) }
        if let id = app?.bundleIdentifier, let home = homes.removeValue(forKey: id) { await place(window, at: home.origin) }
        guard let home = frame(of: window) else { return }
        let id = windowID(of: window)
        let before = spaces(of: [id])
        // Pictured meanwhile, off the main thread.
        async let image = picture(of: id)
        // The display comes online first, before anything shows: it moves windows about as it does,
        // and would stall an animation. Then the window goes full screen there while the stand-in
        // grows into its Space.
        guard let stage = await openStage(on: screen, sized: sized) else { return await giveUp(window, id: id, sized: sized) }
        let standIn = StandIn(screen: screen, over: home, image: await image, title: app?.localizedName ?? "", feed: stage.feed)
        note("growing after \(elapsed())")
        async let entered = standIn.enter()
        await stage.settle(pid)
        if sized {
            if stage.top == 0 {
                // macOS keeps the window below this display's menu bar: where it ends up is where the
                // picture starts.
                let (size, origin) = (stage.panel.size, stage.bounds.origin)
                await apart {
                    setSize(window, size)
                    move(window, to: origin)
                }
                try? await Task.sleep(for: .milliseconds(60))
                let menuBar = NSScreen.screens.first { $0.displayID == stage.id }.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0
                let top = await apart { frame(of: window)?.minY }
                stage.top = max(menuBar, (top ?? stage.bounds.minY) - stage.bounds.minY)
            }
            await fit(window, into: stage.fill)
            // One that can't fill it goes in the middle, on black, as it would in full screen.
            if let size = await apart({ frame(of: window)?.size }), stage.fill.width - size.width >= 2 || stage.fill.height - size.height >= 2 {
                await place(window, at: stage.centered(size))
            }
        } else {
            await place(window, at: home.origin - stage.panel.origin + stage.bounds.origin)
        }
        let placed = await apart { frame(of: window) }
        let moved = placed.map { sized ? $0.width < stage.fill.width + 2 && $0.height < stage.fill.height + 2
                                           && hypot($0.minX - stage.centered($0.size).x, $0.minY - stage.centered($0.size).y) < 2
                                       : stage.bounds.contains($0.origin) } ?? false
        if sized, let placed { standIn.lands = placed.offsetBy(dx: -stage.bounds.minX, dy: -stage.bounds.minY) }
        // Only once it's in a Space there does it go full screen.
        guard moved, await settled(id, on: stage.id, from: before) else {
            note("won't move there: at \(frame(of: window).map { "\($0)" } ?? "?"), Spaces \(spaces(of: [id]))")
            setSize(window, home.size)
            move(window, to: home.origin)
            _ = await entered
            standIn.close()
            return await giveUp(window, id: id, sized: sized)
        }
        await caughtUp(pid)
        targets.append(Target(pid: pid, app: app?.bundleIdentifier, window: window, id: id, home: home, standIn: standIn, sized: sized))
        await observe(window, pid: pid)
        beat(true)
        let desk = spaces(of: [id])
        let started = ContinuousClock.now
        let went = sized ? true : await goFullScreen(window)
        // No Space for it on the panel, or it won't go full screen there: back out. One that says it
        // won't, rather than being too busy to say, gets what its green button does next time.
        let inSpace = await entered
        if !went, fullScreen(window) == false { ignored.append(window) }
        guard went, inSpace else { return leave(window, went ? "no Space on the panel" : "won't go full screen") }
        // Its own way into full screen there, out of sight, takes at least this long, and lasts until the
        // display is all the way in the window's own Space, which it shows only once the way in is over.
        try? await Task.sleep(until: started.advanced(by: .milliseconds(sized ? 100 : 250)), clock: .continuous)
        let inOwnSpace = { sized || desk.isEmpty || !spaces(of: [id]).isSubset(of: desk) && stage.hasArrived(at: id) }
        while !inOwnSpace(), started.duration(to: .now) < .seconds(1) {
            try? await Task.sleep(for: .milliseconds(4))
        }
        // Nothing to show it with: back out.
        guard await stage.capturing?.value == true else { return leave(window, "no picture") }
        if let index = targets.firstIndex(where: { CFEqual($0.window, window) }) { targets[index].ready = true }
        note("in true full screen: \(app?.bundleIdentifier ?? "?") after \(elapsed()), the panel's way in taking \(Int(standIn.enterDuration * 1000)) ms")
        entering.removeAll { CFEqual($0, window) }
        // The picture goes up first: asking the app anything can take a while.
        follow(now: true)
        CATransaction.flush()
        if standIn.isCurrent, !justFocused(window) {
            lastFocus = (window, Date())
            focus(window, pid: pid)
        }
        update()
    }

    /// The app won't move, so it gets what its green button would have done, once its window is
    /// back in a Space of the panel.
    private func giveUp(_ window: AXUIElement, id: CGWindowID, sized: Bool) async {
        note("give up: the app's own \(sized ? "zoom" : "full screen")")
        ignored.append(window)
        if let screen = NSScreen.notched { _ = await settled(id, on: screen.displayID, from: spaces(of: [id])) }
        if sized {
            element(window, kAXZoomButtonAttribute).map { _ = AXUIElementPerformAction($0, kAXPressAction as CFString) }
        } else {
            setFullScreen(window, true)
        }
        entering.removeAll { CFEqual($0, window) }
        update()
    }

    /// Takes a window out of true full screen: out of full screen on the stage, which brings it home,
    /// or for one sized to fill, home directly.
    private func release(_ window: AXUIElement) {
        guard let target = targets.first(where: { CFEqual($0.window, window) }) else { return }
        if target.sized || !target.ready { leave(window, "released") } else { setFullScreen(window, false) }
    }

    private func leave(_ window: AXUIElement, _ why: String) {
        guard let index = targets.firstIndex(where: { CFEqual($0.window, window) }), !targets[index].leaving else { return }
        note("leave \(targets[index].app ?? "?"): \(why)")
        targets[index].leaving = true
        let target = targets[index]
        Task { await bringHome(target) }
    }

    private func stageSettled() {
        let settling = settling
        self.settling = []
        settling.forEach { $0.resume() }
    }

    private func openStage(on screen: NSScreen, sized: Bool) async -> Stage? {
        // One on its way out stays if it's the right kind, or goes now to make way.
        if closing, let stage {
            wanted = (stage.extra > 0) == sized
            lingering?.cancel()
        }
        while opening || closing { await withCheckedContinuation { settling.append($0) } }
        // One kind at a time: windows sized to fill need a taller stage than full screen ones.
        if let stage {
            guard (stage.extra > 0) == sized else { return nil }
            note("virtual display \(stage.id) reused")
            stage.startCapture()
            return stage
        }
        opening = true
        defer { opening = false }
        guard let made = await Stage.open(on: screen, serial: serial, extra: sized ? 64 : 0) else {
            note("no virtual display")
            return nil
        }
        note("virtual display \(made.id) at \(made.bounds)")
        made.onOffset = { [weak self, weak made] in
            guard let self, let made else { return }
            // Not one on its way out, whose picture shrinks from just where it was: the menu bar going as
            // it starts would move the band at once and the rest a few frames later.
            for target in targets where !target.leaving { target.standIn.picture = made.picture(over: target.standIn.full) }
        }
        made.onExitKey = { [weak self] in
            guard let self, let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  let target = targets.first(where: { $0.sized && !$0.leaving && $0.pid == front && $0.standIn.isCurrent }) else { return }
            leave(target.window, "⌃⌘F")
        }
        made.onSwipe = { [weak self] on, vertical in self?.swiped(on, vertical: vertical) }
        made.onSystemKey = { [weak self] overview in self?.systemKey(overview: overview) }
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
            await takeOver(window, pid: app.processIdentifier, sized: false)
        }
    }

    /// Brings a window back to the panel once it has left full screen on the stage. Its stand-in
    /// shrinks back to where the window goes meanwhile, ending on a picture of it.
    private func bringHome(_ target: Target) async {
        let started = ContinuousClock.now
        let elapsed = { "\(Int(started.duration(to: .now) / .milliseconds(1))) ms" }
        target.standIn.hold()
        stage?.hold(pointer: false)
        // The stand-in starts home at once; a window still full screen there (quitting, switched off,
        // on its way in) is taken out meanwhile, its app being too busy to answer quickly then.
        async let left = target.standIn.leave(to: target.home)
        if target.sized { await apart { setSize(target.window, target.home.size) } } else { await outOfFullScreen(target.window) }
        for _ in 0..<30 {
            if let size = await apart({ frame(of: target.window)?.size }), abs(size.width - target.home.width) < 2,
               abs(size.height - target.home.height) < 2 { break }
            try? await Task.sleep(for: .milliseconds(30))
        }
        note("home: sized back after \(elapsed())")
        // Its own picture, as it is out of full screen, for the end of the way out. The window can be
        // pictured only once its own way out on the stage is over, about when the stand-in's is, so
        // it's asked again until it can, and takes the stand-in's place only once that's faded in.
        var landed: ContinuousClock.Instant?
        for _ in 0..<60 {
            if let image = await picture(of: target.id, quick: true) {
                let (size, scale) = (target.home.size, NSScreen.notched?.backingScaleFactor ?? 2)
                let image = await apart { trimmed(image, to: size, scale: scale) }
                landed = .now + .milliseconds(Int(target.standIn.land(image) * 1000))
                break
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        note("home: \(landed == nil ? "no picture of the window" : "pictured") after \(elapsed())")
        _ = await left
        note("home: stand-in out after \(elapsed())")
        // An app too busy to answer before may have gone full screen there since.
        if !target.sized { await outOfFullScreen(target.window) }
        await place(target.window, at: target.home.origin)
        note("home: placed after \(elapsed())")
        if let screen = NSScreen.notched { _ = await settled(target.id, on: screen.displayID, from: spaces(of: [target.id])) }
        note("home: in a panel Space after \(elapsed())")
        // On no Space at all, it couldn't be seen or reached: a trip to the Dock puts it on the current one.
        if target.id != 0, spaces(of: [target.id]).isEmpty {
            AXUIElementSetAttributeValue(target.window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            try? await Task.sleep(for: .milliseconds(300))
            AXUIElementSetAttributeValue(target.window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        if let landed { try? await Task.sleep(until: landed, clock: .continuous) }
        focus(target.window, pid: target.pid)
        // The stand-in goes once the window is in front of it, so nothing behind shows in between.
        for _ in 0..<40 where !target.standIn.isCovered(by: target.id) {
            try? await Task.sleep(for: .milliseconds(8))
        }
        note("home: in front after \(elapsed())")
        drop(target, "home")
        update()
    }

    /// Lets go of a target: its stand-in and title bar go, and so does its app's observer with its last.
    private func drop(_ target: Target, _ why: String) {
        note("drop \(target.app ?? "?"): \(why)")
        target.close()
        targets.removeAll { CFEqual($0.window, target.window) }
        guard !targets.contains(where: { $0.pid == target.pid }), let observer = observers.removeValue(forKey: target.pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    /// Hears about a target's window moving, resizing, closing or retitling, and its app's focus moving.
    private func observe(_ window: AXUIElement, pid: pid_t) async {
        let info = Unmanaged.passUnretained(self).toOpaque()
        if observers[pid] == nil {
            var made: AXObserver?
            guard AXObserverCreate(pid, accessibilityEvent, &made) == .success, let made else { return }
            observers[pid] = made
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), .commonModes)
            await apart { _ = AXObserverAddNotification(made, AXUIElementCreateApplication(pid), kAXFocusedWindowChangedNotification as CFString, info) }
        }
        guard let observer = observers[pid] else { return }
        await apart {
            for name in [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification, kAXTitleChangedNotification] {
                AXObserverAddNotification(observer, window, name as CFString, info)
            }
        }
    }

    /// Looks again a few times a second while anything is in true full screen, in case something
    /// changed that nothing announced. Only cheap questions, none to the apps.
    private func beat(_ on: Bool) {
        if on, heartbeat == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.follow() } }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            heartbeat = timer
        } else if !on {
            heartbeat?.invalidate()
            heartbeat = nil
        }
    }

    /// Moves windows that ended up on the stage without going full screen back to the panel: one an
    /// app opened there while the stage had the window in front, say. Found through the window
    /// server, since Accessibility leaves out windows in Spaces not showing. Returns whether any were.
    @discardableResult
    private func sweep(_ stage: Stage) -> Bool {
        let handled = Set(targets.map(\.id) + entering.map(windowID(of:)))
        // The targets' own full screen Spaces, title bars and all, stay as they are.
        let theirs = spaces(of: targets.map(\.id))
        let there = spaces(on: stage.id)
        var found = false
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            // Ordinary app windows mostly on the stage: other apps keep helper windows out of sight
            // beyond the displays on purpose.
            guard info[kCGWindowLayer as String] as? Int == 0, let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let id = info[kCGWindowNumber as String] as? CGWindowID, !handled.contains(id),
                  let rect = windowBounds(info), rect.width > 50, rect.height > 50,
                  stage.bounds.contains(CGPoint(x: rect.midX, y: rect.midY)),
                  NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular else { continue }
            // In a Space there that's no target's: windows on their way off are in none.
            let now = spaces(of: [id])
            guard !now.isEmpty, now.isDisjoint(with: theirs), there.isEmpty || !now.isDisjoint(with: there) else { continue }
            found = true
            if let window = windows(of: pid).first(where: { windowID(of: $0) == id }) {
                send(window, pid: pid, from: rect, stage)
            } else {
                rescue(id, of: pid, from: rect, stage)
            }
        }
        return found
    }

    /// Sends a window on the stage to the same spot on the panel, out of full screen first.
    private func send(_ window: AXUIElement, pid: pid_t, from rect: CGRect, _ stage: Stage) {
        guard isStandardWindow(window) else { return }
        let app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?"
        if isFullScreen(window) {
            note("sweep \(app): out of full screen at \(rect)")
            setFullScreen(window, false)
        } else {
            note("sweep \(app): to the panel from \(rect)")
            move(window, to: rect.origin - stage.bounds.origin + stage.panel.origin)
            // Opened there by the app in front: in front on the panel, where it was meant to be.
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { focus(window, pid: pid) }
        }
    }

    /// Finds a window that Accessibility doesn't list by its number, off the main thread, since that
    /// asks its app many times over, then sends it to the panel. Not again for a while if it fails.
    private func rescue(_ id: CGWindowID, of pid: pid_t, from rect: CGRect, _ stage: Stage) {
        guard !rescuing.contains(id), (unfound[id] ?? .distantPast) < Date() else { return }
        rescuing.insert(id)
        DispatchQueue.global(qos: .userInitiated).async {
            let window = hiddenWindow(id, of: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.rescuing.remove(id)
                    guard let window else {
                        note("sweep: window \(id) not found")
                        self.unfound[id] = Date().addingTimeInterval(10)
                        return
                    }
                    if self.stage === stage { self.send(window, pid: pid, from: rect, stage) }
                }
            }
        }
    }

    /// Takes the stage down, once nothing is left on it: a window on a display that disappears
    /// can end up nowhere. The picture stops at once, but the display stays a while: every app has
    /// to keep up with a display coming and going, and one going full screen again soon reuses it.
    private func close(_ stage: Stage) {
        guard !closing else { return }
        closing = true
        beat(false)
        stage.hold(pointer: false)
        // ⌃⌘F goes back to every app.
        stage.fence.armExit(false)
        Task {
            var tries = 0
            while tries < 25, sweep(stage) || stage.holdsWindows {
                tries += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
            note("virtual display \(stage.id) empty after \(tries) looks\(tries == 25 ? ", still holding \(stage.holders)" : "")")
            stage.stopCapture()
            let since = ContinuousClock.now
            var lastSweep = since
            // Not with the Dock there, out of sight: it comes back with the display gone.
            var dock = stage.holdsDock
            while wanted == nil, self.stage === stage, !dock, !terminating, keepsReady && enabled || since.duration(to: .now) < .seconds(15) {
                let nap = Task { _ = try? await Task.sleep(for: .milliseconds(50)) }
                lingering = nap
                await nap.value
                lingering = nil
                // Anything that lands there meanwhile goes back.
                if lastSweep.duration(to: .now) > .seconds(1) {
                    lastSweep = .now
                    sweep(stage)
                    dock = stage.holdsDock
                }
            }
            defer { wanted = nil }
            if wanted == true, self.stage === stage {
                closing = false
                return
            }
            tries = 0
            while tries < 25, sweep(stage) || stage.holdsWindows {
                tries += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
            note("virtual display \(stage.id) goes\(dock ? ", the Dock being there" : "")")
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
              let id = app.bundleIdentifier else { return }
        if always.contains(id) { Task { await takeOverAsItOpens(app) } }
        guard let home = homes[id] else { return }
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

    /// The first window of an app that's always in true full screen, once it's open and settled in:
    /// where a window that was full screen when the app quit goes back first.
    private func takeOverAsItOpens(_ app: NSRunningApplication) async {
        let pid = app.processIdentifier
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            guard !app.isTerminated else { return }
            if let id = app.bundleIdentifier, homes[id] != nil { continue }
            guard let window = await apart({ element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute) }),
                  await apart({ isStandardWindow(window) }) else { continue }
            // Its app may still be bringing it in.
            try? await Task.sleep(for: .milliseconds(500))
            return await takeOverOnItsOwn(window, pid: pid)
        }
    }

    /// What a window's green button would do, for one of an app that's always in true full screen. Not
    /// one that keeps a size of its own, which its green button would only zoom.
    private func takeOverOnItsOwn(_ window: AXUIElement, pid: pid_t) async {
        guard enabled, allowed, !terminating, !isBusy(window), let screen = NSScreen.notched,
              let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, !excluded.contains(id) else { return }
        let panel = CGDisplayBounds(screen.displayID)
        let sized: Bool? = await apart {
            guard isStandardWindow(window), !isFullScreen(window), let rect = frame(of: window),
                  panel.contains(CGPoint(x: rect.midX, y: rect.midY)) else { return nil }
            if element(window, kAXFullScreenButtonAttribute) != nil { return false }
            guard element(window, kAXZoomButtonAttribute) != nil, isSettable(window, kAXSizeAttribute), !keepsItsSize(window) else { return nil }
            return true
        }
        guard let sized else { return }
        note("always: \(id)")
        await takeOver(window, pid: pid, sized: sized)
    }

    @objc private func activated(_ notification: Notification) {
        // Switched to from elsewhere (⌘Tab, the Dock): its Space comes up, as any full screen app's does.
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, !missionControl, !swiping {
            let candidates = targets.filter { $0.pid == app.processIdentifier && $0.ready && !$0.leaving }
            if !candidates.isEmpty {
                Task {
                    guard let target = await focused(among: candidates), !target.standIn.isCurrent, !missionControl, !swiping else { return }
                    target.standIn.reveal()
                    // Its Space takes a moment to come up, meanwhile the one before is still current.
                    revealing = (target.window, Date().addingTimeInterval(1.5))
                }
            }
        }
        update()
    }

    /// An app in front went to one of its windows in true full screen (its Window menu, ⌘`), from a
    /// desktop or another of its windows there: that window's Space comes up at once, as a full screen
    /// window's would, rather than once the stage has got there.
    fileprivate func focusMoved(in pid: pid_t) {
        // Not while one is on its way in or out, which moves the app's focus about by itself.
        let elsewhere = { [self] in
            entering.isEmpty && StandIn.moving == 0 && targets.allSatisfy { !$0.leaving && (!$0.standIn.isCurrent || $0.pid == pid) }
        }
        guard !missionControl, !swiping, Date() >= heldUntil, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              elsewhere() else { return }
        let candidates = targets.filter { $0.pid == pid && $0.ready && !$0.leaving }
        guard !candidates.isEmpty else { return }
        Task {
            guard let target = await focused(among: candidates), !target.standIn.isCurrent, !missionControl, !swiping,
                  elsewhere() else { return }
            note("reveal \(target.app ?? "?"): its app went to it")
            target.standIn.reveal()
            revealing = (target.window, Date().addingTimeInterval(1.5))
        }
    }

    /// A target's window resized: out of full screen there, it goes home now rather than in a moment,
    /// before the stage shows much of its way out.
    fileprivate func resized(_ window: AXUIElement) {
        guard let target = targets.first(where: { CFEqual($0.window, window) }), target.ready, !target.sized, !target.leaving else { return }
        Task {
            // Asked off the main thread: its app may be busy with another of its windows, and waiting on
            // it would stall a stand-in on its way in or out.
            guard await apart({ fullScreen(window) }) == false else { return }
            leave(window, "out of full screen")
        }
    }

    /// Which of these windows has the keyboard in its app, asked off the main thread.
    private func focused(among candidates: [Target]) async -> Target? {
        let windows = candidates.map { ($0.window, $0.pid) }
        guard let index = await apart({ windows.firstIndex { isFocused($0.0, pid: $0.1) } }) else { return nil }
        let window = candidates[index].window
        return targets.first { CFEqual($0.window, window) && $0.ready && !$0.leaving }
    }

    /// One update for a burst of changes.
    fileprivate func soon() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            pending = false
            update()
        }
    }

    @objc private func update() {
        // The picture follows a Space change at once; the apps are asked about their windows after.
        follow(now: true)
        CATransaction.flush()
        // Not while a stand-in is on its way in or out: asking a busy app would stall it. Once it's there.
        guard StandIn.moving == 0 else {
            updateDue = true
            return
        }
        updateDue = false
        for target in targets where isGone(target.window, of: target.pid) {
            // Closed, or its app quit: its Space goes with it.
            if NSRunningApplication(processIdentifier: target.pid) == nil, let app = target.app { homes[app] = target.home }
            drop(target, "gone")
        }
        // Out of full screen there, from its own menu or keyboard: home it goes. Not while its app is
        // too busy to say.
        for target in targets where target.ready && !target.sized && !target.leaving && fullScreen(target.window) == false {
            leave(target.window, "out of full screen")
        }
        // Nothing that could move windows about while Mission Control is up.
        if !missionControl { adoptFullScreenWindow() }

        guard let stage, entering.isEmpty, !closing else { return }
        // A window moved to another display from its green button menu stays there.
        for target in targets where target.ready && !target.leaving {
            guard let rect = frame(of: target.window), !rect.intersects(stage.bounds) else { continue }
            ignored.append(target.window)
            drop(target, "moved off the stage to \(rect)")
        }
        if !missionControl { sweep(stage) }
        if targets.isEmpty { return close(stage) }

        if !missionControl, missionControlIsOpen() { missionControlOpened(late: true) }
        refreshOpenings()
        // Where a window sized there is, should it have been moved there: its way out starts from it.
        for target in targets where target.sized && target.ready && !target.leaving {
            if let rect = frame(of: target.window) { target.standIn.lands = rect.offsetBy(dx: -stage.bounds.minX, dy: -stage.bounds.minY) }
        }
        follow(now: true)
    }

    /// Picks the stand-in that follows the stage: the one whose Space is up, while the stage shows
    /// its window. The stage is shown only then, so a Space change or Mission Control there is never
    /// seen. `now` when something just happened, rather than on the heartbeat.
    private func follow(now: Bool = false) {
        guard let stage, entering.isEmpty, !closing else { return }
        let hidden = { (target: Target) in NSRunningApplication(processIdentifier: target.pid)?.isHidden == true }
        // Hidden with its app (⌘H): it goes from the panel, as the app's own full screen would.
        if !targets.isEmpty, targets.allSatisfy(hidden), !NSApp.isHidden { NSApp.hide(nil) }
        var live: Target?
        if let (window, until) = revealing {
            if Date() > until || targets.contains(where: { CFEqual($0.window, window) && $0.standIn.isCurrent }) {
                revealing = nil
            } else {
                targets.forEach { $0.standIn.hold() }
                return
            }
        }
        // The keyboard is passed on once the picture is sorted out: asking an app anything can take a while.
        var handOff: (() -> Void)?
        if !missionControl, Date() >= heldUntil, let current = targets.first(where: { $0.ready && !$0.leaving && $0.standIn.isCurrent }) {
            let showing = stage.isShowing(current.id)
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let ours = front == getpid()
            if !swiping, !hidden(current), ours || !showing && front == current.pid, now && !justFocused(current.window) || Date() >= nextFocus {
                // Its Space coming up hands the keyboard to this app, or the stage moved off the window
                // while its app is in front: pass the keyboard on, which brings the window back there too.
                nextFocus = Date().addingTimeInterval(ours ? 0.5 : 1)
                lastFocus = (current.window, Date())
                let others = ours ? [] : targets.filter { $0.pid == current.pid && !CFEqual($0.window, current.window) && $0.ready && !$0.leaving }
                handOff = { [self] in
                    guard !others.isEmpty else {
                        note("focus \(current.app ?? "?"): \(ours ? "its Space came up" : "the stage moved off it")")
                        return focus(current.window, pid: current.pid)
                    }
                    Task {
                        if let other = await focused(among: others), !other.standIn.isCurrent {
                            // Its app went to another of its windows in true full screen (⌘`, its Window menu):
                            // that one's Space comes up, as it would in full screen, rather than being pulled back.
                            note("reveal \(other.app ?? "?"): its app went to another window")
                            other.standIn.reveal()
                            revealing = (other.window, Date().addingTimeInterval(1.5))
                        } else {
                            note("focus \(current.app ?? "?"): the stage moved off it")
                            focus(current.window, pid: current.pid)
                        }
                    }
                }
            } else if !swiping, !showing, !ours, front != current.pid, Date() >= nextSweep {
                // Another app opened a window on the stage, where windows open beside the one in front:
                // it goes to the panel, in front, as it would from the app's own full screen. Never
                // pulled back from that app.
                nextSweep = Date().addingTimeInterval(0.5)
                soon()
            }
            // Not while the stage moves to its Space, from another window's (one in true full screen
            // switched to): only once it's there. One already following it keeps on.
            if showing, current.standIn.isLive || !stageArriving(stage, at: current.id) {
                switchingSince = nil
                live = current
            } else if !showing, stage.hasArrived(at: current.id) {
                // The window is said to be on screen a moment after the stage gets to its Space.
                _ = lookAgainSoon()
            }
        }
        for target in targets {
            if let live, CFEqual(live.window, target.window) {
                target.standIn.picture = stage.picture(over: target.standIn.full)
                target.standIn.goLive()
            } else {
                target.standIn.hold()
            }
        }
        if live?.id != lastLive {
            lastLive = live?.id
            note(live.map { "live: \($0.app ?? "?")" } ?? "held")
        }
        // The pointer stays on the panel through a swipe, where the Dock looks for it.
        let confine = live != nil && !swiping
        if now || confine != stage.isConfined { stage.hold(pointer: confine) }
        stage.fence.armExit(live?.sized == true && NSWorkspace.shared.frontmostApplication?.processIdentifier == live?.pid)
        guard let handOff else { return }
        // On screen now, rather than once the app has answered.
        CATransaction.flush()
        handOff()
    }

    /// Whether a window was handed the keyboard a moment ago: several things announce the same
    /// Space coming up, and it's handed over once.
    private func justFocused(_ window: AXUIElement) -> Bool {
        lastFocus.map { CFEqual($0.window, window) && Date().timeIntervalSince($0.at) < 0.3 } ?? false
    }

    /// Whether the stage is still on its way to a window's Space, in which case it's looked at again
    /// in a moment. Never for long: after a second it's taken to be there.
    private func stageArriving(_ stage: Stage, at window: CGWindowID) -> Bool {
        guard !stage.hasArrived(at: window) else {
            switchingSince = nil
            return false
        }
        return lookAgainSoon()
    }

    /// Follows again in a moment, for up to a second of waiting. Returns whether it will.
    private func lookAgainSoon() -> Bool {
        let since = switchingSince ?? Date()
        switchingSince = since
        guard Date().timeIntervalSince(since) < 1 else { return false }
        if !followDue {
            followDue = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(4)) { [self] in
                followDue = false
                follow()
            }
        }
        return true
    }

    /// A swipe between Spaces moves the panel's, leaving the stage as it is: the picture stays live.
    /// Up or down brings Mission Control or App Exposé, which the stage would show too.
    private func swiped(_ on: Bool, vertical: Bool) {
        swiping = on
        if on, vertical {
            missionControlOpened(late: false)
        } else if !on {
            // A cancelled swipe leaves the Space as it was, with nothing else to say so.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.update() }
        }
    }

    /// A key for Mission Control or Spaces: hold the picture still until it's clear what it did, so
    /// whatever the stage shows meanwhile is never seen.
    private func systemKey(overview: Bool) {
        heldUntil = Date().addingTimeInterval(0.6)
        targets.forEach { $0.standIn.hold() }
        // Mission Control would show the band over everything; a Space slides away with it in.
        if overview { targets.forEach { $0.standIn.showBand(false) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { self.update() }
    }

    // MARK: Mission Control

    /// Mission Control shows the panel's Spaces, the stand-ins' among them, so let the pointer
    /// go there and keep the stage's own Mission Control out of the picture.
    fileprivate func windowsChanged() {
        guard !closing, stage != nil else { return }
        lookForMissionControl()
        guard !checking else { return }
        // One look per burst of window changes: each asks WindowServer, which has animations to draw.
        checking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            checking = false
            if missionControl { return }
            refreshOpenings()
            if missionControlIsOpen() { missionControlOpened(late: true) }
            // A window that just opened may have opened on the stage.
            if let stage, entering.isEmpty, !closing, !missionControl { sweep(stage) }
        }
    }

    /// Mission Control coming up shows on the stage too, so its windows are looked for as they come,
    /// at most a frame or two apart, rather than once they're all there. And as they go, so the top
    /// strip is back the moment it's over.
    private func lookForMissionControl() {
        guard !closing, stage != nil else { return }
        let now = DispatchTime.now()
        if now < nextLook {
            guard !lookDue else { return }
            lookDue = true
            DispatchQueue.main.asyncAfter(deadline: nextLook) { [self] in
                lookDue = false
                lookForMissionControl()
            }
            return
        }
        nextLook = now + .milliseconds(16)
        if missionControl {
            checkMissionControl()
        } else if missionControlIsOpen() {
            missionControlOpened(late: true)
        }
    }

    /// Other apps' windows on the panel (notifications, alerts, the Dock), which can only be over
    /// the stand-ins, there being nothing else in their Spaces.
    private func refreshOpenings() {
        guard let stage else { return }
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        stage.fence.setOpenings(windows.compactMap { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t != getpid(), info[kCGWindowOwnerName as String] as? String != "Window Server",
                  (info[kCGWindowLayer as String] as? Int ?? -1) >= 0, (info[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                  let rect = windowBounds(info), rect.intersects(stage.panel) else { return nil }
            return rect.intersection(stage.panel)
        })
    }

    /// Freezes the stand-ins and lets the pointer go to the panel. `late` when it's seen by its windows
    /// rather than a key or a swipe, which is usually still before anything of it shows. A picture of
    /// the window taken then would be too late: the stage's Mission Control is shrinking it by then.
    private func missionControlOpened(late: Bool) {
        guard !missionControl else { return }
        note("Mission Control\(late ? ", seen late" : "")")
        missionControl = true
        missionControlGone = nil
        missionControlSince = Date()
        landed = nil
        targets.forEach { $0.standIn.showBand(false) }
        targets.forEach { $0.standIn.hold() }
        stage?.hold(pointer: false)
        stage?.idle(true)

        // Its windows going away says when it's over; this is in case that's missed.
        missionControlTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkMissionControl() } }
        RunLoop.main.add(timer, forMode: .common)
        missionControlTimer = timer
    }

    private func checkMissionControl() {
        guard missionControl, !swiping else { return }
        // A swipe up gets here before Mission Control's windows do, and nothing is asked while it opens:
        // it's looked at again once that's through, in case it's already over by then.
        let opening = 0.4 - Date().timeIntervalSince(missionControlSince)
        guard opening <= 0 else {
            if !checkDue {
                checkDue = true
                DispatchQueue.main.asyncAfter(deadline: .now() + opening) { [self] in
                    checkDue = false
                    checkMissionControl()
                }
            }
            return
        }
        // Its windows come and go while it switches between Spaces under a resting pointer: it's over
        // only once they've stayed gone a moment. Anything done before then breaks the switch.
        guard !missionControlIsOpen() else {
            // Back after going, or still up a while after seeming to land: the strip goes again.
            if missionControlGone != nil || landed.map({ Date().timeIntervalSince($0) > 0.5 }) == true {
                targets.forEach { $0.standIn.showBand(false) }
                targets.forEach { $0.standIn.hold() }
                stage?.idle(true)
                landed = nil
            }
            missionControlGone = nil
            followLanding()
            return
        }
        if missionControlGone == nil {
            note("Mission Control gone")
            // The top strip is back the moment it's gone, if it went back to a stand-in (or already, as
            // it landed), and so is the picture once the stage is back on its window: only the pointer
            // and the keyboard wait.
            targets.filter { $0.standIn.isCurrent }.forEach { $0.standIn.showBand(true) }
            stage?.idle(false)
            if let stage, let current = targets.first(where: { $0.ready && !$0.leaving && $0.standIn.isCurrent }),
               stage.isShowing(current.id), stage.hasArrived(at: current.id) {
                current.standIn.picture = stage.picture(over: current.standIn.full)
                current.standIn.goLive()
            }
        }
        let gone = missionControlGone ?? Date()
        missionControlGone = gone
        guard Date().timeIntervalSince(gone) >= 0.25 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.27) { self.checkMissionControl() }
            return
        }
        missionControlGone = nil
        missionControl = false
        landed = nil
        note("Mission Control over")
        missionControlTimer?.invalidate()
        missionControlTimer = nil
        stage?.idle(false)
        update()
    }

    /// Mission Control zooming back into a stand-in's Space: its backdrop grows back to the panel's
    /// size as the zoom lands, a tenth of a second before Mission Control's own windows go. Followed
    /// frame by frame once it moves, so the top strip is back as the Space lands.
    private func followLanding() {
        guard landing == nil, landed == nil, let stage else { return }
        let panel = stage.panel
        landing = Task {
            var last: CGRect?
            var unmoved = 0
            // For a second at most, and not while Mission Control just sits there.
            for _ in 0..<125 where missionControl && missionControlGone == nil && unmoved < 12 {
                guard let (backdrop, id) = fullScreenBackdrop(on: panel) else { break }
                if backdrop.width >= panel.width - 1, backdrop.height >= panel.height - 1 {
                    if last != nil { missionControlLanded(in: spaces(of: [id])) }
                    break
                }
                unmoved = backdrop == last ? unmoved + 1 : 0
                last = backdrop
                try? await Task.sleep(for: .milliseconds(8))
            }
            landing = nil
        }
    }

    /// Its Space only becomes the panel's current one once Mission Control is gone.
    private func missionControlLanded(in theirs: Set<Int>) {
        let there = targets.filter { theirs.isEmpty ? $0.standIn.isCurrent : $0.standIn.isIn(anyOf: theirs) }
        guard missionControl, missionControlGone == nil, !there.isEmpty else { return }
        note("Mission Control landing")
        landed = Date()
        there.forEach { $0.standIn.showBand(true) }
        // In case its windows stay, Mission Control being up after all.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) { self.checkMissionControl() }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add("True Full Screen", #selector(toggleEnabled), on: enabled, to: menu)

        let apps = NSMenuItem(title: "Apps", action: nil, keyEquivalent: "")
        apps.submenu = appsMenu()
        apps.isEnabled = enabled
        menu.addItem(apps)
        let always = NSMenuItem(title: "Always in True Full Screen", action: nil, keyEquivalent: "")
        always.submenu = alwaysMenu()
        always.isEnabled = enabled
        menu.addItem(always)
        add("Keep Ready", #selector(toggleReady), on: keepsReady, to: menu).toolTip =
            "Keeps the virtual display once it's made, so windows go into true full screen sooner."

        if !AXIsProcessTrusted() { add("Allow Accessibility…", #selector(openAccessibility), on: false, to: menu) }
        if !CGPreflightScreenCaptureAccess() { add("Allow Screen Recording…", #selector(openScreenRecording), on: false, to: menu) }

        menu.addItem(.separator())
        add("Launch at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled, to: menu)
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate), keyEquivalent: "q")
    }

    private func appsMenu() -> NSMenu {
        let menu = NSMenu()
        for (id, name) in appNames(and: excluded) {
            add(name, #selector(toggleApp), on: !excluded.contains(id), to: menu).representedObject = id
        }
        return menu
    }

    private func alwaysMenu() -> NSMenu {
        let menu = NSMenu()
        for (id, name) in appNames(and: always) where id != Bundle.main.bundleIdentifier {
            add(name, #selector(toggleAlways), on: always.contains(id), to: menu).representedObject = id
        }
        return menu
    }

    /// The running apps, and these others, by bundle ID, sorted by name.
    private func appNames(and others: Set<String>) -> [(String, String)] {
        var names: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier else { continue }
            names[id] = app.localizedName ?? id
        }
        for id in others where names[id] == nil {
            names[id] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) } ?? id
        }
        return names.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }.map { ($0.key, $0.value) }
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
        if !enabled { targets.forEach { release($0.window) } }
    }

    @objc private func toggleReady() {
        keepsReady.toggle()
        getReady()
    }

    @objc private func toggleAlways(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if always.contains(id) {
            always.remove(id)
            return
        }
        always.insert(id)
        // Running already: its window in front goes in now.
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return }
        let pid = app.processIdentifier
        Task {
            guard let window = await apart({ element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute) }) else { return }
            await takeOverOnItsOwn(window, pid: pid)
        }
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
