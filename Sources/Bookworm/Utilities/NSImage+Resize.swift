import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

extension NSImage {
    func resized(maxDimension: CGFloat) -> NSImage {
        let originalSize = self.size
        let maxSide = max(originalSize.width, originalSize.height)
        guard maxSide > maxDimension, maxSide > 0 else { return self }
        let scale = maxDimension / maxSide
        let newSize = NSSize(width: floor(originalSize.width * scale),
                             height: floor(originalSize.height * scale))
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        self.draw(in: NSRect(origin: .zero, size: newSize),
                  from: NSRect(origin: .zero, size: originalSize),
                  operation: .copy,
                  fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let tiff = self.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}

enum ImageDecoder {
    static func image(from data: Data) -> NSImage? {
        // Use ImageIO for broader format support and faster decoding.
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        return NSImage(data: data)
    }
}
