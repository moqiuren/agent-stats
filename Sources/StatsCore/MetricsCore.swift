import CoreFoundation
import Foundation

package typealias JSONObject = [String: Any]
package let jsonNull = NSNull()
package func jsonObject(_ value: Any?) -> JSONObject { value as? JSONObject ?? [:] }
package func number(_ value: Any?) -> Double? {
  guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite
  else { return nil }
  return n.doubleValue
}
package func nonnegative(_ value: Any?) -> Double? {
  guard let n = number(value), n >= 0 else { return nil }
  return n
}
package func identifier(_ value: Any?) -> String {
  if let value = value as? String { return value }
  if let value = value as? NSNumber { return value.stringValue }
  return "undefined"
}
package func nullable<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? jsonNull }
package func sum(_ values: [JSONObject], _ key: String) -> Double {
  values.reduce(0) { $0 + (nonnegative($1[key]) ?? 0) }
}
package func spanMilliseconds(_ spans: [(Double, Double)]) -> Double {
  var end = -Double.infinity
  var total = 0.0
  for (a, b) in spans.sorted(by: { $0.0 < $1.0 }) where a.isFinite && b.isFinite && b >= a {
    total += max(0, b - max(a, end))
    end = max(end, b)
  }
  return total
}
// Union coverage of spans clipped into [start, end]. Codex item rows can carry a
// completed_at_ms that is really the log-write time (a completed command whose
// rows arrive with the next record), so an unclipped interval swallows unrelated
// items and fabricates huge tool spans; every turn-scoped projection must clamp.
package func windowedSpanMilliseconds(_ spans: [(Double, Double)], _ start: Double, _ end: Double)
  -> Double
{
  spanMilliseconds(spans.map { (max($0.0, start), min($0.1, end)) }.filter { $0.1 >= $0.0 })
}

package struct OrderedRecords {
  private var keys = [String]()
  private var records = [String: JSONObject]()
  package subscript(_ key: String) -> JSONObject? {
    get { records[key] }
    set {
      if records[key] == nil && newValue != nil { keys.append(key) }
      records[key] = newValue
    }
  }
  package var values: [JSONObject] { keys.compactMap { records[$0] } }
  package var count: Int { records.count }
  package mutating func update(_ key: String, _ body: (inout JSONObject) -> Void) {
    var record = self[key] ?? [:]
    body(&record)
    self[key] = record
  }
  package var cacheState: JSONObject { ["keys": keys, "records": records] }
  package mutating func restore(_ state: JSONObject) -> Bool {
    guard let keys = state["keys"] as? [String],
      let records = state["records"] as? [String: JSONObject]
    else { return false }
    self.keys = keys
    self.records = records
    return true
  }
  package init() {}
}
package protocol SessionMetrics: AnyObject {
  var issues: Int { get set }
  func accept(_ record: JSONObject)
  func snapshot(now: Double) -> JSONObject
  // A collector that does not implement both sides stays uncached, so a missing
  // or partial state can never be mistaken for a complete parse.
  var cacheState: JSONObject? { get }
  func restore(_ state: JSONObject) -> Bool
}

extension SessionMetrics {
  package var cacheState: JSONObject? { nil }
  package func restore(_ state: JSONObject) -> Bool { false }
}
