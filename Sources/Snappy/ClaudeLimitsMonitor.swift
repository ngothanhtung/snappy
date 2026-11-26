import Foundation
import Security
import SnappyCore

/// Official Claude plan usage (Session 5hr / Weekly 7 day, as in Claude Code's
/// "Account & Usage" panel) for the account Claude Code is signed in to.
///
/// Reads Claude Code's login from the Keychain item "Claude Code-credentials"
/// (read-only: never refreshed or stored by Snappy — refreshing would rotate the
/// refresh token and could sign Claude Code out) and calls the same internal
/// endpoint Claude Code uses, `GET https://api.anthropic.com/api/oauth/usage`.
/// That endpoint is undocumented and may change. Polls every 5 minutes while
/// someone (the mini display's Claude widget) is interested, and remembers the last values
/// per account so a failed fetch still shows that account's last-known usage.
@MainActor
final class ClaudeLimitsMonitor: ObservableObject {
    static let shared = ClaudeLimitsMonitor()

    /// Last-known usage of one Claude account.
    struct AccountLimits: Codable, Equatable, Sendable {
        var accountID: String
        var email: String?
        var organization: String?
        var plan: String?
        var usage: ClaudeLimits.Usage
        var fetchedAt: Date
    }

    /// What the mini display card needs.
    struct Snapshot: Sendable {
        var current: AccountLimits?
        var note: String?
    }

    @Published private(set) var current: AccountLimits?
    /// Why the latest fetch didn't work (nil when fine).
    @Published private(set) var note: String?
    @Published private(set) var isFetching = false

    let box = Box()

    private static let storeKey = "claudeLimitsByAccount"
    nonisolated private static let keychainService = "Claude Code-credentials"
    nonisolated private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let interval: TimeInterval = 300
    private var timer: Timer?
    /// Cheap 30 s check of `~/.claude.json` so switching accounts shows up at once.
    private var watchTimer: Timer?
    private var watchedModified: Date?
    private var fetchedAccountID: String?
    private var users = 0
    private var known: [String: AccountLimits]

    private init() {
        known = (UserDefaults.standard.data(forKey: Self.storeKey))
            .flatMap { try? JSONDecoder().decode([String: AccountLimits].self, from: $0) } ?? [:]
    }

    // MARK: Lifecycle

