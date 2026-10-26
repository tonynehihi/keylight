import AppKit
import IOKit
import ApplicationServices

// KeyLight 2.1 - menu bar + global hotkeys for MacBook keyboard backlight.
// Apple Silicon only. English UI.
// Default hotkeys (user-chosen): Option + Up = brighter, Option + Down = dimmer.
// Note: Option + Up/Down is also macOS paragraph navigation in text fields.
// This app uses a global monitor that does NOT swallow the key event, so in a
// text field Option + Up will both move by paragraph AND change brightness.
// That is the trade-off of the chosen default. Users can change the hotkeys
// in Settings to a safer combination such as Control + Option + Up/Down.
// Brightness control: IOKit property "KeyboardBacklightBrightness" on
// AppleHIDKeyboardEventDriverV2, range 0-4095. No private CoreBrightness use.

struct Hotkey: Equatable {
    var modifiers: NSEvent.ModifierFlags
    var keyCode: UInt16
}

let modifierOptions: [(name: String, flag: NSEvent.ModifierFlags)] = [
    ("Control", .control),
    ("Option", .option),
    ("Command", .command),
    ("Shift", .shift),
]

let keyOptions: [(name: String, code: UInt16, symbol: String)] = [
    ("Up Arrow", 126, "↑"),
    ("Down Arrow", 125, "↓"),
    ("Left Arrow", 123, "←"),
    ("Right Arrow", 124, "→"),
    ("K", 40, "K"),
    ("J", 38, "J"),
    ("H", 4, "H"),
    ("L", 37, "L"),
]

func modifierNames(_ flags: NSEvent.ModifierFlags) -> [String] {
    modifierOptions.filter { flags.contains($0.flag) }.map { $0.name }
}

func keySymbol(_ code: UInt16) -> String {
    keyOptions.first { $0.code == code }?.symbol ?? "Key \(code)"
}

func hotkeyDisplay(_ hotkey: Hotkey) -> String {
    let parts = modifierNames(hotkey.modifiers) + [keySymbol(hotkey.keyCode)]
    return parts.joined(separator: " + ")
}

// Rounded Control Center-style panel behind the menu slider.
final class SliderPanelView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let panel = NSRect(x: 12, y: 8, width: bounds.width - 24, height: bounds.height - 16)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: panel, xRadius: 18, yRadius: 18).fill()
    }
}

// A small filled circle for permission status: red = not granted, green = granted.
final class CircleView: NSView {
    var color: NSColor = .systemRed {
        didSet { needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
    }
}

func flagsFromNames(_ names: [String]) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    for option in modifierOptions where names.contains(option.name) {
        flags.insert(option.flag)
    }
    return flags
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var currentItem: NSMenuItem?
    private var brightnessSlider: NSSlider?
    private var globalMonitor: Any?
    private var settingsWindow: NSWindow?
    private var permissionsWindow: NSWindow?

    private var increaseHotkey = Hotkey(modifiers: .option, keyCode: 126)
    private var decreaseHotkey = Hotkey(modifiers: .option, keyCode: 125)

    // Settings controls, kept while the Settings window is open.
    private var incModifierButtons: [NSButton] = []
    private var decModifierButtons: [NSButton] = []
    private var incKeyPopup: NSPopUpButton?
    private var decKeyPopup: NSPopUpButton?
    private var settingsWarningLabel: NSTextField?
    private var accessibilityCircle: CircleView?
    private var inputCircle: CircleView?
    private var permissionsStatusLabel: NSTextField?
    private var monitorReceivedEvent = false

