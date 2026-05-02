import Foundation
import NudgeCore

// nudge-update — checks GitHub releases for a newer Nudge.app and (with
// --apply) downloads, swaps, and relaunches it.
//
// Usage:
//   nudge-update              # print current vs latest, exit 0
//   nudge-update --check      # exit 0 if up-to-date, 1 if an update exists
//   nudge-update --apply      # download + replace /Applications/Nudge.app
//
// This is the v1 of the updater; eventually replaced by Sparkle.

let repo = "ZachDeLong/nudge"
let appPath = "/Applications/Nudge.app"
let assetName = "Nudge.app.zip"

let args = Array(CommandLine.arguments.dropFirst())
let checkOnly = args.contains("--check")
let apply = args.contains("--apply")

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// MARK: - Read installed version

func installedVersion() -> Version? {
    let plistURL = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: plistURL) else { return nil }
    guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
    guard let raw = plist["CFBundleShortVersionString"] as? String else { return nil }
    return Version(raw)
}

guard let current = installedVersion() else {
    eprint("nudge-update: couldn't read \(appPath)/Contents/Info.plist — is Nudge installed?")
    exit(2)
}

// MARK: - Fetch latest release

let release: GitHubReleases.Release
do {
    release = try GitHubReleases.latest(repo: repo, assetName: assetName)
} catch {
    eprint("nudge-update: failed to query GitHub: \(error)")
    exit(2)
}

guard let latest = Version(release.tag) else {
    eprint("nudge-update: latest tag \(release.tag) didn't parse as a version")
    exit(2)
}

// MARK: - Compare

if current >= latest {
    print("Nudge \(current) is up to date (latest: \(latest)).")
    exit(0)
}

print("Update available: \(current) → \(latest)")
if let url = release.assetURL {
    print("  asset: \(url.absoluteString)")
} else {
    print("  (no \(assetName) asset attached to this release yet)")
}

if checkOnly {
    exit(1)
}

if !apply {
    print("Re-run with --apply to download and install.")
    exit(0)
}

// MARK: - Apply

guard let assetURL = release.assetURL else {
    eprint("nudge-update: release \(latest) has no \(assetName) asset; can't auto-apply.")
    exit(2)
}

print("Downloading \(assetURL.lastPathComponent)…")

let stagingDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("nudge-update-\(UUID().uuidString)")
try? FileManager.default.removeItem(at: stagingDir)
try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

let zipURL = stagingDir.appendingPathComponent(assetName)
let downloadOK = downloadSync(assetURL, to: zipURL)
guard downloadOK else {
    eprint("nudge-update: download failed.")
    exit(2)
}

print("Unzipping…")
let unzip = Process()
unzip.launchPath = "/usr/bin/unzip"
unzip.arguments = ["-q", zipURL.path, "-d", stagingDir.path]
do {
    try unzip.run()
    unzip.waitUntilExit()
} catch {
    eprint("nudge-update: unzip failed: \(error.localizedDescription)")
    exit(2)
}
guard unzip.terminationStatus == 0 else {
    eprint("nudge-update: unzip exited \(unzip.terminationStatus).")
    exit(2)
}

let stagedApp = stagingDir.appendingPathComponent("Nudge.app")
guard FileManager.default.fileExists(atPath: stagedApp.path) else {
    eprint("nudge-update: zip didn't contain Nudge.app at the top level.")
    exit(2)
}

print("Quitting running Nudge…")
let kill = Process()
kill.launchPath = "/usr/bin/pkill"
kill.arguments = ["-x", "Nudge"]
try? kill.run()
kill.waitUntilExit()
// pkill exits 1 when no process matched; fine either way.

print("Swapping app bundle…")
let stale = URL(fileURLWithPath: appPath + ".old-\(Int(Date().timeIntervalSince1970))")
do {
    if FileManager.default.fileExists(atPath: appPath) {
        try FileManager.default.moveItem(atPath: appPath, toPath: stale.path)
    }
    try FileManager.default.moveItem(at: stagedApp, to: URL(fileURLWithPath: appPath))
    // Clear the quarantine bit so the swap doesn't trip Gatekeeper.
    let xattr = Process()
    xattr.launchPath = "/usr/bin/xattr"
    xattr.arguments = ["-dr", "com.apple.quarantine", appPath]
    try? xattr.run()
    xattr.waitUntilExit()
    // Best-effort cleanup of the .old bundle.
    try? FileManager.default.removeItem(at: stale)
} catch {
    eprint("nudge-update: swap failed: \(error.localizedDescription)")
    if FileManager.default.fileExists(atPath: stale.path) {
        try? FileManager.default.moveItem(atPath: stale.path, toPath: appPath)
    }
    exit(2)
}

refreshPathSymlinks()

print("Relaunching Nudge…")
let open = Process()
open.launchPath = "/usr/bin/open"
open.arguments = ["-ga", "Nudge"]
try? open.run()
// Don't waitUntilExit — open returns immediately and the new app stays running.

try? FileManager.default.removeItem(at: stagingDir)
print("✓ Updated to Nudge \(latest).")

// MARK: - Helpers

/// Mirrors `scripts/link-cli.sh`. After a swap, refresh the PATH symlinks so
/// users upgrading from a pre-1.2.0 install still get the bare command names
/// (and so any newly-bundled CLIs land on PATH on the next release).
func refreshPathSymlinks() {
    let names = ["nudge-claude", "nudge-update"]
    let candidates = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("bin").path,
    ]
    let appBin = "\(appPath)/Contents/MacOS"

    var dest: String?
    for dir in candidates {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
        if FileManager.default.isWritableFile(atPath: dir) { dest = dir; break }
    }
    guard let dest = dest else { return }

    for name in names {
        let target = "\(appBin)/\(name)"
        guard FileManager.default.isExecutableFile(atPath: target) else { continue }
        let link = "\(dest)/\(name)"
        // Replace any existing entry — link, regular file, or stale path.
        try? FileManager.default.removeItem(atPath: link)
        do {
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        } catch {
            eprint("  warning: failed to symlink \(link): \(error.localizedDescription)")
        }
    }
}

func downloadSync(_ url: URL, to dest: URL) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    var ok = false
    var req = URLRequest(url: url)
    req.setValue("nudge-update", forHTTPHeaderField: "User-Agent")
    let task = URLSession.shared.downloadTask(with: req) { tmp, response, err in
        defer { semaphore.signal() }
        guard let tmp = tmp else {
            if let err = err { eprint("  \(err.localizedDescription)") }
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            eprint("  http \(status)")
            return
        }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tmp, to: dest)
            ok = true
        } catch {
            eprint("  \(error.localizedDescription)")
        }
    }
    task.resume()
    semaphore.wait()
    return ok
}
