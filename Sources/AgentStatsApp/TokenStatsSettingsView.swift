import AppKit
import StatsCore

enum TokenStatsColors {
  static let input = NSColor.systemBlue
  static let cacheWrite = NSColor.systemIndigo
  static let cacheRead = NSColor.systemTeal
  static let output = NSColor.systemOrange
  static let hostFallback = NSColor.systemGray
}

final class TokenMixBarView: NSView {
  override var isFlipped: Bool { true }
  var segments: [(label: String, value: Double, color: NSColor)] = [] {
    didSet { needsDisplay = true }
  }
  var total: Double = 0 { didSet { needsDisplay = true } }

  override func draw(_ dirtyRect: NSRect) {
    let trackRect = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
    let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: 5, yRadius: 5)
    SettingsPalette.stageFill.setFill()
    trackPath.fill()

    guard total > 0, bounds.width > 0 else { return }
    let active = segments.filter { $0.value > 0 }
    guard !active.isEmpty else { return }

    NSGraphicsContext.saveGraphicsState()
    trackPath.addClip()
    var cursor: CGFloat = 0
    for (index, segment) in active.enumerated() {
      let width: CGFloat
      if index == active.count - 1 {
        width = max(0, bounds.width - cursor)
      } else {
        width = max(2, floor(bounds.width * CGFloat(segment.value / total)))
      }
      segment.color.setFill()
      NSRect(x: cursor, y: 0, width: width, height: bounds.height).fill()
      cursor += width
    }
    NSGraphicsContext.restoreGraphicsState()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

final class TokenTrendChartView: NSView {
  override var isFlipped: Bool { true }

  var buckets: [TokenTrendBucket] = [] {
    didSet {
      hoveredIndex = nil
      selectedIndex = nil
      needsDisplay = true
    }
  }
  var axisIndices: [Int] = [] { didSet { needsDisplay = true } }
  var peakTokens: Double = 0 { didSet { needsDisplay = true } }
  var onInspectBucket: ((TokenTrendBucket?) -> Void)?

  private(set) var hoveredIndex: Int? { didSet { needsDisplay = true } }
  private var selectedIndex: Int? { didSet { needsDisplay = true } }
  private var trackingArea: NSTrackingArea?

  private var plotRect: NSRect {
    let left: CGFloat = 46
    let top: CGFloat = 8
    let right: CGFloat = 6
    let bottom: CGFloat = 22
    return NSRect(
      x: left, y: top,
      width: max(40, bounds.width - left - right),
      height: max(40, bounds.height - top - bottom))
  }

