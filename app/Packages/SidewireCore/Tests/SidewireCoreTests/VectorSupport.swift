import XCTest
import Foundation

/// See `SidewireProtocolTests/VectorSupport.swift` — same generate/verify machinery, used here
/// for the crypto (pairing) vectors that live in `SidewireCore`. Writes with
/// `SIDEWIRE_WRITE_VECTORS=1 swift test`, otherwise verifies the checked-in files.
enum Vectors {
    static func repoRoot(_ filePath: StaticString = #filePath) -> URL {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        for _ in 0..<12 {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.appendingPathComponent("Packages").path, isDirectory: &isDir),
               isDir.boolValue {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        fatalError("Vectors.repoRoot: could not locate the repo root from \(filePath)")
    }

    static var directory: URL { repoRoot().appendingPathComponent("protocol-vectors") }
    static var isWriting: Bool { ProcessInfo.processInfo.environment["SIDEWIRE_WRITE_VECTORS"] != nil }

    static func sync<T: Codable & Equatable>(_ fileName: String, _ document: T,
                                             file: StaticString = #filePath, line: UInt = #line) {
        let url = directory.appendingPathComponent(fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        if isWriting {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var data = try encoder.encode(document)
                data.append(0x0A)
                try data.write(to: url)
                print("wrote vectors: \(url.path)")
            } catch {
                XCTFail("failed to write \(fileName): \(error)", file: file, line: line)
            }
            return
        }

        guard let data = try? Data(contentsOf: url) else {
            XCTFail("missing \(url.path) — regenerate with `SIDEWIRE_WRITE_VECTORS=1 swift test`",
                    file: file, line: line)
            return
        }
        do {
            let onDisk = try JSONDecoder().decode(T.self, from: data)
            XCTAssertEqual(onDisk, document,
                           "\(fileName) is stale vs the current encoding — regenerate with `SIDEWIRE_WRITE_VECTORS=1 swift test`",
                           file: file, line: line)
        } catch {
            XCTFail("failed to decode \(fileName): \(error)", file: file, line: line)
        }
    }
}
