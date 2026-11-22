import StatsCore
import StatsAdapters
import Foundation

// Display definitions are shared by the HUD, menu bar, settings preview and
// detail presenters. Parsers and accounting retain ownership of the measurements.
enum HUDMetric: String, CaseIterable {
  case speed, latency
  case usage, input, cacheRead, output, cacheHit, contextLength
  case turns
  case subagents
  case backgroundTasks, waitingUser
  case timing, toolTime, modelTime

  var definition: MetricDefinition { MetricRegistry.definitions[self]! }
  var label: String { definition.label }
  var shortLabel: String { definition.shortLabel }
  var group: String { definition.group.rawValue }
  var isRate: Bool { definition.unit == .rate }
  var isDuration: Bool { definition.unit == .duration }
  static var kimiOnly: Set<HUDMetric> {
    Set(allCases.filter { $0.definition.providers == [.kimi] })
  }
  static func available(for provider: String) -> [Self] {
    guard let provider = StatsProvider(rawValue: provider) else { return [] }
    return allCases.filter { $0.definition.providers.contains(provider) }
  }
  func value(in session: JSONObject?) -> Any? { value(inRecord: session.map(StatsRecord.init)) }
  func value(inRecord session: StatsRecord?, inventory: AgentInventory? = nil) -> Any? {
    definition.read(session, inventory)
  }
}

enum MetricUnit { case count, rate, duration, percent }

enum MetricGroup: String, CaseIterable {
  case speed, usage, timing, kimi, agents
  var title: String {
    switch self {
    case .speed: return "速度与延迟"
    case .usage: return "Token 用量"
    case .timing: return "耗时分布"
    case .kimi: return "Kimi 运行状态"
    case .agents: return "代理"
    }
  }
}

struct MetricDefinition {
  let label: String
  let shortLabel: String
  let group: MetricGroup
  let unit: MetricUnit
  var providers: Set<StatsProvider> = [.codex, .kimi]
  var explanation: ((StatsRecord?) -> String)? = nil
  let read: (StatsRecord?, AgentInventory?) -> Any?
}

