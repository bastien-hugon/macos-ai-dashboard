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

    // MARK: - Usage du jour (get-filtered-usage-events, research §3.2)
    //
    // ⚠️ `get-aggregated-usage-events` (teamId:-1) renvoie désormais `{}` (endpoint mort,
    //    vérifié le 5 juil. 2026). L'usage du jour vient de `get-filtered-usage-events`
    //    (SANS `teamId` — le passer déclenche un 401 « Team ID is required ») : une liste
    //    paginée `usageEventsDisplay[]` où chaque événement porte `tokenUsage` et
    //    `usageBasedCosts` (dépense usage-based réelle, string « $1.67 »).

    public struct TodayEvents: Equatable, Sendable {
        public var tokens: Int       // input + output du jour (parité notch Claude)
        public var costUSD: Double   // Σ usageBasedCosts (dépense usage-based réelle)
    }

    private static let eventsPageSize = 100
    private static let eventsPageCap = 20 // garde-fou (max 2000 events/jour)

    /// Dépense et tokens du jour (depuis minuit locale) via l'endpoint dashboard, paginé.
    /// `userId` (optionnel) : filtre défensif — l'endpoint est déjà scopé à l'utilisateur
    /// authentifié, mais si on connaît son id numérique on ne garde que ses events
    /// (`owningUser`), garantissant que le compteur ne reflète JAMAIS un autre membre.
    public func fetchTodayEvents(now: Date = Date(), userId: Int? = nil) async throws -> TodayEvents {
        let creds = try readCredentials()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let body: [String: Any] = [
            "startDate": Int(startOfDay.timeIntervalSince1970 * 1000),
            "endDate": Int(now.timeIntervalSince1970 * 1000),
        ]

        var events: [[String: Any]] = []
        var total = Int.max
        var page = 1
        while events.count < total, page <= Self.eventsPageCap {
            var pageBody = body
            pageBody["page"] = page
            pageBody["pageSize"] = Self.eventsPageSize
            let data = try await post("dashboard/get-filtered-usage-events", body: pageBody, creds: creds)
            let (pageEvents, pageTotal) = Self.decodePage(data)
            events.append(contentsOf: pageEvents)
            total = pageTotal
            if pageEvents.isEmpty { break } // plus rien à paginer (protège si total surestimé)
            page += 1
        }
        return Self.aggregateEvents(events, userId: userId)
    }

    // MARK: - Dépense de la team (cycle en cours)
    //
    // ⚠️ Un membre NON-admin ne peut PAS lire les events quotidiens des autres membres
    //    (`get-filtered-usage-events` est scopé à soi ; `adminOnlyUsagePricing` sur la team).
    //    Seul le total *cycle-de-facturation* par membre est lisible via `get-team-spend`.
    //    On expose donc la dépense team « ce cycle », pas « du jour ».

    public struct TeamSpend: Equatable, Sendable {
        public var cycleCostUSD: Double // Σ spendCents des membres / 100
        public var myUserId: Int?       // id numérique de l'utilisateur courant (par email)
    }

    /// Dépense totale de la team sur le cycle en cours (+ résout l'id numérique de l'user).
    /// `nil` si l'utilisateur n'appartient à aucune team.
    public func fetchTeamSpend() async throws -> TeamSpend? {
        let creds = try readCredentials()
        guard let teamId = try await fetchPrimaryTeamId(creds: creds) else { return nil }

        var members: [[String: Any]] = []
        var totalPages = 1
        var page = 1
        repeat {
            let data = try await post("dashboard/get-team-spend",
                                      body: ["teamId": teamId, "page": page], creds: creds)
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
            members.append(contentsOf: root["teamMemberSpend"] as? [[String: Any]] ?? [])
            totalPages = (root["totalPages"] as? NSNumber)?.intValue ?? 1
            page += 1
        } while page <= totalPages && page <= Self.eventsPageCap

        let cents = members.reduce(0.0) { sum, m in
            sum + ((m["spendCents"] as? NSNumber)?.doubleValue ?? 0)
        }
        let myUserId = creds.email.flatMap { email in
            members.first { ($0["email"] as? String)?.caseInsensitiveCompare(email) == .orderedSame }
        }.flatMap { ($0["userId"] as? NSNumber)?.intValue }
        return TeamSpend(cycleCostUSD: cents / 100, myUserId: myUserId)
    }

    /// Première team de l'utilisateur (`dashboard/teams`) → `id` numérique.
    private func fetchPrimaryTeamId(creds: Credentials) async throws -> Int? {
        let data = try await post("dashboard/teams", body: [:], creds: creds)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let teams = root["teams"] as? [[String: Any]] else { return nil }
        return teams.compactMap { ($0["id"] as? NSNumber)?.intValue }.first
    }

    // MARK: - Requête POST dashboard partagée (cookie WorkOS + en-têtes navigateur)

    private func post(_ path: String, body: [String: Any], creds: Credentials) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://cursor.com/api/\(path)")!)
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
        case 200: return data
        case 401, 403: throw UsageError.unauthorized
        case 429: throw UsageError.rateLimited(retryAfter: nil)
        default: throw UsageError.network("HTTP \(http.statusCode)")
        }
    }

    /// Extrait `(usageEventsDisplay, totalUsageEventsCount)` d'une page (pur, testable).
    nonisolated static func decodePage(_ data: Data) -> (events: [[String: Any]], total: Int) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], 0)
        }
        let events = root["usageEventsDisplay"] as? [[String: Any]] ?? []
        let total = (root["totalUsageEventsCount"] as? NSNumber)?.intValue
            ?? Int((root["totalUsageEventsCount"] as? String) ?? "") ?? events.count
        return (events, total)
    }

    /// Agrège tokens (input+output) et dépense (Σ usageBasedCosts) — pur, testable,
    /// tolérant aux nombres sérialisés en strings. Si `userId` est fourni, ne compte que
    /// les events dont `owningUser` correspond (garde-fou multi-membres).
    nonisolated static func aggregateEvents(_ events: [[String: Any]], userId: Int? = nil) -> TodayEvents {
        func int(_ any: Any?) -> Int {
            if let n = any as? NSNumber { return n.intValue }
            if let s = any as? String, let i = Int(s) { return i }
            return 0
        }
        var tokens = 0
        var costUSD = 0.0
        for event in events {
            if let userId, int(event["owningUser"]) != userId { continue }
            if let usage = event["tokenUsage"] as? [String: Any] {
                tokens += int(usage["inputTokens"]) + int(usage["outputTokens"])
            }
            costUSD += parseDollars(event["usageBasedCosts"])
        }
        return TodayEvents(tokens: tokens, costUSD: costUSD)
    }

    /// « $1.67 » / « $1,234.50 » / 1.67 → Double (0 si absent/illisible).
    nonisolated static func parseDollars(_ raw: Any?) -> Double {
        if let n = raw as? NSNumber { return n.doubleValue }
        guard let s = raw as? String else { return 0 }
        let cleaned = s.filter { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(cleaned) ?? 0
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