    private let maxRaw = 4095
    private let stepRaw = 410 // ~10%

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func wrappedLabel(_ text: String, frame: NSRect) -> NSTextField {
        let label = NSTextField(frame: frame)
        label.stringValue = text
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.font = NSFont.systemFont(ofSize: 13)
        if let cell = label.cell as? NSTextFieldCell {
            cell.wraps = true
            cell.isScrollable = false
        }
        return label
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadHotkeys()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = symbol("keyboard")
        item.button?.toolTip = "KeyLight: \(hotkeyDisplay(increaseHotkey)) / \(hotkeyDisplay(decreaseHotkey))"

        let menu = NSMenu()
        menu.delegate = self

        let current = NSMenuItem(title: "Reading brightness...", action: nil, keyEquivalent: "")
        current.isEnabled = false
        menu.addItem(current)
        currentItem = current

        menu.addItem(.separator())

        // Only brightness control in the menu is the slider, styled like
        // a macOS Control Center module: a rounded panel with a dim icon
        // on the left, a bright icon on the right, slider in the middle.
        // Global hotkeys (Option + Up/Down by default) still work, and
        // sliding to 0 turns the backlight off, so the old Increase /
        // Decrease / Turn Off menu buttons are gone.
        let sliderItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let sliderView = SliderPanelView(frame: NSRect(x: 0, y: 0, width: 280, height: 56))
        let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: self, action: #selector(sliderChanged))
        slider.frame = NSRect(x: 52, y: 17, width: 176, height: 22)
        slider.isContinuous = true
        sliderView.addSubview(slider)
        if let dim = NSImage(systemSymbolName: "sun.min", accessibilityDescription: nil) {
            let dimView = NSImageView(frame: NSRect(x: 24, y: 18, width: 20, height: 20))
            dimView.image = dim
            dimView.contentTintColor = .secondaryLabelColor
            sliderView.addSubview(dimView)
        }
        if let bright = NSImage(systemSymbolName: "sun.max", accessibilityDescription: nil) {
            let brightView = NSImageView(frame: NSRect(x: 236, y: 18, width: 20, height: 20))
            brightView.image = bright
            brightView.contentTintColor = .secondaryLabelColor
            sliderView.addSubview(brightView)
        }
        sliderItem.view = sliderView
        menu.addItem(sliderItem)
        brightnessSlider = slider

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        let permissions = NSMenuItem(title: "Permissions...", action: #selector(openPermissions), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApplication.shared
        menu.addItem(quit)

        let byline = NSMenuItem(title: "by @tonynehihi", action: nil, keyEquivalent: "")
        byline.isEnabled = false
        menu.addItem(byline)

        item.menu = menu
        statusItem = item

        setupGlobalMonitor()

        // First-launch permission panel. It is also available any time
        // from the menu as Permissions...
        if !UserDefaults.standard.bool(forKey: "permissionPanelSeen") {
            openPermissions()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if let raw = currentRaw() {
            let percent = Int(round(Double(raw) / Double(maxRaw) * 100))
            currentItem?.title = "Current brightness: \(percent)%"
            brightnessSlider?.doubleValue = Double(percent)
            brightnessSlider?.isEnabled = true
        } else {
            // Short title on purpose: the old long
            // "Cannot read backlight (not a MacBook?)" stretched the whole
            // menu wider than the slider panel, leaving a big white gap
            // on the right of the panel.
            currentItem?.title = "No backlight"
            brightnessSlider?.isEnabled = false
        }
    }

    // MARK: - Hotkeys: load, save, monitor

    private func loadHotkeys() {
        let defaults = UserDefaults.standard
        if let names = defaults.array(forKey: "increaseModifiers") as? [String],
           let code = defaults.object(forKey: "increaseKeyCode") as? Int {
            increaseHotkey = Hotkey(modifiers: flagsFromNames(names), keyCode: UInt16(code))
        }
        if let names = defaults.array(forKey: "decreaseModifiers") as? [String],
           let code = defaults.object(forKey: "decreaseKeyCode") as? Int {
            decreaseHotkey = Hotkey(modifiers: flagsFromNames(names), keyCode: UInt16(code))
        }
    }

    private func saveHotkeys() {
        let defaults = UserDefaults.standard
        defaults.set(modifierNames(increaseHotkey.modifiers), forKey: "increaseModifiers")
        defaults.set(Int(increaseHotkey.keyCode), forKey: "increaseKeyCode")
        defaults.set(modifierNames(decreaseHotkey.modifiers), forKey: "decreaseModifiers")
        defaults.set(Int(decreaseHotkey.keyCode), forKey: "decreaseKeyCode")
    }

    private func setupGlobalMonitor() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        // Global monitor does NOT swallow the event. The hotkey will also
        // reach the focused app. That is why a combination with no system
        // function (for example Control + Option + arrows) is safer than
        // Option + arrows alone, which also moves by paragraph in text.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            let relevant = event.modifierFlags.intersection([.control, .option, .command, .shift])
            if relevant == self.increaseHotkey.modifiers && event.keyCode == self.increaseHotkey.keyCode {
                self.monitorReceivedEvent = true
                self.increase()
            } else if relevant == self.decreaseHotkey.modifiers && event.keyCode == self.decreaseHotkey.keyCode {
                self.monitorReceivedEvent = true
                self.decrease()
            }
        }
    }

