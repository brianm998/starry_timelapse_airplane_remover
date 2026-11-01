import Foundation

/// Where the daemon is and how to talk to it: `~/.star-pipeline/api.token` and `api_port` from `config.toml`
/// (47231 by default). STARPIPE_HOME and STARPIPE_API_PORT override, like the CLI.
public struct APIConfig: Sendable, Equatable {
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    public enum LoadError: Error, Equatable, LocalizedError {
        case noToken(String)

        public var errorDescription: String? {
            switch self {
            case .noToken(let path): "No API token at \(path): the daemon has never run."
            }
        }
    }

    public static func home(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["STARPIPE_HOME"], !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".star-pipeline")
    }

    public static func port(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        if let raw = environment["STARPIPE_API_PORT"], let value = Int(raw) { return value }
        let file = home.appendingPathComponent("config.toml")
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, parts[0] == "api_port", let value = Int(parts[1]) { return value }
            }
        }
        return 47231
    }

    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> APIConfig {
        let home = home(environment: environment)
        let tokenFile = home.appendingPathComponent("api.token")
        guard let raw = try? String(contentsOf: tokenFile, encoding: .utf8) else {
            throw LoadError.noToken(tokenFile.path)
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw LoadError.noToken(tokenFile.path) }
        return APIConfig(baseURL: URL(string: "http://127.0.0.1:\(port(home: home, environment: environment))")!, token: token)
    }
}

public enum APIError: Error, Equatable, LocalizedError {
    case status(Int, String)
    case daemonDown(String)

    public var errorDescription: String? {
        switch self {
        case .status(let code, let body): "The daemon answered \(code): \(body)"
        case .daemonDown(let why): "The daemon is not answering: \(why)"
        }
    }
}

/// The monitor's only way to read or change anything: the same /v1 endpoints the CLI uses.
public struct APIClient: Sendable {
    public var config: APIConfig
    private let session: URLSession

    public init(config: APIConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval = 10) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: config.baseURL) else { throw APIError.daemonDown("bad path \(path)") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.daemonDown("no HTTP response") }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.status(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            return data
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.daemonDown(error.localizedDescription)
        }
    }

    public func snapshot() async throws -> Snapshot {
        try JSONDecoder().decode(Snapshot.self, from: try await send(request("/v1/snapshot")))
    }

    public func detail(_ number: Int) async throws -> TicketDetail {
        try JSONDecoder().decode(TicketDetail.self, from: try await send(request("/v1/tickets/\(number)")))
    }

    public func log(_ number: Int, lines: Int = 60) async throws -> [String] {
        struct Tail: Decodable { var lines: [String] }
        return try JSONDecoder().decode(Tail.self, from: try await send(request("/v1/tickets/\(number)/log?lines=\(lines)"))).lines
    }

    public func post(_ path: String, body: [String: Any] = [:]) async throws {
        _ = try await send(request(path, method: "POST", body: body))
    }

    /// Query-value characters: `urlQueryAllowed` keeps `&`, `=`, `+`, `#` and `?`, which would cut the value short.
    static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#?")
        return set
    }()

    /// Resolve an issue link to its number and title; a rejection (another repo, a PR, closed) is `.status(4xx, reason)`.
    public func resolve(url: String) async throws -> ResolvedIssue {
        let value = url.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? ""
        return try JSONDecoder().decode(ResolvedIssue.self, from: try await send(request("/v1/issues/resolve?url=\(value)", timeout: 30)))
    }

    /// Label these issues `pipeline` so the daemon's next intake poll queues them, first writing the per-stage
    /// `models` choices (stage → model, defaults already dropped) into each issue's `## Pipeline` section.
    public func enqueue(numbers: [Int], models: [String: String] = [:]) async throws -> [EnqueueResult] {
        struct Results: Decodable { var results: [EnqueueResult] }
        let body = EnqueueRequest.body(numbers: numbers, choices: models)
        let data = try await send(request("/v1/enqueue", method: "POST", body: body, timeout: 60))
        return try JSONDecoder().decode(Results.self, from: data).results
    }

    public func answer(_ number: Int, text: String) async throws { try await post("/v1/tickets/\(number)/answer", body: ["text": text]) }
    public func retry(_ number: Int, stage: String) async throws { try await post("/v1/tickets/\(number)/retry", body: ["stage": stage]) }
    public func cancel(_ number: Int, reason: String) async throws { try await post("/v1/tickets/\(number)/cancel", body: ["reason": reason]) }
    public func setPriority(_ number: Int, _ priority: Int) async throws { try await post("/v1/tickets/\(number)/prio", body: ["priority": priority]) }
    public func landNow(_ number: Int) async throws { try await post("/v1/tickets/\(number)/land-now") }
    public func setMaxActive(_ n: Int) async throws { try await post("/v1/settings", body: ["max_active": n]) }

    /// The server-sent event stream, from `after`. Ends (throwing) when the connection drops; the caller reconnects.
    public func events(after: Int) -> AsyncThrowingStream<ServerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = try request("/v1/events?after=\(after)", timeout: 3600)
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: req)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.daemonDown("event stream refused") }
                    var parser = SSEParser()
                    for try await line in bytes.lines {
                        if let event = parser.feed(line: line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Parses `id:` / `data:` / blank-line framing into events; comment lines (keepalives) are ignored.
public struct SSEParser: Sendable {
    private var id: Int?
    private var data: String?

    public init() {}

    public mutating func feed(line: String) -> ServerEvent? {
        if line.isEmpty {
            defer { id = nil; data = nil }
            guard let data, let event = Self.decode(data) else { return nil }
            return event
        }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("id:") { id = Int(line.dropFirst(3).trimmingCharacters(in: .whitespaces)) }
        if line.hasPrefix("data:") {
            let chunk = String(line.dropFirst(5).drop(while: { $0 == " " }))
            data = (data.map { $0 + "\n" } ?? "") + chunk
        }
        return nil
    }

    static func decode(_ text: String) -> ServerEvent? {
        guard let raw = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let id = raw["id"] as? Int, let kind = raw["kind"] as? String else { return nil }
        var fields: [String: String] = [:]
        for (key, value) in (raw["data"] as? [String: Any]) ?? [:] {
            fields[key] = value is NSNull ? "" : "\(value)"
        }
        return ServerEvent(id: id, ticket: raw["ticket"] as? Int, kind: kind, data: fields, at: (raw["at"] as? Double) ?? 0)
    }
}
