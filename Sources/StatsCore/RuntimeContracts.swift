import Foundation

// Relative scheduling and wall/monotonic time are separate dependencies. Core
// policies never create a timer, access a host process or own a bridge listener.
package protocol StatsClock {
  var now: Date { get }
  var uptime: TimeInterval { get }
}
extension StatsClock {
  package var milliseconds: Double { now.timeIntervalSince1970 * 1000 }
}
package protocol StatsCancellation: AnyObject { func cancel() }
package protocol StatsScheduling: AnyObject {
  var isIsolated: Bool { get }
  func execute(_ action: @escaping () -> Void)
  func schedule(
    after delay: TimeInterval, repeating interval: TimeInterval?, tolerance: TimeInterval,
    _ action: @escaping () -> Void
  ) -> StatsCancellation
}
package protocol CurrentSessionMonitoring: AnyObject {
  var onChange: ((CurrentSession) -> Void)? { get set }
  func start()
  func setEnabled(_ enabled: Bool)
  func observe(_ window: HostWindowReference?)
  func stop()
}
package protocol HostWindowMonitoring: AnyObject {
  func observe(windows: [HostWindowReference], requireFocused: Bool, provider: String) -> UInt32?
  func reset()
}
package protocol PageSelectionBridging: AnyObject {
  func start()
  func snapshot() -> PageSessionSelection
  func stop()
}
