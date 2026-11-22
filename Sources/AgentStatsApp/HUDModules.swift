import StatsCore
import StatsAdapters
import AppKit

struct HUDModule: Equatable {
    var id = UUID().uuidString
    var metric: HUDMetric
}

enum HUDModuleEdit {
    case add(HUDMetric), replace(String, HUDMetric), move(String, Int), remove(String), reset
}

/// Pure reorder arithmetic for the metric editor, so the drag interaction and its
/// regression test share exactly one rule.
enum HUDModuleReorder {
    /// Destination slot for a row dragged by `translation` points.
    static func targetIndex(from index: Int, translation: CGFloat, pitch: CGFloat, count: Int) -> Int {
        guard pitch > 0, count > 0 else { return index }
        let steps = Int((translation / pitch).rounded())
        return min(count - 1, max(0, index + steps))
    }
    /// The same list with one row moved into another slot.
    static func moved<T>(_ items: [T], from: Int, to: Int) -> [T] {
        guard items.indices.contains(from), items.indices.contains(to), from != to else { return items }
        var copy = items
        let item = copy.remove(at: from)
        copy.insert(item, at: to)
        return copy
    }
}

/// One position in the metric layout. A click opens the metric chooser and a vertical
/// drag reorders the position; there is deliberately no popup button any more, because
/// a click inside one changed the metric instead of offering the choice.
final class HUDModuleRow: NSView {
    override var isFlipped: Bool { true }
    let moduleID: String
    private(set) var metric: HUDMetric
    var onChoose: ((String) -> Void)?
    var onRemove: ((String) -> Void)?
    var onDrag: ((String, CGFloat) -> Void)?
    var onDragEnd: ((String) -> Void)?
    private var label = NSTextField(labelWithString:"")
    private var number = NSTextField(labelWithString:"")
    private var removeButton: NSButton!
    private var pressOrigin: NSPoint?
    private var dragging = false
    private var highlighted = false { didSet { needsDisplay = true } }
    init(index: Int, module: HUDModule, width: CGFloat) {
        moduleID = module.id; metric = module.metric
        super.init(frame:NSRect(x:0,y:0,width:width,height:32))
        let grip = NSImageView()
        grip.image = NSImage(systemSymbolName:"line.3.horizontal",accessibilityDescription:nil)
        grip.contentTintColor = .tertiaryLabelColor
        grip.imageScaling = .scaleProportionallyDown
        grip.frame = NSRect(x:8,y:9,width:11,height:14); addSubview(grip)
        number.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular)
        number.textColor = .secondaryLabelColor
        number.alignment = .right
        number.frame = NSRect(x:22,y:7,width:18,height:18); addSubview(number)
        label.font = .systemFont(ofSize:13,weight:.medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail; label.cell?.usesSingleLineMode = true
        label.frame = NSRect(x:48,y:7,width:max(40,width-106),height:18); addSubview(label)
        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName:"chevron.up.chevron.down",accessibilityDescription:"点击更换指标")
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.frame = NSRect(x:width-52,y:8,width:14,height:16); addSubview(chevron)
        removeButton = NSButton(image:NSImage(systemSymbolName:"minus.circle.fill",accessibilityDescription:"删除")!,target:self,action:#selector(remove))
        removeButton.isBordered = false; removeButton.bezelStyle = .recessed
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.identifier = NSUserInterfaceItemIdentifier("remove-"+module.id)
        removeButton.frame = NSRect(x:width-30,y:6,width:20,height:20); addSubview(removeButton)
        apply(index: index)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func apply(index: Int) {
        number.stringValue = String(index+1)
        label.stringValue = metric.label
        let position = "第 \(index+1) 项指标：\(metric.label)"
        toolTip = "点击更换指标；上下拖动排序。当前\(position)"
        setAccessibilityLabel(position + "，点击更换，可拖动排序")
        removeButton.toolTip = "删除" + position
        removeButton.setAccessibilityLabel("删除" + position)
    }
    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua
        let fill: NSColor
        let border: NSColor
        if highlighted {
            fill = NSColor.controlAccentColor.withAlphaComponent(0.18)
            border = NSColor.controlAccentColor.withAlphaComponent(0.45)
        } else {
            fill = isDark ? NSColor(white:1,alpha:0.05) : NSColor(white:0,alpha:0.03)
            border = isDark ? NSColor(white:1,alpha:0.08) : NSColor(white:0,alpha:0.06)
        }
        let path = NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:1.5),xRadius:8,yRadius:8)
        fill.setFill(); path.fill()
        border.setStroke(); path.lineWidth = 0.5; path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.openHand) }
    override func mouseDown(with event: NSEvent) {
        pressOrigin = convert(event.locationInWindow,from:nil)
        dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let pressOrigin else { return }
        let point = convert(event.locationInWindow,from:nil)
        let translation = point.y - pressOrigin.y
        if !dragging, abs(translation) < 4 { return }
        dragging = true; highlighted = true
        onDrag?(moduleID,translation)
    }
    override func mouseUp(with event: NSEvent) {
        let wasDragging = dragging
        pressOrigin = nil; dragging = false; highlighted = false
        if wasDragging { onDragEnd?(moduleID); return }
        onChoose?(moduleID)
    }
    @objc private func remove() { onRemove?(moduleID) }
}

