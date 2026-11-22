import Foundation

package enum SessionTitle {
  package static func singleLine(_ text: String) -> String {
    text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
      .filter { !$0.isEmpty }.joined(separator: " ")
  }
  package static func nonempty(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let title = singleLine(text)
    return title.isEmpty ? nil : title
  }
  package static func unnamed(_ id: String) -> String {
    let short = (id.hasPrefix("session_") ? String(id.dropFirst(8)) : id).prefix(8)
    return short.isEmpty ? "未命名会话" : "未命名会话 · \(short)"
  }
  package static func resolved(_ value: Any?, id: String) -> String {
    nonempty(value) ?? unnamed(id)
  }
}
