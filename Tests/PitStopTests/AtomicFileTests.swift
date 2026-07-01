import XCTest
@testable import PitStop

final class AtomicFileTests: XCTestCase {
    func testWritePreservesSymlink() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pitstop-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.json")
        let link = dir.appendingPathComponent("link.json")
        try Data("old".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try AtomicFile.write(Data("new".utf8), to: link)

        // Still a symlink, and the target got the new contents.
        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink)
        XCTAssertEqual(try Data(contentsOf: real), Data("new".utf8))
    }

    func testWritePlainFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pitstop-plain-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try AtomicFile.write(Data("x".utf8), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("x".utf8))
    }
}
