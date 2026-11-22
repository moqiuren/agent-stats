import Foundation
@testable import StatsAdapters
@testable import StatsCore

enum AppInstallationTests {
  static func main() throws {
    var checks = 0
    func check(_ value: Bool, _ message: String) {
      precondition(value, message)
      checks += 1
    }

    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("app-install-tests-\(UUID().uuidString)")
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    let home = base.appendingPathComponent("home")
    let support = home.appendingPathComponent("Library/Application Support/Agent Stats")
    let sysApps = base.appendingPathComponent("SystemApplications")
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    try fm.createDirectory(at: support, withIntermediateDirectories: true)
    try fm.createDirectory(at: sysApps, withIntermediateDirectories: true)

    // 1. Standard install locations & isolation
    check(
      AppInstallation.standardApplicationsDirectory(home: home)
        == home.appendingPathComponent("Applications").standardizedFileURL,
      "non-host home stays isolated from /Applications")
    check(
      AppInstallation.standardApplicationsDirectory(
        home: home, systemApplications: sysApps, isWritable: { _ in true }) == sysApps.standardizedFileURL,
      "writable system Applications wins when provided")
    check(
      AppInstallation.standardApplicationsDirectory(
        home: home, systemApplications: sysApps, isWritable: { _ in false })
        == home.appendingPathComponent("Applications").standardizedFileURL,
      "unwritable Applications falls back to user Applications")

    check(
      AppInstallation.isStandardInstallLocation(
        URL(fileURLWithPath: "/Applications/Agent Stats.app"), home: home, support: support),
      "/Applications bundle is standard")
    check(
      AppInstallation.isStandardInstallLocation(
        home.appendingPathComponent("Applications/Agent Stats.app"), home: home, support: support),
      "~/Applications bundle is standard")
    check(
      AppInstallation.isStandardInstallLocation(
        support.appendingPathComponent("Agent Stats.app"), home: home, support: support),
      "legacy support bundle is recognized as standard")
    check(
      !AppInstallation.isStandardInstallLocation(
        URL(fileURLWithPath: "/Volumes/Agent Stats/Agent Stats.app"), home: home, support: support),
      "mounted DMG is not a standard location")
    check(
      !AppInstallation.isStandardInstallLocation(
        home.appendingPathComponent("Downloads/Agent Stats.app"), home: home, support: support),
      "Downloads is not a standard location")
    check(
      !AppInstallation.isStandardInstallLocation(
        URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/123/d/Agent Stats.app"),
        home: home, support: support),
      "AppTranslocation is not a standard location")
    check(
      !AppInstallation.isStandardInstallLocation(
        URL(fileURLWithPath: "/tmp/repo/.build/apps/Agent Stats.app"), home: home, support: support),
      ".build output is not a standard location")

    // 2. Launch at login preserves environment across disable/re-enable without bootout
    let appInUserApps = home.appendingPathComponent("Applications/Agent Stats.app")
    try fm.createDirectory(
      at: appInUserApps.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    let launch = AppInstallation.launchAgentURL(home: home)
    try AppInstallation.setLaunchAtLogin(
      true, bundleURL: appInUserApps, home: home, support: support,
      environment: ["CODEX_HOME": "/custom/codex", "KIMI_CODE_HOME": home.appendingPathComponent("kimi").path])
    check(AppInstallation.isLaunchAtLoginEnabled(home: home), "enabling launch at login writes plist")
    let initialPlist =
      try PropertyListSerialization.propertyList(from: Data(contentsOf: launch), format: nil)
      as? [String: Any]
    check(
      (initialPlist?["EnvironmentVariables"] as? [String: String])?["CODEX_HOME"] == "/custom/codex",
      "launch plist records environment overrides")

    try AppInstallation.setLaunchAtLogin(
      false, bundleURL: appInUserApps, home: home, support: support, environment: [:])
    check(
      !AppInstallation.isLaunchAtLoginEnabled(home: home),
      "disabling launch at login moves plist away")
    let trashedPlists =
      (try? fm.contentsOfDirectory(
        at: home.appendingPathComponent(".Trash"), includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("Agent-Stats-login-item-") }) ?? []
    check(trashedPlists.count == 1, "disabled launch plist moves safely to Trash")

    try AppInstallation.setLaunchAtLogin(
      true, bundleURL: appInUserApps, home: home, support: support, environment: [:])
    let restoredPlist =
      try PropertyListSerialization.propertyList(from: Data(contentsOf: launch), format: nil)
      as? [String: Any]
    check(
      (restoredPlist?["EnvironmentVariables"] as? [String: String])?["CODEX_HOME"]
        == "/custom/codex",
      "re-enabling launch at login restores preserved environment variables")

    // 3. Kimi plugin sync: idempotency, user-disabled preservation, forceEnable, backup pruning
    let kimiRoot = home.appendingPathComponent("kimi")
    let pluginsDir = kimiRoot.appendingPathComponent("plugins")
    try fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
    let registry = pluginsDir.appendingPathComponent("installed.json")
    try JSONSerialization.data(
      withJSONObject: ["version": 1, "plugins": [["id": "other-plugin", "enabled": true]]],
      options: [.sortedKeys]
    ).write(to: registry)

    let firstSync = try AppInstallation.syncKimiPlugin(
      bundleURL: appInUserApps, home: home, support: support, forceEnable: false)
    check(firstSync == .synced, "initial plugin sync succeeds")
    check(
      AppInstallation.kimiPluginStatus(bundleURL: appInUserApps, home: home, support: support)
        == .synced,
      "status reports synced after registration")

    let manifestFile = pluginsDir.appendingPathComponent("managed/kimi-stats-hud/kimi.plugin.json")
    let manifestModified = try fm.attributesOfItem(atPath: manifestFile.path)[.modificationDate] as? Date
    let existingBackups = try fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix("installed-") }
    check(existingBackups.count == 1, "updating an existing registry saves one backup")

    let secondSync = try AppInstallation.syncKimiPlugin(
      bundleURL: appInUserApps, home: home, support: support, forceEnable: false)
    check(secondSync == .synced, "repeated sync returns synced")
    let manifestModifiedAfter =
      try fm.attributesOfItem(atPath: manifestFile.path)[.modificationDate] as? Date
    let backupsAfterSecond = try fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix("installed-") }
    check(
      manifestModified == manifestModifiedAfter && backupsAfterSecond.count == 1,
      "idempotent plugin sync avoids rewriting files or creating extra backups")