enum MetricRegistry {
  static let defaults: [HUDMetric] = [.speed, .usage, .timing, .subagents]
  static let detailGroups: Set<String> = ["speed", "usage", "timing", "kimi"]
  private static func field(_ key: StatsMetric) -> (StatsRecord?, AgentInventory?) -> Any? {
    { record, _ in nonnegative(record?.value(key)) }
  }
  static let definitions: [HUDMetric: MetricDefinition] = [
    .subagents: MetricDefinition(
      label: "子代理", shortLabel: "子代理", group: .agents, unit: .count,
      read: { record, inventory in
        let resolved = inventory ?? AgentInventory(record?.values)
        return resolved.known ? resolved.children.count : nil
      }),
    .contextLength: MetricDefinition(
      label: "上下文长度", shortLabel: "上下文", group: .usage, unit: .count, providers: [.kimi],
      explanation: { _ in "宿主最近一次测量的上下文长度。它只是长度，不代表占用率或上限。" },
      read: { record, _ in nonnegative(record?.values["contextTokens"]) }),
    .turns: MetricDefinition(
      label: "轮次", shortLabel: "轮次", group: .timing, unit: .count,
      explanation: { record in
        guard let done = nonnegative(record?.values["completedTurns"]) else { return "已记录的轮次数。" }
        return "已记录的轮次数，其中已完成 " + Int(done).description + " 轮。"
      },
      read: { record, _ in nonnegative(record?.values["turns"]) }),
    .backgroundTasks: MetricDefinition(
      label: "后台任务", shortLabel: "后台", group: .kimi, unit: .count, providers: [.kimi],
      explanation: { _ in "按宿主任务记录统计当前运行中的后台进程。" },
      read: { record, _ in nonnegative(record?.values["backgroundRunning"]) }),
    .waitingUser: MetricDefinition(
      label: "等待处理", shortLabel: "等待", group: .kimi, unit: .count, providers: [.kimi],
      explanation: { _ in "按本地日志最后记录的等待状态；宿主退出后可能已过期。" },
      read: { record, _ in
        guard let approvals = nonnegative(record?.values["pendingApprovals"]),
          let questions = nonnegative(record?.values["pendingQuestions"])
        else { return nil }
        return approvals + questions
      }),
    .speed: MetricDefinition(
      label: "速度（最近一轮优先）", shortLabel: "速度", group: .speed, unit: .rate,
      explanation: { record in
        nonnegative(record?.lastTurn?.value(.tps)) != nil
          ? "当前显示最近一轮速度。"
          : nonnegative(record?.value(.tps)) != nil ? "最近一轮暂无有效速度，当前显示会话平均速度。" : "暂无有效速度数据。"
      },
      read: { record, _ in
        nonnegative(record?.lastTurn?.value(.tps)) ?? nonnegative(record?.value(.tps))
      }),
    .latency: MetricDefinition(
      label: "首 Token 延迟（最近一轮优先）", shortLabel: "首延", group: .speed, unit: .duration,
      explanation: { record in
        nonnegative(record?.lastTurn?.value(.ttftMs)) != nil
          ? "当前显示最近一轮首 Token 延迟。"
          : nonnegative(record?.value(.avgTtftMs)) != nil ? "最近一轮暂无首 Token 延迟，当前显示会话平均值。" : "暂无首 Token 延迟数据。"
      },
      read: { record, _ in
        nonnegative(record?.lastTurn?.value(.ttftMs)) ?? nonnegative(record?.value(.avgTtftMs))
      }),
    .usage: MetricDefinition(
      label: "总 Token", shortLabel: "Token", group: .usage, unit: .count, read: field(.totalTokens)),
    .input: MetricDefinition(
      label: "输入 Token", shortLabel: "输入", group: .usage, unit: .count,
      read: { record, _ in
        number(record?.value(.input)).map { $0 + (number(record?.value(.cacheWrite)) ?? 0) }
      }),
    .cacheRead: MetricDefinition(
      label: "缓存读取 Token", shortLabel: "缓存读", group: .usage, unit: .count, read: field(.cacheRead)),
    .output: MetricDefinition(
      label: "输出 Token", shortLabel: "输出", group: .usage, unit: .count, read: field(.output)),
    .cacheHit: MetricDefinition(
      label: "缓存命中率", shortLabel: "命中率", group: .usage, unit: .percent, read: field(.cacheHit)),
    .timing: MetricDefinition(
      label: "累计用时", shortLabel: "用时", group: .timing, unit: .duration, read: field(.totalMs)),
    .toolTime: MetricDefinition(
      label: "工具调用耗时", shortLabel: "工具", group: .timing, unit: .duration, read: field(.toolMs)),
    .modelTime: MetricDefinition(
      label: "模型耗时", shortLabel: "模型", group: .timing, unit: .duration,
      explanation: { _ in "模型生成所用时间（Codex 取模型用时，Kimi 取模型请求耗时）。" },
      read: { record, _ in
        nonnegative(record?.value(.modelMs)) ?? nonnegative(record?.value(.llmMs))
      }),
  ]
}

/// Everything a detail row needs to render itself. Parsers keep owning the
/// measurements; this context only carries the current record, the resolved agent
/// inventory and the injected clocks, so a row never reads preferences directly.
struct DetailRowContext {
  let record: StatsRecord
  let inventory: AgentInventory
  let provider: StatsProvider
  let now: () -> Double
  let hookReport: () -> Lifecycle.HookReport?
}

/// One configurable row inside an expanded detail card. `key` is the stable
/// preference identity; `title` is only the label shown while choosing rows, and a
/// row may render no cells at all when its condition does not apply right now.
struct DetailRowDefinition {
  let key: String
  let group: MetricGroup
  let title: String
  var providers: Set<StatsProvider> = [.codex, .kimi]
  let rows: (DetailRowContext) -> [(String, String)]
}

