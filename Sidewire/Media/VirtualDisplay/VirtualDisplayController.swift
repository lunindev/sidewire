import Foundation
import CoreGraphics

/// Owns the private CGVirtualDisplay. Phase 0 creates it in-process (as the previous
/// app did). Phase 1 moves creation into the SidewireDisplayHelper subprocess for
/// reliable registration + crash isolation (see docs/00 C2, docs/04 § Virtual Display),
/// keeping this same async-ish API.
///
/// Guardrails already in place: a minimal single-mode list and a 60 Hz cap, to avoid the
/// documented WindowServer mode-list assertion / high-refresh crash.
final class VirtualDisplayController: ObservableObject {
    private var display: CGVirtualDisplay?

    @Published var isActive = false
    @Published var statusMessage = "Not created"
    @Published var virtualDisplayID: CGDirectDisplayID?
    @Published var width: UInt = 2560
    @Published var height: UInt = 1600

    /// Fired on the main queue once the display has a valid ID (ready to capture).
    var onActivated: ((CGDirectDisplayID) -> Void)?
    private var activationReported = false

    func create() {
        guard display == nil else { return }
        Log.media.info("creating virtual display \(self.width)x\(self.height)")

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "Sidewire Display"
        descriptor.maxPixelsWide = UInt32(width)
        descriptor.maxPixelsHigh = UInt32(height)
        descriptor.sizeInMillimeters = CGSize(width: 340, height: 210)
        descriptor.productID = 0x1234
        descriptor.vendorID = 0x5678
        descriptor.serialNum = 0x0001
        descriptor.terminationHandler = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.isActive = false
                self?.statusMessage = "Terminated by system"
                self?.virtualDisplayID = nil
                self?.display = nil
            }
        }

        let vd = CGVirtualDisplay(descriptor: descriptor)

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        // Minimal mode list, 60 Hz cap — see guardrail note above.
        settings.modes = [
            CGVirtualDisplayMode(width: width / 2, height: height / 2, refreshRate: 60)
        ]
        vd.apply(settings)
        self.display = vd

        let did = vd.displayID
        if did != 0 {
            DispatchQueue.main.async {
                self.virtualDisplayID = did
                self.isActive = true
                self.statusMessage = "Active (ID: \(did))"
                self.forceHiDPIMode(displayID: did)
                self.reportActivation(did)
            }
        } else {
            DispatchQueue.main.async { self.statusMessage = "Created, waiting for ID..." }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.pollDisplayID() }
        }
    }

    func recreate(width: UInt, height: UInt) {
        self.width = width
        self.height = height
        destroy()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.create() }
    }

    func destroy() {
        display = nil
        activationReported = false
        DispatchQueue.main.async {
            self.virtualDisplayID = nil
            self.isActive = false
            self.statusMessage = "Destroyed"
        }
    }

    private func reportActivation(_ did: CGDirectDisplayID) {
        guard !activationReported else { return }
        activationReported = true
        Log.media.info("virtual display registered with ID \(did)")
        onActivated?(did)
    }

    private func pollDisplayID() {
        guard let vd = display else { return }
        let did = vd.displayID
        if did != 0 {
            virtualDisplayID = did
            isActive = true
            statusMessage = "Active (ID: \(did))"
            forceHiDPIMode(displayID: did)
            reportActivation(did)
        } else {
            statusMessage = "Waiting for system recognition..."
            Log.media.notice("virtual display not yet registered (in-process CGVirtualDisplay may need the Phase 1 helper subprocess)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.pollDisplayID() }
        }
    }

    private func forceHiDPIMode(displayID: CGDirectDisplayID) {
        let targetW = Int(width / 2)
        let targetH = Int(height / 2)
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue!] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return }
        if let hiDPI = modes.first(where: { $0.width == targetW && $0.height == targetH && $0.pixelWidth > $0.width }) {
            CGDisplaySetDisplayMode(displayID, hiDPI, nil)
            return
        }
        if let mode = modes.first(where: { $0.width == targetW && $0.height == targetH }) {
            CGDisplaySetDisplayMode(displayID, mode, nil)
        }
    }

    deinit { display = nil }
}
