import Foundation

package enum TokenStatsToolScope: String, CaseIterable, Equatable {
  case all, codex, kimi

  package var title: String {
    switch self {
    case .all: return "全部"
    case .codex: return "Codex"
    case .kimi: return "Kimi"
    }
  }

  package func includes(_ provider: StatsProvider) -> Bool {
    switch self {
    case .all: return true
    case .codex: return provider == .codex
    case .kimi: return provider == .kimi
    }
  }
}

package enum TokenStatsTimeRange: String, CaseIterable, Equatable {
  case today, days7, days30, all

  package var title: String {
    switch self {
    case .today: return "今日"
    case .days7: return "近7天"
    case .days30: return "近30天"
    case .all: return "全部"
    }
  }
}

package enum TokenStatsDimension: String, CaseIterable, Equatable {
  case models, projects, sessions

  package var title: String {
    switch self {
    case .models: return "按模型"
    case .projects: return "按项目"
    case .sessions: return "按会话"
    }
  }
}

package struct TokenUsageEntry: Equatable {
  package enum Source: String, Equatable {
    case requests, cumulative, hostCounter
  }

  package let provider: StatsProvider
  package let timestampMs: Double?
  package let model: String?
  package let projectKey: String
  package let projectTitle: String
  package let projectSubtitle: String?
  package let sessionKey: String
  package let sessionTitle: String
  package let archived: Bool
  package let isSharedCrossSession: Bool
  package let source: Source
  package let input: Double
  package let cacheRead: Double
  package let cacheWrite: Double
  package let output: Double
  package let totalTokens: Double
  package let requestCount: Int

  package init(
    provider: StatsProvider, timestampMs: Double?, model: String?,
    projectKey: String, projectTitle: String, projectSubtitle: String? = nil,
    sessionKey: String, sessionTitle: String, archived: Bool = false,
    isSharedCrossSession: Bool = false, source: Source,
    input: Double, cacheRead: Double, cacheWrite: Double, output: Double,
    totalTokens: Double, requestCount: Int
  ) {
    self.provider = provider
    self.timestampMs = timestampMs
    self.model = model
    self.projectKey = projectKey
    self.projectTitle = projectTitle
    self.projectSubtitle = projectSubtitle
    self.sessionKey = sessionKey
    self.sessionTitle = sessionTitle
    self.archived = archived
    self.isSharedCrossSession = isSharedCrossSession
    self.source = source
    self.input = input
    self.cacheRead = cacheRead
    self.cacheWrite = cacheWrite
    self.output = output
    self.totalTokens = totalTokens
    self.requestCount = requestCount
  }
}

