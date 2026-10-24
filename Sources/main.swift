import AppKit
import ServiceManagement

// macOS keeps full screen windows below the notch on the built-in display. While on,
// this app runs the screen on a notch-free virtual display of the same size and has
// the built-in panel mirror it pixel for pixel, so full screen is ordinary macOS full
// screen that reaches the top edge.

private extension NSScreen {
    var displayID: CGDirectDisplayID { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0 }
}

/// The built-in display, while it's connected and the lid is open.
private func builtInDisplay() -> CGDirectDisplayID? {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &displays, &count)
    return displays.first { CGDisplayIsBuiltin($0) != 0 }
}

/// A notch-free display with the panel's size, sharpness and colors.
private func makeTwin(of panel: CGDirectDisplayID) -> CGVirtualDisplay? {
    guard let mode = CGDisplayCopyDisplayMode(panel) else { return nil }
    let descriptor = CGVirtualDisplayDescriptor()
    descriptor.queue = .main
    descriptor.name = "True Full Screen"
    descriptor.maxPixelsWide = UInt32(mode.pixelWidth)
    descriptor.maxPixelsHigh = UInt32(mode.pixelHeight)
    descriptor.sizeInMillimeters = CGDisplayScreenSize(panel)
    // A fixed identity, so macOS treats it as the same display every time.
    descriptor.vendorID = 0x5446
    descriptor.productID = 0x4654
    descriptor.serialNum = 2
    // Display P3, like the panel.
    descriptor.redPrimary = CGPoint(x: 0.680, y: 0.320)
    descriptor.greenPrimary = CGPoint(x: 0.265, y: 0.690)
    descriptor.bluePrimary = CGPoint(x: 0.150, y: 0.060)
    descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)

    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 1
    settings.modes = [CGVirtualDisplayMode(width: UInt32(mode.width), height: UInt32(mode.height),
                                           refreshRate: mode.refreshRate, transferFunction: 1)]
    guard let twin = CGVirtualDisplay(descriptor: descriptor), twin.apply(settings) else { return nil }
    return twin
}

/// Puts the twin where the panel was and has the panel show it.
private func mirror(_ panel: CGDirectDisplayID, onto twin: CGDirectDisplayID) {
    let origin = CGDisplayBounds(panel).origin
    var config: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&config)
    CGConfigureDisplayOrigin(config, twin, Int32(origin.x), Int32(origin.y))
    CGConfigureDisplayMirrorOfDisplay(config, panel, twin)
    CGCompleteDisplayConfiguration(config, .forSession)
}

private let reconfigured: CGDisplayReconfigurationCallBack = { _, flags, info in
    guard !flags.contains(.beginConfigurationFlag), let info else { return }
    let controller = Unmanaged<Controller>.fromOpaque(info).takeUnretainedValue()
    DispatchQueue.main.async { MainActor.assumeIsolated { controller.displaysChanged() } }
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
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let defaults = UserDefaults.standard
    private var twin: CGVirtualDisplay?
    private var syncing = false
    private var resync = false
    private var mirrorings: [Date] = []
    private var pending: Task<Void, Never>?

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    /// Remembered, since the panel isn't listed as a screen while it mirrors the twin.
    private var notched: Bool {
        get { defaults.bool(forKey: "notched") }
        set { defaults.set(newValue, forKey: "notched") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !defaults.bool(forKey: "setUp") {
            defaults.set(true, forKey: "setUp")
            try? SMAppService.mainApp.register()
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.image = glyph(on: enabled)
        CGDisplayRegisterReconfigurationCallback(reconfigured, Unmanaged.passUnretained(self).toOpaque())
        Task { await sync() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        twin = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        item.button?.performClick(nil)
        return false
    }

    /// Waits for a burst of display changes to settle, then checks the setup still holds.
    fileprivate func displaysChanged() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { await sync() }
        }
    }

    /// Keeps the twin and the mirroring in line with the switch and the panel.
    private func sync() async {
        guard !syncing else {
            resync = true
            return
        }
        syncing = true
        defer { syncing = false }
        repeat {
            resync = false
            guard let panel = builtInDisplay() else {
                // Lid closed: never leave a display nobody can see.
                twin = nil
                continue
            }
            if let screen = NSScreen.screens.first(where: { $0.displayID == panel }) {
                notched = screen.safeAreaInsets.top > 0
            }
            guard enabled, notched else {
                twin = nil
                continue
            }
            if twin == nil {
                twin = makeTwin(of: panel)
                for _ in 0..<100 where twin.map({ CGDisplayBounds($0.displayID).isEmpty }) == true {
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            guard let twin, CGDisplayMirrorsDisplay(panel) != twin.displayID else { continue }
            mirrorings = mirrorings.filter { $0.timeIntervalSinceNow > -10 } + [Date()]
            if mirrorings.count > 3 {
                // macOS keeps undoing it, so stop rather than flicker.
                self.twin = nil
                enabled = false
                item.button?.image = glyph(on: false)
                continue
            }
            mirror(panel, onto: twin.displayID)
        } while resync
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if notched || builtInDisplay() == nil {
            add("True Full Screen", #selector(toggleEnabled), on: enabled, to: menu)
        } else {
            menu.addItem(withTitle: "No notch on this Mac", action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(.separator())
        add("Launch at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled, to: menu)
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate), keyEquivalent: "q")
    }

    private func add(_ title: String, _ action: Selector, on: Bool, to menu: NSMenu) {
        let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.state = on ? .on : .off
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        item.button?.image = glyph(on: enabled)
        mirrorings = []
        Task { await sync() }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        if service.status == .enabled { try? service.unregister() } else { try? service.register() }
    }
}

MainActor.assumeIsolated {
    let application = Application.shared
    let controller = Controller()
    application.delegate = controller
    application.run()
}
