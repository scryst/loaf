// Loaf: a menu-bar cat that keeps this Mac awake only while agents are working,
// and plays a soft chime as the lid closes.
import AppKit
import SwiftUI
import AVFoundation
import UserNotifications
import CoreAudio
import IOKit
import IOKit.hid
import IOKit.pwr_mgt
import IOKit.ps

// MARK: - Event log (~/Library/Logs/Loaf/events.log): what happened around a lid close, with timestamps

enum EventLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Loaf/events.log")
    private static let queue = DispatchQueue(label: "loaf.eventlog")
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    static func write(_ text: String) {
        let line = "\(stamp.string(from: Date())) pid=\(getpid()) \(text)\n"
        queue.sync {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 256_000 {
                let old = url.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        }
    }
}

// MARK: - Power state

let systemTypes: Set<String> = ["PreventUserIdleSystemSleep", "NoIdleSleep", "NoIdleSleepAssertion", "PreventSystemSleep"]

func procName(_ pid: Int32) -> String {
    var buf = [CChar](repeating: 0, count: 1024)
    return proc_name(pid, &buf, 1024) > 0 ? String(cString: buf) : "pid \(pid)"
}

func parent(_ pid: Int32) -> Int32? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid > 1 else { return nil }
    return Int32(info.pbi_ppid)
}

/// The app a process belongs to: itself, or the nearest ancestor that is a real app (so a helper or a
/// `caffeinate` started from a terminal is shown as that app).
func owningApp(_ pid: Int32) -> NSRunningApplication? {
    var p: Int32? = pid
    for _ in 0..<8 {
        guard let cur = p else { return nil }
        if let app = NSRunningApplication(processIdentifier: cur), app.activationPolicy != .prohibited { return app }
        p = parent(cur)
    }
    return nil
}

/// Other processes with an active system-sleep assertion; display-only holds do not count.
func currentHolders() -> [String] {
    var raw: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
          let dict = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
    var names = Set<String>()
    for (pidNum, list) in dict {
        for a in list {
            let type = a["AssertionTrueType"] as? String ?? a["AssertType"] as? String ?? ""
            guard systemTypes.contains(type), (a[kIOPMAssertionLevelKey] as? NSNumber)?.intValue != 0 else { continue }
            // coreaudiod and friends hold on behalf of the app that is actually playing
            let pid = (a["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value ?? pidNum.int32Value
            if pid == getpid() || pidNum.int32Value == getpid() { continue }   // the chime's own short hold is not "something keeping the Mac up"
            let app = owningApp(pid)
            names.insert(app?.localizedName ?? procName(pid))
        }
    }
    return names.sorted()
}

enum IdleSleep {
    /// `keepAwake` includes working agents and their grace period. Manual sleep overrides both.
    static func shouldSleep(idleSeconds: Double, sleepMinutes: Int, keepAwake: Bool, allowSleep: Bool,
                            secondsSinceWake: Double, holders: [String]) -> Bool {
        sleepMinutes > 0 && idleSeconds > Double(sleepMinutes) * 60 &&
            (!keepAwake || allowSleep) && secondsSinceWake >= 120 && !holders.isEmpty
    }

    static func idleSeconds() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let ns = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        return ns.doubleValue / 1_000_000_000
    }

    /// The idle minutes after which macOS itself would sleep: the system sleep setting, but never before the screen
    /// sleeps (macOS keeps the system up while the display is on, so `sleep 1` with `displaysleep 10` means 10).
    /// 0 means never, from either setting.
    static func sleepMinutes(in settings: String) -> Int? {
        var values: [Substring: Int] = [:]
        for line in settings.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            if let key = fields.first, key == "sleep" || key == "displaysleep", fields.count > 1, let n = Int(fields[1]) {
                values[key] = n
            }
        }
        guard let sleep = values["sleep"] else { return nil }
        guard let display = values["displaysleep"] else { return sleep }
        return sleep == 0 || display == 0 ? 0 : max(sleep, display)
    }

    /// `pmset -g` reports the settings currently in use, including the current power source.
    static func sleepMinutes() -> Int? { pmsetOutput(["-g"]).flatMap { sleepMinutes(in: $0) } }

    /// What `pmset <args>` prints, or nil if it failed.
    static func pmsetOutput(_ args: [String]) -> String? {
        // posix_spawn, not Process + Pipe: Foundation leaked about 5 KB per call here, once a minute.
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        fds.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }   // no other spawn may inherit the write end and stall the read
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addclose(&actions, fds[1])
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = ([SleepHold.pmset] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let rc = posix_spawn(&pid, SleepHold.pmset, &actions, nil, argv, environ)
        close(fds[1])
        guard rc == 0 else { close(fds[0]); return nil }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fds[0], &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        close(fds[0])
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        guard status == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Alerts that must reach the user: a macOS notification, plus the command in `defaults write <bundle id> alertCommand
/// -array <program> <args...>` (Loaf adds the title and the body), for a phone. Off in headless checks and renders.
enum Alerts {
    static var enabled = false
    static func post(_ w: (title: String, body: String)) {
        guard enabled else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted else { EventLog.write("notification not allowed\(error.map { ": \($0.localizedDescription)" } ?? "")"); return }
            let c = UNMutableNotificationContent()
            c.title = w.title; c.body = w.body; c.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
        if let cmd = UserDefaults.standard.stringArray(forKey: "alertCommand") { run(cmd, w) }
    }
    @discardableResult static func run(_ cmd: [String], _ w: (title: String, body: String)) -> Process? {
        guard let exe = cmd.first else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(cmd.dropFirst()) + [w.title, w.body]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        if enabled { p.terminationHandler = { EventLog.write("alert command exited \($0.terminationStatus)") } }   // not from the checks
        do { try p.run(); return p } catch { EventLog.write("alert command failed to run: \(error)"); return nil }
    }
}

// MARK: - What is holding the screen and the Mac awake, as `pmset -g assertions` lists it by owning process

/// One hold from the "Listed by owning process" part of `pmset -g assertions`. `forPid` is the app a system daemon
/// holds for ("Created for PID: 41549." under a coreaudiod line: an app with its audio output left open).
struct PowerHold: Equatable { var pid: Int32; var process: String; var type: String; var name: String; var forPid: Int32? = nil }

enum PowerHolds {
    static let displayTypes: Set = ["NoDisplaySleepAssertion", "PreventUserIdleDisplaySleep", "InternalPreventDisplaySleep"]
    static let systemTypes: Set = ["NoIdleSleepAssertion", "PreventUserIdleSystemSleep", "PreventSystemSleep"]
    /// macOS's own bookkeeping: "the display is on" and "the user just typed", never a reason the screen stays on.
    static let bookkeeping: Set = ["powerd", "WindowServer"]

    static func parse(_ text: String) -> [PowerHold] {
        var holds: [PowerHold] = []
        var listed = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Listed by owning process") { listed = true; continue }
            if line.hasPrefix("Kernel Assertions") { listed = false; continue }
            guard listed else { continue }
            if line.hasPrefix("Created for PID:"), !holds.isEmpty {
                holds[holds.count - 1].forPid = Int32(line.dropFirst("Created for PID:".count).trimmingCharacters(in: CharacterSet(charactersIn: " .")))
                continue
            }
            // pid 41425(Discord): [0x0007c4040005a4b5] 02:35:52 NoDisplaySleepAssertion named: "Video Wake Lock"
            guard line.hasPrefix("pid "), let open = line.firstIndex(of: "("), let close = line.range(of: "): ["),
                  let pid = Int32(line[line.index(line.startIndex, offsetBy: 4)..<open]),
                  let named = line.range(of: " named: \"") else { continue }
            let fields = line[close.upperBound..<named.lowerBound].split(separator: " ")
            guard fields.count >= 3 else { continue }
            var name = String(line[named.upperBound...]).trimmingCharacters(in: .whitespaces)
            if name.hasSuffix("\"") { name.removeLast() }
            holds.append(PowerHold(pid: pid, process: String(line[line.index(after: open)..<close.lowerBound]),
                                   type: String(fields[2]), name: name))
        }
        return holds
    }

    static func live() -> [PowerHold] { IdleSleep.pmsetOutput(["-g", "assertions"]).map(parse) ?? [] }

    /// Holds that may be left behind and so never count against turning the screen off: Discord takes a "Video Wake
    /// Lock" per call or stream and can keep them for hours after it ends.
    /// Matched by app, not by name: Chrome uses the same name while a video really plays.
    static func forgotten(_ h: PowerHold) -> Bool { h.process.hasPrefix("Discord") && h.name == "Video Wake Lock" }

    /// Display holds that should keep the screen on.
    static func screenBlockers(_ holds: [PowerHold]) -> [PowerHold] {
        holds.filter { displayTypes.contains($0.type) && !bookkeeping.contains($0.process) && !forgotten($0) }
    }

    /// One card row per app, most holds first: what it holds ("screen on (15), audio") and how many holds in all.
    /// `app` names the app behind a pid (fallback: the process name).
    struct Row: Hashable { let app: String; let what: String; let count: Int }
    static func rows(_ holds: [PowerHold], me: Int32 = getpid(),
                     app: (Int32, String) -> String = { pid, process in owningApp(pid)?.localizedName ?? process }) -> [Row] {
        var counts: [String: [String: Int]] = [:], order: [String] = []
        for h in holds where !bookkeeping.contains(h.process) && h.pid != me && h.forPid != me {
            let what: String
            if displayTypes.contains(h.type) { what = "screen on" }
            else if systemTypes.contains(h.type) { what = h.process == "coreaudiod" ? "audio" : "awake" }
            else { continue }
            let name = app(h.forPid ?? h.pid, h.process)
            if counts[name] == nil { order.append(name) }
            counts[name, default: [:]][what, default: 0] += 1
        }
        return order.map { name -> Row in
            let kinds = counts[name]!.sorted { ($1.value, $0.key) < ($0.value, $1.key) }
            return Row(app: name, what: kinds.map { $0.value > 1 ? "\($0.key) (\($0.value))" : $0.key }.joined(separator: ", "),
                       count: kinds.reduce(0) { $0 + $1.value })
        }.sorted { ($1.count, $0.app) < ($0.count, $1.app) }
    }
}

enum ScreenIdle {
    /// Turn the screen off: the user has been away `minutes`, the screen is still on, and nothing that matters is holding it.
    static func shouldTurnOff(idleSeconds: Double, minutes: Int, screenAsleep: Bool, holds: [PowerHold]) -> Bool {
        minutes > 0 && !screenAsleep && idleSeconds >= Double(minutes) * 60 && PowerHolds.screenBlockers(holds).isEmpty
    }
    static var screenAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }
    static func turnOff() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SleepHold.pmset)
        p.arguments = ["displaysleepnow"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { EventLog.write("pmset displaysleepnow failed to run: \(error)") }
    }
}

enum BatteryAlert {
    static let levels = [20, 10]
    /// The level to alert for now (the lowest one crossed and not yet sent), and the levels sent so far on this charge.
    /// Plugging in, or charging back above 25%, starts over.
    static func next(percent: Int, onBattery: Bool, sent: Set<Int>) -> (alert: Int?, sent: Set<Int>) {
        guard onBattery, percent <= 25 else { return (nil, []) }
        let due = levels.filter { percent <= $0 && !sent.contains($0) }
        guard let level = due.min() else { return (nil, sent) }
        return (level, sent.union(due))
    }
    static func words(_ level: Int) -> (title: String, body: String) {
        level <= 10
            ? ("Mac battery at \(level)%", "Plug it in. Loaf has stopped keeping the Mac awake for agents, so it can sleep.")
            : ("Mac battery at \(level)%", "Plug it in soon. At 10% Loaf stops keeping the Mac awake for agents.")
    }
}

// MARK: - Audio output facts, so the log can say whether the speakers were able to make a sound

enum Output {
    private static func get<T>(_ dev: AudioObjectID, _ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ zero: T) -> T? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = zero
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }
    static var device: AudioObjectID? {
        let d: AudioObjectID? = get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
        return d == 0 ? nil : d
    }
    static var running: Bool? {
        guard let d = device, let v: UInt32 = get(d, kAudioDevicePropertyDeviceIsRunningSomewhere, 0) else { return nil }
        return v != 0
    }
    /// Is this process itself driving the output right now? (CoreAudio process objects, macOS 14.4+.)
    static var ownRunning: Bool? {
        var pid = getpid()
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var obj = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj) == noErr, obj != 0 else { return false }
        guard let v: UInt32 = get(obj, kAudioProcessPropertyIsRunningOutput, 0) else { return nil }
        return v != 0
    }
    static var summary: String {
        guard let d = device else { return "output=none" }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let name = AudioObjectGetPropertyData(d, &addr, 0, nil, &size, &cf) == noErr ? (cf?.takeRetainedValue() as String?) ?? "?" : "?"
        let vol: Float32? = get(d, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, 0)
        let mute: UInt32? = get(d, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, 0)
        return "output=\(name) volume=\(vol.map { String(format: "%.2f", $0) } ?? "n/a") muted=\(mute.map { String($0) } ?? "n/a") running=\(running.map { String($0) } ?? "n/a") ours=\(ownRunning.map { String($0) } ?? "n/a")"
    }
}

