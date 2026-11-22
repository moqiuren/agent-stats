import CZstd
import Foundation
import SQLite3
@testable import StatsAdapters
@testable import StatsCore

enum UsageHistoryReaderTests {
  static func main() throws {
    var checks = 0
    func check(_ value: Bool, _ message: String) {
      precondition(value, message)
      checks += 1
    }

    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "usage-history-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    func writeJSONL(_ lines: [JSONObject], to file: URL) throws {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      var data = Data()
      for line in lines {
        data.append(try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]))
        data.append(10)
      }
      try data.write(to: file)
    }

    let codexRoot = base.appendingPathComponent("codex")
    let kimiRoot = base.appendingPathComponent("kimi")
    let cacheDir = base.appendingPathComponent("cache")

    // Build Codex fixture with:
    // 1) Active session with turn_context model attribution
    // 2) Archived session (must be included by UsageHistoryReader, excluded by CodexSessionReader)
    // 3) Missing rollout thread falling back to host tokens_used
    // 4) Subagent sharing a request ID with main session (deduplicated)
    let activeID = "11111111-1111-4111-8111-111111111111"
    let subID = "22222222-2222-4222-8222-222222222222"
    let archivedID = "33333333-3333-4333-8333-333333333333"
    let hostOnlyID = "44444444-4444-4444-8444-444444444444"

    let activeFile = codexRoot.appendingPathComponent("sessions/rollout-\(activeID).jsonl")
    let subFile = codexRoot.appendingPathComponent("sessions/rollout-\(subID).jsonl")
    let archivedFile = codexRoot.appendingPathComponent("archived_sessions/rollout-\(archivedID).jsonl")

    try writeJSONL(
      [
        [
          "type": "session_meta",
          "timestamp": "2026-11-22T02:00:00.000Z",
          "payload": ["id": activeID, "cwd": "/work/shared-repo", "source": "vscode"],
        ],
        [
          "type": "turn_context",
          "timestamp": "2026-11-22T02:00:01.000Z",
          "payload": ["turn_id": "t1", "model": "gpt-6-astra"],
        ],
        [
          "type": "token_usage_record",
          "timestamp": "2026-11-22T02:00:05.000Z",
          "payload": [
            "turn_id": "t1",
            "response_id": "req-main-1",
            "usage": [
              "input_tokens": 100,
              "cached_input_tokens": 40,
              "cache_write_input_tokens": 10,
              "output_tokens": 20,
            ],
          ],
        ],
      ], to: activeFile)

    try writeJSONL(
      [
        [
          "type": "session_meta",
          "timestamp": "2026-11-22T02:01:00.000Z",
          "payload": [
            "id": subID,
            "cwd": "/work/shared-repo",
            "source": ["subagent": ["thread_spawn": ["parent_thread_id": activeID]]],
          ],
        ],
        [
          "type": "turn_context",
          "timestamp": "2026-11-22T02:01:01.000Z",
          "payload": ["turn_id": "ts1", "model": "gpt-5.6-mini"],
        ],
        // Echoed parent request must count once across the task.
        [
          "type": "token_usage_record",
          "timestamp": "2026-11-22T02:00:05.000Z",
          "payload": [
            "response_id": "req-main-1",
            "usage": [
              "input_tokens": 100,
              "cached_input_tokens": 40,
              "cache_write_input_tokens": 10,
              "output_tokens": 20,
            ],
          ],
        ],
        [
          "type": "token_usage_record",
          "timestamp": "2026-11-22T02:01:05.000Z",
          "payload": [
            "turn_id": "ts1",
            "response_id": "req-sub-1",
            "usage": [
              "input_tokens": 50,
              "cached_input_tokens": 0,
              "output_tokens": 10,
            ],
          ],
        ],
      ], to: subFile)

    try writeJSONL(
      [
        [
          "type": "session_meta",
          "timestamp": "2026-11-10T02:00:00.000Z",
          "payload": ["id": archivedID, "cwd": "/work/archived-proj", "source": "vscode"],
        ],
        [
          "type": "turn_context",
          "timestamp": "2026-11-10T02:00:01.000Z",
          "payload": ["turn_id": "ta1", "model": "gpt-5.6-sol"],
        ],
        [
          "type": "token_usage_record",
          "timestamp": "2026-11-10T02:00:05.000Z",
          "payload": [
            "turn_id": "ta1",
            "response_id": "req-arch-1",
            "usage": [
              "input_tokens": 200,
              "cached_input_tokens": 100,
              "output_tokens": 50,
            ],
          ],
        ],
      ], to: archivedFile)

    try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
    let dbURL = codexRoot.appendingPathComponent("state_5.sqlite")
    var db: OpaquePointer?
    check(sqlite3_open(dbURL.path, &db) == SQLITE_OK, "sqlite opens")
    let ddl = """
      CREATE TABLE projects(id TEXT, name TEXT, position INTEGER);
      CREATE TABLE threads(
        id TEXT, title TEXT, rollout_path TEXT, archived INTEGER, updated_at INTEGER,
        thread_source TEXT, source TEXT, parent_thread_id TEXT, cwd TEXT, project_id TEXT,
        tokens_used INTEGER, model TEXT
      );
      """
    check(sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK, "sqlite ddl")
    let insert = """
      INSERT INTO threads VALUES
      ('\(activeID)','Active Task','\(activeFile.path)',0,1795312805,'user','vscode',NULL,'/work/shared-repo',NULL,180,'gpt-6-astra'),
      ('\(subID)','Sub Task','\(subFile.path)',0,1795312865,'subagent','vscode','\(activeID)','/work/shared-repo',NULL,60,'gpt-5.6-mini'),
      ('\(archivedID)','Archived Task','\(archivedFile.path)',1,1794276005,'user','vscode',NULL,'/work/archived-proj',NULL,250,'gpt-5.6-sol'),
      ('\(hostOnlyID)','Host Fallback Task','\(codexRoot.appendingPathComponent("sessions/missing.jsonl").path)',1,1794000000,'user','vscode',NULL,'/work/host-only',NULL,777,'gpt-5-codex');
      """
    check(sqlite3_exec(db, insert, nil, nil, nil) == SQLITE_OK, "sqlite inserts")
    sqlite3_close(db)

    // Build Kimi fixture with both active & archived sessions and task model fallback.
    let kimiActiveDir = kimiRoot.appendingPathComponent("sessions/ws1/kimi-active")
    let kimiArchDir = kimiRoot.appendingPathComponent("sessions/ws1/kimi-archived")
    try writeJSONL(
      [
        ["type": "profile.bind", "modelAlias": "kimi-code/k3", "time": 1795312900000.0],
        [
          "type": "usage.record",
          "requestId": "k-1",
          "time": 1795312901000.0,
          "usage": ["inputOther": 30, "inputCacheRead": 70, "inputCacheCreation": 10, "output": 40],
        ],
      ], to: kimiActiveDir.appendingPathComponent("agents/main/wire.jsonl"))
    try FileManager.default.createDirectory(at: kimiActiveDir, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: [
      "title": "Kimi Active",
      "cwd": "/work/shared-repo",
      "archived": false,
      "agents": ["main": [:], "emptySub": ["parentAgentId": "main"]],
    ]).write(to: kimiActiveDir.appendingPathComponent("state.json"))

    try writeJSONL(
      [
        [
          "type": "usage.record",
          "requestId": "k-arch-1",
          "time": 1794300000000.0,
          "usage": ["inputOther": 80, "inputCacheRead": 20, "output": 50],
        ],
      ], to: kimiArchDir.appendingPathComponent("agents/main/wire.jsonl"))
    try FileManager.default.createDirectory(at: kimiArchDir, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["title": "Kimi Archived", "cwd": "/work/kimi-arch", "archived": true])
      .write(to: kimiArchDir.appendingPathComponent("state.json"))

    // 1. Live HUD CodexSessionReader must still skip the archived root thread!
    let liveCodex = CodexSessionReader(root: codexRoot).scan(selected: nil, now: 1795320000000)
    check(liveCodex.sessions.count == 1 && liveCodex.sessions[0].statistics.id == activeID,
          "live CodexSessionReader continues skipping archived threads")

    // 2. Historical UsageHistoryReader must include active + archived + host fallback.
    let reader = UsageHistoryReader(
      roots: [.codex: codexRoot, .kimi: kimiRoot], cacheDirectory: cacheDir)
    let firstScan = reader.scanAll(now: 1795320000000)
    reader.flushCaches()

    let nowDate = Date(timeIntervalSince1970: 1795320000)
    let report = TokenStatsAggregator.aggregate(
      corpora: firstScan, scope: .all, range: .all, now: nowDate)
    // Codex active (120) + sub (60) + archived (250) + host fallback (777) = 1207
    // Kimi active (150) + archived (150) = 300
    // Combined = 1507
    check(report.totalTokens == 1507, "historical scan combines active, archived and host-fallback totals accurately (got \(report.totalTokens))")
    check(report.hostFallbackTokens == 777, "host fallback tokens are isolated cleanly")
    check(report.archivedSessionCount == 3, "counts archived Codex + host-only + archived Kimi sessions")
    check(report.models.contains(where: { $0.title == "gpt-6-astra" && $0.totalTokens == 120 }),
          "Codex turn_context model is attributed onto token_usage_record")
    check(report.models.contains(where: { $0.title == "gpt-5.6-mini" && $0.totalTokens == 60 }),
          "Codex subagent model attribution stays distinct")
    check(report.models.contains(where: { $0.title == "kimi-code/k3" && $0.totalTokens == 150 }),
          "Kimi profile.bind model is attributed onto usage.record")
    check(report.projects.contains(where: { $0.title == "shared-repo" && $0.totalTokens == 330 }),
          "same cwd merges Codex (180) and Kimi (150) under shared-repo")

    // 3. Cache parity: a brand-new UsageHistoryReader restores from disk with zero parsed bytes!
    let warmReader = UsageHistoryReader(
      roots: [.codex: codexRoot, .kimi: kimiRoot], cacheDirectory: cacheDir)
    let warmScan = warmReader.scanAll(now: 1795320000000)
    check(warmReader.restoredLogs(for: .codex) == 3 && warmReader.parsedBytes(for: .codex) == 0,
          "warm Codex history scan restores all 3 logs with zero bytes read")
    check(warmReader.restoredLogs(for: .kimi) == 2 && warmReader.parsedBytes(for: .kimi) == 0,
          "warm Kimi history scan restores both logs with zero bytes read")
    check(warmScan == firstScan, "warm cached history corpus matches cold scan identically")

    print("\(checks) usage history reader checks passed")
  }
}
