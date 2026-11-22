import Foundation
import StatsCore

// One serial owner for retained readers. A provider switch cannot race an old
// scan against a reused reader; all access runs on this store's scheduler.
package final class StatsReaderStore {
  // Kept internal for legacy queue-isolation fixtures; app code uses the contract.
  let queue: DispatchQueue
  let scheduler: StatsScheduling
  private let clock: StatsClock
  private struct Entry {
    let reader: StatsReading
    var lastUsed: TimeInterval
  }
  private let capacity: Int
  private let idleLifetime: TimeInterval
  private let factory: (StatsProvider) -> StatsReading
  private var entries = [StatsProvider: Entry]()
  private var memoryPressure: DispatchSourceMemoryPressure?

  package init(
    capacity: Int = 2, idleLifetime: TimeInterval = 120,
    clock: StatsClock = SystemStatsClock(), scheduler: StatsScheduling? = nil,
    factory: ((StatsProvider) -> StatsReading)? = nil
  ) {
    precondition(capacity > 0 && idleLifetime > 0)
    let queue = DispatchQueue(label: "\(Product.bundleID).collectors", qos: .utility)
    self.queue = queue
    self.scheduler = scheduler ?? DispatchStatsScheduler(queue: queue)
    self.clock = clock
    self.capacity = capacity
    self.idleLifetime = idleLifetime
    self.factory =
      factory ?? { provider in
        let cache = ParseCacheStore(
          path: Product.cacheDirectory.appendingPathComponent(
            "parse-cache-\(provider.rawValue).json"), clock: clock)
        return SessionReader(
          root: provider.dataRoot, provider: provider, cache: cache, clock: clock)
      }
    let pressure = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical], queue: queue)
    pressure.setEventHandler { [weak self] in
      self?.scheduler.execute { [weak self] in self?.entries.removeAll() }
    }
    pressure.resume()
    memoryPressure = pressure
  }
  deinit { memoryPressure?.cancel() }
  package func scan(
    provider: StatsProvider, selected: String?, now: Double, uptime: TimeInterval? = nil
  ) -> StatsSnapshot {
    precondition(scheduler.isIsolated, "Reader access must stay on its owning scheduler")
    let uptime = uptime ?? clock.uptime
    entries = entries.filter { uptime - $0.value.lastUsed < idleLifetime }
    if entries[provider] == nil {
      if entries.count >= capacity,
        let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key
      {
        entries.removeValue(forKey: oldest)
      }
      entries[provider] = Entry(reader: factory(provider), lastUsed: uptime)
    }
    entries[provider]?.lastUsed = uptime
    return entries[provider]!.reader.scan(selected: selected, now: now)
  }
}

package final class NativeStatsService: StatsCollecting {
  package let provider: StatsProvider
  private let readers: StatsReaderStore
  private var scheduler: StatsScheduling { readers.scheduler }
  private let uiScheduler: StatsScheduling
  private let clock: StatsClock
  private let bridge: PageSelectionBridging
  private let monitor: CurrentSessionMonitoring
  private var nativeSessionID: String?
  private var timer: StatsCancellation?, paused = false, stopped = false
  private var selection: SessionSelectionMode
  package var onUpdate: ((StatsUpdate) -> Void)?

  package init(
    provider: StatsProvider, readers: StatsReaderStore,
    bridge: PageSelectionBridging, clock: StatsClock = SystemStatsClock(),
    uiScheduler: StatsScheduling = DispatchStatsScheduler(queue: .main),
    monitor: CurrentSessionMonitoring? = nil
  ) {
    self.provider = provider
    self.readers = readers
    self.bridge = bridge
    self.clock = clock
    self.uiScheduler = uiScheduler
    selection = SessionSelectionMode.resolve(nil, provider: provider.rawValue)
    self.monitor = monitor ?? CurrentSessionMonitor(provider: provider.rawValue, clock: clock)
  }
  private func publish(_ update: StatsUpdate) {
    uiScheduler.execute { [weak self] in self?.onUpdate?(update) }
  }
  package func start() {
    monitor.onChange = { [weak self] selection in
      guard let self else { return }
      self.scheduler.execute { [weak self] in
        guard let self, !self.stopped else { return }
        self.publish(StatsUpdate(provider: self.provider, nativeSelection: selection))
        let id = selection.state == .current ? selection.sessionID : nil
        let changed = self.nativeSessionID != id
        self.nativeSessionID = id
        if changed && self.selection == .automatic { self.scan() }
      }
    }
    monitor.start()
    bridge.start()
    scheduler.execute { [self] in
      guard !stopped, timer == nil else { return }
      timer = scheduler.schedule(after: 0, repeating: 1.5, tolerance: 0) { [weak self] in
        self?.scan()
      }
    }
  }
  package func update(selection: SessionSelectionMode, paused: Bool? = nil, refresh: Bool = false) {
    monitor.setEnabled(selection == .automatic)
    scheduler.execute { [self] in
      self.selection = selection
      if let paused { self.paused = paused }
      if refresh { self.scan() }
    }
  }
  package func observe(_ window: HostWindowReference?) { monitor.observe(window) }
  private func scan() {
    guard !paused && !stopped else { return }
    let target = selection == .automatic ? nativeSessionID : selection.storedValue
    let value = readers.scan(provider: provider, selected: target, now: clock.milliseconds)
    publish(
      StatsUpdate(snapshot: value, pageSelection: provider == .kimi ? bridge.snapshot() : nil))
  }
  package func stop() {
    monitor.stop()
    // Publication and callback teardown share the UI scheduler. Pending reads
    // retain their serial owner, and generation checks still reject old providers.
    uiScheduler.execute { self.onUpdate = nil }
    scheduler.execute {
      self.stopped = true
      self.timer?.cancel()
      self.timer = nil
    }
  }
}