// MARK: - Chime (synthesised glass bell, two rising notes, under a second)

final class Chime: NSObject, AVAudioPlayerDelegate {
    static let shared = Chime()
    static let length = 0.8
    /// Tests play at volume 0: the whole audio path runs, nothing is heard.
    var silent = false
    private var player: AVAudioPlayer?

    override init() {
        super.init()
        player = try? AVAudioPlayer(data: Self.wav(), fileTypeHint: AVFileType.wav.rawValue)
        player?.delegate = self
        player?.prepareToPlay()   // decoded and ready, so the first play has no setup delay
    }

    static func wav() -> Data {
        let rate = 44100.0, n = Int(rate * length)
        var samples = [Float](repeating: 0, count: n)
        let notes: [(freq: Double, at: Double, gain: Double)] = [(1318.5, 0, 0.6), (1975.5, 0.09, 0.5)]
        let partials: [(mult: Double, gain: Double, tau: Double)] = [(1, 1, 0.3), (2.0, 0.22, 0.14), (3.01, 0.07, 0.07), (0.5, 0.12, 0.4)]
        for note in notes {
            let start = Int(note.at * rate)
            for i in start..<n {
                let t = Double(i - start) / rate
                let attack = min(1, t / 0.004)
                var v = 0.0
                for p in partials { v += p.gain * exp(-t / p.tau) * sin(2 * .pi * note.freq * p.mult * t) }
                samples[i] += Float(v * attack * note.gain * 0.4)
            }
        }
        let fade = Int(rate * 0.08)
        for i in 0..<fade { samples[n - 1 - i] *= Float(i) / Float(fade) }   // no click at the end
        var data = Data()
        func u32(_ x: UInt32) { withUnsafeBytes(of: x.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ x: UInt16) { withUnsafeBytes(of: x.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 2))
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        return data
    }

    var duration: Double { player?.duration ?? 0 }
    var isPlaying: Bool { player?.isPlaying ?? false }
    var remaining: Double { player.map { $0.isPlaying ? max(0, $0.duration - $0.currentTime) : 0 } ?? 0 }

    @discardableResult
    func play(reason: String) -> Bool {
        guard let p = player else { EventLog.write("chime FAILED: no player"); return false }
        p.stop()
        p.currentTime = 0
        p.volume = silent ? 0 : 1
        let ok = p.play()
        EventLog.write("chime started (\(reason)) play()=\(ok) \(Output.summary)\(silent ? " [silent test]" : "")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak p] in   // is the clock really moving?
            guard let p else { return }
            EventLog.write("chime +150ms playing=\(p.isPlaying) position=\(String(format: "%.2f", p.currentTime)) s \(Output.summary)")
        }
        return ok
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        EventLog.write("chime finished ok=\(flag) \(Output.summary)")
        player.prepareToPlay()
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        EventLog.write("chime decode error \(String(describing: error))")
    }
}

// MARK: - The lid
//
// Why the chime used to be silent: audio is not muted by the lid, it is muted by sleep. The moment the lid switch
// fires, powerd starts clamshell sleep and coreaudiod goes to `DarkWakeSilenceBuffers` (logged within 50 ms of
// `Observed clamshell state change: Closed`), and `NSSound play` logs "in dark wake" and does nothing. So while
// keep-awake is on, SleepHold sets `pmset disablesleep 1`: closing the lid then leaves the Mac running (display off,
// no sleep) and the chime plays in full. Loaf never sleeps the Mac itself.

func lidClosed() -> Bool {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    defer { IOObjectRelease(root) }
    let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
    return (v?.takeRetainedValue() as? Bool) ?? false
}

final class LidWatch {
    /// Start the chime flow when the lid falls below this many degrees while closing; it re-arms once the lid is above `rearmAngle`.
    static let triggerAngle = 45.0, rearmAngle = 60.0
    var onClose: ((String) -> Void)?
    /// Appended to the lid log lines: keep-awake, hold and SleepDisabled state.
    var context: () -> String = { "" }
    private(set) var angle: Double?
    private var device: IOHIDDevice?
    private var manager: IOHIDManager?
    private var timer: DispatchSourceTimer?
    private var interval = 0.0
    private var last: Double?
    private var armed = false
    private var wasClosed = lidClosed()
    private var readFailed = false
    private var notifyPort: IONotificationPortRef?
    private var rootNotifier: io_object_t = 0

    func start() {
        openSensor()
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        if let notifyPort {
            CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .commonModes)
            IOServiceAddInterestNotification(notifyPort, root, kIOGeneralInterest, { refcon, _, _, _ in
                guard let refcon else { return }
                Unmanaged<LidWatch>.fromOpaque(refcon).takeUnretainedValue().clamshellMaybeChanged()
            }, Unmanaged.passUnretained(self).toOpaque(), &rootNotifier)
        }
        IOObjectRelease(root)
        EventLog.write("lid watch started: angle sensor \(device == nil ? "NOT available" : "ok, \(angle.map { String(format: "%.0f", $0) } ?? "?")°"), clamshell=\(wasClosed ? "closed" : "open")")
        if device != nil { reschedule(0.08) }
    }

    private func openSensor() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // The lid-angle sensor on MacBook Pros: Apple vendor, product 0x8104, sensor page, usage 0x8A.
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x05AC, kIOHIDProductIDKey: 0x8104,
                                          kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A] as CFDictionary)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        manager = m
        device = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>)?.first
        if let a = readAngle() { angle = a; last = a; armed = a > Self.rearmAngle }
    }

    private func readAngle() -> Double? {
        guard let device else { return nil }
        var buf = [UInt8](repeating: 0, count: 8)
        var len = buf.count
        let rc = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &buf, &len)
        guard rc == kIOReturnSuccess, len >= 3 else {
            if !readFailed { readFailed = true; EventLog.write("angle read failed rc=\(String(rc, radix: 16))") }
            return nil
        }
        readFailed = false
        let a = Double(Int(buf[2]) << 8 | Int(buf[1]))
        return a <= 360 ? a : nil
    }

    private func reschedule(_ seconds: Double) {
        guard seconds != interval else { return }
        interval = seconds
        if timer == nil {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
        timer?.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(5))
    }

    private func tick() {
        guard let a = readAngle() else { reschedule(1); return }
        feed(angle: a)
        reschedule(a < 90 ? 0.025 : 0.08)   // watch closely once the lid is coming down; barely at all while you work
    }

    /// The detector. Real sensor readings and the test hook both come through here.
    func feed(angle a: Double) {
        let previous = last
        angle = a
        last = a
        if a > Self.rearmAngle { armed = true }
        guard armed, let previous, a < Self.triggerAngle, a < previous else { return }
        armed = false
        EventLog.write(String(format: "lid angle %.0f° falling through %.0f° (was %.0f°) [%@]", a, Self.triggerAngle, previous, context()))
        onClose?("angle")
    }

    func clamshellMaybeChanged() {
        let closed = lidClosed()
        guard closed != wasClosed else { return }
        wasClosed = closed
        EventLog.write("clamshell switch: lid \(closed ? "CLOSED" : "OPENED")\(angle.map { String(format: ", last angle %.0f°", $0) } ?? "") [\(context())]")
        if closed { onClose?("clamshell") } else { armed = false }
    }

    /// After wake the lid may have moved: forget the last reading, and re-arm only once it is seen open.
    func resetAfterWake() { last = nil; armed = false }

    /// For the test hook: pretend the clamshell switch changed.
    func simulateClamshell(closed: Bool) {
        EventLog.write("clamshell switch: lid \(closed ? "CLOSED" : "OPENED") [simulated; \(context())]")
        if closed { onClose?("clamshell") }
    }
}

// MARK: - Sleep hold: while keep-awake is on, closing the lid must not sleep the Mac
//
// macOS sleeps on lid close even when an app holds a "keep awake" assertion; the one switch that stops that is
// `pmset -a disablesleep 1`. Loaf holds it exactly while something is keeping the Mac awake (the cat is awake), so
// closing the lid leaves the system running (the display goes dark, the Mac does not sleep) and the lid chime plays in full.
//
// Needs the sudoers drop-in from install-sleep-helper.sh (only `pmset -a disablesleep 0|1`, no password). Without it
// Loaf logs "sleep helper NOT available" and behaves as before.
//
// `disablesleep` must never stay on by accident. It goes back to 0:
//   1. when keep-awake turns off (Model.refresh -> sync);
//   2. on Quit and on SIGTERM;
//   3. at every launch, so a crash relaunch (KeepAlive) cleans up; this also probes whether the helper works;
//   4. by loaf-watchdog.sh (second LaunchAgent, every 60 s): resets it if Loaf is not running at all;
//   5. by the safety floor: on battery at 10% or less, or a serious/critical thermal state, the hold is released and
//      stays off until the condition clears (battery above 14% or plugged in, thermal below serious).

final class SleepHold {
    static let pmset = "/usr/bin/pmset"
    /// Only the `--fake-sudo` test hook changes this.
    static var sudo = "/usr/bin/sudo"
    private(set) var available = false
    private(set) var held = false
    /// Why the safety floor is keeping the hold off, while it is.
    private(set) var floor: String?
    private var wanted = false
    private var pending = 0
    private var lastReassert = Date.distantPast
    private let queue = DispatchQueue(label: "loaf.sleephold")
    /// Tests replace the safety-floor reading, the lid, the display check and the sleep call.
    var floorProbe: ((Bool) -> String?)?
    var lidIsClosed: () -> Bool = lidClosed
    var externalDisplayAttached: () -> Bool = SleepHold.externalDisplay
    var sleepNow: () -> Void = SleepHold.pmsetSleepNow

    static func externalDisplay() -> Bool {
        NSScreen.screens.contains { sc in
            (sc.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) == 0 } ?? false
        }
    }

    /// `pmset sleepnow` needs no root. Shared by lid release and the idle-sleep check.
    static func pmsetSleepNow() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pmset)
        p.arguments = ["sleepnow"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { EventLog.write("pmset sleepnow failed to run: \(error)") }
    }

    /// The hold was just released (grace over, or the safety floor). If the lid is already shut nothing will sleep the Mac
    /// by itself (Claude.app's own keep-awake still blocks idle sleep), so do it now. Lid open, or an external display
    /// attached (clamshell mode): leave it alone.
    private func releasedWithLidShut(_ why: String) {
        guard lidIsClosed() else { EventLog.write("hold released (\(why)); lid is open, not sleeping"); return }
        guard !externalDisplayAttached() else { EventLog.write("hold released (\(why)); lid is closed but an external display is attached, not sleeping"); return }
        EventLog.write("hold released (\(why)) with the lid closed: sleeping the Mac now")
        sleepNow()
    }

    static var sleepDisabled: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        return (IORegistryEntryCreateCFProperty(root, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) ?? false
    }

    static func battery() -> (percent: Int, onBattery: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let pct = d[kIOPSCurrentCapacityKey] as? Int else { continue }
            return (pct, d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue)
        }
        return nil
    }

    /// The safety floor: why holding the Mac awake with the lid shut is not safe right now, or nil.
    /// `tripped` widens the battery margin (10% to trip, 14% or plugged in to clear) so it does not flap.
    static func floorReason(tripped: Bool) -> String? {
        switch ProcessInfo.processInfo.thermalState {
        case .serious: return "thermal state serious"
        case .critical: return "thermal state critical"
        default: break
        }
        if let b = battery(), b.onBattery, b.percent <= (tripped ? 14 : 10) { return "battery at \(b.percent)%" }
        return nil
    }

    var summary: String { "keep-awake=\(wanted ? "on" : "off") hold=\(held ? "yes" : "no") SleepDisabled=\(Self.sleepDisabled ? "yes" : "no")\(floor.map { " floor(\($0))" } ?? "")" }

    /// `sudo -n pmset -a disablesleep N`; returns the exit status (1 when sudo wants a password).
    private func pm(_ value: Int) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.sudo)
        p.arguments = ["-n", Self.pmset, "-a", "disablesleep", String(value)]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Launch: reset disablesleep to 0 and learn whether the helper works, then apply whatever keep-awake wants.
    func probe() {
        let was = Self.sleepDisabled
        pending += 1
        queue.async {
            let rc = self.pm(0)
            DispatchQueue.main.async {
                self.pending -= 1
                self.available = rc == 0
                EventLog.write("sleep helper \(rc == 0 ? "available" : "NOT available (sudo -n pmset rc=\(rc)); closing the lid will still sleep the Mac"); launch reset: SleepDisabled was \(was), now \(Self.sleepDisabled)")
                self.sync(awake: self.wanted)
            }
        }
    }

    /// Called whenever keep-awake may have changed, and every few seconds (that is the safety-floor check).
    func sync(awake: Bool) {
        wanted = awake
        guard available else { return }
        let floorCheck = floorProbe ?? { Self.floorReason(tripped: $0) }
        if awake, let why = floorCheck(floor != nil) {
            if floor != why { EventLog.write("safety floor: \(why); releasing the sleep hold until it clears"); floor = why }
            set(false, why: "safety floor", thenSleep: true)
            return
        }
        if floor != nil { EventLog.write("safety floor cleared"); floor = nil }
        if awake != held { set(awake, why: awake ? "keep-awake on" : "keep-awake off", thenSleep: !awake) }
        else if held, pending == 0, !Self.sleepDisabled, Date().timeIntervalSince(lastReassert) > 60 {
            lastReassert = Date()
            set(true, why: "re-asserting (SleepDisabled was cleared elsewhere)", force: true)
        }
    }

    private func set(_ on: Bool, why: String, force: Bool = false, thenSleep: Bool = false) {
        guard force || on != held else { return }
        held = on
        pending += 1
        let t0 = Date()
        queue.async {
            var rc = self.pm(on ? 1 : 0)
            var tries = 1
            while rc != 0, !on, tries < 3 { rc = self.pm(0); tries += 1 }   // releasing is the one that must not fail
            DispatchQueue.main.async {
                self.pending -= 1
                EventLog.write(String(format: "sleep hold %@ (%@): disablesleep %d rc=%d SleepDisabled=%@ (%.0f ms)", on ? "SET" : "RELEASED", why,
                                      on ? 1 : 0, rc, Self.sleepDisabled ? "yes" : "no", Date().timeIntervalSince(t0) * 1000))
                if rc != 0 && on { self.available = false; self.held = false }
                if rc != 0 && !on { EventLog.write("WARNING: could not release disablesleep; the watchdog and the next launch will retry") }
                if thenSleep && !on && !self.held { self.releasedWithLidShut(why) }   // not if a new hold was set meanwhile
            }
        }
    }

    /// Quit and SIGTERM: release synchronously (after any set still in flight).
    func releaseNow() {
        guard available, held || pending > 0 else { return }
        held = false
        let rc = queue.sync { pm(0) }
        EventLog.write("sleep hold released on quit rc=\(rc) SleepDisabled=\(Self.sleepDisabled ? "yes" : "no")")
    }
}