/// The complete, user-visible set of detail rows. Every row here is opt-in by
/// preference; the Codex-only reasoning/decode breakdown was deleted outright
/// instead of becoming another switch.
enum DetailRowRegistry {
  static let rows: [DetailRowDefinition] = [
    DetailRowDefinition(key: "speed.lastTurn", group: .speed, title: "最近一轮速度") { context in
      [("最近一轮速度", decimal(context.record.lastTurn?.value(.tps), suffix: " tok/s"))]
    },
    DetailRowDefinition(key: "speed.average", group: .speed, title: "平均速度") { context in
      [("平均速度", decimal(context.record.value(.tps), suffix: " tok/s"))]
    },
    DetailRowDefinition(key: "speed.lastTtft", group: .speed, title: "最近一轮 TTFT") { context in
      [("最近一轮 TTFT", seconds(context.record.lastTurn?.value(.ttftMs)))]
    },
    DetailRowDefinition(key: "speed.averageTtft", group: .speed, title: "平均 TTFT") { context in
      [("平均 TTFT", seconds(context.record.value(.avgTtftMs)))]
    },
    DetailRowDefinition(key: "usage.total", group: .usage, title: "总计") { context in
      let host = context.record.values["totalSource"] as? String == "host"
      let title =
        host ? "总计（宿主计数）" : (context.inventory.main != nil ? "会话总计" : "总计")
      return [(title, exactCount(context.record.value(.totalTokens)))]
    },
    DetailRowDefinition(key: "usage.scope", group: .usage, title: "统计口径") { context in
      guard let note = SessionTitle.nonempty(context.record.values["coverageNote"]) else { return [] }
      return [("统计口径", note)]
    },
    DetailRowDefinition(key: "usage.mainAgent", group: .usage, title: "主代理 Token") { context in
      guard context.inventory.known, !context.inventory.children.isEmpty,
        let main = context.inventory.main
      else { return [] }
      return [("主代理 Token", exactCount(main.record["totalTokens"]))]
    },
    DetailRowDefinition(key: "usage.input", group: .usage, title: "输入") { context in
      let input = number(context.record.value(.input)).map {
        $0 + (number(context.record.value(.cacheWrite)) ?? 0)
      }
      return [("输入", exactCount(input))]
    },
    DetailRowDefinition(key: "usage.cacheRead", group: .usage, title: "缓存读取") { context in
      [("缓存读取", exactCount(context.record.value(.cacheRead)))]
    },
    DetailRowDefinition(key: "usage.output", group: .usage, title: "输出") { context in
      [("输出", exactCount(context.record.value(.output)))]
    },
    DetailRowDefinition(key: "usage.cacheHit", group: .usage, title: "缓存命中率") { context in
      [("缓存命中率", decimal(context.record.value(.cacheHit), suffix: "%"))]
    },
    DetailRowDefinition(key: "usage.sharedHistory", group: .usage, title: "共享历史（去重）") { context in
      guard (number(context.record.value(.sharedHistoryTokens)) ?? 0) > 0 else { return [] }
      return [("共享历史（去重）", exactCount(context.record.value(.sharedHistoryTokens)))]
    },
    DetailRowDefinition(key: "usage.observedRequests", group: .usage, title: "已确认的逐请求 Token") {
      context in
      guard context.record.partial else { return [] }
      return [("已确认的逐请求 Token", exactCount(context.record.value(.observedRequestTokens)))]
    },
    // Kimi Code shows the context length itself, so this is reported as a length
    // only: no occupancy ratio and no limit are inferred from it.
    DetailRowDefinition(
      key: "usage.contextLength", group: .usage, title: "上下文长度", providers: [.kimi]
    ) { context in
      [("上下文长度", exactCount(context.record.value(.contextTokens)))]
    },
    DetailRowDefinition(key: "timing.total", group: .timing, title: "累计用时") { context in
      [("累计用时", seconds(context.record.value(.totalMs)))]
    },
    DetailRowDefinition(key: "timing.lastTurn", group: .timing, title: "最近一轮") { context in
      [("最近一轮", seconds(context.record.lastTurn?.value(.durationMs)))]
    },
    DetailRowDefinition(key: "timing.turns", group: .timing, title: "轮次") { context in
      guard let turns = nonnegative(context.record.values["turns"]) else { return [] }
      let done = nonnegative(context.record.values["completedTurns"])
      return [("轮次", done.map { "\(Int(turns))（已完成 \(Int($0))）" } ?? Int(turns).description)]
    },
    DetailRowDefinition(key: "timing.tool", group: .timing, title: "工具调用") { context in
      [("工具调用", seconds(context.record.value(.toolMs)))]
    },
    DetailRowDefinition(key: "timing.model", group: .timing, title: "模型耗时") { context in
      [(
        "模型耗时",
        seconds(
          nonnegative(context.record.value(.modelMs))
            ?? nonnegative(context.record.value(.llmMs)))
      )]
    },
    DetailRowDefinition(
      key: "timing.firstTokenWait", group: .timing, title: "首 Token 等待", providers: [.kimi]
    ) { context in
      [("首 Token 等待", seconds(context.record.value(.firstTokenWaitMs)))]
    },
    DetailRowDefinition(
      key: "timing.stream", group: .timing, title: "流式输出", providers: [.kimi]
    ) { context in
      [("流式输出", seconds(context.record.value(.decodeMs)))]
    },
    DetailRowDefinition(
      key: "kimi.backgroundRunning", group: .kimi, title: "后台任务运行中", providers: [.kimi]
    ) { context in
      [("后台任务运行中", exactCount(context.record.values["backgroundRunning"]))]
    },
    DetailRowDefinition(
      key: "kimi.backgroundTotal", group: .kimi, title: "后台任务总数", providers: [.kimi]
    ) { context in
      [("后台任务总数", exactCount(context.record.values["backgroundTotal"]))]
    },
    DetailRowDefinition(
      key: "kimi.pendingApprovals", group: .kimi, title: "等待批准", providers: [.kimi]
    ) { context in
      [("等待批准", exactCount(context.record.values["pendingApprovals"]))]
    },
    DetailRowDefinition(
      key: "kimi.pendingQuestions", group: .kimi, title: "等待回答", providers: [.kimi]
    ) { context in
      [("等待回答", exactCount(context.record.values["pendingQuestions"]))]
    },
    DetailRowDefinition(
      key: "kimi.permissionMode", group: .kimi, title: "权限模式", providers: [.kimi]
    ) { context in
      let mode = SessionTitle.nonempty(context.record.values["permissionMode"])
      let modes = ["yolo": "yolo（不再逐次询问）", "auto": "auto（自动判断）", "plan": "plan（先给出计划）"]
      return [("权限模式", mode.flatMap { modes[$0] } ?? mode ?? "—")]
    },
    DetailRowDefinition(
      key: "kimi.backgroundItems", group: .kimi, title: "正在运行的后台任务", providers: [.kimi]
    ) { context in
      let now = context.now()
      return (context.record.values["backgroundItems"] as? [JSONObject] ?? []).prefix(6).map { item in
        let elapsed = nonnegative(item["startedAt"]).map { shortTime(max(0, now - $0)) }
        return (
          identifier(item["description"]), "运行中" + (elapsed.map { " · 已运行 " + $0 } ?? "")
        )
      }
    },
    DetailRowDefinition(
      key: "kimi.hookReport", group: .kimi, title: "插件上报", providers: [.kimi]
    ) { context in
      guard let report = context.hookReport() else { return [("插件上报", "未收到插件事件")] }
      return [
        (
          "插件上报",
          report.event + " · "
            + clockFormatter.string(from: Date(timeIntervalSince1970: report.time / 1000))
        )
      ]
    },
  ]
  /// Every key, regardless of provider, so a stored preference is never mistaken
  /// for an unknown key while a tool is switched.
  static var allKeys: Set<String> { Set(rows.map(\.key)) }
  static func available(for provider: StatsProvider) -> [DetailRowDefinition] {
    rows.filter { $0.providers.contains(provider) }
  }
  static func available(for provider: StatsProvider, in group: MetricGroup) -> [DetailRowDefinition] {
    available(for: provider).filter { $0.group == group }
  }
  static func defaultKeys(for provider: StatsProvider) -> Set<String> {
    Set(available(for: provider).map(\.key))
  }
  static func groups(for provider: StatsProvider) -> [MetricGroup] {
    MetricGroup.allCases.filter { !available(for: provider, in: $0).isEmpty }
  }
}

