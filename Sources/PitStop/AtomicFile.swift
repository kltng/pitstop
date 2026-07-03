import Foundation

enum AtomicFile {
    /// `.atomic` writes rename a temp file over the destination, which
    /// replaces a symlink itself rather than its target — silently forking
    /// state for dotfile-symlink setups. Resolve first, then write.
    /// Preserves an existing destination's permissions (Foundation copies
    /// them onto the temp file); a fresh file gets the default 644.
    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url.resolvingSymlinksInPath(), options: .atomic)
    }

    /// Atomic write for secret-bearing files: the temp file is born with
    /// `mode` (e.g. 0o600), so the bytes are never readable more broadly
    /// than intended — not even in the window a write-then-chmod leaves open
    /// when the destination didn't exist yet.
    static func write(_ data: Data, to url: URL, mode: Int) throws {
        let dest = url.resolvingSymlinksInPath()
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(
            ".\(dest.lastPathComponent).pitstop-\(ProcessInfo.processInfo.globallyUniqueString)")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data,
                                             attributes: [.posixPermissions: mode]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path])
        }
        guard rename(tmp.path, dest.path) == 0 else {
            let err = errno
            try? FileManager.default.removeItem(at: tmp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err),
                          userInfo: [NSFilePathErrorKey: dest.path])
        }
    }
}