// MARK: - Busy signal: are agents actually working?
//
// Claude Code hooks (loaf-busy-hook.sh, merged into ~/.claude/settings.json by install-hooks.py) touch
// `~/Library/Application Support/Loaf/busy/<session_id>` on every prompt and tool call and remove it on Stop / SessionEnd.
// A file touched in the last 3 minutes means that session is working; an older one is a crashed session and is ignored.
// A stopped turn runs no Stop hook, so Busy.stoppedAt reads the transcript's tail to drop it at once.
// Codex has no hooks here, so its rollout files (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl, appended to as it works)
// count the same way. App assertions never count as agents and cannot keep an idle Mac awake after grace ends.

/// Directory entries by readdir. Foundation's contentsOfDirectory leaks a few hundred bytes to several KB per call, and
/// the 5 s and 60 s scans made 100k of them over a few days (Loaf grew to 250 MB). `prefix` skips names before a String is built.
func listDir(_ path: String, prefix: String? = nil) -> [String] {
    guard let dp = opendir(path) else { return [] }
    defer { closedir(dp) }
    var names: [String] = []
    while let e = readdir(dp) {
        let name: String? = withUnsafePointer(to: &e.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(e.pointee.d_namlen) + 1) { c in
                if c[0] == 0x2E, c[1] == 0 || (c[1] == 0x2E && c[2] == 0) { return nil }   // "." and ".."
                if let prefix, strncmp(c, prefix, prefix.utf8.count) != 0 { return nil }
                return String(cString: c)
            }
        }
        if let name { names.append(name) }
    }
    return names
}

/// When a file was made, or nil.
func birth(_ path: String) -> Date? {
    var st = stat()
    guard stat(path, &st) == 0 else { return nil }
    return Date(timeIntervalSince1970: Double(st.st_birthtimespec.tv_sec))
}

/// The first `limit` bytes of a file as text (POSIX read: no Foundation file APIs in the scans, see listDir).
func head(_ path: String, _ limit: Int) -> String? {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var buf = [UInt8](repeating: 0, count: limit)
    let n = read(fd, &buf, limit)
    return n > 0 ? String(decoding: buf.prefix(n), as: UTF8.self) : nil
}

/// The JSON string value of the first `"key":"..."` in `text`, unescaped.
func jsonString(_ key: String, in text: String) -> String? {
    guard let r = text.range(of: "\"\(key)\":\"") else { return nil }
    var out = "\"", escaped = false
    for c in text[r.upperBound...] {
        out.append(c)
        if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { break }
    }
    guard out.count > 1, out.last == "\"", let d = out.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed)) as? String
}

/// A name for a Claude session id: the title the Claude app shows for it, else its project folder, else nil.
/// The app keeps one JSON record per session under claude-code-sessions/<account>/<org>/local_*.json, with
/// cliSessionId and title in its first few hundred bytes. Read only while the card is open, at most every 30 s.
enum SessionNames {
    static var appRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions").path
    static var projectsRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects").path
    static var titles: [String: String] = [:]
    private static var folders: [String: String] = [:]
    private static var indexedAt = Date.distantPast

    static func name(_ id: String, now: Date = Date()) -> String? {
        if let t = titles[id] { return t }
        if now.timeIntervalSince(indexedAt) > 30 {
            indexedAt = now
            reindex()
            if let t = titles[id] { return t }
        }
        if let f = folders[id] { return f }
        let f = folder(id)
        if let f { folders[id] = f }
        return f
    }

    private static func reindex() {
        var found: [String: String] = [:]
        for a in listDir(appRoot) { for b in listDir(appRoot + "/" + a) {
            let dir = appRoot + "/" + a + "/" + b
            for f in listDir(dir, prefix: "local_") where f.hasSuffix(".json") {
                guard let text = head(dir + "/" + f, 4096), let title = jsonString("title", in: text), !title.isEmpty else { continue }
                for key in ["cliSessionId", "lastAssistantCliSessionId"] { if let id = jsonString(key, in: text) { found[id] = title } }
            }
        } }
        titles = found
    }

    /// A terminal session has no app record: use the last folder of the cwd in its transcript.
    private static func folder(_ id: String) -> String? {
        for slug in listDir(projectsRoot) {
            let path = projectsRoot + "/" + slug + "/" + id + ".jsonl"
            guard mtime(path) != nil else { continue }
            return head(path, 16384).flatMap { jsonString("cwd", in: $0) }.map { ($0 as NSString).lastPathComponent }
        }
        return nil
    }
}

/// Last modification time of a path (following symlinks), or nil.
func mtime(_ path: String) -> Date? {
    var st = stat()
    guard stat(path, &st) == 0 else { return nil }
    return Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
}

enum Busy {
    static var dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Loaf/busy")
    static var codexRoot: URL? = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    static let fresh = 180.0, grace = 120.0, purge = 3600.0
    /// `sessions`: each working Claude session id with when its busy file was made (the hook makes it on the turn's first
    /// prompt or tool call and removes it on Stop, so its birth time is when this stretch of work began).
    struct Scan: Equatable { var claude = 0; var codex = 0; var sessions: [String: Date] = [:]; var total: Int { claude + codex } }

    /// Where Claude Code puts background task output: <root>/<project slug>/<session id>/tasks/*.output. A background shell
    /// writes its output there; a background subagent's .output is a symlink to its transcript, which grows while it runs.
    static var tasksRoot: URL? = URL(fileURLWithPath: "/private/tmp/claude-\(getuid())")
    /// An output file written to within `fresh` seconds, or held open for writing by a live process (a quiet step of a long
    /// gate writes nothing for minutes). Neither test counts a file once it was first seen more than `openLimit` ago, so a
    /// forgotten server that keeps logging cannot keep the lid-shut Mac awake all night.
    static let openLimit = 2 * 3600.0
    /// When each output file (by its real path) was first seen counting; files no longer seen are dropped each scan.
    private static var firstSeen: [String: Date] = [:]
    /// `bySession`: how many counting outputs each session has, and when the oldest of them was made (task start).
    struct Background { var recent = 0; var open = 0; var total: Int { recent + open }; var millis = 0.0
                        var bySession: [String: (count: Int, since: Date)] = [:] }

    /// The session id in a task output path: <root>/<project slug>/<session id>/tasks/<task>.output.
    static func session(ofTask path: String) -> String? {
        let parts = path.split(separator: "/")
        guard let i = parts.lastIndex(of: "tasks"), i > 0 else { return nil }
        return String(parts[i - 1])
    }
    private static func born(_ st: stat) -> Date { Date(timeIntervalSince1970: Double(st.st_birthtimespec.tv_sec)) }
    private static func count(_ b: inout Background, _ path: String, since: Date) {
        guard let id = session(ofTask: path) else { return }
        let old = b.bySession[id]
        b.bySession[id] = ((old?.count ?? 0) + 1, min(old?.since ?? since, since))
    }

    /// The kernel's spelling of a path (Foundation's resolvingSymlinksInPath turns /private/tmp into /tmp).
    private static func real(_ path: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(path, &buf) != nil ? String(cString: buf) : path
    }

    private static func taskFiles(under root: URL) -> [String] {
        var out: [String] = []
        for slug in listDir(root.path) {
            let slugPath = root.path + "/" + slug
            for session in listDir(slugPath) {
                let tasks = slugPath + "/" + session + "/tasks"
                for f in listDir(tasks) where f.hasSuffix(".output") && f.count > 7 { out.append(tasks + "/" + f) }
            }
        }
        return out
    }

