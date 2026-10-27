import Foundation
import AppKit
import CoreGraphics
import CoreImage

/// Heuristic detector for speech-bubble / caption regions on a comic page.
///
/// We need this because `VNRecognizeTextRequest` flat-out can't read the
/// stylised fonts used in most manga (verified for both Japanese and
/// Chinese; see `OCRDiagnostic`). VisionKit's `ImageAnalyzer` (the engine
/// that powers Live Text) can read them perfectly, but it only exposes a
/// flat transcript — no per-line bounding boxes. To keep the per-bubble
/// hover UX in translate mode we need to feed `ImageAnalyzer` cropped
/// regions one at a time, and that requires knowing where the bubbles
/// are up-front.
///
/// Pipeline:
///   1. Downscale the page to a working resolution (default 600 px on the
///      longest side) so the connected-components pass stays cheap.
///   2. Convert to grayscale.
///   3. Threshold for "light" pixels — bubble interiors are distinctly
///      lighter than panel backgrounds (cream/white vs gray) in most
///      manga.
///   4. **Dilate the light mask** several times to close over the dark
///      text strokes inside each bubble. Without this step, each glyph
///      carves a hole in the interior and the flood-fill returns dozens
///      of tiny components that all get rejected by the area filter.
///   5. 4-connected flood-fill to label connected light components.
///   6. Filter by area + aspect ratio.
///   7. Pad each surviving bbox slightly so Live Text gets a margin.
///
/// Output: normalised, top-left-origin rectangles in 0…1 image
/// coordinates. Each rectangle is a *candidate* — the caller still has
/// to run Live Text on it to confirm there's real text, since the same
/// signal triggers on light-coloured art (skin tones, sky, etc.).
enum BubbleDetector {
    /// Toggle to true while tuning the detector — emits the intermediate
    /// grayscale + binary mask to /tmp on each call so a human can pick
    /// thresholds. Ship as `false`; the file I/O is real work.
    static var isDebugBuildEnabled: Bool = false

    /// Tunables. Visible at file scope so the diagnostic CLI can sweep
    /// them without round-tripping through compile cycles when we tune.
    struct Parameters {
        /// Longest-edge target after downscale. 600 px is enough to
        /// resolve bubble boundaries while keeping the connected-components
        /// pass cheap (~360k pixels worst case).
        var workingDimension: Int = 600
        /// Pixels at or above this brightness (0…255) count as "light" —
        /// i.e. candidate bubble interior. 215 is high enough to reject
        /// the gray panel backgrounds in most manga but low enough to
        /// keep cream-tinted bubbles.
        var lightThreshold: UInt8 = 215
        /// Number of dilation passes applied to the light mask before
        /// flood-fill. Each pass grows the mask by one pixel in 4
        /// directions, closing thin dark strokes (text characters, panel
        /// borders) so the bubble interior stays a single component.
        /// 4 passes ≈ ~4 px growth at the default working resolution.
        var closeIterations: Int = 4
        /// Minimum area, as a fraction of working area. 0.3 % filters
        /// specks; small captions are typically ~0.5 %.
        var minAreaFraction: CGFloat = 0.003
        /// Maximum area. The page outside the panels is also "light"
        /// and merges into one large component; this filter drops it.
        /// 15 % is generous for bubbles + captions but rejects "the
        /// whole page background became one blob" failures.
        var maxAreaFraction: CGFloat = 0.15
        /// Maximum width:height (or height:width) ratio. A 12:1 strip
        /// is either a panel border that survived merging or a row of
        /// running text; tightens up the candidate set.
        var maxAspectRatio: CGFloat = 12
        /// Padding around each detected region (fraction of its longer
        /// edge) when emitting the final rectangle. Live Text reads
        /// better with a little margin around the text.
        var paddingFraction: CGFloat = 0.08
        /// Pixels below this brightness count as "dark" when measuring
        /// text density inside a candidate region.
        var darkThreshold: UInt8 = 110
        /// A candidate region's bounding box must have at least this
        /// fraction of dark pixels (in the original grayscale, not the
        /// dilated mask) — otherwise it's likely a character's shirt or
        /// skin, not a text-bearing bubble. 3 % is the empirical floor
        /// below which a region is uniform light artwork.
        var minDarkFraction: CGFloat = 0.03
        /// Upper bound on dark fraction. A region that's >40 % dark is a
        /// shaded character or solid art panel, not a speech bubble.
        var maxDarkFraction: CGFloat = 0.45
    }

