import Foundation

// Keep original native values at the input boundary. No JSON round trip or
// blanket numeric coercion is needed to present Int, Double, zero or unknown.
package struct StatsRecord {
  package let values: JSONObject
  package init(_ values: JSONObject) { self.values = values }
  package var id: String? { values["id"] as? String }
  package var sessionID: String? { values["sessionID"] as? String }
  package var agentKey: String { identifier(values["key"]) }
  package var title: String { SessionTitle.resolved(values["title"], id: id ?? "") }
  package var model: String? { values["model"] as? String }
  package var archived: Bool { values["archived"] as? Bool == true }
  package var partial: Bool { values["partial"] as? Bool == true }
  package var group: StatsGroup? { StatsGroup(jsonObject(values["group"])) }
  package var groupID: String {
    jsonObject(values["group"])["id"] as? String ?? StatsGroup.ungroupedID
  }
  package var lastTurn: StatsRecord? { (values["lastTurn"] as? JSONObject).map(StatsRecord.init) }

  package func value(_ metric: StatsMetric) -> Double? { number(values[metric.rawValue]) }
}

package enum StatsMetric: String {
  case input, cacheRead, cacheWrite, output, totalTokens, cacheHit, sharedHistoryTokens,
    observedRequestTokens
  case tps, avgTtftMs, avgTurnMs, ttftMs, durationMs, totalMs, toolMs, modelMs, decodeMs,
    reasoningMs, llmMs, firstTokenWaitMs
  case contextTokens
}

package struct StatsGroup: Equatable {
  package static let ungroupedID = "ungrouped"
  package let id: String
  package let title: String
  package init?(_ value: JSONObject) {
    guard let id = value["id"] as? String, let title = SessionTitle.nonempty(value["title"]) else {
      return nil
    }
    self.id = id
    self.title = title
  }
  package static let ungrouped = StatsGroup(["id": ungroupedID, "title": "未分组"])!
  package var json: JSONObject { ["id": id, "title": title] }
}

package struct StatsCatalog {
  package var sessions = [StatsRecord]()
  package var projects = [StatsRecord]()
  package var agents = [StatsRecord]()
  package var groups = [StatsGroup]()

  package init() {}
  package init(_ snapshot: StatsSnapshot) {
    // Existing AppKit presentation keeps native values, without JSON encoding.
    sessions = snapshot.sessions.map { StatsRecord($0.legacyJSON) }
    projects = snapshot.projects.map { StatsRecord($0.legacyJSON) }
    agents = snapshot.agents.map { StatsRecord($0.legacyJSON) }
    groups = snapshot.groups.compactMap { StatsGroup($0.legacyJSON) }
  }
  package init(_ value: JSONObject) {
    sessions = (value["sessions"] as? [JSONObject] ?? []).map(StatsRecord.init)
    projects = (value["projects"] as? [JSONObject] ?? []).map(StatsRecord.init)
    agents = (value["agents"] as? [JSONObject] ?? []).map(StatsRecord.init)
    groups = (value["sessionGroups"] as? [JSONObject] ?? []).compactMap(StatsGroup.init)
  }
}

package struct StatsUpdate {
  package enum CatalogChange {
    case unchanged
    case replace(StatsCatalog)
    case failed(String)
  }
  package let provider: StatsProvider
  package var catalog: CatalogChange = .unchanged
  package var nativeSelection: CurrentSession?
  package var pageSelection: PageSessionSelection?

  package init(provider: StatsProvider, nativeSelection: CurrentSession) {
    self.provider = provider
    self.nativeSelection = nativeSelection
  }

  package init(snapshot: StatsSnapshot, pageSelection: PageSessionSelection? = nil) {
    provider = snapshot.provider
    catalog = .replace(StatsCatalog(snapshot))
    self.pageSelection = pageSelection
  }

  package init(
    provider: StatsProvider, snapshot: JSONObject, pageSelection: PageSessionSelection? = nil
  ) {
    self.provider = provider
    self.pageSelection = pageSelection
    if let error = snapshot["error"] as? String {
      catalog = .failed(error)
    } else if snapshot["sessions"] is [JSONObject] {
      catalog = .replace(StatsCatalog(snapshot))
    }
  }

  // Only compatibility fixtures accept a mixed JSON message. The native
  // collector publishes typed updates with an immutable provider identity.
  package init?(json: JSONObject, defaultProvider: StatsProvider) {
    if let value = json["provider"] {
      guard let raw = value as? String, let provider = StatsProvider(rawValue: raw) else {
        return nil
      }
      self.init(provider: provider, snapshot: json)
    } else {
      self.init(provider: defaultProvider, snapshot: json)
    }
    nativeSelection = (json["nativeSelection"] as? JSONObject).map(CurrentSession.init(json:))
    pageSelection = (json["kimiSelection"] as? JSONObject).map(PageSessionSelection.init)
  }
}

package enum StatsPlaceholder: String {
  case loading = "加载会话…"
  case readError = "读取异常"
  case empty = "暂无会话统计"
  case unidentified = "当前会话未识别"
  case permissionRequired = "需辅助功能授权"
  case routeUnavailable = "宿主未提供当前会话ID"
  case draft = "新对话 · 暂无统计"
  case noLocalStats = "当前对话暂无本地统计"
}

package struct StatsPresentation {
  package let record: StatsRecord?
  package let placeholder: StatsPlaceholder
  package init(record: StatsRecord?, placeholder: StatsPlaceholder) {
    self.record = record
    self.placeholder = placeholder
  }
}