    /// Paths under `prefix` that some live process of ours has open for writing (libproc; about 15 to 35 ms for ~7,700 fds).
    private static func openForWriting(prefix: String) -> Set<String> {
        var hits = Set<String>()
        var pids = [pid_t](repeating: 0, count: 4096)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        for pid in pids.prefix(max(n, 0)) where pid > 0 {
            var info = proc_bsdshortinfo()
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size)) > 0, info.pbsi_uid == getuid() else { continue }
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 8)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
            for fd in fds.prefix(max(Int(got), 0) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var vi = vnode_fdinfowithpath()
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0,
                      vi.pfi.fi_openflags & 3 != 0 else { continue }   // O_WRONLY or O_RDWR
                let path = withUnsafePointer(to: &vi.pvip.vip_path) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
                if path.hasPrefix(prefix) && path.contains("/tasks/") { hits.insert(path) }
            }
        }
        return hits
    }

    /// Run about once a minute. Every session, not just those with a busy file: Stop has already removed that.
    static func scanBackground(now: Date) -> Background {
        var b = Background()
        guard let root = tasksRoot else { return b }
        let t0 = CACurrentMediaTime()
        var young = Set<String>(), candidates = 0, seen: [String: Date] = [:]
        for f in taskFiles(under: root) {
            var st = stat()
            guard stat(f, &st) == 0 else { continue }   // follows the symlink to the subagent transcript
            let age = now.timeIntervalSince(Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec)))
            guard age <= openLimit else { continue }
            let path = real(f), first = firstSeen[path] ?? now
            seen[path] = first
            guard now.timeIntervalSince(first) <= openLimit else { continue }   // still written to, but for too long
            if age <= fresh { b.recent += 1; young.insert(path); count(&b, f, since: born(st)) } else { candidates += 1 }
        }
        if candidates > 0 {   // only look at open files when an older output file exists that could still be held
            for path in openForWriting(prefix: real(root.path)) {
                var st = stat()
                guard stat(path, &st) == 0, now.timeIntervalSince(Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec))) <= openLimit,
                      !young.contains(path) else { continue }
                let first = seen[path] ?? firstSeen[path] ?? now
                seen[path] = first
                guard now.timeIntervalSince(first) <= openLimit else { continue }
                b.open += 1; count(&b, path, since: born(st))
            }
        }
        firstSeen = seen
        b.millis = (CACurrentMediaTime() - t0) * 1000
        return b
    }

    /// Claude Code runs no Stop hook when you stop a turn (Esc or the app's stop button), so its busy file would count
    /// for up to `fresh` more seconds. A stopped turn ends its transcript
    /// (~/.claude/projects/<slug>/<id>.jsonl) with a user line "[Request interrupted by user…]". Returns when it was
    /// written, or nil when the last user or assistant line in the transcript's tail is anything else.
    private static var transcripts: [String: String] = [:]
    private static var stopCache: [String: (stamp: Date, at: Date?)] = [:]
    private static let isoTime: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static func stoppedAt(_ id: String) -> Date? {
        let root = SessionNames.projectsRoot
        if transcripts[id].map({ mtime($0) == nil }) ?? true {
            transcripts[id] = listDir(root).lazy.map { root + "/" + $0 + "/" + id + ".jsonl" }.first { mtime($0) != nil }
        }
        guard let path = transcripts[id], let stamp = mtime(path) else { return nil }
        if let c = stopCache[id], c.stamp == stamp { return c.at }
        var at: Date? = nil
        let fd = open(path, O_RDONLY)
        if fd >= 0 {
            defer { close(fd) }
            let size = lseek(fd, 0, SEEK_END), want = Int(min(size, 65536))
            var buf = [UInt8](repeating: 0, count: want)
            let n = pread(fd, &buf, want, size - off_t(want))
            var lines = buf.prefix(max(n, 0)).split(separator: 0x0A)
            if size > want, !lines.isEmpty { lines.removeFirst() }   // a partial line
            for l in lines.reversed() {
                guard let d = try? JSONSerialization.jsonObject(with: Data(l)) as? [String: Any],
                      let type = d["type"] as? String, type == "user" || type == "assistant" else { continue }
                let first = ((d["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first
                if type == "user", let text = first?["text"] as? String, text.hasPrefix("[Request interrupted by user"),
                   let t = d["timestamp"] as? String { at = isoTime.date(from: t) }
                break
            }
        }
        stopCache[id] = (stamp, at)
        return at
    }

    static func scan(now: Date) -> Scan {
        var s = Scan()
        for name in listDir(dir.path) {
            let path = dir.path + "/" + name
            guard let m = mtime(path) else { continue }
            let age = now.timeIntervalSince(m)
            // a hook touch more than 5 s after the stop is a new prompt or tool call: the session is working again
            if age <= fresh, age > 5, let stop = stoppedAt(name), m <= stop + 5 { continue }
            if age <= fresh { s.claude += 1; s.sessions[name] = birth(path) ?? m } else if age > purge { try? FileManager.default.removeItem(atPath: path) }   // our own leftovers from a crashed session
        }
        if let root = codexRoot {
            let cal = Calendar.current
            for back in 0...1 {   // today and yesterday (a session can run across midnight)
                guard let day = cal.date(byAdding: .day, value: -back, to: now) else { continue }
                let c = cal.dateComponents([.year, .month, .day], from: day)
                let d = root.path + String(format: "/%04d/%02d/%02d", c.year!, c.month!, c.day!)
                for f in listDir(d, prefix: "rollout-") {
                    if let m = mtime(d + "/" + f), now.timeIntervalSince(m) <= fresh { s.codex += 1 }
                }
            }
        }
        return s
    }
}

// MARK: - Model

final class Model: ObservableObject {
    /// Agents are working, or finished less than `Busy.grace` ago. This drives the cat and the sleep hold.
    @Published var awake = false
    @Published var scan = Busy.Scan()
    @Published var allowSleep = false
    @Published var chimeOnClose: Bool = UserDefaults.standard.object(forKey: "chimeOnClose") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(chimeOnClose, forKey: "chimeOnClose")
            EventLog.write("lid chime switched \(chimeOnClose ? "on" : "off")")
        }
    }
    /// Turn the screen off after `screenOffMinutes` (default 20; `defaults write <bundle id> screenOffMinutes`) without
    /// input when only forgotten holds (PowerHolds.forgotten) keep it on.
    @Published var screenOffWhenIdle: Bool = UserDefaults.standard.object(forKey: "screenOffWhenIdle") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(screenOffWhenIdle, forKey: "screenOffWhenIdle")
            EventLog.write("screen off when idle switched \(screenOffWhenIdle ? "on" : "off")")
        }
    }
    var screenOffMinutes: Int { (UserDefaults.standard.object(forKey: "screenOffMinutes") as? Int).map { max($0, 1) } ?? 20 }
    /// The internal battery, read every refresh; nil on a Mac without one.
    struct Battery: Equatable { let percent: Int; let onBattery: Bool }
    @Published var battery: Battery?
    private var batterySent: Set<Int> = []
    /// What other apps hold awake, for the card; read while the card is open, at most every 10 s.
    @Published var appHolds: [PowerHolds.Row] = []
    private var appHoldsAt = Date.distantPast
    let film = Film()
    let hold = SleepHold()
    var onChange: (() -> Void)?
    var lastChime = Date.distantPast
    private var lastBusy: Date?
    private var lastBackground = Date.distantPast
    @Published var background = Busy.Background()
    private var lastWake = Date()
    var agents: Int { scan.total + background.total }

    /// One row per Claude session keeping the Mac awake: working now, background tasks still running, or both.
    struct Holder: Identifiable, Equatable { let id: String; let name: String; let working: Bool; let tasks: Int; let since: Date }
    func holders(now: Date = Date()) -> [Holder] {
        Set(scan.sessions.keys).union(background.bySession.keys).map { id in
            let bg = background.bySession[id]
            let since = [scan.sessions[id], bg?.since].compactMap { $0 }.min() ?? now
            return Holder(id: id, name: SessionNames.name(id, now: now) ?? "Claude session", working: scan.sessions[id] != nil,
                          tasks: bg?.count ?? 0, since: since)
        }.sorted { ($0.since, $0.id) < ($1.since, $1.id) }
    }

    /// What the cat is doing, in the words the panel and the menu bar use.
    enum Mood { case watching, winding, napping, asleep }
    var mood: Mood {
        if allowSleep { return agents > 0 ? .napping : .asleep }
        if awake { return agents > 0 ? .watching : .winding }
        return .asleep
    }

    func toggleAllowSleep() {
        allowSleep.toggle()
        EventLog.write("Allow sleep switched \(allowSleep ? "on" : "off") manually")
        refresh()
    }

    func resetAfterWake(now: Date = Date()) {
        lastWake = now
        if allowSleep {
            allowSleep = false
            EventLog.write("Allow sleep cleared automatically on system wake")
        }
        refresh(now: now)
    }

    /// Called once a minute by the app, never by headless checks or renders.
    func checkIdleSleep(now: Date = Date()) {
        // at the battery floor (10%) agents no longer keep the Mac up: it sleeps when idle like any other day
        let keepAwake = awake && hold.floor == nil
        guard !keepAwake, now.timeIntervalSince(lastWake) >= 120,
              let minutes = IdleSleep.sleepMinutes(), minutes > 0 else { return }
        let holders = currentHolders()
        guard let idle = IdleSleep.idleSeconds(),
              IdleSleep.shouldSleep(idleSeconds: idle, sleepMinutes: minutes, keepAwake: keepAwake, allowSleep: allowSleep,
                                    secondsSinceWake: now.timeIntervalSince(lastWake), holders: holders) else { return }
        EventLog.write("idle \(Int(idle / 60))m with \(awake ? "agents held off by the safety floor (\(hold.floor ?? ""))" : "no agents"); app holds \(holders.joined(separator: ", ")) ignored: sleeping the Mac now")
        SleepHold.pmsetSleepNow()
    }

    /// Called once a minute by the app. Reads the holds only once the user has been away long enough.
    func checkScreenIdle() {
        guard screenOffWhenIdle, !ScreenIdle.screenAsleep, let idle = IdleSleep.idleSeconds(),
              idle >= Double(screenOffMinutes) * 60 else { return }
        let holds = PowerHolds.live()
        guard ScreenIdle.shouldTurnOff(idleSeconds: idle, minutes: screenOffMinutes, screenAsleep: false, holds: holds) else { return }
        let forgotten = holds.filter(PowerHolds.forgotten)
        EventLog.write("idle \(Int(idle / 60))m and " + (forgotten.isEmpty ? "nothing holds the screen on" :
            "only forgotten holds keep the screen on (\(forgotten.count) from \(Set(forgotten.map(\.process)).sorted().joined(separator: ", ")))") + ": screen off")
        ScreenIdle.turnOff()
    }

    /// The card's list of other apps holding the screen or the Mac awake.
    func refreshAppHolds(now: Date = Date()) {
        guard now.timeIntervalSince(appHoldsAt) >= 10 else { return }
        appHoldsAt = now
        let rows = PowerHolds.rows(PowerHolds.live())
        if rows != appHolds { appHolds = rows }
    }

    private func checkBattery() {
        let b = SleepHold.battery().map { Battery(percent: $0.percent, onBattery: $0.onBattery) }
        if b != battery { battery = b }
        guard let b else { return }
        let (alert, sent) = BatteryAlert.next(percent: b.percent, onBattery: b.onBattery, sent: batterySent)
        batterySent = sent
        if let alert { Alerts.post(BatteryAlert.words(alert)); EventLog.write("battery at \(b.percent)% on battery: \(alert)% alert sent") }
    }

    func refresh(now: Date = Date()) {
        checkBattery()
        let scan = Busy.scan(now: now)
        if scan != self.scan { self.scan = scan }
        if now.timeIntervalSince(lastBackground) >= 60 || now < lastBackground {   // about once a minute
            lastBackground = now
            let b = Busy.scanBackground(now: now)
            // only when background work starts or stops (or a scan is slow): the count moves almost every minute and buried
            // the lid and hold events
            if (b.total > 0) != (background.total > 0) || b.millis > 250 { EventLog.write("background tasks: \(b.recent) written to recently, \(b.open) held open (\(String(format: "%.0f", b.millis)) ms)") }
            background = b
        }
        let total = scan.total + background.total
        if total > 0 { lastBusy = now }
        let graceLeft = lastBusy.map { Busy.grace - now.timeIntervalSince($0) } ?? 0
        let a = !allowSleep && (total > 0 || graceLeft > 0)
        if a != awake {
            EventLog.write(a ? "agents busy (\(scan.claude) Claude, \(scan.codex) Codex, \(background.total) background): keep-awake on" :
                           (allowSleep ? "Allow sleep: keep-awake off" : "agents idle for \(Int(Busy.grace)) s: keep-awake off"))
            awake = a; film.set(awake: a)
        }
        hold.sync(awake: a)   // keep-awake on = lid close does not sleep; also the battery / thermal safety floor
        onChange?()
    }

    /// One call per trigger: "angle" (the lid is coming down) or "clamshell" (the lid switch fired). Both fire for one
    /// close; the chime plays once, at the first.
    func lidDidClose(reason: String) {
        EventLog.write("lid close detected (\(reason)); \(hold.summary)")
        guard chimeOnClose else { EventLog.write("chime skipped: Lid chime is off"); return }
        let since = Date().timeIntervalSince(lastChime)
        guard since > 3 else { EventLog.write(String(format: "chime skipped: already chimed %.2f s ago", since)); return }
        lastChime = Date()
        Chime.shared.play(reason: reason)
    }
}

// MARK: - The cat: a riso-printed film, cut by art/clips.py into short clips that all start and end on one of two
// held poses (awake, asleep), so any clip can follow any other with no jump.

enum Loaf {
    static let accent = Color(red: 0.94, green: 0.49, blue: 0.24)
    static let dir: URL? = [Bundle.main.resourceURL?.appendingPathComponent("loaf"),
                            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("loaf")]
        .compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("light-idle_a.mp4").path) }
    /// Clips that start and end on the same pose, with how often each comes up. Quiet ones dominate.
    static let awakeClips: [(String, Int)] = [("idle_a", 3), ("idle_b", 3), ("idle_c", 3), ("blink", 3),
                                              ("earflick", 1), ("lookaround", 1), ("tilt", 1), ("squint", 1)]
    static let sleepClips: [(String, Int)] = [("sleep_idle", 4), ("sleepear", 1), ("sleeptail", 1)]
    /// The pose a clip ends on.
    static func endsAwake(_ clip: String) -> Bool { clip == "wake" || awakeClips.contains { $0.0 == clip } }
    static func url(_ clip: String, dark: Bool) -> URL? { dir?.appendingPathComponent("\(dark ? "dark" : "light")-\(clip).mp4") }
    /// The held pose as a still, shown before the film has its first frame and in design snapshots.
    static func poster(awake: Bool, dark: Bool) -> NSImage? {
        // Headless hosts may lack the HEVC decoder. Render checks can supply exact first-frame PNGs from the clips.
        if let dir = ProcessInfo.processInfo.environment["LOAF_RENDER"],
           let image = NSImage(contentsOfFile: "\(dir)/poster-\(awake ? "awake" : "asleep")-\(dark ? "dark" : "light").png") {
            return image
        }
        guard let url = url(awake ? "idle_a" : "sleep_idle", dark: dark) else { return nil }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        var image: CGImage?
        let done = DispatchSemaphore(value: 0)
        gen.generateCGImageAsynchronously(for: .zero) { img, _, _ in image = img; done.signal() }
        done.wait()
        return image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }
}

/// Strings clips together on a queue player, always one clip ahead: idles and small actions while awake,
/// settle into sleep, sleep idles, wake up. A change of state takes effect at the next clip boundary.
final class Film: NSObject {
    let player = AVQueuePlayer()
    private(set) var awake = true
    private var dark = false
    private var names: [ObjectIdentifier: String] = [:]
    private var last: String?
    private var pausedAt = Date.distantPast
    private var watch: NSKeyValueObservation?

    override init() {
        super.init()
        player.preventsDisplaySleepDuringVideoPlayback = false   // the cat must never be what keeps the Mac awake
        player.isMuted = true
        player.actionAtItemEnd = .advance
        // Each time the queue moves on to the clip already lined up, line up the one after it.
        watch = player.observe(\.currentItem) { [weak self] _, _ in DispatchQueue.main.async { self?.queueNext() } }
    }

