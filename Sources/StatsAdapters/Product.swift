import Foundation
import StatsCore

extension StatsProvider {
  private static let defaultProviders: [String: [String: String]] = [
    "codex": ["name": "Codex", "host_bundle_id": "com.openai.codex"],
    "kimi": ["name": "Kimi Code", "host_bundle_id": "com.kimi.code.desktop"],
  ]
  private var metadata: [String: String] {
    let providers =
      (Product.appInfo["StatsProviders"] ?? Product.developmentManifest["providers"])
      as? [String: [String: String]]
    return providers?[rawValue] ?? Self.defaultProviders[rawValue] ?? [:]
  }
  package var name: String { metadata["name"] ?? rawValue.capitalized }
  package var hostBundleID: String { metadata["host_bundle_id"] ?? "" }
  package var shortName: String { self == .kimi ? "Kimi" : name }
  package var dataRoot: URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let key = ["codex": "CODEX_HOME", "kimi": "KIMI_CODE_HOME"][rawValue]!
    if let value = ProcessInfo.processInfo.environment[key] { return URL(fileURLWithPath: value) }
    return home.appendingPathComponent(["codex": ".codex", "kimi": ".kimi-code"][rawValue]!)
  }
  package static func host(_ bundleID: String?) -> Self? {
    allCases.first { $0.hostBundleID == bundleID }
  }
}

package enum Product {
  // SwiftPM tests run inside xctest. Only the actual app bundle supplies product
  // identity; unbundled tools/tests read the single source products.json.
  package static var appInfo: [String: Any] {
    guard let info = Bundle.main.infoDictionary, info["StatsProviders"] != nil else { return [:] }
    return info
  }
  // Unbundled tests use the same product source; installed apps use generated Info.plist.
  package static let developmentManifest: [String: Any] = {
    #if DEBUG
      let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
          "products.json")
      guard let data = try? Data(contentsOf: file),
        let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]]
      else { return [:] }
      return manifest["agent"] ?? [:]
    #else
      return [:]
    #endif
  }()
  // Only the command-line/test default. Runtime collectors own an immutable provider.
  package static var provider: String {
    StatsProvider(rawValue: ProcessInfo.processInfo.environment["STATS_PROVIDER"] ?? "")?.rawValue
      ?? "codex"
  }
  package static var name: String {
    appInfo["CFBundleName"] as? String ?? developmentManifest["name"] as? String ?? "Agent Stats"
  }
  package static var executable: String {
    appInfo["CFBundleExecutable"] as? String ?? developmentManifest["executable"] as? String
      ?? "AgentStats"
  }
  package static var bundleID: String {
    appInfo["CFBundleIdentifier"] as? String ?? developmentManifest["bundle_id"] as? String
      ?? "local.agent.stats"
  }
  package static var version: String {
    appInfo["CFBundleShortVersionString"] as? String ?? developmentManifest["version"] as? String
      ?? "1.1.0"
  }
  package static var build: String {
    appInfo["CFBundleVersion"] as? String ?? developmentManifest["build"] as? String ?? "2"
  }
  package static var githubRepository: String {
    if let env = ProcessInfo.processInfo.environment["AGENT_STATS_REPO"], !env.isEmpty {
      return env
    }
    return (appInfo["StatsGitHubRepo"] as? String)
      ?? (developmentManifest["github_repo"] as? String)
      ?? "moqiuren/agent-stats"
  }
  package static var legacyProducts: [[String: String]] {
    (appInfo["StatsLegacyProducts"] ?? developmentManifest["legacy_products"])
      as? [[String: String]] ?? []
  }
  package static var hostBundleID: String { StatsProvider(rawValue: provider)!.hostBundleID }
  package static var support: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/\(name)")
  }
  // Performance-only state (parsed log accumulators). Tests redirect it so a
  // synthetic root can never read or prune a real machine's cache.
  package static var cacheDirectory: URL {
    if let value = ProcessInfo.processInfo.environment["STATS_CACHE_DIR"], !value.isEmpty {
      return URL(fileURLWithPath: value)
    }
    return support
  }
  package static var dataRoot: URL { StatsProvider(rawValue: provider)!.dataRoot }
  package static func migratePreferences(
    to preferences: UserDefaults, legacyValues: [String: [String: Any]]? = nil
  ) {
    guard !preferences.bool(forKey: "unifiedMigration.v1") else { return }
    let legacy =
      (appInfo["StatsLegacyProducts"] ?? developmentManifest["legacy_products"])
      as? [[String: String]] ?? []
    for provider in [StatsProvider.codex, .kimi] {
      let id = legacy.first(where: { $0["provider"] == provider.rawValue })?["bundle_id"]
      guard
        let values = legacyValues?[provider.rawValue]
          ?? (legacyValues == nil ? id.flatMap { preferences.persistentDomain(forName: $0) } : nil)
      else { continue }
      for (key, value) in values where key.hasSuffix("." + provider.rawValue) {
        if preferences.object(forKey: key) == nil { preferences.set(value, forKey: key) }
      }
      let moduleKey = "hudModuleLayout.v1." + provider.rawValue
      if preferences.object(forKey: moduleKey) == nil, let layout = values["hudModuleLayout.v1"] {
        preferences.set(layout, forKey: moduleKey)
      }
      if let layout = values["hudModules"],
        preferences.object(forKey: "hudModules." + provider.rawValue) == nil
      {
        preferences.set(layout, forKey: "hudModules." + provider.rawValue)
      }
    }
    preferences.set(true, forKey: "unifiedMigration.v1")
  }
}
