import Foundation
@testable import StatsCore

enum TokenStatsTests {
  static func main() throws {
    var checks = 0
    func check(_ value: Bool, _ message: String) {
      precondition(value, message)
      checks += 1
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 15, minute: 30))!
    let nowMs = now.timeIntervalSince1970 * 1000
    let today10amMs = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 10, minute: 15))!.timeIntervalSince1970 * 1000
    let daysAgo3Ms = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 12, minute: 0))!.timeIntervalSince1970 * 1000
    let daysAgo20Ms = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12, minute: 0))!.timeIntervalSince1970 * 1000
    let daysAgo200Ms = calendar.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 12, minute: 0))!.timeIntervalSince1970 * 1000

    let codexEntries: [TokenUsageEntry] = [
      TokenUsageEntry(
        provider: .codex, timestampMs: today10amMs, model: "gpt-5.6-sol",
        projectKey: "cwd:/work/app", projectTitle: "app", projectSubtitle: "/work/app",
        sessionKey: "c1", sessionTitle: "今日新任务", archived: false,
        source: .requests, input: 100, cacheRead: 300, cacheWrite: 50, output: 150,
        totalTokens: 600, requestCount: 2),
      TokenUsageEntry(
        provider: .codex, timestampMs: daysAgo20Ms, model: "gpt-5.6-sol",
        projectKey: "cwd:/work/app", projectTitle: "app", projectSubtitle: "/work/app",
        sessionKey: "c2", sessionTitle: "归档优化", archived: true,
        source: .requests, input: 200, cacheRead: 600, cacheWrite: 0, output: 200,
        totalTokens: 1000, requestCount: 4),
      TokenUsageEntry(
        provider: .codex, timestampMs: daysAgo200Ms, model: nil,
        projectKey: "cwd:/work/legacy", projectTitle: "legacy", projectSubtitle: "/work/legacy",
        sessionKey: "c3", sessionTitle: "丢失日志的旧任务", archived: true,
        source: .hostCounter, input: 0, cacheRead: 0, cacheWrite: 0, output: 0,
        totalTokens: 500, requestCount: 0),
      TokenUsageEntry(
        provider: .codex, timestampMs: nil, model: "gpt-5.6-sol",
        projectKey: "codex:unknown", projectTitle: "未归属项目", projectSubtitle: nil,
        sessionKey: "__shared__", sessionTitle: "跨会话共享历史（去重）", archived: false,
        isSharedCrossSession: true, source: .requests,
        input: 40, cacheRead: 60, cacheWrite: 0, output: 20,
        totalTokens: 120, requestCount: 1),
    ]

    let kimiEntries: [TokenUsageEntry] = [
      TokenUsageEntry(
        provider: .kimi, timestampMs: daysAgo3Ms, model: "kimi-code/k3",
        projectKey: "cwd:/work/app", projectTitle: "app", projectSubtitle: "/work/app",
        sessionKey: "k1", sessionTitle: "Kimi 协同", archived: false,
        source: .requests, input: 50, cacheRead: 400, cacheWrite: 50, output: 100,
        totalTokens: 600, requestCount: 3),
    ]

    let corpora: [StatsProvider: ProviderTokenCorpus] = [
      .codex: ProviderTokenCorpus(
        provider: .codex, collectedAt: nowMs, entries: codexEntries,
        totalSessions: 3, archivedSessions: 2, ambiguousSessions: 0, hostFallbackSessions: 1),
      .kimi: ProviderTokenCorpus(
        provider: .kimi, collectedAt: nowMs, entries: kimiEntries,
        totalSessions: 1, archivedSessions: 0, ambiguousSessions: 0, hostFallbackSessions: 0),
    ]

    let todayReport = TokenStatsAggregator.aggregate(
      corpora: corpora, scope: .all, range: .today, now: now, calendar: calendar)
    check(todayReport.buckets.count == 24, "today range has 24 hourly buckets")
    check(todayReport.totalTokens == 600 && todayReport.combinedInputTokens == 150,
          "today report includes cacheWrite inside combinedInputTokens")
    check(todayReport.buckets[10].totalTokens == 600 && todayReport.buckets[10].cacheRead == 300,
          "hourly bucket places 10:15 into slot 10")

    let days7Report = TokenStatsAggregator.aggregate(
      corpora: corpora, scope: .all, range: .days7, now: now, calendar: calendar)
    check(days7Report.buckets.count == 7, "7-day range has 7 daily buckets")
    check(days7Report.totalTokens == 1200 && days7Report.sessionCount == 2,
          "7-day range combines Codex today and Kimi 3 days ago")
    check(days7Report.projects.count == 1 && days7Report.projects[0].title == "app" && days7Report.projects[0].badge == "Codex + Kimi",
          "same cwd project merges across Codex and Kimi under .all scope")

    let days30Report = TokenStatsAggregator.aggregate(
      corpora: corpora, scope: .all, range: .days30, now: now, calendar: calendar)
    check(days30Report.buckets.count == 30, "30-day range has 30 daily buckets")
    check(days30Report.totalTokens == 2200 && days30Report.archivedSessionCount == 1,
          "30-day range includes archived session within 30 days")

    let allReport = TokenStatsAggregator.aggregate(
      corpora: corpora, scope: .all, range: .all, now: now, calendar: calendar)
    check(allReport.totalTokens == 2820, "all-time includes undated cross-session shared and 200-day host fallback")
    check(allReport.hostFallbackTokens == 500 && allReport.inputTokens == 390 && allReport.cacheWriteTokens == 100 && allReport.combinedInputTokens == 490,
          "host fallback stays separate without fabricating input or output")
    check(allReport.trendTitle == "历史按月趋势" && allReport.buckets.count >= 7,
          "200-day span adapts to monthly buckets")
    let expectedHit = 1360.0 * 100.0 / (390.0 + 100.0 + 1360.0)
    check(abs((allReport.cacheHitPercent ?? -1) - expectedHit) < 0.0001,
          "cacheHitPercent includes input, cacheWrite and cacheRead in denominator")
    check(abs(allReport.models.reduce(0) { $0 + $1.totalTokens } - allReport.totalTokens) < 0.001,
          "models breakdown sums to grand total")
    check(abs(allReport.projects.reduce(0) { $0 + $1.totalTokens } - allReport.totalTokens) < 0.001,
          "projects breakdown sums to grand total")
    check(abs(allReport.sessions.reduce(0) { $0 + $1.totalTokens } - allReport.totalTokens) < 0.001,
          "sessions breakdown including shared history row sums to grand total")
    check(allReport.sessions.contains(where: { $0.id == "session:__shared__" && $0.totalTokens == 120 }),
          "cross-session shared history row reconciles session total")

    let kimiOnly = TokenStatsAggregator.aggregate(
      corpora: corpora, scope: .kimi, range: .all, now: now, calendar: calendar)
    check(kimiOnly.totalTokens == 600 && kimiOnly.models.map(\.title) == ["kimi-code/k3"],
          "single-provider scope isolates Kimi entries")

    // Native Int bridging through ProviderTokenCorpus.fromCatalog
    let catalog = StatsCatalog([
      "sessions": [
        [
          "id": "native-int-session",
          "title": "原生整型会话",
          "input": 100,
          "cacheWrite": 25,
          "cacheRead": 300,
          "output": 75,
          "totalTokens": 500,
          "turns": 3,
          "updatedAt": Int64(today10amMs),
          "model": "gpt-6-astra",
          "archived": false,
          "project": ["id": "p", "cwd": "/work/native"],
          "group": ["id": "g1", "title": "原生项目"],
        ] as JSONObject
      ]
    ])
    let catalogCorpus = ProviderTokenCorpus.fromCatalog(catalog, provider: .codex, collectedAt: nowMs)
    let catalogReport = TokenStatsAggregator.aggregate(
      corpora: [.codex: catalogCorpus], scope: .codex, range: .today, now: now, calendar: calendar)
    check(catalogReport.totalTokens == 500 && catalogReport.combinedInputTokens == 125 && catalogReport.projects[0].title == "原生项目",
          "fromCatalog preserves native integer token counters and group titles")

    print("\(checks) token stats checks passed")
  }
}
