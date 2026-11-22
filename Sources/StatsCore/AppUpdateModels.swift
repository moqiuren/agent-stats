import Foundation

package struct SemanticVersion: Comparable, Equatable {
  package let raw: String
  package let components: [Int]
  package let prerelease: String?

  package init?(_ string: String) {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let strippedV =
      (trimmed.hasPrefix("v") || trimmed.hasPrefix("V"))
      ? String(trimmed.dropFirst())
      : trimmed
    let noBuild = strippedV.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first
      .map(String.init) ?? strippedV
    let dashSplit = noBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    let coreText = String(dashSplit[0])
    let preText = dashSplit.count > 1 ? String(dashSplit[1]) : nil
    if let preText, preText.isEmpty { return nil }

    let parts = coreText.split(separator: ".", omittingEmptySubsequences: false)
    guard !parts.isEmpty else { return nil }
    var parsed = [Int]()
    for part in parts {
      guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
        let num = Int(part), num >= 0
      else { return nil }
      parsed.append(num)
    }

    self.raw = string
    self.components = parsed
    self.prerelease = preText
  }

  package var normalized: String {
    let core = components.map(String.init).joined(separator: ".")
    if let prerelease { return core + "-" + prerelease }
    return core
  }

  package static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    let count = max(lhs.components.count, rhs.components.count)
    for i in 0..<count {
      let l = i < lhs.components.count ? lhs.components[i] : 0
      let r = i < rhs.components.count ? rhs.components[i] : 0
      if l != r { return false }
    }
    return lhs.prerelease == rhs.prerelease
  }

  package static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    let count = max(lhs.components.count, rhs.components.count)
    for i in 0..<count {
      let l = i < lhs.components.count ? lhs.components[i] : 0
      let r = i < rhs.components.count ? rhs.components[i] : 0
      if l != r { return l < r }
    }
    switch (lhs.prerelease, rhs.prerelease) {
    case (nil, nil): return false
    case (nil, .some): return false
    case (.some, nil): return true
    case (.some(let a), .some(let b)): return a < b
    }
  }
}

package struct AppReleaseAsset: Equatable {
  package enum Kind: String, Equatable {
    case zip, dmg
  }

  package let name: String
  package let downloadURL: URL
  package let size: Int64?
  package let sha256: String?
  package let kind: Kind

  package init(name: String, downloadURL: URL, size: Int64?, sha256: String?, kind: Kind) {
    self.name = name
    self.downloadURL = downloadURL
    self.size = size
    self.sha256 = sha256
    self.kind = kind
  }
}