    private func pick(_ pool: [(String, Int)]) -> String {
        let options = pool.filter { $0.0 != last }
        var r = Int.random(in: 0..<options.reduce(0) { $0 + $1.1 })
        for (name, weight) in options { if r < weight { return name }; r -= weight }
        return options[0].0
    }

    private func next(after clip: String) -> String {
        switch (Loaf.endsAwake(clip), awake) {
        case (true, true): return pick(Loaf.awakeClips)
        case (true, false): return "settle"
        case (false, false): return pick(Loaf.sleepClips)
        case (false, true): return "wake"
        }
    }

    private func item(_ clip: String) -> AVPlayerItem? {
        guard let url = Loaf.url(clip, dark: dark) else { return nil }
        let it = AVPlayerItem(url: url)
        names[ObjectIdentifier(it)] = clip
        last = clip
        return it
    }

    /// Exactly one clip lined up after the one playing, and it follows from the current state.
    private func queueNext() {
        let items = player.items()
        names = names.filter { k, _ in items.contains { ObjectIdentifier($0) == k } }
        guard let cur = items.first, let name = names[ObjectIdentifier(cur)] else { return }
        let want = next(after: name)
        if items.count == 2, let queued = names[ObjectIdentifier(items[1])],
           queued == want || (Loaf.endsAwake(name) == awake && queued != "settle" && queued != "wake") { return }
        for extra in items.dropFirst() { player.remove(extra); names[ObjectIdentifier(extra)] = nil }
        last = name
        if let it = item(want) { player.insert(it, after: cur) }
    }

    private func restart() {
        player.removeAllItems(); names.removeAll(); last = nil
        if let it = item(awake ? "idle_a" : "sleep_idle") { player.insert(it, after: nil) }
        queueNext()
    }

    /// Start or resume. After a long pause in the wrong pose, cut straight to the right one rather than replay old news.
    func play(awake: Bool, dark: Bool) {
        let stale = Date().timeIntervalSince(pausedAt) > 2
        let changed = awake != self.awake
        self.awake = awake
        let showing = player.items().first.flatMap { names[ObjectIdentifier($0)] }
        if dark != self.dark || showing == nil || (stale && Loaf.endsAwake(showing!) != awake) {
            self.dark = dark
            restart()
        } else if changed { queueNext() }
        player.play()
    }

    func set(awake: Bool) {
        guard awake != self.awake else { return }
        self.awake = awake
        queueNext()
    }

    func pause() { player.pause(); pausedAt = Date() }
}

// MARK: - Menu-bar cat: the mark as a template image (art/icons.py): solid = kept awake (working or in grace),
// hollow outline = can sleep

enum MenuCat {
    private static var cache: [String: NSImage] = [:]
    /// The side-profile loaf (art/icons.py): solid = kept awake (working or in grace), hollow outline = can sleep.
    /// Loaded once per mood.
    static func image(_ mood: Model.Mood) -> NSImage {
        let name = mood == .watching || mood == .winding ? "menu-awake" : "menu-asleep"
        if let img = cache[name] { return img }
        let img = Loaf.dir.flatMap { NSImage(contentsOf: $0.appendingPathComponent("\(name).png")) }
            ?? NSImage(systemSymbolName: "cat", accessibilityDescription: nil) ?? NSImage()
        if img.size.height > 0 { img.size = NSSize(width: (16 * img.size.width / img.size.height).rounded(), height: 16) }
        img.isTemplate = true
        cache[name] = img
        return img
    }
    static func words(_ mood: Model.Mood) -> String {
        switch mood {
        case .watching: return "Keeping watch"
        case .winding: return "One eye open"
        case .napping: return "Napping anyway"
        case .asleep: return "Fast asleep"
        }
    }
}

/// Print colours: brown riso ink on warm paper in light mode, the paper's own cream on warm ink in dark mode.
enum Ink {
    static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
    }
    static let paper = dyn(hex(0xF1ECE0), hex(0x201813))   // light: the film's own paper, so the print has no edge
    static let text = dyn(hex(0x3B2216), hex(0xF3E9DA))
    static let soft = dyn(hex(0x3B2216, 0.62), hex(0xF3E9DA, 0.62))
    static let faint = dyn(hex(0x3B2216, 0.12), hex(0xF3E9DA, 0.12))
    static let hover = dyn(hex(0x3B2216, 0.06), hex(0xF3E9DA, 0.07))
    static let group = dyn(hex(0x3B2216, 0.045), hex(0xF3E9DA, 0.055))   // a settings group sits on the paper
}

/// The film's own layer, filling the view.
struct PlayerLayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        v.layer = layer
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

struct CatView: View {
    let awake: Bool
    let film: Film
    @Environment(\.colorScheme) private var scheme
    private static var posters: [String: NSImage] = [:]

    func poster(dark: Bool) -> NSImage? {
        let key = "\(awake)-\(dark)"
        if let p = Self.posters[key] { return p }
        let p = Loaf.poster(awake: awake, dark: dark)
        Self.posters[key] = p
        return p
    }

    var body: some View {
        ZStack {
            if let img = poster(dark: scheme == .dark) { Image(nsImage: img).resizable().interpolation(.high) }
            PlayerLayer(player: film.player)
        }
        .aspectRatio(1.5, contentMode: .fit)
        .onChange(of: scheme) { _, s in if film.player.rate > 0 { film.play(awake: awake, dark: s == .dark) } }
        .accessibilityElement()
        .accessibilityLabel(awake ? "Cat, awake" : "Cat, asleep")
    }
}

/// One settings row, the way System Settings draws it: the label on the left, a native switch on the right.
struct SettingRow: View {
    let label: String, help: String
    @Binding var on: Bool
    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 13)).foregroundStyle(Ink.text)
            Spacer(minLength: 0)
            Toggle(label, isOn: $on).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Loaf.accent)
        }
        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36)
        .contentShape(Rectangle()).onTapGesture { on.toggle() }
        .help(help)
    }
}

/// One session keeping the Mac awake: its name on the left; what it is doing and for how long on the right.
struct HolderRow: View {
    let holder: Model.Holder, now: Date
    static func age(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        return m < 1 ? "<1m" : m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }
    var doing: String {
        var parts: [String] = []
        if holder.working { parts.append("working") }
        if holder.tasks > 0 { parts.append(holder.tasks == 1 ? "1 task" : "\(holder.tasks) tasks") }
        return parts.joined(separator: ", ")
    }
    var body: some View {
        HStack(spacing: 10) {
            Text(holder.name).font(.system(size: 12)).foregroundStyle(Ink.text).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Text("\(doing)  ·  \(Self.age(now.timeIntervalSince(holder.since)))")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(Ink.soft).fixedSize()
        }
        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(holder.name), \(doing), \(Self.age(now.timeIntervalSince(holder.since)))")
    }
}

/// One app holding the screen or the Mac awake: its name, what it holds, and how many holds.
struct AppHoldRow: View {
    let row: PowerHolds.Row
    var detail: String { row.what }
    var body: some View {
        HStack(spacing: 10) {
            Text(row.app).font(.system(size: 12)).foregroundStyle(Ink.text).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Text(detail).font(.system(size: 11)).monospacedDigit().foregroundStyle(Ink.soft).fixedSize()
        }
        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.app), \(detail)")
    }
}

/// The footer action: full width, highlights under the pointer like a menu item, its shortcut on the right.
final class Hover: ObservableObject { @Published var on = false }

struct QuitRow: View {
    @StateObject private var state = Hover()   // owned here: survives the Panel re-rendering every minute
    var body: some View {
        Button { NSApp.terminate(nil) } label: {
            HStack {
                Text("Quit Loaf").font(.system(size: 13)).foregroundStyle(Ink.text)
                Spacer()
                Text("⌘Q").font(.system(size: 12)).foregroundStyle(Ink.soft)
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(state.on ? Ink.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).keyboardShortcut("q").onHover { state.on = $0 }
    }
}

struct Panel: View {
    @ObservedObject var model: Model
    @Environment(\.colorScheme) private var scheme
    static let width: CGFloat = 300
    static let maxHolders = 5

    /// One plain line under the status: who is keeping it up, or what happens next.
    var summary: String {
        let parts = [(model.scan.claude, model.scan.claude == 1 ? "Claude session" : "Claude sessions"),
                     (model.scan.codex, model.scan.codex == 1 ? "Codex session" : "Codex sessions"),
                     (model.background.total, model.background.total == 1 ? "task" : "tasks")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        let line: String
        if !parts.isEmpty { line = parts.joined(separator: "  ·  ") }
        else {
            switch model.mood {
            case .winding: line = "Agents finished. Dozing off soon."
            case .asleep: line = model.allowSleep ? "Wakes up with the Mac." : "Wakes when an agent starts."
            case .watching, .napping: line = "Agents are working."
            }
        }
        guard let b = model.battery, b.onBattery else { return line }
        return line + "  ·  battery \(b.percent)%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The print sits inset on the card with the same rounded corners as the settings group, in both themes.
            CatView(awake: model.awake, film: model.film)
                .frame(width: Self.width - 16, height: (Self.width - 16) / 1.5)   // fixed: a taller panel must never squeeze it
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding([.horizontal, .top], 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(MenuCat.words(model.mood))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Ink.text)
                    .contentTransition(.opacity)
                Text(summary)
                    .font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(Ink.soft)
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 12)
            // Which sessions are keeping it awake, longest first. Ages tick each minute while the card is open.
            TimelineView(.everyMinute) { t in
                let all = model.holders(now: t.date), shown = all.prefix(Self.maxHolders)
                if !all.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(shown) { HolderRow(holder: $0, now: t.date) }
                        if all.count > shown.count {
                            Text("and \(all.count - shown.count) more").font(.system(size: 11)).foregroundStyle(Ink.soft)
                                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.group))
                    .padding(.horizontal, 8).padding(.bottom, 8)
                    .transition(.opacity)
                }
            }
            // Other apps holding the screen or the Mac awake, read live while the card is open.
            if !model.appHolds.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Other apps").font(.system(size: 11)).foregroundStyle(Ink.soft)
                        .padding(.horizontal, 12).frame(minHeight: 22)
                    ForEach(model.appHolds, id: \.self) { AppHoldRow(row: $0) }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.group))
                .padding(.horizontal, 8).padding(.bottom, 8)
                .transition(.opacity)
            }
            VStack(spacing: 0) {
                SettingRow(label: "Chime when the lid closes", help: "Plays a short chime as the lid shuts", on: Binding(
                    get: { model.chimeOnClose },
                    set: { model.chimeOnClose = $0; if $0 { Chime.shared.play(reason: "preview") } }))   // hear what it sounds like
                Rectangle().fill(Ink.faint).frame(height: 1).padding(.leading, 12)
                SettingRow(label: "Let the Mac sleep", help: "Sleep on schedule even while agents work, until the Mac next wakes", on: Binding(
                    get: { model.allowSleep }, set: { _ in model.toggleAllowSleep() }))
                Rectangle().fill(Ink.faint).frame(height: 1).padding(.leading, 12)
                SettingRow(label: "Screen off after \(model.screenOffMinutes) min idle",
                           help: "Turns the screen off when nothing but a forgotten hold (Discord's video lock) keeps it on", on: $model.screenOffWhenIdle)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.group))
            .padding(.horizontal, 8)
            QuitRow().padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 8)
        }
        .frame(width: Self.width)
        .background(Ink.paper)
        .animation(.easeOut(duration: 0.25), value: model.agents)
        .animation(.easeOut(duration: 0.25), value: model.mood)
    }
}

// MARK: - App

