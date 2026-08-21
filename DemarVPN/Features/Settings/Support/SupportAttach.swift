import SwiftUI
import PhotosUI
import webp
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
            guard let encoded = photoData(from: raw) else {
                throw DemarAPIError(
                    message: "unsupported image",
                    statusCode: 400,
                    retryAfterSeconds: nil,
                    hint: nil
                )
            }
            out.append(try SupportApi.uploadFromData(
                encoded.data,
                fileName: "photo_\(i + 1).\(encoded.ext)",
                mimeType: encoded.mime
            ))
        }
        if out.isEmpty, !items.isEmpty {
            throw DemarAPIError(
                message: String(localized: "Could not load photo"),
                statusCode: 400,
                retryAfterSeconds: nil,
                hint: nil
            )
        }
        return out
    }

    static func fromFileURLs(_ urls: [URL]) async throws -> [SupportUploadMedia] {
        var out: [SupportUploadMedia] = []
        for (i, url) in urls.enumerated() {
            #if os(macOS)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            #endif

            let raw = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !raw.isEmpty else { continue }

            guard let encoded = photoData(from: raw) else {
                throw DemarAPIError(
                    message: "unsupported image",
                    statusCode: 400,
                    retryAfterSeconds: nil,
                    hint: nil
                )
            }
            out.append(try SupportApi.uploadFromData(
                encoded.data,
                fileName: "photo_\(i + 1).\(encoded.ext)",
                mimeType: encoded.mime
            ))
        }
        return out
    }

    private struct EncodedPhoto {
        let data: Data
        let ext: String
        let mime: String
    }

    /// Prefer WebP; fall back to JPEG if encode fails.
    private static func photoData(from data: Data) -> EncodedPhoto? {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        let scaled = scaledImage(image, maxEdge: maxPhotoEdge)
        if let webp = compressedWebP(scaled, maxBytes: maxPhotoBytes) {
            return EncodedPhoto(data: webp, ext: "webp", mime: "image/webp")
        }
        guard let jpeg = compressedJPEG(scaled, maxBytes: maxPhotoBytes) else { return nil }
        return EncodedPhoto(data: jpeg, ext: "jpg", mime: "image/jpeg")
        #elseif os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        let scaled = scaledImage(image, maxEdge: maxPhotoEdge)
        if let webp = compressedWebP(scaled, maxBytes: maxPhotoBytes) {
            return EncodedPhoto(data: webp, ext: "webp", mime: "image/webp")
        }
        guard let jpeg = compressedJPEG(scaled, maxBytes: maxPhotoBytes) else { return nil }
        return EncodedPhoto(data: jpeg, ext: "jpg", mime: "image/jpeg")
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

    private static func compressedWebP(_ image: UIImage, maxBytes: Int) -> Data? {
        let encoder = WebPEncoder()
        var quality: Float = 75
        while quality >= 25 {
            do {
                let data = try encoder.encode(image, config: .preset(.picture, quality: quality))
                if data.count <= maxBytes { return data }
            } catch {
                return nil
            }
            quality -= 10
        }
        return nil
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

    private static func compressedWebP(_ image: NSImage, maxBytes: Int) -> Data? {
        let encoder = WebPEncoder()
        var quality: Float = 75
        while quality >= 25 {
            do {
                let data = try encoder.encode(image, config: .preset(.picture, quality: quality))
                if data.count <= maxBytes { return data }
            } catch {
                return nil
            }
            quality -= 10
        }
        return nil
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
