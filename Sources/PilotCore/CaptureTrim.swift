import CoreGraphics
import Foundation

/// Smart selection's snap (Sven Q189): a rough area shrinks to its content by trimming the uniform
/// background round it. The background is the colour most of the area's four corners share; each side moves in while
/// its whole line is that colour, within a small tolerance for anti-aliasing. Only the area's own pixels are copied, in
/// one draw, so a 5K frame costs one blit of the area and a scan of the margins.
public enum CaptureTrim {
    /// `rect` in `image`'s pixels (top left, y down) trimmed to its content; `rect` itself when it has no shared corner
    /// colour or is all background.
    public static func trim(_ image: CGImage, pixels rect: CGRect, tolerance: Int = 12) -> CGRect {
        let rect = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let w = Int(rect.width), h = Int(rect.height)
        guard w > 2, h > 2, let cut = image.cropping(to: rect) else { return rect }
        // The still's own colour space, so the draw is a copy and not a conversion.
        let space = cut.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = ctx.data else { return rect }
        ctx.interpolationQuality = .none
        ctx.draw(cut, in: CGRect(x: 0, y: 0, width: w, height: h))
        let row = ctx.bytesPerRow / 4
        let px = data.bindMemory(to: UInt32.self, capacity: row * h)

        func near(_ a: UInt32, _ b: UInt32) -> Bool {
            if a == b { return true }
            for shift in stride(from: 0, to: 32, by: 8) where abs(Int((a >> shift) & 0xFF) - Int((b >> shift) & 0xFF)) > tolerance {
                return false
            }
            return true
        }
        let corners = [px[0], px[w - 1], px[(h - 1) * row], px[(h - 1) * row + w - 1]]
        guard let bg = corners.first(where: { c in corners.filter { near($0, c) }.count >= 2 }) else { return rect }

        // Rows first, a whole row compared at once when it is exactly the background; then, inside the rows left,
        // each row's margins from both ends, so only the margins are ever read pixel by pixel.
        let plain = [UInt32](repeating: bg, count: w)
        func rowIsBackground(_ y: Int) -> Bool {
            let base = px + y * row
            if memcmp(base, plain, w * 4) == 0 { return true }
            var x = 0
            while x < w, near(base[x], bg) { x += 1 }
            return x == w
        }
        var top = 0, bottom = h - 1
        while top <= bottom, rowIsBackground(top) { top += 1 }
        guard top <= bottom else { return rect }
        while rowIsBackground(bottom) { bottom -= 1 }
        var left = w, right = -1
        for y in top...bottom {
            let base = px + y * row
            var x = 0
            while x < left, near(base[x], bg) { x += 1 }
            left = x
            var r = w - 1
            while r > right, near(base[r], bg) { r -= 1 }
            right = r
        }
        return CGRect(x: rect.minX + CGFloat(left), y: rect.minY + CGFloat(top), width: CGFloat(right - left + 1), height: CGFloat(bottom - top + 1))
    }
}
