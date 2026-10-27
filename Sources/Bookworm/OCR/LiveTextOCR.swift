import Foundation
import AppKit
import VisionKit

/// Wraps VisionKit's `ImageAnalyzer` (the engine that powers Live Text in
/// Preview / Photos / Quick Look) and exposes it as a simple "give me the
/// recognised text" call.
///
/// We need this as a fallback because `VNRecognizeTextRequest` fails
/// completely on the stylised fonts that show up in real-world manga and
/// comics. `ImageAnalyzer` reads them reliably but only exposes a flat
/// transcript — no per-line bounding boxes. The translate-mode pipeline
/// recovers per-bubble regions by detecting candidate bubble rectangles
/// up-front (see `BubbleDetector`) and feeding each crop into this
/// recogniser individually.
///
/// `ImageAnalyzer` is `@MainActor`-bound, so the recognise calls bounce
/// to the main actor internally. Callers can stay on any actor.
@MainActor
final class LiveTextOCR {
    static let shared = LiveTextOCR()

    private let analyzer = ImageAnalyzer()

    /// Run Live Text OCR on a CGImage. Returns the recognised text (with
    /// embedded line breaks) or nil if recognition failed / the image
    /// contained no text. Empty / whitespace-only transcripts are
    /// normalised to nil so the caller can treat "no text" uniformly.
    func recognize(in cgImage: CGImage) async -> String? {
        let nsImage = NSImage(cgImage: cgImage,
                               size: NSSize(width: cgImage.width, height: cgImage.height))
        let config = ImageAnalyzer.Configuration([.text])
        do {
            let analysis = try await analyzer.analyze(nsImage,
                                                        orientation: .up,
                                                        configuration: config)
            let transcript = analysis.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            return transcript.isEmpty ? nil : transcript
        } catch {
            return nil
        }
    }

    /// Recognise text inside a specific rectangle of the source image.
    /// `rect` is in normalised, top-left-origin coordinates (0…1) — the
    /// same convention as `OCRBox`. Crops via a CGContext draw so the
    /// caller can pass any normalised rect without worrying about
    /// CGImage's bottom-left origin or odd colorSpace combinations.
    func recognize(in cgImage: CGImage, rect: CGRect) async -> String? {
        let imgW = cgImage.width
        let imgH = cgImage.height
        let cropX = max(0, min(imgW - 1, Int(rect.minX * CGFloat(imgW))))
        let cropY = max(0, min(imgH - 1, Int(rect.minY * CGFloat(imgH))))
        let cropW = max(1, min(imgW - cropX, Int(rect.width  * CGFloat(imgW))))
        let cropH = max(1, min(imgH - cropY, Int(rect.height * CGFloat(imgH))))

        // Render the crop into a fresh deviceRGB context so the colour
        // space + pixel format are guaranteed compatible. CGImage.cropping
        // would be cheaper but inherits the source colour space and can
        // surface obscure colour-management bugs into ImageAnalyzer.
        let ctxColorSpace = CGColorSpaceCreateDeviceRGB()
        let ctxBitmap: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil,
                                   width: cropW, height: cropH,
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: ctxColorSpace,
                                   bitmapInfo: ctxBitmap) else { return nil }
        ctx.interpolationQuality = .high
        // The draw rect needs to be offset so the source crop region
        // ends up at (0, 0). CG y-axis is flipped relative to top-left
        // normalised coordinates, so we offset accordingly.
        let drawX = -CGFloat(cropX)
        let drawY = CGFloat(cropY) + CGFloat(cropH) - CGFloat(imgH)
        ctx.draw(cgImage, in: CGRect(x: drawX, y: drawY,
                                      width: CGFloat(imgW), height: CGFloat(imgH)))
        guard let cropped = ctx.makeImage() else { return nil }
        return await recognize(in: cropped)
    }
}