    /// Find candidate text-bubble regions. Returns rectangles in
    /// normalised image coordinates (top-left origin, 0…1).
    static func detect(in cgImage: CGImage,
                       parameters: Parameters = Parameters()) -> [CGRect] {
        guard let intermediates = makeBinaryMask(cgImage: cgImage,
                                                   parameters: parameters) else { return [] }
        let mask = intermediates.mask
        let gray = intermediates.gray
        let components = findConnectedComponents(mask: mask,
                                                   width: intermediates.width,
                                                   height: intermediates.height)
        let totalArea = intermediates.width * intermediates.height
        let minArea = Int(CGFloat(totalArea) * parameters.minAreaFraction)
        let maxArea = Int(CGFloat(totalArea) * parameters.maxAreaFraction)
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        let rects: [CGRect] = components.compactMap { c -> CGRect? in
            guard c.area >= minArea, c.area <= maxArea else { return nil }
            let w = c.maxX - c.minX + 1
            let h = c.maxY - c.minY + 1
            let ratio = CGFloat(max(w, h)) / CGFloat(max(min(w, h), 1))
            guard ratio <= parameters.maxAspectRatio else { return nil }

            // Text-density check: count dark pixels in the original
            // grayscale buffer (before dilation closed them over) within
            // the candidate's bbox. Bubbles average 5–25 % dark area;
            // shirts and skin are under 1 %; shaded characters / solid
            // art are well above 45 %.
            var darkCount = 0
            let bboxArea = w * h
            for yy in c.minY...c.maxY {
                let row = yy * intermediates.width
                for xx in c.minX...c.maxX {
                    if gray[row + xx] < parameters.darkThreshold {
                        darkCount += 1
                    }
                }
            }
            let darkFraction = CGFloat(darkCount) / CGFloat(max(1, bboxArea))
            guard darkFraction >= parameters.minDarkFraction,
                  darkFraction <= parameters.maxDarkFraction else { return nil }

            // Working-resolution bbox → original-resolution normalised bbox.
            let scaleX = imgW / CGFloat(intermediates.width)
            let scaleY = imgH / CGFloat(intermediates.height)
            var px = CGFloat(c.minX) * scaleX
            var py = CGFloat(c.minY) * scaleY
            var pw = CGFloat(w) * scaleX
            var ph = CGFloat(h) * scaleY

            // Padding so Live Text gets a margin around the text. The
            // pad is symmetric and clamped to the image bounds.
            let pad = max(pw, ph) * parameters.paddingFraction
            px = max(0, px - pad)
            py = max(0, py - pad)
            pw = min(imgW - px, pw + 2 * pad)
            ph = min(imgH - py, ph + 2 * pad)

            return CGRect(x: px / imgW,
                          y: py / imgH,
                          width: pw / imgW,
                          height: ph / imgH)
        }
        // Sort top-to-bottom, then left-to-right so downstream rendering
        // sees a stable order frame-to-frame.
        return rects.sorted { lhs, rhs in
            if abs(lhs.minY - rhs.minY) > 0.02 {
                return lhs.minY < rhs.minY
            }
            return lhs.minX < rhs.minX
        }
    }

    // MARK: - Binary mask

