import DashCore
import Foundation

/// Poller d'usage Claude (09 · §3.2, REQ-USG-01..03) : endpoint OAuth non documenté,
/// lecture du Keychain à la demande, décodage tolérant (fenêtres nulles), back-off sur 429.
public actor ClaudeUsagePoller: UsageProvider {
    public nonisolated var agent: AgentKind { .claude }

    private let paths: DashPaths
    private let session: URLSession
    private var cachedLabel: String?

    public init(paths: DashPaths, session: URLSession = .shared) {
        self.paths = paths
        self.session = session
    }

    public func discoverAccounts() async throws -> [UsageAccount] {
        let creds = try KeychainReader.claudeCredentials()
        cachedLabel = creds.accountLabel
        let label = creds.accountLabel ?? "Claude account"
        let id = "claude:" + String(SipHasher.hash(creds.accessToken), radix: 16)
        return [UsageAccount(id: id, agent: .claude, label: label)]
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        let creds = try KeychainReader.claudeCredentials()
        cachedLabel = creds.accountLabel ?? cachedLabel

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(ClaudeVersion.detect(paths: paths))", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.network("réponse non HTTP")
        }
        switch http.statusCode {
        case 200: break
        case 401: throw UsageError.unauthorized
        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw UsageError.rateLimited(retryAfter: retryAfter)
        default: throw UsageError.network("HTTP \(http.statusCode)")
        }

        return try decode(data, account: cachedLabel ?? "Claude account")
    }

    // MARK: - Décodage tolérant (pur, testable hors acteur)

    nonisolated func decode(_ data: Data, account: String) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.decoding(field: nil)
        }
        let now = Date()
        var windows: [UsageWindow] = []

        func window(_ key: String, kind: UsageWindowKind) {
            guard let object = root[key] as? [String: Any],
                  let utilization = (object["utilization"] as? NSNumber)?.doubleValue else { return }
            let resetsAt = (object["resets_at"] as? String).flatMap(Self.parseDate)
            windows.append(UsageWindow(kind: kind, utilization: utilization, resetsAt: resetsAt, fetchedAt: now))
        }
        window("five_hour", kind: .fiveHour)
        window("seven_day", kind: .sevenDay)
        window("seven_day_opus", kind: .sevenDayOpus)
        window("seven_day_sonnet", kind: .sevenDaySonnet)

        guard !windows.isEmpty else { throw UsageError.decoding(field: "five_hour/seven_day") }
        return UsageSnapshot(agent: .claude, account: account, windows: windows, fetchedAt: now)
    }

    private static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

/// Hash non cryptographique stable pour dériver un id de compte opaque (jamais le token).
enum SipHasher {
    static func hash(_ string: String) -> UInt64 {
        var h: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 { h ^= UInt64(byte); h = h &* 1_099_511_628_211 }
        return h
    }
}