struct MetricPresentation {
  let title: String
  let toolTip: String
  let accessibilityLabel: String
}

struct MetricPresenter {
  let provider: StatsProvider
  let record: StatsRecord?
  var now: () -> Double = { Date().timeIntervalSince1970 * 1000 }
  var hookReport: () -> Lifecycle.HookReport? = { Lifecycle.hookReport(support: Product.support) }
  /// nil keeps every row the current tool supports. The settings page stores the
  /// user's own subset of `DetailRowRegistry` keys here.
  var detailKeys: Set<String>? = nil

  /// The bar has one shape, so a metric always renders as one line: short label
  /// plus the value.
  func title(_ metric: HUDMetric, inventory: AgentInventory? = nil) -> String {
    let value = metric.value(inRecord: record, inventory: inventory)
    let formatted: String
    if metric.isRate {
      formatted = decimal(value, suffix: " tok/s")
    } else if metric.isDuration {
      formatted = shortTime(value)
    } else if metric.definition.unit == .percent {
      formatted = decimal(value, suffix: "%")
    } else {
      formatted = count(value)
    }
    return metric.shortLabel + " " + formatted
  }
  func presentation(_ metric: HUDMetric, inventory: AgentInventory? = nil) -> MetricPresentation
  {
    let inventory = inventory ?? AgentInventory(record?.values)
    let value = metric.value(inRecord: record, inventory: inventory)
    var hint = metric.definition.explanation?(record) ?? metric.label
    if inventory.main != nil, metric.isRate || metric.isDuration { hint = "主代理 · " + hint }
    if metric.isRate { hint += provider == .codex ? " TPS 包含推理、正文及工具参数（无首 Token 锚点的纯工具步除外）。" : " TPS 包含推理、正文及工具参数。" }
    if metric.group == "usage", metric != .contextLength { hint += " 累计用量，不是上下文窗口占用；输入含缓存写入。" }
    if metric == .usage, record?.values["totalSource"] as? String == "host" {
      hint += " 本次总计来自宿主本机计数，拆分未知。"
    }
    let exact: String
    switch metric.definition.unit {
    case .rate: exact = decimal(value, suffix: " tok/s")
    case .duration: exact = seconds(value)
    case .percent: exact = decimal(value, suffix: "%")
    case .count: exact = exactCount(value)
    }
    return MetricPresentation(
      title: title(metric, inventory: inventory),
      toolTip: hint + "\n" + exact + " · 点击查看明细",
      accessibilityLabel: metric.label + "，" + exact)
  }
  /// Rows for one expanded detail card, already filtered by the user's selection.
  /// A group with every row disabled simply renders an empty card.
  func content(_ kind: String) -> ([(String, String)], String) {
    guard let record, let group = MetricGroup(rawValue: kind) else { return ([], "") }
    let inventory = AgentInventory(record.values)
    let enabled = detailKeys ?? DetailRowRegistry.defaultKeys(for: provider)
    let context = DetailRowContext(
      record: record, inventory: inventory, provider: provider, now: now, hookReport: hookReport)
    let rows = DetailRowRegistry.available(for: provider, in: group).flatMap {
      enabled.contains($0.key) ? $0.rows(context) : []
    }
    return (rows, "")
  }
  static func agentGroups(_ record: JSONObject) -> [AgentMetricGroup] {
    let values = agentMetrics(record)
    let sections: [(String, [String])] = [
      ("Token 用量", ["Token 总计", "已记录 Token", "输入 Token", "输出 Token", "缓存读取", "缓存命中率"]),
      ("性能与耗时", ["平均 TPS", "平均首 Token", "平均每轮耗时", "累计用时", "工具耗时"]),
    ]
    return sections.map { section in
      AgentMetricGroup(title: section.0, metrics: values.filter { section.1.contains($0.0) })
    }
  }
  static func agentMetrics(_ record: JSONObject) -> [(String, String)] {
    func exact(_ value: Any?) -> String {
      guard let n = number(value), n.isFinite else { return "—" }
      return exactCountFormatter.string(from: NSNumber(value: n)) ?? "—"
    }
    let input = number(record["input"]).map { $0 + (number(record["cacheWrite"]) ?? 0) }
    return [
      (record["totalSource"] as? String == "host"
        ? "宿主计数 Token" : (record["partial"] as? Bool == true ? "已记录 Token" : "Token 总计"),
        exact(record["totalTokens"])),
      ("输入 Token", exact(input)), ("输出 Token", exact(record["output"])),
      ("缓存读取", exact(record["cacheRead"])), ("缓存命中率", decimal(record["cacheHit"], suffix: "%")),
      ("平均 TPS", decimal(record["tps"], suffix: " tok/s")),
      ("平均首 Token", seconds(record["avgTtftMs"])),
      ("平均每轮耗时", seconds(record["avgTurnMs"])), ("累计用时", seconds(record["totalMs"])),
      ("工具耗时", seconds(record["toolMs"])),
    ]
  }
}
