import Foundation
import CoreGraphics

/// The virtual-display helper. The main app re-execs its OWN universal binary with
/// `--vd-helper` (see main.swift); that subprocess runs this instead of the GUI.
///
/// Why a subprocess: `CGVirtualDisplay` registers reliably only from a clean process
/// context (a shipping app, Lumen, needed exactly this), and isolating it means an
/// encoder/transport crash in the main app can never strand a phantom monitor. If the
/// main app dies, this helper's stdin reaches EOF and it tears the display down.
enum VirtualDisplayHelper {
    static func run() -> Never {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let width = UInt(value("--width") ?? "") ?? 2560
        let height = UInt(value("--height") ?? "") ?? 1600

        let vd = VirtualDisplayController()
        vd.width = width
        vd.height = height
        vd.onActivated = { did in
            // The ONLY thing written to stdout — the parent parses "ACTIVATED <id>".
            FileHandle.standardOutput.write(Data("ACTIVATED \(did)\n".utf8))
        }
        DispatchQueue.main.async { vd.create() }

        // Read stdin on a background thread. EOF (parent exited/crashed) or an explicit
        // "DESTROY" tears the display down and exits — no phantom display survives.
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                if line == "DESTROY" { break }
            }
            DispatchQueue.main.async {
                vd.destroy()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
            }
        }

        dispatchMain() // run loop for the CGVirtualDisplay dispatch queue; never returns
    }
}
