import StatsCore
import StatsAdapters
import AppKit

// AppKit lifecycle only. State, configuration, menus and windows have separate owners.
final class AppDelegate: NSObject, NSApplicationDelegate {
  let coordinator: AppCoordinator
  override init() {
    coordinator = AppCoordinator()
    super.init()
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: Product.bundleID)
      .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    guard others.isEmpty else {
      DistributedNotificationCenter.default().postNotificationName(
        AppCoordinator.showSettingsNotification, object: nil, userInfo: nil,
        deliverImmediately: true)
      NSApp.terminate(nil)
      return
    }
    coordinator.start()
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    coordinator.handleReopen()
    return false
  }
  func applicationDidResignActive(_ notification: Notification) { coordinator.resignActive() }
  func applicationWillTerminate(_ notification: Notification) { coordinator.stop() }
}

  @main enum AgentStatsMain {
    static func main() {
      if Lifecycle.commandLine() { return }
      let application = NSApplication.shared
      let delegate = AppDelegate()
      application.delegate = delegate
      withExtendedLifetime(delegate) { application.run() }
    }
  }
