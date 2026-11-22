@testable import StatsCore
import Foundation

enum StatsStateTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let stamp = Date(timeIntervalSince1970: 100)
        let window = HostWindowReference(pid: 1, number: 2, bounds: CGRect(x: 0, y: 0, width: 900, height: 650))
        let other = HostWindowReference(pid: 1, number: 3, bounds: window.bounds)
        let zero = StatsRecord(["totalTokens": 0, "tps": true, "toolMs": NSNull(), "lastTurn": ["ttftMs": 0], "title": " A\n B "])
        check(zero.value(.totalTokens) == 0 && zero.values["totalTokens"] is Int, "native zero remains an Int at the source boundary")
        check(zero.value(.tps) == nil && zero.value(.toolMs) == nil && zero.value(.input) == nil, "Boolean, null and absent metrics stay unknown")
        check(zero.lastTurn?.value(.ttftMs) == 0 && zero.title == "A B", "zero timing and normalized titles retain their meaning")
        check(StatsRecord(["totalMs": Double.infinity]).value(.totalMs) == nil, "nonfinite values cannot reach numeric presentation")

        let collected = StatsSnapshot(provider: .kimi, collectedAt: 100000, sessions: [SessionSnapshot([
            "id": "typed", "title": "Typed", "totalTokens": 0,
            "lastTurn": ["ttftMs": 0], "output": NSNull()
        ])])
        let typedUpdate = StatsUpdate(snapshot: collected)
        let typedState = StatsState(provider: .kimi)
        check(typedState.receive(typedUpdate, generation: typedState.generation), "native typed collections are accepted")
        let typedRecord = typedState.resolve(.manual("typed")).record
        check(typedRecord?.values["totalTokens"] is Int && typedRecord?.value(.totalTokens) == 0,
              "the complete collector-to-state path preserves native integer zero")
        check(typedRecord?.lastTurn?.values["ttftMs"] is Int && typedRecord?.value(.output) == nil,
              "typed collection keeps nested native values and unknowns in presentation")
        typedState.switchProvider(.codex)
        check(!typedState.receive(typedUpdate, generation: typedState.generation),
              "a typed snapshot cannot be relabelled with the active provider")

        for provider in StatsProvider.allCases {
            let selections: [SessionSelectionMode] = [.automatic, .recent, .manual("session_old"), .manual("__task__:scoped"), .project("p"), .agent("worker")]
            for selection in selections {
                // A tool whose host exposes no live route cannot store automatic
                // following: it resolves to recent instead of an unavailable mode.
                let expected = selection == .automatic && !provider.supportsAutomaticSessionFollow
                    ? SessionSelectionMode.recent : selection
                check(SessionSelectionMode.resolve(selection.storedValue, provider: provider.rawValue) == expected,
                      "selection persistence is unchanged for every target and provider")
            }
        }
        check(!StatsProvider.codex.supportsAutomaticSessionFollow && StatsProvider.kimi.supportsAutomaticSessionFollow,
              "only the host with a live route advertises automatic following")
        check(SessionSelectionMode.resolve("__bridge__", provider: "kimi") == .automatic, "legacy Kimi bridge preferences still follow automatically")
        check(SessionSelectionMode.resolve("__bridge__", provider: "codex") == .manual("__bridge__"), "legacy Kimi IDs do not leak into other providers")
        check(SessionSelectionMode.resolve(nil, provider: "kimi") == .automatic, "provider-specific defaults are retained")

        let state = StatsState(provider: .codex)
        let originalGeneration = state.generation
        check(state.resolve(.recent).placeholder == .loading, "unread catalogs show loading")
        state.observeWindow(window, now: stamp)
        let snapshot: JSONObject = ["sessions": [
            ["id": "recent", "title": "Recent", "totalTokens": 999, "group": ["id": "navigation", "title": "Named project"]],
            ["id": "old", "title": "Old", "totalTokens": 0, "project": ["id": "accounting", "title": "Billing bucket"]]],
            "agents": [["id": "agent-row", "key": "worker", "totalTokens": 12]],
            "projects": [["id": "__project__:accounting", "totalTokens": 24]],
            "sessionGroups": [["id": "navigation", "title": "Named project"]]]
        let catalog = StatsUpdate(provider: .codex, snapshot: snapshot)
        check(state.receive(catalog, generation: originalGeneration, now: stamp), "the current collector can replace its catalog")
        state.receive(StatsUpdate(provider: .codex, nativeSelection: CurrentSession(.current, id: "old", window: window.token)), generation: originalGeneration)
        check(state.resolve(.automatic).record?.id == "old" && state.current?.value(.totalTokens) == 0, "automatic selection keeps an idle session and zero metrics")
        check(state.resolve(.recent).record?.id == "recent", "recent activity is an explicit independent target")
        check(state.resolve(.manual("missing")).record == nil, "a missing manual session never falls back")
        check(state.resolve(.agent("worker")).record?.value(.totalTokens) == 12, "agent selections use the accounting key")
        check(state.resolve(.project("accounting")).record?.value(.totalTokens) == 24, "project totals use their own namespace")
        check(state.navigationGroups.map(\.id) == ["navigation", "ungrouped"], "accounting buckets never become navigation projects")
        check(state.conversations(in: "navigation").map(\.id) == ["recent"], "project browsing uses explicit navigation membership")

        let readAt = state.lastReceived
        state.receive(StatsUpdate(provider: .codex, nativeSelection: CurrentSession(.draft, window: window.token)), generation: originalGeneration)
        check(state.resolve(.automatic).record == nil && state.resolve(.automatic).placeholder == .draft, "a blank native page clears old measurements")
        check(state.catalog.sessions.count == 2 && state.lastReceived == readAt, "selection-only updates do not replace or mark catalogs as freshly read")
        state.observeWindow(other, now: stamp.addingTimeInterval(1))
        state.receive(StatsUpdate(provider: .codex, nativeSelection: CurrentSession(.current, id: "old", window: window.token)), generation: originalGeneration)
        check(state.resolve(.automatic).record == nil && state.nativeSelection.windowToken == other.token, "late native results from the previous window are discarded")
        state.receive(StatsUpdate(provider: .codex, nativeSelection: CurrentSession(.routeUnavailable, window: other.token)), generation: originalGeneration)
        check(!state.canFollowCurrentConversation && state.resolve(.automatic).placeholder == .routeUnavailable, "an unavailable route is explicit in presentation and settings")

        state.switchProvider(.kimi, now: stamp)
        let kimiGeneration = state.generation
        check(state.current == nil && state.catalog.sessions.isEmpty && state.observedWindow == nil, "provider changes reset measurements and window selection together")
        check(!state.receive(catalog, generation: originalGeneration), "old provider generations are rejected")
        check(!state.receive(catalog, generation: kimiGeneration), "provider identity is checked independently from generation")
        state.observeWindow(window, now: stamp); state.hostWindowCount = 1
        let bridge = PageSessionSelection(["status": "connected", "known": true, "sessionId": "session_old", "focused": true, "visible": true, "updatedAt": 101000])
        let kimiSnapshot: JSONObject = ["sessions": [["id": "session_old", "sessionID": "session_old", "totalTokens": 10]]]
        state.receive(StatsUpdate(provider: .kimi, snapshot: kimiSnapshot, pageSelection: bridge), generation: kimiGeneration)
        check(state.resolve(.automatic).record?.id == "session_old", "a fresh focused single-window bridge can provide fallback")
        state.receive(StatsUpdate(provider: .kimi, nativeSelection: CurrentSession(.draft, window: window.token)), generation: kimiGeneration)
        check(state.resolve(.automatic).placeholder == .draft && state.current == nil, "native draft remains authoritative over the bridge")
        state.nativeSelection = CurrentSession(.ambiguous, window: window.token)
        check(state.resolve(.automatic).record == nil, "ambiguous native windows never use bridge fallback")
        state.nativeSelection = CurrentSession(.unknown, window: window.token); state.hostWindowCount = 2
        check(state.resolve(.automatic).record == nil, "the bridge cannot choose across multiple host windows")
        state.hostWindowCount = 1; state.observeWindow(other, now: stamp.addingTimeInterval(2))
        check(state.resolve(.automatic).record == nil, "bridge evidence predating the window switch is rejected")
        state.receive(StatsUpdate(provider: .kimi, snapshot: ["sessions": [["id": "a", "sessionID": "duplicate"], ["id": "b", "sessionID": "duplicate"]]]), generation: kimiGeneration)
        state.receive(StatsUpdate(provider: .kimi, nativeSelection: CurrentSession(.current, id: "duplicate", window: other.token)), generation: kimiGeneration)
        check(state.resolve(.automatic).record == nil, "duplicate session IDs across workspaces never choose arbitrarily")

        state.receive(StatsUpdate(provider: .kimi, snapshot: ["error": "unavailable"]), generation: kimiGeneration, now: stamp)
        check(state.catalog.sessions.isEmpty && state.current == nil && state.error == "unavailable", "read failures clear stale data")
        check(state.resolve(.recent).placeholder == .readError, "read failures remain distinct from empty catalogs")
        state.receive(StatsUpdate(provider: .kimi, snapshot: ["sessions": [] as [JSONObject]]), generation: kimiGeneration, now: stamp)
        check(state.error == nil && state.resolve(.recent).placeholder == .empty, "successful empty reads recover from a failure without fabricating data")
        state.switchProvider(.codex)
        check(!state.receive(catalog, generation: originalGeneration), "switching back cannot revive a previous generation of the same provider")
        check(StatsUpdate(json: ["provider": "unknown", "sessions": []], defaultProvider: .codex) == nil, "unknown providers fail closed at the compatibility boundary")
        print("\(checks) typed statistics state checks passed")
    }
}