package struct ProviderTokenCorpus: Equatable {
  package let provider: StatsProvider
  package let collectedAt: Double
  package let entries: [TokenUsageEntry]
  package let totalSessions: Int
  package let archivedSessions: Int
  package let ambiguousSessions: Int
  package let hostFallbackSessions: Int
  package let partialSessions: Int

  package init(
    provider: StatsProvider, collectedAt: Double, entries: [TokenUsageEntry] = [],
    totalSessions: Int = 0, archivedSessions: Int = 0,
    ambiguousSessions: Int = 0, hostFallbackSessions: Int = 0, partialSessions: Int = 0
  ) {
    self.provider = provider
    self.collectedAt = collectedAt
    self.entries = entries
    self.totalSessions = totalSessions
    self.archivedSessions = archivedSessions
    self.ambiguousSessions = ambiguousSessions
    self.hostFallbackSessions = hostFallbackSessions
    self.partialSessions = partialSessions
  }

  /// Converts an in-memory `StatsCatalog` into a token corpus (used as an initial fallback
  /// before background history scanning finishes, and by unit tests without disk fixtures).
  package static func fromCatalog(
    _ catalog: StatsCatalog, provider: StatsProvider, collectedAt: Double
  ) -> ProviderTokenCorpus {
    var entries = [TokenUsageEntry]()
    var archivedCount = 0
    var hostFallbackCount = 0
    var partialCount = 0
    var ambiguousCount = 0

    for record in catalog.sessions {
      let values = record.values
      let archived = record.archived
      if archived { archivedCount += 1 }
      let total = nonnegative(values["totalTokens"])
      let isHost = values["totalSource"] as? String == "host"
      if isHost { hostFallbackCount += 1 }
      if record.partial { partialCount += 1 }
      let note = values["coverageNote"] as? String ?? ""
      if note.contains("合计未相加") { ambiguousCount += 1 }

      guard let total else { continue }
      let sessionKey = identifier(values["taskKey"] ?? values["id"] ?? record.sessionID ?? "")
      let title = record.title
      let group = jsonObject(values["group"])
      let projectObj = jsonObject(values["project"])
      let cwd = projectObj["cwd"] as? String
      let workspace = projectObj["workspace"] as? String
      let groupID = group["id"] as? String
      let groupTitle = SessionTitle.nonempty(group["title"])

      let projectKey: String
      let projectTitle: String
      let projectSubtitle: String?
      if let cwd, !cwd.isEmpty {
        projectKey = "cwd:" + cwd
        if let groupID, groupID != StatsGroup.ungroupedID, let groupTitle {
          projectTitle = groupTitle
          projectSubtitle = cwd
        } else {
          let last = URL(fileURLWithPath: cwd).lastPathComponent
          projectTitle = (last.isEmpty || last == "/") ? cwd : last
          projectSubtitle = cwd
        }
      } else if let groupID, groupID != StatsGroup.ungroupedID, let groupTitle {
        projectKey = "\(provider.rawValue):group:\(groupID)"
        projectTitle = groupTitle
        projectSubtitle = nil
      } else if let workspace, !workspace.isEmpty {
        projectKey = "\(provider.rawValue):ws:\(workspace)"
        projectTitle = "工作区 · " + workspace
        projectSubtitle = nil
      } else {
        projectKey = "\(provider.rawValue):unknown"
        projectTitle = "未归属项目"
        projectSubtitle = nil
      }

      let rawTime = nonnegative(values["updatedAt"])
      let timestampMs = rawTime.flatMap { $0 > 0 ? $0 : nil }
      let model = SessionTitle.nonempty(values["model"])
      let input = isHost ? 0 : (nonnegative(values["input"]) ?? 0)
      let cacheRead = isHost ? 0 : (nonnegative(values["cacheRead"]) ?? 0)
      let cacheWrite = isHost ? 0 : (nonnegative(values["cacheWrite"]) ?? 0)
      let output = isHost ? 0 : (nonnegative(values["output"]) ?? 0)
      let reqCount = max(1, Int(nonnegative(values["turns"]) ?? 1))

      entries.append(
        TokenUsageEntry(
          provider: provider, timestampMs: timestampMs, model: model,
          projectKey: projectKey, projectTitle: projectTitle, projectSubtitle: projectSubtitle,
          sessionKey: sessionKey, sessionTitle: title, archived: archived,
          isSharedCrossSession: false,
          source: isHost ? .hostCounter : .requests,
          input: input, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output,
          totalTokens: total, requestCount: isHost ? 0 : reqCount))
    }

    return ProviderTokenCorpus(
      provider: provider, collectedAt: collectedAt, entries: entries,
      totalSessions: catalog.sessions.count, archivedSessions: archivedCount,
      ambiguousSessions: ambiguousCount, hostFallbackSessions: hostFallbackCount,
      partialSessions: partialCount)
  }
}

package struct TokenTrendBucket: Equatable {
  package let id: String
  package let axisLabel: String
  package let detailTitle: String
  package let startMs: Double
  package let endMs: Double
  package var input: Double = 0
  package var cacheWrite: Double = 0
  package var cacheRead: Double = 0
  package var output: Double = 0
  package var hostFallback: Double = 0
  package var totalTokens: Double = 0

  package var combinedInput: Double { input + cacheWrite }

  package init(
    id: String, axisLabel: String, detailTitle: String, startMs: Double, endMs: Double,
    input: Double = 0, cacheWrite: Double = 0, cacheRead: Double = 0, output: Double = 0,
    hostFallback: Double = 0, totalTokens: Double = 0
  ) {
    self.id = id
    self.axisLabel = axisLabel
    self.detailTitle = detailTitle
    self.startMs = startMs
    self.endMs = endMs
    self.input = input
    self.cacheWrite = cacheWrite
    self.cacheRead = cacheRead
    self.output = output
    self.hostFallback = hostFallback
    self.totalTokens = totalTokens
  }
}

