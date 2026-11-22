import StatsCore
import StatsAdapters
import CoreGraphics
import Foundation

// The only owner of application preference keys. Getters preserve the existing
// defaults and migration order; applying an app action is the coordinator's job.
final class StatsPreferencesStore {
  private let defaults: UserDefaults
  init(_ defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if defaults === UserDefaults.standard { Product.migratePreferences(to: defaults) }
  }
  var activeProvider: StatsProvider {
    get {
      StatsProvider(rawValue: defaults.string(forKey: "activeProvider") ?? Product.provider)
        ?? .codex
    }
    set { defaults.set(newValue.rawValue, forKey: "activeProvider") }
  }
  var followsActiveTool: Bool {
    get { defaults.object(forKey: "followActiveTool") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "followActiveTool") }
  }
  func selectedProject(for provider: StatsProvider) -> String {
    defaults.string(forKey: "selectedProject." + provider.rawValue) ?? "all"
  }
  func setSelectedProject(_ id: String, for provider: StatsProvider) {
    defaults.set(id, forKey: "selectedProject." + provider.rawValue)
  }
  func selectedSession(for provider: StatsProvider) -> String? {
    defaults.string(forKey: "selectedSession." + provider.rawValue)
  }
  func setSelectedSession(_ id: String?, for provider: StatsProvider) {
    defaults.set(id, forKey: "selectedSession." + provider.rawValue)
  }
  func hudHidden(for provider: StatsProvider) -> Bool {
    defaults.bool(forKey: "hudHidden." + provider.rawValue)
  }
  func setHUDHidden(_ hidden: Bool, for provider: StatsProvider) {
    defaults.set(hidden, forKey: "hudHidden." + provider.rawValue)
  }
  /// Global: the bar sinks into the host after a quiet period. On by default.
  var hudIdleSink: Bool {
    get { defaults.object(forKey: "hudIdleSink") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "hudIdleSink") }
  }
  /// Global: hide the menu bar icon in floating mode. The icon always shows in menu bar mode.
  var statusItemHidden: Bool {
    get { defaults.bool(forKey: "statusItemHidden") }
    set { defaults.set(newValue, forKey: "statusItemHidden") }
  }
  var tokenStatsScope: TokenStatsToolScope {
    get {
      TokenStatsToolScope(rawValue: defaults.string(forKey: "tokenStats.scope.v1") ?? "") ?? .all
    }
    set { defaults.set(newValue.rawValue, forKey: "tokenStats.scope.v1") }
  }
  var tokenStatsRange: TokenStatsTimeRange {
    get {
      TokenStatsTimeRange(rawValue: defaults.string(forKey: "tokenStats.range.v1") ?? "")
        ?? .days30
    }
    set { defaults.set(newValue.rawValue, forKey: "tokenStats.range.v1") }
  }
  var tokenStatsDimension: TokenStatsDimension {
    get {
      TokenStatsDimension(rawValue: defaults.string(forKey: "tokenStats.dimension.v1") ?? "")
        ?? .models
    }
    set { defaults.set(newValue.rawValue, forKey: "tokenStats.dimension.v1") }
  }
  var autoCheckUpdates: Bool {
    get { defaults.object(forKey: "updates.autoCheck.v1") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "updates.autoCheck.v1") }
  }
  var autoDownloadUpdates: Bool {
    get { defaults.object(forKey: "updates.autoDownload.v1") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "updates.autoDownload.v1") }
  }
  var lastUpdateCheckMs: Double? {
    get { defaults.object(forKey: "updates.lastCheckedAtMs.v1") as? Double }
    set {
      if let newValue {
        defaults.set(newValue, forKey: "updates.lastCheckedAtMs.v1")
      } else {
        defaults.removeObject(forKey: "updates.lastCheckedAtMs.v1")
      }
    }
  }
  func hasExplicitDisplayMode(for provider: StatsProvider) -> Bool {
    defaults.object(forKey: "displayMode." + provider.rawValue) != nil
  }
  func displayMode(for provider: StatsProvider) -> StatsDisplayMode {
    StatsDisplayMode(rawValue: defaults.string(forKey: "displayMode." + provider.rawValue) ?? "")
      ?? .floating
  }
  func setDisplayMode(_ mode: StatsDisplayMode, for provider: StatsProvider) {
    defaults.set(mode.rawValue, forKey: "displayMode." + provider.rawValue)
  }
  var onboardingCompleted: Bool {
    get { defaults.bool(forKey: "onboardingCompleted.v1") }
    set { defaults.set(newValue, forKey: "onboardingCompleted.v1") }
  }
  var pendingFloatingActivation: Bool {
    get { defaults.bool(forKey: "pendingFloatingActivation.v1") }
    set { defaults.set(newValue, forKey: "pendingFloatingActivation.v1") }
  }
  func modules(for provider: StatsProvider) -> [HUDModule] {
    HUDModuleSettings.load(from: defaults, provider: provider.rawValue)
  }
  func setModules(_ modules: [HUDModule], for provider: StatsProvider) {
    HUDModuleSettings.save(modules, to: defaults, provider: provider.rawValue)
  }
  func prepareLaunch(provider: StatsProvider, bridgeInstalled: Bool) {
    removeRetiredPreferences()
    let selected = selectedSession(for: provider)
    if provider == .kimi, selected == "__bridge__" || (selected == nil && !bridgeInstalled) {
      setSelectedSession("__current__", for: provider)
    }
    for provider in StatsProvider.allCases {
      HUDModuleSettings.installSubagentModule(in: defaults, provider: provider.rawValue)
    }
  }
  // Only the free position the user dragged the bar to survives; it is stored as a
  // fraction of the host window, so resizing or moving the host keeps the bar in the
  // same relative place. A missing value means the default top-centre position.
  func placement(for provider: StatsProvider) -> HUDPlacement {
    let prefix = Self.placementKey + "." + provider.rawValue + "."
    if let x = defaults.object(forKey: prefix + "relativeX") as? NSNumber,
      let y = defaults.object(forKey: prefix + "relativeY") as? NSNumber
    {
      return HUDPlacement(relativePosition: CGPoint(x: x.doubleValue, y: y.doubleValue))
    }
    return HUDPlacement()
  }
  func setPlacement(_ newValue: HUDPlacement, for provider: StatsProvider) {
    let prefix = Self.placementKey + "." + provider.rawValue + "."
    if let point = newValue.relativePosition {
      defaults.set(point.x, forKey: prefix + "relativeX")
      defaults.set(point.y, forKey: prefix + "relativeY")
    } else {
      defaults.removeObject(forKey: prefix + "relativeX")
      defaults.removeObject(forKey: prefix + "relativeY")
    }
  }
  static let placementKey = "placement"
  /// Retired fields of the removed edge-docking feature plus the old "custom position"
  /// flag. Reading or writing them has no effect, so they are deleted once per launch
  /// instead of lingering in the preference domain forever.
  static let retiredPlacementKeys = ["dock", "x", "y", "vertical", "alignment", "hasCustom"]
  /// Every preference stored per tool. A suffix that no longer names a supported tool
  /// is a leftover from a removed product and is deleted with its fields.
  static let perProviderStems = [
    "selectedSession", "selectedProject", "hudHidden", "displayMode", "hudModules",
    HUDModuleSettings.key, "detailRows.v1", "subagentModule.v1", placementKey,
  ]
  func removeRetiredPreferences() {
    let supported = Set(StatsProvider.allCases.map(\.rawValue))
    for key in defaults.dictionaryRepresentation().keys {
      for stem in Self.perProviderStems where key.hasPrefix(stem + ".") {
        let provider = key.dropFirst(stem.count + 1).split(separator: ".").first.map(String.init)
        if let provider, !supported.contains(provider) {
          defaults.removeObject(forKey: key)
        }
      }
    }
    for provider in StatsProvider.allCases {
      for key in Self.retiredPlacementKeys {
        defaults.removeObject(forKey: Self.placementKey + "." + provider.rawValue + "." + key)
      }
    }
  }
  static let mergedDetailRows = [
    "timing.modelUse": "timing.model", "timing.modelRequest": "timing.model",
  ]
  // A stored subset of `DetailRowRegistry` keys. A missing key list means "every row
  // this tool supports", so an upgrade keeps the rows it showed before.
  func detailRowKeys(for provider: StatsProvider) -> Set<String> {
    guard let stored = defaults.array(forKey: Self.detailRowKey + "." + provider.rawValue)
      as? [String]
    else { return DetailRowRegistry.defaultKeys(for: provider) }
    return Set(stored.map { Self.mergedDetailRows[$0] ?? $0 }).intersection(
      DetailRowRegistry.allKeys)
  }
  func setDetailRowKeys(_ keys: Set<String>, for provider: StatsProvider) {
    defaults.set(keys.sorted(), forKey: Self.detailRowKey + "." + provider.rawValue)
  }
  static let detailRowKey = "detailRows.v1"
  func editModules(_ edit: HUDModuleEdit, for provider: StatsProvider) {
    var configured = modules(for: provider)
    switch edit {
    case .add(let metric): configured.append(HUDModule(metric: metric))
    case .replace(let id, let metric):
      if let index = configured.firstIndex(where: { $0.id == id }) {
        configured[index].metric = metric
      }
    case .remove(let id): configured.removeAll { $0.id == id }
    case .move(let id, let delta):
      // A row is dropped into a slot, so the other rows shift: this is a rotation,
      // not a swap. Swapping scrambled a layout when a row moved more than one slot.
      if let index = configured.firstIndex(where: { $0.id == id }) {
        let target = min(configured.count - 1, max(0, index + delta))
        configured = HUDModuleReorder.moved(configured, from: index, to: target)
      }
    case .reset: configured = HUDModuleSettings.defaults(provider: provider.rawValue)
    }
    setModules(configured, for: provider)
  }
}

