import SwiftUI
import Foundation

func formatSupportMsgTime(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = iso.date(from: raw) ?? {
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }()
    guard let date else { return nil }
    let fmt = DateFormatter()
    fmt.locale = .current
    fmt.dateFormat = "HH:mm"
    return fmt.string(from: date)
}

func supportErrorMessage(_ error: Error) -> String {
    // Cancellation is not an API outage — callers should ignore it; keep message generic if shown.
    if isSupportCancellation(error) {
        return String(localized: "Could not reach api. Try again")
    }
    if let e = error as? DemarAPIError {
        if e.isMediaTooLarge {
            return String(localized: "File must not exceed 25 MB")
        }
        if e.message.hasPrefix("media: max") {
            return String(localized: "You can attach up to 10 photos")
        }
        if e.isChannelMismatch {
            return String(localized: "This ticket was opened in another source. Reply there or create a new ticket.")
        }
        if let msg = e.message.nilIfBlank { return msg }
    }
    if let urlErr = error as? URLError {
        return "\(String(localized: "Could not reach api. Try again")) (\(urlErr.code.rawValue))"
    }
    return String(localized: "Could not reach api. Try again")
}

func isSupportCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlErr = error as? URLError, urlErr.code == .cancelled { return true }
    let ns = error as NSError
    return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
}

func isTransientSupportFailure(_ error: Error) -> Bool {
    if isSupportCancellation(error) { return true }
    guard let urlErr = error as? URLError else { return false }
    switch urlErr.code {
    case .timedOut, .networkConnectionLost, .notConnectedToInternet,
         .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff,
         .dataNotAllowed, .secureConnectionFailed:
        return true
    default:
        return false
    }
}

extension AttributedString {
    init(linkified text: String) {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            self = result
            return
        }
        let ns = text as NSString
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            guard let url = m.url,
                  let range = Range(m.range, in: text),
                  let attrRange = Range(range, in: result)
            else { continue }
            result[attrRange].link = url
            result[attrRange].foregroundColor = .demarPrimary
        }
        self = result
    }
}
