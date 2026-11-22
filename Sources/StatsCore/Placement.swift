import CoreGraphics
import Foundation

// The floating bar is a horizontal strip. It starts centred on the top edge of the
// verified host window and the user may drag it anywhere inside that window; the
// position is remembered as a fraction of the window, so resizing or moving the host
// keeps it in the same relative place. Edge docking, the position menu and every
// "which side am I on" recognition were removed. Window-identity verification below
// is unchanged.
package struct HUDPlacement {
  package var moduleCount: Int = 3
  package var contentSize: CGSize?
  /// nil keeps the default top-centre position. Otherwise x/y are fractions of the
  /// free space inside the host container, exactly like the dragged frame was.
  package var relativePosition: CGPoint?
  package var preferredSize: CGSize {
    contentSize ?? CGSize(width: 34 + 110 * moduleCount, height: 28)
  }
  package static func container(host: CGRect, screen: CGRect) -> CGRect {
    let clipped = host.intersection(screen)
    let base = clipped.isNull || clipped.width < 30 || clipped.height < 30 ? screen : clipped
    return base.insetBy(dx: 8, dy: 8)
  }
  package static func unit(_ value: CGFloat) -> CGFloat {
    value.isFinite ? min(1, max(0, value)) : 0.5
  }
  package static func fraction(_ value: CGFloat, _ span: CGFloat) -> CGFloat {
    span > 0 ? unit(value / span) : 0.5
  }
  package func frame(host: CGRect, screen: CGRect) -> CGRect {
    let area = Self.container(host: host, screen: screen)
    let size = CGSize(
      width: min(preferredSize.width, area.width), height: min(preferredSize.height, area.height))
    var origin = CGPoint(x: area.midX - size.width / 2, y: area.maxY - size.height)
    if let relativePosition {
      origin = CGPoint(
        x: area.minX + (area.width - size.width) * Self.unit(relativePosition.x),
        y: area.minY + (area.height - size.height) * Self.unit(relativePosition.y))
    }
    return Self.clamp(CGRect(origin: origin, size: size), to: area)
  }
  /// Record a dragged frame as the fraction it occupies inside the host container.
  package mutating func recordDrag(frame: CGRect, host: CGRect, screen: CGRect) {
    let area = Self.container(host: host, screen: screen)
    relativePosition = CGPoint(
      x: Self.fraction(frame.minX - area.minX, area.width - frame.width),
      y: Self.fraction(frame.minY - area.minY, area.height - frame.height))
  }
  package static func clamp(_ rect: CGRect, to area: CGRect) -> CGRect {
    let size = CGSize(
      width: min(rect.width, max(1, area.width)), height: min(rect.height, max(1, area.height)))
    return CGRect(
      x: min(max(rect.minX, area.minX), area.maxX - size.width),
      y: min(max(rect.minY, area.minY), area.maxY - size.height), width: size.width,
      height: size.height)
  }
  package init(moduleCount: Int = 3, contentSize: CGSize? = nil, relativePosition: CGPoint? = nil) {
    self.moduleCount = moduleCount
    self.contentSize = contentSize
    self.relativePosition = relativePosition
  }
}

