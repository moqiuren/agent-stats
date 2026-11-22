import Foundation
import StatsCore

package struct SystemStatsClock: StatsClock {
  package init() {}
  package var now: Date { Date() }
  package var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

private final class WorkCancellation: StatsCancellation {
  let item: DispatchWorkItem
  init(_ item: DispatchWorkItem) { self.item = item }
  func cancel() { item.cancel() }
}
private final class DispatchTimerCancellation: StatsCancellation {
  let timer: DispatchSourceTimer
  init(_ timer: DispatchSourceTimer) { self.timer = timer }
  func cancel() { timer.cancel() }
  deinit { timer.cancel() }
}
private final class RunLoopCancellation: StatsCancellation {
  let timer: Timer
  init(_ timer: Timer) { self.timer = timer }
  func cancel() { timer.invalidate() }
  deinit { timer.invalidate() }
}

package final class DispatchStatsScheduler: StatsScheduling {
  private let queue: DispatchQueue
  private let key = DispatchSpecificKey<Bool>()
  package init(queue: DispatchQueue) {
    self.queue = queue
    queue.setSpecific(key: key, value: true)
  }
  deinit { queue.setSpecific(key: key, value: nil) }
  package var isIsolated: Bool { DispatchQueue.getSpecific(key: key) == true }
  package func execute(_ action: @escaping () -> Void) {
    queue.async(execute: DispatchWorkItem(block: action))
  }
  package func schedule(
    after delay: TimeInterval, repeating interval: TimeInterval?, tolerance: TimeInterval,
    _ action: @escaping () -> Void
  ) -> StatsCancellation {
    if let interval {
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(
        deadline: .now() + delay, repeating: interval,
        leeway: .nanoseconds(Int(tolerance * 1_000_000_000)))
      timer.setEventHandler(handler: action)
      timer.resume()
      return DispatchTimerCancellation(timer)
    }
    let item = DispatchWorkItem(block: action)
    queue.asyncAfter(deadline: .now() + delay, execute: item)
    return WorkCancellation(item)
  }
}

// The HUD retains its original default-run-loop timer behavior during native
// menu tracking. Background collectors use DispatchStatsScheduler instead.
package final class RunLoopStatsScheduler: StatsScheduling {
  package init() {}
  package var isIsolated: Bool { Thread.isMainThread }
  package func execute(_ action: @escaping () -> Void) {
    DispatchQueue.main.async(execute: DispatchWorkItem(block: action))
  }
  package func schedule(
    after delay: TimeInterval, repeating interval: TimeInterval?, tolerance: TimeInterval,
    _ action: @escaping () -> Void
  ) -> StatsCancellation {
    precondition(Thread.isMainThread)
    let timer = Timer(
      fire: Date().addingTimeInterval(delay), interval: interval ?? 0, repeats: interval != nil
    ) { _ in action() }
    timer.tolerance = tolerance
    RunLoop.main.add(timer, forMode: .default)
    return RunLoopCancellation(timer)
  }
}
