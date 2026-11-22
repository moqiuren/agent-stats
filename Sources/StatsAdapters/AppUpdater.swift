import CryptoKit
import Foundation
import StatsCore

package protocol AppUpdateTransport: AnyObject {
  func fetchLatestRelease(repository: String, completion: @escaping (Result<Data, Error>) -> Void)
  func downloadAsset(
    from url: URL, to destination: URL, completion: @escaping (Result<Void, Error>) -> Void)
}

package final class URLSessionUpdateTransport: AppUpdateTransport {
  private let session: URLSession
  private let userAgent: String

  package init(userAgent: String = "\(Product.executable)/\(Product.version)") {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 15
    config.timeoutIntervalForResource = 120
    self.session = URLSession(configuration: config)
    self.userAgent = userAgent
  }

  deinit {
    session.invalidateAndCancel()
  }

  package func fetchLatestRelease(
    repository: String, completion: @escaping (Result<Data, Error>) -> Void
  ) {
    guard let encodedRepo = repository.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      let url = URL(string: "https://api.github.com/repos/\(encodedRepo)/releases/latest")
    else {
      completion(.failure(Lifecycle.error("无效的 GitHub 仓库标识。")))
      return
    }
    var request = URLRequest(url: url)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

    session.dataTask(with: request) { data, response, error in
      if let error {
        completion(.failure(error))
        return
      }
      guard let http = response as? HTTPURLResponse else {
        completion(.failure(Lifecycle.error("网络响应无效。")))
        return
      }
      switch http.statusCode {
      case 200:
        completion(.success(data ?? Data()))
      case 404:
        completion(.failure(Lifecycle.error("暂无已发布的 Release 版本。")))
      case 403, 429:
        completion(.failure(Lifecycle.error("GitHub API 请求受限，请稍后再试。")))
      default:
        completion(.failure(Lifecycle.error("服务器返回状态码 \(http.statusCode)。")))
      }
    }.resume()
  }

  package func downloadAsset(
    from url: URL, to destination: URL, completion: @escaping (Result<Void, Error>) -> Void
  ) {
    var request = URLRequest(url: url)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    session.downloadTask(with: request) { tempURL, response, error in
      if let error {
        completion(.failure(error))
        return
      }
      guard let http = response as? HTTPURLResponse else {
        completion(.failure(Lifecycle.error("下载响应无效。")))
        return
      }
      guard (200...299).contains(http.statusCode), let tempURL else {
        completion(.failure(Lifecycle.error("下载失败（状态码 \(http.statusCode)）。")))
        return
      }
      do {
        let fm = FileManager.default
        try fm.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
          try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempURL, to: destination)
        completion(.success(()))
      } catch {
        completion(.failure(error))
      }
    }.resume()
  }
}

package protocol AppUpdateManaging: AnyObject {
  var state: AppUpdateState { get }
  var onStateChange: ((AppUpdateState) -> Void)? { get set }
  var onCheckRecorded: ((Double) -> Void)? { get set }
  func start(autoCheck: Bool, autoDownload: Bool, lastCheckedAtMs: Double?)
  func setPreferences(autoCheck: Bool, autoDownload: Bool)
  func checkForUpdates(userInitiated: Bool)
  func downloadUpdate()
  func stagedBundleForInstall() throws -> (release: AppReleaseInfo, stagedApp: URL)
  func revealDownloadedUpdate()
  func stop()
}