package struct TokenBreakdownRow: Equatable {
  package let id: String
  package let title: String
  package let subtitle: String
  package let badge: String?
  package let toolTip: String
  package let input: Double
  package let cacheWrite: Double
  package let cacheRead: Double
  package let output: Double
  package let hostFallback: Double
  package let totalTokens: Double
  package let share: Double
  package let cacheHitPercent: Double?
  package let requestCount: Int
  package let sessionCount: Int

  package var combinedInput: Double { input + cacheWrite }
  package var hasBreakdown: Bool { totalTokens == 0 || hostFallback < totalTokens }

  package init(
    id: String, title: String, subtitle: String, badge: String?, toolTip: String,
    input: Double, cacheWrite: Double, cacheRead: Double, output: Double,
    hostFallback: Double, totalTokens: Double, share: Double, cacheHitPercent: Double?,
    requestCount: Int, sessionCount: Int
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.badge = badge
    self.toolTip = toolTip
    self.input = input
    self.cacheWrite = cacheWrite
    self.cacheRead = cacheRead
    self.output = output
    self.hostFallback = hostFallback
    self.totalTokens = totalTokens
    self.share = share
    self.cacheHitPercent = cacheHitPercent
    self.requestCount = requestCount
    self.sessionCount = sessionCount
  }
}

package struct TokenStatsReport: Equatable {
  package let scope: TokenStatsToolScope
  package let range: TokenStatsTimeRange
  package let totalTokens: Double
  package let inputTokens: Double
  package let cacheWriteTokens: Double
  package let combinedInputTokens: Double
  package let cacheReadTokens: Double
  package let outputTokens: Double
  package let hostFallbackTokens: Double
  package let cacheHitPercent: Double?
  package let requestCount: Int
  package let sessionCount: Int
  package let archivedSessionCount: Int
  package let trendTitle: String
  package let buckets: [TokenTrendBucket]
  package let axisIndices: [Int]
  package let averagePerDayTokens: Double?
  package let peakBucketTokens: Double
  package let peakBucketLabel: String?
  package let models: [TokenBreakdownRow]
  package let projects: [TokenBreakdownRow]
  package let sessions: [TokenBreakdownRow]
  package let coverageNotes: [String]
}

