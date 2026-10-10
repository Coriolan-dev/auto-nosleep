// auto-nosleep: lets a MacBook stay awake with the lid closed on battery while an external
// display is connected (`pmset disablesleep 1`), but still idle-sleeps like normal macOS.
import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

let pmset = "/usr/bin/pmset"
let pollSeconds = 600
let debounceSeconds = 2.0
let noDisplayGraceSeconds = 15.0
var pendingSync: DispatchWorkItem?
var lastWake = Date()
var noDisplaySince: Date?

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}

func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String)? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = pipe
    do {
        try process.run()
    } catch {
        log("error: could not run \(path): \(error)")
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func sudoPmset(_ arguments: [String]) -> Bool {
    guard let result = run("/usr/bin/sudo", ["-n", pmset] + arguments) else { return false }
    if result.status != 0 {
        let command = arguments.joined(separator: " ")
        log("error: 'sudo pmset \(command)' exited \(result.status)")
        log("check /etc/sudoers.d/auto-nosleep")
    }
    return result.status == 0
}

func externalDisplayConnected() -> Bool {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    var filled: UInt32 = 0
    guard CGGetOnlineDisplayList(count, &displays, &filled) == .success else { return false }
    return displays.prefix(Int(filled)).contains { CGDisplayIsBuiltin($0) == 0 }
}

/// Seconds since the last keyboard/mouse/trackpad input or full wake, whichever is more recent.
func userIdleSeconds() -> TimeInterval {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    guard service != 0 else { return 0 }
    defer { IOObjectRelease(service) }
    let property = IORegistryEntryCreateCFProperty(
        service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)
    guard let nanoseconds = property?.takeRetainedValue() as? NSNumber else { return 0 }
    return min(Double(nanoseconds.uint64Value) / 1e9, Date().timeIntervalSince(lastWake))
}

/// Current `pmset -g` values for the active power source (sleep, displaysleep, SleepDisabled...).
func pmsetSettings() -> [String: Int]? {
    guard let result = run(pmset, ["-g"]), result.status == 0 else { return nil }
    var settings: [String: Int] = [:]
    for line in result.output.split(separator: "\n") {
        let fields = line.split(whereSeparator: \.isWhitespace)
        if fields.count >= 2, let value = Int(fields[1]) { settings[String(fields[0])] = value }
    }
    return settings
}

/// Idle delay macOS would apply for the current power source, or nil if it never idle-sleeps.
/// macOS doesn't system-sleep before the display sleeps, hence the max().
func idleSleepDelay(_ settings: [String: Int]) -> TimeInterval? {
    guard let sleep = settings["sleep"], let display = settings["displaysleep"],
          sleep > 0, display > 0 else { return nil }
    return TimeInterval(max(sleep, display) * 60)
}

func onACPower() -> Bool {
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    return IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String == "AC Power"
}

/// True if an app holds a power assertion that blocks normal idle sleep (video, calls, caffeinate).
func appBlocksIdleSleep() -> Bool {
    var status: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
          let counts = status?.takeRetainedValue() as? [String: NSNumber] else { return false }
    var types = ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep"]
    if onACPower() { types.append("PreventSystemSleep") }
    return types.contains { (counts[$0]?.intValue ?? 0) > 0 }
}

func idleSleepDue(_ settings: [String: Int]) -> Bool {
    guard let delay = idleSleepDelay(settings) else { return false }
    return userIdleSeconds() >= delay && !appBlocksIdleSleep()
}

/// Seconds left before a "no external display" reading counts. Unplugging one of several
/// screens (or a dock) can briefly report none, and enabling sleep then would put a
/// lid-closed Mac to sleep.
func noDisplayGraceRemaining(_ display: Bool) -> TimeInterval {
    if display {
        noDisplaySince = nil
        return 0
    }
    let since = noDisplaySince ?? Date()
    noDisplaySince = since
    return max(0, noDisplayGraceSeconds - Date().timeIntervalSince(since))
}

func sync() {
    guard let settings = pmsetSettings(), let current = settings["SleepDisabled"] else {
        log("error: could not read SleepDisabled from 'pmset -g'")
        return
    }
    let display = externalDisplayConnected()
    let grace = noDisplayGraceRemaining(display)
    let sleepDue = display && idleSleepDue(settings)
    let wanted = display && !sleepDue
    guard wanted != (current != 0) else { return }
    if grace > 0 {
        log("no external display seen; confirming in \(Int(grace.rounded(.up))) s")
        scheduleSync(after: grace)
        return
    }
    guard sudoPmset(["disablesleep", wanted ? "1" : "0"]) else { return }
    if wanted {
        log("external display connected, user active: sleep disabled")
    } else if sleepDue {
        log("idle timeout reached: sleep enabled, sleeping now")
        _ = sudoPmset(["sleepnow"])
    } else {
        log("no external display: sleep enabled")
    }
}

// Plugging a display in fires several events in a row; wait for things to settle.
func scheduleSync(after delay: TimeInterval = debounceSeconds) {
    pendingSync?.cancel()
    let item = DispatchWorkItem(block: sync)
    pendingSync = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
}

// On logout or unload, don't leave sleep disabled behind.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        _ = sudoPmset(["disablesleep", "0"])
        log("stopping")
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

// A full (user) wake restarts the idle clock and must re-disable sleep right away, before
// macOS puts a lid-closed, on-battery Mac back to sleep. Dark wakes don't post this.
_ = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
) { _ in
    lastWake = Date()
    sync()
}

let poller = DispatchSource.makeTimerSource(queue: .main)
poller.schedule(deadline: .now() + .seconds(pollSeconds), repeating: .seconds(pollSeconds))
poller.setEventHandler(handler: sync)
poller.resume()

// Display change events are only delivered reliably to a running NSApplication.
// `.prohibited` keeps it invisible: no Dock icon, no menu bar.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
_ = NotificationCenter.default.addObserver(
    forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
) { _ in
    log("display configuration changed")
    scheduleSync()
}

sync()
log("watching for display changes and idle time")
app.run()
