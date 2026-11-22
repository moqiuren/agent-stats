@testable import StatsCore
@testable import StatsAdapters
import Foundation
import ApplicationServices

// Electron 43.1.1's AtomApplication.accessibilityRole enables native AX lazily.
// Exercise the real reader, including the application -> window -> document
// call sequence. No real host, permission database or conversation is accessed.
private final class LazyHost {
    let pid: Int32
    let app: AXUIElement
    let main: AXUIElement
    let web: AXUIElement
    let companion: AXUIElement
    let picker: AXUIElement
    let reference: HostWindowReference
    var primed = false
    var documentReady = true
    var roleAvailable = true
    var focused = true
    var hasSheet = false
    var modal = false
    var mainDocument: String
    var companionDocument: String?
    var calls = [(String, String)]()

    init(pid: Int32 = 91000, document: String) {
        self.pid = pid; mainDocument = document
        app = AXUIElementCreateApplication(pid)
        main = AXUIElementCreateApplication(pid + 1)
        web = AXUIElementCreateApplication(pid + 2)
        companion = AXUIElementCreateApplication(pid + 3)
        picker = AXUIElementCreateApplication(pid + 4)
        reference = HostWindowReference(pid: pid, number: 10, bounds: CGRect(x: 100, y: 100, width: 900, height: 650))
    }

    func read(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        let node = CFEqual(element, app) ? "app" : CFEqual(element, main) ? "main" :
            CFEqual(element, web) ? "web" : CFEqual(element, companion) ? "companion" : "picker"
        calls.append((node, key))
        switch (node, key) {
        case ("app", kAXRoleAttribute):
            guard roleAvailable else { return nil }
            primed = true; return "AXApplication" as NSString
        case ("app", kAXMainWindowAttribute): return main
        case ("app", kAXFocusedWindowAttribute): return focused ? main : picker
        case ("app", kAXWindowsAttribute): return [main] as NSArray
        case ("main", kAXRoleAttribute): return "AXWindow" as NSString
        case ("main", kAXSubroleAttribute): return "AXStandardWindow" as NSString
        case ("main", kAXMainAttribute): return kCFBooleanTrue
        case ("main", kAXModalAttribute): return modal ? kCFBooleanTrue : kCFBooleanFalse
        case ("main", kAXMinimizedAttribute): return kCFBooleanFalse
        case ("main", kAXPositionAttribute):
            var point = reference.bounds.origin; return AXValueCreate(.cgPoint, &point)
        case ("main", kAXSizeAttribute):
            var size = reference.bounds.size; return AXValueCreate(.cgSize, &size)
        case ("main", "AXSheets"): return (hasSheet ? [picker] : []) as NSArray
        case ("main", kAXChildrenAttribute):
            guard primed && documentReady else { return [] as NSArray }
            return (companionDocument == nil ? [web] : [web, companion]) as NSArray
        case ("web", kAXRoleAttribute), ("companion", kAXRoleAttribute): return "AXWebArea" as NSString
        case ("web", kAXURLAttribute): return mainDocument as NSString
        case ("companion", kAXURLAttribute): return companionDocument as NSString?
        case ("picker", kAXRoleAttribute): return "AXSheet" as NSString
        default: preconditionFailure("Unexpected AX read: \(node).\(key)")
        }
    }
}

enum HostAccessibilityTests {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        for (provider, document, state) in [
            ("kimi", "app://renderer/", CurrentSession.State.draft),
            ("codex", "app://-/index.html", .routeUnavailable),
        ] {
            let host = LazyHost(document: document)
            let reader = HostAccessibility(authorized: { true }, attribute: host.read)
            let proof = reader.mainWindow(provider: provider, windows: [host.reference], requireFocused: true)
            check(proof?.number == 10 && proof?.focusConfirmed == true, "A cold \(provider) host must initialize native AX before scanning its document")
            check(host.calls.first?.0 == "app" && host.calls.first?.1 == kAXRoleAttribute, "Application role is read before window traversal")
            host.primed = false; host.calls = []
            check(reader.read(provider: provider, window: host.reference).state == state, "Current-session reads also initialize a cold host")
            check(host.calls.first?.0 == "app" && host.calls.first?.1 == kAXRoleAttribute, "Session reads must not depend on another AX client")
        }

        let host = LazyHost(document: "app://renderer/sessions/session_test")
        let reader = HostAccessibility(authorized: { true }, attribute: host.read)
        func verify() -> HUDHostVerification? { reader.mainWindow(provider: "kimi", windows: [host.reference], requireFocused: true) }
        host.documentReady = false
        check(verify() == nil, "Priming is not proof: an asynchronously unavailable document stays hidden")
        host.documentReady = true
        check(verify()?.number == 10, "A later poll recovers after the renderer publishes its document")
        host.primed = false; host.roleAvailable = false
        check(verify() == nil, "Failed activation cannot substitute for a main document")
        host.roleAvailable = true
        check(verify()?.number == 10, "A transient application-role failure is retried")
        host.companionDocument = "app://renderer/browser-overlay.html"
        check(verify()?.number == 10, "Kimi's known companion document remains supported")
        host.hasSheet = true
        check(verify() == nil, "Priming must never override a file-picker sheet")
        host.hasSheet = false; host.modal = true
        check(verify() == nil, "Priming must never override modality")
        host.modal = false; host.focused = false
        check(verify() == nil, "Priming must never override focus on another window")
        host.focused = true; host.companionDocument = "https://example.com/"
        check(verify() == nil, "Unknown companion documents still fail closed")
        host.companionDocument = nil; host.mainDocument = "app://renderer/browser-overlay.html"
        check(verify() == nil, "A companion document alone cannot become the primary window")
        check(host.calls.allSatisfy { ![kAXTitleAttribute, kAXValueAttribute, kAXFocusedUIElementAttribute].contains($0.1) }, "No title, input, or conversation content is read")
        check(!host.calls.contains { ["web", "companion"].contains($0.0) && $0.1 == kAXChildrenAttribute }, "Document bodies are never traversed")

        var permitted = false
        let protected = LazyHost(pid: 92000, document: "app://renderer/")
        let permissionReader = HostAccessibility(authorized: { permitted }, attribute: protected.read)
        check(permissionReader.mainWindow(provider: "kimi", windows: [protected.reference], requireFocused: true) == nil, "No permission means no window proof")
        check(permissionReader.read(provider: "kimi", window: protected.reference).state == .permissionRequired, "Session reads report missing permission")
        check(protected.calls.isEmpty, "Application role is never queried before permission is granted")
        permitted = true
        check(permissionReader.mainWindow(provider: "kimi", windows: [protected.reference], requireFocused: true)?.number == 10, "Existing readers recover after authorization")
        let replacement = LazyHost(pid: 93000, document: "app://renderer/")
        var active = protected
        let reused = HostAccessibility(authorized: { true }, attribute: { active.read($0, $1) })
        _ = reused.mainWindow(provider: "kimi", windows: [protected.reference], requireFocused: true)
        active = replacement
        check(reused.mainWindow(provider: "kimi", windows: [replacement.reference], requireFocused: true)?.number == 10, "A restarted host is initialized independently of the previous PID")
        print("Host accessibility: \(checks) checks passed")
    }
}
