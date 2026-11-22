import Foundation
import StatsCore

enum CurrentSessionResolver {
    static func resolve(provider: String, documentURLs: [String], window: String) -> CurrentSession {
        let candidates = documentURLs.compactMap { route(provider: provider, rawURL: $0, window: window) }
        guard let first = candidates.first else { return CurrentSession(.unsupported, window: window) }
        guard candidates.allSatisfy({ $0 == first }) else { return CurrentSession(.ambiguous, window: window) }
        return first
    }
    private static func route(provider: String, rawURL: String, window: String) -> CurrentSession? {
        guard let url = URLComponents(string: rawURL), url.scheme == "app", url.user == nil, url.password == nil, url.port == nil else { return nil }
        let path = url.path.split(separator: "/").map(String.init)
        if provider == "kimi" {
            guard url.host == "renderer" else { return nil }
            if path.isEmpty { return CurrentSession(.draft, window: window) }
            guard path.count == 2, path[0] == "sessions", path[1].range(of: "^session_[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil else { return nil }
            return CurrentSession(.current, id: path[1], window: window)
        }
        guard provider == "codex", url.host == "-" else { return nil }
        // Codex currently loads a fixed document and navigates with a memory router.
        // initialRoute (and fragments on that document) can be stale after switching
        // chats. Never promote a startup URL into a live selected-session signal.
        if path.isEmpty || path == ["index.html"] || path == ["detached-window.html"] {
            return CurrentSession(.routeUnavailable, window: window)
        }
        // A remote host can use the same UUID namespace. Never map it into local logs.
        if url.queryItems?.contains(where: { $0.name == "hostId" && $0.value != "local" }) == true { return nil }
        if path == ["new"] || path == ["hotkey-window", "new-thread"] { return CurrentSession(.draft, window: window) }
        let id: String
        if path.count == 2 && path[0] == "local" { id = path[1] }
        else if path.count == 3 && path[0] == "hotkey-window" && path[1] == "thread" { id = path[2] }
        else { return nil }
        if id.hasPrefix("client-new-thread:") { return CurrentSession(.draft, window: window) }
        guard UUID(uuidString: id) != nil else { return nil }
        return CurrentSession(.current, id: id.lowercased(), window: window)
    }
}

