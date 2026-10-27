import Foundation
import AppKit
import CoreImage
import Vision

/// One detected text region on the page. `rect` is in normalized image
/// coordinates with the origin at the *top-left* (0,0 = top-left,
/// 1,1 = bottom-right), so callers can scale it straight onto whatever
/// frame the page is being rendered at.
struct OCRBox: Hashable {
    let text: String
    let rect: CGRect            // top-left origin, normalized 0…1
    let confidence: Float
}

/// Wraps Vision's `VNRecognizeTextRequest` so the rest of the app doesn't
/// have to deal with Vision's bottom-left-origin coordinates or its
/// async/observer style. Results are returned with top-left origin.
@MainActor
final class OCRService {
    static let shared = OCRService()

    /// Cache OCR results per (image identity, recognition language) so
    /// flipping the translate toggle off and back on doesn't re-run Vision.
    /// NSCache uses NSImage identity (pointer) as the key — works because
    /// the ZoomablePageView reuses NSImage instances from the model cache.
    private let cache = NSCache<CacheKey, NSArray>()

    private final class CacheKey: NSObject {
        let imageID: ObjectIdentifier
        let language: String

        init(image: NSImage, language: String) {
            self.imageID = ObjectIdentifier(image)
            self.language = language
        }

        override var hash: Int {
            var h = Hasher()
            h.combine(imageID)
            h.combine(language)
            return h.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let o = object as? CacheKey else { return false }
            return o.imageID == imageID && o.language == language
        }
    }

    func recognize(in image: NSImage,
                   recognitionLanguage: String?) async -> [OCRBox] {
        let langKey = recognitionLanguage ?? "auto"
        let key = CacheKey(image: image, language: langKey)
        if let cached = cache.object(forKey: key) as? [OCRBox] {
            return cached
        }

        // Phase 1: Vision's VNRecognizeTextRequest, with the 90°-CCW
        // rotated pass for vertical CJK. Fast and gives precise per-line
        // bounding boxes for any text Vision can actually read.
        let visionResult = await Task.detached(priority: .userInitiated) {
            OCRService.recognizeAllOrientations(in: image,
                                                 recognitionLanguage: recognitionLanguage)
        }.value

        if visionResult.count >= 2 || !OCRService.shouldRunLiveTextFallback(for: recognitionLanguage) {
            cache.setObject(visionResult as NSArray, forKey: key)
            return visionResult
        }

        // Phase 2: Vision found 0 or 1 observation despite the source
        // language being CJK / Auto. That's almost always Apple's text
        // recogniser bailing on a stylised manga font. Fall back to
        // VisionKit's ImageAnalyzer (Live Text), which reads those
        // fonts reliably. Live Text only exposes a flat transcript so
        // we recover per-bubble regions by detecting bubble-shaped
        // text-dense blobs up-front, then running Live Text on each
        // crop individually.
        let liveTextResult = await runLiveTextFallback(on: image)
        // Prefer whichever pass returned more observations. Vision
        // sometimes produces 1 high-confidence read (e.g. an English
        // sound effect inside an otherwise Chinese page) that the
        // Live Text fallback might miss.
        let merged = liveTextResult.count >= visionResult.count
            ? liveTextResult
            : visionResult
        cache.setObject(merged as NSArray, forKey: key)
        return merged
    }

    /// Live Text is expensive (one ImageAnalyzer call per detected
    /// bubble), so only run it for languages where Vision is known to
    /// have a stylised-font blind spot. Latin scripts on regular comic
    /// captions don't need it.
    nonisolated private static func shouldRunLiveTextFallback(for language: String?) -> Bool {
        guard let language = language?.lowercased() else { return true }
        return language.hasPrefix("ja") || language.hasPrefix("zh") || language.hasPrefix("ko")
    }

    /// Detect candidate bubble rectangles and OCR each one with Live
    /// Text. Returns one `OCRBox` per region that actually contained
    /// readable text. The boxes use the detected bubble's normalised
    /// bounding box; multi-line transcripts inside a bubble are joined
    /// with a space so the existing cluster pipeline treats each bubble
    /// as a single translation unit.
    private func runLiveTextFallback(on image: NSImage) async -> [OCRBox] {
        guard let cgImage = image.cgImage(forProposedRect: nil,
                                           context: nil,
                                           hints: nil) else { return [] }
        let regions = BubbleDetector.detect(in: cgImage)
        guard !regions.isEmpty else { return [] }

        var results: [OCRBox] = []
        results.reserveCapacity(regions.count)
        let recogniser = LiveTextOCR.shared
        for rect in regions {
            guard let transcript = await recogniser.recognize(in: cgImage, rect: rect) else { continue }
            let joined = transcript
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard joined.count >= 2 else { continue }
            results.append(OCRBox(text: joined, rect: rect, confidence: 1.0))
        }
        return results
    }

