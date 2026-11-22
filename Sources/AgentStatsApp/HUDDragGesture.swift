import AppKit

/// Press/drag discrimination shared by every surface of the floating bar. The bar has
/// no grip: it is moved by dragging it directly, and a press that never travels beyond
/// the threshold stays a click and keeps its normal action.
final class HUDDragGesture {
  static let threshold: CGFloat = 3
  var onBegin: ((CGPoint) -> Void)?
  var onMove: ((CGPoint) -> Void)?
  var onEnd: ((Bool) -> Void)?
  private var start: CGPoint?
  private var moved = false
  var isDragging: Bool { moved }

  func mouseDown() {
    start = NSEvent.mouseLocation
    moved = false
  }
  /// True once the press became a drag.
  @discardableResult func mouseDragged() -> Bool {
    guard let start else { return false }
    let point = NSEvent.mouseLocation
    if !moved, hypot(point.x - start.x, point.y - start.y) < Self.threshold { return false }
    if !moved {
      moved = true
      onBegin?(start)
    }
    onMove?(point)
    return true
  }
  /// True when the finished press was a drag, so the caller must not run its click action.
  @discardableResult func mouseUp() -> Bool {
    let wasDragging = moved
    start = nil
    moved = false
    onEnd?(wasDragging)
    return wasDragging
  }
}

/// Any bar surface that can start a move by direct mouse interaction.
protocol HUDDragSurface: AnyObject {
  var drag: HUDDragGesture { get }
}

/// A metric value. Dragging it moves the bar; a plain click still opens its detail
/// card, so the two gestures never share a trigger.
final class HUDMetricButton: NSButton, HUDDragSurface {
  let drag = HUDDragGesture()
  override func mouseDown(with event: NSEvent) {
    drag.mouseDown()
    highlight(true)
  }
  override func mouseDragged(with event: NSEvent) {
    _ = drag.mouseDragged()
  }
  override func mouseUp(with event: NSEvent) {
    highlight(false)
    guard !drag.mouseUp() else { return }
    guard bounds.contains(convert(event.locationInWindow, from: nil)), let action else { return }
    _ = NSApp.sendAction(action, to: target, from: self)
  }
}
