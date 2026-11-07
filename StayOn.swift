// StayOn: one click in the menu bar keeps the Mac awake, even with the lid closed.
// There is no timer. It stays on until you click again.
//
// The menu bar icon always shows the real system setting (pmset SleepDisabled).
// A marker file records that StayOn turned it on, so that a crash keeps the
// session and a reboot ends it.

import AppKit
import IOKit
import IOKit.ps
import ServiceManagement

// test.sh compiles with -D TESTMODE. That build runs fake commands and reads a
// fake lid and battery from a folder, so it cannot touch the real sleep setting.
#if TESTMODE
let testRoot = ProcessInfo.processInfo.environment["STAYON_TEST_ROOT"]!
func testFlag(_ name: String) -> Bool { FileManager.default.fileExists(atPath: "\(testRoot)/\(name)") }
func testValue(_ name: String) -> String? {
    (try? String(contentsOfFile: "\(testRoot)/\(name)", encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
let pmsetPath = "\(testRoot)/pmset"
let sudoPath = "\(testRoot)/sudo"
let tickSeconds = 0.1
#else
let pmsetPath = "/usr/bin/pmset"
let sudoPath = "/usr/bin/sudo"
let tickSeconds = 3.0
#endif
let batteryFloor = 10

// MARK: - System helpers

@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// The real system setting, or nil if pmset could not be read.
func sleepIsDisabled() -> Bool? {
    let result = run(pmsetPath, ["-g"])
    guard result.status == 0 else { return nil }
    for line in result.output.split(separator: "\n") {
        let fields = line.split(whereSeparator: \.isWhitespace)
        if fields.first == "SleepDisabled" { return fields.last == "1" }
    }
    return false
}

func setSleepDisabled(_ disabled: Bool) -> Bool {
    run(sudoPath, ["-n", pmsetPath, "-a", "disablesleep", disabled ? "1" : "0"]).status == 0
}

/// Asks for the admin password once and installs a sudo rule that allows only
/// the two exact commands StayOn runs.
func installSudoRule() -> Bool {
    #if TESTMODE
    guard testFlag("password_accepted") else { return false }
    try? FileManager.default.removeItem(atPath: "\(testRoot)/sudo_denied")
    return true
    #else
    let user = NSUserName()
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    guard !user.isEmpty, user.unicodeScalars.allSatisfy(allowed.contains) else { return false }
    let rule = "\(user) ALL=(root) NOPASSWD: \(pmsetPath) -a disablesleep 0, \(pmsetPath) -a disablesleep 1"
    let shell = "t=$(/usr/bin/mktemp /tmp/stayon.XXXXXX) && /usr/bin/printf '%s\\n' '\(rule)' > $t"
        + " && /usr/sbin/visudo -cf $t && /usr/sbin/chown root:wheel $t && /bin/chmod 440 $t"
        + " && /bin/mv $t /etc/sudoers.d/stayon"
    let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
    let script = "do shell script \"\(escaped)\" with prompt "
        + "\"StayOn needs your password once to control sleep.\" with administrator privileges"
    return run("/usr/bin/osascript", ["-e", script]).status == 0
    #endif
}

func lidIsClosed() -> Bool {
    #if TESTMODE
    return testFlag("lid_closed")
    #else
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return false }
    defer { IOObjectRelease(service) }
    let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
    return (value?.takeRetainedValue() as? Bool) ?? false
    #endif
}

/// Percent charged and whether the Mac is running on battery. Nil without a battery.
func batteryStatus() -> (percent: Int, onBattery: Bool)? {
    #if TESTMODE
    let fields = (testValue("battery") ?? "").split(separator: " ")
    guard fields.count == 2, let percent = Int(fields[0]) else { return nil }
    return (percent, fields[1] == "battery")
    #else
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
    for source in sources {
        guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              let percent = description[kIOPSCurrentCapacityKey] as? Int,
              let state = description[kIOPSPowerSourceStateKey] as? String
        else { continue }
        return (percent, state == kIOPSBatteryPowerValue)
    }
    return nil
    #endif
}

// MARK: - Marker file

enum Marker {
    #if TESTMODE
    static let url = URL(fileURLWithPath: "\(testRoot)/support/on")
    static var bootSession: String { testValue("boot") ?? "" }
    #else
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/StayOn/on")

    static var bootSession: String {
        run("/usr/sbin/sysctl", ["-n", "kern.bootsessionuuid"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif
    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    static var savedBootSession: String? {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func write() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? bootSession.write(to: url, atomically: true, encoding: .utf8)
    }
    static func remove() { try? FileManager.default.removeItem(at: url) }
}

// MARK: - Screen brightness

/// With the lid closed, StayOn dims the built-in screen to black instead of
/// switching the display off. Remote desktop apps like RustDesk need the display
/// to stay on so they can capture it. The brightness to restore is saved to a
/// file, so a crash never leaves the screen black.
enum Backlight {
    static let savedURL = Marker.url.deletingLastPathComponent().appendingPathComponent("brightness")

    #if TESTMODE
    static func get() -> Float? { testValue("brightness").flatMap(Float.init) }
    static func set(_ value: Float) {
        try? "\(value)".write(toFile: "\(testRoot)/brightness", atomically: true, encoding: .utf8)
    }
    #else
    // DisplayServices is a private framework. If it ever goes missing, StayOn simply skips dimming.
    private typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let library = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getFunction = library.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetFunction.self) }
    private static let setFunction = library.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetFunction.self) }

    private static var builtInDisplay: CGDirectDisplayID? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func get() -> Float? {
        guard let display = builtInDisplay, let getFunction else { return nil }
        var value: Float = 0
        return getFunction(display, &value) == 0 ? value : nil
    }

    static func set(_ value: Float) {
        guard let display = builtInDisplay, let setFunction else { return }
        _ = setFunction(display, value)
    }
    #endif

    static var saved: Float? {
        (try? String(contentsOf: savedURL, encoding: .utf8))
            .flatMap { Float($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static func darken(remembering value: Float) {
        try? FileManager.default.createDirectory(
            at: savedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(value)".write(to: savedURL, atomically: true, encoding: .utf8)
        set(0)
    }

    /// Puts the saved brightness back. Returns it, or nil if nothing was saved.
    @discardableResult
    static func restore() -> Float? {
        guard let value = saved else { return nil }
        set(value)
        try? FileManager.default.removeItem(at: savedURL)
        return value
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A crowded menu bar hides new icons, so start near the right edge.
    /// macOS updates this position if you Command-drag the icon elsewhere.
    private let statusItem: NSStatusItem = {
        let name = "stayon.status"
        let key = "NSStatusItem Preferred Position \(name)"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(60, forKey: key)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = name
        return item
    }()
    /// Every pmset change and read runs here, one at a time.
    private let worker = DispatchQueue(label: "stayon.worker")
    private var isOn = false
    private var busy = false
    private var note: String?
    private var ticks = 0
    /// The latest brightness seen with the lid open. macOS starts dimming as the
    /// lid closes, so reading it at that moment would save the wrong value.
    private var openBrightness: Float?
    /// macOS sometimes resets brightness right after the lid opens, so restore twice.
    private var restoredBrightness: Float?
    /// You turned StayOn on while already below the floor, so don't undo that.
    private var floorOverride = false
    private var timer: Timer?
    private var termSource: DispatchSourceSignal?
    #if TESTMODE
    private var testClicks: DispatchSourceSignal?
    #endif
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // App Nap would slow the timer that notices the lid closing.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Watching the lid")

        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source

        #if TESTMODE
        signal(SIGUSR1, SIG_IGN)
        let clicks = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        clicks.setEventHandler { [weak self] in self?.toggle() }
        clicks.resume()
        testClicks = clicks
        #endif

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        render()

        worker.async { self.endSessionFromEarlierBoot() }
        refresh()

        let timer = Timer(timeInterval: tickSeconds, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = tickSeconds / 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        Backlight.restore()
        worker.sync {
            guard Marker.exists else { return }
            if setSleepDisabled(false) { Marker.remove() }
        }
    }

    private func endSessionFromEarlierBoot() {
        guard let saved = Marker.savedBootSession, saved != Marker.bootSession else { return }
        if setSleepDisabled(false) { Marker.remove() }
    }

    // MARK: Clicks

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            toggle()
        }
    }

    @objc private func toggle() {
        guard !busy else { return }
        if isOn && lidIsClosed() && !confirmTurnOffWithLidClosed() { return }
        change(to: !isOn, because: nil)
    }

    private func change(to on: Bool, because reason: String?) {
        guard !busy else { return }
        busy = true
        if on, let battery = batteryStatus() {
            floorOverride = battery.onBattery && battery.percent <= batteryFloor
        }
        worker.async {
            let succeeded = self.apply(on)
            let actual = sleepIsDisabled()
            DispatchQueue.main.async {
                self.busy = false
                self.isOn = actual ?? self.isOn
                self.note = reason
                self.render()
                if !succeeded { self.showFailure(wanted: on) }
            }
        }
    }

    /// Runs on the worker.
    private func apply(_ on: Bool) -> Bool {
        if on { Marker.write() }
        if !setSleepDisabled(on) && installSudoRule() { _ = setSleepDisabled(on) }
        let actual = sleepIsDisabled()
        if actual == false { Marker.remove() }
        return actual == on
    }

    /// Turning off with the lid closed sleeps the Mac at once and drops remote sessions.
    private func confirmTurnOffWithLidClosed() -> Bool {
        #if TESTMODE
        return testFlag("confirm_turn_off")
        #endif
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Turn off with the lid closed?"
        alert.informativeText = "The Mac will sleep right away and remote connections like RustDesk will drop. "
            + "You will need to open the lid to get back in."
        alert.addButton(withTitle: "Keep On")
        alert.addButton(withTitle: "Turn Off")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func showFailure(wanted on: Bool) {
        #if TESTMODE
        try? "failed".write(toFile: "\(testRoot)/failure_shown", atomically: true, encoding: .utf8)
        return
        #endif
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = on ? "StayOn could not turn on" : "StayOn could not turn off"
        alert.informativeText = "macOS did not accept the sleep change. The icon shows the current setting."
        alert.runModal()
    }

    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Could not change Open at Login"
            alert.informativeText = "Move StayOn to the Applications folder and try again. (\(error.localizedDescription))"
            alert.runModal()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let change = NSMenuItem(title: isOn ? "Turn Off" : "Turn On", action: #selector(toggle), keyEquivalent: "")
        change.target = self
        menu.addItem(change)
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let quit = NSMenuItem(title: "Quit StayOn", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: Watching

    private func tick() {
        let closed = lidIsClosed()
        if closed {
            restoredBrightness = nil
            if isOn {
                // Dim to black rather than switching the display off, so remote desktop apps keep working.
                if Backlight.saved == nil {
                    if let brightness = openBrightness ?? Backlight.get() { Backlight.darken(remembering: brightness) }
                } else if let brightness = Backlight.get(), brightness > 0.01 {
                    Backlight.set(0)   // macOS turned it back up.
                }
            }
        } else if let restored = Backlight.restore() {
            restoredBrightness = restored
        } else if let restored = restoredBrightness {
            Backlight.set(restored)
            restoredBrightness = nil
        } else if let brightness = Backlight.get(), brightness > 0.01 {
            openBrightness = brightness
        }

        ticks += 1
        if ticks % 5 == 0 { refresh() }
    }

    /// Follows the real setting and applies the safety limits.
    private func refresh() {
        worker.async {
            let actual = sleepIsDisabled()
            if actual == false && Marker.exists { Marker.remove() }
            let owned = Marker.exists
            DispatchQueue.main.async {
                guard !self.busy else { return }
                if let actual, actual != self.isOn {
                    self.isOn = actual
                    self.note = nil
                    self.render()
                }
                if owned { self.checkSafetyLimits() }
            }
        }
    }

    private func checkSafetyLimits() {
        if ProcessInfo.processInfo.thermalState == .critical {
            change(to: false, because: "Turned off: the Mac got too hot")
            return
        }
        guard let battery = batteryStatus() else { return }
        guard battery.onBattery && battery.percent <= batteryFloor else {
            floorOverride = false
            return
        }
        if !floorOverride {
            change(to: false, because: "Turned off: battery reached \(battery.percent)%")
        }
    }

    // MARK: Display

    private var statusText: String {
        note ?? (isOn ? "On: stays awake with the lid closed" : "Off: normal sleep")
    }

    private func render() {
        guard let button = statusItem.button else { return }
        var image = NSImage(systemSymbolName: isOn ? "sun.max.fill" : "moon.zzz",
                            accessibilityDescription: isOn ? "StayOn is on" : "StayOn is off")
        if isOn {
            // Orange comes from the image itself. A tint on the button drew black in the menu bar.
            image = image?.withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        button.image = image
        button.toolTip = "StayOn. \(statusText). Click to \(isOn ? "turn off" : "turn on"), right-click for menu."
        #if TESTMODE
        try? "\(isOn ? "on" : "off")|\(note ?? "")".write(toFile: "\(testRoot)/ui", atomically: true, encoding: .utf8)
        #endif
    }
}

// MARK: - Entry point

let bundleID = Bundle.main.bundleIdentifier ?? "io.github.yyswn.stayon"
if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
