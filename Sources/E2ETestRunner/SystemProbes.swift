// What layer 2 needs to see outside its own process: other processes (to
// catch a real Nudge hook firing inside a test session), on-screen windows
// (to find a popover by owner pid), and small helpers for running tools.

import CoreGraphics
import Darwin
import Foundation

// MARK: - Running tools

struct ToolResult {
    let status: Int32
    let out: String
    let err: String
    var ok: Bool { status == 0 }
}

/// Runs `exe` to completion (killing it after `timeout`), capturing output.
/// Stdin is /dev/null so nothing can block on a terminal.
@discardableResult
func runTool(_ exe: String, _ args: [String], cwd: URL? = nil, timeout: TimeInterval = 60) -> ToolResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    let out = Pipe(), err = Pipe()
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = out
    p.standardError = err
    let group = DispatchGroup()
    var outData = Data(), errData = Data()
    do {
        try p.run()
    } catch {
        return ToolResult(status: 127, out: "", err: "\(exe): \(error)")
    }
    // Drain both pipes while it runs so a chatty tool can't fill one and stall.
    group.enter()
    DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.enter()
    DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    if !waitUntil(timeout, { !p.isRunning }) {
        p.terminate()
        if !waitUntil(2, { !p.isRunning }) { kill(p.processIdentifier, SIGKILL) }
    }
    p.waitUntilExit()
    group.wait()
    return ToolResult(status: p.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self))
}

/// First executable named `name` on PATH, then in the usual install spots.
func findExecutable(_ name: String, extraDirs: [String] = []) -> String? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let dirs = path.split(separator: ":").map(String.init)
        + extraDirs.map { $0.replacingOccurrences(of: "~", with: home) }
    for dir in dirs {
        let candidate = (dir as NSString).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}

/// Single-quotes `s` for /bin/sh.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

// MARK: - Processes

struct ProcInfo {
    let pid: pid_t
    let ppid: pid_t
    let path: String
}

/// Every process we can see, with its parent and executable path.
func processTable() -> [ProcInfo] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    var table: [ProcInfo] = []
    for pid in pids.prefix(Int(max(n, 0))) where pid > 0 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
        var buf = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        table.append(ProcInfo(pid: pid, ppid: pid_t(info.pbi_ppid), path: len > 0 ? String(cString: buf) : ""))
    }
    return table
}

/// All processes below `root` in `table` (children, grandchildren, ...).
func descendants(of root: pid_t, in table: [ProcInfo]) -> [ProcInfo] {
    var children: [pid_t: [ProcInfo]] = [:]
    for p in table { children[p.ppid, default: []].append(p) }
    var out: [ProcInfo] = []
    var stack = children[root] ?? []
    while let p = stack.popLast() {
        out.append(p)
        stack.append(contentsOf: children[p.pid] ?? [])
    }
    return out
}

// MARK: - Windows

struct WindowInfo {
    let id: Int
    let pid: pid_t
    let layer: Int
    let bounds: CGRect
}

/// On-screen windows owned by any of `pids`. Owner pid, layer, and bounds
/// don't need Screen Recording permission; titles would, and we don't use them.
func onScreenWindows(ownedBy pids: Set<pid_t>) -> [WindowInfo] {
    guard !pids.isEmpty,
          let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    return list.compactMap { w in
        guard let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(pid),
              let id = (w[kCGWindowNumber as String] as? NSNumber)?.intValue,
              let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }
        let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        return WindowInfo(id: id, pid: pid, layer: layer, bounds: bounds)
    }
}

/// Nudge's popover is a borderless panel above the menu bar's layer; the
/// status item itself is a small window on the same layer, so size tells
/// them apart.
func popoverWindows(ownedBy pids: Set<pid_t>) -> [WindowInfo] {
    onScreenWindows(ownedBy: pids).filter { $0.layer > 0 && $0.bounds.width >= 300 && $0.bounds.height >= 100 }
}