/// A borderless card under the menu-bar cat: no popover arrow, the print runs to its edges.
final class Card: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let model = Model()
    let lid = LidWatch()
    lazy var host = NSHostingView(rootView: Panel(model: model))
    lazy var card: Card = {
        let c = Card(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        c.isOpaque = false
        c.backgroundColor = .clear
        c.hasShadow = true
        c.level = .statusBar
        c.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        c.delegate = self
        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.layer?.cornerRadius = 14
        wrap.layer?.cornerCurve = .continuous
        wrap.layer?.masksToBounds = true
        wrap.addSubview(host)
        c.contentView = wrap
        return c
    }()
    var outside: Any?
    var closedAt = Date.distantPast
    var fast: Timer?
    var powerPort: io_connect_t = 0
    var notifyPort: IONotificationPortRef?
    var notifier: io_object_t = 0
    var termSource: DispatchSourceSignal?
    var busySource: DispatchSourceFileSystemObject?

    func applicationDidFinishLaunching(_ n: Notification) {
        item.autosaveName = "Loaf"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        model.onChange = { [weak self] in
            guard let self else { return }
            self.draw()
            if self.card.isVisible { self.place() }
        }
        model.refresh(); draw()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.model.refresh() }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.model.refresh()
            self?.model.checkIdleSleep()
            self?.model.checkScreenIdle()
        }
        _ = Chime.shared   // decode the chime now so it is ready the instant the lid moves
        lid.onClose = { [weak self] reason in self?.model.lidDidClose(reason: reason) }
        lid.start()
        watchSleep()
        lid.context = { [weak self] in self?.model.hold.summary ?? "" }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.model.refresh()
        }
        watchBusyDir()
        model.hold.probe()
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in self?.model.hold.releaseNow(); EventLog.write("SIGTERM: exiting"); exit(0) }
        term.resume()
        termSource = term
        Alerts.enabled = true
        EventLog.write("Loaf started, Lid chime \(model.chimeOnClose ? "on" : "off")")
    }

    /// Make the busy folder, and refresh the moment a session file appears or goes (touching an existing one is caught by the 5 s tick).
    func watchBusyDir() {
        try? FileManager.default.createDirectory(at: Busy.dir, withIntermediateDirectories: true)
        let fd = open(Busy.dir.path, O_EVTONLY)
        guard fd >= 0 else { EventLog.write("cannot watch \(Busy.dir.path)"); return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.model.refresh() }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        busySource = src
    }

    private var drawnMood: Model.Mood?
    func draw() {
        let mood = model.mood
        guard mood != drawnMood else { return }   // refresh runs every 5 s; the cat only changes with the mood
        drawnMood = mood
        item.button?.image = MenuCat.image(mood)
        item.button?.toolTip = "Loaf: \(MenuCat.words(model.mood).lowercased())"
        item.button?.setAccessibilityLabel("Loaf, \(MenuCat.words(model.mood).lowercased())")
    }

    /// Size the card to its content, top edge pinned 6 pt under the menu bar, centered on the cat and kept on screen.
    func place() {
        guard let b = item.button, let bw = b.window, let screen = bw.screen ?? NSScreen.main else { return }
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let anchor = bw.convertToScreen(b.convert(b.bounds, to: nil))
        let vis = screen.visibleFrame
        var x = anchor.midX - size.width / 2
        x = min(max(x, vis.minX + 8), vis.maxX - size.width - 8)
        let frame = NSRect(x: x, y: anchor.minY - 6 - size.height, width: size.width, height: size.height)
        card.setFrame(frame, display: true, animate: false)
        card.invalidateShadow()
    }

    @objc func toggle() {
        // A click on the cat while the card is open first takes key away from the card, which closes it.
        if card.isVisible || Date().timeIntervalSince(closedAt) < 0.3 { close(); return }
        model.refresh()
        model.refreshAppHolds()
        if host.superview == nil { card.contentView?.addSubview(host) }
        place()
        let end = card.frame
        card.setFrame(end.offsetBy(dx: 0, dy: 6), display: false)
        card.alphaValue = 0
        card.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.4, 0.64, 1)   // a small overshoot, like a spring
            card.animator().alphaValue = 1
            card.animator().setFrame(end, display: true)
        }
        item.button?.highlight(true)
        model.film.play(awake: model.awake, dark: card.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        if let outside { NSEvent.removeMonitor(outside) }
        fast?.invalidate()
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() }
        fast = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.model.refresh()
            self.model.refreshAppHolds()
        }
    }

    func close() {
        guard card.isVisible else { return }
        closedAt = Date()
        if let outside { NSEvent.removeMonitor(outside) }
        outside = nil
        fast?.invalidate(); fast = nil
        item.button?.highlight(false)
        model.film.pause()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            card.animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.hideCard() })
    }

    /// Order the card out and take the SwiftUI view out of its window. Left in an ordered-out window it keeps re-rendering
    /// on every model change, and each redraw adds glyph bitmaps that are never freed (about 100 MB in 20 minutes).
    func hideCard() {
        card.orderOut(nil)
        host.removeFromSuperview()
    }

    func windowDidResignKey(_ n: Notification) { close() }

    func applicationWillTerminate(_ n: Notification) { model.hold.releaseNow() }

    // Esc closes the card.
    func applicationWillFinishLaunching(_ n: Notification) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53, self?.card.isVisible == true { self?.close(); return nil }
            return e
        }
    }

    // Sleep and wake are logged so a real lid close can be checked afterwards, and this is the one place wake resets the lid
    // and the model. It never holds the sleep request for long: only if a chime is still sounding, for at most a second,
    // and it always allows the change.
    func watchSleep() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        powerPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, type, arg in
            guard let refcon else { return }
            let app = Unmanaged<App>.fromOpaque(refcon).takeUnretainedValue()
            let id = Int(bitPattern: arg)
            switch type {
            case UInt32(0xE0000270):   // kIOMessageCanSystemSleep
                EventLog.write("can-system-sleep asked (lid \(lidClosed() ? "closed" : "open")); allowing")
                IOAllowPowerChange(app.powerPort, id)
            case UInt32(0xE0000280):   // kIOMessageSystemWillSleep
                let r = Chime.shared.remaining, wait = r > 0 ? min(1.0, r + 0.05) : 0
                EventLog.write(String(format: "will-sleep received (lid %@); holding %.2f s", lidClosed() ? "closed" : "open", wait))
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                    IOAllowPowerChange(app.powerPort, id)
                    EventLog.write("power change allowed")
                }
            case UInt32(0xE0000300):   // kIOMessageSystemHasPoweredOn
                EventLog.write("system woke (lid \(lidClosed() ? "closed" : "open")); \(app.model.hold.summary)")
                app.lid.resetAfterWake()
                app.model.resetAfterWake()
            default: break
            }
        }, &notifier)
        if let notifyPort {
            CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .commonModes)
        }
    }
}

