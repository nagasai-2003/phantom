import AppKit
import ScreenCaptureKit

// Captures the main display as a base64 PNG. Phantom's own windows use
// sharingType = .none, so they never appear in the image.
func captureScreenBase64(maxWidth: Int = 1440, completion: @escaping (String?) -> Void) {
    guard #available(macOS 14.0, *) else {
        completion(legacyCaptureScreen().flatMap { pngBase64($0, maxWidth: maxWidth) })
        return
    }
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
        guard let displays = content?.displays,
              let display = displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? displays.first else {
            CGRequestScreenCaptureAccess()
            completion(nil)
            return
        }
        let cfg = SCStreamConfiguration()
        let scale = display.width > maxWidth ? Double(maxWidth) / Double(display.width) : 1.0
        cfg.width = max(1, Int(Double(display.width) * scale))
        cfg.height = max(1, Int(Double(display.height) * scale))
        cfg.showsCursor = false
        SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []),
                                         configuration: cfg) { image, error in
            if let error = error { print("[screenshot] \(error)") }
            completion(image.flatMap { pngBase64($0, maxWidth: maxWidth) })
        }
    }
}

private func legacyCaptureScreen() -> CGImage? {
    let cg = CGWindowListCreateImage(.infinite, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)
    if cg == nil { CGRequestScreenCaptureAccess() }
    return cg
}

private func pngBase64(_ cg: CGImage, maxWidth: Int) -> String? {
    let w = cg.width, h = cg.height
    let scale = w > maxWidth ? Double(maxWidth) / Double(w) : 1.0
    let tw = max(1, Int(Double(w) * scale)), th = max(1, Int(Double(h) * scale))
    guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
    guard let resized = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: resized)
    guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
    return png.base64EncodedString()
}
