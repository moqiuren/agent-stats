import Darwin
import Foundation
import StatsCore

package enum KimiPluginStatus: Equatable {
  case synced
  case disabledByUser
  case notSynced
  case error(String)
}

package protocol AppSystemIntegrating {
  var isInStandardApplicationsLocation: Bool { get }
  var isLaunchAtLoginEnabled: Bool { get }
  func setLaunchAtLogin(_ enabled: Bool) throws
  func kimiPluginStatus() -> KimiPluginStatus
  @discardableResult func syncKimiPlugin(forceEnable: Bool) throws -> KimiPluginStatus
  func performSilentLaunchMaintenance()
  @discardableResult func relocateToApplicationsAndRelaunch() throws -> URL
  func revealCurrentAppInFinder()
  func performGUIUninstall() throws
  @discardableResult func installUpdateAndRelaunch(from stagedApp: URL) throws -> URL
}

package enum AppInstallation {
  package static func standardApplicationsDirectory(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    systemApplications: URL? = nil,
    isWritable: ((URL) -> Bool)? = nil
  ) -> URL {
    let realHome = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
      .standardizedFileURL
    let targetHome = home.resolvingSymlinksInPath().standardizedFileURL
    let sysApps = systemApplications ?? (targetHome == realHome ? URL(fileURLWithPath: "/Applications") : nil)
    let checkWritable = isWritable ?? { FileManager.default.isWritableFile(atPath: $0.path) }
    if let sysApps, checkWritable(sysApps) {
      return sysApps.standardizedFileURL
    }
    return home.appendingPathComponent("Applications").standardizedFileURL
  }

  package static func isStandardInstallLocation(
    _ url: URL,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    support: URL = Product.support
  ) -> Bool {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    guard resolved.pathExtension == "app" else { return false }
    let path = resolved.path
    if path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") || path.contains("/.build/") {
      return false
    }
    let downloads = home.appendingPathComponent("Downloads").resolvingSymlinksInPath()
      .standardizedFileURL.path
    if path == downloads || path.hasPrefix(downloads + "/") {
      return false
    }
    let parent = resolved.deletingLastPathComponent().standardizedFileURL.path
    let systemApps = URL(fileURLWithPath: "/Applications").resolvingSymlinksInPath()
      .standardizedFileURL.path
    let userApps = home.appendingPathComponent("Applications").resolvingSymlinksInPath()
      .standardizedFileURL.path
    let supportApp = support.appendingPathComponent(Product.name + ".app").resolvingSymlinksInPath()
      .standardizedFileURL.path
    return parent == systemApps || parent == userApps || path == supportApp
  }

  package static func isInstalledAppBundle(_ url: URL) -> Bool {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    guard resolved.pathExtension == "app" else { return false }
    let path = resolved.path
    return !path.hasPrefix("/Volumes/") && !path.contains("/AppTranslocation/")
      && !path.contains("/.build/")
  }

  package static func launchAgentURL(
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    home.appendingPathComponent("Library/LaunchAgents/\(Product.bundleID).plist")
  }

  package static func isLaunchAtLoginEnabled(
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> Bool {
    FileManager.default.fileExists(atPath: launchAgentURL(home: home).path)
  }

  private static func timestampString() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
    return formatter.string(from: Date())
  }

  private static func shellQuote(_ value: String) -> String {
    if !value.isEmpty
      && value.range(of: "^[A-Za-z0-9_@%+=:,./-]+$", options: .regularExpression) != nil
    {
      return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
  }

  package static func expectedPluginManifest(bundleURL: URL) -> JSONObject {
    let appPath = bundleURL.standardizedFileURL.path
    let exePath = bundleURL.standardizedFileURL.appendingPathComponent(
      "Contents/MacOS/\(Product.executable)"
    ).path
    let report = "\(shellQuote(exePath)) --record-session"
    let startCommand = report + "; /usr/bin/open -g \(shellQuote(appPath))"
    let lifecycle = [
      "Stop", "StopFailure", "SessionEnd", "SubagentStart", "SubagentStop", "PreCompact",
      "PostCompact",
    ]
    var hooks: [JSONObject] = [["event": "SessionStart", "command": startCommand, "timeout": 10]]
    hooks += lifecycle.map { ["event": $0, "command": report, "timeout": 5] }
    return [
      "name": "kimi-stats-hud",
      "version": Product.version,
      "description":
        "Agent Stats 的 Kimi Code 启动入口与会话生命周期上下文。统一应用同时支持 Codex、Kimi Code；插件移除不会卸载应用。",
      "license": "MIT",
      "interface": [
        "displayName": Product.name,
        "shortDescription": "Codex、Kimi Code 统一原生统计",
      ],
      "hooks": hooks,
    ]
  }

  private static func readInstallationRecord(support: URL) -> JSONObject {
    let file = support.appendingPathComponent("installation.json")
    guard let data = try? Data(contentsOf: file),
      let object = try? JSONSerialization.jsonObject(with: data) as? JSONObject
    else { return [:] }
    return object
  }

  private static func writeInstallationRecord(
    _ record: JSONObject, support: URL
  ) throws {
    let file = support.appendingPathComponent("installation.json")
    try Lifecycle.writeJSON(record, to: file)
  }

  private static func preservedEnvironment(
    home: URL, support: URL, launch: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    let keys = ["CODEX_HOME", "KIMI_CODE_HOME"]
    var result = [String: String]()
    for legacy in Product.legacyProducts {
      guard let bundleID = legacy["bundle_id"] else { continue }
      let legacyLaunch = home.appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")
      if let data = try? Data(contentsOf: legacyLaunch),
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
          as? JSONObject,
        let env = plist["EnvironmentVariables"] as? [String: String]
      {
        for key in keys where env[key]?.isEmpty == false { result[key] = env[key] }
      }
    }
    let record = readInstallationRecord(support: support)
    if let savedEnv = record["environmentVariables"] as? [String: String] {
      for key in keys where savedEnv[key]?.isEmpty == false { result[key] = savedEnv[key] }
    }
    if let data = try? Data(contentsOf: launch),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? JSONObject,
      let env = plist["EnvironmentVariables"] as? [String: String]
    {
      for key in keys where env[key]?.isEmpty == false { result[key] = env[key] }
    }
    for key in keys {
      if let value = environment[key], !value.isEmpty { result[key] = value }
    }
    return result
  }

  package static func setLaunchAtLogin(
    _ enabled: Bool,
    bundleURL: URL,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    support: URL = Product.support,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    let fm = FileManager.default
    let launch = launchAgentURL(home: home)
    try fm.createDirectory(at: support, withIntermediateDirectories: true)
    let env = preservedEnvironment(
      home: home, support: support, launch: launch, environment: environment)
    var record = readInstallationRecord(support: support)
    record["version"] = 1
    if record["kimiDataRoot"] == nil {
      record["kimiDataRoot"] =
        env["KIMI_CODE_HOME"] ?? home.appendingPathComponent(".kimi-code").path
    }
    if isStandardInstallLocation(bundleURL, home: home, support: support) {
      record["appPath"] = bundleURL.standardizedFileURL.path
    }
    if !env.isEmpty { record["environmentVariables"] = env }
    try writeInstallationRecord(record, support: support)

    if enabled {
      let executable = bundleURL.standardizedFileURL.appendingPathComponent(
        "Contents/MacOS/\(Product.executable)"
      ).path
      var plist: [String: Any] = [
        "Label": Product.bundleID,
        "ProgramArguments": [executable],
        "RunAtLoad": true,
        "ProcessType": "Interactive",
        "LimitLoadToSessionType": "Aqua",
        "StandardOutPath": support.appendingPathComponent("stdout.log").path,
        "StandardErrorPath": support.appendingPathComponent("stderr.log").path,
      ]
      if !env.isEmpty { plist["EnvironmentVariables"] = env }
      try fm.createDirectory(at: launch.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0)
      try data.write(to: launch, options: .atomic)
      try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: launch.path)
    } else if fm.fileExists(atPath: launch.path) {
      // Never run `launchctl bootout` on the live GUI process; moving the plist
      // to Trash disables future login starts without terminating ourselves.
      let trash = home.appendingPathComponent(
        ".Trash/Agent-Stats-login-item-\(timestampString())-\(UUID().uuidString.prefix(6))")
      try fm.createDirectory(at: trash, withIntermediateDirectories: true)
      try fm.moveItem(at: launch, to: trash.appendingPathComponent(launch.lastPathComponent))
    }
  }

  private static func resolveKimiDataRoot(
    home: URL, support: URL, launch: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> URL {
    let fm = FileManager.default
    let state = support.appendingPathComponent("installation.json")
    if fm.fileExists(atPath: state.path) {
      return try Lifecycle.installedKimiRoot(home: home, support: support, launch: launch)
    }
    if fm.fileExists(atPath: launch.path) {
      return try Lifecycle.installedKimiRoot(home: home, support: support, launch: launch)
    }
    if let envPath = environment["KIMI_CODE_HOME"], envPath.hasPrefix("/") {
      return URL(fileURLWithPath: envPath).standardizedFileURL
    }
    return home.appendingPathComponent(".kimi-code").standardizedFileURL
  }

  package static func kimiPluginStatus(
    bundleURL: URL,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    support: URL = Product.support,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> KimiPluginStatus {
    let launch = launchAgentURL(home: home)
    let kimiRoot: URL
    do {
      kimiRoot = try resolveKimiDataRoot(
        home: home, support: support, launch: launch, environment: environment)
    } catch {
      return .error(error.localizedDescription)
    }
    let plugins = kimiRoot.appendingPathComponent("plugins")
    let registry = plugins.appendingPathComponent("installed.json")
    let managed = plugins.appendingPathComponent("managed/kimi-stats-hud")
    let manifestFile = managed.appendingPathComponent("kimi.plugin.json")
    guard FileManager.default.fileExists(atPath: registry.path) else { return .notSynced }
    guard let original = try? Data(contentsOf: registry),
      let object = try? JSONSerialization.jsonObject(with: original) as? JSONObject,
      number(object["version"]) == 1, let entries = object["plugins"] as? [JSONObject]
    else {
      return .error("插件注册表格式不兼容")
    }
    guard let entry = entries.first(where: { $0["id"] as? String == "kimi-stats-hud" }) else {
      return .notSynced
    }
    if entry["enabled"] as? Bool == false {
      return .disabledByUser
    }
    guard let rootPath = entry["root"] as? String,
      URL(fileURLWithPath: rootPath).standardizedFileURL == managed.standardizedFileURL,
      let manifestData = try? Data(contentsOf: manifestFile),
      let manifestObject = try? JSONSerialization.jsonObject(with: manifestData) as? JSONObject,
      NSDictionary(dictionary: manifestObject).isEqual(to: expectedPluginManifest(bundleURL: bundleURL))
    else {
      return .notSynced
    }
    return .synced
  }

  private static func pruneRegistryBackups(support: URL, home: URL, keep: Int = 5) {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil) else {
      return
    }
    let backups = items.filter {
      let name = $0.lastPathComponent
      return name.hasPrefix("installed-") && name.hasSuffix(".json.backup")
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    let staleCount = max(0, backups.count - keep)
    guard staleCount > 0 else { return }
    let trashFolder = home.appendingPathComponent(
      ".Trash/Agent-Stats-registry-backups-\(timestampString())")
    try? fm.createDirectory(at: trashFolder, withIntermediateDirectories: true)
    for backup in backups.prefix(staleCount) {
      try? fm.moveItem(at: backup, to: trashFolder.appendingPathComponent(backup.lastPathComponent))
    }
  }

  @discardableResult
  package static func syncKimiPlugin(
    bundleURL: URL,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    support: URL = Product.support,
    forceEnable: Bool = false,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> KimiPluginStatus {
    let fm = FileManager.default
    let launch = launchAgentURL(home: home)
    let kimiRoot = try resolveKimiDataRoot(
      home: home, support: support, launch: launch, environment: environment)
    let plugins = kimiRoot.appendingPathComponent("plugins")
    let registry = plugins.appendingPathComponent("installed.json")
    let managed = plugins.appendingPathComponent("managed/kimi-stats-hud")
    let manifestFile = managed.appendingPathComponent("kimi.plugin.json")

    let original = fm.fileExists(atPath: registry.path) ? try Data(contentsOf: registry) : nil
    var registryObject: JSONObject
    if let original {
      guard let parsed = try JSONSerialization.jsonObject(with: original) as? JSONObject,
        number(parsed["version"]) == 1, parsed["plugins"] is [JSONObject]
      else {
        throw Lifecycle.error("插件注册表格式不兼容，未覆盖。")
      }
      registryObject = parsed
    } else {
      registryObject = ["version": 1, "plugins": [JSONObject]()]
    }

    let existingPlugins = registryObject["plugins"] as? [JSONObject] ?? []
    let prior = existingPlugins.first { $0["id"] as? String == "kimi-stats-hud" }
    let targetEnabled = forceEnable ? true : (prior?["enabled"] as? Bool ?? true)
    let expectedManifest = expectedPluginManifest(bundleURL: bundleURL)

    let currentManifestMatches: Bool = {
      guard let data = try? Data(contentsOf: manifestFile),
        let object = try? JSONSerialization.jsonObject(with: data) as? JSONObject
      else { return false }
      return NSDictionary(dictionary: object).isEqual(to: expectedManifest)
    }()
    let currentEntryMatches: Bool = {
      guard let prior else { return false }
      guard let root = prior["root"] as? String else { return false }
      return URL(fileURLWithPath: root).standardizedFileURL == managed.standardizedFileURL
        && (prior["enabled"] as? Bool ?? true) == targetEnabled
    }()

    if currentManifestMatches && currentEntryMatches {
      return targetEnabled ? .synced : .disabledByUser
    }

    try fm.createDirectory(at: support, withIntermediateDirectories: true)
    try fm.createDirectory(at: managed, withIntermediateDirectories: true)

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let now = formatter.string(from: Date())

    var record: JSONObject = [
      "id": "kimi-stats-hud",
      "root": managed.standardizedFileURL.path,
      "source": "local-path",
      "enabled": targetEnabled,
      "installedAt": (prior?["installedAt"] as? String) ?? now,
      "updatedAt": now,
      "originalSource": bundleURL.standardizedFileURL.path,
    ]
    if let existingSource = prior?["originalSource"] as? String, !existingSource.isEmpty {
      record["originalSource"] = existingSource
    }
    var updatedPlugins = existingPlugins.filter { $0["id"] as? String != "kimi-stats-hud" }
    updatedPlugins.append(record)
    registryObject["plugins"] = updatedPlugins

    if let original {
      let backup = support.appendingPathComponent("installed-\(timestampString()).json.backup")
      try original.write(to: backup, options: .atomic)
      pruneRegistryBackups(support: support, home: home)
      if (try? Data(contentsOf: registry)) != original {
        throw Lifecycle.error("插件列表刚被其他进程修改，请重试。")
      }
    }

    let previousManifest = try? Data(contentsOf: manifestFile)
    let manifestBytes = try JSONSerialization.data(
      withJSONObject: expectedManifest, options: [.sortedKeys, .prettyPrinted]) + Data([10])
    let registryBytes = try JSONSerialization.data(
      withJSONObject: registryObject, options: [.sortedKeys, .prettyPrinted]) + Data([10])

    do {
      try manifestBytes.write(to: manifestFile, options: .atomic)
      try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifestFile.path)
      try registryBytes.write(to: registry, options: .atomic)
      try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: registry.path)
    } catch {
      if let previousManifest {
        try? previousManifest.write(to: manifestFile, options: .atomic)
      } else {
        try? fm.removeItem(at: manifestFile)
      }
      throw error
    }

    var installRecord = readInstallationRecord(support: support)
    installRecord["version"] = 1
    installRecord["kimiDataRoot"] = kimiRoot.standardizedFileURL.path
    if isStandardInstallLocation(bundleURL, home: home, support: support) {
      installRecord["appPath"] = bundleURL.standardizedFileURL.path
    }
    try? writeInstallationRecord(installRecord, support: support)

    return targetEnabled ? .synced : .disabledByUser
  }

  package static func migrateLegacyRuntime(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    support: URL = Product.support
  ) {
    let fm = FileManager.default
    let marker = support.appendingPathComponent(".legacy-runtime-migration-v3.json")
    guard !fm.fileExists(atPath: marker.path) else { return }
    guard let kimi = Product.legacyProducts.first(where: { $0["provider"] == "kimi" }),
      let kimiName = kimi["name"]
    else { return }
    let legacy = home.appendingPathComponent("Library/Application Support/\(kimiName)")
    try? fm.createDirectory(at: support, withIntermediateDirectories: true)
    for name in ["kimi-bridge", "hook-context.json"] {
      let source = legacy.appendingPathComponent(name)
      let destination = support.appendingPathComponent(name)
      guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: destination.path) else {
        continue
      }
      let temp = support.appendingPathComponent(".migration-\(UUID().uuidString)-\(name)")
      do {
        try fm.copyItem(at: source, to: temp)
        try fm.moveItem(at: temp, to: destination)
      } catch {
        try? fm.removeItem(at: temp)
      }
    }
    let payload: JSONObject = [
      "version": 3, "source": legacy.path, "completedAt": timestampString(),
    ]
    try? Lifecycle.writeJSON(payload, to: marker)
  }

  package static func performSilentLaunchMaintenance(
    bundleURL: URL = Bundle.main.bundleURL,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    support: URL = Product.support,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    guard isStandardInstallLocation(bundleURL, home: home, support: support) else { return }
    let fm = FileManager.default
    try? fm.createDirectory(at: support, withIntermediateDirectories: true)
    migrateLegacyRuntime(home: home, support: support)

    let launch = launchAgentURL(home: home)
    let expectedExecutable = bundleURL.standardizedFileURL.appendingPathComponent(
      "Contents/MacOS/\(Product.executable)"
    ).path
    if let data = try? Data(contentsOf: launch),
      var plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      var args = plist["ProgramArguments"] as? [String],
      args.first != expectedExecutable
    {
      if args.isEmpty { args = [expectedExecutable] } else { args[0] = expectedExecutable }
      plist["ProgramArguments"] = args
      if let updated = try? PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0)
      {
        try? updated.write(to: launch, options: .atomic)
      }
    }

    var record = readInstallationRecord(support: support)
    let kimiPath =
      (try? resolveKimiDataRoot(
        home: home, support: support, launch: launch, environment: environment
      ).path) ?? (environment["KIMI_CODE_HOME"] ?? home.appendingPathComponent(".kimi-code").path)
    if record["version"] as? Int != 1 || record["kimiDataRoot"] as? String != kimiPath
      || record["appPath"] as? String != bundleURL.standardizedFileURL.path
    {
      record["version"] = 1
      record["kimiDataRoot"] = kimiPath
      record["appPath"] = bundleURL.standardizedFileURL.path
      try? writeInstallationRecord(record, support: support)
    }

    _ = try? syncKimiPlugin(
      bundleURL: bundleURL, home: home, support: support, forceEnable: false,
      environment: environment)
  }

  private static func defaultRunCommand(_ path: String, _ arguments: [String]) throws -> Int32 {
    try Lifecycle.run(path, arguments)
  }

  private static func defaultProcessRunning(_ executablePath: String) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-f", "^" + NSRegularExpression.escapedPattern(for: executablePath) + "$"]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return false }
    task.waitUntilExit()
    return task.terminationStatus == 0
  }

  private static func stopOtherProcesses(executablePath: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-f", "^" + NSRegularExpression.escapedPattern(for: executablePath) + "$"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
      if let pid = Int32(line), pid != getpid() {
        kill(pid, SIGTERM)
      }
    }
  }

  @discardableResult
  package static func installBundle(
    from source: URL,
    to applicationsDir: URL? = nil,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    support: URL = Product.support,
    launchAfterInstall: Bool = true,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    runCommand: ((String, [String]) throws -> Int32)? = nil,
    isProcessRunning: ((String) -> Bool)? = nil
  ) throws -> URL {
    let fm = FileManager.default
    let execCommand = runCommand ?? defaultRunCommand
    let processRunning = isProcessRunning ?? defaultProcessRunning
    let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
    guard fm.fileExists(atPath: resolvedSource.path),
      let infoData = try? Data(
        contentsOf: resolvedSource.appendingPathComponent("Contents/Info.plist")),
      let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil)
        as? JSONObject,
      info["CFBundleIdentifier"] as? String == Product.bundleID
    else {
      throw Lifecycle.error("无效的 \(Product.name) 应用包：\(source.path)")
    }

    try fm.createDirectory(at: support, withIntermediateDirectories: true)
    let targetDir = (applicationsDir ?? standardApplicationsDirectory(home: home))
      .standardizedFileURL
    try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
    let destination = targetDir.appendingPathComponent(Product.name + ".app").standardizedFileURL
    let legacyDestination = support.appendingPathComponent(Product.name + ".app")
      .standardizedFileURL

    let stageParent = fm.isWritableFile(atPath: targetDir.path) ? targetDir : support
    let stage = stageParent.appendingPathComponent(".install-\(UUID().uuidString)")
    try fm.createDirectory(at: stage, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: stage) }
    let stagedApp = stage.appendingPathComponent(Product.name + ".app")
    try fm.copyItem(at: resolvedSource, to: stagedApp)

    for attr in ["com.apple.quarantine", "com.apple.FinderInfo", "com.apple.ResourceFork"] {
      _ = try? execCommand("/usr/bin/xattr", ["-dr", attr, stagedApp.path])
    }
    let verifyStatus = try execCommand(
      "/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedApp.path])
    guard verifyStatus == 0 else {
      throw Lifecycle.error("应用代码签名校验未通过，未安装。")
    }

    migrateLegacyRuntime(home: home, support: support)

    let domain = "gui/\(getuid())"
    let destinationExecutable = destination.appendingPathComponent(
      "Contents/MacOS/\(Product.executable)"
    ).path
    let legacyExecutable = legacyDestination.appendingPathComponent(
      "Contents/MacOS/\(Product.executable)"
    ).path

    let sourceIsRunningDestination =
      resolvedSource == destination || resolvedSource == legacyDestination
    if !sourceIsRunningDestination {
      _ = try? execCommand("/bin/launchctl", ["bootout", "\(domain)/\(Product.bundleID)"])
      stopOtherProcesses(executablePath: destinationExecutable)
      if legacyDestination != destination {
        stopOtherProcesses(executablePath: legacyExecutable)
      }
      let deadline = Date().addingTimeInterval(5)
      while Date() < deadline {
        let loaded = (try? execCommand("/bin/launchctl", ["print", "\(domain)/\(Product.bundleID)"])) == 0
        let stillRunning =
          processRunning(destinationExecutable)
          || (legacyDestination != destination && processRunning(legacyExecutable))
        if !loaded && !stillRunning { break }
        Thread.sleep(forTimeInterval: 0.05)
      }
    }

    let launch = launchAgentURL(home: home)
    let oldLaunch = try? Data(contentsOf: launch)
    var backup: URL?
    if fm.fileExists(atPath: destination.path) {
      let backupURL = support.appendingPathComponent("previous-\(timestampString()).app")
      try fm.moveItem(at: destination, to: backupURL)
      backup = backupURL
    }

    do {
      try fm.moveItem(at: stagedApp, to: destination)
      let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
      if fm.isExecutableFile(atPath: lsregister) {
        _ = try? execCommand(lsregister, ["-f", destination.path])
      }
      try setLaunchAtLogin(
        true, bundleURL: destination, home: home, support: support, environment: environment)
      if launchAfterInstall {
        let bootStatus = try execCommand("/bin/launchctl", ["bootstrap", domain, launch.path])
        if bootStatus != 0 {
          _ = try execCommand("/usr/bin/open", ["-g", destination.path])
        }
        let startDeadline = Date().addingTimeInterval(8)
        while !processRunning(destinationExecutable), Date() < startDeadline {
          Thread.sleep(forTimeInterval: 0.15)
        }
        if !processRunning(destinationExecutable) {
          let openStatus = try execCommand("/usr/bin/open", ["-g", destination.path])
          if openStatus != 0 {
            throw Lifecycle.error("\(Product.name) 未成功启动；已恢复旧版本。")
          }
        }
      }
      _ = try syncKimiPlugin(
        bundleURL: destination, home: home, support: support, forceEnable: false,
        environment: environment)
      var record = readInstallationRecord(support: support)
      record["version"] = 1
      record["appPath"] = destination.standardizedFileURL.path
      if record["kimiDataRoot"] == nil {
        record["kimiDataRoot"] =
          environment["KIMI_CODE_HOME"] ?? home.appendingPathComponent(".kimi-code").path
      }
      try writeInstallationRecord(record, support: support)
    } catch {
      if fm.fileExists(atPath: destination.path) {
        let broken = home.appendingPathComponent(
          ".Trash/Agent-Stats-failed-install-\(timestampString())")
        try? fm.createDirectory(at: broken, withIntermediateDirectories: true)
        try? fm.moveItem(at: destination, to: broken.appendingPathComponent(destination.lastPathComponent))
      }
      if let backup, fm.fileExists(atPath: backup.path) {
        try? fm.moveItem(at: backup, to: destination)
      }
      if let oldLaunch {
        try? oldLaunch.write(to: launch, options: .atomic)
      } else {
        try? fm.removeItem(at: launch)
      }
      throw error
    }

    if legacyDestination != destination && fm.fileExists(atPath: legacyDestination.path) {
      let trash = home.appendingPathComponent(
        ".Trash/Agent-Stats-legacy-app-\(timestampString())")
      try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
      try? fm.moveItem(
        at: legacyDestination, to: trash.appendingPathComponent(legacyDestination.lastPathComponent))
    }
    if let backup, fm.fileExists(atPath: backup.path) {
      let trash = home.appendingPathComponent(
        ".Trash/Agent-Stats-previous-\(timestampString())")
      try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
      try? fm.moveItem(at: backup, to: trash.appendingPathComponent(destination.lastPathComponent))
    }
    let downloads = home.appendingPathComponent("Downloads").resolvingSymlinksInPath()
      .standardizedFileURL.path
    if resolvedSource != destination,
      resolvedSource.path == downloads || resolvedSource.path.hasPrefix(downloads + "/"),
      fm.fileExists(atPath: resolvedSource.path)
    {
      let trash = home.appendingPathComponent(
        ".Trash/Agent-Stats-downloaded-\(timestampString())")
      try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
      try? fm.moveItem(
        at: resolvedSource, to: trash.appendingPathComponent(resolvedSource.lastPathComponent))
    }
    return destination
  }

  @discardableResult
  package static func relocateToApplicationsAndRelaunch(
    bundleURL: URL = Bundle.main.bundleURL,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    support: URL = Product.support
  ) throws -> URL {
    let destination = try installBundle(
      from: bundleURL, home: home, support: support, launchAfterInstall: false)
    let launcher = Process()
    launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
    launcher.arguments = ["-c", "sleep 0.3; /usr/bin/open -n \"$1\"", "_", destination.path]
    launcher.standardOutput = FileHandle.nullDevice
    launcher.standardError = FileHandle.nullDevice
    try launcher.run()
    return destination
  }

  @discardableResult
  package static func applyStagedUpdateAndRelaunch(
    from stagedApp: URL,
    currentBundleURL: URL = Bundle.main.bundleURL,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    support: URL = Product.support,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    runCommand: ((String, [String]) throws -> Int32)? = nil,
    scheduleRelaunch: Bool = true
  ) throws -> URL {
    let fm = FileManager.default
    let execCommand = runCommand ?? defaultRunCommand
    let resolvedSource = stagedApp.resolvingSymlinksInPath().standardizedFileURL
    guard fm.fileExists(atPath: resolvedSource.path),
      let infoData = try? Data(
        contentsOf: resolvedSource.appendingPathComponent("Contents/Info.plist")),
      let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil)
        as? JSONObject,
      info["CFBundleIdentifier"] as? String == Product.bundleID
    else {
      throw Lifecycle.error("无效的更新应用包：\(stagedApp.path)")
    }

    try fm.createDirectory(at: support, withIntermediateDirectories: true)
    let resolvedCurrent = currentBundleURL.resolvingSymlinksInPath().standardizedFileURL
    let currentParent = resolvedCurrent.deletingLastPathComponent().standardizedFileURL
    let destination: URL
    if isStandardInstallLocation(resolvedCurrent, home: home, support: support),
      fm.isWritableFile(atPath: currentParent.path)
    {
      destination = resolvedCurrent
    } else {
      destination = standardApplicationsDirectory(home: home)
        .appendingPathComponent(Product.name + ".app")
        .standardizedFileURL
    }

    let targetDir = destination.deletingLastPathComponent().standardizedFileURL
    try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
    let stageParent = fm.isWritableFile(atPath: targetDir.path) ? targetDir : support
    let stage = stageParent.appendingPathComponent(".update-stage-\(UUID().uuidString)")
    try fm.createDirectory(at: stage, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: stage) }

    let stagedCopy = stage.appendingPathComponent(Product.name + ".app")
    try fm.copyItem(at: resolvedSource, to: stagedCopy)
    for attr in ["com.apple.quarantine", "com.apple.FinderInfo", "com.apple.ResourceFork"] {
      _ = try? execCommand("/usr/bin/xattr", ["-dr", attr, stagedCopy.path])
    }
    let verifyStatus = try execCommand(
      "/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedCopy.path])
    guard verifyStatus == 0 else {
      throw Lifecycle.error("更新包代码签名校验未通过，已取消替换。")
    }

    let launchWasEnabled = isLaunchAtLoginEnabled(home: home)
    var backup: URL?
    if fm.fileExists(atPath: destination.path) {
      let backupURL = support.appendingPathComponent("previous-\(timestampString()).app")
      try fm.moveItem(at: destination, to: backupURL)
      backup = backupURL
    }

    do {
      try fm.moveItem(at: stagedCopy, to: destination)
      let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
      if fm.isExecutableFile(atPath: lsregister) {
        _ = try? execCommand(lsregister, ["-f", destination.path])
      }
      if launchWasEnabled {
        try setLaunchAtLogin(
          true, bundleURL: destination, home: home, support: support, environment: environment)
      } else {
        let launch = launchAgentURL(home: home)
        let env = preservedEnvironment(
          home: home, support: support, launch: launch, environment: environment)
        var record = readInstallationRecord(support: support)
        record["version"] = 1
        record["appPath"] = destination.standardizedFileURL.path
        if record["kimiDataRoot"] == nil {
          record["kimiDataRoot"] =
            env["KIMI_CODE_HOME"] ?? home.appendingPathComponent(".kimi-code").path
        }
        if !env.isEmpty { record["environmentVariables"] = env }
        try writeInstallationRecord(record, support: support)
      }
      _ = try? syncKimiPlugin(
        bundleURL: destination, home: home, support: support, forceEnable: false,
        environment: environment)
    } catch {
      if fm.fileExists(atPath: destination.path) {
        let broken = home.appendingPathComponent(
          ".Trash/Agent-Stats-failed-update-\(timestampString())")
        try? fm.createDirectory(at: broken, withIntermediateDirectories: true)
        try? fm.moveItem(
          at: destination, to: broken.appendingPathComponent(destination.lastPathComponent))
      }
      if let backup, fm.fileExists(atPath: backup.path) {
        try? fm.moveItem(at: backup, to: destination)
      }
      throw error
    }

    if let backup, fm.fileExists(atPath: backup.path) {
      let trash = home.appendingPathComponent(
        ".Trash/Agent-Stats-previous-\(timestampString())")
      try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
      try? fm.moveItem(at: backup, to: trash.appendingPathComponent(destination.lastPathComponent))
    }
    let updatesDir = support.appendingPathComponent("updates")
    if fm.fileExists(atPath: updatesDir.path) {
      let trash = home.appendingPathComponent(
        ".Trash/Agent-Stats-updates-\(timestampString())")
      try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
      try? fm.moveItem(at: updatesDir, to: trash.appendingPathComponent(updatesDir.lastPathComponent))
    }
    if scheduleRelaunch {
      let launcher = Process()
      launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
      launcher.arguments = ["-c", "sleep 0.4; /usr/bin/open -n \"$1\"", "_", destination.path]
      launcher.standardOutput = FileHandle.nullDevice
      launcher.standardError = FileHandle.nullDevice
      try launcher.run()
    }
    return destination
  }

  package static func revealCurrentAppInFinder(bundleURL: URL = Bundle.main.bundleURL) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-R", bundleURL.standardizedFileURL.path]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try? task.run()
  }

  package static func performGUIUninstall(
    bundleURL: URL = Bundle.main.bundleURL,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    support: URL = Product.support,
    preferences: UserDefaults = .standard,
    scheduleBootout: Bool = true
  ) throws {
    let fm = FileManager.default
    guard isInstalledAppBundle(bundleURL) else {
      throw Lifecycle.error("请先将 \(Product.name) 安装到应用程序目录后再执行卸载。")
    }
    let launch = launchAgentURL(home: home)
    let state = support.appendingPathComponent("installation.json")
    let kimiRoot: URL
    if fm.fileExists(atPath: state.path) || fm.fileExists(atPath: launch.path) {
      kimiRoot = try Lifecycle.installedKimiRoot(home: home, support: support, launch: launch)
    } else {
      kimiRoot = home.appendingPathComponent(".kimi-code").standardizedFileURL
    }
    try Lifecycle.removeAppArtifacts(
      bundleURL: bundleURL,
      home: home,
      support: support,
      launch: launch,
      kimiRoot: kimiRoot,
      preferences: preferences,
      stopRunningProcesses: false
    )
    if scheduleBootout {
      let target = "gui/\(getuid())/\(Product.bundleID)"
      let task = Process()
      task.executableURL = URL(fileURLWithPath: "/bin/sh")
      task.arguments = ["-c", "sleep 0.4; /bin/launchctl bootout \"$1\" >/dev/null 2>&1 || true", "_", target]
      task.standardOutput = FileHandle.nullDevice
      task.standardError = FileHandle.nullDevice
      try? task.run()
    }
  }
}