    // Respect user disabling unless forceEnable == true
    var regObj = try JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as! JSONObject
    var regList = regObj["plugins"] as! [JSONObject]
    for i in regList.indices where regList[i]["id"] as? String == "kimi-stats-hud" {
      regList[i]["enabled"] = false
    }
    regObj["plugins"] = regList
    try JSONSerialization.data(withJSONObject: regObj).write(to: registry)

    let disabledSync = try AppInstallation.syncKimiPlugin(
      bundleURL: appInUserApps, home: home, support: support, forceEnable: false)
    check(
      disabledSync == .disabledByUser
        && AppInstallation.kimiPluginStatus(bundleURL: appInUserApps, home: home, support: support)
          == .disabledByUser,
      "silent sync respects user-disabled plugin state")
    let forcedSync = try AppInstallation.syncKimiPlugin(
      bundleURL: appInUserApps, home: home, support: support, forceEnable: true)
    check(forcedSync == .synced, "explicit forceEnable re-enables disabled plugin")

    // 4. installBundle migrates legacy support app, cleans Downloads source, preserves cache
    let downloadsSource = home.appendingPathComponent("Downloads/Agent Stats.app")
    try fm.createDirectory(
      at: downloadsSource.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    let sourcePlist: [String: Any] = [
      "CFBundleIdentifier": Product.bundleID,
      "CFBundleName": Product.name,
      "CFBundleExecutable": Product.executable,
    ]
    try PropertyListSerialization.data(fromPropertyList: sourcePlist, format: .xml, options: 0)
      .write(to: downloadsSource.appendingPathComponent("Contents/Info.plist"))
    try Data("binary".utf8).write(
      to: downloadsSource.appendingPathComponent("Contents/MacOS/\(Product.executable)"))

    let legacySupportApp = support.appendingPathComponent("Agent Stats.app")
    try fm.createDirectory(at: legacySupportApp, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: legacySupportApp.appendingPathComponent("marker"))
    let cacheFile = support.appendingPathComponent("parse-cache-codex.json")
    try Data("cache".utf8).write(to: cacheFile)

    var commands = [[String]]()
    var runningChecks = 0
    let installedDest = try AppInstallation.installBundle(
      from: downloadsSource,
      to: home.appendingPathComponent("Applications"),
      home: home,
      support: support,
      launchAfterInstall: true,
      environment: ["KIMI_CODE_HOME": kimiRoot.path],
      runCommand: { path, args in
        commands.append([path] + args)
        return path == "/bin/launchctl" && args.first == "print" ? 113 : 0
      },
      isProcessRunning: { _ in
        runningChecks += 1
        return runningChecks > 1
      })
    check(
      installedDest == home.appendingPathComponent("Applications/Agent Stats.app").standardizedFileURL,
      "installBundle places bundle in target Applications directory")
    check(!fm.fileExists(atPath: legacySupportApp.path), "legacy support app is retired to Trash")
    check(!fm.fileExists(atPath: downloadsSource.path), "downloaded source bundle moves to Trash")
    check(fm.fileExists(atPath: cacheFile.path), "support cache files remain intact")
    check(
      commands.contains { $0.prefix(4) == ["/usr/bin/codesign", "--verify", "--deep", "--strict"] },
      "installBundle verifies code signature before replacing")

    // 5. GUI uninstall cleans app, support, launchd, and plugin entry while keeping host data
    let hostSessionFile = kimiRoot.appendingPathComponent("sessions/ws/s1/state.json")
    try fm.createDirectory(at: hostSessionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: hostSessionFile)

    let suite = "app-install-uninstall-\(UUID().uuidString)"
    let prefs = UserDefaults(suiteName: suite)!
    prefs.set("codex", forKey: "activeProvider")
    try AppInstallation.performGUIUninstall(
      bundleURL: installedDest, home: home, support: support, preferences: prefs,
      scheduleBootout: false)
    check(!fm.fileExists(atPath: installedDest.path), "GUI uninstall removes app bundle to Trash")
    check(!fm.fileExists(atPath: support.path), "GUI uninstall removes support folder to Trash")
    check(!fm.fileExists(atPath: launch.path), "GUI uninstall removes launch agent to Trash")
    let postUninstallRegistry =
      try JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as! JSONObject
    let remainingIds = (postUninstallRegistry["plugins"] as! [JSONObject]).compactMap {
      $0["id"] as? String
    }
    check(remainingIds == ["other-plugin"], "GUI uninstall unregisters only kimi-stats-hud")
    check(fm.fileExists(atPath: hostSessionFile.path), "host session data remains untouched")

    print("\(checks) app installation checks passed")
  }
}
