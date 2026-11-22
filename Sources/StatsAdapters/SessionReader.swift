import Foundation
import StatsCore

protocol ProviderSessionReading: StatsReading {
  var logs: SessionLogStore { get }
}

// Compatibility entry point shared by the app, CLI and benchmarks. Selection is
// still accepted, but collection remains complete for cross-session deduplication
// and project totals. Choosing a visible session belongs to StatsState.
package final class SessionReader: StatsReading {
  private let clock: StatsClock
  private let reader: ProviderSessionReading
  package init(
    root: URL, provider: StatsProvider, cache: ParseCacheStore? = nil,
    clock: StatsClock = SystemStatsClock()
  ) {
    self.clock = clock
    switch provider {
    case .codex: reader = CodexSessionReader(root: root, cache: cache)
    case .kimi: reader = KimiSessionReader(root: root, cache: cache)
    }
  }
  package var restoredLogs: Int { reader.logs.restoredLogs }
  package var parsedBytes: UInt64 { reader.logs.parsedBytes }
  package func scan(selected: String?, now: Double) -> StatsSnapshot {
    reader.scan(selected: selected, now: now)
  }
  package func scan(selected: String?) -> StatsSnapshot {
    scan(selected: selected, now: clock.milliseconds)
  }
}