// Playback check: LOAF_FILMTEST=1 Loaf plays the film off-screen for 40 s, falls asleep at 8 s and wakes at 24 s,
// and prints each clip with the gap between when it started and when the clip before it should have ended.
if ProcessInfo.processInfo.environment["LOAF_FILMTEST"] != nil {
    MainActor.assumeIsolated {
        let film = Film()
        var prev: (name: String, at: Double, dur: Double)?
        let t0 = CACurrentMediaTime()
        let watch = film.player.observe(\.currentItem, options: [.new]) { p, _ in
            let now = CACurrentMediaTime() - t0
            guard let it = p.currentItem, let name = (it.asset as? AVURLAsset)?.url.deletingPathExtension().lastPathComponent else { return }
            let dur = it.duration.seconds.isFinite ? it.duration.seconds : it.asset.duration.seconds
            let gap = prev.map { now - ($0.at + $0.dur) } ?? 0
            print(String(format: "%6.2f s  %-18@ %.2f s  gap %+.3f s", now, name as NSString, dur, gap))
            prev = (name, now, dur)
        }
        film.play(awake: true, dark: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { print("-- asleep"); film.set(awake: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 24) { print("-- awake"); film.set(awake: true) }
        RunLoop.main.run(until: Date().addingTimeInterval(40))
        watch.invalidate()
    }
    exit(0)
}

// Off-screen snapshots for design review: LOAF_RENDER=<dir> Loaf
if let dir = ProcessInfo.processInfo.environment["LOAF_RENDER"] {
    MainActor.assumeIsolated {
        for state in ["awake", "winding", "asleep", "allowed", "live"] { for dark in [false, true] {   // live: this Mac's real sessions
            let m = Model()
            m.awake = state == "awake" || state == "winding"
            m.allowSleep = state == "allowed"
            // awake: more sessions than fit (long titles, a background-only one); allowed: two
            let now = Date(), names = ["Sync engine refactor", "Release notes", "Docs site", "Flaky test",
                                       "Migrate settings to the new schema", "Icon polish", "Benchmark the parser on large inputs"]
            let n = state == "awake" ? names.count : state == "allowed" ? 2 : 0
            var sessions: [String: Date] = [:], bg = Busy.Background()
            for i in 0..<n {
                let id = "render-\(i)"; SessionNames.titles[id] = names[i]
                let since = now.addingTimeInterval(-[4920, 1500, 1260, 700, 380, 150, 20][i])
                if i != 3 { sessions[id] = since }
                if i == 0 || i == 3 { bg.bySession[id] = (i == 0 ? 2 : 1, since); bg.recent += i == 0 ? 2 : 1 }
            }
            m.scan = n > 0 ? Busy.Scan(claude: sessions.count, codex: 0, sessions: sessions) : Busy.Scan()
            m.background = bg
            // other apps holding the screen or the Mac, as the card lists them while they do
            if state != "allowed" { m.appHolds = [.init(app: "Discord", what: "screen on (15), audio", count: 16), .init(app: "Spotify", what: "audio", count: 1)] }
            if state == "live" {
                m.awake = true; m.scan = Busy.scan(now: now); m.background = Busy.scanBackground(now: now)
                m.appHolds = PowerHolds.rows(PowerHolds.live())
                m.battery = SleepHold.battery().map { Model.Battery(percent: $0.percent, onBattery: $0.onBattery) }
            }
            let host = NSHostingView(rootView: Panel(model: m))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(2.5))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(dir)/panel-\(state)-\(dark ? "dark" : "light").png"))
            }
        } }
        // The menu-bar icon on a light and a dark menu bar (template image: black on light, white on dark), 88 x 64 each.
        for (mood, name) in [(Model.Mood.watching, "awake"), (.winding, "winding"), (.asleep, "asleep")] { for dark in [false, true] {
            let img = MenuCat.image(mood)
            let big = NSImage(size: NSSize(width: 88, height: 64), flipped: false) { r in
                (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill(); r.fill()
                let tinted = NSImage(size: img.size, flipped: false) { ir in
                    img.draw(in: ir)
                    (dark ? NSColor.white : NSColor.black).setFill(); ir.fill(using: .sourceAtop); return true }
                tinted.draw(in: NSRect(x: (r.width - img.size.width * 3) / 2, y: (r.height - img.size.height * 3) / 2,
                                       width: img.size.width * 3, height: img.size.height * 3))
                return true }
            if let t = big.tiffRepresentation, let rep = NSBitmapImageRep(data: t) {
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(dir)/menu-\(name)-\(dark ? "dark" : "light").png"))
            }
        } }
    }
    print("chime", String(format: "%.2fs", Chime.shared.duration))
    exit(0)
}

// Lid-chime check, headless: `Loaf --test-chime [--audible]` runs the real flow (angle detector -> chime) with a synthetic
// lid closing, then the clamshell switch for the same close (must not chime twice), then a second close with Lid chime off
// (must stay silent). With the sudoers helper installed it also holds keep-awake first, so the log shows SleepDisabled=yes
// around the close. It never sleeps the Mac.
// `Loaf --test-hold [--crash]`: keep-awake on -> off, the safety floor, then release; with --crash it SIGKILLs itself
// while the hold is set, to prove the next launch (or the watchdog) resets it.
// `Loaf --test-prefs set-on|set-off|get` checks that the toggle survives a relaunch.
let args = CommandLine.arguments
/// The headless checks below let the main run loop turn for `s` seconds so queued hold and player work completes.
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
if args.contains("--test-idle-sleep") {
    var failures = 0
    func check(_ name: String, idle: Double = 601, minutes: Int = 10, awake: Bool = false,
               allowed: Bool = false, sinceWake: Double = 300, holders: [String] = ["Claude", "Spotify"], expected: Bool) {
        let actual = IdleSleep.shouldSleep(idleSeconds: idle, sleepMinutes: minutes, keepAwake: awake,
                                          allowSleep: allowed, secondsSinceWake: sinceWake, holders: holders)
        let pass = actual == expected
        print("\(pass ? "PASS" : "FAIL") \(name): sleep=\(actual)")
        if !pass { failures += 1 }
    }
    check("active user", idle: 30, expected: false)
    check("never-sleep setting", minutes: 0, expected: false)
    check("invalid setting", minutes: -1, expected: false)
    check("agents working", awake: true, expected: false)
    check("agents in grace", awake: true, expected: false)
    check("allow-sleep on with agents", awake: true, allowed: true, expected: true)
    check("allow-sleep still protects active user", idle: 30, awake: true, allowed: true, expected: false)
    check("allow-sleep respects never-sleep", minutes: 0, awake: true, allowed: true, expected: false)
    check("just woke", sinceWake: 119, expected: false)
    check("just woke with allow-sleep", allowed: true, sinceWake: 0, expected: false)
    check("wake guard elapsed", sinceWake: 120, expected: true)
    check("exact idle threshold", idle: 600, expected: false)
    check("idle with app assertions", expected: true)
    check("no other holders", holders: [], expected: false)
    for (settings, expected) in [(" sleep 1 (sleep prevented by Claude)\n", 1),
                                  ("displaysleep 10\n sleep 0\n", 0), ("sleep never", nil), ("displaysleep 10", nil),
                                  (" displaysleep 10\n sleep 1 (sleep prevented by powerd)\n", 10),
                                  (" displaysleep 0\n sleep 1\n", 0), (" displaysleep 2\n sleep 15\n", 15)] {
        let pass = IdleSleep.sleepMinutes(in: settings) == expected
        print("\(pass ? "PASS" : "FAIL") parse sleep setting: \(settings.debugDescription)")
        if !pass { failures += 1 }
    }
    exit(failures == 0 ? 0 : 1)
}
if let i = args.firstIndex(of: "--tasks-root"), i + 1 < args.count { Busy.tasksRoot = URL(fileURLWithPath: args[i + 1]) }   // tests
if args.contains("--scan-bg") {   // prints one background-task scan: `Loaf --scan-bg [--tasks-root <dir>]`
    let b = Busy.scanBackground(now: Date())
    print("recent=\(b.recent) open=\(b.open) total=\(b.total) \(String(format: "%.1f", b.millis)) ms")
    exit(0)
}
if args.contains("--test-holders") {   // the card's rows from fixture folders: app title, terminal folder, unknown, ordering
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("loaf-holders-\(getpid())").path
    defer { try? fm.removeItem(atPath: root) }
    func put(_ path: String, _ text: String) {
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: Data(text.utf8))
    }
    Busy.dir = URL(fileURLWithPath: root + "/busy"); Busy.codexRoot = nil
    Busy.tasksRoot = URL(fileURLWithPath: root + "/tmp")
    SessionNames.appRoot = root + "/app"; SessionNames.projectsRoot = root + "/projects"
    put(root + "/busy/s-app", "")                                                    // working, titled in the app
    put(root + "/app/acct/org/local_1.json", #"{"sessionId":"local_1","cliSessionId":"s-app","cwd":"/x","title":"Say \"hi\""}"#)
    put(root + "/tmp/-x-term/s-term/tasks/a.output", "")                              // background task only, terminal session
    put(root + "/projects/-x-term/s-term.jsonl", #"{"type":"user","cwd":"/work/my-project","sessionId":"s-term"}"#)
    put(root + "/tmp/-x/s-gone/tasks/b.output", ""); put(root + "/tmp/-x/s-gone/tasks/c.output", "")   // no name anywhere
    let m = Model(), now = Date()
    m.scan = Busy.scan(now: now); m.background = Busy.scanBackground(now: now)
    let got = Set(m.holders(now: now).map { "\($0.name)|\(HolderRow(holder: $0, now: now).doing)" })
    let want: Set = ["Say \"hi\"|working", "my-project|1 task", "Claude session|2 tasks"]
    print(got == want ? "PASS holders: app title, terminal folder, unknown session" : "FAIL holders: got \(got.sorted())")
    let ages = [30.0, 60, 3599, 3660].map { HolderRow.age($0) }
    print(ages == ["<1m", "1m", "59m", "1h 1m"] ? "PASS ages" : "FAIL ages: \(ages)")
    exit(got == want && ages == ["<1m", "1m", "59m", "1h 1m"] ? 0 : 1)
}
if args.contains("--test-interrupt") {   // a stopped turn stops counting at once (no Stop hook runs on an interrupt)
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("loaf-interrupt-\(getpid())").path
    defer { try? fm.removeItem(atPath: root) }
    let now = Date(), iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func put(_ path: String, _ text: String, mtime: Date = now) {
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: Data(text.utf8))
        try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
    }
    func line(_ type: String, _ ago: Double, _ content: String) -> String {
        #"{"parentUuid":"p","sessionId":"s","type":"\#(type)","message":{"role":"\#(type)","content":\#(content)},"timestamp":"\#(iso.string(from: now - ago))"}"#
    }
    let tool = line("assistant", 31, #"[{"type":"tool_use","id":"t","name":"Bash","input":{}}]"#)
    let refused = line("user", 30.5, #"[{"type":"tool_result","tool_use_id":"t","content":"The user doesn't want to proceed"}]"#)
    let stop = line("user", 30, #"[{"type":"text","text":"[Request interrupted by user for tool use]"}]"#)
    let tail = #"{"type":"api-request-blob","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"# + "\n" +
               #"{"type":"last-prompt","lastPrompt":"go"}"# + "\n" + #"{"type":"custom-title","customTitle":"X"}"#
    Busy.dir = URL(fileURLWithPath: root + "/busy"); Busy.codexRoot = nil
    SessionNames.projectsRoot = root + "/projects"
    let cases: [(id: String, transcript: String?, touched: Double, counts: Bool)] = [
        ("s-stopped", [tool, refused, stop, tail].joined(separator: "\n") + "\n", 31, false),
        ("s-stopped-plain", [tool, line("user", 40, #"[{"type":"text","text":"[Request interrupted by user]"}]"#)].joined(separator: "\n"), 41, false),
        ("s-resumed", [tool, stop, line("user", 2, #""next prompt""#), tail].joined(separator: "\n") + "\n", 2, true),
        ("s-new-prompt", [tool, stop, tail].joined(separator: "\n") + "\n", 8, true),   // hook touched it after the stop; transcript not written yet
        ("s-working", [stop, tool, refused].joined(separator: "\n") + "\n", 30, true),
        ("s-no-transcript", nil, 30, true),
    ]
    for c in cases {
        put(root + "/busy/" + c.id, "", mtime: now - c.touched)
        if let t = c.transcript { put(root + "/projects/-x/" + c.id + ".jsonl", t) }
    }
    let got = Set(Busy.scan(now: now).sessions.keys), want = Set(cases.filter(\.counts).map(\.id))
    print(got == want ? "PASS interrupt: a stopped turn stops counting, a resumed one counts" :
                        "FAIL interrupt: counted \(got.sorted()), want \(want.sorted())")
    exit(got == want ? 0 : 1)
}
if args.contains("--test-power") {   // what holds the screen and the Mac awake, screen off when idle, battery alerts
    // A real `pmset -g assertions` with 15 forgotten Discord video locks
    let fixture = """
    Assertion status system-wide:
       PreventUserIdleDisplaySleep    1
       PreventUserIdleSystemSleep     1
    Listed by owning process:
       pid 364(powerd): [0x0007c3f70001a498] 02:36:05 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"
       pid 364(powerd): [0x0007e34400108341] 00:02:40 InternalPreventDisplaySleep named: "com.apple.powermanagement.delayDisplayOff"
    \tTimeout will fire in 140 secs Action=TimeoutActionTurnOff
       pid 549(coreaudiod): [0x0007cf2900019307] 01:48:19 PreventUserIdleSystemSleep named: "com.apple.audio.BuiltInSpeakerDevice.context.preventuseridlesleep"
    \tCreated for PID: 25144.
    \tResources: audio-out BuiltInSpeakerDevice
       pid 549(coreaudiod): [0x0007c3f800018409] 02:36:04 PreventUserIdleSystemSleep named: "com.apple.audio.BuiltInSpeakerDevice.context.preventuseridlesleep"
    \tCreated for PID: 41549.
    \tResources: audio-out BuiltInSpeakerDevice

    """ + (0..<15).map { "   pid 41425(Discord): [0x0007c4040005a4\(String(format: "%02x", 0xa7 + $0))] 02:35:52 NoDisplaySleepAssertion named: \"Video Wake Lock\"  \n" }.joined() + """
       pid 421(WindowServer): [0x0007e7ae000982c8] 00:00:01 UserIsActive named: "com.apple.iohideventsystem.queue.tickle"
    \tTimeout will fire in 10798 secs Action=TimeoutActionRelease
       pid 41857(Claude): [0x0007d1920001a63e] 01:38:01 NoIdleSleepAssertion named: "Electron"
    Kernel Assertions: 0x100=MAGICWAKE
       id=563  level=255 0x100=MAGICWAKE creat=  mod= description=en0 owner=IOSkywalkNetworkBSDClient
    """
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print("\(ok ? "PASS" : "FAIL") \(what)"); if !ok { failures += 1 } }
    let holds = PowerHolds.parse(fixture)
    check(holds.count == 21, "parse: 21 holds (got \(holds.count))")
    check(holds.filter { $0.process == "Discord" && $0.type == "NoDisplaySleepAssertion" && $0.name == "Video Wake Lock" }.count == 15,
          "parse: Discord's 15 video wake locks")
    check(holds.filter { $0.process == "coreaudiod" }.map(\.forPid) == [25144, 41549], "parse: coreaudiod holds name the app they hold for")
    check(holds.contains(PowerHold(pid: 41857, process: "Claude", type: "NoIdleSleepAssertion", name: "Electron")), "parse: Claude's system hold")
    let names: [Int32: String] = [25144: "Spotify", 41549: "Discord", 41425: "Discord", 41857: "Claude"]
    let rows = PowerHolds.rows(holds, me: 1) { pid, process in names[pid] ?? process }
    let want = [PowerHolds.Row(app: "Discord", what: "screen on (15), audio", count: 16), .init(app: "Claude", what: "awake", count: 1),
                .init(app: "Spotify", what: "audio", count: 1)]
    check(rows == want, "card rows: one per app, Discord screen on (15) and audio first (got \(rows.map { "\($0.app): \($0.what)" }))")
    check(ScreenIdle.shouldTurnOff(idleSeconds: 25 * 60, minutes: 20, screenAsleep: false, holds: holds), "screen off: idle 25m, only Discord's forgotten locks")
    check(!ScreenIdle.shouldTurnOff(idleSeconds: 10 * 60, minutes: 20, screenAsleep: false, holds: holds), "screen stays: idle 10m of 20")
    check(!ScreenIdle.shouldTurnOff(idleSeconds: 25 * 60, minutes: 20, screenAsleep: true, holds: holds), "screen stays: already off")
    check(!ScreenIdle.shouldTurnOff(idleSeconds: 25 * 60, minutes: 0, screenAsleep: false, holds: holds), "screen stays: setting off")
    let video = PowerHolds.parse("Listed by owning process:\n   pid 777(Google Chrome Helper): [0x1] 00:10:00 NoDisplaySleepAssertion named: \"Video Wake Lock\"\n")
    check(video.count == 1 && !ScreenIdle.shouldTurnOff(idleSeconds: 25 * 60, minutes: 20, screenAsleep: false, holds: holds + video),
          "screen stays: a browser is really playing video")
    var sent: Set<Int> = [], got: [String] = []
    for (pct, onBattery) in [(30, true), (21, true), (20, true), (19, true), (11, true), (10, true), (8, true), (8, false), (50, true), (9, true), (5, true)] {
        let r = BatteryAlert.next(percent: pct, onBattery: onBattery, sent: sent); sent = r.sent
        if let a = r.alert { got.append("\(pct):\(a)") }
    }
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("loaf-alert-\(getpid())").path
    defer { try? FileManager.default.removeItem(atPath: out) }
    let p = Alerts.run(["/bin/sh", "-c", "printf '%s|%s' \"$1\" \"$2\" > \(out)", "alert"], BatteryAlert.words(20))
    p?.waitUntilExit()
    check((try? String(contentsOfFile: out, encoding: .utf8)) == "Mac battery at 20%|Plug it in soon. At 10% Loaf stops keeping the Mac awake for agents.",
          "the alert command gets the title and the body")
    check(got == ["20:20", "10:10", "9:10"], "battery alerts once at 20% and 10%; plugged in starts over; a drop past both alerts once (got \(got))")
    exit(failures == 0 ? 0 : 1)
}
if args.contains("--power") {   // prints the live holds as the card lists them, and whether the screen would go off now
    let holds = PowerHolds.live(), m = Model()
    for r in PowerHolds.rows(holds) { print("\(r.app) | \(r.what)") }
    let idle = IdleSleep.idleSeconds() ?? 0, blockers = PowerHolds.screenBlockers(holds)
    print("idle \(Int(idle))s, screen \(ScreenIdle.screenAsleep ? "off" : "on"), setting \(m.screenOffWhenIdle ? "\(m.screenOffMinutes) min" : "off"), " +
          "screen held by \(blockers.isEmpty ? "nothing that counts" : Set(blockers.map(\.process)).sorted().joined(separator: ", ")), " +
          "would turn off now: \(m.screenOffWhenIdle && ScreenIdle.shouldTurnOff(idleSeconds: idle, minutes: m.screenOffMinutes, screenAsleep: ScreenIdle.screenAsleep, holds: holds))")
    if let b = SleepHold.battery() { print("battery \(b.percent)% \(b.onBattery ? "on battery" : "on power")") }
    exit(0)
}
if args.contains("--holders") {   // prints the card's "keeping it awake" rows from the live scans; never touches the sleep hold
    let m = Model(), now = Date(), t0 = CACurrentMediaTime()
    m.scan = Busy.scan(now: now)
    m.background = Busy.scanBackground(now: now)
    let rows = m.holders(now: now)
    let ms = (CACurrentMediaTime() - t0) * 1000
    for h in rows { let r = HolderRow(holder: h, now: now); print("\(h.name) | \(r.doing) | \(HolderRow.age(now.timeIntervalSince(h.since)))") }
    print(String(format: "%d rows, %d named, %.1f ms", rows.count, rows.filter { $0.name != "Claude session" }.count, ms))
    exit(0)
}
if let i = args.firstIndex(of: "--fake-sudo"), i + 1 < args.count { SleepHold.sudo = args[i + 1] }   // tests: a script that logs its arguments
if args.contains("--test-prefs"), let verb = args.last {
    let m = Model()
    if verb == "set-on" { m.chimeOnClose = true } else if verb == "set-off" { m.chimeOnClose = false }
    print("chimeOnClose =", m.chimeOnClose)
    let stored = UserDefaults.standard.object(forKey: "chimeOnClose") as? Bool ?? true
    let chimePass = m.chimeOnClose == stored && Model().chimeOnClose == stored
    print("\(chimePass ? "PASS" : "FAIL") Lid chime matches saved preference")
    m.allowSleep = true
    let manualPass = !Model().allowSleep
    print("\(manualPass ? "PASS" : "FAIL") Allow sleep starts off in a new model")
    exit(chimePass && manualPass ? 0 : 1)
}
if args.contains("--test-hold") {
    var failures = 0
    MainActor.assumeIsolated {
        let h = SleepHold()
        h.sleepNow = {}   // tests never sleep the Mac
        h.floorProbe = { _ in nil }   // deterministic; never depend on the real battery or thermal state
        func show(_ what: String, held: Bool, floor: Bool = false) {
            let pass = h.available && h.held == held && (h.floor != nil) == floor
            print("\(pass ? "PASS" : "FAIL") \(what): \(h.summary)")
            if !pass { failures += 1 }
        }
        h.probe(); spin(1)
        print("helper available:", h.available)
        show("after launch reset", held: false)
        h.sync(awake: true); spin(0.8); show("keep-awake ON", held: true)
        h.floorProbe = { _ in "test: battery at 9%" }
        h.sync(awake: true); spin(0.8); show("safety floor trips (battery 9%)", held: false, floor: true)
        h.floorProbe = { _ in nil }
        h.sync(awake: true); spin(0.8); show("floor clears", held: true)
        if args.contains("--crash") { EventLog.write("TEST hold: SIGKILL while held"); print("SIGKILL now"); fflush(stdout); raise(SIGKILL) }
        h.sync(awake: false); spin(0.8); show("keep-awake OFF", held: false)
        h.sync(awake: true); spin(0.8); show("keep-awake ON again", held: true)
        h.releaseNow(); show("quit (releaseNow)", held: false)

        // Drive the real manual-switch/wake path with one synthetic agent and the same fake helper.
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/hold-busy-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        Busy.dir = dir; Busy.codexRoot = nil; Busy.tasksRoot = nil
        FileManager.default.createFile(atPath: dir.appendingPathComponent("agent").path, contents: nil)
        let m = Model()
        m.hold.sleepNow = {}; m.hold.floorProbe = { _ in nil }
        func checkModel(_ name: String, awake: Bool, allowed: Bool) {
            let pass = m.agents == 1 && m.awake == awake && m.hold.held == awake && m.allowSleep == allowed
            print("\(pass ? "PASS" : "FAIL") \(name): agents=\(m.agents) awake=\(m.awake) allowed=\(m.allowSleep) hold=\(m.hold.held)")
            if !pass { failures += 1 }
        }
        m.hold.probe(); spin(1); m.refresh(); spin(0.8)
        checkModel("agent holds awake", awake: true, allowed: false)
        m.toggleAllowSleep(); spin(0.8)
        checkModel("Allow sleep releases hold with agent working", awake: false, allowed: true)
        m.toggleAllowSleep(); spin(0.8)
        checkModel("second click restores agent hold", awake: true, allowed: false)
        m.toggleAllowSleep(); spin(0.8); m.resetAfterWake(); spin(0.8)
        checkModel("wake clears Allow sleep and restores agent hold", awake: true, allowed: false)
        m.hold.releaseNow()
    }
    exit(failures == 0 ? 0 : 1)
}
// `Loaf --test-busy [--fake-sudo <script>]`: the busy signal drives the hold. Uses a simulated clock and its own busy and
// task folders under .build, so real sessions never count. Exits 1 if any step differs from what it expects.
if args.contains("--test-busy") {
    var failures = 0
    MainActor.assumeIsolated {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/test-busy-\(UUID().uuidString)")
        try! fm.createDirectory(at: root.appendingPathComponent("busy"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        Busy.dir = root.appendingPathComponent("busy"); Busy.codexRoot = nil; Busy.tasksRoot = root.appendingPathComponent("tasks")
        let m = Model()
        m.hold.sleepNow = {}   // tests never sleep the Mac
        m.hold.floorProbe = { _ in nil }   // deterministic; never depend on the real battery or thermal state
        func file(_ name: String) -> URL { Busy.dir.appendingPathComponent(name) }
        let t0 = Date()
        func touch(_ name: String, at dt: Double, age: Double = 0) {   // mtime on the simulated clock
            fm.createFile(atPath: file(name).path, contents: nil)
            try? fm.setAttributes([.modificationDate: t0.addingTimeInterval(dt - age)], ofItemAtPath: file(name).path)
        }
        func step(_ what: String, _ dt: Double, agents: Int, awake: Bool) {
            m.refresh(now: t0.addingTimeInterval(dt)); spin(0.6)
            let pass = m.agents == agents && m.awake == awake && m.hold.held == (awake && m.hold.available)
            print("\(pass ? "PASS" : "FAIL")", what.padding(toLength: 46, withPad: " ", startingAt: 0), "agents=\(m.agents) cat=\(m.awake ? "awake" : "asleep") hold=\(m.hold.held ? "SET" : "off")")
            if !pass { failures += 1 }
        }
        m.hold.probe(); spin(1)
        print("helper available:", m.hold.available)
        step("1. no busy files", 0, agents: 0, awake: false)
        touch("session-a", at: 1); step("2. session-a touched", 1, agents: 1, awake: true)
        try? fm.removeItem(at: file("session-a")); step("3. session-a deleted (grace starts)", 2, agents: 0, awake: true)
        step("4. 61 s after last busy", 62, agents: 0, awake: true)
        step("5. 119 s after last busy", 120, agents: 0, awake: true)
        step("6. 122 s after last busy", 123, agents: 0, awake: false)
        touch("session-b", at: 124, age: 240); step("7. file touched 4 min ago", 124, agents: 0, awake: false)
        touch("session-c", at: 125, age: 100); step("8. file touched 100 s ago", 125, agents: 1, awake: true)
        try? fm.removeItem(at: file("session-b")); try? fm.removeItem(at: file("session-c"))
        step("9. both removed, grace restarts", 126, agents: 0, awake: true)
        step("10. grace over", 126 + 121, agents: 0, awake: false)
        // A background task that never stops writing (a forgotten server logging every minute) counts for `Busy.openLimit`
        // (2 h) from when it was first seen, then no longer holds the Mac awake.
        let tasks = root.appendingPathComponent("tasks/project/session/tasks")
        try! fm.createDirectory(at: tasks, withIntermediateDirectories: true)
        let output = tasks.appendingPathComponent("server.output").path
        let start = 400.0, every = 61.0   // just over the once-a-minute background scan
        for k in 0...177 {   // 3 h
            let dt = start + Double(k) * every
            fm.createFile(atPath: output, contents: nil)
            try? fm.setAttributes([.modificationDate: t0.addingTimeInterval(dt)], ofItemAtPath: output)
            switch k {
            case 0: step("11. background task writing", dt, agents: 1, awake: true)
            case 117: step("12. still writing 1 h 59 min later", dt, agents: 1, awake: true)
            case 119: step("13. 2 h 1 min: no longer counted, grace", dt, agents: 0, awake: true)
            case 177: step("14. 3 h, still writing: may sleep", dt, agents: 0, awake: false)
            default:
                m.refresh(now: t0.addingTimeInterval(dt))
                let expected = Double(k) * every <= Busy.openLimit ? 1 : 0
                if m.background.total != expected { print("FAIL background task at \(Int(dt - start)) s: counted \(m.background.total), expected \(expected)"); failures += 1 }
            }
        }
        m.hold.releaseNow()
    }
    exit(failures == 0 ? 0 : 1)
}
// `Loaf --test-sleep --fake-sudo <script>`: when the hold is released the Mac sleeps only with the lid shut and no external
// display. The lid, the display and the sleep call are all simulated; the real Mac is never put to sleep. Needs the helper
// (or --fake-sudo); exits 1 without it or if any sleepnow count differs from what it expects.
if args.contains("--test-sleep") {
    var failures = 0
    MainActor.assumeIsolated {
        let h = SleepHold()
        var lid = false, display = false, calls = 0
        h.lidIsClosed = { lid }
        h.externalDisplayAttached = { display }
        h.sleepNow = { calls += 1 }
        h.probe(); spin(1)
        if !h.available { print("FAIL sleep helper not available: run with --fake-sudo <script>"); failures += 1 }
        func show(_ what: String, expected: Int) {
            let pass = calls == expected
            print("\(pass ? "PASS" : "FAIL")", what.padding(toLength: 52, withPad: " ", startingAt: 0), "sleepnow calls =", calls)
            if !pass { failures += 1 }
        }
        func scenario(_ what: String, lidShut: Bool, extDisplay: Bool, floor: Bool = false, openDuringGrace: Bool = false, expected: Int) {
            lid = false; display = extDisplay; calls = 0; h.floorProbe = { _ in nil }
            h.sync(awake: true); spin(0.6)
            lid = lidShut
            if openDuringGrace { lid = true; spin(0.1); lid = false }   // opened again while agents were still in grace
            if floor { h.floorProbe = { _ in "test: battery at 9%" }; h.sync(awake: true) } else { h.sync(awake: false) }
            spin(0.6)
            show(what, expected: expected)
            h.floorProbe = { _ in nil }; h.sync(awake: false); spin(0.4); calls = 0
        }
        scenario("lid CLOSED, grace ends", lidShut: true, extDisplay: false, expected: 1)
        scenario("lid OPEN, grace ends", lidShut: false, extDisplay: false, expected: 0)
        scenario("lid CLOSED + external display, grace ends", lidShut: true, extDisplay: true, expected: 0)
        scenario("lid CLOSED, battery floor trips", lidShut: true, extDisplay: false, floor: true, expected: 1)
        scenario("lid OPEN, battery floor trips", lidShut: false, extDisplay: false, floor: true, expected: 0)
        scenario("lid closed then reopened during grace, grace ends", lidShut: false, extDisplay: false, openDuringGrace: true, expected: 0)
        // quit never sleeps the Mac
        lid = true; calls = 0; h.sync(awake: true); spin(0.6); h.releaseNow(); spin(0.3)
        show("quit with the lid CLOSED", expected: 0)
    }
    exit(failures == 0 ? 0 : 1)
}
if args.contains("--test-chime") {
    var failures = 0
    MainActor.assumeIsolated {
        let silent = !args.contains("--audible")
        Chime.shared.silent = silent
        let model = Model()
        model.hold.sleepNow = {}   // tests never sleep the Mac
        let watch = LidWatch()
        var closes = 0, chimes = 0
        watch.context = { model.hold.summary }
        watch.onClose = {   // a chime is counted when lidDidClose decides to play one (it stamps lastChime)
            closes += 1
            let before = model.lastChime
            model.lidDidClose(reason: $0)
            if model.lastChime != before { chimes += 1 }
        }
        func check(_ what: String, _ pass: Bool) {
            print("\(pass ? "PASS" : "FAIL") \(what): closes=\(closes) chimes=\(chimes)")
            if !pass { failures += 1 }
        }
        model.hold.probe()
        spin(1)
        model.hold.sync(awake: true)   // as if something were keeping the Mac awake
        spin(0.8)
        EventLog.write("TEST begin (\(silent ? "silent" : "audible")) \(model.hold.summary) \(Output.summary)")
        let wasOn = model.chimeOnClose
        model.chimeOnClose = true
        // 1. the lid comes down: 100 deg to 2 deg in 0.4 s, sampled at 25 ms like the real watcher
        for a in stride(from: 100.0, through: 2.0, by: -6.0) { watch.feed(angle: a); spin(0.025) }
        check("lid falling through 45 degrees chimes once", closes == 1 && chimes == 1 && Chime.shared.isPlaying)
        // 2. the clamshell switch follows for the same close
        spin(0.4)
        watch.simulateClamshell(closed: true)
        check("clamshell switch for the same close does not chime again", closes == 2 && chimes == 1)
        spin(Chime.length + 1)
        // 3. Lid chime off: a second close must not sound
        model.chimeOnClose = false
        model.lastChime = .distantPast
        for a in stride(from: 100.0, through: 2.0, by: -6.0) { watch.feed(angle: a); spin(0.002) }
        spin(0.2)
        check("second close with Lid chime off stays silent", closes == 3 && chimes == 1)
        model.chimeOnClose = wasOn
        model.hold.sync(awake: false); spin(0.8)
        EventLog.write("TEST end \(model.hold.summary)")
        print("SleepDisabled at end:", SleepHold.sleepDisabled)
    }
    exit(failures == 0 ? 0 : 1)
}

// One Loaf at a time: a second copy (a double-click while the LaunchAgent's copy runs) quits quietly.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
    EventLog.write("another Loaf is already running; quitting this copy")
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
