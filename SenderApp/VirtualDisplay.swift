import Foundation
import CoreGraphics

final class VirtualDisplay: ObservableObject {
    private var display: CGVirtualDisplay?

    @Published var isActive = false
    @Published var statusMessage = "Not created"
    @Published var virtualDisplayID: CGDirectDisplayID?

    @Published var width: UInt = 2560
    @Published var height: UInt = 1600

    func create() {
        guard display == nil else { return }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "MacDisplay Virtual Monitor"
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
            }
            print("[VirtualDisplay] Created with ID: \(did)")
        } else {
            DispatchQueue.main.async {
                self.statusMessage = "Created, waiting for ID..."
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.pollDisplayID()
            }
        }
    }

    func recreate(width: UInt, height: UInt) {
        self.width = width
        self.height = height
        destroy()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.create()
        }
    }

    func destroy() {
        display = nil
        DispatchQueue.main.async {
            self.virtualDisplayID = nil
            self.isActive = false
            self.statusMessage = "Destroyed"
        }
    }

    private func pollDisplayID() {
        guard let vd = display else { return }
        let did = vd.displayID
        if did != 0 {
            virtualDisplayID = did
            isActive = true
            statusMessage = "Active (ID: \(did))"
            forceHiDPIMode(displayID: did)
            print("[VirtualDisplay] Display ID: \(did)")
        } else {
            statusMessage = "Waiting for system recognition..."
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.pollDisplayID()
            }
        }
    }

    private func forceHiDPIMode(displayID: CGDirectDisplayID) {
        let targetW = Int(width / 2)
        let targetH = Int(height / 2)

        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue!] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return }

        print("[VirtualDisplay] Available modes:")
        for mode in modes {
            print("  \(mode.width)×\(mode.height) pixel:\(mode.pixelWidth)×\(mode.pixelHeight)")
        }

        if let hiDPI = modes.first(where: { $0.width == targetW && $0.height == targetH && $0.pixelWidth > $0.width }) {
            CGDisplaySetDisplayMode(displayID, hiDPI, nil)
            print("[VirtualDisplay] Forced HiDPI mode: \(hiDPI.width)×\(hiDPI.height) @2x")
            return
        }

        if let mode = modes.first(where: { $0.width == targetW && $0.height == targetH }) {
            CGDisplaySetDisplayMode(displayID, mode, nil)
            print("[VirtualDisplay] Forced mode: \(mode.width)×\(mode.height)")
        }
    }

    deinit {
        display = nil
    }
}
