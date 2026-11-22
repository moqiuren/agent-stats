import ApplicationServices
import Foundation
import StatsCore

// Reads window identity, modality, geometry and top-level web-document URLs only. It never reads page
// text, message content, input values, titles, or credentials, and never invokes AX actions.
package final class HostAccessibility {
  package static var isAuthorized: Bool { AXIsProcessTrusted() }
  private let clock: StatsClock
  private let authorized: () -> Bool
  private let attribute: (AXUIElement, String) -> CFTypeRef?
  package init(
    clock: StatsClock = SystemStatsClock(),
    authorized: @escaping () -> Bool = { HostAccessibility.isAuthorized },
    attribute: @escaping (AXUIElement, String) -> CFTypeRef? = HostAccessibility.copyValue
  ) {
    self.clock = clock
    self.authorized = authorized
    self.attribute = attribute
  }
  package static func requestAuthorization() {
    let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
  }
  private static func copyValue(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    AXUIElementSetMessagingTimeout(element, 0.05)
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else {
      return nil
    }
    return result
  }
  private func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    attribute(element, key)
  }
  private func application(_ pid: Int32) -> AXUIElement {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.15)
    // Electron/Chromium initialize native accessibility when the application
    // role is read. Going directly to AXMainWindow can leave a cold renderer
    // without a web-document tree until another accessibility client visits.
    // This is a structural read, not AXManualAccessibility/AXEnhancedUserInterface
    // mutation. A delayed or missing document must still fail normal validation.
    _ = value(app, kAXRoleAttribute)
    return app
  }
  private func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
  }
  private func bounds(_ element: AXUIElement) -> CGRect? {
    guard let position = value(element, kAXPositionAttribute),
      CFGetTypeID(position) == AXValueGetTypeID(),
      let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
      AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
    else { return nil }
    return CGRect(origin: point, size: dimensions)
  }
  private func matches(_ element: AXUIElement, target: CGRect) -> Bool {
    guard let rect = bounds(element) else { return false }
    return abs(rect.minX - target.minX) <= 3 && abs(rect.minY - target.minY) <= 3
      && abs(rect.width - target.width) <= 3 && abs(rect.height - target.height) <= 3
  }
  package func mainWindow(provider: String, windows: [HostWindowReference], requireFocused: Bool)
    -> HUDHostVerification?
  {
    guard authorized(), let pid = windows.first?.pid, windows.allSatisfy({ $0.pid == pid }) else {
      return nil
    }
    let app = application(pid)
    guard let main = element(value(app, kAXMainWindowAttribute)) else { return nil }
    let candidates = windows.filter { matches(main, target: $0.bounds) }
    guard candidates.count == 1 else { return nil }
    let focused = element(value(app, kAXFocusedWindowAttribute))
    let sameWindow = focused.map { CFEqual($0, main) }
    var identity = HUDHostIdentity(
      role: value(main, kAXRoleAttribute) as? String,
      subrole: value(main, kAXSubroleAttribute) as? String,
      isMain: value(main, kAXMainAttribute) as? Bool, isFocused: sameWindow,
      isModal: value(main, kAXModalAttribute) as? Bool,
      isMinimized: value(main, kAXMinimizedAttribute) as? Bool)
    // Reject transient windows before scanning their document containers.
    guard identity.role == "AXWindow", identity.subrole == "AXStandardWindow",
      identity.isMain == true,
      !requireFocused || sameWindow == true, identity.isModal == false,
      identity.isMinimized == false
    else { return nil }
    guard let scan = documentScan(main) else { return nil }
    let sheets = value(main, "AXSheets") as? [AXUIElement] ?? []
    identity.hasSheet = scan.hasSheet || !sheets.isEmpty
    identity.documentURLs = scan.urls
    guard identity.permitsHUD(provider: provider, requireFocused: requireFocused) else {
      return nil
    }
    // Recheck focus after the bounded scan: a newly opened picker invalidates
    // this proof even if the original main-window geometry still matches.
    guard let stillMain = element(value(app, kAXMainWindowAttribute)), CFEqual(main, stillMain)
    else { return nil }
    let stillFocused = element(value(app, kAXFocusedWindowAttribute))
    let focusConfirmed = sameWindow == true && stillFocused.map { CFEqual(main, $0) } == true
    if requireFocused && !focusConfirmed { return nil }
    // A nonactivating HUD can be key while the host's native focused window
    // remains its main window. Record the evidence, not the requested policy.
    return HUDHostVerification(number: candidates[0].number, focusConfirmed: focusConfirmed)
  }
  package func read(provider: String, window: HostWindowReference) -> CurrentSession {
    guard authorized() else { return CurrentSession(.permissionRequired, window: window.token) }
    let app = application(window.pid)
    let focused = element(value(app, kAXFocusedWindowAttribute))
    let selected: AXUIElement
    if let focused, matches(focused, target: window.bounds) {
      selected = focused
    } else {
      let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
      let candidates = windows.prefix(32).filter { matches($0, target: window.bounds) }
      guard candidates.count == 1 else { return CurrentSession(.unknown, window: window.token) }
      selected = candidates[0]
      // If the app explicitly focuses another window, the HUD and observation
      // must converge on the same window before showing any conversation.
      if let focused, !CFEqual(focused, selected) {
        return CurrentSession(.unknown, window: window.token)
      }
    }
    guard let scan = documentScan(selected), !scan.hasSheet else {
      return CurrentSession(.unknown, window: window.token)
    }
    return CurrentSessionResolver.resolve(
      provider: provider, documentURLs: scan.urls, window: window.token)
  }
  private func documentScan(_ window: AXUIElement) -> (urls: [String], hasSheet: Bool)? {
    let deadline = clock.now.addingTimeInterval(0.25)
    var pending: [(AXUIElement, Int)] = [(window, 0)]
    var urls = [String]()
    var visited = 0
    var hasSheet = false
    while let (node, depth) = pending.popLast() {
      guard visited < 128, clock.now < deadline else { return nil }
      visited += 1
      guard let role = value(node, kAXRoleAttribute) as? String else { return nil }
      if ["AXSheet", "AXDialog", "AXSystemDialog"].contains(role) {
        hasSheet = true
        continue
      }
      if role == "AXWebArea" {
        if let url = value(node, kAXURLAttribute) as? URL {
          urls.append(url.absoluteString)
        } else if let string = value(node, kAXURLAttribute) as? String {
          urls.append(string)
        }
        // Do not traverse the web document: only its own URL is needed.
        continue
      }
      guard depth < 10 else { return nil }
      // Web documents sit below window/group/split/scroll containers. Do not
      // explore menus, text controls, or arbitrary page descendants.
      guard ["AXWindow", "AXGroup", "AXSplitGroup", "AXScrollArea", "AXUnknown"].contains(role)
      else { continue }
      guard let children = value(node, kAXChildrenAttribute) as? [AXUIElement],
        pending.count + children.count <= 128
      else { return nil }
      pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
    }
    return (urls, hasSheet)
  }
}