    /// Drop the cached OCR results. Bound to the Clear Cache button in
    /// the translate settings popover — also covers the case where the
    /// user wants Vision to retry a page after switching language hints.
    func clearCache() {
        cache.removeAllObjects()
        transcriptCache.removeAllObjects()
    }

    /// Cache for `recognizeFullPageTranscript`. Keyed by NSImage identity
    /// alone since Live Text is language-agnostic.
    private let transcriptCache = NSCache<NSObject, NSString>()

    /// Full-page transcript via VisionKit's `ImageAnalyzer` (Live Text).
    /// Reads stylised manga fonts that VNRecognizeTextRequest can't
    /// handle. Returns the raw transcript split into non-empty lines,
    /// preserving the order Live Text reports them in.
    ///
    /// Live Text doesn't expose per-line bounding boxes, so callers
    /// can't use the result for on-image hover overlays — surface it in
    /// a side panel instead. Cached per-NSImage so flipping translate
    /// mode off/on doesn't re-run the model.
    func recognizeFullPageTranscript(in image: NSImage) async -> [String] {
        let key = image as NSObject
        if let cached = transcriptCache.object(forKey: key) {
            let lines = (cached as String)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            return lines
        }
        guard let cgImage = image.cgImage(forProposedRect: nil,
                                           context: nil,
                                           hints: nil) else { return [] }
        guard let transcript = await LiveTextOCR.shared.recognize(in: cgImage) else { return [] }
        transcriptCache.setObject(transcript as NSString, forKey: key)
        return transcript
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 1 }
    }

    /// Two-pass OCR for CJK languages. Vision's current text-recognition
    /// revision claims vertical-script support, but on real manga pages
    /// it routinely returns zero observations for tategaki bubbles — the
    /// internal layout pass classifies a tall narrow column as "not a
    /// line" and never reads it. The workaround that actually works in
    /// practice is to rotate the page 90° CCW so each vertical column
    /// becomes an ordinary horizontal line, OCR that, then transform the
    /// observation rects back into original-image coordinates. We merge
    /// with the upright pass (dropping rects that already overlap an
    /// upright observation) so a single page with mixed vertical bubbles
    /// and horizontal sound-effects gets both read.
    nonisolated private static func recognizeAllOrientations(in image: NSImage,
                                                              recognitionLanguage: String?) -> [OCRBox] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }
        let upright = runVision(on: cgImage, recognitionLanguage: recognitionLanguage)

        guard shouldRunRotatedPass(for: recognitionLanguage) else { return upright }
        guard let rotated = rotated90CCW(cgImage) else { return upright }

        let rotatedResults = runVision(on: rotated, recognitionLanguage: recognitionLanguage)
        let unrotated = rotatedResults.map { box -> OCRBox in
            // Inverse of the 90°-CCW rotation in normalized top-left-origin
            // space: original = (1 - ry - rh, rx, rh, rw).
            let r = box.rect
            let mapped = CGRect(
                x: 1.0 - r.minY - r.height,
                y: r.minX,
                width: r.height,
                height: r.width
            )
            return OCRBox(text: box.text, rect: mapped, confidence: box.confidence)
        }
        return mergeDeduplicating(upright: upright, rotated: unrotated)
    }

    /// Synchronous Vision invocation against a CGImage. Runs on a
    /// detached task in `recognize(...)` so the main actor stays free
    /// during OCR. Marked `nonisolated` so it can be called from a
    /// background context.
    nonisolated private static func runVision(on cgImage: CGImage,
                                               recognitionLanguage: String?) -> [OCRBox] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Pin to Vision's newest text-recognition revision; only that
        // revision ships the Japanese/Chinese models that can read
        // vertical (top-to-bottom) text — older revisions return zero
        // observations for tategaki manga.
        request.revision = VNRecognizeTextRequest.currentRevision
        if let lang = recognitionLanguage {
            // For a hint that already includes a CJK script, also list the
            // sibling scripts so Vision picks the right vertical model
            // even when, say, the user set "Chinese (Simplified)" but the
            // page has a kanji loanword. English tags along as a fallback
            // for embedded sound effects.
            request.recognitionLanguages = expandCJKLanguageHint(lang)
            request.automaticallyDetectsLanguage = false
        } else {
            // "Auto" mode: Vision's automaticallyDetectsLanguage doesn't
            // turn on vertical-script support, it just guesses one
            // language for the whole image. Explicitly enumerate the
            // common comic/manga source scripts so vertical Japanese,
            // Chinese (both scripts) and Korean all get a model.
            request.recognitionLanguages = [
                "ja-JP", "zh-Hans", "zh-Hant", "ko-KR", "en-US",
            ]
            request.automaticallyDetectsLanguage = false
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let observations = request.results else { return [] }

        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            // Vision returns rects in bottom-left-origin normalized coords;
            // flip Y so callers can use top-left origin consistently.
            let visionRect = observation.boundingBox
            let topLeftRect = CGRect(
                x: visionRect.origin.x,
                y: 1.0 - visionRect.origin.y - visionRect.height,
                width: visionRect.width,
                height: visionRect.height
            )
            return OCRBox(text: candidate.string,
                          rect: topLeftRect,
                          confidence: candidate.confidence)
        }
        // Vision returns one observation per *line* by default. For dense
        // speech bubbles that's usually right — each bubble is its own bubble.
    }

    /// Rotate the rotated pass on for CJK / Auto modes only. For Latin /
    /// Cyrillic / Arabic etc. a rotated pass would just double the OCR
    /// cost without finding any new text — those scripts never read
    /// top-to-bottom.
    nonisolated private static func shouldRunRotatedPass(for language: String?) -> Bool {
        guard let language = language?.lowercased() else { return true }
        return language.hasPrefix("ja") || language.hasPrefix("zh") || language.hasPrefix("ko")
    }

    /// Bitmap-rotate a CGImage 90° counter-clockwise. We feed the rotated
    /// copy through Vision so vertical CJK columns become ordinary
    /// horizontal lines: the topmost character of a column ends up at the
    /// leftmost end of a row, which Vision handles reliably even when its
    /// vertical-text path fails. The caller transforms the returned boxes
    /// back into the original image's coordinate space.
    ///
    /// The destination context is hard-coded to device RGB + premultiplied
    /// alpha. Inheriting the source CGImage's colorSpace (the obvious
    /// thing to do) silently broke for monochrome manga: a grayscale
    /// source + 4-channel `premultipliedLast` alpha is an unsupported
    /// CGContext combination, so `CGContext.init` returns nil and the
    /// rotated pass quietly degrades to no-op. Quartz handles
    /// grayscale → RGB on draw automatically, so forcing RGB always works
    /// regardless of the source pixel format.
    nonisolated private static func rotated90CCW(_ cgImage: CGImage) -> CGImage? {
        let w = cgImage.width
        let h = cgImage.height
        let newWidth = h
        let newHeight = w
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        if let ctx = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) {
            ctx.interpolationQuality = .high
            // CG's coordinate origin is bottom-left. translate(h, 0) then
            // rotate(+π/2) draws the source so its visual top edge lands on
            // the rotated canvas's visual left edge — a 90° CCW rotation
            // when the image is viewed top-left-origin.
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: .pi / 2)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let rotated = ctx.makeImage() { return rotated }
        }
        // Fallback: Core Image. Slower per-call but tolerates any source
        // pixel format Quartz can't synthesise a context for.
        let ci = CIImage(cgImage: cgImage)
        let rotated = ci.transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
        let normalized = rotated.transformed(by: CGAffineTransform(
            translationX: -rotated.extent.minX,
            y: -rotated.extent.minY
        ))
        return CIContext().createCGImage(normalized, from: normalized.extent)
    }

    /// Merge the upright and rotated OCR passes, dropping any rotated
    /// observation whose rect already overlaps an upright observation by
    /// more than ~40 % IoU. The upright version wins because its bounding
    /// box is naturally aligned to the page and feeds the cluster
    /// algorithm without surprises.
    nonisolated private static func mergeDeduplicating(upright: [OCRBox],
                                                        rotated: [OCRBox]) -> [OCRBox] {
        var merged = upright
        for r in rotated {
            let isDup = upright.contains { u in iou(u.rect, r.rect) > 0.4 }
            if !isDup { merged.append(r) }
        }
        return merged
    }

    nonisolated private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }

    /// When the user picks a CJK source language, also enable the related
    /// scripts so Vision still recognises stray kanji / hanzi / hangul that
    /// the page mixes in. English tags along as a fallback for inline
    /// sound effects rendered with the Latin alphabet.
    nonisolated private static func expandCJKLanguageHint(_ lang: String) -> [String] {
        let normalized = lang.lowercased()
        if normalized.hasPrefix("ja") {
            return ["ja-JP", "zh-Hans", "zh-Hant", "en-US"]
        }
        if normalized.hasPrefix("zh") {
            // Keep the requested Chinese variant first so Vision prefers it,
            // then include the other plus Japanese kanji + English.
            let other = normalized.contains("hant") || normalized.contains("tw")
                ? "zh-Hans" : "zh-Hant"
            return [lang, other, "ja-JP", "en-US"]
        }
        if normalized.hasPrefix("ko") {
            return ["ko-KR", "ja-JP", "zh-Hans", "en-US"]
        }
        return [lang]
    }
}

