import Foundation

enum AtomicFile {
    /// `.atomic` writes rename a temp file over the destination, which
    /// replaces a symlink itself rather than its target — silently forking
    /// state for dotfile-symlink setups. Resolve first, then write.
    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url.resolvingSymlinksInPath(), options: .atomic)
    }
}
