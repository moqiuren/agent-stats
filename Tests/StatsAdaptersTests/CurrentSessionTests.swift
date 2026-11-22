@testable import StatsCore
@testable import StatsAdapters
import Foundation

enum CurrentSessionTests {
    static func main() {
        var checks = 0
        func check(_ result: Bool, _ message: String) { precondition(result, message); checks += 1 }
        func resolve(_ provider: String, _ urls: [String], _ window: String = "1:2") -> CurrentSession {
            CurrentSessionResolver.resolve(provider: provider, documentURLs: urls, window: window)
        }
        let a = "01a0fb3a-3ee5-7761-9292-5dc19fe74ab6", b = "01a0f554-4d4b-71b0-8e85-7aaa781256a3"
        check(resolve("kimi",["app://renderer/sessions/session_old"]).sessionID == "session_old", "idle old sessions follow their URL")
        check(resolve("kimi",["app://renderer/"]).state == .draft, "new Kimi conversations explicitly clear selection")
        check(resolve("kimi",["app://renderer/", "app://renderer/browser-overlay.html"]).state == .draft, "browser overlay is not a conversation")
        check(resolve("kimi",["app://renderer/browser-overlay.html", "app://renderer/sessions/session_old"]).sessionID == "session_old", "the attached browser overlay does not suppress the current Kimi session")
        check(resolve("kimi",["app://renderer/browser-overlay.html"]).state == .unsupported, "an overlay-only document cannot select a Kimi session")
        check(resolve("kimi",["app://renderer/sessions/session_old", "https://example.com/sessions/session_background"]).sessionID == "session_old", "external browser pages cannot supply IDs")
        check(resolve("kimi",["app://renderer/sessions/session_old", "app://renderer/sessions/session_new"]).state == .ambiguous, "conflicting documents never guess")
        check(resolve("kimi",["app://renderer/settings?session_id=session_old"]).sessionID == nil, "unrelated pages do not select a session")
        check(resolve("codex",["app://-/local/\(a)"]).sessionID == a, "Codex local route uses the exact UUID")
        check(resolve("codex",["app://-/local/\(b)?view=review"]).sessionID == b, "old Codex route works without new activity")
        check(resolve("codex",["app://-/local/\(a)?hostId=remote-host"]).state == .unsupported, "remote host IDs cannot match local logs")
        check(resolve("codex",["app://-/local/\(a)?hostId=local&hostId=remote-host"]).state == .unsupported, "duplicate host parameters cannot hide a remote host")
        check(resolve("codex",["app://-/remote/\(a)"]).state == .unsupported, "remote routes are unsupported")
        check(resolve("codex",["app://-/new"]).state == .draft, "explicit new route clears selection")
        check(resolve("codex",["app://-/local/client-new-thread:temporary"]).state == .draft, "pending new threads have no persisted statistics")
        check(resolve("codex",["app://-/"]).state == .routeUnavailable, "an unverified root document must not masquerade as a thread")
        check(resolve("codex",["app://-/local/not-a-uuid"]).sessionID == nil, "invalid IDs are rejected")
        let initial = "app://-/index.html?initialRoute=%2Flocal%2F\(a)"
        check(resolve("codex",[initial]).state == .routeUnavailable, "actual Codex loader URL is not a live route")
        check(resolve("codex",[initial]).sessionID == nil, "a startup thread ID must not masquerade as the current thread")
        check(resolve("codex",["app://-/index.html#/local/\(a)"]).sessionID == nil, "fixed-document fragments are not verified live routes")
        check(resolve("codex",["https://example.com/local/\(a)"]).sessionID == nil, "a browser page cannot spoof a native route")
        check(resolve("codex",["app://-/local/\(a)","app://-/local/\(b)"]).state == .ambiguous, "multiple visible documents fail closed")
        check(resolve("codex",["app://-/local/\(a)","app://-/local/\(a)"]).sessionID == a, "duplicate metadata agrees")
        for provider in ["codex","kimi"] {
            check(resolve(provider,[]).sessionID == nil, "disconnected metadata never reuses an ID")
            let expected: SessionSelectionMode = provider == "kimi" ? .automatic : .recent
            check(SessionSelectionMode.resolve("__current__",provider:provider) == expected, "native following is explicit only where the host exposes a live route")
            check(SessionSelectionMode.resolve("__recent__",provider:provider) == .recent, "recent activity remains an explicit alternative")
            check(SessionSelectionMode.resolve("manual-id",provider:provider) == .manual("manual-id"), "manual selection remains independent")
        }
        check(SessionSelectionMode.resolve(nil,provider:"codex") == .recent, "existing Codex preferences do not silently change")
        check(SessionSelectionMode.resolve(nil,provider:"kimi") == .automatic, "existing Kimi bridge remains until replacement is verified")
        check(CurrentSession(.permissionRequired,window:"1:2").json["known"] as? Bool == false, "permission loss is unknown")
        check(resolve("kimi",["app://renderer/sessions/session_old"],"2:3").windowToken == "2:3", "selection carries window identity")
        let window=HostWindowReference(pid:1,number:2,bounds:CGRect(x:0,y:0,width:900,height:650))
        let unavailable=CurrentSession(.unsupported,window:window.token).json
        let bridge:JSONObject=["status":"connected","known":true,"sessionId":"session_bridge","updatedAt":2000.0,"focused":true,"visible":true]
        func automatic(_ native:JSONObject,_ bridge:JSONObject,_ windows:Int=1,_ changed:Double=1000)->JSONObject {
            AutomaticSessionSelection.resolve(provider:"kimi",native:native,bridge:bridge,window:window,hostWindowCount:windows,windowChangedAt:changed)
        }
        check(automatic(unavailable,bridge)["sessionId"] as? String == "session_bridge", "single-window auto mode can use a fresh focused page bridge")
        check(automatic(CurrentSession(.current,id:"session_native",window:window.token).json,bridge)["sessionId"] as? String == "session_native", "native identity takes priority")
        check(automatic(CurrentSession(.draft,window:window.token).json,bridge)["sessionId"] is NSNull, "a native draft never falls back to an old conversation")
        check(automatic(unavailable,bridge,2)["known"] as? Bool == false, "a bridge without window identity cannot guess across multiple windows")
        check(automatic(unavailable,bridge,1,3000)["known"] as? Bool == false, "a bridge event from the previous window is rejected")
        check(automatic(unavailable,bridge,1,2000)["known"] as? Bool == false, "a same-millisecond bridge heartbeat may predate the window switch and never selects")
        var background=bridge;background["focused"]=false
        check(automatic(unavailable,background)["known"] as? Bool == false, "background renderers cannot select a conversation")
        check(automatic(CurrentSession(.ambiguous,window:window.token).json,bridge)["known"] as? Bool == false, "conflicting native observations do not select a fallback")
        check(AutomaticSessionSelection.resolve(provider:"codex",native:unavailable,bridge:bridge,window:window,hostWindowCount:1,windowChangedAt:0)["known"] as? Bool == false, "Codex never consumes Kimi bridge state")
        print("\(checks) current-session routing checks passed")
    }
}
