import AppKit
import ServiceManagement

// AppKit reads this when an app launches. YES lets green-button full screen
// windows use the area beside the notch instead of a black bar.
private let key = "NSApplicationSafeApertureCompatibilityModeSystemFullScreen" as CFString

/// Writes the preference to a domain. `nil` removes it.
@discardableResult
private func write(_ value: Bool?, to domain: CFString) -> Bool {
    let flag: CFBoolean? = value.map { $0 ? kCFBooleanTrue : kCFBooleanFalse }
    CFPreferencesSetValue(key, flag, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    return CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
}

private func url(for id: String) -> URL? {
    NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.bundleURL
        ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
}

/// Sandboxed apps read preferences from their container, not ~/Library/Preferences.
private func domain(for id: String) -> CFString {
    var code: SecStaticCode?
    var info: CFDictionary?
    guard let url = url(for: id),
          SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
          SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let entitlements = (info as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
          entitlements["com.apple.security.app-sandbox"] as? Bool == true
    else { return id as CFString }
    return "\(NSHomeDirectory())/Library/Containers/\(id)/Data/Library/Preferences/\(id)" as CFString
}

/// Menu bar glyph: a screen with a notch, solid when on.
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
    private var changed = false

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    private var excluded: Set<String> {
        get { Set(defaults.stringArray(forKey: "excluded") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "excluded") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !defaults.bool(forKey: "setUp") {
            defaults.set(true, forKey: "setUp")
            try? SMAppService.mainApp.register()
        }
        write(enabled ? true : nil, to: kCFPreferencesAnyApplication)
        for id in excluded { write(false, to: domain(for: id)) }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.image = glyph(on: enabled)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        item.button?.performClick(nil)
        return false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add("True Full Screen", #selector(toggleEnabled), on: enabled, to: menu)

        let apps = NSMenuItem(title: "Apps", action: nil, keyEquivalent: "")
        apps.submenu = appsMenu()
        apps.isEnabled = enabled
        menu.addItem(apps)

        if changed {
            menu.addItem(.separator())
            let note = NSMenuItem(title: "Reopen apps to apply", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }

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
            names[id] = url(for: id).map { FileManager.default.displayName(atPath: $0.path) } ?? id
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
        write(enabled ? true : nil, to: kCFPreferencesAnyApplication)
        item.button?.image = glyph(on: enabled)
        changed = true
    }

    @objc private func toggleApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let exclude = !excluded.contains(id)
        guard write(exclude ? false : nil, to: domain(for: id)) else { return askForAccess(sender.title) }
        if exclude { excluded.insert(id) } else { excluded.remove(id) }
        changed = true
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        if service.status == .enabled { try? service.unregister() } else { try? service.register() }
    }

    private func askForAccess(_ name: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Full Disk Access needed"
        alert.informativeText = "\(name) is sandboxed. Allow True Full Screen in Full Disk Access, then try again."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        }
    }
}

MainActor.assumeIsolated {
    let application = Application.shared
    let controller = Controller()
    application.delegate = controller
    application.run()
}