    private static func makeBinaryMask(cgImage: CGImage,
                                        parameters: Parameters) -> (mask: [UInt8], gray: [UInt8], width: Int, height: Int)? {
        let longest = max(cgImage.width, cgImage.height)
        let scale = min(1.0, CGFloat(parameters.workingDimension) / CGFloat(longest))
        let w = max(2, Int(CGFloat(cgImage.width) * scale))
        let h = max(2, Int(CGFloat(cgImage.height) * scale))

        // Downscale into a grayscale buffer we can iterate directly.
        let grayColorSpace = CGColorSpaceCreateDeviceGray()
        var grayBytes = [UInt8](repeating: 0, count: w * h)
        guard let ctx = grayBytes.withUnsafeMutableBytes({ ptr -> CGContext? in
            guard let base = ptr.baseAddress else { return nil }
            return CGContext(data: base,
                              width: w, height: h,
                              bitsPerComponent: 8,
                              bytesPerRow: w,
                              space: grayColorSpace,
                              bitmapInfo: CGImageAlphaInfo.none.rawValue)
        }) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Light-pixel mask.
        let cutoff = parameters.lightThreshold
        var mask = [UInt8](repeating: 0, count: w * h)
        for i in 0..<grayBytes.count {
            mask[i] = grayBytes[i] >= cutoff ? 1 : 0
        }

        // Morphological dilation — close gaps left by text strokes and
        // panel borders inside the bubble. Two buffers and a swap keep
        // allocations down.
        var work = mask
        var tmp = [UInt8](repeating: 0, count: w * h)
        for _ in 0..<parameters.closeIterations {
            for y in 0..<h {
                let row = y * w
                for x in 0..<w {
                    let idx = row + x
                    if work[idx] == 1 {
                        tmp[idx] = 1
                        continue
                    }
                    let up    = y > 0       ? work[idx - w] : 0
                    let down  = y < h - 1   ? work[idx + w] : 0
                    let left  = x > 0       ? work[idx - 1] : 0
                    let right = x < w - 1   ? work[idx + 1] : 0
                    tmp[idx] = (up | down | left | right)
                }
            }
            swap(&work, &tmp)
            for i in 0..<tmp.count { tmp[i] = 0 }
        }

        if isDebugBuildEnabled {
            saveGrayBuffer(grayBytes, w: w, h: h, to: "/tmp/bookworm-bubble-gray.png")
            let visible = work.map { $0 == 1 ? UInt8(255) : UInt8(0) }
            saveGrayBuffer(visible, w: w, h: h, to: "/tmp/bookworm-bubble-mask.png")
        }
        return (mask: work, gray: grayBytes, width: w, height: h)
    }

    private static func saveGrayBuffer(_ bytes: [UInt8], w: Int, h: Int, to path: String) {
        var bytes = bytes
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = bytes.withUnsafeMutableBytes({ ptr -> CGContext? in
            guard let base = ptr.baseAddress else { return nil }
            return CGContext(data: base,
                              width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: w,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.none.rawValue)
        }), let image = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image)
            .representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Connected components

    private struct Component {
        var minX, minY, maxX, maxY, area: Int
    }

    /// 4-connected flood-fill labelling using an iterative stack so we
    /// don't risk blowing the call stack on large blobs.
    private static func findConnectedComponents(mask: [UInt8],
                                                  width: Int,
                                                  height: Int) -> [Component] {
        var visited = [Bool](repeating: false, count: mask.count)
        var components: [Component] = []
        var stack: [(Int, Int)] = []
        stack.reserveCapacity(1024)

        for startY in 0..<height {
            for startX in 0..<width {
                let startIdx = startY * width + startX
                if visited[startIdx] || mask[startIdx] == 0 { continue }
                var comp = Component(minX: startX, minY: startY,
                                      maxX: startX, maxY: startY, area: 0)
                stack.removeAll(keepingCapacity: true)
                stack.append((startX, startY))
                while let (x, y) = stack.popLast() {
                    let idx = y * width + x
                    if visited[idx] || mask[idx] == 0 { continue }
                    visited[idx] = true
                    comp.area += 1
                    if x < comp.minX { comp.minX = x }
                    if x > comp.maxX { comp.maxX = x }
                    if y < comp.minY { comp.minY = y }
                    if y > comp.maxY { comp.maxY = y }
                    if x > 0 { stack.append((x - 1, y)) }
                    if x < width - 1 { stack.append((x + 1, y)) }
                    if y > 0 { stack.append((x, y - 1)) }
                    if y < height - 1 { stack.append((x, y + 1)) }
                }
                components.append(comp)
            }
        }
        return components
    }
}
