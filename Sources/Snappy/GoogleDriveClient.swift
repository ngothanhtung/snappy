import AppKit
import CryptoKit
import Network

/// Google Drive upload via OAuth 2.0 for native apps (loopback redirect + PKCE).
///
/// The user supplies their own OAuth "Desktop app" Client ID/Secret in Settings
/// (Google Cloud Console → APIs & Services → Credentials, with the Drive API
/// enabled). Sign-in happens in the default browser; Snappy only receives the
/// authorization code on a localhost redirect. Tokens are kept in the Keychain.
/// Scope is `drive.file` — Snappy can only see files it created itself.
final class GoogleDriveClient {
    static let shared = GoogleDriveClient()
    private init() {}

    static let clientIDDefaultsKey = "googleDriveClientID"
    private static let keychainService = "com.ngothanhtung.snappy.google-drive"
    static let clientSecretDefaultsKey = "googleDriveClientSecret"

    enum DriveError: LocalizedError {
        case notConfigured
        case authFailed(String)
        case timedOut
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Google Drive is not set up. Open Snappy Settings and enter your "
                    + "OAuth Client ID and Client Secret (create a \u{201C}Desktop app\u{201D} "
                    + "credential in Google Cloud Console with the Drive API enabled)."
            case .authFailed(let reason):
                return "Google sign-in failed: \(reason)"
            case .timedOut:
                return "Google sign-in timed out. Please try again."
            case .http(let code, let body):
                return "Google Drive request failed (HTTP \(code)): \(body)"
            }
        }
    }

    // MARK: - Configuration / session state

    /// Credentials baked into the app bundle by `bundle.sh` from the gitignored
    /// `Secrets/GoogleDriveCredentials.plist`. The Settings fields override them.
    private static let bundled: (id: String, secret: String)? = {
        guard let url = Bundle.main.url(forResource: "GoogleDriveCredentials",
                                        withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: String],
              let id = plist["ClientID"], !id.isEmpty
        else { return nil }
        return (id, plist["ClientSecret"] ?? "")
    }()

    static var hasBundledCredentials: Bool { bundled != nil }

    private var clientID: String? {
        let value = UserDefaults.standard.string(forKey: Self.clientIDDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty { return value }
        return Self.bundled?.id
    }

    private var clientSecret: String {
        let value = UserDefaults.standard.string(forKey: Self.clientSecretDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty { return value }
        return Self.bundled?.secret ?? ""
    }

    var isConfigured: Bool { clientID != nil }
    var isSignedIn: Bool { KeychainStore.load(service: Self.keychainService) != nil }

    func signOut() {
        KeychainStore.delete(service: Self.keychainService)
    }

    // MARK: - Upload

    /// Uploads PNG data into the "Snappy" folder of the user's Drive
    /// (created on first upload); returns the file's webViewLink.
    func upload(png: Data, filename: String) async throws -> URL? {
        var token = try await validAccessToken()
        var folderID = try await snappyFolderID(accessToken: token)
        var (status, body) = try await performUpload(
            png: png, filename: filename, folderID: folderID, accessToken: token)
        if status == 401 {
            // Stored token was revoked server-side; force a fresh sign-in once.
            KeychainStore.delete(service: Self.keychainService)
            token = try await validAccessToken()
            (status, body) = try await performUpload(
                png: png, filename: filename, folderID: folderID, accessToken: token)
        }
        if status == 404 {
            // Cached folder was deleted on Drive; find or recreate it once.
            UserDefaults.standard.removeObject(forKey: Self.folderIDDefaultsKey)
            folderID = try await snappyFolderID(accessToken: token)
            (status, body) = try await performUpload(
                png: png, filename: filename, folderID: folderID, accessToken: token)
        }
        guard status == 200 else {
            throw DriveError.http(status, String(data: body, encoding: .utf8) ?? "")
        }
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        return (json?["webViewLink"] as? String).flatMap(URL.init(string:))
    }

    // MARK: - Snappy folder

    private static let folderIDDefaultsKey = "googleDriveSnappyFolderID"
    private static let folderName = "Snappy"
    private static let folderMimeType = "application/vnd.google-apps.folder"

    /// Returns the Drive folder ID for "Snappy", searching then creating as
    /// needed. With the drive.file scope the search only sees folders this app
    /// created, so a user folder with the same name is never hijacked.
    private func snappyFolderID(accessToken: String) async throws -> String {
        if let cached = UserDefaults.standard.string(forKey: Self.folderIDDefaultsKey) {
            return cached
        }

        var search = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        search.queryItems = [
            .init(name: "q", value: "name = '\(Self.folderName)' and "
                + "mimeType = '\(Self.folderMimeType)' and trashed = false"),
            .init(name: "fields", value: "files(id)"),
            .init(name: "pageSize", value: "1"),
        ]
        var request = URLRequest(url: search.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw DriveError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let id = ((json?["files"] as? [[String: Any]])?.first?["id"]) as? String {
            UserDefaults.standard.set(id, forKey: Self.folderIDDefaultsKey)
            return id
        }

        // Not found — create it.
        var create = URLRequest(
            url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!)
        create.httpMethod = "POST"
        create.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        create.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        create.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": Self.folderName,
            "mimeType": Self.folderMimeType,
        ])
        let (created, createResponse) = try await URLSession.shared.data(for: create)
        let createStatus = (createResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard createStatus == 200,
              let createdJSON = try? JSONSerialization.jsonObject(with: created) as? [String: Any],
              let id = createdJSON["id"] as? String else {
            throw DriveError.http(createStatus, String(data: created, encoding: .utf8) ?? "")
        }
        NSLog("Snappy: created Drive folder %@ (%@)", Self.folderName, id)
        UserDefaults.standard.set(id, forKey: Self.folderIDDefaultsKey)
        return id
    }

    private func performUpload(png: Data, filename: String, folderID: String,
                               accessToken: String) async throws -> (Int, Data) {
        let url = URL(string:
            "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,webViewLink")!
        let boundary = "snappy-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let metadata = try JSONSerialization.data(
            withJSONObject: ["name": filename, "mimeType": "image/png",
                             "parents": [folderID]])
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: image/png\r\n\r\n".utf8))
        body.append(png)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }

    // MARK: - Tokens

    private struct StoredToken: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiry: Date
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
    }

    private func validAccessToken() async throws -> String {
        if let stored = KeychainStore.load(service: Self.keychainService),
           let token = try? JSONDecoder().decode(StoredToken.self, from: stored) {
            if token.expiry > Date().addingTimeInterval(60) {
                return token.accessToken
            }
            if let refreshToken = token.refreshToken,
               let refreshed = try? await refresh(refreshToken: refreshToken) {
                return refreshed
            }
        }
        return try await authorize()
    }

    private func refresh(refreshToken: String) async throws -> String {
        guard let clientID else { throw DriveError.notConfigured }
        let response = try await tokenRequest(form: [
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
        store(response, fallbackRefreshToken: refreshToken)
        return response.access_token
    }

    private func authorize() async throws -> String {
        guard let clientID else { throw DriveError.notConfigured }

        let verifier = Self.randomURLSafeString()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        let catcher = try RedirectCatcher()
        defer { catcher.stop() }
        let port = try await catcher.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "https://www.googleapis.com/auth/drive.file"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        let authURL = comps.url!
        await MainActor.run { NSWorkspace.shared.open(authURL) }

        let code = try await catcher.waitForCode()

        let response = try await tokenRequest(form: [
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ])
        store(response, fallbackRefreshToken: nil)
        return response.access_token
    }

    private func tokenRequest(form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(form).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw DriveError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func store(_ response: TokenResponse, fallbackRefreshToken: String?) {
        let token = StoredToken(
            accessToken: response.access_token,
            refreshToken: response.refresh_token ?? fallbackRefreshToken,
            expiry: Date().addingTimeInterval(response.expires_in)
        )
        if let data = try? JSONEncoder().encode(token) {
            KeychainStore.save(data, service: Self.keychainService)
        }
    }

    // MARK: - Helpers

    private static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(encoded)"
        }.joined(separator: "&")
    }

    private static func randomURLSafeString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback redirect listener

/// Minimal one-shot HTTP listener on 127.0.0.1 that catches Google's OAuth
/// redirect (`GET /?code=...`) and shows a "you can close this tab" page.
private final class RedirectCatcher {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.ngothanhtung.snappy.oauth-loopback")
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var connections: [NWConnection] = []

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    /// Starts listening; returns the OS-assigned port.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    guard let port = self?.listener.port?.rawValue else { return }
                    resumed = true
                    cont.resume(returning: port)
                case .failed(let error):
                    resumed = true
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.codeContinuation = cont
                // Give up if the user abandons the browser sign-in.
                self.queue.asyncAfter(deadline: .now() + 300) {
                    self.codeContinuation?.resume(throwing: GoogleDriveClient.DriveError.timedOut)
                    self.codeContinuation = nil
                }
            }
        }
    }

    func stop() {
        queue.async {
            self.listener.cancel()
            self.connections.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    private func handle(_ conn: NWConnection) {
        connections.append(conn)
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data,
                  let request = String(data: data, encoding: .utf8),
                  // "GET /?code=... HTTP/1.1"
                  let target = request.split(separator: " ").dropFirst().first
            else { return }
            let query = URLComponents(string: String(target))?.queryItems
            let code = query?.first(where: { $0.name == "code" })?.value
            let errorParam = query?.first(where: { $0.name == "error" })?.value

            // Ignore stray requests (e.g. /favicon.ico) that carry no result.
            if code == nil && errorParam == nil {
                conn.cancel()
                return
            }

            let message = code != nil
                ? "Snappy is now connected to Google Drive. You can close this tab."
                : "Google sign-in failed. You can close this tab and try again."
            let html = "<html><body style=\"font-family:sans-serif;padding:2em\">\(message)</body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            conn.send(content: Data(response.utf8),
                      completion: .contentProcessed { _ in conn.cancel() })

            if let code {
                self.codeContinuation?.resume(returning: code)
            } else {
                self.codeContinuation?.resume(
                    throwing: GoogleDriveClient.DriveError.authFailed(errorParam ?? "unknown"))
            }
            self.codeContinuation = nil
        }
    }
}
