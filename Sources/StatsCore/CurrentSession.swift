import CoreGraphics
import Foundation

package struct HostWindowReference: Equatable {
  package let pid: Int32
  package let number: UInt32
  package let bounds: CGRect  // Core Graphics / Accessibility screen coordinates (top-left origin).
  package var token: String { "\(pid):\(number)" }
  package init(pid: Int32, number: UInt32, bounds: CGRect) {
    self.pid = pid
    self.number = number
    self.bounds = bounds
  }
}

package struct CurrentSession: Equatable {
  package enum State: String {
    case current, draft, unknown, permissionRequired, hostUnavailable, disabled, unsupported,
      ambiguous, routeUnavailable
  }
  package let state: State
  package let sessionID: String?
  package let windowToken: String?
  package init(_ state: State, id: String? = nil, window: String? = nil) {
    self.state = state
    sessionID = id
    windowToken = window
  }
  package init(json: JSONObject) {
    let id = json["sessionId"] as? String
    if json["status"] as? String == "connected", json["known"] as? Bool == true {
      self.init(id == nil ? .draft : .current, id: id, window: json["windowToken"] as? String)
    } else {
      let reason = State(rawValue: json["reason"] as? String ?? "") ?? .unknown
      self.init(
        reason == .current || reason == .draft ? .unknown : reason,
        window: json["windowToken"] as? String)
    }
  }
  package var isKnown: Bool { state == .current || state == .draft }
  package var json: JSONObject {
    [
      "status": state == .current || state == .draft ? "connected" : "waiting",
      "reason": state.rawValue, "known": state == .current || state == .draft,
      "sessionId": nullable(sessionID), "windowToken": nullable(windowToken),
      "source": "accessibility",
    ]
  }
}

package enum SessionSelectionMode: Equatable {
  case automatic, recent
  case manual(String)
  case project(String)
  case agent(String)
  package static func resolve(_ selection: String?, provider: String) -> SessionSelectionMode {
    let supported = StatsProvider(rawValue: provider)?.supportsAutomaticSessionFollow ?? false
    // A tool without automatic following never resolves to it, even if an older
    // preference still stores "__current__".
    if selection == "__current__" { return supported ? .automatic : .recent }
    if selection == "__recent__" { return .recent }
    if selection == "__bridge__" && provider == "kimi" { return .automatic }
    if let selection, selection.hasPrefix("__project__:") {
      return .project(String(selection.dropFirst("__project__:".count)))
    }
    if let selection, selection.hasPrefix("__agent__:") {
      return .agent(String(selection.dropFirst("__agent__:".count)))
    }
    if let selection { return .manual(selection) }
    return supported ? .automatic : .recent
  }
  package var storedValue: String {
    switch self {
    case .automatic: return "__current__"
    case .recent: return "__recent__"
    case .manual(let id): return id
    case .project(let id): return "__project__:" + id
    case .agent(let id): return "__agent__:" + id
    }
  }
}

package struct PageSessionSelection {
  package enum Status: String {
    case connected, waiting, disabled, error
    case notInstalled = "not_installed"
  }
  package let status: Status
  package let known: Bool
  package let sessionID: String?
  package let updatedAt: Double
  package let focused: Bool
  package let visible: Bool
  private let values: JSONObject

  package init(_ value: JSONObject = ["status": "waiting"]) {
    values = value
    status = Status(rawValue: value["status"] as? String ?? "") ?? .waiting
    known = value["known"] as? Bool == true
    sessionID = value["sessionId"] as? String
    updatedAt = number(value["updatedAt"]) ?? 0
    focused = value["focused"] as? Bool == true
    visible = value["visible"] as? Bool == true
  }
  package var json: JSONObject { values }
}

package struct SessionSelectionEvidence {
  package enum Source { case accessibility, pageBridge }
  package let selection: CurrentSession
  package let source: Source
  package init(selection: CurrentSession, source: Source) {
    self.selection = selection
    self.source = source
  }
}

package enum AutomaticSessionSelection {
  package static func resolve(
    provider: String, native: CurrentSession, bridge: PageSessionSelection,
    window: HostWindowReference?, hostWindowCount: Int,
    windowChangedAt: Double
  ) -> SessionSelectionEvidence {
    let primary = SessionSelectionEvidence(selection: native, source: .accessibility)
    guard provider == "kimi", !native.isKnown, native.state != .ambiguous else { return primary }
    // Strictly later than the window switch: a heartbeat carrying the same
    // millisecond stamp may still describe the previous window's conversation.
    guard let window, hostWindowCount == 1, bridge.status == .connected, bridge.known,
      bridge.focused, bridge.visible, bridge.updatedAt > windowChangedAt
    else { return primary }
    return SessionSelectionEvidence(
      selection: CurrentSession(
        bridge.sessionID == nil ? .draft : .current,
        id: bridge.sessionID, window: window.token), source: .pageBridge)
  }

  // JSON is retained at compatibility/test boundaries; both callers share the
  // same typed policy for native priority and fresh single-window fallback.
  package static func resolve(
    provider: String, native: JSONObject, bridge: JSONObject,
    window: HostWindowReference?, hostWindowCount: Int,
    windowChangedAt: Double
  ) -> JSONObject {
    let evidence = resolve(
      provider: provider, native: CurrentSession(json: native),
      bridge: PageSessionSelection(bridge),
      window: window, hostWindowCount: hostWindowCount, windowChangedAt: windowChangedAt)
    guard evidence.source == .pageBridge else { return native }
    var result = bridge
    result["source"] = "page_bridge"
    result["windowToken"] = window?.token
    return result
  }
}