package struct LiveAppSystemIntegration: AppSystemIntegrating {
  package init() {}
  package var isInStandardApplicationsLocation: Bool {
    AppInstallation.isStandardInstallLocation(Bundle.main.bundleURL)
  }
  package var isLaunchAtLoginEnabled: Bool {
    AppInstallation.isLaunchAtLoginEnabled()
  }
  package func setLaunchAtLogin(_ enabled: Bool) throws {
    try AppInstallation.setLaunchAtLogin(enabled, bundleURL: Bundle.main.bundleURL)
  }
  package func kimiPluginStatus() -> KimiPluginStatus {
    AppInstallation.kimiPluginStatus(bundleURL: Bundle.main.bundleURL)
  }
  @discardableResult
  package func syncKimiPlugin(forceEnable: Bool) throws -> KimiPluginStatus {
    try AppInstallation.syncKimiPlugin(bundleURL: Bundle.main.bundleURL, forceEnable: forceEnable)
  }
  package func performSilentLaunchMaintenance() {
    AppInstallation.performSilentLaunchMaintenance(bundleURL: Bundle.main.bundleURL)
  }
  @discardableResult
  package func relocateToApplicationsAndRelaunch() throws -> URL {
    try AppInstallation.relocateToApplicationsAndRelaunch(bundleURL: Bundle.main.bundleURL)
  }
  package func revealCurrentAppInFinder() {
    AppInstallation.revealCurrentAppInFinder(bundleURL: Bundle.main.bundleURL)
  }
  package func performGUIUninstall() throws {
    try AppInstallation.performGUIUninstall(bundleURL: Bundle.main.bundleURL)
  }
  @discardableResult
  package func installUpdateAndRelaunch(from stagedApp: URL) throws -> URL {
    try AppInstallation.applyStagedUpdateAndRelaunch(
      from: stagedApp, currentBundleURL: Bundle.main.bundleURL)
  }
}
