import CryptoKit
import Foundation
@testable import StatsAdapters
@testable import StatsCore

private final class UpdaterTestClock: StatsClock {
  var now = Date(timeIntervalSince1970: 1_795_320_000)
  var uptime: TimeInterval = 100
}

private final class ImmediateScheduler: StatsScheduling {
  final class Task: StatsCancellation {
    var cancelled = false
    func cancel() { cancelled = true }
  }
  var isIsolated: Bool { true }
  var scheduledTasks = [(delay: TimeInterval, repeating: TimeInterval?, task: Task, action: () -> Void)]()
  func execute(_ action: @escaping () -> Void) { action() }
  func schedule(
    after delay: TimeInterval, repeating interval: TimeInterval?, tolerance: TimeInterval,
    _ action: @escaping () -> Void
  ) -> StatsCancellation {
    let task = Task()
    scheduledTasks.append((delay, interval, task, action))
    return task
  }
}

private final class StubTransport: AppUpdateTransport {
  var releaseResult: Result<Data, Error> = .failure(Lifecycle.error("offline"))
  var archiveData = Data()
  var downloadResult: Result<Void, Error>?
  var fetchCalls = 0
  var downloadCalls = 0

  func fetchLatestRelease(
    repository: String, completion: @escaping (Result<Data, Error>) -> Void
  ) {
    fetchCalls += 1
    completion(releaseResult)
  }

  func downloadAsset(
    from url: URL, to destination: URL, completion: @escaping (Result<Void, Error>) -> Void
  ) {
    downloadCalls += 1
    if let downloadResult {
      completion(downloadResult)
      return
    }
    do {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try archiveData.write(to: destination)
      completion(.success(()))
    } catch {
      completion(.failure(error))
    }
  }
}

enum AppUpdaterTests {
  static func main() throws {
    var checks = 0
    func check(_ value: Bool, _ message: String) {
      precondition(value, message)
      checks += 1
    }

    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("app-updater-tests-\(UUID().uuidString)")
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    func makeFakeBundle(at bundleURL: URL, version: String) throws {
      let mac = bundleURL.appendingPathComponent("Contents/MacOS")
      try fm.createDirectory(at: mac, withIntermediateDirectories: true)
      try Data("#!/bin/sh\nexit 0\n".utf8).write(to: mac.appendingPathComponent(Product.executable))
      try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mac.appendingPathComponent(Product.executable).path)
      let plist: [String: Any] = [
        "CFBundleIdentifier": Product.bundleID,
        "CFBundleName": Product.name,
        "CFBundleExecutable": Product.executable,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": "2",
      ]
      let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      try plistData.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
    }