    // MARK: - Settings window

    @objc private func openSettings() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "KeyLight Settings"
        guard let content = window.contentView else { return }
        settingsWindow = window

        var y: CGFloat = 360
        content.addSubview(wrappedLabel("Choose your hotkeys. At least one modifier is required. Increase and Decrease must be different.", frame: NSRect(x: 20, y: y - 30, width: 420, height: 40)))
        y -= 60

        content.addSubview(wrappedLabel("Increase Brightness", frame: NSRect(x: 20, y: y, width: 420, height: 20)))
        y -= 30
        incModifierButtons = makeModifierRow(in: content, y: y)
        incKeyPopup = makeKeyPopup(in: content, y: y, selected: increaseHotkey.keyCode)
        y -= 50

        content.addSubview(wrappedLabel("Decrease Brightness", frame: NSRect(x: 20, y: y, width: 420, height: 20)))
        y -= 30
        decModifierButtons = makeModifierRow(in: content, y: y)
        decKeyPopup = makeKeyPopup(in: content, y: y, selected: decreaseHotkey.keyCode)
        y -= 50

        populateModifierButtons(incModifierButtons, flags: increaseHotkey.modifiers)
        populateModifierButtons(decModifierButtons, flags: decreaseHotkey.modifiers)

        let warning = wrappedLabel("", frame: NSRect(x: 20, y: y - 20, width: 420, height: 40))
        warning.textColor = NSColor.systemOrange
        content.addSubview(warning)
        settingsWarningLabel = warning
        updateSettingsWarning()
        y -= 60

