import Foundation

/// Uploads annotated screenshots to a GitHub repository via the Contents API.
///
/// Configured in Settings: repository ("owner/name"), optional branch (empty =
/// the repo's default branch), folder inside the repo, and a personal access
/// token. The token lives in the Keychain, never in UserDefaults. A
/// fine-grained PAT with read/write access to "Contents" of that one
/// repository is all that's needed.
final class GitHubUploader {
    static let shared = GitHubUploader()
    private init() {}

    static let repoDefaultsKey = "githubUploadRepo"
    static let branchDefaultsKey = "githubUploadBranch"
    static let folderDefaultsKey = "githubUploadFolder"
    private static let keychainService = "com.ngothanhtung.snappy.github"

    enum GitHubError: LocalizedError {
        case notConfigured
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "GitHub upload is not set up. Open Snappy Settings and enter a "
                    + "repository (owner/name) and a personal access token with "
                    + "Contents read/write permission."
            case .http(let code, let body):
                return "GitHub request failed (HTTP \(code)): \(body)"
            }
        }
    }

    // MARK: - Configuration

    private func defaultsValue(_ key: String) -> String? {
        let value = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// Normalized "owner/name". Accepts what users actually paste: a plain
    /// "owner/name", a full https://github.com/owner/name URL, or a clone URL
    /// with a trailing ".git".
    private var repo: String? {
        guard var value = defaultsValue(Self.repoDefaultsKey) else { return nil }
        for prefix in ["https://github.com/", "http://github.com/", "github.com/"]
        where value.lowercased().hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        if value.lowercased().hasSuffix(".git") { value = String(value.dropLast(4)) }
        while value.hasSuffix("/") { value = String(value.dropLast()) }
        let parts = value.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return value
    }

    var token: String? {
        KeychainStore.load(service: Self.keychainService)
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    var hasToken: Bool { token != nil }
    var isConfigured: Bool { repo != nil && hasToken }

    func setToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeychainStore.save(Data(trimmed.utf8), service: Self.keychainService)
    }

    func clearToken() {
        KeychainStore.delete(service: Self.keychainService)
    }

    // MARK: - Upload

    /// Commits the PNG to the configured repo; returns the file's raw-content
    /// URL (download_url — raw.githubusercontent.com for public repos, a
    /// tokenized raw link for private ones).
    func upload(png: Data, filename: String) async throws -> URL? {
        guard let repo, let token else { throw GitHubError.notConfigured }
        let folder = defaultsValue(Self.folderDefaultsKey) ?? "snappy"
        let path = folder.isEmpty ? filename : "\(folder)/\(filename)"
        guard let encodedPath = path.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(.init(charactersIn: "?#"))
        ), let url = URL(string: "https://api.github.com/repos/\(repo)/contents/\(encodedPath)")
        else { throw GitHubError.notConfigured }

        var body: [String: Any] = [
            "message": "Add \(filename) via Snappy",
            "content": png.base64EncodedString(),
        ]
        if let branch = defaultsValue(Self.branchDefaultsKey) {
            body["branch"] = branch
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201 || status == 200 else {
            throw GitHubError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = json?["content"] as? [String: Any]
        return (content?["download_url"] as? String).flatMap(URL.init(string:))
    }
}