// AX calls run off the UI thread. Proofs are short-lived, bound to the exact
// process/window stack and discarded when a newer observation supersedes them.
package final class HostWindowMonitor: HostWindowMonitoring {
  private let scheduler: StatsScheduling
  private let uiScheduler: StatsScheduling
  private let clock: StatsClock
  private let authorized: () -> Bool
  private let readWindow: (String, [HostWindowReference], Bool) -> HUDHostVerification?
  private var pending = false, lastPoll = Date.distantPast, proof = HUDHostProof()
  package init(
    clock: StatsClock = SystemStatsClock(), scheduler: StatsScheduling? = nil,
    uiScheduler: StatsScheduling = DispatchStatsScheduler(queue: .main),
    authorized: @escaping () -> Bool = { HostAccessibility.isAuthorized },
    readWindow: ((String, [HostWindowReference], Bool) -> HUDHostVerification?)? = nil
  ) {
    self.clock = clock
    self.uiScheduler = uiScheduler
    self.scheduler =
      scheduler
      ?? DispatchStatsScheduler(
        queue: DispatchQueue(label: "\(Product.bundleID).primary-window", qos: .userInitiated))
    self.authorized = authorized
    let reader = HostAccessibility(clock: clock)
    self.readWindow =
      readWindow ?? { reader.mainWindow(provider: $0, windows: $1, requireFocused: $2) }
  }
  package func observe(
    windows: [HostWindowReference], requireFocused: Bool, provider: String = Product.provider
  ) -> UInt32? {
    guard authorized(), !windows.isEmpty else {
      reset()
      return nil
    }
    let requestKey = provider + ":" + windows.map(\.token).joined(separator: ",")
    let oldGeneration = proof.generation
    proof.prepare(key: requestKey, requireFocused: requireFocused)
    if proof.generation != oldGeneration { lastPoll = .distantPast }
    if !pending, clock.now.timeIntervalSince(lastPoll) >= 0.25 {
      pending = true
      lastPoll = clock.now
      let generation = proof.generation
      let startedAt = lastPoll
      scheduler.execute { [weak self] in
        guard let self else { return }
        let result = self.readWindow(provider, windows, requireFocused)
        self.uiScheduler.execute { [weak self] in
          guard let self else { return }
          self.pending = false
          guard self.authorized() else {
            self.proof.reset()
            return
          }
          self.proof.accept(
            result?.number, focusConfirmed: result?.focusConfirmed ?? false,
            key: requestKey, generation: generation, checkedAt: startedAt)
        }
      }
    }
    return proof.current(at: clock.now)
  }
  package func reset() {
    proof.reset()
    lastPoll = .distantPast
  }
}

