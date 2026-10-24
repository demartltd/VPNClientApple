import Foundation
import zlib

/// Decoded `openflux://v1` share link (Yandex Boards carrier).
struct OpenFluxLinkConfig: Equatable, Sendable {
    let secret: String
    let boardsUrl: String
}

enum OpenFluxLink {
    private static let prefix = "openflux://v1/"
    private static let maxPayload = 16 * 1024
    private static let transport = "boards"

    static func decode(_ link: String) throws -> OpenFluxLinkConfig {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { throw DecodeError.notOpenFluxLink }
        let body = normalizeBody(String(trimmed.dropFirst(prefix.count)))
        guard let packed = Data(base64URLEncoded: padBase64(body)) else {
            throw DecodeError.badBase64
        }
        let raw = try inflateRaw(packed)
        guard raw.count <= maxPayload else { throw DecodeError.payloadTooLarge }
        guard let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw DecodeError.badJSON
        }
        let secret = ((json["secret"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard secret.count >= 16 else { throw DecodeError.shortSecret }
        var url = ""
        if let transports = json["transports"] as? [[String: Any]] {
            for t in transports where (t["type"] as? String) == transport {
                let u = ((t["url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !u.isEmpty {
                    url = u
                    break
                }
            }
        }
        if url.isEmpty {
            url = ((json["context"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !url.isEmpty else { throw DecodeError.boardsUrlMissing }
        return OpenFluxLinkConfig(secret: secret, boardsUrl: url)
    }

    enum DecodeError: Error {
        case notOpenFluxLink, badBase64, payloadTooLarge, badJSON, shortSecret, boardsUrlMissing, inflateFailed
    }

    private static func normalizeBody(_ b: String) -> String {
        let drop: Set<Character> = [" ", "\t", "\r", "\n", "\u{00a0}", "\u{200b}"]
        return String(b.filter { !drop.contains($0) })
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private static func padBase64(_ s: String) -> String {
        let rem = s.count % 4
        return rem == 0 ? s : s + String(repeating: "=", count: 4 - rem)
    }

    /// Raw DEFLATE (Android `Inflater(nowrap=true)` / RFC 1951).
    private static func inflateRaw(_ packed: Data) throws -> Data {
        let srcBytes = [UInt8](packed)
        var outCap = max(srcBytes.count * 16, 2048)
        for _ in 0..<4 {
            var outBytes = [UInt8](repeating: 0, count: outCap)
            let (rc, written): (Int32, Int) = srcBytes.withUnsafeBufferPointer { src in
                outBytes.withUnsafeMutableBufferPointer { dst in
                    var stream = z_stream()
                    guard inflateInit2_(
                        &stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
                    ) == Z_OK else { return (Z_MEM_ERROR, 0) }
                    defer { inflateEnd(&stream) }
                    stream.next_in = UnsafeMutablePointer(mutating: src.baseAddress!)
                    stream.avail_in = uInt(src.count)
                    stream.next_out = dst.baseAddress!
                    stream.avail_out = uInt(dst.count)
                    let code = inflate(&stream, Z_FINISH)
                    let n = dst.count - Int(stream.avail_out)
                    return (code, n)
                }
            }
            if rc == Z_STREAM_END {
                return Data(outBytes.prefix(written))
            }
            if rc == Z_BUF_ERROR || rc == Z_OK {
                outCap *= 4
                continue
            }
            throw DecodeError.inflateFailed
        }
        throw DecodeError.inflateFailed
    }
}

private extension Data {
    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = s.count % 4
        if rem != 0 { s += String(repeating: "=", count: 4 - rem) }
        self.init(base64Encoded: s)
    }
}