        let save = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        save.frame = NSRect(x: 20, y: 20, width: 90, height: 28)
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        content.addSubview(save)

        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetSettings))
        reset.frame = NSRect(x: 120, y: 20, width: 140, height: 28)
        reset.bezelStyle = .rounded
        content.addSubview(reset)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeSettings))
        cancel.frame = NSRect(x: 270, y: 20, width: 90, height: 28)
        cancel.bezelStyle = .rounded
        content.addSubview(cancel)
        content.addSubview(wrappedLabel("by @tonynehihi", frame: NSRect(x: 20, y: 60, width: 420, height: 20)))

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeModifierRow(in content: NSView, y: CGFloat) -> [NSButton] {
        var buttons: [NSButton] = []
        var x: CGFloat = 20
        for option in modifierOptions {
            let button = NSButton(checkboxWithTitle: option.name, target: nil, action: nil)
            button.frame = NSRect(x: x, y: y, width: 90, height: 20)
            content.addSubview(button)
            buttons.append(button)
            x += 95
        }
        return buttons
    }

    private func makeKeyPopup(in content: NSView, y: CGFloat, selected: UInt16) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(x: 20, y: y - 28, width: 160, height: 24), pullsDown: false)
        popup.addItems(withTitles: keyOptions.map { $0.name })
        if let name = keyOptions.first(where: { $0.code == selected })?.name {
            popup.selectItem(withTitle: name)
        }
        content.addSubview(popup)
        return popup
    }

    private func populateModifierButtons(_ buttons: [NSButton], flags: NSEvent.ModifierFlags) {
        for (index, option) in modifierOptions.enumerated() where index < buttons.count {
            buttons[index].state = flags.contains(option.flag) ? .on : .off
        }
    }

    private func readHotkey(buttons: [NSButton], popup: NSPopUpButton?) -> Hotkey? {
        var flags: NSEvent.ModifierFlags = []
        for (index, option) in modifierOptions.enumerated() where index < buttons.count {
            if buttons[index].state == .on {
                flags.insert(option.flag)
            }
        }
        guard let title = popup?.selectedItem?.title,
              let code = keyOptions.first(where: { $0.name == title })?.code else { return nil }
        return Hotkey(modifiers: flags, keyCode: code)
    }

    private func updateSettingsWarning() {
        guard let inc = readHotkey(buttons: incModifierButtons, popup: incKeyPopup),
              let dec = readHotkey(buttons: decModifierButtons, popup: decKeyPopup) else { return }
        if inc.modifiers == .option && (inc.keyCode == 126 || inc.keyCode == 125) ||
           dec.modifiers == .option && (dec.keyCode == 126 || dec.keyCode == 125) {
            settingsWarningLabel?.stringValue = "Note: Option + Up/Down also moves by paragraph in text fields. In a text field it will both move the cursor and change brightness."
        } else {
            settingsWarningLabel?.stringValue = ""
        }
    }

    @objc private func saveSettings() {
        guard let inc = readHotkey(buttons: incModifierButtons, popup: incKeyPopup),
              let dec = readHotkey(buttons: decModifierButtons, popup: decKeyPopup) else { return }
        if inc.modifiers.isEmpty || dec.modifiers.isEmpty {
            settingsWarningLabel?.stringValue = "Each hotkey needs at least one modifier (Control, Option, Command or Shift)."
            return
        }
        if inc == dec {
            settingsWarningLabel?.stringValue = "Increase and Decrease must be different hotkeys."
            return
        }
        increaseHotkey = inc
        decreaseHotkey = dec
        saveHotkeys()
        setupGlobalMonitor()
        statusItem?.button?.toolTip = "KeyLight: \(hotkeyDisplay(increaseHotkey)) / \(hotkeyDisplay(decreaseHotkey))"
        settingsWindow?.close()
    }

    @objc private func resetSettings() {
        increaseHotkey = Hotkey(modifiers: .option, keyCode: 126)
        decreaseHotkey = Hotkey(modifiers: .option, keyCode: 125)
        populateModifierButtons(incModifierButtons, flags: increaseHotkey.modifiers)
        populateModifierButtons(decModifierButtons, flags: decreaseHotkey.modifiers)
        if let name = keyOptions.first(where: { $0.code == 126 })?.name {
            incKeyPopup?.selectItem(withTitle: name)
        }
        if let name = keyOptions.first(where: { $0.code == 125 })?.name {
            decKeyPopup?.selectItem(withTitle: name)
        }
        updateSettingsWarning()
    }

    @objc private func closeSettings() {
        settingsWindow?.close()
    }

    // MARK: - Permissions window

    @objc private func openPermissions() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "KeyLight Permissions"
        guard let content = window.contentView else { return }
        permissionsWindow = window

        // Compact layout: one row per permission, circle + name + Open
        // button all on the same line, so the red/green status sits right
        // beside the button that fixes it. No separate status section.
        // Red circle = not granted, green circle = granted.
        // Accessibility can be checked live. Input Monitoring cannot be
        // checked by any public macOS API, so its circle turns green only
        // after a real hotkey test passes (see checkPermissionsAgain).
        var y: CGFloat = 340
        content.addSubview(wrappedLabel("KeyLight needs permission to detect your global hotkeys.", frame: NSRect(x: 20, y: y - 20, width: 420, height: 20)))
        y -= 40
        content.addSubview(wrappedLabel("It does not record what you type. It only reacts when you press the hotkey you set in Settings.", frame: NSRect(x: 20, y: y - 30, width: 420, height: 40)))
        y -= 60

        let accCircle = CircleView(frame: NSRect(x: 20, y: y - 2, width: 16, height: 16))
        content.addSubview(accCircle)
        accessibilityCircle = accCircle
        content.addSubview(wrappedLabel("Accessibility", frame: NSRect(x: 45, y: y, width: 130, height: 20)))
        let accessibilityButton = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibilitySettings))
        accessibilityButton.frame = NSRect(x: 190, y: y - 4, width: 250, height: 28)
        accessibilityButton.bezelStyle = .rounded
        content.addSubview(accessibilityButton)
        y -= 40

        let inCircle = CircleView(frame: NSRect(x: 20, y: y - 2, width: 16, height: 16))
        content.addSubview(inCircle)
        inputCircle = inCircle
        content.addSubview(wrappedLabel("Input Monitoring", frame: NSRect(x: 45, y: y, width: 130, height: 20)))
        let inputButton = NSButton(title: "Open Input Monitoring Settings", target: self, action: #selector(openInputMonitoringSettings))
        inputButton.frame = NSRect(x: 190, y: y - 4, width: 250, height: 28)
        inputButton.bezelStyle = .rounded
        content.addSubview(inputButton)
        y -= 40

        content.addSubview(wrappedLabel("To test Input Monitoring: switch to another app (for example Finder), press your Increase hotkey, come back here, then click Check Again.", frame: NSRect(x: 20, y: y - 40, width: 420, height: 50)))
        y -= 60

        let status = wrappedLabel("", frame: NSRect(x: 20, y: y - 20, width: 420, height: 20))
        content.addSubview(status)
        permissionsStatusLabel = status
        updatePermissionCircles()

        let check = NSButton(title: "Check Again", target: self, action: #selector(checkPermissionsAgain))
        check.frame = NSRect(x: 20, y: 20, width: 120, height: 28)
        check.bezelStyle = .rounded
        content.addSubview(check)

        let cont = NSButton(title: "Continue", target: self, action: #selector(closePermissions))
        cont.frame = NSRect(x: 150, y: 20, width: 90, height: 28)
        cont.bezelStyle = .rounded
        cont.keyEquivalent = "\r"
        content.addSubview(cont)
        content.addSubview(wrappedLabel("by @tonynehihi", frame: NSRect(x: 320, y: 24, width: 120, height: 20)))

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updatePermissionCircles() {
        accessibilityCircle?.color = AXIsProcessTrusted() ? .systemGreen : .systemRed
        let inputGranted = UserDefaults.standard.bool(forKey: "inputMonitoringTestPassed")
        inputCircle?.color = inputGranted ? .systemGreen : .systemRed
    }

    @objc private func checkPermissionsAgain() {
        // Accessibility is checked live. Input Monitoring has no public
        // status API, so a green circle here means a global hotkey event
        // was actually received since this app started, which proves the
        // permission is working. Pressing the hotkey while this window is
        // in front does not count, because global monitors only see events
        // sent to other apps.
        if monitorReceivedEvent {
            UserDefaults.standard.set(true, forKey: "inputMonitoringTestPassed")
            permissionsStatusLabel?.stringValue = "Hotkey received. Input Monitoring is working."
        } else {
            permissionsStatusLabel?.stringValue = "No hotkey received yet. Switch to another app, press your Increase hotkey, then Check Again."
        }
        updatePermissionCircles()
    }

    @objc private func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func closePermissions() {
        UserDefaults.standard.set(true, forKey: "permissionPanelSeen")
        permissionsWindow?.close()
    }

    // MARK: - IOKit: read / write backlight

    private func withKeyboardServices(_ body: (io_service_t) -> Void) {
        // Apple Silicon MacBooks. Extra names are fallbacks for other
        // Apple Silicon generations, not Intel support.
        for name in ["AppleHIDKeyboardEventDriverV2", "AppleHIDKeyboardEventDriver", "AppleHIDKeyboard"] {
            var iterator: io_iterator_t = 0
            let kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator)
            guard kr == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            var service = IOIteratorNext(iterator)
            while service != 0 {
                body(service)
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
        }
    }

    private func currentRaw() -> Int? {
        var found: Int?
        withKeyboardServices { service in
            if found != nil { return }
            guard let prop = IORegistryEntryCreateCFProperty(
                service, "KeyboardBacklightBrightness" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? NSNumber else { return }
            found = prop.intValue
        }
        return found
    }

    private func setRaw(_ raw: Int) -> Bool {
        var value = Int32(min(max(raw, 0), maxRaw))
        guard let number = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &value) else { return false }
        var ok = false
        withKeyboardServices { service in
            if IORegistryEntrySetCFProperty(service, "KeyboardBacklightBrightness" as CFString, number) == KERN_SUCCESS {
                ok = true
            }
        }
        return ok
    }

    private func showError() {
        statusItem?.button?.image = symbol("exclamationmark.triangle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.statusItem?.button?.image = self?.symbol("keyboard")
        }
    }

    // MARK: - Actions

    @objc private func sliderChanged(_ sender: NSSlider) {
        let percent = Int(round(sender.doubleValue))
        let raw = Int(round(Double(percent) / 100 * Double(maxRaw)))
        if !setRaw(raw) { showError(); return }
        currentItem?.title = "Current brightness: \(percent)%"
    }

    @objc private func increase() {
        guard let current = currentRaw() else { showError(); return }
        if !setRaw(current + stepRaw) { showError() }
    }

    @objc private func decrease() {
        guard let current = currentRaw() else { showError(); return }
        if !setRaw(current - stepRaw) { showError() }
    }

    @objc private func turnOff() {
        if !setRaw(0) { showError() }
    }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
