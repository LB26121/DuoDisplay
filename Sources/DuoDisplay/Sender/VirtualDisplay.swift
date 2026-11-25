import Foundation
import CoreGraphics
import CGVirtualDisplayPrivate

/// A virtual monitor attached to this Mac. It disappears when this object is released.
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    var displayID: CGDirectDisplayID { display.displayID }

    /// Must be called on the main thread.
    init?(name: String, serial: UInt32, pixelWidth: Int, pixelHeight: Int,
          pointWidth: Int, pointHeight: Int, refreshRate: Int, hiDPI: Bool, placeRight: Bool) {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(pixelWidth)
        descriptor.maxPixelsHigh = UInt32(pixelHeight)
        // Pretend a sensible physical size so macOS picks a reasonable default scale.
        let ppi = hiDPI ? 220.0 : 110.0
        descriptor.sizeInMillimeters = CGSize(width: Double(pixelWidth) / ppi * 25.4,
                                              height: Double(pixelHeight) / ppi * 25.4)
        descriptor.vendorID = 0xD0D0
        descriptor.productID = 0xD15D
        descriptor.serialNum = serial

        let display = CGVirtualDisplay(descriptor: descriptor)
        guard display.displayID != 0 else { return nil }
        self.display = display

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        let hz = Double(refreshRate)
        var modes = [CGVirtualDisplayMode(width: UInt32(pixelWidth), height: UInt32(pixelHeight), refreshRate: hz)]
        if hiDPI && (pointWidth != pixelWidth || pointHeight != pixelHeight) {
            // Depending on the macOS version the HiDPI mode is derived from either list entry;
            // offering both guarantees a "points × scale = pixels" mode exists.
            modes.append(CGVirtualDisplayMode(width: UInt32(pointWidth), height: UInt32(pointHeight), refreshRate: hz))
        }
        settings.modes = modes
        guard display.apply(settings) else { return nil }

        selectMode(pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                   pointWidth: pointWidth, pointHeight: pointHeight, refreshRate: hz)
        place(right: placeRight, pointWidth: pointWidth)
    }

    /// Puts the virtual display directly right (or left) of the main display, top-aligned –
    /// matching where the receiver Mac physically stands.
    private func place(right: Bool, pointWidth: Int) {
        let main = CGDisplayBounds(CGMainDisplayID())
        let x = right ? Int32(main.maxX) : Int32(main.minX) - Int32(pointWidth)
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayOrigin(config, displayID, x, Int32(main.minY))
        CGCompleteDisplayConfiguration(config, .forSession)
    }

    private func selectMode(pixelWidth: Int, pixelHeight: Int, pointWidth: Int, pointHeight: Int, refreshRate: Double) {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode], !modes.isEmpty else { return }
        let exact = modes.filter {
            $0.pixelWidth == pixelWidth && $0.pixelHeight == pixelHeight &&
            $0.width == pointWidth && $0.height == pointHeight
        }
        let samePixels = modes.filter { $0.pixelWidth == pixelWidth && $0.pixelHeight == pixelHeight }
        let candidates = !exact.isEmpty ? exact : samePixels
        guard let mode = candidates.min(by: { abs($0.refreshRate - refreshRate) < abs($1.refreshRate - refreshRate) }) else { return }
        if let current = CGDisplayCopyDisplayMode(displayID),
           current.pixelWidth == mode.pixelWidth, current.width == mode.width,
           current.refreshRate == mode.refreshRate { return }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
        CGCompleteDisplayConfiguration(config, .forSession)
    }
}