enum HUDModuleSettings {
  static let key = "hudModuleLayout.v1"
  /// Retired duplicate variants fold into the one metric that replaced them.
  static let mergedMetrics: [String: HUDMetric] = [
    "recentSpeed": .speed, "averageSpeed": .speed, "averageLatency": .latency,
    "modelUseTime": .modelTime,
  ]
  static func storageKey(for provider: String) -> String { key + "." + provider }
  static func defaults(provider: String = "codex") -> [HUDModule] {
    let metrics = MetricRegistry.defaults
    return metrics.map { HUDModule(metric: $0) }
  }
  static func installSubagentModule(in preferences: UserDefaults, provider: String) {
    let marker = "subagentModule.v1." + provider
    guard !preferences.bool(forKey: marker) else { return }
    var modules = load(from: preferences, provider: provider)
    if !modules.contains(where: { $0.metric == .subagents }) {
      modules.append(HUDModule(metric: .subagents))
      save(modules, to: preferences, provider: provider)
    }
    preferences.set(true, forKey: marker)
  }
  static func load(from preferences: UserDefaults, provider: String) -> [HUDModule] {
    let available = HUDMetric.available(for: provider)
    if let records = preferences.array(forKey: storageKey(for: provider)) as? [[String: String]] {
      var used = Set<String>()
      var kept = Set<HUDMetric>()
      let modules: [HUDModule] = records.compactMap { record in
        guard let name = record["metric"] else { return nil }
        let direct = HUDMetric(rawValue: name)
        guard let metric = direct ?? mergedMetrics[name], available.contains(metric) else {
          return nil
        }
        if direct == nil && kept.contains(metric) { return nil }
        kept.insert(metric)
        var id = record["id"] ?? UUID().uuidString
        if id.isEmpty || used.contains(id) { id = UUID().uuidString }
        used.insert(id)
        return HUDModule(id: id, metric: metric)
      }
      if modules.map({ ["id": $0.id, "metric": $0.metric.rawValue] }) != records {
        save(modules, to: preferences, provider: provider)
      }
      return modules
    }
    var modules = defaults(provider: provider)
    if let legacy = preferences.stringArray(forKey: "hudModules." + provider)
      ?? preferences.stringArray(forKey: "hudModules")
    {
      // Earlier versions merged speed and latency into one visible button.
      var seen = Set<HUDMetric>()
      modules = legacy.compactMap { name in
        let metric = name == "latency" ? HUDMetric.speed : HUDMetric(rawValue: name)
        guard let metric, available.contains(metric), seen.insert(metric).inserted else {
          return nil
        }
        return HUDModule(metric: metric)
      }
    }
    save(modules, to: preferences, provider: provider)
    return modules
  }
  static func save(_ modules: [HUDModule], to preferences: UserDefaults, provider: String = "codex")
  {
    preferences.set(
      modules.map { ["id": $0.id, "metric": $0.metric.rawValue] }, forKey: storageKey(for: provider)
    )
  }
}