/// One editable row per position. Edits are submitted through `onEdit`; the editor
/// never writes preferences and never changes the layout behind the coordinator.
final class HUDModuleEditor: NSView {
    override var isFlipped: Bool { true }
    static let rowPitch: CGFloat = 38
    let onEdit: (HUDModuleEdit) -> Void
    private let available: [HUDMetric]
    private var modules: [HUDModule]
    private var display: [HUDModule]
    private var rowViews = [String: HUDModuleRow]()
    private let hint = NSTextField(labelWithString:"")
    init(width: CGFloat, modules: [HUDModule], available: [HUDMetric], onEdit: @escaping (HUDModuleEdit) -> Void) {
        self.onEdit = onEdit; self.available = available
        self.modules = modules; self.display = modules
        let rowsHeight = modules.isEmpty ? 32 : CGFloat(modules.count) * Self.rowPitch
        super.init(frame:NSRect(x:0,y:0,width:width,height:rowsHeight+52))
        hint.font = .systemFont(ofSize:12); hint.textColor = .secondaryLabelColor
        hint.stringValue = "暂无指标"
        hint.isHidden = !modules.isEmpty
        hint.frame = NSRect(x:16,y:10,width:width-32,height:20); addSubview(hint)
        let y = rowsHeight+14
        let add = NSPopUpButton(frame:NSRect(x:14,y:y,width:140,height:30),pullsDown:true)
        add.addItem(withTitle:"＋ 添加指标"); fill(add,available:available)
        add.target = self; add.action = #selector(addModule(_:)); add.identifier = NSUserInterfaceItemIdentifier("add-module"); addSubview(add)
        let reset = NSButton(title:"恢复默认",target:self,action:#selector(resetModules)); reset.bezelStyle = .rounded
        reset.frame = NSRect(x:width-104,y:y,width:90,height:30); addSubview(reset)
        layoutRows()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// The rows in their current visual order, for tests and for the drag preview.
    var rows: [HUDModuleRow] { display.compactMap { rowViews[$0.id] } }
    private func fill(_ picker: NSPopUpButton, available: [HUDMetric]) {
        var group: String?
        for metric in available {
            if group != nil && group != metric.group { picker.menu?.addItem(.separator()) }
            picker.addItem(withTitle:metric.label); picker.lastItem?.representedObject = metric.rawValue
            group = metric.group
        }
    }
    private func layoutRows() {
        hint.isHidden = !modules.isEmpty
        let live = Set(display.map(\.id))
        for (id,row) in rowViews where !live.contains(id) { row.removeFromSuperview(); rowViews.removeValue(forKey: id) }
        for (index,module) in display.enumerated() {
            let row = rowViews[module.id] ?? {
                let created = HUDModuleRow(index:index,module:module,width:max(120,bounds.width-28))
                created.identifier = NSUserInterfaceItemIdentifier("metric-row-"+module.id)
                created.onChoose = { [weak self] id in self?.presentPicker(for:id) }
                created.onRemove = { [weak self] id in self?.onEdit(.remove(id)) }
                created.onDrag = { [weak self] id,translation in self?.dragRow(id,translation:translation) }
                created.onDragEnd = { [weak self] id in self?.endRowDrag(id) }
                rowViews[module.id] = created
                addSubview(created)
                return created
            }()
            row.apply(index:index)
            row.frame = NSRect(x:14,y:CGFloat(index)*Self.rowPitch+8,width:max(120,bounds.width-28),height:32)
        }
    }
    /// Live preview while dragging: the dragged row moves by whole slots, in the
    /// same arithmetic the drop uses, so the preview cannot disagree with the result.
    func dragRow(_ id: String, translation: CGFloat) {
        guard let index = display.firstIndex(where: { $0.id == id }) else { return }
        let target = HUDModuleReorder.targetIndex(
            from: index, translation: translation, pitch: Self.rowPitch, count: display.count)
        guard target != index else { return }
        display = HUDModuleReorder.moved(display, from: index, to: target)
        layoutRows()
    }
    /// Commit a drop as one relative move against the persisted layout.
    func endRowDrag(_ id: String) {
        guard let stored = modules.firstIndex(where: { $0.id == id }),
              let visual = display.firstIndex(where: { $0.id == id })
        else { return }
        display = modules
        layoutRows()
        if stored != visual { onEdit(.move(id, visual - stored)) }
    }
    /// Choose a replacement for one position, exactly as a menu pick would.
    func choose(_ id: String, metric: HUDMetric) { onEdit(.replace(id,metric)) }
    func presentPicker(for id: String) {
        guard let row = rowViews[id] else { return }
        let menu = metricPickerMenu(for: id)
        menu.popUp(positioning: nil, at: NSPoint(x: 26, y: row.frame.maxY + 2), in: self)
    }
    /// The chooser for one position: every metric the tool supports, grouped by
    /// category, with the current one marked.
    func metricPickerMenu(for id: String) -> NSMenu {
        let menu = NSMenu(title: "选择指标")
        let current = rowViews[id]?.metric
        var group: String?
        for metric in available {
            if let group, group != metric.group { menu.addItem(.separator()) }
            group = metric.group
            let entry = NSMenuItem(title: metric.label, action: #selector(pickMetric(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = HUDMetricMenuItem(module: id, metric: metric)
            entry.state = metric == current ? .on : .off
            menu.addItem(entry)
        }
        return menu
    }
    @objc private func pickMetric(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? HUDMetricMenuItem else { return }
        choose(choice.module, metric: choice.metric)
    }
    @objc private func addModule(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let metric = HUDMetric(rawValue:raw) else { return }
        onEdit(.add(metric))
    }
    @objc private func resetModules() { onEdit(.reset) }
}

struct HUDMetricMenuItem {
    let module: String
    let metric: HUDMetric
}

/// A category header renders exactly like the plain label it replaces, but it also
/// jumps the page to its own section when the host wires up a selection handler.
/// It behaves like a button: the press is swallowed so a drag never moves the window
/// and never jumps, and the jump only happens on a release inside the header.
final class HUDHelpCategoryLabel: NSTextField {
    var onSelect: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { onSelect != nil }
    override func resetCursorRects() { if onSelect != nil { addCursorRect(bounds,cursor:.pointingHand) } }
    override func mouseDown(with event: NSEvent) {
        if onSelect == nil { super.mouseDown(with:event) }
    }
    override func mouseUp(with event: NSEvent) {
        guard let onSelect else { return super.mouseUp(with:event) }
        if bounds.contains(convert(event.locationInWindow,from:nil)) { onSelect() }
    }
}

/// Native categorized usage help rendered as ordinary labels: full text is
/// wrapped and laid out row by row, so nothing is ever clipped or truncated.
final class HUDHelpContentView: NSView {
    override var isFlipped: Bool { true }
    private(set) var categoryOffsets = [String: CGFloat]()
    init(width: CGFloat, categories: [HelpCategory], onSelect: ((String) -> Void)? = nil) {
        let rowWidth=width
        super.init(frame:NSRect(x:0,y:0,width:width,height:100))
        var y: CGFloat = 0
        let secondaryColor = NSColor(name:nil) { appearance in
            appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua
                ? NSColor(white:0.78,alpha:1) : NSColor(white:0.34,alpha:1)
        }
        let cardFill = NSColor(name:nil) { appearance in
            appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua
                ? NSColor(white:1,alpha:0.06) : NSColor(white:1,alpha:0.94)
        }
        let cardBorder = NSColor(name:nil) { appearance in
            appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua
                ? NSColor(white:1,alpha:0.10) : NSColor(white:0,alpha:0.08)
        }
        for category in categories {
            categoryOffsets[category.id] = y
            let title = HUDHelpCategoryLabel(labelWithString:category.title)
            title.font = .systemFont(ofSize:13,weight:.semibold)
            title.textColor = .labelColor
            title.frame = NSRect(x:4,y:y,width:width-8,height:20)
            if let onSelect {
                title.onSelect = { onSelect(category.id) }
                title.toolTip = "点击将「\(category.title)」滚动到顶部"
                title.setAccessibilityRole(.button)
            }
            addSubview(title); y += 26
            let card = SettingsSurface(frame:NSRect(x:0,y:y,width:width,height:0))
            card.fill = cardFill
            card.borderColor = cardBorder
            card.borderWidth = 1
            card.radius = 12
            var rowY: CGFloat = 14
            for (index,item) in category.items.enumerated() {
                if index>0 {
                    let line = SettingsSurface(frame:NSRect(x:16,y:rowY,width:rowWidth-32,height:0.5))
                    line.fill = NSColor.labelColor.withAlphaComponent(0.09); card.addSubview(line)
                    rowY += 14
                }
                let innerWidth = rowWidth-32
                let body = NSTextField(wrappingLabelWithString:item.1)
                body.font = .systemFont(ofSize:12.5)
                body.textColor = secondaryColor
                let bodyHeight = ceil((item.1 as NSString).boundingRect(with:NSSize(width:innerWidth,height:10000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:NSFont.systemFont(ofSize:12.5)]).height)
                let label = NSTextField(labelWithString:item.0)
                label.font = .systemFont(ofSize:13,weight:.medium)
                label.textColor = .labelColor
                label.frame = NSRect(x:16,y:rowY,width:innerWidth,height:18)
                card.addSubview(label); rowY += 22
                body.frame = NSRect(x:16,y:rowY,width:innerWidth,height:bodyHeight)
                card.addSubview(body); rowY += bodyHeight+14
            }
            card.frame = NSRect(x:0,y:y,width:width,height:rowY)
            addSubview(card); y += rowY+18
        }
        frame.size = NSSize(width:width,height:max(1,y))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Chooses which rows an expanded detail card may show. Rows are grouped by the
/// same categories as the metrics themselves, and toggling one saves immediately
/// through the coordinator; this view never writes preferences itself.
final class HUDDetailRowEditor: NSView {
    override var isFlipped: Bool { true }
    private let onToggle: (String, Bool) -> Void
    init(width: CGFloat, provider: StatsProvider, enabled: Set<String>, onToggle: @escaping (String, Bool) -> Void) {
        self.onToggle = onToggle
        super.init(frame:NSRect(x:0,y:0,width:width,height:0))
        var y: CGFloat = 12
        let groups = DetailRowRegistry.groups(for: provider)
        for (groupIndex, group) in groups.enumerated() {
            if groupIndex > 0 {
                let divider = SettingsSurface(frame:NSRect(x:16,y:y,width:width-32,height:0.5))
                divider.fill = NSColor.labelColor.withAlphaComponent(0.09); addSubview(divider)
                y += 12
            }
            let title = NSTextField(labelWithString:group.title)
            title.font = .systemFont(ofSize:12,weight:.semibold)
            title.textColor = .secondaryLabelColor
            title.frame = NSRect(x:16,y:y,width:width-32,height:18); addSubview(title); y += 24
            for definition in DetailRowRegistry.available(for: provider, in: group) {
                let box = NSButton(checkboxWithTitle:definition.title,target:self,action:#selector(toggle(_:)))
                box.font = .systemFont(ofSize:13)
                box.state = enabled.contains(definition.key) ? .on : .off
                box.identifier = NSUserInterfaceItemIdentifier("detail-row-"+definition.key)
                box.setAccessibilityLabel("展开明细："+definition.title)
                box.frame = NSRect(x:16,y:y,width:width-32,height:22); addSubview(box); y += 26
            }
            y += 6
        }
        frame.size = NSSize(width:width,height:max(1,y+8))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggle(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        onToggle(String(key.dropFirst("detail-row-".count)),sender.state == .on)
    }
}

/// The bar's glass. It never takes the mouse, so presses still reach HUDContentView.
final class HUDBackdropView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class HUDContentView: NSView, HUDDragSurface {
    var onLayout: (() -> Void)?
    let drag = HUDDragGesture()
    let backdrop = HUDBackdropView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        backdrop.frame = bounds
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); onLayout?() }
    override func mouseDown(with event: NSEvent) { drag.mouseDown() }
    override func mouseDragged(with event: NSEvent) { _ = drag.mouseDragged() }
    override func mouseUp(with event: NSEvent) { _ = drag.mouseUp() }
}

final class HUDMetricScrollView: NSScrollView, HUDDragSurface {
    let drag = HUDDragGesture()
    override func mouseDown(with event: NSEvent) { drag.mouseDown() }
    override func mouseDragged(with event: NSEvent) { _ = drag.mouseDragged() }
    override func mouseUp(with event: NSEvent) { _ = drag.mouseUp() }
    /// The bar never installs a scroller, so a vertical wheel over a wider-than-clip
    /// metric strip scrolls it sideways instead of doing nothing.
    override func scrollWheel(with event: NSEvent) {
        if let documentView, documentView.frame.width > contentSize.width,
           abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            var point = contentView.bounds.origin
            let step = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12)
            point.x = min(max(0,point.x-step),documentView.frame.width-contentSize.width)
            contentView.scroll(to:point); reflectScrolledClipView(contentView)
        } else { super.scrollWheel(with:event) }
    }
}
