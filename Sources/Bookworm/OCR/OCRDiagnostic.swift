import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import VisionKit

/// CLI diagnostic for the translate-mode OCR pipeline. Invoked via
/// `swift run Bookworm --ocr-test <imagePath>`. Loads the image, runs
/// Vision OCR on both the upright and 90°-CCW-rotated copies with each
/// CJK language hint, and prints the observations. Used to confirm
/// whether the rotated pass is actually doing its job on a real page
/// before pinning down a translate-mode regression in the UI layer.
enum OCRDiagnostic {
    static func run(imagePath: String) {
        let url = URL(fileURLWithPath: (imagePath as NSString).expandingTildeInPath)
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("Couldn't load CGImage from \(url.path)")
            return
        }
        print("Loaded: \(cgImage.width)×\(cgImage.height) (colorSpace: \(cgImage.colorSpace?.name as? String ?? "nil"))")

        // What does Vision claim it can OCR? If zh-Hans isn't in the list
        // for the current revision, that's the whole story — no amount of
        // rotation will help.
        let rev = VNRecognizeTextRequest.currentRevision
        print("\nVision currentRevision: \(rev)")
        let accurateSupported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: .accurate, revision: rev
        )) ?? []
        let fastSupported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: .fast, revision: rev
        )) ?? []
        print("accurate supports: \(accurateSupported)")
        print("fast supports:     \(fastSupported)")

        // Save a copy of the CCW-rotated bitmap so we can eyeball it for
        // correctness. If Vision returns nothing but the rotation looks
        // wrong, that's where to start; if the rotation is correct but
        // Vision still returns nothing, the issue is upstream.
        if let rotated = rotated90CCW(cgImage) {
            let outURL = URL(fileURLWithPath: "/tmp/bookworm-ocr-rotated.png")
            saveCGImage(rotated, to: outURL)
            print("\nSaved rotated copy to \(outURL.path)")
        }

        let configs: [(label: String, configure: (VNRecognizeTextRequest) -> Void)] = [
            ("baseline (currentRevision, accurate, langCorr, zh-Hans+en)", { r in
                r.recognitionLanguages = ["zh-Hans", "en-US"]
                r.automaticallyDetectsLanguage = false
            }),
            ("baseline + minHeight=0.001", { r in
                r.recognitionLanguages = ["zh-Hans", "en-US"]
                r.automaticallyDetectsLanguage = false
                r.minimumTextHeight = 0.001
            }),
            ("no langCorrection, zh-Hans", { r in
                r.recognitionLanguages = ["zh-Hans"]
                r.usesLanguageCorrection = false
            }),
            ("automaticallyDetectsLanguage=true", { r in
                r.automaticallyDetectsLanguage = true
            }),
            ("revision3, all CJK languages", { r in
                r.recognitionLanguages = ["zh-Hans", "zh-Hant", "yue-Hans", "yue-Hant", "ja-JP", "ko-KR"]
                r.automaticallyDetectsLanguage = false
            }),
        ]

        // Run each config on upright + rotated + 2× upscaled + 2× upscaled-rotated.
        // The upscale variants test the hypothesis that Vision's layout
        // pass is dropping the bubbles because they're a small fraction
        // of total image area.
        let upscaled = upscale2x(cgImage)
        let rotated = rotated90CCW(cgImage)
        let rotatedUpscaled = upscaled.flatMap { rotated90CCW($0) }

        for (label, configure) in configs {
            print("\n========== \(label) ==========")
            print("  -- upright (\(cgImage.width)×\(cgImage.height))")
            dump(runVision(on: cgImage, configure: configure))
            if let r = rotated {
                print("  -- rotated 90° CCW (\(r.width)×\(r.height))")
                dump(runVision(on: r, configure: configure))
            }
            if let up = upscaled {
                print("  -- upright 2× (\(up.width)×\(up.height))")
                dump(runVision(on: up, configure: configure))
            }
            if let ru = rotatedUpscaled {
                print("  -- rotated 2× (\(ru.width)×\(ru.height))")
                dump(runVision(on: ru, configure: configure))
            }
        }

        // Contrast / binarisation pass. Manga bubbles are typically dark
        // text on cream — the layout pass may be classifying it as
        // illustration rather than text. Boosting contrast forces it
        // closer to pure black-on-white, which Vision is trained on.
        if let boosted = boostContrast(cgImage) {
            saveCGImage(boosted, to: URL(fileURLWithPath: "/tmp/bookworm-ocr-boosted.png"))
            print("\nSaved contrast-boosted copy to /tmp/bookworm-ocr-boosted.png")
            print("\n========== contrast-boosted, zh-Hans ==========")
            print("  -- upright (\(boosted.width)×\(boosted.height))")
            dump(runVision(on: boosted, configure: { r in
                r.recognitionLanguages = ["zh-Hans", "en-US"]
                r.automaticallyDetectsLanguage = false
            }))
            if let rb = rotated90CCW(boosted) {
                print("  -- rotated 90° CCW (\(rb.width)×\(rb.height))")
                dump(runVision(on: rb, configure: { r in
                    r.recognitionLanguages = ["zh-Hans", "en-US"]
                    r.automaticallyDetectsLanguage = false
                }))
            }
        }

        // VisionKit's ImageAnalyzer is the Live Text engine. It usually
        // outperforms VNRecognizeTextRequest on stylised real-world text
        // (manga bubbles, signs, hand-written labels), at the cost of
        // not giving us per-region bounding boxes — analysis.transcript
        // is just one big string. If this returns the Chinese text, we
        // know the device CAN OCR this page; we'd just need a more
        // expensive scheme to recover per-bubble regions.
        print("\n========== VisionKit ImageAnalyzer (Live Text) ==========")
        // ImageAnalyzer is @MainActor, so we can't block the main thread
        // with a semaphore (the analyze task would never get a chance to
        // run on main). Spin the main run loop until the async task
        // completes — that lets the @MainActor work make progress.
        let done = DiagnosticFlag()
        Task { @MainActor in
            let nsImage = NSImage(cgImage: cgImage,
                                   size: NSSize(width: cgImage.width, height: cgImage.height))
            let analyzer = ImageAnalyzer()
            let config = ImageAnalyzer.Configuration([.text])
            do {
                let analysis = try await analyzer.analyze(nsImage,
                                                            orientation: .up,
                                                            configuration: config)
                let transcript = analysis.transcript
                print("  transcript [\(transcript.count) chars]:")
                let lines = transcript.split(separator: "\n", omittingEmptySubsequences: true)
                for line in lines.prefix(40) {
                    print("    \(line)")
                }
                if lines.count > 40 { print("    …(\(lines.count - 40) more lines)") }
            } catch {
                print("  ImageAnalyzer failed: \(error.localizedDescription)")
            }
            done.value = true
        }
        let deadline = Date().addingTimeInterval(120)
        while !done.value, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if !done.value { print("  (timed out after 120 s)") }

        // Try VNDetectTextRectanglesRequest — Vision's older "find places
        // that look like text" detector. Doesn't run OCR, just layout.
        // May find regions on this manga where VNRecognizeTextRequest's
        // full pipeline rejects everything.
        print("\n========== VNDetectTextRectanglesRequest ==========")
        do {
            let req = VNDetectTextRectanglesRequest()
            req.reportCharacterBoxes = false
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([req])
            let observations = req.results ?? []
            print("  \(observations.count) regions")
            for obs in observations.prefix(40) {
                let v = obs.boundingBox
                let r = CGRect(x: v.origin.x,
                                y: 1 - v.origin.y - v.height,
                                width: v.width, height: v.height)
                let coords = String(format: "[%.3f, %.3f  %.3fx%.3f]",
                                    r.minX, r.minY, r.width, r.height)
                print("  \(coords) conf=\(String(format: "%.2f", obs.confidence))")
            }
        } catch {
            print("  detector failed: \(error)")
        }

        // End-to-end: bubble detector → Live Text per crop. This is the
        // pipeline OCRService now falls back to when Vision returns < 2
        // observations for a CJK source language. If the regions look
        // reasonable AND each region's transcript is correct, the
        // translate-mode overlay will show working per-bubble tooltips.
        print("\n========== BubbleDetector + LiveTextOCR (production pipeline) ==========")
        let regions = BubbleDetector.detect(in: cgImage)
        print("  detected \(regions.count) bubble candidates")
        // Render the regions onto a debug copy of the page so we can
        // eyeball whether the detector found the speech bubbles.
        if let debugImage = drawRegions(on: cgImage, regions: regions) {
            saveCGImage(debugImage, to: URL(fileURLWithPath: "/tmp/bookworm-ocr-bubbles.png"))
            print("  saved bubble-overlay debug PNG to /tmp/bookworm-ocr-bubbles.png")
        }
        let liveTextDone = DiagnosticFlag()
        Task { @MainActor in
            for (i, rect) in regions.enumerated() {
                let coords = String(format: "[%.3f, %.3f  %.3fx%.3f]",
                                    rect.minX, rect.minY, rect.width, rect.height)
                if let text = await LiveTextOCR.shared.recognize(in: cgImage, rect: rect) {
                    let oneLine = text.replacingOccurrences(of: "\n", with: " / ")
                    print("  #\(i + 1) \(coords): \(oneLine)")
                } else {
                    print("  #\(i + 1) \(coords): (no text)")
                }
            }
            liveTextDone.value = true
        }
        let deadline2 = Date().addingTimeInterval(180)
        while !liveTextDone.value, Date() < deadline2 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if !liveTextDone.value { print("  (live-text-per-region timed out)") }
    }

    /// Render a debug overlay showing each detected bubble region as a
    /// yellow rectangle on a copy of the source image. Helps us see
    /// whether the detector is finding the right blobs at a glance.
    private static func drawRegions(on cgImage: CGImage, regions: [CGRect]) -> CGImage? {
        let w = cgImage.width, h = cgImage.height
        guard let ctx = CGContext(data: nil,
                                   width: w, height: h,
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setStrokeColor(NSColor.systemYellow.cgColor)
        ctx.setLineWidth(4)
        for rect in regions {
            // CG bottom-left origin: flip Y for drawing.
            let drawRect = CGRect(
                x: rect.minX * CGFloat(w),
                y: CGFloat(h) - (rect.minY + rect.height) * CGFloat(h),
                width: rect.width * CGFloat(w),
                height: rect.height * CGFloat(h)
            )
            ctx.stroke(drawRect)
        }
        return ctx.makeImage()
    }

    /// Cheap boxed-flag so the run-loop spin can poll a mutable bool
    /// that the async task can also write. A plain `var` capture would
    /// be a Sendable warning; a class reference passes by identity.
    private final class DiagnosticFlag {
        var value: Bool = false
    }

    /// Apply contrast + lightness boost via Core Image so the cream-on-
    /// gray manga text becomes closer to black-on-white. Returns nil if
    /// CI fails to render the result.
    private static func boostContrast(_ cgImage: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: cgImage)
        let filter = CIFilter.colorControls()
        filter.inputImage = ci
        filter.saturation = 0     // strip colour
        filter.brightness = 0.0
        filter.contrast = 2.4     // crank contrast
        guard let out = filter.outputImage else { return nil }
        return CIContext().createCGImage(out, from: ci.extent)
    }

    private static func upscale2x(_ cgImage: CGImage) -> CGImage? {
        let w = cgImage.width * 2
        let h = cgImage.height * 2
        guard let ctx = CGContext(data: nil,
                                   width: w, height: h,
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func saveCGImage(_ image: CGImage, to url: URL) {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    private static func dump(_ boxes: [(text: String, rect: CGRect, confidence: Float)]) {
        print("  \(boxes.count) observations")
        for b in boxes.prefix(40) {
            let r = b.rect
            let coords = String(format: "[%.3f, %.3f  %.3fx%.3f]",
                                r.minX, r.minY, r.width, r.height)
            let conf = String(format: "%.2f", b.confidence)
            print("  \(coords) (\(conf)): \(b.text)")
        }
        if boxes.count > 40 { print("  …") }
    }

    private static func runVision(on cgImage: CGImage,
                                   configure: (VNRecognizeTextRequest) -> Void)
        -> [(text: String, rect: CGRect, confidence: Float)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.revision = VNRecognizeTextRequest.currentRevision
        configure(request)
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do { try handler.perform([request]) } catch {
            print("    perform failed: \(error)")
            return []
        }
        guard let observations = request.results else { return [] }
        return observations.compactMap { obs in
            guard let cand = obs.topCandidates(1).first else { return nil }
            let v = obs.boundingBox
            // Vision returns bottom-left-origin; flip to top-left.
            let r = CGRect(x: v.origin.x,
                            y: 1.0 - v.origin.y - v.height,
                            width: v.width,
                            height: v.height)
            return (cand.string, r, cand.confidence)
        }
    }

    private static func rotated90CCW(_ cgImage: CGImage) -> CGImage? {
        let w = cgImage.width
        let h = cgImage.height
        let cs = CGColorSpaceCreateDeviceRGB()
        let info: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        if let ctx = CGContext(data: nil,
                                width: h, height: w,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: cs, bitmapInfo: info) {
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: .pi / 2)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()
        }
        return nil
    }
}