    func retain() {
        users += 1
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Baseline: only later edits of ~/.claude.json count as a possible switch.
        watchedModified = (try? Self.claudeJSONURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        watchTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAccountSwitch() }
        }
    }

    /// Re-fetches right away when Claude Code is signed in to a different account.
    /// Only parses `~/.claude.json` when its modification date changed.
    private func checkAccountSwitch() {
        let url = Self.claudeJSONURL
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard modified != watchedModified else { return }
        watchedModified = modified
        let id = Self.signedInAccount()?.id
        if id != fetchedAccountID, !isFetching {
            MiniDisplayLog.log("claude limits: signed-in account changed, refreshing")
            refresh()
        }
    }

    func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        timer?.invalidate()
        timer = nil
        watchTimer?.invalidate()
        watchTimer = nil
    }

    // MARK: Fetch

    func refresh() {
        guard !isFetching else { return }
        isFetching = true
        Task.detached(priority: .utility) {
            let result = await Self.fetch()
            await MainActor.run { self.apply(result) }
        }
    }

    private enum Result {
        case ok(AccountLimits)
        case failed(accountID: String?, note: String)
        /// The account changed while fetching (mid sign-in); try again shortly.
        case accountChanged
    }

    private func apply(_ result: Result) {
        isFetching = false
        var currentID: String?
        switch result {
        case .accountChanged:
            // Let Claude Code finish writing both the Keychain and ~/.claude.json.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
            return
        case .ok(let limits):
            known[limits.accountID] = limits
            currentID = limits.accountID
            fetchedAccountID = limits.accountID
            note = nil
            if let data = try? JSONEncoder().encode(known) {
                UserDefaults.standard.set(data, forKey: Self.storeKey)
            }
        case .failed(let id, let message):
            currentID = id
            note = message
            MiniDisplayLog.log("claude limits: \(message)")
        }
        current = currentID.flatMap { known[$0] }
        box.set(Snapshot(current: current, note: note))
    }

    /// Runs off the main actor: Keychain (may show a permission prompt) + network.
    nonisolated private static func fetch() async -> Result {
        let account = signedInAccount()
        guard let creds = claudeCredentials() else {
            return .failed(accountID: account?.id, note: "Claude.ai login of Claude Code not found (or access denied)")
        }
        if creds.isExpired(at: Date()) {
            return .failed(accountID: account?.id, note: "Login expired \u{2014} use Claude Code to refresh it")
        }
        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Snappy", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let note = status == 401 ? "Login expired \u{2014} use Claude Code to refresh it"
                                         : "Usage unavailable (HTTP \(status))"
                return .failed(accountID: account?.id, note: note)
            }
            guard let usage = ClaudeLimits.usage(fromJSON: data) else {
                return .failed(accountID: account?.id, note: "Usage response not understood")
            }
            // Never file one account's numbers under another: if the sign-in
            // changed while we were fetching, the token and the account may not match.
            if signedInAccount()?.id != account?.id { return .accountChanged }
            return .ok(AccountLimits(accountID: account?.id ?? "current", email: account?.email,
                                     organization: account?.organization,
                                     plan: ClaudeLimits.planName(creds.subscriptionType),
                                     usage: usage, fetchedAt: Date()))
        } catch {
            return .failed(accountID: account?.id, note: "Usage unavailable (\(error.localizedDescription))")
        }
    }

    /// The account Claude Code is signed in to, from `~/.claude.json` (`oauthAccount`).
    nonisolated private static var claudeJSONURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    nonisolated private static func signedInAccount() -> (id: String, email: String?, organization: String?)? {
        guard let data = try? Data(contentsOf: claudeJSONURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let a = obj["oauthAccount"] as? [String: Any],
              let id = a["accountUuid"] as? String else { return nil }
        return (id, a["emailAddress"] as? String, a["organizationName"] as? String)
    }

    /// Claude Code's Claude.ai login. Several items can share the service name
    /// (one may hold only MCP server tokens), so list them by attributes first —
    /// no secret is read for that — then open them in order: the one under the
    /// macOS user name, then the most recently modified.
    nonisolated private static func claudeCredentials() -> ClaudeLimits.Credentials? {
        let list: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(list as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return nil }
        let user = NSUserName()
        let accounts = items
            .sorted { a, b in
                let ua = (a[kSecAttrAccount as String] as? String) == user
                let ub = (b[kSecAttrAccount as String] as? String) == user
                if ua != ub { return ua }
                let ma = a[kSecAttrModificationDate as String] as? Date ?? .distantPast
                let mb = b[kSecAttrModificationDate as String] as? Date ?? .distantPast
                return ma > mb
            }
            .compactMap { $0[kSecAttrAccount as String] as? String }
        for acct in accounts {
            guard let raw = readWithSecurityTool(account: acct) else { continue }
            if let creds = ClaudeLimits.credentials(fromJSON: raw) { return creds }
        }
        return nil
    }

    /// Reads the item's secret through `/usr/bin/security`, the same tool
    /// Claude Code uses to write it. Every token refresh rewrites the item and
    /// resets its access list to the writer, so reading it from Snappy itself
    /// asked for the login password again and again ("Always Allow" never
    /// stuck); `/usr/bin/security` stays on the list, so this never prompts.
    nonisolated private static func readWithSecurityTool(account: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", keychainService, "-a", account, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // `security -w` prints the secret as hex when it has non-printable bytes.
        if !text.hasPrefix("{"), text.count % 2 == 0, text.allSatisfy(\.isHexDigit) {
            var bytes = [UInt8]()
            var i = text.startIndex
            while i < text.endIndex {
                let j = text.index(i, offsetBy: 2)
                guard let b = UInt8(text[i..<j], radix: 16) else { return nil }
                bytes.append(b)
                i = j
            }
            text = String(decoding: bytes, as: UTF8.self)
        }
        return Data(text.utf8)
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Snapshot?
        func set(_ v: Snapshot?) { lock.lock(); value = v; lock.unlock() }
        func get() -> Snapshot? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
