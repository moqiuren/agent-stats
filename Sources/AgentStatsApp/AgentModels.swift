import StatsCore
import StatsAdapters
import CoreGraphics
import Foundation

struct AgentEntry {
  let id: String
  let name: String
  let isMain: Bool
  let record: JSONObject
  var role: String { isMain ? "主代理" : "子代理" }
}

struct AgentInventory {
  let known: Bool
  let main: AgentEntry?
  let children: [AgentEntry]
  init(_ session: JSONObject?) {
    let records = session?["agents"] as? [JSONObject]
    known = records != nil && session?["isProject"] as? Bool != true
    let roots = (records ?? []).filter { $0["role"] as? String == "main" }
    func key(_ row: JSONObject) -> String { identifier(row["key"] ?? row["id"] ?? row["agentID"]) }
    main =
      roots.count == 1
      ? AgentEntry(id: key(roots[0]), name: "主代理", isMain: true, record: roots[0]) : nil
    var used = Set<String>()
    var children = [AgentEntry]()
    for record in (records ?? []).filter({ $0["role"] as? String == "subagent" }).sorted(by: {
      key($0) < key($1)
    }) {
      let id = key(record)
      guard !id.isEmpty, used.insert(id).inserted else { continue }
      let raw = SessionTitle.nonempty(record["agentID"])
      let readableID = raw.flatMap { value -> String? in
        guard UUID(uuidString: value) == nil, value.count <= 40, !value.hasPrefix("__"),
          value.range(of: "^[0-9a-fA-F-]{12,}$", options: .regularExpression) == nil
        else { return nil }
        return value
      }
      let name =
        SessionTitle.nonempty(record["nickname"]) ?? readableID ?? "子代理 \(children.count+1)"
      children.append(AgentEntry(id: id, name: name, isMain: false, record: record))
    }
    self.children = children
  }
  func entry(_ id: String) -> AgentEntry? { main?.id == id ? main : children.first { $0.id == id } }
}

struct AgentInspectorState {
  private(set) var scope: String?
  var selectedID: String?
  var listPage = 0, detailPage = 0
  mutating func updateScope(provider: String, session: JSONObject?, reset: Bool = false) {
    let next = session.map {
      provider + ":" + identifier($0["taskKey"] ?? $0["id"] ?? $0["sessionID"])
    }
    if reset || scope != next {
      scope = next
      selectedID = nil
      listPage = 0
      detailPage = 0
    }
  }
  mutating func open(_ id: String) {
    selectedID = id
    detailPage = 0
  }
  mutating func back() {
    selectedID = nil
    detailPage = 0
  }
}

// Detail metrics are grouped by meaning. The named group is part of the model,
// not just a caption, so the grid and the paging fallback agree on what belongs
// together and a group heading is never separated from its own values.
struct AgentMetricGroup {
  let title: String
  let metrics: [(String, String)]
}

// The panel body always matches its viewport. Short host windows reduce the
// number of rows/cards per page; they never force a nested scrolling surface.
struct AgentPageLayout {
  let size: CGSize
  var compact: Bool { size.height < 240 }
  var rowHeight: CGFloat { compact ? 34 : 44 }
  var footerHeight: CGFloat { 28 }
  func listCapacity(hasMain: Bool) -> Int {
    let top: CGFloat = 6 + (hasMain ? rowHeight + 8 : 0) + 24
    return max(1, Int((size.height - top - footerHeight - 4) / rowHeight))
  }
  var columns: Int { size.width >= 280 ? 2 : 1 }
  var detailHeader: CGFloat { compact ? 66 : 74 }
  var titleY: CGFloat { compact ? 28 : 30 }
  var nameHeight: CGFloat { compact ? 20 : 22 }
  var subtitleY: CGFloat { compact ? 50 : 54 }
  var subtitleHeight: CGFloat { compact ? 14 : 18 }
  var groupTitleHeight: CGFloat { compact ? 16 : 18 }
  var groupRuleY: CGFloat { compact ? 13 : 15 }
  var metricCaptionHeight: CGFloat { compact ? 12 : 13 }
  var metricValueHeight: CGFloat { compact ? 17 : 19 }
  var metricRowPitch: CGFloat { compact ? 30 : 34 }
  var groupGap: CGFloat { compact ? 3 : 6 }
  var bottomPadding: CGFloat { 6 }
  var detailValueSize: CGFloat { compact ? 14 : 16 }
  // Every metric fits on one page whenever the panel has room for the whole
  // grouped grid. Only an unusually short viewport falls back to paging, and
  // then whole rows move together while a continuing group repeats its heading.
  func detailPages(_ groups: [AgentMetricGroup]) -> [[AgentMetricGroup]] {
    guard !groups.isEmpty else { return [[]] }
    func rows(_ count: Int) -> Int { max(1, (count + columns - 1) / columns) }
    func height(_ group: AgentMetricGroup) -> CGFloat {
      groupTitleHeight + CGFloat(rows(group.metrics.count)) * metricRowPitch
    }
    let available = max(1, size.height - detailHeader - bottomPadding)
    if groups.reduce(0, { $0 + height($1) }) + groupGap * CGFloat(groups.count - 1) <= available {
      return [groups]
    }
    let usable = max(metricRowPitch, available - footerHeight)
    var pages = [[AgentMetricGroup]]()
    var current = [AgentMetricGroup]()
    var used: CGFloat = 0
    for group in groups {
      var remaining = group.metrics
      repeat {
        let overhead = (current.isEmpty ? 0 : groupGap) + groupTitleHeight
        var capacity = max(0, Int((usable - used - overhead) / metricRowPitch)) * columns
        if capacity == 0 {
          if !current.isEmpty {
            pages.append(current)
            current = []
            used = 0
            continue
          }
          capacity = columns
        }
        let slice = Array(remaining.prefix(capacity))
        current.append(AgentMetricGroup(title: group.title, metrics: slice))
        used += overhead + CGFloat(max(1, (slice.count + columns - 1) / columns)) * metricRowPitch
        remaining = Array(remaining.dropFirst(slice.count))
      } while !remaining.isEmpty
    }
    if !current.isEmpty { pages.append(current) }
    return pages.isEmpty ? [[]] : pages
  }
}
