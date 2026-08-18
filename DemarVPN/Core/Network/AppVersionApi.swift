import Foundation

struct AppVersionInfo: Equatable, Sendable {
    let version: String
    let buildNumber: String

    var buildInt: Int? {
        Int(buildNumber.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func isNewer(thanInstalledBuild installedBuild: String) -> Bool {
        guard let remote = buildInt,
              let local = Int(installedBuild.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return remote > local
    }

    var token: String { "\(version)#\(buildNumber)" }
}

enum AppVersionApi {
    static func fetchLatest() async throws -> AppVersionInfo {
        try parseResponse(try await DemarHttp.getJSON(AppPlatform.versionEndpointURL))
    }

    static func parseResponse(_ json: [String: Any]) throws -> AppVersionInfo {
        guard let version = (json["version"] as? String)?.nilIfBlank else {
            throw DemarAPIError(message: "Missing version", statusCode: 0, retryAfterSeconds: nil, hint: nil)
        }
        guard let buildNumber = (json["buildNumber"] as? String)?.nilIfBlank else {
            throw DemarAPIError(message: "Missing buildNumber", statusCode: 0, retryAfterSeconds: nil, hint: nil)
        }
        return AppVersionInfo(version: version, buildNumber: buildNumber)
    }
}