  func inspectBucket(at index: Int?) {
    if let index, buckets.indices.contains(index) {
      hoveredIndex = index
      onInspectBucket?(buckets[index])
    } else {
      hoveredIndex = nil
      onInspectBucket?(selectedIndex.flatMap { buckets.indices.contains($0) ? buckets[$0] : nil })
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingArea = area
  }

  private func bucketIndex(at point: NSPoint) -> Int? {
    guard !buckets.isEmpty else { return nil }
    let plot = plotRect
    guard point.x >= plot.minX, point.x <= plot.maxX,
      point.y >= plot.minY - 4, point.y <= plot.maxY + 4
    else { return nil }
    let step = plot.width / CGFloat(buckets.count)
    guard step > 0 else { return nil }
    let idx = Int((point.x - plot.minX) / step)
    return buckets.indices.contains(idx) ? idx : nil
  }

  override func mouseMoved(with event: NSEvent) {
    let local = convert(event.locationInWindow, from: nil)
    let idx = bucketIndex(at: local)
    if idx != hoveredIndex {
      inspectBucket(at: idx)
    }
  }

  override func mouseExited(with event: NSEvent) {
    inspectBucket(at: nil)
  }

  override func mouseDown(with event: NSEvent) {
    let local = convert(event.locationInWindow, from: nil)
    guard let idx = bucketIndex(at: local) else {
      selectedIndex = nil
      onInspectBucket?(nil)
      return
    }
    if selectedIndex == idx {
      selectedIndex = nil
      onInspectBucket?(hoveredIndex.flatMap { buckets.indices.contains($0) ? buckets[$0] : nil })
    } else {
      selectedIndex = idx
      onInspectBucket?(buckets[idx])
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    let plot = plotRect
    let gridColor = NSColor.labelColor.withAlphaComponent(0.08)
    let axisAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
      .foregroundColor: SettingsPalette.secondary,
    ]

    for fraction in [0.0, 0.5, 1.0] {
      let y = plot.maxY - plot.height * CGFloat(fraction)
      let line = NSBezierPath()
      line.move(to: NSPoint(x: plot.minX, y: y))
      line.line(to: NSPoint(x: plot.maxX, y: y))
      line.lineWidth = 0.5
      if fraction > 0 { line.setLineDash([2, 2], count: 2, phase: 0) }
      gridColor.setStroke()
      line.stroke()
    }

    let yTopText = peakTokens > 0 ? compactTokenCount(peakTokens) : "0"
    let yMidText = peakTokens > 0 ? compactTokenCount(peakTokens * 0.5) : ""
    for (text, y) in [(yTopText, plot.minY - 6), (yMidText, plot.midY - 6), ("0", plot.maxY - 6)]
    where !text.isEmpty {
      let size = (text as NSString).size(withAttributes: axisAttrs)
      let drawPoint = NSPoint(x: max(0, plot.minX - 6 - size.width), y: y)
      (text as NSString).draw(at: drawPoint, withAttributes: axisAttrs)
    }

    guard !buckets.isEmpty else { return }

    if peakTokens <= 0 {
      let msg = "所选时间范围内暂无本地 Token 记录" as NSString
      let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12),
        .foregroundColor: SettingsPalette.secondary,
      ]
      let size = msg.size(withAttributes: attrs)
      msg.draw(
        at: NSPoint(x: plot.midX - size.width / 2, y: plot.midY - size.height / 2),
        withAttributes: attrs)
    } else {
      let count = CGFloat(buckets.count)
      let slotWidth = plot.width / count
      let gap: CGFloat = slotWidth > 12 ? 4 : (slotWidth > 6 ? 2 : 1)
      let barWidth = max(2, slotWidth - gap)
      let activeHighlight = hoveredIndex ?? selectedIndex

      for (index, bucket) in buckets.enumerated() {
        let slotX = plot.minX + CGFloat(index) * slotWidth
        let barX = slotX + (slotWidth - barWidth) / 2
        if activeHighlight == index {
          NSColor.labelColor.withAlphaComponent(0.06).setFill()
          NSBezierPath(
            roundedRect: NSRect(x: slotX, y: plot.minY, width: slotWidth, height: plot.height),
            xRadius: 3, yRadius: 3
          ).fill()
        }

        guard bucket.totalTokens > 0 else { continue }
        let barHeight = max(2, plot.height * CGFloat(bucket.totalTokens / peakTokens))
        let barTop = plot.maxY - barHeight
        let barRect = NSRect(x: barX, y: barTop, width: barWidth, height: barHeight)
        let corner = min(3, barWidth / 2, barHeight / 2)
        let clipPath = NSBezierPath(roundedRect: barRect, xRadius: corner, yRadius: corner)

        NSGraphicsContext.saveGraphicsState()
        clipPath.addClip()
        let parts: [(Double, NSColor)] = [
          (bucket.hostFallback, TokenStatsColors.hostFallback),
          (bucket.combinedInput, TokenStatsColors.input),
          (bucket.cacheRead, TokenStatsColors.cacheRead),
          (bucket.output, TokenStatsColors.output),
        ].filter { $0.0 > 0 }
        var cursorY = plot.maxY
        for (idx, part) in parts.enumerated() {
          let h =
            idx == parts.count - 1
            ? max(0, cursorY - barTop)
            : max(1, barHeight * CGFloat(part.0 / bucket.totalTokens))
          let segY = max(barTop, cursorY - h)
          part.1.withAlphaComponent(activeHighlight == nil || activeHighlight == index ? 0.92 : 0.45)
            .setFill()
          NSRect(x: barX, y: segY, width: barWidth, height: cursorY - segY).fill()
          cursorY = segY
        }
        NSGraphicsContext.restoreGraphicsState()
      }
    }

    // Draw sparse X-axis labels cleanly without overlapping.
    let slotWidth = plot.width / CGFloat(buckets.count)
    var lastRight: CGFloat = -1000
    for idx in axisIndices where buckets.indices.contains(idx) {
      let label = buckets[idx].axisLabel as NSString
      let size = label.size(withAttributes: axisAttrs)
      let centerX = plot.minX + (CGFloat(idx) + 0.5) * slotWidth
      let x = min(max(plot.minX, centerX - size.width / 2), plot.maxX - size.width)
      if x < lastRight + 8 { continue }
      label.draw(at: NSPoint(x: x, y: plot.maxY + 5), withAttributes: axisAttrs)
      lastRight = x + size.width
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

final class TokenBreakdownBarView: NSView {
  override var isFlipped: Bool { true }
  var share: Double = 0 { didSet { needsDisplay = true } }
  var isHostFallback: Bool = false { didSet { needsDisplay = true } }

  override func draw(_ dirtyRect: NSRect) {
    let track = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
    SettingsPalette.stageFill.setFill()
    track.fill()
    guard share > 0, bounds.width > 0 else { return }
    let fillWidth = min(bounds.width, max(3, bounds.width * CGFloat(share)))
    let fillRect = NSRect(x: 0, y: 0, width: fillWidth, height: bounds.height)
    (isHostFallback ? TokenStatsColors.hostFallback : NSColor.controlAccentColor)
      .withAlphaComponent(0.85)
      .setFill()
    NSBezierPath(roundedRect: fillRect, xRadius: 2, yRadius: 2).fill()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}
