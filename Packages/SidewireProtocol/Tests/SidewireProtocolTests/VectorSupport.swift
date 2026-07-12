import XCTest
import Foundation

/// Shared machinery for the language-neutral **golden vectors** in `protocol-vectors/`.
///
/// Each vector JSON file is the conformance fixture a foreign (e.g. Rust) implementation tests
/// against. The files are generated FROM these Swift tests and checked in:
///
/// - `SIDEWIRE_WRITE_VECTORS=1 swift test` → (re)writes the files from the current encoding.
/// - plain `swift test` → decodes the checked-in files and asserts they still match the current
///   encoding, so any drift in the wire format fails a test until the vectors are regenerated.
///
/// See `protocol-vectors/README.md`.
enum Vectors {
    /// Locate the repo root by walking up from this source file until a directory containing a
    /// `Packages/` subdirectory is found (only the repo root has one).
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

    /// Write (generate mode) or verify (default) a vector document against `fileName`.
    static func sync<T: Codable & Equatable>(_ fileName: String, _ document: T,
                                             file: StaticString = #filePath, line: UInt = #line) {
        let url = directory.appendingPathComponent(fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        if isWriting {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var data = try encoder.encode(document)
                data.append(0x0A) // trailing newline for tidy diffs
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

extension Data {
    /// Lowercase hex, used throughout the vectors.
    var vectorHex: String { map { String(format: "%02x", $0) }.joined() }
}
