import Foundation
@testable import StatsCore

enum AppUpdateModelsTests {
  static func main() throws {
    var checks = 0
    func check(_ value: Bool, _ message: String) {
      precondition(value, message)
      checks += 1
    }

    // SemanticVersion parsing and ordering
    let v100 = SemanticVersion("v1.0.0")!
    let v110 = SemanticVersion("1.1.0")!
    let v120 = SemanticVersion("1.2.0")!
    let v1100 = SemanticVersion("1.10.0")!
    let v11 = SemanticVersion("1.1")!
    let v110Beta = SemanticVersion("1.1.0-beta.1")!
    let v110Build = SemanticVersion("v1.1.0+2")!

    check(v110 > v100, "minor version bump orders higher")
    check(v1100 > v120, "numeric segment comparison beats lexicographic ordering")
    check(v11 == v110 && v110 == v110Build, "trailing zeros and build metadata compare equal")
    check(v110 > v110Beta, "stable release ranks above prerelease")
    check(SemanticVersion("") == nil && SemanticVersion("v-bad") == nil && SemanticVersion("1..0") == nil,
          "invalid version strings are rejected")

    // GitHub release JSON parsing
    let validJSON = try JSONSerialization.data(withJSONObject: [
      "tag_name": "v1.1.0",
      "name": "Agent Stats v1.1.0",
      "body": "## 更新内容\n- 检查更新与自动下载",
      "html_url": "https://github.com/moqiuren/agent-stats/releases/tag/v1.1.0",
      "published_at": "2026-11-22T10:00:00Z",
      "draft": false,
      "prerelease": false,
      "assets": [
        [
          "name": "Agent-Stats-1.1.0.dmg",
          "browser_download_url": "https://github.com/moqiuren/agent-stats/releases/download/v1.1.0/Agent-Stats-1.1.0.dmg",
          "size": 1300000,
          "digest": "sha256:" + String(repeating: "a", count: 64),
        ],
        [
          "name": "Agent-Stats-1.1.0-macos-arm64.zip",
          "browser_download_url": "https://github.com/moqiuren/agent-stats/releases/download/v1.1.0/Agent-Stats-1.1.0-macos-arm64.zip",
          "size": 900000,
          "digest": "sha256:" + String(repeating: "B", count: 64),
        ],
      ],
    ] as JSONObject)
    let release = try AppReleaseInfo.parseGitHubRelease(validJSON)
    check(release.version == "1.1.0" && release.tagName == "v1.1.0", "parses normalized release version")
    check(release.asset?.kind == .zip && release.asset?.name == "Agent-Stats-1.1.0-macos-arm64.zip",
          "prefers macOS arm64 zip archive over dmg for silent extraction")
    check(release.asset?.sha256 == String(repeating: "b", count: 64),
          "normalizes sha256 digest to lowercase hex")

    // Falls back to DMG if zip absent; ignores non-https assets
    let dmgOnlyJSON = try JSONSerialization.data(withJSONObject: [
      "tag_name": "v1.1.0",
      "html_url": "https://github.com/moqiuren/agent-stats/releases/tag/v1.1.0",
      "assets": [
        [
          "name": "Agent-Stats-1.1.0-macos-arm64.zip",
          "browser_download_url": "http://insecure.example/bad.zip",
        ],
        [
          "name": "Agent-Stats-1.1.0.dmg",
          "browser_download_url": "https://github.com/moqiuren/agent-stats/releases/download/v1.1.0/Agent-Stats-1.1.0.dmg",
        ],
      ],
    ] as JSONObject)
    let dmgRelease = try AppReleaseInfo.parseGitHubRelease(dmgOnlyJSON)
    check(dmgRelease.asset?.kind == .dmg && dmgRelease.asset?.sha256 == nil,
          "rejects http asset URL and falls back to valid https DMG asset")

    // Rejects prereleases and drafts
    let prereleaseJSON = try JSONSerialization.data(withJSONObject: [
      "tag_name": "v1.2.0-beta.1",
      "html_url": "https://github.com/moqiuren/agent-stats/releases/tag/v1.2.0-beta.1",
      "prerelease": true,
    ] as JSONObject)
    var rejectedPrerelease = false
    do { _ = try AppReleaseInfo.parseGitHubRelease(prereleaseJSON) } catch { rejectedPrerelease = true }
    check(rejectedPrerelease, "prereleases are excluded")

    // Schedule policy
    check(AppUpdateSchedulePolicy.isCheckDue(autoCheck: true, lastCheckedAtMs: nil, nowMs: 1000),
          "nil last check timestamp is due when autoCheck enabled")
    check(!AppUpdateSchedulePolicy.isCheckDue(autoCheck: false, lastCheckedAtMs: nil, nowMs: 1000),
          "disabled autoCheck is never due")
    check(!AppUpdateSchedulePolicy.isCheckDue(autoCheck: true, lastCheckedAtMs: 10_000, nowMs: 10_000 + 3600 * 1000),
          "within 12h interval is not due")
    check(AppUpdateSchedulePolicy.isCheckDue(autoCheck: true, lastCheckedAtMs: 10_000, nowMs: 10_000 + 12 * 3600 * 1000),
          "at 12h interval boundary check becomes due")

    print("\(checks) app update model checks passed")
  }
}