package final class CurrentSessionMonitor: CurrentSessionMonitoring {
  private let provider: String
  private let scheduler: StatsScheduling
  private let read: (String, HostWindowReference) -> CurrentSession
  private var timer: StatsCancellation?, window: HostWindowReference?, enabled = false,
    stopped = false
  private var last: CurrentSession?
  package var onChange: ((CurrentSession) -> Void)?
  package init(
    provider: String = Product.provider, clock: StatsClock = SystemStatsClock(),
    scheduler: StatsScheduling? = nil,
    read: ((String, HostWindowReference) -> CurrentSession)? = nil
  ) {
    self.provider = provider
    self.scheduler =
      scheduler
      ?? DispatchStatsScheduler(
        queue: DispatchQueue(label: "\(Product.bundleID).current-window", qos: .userInitiated))
    let reader = HostAccessibility(clock: clock)
    self.read = read ?? { reader.read(provider: $0, window: $1) }
  }
  package func start() {
    scheduler.execute { [self] in
      guard !stopped, timer == nil else { return }
      timer = scheduler.schedule(after: 0, repeating: 0.5, tolerance: 0) { [weak self] in
        self?.poll()
      }
    }
  }
  package func observe(_ window: HostWindowReference?) {
    scheduler.execute { [self] in
      let changed = self.window?.token != window?.token
      self.window = window
      if changed { poll() }
    }
  }
  package func setEnabled(_ enabled: Bool) {
    scheduler.execute { [self] in
      guard self.enabled != enabled else { return }
      self.enabled = enabled
      poll()
    }
  }
  private func poll() {
    guard !stopped else { return }
    let result: CurrentSession
    if !enabled {
      result = CurrentSession(.disabled, window: window?.token)
    } else if let window {
      result = read(provider, window)
    } else {
      result = CurrentSession(.hostUnavailable)
    }
    guard result != last else { return }
    last = result
    onChange?(result)
  }
  package func stop() {
    scheduler.execute {
      self.stopped = true
      self.timer?.cancel()
      self.timer = nil
      self.onChange = nil
    }
  }
}
