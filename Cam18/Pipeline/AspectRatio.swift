import CoreGraphics

/// The shape a photo is cropped to. The crop is centered and follows how the
/// phone is held: 16:9 on a portrait photo gives a 9:16 result.
enum AspectRatio: String, Codable, CaseIterable, Identifiable, Sendable {
    /// No crop. The camera's native shape, which is 4:3.
    case full
    case r16x9 = "16:9"
    case r3x2 = "3:2"
    case square = "1:1"

    var id: String { rawValue }

    /// Label used in the camera, where "no crop" means the sensor's 4:3.
    var label: String { self == .full ? "4:3" : rawValue }

    /// Long side divided by short side, or nil for no crop.
    var ratio: Double? {
        switch self {
        case .full: nil
        case .r16x9: 16.0 / 9.0
        case .r3x2: 3.0 / 2.0
        case .square: 1.0
        }
    }

    /// The largest centered rect of this shape inside `extent`, on whole
    /// pixels. Returns `extent` itself when it already has this shape (within
    /// a pixel), so cropping twice changes nothing.
    func cropRect(in extent: CGRect) -> CGRect {
        guard let ratio, !extent.isInfinite, extent.width >= 2, extent.height >= 2 else { return extent }
        let w = Double(extent.width), h = Double(extent.height)
        let target = w >= h ? ratio : 1 / ratio
        var newW = w, newH = h
        if w / h > target {
            newW = (h * target).rounded()
        } else {
            newH = (w / target).rounded()
        }
        if w - newW < 1.5, h - newH < 1.5 { return extent }
        let x = ((w - newW) / 2).rounded(.down)
        let y = ((h - newH) / 2).rounded(.down)
        return CGRect(x: Double(extent.minX) + x, y: Double(extent.minY) + y, width: newW, height: newH)
    }
}
