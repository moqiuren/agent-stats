import StatsCore
import StatsAdapters
import Foundation

func seconds(_ x: Any?) -> String {
  guard let n = number(x), n.isFinite else { return "—" }
  if n < 60000 { return String(format: "%.2f 秒", n / 1000) }
  return "\(Int(n/60000)) 分 \(Int(n/1000) % 60) 秒"
}
func count(_ x: Any?) -> String {
  guard let n = number(x) else { return "—" }
  if n >= 1_000_000 { return String(format: "%.2fM", n / 1_000_000) }
  if n >= 1000 { return String(format: "%.1fk", n / 1000) }
  return String(format: "%.0f", n)
}
func compactTokenCount(_ x: Any?) -> String {
  guard let n = number(x) else { return "—" }
  if n >= 1_000_000_000 { return String(format: "%.2fB", n / 1_000_000_000) }
  if n >= 1_000_000 { return String(format: "%.2fM", n / 1_000_000) }
  if n >= 1000 { return String(format: "%.1fk", n / 1000) }
  return String(format: "%.0f", n)
}
func decimal(_ x: Any?, suffix: String = "") -> String {
  guard let n = number(x), n.isFinite else { return "—" }
  return String(format: "%.1f", n) + suffix
}
// Creating a NumberFormatter costs far more than the formatting itself, and every
// HUD render, settings preview and inspector row needs one. Main-thread UI only.
let exactCountFormatter: NumberFormatter = {
  let formatter = NumberFormatter()
  formatter.numberStyle = .decimal
  formatter.maximumFractionDigits = 0
  return formatter
}()
// A plugin report is a wall-clock timestamp, so it needs one shared formatter
// instead of a new DateFormatter per panel refresh.
let clockFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "HH:mm"
  return formatter
}()

func shortTime(_ value: Any?) -> String {
  guard let n = number(value), n.isFinite else { return "—" }
  if n < 60000 { return String(format: "%.1fs", n / 1000) }
  if n < 3_600_000 { return String(format: "%.0fm", n / 60000) }
  return String(format: "%.1fh", n / 3_600_000)
}
func exactCount(_ value: Any?) -> String {
  guard let n = number(value) else { return "—" }
  return exactCountFormatter.string(from: NSNumber(value: n)) ?? "—"
}
