import Darwin
import Foundation

/// Exits a blocking CLI (nudge-hook, nudge-ask) once nobody is waiting on it.
///
/// Claude Code starts each hook in its own process group, so when `claude` is
/// SIGKILLed nothing signals the hook: it would sit on its socket and hold the
/// head of Nudge's queue until the server's 5-minute timeout. Two signals mean
/// the caller is gone, and either one ends the process (which closes the
/// socket, and the server withdraws the prompt):
///
/// - the parent process exits (the hook is reparented), or
/// - the read end of stdout closes — the caller that would read our answer
///   died, even if an intermediate `sh -c` parent is still alive.
public enum CallerWatch {
    public static func exitWhenCallerGone(onGone: @escaping () -> Void = { exit(0) }) {
        let parent = getppid()
        guard parent > 1 else { return onGone() }

        let kq = kqueue()
        guard kq >= 0 else { return }

        var changes = [
            kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                   fflags: UInt32(NOTE_EXIT), data: 0, udata: nil),
        ]
        var st = stat()
        let type = fstat(STDOUT_FILENO, &st) == 0 ? st.st_mode & S_IFMT : 0
        if type == S_IFIFO || type == S_IFSOCK {
            // EV_CLEAR: report the pipe once as writable, then again only when
            // its state changes, which for an idle writer means the reader left.
            changes.append(kevent(ident: UInt(STDOUT_FILENO), filter: Int16(EVFILT_WRITE),
                                  flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: nil))
        }
        if kevent(kq, &changes, Int32(changes.count), nil, 0, nil) < 0, errno == ESRCH {
            return onGone() // the parent died before we could watch it
        }

        let thread = Thread {
            var event = kevent()
            var tick = timespec(tv_sec: 1, tv_nsec: 0)
            while true {
                let n = kevent(kq, nil, 0, &event, 1, &tick)
                if n > 0 {
                    let eof = event.flags & UInt16(EV_EOF) != 0
                    if event.filter == Int16(EVFILT_PROC) || (event.filter == Int16(EVFILT_WRITE) && eof) {
                        return onGone()
                    }
                }
                // Belt and braces: a reparented process has lost its caller.
                if getppid() != parent { return onGone() }
            }
        }
        thread.stackSize = 64 * 1024
        thread.start()
    }
}
