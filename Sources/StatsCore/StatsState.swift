import Foundation

// UI-independent state. All runtime mutations occur on the main queue through
// provider switching, window observation, typed collection updates and selection.
package final class StatsState {
  package private(set) var provider: StatsProvider
  package private(set) var generation = UUID()
  package var catalog = StatsCatalog()
  package var current: StatsRecord?
  package var nativeSelection = CurrentSession(.disabled)
  package var pageSelection = PageSessionSelection()
  package private(set) var observedWindow: HostWindowReference?
  package var hostWindowCount = 0
  private let clock: () -> Date
  package var windowChangedAt: Double
  package private(set) var nativeRouteAvailable: Bool?
  package private(set) var error: String?
  package private(set) var lastReceived = Date.distantPast

  package init(provider: StatsProvider, clock: @escaping () -> Date = Date.init) {
    self.provider = provider
    self.clock = clock
    windowChangedAt = clock().timeIntervalSince1970 * 1000
  }

  package func switchProvider(_ provider: StatsProvider, now: Date? = nil) {
    let now = now ?? clock()
    self.provider = provider
    generation = UUID()
    catalog = StatsCatalog()
    current = nil
    nativeSelection = CurrentSession(.unknown)
    pageSelection = PageSessionSelection()
    observedWindow = nil
    hostWindowCount = 0
    windowChangedAt = now.timeIntervalSince1970 * 1000
    nativeRouteAvailable = nil
    error = nil
    lastReceived = .distantPast
  }

  @discardableResult package func observeWindow(_ window: HostWindowReference?, now: Date? = nil)
    -> Bool
  {
    let now = now ?? clock()
    let changed = observedWindow?.token != window?.token
    observedWindow = window
    if changed {
      windowChangedAt = now.timeIntervalSince1970 * 1000
      nativeSelection = CurrentSession(
        window == nil ? .hostUnavailable : .unknown, window: window?.token)
    }
    return changed
  }

  @discardableResult package func receive(_ update: StatsUpdate, generation: UUID, now: Date? = nil)
    -> Bool
  {
    let now = now ?? clock()
    guard generation == self.generation, update.provider == provider else { return false }
    if let page = update.pageSelection { pageSelection = page }
    if let native = update.nativeSelection, native.windowToken == observedWindow?.token {
      nativeSelection = native
      if native.state == .routeUnavailable {
        nativeRouteAvailable = false
      } else if native.isKnown {
        nativeRouteAvailable = true
      }
    }
    switch update.catalog {
    case .unchanged: break
    case .replace(let catalog):
      self.catalog = catalog
      error = nil
      lastReceived = now
    case .failed(let error):
      self.error = error
      catalog = StatsCatalog()
      current = nil
      lastReceived = now
    }
    return true
  }

  package var canFollowCurrentConversation: Bool {
    provider.supportsAutomaticSessionFollow && nativeRouteAvailable != false
  }

  package func resolve(_ target: SessionSelectionMode) -> StatsPresentation {
    var placeholder: StatsPlaceholder =
      error != nil ? .readError : lastReceived == .distantPast ? .loading : .empty
    switch target {
    case .automatic:
      let evidence = AutomaticSessionSelection.resolve(
        provider: provider.rawValue, native: nativeSelection,
        bridge: pageSelection, window: observedWindow, hostWindowCount: hostWindowCount,
        windowChangedAt: windowChangedAt)
      let selection = evidence.selection
      let matches = catalog.sessions.filter { record in
        guard let id = selection.sessionID else { return false }
        return record.id == id || record.sessionID == id
      }
      current = selection.isKnown && matches.count == 1 ? matches[0] : nil
      if selection.isKnown {
        placeholder = selection.sessionID == nil ? .draft : .noLocalStats
      } else if selection.state == .permissionRequired {
        placeholder = .permissionRequired
      } else if selection.state == .routeUnavailable {
        placeholder = .routeUnavailable
      } else {
        placeholder = .unidentified
      }
    case .recent: current = catalog.sessions.first
    case .manual(let id): current = catalog.sessions.first { $0.id == id }
    case .project(let id): current = catalog.projects.first { $0.id == "__project__:" + id }
    case .agent(let id): current = catalog.agents.first { $0.agentKey == id }
    }
    return StatsPresentation(record: current, placeholder: placeholder)
  }

  package var navigationGroups: [StatsGroup] {
    var seen = Set<String>()
    let groups = (catalog.groups + catalog.sessions.compactMap(\.group)).filter {
      $0.id != StatsGroup.ungroupedID && seen.insert($0.id).inserted
    }
    return groups + [.ungrouped]
  }

  package func conversations(in group: String) -> [StatsRecord] {
    catalog.sessions.filter { !$0.archived && (group == "all" || $0.groupID == group) }
  }
}