extension OCRBox {
    /// Convert this box's normalized rect into a CGRect inside a view of
    /// `size` pixels, optionally with image content scaled by `contentScale`
    /// (e.g. the magnification of an NSScrollView).
    func frameInView(imageSize: CGSize,
                     displaySize: CGSize) -> CGRect {
        // The image is drawn aspectFit-style into displaySize, so figure out
        // the visible image rect first and lay the normalized box inside it.
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(displaySize.width / imageSize.width,
                        displaySize.height / imageSize.height)
        let scaledW = imageSize.width  * scale
        let scaledH = imageSize.height * scale
        let offX = (displaySize.width  - scaledW) / 2
        let offY = (displaySize.height - scaledH) / 2
        return CGRect(
            x: offX + rect.origin.x * scaledW,
            y: offY + rect.origin.y * scaledH,
            width:  rect.width  * scaledW,
            height: rect.height * scaledH
        )
    }
}

/// A spatial cluster of OCR boxes that probably belong to the same speech
/// bubble / caption / sign. Translating a whole cluster at once gives the
/// engine the full sentence as context, instead of one line at a time.
struct OCRCluster: Hashable {
    let boxes: [OCRBox]
    let rect: CGRect           // top-left-origin, normalized 0…1 — bounding box of all members
    let text: String           // member texts joined in reading order

