import CryptoKit
import Darwin
import Foundation
import StatsCore

package enum Lifecycle {
  // Every lifecycle event the host documents. The plugin registers only the
  // low-frequency ones, but a manually registered tool event must still be
  // readable instead of being stored as an unknown string.
  package static let hookEvents: Set<String> = [
    "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionResult",
    "UserPromptSubmit", "Stop", "StopFailure", "Interrupt", "SessionStart", "SessionEnd",
    "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "Notification",
  ]
  package struct HookReport {
    package let event: String, sessionID: String, title: String?, source: String?, time: Double
  }
  // The last lifecycle report, used for diagnostics and to refresh promptly. The
  // file holds no prompt, reply, tool input or tool output.
  package static func hookReport(support: URL) -> HookReport? {
    let file = support.appendingPathComponent("hook-context.json")
    guard let info = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]),
      info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 4096,
      let value = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? JSONObject,
      let event = value["event"] as? String, hookEvents.contains(event),
      let id = value["sessionId"] as? String, !id.isEmpty,
      let time = number(value["updatedAt"])
    else { return nil }
    return HookReport(
      event: event, sessionID: id, title: SessionTitle.nonempty(value["title"]),
      source: SessionTitle.nonempty(value["source"]), time: time)
  }
  // Validation and storage for one lifecycle report, kept separate from the
  // command-line entry so it can be exercised without the installed app. Prompt,
  // reply, tool input and tool output are never stored.
  @discardableResult package static func recordHook(
    _ payload: JSONObject, support: URL, clock: StatsClock = SystemStatsClock()
  ) throws -> JSONObject {
    guard let id = payload["session_id"] as? String,
      id.range(of: "^session_[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil
    else { throw error("无效的 hook 会话信息") }
    let event = payload["hook_event_name"] as? String ?? "SessionStart"
    guard hookEvents.contains(event) else { throw error("未知的 hook 事件") }
    // This is lifecycle context only. It is never treated as the selected GUI tab.
    // Every stored string is bounded so one hostile payload cannot push the file
    // past the reader's size limit and silence all later reports.
    func bounded(_ key: String) -> String {
      String(SessionTitle.nonempty(payload[key])?.prefix(200) ?? "unknown")
    }
    var value: JSONObject = [
      "sessionId": id, "event": event, "source": bounded("source"),
      "clientType": bounded("client_type"), "updatedAt": clock.milliseconds,
    ]
    for (key, source) in [
      ("title", "session_title"), ("model", "model"), ("profile", "profile"), ("reason", "reason"),
      ("trigger", "trigger"),
    ] {
      if let text = SessionTitle.nonempty(payload[source]) { value[key] = String(text.prefix(200)) }
    }
    try writeJSON(value, to: support.appendingPathComponent("hook-context.json"))
    return value
  }
  @discardableResult package static func run(
    _ path: String, _ arguments: [String], quiet: Bool = true
  ) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    if quiet {
      p.standardOutput = FileHandle.nullDevice
      p.standardError = FileHandle.nullDevice
    }
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
  }
  package static func error(_ text: String) -> NSError {
    NSError(domain: Product.name, code: 1, userInfo: [NSLocalizedDescriptionKey: text])
  }
  package static func writeJSON(_ value: Any, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(
      to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  package static func commandLine() -> Bool {
    let args = CommandLine.arguments
    guard args.count > 1 else { return false }
    do {
      if args[1] == "--read-once" {
        let selectedProvider: StatsProvider
        if let index = args.firstIndex(of: "--provider"), index + 1 < args.count,
          let value = StatsProvider(rawValue: args[index + 1])
        {
          selectedProvider = value
        } else if args.contains("--provider") {
          throw error("--provider 必须为 codex 或 kimi")
        } else {
          selectedProvider = StatsProvider(rawValue: Product.provider)!
        }
        let value = SessionReader(root: selectedProvider.dataRoot, provider: selectedProvider).scan(
          selected: nil)
        let data = try JSONSerialization.data(
          withJSONObject: value.legacyJSON, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
        return true
      }
      if args[1] == "--install" {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
          throw error("请使用 .app 应用包内的可执行文件安装。")
        }
        var applicationsDir: URL?
        if let index = args.firstIndex(of: "--applications-dir") {
          guard index + 1 < args.count, !args[index + 1].isEmpty else {
            throw error("--applications-dir 必须指定有效目录")
          }
          applicationsDir = URL(fileURLWithPath: args[index + 1])
        }
        let destination = try AppInstallation.installBundle(
          from: Bundle.main.bundleURL, to: applicationsDir, launchAfterInstall: true)
        print("已安装并启动：\(destination.path)")
        return true
      }
      if args[1] == "--uninstall" {
        try uninstall()
        return true
      }
      if args[1] == "--record-session" {
        let bytes = try FileHandle.standardInput.read(upToCount: 65537) ?? Data()
        guard bytes.count <= 65536,
          let o = try JSONSerialization.jsonObject(with: bytes) as? JSONObject
        else { throw error("无效的 hook 会话信息") }
        try recordHook(o, support: Product.support)
        return true
      }
      throw error(
        "未知参数。支持 --read-once [--provider codex|kimi]、--install [--applications-dir <dir>]、--uninstall、--record-session"
      )
    } catch {
      FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
      exit(1)
    }
  }
  package static func installedKimiRoot(home: URL, support: URL, launch: URL) throws -> URL {
    let fm = FileManager.default
    // Read installed configuration, not a potentially unrelated KIMI_CODE_HOME
    // inherited from the terminal invoking --uninstall.
    let state = support.appendingPathComponent("installation.json")
    if fm.fileExists(atPath: state.path) {
      guard
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? JSONObject,
        number(value["version"]) == 1, let path = value["kimiDataRoot"] as? String,
        path.hasPrefix("/")
      else { throw error("安装记录格式无效；保留插件和应用。") }
      return URL(fileURLWithPath: path).standardizedFileURL
    }
    if fm.fileExists(atPath: launch.path) {
      guard
        let value = try PropertyListSerialization.propertyList(
          from: Data(contentsOf: launch), format: nil) as? JSONObject
      else {
        throw error("登录项格式无效；无法确认 Kimi 插件目录，保留应用。")
      }
      if let env = value["EnvironmentVariables"] as? [String: String],
        let path = env["KIMI_CODE_HOME"]
      {
        guard path.hasPrefix("/") else { throw error("登录项中的 Kimi 数据目录无效；保留应用。") }
        return URL(fileURLWithPath: path).standardizedFileURL
      }
      return home.appendingPathComponent(".kimi-code")
    }
    throw error("缺少安装记录和登录项，无法确认 Kimi 插件目录；请重新安装后卸载。")
  }
  @discardableResult
  package static func removeAppArtifacts(
    bundleURL: URL,
    home: URL,
    support: URL,
    launch: URL,
    kimiRoot: URL,
    preferences: UserDefaults = .standard,
    systemApplications: URL? = nil,
    stopRunningProcesses: Bool
  ) throws -> URL {
    let fm = FileManager.default
    let registry = kimiRoot.appendingPathComponent("plugins/installed.json")
    let managedPlugin = kimiRoot.appendingPathComponent("plugins/managed/kimi-stats-hud")
    var registryOriginal: Data?
    var registryUpdate: JSONObject?
    if fm.fileExists(atPath: registry.path) {
      let original = try Data(contentsOf: registry)
      guard var object = try JSONSerialization.jsonObject(with: original) as? JSONObject,
        number(object["version"]) == 1, let plugins = object["plugins"] as? [JSONObject]
      else { throw error("插件注册表格式不兼容；保留安装。") }
      for plugin in plugins where plugin["id"] as? String == "kimi-stats-hud" {
        guard let path = plugin["root"] as? String,
          URL(fileURLWithPath: path).standardizedFileURL == managedPlugin.standardizedFileURL
        else {
          throw error("Kimi 插件已指向其他目录；未移除插件或应用。")
        }
      }
      object["plugins"] = plugins.filter { $0["id"] as? String != "kimi-stats-hud" }
      registryOriginal = original
      registryUpdate = object
    }
    // Validate all integration metadata before changing the host's bridge.
    if let original = registryOriginal, try Data(contentsOf: registry) != original {
      throw error("插件列表刚被修改，请重试。")
    }
    try restoreBridge(support: support)
    if let object = registryUpdate, let original = registryOriginal {
      guard try Data(contentsOf: registry) == original else {
        throw error("插件列表刚被修改；桥接已恢复，插件和应用保留。请重试。")
      }
      try writeJSON(object, to: registry)
    }
    let trash = home.appendingPathComponent(
      ".Trash/\(Product.name)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6))")
    try fm.createDirectory(at: trash, withIntermediateDirectories: true)
    if stopRunningProcesses {
      try run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(Product.bundleID)"])
      // Hook-started instances are not necessarily managed by launchd. Match this exact executable,
      // and exclude this uninstall process before sending SIGTERM.
      if let exe = Bundle.main.executableURL?.path {
        let running = Process()
        running.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        running.arguments = ["-f", "^" + NSRegularExpression.escapedPattern(for: exe) + "$"]
        let output = Pipe()
        running.standardOutput = output
        running.standardError = FileHandle.nullDevice
        try running.run()
        let ids = output.fileHandleForReading.readDataToEndOfFile()
        running.waitUntilExit()
        for item in String(decoding: ids, as: UTF8.self).split(separator: "\n") {
          if let pid = Int32(item), pid != getpid() { kill(pid, SIGTERM) }
        }
      }
    }
    preferences.removePersistentDomain(forName: Product.bundleID)
    let appName = Product.name + ".app"
    let realHome = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
    let targetHome = home.resolvingSymlinksInPath().standardizedFileURL
    let sysApps =
      systemApplications
      ?? (targetHome == realHome ? URL(fileURLWithPath: "/Applications") : nil)
    var candidates = [
      support,
      launch,
      managedPlugin,
      bundleURL.standardizedFileURL,
      home.appendingPathComponent("Applications").appendingPathComponent(appName),
      support.appendingPathComponent(appName),
    ]
    if let sysApps {
      candidates.append(sysApps.appendingPathComponent(appName))
    }
    var seenPaths = Set<String>()
    var usedNames = Set<String>()
    for source in candidates {
      let standardized = source.standardizedFileURL
      guard seenPaths.insert(standardized.path).inserted else { continue }
      guard fm.fileExists(atPath: standardized.path) else { continue }
      var name = standardized.lastPathComponent
      var suffix = 2
      while usedNames.contains(name) || fm.fileExists(atPath: trash.appendingPathComponent(name).path) {
        name = "\(standardized.deletingPathExtension().lastPathComponent)-\(suffix)"
        if !standardized.pathExtension.isEmpty { name += ".\(standardized.pathExtension)" }
        suffix += 1
      }
      usedNames.insert(name)
      try fm.moveItem(at: standardized, to: trash.appendingPathComponent(name))
    }
    return trash
  }

  private static func uninstall() throws {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let support = Product.support
    guard AppInstallation.isInstalledAppBundle(Bundle.main.bundleURL) else {
      throw error("请使用已安装 App 内的可执行文件卸载。")
    }
    let launch = home.appendingPathComponent("Library/LaunchAgents/\(Product.bundleID).plist")
    let kimiRoot = try installedKimiRoot(home: home, support: support, launch: launch)
    let trash = try removeAppArtifacts(
      bundleURL: Bundle.main.bundleURL,
      home: home,
      support: support,
      launch: launch,
      kimiRoot: kimiRoot,
      stopRunningProcesses: true
    )
    print("\(Product.name) 已卸载；组件已移至 \(trash.path)。Codex、Kimi 宿主和会话数据不受影响。")
  }
  private static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  package static func restoreBridge(support: URL) throws {
    let fm = FileManager.default
    let folder = support.appendingPathComponent("kimi-bridge")
    let manifest = folder.appendingPathComponent("manifest.json")
    guard fm.fileExists(atPath: manifest.path) else { return }
    let state =
      try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? JSONObject ?? [:]
    guard let renderer = state["renderer"] as? String,
      state["asset"] as? String == "assets/agent-stats-kimi-bridge.js"
    else { throw error("桥接备份格式无效；保留备份。") }
    let original = try Data(contentsOf: folder.appendingPathComponent("original-index.html"))
    guard hash(original) == state["originalSha256"] as? String else {
      throw error("原页面备份校验失败；保留备份。")
    }
    let root = URL(fileURLWithPath: renderer)
    let index = root.appendingPathComponent("index.html")
    let asset = root.appendingPathComponent("assets/agent-stats-kimi-bridge.js")
    if fm.fileExists(atPath: asset.path),
      hash(try Data(contentsOf: asset)) != state["assetSha256"] as? String
    {
      throw error("桥接资源已被修改；保留备份。")
    }
    var replacement: Data?
    if fm.fileExists(atPath: index.path) {
      let raw = try Data(contentsOf: index)
      guard var text = String(data: raw, encoding: .utf8) else { throw error("无法读取宿主页面；保留备份。") }
      if hash(raw) == state["patchedSha256"] as? String {
        replacement = original
      } else {
        let begin = "<!-- AgentStats Kimi Bridge v1 BEGIN -->"
        let end = "<!-- AgentStats Kimi Bridge v1 END -->"
        if text.contains(begin) || text.contains(end) {
          guard text.components(separatedBy: begin).count == 2,
            text.components(separatedBy: end).count == 2, let a = text.range(of: begin),
            let b = text.range(of: end), a.lowerBound < b.lowerBound
          else { throw error("桥接标记异常；保留页面与备份。") }
          var stop = b.upperBound
          if stop < text.endIndex && text[stop] == "\n" { stop = text.index(after: stop) }
          text.removeSubrange(a.lowerBound..<stop)
          replacement = Data(text.utf8)
        }
      }
    }
    // Stop any already-open renderer's heartbeat before retiring the local service.
    if let bytes = try? Data(contentsOf: folder.appendingPathComponent("connection.json")),
      let cfg = try? JSONSerialization.jsonObject(with: bytes) as? JSONObject,
      let port = number(cfg["port"]), let key = cfg["key"] as? String,
      let url = URL(string: "http://127.0.0.1:\(Int(port))/disable")
    {
      var req = URLRequest(url: url)
      req.httpMethod = "POST"
      req.setValue(key, forHTTPHeaderField: "X-Agent-Stats-Key")
      req.timeoutInterval = 2
      let done = DispatchSemaphore(value: 0)
      URLSession.shared.dataTask(with: req) { _, _, _ in done.signal() }.resume()
      _ = done.wait(timeout: .now() + 3)
      Thread.sleep(forTimeInterval: 2.2)
    }
    if let replacement {
      let permissions = try fm.attributesOfItem(atPath: index.path)[.posixPermissions]
      try replacement.write(to: index, options: .atomic)
      if let permissions {
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: index.path)
      }
    }
    if fm.fileExists(atPath: asset.path) { try fm.removeItem(at: asset) }
  }
}
