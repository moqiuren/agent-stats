import AppKit
import Foundation
import StatsAdapters
import StatsCore

final class InMemoryAppSystemIntegration: AppSystemIntegrating {
  var isInStandardApplicationsLocation: Bool = true
  var isLaunchAtLoginEnabled: Bool = false
  var pluginStatus: KimiPluginStatus = .synced
  var launchMaintenanceCalls = 0
  var syncCalls = 0
  var relocateCalls = 0
  var revealCalls = 0
  var uninstallCalls = 0
  var installedUpdatePaths = [URL]()

  func setLaunchAtLogin(_ enabled: Bool) throws {
    isLaunchAtLoginEnabled = enabled
  }

  func kimiPluginStatus() -> KimiPluginStatus {
    pluginStatus
  }

  @discardableResult
  func syncKimiPlugin(forceEnable: Bool) throws -> KimiPluginStatus {
    syncCalls += 1
    if forceEnable || pluginStatus == .notSynced {
      pluginStatus = .synced
    }
    return pluginStatus
  }

  func performSilentLaunchMaintenance() {
    launchMaintenanceCalls += 1
  }

  @discardableResult
  func relocateToApplicationsAndRelaunch() throws -> URL {
    relocateCalls += 1
    return URL(fileURLWithPath: "/Applications/\(Product.name).app")
  }

  func revealCurrentAppInFinder() {
    revealCalls += 1
  }

  func performGUIUninstall() throws {
    uninstallCalls += 1
  }

  @discardableResult
  func installUpdateAndRelaunch(from stagedApp: URL) throws -> URL {
    installedUpdatePaths.append(stagedApp)
    return URL(fileURLWithPath: "/Applications/\(Product.name).app")
  }
}

// The process composition root owns the one bridge and shares a clock with state,
// collectors, cache expiration and display. Tests replace these dependencies as a unit.
struct AppRuntimeDependencies {
  let clock: StatsClock
  let uiScheduler: StatsScheduling
  let bridge: PageSelectionBridging
  let makeHostMonitor: () -> HostWindowMonitoring
  let makeSessionMonitor: (StatsProvider) -> CurrentSessionMonitoring
  let isAccessibilityAuthorized: () -> Bool
  let system: AppSystemIntegrating
  let enablesLaunchSetup: Bool
  let terminateApp: () -> Void
  let tokenHistory: TokenHistoryServing?
  let updater: AppUpdateManaging?

  init(
    clock: StatsClock,
    uiScheduler: StatsScheduling,
    bridge: PageSelectionBridging,
    makeHostMonitor: @escaping () -> HostWindowMonitoring,
    makeSessionMonitor: @escaping (StatsProvider) -> CurrentSessionMonitoring,
    isAccessibilityAuthorized: @escaping () -> Bool = { HostAccessibility.isAuthorized },
    system: AppSystemIntegrating = InMemoryAppSystemIntegration(),
    enablesLaunchSetup: Bool = false,
    terminateApp: @escaping () -> Void = { NSApp.terminate(nil) },
    tokenHistory: TokenHistoryServing? = nil,
    updater: AppUpdateManaging? = nil
  ) {
    self.clock = clock
    self.uiScheduler = uiScheduler
    self.bridge = bridge
    self.makeHostMonitor = makeHostMonitor
    self.makeSessionMonitor = makeSessionMonitor
    self.isAccessibilityAuthorized = isAccessibilityAuthorized
    self.system = system
    self.enablesLaunchSetup = enablesLaunchSetup
    self.terminateApp = terminateApp
    self.tokenHistory = tokenHistory
    self.updater = updater
  }

  static func live() -> Self {
    let clock = SystemStatsClock()
    let ui = RunLoopStatsScheduler()
    return Self(
      clock: clock,
      uiScheduler: ui,
      bridge: KimiBridgeRuntime(clock: clock),
      makeHostMonitor: { HostWindowMonitor(clock: clock, uiScheduler: ui) },
      makeSessionMonitor: { CurrentSessionMonitor(provider: $0.rawValue, clock: clock) },
      isAccessibilityAuthorized: { HostAccessibility.isAuthorized },
      system: LiveAppSystemIntegration(),
      enablesLaunchSetup: true,
      terminateApp: { NSApp.terminate(nil) },
      tokenHistory: LiveTokenHistoryService(clock: clock, uiScheduler: ui),
      updater: LiveAppUpdateManager(clock: clock, uiScheduler: ui)
    )
  }
}
