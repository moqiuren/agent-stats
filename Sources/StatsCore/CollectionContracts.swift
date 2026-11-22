import Foundation

package protocol StatsReading: AnyObject {
  func scan(selected: String?, now: Double) -> StatsSnapshot
}

package protocol StatsCollecting: AnyObject {
  var onUpdate: ((StatsUpdate) -> Void)? { get set }
  func start()
  func update(selection: SessionSelectionMode, paused: Bool?, refresh: Bool)
  func observe(_ window: HostWindowReference?)
  func stop()
}