package struct AppReleaseInfo: Equatable {
  package enum ParseError: LocalizedError, Equatable {
    case invalidPayload
    case excludedRelease
    case invalidVersion
    case invalidReleaseURL

    package var errorDescription: String? {
      switch self {
      case .invalidPayload: return "发布信息格式无效。"
      case .excludedRelease: return "暂无可用的正式发布版本。"
      case .invalidVersion: return "发布版本号格式无效。"
      case .invalidReleaseURL: return "发布页面地址无效。"
      }
    }
  }

  package let version: String
  package let semanticVersion: SemanticVersion
  package let tagName: String
  package let title: String
  package let notes: String
  package let htmlURL: URL
  package let publishedAt: String?
  package let asset: AppReleaseAsset?

  package init(
    version: String, semanticVersion: SemanticVersion, tagName: String,
    title: String, notes: String, htmlURL: URL, publishedAt: String?, asset: AppReleaseAsset?
  ) {
    self.version = version
    self.semanticVersion = semanticVersion
    self.tagName = tagName
    self.title = title
    self.notes = notes
    self.htmlURL = htmlURL
    self.publishedAt = publishedAt
    self.asset = asset
  }

  package static func parseGitHubRelease(_ data: Data) throws -> AppReleaseInfo {
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else {
      throw ParseError.invalidPayload
    }
    if json["draft"] as? Bool == true || json["prerelease"] as? Bool == true {
      throw ParseError.excludedRelease
    }
    guard let tagName = json["tag_name"] as? String, !tagName.isEmpty,
      let semVer = SemanticVersion(tagName)
    else {
      throw ParseError.invalidVersion
    }
    guard let htmlStr = json["html_url"] as? String,
      let htmlURL = URL(string: htmlStr),
      htmlURL.scheme?.lowercased() == "https"
    else {
      throw ParseError.invalidReleaseURL
    }

    let rawTitle = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = (rawTitle?.isEmpty == false) ? rawTitle! : tagName
    let notes = (json["body"] as? String) ?? ""
    let publishedAt = json["published_at"] as? String
    let assets = json["assets"] as? [JSONObject] ?? []

    var matchedAsset: AppReleaseAsset?
    let patterns: [(pattern: String, kind: AppReleaseAsset.Kind)] = [
      ("^Agent-Stats-.*-macos-arm64\\.zip$", .zip),
      ("^Agent-Stats-.*\\.dmg$", .dmg),
    ]
    outer: for (pattern, kind) in patterns {
      for rawAsset in assets {
        guard let name = rawAsset["name"] as? String,
          name.range(of: pattern, options: .regularExpression) != nil,
          let urlStr = rawAsset["browser_download_url"] as? String,
          let downloadURL = URL(string: urlStr),
          downloadURL.scheme?.lowercased() == "https"
        else { continue }

        let size: Int64? = (rawAsset["size"] as? NSNumber).flatMap {
          CFGetTypeID($0) != CFBooleanGetTypeID() ? $0.int64Value : nil
        }
        var sha256: String?
        if let digest = rawAsset["digest"] as? String,
          digest.range(of: "^sha256:([A-Fa-f0-9]{64})$", options: .regularExpression) != nil
        {
          sha256 = String(digest.dropFirst(7)).lowercased()
        }
        matchedAsset = AppReleaseAsset(
          name: name, downloadURL: downloadURL, size: size, sha256: sha256, kind: kind)
        break outer
      }
    }

    return AppReleaseInfo(
      version: semVer.normalized,
      semanticVersion: semVer,
      tagName: tagName,
      title: title,
      notes: notes,
      htmlURL: htmlURL,
      publishedAt: publishedAt,
      asset: matchedAsset)
  }
}

package struct StagedUpdateArtifact: Equatable {
  package let version: String
  package let archiveURL: URL
  package let stagedAppURL: URL?
  package let statusDetail: String?

  package var canInstallInPlace: Bool { stagedAppURL != nil }

  package init(
    version: String, archiveURL: URL, stagedAppURL: URL?, statusDetail: String? = nil
  ) {
    self.version = version
    self.archiveURL = archiveURL
    self.stagedAppURL = stagedAppURL
    self.statusDetail = statusDetail
  }
}

package enum AppUpdateState: Equatable {
  case idle(lastCheckedAt: Double?)
  case checking
  case upToDate(version: String, checkedAt: Double)
  case available(AppReleaseInfo, checkedAt: Double)
  case downloading(AppReleaseInfo)
  case downloaded(AppReleaseInfo, StagedUpdateArtifact)
  case installing(AppReleaseInfo)
  case failed(message: String, release: AppReleaseInfo?)

  package var availableRelease: AppReleaseInfo? {
    switch self {
    case .available(let release, _), .downloading(let release),
      .downloaded(let release, _), .installing(let release):
      return release
    case .failed(_, let release):
      return release
    case .idle, .checking, .upToDate:
      return nil
    }
  }
}

package enum AppUpdateSchedulePolicy {
  package static let startupDelay: TimeInterval = 5.0
  package static let checkInterval: TimeInterval = 12 * 3600

  package static func isCheckDue(autoCheck: Bool, lastCheckedAtMs: Double?, nowMs: Double) -> Bool {
    guard autoCheck else { return false }
    guard let last = lastCheckedAtMs else { return true }
    return nowMs - last >= checkInterval * 1000
  }
}
