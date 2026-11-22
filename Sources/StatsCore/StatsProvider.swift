import Foundation

package enum StatsProvider: String, CaseIterable {
  case codex, kimi

  /// Only a host that exposes a reliable current-conversation identifier can follow
  /// the foreground conversation. The Codex host loads one document and navigates
  /// with a memory router, so its automatic mode is not offered at all instead of
  /// appearing as a permanently unavailable choice.
  package var supportsAutomaticSessionFollow: Bool { self == .kimi }
}
