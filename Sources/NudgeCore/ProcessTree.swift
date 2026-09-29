import Darwin

/// Reads other processes' parent and arguments, to learn what launched a
/// hook. Codex doesn't say whether a run is scripted (`codex exec`) or a
/// person at the TUI or the ChatGPT app; the process that ran the hook does.
public enum ProcessTree {
    /// The parent of `pid`, or nil if it can't be read.
    public static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    /// `argv` of `pid` (KERN_PROCARGS2), or nil if it can't be read.
    public static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        // argc, then the executable path, NUL padding, then argv.
        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// The controlling terminal of `pid` ("/dev/ttys002"), or nil if it has
    /// none or it can't be read.
    public static func tty(of pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let dev = info.kp_eproc.e_tdev
        guard dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
        let tty = String(cString: name)
        return tty.hasPrefix("tty") ? "/dev/" + tty : nil
    }

    /// The terminal the agent that ran this hook is attached to: this
    /// process's own, or the nearest ancestor's (a hook may run detached).
    public static func sessionTTY(depth: Int = 4) -> String? {
        var pid = getpid()
        for _ in 0...depth where pid > 1 {
            if let tty = tty(of: pid) { return tty }
            guard let next = parent(of: pid) else { break }
            pid = next
        }
        return nil
    }

    /// `argv` of this process's ancestors, nearest first, up to `depth`.
    public static func ancestorArguments(depth: Int = 4) -> [[String]] {
        var result: [[String]] = []
        var pid = getppid()
        for _ in 0..<depth where pid > 1 {
            if let args = arguments(of: pid) { result.append(args) }
            guard let next = parent(of: pid) else { break }
            pid = next
        }
        return result
    }
}