package final class LiveAppUpdateManager: AppUpdateManaging {
  private let currentVersion: String
  private let repository: String
  private let support: URL
  private let clock: StatsClock
  private let workScheduler: StatsScheduling
  private let uiScheduler: StatsScheduling
  private let transport: AppUpdateTransport
  private let runCommand: (String, [String]) throws -> Int32
  private let revealURL: (URL) -> Void

  package private(set) var state: AppUpdateState = .idle(lastCheckedAt: nil)
  package var onStateChange: ((AppUpdateState) -> Void)?
  package var onCheckRecorded: ((Double) -> Void)?

  private var autoCheck = true
  private var autoDownload = true
  private var lastCheckedAtMs: Double?
  private var started = false
  private var stopped = false
  private var startupTimer: StatsCancellation?
  private var periodicTimer: StatsCancellation?
  private var operationID = UUID()

  package init(
    currentVersion: String = Product.version,
    repository: String = Product.githubRepository,
    support: URL = Product.support,
    clock: StatsClock = SystemStatsClock(),
    workScheduler: StatsScheduling? = nil,
    uiScheduler: StatsScheduling = DispatchStatsScheduler(queue: .main),
    transport: AppUpdateTransport = URLSessionUpdateTransport(),
    runCommand: ((String, [String]) throws -> Int32)? = nil,
    revealURL: ((URL) -> Void)? = nil
  ) {
    self.currentVersion = currentVersion
    self.repository = repository
    self.support = support
    self.clock = clock
    let queue = DispatchQueue(label: "\(Product.bundleID).updater", qos: .utility)
    self.workScheduler = workScheduler ?? DispatchStatsScheduler(queue: queue)
    self.uiScheduler = uiScheduler
    self.transport = transport
    self.runCommand = runCommand ?? { path, args in try Lifecycle.run(path, args) }
    self.revealURL =
      revealURL ?? { url in
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-R", url.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
      }
  }

  private func publish(_ next: AppUpdateState) {
    uiScheduler.execute { [weak self] in
      guard let self, !self.stopped else { return }
      self.state = next
      self.onStateChange?(next)
    }
  }

  private func recordCheck(_ timestampMs: Double) {
    lastCheckedAtMs = timestampMs
    uiScheduler.execute { [weak self] in
      guard let self, !self.stopped else { return }
      self.onCheckRecorded?(timestampMs)
    }
  }

  package func start(autoCheck: Bool, autoDownload: Bool, lastCheckedAtMs: Double?) {
    workScheduler.execute { [weak self] in
      guard let self, !self.stopped, !self.started else { return }
      self.started = true
      self.autoCheck = autoCheck
      self.autoDownload = autoDownload
      self.lastCheckedAtMs = lastCheckedAtMs
      if case .idle = self.state {
        self.publish(.idle(lastCheckedAt: lastCheckedAtMs))
      }
      self.pruneObsoleteStagedUpdates()
      self.rescheduleTimersLocked()
    }
  }

  package func setPreferences(autoCheck: Bool, autoDownload: Bool) {
    workScheduler.execute { [weak self] in
      guard let self, !self.stopped else { return }
      let checkTurnedOn = !self.autoCheck && autoCheck
      let downloadTurnedOn = !self.autoDownload && autoDownload
      self.autoCheck = autoCheck
      self.autoDownload = autoDownload
      if self.started {
        self.rescheduleTimersLocked()
      }
      let nowMs = self.clock.milliseconds
      if checkTurnedOn,
        AppUpdateSchedulePolicy.isCheckDue(
          autoCheck: autoCheck, lastCheckedAtMs: self.lastCheckedAtMs, nowMs: nowMs),
        case .idle = self.state
      {
        self.performCheckLocked(userInitiated: false)
      } else if downloadTurnedOn,
        case .available(let release, _) = self.state,
        release.asset != nil
      {
        self.performDownloadLocked(release)
      }
    }
  }

  package func checkForUpdates(userInitiated: Bool) {
    workScheduler.execute { [weak self] in
      guard let self, !self.stopped else { return }
      self.performCheckLocked(userInitiated: userInitiated)
    }
  }

  package func downloadUpdate() {
    workScheduler.execute { [weak self] in
      guard let self, !self.stopped else { return }
      guard let release = self.state.availableRelease, release.asset != nil else { return }
      switch self.state {
      case .downloading, .installing:
        return
      default:
        self.performDownloadLocked(release)
      }
    }
  }

  package func stagedBundleForInstall() throws -> (release: AppReleaseInfo, stagedApp: URL) {
    guard case .downloaded(let release, let artifact) = state,
      let stagedApp = artifact.stagedAppURL,
      validateStagedBundle(at: stagedApp, expectedVersion: release.semanticVersion)
    else {
      throw Lifecycle.error("未找到已验证的可安装更新包。")
    }
    return (release, stagedApp)
  }

  package func revealDownloadedUpdate() {
    guard case .downloaded(_, let artifact) = state else { return }
    let fm = FileManager.default
    let target = fm.fileExists(atPath: artifact.archiveURL.path)
      ? artifact.archiveURL
      : (artifact.stagedAppURL ?? artifact.archiveURL)
    revealURL(target)
  }

  package func stop() {
    startupTimer?.cancel()
    startupTimer = nil
    periodicTimer?.cancel()
    periodicTimer = nil
    workScheduler.execute { [weak self] in
      guard let self else { return }
      self.stopped = true
      self.operationID = UUID()
      self.startupTimer?.cancel()
      self.startupTimer = nil
      self.periodicTimer?.cancel()
      self.periodicTimer = nil
    }
    uiScheduler.execute { [weak self] in
      self?.onStateChange = nil
      self?.onCheckRecorded = nil
    }
  }

  private func rescheduleTimersLocked() {
    startupTimer?.cancel()
    startupTimer = nil
    periodicTimer?.cancel()
    periodicTimer = nil
    guard started, !stopped, autoCheck else { return }

    let nowMs = clock.milliseconds
    if AppUpdateSchedulePolicy.isCheckDue(
      autoCheck: autoCheck, lastCheckedAtMs: lastCheckedAtMs, nowMs: nowMs)
    {
      startupTimer = workScheduler.schedule(
        after: AppUpdateSchedulePolicy.startupDelay, repeating: nil, tolerance: 1
      ) { [weak self] in
        guard let self, !self.stopped, self.autoCheck else { return }
        self.performCheckLocked(userInitiated: false)
      }
    }
    periodicTimer = workScheduler.schedule(
      after: AppUpdateSchedulePolicy.checkInterval,
      repeating: AppUpdateSchedulePolicy.checkInterval,
      tolerance: 300
    ) { [weak self] in
      guard let self, !self.stopped, self.autoCheck else { return }
      if AppUpdateSchedulePolicy.isCheckDue(
        autoCheck: self.autoCheck, lastCheckedAtMs: self.lastCheckedAtMs,
        nowMs: self.clock.milliseconds)
      {
        self.performCheckLocked(userInitiated: false)
      }
    }
  }

  private func performCheckLocked(userInitiated: Bool) {
    switch state {
    case .checking, .downloading, .installing:
      return
    default:
      break
    }
    let priorState = state
    if userInitiated || priorState.availableRelease == nil {
      publish(.checking)
    }
    let currentOp = UUID()
    operationID = currentOp

    transport.fetchLatestRelease(repository: repository) { [weak self] result in
      guard let self else { return }
      self.workScheduler.execute { [weak self] in
        guard let self, !self.stopped, self.operationID == currentOp else { return }
        switch result {
        case .failure(let error):
          if userInitiated {
            self.publish(.failed(message: error.localizedDescription, release: nil))
          } else {
            let restored: AppUpdateState =
              priorState.availableRelease != nil ? priorState : .idle(lastCheckedAt: self.lastCheckedAtMs)
            self.publish(restored)
          }
        case .success(let data):
          do {
            let release = try AppReleaseInfo.parseGitHubRelease(data)
            let checkedAt = self.clock.milliseconds
            self.recordCheck(checkedAt)

            guard let currentSemVer = SemanticVersion(self.currentVersion) else {
              self.publish(.upToDate(version: self.currentVersion, checkedAt: checkedAt))
              return
            }
            if release.semanticVersion > currentSemVer {
              if let staged = self.existingStagedArtifact(for: release) {
                self.publish(.downloaded(release, staged))
              } else if self.autoDownload, release.asset != nil {
                self.performDownloadLocked(release)
              } else {
                self.publish(.available(release, checkedAt: checkedAt))
              }
            } else {
              self.publish(.upToDate(version: self.currentVersion, checkedAt: checkedAt))
            }
          } catch {
            if userInitiated {
              self.publish(.failed(message: error.localizedDescription, release: nil))
            } else {
              let restored: AppUpdateState =
                priorState.availableRelease != nil
                ? priorState : .idle(lastCheckedAt: self.lastCheckedAtMs)
              self.publish(restored)
            }
          }
        }
      }
    }
  }

  private func performDownloadLocked(_ release: AppReleaseInfo) {
    guard let asset = release.asset else {
      publish(.available(release, checkedAt: clock.milliseconds))
      return
    }
    if let staged = existingStagedArtifact(for: release) {
      publish(.downloaded(release, staged))
      return
    }

    let currentOp = UUID()
    operationID = currentOp
    publish(.downloading(release))

    let versionDir = support.appendingPathComponent("updates/\(release.version)")
    let partFile = versionDir.appendingPathComponent(asset.name + ".part")
    let archiveURL = versionDir.appendingPathComponent(asset.name)

    transport.downloadAsset(from: asset.downloadURL, to: partFile) { [weak self] result in
      guard let self else { return }
      self.workScheduler.execute { [weak self] in
        guard let self, !self.stopped, self.operationID == currentOp else { return }
        let fm = FileManager.default
        switch result {
        case .failure(let error):
          try? fm.removeItem(at: partFile)
          self.publish(
            .failed(
              message: "下载更新失败：\(error.localizedDescription)", release: release))
        case .success:
          do {
            if let expectedDigest = asset.sha256 {
              let actualDigest = try Self.sha256Hex(of: partFile)
              guard actualDigest == expectedDigest else {
                try? fm.removeItem(at: partFile)
                self.publish(
                  .failed(
                    message: "更新包 SHA-256 校验失败，已丢弃文件。", release: release))
                return
              }
            }
            if fm.fileExists(atPath: archiveURL.path) {
              try fm.removeItem(at: archiveURL)
            }
            try fm.moveItem(at: partFile, to: archiveURL)

            let artifact = try self.stageArchive(archiveURL, asset: asset, release: release, in: versionDir)
            self.publish(.downloaded(release, artifact))
          } catch {
            try? fm.removeItem(at: partFile)
            self.publish(
              .failed(
                message: "处理更新包失败：\(error.localizedDescription)", release: release))
          }
        }
      }
    }
  }

  private func stageArchive(
    _ archiveURL: URL,
    asset: AppReleaseAsset,
    release: AppReleaseInfo,
    in versionDir: URL
  ) throws -> StagedUpdateArtifact {
    let fm = FileManager.default
    let extractDir = versionDir.appendingPathComponent(".extract-\(UUID().uuidString)")
    try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: extractDir) }

    switch asset.kind {
    case .zip:
      let status = try runCommand("/usr/bin/ditto", ["-x", "-k", archiveURL.path, extractDir.path])
      guard status == 0 else {
        throw Lifecycle.error("解压更新压缩包失败。")
      }
    case .dmg:
      let mountDir = extractDir.appendingPathComponent(".mount")
      try fm.createDirectory(at: mountDir, withIntermediateDirectories: true)
      let attachStatus = try runCommand(
        "/usr/bin/hdiutil",
        ["attach", "-nobrowse", "-readonly", "-mountpoint", mountDir.path, archiveURL.path])
      guard attachStatus == 0 else {
        throw Lifecycle.error("挂载更新镜像失败。")
      }
      defer {
        _ = try? runCommand("/usr/bin/hdiutil", ["detach", mountDir.path, "-quiet"])
      }
      guard let mountedApp = findAppBundle(in: mountDir) else {
        throw Lifecycle.error("更新镜像中未找到 \(Product.name).app。")
      }
      let copied = extractDir.appendingPathComponent(Product.name + ".app")
      let dittoStatus = try runCommand("/usr/bin/ditto", [mountedApp.path, copied.path])
      guard dittoStatus == 0 else {
        throw Lifecycle.error("复制更新镜像内容失败。")
      }
    }

    guard let extractedApp = findAppBundle(in: extractDir) else {
      throw Lifecycle.error("更新包中未找到 \(Product.name).app。")
    }

    for attr in ["com.apple.quarantine", "com.apple.FinderInfo", "com.apple.ResourceFork"] {
      _ = try? runCommand("/usr/bin/xattr", ["-dr", attr, extractedApp.path])
    }

    guard validateBundleIdentity(at: extractedApp, expectedVersion: nil) else {
      throw Lifecycle.error("更新包应用标识不匹配。")
    }

    let verifyStatus = try runCommand(
      "/usr/bin/codesign", ["--verify", "--deep", "--strict", extractedApp.path])
    guard verifyStatus == 0 else {
      return StagedUpdateArtifact(
        version: release.version,
        archiveURL: archiveURL,
        stagedAppURL: nil,
        statusDetail: "已下载安装包，但本机尚未信任该签名证书；请在访达中查看并手动替换。")
    }

    let stagedAppURL = versionDir.appendingPathComponent(Product.name + ".app")
    if fm.fileExists(atPath: stagedAppURL.path) {
      try fm.removeItem(at: stagedAppURL)
    }
    try fm.moveItem(at: extractedApp, to: stagedAppURL)
    return StagedUpdateArtifact(
      version: release.version,
      archiveURL: archiveURL,
      stagedAppURL: stagedAppURL,
      statusDetail: nil)
  }

  private func existingStagedArtifact(for release: AppReleaseInfo) -> StagedUpdateArtifact? {
    let fm = FileManager.default
    let versionDir = support.appendingPathComponent("updates/\(release.version)")
    let stagedAppURL = versionDir.appendingPathComponent(Product.name + ".app")
    guard fm.fileExists(atPath: stagedAppURL.path),
      validateStagedBundle(at: stagedAppURL, expectedVersion: release.semanticVersion)
    else { return nil }

    let candidateArchive = release.asset.map { versionDir.appendingPathComponent($0.name) }
    let archiveURL =
      (candidateArchive.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }) ?? stagedAppURL
    return StagedUpdateArtifact(
      version: release.version,
      archiveURL: archiveURL,
      stagedAppURL: stagedAppURL,
      statusDetail: nil)
  }

  private func validateBundleIdentity(at bundleURL: URL, expectedVersion: SemanticVersion?) -> Bool {
    let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: plistURL),
      let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? JSONObject,
      info["CFBundleIdentifier"] as? String == Product.bundleID
    else { return false }
    if let expectedVersion,
      let rawVer = info["CFBundleShortVersionString"] as? String,
      let parsed = SemanticVersion(rawVer)
    {
      return parsed == expectedVersion
    }
    return true
  }

  private func validateStagedBundle(at bundleURL: URL, expectedVersion: SemanticVersion?) -> Bool {
    guard validateBundleIdentity(at: bundleURL, expectedVersion: expectedVersion) else {
      return false
    }
    let verifyStatus = (try? runCommand("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundleURL.path])) ?? -1
    return verifyStatus == 0
  }

  private func findAppBundle(in root: URL) -> URL? {
    let fm = FileManager.default
    let direct = root.appendingPathComponent(Product.name + ".app")
    if fm.fileExists(atPath: direct.path) { return direct }
    guard let entries = try? fm.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    else { return nil }
    for entry in entries {
      if entry.lastPathComponent == Product.name + ".app" { return entry }
      let nested = entry.appendingPathComponent(Product.name + ".app")
      if fm.fileExists(atPath: nested.path) { return nested }
    }
    return nil
  }

  private func pruneObsoleteStagedUpdates() {
    guard let currentSemVer = SemanticVersion(currentVersion) else { return }
    let fm = FileManager.default
    let updatesRoot = support.appendingPathComponent("updates")
    guard let items = try? fm.contentsOfDirectory(
      at: updatesRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    else { return }
    for item in items {
      guard let ver = SemanticVersion(item.lastPathComponent), ver <= currentSemVer else {
        continue
      }
      try? fm.removeItem(at: item)
    }
  }

  private static func sha256Hex(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let chunk = try handle.read(upToCount: 262_144) ?? Data()
      if chunk.isEmpty { break }
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
