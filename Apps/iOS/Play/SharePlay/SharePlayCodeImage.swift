import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import TracksCore

/// A SharePlay code as a picture: black squares on white, drawn square by square so every
/// edge is sharp at any size, with the white margin a camera needs to find it. For the car's
/// screen and the iPhone's.
enum SharePlayCodeImage {
    /// What the code holds: Apple's App Clip link once the App Clip is live, so anyone can
    /// join, and Tracks’ own link until then. See `TRACKS_APP_CLIP_LIVE`.
    static func link(for invite: SharePlayInvite) -> URL {
        guard isForEveryone, let clip = Bundle.main.infoDictionary?["TracksAppClipBundleID"] as? String else { return invite.url }
        return invite.appClipURL(bundleID: clip)
    }

    /// Whether anyone can join with the code, Tracks or not: the App Clip is live, and there's
    /// a relay for it to reach this iPhone through.
    static var isForEveryone: Bool {
        (Bundle.main.infoDictionary?["TracksAppClipIsLive"] as? String)?.uppercased() == "YES"
            && SharePlayRelayConfig.main != nil
    }

    /// The code's squares, row by row, dark ones true, without a margin.
    static func modules(for invite: SharePlayInvite) -> [[Bool]] {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link(for: invite).absoluteString.utf8)
        // Medium: a bit of glare or a smudge on the car's screen, and it still reads.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return [] }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let image = context.createCGImage(output, from: output.extent) else { return [] }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        guard let bitmap = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [] }
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let rows = (0..<height).map { y in (0..<width).map { x in pixels[y * width + x] < 128 } }
        // Core Image leaves its own margin: trimmed, so the margin drawn is the one chosen.
        guard let top = rows.firstIndex(where: { $0.contains(true) }),
              let bottom = rows.lastIndex(where: { $0.contains(true) }),
              let left = (0..<width).first(where: { x in rows.contains { $0[x] } }),
              let right = (0..<width).last(where: { x in rows.contains { $0[x] } })
        else { return [] }
        return rows[top...bottom].map { Array($0[left...right]) }
    }

    /// Squares of margin on every side: two is enough for a phone's camera, and leaves the
    /// squares larger than the standard four would.
    static let margin = 2

    /// The code on a white rounded square, `side` points across, at `scale` pixels a point.
    static func image(for invite: SharePlayInvite, side: CGFloat, scale: CGFloat, cornerRadius: CGFloat = 0) -> UIImage {
        let modules = modules(for: invite)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { renderer in
            let context = renderer.cgContext
            let bounds = CGRect(x: 0, y: 0, width: side, height: side)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius).fill()
            guard !modules.isEmpty else { return }
            // As large as the square allows, each edge on a whole pixel, so every square is
            // sharp: some a pixel wider than others, which a camera doesn't mind. Whole
            // squares of equal size would leave a small code swimming in white on a car's
            // screen, where a square is only three or four pixels across.
            let count = CGFloat(modules.count + margin * 2)
            let module = side / count
            let origin = module * CGFloat(margin)
            let snap = { (value: CGFloat) in (value * scale).rounded() / scale }
            context.setShouldAntialias(false)
            UIColor.black.setFill()
            for (row, squares) in modules.enumerated() {
                let top = snap(origin + CGFloat(row) * module)
                let bottom = snap(origin + CGFloat(row + 1) * module)
                for (column, isDark) in squares.enumerated() where isDark {
                    let left = snap(origin + CGFloat(column) * module)
                    let right = snap(origin + CGFloat(column + 1) * module)
                    context.fill(CGRect(x: left, y: top, width: right - left, height: bottom - top))
                }
            }
        }
    }
}
