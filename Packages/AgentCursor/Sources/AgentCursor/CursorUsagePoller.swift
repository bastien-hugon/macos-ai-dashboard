import DashCore
import Foundation

/// Mesure mensuelle Cursor sélectionnable (02 · §5, feature AgentPeek v0.2.10).
public enum CursorUsageMeasure: String, Codable, CaseIterable, Sendable {
    case spend, weighted, auto, api
}

/// Poller d'usage mensuel Cursor (04 · §3, research cursor §3) : session locale existante
/// (JWT de state.vscdb → cookie WorkOS), endpoint dashboard `usage-summary` — non officiel,
/// décodage tolérant, santé dégradée plutôt qu'erreur bloquante.
public actor CursorUsagePoller: UsageProvider {
    public nonisolated var agent: AgentKind { .cursor }

    private let paths: DashPaths
    private let session: URLSession
    private let measure: @Sendable () -> CursorUsageMeasure

    public init(paths: DashPaths, session: URLSession = .shared,
                measure: @escaping @Sendable () -> CursorUsageMeasure) {
        self.paths = paths
        self.session = session
        self.measure = measure
    }

    // MARK: - Credentials (state.vscdb, lecture seule)

    struct Credentials {
        var userId: String
        var accessToken: String
        var email: String?
        var membership: String?
    }

    func readCredentials() throws -> Credentials {
        guard let reader = SQLiteReader(path: paths.cursorGlobalStorageDB.path) else {
            throw UsageError.accountUnavailable
        }
        guard let token = reader.stringValue(itemKey: "cursorAuth/accessToken"),
              !token.isEmpty else {
            throw UsageError.accountUnavailable
        }
        // userId = sub.split("|")[1] du payload JWT (research §3.1, méthode cursor-stats).
        guard let sub = Self.jwtSubject(token),
              let userId = sub.split(separator: "|").last.map(String.init) else {
            throw UsageError.decoding(field: "jwt.sub")
        }
        return Credentials(
            userId: userId,
            accessToken: token,
            email: reader.stringValue(itemKey: "cursorAuth/cachedEmail"),
            membership: reader.stringValue(itemKey: "cursorAuth/stripeMembershipType")
        )
    }

    static func jwtSubject(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["sub"] as? String
    }

    // MARK: - UsageProvider

    public func discoverAccounts() async throws -> [UsageAccount] {
        let creds = try readCredentials()
        return [UsageAccount(
            id: "cursor:\(creds.userId)", agent: .cursor,
            label: creds.email ?? "Cursor account", plan: creds.membership
        )]
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        let creds = try readCredentials()
        var request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        // Cookie WorkOS + en-têtes navigateur (research §3.1, extensions OSS).
        request.setValue("WorkosCursorSessionToken=\(creds.userId)%3A%3A\(creds.accessToken)",
                         forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard?tab=usage", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 20

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw UsageError.network("réponse non HTTP") }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw UsageError.unauthorized
        case 429: throw UsageError.rateLimited(retryAfter: nil)
        default: throw UsageError.network("HTTP \(http.statusCode)")
        }
        return try Self.decode(data, account: "cursor:\(creds.userId)", measure: measure(), now: Date())
    }

    // MARK: - Usage du jour (get-aggregated-usage-events, research §3.2)

    public struct TodayEvents: Equatable, Sendable {
        public var tokens: Int       // input + output du jour
        public var costUSD: Double   // totalCostCents / 100
    }

    /// Dépense et tokens du jour (depuis minuit locale) via l'endpoint dashboard.
    public func fetchTodayEvents(now: Date = Date()) async throws -> TodayEvents {
        let creds = try readCredentials()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let body: [String: Any] = [
            "teamId": -1,
            "startDate": Int(startOfDay.timeIntervalSince1970 * 1000),
            "endDate": Int(now.timeIntervalSince1970 * 1000),
        ]
        var request = URLRequest(url: URL(string: "https://cursor.com/api/dashboard/get-aggregated-usage-events")!)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("WorkosCursorSessionToken=\(creds.userId)%3A%3A\(creds.accessToken)",
                         forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard?tab=usage", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 20

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw UsageError.network("réponse non HTTP") }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw UsageError.unauthorized
        case 429: throw UsageError.rateLimited(retryAfter: nil)
        default: throw UsageError.network("HTTP \(http.statusCode)")
        }
        return try Self.decodeTodayEvents(data)
    }

    /// Décodage tolérant (nombres parfois sérialisés en strings).
    nonisolated static func decodeTodayEvents(_ data: Data) throws -> TodayEvents {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.decoding(field: nil)
        }
        func number(_ key: String) -> Double {
            if let n = root[key] as? NSNumber { return n.doubleValue }
            if let s = root[key] as? String, let d = Double(s) { return d }
            return 0
        }
        let tokens = Int(number("totalInputTokens") + number("totalOutputTokens"))
        let costCents = number("totalCostCents")
        return TodayEvents(tokens: tokens, costUSD: costCents / 100)
    }

    // MARK: - Décodage (pur, testable)

    static func decode(_ data: Data, account: String, measure: CursorUsageMeasure, now: Date) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.decoding(field: nil)
        }
        let individual = root["individualUsage"] as? [String: Any] ?? [:]
        let plan = individual["plan"] as? [String: Any] ?? [:]
        let onDemand = individual["onDemand"] as? [String: Any] ?? [:]
        let resetsAt = parseCycleDate(root["billingCycleEnd"])

        // VÉRIFIÉ sur données réelles : plan.{total,auto,api}PercentUsed = pourcentages (0-100)
        // de l'usage inclus ; onDemand.{used,limit} = cents (dépense usage-based réelle),
        // limit null = illimité. plan.used/limit sont des COMPTES D'UNITÉS, pas des cents.
        let totalPct = (plan["totalPercentUsed"] as? NSNumber)?.doubleValue ?? 0
        let autoPct = (plan["autoPercentUsed"] as? NSNumber)?.doubleValue ?? 0
        let apiPct = (plan["apiPercentUsed"] as? NSNumber)?.doubleValue ?? 0
        let onDemandUsedCents = (onDemand["used"] as? NSNumber)?.doubleValue
        let onDemandLimitCents = (onDemand["limit"] as? NSNumber)?.doubleValue

        // Dollars = dépense on-demand réelle (cents → $) ; limite illimitée si absente.
        var dollars: UsageWindow.Dollars?
        if let usedCents = onDemandUsedCents, usedCents > 0 {
            dollars = UsageWindow.Dollars(
                used: usedCents / 100,
                limit: onDemandLimitCents.map { $0 / 100 } ?? .infinity
            )
        }

        // Fill de la jauge selon la mesure choisie.
        let utilization: Double
        switch measure {
        case .weighted: utilization = totalPct
        case .auto: utilization = autoPct
        case .api: utilization = apiPct
        case .spend:
            // % on-demand si une limite existe, sinon on retombe sur le % pondéré.
            if let usedCents = onDemandUsedCents, let limitCents = onDemandLimitCents, limitCents > 0 {
                utilization = usedCents / limitCents * 100
            } else {
                utilization = totalPct
            }
        }

        let window = UsageWindow(
            kind: .monthly, utilization: min(100, max(0, utilization)),
            resetsAt: resetsAt, fetchedAt: now, dollars: dollars
        )
        return UsageSnapshot(agent: .cursor, account: account, windows: [window], fetchedAt: now)
    }

    /// `billingCycleEnd` : date ISO **ou** epoch ms en string (les deux formats acceptés).
    static func parseCycleDate(_ raw: Any?) -> Date? {
        if let number = raw as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue / 1000)
        }
        guard let string = raw as? String else { return nil }
        if let ms = Double(string), ms > 1_000_000_000 {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
