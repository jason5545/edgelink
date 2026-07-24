import AppKit
import Foundation

enum ClipboardThumbnailGenerator {
    static let maxEdge: CGFloat = 96

    static func thumbnailBase64(forImageIn pasteboard: NSPasteboard) -> String? {
        let types = pasteboard.types ?? []
        guard types.contains(.png) || types.contains(.tiff) else {
            return nil
        }
        if let png = pasteboard.data(forType: .png) {
            return thumbnailBase64(for: png)
        }
        if let tiff = pasteboard.data(forType: .tiff) {
            return thumbnailBase64(for: tiff)
        }
        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
            return thumbnailBase64(for: image)
        }
        return nil
    }

    static func thumbnailBase64(for data: Data) -> String? {
        guard let image = NSImage(data: data) else {
            return nil
        }
        return thumbnailBase64(for: image)
    }

    static func thumbnailBase64(for image: NSImage) -> String? {
        let size = image.size
        guard size.width > 0, size.height > 0 else {
            return nil
        }
        let scale = min(maxEdge / size.width, maxEdge / size.height, 1)
        let target = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                          pixelsWide: Int(target.width),
                                          pixelsHigh: Int(target.height),
                                          bitsPerSample: 8,
                                          samplesPerPixel: 4,
                                          hasAlpha: true,
                                          isPlanar: false,
                                          colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0,
                                          bitsPerPixel: 0) else {
            return nil
        }
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy,
                   fraction: 1.0)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return pngData.base64EncodedString()
    }
}