    func makeZipArchive(version: String) throws -> (zipData: Data, sha256: String) {
      let stage = base.appendingPathComponent("zip-stage-\(UUID().uuidString)")
      let app = stage.appendingPathComponent(Product.name + ".app")
      try makeFakeBundle(at: app, version: version)
      let zipURL = stage.appendingPathComponent("Agent-Stats-\(version)-macos-arm64.zip")
      let status = try Lifecycle.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zipURL.path])
      precondition(status == 0, "ditto creates synthetic zip")
      let data = try Data(contentsOf: zipURL)
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      return (data, digest)
    }

    func releasePayload(version: String, sha256: String) throws -> Data {
      try JSONSerialization.data(withJSONObject: [
        "tag_name": "v\(version)",
        "name": "Agent Stats v\(version)",
        "body": "Release \(version)",
        "html_url": "https://github.com/moqiuren/agent-stats/releases/tag/v\(version)",
        "draft": false,
        "prerelease": false,
        "assets": [
          [
            "name": "Agent-Stats-\(version)-macos-arm64.zip",
            "browser_download_url": "https://github.com/moqiuren/agent-stats/releases/download/v\(version)/Agent-Stats-\(version)-macos-arm64.zip",
            "size": 1024,
            "digest": "sha256:\(sha256)",
          ]
        ],
      ] as JSONObject)
    }

    // 1. Up-to-date & silent error resilience + obsolete staged folder pruning
    do {
      let support = base.appendingPathComponent("support-1")
      let obsoleteDir = support.appendingPathComponent("updates/1.0.0")
      let newerDir = support.appendingPathComponent("updates/2.0.0")
      try fm.createDirectory(at: obsoleteDir, withIntermediateDirectories: true)
      try fm.createDirectory(at: newerDir, withIntermediateDirectories: true)

      let clock = UpdaterTestClock()
      let work = ImmediateScheduler()
      let ui = ImmediateScheduler()
      let transport = StubTransport()
      var recordedChecks = [Double]()

      let manager = LiveAppUpdateManager(
        currentVersion: "1.1.0", support: support, clock: clock,
        workScheduler: work, uiScheduler: ui, transport: transport,
        runCommand: { path, args in
          if path == "/usr/bin/codesign" { return 0 }
          return try Lifecycle.run(path, args)
        })
      manager.onCheckRecorded = { recordedChecks.append($0) }
      manager.start(autoCheck: true, autoDownload: false, lastCheckedAtMs: nil)
      check(!fm.fileExists(atPath: obsoleteDir.path) && fm.fileExists(atPath: newerDir.path),
            "prunes staged folders <= current version while keeping newer ones")
      check(work.scheduledTasks.count == 2 && work.scheduledTasks[0].delay == AppUpdateSchedulePolicy.startupDelay,
            "schedules startup check and repeating check when due")

      // Silent check failure reverts to idle without showing error
      work.scheduledTasks[0].action()
      if case .idle = manager.state {} else { preconditionFailure("silent check failure should remain idle") }
      check(recordedChecks.isEmpty, "failed check does not record check timestamp")

      // Manual check failure reports .failed
      manager.checkForUpdates(userInitiated: true)
      if case .failed = manager.state {} else { preconditionFailure("user-initiated failure reports failed state") }

      // Up-to-date check
      let (_, emptySha) = try makeZipArchive(version: "1.1.0")
      transport.releaseResult = .success(try releasePayload(version: "1.1.0", sha256: emptySha))
      manager.checkForUpdates(userInitiated: true)
      if case .upToDate(let v, _) = manager.state {
        check(v == "1.1.0", "up-to-date records current version")
      } else {
        preconditionFailure("expected upToDate state")
      }
      check(recordedChecks.count == 1, "successful check records timestamp")
      manager.stop()
      check(work.scheduledTasks.allSatisfy(\.task.cancelled), "stop cancels all scheduled updater timers")
    }

    // 2. Manual download vs Auto-download, SHA-256 mismatch rejection, and untrusted signature fallback
    do {
      let (zipData, sha) = try makeZipArchive(version: "1.2.0")
      let support = base.appendingPathComponent("support-2")
      let transport = StubTransport()
      transport.releaseResult = .success(try releasePayload(version: "1.2.0", sha256: sha))
      transport.archiveData = zipData
      var revealed = [URL]()

      let manager = LiveAppUpdateManager(
        currentVersion: "1.1.0", support: support,
        workScheduler: ImmediateScheduler(), uiScheduler: ImmediateScheduler(),
        transport: transport,
        runCommand: { path, args in
          if path == "/usr/bin/codesign" { return 0 }
          return try Lifecycle.run(path, args)
        },
        revealURL: { revealed.append($0) })
      manager.start(autoCheck: false, autoDownload: false, lastCheckedAtMs: nil)
      manager.checkForUpdates(userInitiated: true)
      if case .available(let rel, _) = manager.state {
        check(rel.version == "1.2.0" && transport.downloadCalls == 0,
              "autoDownload == false stops at .available without downloading")
      } else {
        preconditionFailure("expected .available state")
      }

      // Turning on autoDownload while in .available immediately downloads and stages
      manager.setPreferences(autoCheck: false, autoDownload: true)
      if case .downloaded(let rel, let artifact) = manager.state {
        check(rel.version == "1.2.0" && artifact.canInstallInPlace && transport.downloadCalls == 1,
              "enabling autoDownload triggers download, zip extraction and staging")
        let staged = try manager.stagedBundleForInstall()
        check(fm.fileExists(atPath: staged.stagedApp.path), "staged .app exists and passes verification")
      } else {
        preconditionFailure("expected .downloaded state after enabling autoDownload")
      }
      manager.revealDownloadedUpdate()
      check(revealed.count == 1, "revealDownloadedUpdate opens archive location")

      // SHA-256 mismatch discards bad file and enters .failed
      let badSupport = base.appendingPathComponent("support-bad-sha")
      transport.releaseResult = .success(try releasePayload(version: "1.2.0", sha256: String(repeating: "0", count: 64)))
      let badManager = LiveAppUpdateManager(
        currentVersion: "1.1.0", support: badSupport,
        workScheduler: ImmediateScheduler(), uiScheduler: ImmediateScheduler(),
        transport: transport,
        runCommand: { path, args in
          if path == "/usr/bin/codesign" { return 0 }
          return try Lifecycle.run(path, args)
        })
      badManager.start(autoCheck: false, autoDownload: true, lastCheckedAtMs: nil)
      badManager.checkForUpdates(userInitiated: true)
      if case .failed(let msg, let rel) = badManager.state {
        check(msg.contains("SHA-256") && rel?.version == "1.2.0", "SHA-256 mismatch rejects archive cleanly")
      } else {
        preconditionFailure("expected SHA-256 mismatch failure")
      }

      // Untrusted codesign keeps archive for manual reveal instead of allowing in-place replace
      let untrustedSupport = base.appendingPathComponent("support-untrusted")
      transport.releaseResult = .success(try releasePayload(version: "1.2.0", sha256: sha))
      let untrustedManager = LiveAppUpdateManager(
        currentVersion: "1.1.0", support: untrustedSupport,
        workScheduler: ImmediateScheduler(), uiScheduler: ImmediateScheduler(),
        transport: transport,
        runCommand: { path, args in
          if path == "/usr/bin/codesign" { return 1 }
          return try Lifecycle.run(path, args)
        })
      untrustedManager.start(autoCheck: false, autoDownload: true, lastCheckedAtMs: nil)
      untrustedManager.checkForUpdates(userInitiated: true)
      if case .downloaded(_, let artifact) = untrustedManager.state {
        check(!artifact.canInstallInPlace && fm.fileExists(atPath: artifact.archiveURL.path),
              "untrusted codesign preserves archive while disabling in-place install")
      } else {
        preconditionFailure("expected downloaded state with nil stagedAppURL")
      }
    }

    // 3. In-place bundle replacement preserves isLaunchAtLoginEnabled (both OFF and ON) without bootout
    for launchWasEnabled in [false, true] {
      let home = base.appendingPathComponent("install-home-\(launchWasEnabled)")
      let apps = home.appendingPathComponent("Applications")
      let support = home.appendingPathComponent("Library/Application Support/\(Product.name)")
      try fm.createDirectory(at: apps, withIntermediateDirectories: true)
      try fm.createDirectory(at: support, withIntermediateDirectories: true)
      try fm.createDirectory(at: home.appendingPathComponent(".Trash"), withIntermediateDirectories: true)

      let existingApp = apps.appendingPathComponent("\(Product.name).app")
      try makeFakeBundle(at: existingApp, version: "1.1.0")
      if launchWasEnabled {
        try AppInstallation.setLaunchAtLogin(true, bundleURL: existingApp, home: home, support: support, environment: [:])
      }

      let stagedApp = support.appendingPathComponent("updates/1.2.0/\(Product.name).app")
      try makeFakeBundle(at: stagedApp, version: "1.2.0")

      var invokedTools = [String]()
      let installed = try AppInstallation.applyStagedUpdateAndRelaunch(
        from: stagedApp,
        currentBundleURL: existingApp,
        home: home,
        support: support,
        environment: ["CODEX_HOME": "/custom/codex"],
        runCommand: { path, args in
          invokedTools.append(([path] + args).joined(separator: " "))
          if path == "/usr/bin/codesign" { return 0 }
          return 0
        },
        scheduleRelaunch: false)

      check(installed == existingApp.standardizedFileURL, "replaces existing standard bundle in place")
      let plistData = try Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
      let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? JSONObject
      check(plist?["CFBundleShortVersionString"] as? String == "1.2.0", "new bundle version is active after update")
      check(AppInstallation.isLaunchAtLoginEnabled(home: home) == launchWasEnabled,
            "in-place update preserves launch-at-login preference (\(launchWasEnabled))")
      check(!invokedTools.contains(where: { $0.contains("launchctl bootout") }),
            "in-place GUI update never calls launchctl bootout on self")
      check(!fm.fileExists(atPath: support.appendingPathComponent("updates").path),
            "staged updates directory moves safely to Trash after installation")
    }

    print("\(checks) app updater checks passed")
  }
}