    func frameInView(imageSize: CGSize, displaySize: CGSize) -> CGRect {
        OCRBox(text: text, rect: rect, confidence: 1).frameInView(
            imageSize: imageSize,
            displaySize: displaySize
        )
    }
}

extension OCRService {
    /// Group line-level OCR observations into per-bubble clusters by
    /// proximity. Two boxes join the same cluster when:
    ///
    /// - they're stacked vertically with a gap of less than ~1.5× the
    ///   average box height AND their horizontal extents overlap
    ///   substantially (typical for multi-line speech bubbles where each
    ///   line is left-aligned under the previous one), or
    /// - they're on the same baseline AND separated by less than a single
    ///   space-width gap (Vision occasionally splits one line into two
    ///   observations across a panel border or wide letter spacing).
    ///
    /// The horizontal-merge rule is intentionally tight: two text blocks
    /// printed side-by-side inside the same bubble (e.g. a translated
    /// page with two stacked sentences arranged as columns) have a
    /// visible gap of at least one character-width between them. That
    /// gap exceeds the threshold below, so the columns stay as separate
    /// clusters and get translated as two distinct sentences.
    ///
    /// Inside each cluster, member boxes are sorted into reading order
    /// (top-to-bottom, then left-to-right) and joined with single spaces
    /// for the translator. The cluster's `rect` is the union of all
    /// member rects so the overlay can draw one hit-zone per bubble
    /// instead of one per line.
    nonisolated static func cluster(_ boxes: [OCRBox]) -> [OCRCluster] {
        guard !boxes.isEmpty else { return [] }

        let avgHeight = boxes.map(\.rect.height).reduce(0, +) / CGFloat(boxes.count)
        let vGapTolerance = avgHeight * 1.5
        // ~one space-width — tight enough that two distinct text columns in
        // the same bubble (separated by a character-width gap) stay split.
        let hGapTolerance = avgHeight * 0.35

        // Union-find over the box indices.
        var parent = Array(0..<boxes.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        for i in 0..<boxes.count {
            for j in (i + 1)..<boxes.count {
                let r1 = boxes[i].rect, r2 = boxes[j].rect
                // Edge-to-edge gap on each axis (negative = overlap).
                let hGap = max(r1.minX - r2.maxX, r2.minX - r1.maxX)
                let vGap = max(r1.minY - r2.maxY, r2.minY - r1.maxY)
                // Overlap extent on the OTHER axis (positive = they share that span).
                let hOverlap = min(r1.maxX, r2.maxX) - max(r1.minX, r2.minX)
                let vOverlap = min(r1.maxY, r2.maxY) - max(r1.minY, r2.minY)
                let smallerHeight = min(r1.height, r2.height)
                let smallerWidth  = min(r1.width,  r2.width)

                // Vertical stacking: the two boxes need a real horizontal
                // overlap relative to their own widths — not just any
                // overlap, since adjacent columns might overlap by a single
                // pixel and that shouldn't merge them.
                let verticallyStacked =
                    vGap <= vGapTolerance &&
                    hOverlap > smallerWidth * 0.3

                // Horizontal "same line" merge: the two boxes must share
                // most of their vertical extent (i.e. clearly the same
                // baseline) and sit a space's width apart at most.
                let sameLineSplit =
                    hGap <= hGapTolerance &&
                    vOverlap > smallerHeight * 0.7

                if verticallyStacked || sameLineSplit {
                    union(i, j)
                }
            }
        }

        var groupedIndices: [Int: [Int]] = [:]
        for i in 0..<boxes.count {
            groupedIndices[find(i), default: []].append(i)
        }

        return groupedIndices.values.map { indices in
            let members = indices.map { boxes[$0] }
            // A cluster is "vertical" when every observation is clearly
            // taller than it is wide — that's how Vision returns tategaki
            // manga / vertical Chinese, where each column becomes one
            // observation. Sort those columns right-to-left (top-to-bottom
            // within a column) instead of the default left-to-right
            // horizontal reading order.
            let isVertical = members.count > 1 && members.allSatisfy {
                $0.rect.height > $0.rect.width * 1.2
            }
            let sorted: [OCRBox]
            if isVertical {
                sorted = sortVerticalReadingOrder(members)
            } else {
                sorted = sortInReadingOrder(members, avgHeight: avgHeight)
            }
            let combinedText = sorted.map(\.text)
                .joined(separator: " ")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let minX = sorted.map(\.rect.minX).min() ?? 0
            let minY = sorted.map(\.rect.minY).min() ?? 0
            let maxX = sorted.map(\.rect.maxX).max() ?? 0
            let maxY = sorted.map(\.rect.maxY).max() ?? 0

            return OCRCluster(
                boxes: sorted,
                rect: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                text: combinedText
            )
        }
        // Stable order so tooltips don't shuffle between renders.
        .sorted { lhs, rhs in
            if abs(lhs.rect.minY - rhs.rect.minY) > 0.01 {
                return lhs.rect.minY < rhs.rect.minY
            }
            return lhs.rect.minX < rhs.rect.minX
        }
    }

    /// Sort boxes top-to-bottom, then left-to-right. Boxes whose vertical
    /// midpoints fall within half a line height of each other are
    /// considered the same "row" for the secondary left-to-right sort.
    nonisolated private static func sortInReadingOrder(_ boxes: [OCRBox],
                                                        avgHeight: CGFloat) -> [OCRBox] {
        boxes.sorted { a, b in
            let aMid = a.rect.midY
            let bMid = b.rect.midY
            if abs(aMid - bMid) <= avgHeight * 0.5 {
                return a.rect.minX < b.rect.minX
            }
            return aMid < bMid
        }
    }

    /// Sort vertical-script columns into reading order: right-to-left
    /// between columns, top-to-bottom within a column. Vision already
    /// returns each column's characters in the correct (top-to-bottom)
    /// order inside its `string`, so we only need to order the columns
    /// themselves. Two boxes count as the "same column" when their
    /// midpoint X's are within half the narrower column's width.
    nonisolated private static func sortVerticalReadingOrder(_ boxes: [OCRBox]) -> [OCRBox] {
        boxes.sorted { a, b in
            let columnTolerance = min(a.rect.width, b.rect.width) * 0.5
            if abs(a.rect.midX - b.rect.midX) > columnTolerance {
                // Different columns — right column reads first.
                return a.rect.midX > b.rect.midX
            }
            // Same column — top reads first.
            return a.rect.minY < b.rect.minY
        }
    }
}
