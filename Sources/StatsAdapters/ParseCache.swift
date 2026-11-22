import Foundation
import StatsCore

// Persists the parsed accumulator state of session logs so a new process resumes
// instead of replaying every history file. This is performance-only state: every
// entry is validated against the file fingerprint before use, and any decode
// failure or mismatch falls back to a full parse, so a damaged cache can never
// invent or drop usage.
package final class ParseCacheStore {
  private let clock: StatsClock
  private let path: URL
  private let maximumBytes: Int
  private var entries: [String: JSONObject]
  private var dirty = false
  private var lastFlush = Date.distantPast

  package init(
    path: URL, maximumBytes: Int = 64 * 1024 * 1024, clock: StatsClock = SystemStatsClock()
  ) {
    self.clock = clock
    self.path = path
    self.maximumBytes = maximumBytes
    entries = [:]
    guard let data = try? Data(contentsOf: path),
      let object = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
      number(object["version"]) == 1,
      let stored = object["entries"] as? [String: JSONObject]
    else { return }
    entries = stored
  }

  package var count: Int { entries.count }

  // A released reader (provider switch, idle expiry or memory pressure) must not
  // drop work that has not reached the debounced flush yet.
  deinit { flush() }

  package func entry(for key: String) -> JSONObject? { entries[key] }

  package func store(_ key: String, _ entry: JSONObject) {
    entries[key] = entry
    dirty = true
  }

  // Entries for files the current scan did not read are dead weight; dropping them
  // also bounds the cache when a host prunes or archives its session logs.
  package func removeAll(except live: Set<String>) {
    guard entries.count != live.count || !entries.keys.allSatisfy(live.contains) else { return }
    entries = entries.filter { live.contains($0.key) }
    dirty = true
  }

  package func flushIfDue(interval: TimeInterval, now: Date? = nil) {
    let now = now ?? clock.now
    guard dirty, now.timeIntervalSince(lastFlush) >= interval else { return }
    flush()
  }

  package func flush() {
    guard dirty else { return }
    guard var data = encode(entries) else { return }
    // Keep the entries that save the most parsing: the largest states win the
    // budget, and a state that cannot fit is simply re-parsed next launch.
    if data.count > maximumBytes {
      entries = prunedToBudget()
      guard let smaller = encode(entries) else { return }
      data = smaller
    }
    try? FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Only a completed write clears the dirty state: a failed write keeps the
    // work pending so a later flush retries instead of silently losing it.
    // The retry is still throttled by the usual interval.
    do {
      try data.write(to: path, options: .atomic)
      dirty = false
    } catch {}
    lastFlush = clock.now
  }

  private func encode(_ values: [String: JSONObject]) -> Data? {
    try? JSONSerialization.data(
      withJSONObject: ["version": 1, "entries": values] as JSONObject, options: [.sortedKeys])
  }

  private func prunedToBudget() -> [String: JSONObject] {
    let sized = entries.compactMap { key, value -> (String, JSONObject, Int)? in
      guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
      return (key, value, data.count)
    }.sorted { $0.2 > $1.2 }
    var kept = [String: JSONObject]()
    var budget = maximumBytes
    for (key, value, size) in sized {
      guard size <= budget else { continue }
      budget -= size
      kept[key] = value
    }
    return kept
  }
}
