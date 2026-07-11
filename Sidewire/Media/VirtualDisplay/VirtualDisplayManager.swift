import Foundation
import AppKit
import CoreGraphics

/// The virtual display as the app uses it. Prefers the helper subprocess (reliable
/// registration + crash isolation); if the helper doesn't activate in time or fails to
/// spawn, it falls back to in-process creation so behavior never regresses. Exposes the
/// same surface `VirtualDisplayController` did, so callers are unchanged.
@MainActor
final class VirtualDisplayManager: ObservableObject {
    @Published var isActive = false
    @Published var statusMessage = "Not created"
    @Published var virtualDisplayID: CGDirectDisplayID?
    @Published var width: UInt = 2560
    @Published var height: UInt = 1600

    var onActivated: ((CGDirectDisplayID) -> Void)?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var activationTimer: Timer?
    private var inProcess: VirtualDisplayController?
    private var activated = false
    /// Once the helper subprocess fails to register a display this session, stop trying it
    /// and go straight to in-process creation — so only the first attempt ever pays a delay.
    private var helperUsable = true

    /// Helper subprocess is DISABLED by default: its ~3s activation timeout was eating the
    /// receiver's no-frame budget and creating reconnect loops, and it isn't validated yet.
    /// In-process creation is instant and is the known-working path. Flip on later once the
    /// helper is proven to register when GUI-spawned.
    private let preferHelper = false

    private let helperTimeout: TimeInterval = 3.0

    func create() { recreate(width: width, height: height) }

    func recreate(width: UInt, height: UInt) {
        self.width = width
        self.height = height
        destroy()
        if preferHelper && helperUsable {
            spawnHelper(width: width, height: height)
        } else {
            fallbackInProcess(width: width, height: height)
        }
    }

    func destroy() {
        activationTimer?.invalidate(); activationTimer = nil
        teardownHelperIO()      // clears the stdout handler so no late line can fire
        stdinHandle?.closeFile(); stdinHandle = nil // EOF → child destroys display + exits
        process?.terminationHandler = nil
        process?.terminate(); process = nil
        inProcess?.onActivated = nil
        inProcess?.destroy(); inProcess = nil
        activated = false
        isActive = false
        virtualDisplayID = nil
        statusMessage = "Destroyed"
    }

    /// Clear the stdout dispatch-read source so a buffered/late "ACTIVATED" can't fire and
    /// an EOF can't busy-loop the handler.
    private func teardownHelperIO() {
        stdoutHandle?.readabilityHandler = nil
        stdoutHandle = nil
    }

    // MARK: - Helper path

    private func spawnHelper(width: UInt, height: UInt) {
        guard let exe = Bundle.main.executableURL else {
            fallbackInProcess(width: width, height: height); return
        }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--vd-helper", "--width", "\(width)", "--height", "\(height)"]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        stdinHandle = inp.fileHandleForWriting
        stdoutHandle = out.fileHandleForReading

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return } // EOF
            guard let s = String(data: data, encoding: .utf8) else { return }
            for line in s.split(separator: "\n") where line.hasPrefix("ACTIVATED ") {
                if let id = UInt32(line.dropFirst("ACTIVATED ".count)) {
                    Task { @MainActor in self?.helperActivated(id) }
                }
            }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.helperExited() }
        }

        do {
            try p.run()
            process = p
            statusMessage = "Creating (helper)…"
            activationTimer = Timer.scheduledTimer(withTimeInterval: helperTimeout, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.helperTimedOut() }
            }
        } catch {
            Log.media.error("failed to spawn vd helper: \(error.localizedDescription, privacy: .public) — in-process fallback")
            fallbackInProcess(width: width, height: height)
        }
    }

    private func helperActivated(_ id: CGDirectDisplayID) {
        // Reject a late line delivered after the helper was retired/torn down.
        guard helperUsable, !activated, process != nil else { return }
        activated = true
        activationTimer?.invalidate(); activationTimer = nil
        virtualDisplayID = id
        isActive = true
        statusMessage = "Active · helper (ID \(id))"
        Log.media.info("virtual display via helper subprocess, ID \(id)")
        onActivated?(id)
    }

    private func helperTimedOut() {
        guard !activated else { return }
        Log.media.notice("vd helper didn't activate in \(Int(self.helperTimeout))s → in-process fallback (helper disabled this session)")
        helperUsable = false
        let (w, h) = (width, height)
        teardownHelperIO()
        stdinHandle?.closeFile(); stdinHandle = nil
        process?.terminationHandler = nil
        process?.terminate(); process = nil
        fallbackInProcess(width: w, height: h)
    }

    private func helperExited() {
        teardownHelperIO()
        stdinHandle?.closeFile(); stdinHandle = nil
        process = nil
        if activated {
            // The helper crashed while holding the display → retire it and rebuild locally.
            Log.media.notice("vd helper exited after activating → retiring helper, rebuilding in-process")
            helperUsable = false
            activated = false
            isActive = false
            virtualDisplayID = nil
            fallbackInProcess(width: width, height: height)
        } else {
            helperUsable = false
            fallbackInProcess(width: width, height: height)
        }
    }

    // MARK: - In-process fallback

    private func fallbackInProcess(width: UInt, height: UInt) {
        guard inProcess == nil else { return }
        activationTimer?.invalidate(); activationTimer = nil
        let vd = VirtualDisplayController()
        vd.width = width
        vd.height = height
        vd.onActivated = { [weak self, weak vd] id in
            Task { @MainActor in
                guard let self, self.inProcess === vd else { return } // ignore after destroy/replace
                self.activated = true
                self.virtualDisplayID = id
                self.isActive = true
                self.statusMessage = "Active · in-process (ID \(id))"
                self.onActivated?(id)
            }
        }
        inProcess = vd
        statusMessage = "Creating (in-process)…"
        vd.create()
    }
}