package enum TokenStatsAggregator {
  private static func providerShortName(_ provider: StatsProvider) -> String {
    provider == .kimi ? "Kimi" : "Codex"
  }

  private struct Accumulator {
    var input: Double = 0
    var cacheWrite: Double = 0
    var cacheRead: Double = 0
    var output: Double = 0
    var hostFallback: Double = 0
    var totalTokens: Double = 0
    var requestCount: Int = 0
    var sessions = Set<String>()
    var providers = Set<StatsProvider>()
    var archived = false
    var title = ""
    var subtitle: String?
    var lastTime: Double = 0

    mutating func add(_ entry: TokenUsageEntry) {
      if entry.source == .hostCounter {
        hostFallback += entry.totalTokens
      } else {
        input += entry.input
        cacheWrite += entry.cacheWrite
        cacheRead += entry.cacheRead
        output += entry.output
      }
      totalTokens += entry.totalTokens
      requestCount += entry.requestCount
      if !entry.isSharedCrossSession {
        sessions.insert("\(entry.provider.rawValue):\(entry.sessionKey)")
      }
      providers.insert(entry.provider)
      if entry.archived { archived = true }
      if let t = entry.timestampMs { lastTime = max(lastTime, t) }
    }

    var cacheDenominator: Double { input + cacheWrite + cacheRead }
    var cacheHitPercent: Double? {
      let denom = cacheDenominator
      guard denom > 0 else { return nil }
      return cacheRead * 100 / denom
    }
  }

  package static func aggregate(
    corpora: [StatsProvider: ProviderTokenCorpus],
    scope: TokenStatsToolScope,
    range: TokenStatsTimeRange,
    now: Date,
    calendar: Calendar = .autoupdatingCurrent
  ) -> TokenStatsReport {
    let selectedCorpora = StatsProvider.allCases.compactMap { provider -> ProviderTokenCorpus? in
      guard scope.includes(provider) else { return nil }
      return corpora[provider]
    }
    let todayStart = calendar.startOfDay(for: now)
    let todayStartMs = todayStart.timeIntervalSince1970 * 1000
    let cutoffMs: Double?
    switch range {
    case .today:
      cutoffMs = todayStartMs
    case .days7:
      cutoffMs = (calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart)
        .timeIntervalSince1970 * 1000
    case .days30:
      cutoffMs = (calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart)
        .timeIntervalSince1970 * 1000
    case .all:
      cutoffMs = nil
    }

    var filtered = [TokenUsageEntry]()
    for corpus in selectedCorpora {
      for entry in corpus.entries {
        if let cutoffMs {
          guard let t = entry.timestampMs, t >= cutoffMs else { continue }
        }
        filtered.append(entry)
      }
    }

    var totalTokens = 0.0
    var inputTokens = 0.0
    var cacheWriteTokens = 0.0
    var cacheReadTokens = 0.0
    var outputTokens = 0.0
    var hostFallbackTokens = 0.0
    var requestCount = 0
    var visibleSessionKeys = Set<String>()
    var archivedSessionKeys = Set<String>()
    var hostFallbackSessionKeys = Set<String>()

    for entry in filtered {
      totalTokens += entry.totalTokens
      if entry.source == .hostCounter {
        hostFallbackTokens += entry.totalTokens
        if !entry.isSharedCrossSession {
          hostFallbackSessionKeys.insert("\(entry.provider.rawValue):\(entry.sessionKey)")
        }
      } else {
        inputTokens += entry.input
        cacheWriteTokens += entry.cacheWrite
        cacheReadTokens += entry.cacheRead
        outputTokens += entry.output
      }
      requestCount += entry.requestCount
      if !entry.isSharedCrossSession {
        let skey = "\(entry.provider.rawValue):\(entry.sessionKey)"
        visibleSessionKeys.insert(skey)
        if entry.archived { archivedSessionKeys.insert(skey) }
      }
    }

    let combinedInputTokens = inputTokens + cacheWriteTokens
    let cacheDenom = inputTokens + cacheWriteTokens + cacheReadTokens
    let cacheHitPercent: Double? = cacheDenom > 0 ? cacheReadTokens * 100 / cacheDenom : nil

    let trend = buildTrend(
      entries: filtered, range: range, now: now, todayStart: todayStart, calendar: calendar)
    let models = buildModels(entries: filtered, scope: scope, grandTotal: totalTokens)
    let projects = buildProjects(entries: filtered, scope: scope, grandTotal: totalTokens)
    let sessions = buildSessions(entries: filtered, scope: scope, grandTotal: totalTokens)

    var coverageNotes = [
      "仅统计本机可见与已归档会话记录；服务端内部未公开消耗无法拆分，不作为官方账单依据。",
    ]
    let hostCount =
      range == .all
      ? max(hostFallbackSessionKeys.count, selectedCorpora.reduce(0) { $0 + $1.hostFallbackSessions })
      : hostFallbackSessionKeys.count
    if hostFallbackTokens > 0 || hostCount > 0 {
      coverageNotes.append(
        "其中 \(hostCount) 个历史会话缺少可读日志，总计回退采用宿主本机计数（无输入/缓存/输出拆分，按会话更新时间归入趋势）。")
    }
    let ambiguousCount = selectedCorpora.reduce(0) { $0 + $1.ambiguousSessions }
    if ambiguousCount > 0 {
      coverageNotes.append("另有 \(ambiguousCount) 个多代理累计快照会话因无法排除历史重叠，未合并累计快照。")
    }

    return TokenStatsReport(
      scope: scope, range: range,
      totalTokens: totalTokens,
      inputTokens: inputTokens,
      cacheWriteTokens: cacheWriteTokens,
      combinedInputTokens: combinedInputTokens,
      cacheReadTokens: cacheReadTokens,
      outputTokens: outputTokens,
      hostFallbackTokens: hostFallbackTokens,
      cacheHitPercent: cacheHitPercent,
      requestCount: requestCount,
      sessionCount: visibleSessionKeys.count,
      archivedSessionCount: archivedSessionKeys.count,
      trendTitle: trend.title,
      buckets: trend.buckets,
      axisIndices: trend.axisIndices,
      averagePerDayTokens: trend.averagePerDay,
      peakBucketTokens: trend.peakTokens,
      peakBucketLabel: trend.peakLabel,
      models: models,
      projects: projects,
      sessions: sessions,
      coverageNotes: coverageNotes)
  }

  private static func buildTrend(
    entries: [TokenUsageEntry],
    range: TokenStatsTimeRange,
    now: Date,
    todayStart: Date,
    calendar: Calendar
  ) -> (
    title: String, buckets: [TokenTrendBucket], axisIndices: [Int],
    averagePerDay: Double?, peakTokens: Double, peakLabel: String?
  ) {
    let dayMs = 86_400_000.0
    var buckets = [TokenTrendBucket]()
    let title: String
    var axisIndices = [Int]()
    let spanDaysForAvg: Double?

    let monthDayFormatter = DateFormatter()
    monthDayFormatter.calendar = calendar
    monthDayFormatter.locale = Locale(identifier: "en_US_POSIX")
    monthDayFormatter.dateFormat = "MM/dd"

    let yearMonthFormatter = DateFormatter()
    yearMonthFormatter.calendar = calendar
    yearMonthFormatter.locale = Locale(identifier: "en_US_POSIX")
    yearMonthFormatter.dateFormat = "yyyy-MM"

    let fullDateFormatter = DateFormatter()
    fullDateFormatter.calendar = calendar
    fullDateFormatter.locale = Locale(identifier: "en_US_POSIX")
    fullDateFormatter.dateFormat = "yyyy-MM-dd"

    switch range {
    case .today:
      title = "今日按小时趋势"
      let startMs = todayStart.timeIntervalSince1970 * 1000
      let hourMs = 3_600_000.0
      for hour in 0..<24 {
        let s = startMs + Double(hour) * hourMs
        let label = String(format: "%02d:00", hour)
        let detail = String(format: "今日 %02d:00–%02d:59", hour, hour)
        buckets.append(TokenTrendBucket(id: "h-\(hour)", axisLabel: label, detailTitle: detail, startMs: s, endMs: s + hourMs))
      }
      axisIndices = [0, 6, 12, 18, 23]
      spanDaysForAvg = nil

    case .days7:
      title = "近 7 天按日趋势"
      let start = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
      for offset in 0..<7 {
        let day = calendar.date(byAdding: .day, value: offset, to: start) ?? todayStart
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
        let s = day.timeIntervalSince1970 * 1000
        let e = nextDay.timeIntervalSince1970 * 1000
        let label = monthDayFormatter.string(from: day)
        let detail = fullDateFormatter.string(from: day)
        buckets.append(TokenTrendBucket(id: "d-\(detail)", axisLabel: label, detailTitle: detail, startMs: s, endMs: e))
      }
      axisIndices = Array(0..<7)
      spanDaysForAvg = 7

    case .days30:
      title = "近 30 天按日趋势"
      let start = calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
      for offset in 0..<30 {
        let day = calendar.date(byAdding: .day, value: offset, to: start) ?? todayStart
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
        let s = day.timeIntervalSince1970 * 1000
        let e = nextDay.timeIntervalSince1970 * 1000
        let label = monthDayFormatter.string(from: day)
        let detail = fullDateFormatter.string(from: day)
        buckets.append(TokenTrendBucket(id: "d-\(detail)", axisLabel: label, detailTitle: detail, startMs: s, endMs: e))
      }
      axisIndices = [0, 7, 14, 21, 29]
      spanDaysForAvg = 30

    case .all:
      let dated = entries.compactMap { entry -> Double? in
        guard entry.totalTokens > 0, let t = entry.timestampMs, t > 0 else { return nil }
        return t
      }
      let minDatedMs = dated.min() ?? todayStart.timeIntervalSince1970 * 1000
      let earliestDay = min(todayStart, calendar.startOfDay(for: Date(timeIntervalSince1970: minDatedMs / 1000)))
      let daySpan = max(1, (calendar.dateComponents([.day], from: earliestDay, to: todayStart).day ?? 0) + 1)

      if daySpan <= 30 {
        title = "历史按日趋势"
        let count = max(7, daySpan)
        let start = calendar.date(byAdding: .day, value: -(count - 1), to: todayStart) ?? todayStart
        for offset in 0..<count {
          let day = calendar.date(byAdding: .day, value: offset, to: start) ?? todayStart
          let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
          let label = monthDayFormatter.string(from: day)
          let detail = fullDateFormatter.string(from: day)
          buckets.append(TokenTrendBucket(
            id: "d-\(detail)", axisLabel: label, detailTitle: detail,
            startMs: day.timeIntervalSince1970 * 1000, endMs: nextDay.timeIntervalSince1970 * 1000))
        }
        axisIndices = sparseAxisIndices(count: count, target: 5)
        spanDaysForAvg = Double(daySpan)
      } else if daySpan <= 120 {
        title = "历史按周趋势"
        let weekCount = max(2, Int(ceil(Double(daySpan) / 7.0)))
        let totalSpanDays = weekCount * 7
        let start = calendar.date(byAdding: .day, value: -(totalSpanDays - 1), to: todayStart) ?? earliestDay
        for w in 0..<weekCount {
          let wStart = calendar.date(byAdding: .day, value: w * 7, to: start) ?? start
          let wEnd = calendar.date(byAdding: .day, value: (w + 1) * 7, to: start) ?? wStart.addingTimeInterval(7 * 86400)
          let wLast = calendar.date(byAdding: .day, value: -1, to: wEnd) ?? wEnd
          let label = monthDayFormatter.string(from: wStart)
          let detail = "\(monthDayFormatter.string(from: wStart)) – \(monthDayFormatter.string(from: wLast))"
          buckets.append(TokenTrendBucket(
            id: "w-\(w)", axisLabel: label, detailTitle: detail,
            startMs: wStart.timeIntervalSince1970 * 1000, endMs: wEnd.timeIntervalSince1970 * 1000))
        }
        axisIndices = sparseAxisIndices(count: weekCount, target: 5)
        spanDaysForAvg = Double(daySpan)
      } else {
        title = "历史按月趋势"
        let startComps = calendar.dateComponents([.year, .month], from: earliestDay)
        let endComps = calendar.dateComponents([.year, .month], from: todayStart)
        var cursor = calendar.date(from: startComps) ?? earliestDay
        let limitDate = calendar.date(from: endComps) ?? todayStart
        var safety = 0
        while cursor <= limitDate && safety < 240 {
          safety += 1
          let nextMonth = calendar.date(byAdding: .month, value: 1, to: cursor) ?? cursor.addingTimeInterval(31 * 86400)
          let label = yearMonthFormatter.string(from: cursor)
          buckets.append(TokenTrendBucket(
            id: "m-\(label)", axisLabel: label, detailTitle: label,
            startMs: cursor.timeIntervalSince1970 * 1000, endMs: nextMonth.timeIntervalSince1970 * 1000))
          cursor = nextMonth
        }
        axisIndices = sparseAxisIndices(count: buckets.count, target: 5)
        spanDaysForAvg = Double(daySpan)
      }
    }

    var datedTotal = 0.0
    if !buckets.isEmpty {
      let minStart = buckets.first!.startMs
      let maxEnd = buckets.last!.endMs
      for entry in entries {
        guard let t = entry.timestampMs, t >= minStart else { continue }
        let clamped = min(t, maxEnd - 1)
        let idx: Int
        if range == .today {
          idx = min(buckets.count - 1, max(0, Int((clamped - minStart) / 3_600_000.0)))
        } else if buckets.count <= 31 && range != .all {
          idx = min(buckets.count - 1, max(0, Int((clamped - minStart) / dayMs)))
        } else {
          idx = buckets.lastIndex(where: { clamped >= $0.startMs && clamped < $0.endMs })
            ?? (clamped >= maxEnd - 1 ? buckets.count - 1 : 0)
        }
        if entry.source == .hostCounter {
          buckets[idx].hostFallback += entry.totalTokens
        } else {
          buckets[idx].input += entry.input
          buckets[idx].cacheWrite += entry.cacheWrite
          buckets[idx].cacheRead += entry.cacheRead
          buckets[idx].output += entry.output
        }
        buckets[idx].totalTokens += entry.totalTokens
        datedTotal += entry.totalTokens
      }
    }

    let peakBucket = buckets.max(by: { $0.totalTokens < $1.totalTokens })
    let peakTokens = peakBucket?.totalTokens ?? 0
    let peakLabel = peakTokens > 0 ? peakBucket?.detailTitle : nil
    let averagePerDay = spanDaysForAvg.flatMap { $0 > 0 ? datedTotal / $0 : nil }
    return (title, buckets, axisIndices, averagePerDay, peakTokens, peakLabel)
  }

  private static func sparseAxisIndices(count: Int, target: Int) -> [Int] {
    guard count > 0 else { return [] }
    if count <= target { return Array(0..<count) }
    var indices = [0]
    let step = Double(count - 1) / Double(target - 1)
    for k in 1..<(target - 1) {
      let idx = Int((Double(k) * step).rounded())
      if idx > (indices.last ?? -1) && idx < count - 1 {
        indices.append(idx)
      }
    }
    if indices.last != count - 1 { indices.append(count - 1) }
    return indices
  }

  private static func buildModels(
    entries: [TokenUsageEntry], scope: TokenStatsToolScope, grandTotal: Double
  ) -> [TokenBreakdownRow] {
    var groups = [String: Accumulator]()
    for entry in entries {
      let name = SessionTitle.nonempty(entry.model) ?? "未知模型"
      groups[name, default: Accumulator()].add(entry)
    }
    return groups.map { name, acc in
      let share = grandTotal > 0 ? acc.totalTokens / grandTotal : 0
      let badge: String?
      if scope == .all {
        if acc.providers.count > 1 { badge = "Codex + Kimi" }
        else { badge = acc.providers.first.map(providerShortName) }
      } else {
        badge = nil
      }
      var subParts = [String]()
      if acc.sessions.count > 0 { subParts.append("\(acc.sessions.count) 个会话") }
      if acc.requestCount > 0 { subParts.append("\(acc.requestCount) 次请求") }
      let subtitle = subParts.isEmpty ? "宿主计数或未记录请求" : subParts.joined(separator: " · ")
      return TokenBreakdownRow(
        id: "model:" + name,
        title: name,
        subtitle: subtitle,
        badge: badge,
        toolTip: name + (subtitle.isEmpty ? "" : "\n" + subtitle),
        input: acc.input, cacheWrite: acc.cacheWrite, cacheRead: acc.cacheRead, output: acc.output,
        hostFallback: acc.hostFallback, totalTokens: acc.totalTokens, share: share,
        cacheHitPercent: acc.cacheHitPercent, requestCount: acc.requestCount, sessionCount: acc.sessions.count)
    }.sorted {
      if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
      return $0.title < $1.title
    }
  }

  private static func buildProjects(
    entries: [TokenUsageEntry], scope: TokenStatsToolScope, grandTotal: Double
  ) -> [TokenBreakdownRow] {
    var groups = [String: Accumulator]()
    for entry in entries {
      var acc = groups[entry.projectKey] ?? Accumulator()
      if acc.title.isEmpty {
        acc.title = entry.projectTitle
        acc.subtitle = entry.projectSubtitle
      } else if entry.projectSubtitle != nil && acc.subtitle == nil {
        acc.subtitle = entry.projectSubtitle
      }
      acc.add(entry)
      groups[entry.projectKey] = acc
    }
    return groups.map { key, acc in
      let share = grandTotal > 0 ? acc.totalTokens / grandTotal : 0
      let badge: String?
      if scope == .all {
        if acc.providers.count > 1 { badge = "Codex + Kimi" }
        else { badge = acc.providers.first.map(providerShortName) }
      } else {
        badge = nil
      }
      let subtitle = acc.subtitle ?? "\(acc.sessions.count) 个会话"
      let tip = acc.subtitle.map { "\(acc.title)\n\($0)" } ?? acc.title
      return TokenBreakdownRow(
        id: "project:" + key,
        title: acc.title,
        subtitle: subtitle,
        badge: badge,
        toolTip: tip,
        input: acc.input, cacheWrite: acc.cacheWrite, cacheRead: acc.cacheRead, output: acc.output,
        hostFallback: acc.hostFallback, totalTokens: acc.totalTokens, share: share,
        cacheHitPercent: acc.cacheHitPercent, requestCount: acc.requestCount, sessionCount: acc.sessions.count)
    }.sorted {
      if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
      return $0.title < $1.title
    }
  }

  private static func buildSessions(
    entries: [TokenUsageEntry], scope: TokenStatsToolScope, grandTotal: Double
  ) -> [TokenBreakdownRow] {
    var groups = [String: Accumulator]()
    var sharedAcc = Accumulator()
    var hasShared = false

    for entry in entries {
      if entry.isSharedCrossSession {
        hasShared = true
        sharedAcc.add(entry)
        continue
      }
      let key = "\(entry.provider.rawValue):\(entry.sessionKey)"
      var acc = groups[key] ?? Accumulator()
      if acc.title.isEmpty {
        acc.title = entry.sessionTitle
        acc.subtitle = entry.projectTitle
      }
      acc.add(entry)
      groups[key] = acc
    }

    var rows = groups.map { key, acc -> TokenBreakdownRow in
      let share = grandTotal > 0 ? acc.totalTokens / grandTotal : 0
      let providerLabel = acc.providers.first.map(providerShortName) ?? ""
      let badge: String?
      if scope == .all {
        badge = acc.archived ? "\(providerLabel) · 已归档" : providerLabel
      } else {
        badge = acc.archived ? "已归档" : nil
      }
      let subtitle = acc.subtitle ?? ""
      let tip = subtitle.isEmpty ? acc.title : "\(acc.title)\n项目：\(subtitle)"
      return TokenBreakdownRow(
        id: "session:" + key,
        title: acc.title,
        subtitle: subtitle,
        badge: badge,
        toolTip: tip,
        input: acc.input, cacheWrite: acc.cacheWrite, cacheRead: acc.cacheRead, output: acc.output,
        hostFallback: acc.hostFallback, totalTokens: acc.totalTokens, share: share,
        cacheHitPercent: acc.cacheHitPercent, requestCount: acc.requestCount, sessionCount: 1)
    }.sorted {
      if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
      return $0.title < $1.title
    }

    if hasShared && sharedAcc.totalTokens > 0 {
      let share = grandTotal > 0 ? sharedAcc.totalTokens / grandTotal : 0
      rows.append(
        TokenBreakdownRow(
          id: "session:__shared__",
          title: "跨会话共享历史（去重）",
          subtitle: "派生或分叉会话共享的相同历史请求，按口径只计一次",
          badge: "去重",
          toolTip: "多个分叉会话复制自同一历史请求，已在汇总时去重仅计一次。",
          input: sharedAcc.input, cacheWrite: sharedAcc.cacheWrite,
          cacheRead: sharedAcc.cacheRead, output: sharedAcc.output,
          hostFallback: sharedAcc.hostFallback, totalTokens: sharedAcc.totalTokens,
          share: share, cacheHitPercent: sharedAcc.cacheHitPercent,
          requestCount: sharedAcc.requestCount, sessionCount: 0))
    }
    return rows
  }
}
