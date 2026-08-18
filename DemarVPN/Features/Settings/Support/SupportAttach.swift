import SwiftUI
import PhotosUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum SupportAttachLoader {
    /// Keep payloads small — large base64 JSON hangs / 502s through CS relay.
    private static let maxPhotoEdge: CGFloat = 1024
    private static let maxPhotoBytes = 400 * 1024

    static func fromPhotos(_ items: [PhotosPickerItem]) async throws -> [SupportUploadMedia] {
        var out: [SupportUploadMedia] = []
        for (i, item) in items.enumerated() {
            guard let raw = try await item.loadTransferable(type: Data.self), !raw.isEmpty else { continue }
            guard let jpeg = jpegData(from: raw) else {
                throw DemarAPIError(
                    message: "unsupported image",
                    statusCode: 400,
                    retryAfterSeconds: nil,
                    hint: nil
                )
            }
            out.append(try SupportApi.uploadFromData(jpeg, fileName: "photo_\(i + 1).jpg", mimeType: "image/jpeg"))
        }
        return out
    }

    /// Re-encode image bytes as JPEG (downscaled). Returns nil if not a decodable image.
    private static func jpegData(from data: Data) -> Data? {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        let scaled = scaledImage(image, maxEdge: maxPhotoEdge)
        return compressedJPEG(scaled, maxBytes: maxPhotoBytes)
        #elseif os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        let scaled = scaledImage(image, maxEdge: maxPhotoEdge)
        return compressedJPEG(scaled, maxBytes: maxPhotoBytes)
        #else
        return nil
        #endif
    }

    #if os(iOS)
    private static func scaledImage(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxEdge, longest > 0 else { return image }
        let scale = maxEdge / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    private static func compressedJPEG(_ image: UIImage, maxBytes: Int) -> Data? {
        var quality: CGFloat = 0.65
        var data = image.jpegData(compressionQuality: quality)
        while let bytes = data, bytes.count > maxBytes, quality > 0.22 {
            quality -= 0.08
            data = image.jpegData(compressionQuality: quality)
        }
        return data
    }
    #elseif os(macOS)
    private static func scaledImage(_ image: NSImage, maxEdge: CGFloat) -> NSImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxEdge, longest > 0 else { return image }
        let scale = maxEdge / longest
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let out = NSImage(size: newSize)
        out.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        out.unlockFocus()
        return out
    }

    private static func compressedJPEG(_ image: NSImage, maxBytes: Int) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        var quality = 0.65
        var data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        while let bytes = data, bytes.count > maxBytes, quality > 0.22 {
            quality -= 0.08
            data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        }
        return data
    }
    #endif
}