package struct HUDHostWindow {
  package let number: UInt32
  package let frame: CGRect  // AppKit coordinates, after converting the CG window list.
  package init(number: UInt32, frame: CGRect) {
    self.number = number
    self.frame = frame
  }
}
package struct HUDHostIdentity {
  package var role: String?
  package var subrole: String?
  package var isMain: Bool?
  package var isFocused: Bool?
  package var isModal: Bool?
  package var isMinimized: Bool?
  package var hasSheet: Bool?
  package var documentURLs: [String]?
  package func permitsHUD(provider: String, requireFocused: Bool) -> Bool {
    guard role == "AXWindow", subrole == "AXStandardWindow", isMain == true,
      !requireFocused || isFocused == true, isModal == false, isMinimized == false,
      hasSheet == false,
      let urls = documentURLs, !urls.isEmpty
    else { return false }
    // Kimi keeps a browser-overlay WebContentsView attached to its main window
    // even while hidden. Its AXWebArea is a companion, never proof of a main
    // window: require a primary document as well and reject every unknown URL.
    guard urls.contains(where: { Self.isPrimaryDocument($0, provider: provider) }) else {
      return false
    }
    return urls.allSatisfy {
      Self.isPrimaryDocument($0, provider: provider)
        || (provider == "kimi" && $0 == "app://renderer/browser-overlay.html")
    }
  }
  package static func isPrimaryDocument(_ raw: String, provider: String) -> Bool {
    guard let url = URLComponents(string: raw), url.user == nil, url.password == nil,
      url.port == nil
    else { return false }
    guard url.scheme == "app" else { return false }
    if provider == "kimi" {
      guard url.host == "renderer" else { return false }
      return url.path.isEmpty || url.path == "/"
        || url.path.range(
          of: "^/sessions/session_[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil
    }
    guard provider == "codex", url.host == "-", url.path == "/index.html" else { return false }
    // A surface hint can exclude an auxiliary window, never identify a live
    // conversation. Do not turn initialRoute into a selected-session signal.
    let routes = url.queryItems?.filter { $0.name == "initialRoute" }.map { $0.value ?? "" } ?? []
    return routes.allSatisfy { route in
      route == "/" || route == "/new"
        || route.range(of: "^/local/[A-Za-z0-9:-]+$", options: .regularExpression) != nil
    }
  }
  package init(
    role: String? = nil, subrole: String? = nil, isMain: Bool? = nil, isFocused: Bool? = nil,
    isModal: Bool? = nil, isMinimized: Bool? = nil, hasSheet: Bool? = nil,
    documentURLs: [String]? = nil
  ) {
    self.role = role
    self.subrole = subrole
    self.isMain = isMain
    self.isFocused = isFocused
    self.isModal = isModal
    self.isMinimized = isMinimized
    self.hasSheet = hasSheet
    self.documentURLs = documentURLs
  }
}
package struct HUDHostVerification {
  package let number: UInt32
  package let focusConfirmed: Bool
  package init(number: UInt32, focusConfirmed: Bool) {
    self.number = number
    self.focusConfirmed = focusConfirmed
  }
}
/// The native window proof is asynchronous and is re-armed whenever the window list or
/// the focus requirement changes, so a single unverified pass is normal traffic, not a
/// host change. This decides when the already-visible bar may simply stay where it is
/// instead of being ordered out and back in.
package enum HUDHostContext {
  /// Whether the foreground application is still our host or our own UI. An
  /// activation handoff reports no frontmost application at all, which is unknown
  /// rather than another application, so it must never hide the bar.
  package static func isActive(front: String?, host: String, selfBundle: String) -> Bool {
    guard let front else { return true }
    return front == host || front == selfBundle
  }
}

package enum HUDVerificationGrace {
  package static let interval: TimeInterval = 0.8
  /// The proof is not refreshed while a drag or menu tracking pauses the positioning
  /// loop, so the grace restarts from the moment work resumes.
  package static func resumedVerifiedAt(_ verifiedAt: Date, pausedAt: Date?) -> Date {
    guard let pausedAt else { return verifiedAt }
    return max(verifiedAt, pausedAt)
  }
  /// A user-driven move or resize of the verified host (geometry changing while the
  /// pointer is held) races every asynchronous proof: the AX geometry trails the window
  /// server. Like the bar's own drag, the grace restarts from the last such motion.
  package static func motionAt(
    previous: Date?, frameChanged: Bool, pointerHeld: Bool, now: Date
  ) -> Date? {
    frameChanged && pointerHeld ? now : previous
  }
  /// `hostContextActive` is true while the host application, the bar's own
  /// interaction, or an unknown foreground (activation handoffs report nil) is the
  /// context. A third application taking focus hides the bar through the activation
  /// path and never reaches this grace.
  package static func holdsVisibleBar(
    hostContextActive: Bool, barVisible: Bool, verifiedNumber: UInt32?, verifiedAt: Date,
    now: Date, windowStillOnScreen: Bool
  ) -> Bool {
    guard hostContextActive, barVisible, verifiedNumber != nil, windowStillOnScreen else {
      return false
    }
    let age = now.timeIntervalSince(verifiedAt)
    return age >= 0 && age < interval
  }
}

/// After a quiet period the bar sheds its glass, border and shadow and leaves only
/// dimmed values on the host; any engagement brings the full bar back at once.
package enum HUDIdleSink {
  package static let delay: TimeInterval = 8
  package static let sunkContentAlpha: CGFloat = 0.55
  package static func shouldSink(
    enabled: Bool, engaged: Bool, lastActivity: Date, now: Date
  ) -> Bool {
    guard enabled, !engaged else { return false }
    return now.timeIntervalSince(lastActivity) >= delay
  }
}

package struct HUDHostProof {
  package private(set) var key: String?
  package private(set) var generation = 0
  private var requiresFocus = true
  private var focusConfirmed = false
  private var number: UInt32?
  private var checkedAt = Date.distantPast
  package mutating func prepare(key: String, requireFocused: Bool) {
    if self.key != key {
      generation += 1
      number = nil
      focusConfirmed = false
      checkedAt = .distantPast
    } else if requireFocused != requiresFocus {
      // Reject in-flight results requested under the previous policy, without
      // discarding a fresh proof that already satisfies the new policy.
      generation += 1
      if requireFocused && !focusConfirmed {
        number = nil
        checkedAt = .distantPast
      }
    }
    self.key = key
    requiresFocus = requireFocused
  }
  package mutating func accept(
    _ number: UInt32?, focusConfirmed: Bool, key: String, generation: Int, checkedAt: Date
  ) {
    guard self.key == key, self.generation == generation else { return }
    self.number = requiresFocus && !focusConfirmed ? nil : number
    self.focusConfirmed = focusConfirmed
    self.checkedAt = checkedAt
  }
  package func current(at now: Date) -> UInt32? {
    let age = now.timeIntervalSince(checkedAt)
    return age >= 0 && age < 0.75 ? number : nil
  }
  package mutating func reset() {
    generation += 1
    key = nil
    number = nil
    focusConfirmed = false
    checkedAt = .distantPast
  }
  package init() {}
}
package enum HUDHostGeometry {
  package static func needsOrdering(panelVisible: Bool, panelIndex: Int?, hostIndex: Int?) -> Bool {
    guard panelVisible, let panelIndex, let hostIndex else { return true }
    // Inspectors and system windows may sit between the HUD and its host. Being
    // above the host is sufficient; enforcing adjacency repeatedly reorders it.
    return panelIndex > hostIndex
  }
  package static func appKitFrame(_ bounds: CGRect, desktopTop: CGFloat) -> CGRect {
    CGRect(x: bounds.minX, y: desktopTop - bounds.maxY, width: bounds.width, height: bounds.height)
  }
  package static func screen(for host: CGRect, screens: [CGRect]) -> CGRect? {
    screens.max { a, b in
      func score(_ screen: CGRect) -> CGFloat {
        let overlap = host.intersection(screen)
        return overlap.isNull ? 0 : overlap.width * overlap.height
      }
      return score(a) < score(b)
    }
  }
  package static func select(
    _ windows: [HUDHostWindow], screens: [CGRect], verifiedMain: UInt32? = nil,
    retaining number: UInt32? = nil
  ) -> HUDHostWindow? {
    guard let verifiedMain, number == nil || number == verifiedMain else { return nil }
    let eligible = windows.filter { window in
      window.frame.width >= 240 && window.frame.height >= 160
        && screens.contains { screen in
          let visible = window.frame.intersection(screen)
          return !visible.isNull && visible.width >= 120 && visible.height >= 100
        }
    }
    let matches = eligible.filter { $0.number == verifiedMain }
    return matches.count == 1 ? matches[0] : nil
  }
}
package enum PopupDirection { case up, down, left, right }
package struct PopupPlan {
  package let frame: CGRect
  package let direction: PopupDirection
  package init(frame: CGRect, direction: PopupDirection) {
    self.frame = frame
    self.direction = direction
  }
}
package enum PopupLayout {
  package static func plan(
    anchor: CGRect, bar: CGRect, host: CGRect, screen: CGRect, desired: CGSize
  ) -> PopupPlan {
    let area = HUDPlacement.container(host: host, screen: screen)
    let gap: CGFloat = 7
    let block = anchor.union(bar)
    // The bar is always the host's top strip, so the card prefers to open below it;
    // the opposite side and then the left/right gaps remain as fallbacks.
    let preferred: PopupDirection = bar.midY > area.midY ? .down : .up
    let opposite: PopupDirection = preferred == .down ? .up : .down
    let order: [PopupDirection] = [preferred, opposite, .right, .left]
    func available(_ d: PopupDirection) -> CGSize {
      switch d {
      case .up: return CGSize(width: area.width, height: max(0, area.maxY - block.maxY - gap))
      case .down: return CGSize(width: area.width, height: max(0, block.minY - area.minY - gap))
      case .left: return CGSize(width: max(0, block.minX - area.minX - gap), height: area.height)
      case .right: return CGSize(width: max(0, area.maxX - block.maxX - gap), height: area.height)
      }
    }
    let target = CGSize(
      width: min(desired.width, area.width), height: min(desired.height, area.height))
    var direction = order.first {
      let s = available($0)
      return s.width >= target.width && s.height >= target.height
    }
    if direction == nil {
      direction = order.max { a, b in
        func score(_ d: PopupDirection) -> CGFloat {
          let s = available(d)
          let width = min(target.width, s.width)
          let height = min(target.height, s.height)
          return width * height * (width < 220 ? 0.1 : 1)
        }
        return score(a) < score(b)
      }
    }
    let d = direction ?? preferred
    let space = available(d)
    var size = CGSize(
      width: min(target.width, space.width), height: min(target.height, space.height))
    if size.width < 180 || size.height < 110 { size = target }
    var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.midY - size.height / 2)
    switch d {
    case .up: origin.y = block.maxY + gap
    case .down: origin.y = block.minY - gap - size.height
    case .left: origin.x = block.minX - gap - size.width
    case .right: origin.x = block.maxX + gap
    }
    return PopupPlan(
      frame: HUDPlacement.clamp(CGRect(origin: origin, size: size), to: area), direction: d)
  }
}
