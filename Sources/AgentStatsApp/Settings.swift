import StatsCore
import StatsAdapters
import AppKit

// Settings observes state and submits actions; it cannot write preference keys or
// perform a partial render/collector update sequence of its own.
protocol StatsSettingsActions: AnyObject {
    var provider: StatsProvider { get }
    var activeProvider: String { get }
    var followsActiveTool: Bool { get }
    var displayMode: StatsDisplayMode { get }
    var hudHidden: Bool { get }
    var hudIdleSink: Bool { get }
    var statusItemHidden: Bool { get }
    var modules: [HUDModule] { get }
    var detailRowKeys: Set<String> { get }
    var selected: String? { get }
    var selectedProject: String { get }
    var projectGroups: [JSONObject] { get }
    var scopeText: String { get }
    var canFollowCurrentConversation: Bool { get }
    var isAccessibilityAuthorized: Bool { get }
    var isLaunchAtLoginEnabled: Bool { get }
    var isInStandardApplicationsLocation: Bool { get }
    var kimiPluginStatusText: String { get }
    var tokenStatsScope: TokenStatsToolScope { get }
    var tokenStatsRange: TokenStatsTimeRange { get }
    var tokenStatsDimension: TokenStatsDimension { get }
    var tokenStatsLoading: Bool { get }
    func setTokenStatsScope(_ scope: TokenStatsToolScope)
    func setTokenStatsRange(_ range: TokenStatsTimeRange)
    func setTokenStatsDimension(_ dimension: TokenStatsDimension)
    func refreshTokenStats(force: Bool)
    func tokenStatsReport() -> TokenStatsReport
    func metricTitle(_ metric: HUDMetric) -> String
    func conversationChoices(in project: String?) -> [InspectorChoice]
    func editModules(_ edit: HUDModuleEdit)
    func selectProvider(_ provider: StatsProvider)
    func enableToolFollowing()
    func setDisplayMode(_ mode: StatsDisplayMode)
    func toggle()
    func setHUDIdleSink(_ enabled: Bool)
    func setStatusItemHidden(_ hidden: Bool)
    func editDetailRow(_ key: String, enabled: Bool)
    func browseProject(_ id: String)
    func selectSession(_ id: String)
    func selectRecentSession()
    func enableNativeFollowing()
    func openAccessibilitySettings()
    func authorizeWindowRecognition()
    func showHelpSettings()
    func setLaunchAtLogin(_ enabled: Bool)
    func relocateToApplications()
    func syncKimiPlugin()
    func revealAppInFinder()
    func showOnboarding()
    func completeOnboarding(keepPendingUpgrade: Bool)
    func confirmAndUninstall()
    var autoCheckUpdates: Bool { get }
    var autoDownloadUpdates: Bool { get }
    var updateState: AppUpdateState { get }
    func setAutoCheckUpdates(_ enabled: Bool)
    func setAutoDownloadUpdates(_ enabled: Bool)
    func checkForUpdates()
    func checkForUpdatesAndShowAbout()
    func performPrimaryUpdateAction()
    func openLatestReleasePage()
}

enum SettingsPalette {
    static let secondary = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.78, alpha: 1) : NSColor(white: 0.34, alpha: 1)
    }
    static let cardFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 1, alpha: 0.94)
    }
    static let cardBorder = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.08)
    }
    static let divider = NSColor.labelColor.withAlphaComponent(0.09)
    static let sidebarPlatterFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.16, alpha: 0.45) : NSColor(white: 0.95, alpha: 0.55)
    }
    static let sidebarSelected = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.13) : NSColor(white: 0, alpha: 0.075)
    }
    static let sidebarHovered = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.035)
    }
    static let stageFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0, alpha: 0.24) : NSColor(white: 0, alpha: 0.035)
    }
    static let pillFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.22, alpha: 0.95) : NSColor(white: 1, alpha: 0.98)
    }
}

enum StatsSettingsPage: Int, CaseIterable {
    case general, metrics, tokenStats, sessions, help, about
    var title: String {
        switch self {
        case .general: return "通用"
        case .metrics: return "显示指标"
        case .tokenStats: return "Token 统计"
        case .sessions: return "会话与权限"
        case .help: return "使用说明"
        case .about: return "关于"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .metrics: return "chart.bar.xaxis"
        case .tokenStats: return "chart.pie.fill"
        case .sessions: return "bubble.left.and.bubble.right.fill"
        case .help: return "book.closed.fill"
        case .about: return "info.circle.fill"
        }
    }
    var badgeColor: NSColor {
        switch self {
        case .general: return .systemGray
        case .metrics: return .systemBlue
        case .tokenStats: return .systemOrange
        case .sessions: return .systemIndigo
        case .help: return .systemTeal
        case .about: return .systemCyan
        }
    }
}

final class SettingsSurface: NSView {
    var isFlippedOverride = true
    override var isFlipped: Bool { isFlippedOverride }
    var fill: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
    var borderColor: NSColor? { didSet { needsDisplay = true } }
    var borderWidth: CGFloat = 0 { didSet { needsDisplay = true } }
    var radius: CGFloat = 0 { didSet { needsDisplay = true } }
    var onLayout: (() -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        if fill == .clear && (borderColor == nil || borderWidth <= 0) { return }
        let inset = borderWidth > 0 ? borderWidth / 2 : 0
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        if let borderColor, borderWidth > 0 {
            borderColor.setStroke()
            path.lineWidth = borderWidth
            path.stroke()
        }
    }
    override func layout() { super.layout(); onLayout?() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Concentric sidebar navigation item matching macOS 27 System Settings geometry
/// (16pt sidebar platter with 8pt inner padding -> 8pt corner radius).
private final class SettingsSidebarButton: NSButton {
    override var isFlipped: Bool { true }
    private let badge = SettingsSurface()
    private let glyph = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(page: StatsSettingsPage, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        tag = page.rawValue
        title = page.title
        isBordered = false
        bezelStyle = .recessed
        setButtonType(.pushOnPushOff)
        focusRingType = .none
        identifier = NSUserInterfaceItemIdentifier("settings-nav-\(page.rawValue)")
        setAccessibilityLabel(page.title)

        badge.fill = page.badgeColor
        badge.radius = 6
        addSubview(badge)

        glyph.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: nil)
        glyph.contentTintColor = .white
        glyph.imageScaling = .scaleProportionallyDown
        badge.addSubview(glyph)

        caption.stringValue = page.title
        caption.font = .systemFont(ofSize: 13, weight: .regular)
        caption.lineBreakMode = .byTruncatingTail
        caption.cell?.usesSingleLineMode = true
        addSubview(caption)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applySelection(_ selected: Bool) {
        state = selected ? .on : .off
        caption.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        caption.textColor = .labelColor
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        badge.frame = NSRect(x: 8, y: (bounds.height - 22) / 2, width: 22, height: 22)
        glyph.frame = NSRect(x: 4, y: 4, width: 14, height: 14)
        caption.frame = NSRect(x: 38, y: (bounds.height - 18) / 2, width: max(20, bounds.width - 46), height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            SettingsPalette.sidebarSelected.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        } else if hovered {
            SettingsPalette.sidebarHovered.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// A normal, independent window. Settings never needs a recognized host or a HUD anchor.
final class StatsSettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private weak var actions: StatsSettingsActions?
    private(set) var page: StatsSettingsPage = .general
    private let root = SettingsSurface()
    private let sidebarContainer = NSView()
    private let sidebarSurface = SettingsSurface()
    private let brandBadge = SettingsSurface()
    private let brandTitle = NSTextField(labelWithString: Product.name)
    private let headerRule = SettingsSurface()
    private let heading = NSTextField(labelWithString: "")
    private var providerControl: NSPopUpButton?
    private let helpCategoryTitle = NSTextField(labelWithString: "分类")
    private var helpCategoryControl: NSPopUpButton?
    private let scroll = NSScrollView()
    private let pageBody = SettingsSurface()
    private var navigation = [SettingsSidebarButton]()
    private var layoutWidth: CGFloat = 0
    private var bodyHeight: CGFloat = 0

    private var displayControl: NSSegmentedControl?
    private var visibilityControl: NSSwitch?
    private var idleSinkControl: NSSwitch?
    private var statusItemControl: NSSwitch?
    private var followToolControl: NSSwitch?
    private var launchAtLoginControl: NSSwitch?
    private var kimiStatusNote: NSTextField?
    private var lastAuthorizedInGeneral: Bool?
    private var lastDisplayModeInGeneral: StatsDisplayMode?
    private var preview: NSTextField?
    private var projectMode: NSPopUpButton?
    private var sessionMode: NSPopUpButton?
    private var search: NSSearchField?
    private var table: NSTableView?
    private var sessionNote: NSTextField?
    private var emptyNote: NSTextField?
    private var permissionNote: NSTextField?
    private var permissionButton: NSButton?
    private var tokenScopeControl: NSSegmentedControl?
    private var tokenRangeControl: NSSegmentedControl?
    private var tokenDimensionControl: NSSegmentedControl?
    private var tokenRefreshButton: NSButton?
    private var tokenChartSummaryLabel: NSTextField?
    private var lastTokenReport: TokenStatsReport?
    private var lastTokenDimension: TokenStatsDimension?
    private var lastTokenLoading: Bool?
    private var defaultTokenSummaryText = ""
    private var autoCheckUpdatesSwitch: NSSwitch?
    private var autoDownloadUpdatesSwitch: NSSwitch?
    private var lastUpdateStateRendered: AppUpdateState?
    private var lastAutoCheckRendered: Bool?
    private static let updateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private var visibleSessions = [InspectorChoice]()
    private var sessionSignature = ""
    private var moduleSignature = [HUDModule]()
    private var choosingFixedSession = false
    private var updating = false
    private var presenting = false
    private var hostName: String { actions?.provider.name ?? "Agent" }

    init(actions: StatsSettingsActions) {
        self.actions = actions
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.title = Product.name + " 设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "StatsSettingsToolbar")
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = false
        }

        root.fill = .windowBackgroundColor
        window.contentView = root
        window.minSize = NSSize(width: 580, height: 640)
        window.contentMinSize = NSSize(width: 580, height: 640)
        let autosaveName = NSWindow.FrameAutosaveName("StatsSettingsWindow.v2")
        // Read the frame the user left the window at before anything else moves it.
        // Only a window without a saved frame is centered; the saved position wins.
        let restoredFrame = window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)
        window.delegate = self

        configureSidebar()
        configureDetailHeader()
        root.onLayout = { [weak self] in self?.layout() }
        if !restoredFrame { window.center() }
        layout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureSidebar() {
        sidebarSurface.fill = SettingsPalette.sidebarPlatterFill
        sidebarSurface.borderColor = SettingsPalette.cardBorder
        sidebarSurface.borderWidth = 0.5
        sidebarSurface.radius = 16
        sidebarSurface.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 16
            glass.contentView = sidebarSurface
            sidebarContainer.addSubview(glass)
            glass.autoresizingMask = [.width, .height]
        } else {
            let effect = NSVisualEffectView()
            effect.material = .sidebar
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 16
            effect.layer?.masksToBounds = true
            effect.autoresizingMask = [.width, .height]
            effect.addSubview(sidebarSurface)
            sidebarContainer.addSubview(effect)
        }
        root.addSubview(sidebarContainer)

        brandBadge.fill = .systemBlue
        brandBadge.radius = 7
        let brandGlyph = NSImageView(frame: NSRect(x: 4, y: 4, width: 18, height: 18))
        brandGlyph.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: nil)
        brandGlyph.contentTintColor = .white
        brandGlyph.imageScaling = .scaleProportionallyDown
        brandBadge.addSubview(brandGlyph)
        sidebarSurface.addSubview(brandBadge)

        brandTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        brandTitle.textColor = .labelColor
        brandTitle.lineBreakMode = .byTruncatingTail
        sidebarSurface.addSubview(brandTitle)

        for item in StatsSettingsPage.allCases {
            let button = SettingsSidebarButton(page: item, target: self, action: #selector(navigate(_:)))
            sidebarSurface.addSubview(button)
            navigation.append(button)
        }
    }

    private func configureDetailHeader() {
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.textColor = .labelColor
        heading.alignment = .left
        heading.lineBreakMode = .byTruncatingTail
        root.addSubview(heading)

        let tools = NSPopUpButton(frame: .zero, pullsDown: false)
        tools.identifier = NSUserInterfaceItemIdentifier("settings-provider")
        tools.setAccessibilityLabel("Agent 工具")
        tools.target = self
        tools.action = #selector(changeProvider(_:))
        tools.addItem(withTitle: "跟随当前工具")
        tools.lastItem?.representedObject = "automatic"
        for provider in StatsProvider.allCases {
            tools.addItem(withTitle: provider.name)
            tools.lastItem?.representedObject = provider.rawValue
        }
        root.addSubview(tools)
        providerControl = tools

        helpCategoryTitle.font = .systemFont(ofSize: 12, weight: .medium)
        helpCategoryTitle.textColor = SettingsPalette.secondary
        helpCategoryTitle.isHidden = true
        root.addSubview(helpCategoryTitle)

        // The usage-help category picker lives in the window header, not in the page
        // body, so jumping to a later category keeps it on screen.
        let helpPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        helpPicker.autoenablesItems = false
        helpPicker.target = self
        helpPicker.action = #selector(selectHelpCategory(_:))
        helpPicker.identifier = NSUserInterfaceItemIdentifier("settings-help-category")
        helpPicker.setAccessibilityLabel("使用说明分类")
        helpPicker.isHidden = true
        root.addSubview(helpPicker)
        helpCategoryControl = helpPicker

        headerRule.fill = SettingsPalette.divider
        root.addSubview(headerRule)

        scroll.identifier = NSUserInterfaceItemIdentifier("settings-page-scroll")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        pageBody.fill = .clear
        scroll.documentView = pageBody
        root.addSubview(scroll)
    }

    func present() {
        // The first refresh happens before the window is ordered front, so the flag
        // keeps that one population. Later refreshes arrive from every metrics
        // update; a closed window must not keep paying for them.
        if page == .tokenStats { actions?.refreshTokenStats(force: false) }
        presenting = true; refresh(); presenting = false
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if page == .tokenStats { actions?.refreshTokenStats(force: false) }
        refresh()
    }
    @objc private func closeSettings() { close() }

    func selectPage(_ value: StatsSettingsPage) {
        page = value
        choosingFixedSession = false
        if value == .tokenStats { actions?.refreshTokenStats(force: false) }
        // The pinned help picker and the scroll area belong to the window header, so
        // the page geometry has to settle before its body is rebuilt.
        layout()
        rebuildPage()
        scroll.contentView.scroll(to: .zero)
        window?.makeFirstResponder(navigation[value.rawValue])
    }

    @objc private func navigate(_ sender: NSButton) {
        guard let value = StatsSettingsPage(rawValue: sender.tag) else { return }
        selectPage(value)
    }

    private func layout() {
        let size = root.bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let sidebarInset: CGFloat = 10
        let sidebarWidth: CGFloat = size.width < 640 ? 186 : 202
        let sidebarHeight = max(120, size.height - sidebarInset * 2)
        sidebarContainer.frame = NSRect(x: sidebarInset, y: sidebarInset, width: sidebarWidth, height: sidebarHeight)
        sidebarContainer.subviews.forEach { $0.frame = sidebarContainer.bounds }
        sidebarSurface.frame = sidebarContainer.bounds

        // Traffic lights occupy the upper-left corner inside the floating sidebar platter.
        brandBadge.frame = NSRect(x: 12, y: 44, width: 26, height: 26)
        brandTitle.frame = NSRect(x: 46, y: 48, width: sidebarWidth - 56, height: 18)

        let navTop: CGFloat = 86
        let navRowHeight: CGFloat = 32
        let navGap: CGFloat = 4
        for (index, button) in navigation.enumerated() {
            button.frame = NSRect(
                x: 8, y: navTop + CGFloat(index) * (navRowHeight + navGap),
                width: sidebarWidth - 16, height: navRowHeight)
        }

        let detailX = sidebarInset + sidebarWidth + 12
        let detailWidth = max(240, size.width - detailX)
        let headerSidePad: CGFloat = detailWidth < 420 ? 18 : 24
        let pickerWidth = min(188, max(144, detailWidth * 0.42))
        let pickerX = detailX + detailWidth - headerSidePad - pickerWidth
        providerControl?.frame = NSRect(x: pickerX, y: 12, width: pickerWidth, height: 26)

        let headingWidth = max(60, pickerX - (detailX + headerSidePad) - 12)
        heading.frame = NSRect(x: detailX + headerSidePad, y: 14, width: headingWidth, height: 22)

        let helpPickerShown = page == .help
        helpCategoryTitle.isHidden = !helpPickerShown
        helpCategoryControl?.isHidden = !helpPickerShown
        // Keep a valid horizontal frame even when hidden so layout checks never see a zero box.
        let helpControlWidth = min(260, max(140, detailWidth - headerSidePad * 2 - 40))
        helpCategoryTitle.frame = NSRect(x: detailX + headerSidePad, y: 56, width: 32, height: 18)
        helpCategoryControl?.frame = NSRect(x: detailX + headerSidePad + 36, y: 52, width: helpControlWidth, height: 26)

        let headerHeight: CGFloat = helpPickerShown ? 88 : 50
        headerRule.frame = NSRect(x: detailX, y: headerHeight - 0.5, width: detailWidth, height: 0.5)

        scroll.frame = NSRect(
            x: detailX, y: headerHeight,
            width: detailWidth, height: max(1, size.height - headerHeight))
        let width = scroll.contentSize.width
        if abs(layoutWidth - width) > 0.5 {
            layoutWidth = width
            rebuildPage()
        }
        pageBody.frame.size = NSSize(width: width, height: max(bodyHeight, scroll.contentSize.height))
    }

    private func formMetrics() -> (x: CGFloat, width: CGFloat) {
        let sidePad: CGFloat = layoutWidth < 420 ? 18 : 24
        let width = min(580, max(220, layoutWidth - sidePad * 2))
        let x = floor((layoutWidth - width) / 2)
        return (x, width)
    }

    private func text(_ value: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        return label
    }

    private func measureHeight(_ value: String, width: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        guard !value.isEmpty, width > 0 else { return 0 }
        let probe = NSTextField(wrappingLabelWithString: value)
        probe.font = .systemFont(ofSize: size, weight: weight)
        return ceil(probe.sizeThatFits(NSSize(width: width, height: 10000)).height)
    }

    @discardableResult
    private func section(_ title: String, x: CGFloat, width: CGFloat, at y: CGFloat) -> CGFloat {
        let label = text(title, size: 12.5, weight: .semibold, color: SettingsPalette.secondary)
        label.frame = NSRect(x: x + 4, y: y, width: width - 8, height: 18)
        pageBody.addSubview(label)
        return y + 24
    }

    private func card(x: CGFloat, width: CGFloat, at y: CGFloat, height: CGFloat) -> SettingsSurface {
        let card = SettingsSurface(frame: NSRect(x: x, y: y, width: width, height: height))
        card.autoresizesSubviews = false
        card.fill = SettingsPalette.cardFill
        card.borderColor = SettingsPalette.cardBorder
        card.borderWidth = 1
        card.radius = 12
        pageBody.addSubview(card)
        return card
    }

    private func rule(in parent: NSView, y: CGFloat) {
        let line = SettingsSurface(frame: NSRect(x: 16, y: y, width: parent.bounds.width - 32, height: 0.5))
        line.fill = SettingsPalette.divider
        parent.addSubview(line)
    }

    private struct FormRowSpec {
        let title: String
        let detail: String
        let keepNote: Bool
        let symbol: String
        let tint: NSColor
        let control: NSView?
        let controlWidth: CGFloat
        let controlHeight: CGFloat
        init(_ title: String, _ detail: String = "", keepNote: Bool = false, symbol: String, tint: NSColor = .systemBlue,
             control: NSView? = nil, controlWidth: CGFloat = 172, controlHeight: CGFloat = 26) {
            self.title = title; self.detail = detail; self.keepNote = keepNote
            self.symbol = symbol; self.tint = tint
            self.control = control; self.controlWidth = controlWidth; self.controlHeight = controlHeight
        }
    }

    @discardableResult
    private func addFormCard(_ specs: [FormRowSpec], x: CGFloat, width: CGFloat, at y: CGFloat) -> (card: SettingsSurface, notes: [NSTextField], nextY: CGFloat) {
        let card = card(x: x, width: width, at: y, height: 10)
        var rowY: CGFloat = 0
        var notes = [NSTextField]()
        var rowFrames = [(index: Int, frame: NSRect, control: NSView?, controlFrame: NSRect, titleFrame: NSRect, detailFrame: NSRect?, iconFrame: NSRect)]()
        for (index, spec) in specs.enumerated() {
            if index > 0 {
                rowY += 0.5
            }
            let textX: CGFloat = 52
            let cSize = spec.control.map {
                NSSize(width: max(spec.controlWidth, $0.fittingSize.width), height: max(spec.controlHeight, $0.fittingSize.height))
            } ?? .zero
            let controlReserve: CGFloat = spec.control == nil ? 16 : cSize.width + 28
            let available = max(120, width - textX - controlReserve)
            let titleHeight = max(18, measureHeight(spec.title, width: available, size: 13, weight: .medium))
            let showsNote = !spec.detail.isEmpty || spec.keepNote
            let detailHeight = showsNote ? max(16, measureHeight(spec.detail.isEmpty ? " " : spec.detail, width: available, size: 11.5)) : 0
            let rowHeight: CGFloat
            let titleTop: CGFloat
            let detailFrame: NSRect?
            if showsNote {
                rowHeight = max(58, 12 + titleHeight + 4 + detailHeight + 12)
                titleTop = floor((rowHeight - (titleHeight + 4 + detailHeight)) / 2)
                detailFrame = NSRect(x: textX, y: titleTop + titleHeight + 4, width: available, height: detailHeight)
            } else {
                rowHeight = max(46, 14 + titleHeight + 14)
                titleTop = floor((rowHeight - titleHeight) / 2)
                detailFrame = nil
            }
            let iconFrame = NSRect(x: 14, y: floor((rowHeight - 26) / 2), width: 26, height: 26)
            let titleFrame = NSRect(x: textX, y: titleTop, width: available, height: titleHeight)
            let controlFrame = NSRect(
                x: width - 16 - cSize.width,
                y: floor((rowHeight - cSize.height) / 2),
                width: cSize.width, height: cSize.height)
            rowFrames.append((index, NSRect(x: 0, y: rowY, width: width, height: rowHeight), spec.control, controlFrame, titleFrame, detailFrame, iconFrame))
            rowY += rowHeight
        }
        card.frame = NSRect(x: x, y: y, width: width, height: rowY)
        for item in rowFrames {
            let spec = specs[item.index]
            if item.index > 0 {
                rule(in: card, y: item.frame.minY - 0.5)
            }
            let row = SettingsSurface(frame: item.frame)
            row.fill = .clear
            card.addSubview(row)

            let iconBox = SettingsSurface(frame: item.iconFrame)
            iconBox.fill = spec.tint.withAlphaComponent(0.14)
            iconBox.radius = 7
            let icon = NSImageView(frame: NSRect(x: 5, y: 5, width: 16, height: 16))
            icon.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: nil)
            icon.imageScaling = .scaleProportionallyDown
            icon.contentTintColor = spec.tint
            iconBox.addSubview(icon)
            row.addSubview(iconBox)

            let label = text(spec.title, size: 13, weight: .medium)
            label.frame = item.titleFrame
            row.addSubview(label)

            if let detailFrame = item.detailFrame {
                let note = text(spec.detail, size: 11.5, color: SettingsPalette.secondary)
                note.frame = detailFrame
                row.addSubview(note)
                notes.append(note)
            }

            if let control = item.control {
                control.frame = item.controlFrame
                row.addSubview(control)
            }
        }
        return (card, notes, y + rowY)
    }

    @discardableResult
    private func addFootnote(_ value: String, x: CGFloat, width: CGFloat, at y: CGFloat) -> CGFloat {
        let noteWidth = max(100, width - 8)
        let height = measureHeight(value, width: noteWidth, size: 11.5) + 4
        let label = text(value, size: 11.5, color: SettingsPalette.secondary)
        label.frame = NSRect(x: x + 4, y: y, width: noteWidth, height: height)
        pageBody.addSubview(label)
        return y + height
    }

    private func segments(_ labels: [String], id: String, action: Selector) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self, action: action)
        control.segmentStyle = .rounded
        control.font = .systemFont(ofSize: 12)
        control.identifier = NSUserInterfaceItemIdentifier(id)
        return control
    }

    private func actionButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12)
        return button
    }

    private func rebuildPage() {
        guard layoutWidth > 0, let actions else { return }
        let query = search?.stringValue ?? ""
        let offset = scroll.contentView.bounds.origin
        pageBody.subviews.forEach { $0.removeFromSuperview() }
        displayControl = nil; visibilityControl = nil; followToolControl = nil; preview = nil
        launchAtLoginControl = nil; kimiStatusNote = nil
        sessionMode = nil; projectMode = nil; search = nil; table = nil
        sessionNote = nil; emptyNote = nil; permissionNote = nil; permissionButton = nil
        tokenScopeControl = nil; tokenRangeControl = nil; tokenDimensionControl = nil
        tokenRefreshButton = nil; tokenChartSummaryLabel = nil
        autoCheckUpdatesSwitch = nil; autoDownloadUpdatesSwitch = nil

        heading.stringValue = page.title
        for button in navigation {
            button.applySelection(button.tag == page.rawValue)
        }
        switch page {
        case .general: buildGeneral()
        case .metrics: buildMetrics()
        case .tokenStats: buildTokenStats()
        case .sessions: buildSessions(query: query)
        case .help: buildHelp()
        case .about: buildAbout()
        }
        moduleSignature = actions.modules
        pageBody.frame.size = NSSize(width: layoutWidth, height: max(bodyHeight, scroll.contentSize.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(offset.y, max(0, bodyHeight - scroll.contentSize.height))))
        refresh()
    }

    private func buildGeneral() {
        guard let actions else { return }
        let form = formMetrics()
        var y = section("展示", x: form.x, width: form.width, at: 18)

        let mode = segments(["悬浮条", "菜单栏"], id: "settings-display-mode", action: #selector(changeDisplay(_:)))
        mode.setAccessibilityLabel("展示模式")
        displayControl = mode

        let visibility = NSSwitch()
        visibility.target = self; visibility.action = #selector(changeVisibility(_:))
        visibility.identifier = NSUserInterfaceItemIdentifier("settings-visibility")
        visibility.setAccessibilityLabel("显示悬浮条")
        visibilityControl = visibility

        let idleSink = NSSwitch()
        idleSink.target = self; idleSink.action = #selector(changeIdleSink(_:))
        idleSink.identifier = NSUserInterfaceItemIdentifier("settings-idle-sink")
        idleSink.setAccessibilityLabel("闲置后下沉")
        idleSinkControl = idleSink

        let statusSwitch = NSSwitch()
        statusSwitch.target = self; statusSwitch.action = #selector(changeStatusItemHidden(_:))
        statusSwitch.identifier = NSUserInterfaceItemIdentifier("settings-hide-status-item")
        statusSwitch.setAccessibilityLabel("隐藏菜单栏图标")
        statusItemControl = statusSwitch

        let authorized = actions.isAccessibilityAuthorized
        lastAuthorizedInGeneral = authorized
        lastDisplayModeInGeneral = actions.displayMode

        var displayRows = [
            FormRowSpec("展示模式", symbol: "macwindow", tint: .systemBlue, control: mode, controlWidth: 164, controlHeight: 24),
            FormRowSpec("显示悬浮条", symbol: "rectangle.topthird.inset.filled", tint: .systemIndigo, control: visibility, controlWidth: 44, controlHeight: 24),
            FormRowSpec("闲置后下沉", "约 8 秒未操作后隐去背景、只留数值；指针移入或点击即浮现。", symbol: "circle.lefthalf.filled", tint: .systemPurple, control: idleSink, controlWidth: 44, controlHeight: 24),
            FormRowSpec("隐藏菜单栏图标", "菜单栏模式下始终显示；隐藏后再次打开 \(Product.name) 即可进入设置。", symbol: "menubar.rectangle", tint: .systemGray, control: statusSwitch, controlWidth: 44, controlHeight: 24),
        ]
        if actions.displayMode == .floating && !authorized {
            let grantButton = actionButton("去授权…", action: #selector(openPermissions))
            grantButton.identifier = NSUserInterfaceItemIdentifier("settings-grant-accessibility")
            displayRows.append(
                FormRowSpec("需要辅助功能权限", "授权后才能识别宿主窗口并显示悬浮条。", symbol: "exclamationmark.triangle.fill", tint: .systemOrange, control: grantButton, controlWidth: 92, controlHeight: 26))
        }
        let displayCard = addFormCard(displayRows, x: form.x, width: form.width, at: y)

        y = section("工具", x: form.x, width: form.width, at: displayCard.nextY + 20)
        let follow = NSSwitch()
        follow.target = self; follow.action = #selector(changeFollowTool(_:))
        follow.identifier = NSUserInterfaceItemIdentifier("settings-follow-tool")
        follow.setAccessibilityLabel("自动跟随前台工具")
        followToolControl = follow

        let toolCard = addFormCard([
            FormRowSpec("自动跟随前台工具", symbol: "arrow.triangle.2.circlepath", tint: .systemTeal, control: follow, controlWidth: 44, controlHeight: 24),
        ], x: form.x, width: form.width, at: y)

        y = section("系统", x: form.x, width: form.width, at: toolCard.nextY + 20)
        let launchSwitch = NSSwitch()
        launchSwitch.target = self; launchSwitch.action = #selector(changeLaunchAtLogin(_:))
        launchSwitch.identifier = NSUserInterfaceItemIdentifier("settings-launch-at-login")
        launchSwitch.setAccessibilityLabel("开机自动启动")
        launchAtLoginControl = launchSwitch

        var systemRows = [
            FormRowSpec("开机自动启动", "登录 macOS 时自动启动 \(Product.name)。", symbol: "power.circle.fill", tint: .systemGreen, control: launchSwitch, controlWidth: 44, controlHeight: 24),
        ]
        if !actions.isInStandardApplicationsLocation {
            let relocateButton = actionButton("移至应用程序…", action: #selector(relocateApplication))
            relocateButton.identifier = NSUserInterfaceItemIdentifier("settings-relocate-app")
            systemRows.append(
                FormRowSpec("移至应用程序文件夹", "当前位置不在「应用程序」中，移入后可稳定保留系统权限。", symbol: "arrow.down.app.fill", tint: .systemOrange, control: relocateButton, controlWidth: 118, controlHeight: 26))
        }
        let updateButtonTitle: String
        switch actions.updateState {
        case .available, .downloaded, .downloading, .installing:
            updateButtonTitle = "查看更新…"
        default:
            updateButtonTitle = "检查更新…"
        }
        let generalUpdateButton = actionButton(updateButtonTitle, action: #selector(openAboutAndCheckUpdates))
        generalUpdateButton.identifier = NSUserInterfaceItemIdentifier("settings-general-check-updates")
        systemRows.append(
            FormRowSpec("软件更新", updateSummaryText(for: actions.updateState, autoCheck: actions.autoCheckUpdates), symbol: "arrow.triangle.2.circlepath.circle.fill", tint: .systemBlue, control: generalUpdateButton, controlWidth: 98, controlHeight: 26))
        lastUpdateStateRendered = actions.updateState
        lastAutoCheckRendered = actions.autoCheckUpdates
        let systemCard = addFormCard(systemRows, x: form.x, width: form.width, at: y)
        bodyHeight = systemCard.nextY + 24
    }

    private func buildMetrics() {
        guard let actions else { return }
        let form = formMetrics()
        var y = section("预览", x: form.x, width: form.width, at: 18)
        let previewCard = card(x: form.x, width: form.width, at: y, height: 74)
        let stage = SettingsSurface(frame: NSRect(x: 12, y: 12, width: form.width - 24, height: 50))
        stage.fill = SettingsPalette.stageFill
        stage.radius = 10
        previewCard.addSubview(stage)

        let pill = SettingsSurface(frame: NSRect(x: 12, y: 11, width: stage.bounds.width - 24, height: 28))
        pill.fill = SettingsPalette.pillFill
        pill.borderColor = SettingsPalette.cardBorder
        pill.borderWidth = 0.5
        pill.radius = 14
        stage.addSubview(pill)

        let label = text("", size: 12, weight: .medium)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.frame = NSRect(x: 14, y: 6, width: pill.bounds.width - 28, height: 16)
        pill.addSubview(label)
        preview = label

        y = section("显示指标", x: form.x, width: form.width, at: y + 92)
        let editor = HUDModuleEditor(width: form.width, modules: actions.modules, available: HUDMetric.available(for: actions.activeProvider)) { [weak self] edit in
            self?.actions?.editModules(edit)
        }
        let group = card(x: form.x, width: form.width, at: y, height: editor.frame.height + 8)
        editor.frame.origin = NSPoint(x: 0, y: 4)
        group.addSubview(editor)
        y += group.frame.height + 20

        y = section("展开明细", x: form.x, width: form.width, at: y)
        let detail = HUDDetailRowEditor(width: form.width, provider: actions.provider, enabled: actions.detailRowKeys) { [weak self] key, on in
            self?.actions?.editDetailRow(key, enabled: on)
        }
        let detailGroup = card(x: form.x, width: form.width, at: y, height: detail.frame.height + 8)
        detail.frame.origin = NSPoint(x: 0, y: 4)
        detailGroup.addSubview(detail)
        bodyHeight = y + detailGroup.frame.height + 24
    }

    private func buildTokenStats() {
        guard let actions else { return }
        let form = formMetrics()
        let scope = actions.tokenStatsScope
        let range = actions.tokenStatsRange
        let dimension = actions.tokenStatsDimension
        let report = actions.tokenStatsReport()
        lastTokenReport = report
        lastTokenDimension = dimension
        lastTokenLoading = actions.tokenStatsLoading

        // 1. Filter Card
        let filterCard = card(x: form.x, width: form.width, at: 18, height: 88)
        let scopeTitle = text("统计范围", size: 13, weight: .medium)
        scopeTitle.frame = NSRect(x: 14, y: 13, width: 64, height: 18)
        filterCard.addSubview(scopeTitle)

        let refreshBtn = actionButton(actions.tokenStatsLoading ? "扫描…" : "刷新", action: #selector(refreshTokenStatsAction))
        refreshBtn.identifier = NSUserInterfaceItemIdentifier("settings-token-refresh")
        refreshBtn.setAccessibilityLabel("刷新 Token 统计")
        refreshBtn.isEnabled = !actions.tokenStatsLoading
        let refreshW: CGFloat = 62
        refreshBtn.frame = NSRect(x: form.width - 14 - refreshW, y: 9, width: refreshW, height: 26)
        filterCard.addSubview(refreshBtn)
        tokenRefreshButton = refreshBtn

        let scopeControl = segments(TokenStatsToolScope.allCases.map(\.title), id: "settings-token-scope", action: #selector(changeTokenScope(_:)))
        scopeControl.setAccessibilityLabel("Token 统计工具范围")
        scopeControl.selectedSegment = TokenStatsToolScope.allCases.firstIndex(of: scope) ?? 0
        let scopeW: CGFloat = min(158, max(124, form.width - 14 - refreshW - 6 - 84))
        scopeControl.frame = NSRect(x: refreshBtn.frame.minX - 6 - scopeW, y: 10, width: scopeW, height: 24)
        filterCard.addSubview(scopeControl)
        tokenScopeControl = scopeControl

        rule(in: filterCard, y: 44)

        let rangeTitle = text("时间窗口", size: 13, weight: .medium)
        rangeTitle.frame = NSRect(x: 14, y: 57, width: 64, height: 18)
        filterCard.addSubview(rangeTitle)

        let rangeControl = segments(TokenStatsTimeRange.allCases.map(\.title), id: "settings-token-range", action: #selector(changeTokenRange(_:)))
        rangeControl.setAccessibilityLabel("Token 统计时间窗口")
        rangeControl.selectedSegment = TokenStatsTimeRange.allCases.firstIndex(of: range) ?? 2
        let rangeW: CGFloat = min(236, max(196, form.width - 96))
        rangeControl.frame = NSRect(x: form.width - 14 - rangeW, y: 54, width: rangeW, height: 24)
        filterCard.addSubview(rangeControl)
        tokenRangeControl = rangeControl

        // 2. Overview KPIs & Token Mix Bar
        var y = section("总览与构成", x: form.x, width: form.width, at: filterCard.frame.maxY + 18)

        let gap: CGFloat = 8
        let tileW = floor((form.width - 24 - gap) / 2)
        let tileH: CGFloat = 62
        let cacheReadSub = report.cacheHitPercent.map { String(format: "命中率 %.1f%%", $0) } ?? "命中率 —"
        let inputSub = report.cacheWriteTokens > 0
            ? "含缓存写入 " + compactTokenCount(report.cacheWriteTokens)
            : "非缓存输入"
        let outputSub = report.totalTokens > 0
            ? String(format: "占总计 %.1f%%", report.outputTokens * 100 / report.totalTokens)
            : "模型生成输出"
        let sessionSub = report.sessionCount > 0
            ? "\(report.sessionCount) 个会话" + (report.archivedSessionCount > 0 ? "（归档 \(report.archivedSessionCount)）" : "")
            : "暂无会话"

        let tiles: [(title: String, value: Double, sub: String, tip: String)] = [
            ("总 Token", report.totalTokens, sessionSub, "总计 \(exactCount(report.totalTokens)) Token · \(sessionSub)"),
            ("缓存读取", report.cacheReadTokens, cacheReadSub, "缓存读取 \(exactCount(report.cacheReadTokens)) Token · \(cacheReadSub)"),
            ("输入 Token", report.combinedInputTokens, inputSub,
             "非缓存输入 \(exactCount(report.inputTokens)) + 缓存写入 \(exactCount(report.cacheWriteTokens))"),
            ("输出 Token", report.outputTokens, outputSub, "输出 \(exactCount(report.outputTokens)) Token · \(outputSub)"),
        ]

        var mixSegments: [(String, Double, NSColor)] = [
            ("输入", report.inputTokens, TokenStatsColors.input),
            ("缓存写入", report.cacheWriteTokens, TokenStatsColors.cacheWrite),
            ("缓存读取", report.cacheReadTokens, TokenStatsColors.cacheRead),
            ("输出", report.outputTokens, TokenStatsColors.output),
        ]
        if report.hostFallbackTokens > 0 {
            mixSegments.append(("宿主未拆分", report.hostFallbackTokens, TokenStatsColors.hostFallback))
        }
        let legendEntries = mixSegments.filter { seg in
            seg.0 == "输入" || seg.0 == "缓存读取" || seg.0 == "输出" || seg.1 > 0
        }
        let legendRows = Int(ceil(Double(legendEntries.count) / 2.0))
        let mixBarY = 12 + tileH * 2 + gap + 14
        let overviewHeight = mixBarY + 10 + 12 + CGFloat(legendRows) * 20 + 12
        let overviewCard = card(x: form.x, width: form.width, at: y, height: overviewHeight)

        for (index, item) in tiles.enumerated() {
            let col = index % 2
            let row = index / 2
            let tx = 12 + CGFloat(col) * (tileW + gap)
            let ty = 12 + CGFloat(row) * (tileH + gap)
            let tile = SettingsSurface(frame: NSRect(x: tx, y: ty, width: tileW, height: tileH))
            tile.fill = SettingsPalette.stageFill
            tile.radius = 8
            tile.toolTip = item.tip
            overviewCard.addSubview(tile)

            let titleLbl = text(item.title, size: 11, weight: .medium, color: SettingsPalette.secondary)
            titleLbl.frame = NSRect(x: 10, y: 7, width: tileW - 20, height: 14)
            tile.addSubview(titleLbl)

            let valLbl = text(compactTokenCount(item.value), size: 18, weight: .bold)
            valLbl.font = .monospacedDigitSystemFont(ofSize: 18, weight: .bold)
            valLbl.maximumNumberOfLines = 1
            valLbl.lineBreakMode = .byTruncatingTail
            valLbl.cell?.usesSingleLineMode = true
            valLbl.frame = NSRect(x: 10, y: 22, width: tileW - 20, height: 22)
            tile.addSubview(valLbl)

            let subLbl = text(item.sub, size: 11, color: SettingsPalette.secondary)
            subLbl.maximumNumberOfLines = 1
            subLbl.lineBreakMode = .byTruncatingTail
            subLbl.cell?.usesSingleLineMode = true
            subLbl.frame = NSRect(x: 10, y: 44, width: tileW - 20, height: 14)
            tile.addSubview(subLbl)
        }

        let mixBar = TokenMixBarView(frame: NSRect(x: 12, y: mixBarY, width: form.width - 24, height: 10))
        mixBar.segments = mixSegments
        mixBar.total = report.totalTokens
        overviewCard.addSubview(mixBar)

        let legendTop = mixBarY + 20
        let legendColW = floor((form.width - 24 - 10) / 2)
        for (idx, seg) in legendEntries.enumerated() {
            let col = idx % 2
            let row = idx / 2
            let lx = 12 + CGFloat(col) * (legendColW + 10)
            let ly = legendTop + CGFloat(row) * 20
            let dot = SettingsSurface(frame: NSRect(x: lx, y: ly + 4, width: 8, height: 8))
            dot.fill = seg.2
            dot.radius = 4
            overviewCard.addSubview(dot)

            let pct = report.totalTokens > 0 ? String(format: "%.1f%%", seg.1 * 100 / report.totalTokens) : "0%"
            let legendText = text("\(seg.0) \(compactTokenCount(seg.1)) · \(pct)", size: 11, color: SettingsPalette.secondary)
            legendText.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            legendText.maximumNumberOfLines = 1
            legendText.lineBreakMode = .byTruncatingTail
            legendText.cell?.usesSingleLineMode = true
            legendText.frame = NSRect(x: lx + 13, y: ly + 1, width: legendColW - 13, height: 16)
            legendText.toolTip = "\(seg.0)：\(exactCount(seg.1)) Token（\(pct)）"
            overviewCard.addSubview(legendText)
        }

        // 3. Trend Chart Card
        y = section("用量趋势", x: form.x, width: form.width, at: overviewCard.frame.maxY + 18)
        let chartCard = card(x: form.x, width: form.width, at: y, height: 194)

        let trendLabel = text(report.trendTitle, size: 12.5, weight: .semibold)
        trendLabel.frame = NSRect(x: 14, y: 11, width: form.width - 28, height: 16)
        chartCard.addSubview(trendLabel)

        let avgPart = report.averagePerDayTokens.map { "日均 " + compactTokenCount($0) + " · " } ?? ""
        defaultTokenSummaryText = report.peakBucketTokens > 0
            ? avgPart + "峰值 " + compactTokenCount(report.peakBucketTokens) + (report.peakBucketLabel.map { "（\($0)）" } ?? "")
            : "暂无可绘制的近期趋势"

        let summaryLabel = text(defaultTokenSummaryText, size: 11, color: SettingsPalette.secondary)
        summaryLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        summaryLabel.maximumNumberOfLines = 1
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.cell?.usesSingleLineMode = true
        summaryLabel.identifier = NSUserInterfaceItemIdentifier("settings-token-chart-summary")
        summaryLabel.frame = NSRect(x: 14, y: 29, width: form.width - 28, height: 15)
        chartCard.addSubview(summaryLabel)
        tokenChartSummaryLabel = summaryLabel

        let chartView = TokenTrendChartView(frame: NSRect(x: 14, y: 50, width: form.width - 28, height: 134))
        chartView.identifier = NSUserInterfaceItemIdentifier("settings-token-chart")
        chartView.buckets = report.buckets
        chartView.axisIndices = report.axisIndices
        chartView.peakTokens = report.peakBucketTokens
        chartView.onInspectBucket = { [weak self] bucket in
            guard let self else { return }
            if let bucket {
                var detail = "\(bucket.detailTitle) · 总计 \(compactTokenCount(bucket.totalTokens))"
                if bucket.hostFallback >= bucket.totalTokens && bucket.totalTokens > 0 {
                    detail += "（宿主计数）"
                } else {
                    detail += "（入 \(compactTokenCount(bucket.combinedInput)) · 缓存 \(compactTokenCount(bucket.cacheRead)) · 出 \(compactTokenCount(bucket.output))）"
                }
                self.tokenChartSummaryLabel?.stringValue = detail
                self.tokenChartSummaryLabel?.toolTip = "\(bucket.detailTitle)\n总计：\(exactCount(bucket.totalTokens))"
            } else {
                self.tokenChartSummaryLabel?.stringValue = self.defaultTokenSummaryText
                self.tokenChartSummaryLabel?.toolTip = nil
            }
        }
        chartCard.addSubview(chartView)

        // 4. Multi-Dimensional Breakdown Card
        y = chartCard.frame.maxY + 18
        let breakdownHeader = text("明细排行", size: 12.5, weight: .semibold, color: SettingsPalette.secondary)
        breakdownHeader.frame = NSRect(x: form.x + 4, y: y + 3, width: max(60, form.width - 200), height: 18)
        pageBody.addSubview(breakdownHeader)

        let dimControl = segments(TokenStatsDimension.allCases.map(\.title), id: "settings-token-dimension", action: #selector(changeTokenDimension(_:)))
        dimControl.setAccessibilityLabel("Token 明细维度")
        dimControl.selectedSegment = TokenStatsDimension.allCases.firstIndex(of: dimension) ?? 0
        let dimW: CGFloat = min(192, max(168, form.width - 78))
        dimControl.frame = NSRect(x: form.x + form.width - dimW, y: y, width: dimW, height: 24)
        pageBody.addSubview(dimControl)
        tokenDimensionControl = dimControl

        y += 30
        let allRows: [TokenBreakdownRow]
        switch dimension {
        case .models: allRows = report.models
        case .projects: allRows = report.projects
        case .sessions: allRows = report.sessions
        }
        let displayed = Array(allRows.prefix(50))
        let hasOverflow = allRows.count > displayed.count

        if displayed.isEmpty {
            let emptyCard = card(x: form.x, width: form.width, at: y, height: 56)
            let emptyLbl = text(
                actions.tokenStatsLoading ? "正在扫描本机历史日志…" : "所选范围内暂无可展示的明细记录",
                size: 12, color: SettingsPalette.secondary)
            emptyLbl.alignment = .center
            emptyLbl.frame = NSRect(x: 16, y: 19, width: form.width - 32, height: 18)
            emptyCard.addSubview(emptyLbl)
            y = emptyCard.frame.maxY
        } else {
            let rowHeight: CGFloat = 58
            let overflowHeight: CGFloat = hasOverflow ? 32 : 0
            let totalH = CGFloat(displayed.count) * rowHeight + CGFloat(max(0, displayed.count - 1)) * 0.5 + overflowHeight
            let listCard = card(x: form.x, width: form.width, at: y, height: totalH)
            var rowY: CGFloat = 0

            for (index, item) in displayed.enumerated() {
                if index > 0 {
                    rule(in: listCard, y: rowY)
                    rowY += 0.5
                }
                let rowView = SettingsSurface(frame: NSRect(x: 0, y: rowY, width: form.width, height: rowHeight))
                rowView.fill = .clear
                let exactTip = item.toolTip + "\n总计 \(exactCount(item.totalTokens))（输入 \(exactCount(item.combinedInput)) · 缓存读 \(exactCount(item.cacheRead)) · 输出 \(exactCount(item.output))）"
                rowView.toolTip = exactTip
                listCard.addSubview(rowView)

                let rightText = compactTokenCount(item.totalTokens) + String(format: " · %.1f%%", item.share * 100)
                let rightLbl = text(rightText, size: 12, weight: .semibold)
                rightLbl.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
                rightLbl.alignment = .right
                let rightW = ceil((rightText as NSString).size(withAttributes: [.font: rightLbl.font!]).width) + 6
                rightLbl.frame = NSRect(x: form.width - 14 - rightW, y: 9, width: rightW, height: 16)
                rowView.addSubview(rightLbl)

                var badgeW: CGFloat = 0
                var badgePill: SettingsSurface?
                if let badge = item.badge, !badge.isEmpty {
                    let badgeFont = NSFont.systemFont(ofSize: 10, weight: .medium)
                    let textW = ceil((badge as NSString).size(withAttributes: [.font: badgeFont]).width)
                    badgeW = textW + 10
                    let pill = SettingsSurface()
                    pill.fill = SettingsPalette.stageFill
                    pill.radius = 4
                    let badgeLbl = text(badge, size: 10, weight: .medium, color: SettingsPalette.secondary)
                    badgeLbl.alignment = .center
                    badgeLbl.frame = NSRect(x: 0, y: 1, width: badgeW, height: 14)
                    pill.addSubview(badgeLbl)
                    badgePill = pill
                }

                let maxTitleW = max(60, form.width - 28 - rightW - (badgeW > 0 ? badgeW + 6 : 0) - 8)
                let titleStr = SessionTitle.singleLine(item.title)
                let titleLbl = text(titleStr, size: 12.5, weight: .medium)
                titleLbl.maximumNumberOfLines = 1
                titleLbl.lineBreakMode = .byTruncatingTail
                titleLbl.cell?.usesSingleLineMode = true
                let naturalTitleW = ceil((titleStr as NSString).size(withAttributes: [.font: titleLbl.font!]).width)
                let titleW = min(maxTitleW, naturalTitleW + 2)
                titleLbl.frame = NSRect(x: 14, y: 9, width: titleW, height: 16)
                rowView.addSubview(titleLbl)

                if let badgePill {
                    badgePill.frame = NSRect(x: 14 + titleW + 6, y: 9, width: badgeW, height: 16)
                    rowView.addSubview(badgePill)
                }

                let barView = TokenBreakdownBarView(frame: NSRect(x: 14, y: 29, width: form.width - 28, height: 4))
                barView.share = item.share
                barView.isHostFallback = !item.hasBreakdown
                rowView.addSubview(barView)

                let detailStr: String
                if item.hasBreakdown {
                    let hitSuffix = item.cacheHitPercent.map { String(format: " · 命中 %.0f%%", $0) } ?? ""
                    detailStr = "入 \(compactTokenCount(item.combinedInput)) · 缓存读 \(compactTokenCount(item.cacheRead)) · 出 \(compactTokenCount(item.output))" + hitSuffix
                } else {
                    detailStr = "宿主本机计数（无分项拆分）"
                }
                let detailLbl = text(detailStr, size: 11, color: SettingsPalette.secondary)
                detailLbl.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                detailLbl.maximumNumberOfLines = 1
                detailLbl.lineBreakMode = .byTruncatingTail
                detailLbl.cell?.usesSingleLineMode = true
                detailLbl.frame = NSRect(x: 14, y: 37, width: form.width - 28, height: 15)
                rowView.addSubview(detailLbl)

                rowY += rowHeight
            }

            if hasOverflow {
                rule(in: listCard, y: rowY)
                let note = text("仅展示前 50 项（共 \(allRows.count) 项，其余已计入上方总览）", size: 11, color: SettingsPalette.secondary)
                note.alignment = .center
                note.frame = NSRect(x: 14, y: rowY + 8, width: form.width - 28, height: 16)
                listCard.addSubview(note)
            }
            y = listCard.frame.maxY
        }

        // 5. Coverage Footnotes
        var footnoteY = y + 10
        for note in report.coverageNotes {
            footnoteY = addFootnote(note, x: form.x, width: form.width, at: footnoteY)
        }
        bodyHeight = footnoteY + 24
    }

    private func buildSessions(query: String) {
        let form = formMetrics()
        var y = section("会话", x: form.x, width: form.width, at: 18)

        let mode = NSPopUpButton(frame: .zero, pullsDown: false)
        let automatic = actions?.provider.supportsAutomaticSessionFollow ?? true
        var modeItems = [("最近活跃会话", "__recent__"), ("固定会话", "__manual__")]
        if automatic { modeItems.insert(("自动跟随当前对话", "__current__"), at: 0) }
        for (title, id) in modeItems {
            mode.addItem(withTitle: title)
            mode.lastItem?.representedObject = id
        }
        mode.autoenablesItems = false
        mode.target = self; mode.action = #selector(changeSessionMode(_:))
        mode.identifier = NSUserInterfaceItemIdentifier("settings-session-mode")
        mode.setAccessibilityLabel("统计会话来源")
        sessionMode = mode

        let sourceWidth: CGFloat = min(194, max(160, form.width * 0.38))
        let strategyCard = addFormCard([
            FormRowSpec("会话来源", symbol: "bubble.left.and.bubble.right", tint: .systemIndigo, control: mode, controlWidth: sourceWidth, controlHeight: 26),
            FormRowSpec("当前对话", keepNote: true, symbol: "waveform.path.ecg", tint: .systemBlue),
        ], x: form.x, width: form.width, at: y)
        let currentNote = strategyCard.notes[0]
        currentNote.maximumNumberOfLines = 1
        currentNote.lineBreakMode = .byTruncatingTail
        currentNote.cell?.usesSingleLineMode = true
        currentNote.cell?.wraps = false
        sessionNote = currentNote

        y = section("固定会话", x: form.x, width: form.width, at: strategyCard.nextY + 20)
        let project = NSPopUpButton(frame: .zero, pullsDown: false)
        project.target = self; project.action = #selector(changeProject(_:))
        project.identifier = NSUserInterfaceItemIdentifier("settings-project-filter")
        project.setAccessibilityLabel("选择项目")
        projectMode = project

        let projectWidth = min(210, max(150, form.width - 180))
        let browseCard = card(x: form.x, width: form.width, at: y, height: 294)
        let projectTitle = text("项目", size: 13, weight: .medium)
        projectTitle.frame = NSRect(x: 16, y: 15, width: 80, height: 18)
        browseCard.addSubview(projectTitle)
        project.frame = NSRect(x: form.width - 16 - projectWidth, y: 11, width: projectWidth, height: 26)
        browseCard.addSubview(project)
        rule(in: browseCard, y: 48)

        let field = NSSearchField(frame: NSRect(x: 14, y: 58, width: form.width - 28, height: 28))
        field.placeholderString = "搜索对话"
        field.stringValue = query
        field.delegate = self
        field.identifier = NSUserInterfaceItemIdentifier("settings-search")
        field.setAccessibilityLabel("搜索固定会话")
        field.sendsSearchStringImmediately = true
        browseCard.addSubview(field)
        search = field

        let tableScroll = NSScrollView(frame: NSRect(x: 14, y: 96, width: form.width - 28, height: 184))
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.drawsBackground = false
        tableScroll.borderType = .noBorder
        tableScroll.wantsLayer = true
        tableScroll.layer?.cornerRadius = 8
        tableScroll.layer?.masksToBounds = true
        tableScroll.layer?.borderWidth = 0.5
        tableScroll.layer?.borderColor = SettingsPalette.divider.cgColor

        let list = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.width = max(120, form.width - 48)
        column.resizingMask = .autoresizingMask
        list.addTableColumn(column)
        list.headerView = nil
        list.rowHeight = 34
        list.style = .inset
        list.backgroundColor = .clear
        list.usesAlternatingRowBackgroundColors = false
        list.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        list.allowsEmptySelection = true
        list.allowsMultipleSelection = false
        list.delegate = self
        list.dataSource = self
        list.identifier = NSUserInterfaceItemIdentifier("settings-session-list")
        list.setAccessibilityLabel("固定会话列表")
        tableScroll.documentView = list
        browseCard.addSubview(tableScroll)
        table = list

        let empty = text("", size: 12, color: SettingsPalette.secondary)
        empty.alignment = .center
        empty.frame = NSRect(x: 28, y: 174, width: form.width - 56, height: 32)
        browseCard.addSubview(empty)
        emptyNote = empty

        y = section("权限", x: form.x, width: form.width, at: y + browseCard.frame.height + 20)
        let button = actionButton("系统设置…", action: #selector(openPermissions))
        button.identifier = NSUserInterfaceItemIdentifier("settings-permission")
        permissionButton = button
        let revealButton = actionButton("在访达中定位", action: #selector(revealApp))
        revealButton.identifier = NSUserInterfaceItemIdentifier("settings-reveal-app")
        let syncButton = actionButton("重新同步", action: #selector(syncKimi))
        syncButton.identifier = NSUserInterfaceItemIdentifier("settings-sync-kimi")
        let permissionCard = addFormCard([
            FormRowSpec("辅助功能权限", keepNote: true, symbol: "accessibility", tint: .systemPurple, control: button, controlWidth: 112, controlHeight: 26),
            FormRowSpec("应用包位置", "点击定位便于拖入辅助功能列表。", symbol: "app.badge.checkmark", tint: .systemBlue, control: revealButton, controlWidth: 112, controlHeight: 26),
            FormRowSpec("Kimi 生命周期联动", keepNote: true, symbol: "link.circle.fill", tint: .systemTeal, control: syncButton, controlWidth: 96, controlHeight: 26),
        ], x: form.x, width: form.width, at: y)
        permissionNote = permissionCard.notes[0]
        kimiStatusNote = permissionCard.notes[1]

        bodyHeight = permissionCard.nextY + 24
        sessionSignature = ""
    }

    private func buildHelp() {
        guard let actions else { return }
        let form = formMetrics()
        let categories = HelpDocs.categories(for: actions.provider)
        // Rebuilding the page (resize, tool switch) must not drop what the user reads.
        let chosen = helpCategoryControl?.selectedItem?.representedObject as? String
        helpCategoryControl?.removeAllItems()
        for category in categories {
            helpCategoryControl?.addItem(withTitle: category.title)
            helpCategoryControl?.lastItem?.representedObject = category.id
        }
        if !categories.isEmpty {
            helpCategoryControl?.selectItem(at: chosen.flatMap { id in categories.firstIndex { $0.id == id } } ?? 0)
        }
        let contentTop: CGFloat = 16
        let content = HUDHelpContentView(width: form.width, categories: categories) { [weak self] id in
            self?.scrollHelpCategory(id)
        }
        content.frame.origin = NSPoint(x: form.x, y: contentTop)
        pageBody.addSubview(content)
        let naturalHeight = contentTop + content.frame.height + 24
        let maxHeaderTop = contentTop + (content.categoryOffsets.values.max() ?? 0)
        // Leave enough trailing space so even the last category header aligns cleanly to the top.
        bodyHeight = max(naturalHeight, maxHeaderTop + scroll.contentSize.height + 16)
    }

    func scrollHelpCategory(_ id: String) {
        guard let actions, let content = pageBody.subviews.compactMap({ $0 as? HUDHelpContentView }).first else { return }
        let categories = HelpDocs.categories(for: actions.provider)
        guard let target = categories.firstIndex(where: { $0.id == id }) else { return }
        // The category picker shows what the page is actually scrolled to, including
        // when the menu bar opened the page for one specific category.
        helpCategoryControl?.selectItem(at: target)
        let headerOffset = content.categoryOffsets[id] ?? 0
        let offset = content.frame.minY + headerOffset
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(offset, max(0, bodyHeight - scroll.contentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func selectHelpCategory(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        scrollHelpCategory(id)
    }

    private func formattedUpdateTime(_ ms: Double) -> String {
        Self.updateTimeFormatter.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    private func updateSummaryText(for state: AppUpdateState, autoCheck: Bool) -> String {
        switch state {
        case .checking:
            return "正在检查新版本…"
        case .upToDate(let v, _):
            return "已是最新版本 v\(v)" + (autoCheck ? " · 已开启自动检查" : "")
        case .available(let rel, _):
            return "发现新版本 v\(rel.version)"
        case .downloading(let rel):
            return "正在后台下载 v\(rel.version)…"
        case .downloaded(let rel, let artifact):
            return artifact.canInstallInPlace ? "v\(rel.version) 已下载就绪，点击重启更新" : "v\(rel.version) 已下载安装包"
        case .installing(let rel):
            return "正在安装 v\(rel.version)…"
        case .failed(let msg, _):
            return msg
        case .idle(let last):
            if let last {
                return "上次检查：" + formattedUpdateTime(last)
            }
            return autoCheck ? "已开启自动检查（每 12 小时）" : "未开启自动检查"
        }
    }

    private func buildAbout() {
        guard let actions else { return }
        let form = formMetrics()
        let version = (Product.appInfo["CFBundleShortVersionString"] as? String)
            ?? (Product.developmentManifest["version"] as? String) ?? "开发版本"
        let build = (Product.appInfo["CFBundleVersion"] as? String)
            ?? (Product.developmentManifest["build"] as? String)
        let versionText = build.map { $0.isEmpty ? version : "\(version)（Build \($0)）" } ?? version

        let hero = card(x: form.x, width: form.width, at: 18, height: 78)
        let badge = SettingsSurface(frame: NSRect(x: 16, y: 17, width: 44, height: 44))
        badge.fill = .systemBlue
        badge.radius = 11
        let symbol = NSImageView(frame: NSRect(x: 9, y: 9, width: 26, height: 26))
        symbol.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: nil)
        symbol.imageScaling = .scaleProportionallyDown
        symbol.contentTintColor = .white
        badge.addSubview(symbol)
        hero.addSubview(badge)

        let title = text(Product.name, size: 17, weight: .semibold)
        title.frame = NSRect(x: 74, y: 17, width: form.width - 90, height: 22)
        hero.addSubview(title)

        let versionLabel = text(versionText, size: 12, color: SettingsPalette.secondary)
        versionLabel.frame = NSRect(x: 74, y: 42, width: form.width - 90, height: 18)
        hero.addSubview(versionLabel)

        let updateY = section("软件更新", x: form.x, width: form.width, at: 18 + hero.frame.height + 20)
        lastUpdateStateRendered = actions.updateState
        lastAutoCheckRendered = actions.autoCheckUpdates

        let statusTitle: String
        let statusDetail: String
        let buttonTitle: String
        let buttonEnabled: Bool
        let statusSymbol: String
        let statusTint: NSColor

        switch actions.updateState {
        case .idle(let last):
            statusTitle = "当前版本 v\(version)"
            statusDetail = last.map { "上次检查：" + formattedUpdateTime($0) } ?? "尚未检查更新"
            buttonTitle = "检查更新"
            buttonEnabled = true
            statusSymbol = "arrow.down.circle.fill"
            statusTint = .systemBlue
        case .checking:
            statusTitle = "正在检查更新…"
            statusDetail = "正在获取 GitHub Releases 最新版本信息"
            buttonTitle = "检查中…"
            buttonEnabled = false
            statusSymbol = "arrow.down.circle.fill"
            statusTint = .systemBlue
        case .upToDate(let v, let at):
            statusTitle = "已是最新版本"
            statusDetail = "当前 v\(v) · 检查于 " + formattedUpdateTime(at)
            buttonTitle = "检查更新"
            buttonEnabled = true
            statusSymbol = "checkmark.seal.fill"
            statusTint = .systemGreen
        case .available(let rel, _):
            statusTitle = "发现新版本 v\(rel.version)"
            statusDetail = rel.asset != nil ? "可下载 \(rel.asset!.name)" : "前往 GitHub Releases 获取安装包"
            buttonTitle = rel.asset != nil ? "立即下载" : "前往下载"
            buttonEnabled = true
            statusSymbol = "arrow.down.circle.fill"
            statusTint = .systemOrange
        case .downloading(let rel):
            statusTitle = "正在下载 v\(rel.version)…"
            statusDetail = "正在后台下载并校验 SHA-256 与代码签名"
            buttonTitle = "下载中…"
            buttonEnabled = false
            statusSymbol = "arrow.down.circle.fill"
            statusTint = .systemBlue
        case .downloaded(let rel, let artifact):
            if artifact.canInstallInPlace {
                statusTitle = "已就绪 · v\(rel.version)"
                statusDetail = "已完成签名校验，点击立即替换并重启应用"
                buttonTitle = "安装并重启"
                statusSymbol = "checkmark.seal.fill"
                statusTint = .systemGreen
            } else {
                statusTitle = "已下载安装包 · v\(rel.version)"
                statusDetail = artifact.statusDetail ?? "请在访达中查看并手动替换"
                buttonTitle = "在访达中查看"
                statusSymbol = "arrow.down.circle.fill"
                statusTint = .systemOrange
            }
            buttonEnabled = true
        case .installing(let rel):
            statusTitle = "正在安装 v\(rel.version)…"
            statusDetail = "正在替换应用并准备重启"
            buttonTitle = "安装中…"
            buttonEnabled = false
            statusSymbol = "arrow.down.circle.fill"
            statusTint = .systemBlue
        case .failed(let msg, let rel):
            statusTitle = "更新检查失败"
            statusDetail = msg
            buttonTitle = rel?.asset != nil ? "重试下载" : "重试"
            buttonEnabled = true
            statusSymbol = "exclamationmark.triangle.fill"
            statusTint = .systemRed
        }

        let primaryBtn = actionButton(buttonTitle, action: #selector(triggerPrimaryUpdate))
        primaryBtn.identifier = NSUserInterfaceItemIdentifier("settings-update-primary")
        primaryBtn.isEnabled = buttonEnabled

        var updateRows: [FormRowSpec] = [
            FormRowSpec(statusTitle, statusDetail, symbol: statusSymbol, tint: statusTint, control: primaryBtn, controlWidth: 106, controlHeight: 26),
        ]
        if let release = actions.updateState.availableRelease {
            let notesBtn = actionButton("GitHub 查看…", action: #selector(openReleaseNotes))
            notesBtn.identifier = NSUserInterfaceItemIdentifier("settings-open-release-notes")
            updateRows.append(
                FormRowSpec("版本发行说明", "查看 v\(release.version) 完整更新内容。", symbol: "doc.text.fill", tint: .systemIndigo, control: notesBtn, controlWidth: 106, controlHeight: 26))
        }

        let autoCheck = NSSwitch()
        autoCheck.target = self; autoCheck.action = #selector(changeAutoCheckUpdates(_:))
        autoCheck.identifier = NSUserInterfaceItemIdentifier("settings-auto-check-updates")
        autoCheck.setAccessibilityLabel("自动检查更新")
        autoCheckUpdatesSwitch = autoCheck

        let autoDownload = NSSwitch()
        autoDownload.target = self; autoDownload.action = #selector(changeAutoDownloadUpdates(_:))
        autoDownload.identifier = NSUserInterfaceItemIdentifier("settings-auto-download-updates")
        autoDownload.setAccessibilityLabel("自动下载更新")
        autoDownloadUpdatesSwitch = autoDownload

        updateRows.append(
            FormRowSpec("自动检查更新", "启动及后台运行时每 12 小时自动检查新版本。", symbol: "clock.arrow.circlepath", tint: .systemTeal, control: autoCheck, controlWidth: 44, controlHeight: 24))
        updateRows.append(
            FormRowSpec("自动下载更新", "发现新版本后自动在后台下载并校验安装包。", symbol: "tray.and.arrow.down.fill", tint: .systemBlue, control: autoDownload, controlWidth: 44, controlHeight: 24))

        let updateCard = addFormCard(updateRows, x: form.x, width: form.width, at: updateY)

        let sectionY = section("数据", x: form.x, width: form.width, at: updateCard.nextY + 20)
        let openButton = actionButton("在访达中打开", action: #selector(openFolder))
        let storageCard = addFormCard([
            FormRowSpec("本地支持目录", symbol: "folder", tint: .systemBlue, control: openButton, controlWidth: 118, controlHeight: 26),
        ], x: form.x, width: form.width, at: sectionY)

        let maintenanceY = section("维护", x: form.x, width: form.width, at: storageCard.nextY + 20)
        let onboardingButton = actionButton("打开向导…", action: #selector(openOnboarding))
        onboardingButton.identifier = NSUserInterfaceItemIdentifier("settings-open-onboarding")
        let uninstallButton = actionButton("卸载 \(Product.name)…", action: #selector(uninstallApplication))
        uninstallButton.identifier = NSUserInterfaceItemIdentifier("settings-uninstall")
        let maintenanceCard = addFormCard([
            FormRowSpec("欢迎向导", "重新查看开箱配置与辅助功能引导。", symbol: "sparkles", tint: .systemIndigo, control: onboardingButton, controlWidth: 108, controlHeight: 26),
            FormRowSpec("卸载应用", "移除登录项、Kimi 插件登记并将应用移至废纸篓，保留宿主数据。", symbol: "trash", tint: .systemRed, control: uninstallButton, controlWidth: 132, controlHeight: 26),
        ], x: form.x, width: form.width, at: maintenanceY)

        let endY = addFootnote("本机离线统计 · MIT 开源许可", x: form.x, width: form.width, at: maintenanceCard.nextY + 10)
        bodyHeight = endY + 24
    }

    /// Update values in place so incoming metrics never steal focus from the search field.
    func refresh() {
        guard let actions, !updating else { return }
        // Metrics updates reach every open collector pass. Rebuild the visible page
        // only; windowDidBecomeKey covers a window that is opened again.
        guard presenting || window?.isVisible == true else { return }
        if page == .metrics, moduleSignature != actions.modules { rebuildPage(); return }
        if page == .tokenStats {
            let report = actions.tokenStatsReport()
            if lastTokenReport != report || lastTokenDimension != actions.tokenStatsDimension
                || lastTokenLoading != actions.tokenStatsLoading
            {
                rebuildPage()
                return
            }
        }
        if page == .general,
           lastAuthorizedInGeneral != actions.isAccessibilityAuthorized
            || lastDisplayModeInGeneral != actions.displayMode
            || lastUpdateStateRendered != actions.updateState
            || lastAutoCheckRendered != actions.autoCheckUpdates
        {
            rebuildPage()
            return
        }
        if page == .about,
           lastUpdateStateRendered != actions.updateState
            || lastAutoCheckRendered != actions.autoCheckUpdates
        {
            rebuildPage()
            return
        }
        updating = true
        defer { updating = false }

        providerControl?.selectItem(at: actions.followsActiveTool ? 0 : (StatsProvider.allCases.firstIndex(of: actions.provider) ?? 0) + 1)
        providerControl?.item(at: 0)?.title = "跟随当前工具 · " + actions.provider.shortName

        displayControl?.selectedSegment = actions.displayMode == .floating ? 0 : 1
        visibilityControl?.state = actions.hudHidden ? .off : .on
        visibilityControl?.isEnabled = actions.displayMode == .floating
        visibilityControl?.toolTip = actions.displayMode == .floating ? "显示已识别主窗口上的悬浮条" : "菜单栏模式下不显示悬浮条。"
        idleSinkControl?.state = actions.hudIdleSink ? .on : .off
        idleSinkControl?.isEnabled = actions.displayMode == .floating
        statusItemControl?.state = actions.statusItemHidden ? .on : .off
        statusItemControl?.isEnabled = actions.displayMode == .floating
        statusItemControl?.toolTip = actions.displayMode == .floating ? "悬浮条模式下可隐藏菜单栏图标" : "菜单栏模式下必须显示图标。"
        followToolControl?.state = actions.followsActiveTool ? .on : .off
        launchAtLoginControl?.state = actions.isLaunchAtLoginEnabled ? .on : .off
        kimiStatusNote?.stringValue = actions.kimiPluginStatusText

        preview?.stringValue = actions.modules.isEmpty
            ? "暂无指标"
            : actions.modules.map { actions.metricTitle($0.metric) }.joined(separator: "   ·   ")
        preview?.toolTip = preview?.stringValue

        if let project = projectMode {
            let items = [("选择项目", "all")] + actions.projectGroups.map { (identifier($0["title"]), identifier($0["id"])) }
            if project.itemArray.map({ ($0.representedObject as? String ?? "") + "\u{1f}" + $0.title }) != items.map({ $0.1 + "\u{1f}" + $0.0 }) {
                project.removeAllItems()
                for (title, id) in items {
                    project.addItem(withTitle: title)
                    project.lastItem?.representedObject = id
                    project.lastItem?.toolTip = title
                }
            }
            if let index = project.itemArray.firstIndex(where: { $0.representedObject as? String == actions.selectedProject }) {
                project.selectItem(at: index)
            } else {
                project.selectItem(at: 0)
                actions.browseProject("all")
            }
        }

        if let mode = sessionMode {
            let choice = SessionSelectionMode.resolve(actions.selected, provider: actions.activeProvider)
            // Without an automatic entry, recent activity and the fixed choice move up
            // one position; selecting beyond the list would leave the control blank.
            let automatic = actions.provider.supportsAutomaticSessionFollow
            let recentIndex = automatic ? 1 : 0, manualIndex = automatic ? 2 : 1
            let selection = choice == .automatic ? 0 : (choice == .recent ? recentIndex : manualIndex)
            mode.selectItem(at: min(max(0, selection), max(0, mode.numberOfItems - 1)))
            let unavailable = !actions.canFollowCurrentConversation
            // Only the automatic entry is renamed; a tool without one has recent
            // activity in the first position.
            if let automaticItem = mode.itemArray.first(where: { $0.representedObject as? String == "__current__" }) {
                automaticItem.isEnabled = !unavailable
                automaticItem.title = unavailable ? "自动跟随（宿主暂不支持）" : "自动跟随当前对话"
            }
            let currentText = choosingFixedSession
                ? "请在下方选择对话"
                : (actions.scopeText.isEmpty ? "等待数据…" : actions.scopeText)
            sessionNote?.stringValue = currentText
            sessionNote?.toolTip = actions.scopeText
            refreshSessions()
        }

        let authorized = actions.isAccessibilityAuthorized
        permissionNote?.stringValue = authorized ? "已授权" : "未授权 · 悬浮条需要"
        permissionButton?.title = authorized ? "系统设置…" : "去授权…"

        tokenScopeControl?.selectedSegment = TokenStatsToolScope.allCases.firstIndex(of: actions.tokenStatsScope) ?? 0
        tokenRangeControl?.selectedSegment = TokenStatsTimeRange.allCases.firstIndex(of: actions.tokenStatsRange) ?? 2
        tokenDimensionControl?.selectedSegment = TokenStatsDimension.allCases.firstIndex(of: actions.tokenStatsDimension) ?? 0
        tokenRefreshButton?.title = actions.tokenStatsLoading ? "扫描…" : "刷新"
        tokenRefreshButton?.isEnabled = !actions.tokenStatsLoading

        autoCheckUpdatesSwitch?.state = actions.autoCheckUpdates ? .on : .off
        autoDownloadUpdatesSwitch?.state = actions.autoDownloadUpdates ? .on : .off
        autoDownloadUpdatesSwitch?.isEnabled = actions.autoCheckUpdates
    }

    private func refreshSessions() {
        guard let actions, let table else { return }
        let query = (search?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let choices = (actions.selectedProject == "all" ? [] : actions.conversationChoices(in: nil)).filter {
            query.isEmpty || SessionTitle.singleLine($0.title).localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
        let signature = choices.map { $0.id + "\u{1f}" + $0.title + "\u{1f}" + ($0.selected ? "1" : "0") }.joined(separator: "\u{1e}")
        if signature != sessionSignature || visibleSessions.count != choices.count {
            visibleSessions = Array(choices)
            sessionSignature = signature
            table.reloadData()
        }
        if let index = visibleSessions.firstIndex(where: { $0.id == actions.selected }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        emptyNote?.stringValue = actions.selectedProject == "all"
            ? "请先选择项目"
            : (query.isEmpty ? "暂无对话" : "无匹配对话")
        emptyNote?.isHidden = !visibleSessions.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleSessions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleSessions.indices.contains(row) else { return nil }
        let choice = visibleSessions[row]
        let cell = NSTableCellView()

        let checkMark = NSTextField(labelWithString: choice.selected ? "✓" : "")
        checkMark.font = .systemFont(ofSize: 12, weight: .semibold)
        checkMark.textColor = .controlAccentColor
        checkMark.alignment = .center
        checkMark.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(checkMark)

        let title = text(SessionTitle.singleLine(choice.title), size: 13)
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        title.cell?.usesSingleLineMode = true
        title.cell?.wraps = false
        title.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(title)
        cell.textField = title

        NSLayoutConstraint.activate([
            checkMark.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            checkMark.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            checkMark.widthAnchor.constraint(equalToConstant: 14),
            title.leadingAnchor.constraint(equalTo: checkMark.trailingAnchor, constant: 4),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            title.heightAnchor.constraint(equalToConstant: 20),
        ])
        cell.toolTip = choice.title
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, let table, visibleSessions.indices.contains(table.selectedRow), let actions else { return }
        choosingFixedSession = false
        actions.selectSession(visibleSessions[table.selectedRow].id)
        refresh()
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func providerDidChange() {
        choosingFixedSession = false
        search?.stringValue = ""
        sessionSignature = ""
        rebuildPage()
    }

    @objc private func changeProvider(_ sender: NSPopUpButton) {
        guard let actions, let value = sender.selectedItem?.representedObject as? String else { return }
        if value == "automatic" { actions.enableToolFollowing() }
        else if let provider = StatsProvider(rawValue: value) { actions.selectProvider(provider) }
        refresh()
    }

    @objc private func changeDisplay(_ sender: NSSegmentedControl) {
        actions?.setDisplayMode(sender.selectedSegment == 0 ? .floating : .menuBar)
        refresh()
    }

    @objc private func changeVisibility(_ sender: NSSwitch) {
        guard let actions, actions.displayMode == .floating else { return }
        if actions.hudHidden == (sender.state == .on) { actions.toggle() }
        refresh()
    }

    @objc private func changeIdleSink(_ sender: NSSwitch) {
        actions?.setHUDIdleSink(sender.state == .on)
        refresh()
    }

    @objc private func changeStatusItemHidden(_ sender: NSSwitch) {
        actions?.setStatusItemHidden(sender.state == .on)
        refresh()
    }

    @objc private func changeFollowTool(_ sender: NSSwitch) {
        guard let actions else { return }
        if sender.state == .on {
            actions.enableToolFollowing()
        } else {
            actions.selectProvider(actions.provider)
        }
        refresh()
    }

    @objc private func changeProject(_ sender: NSPopUpButton) {
        guard let actions, let id = sender.selectedItem?.representedObject as? String else { return }
        actions.browseProject(id)
        choosingFixedSession = true
        search?.stringValue = ""
        refresh()
    }

    @objc private func changeSessionMode(_ sender: NSPopUpButton) {
        guard let actions else { return }
        choosingFixedSession = sender.selectedItem?.representedObject as? String == "__manual__"
        if choosingFixedSession {
            refresh()
            window?.makeFirstResponder(search)
            return
        }
        switch sender.selectedItem?.representedObject as? String {
        case "__current__": actions.enableNativeFollowing()
        case "__recent__": actions.selectRecentSession()
        default: break
        }
        refresh()
    }

    @objc private func openPermissions() {
        if actions?.isAccessibilityAuthorized == true {
            actions?.openAccessibilitySettings()
        } else {
            actions?.authorizeWindowRecognition()
        }
    }
    @objc private func openFolder() { NSWorkspace.shared.open(Product.support) }
    @objc private func showHelpSettings() { actions?.showHelpSettings() }
    @objc private func changeLaunchAtLogin(_ sender: NSSwitch) {
        actions?.setLaunchAtLogin(sender.state == .on)
    }
    @objc private func relocateApplication() { actions?.relocateToApplications() }
    @objc private func revealApp() { actions?.revealAppInFinder() }
    @objc private func syncKimi() { actions?.syncKimiPlugin() }
    @objc private func openOnboarding() { actions?.showOnboarding() }
    @objc private func uninstallApplication() { actions?.confirmAndUninstall() }
    @objc private func changeTokenScope(_ sender: NSSegmentedControl) {
        let cases = TokenStatsToolScope.allCases
        guard cases.indices.contains(sender.selectedSegment) else { return }
        actions?.setTokenStatsScope(cases[sender.selectedSegment])
    }
    @objc private func changeTokenRange(_ sender: NSSegmentedControl) {
        let cases = TokenStatsTimeRange.allCases
        guard cases.indices.contains(sender.selectedSegment) else { return }
        actions?.setTokenStatsRange(cases[sender.selectedSegment])
    }
    @objc private func changeTokenDimension(_ sender: NSSegmentedControl) {
        let cases = TokenStatsDimension.allCases
        guard cases.indices.contains(sender.selectedSegment) else { return }
        actions?.setTokenStatsDimension(cases[sender.selectedSegment])
    }
    @objc private func refreshTokenStatsAction() {
        actions?.refreshTokenStats(force: true)
    }
    @objc private func openAboutAndCheckUpdates() {
        actions?.checkForUpdatesAndShowAbout()
    }
    @objc private func triggerPrimaryUpdate() {
        actions?.performPrimaryUpdateAction()
    }
    @objc private func openReleaseNotes() {
        actions?.openLatestReleasePage()
    }
    @objc private func changeAutoCheckUpdates(_ sender: NSSwitch) {
        actions?.setAutoCheckUpdates(sender.state == .on)
    }
    @objc private func changeAutoDownloadUpdates(_ sender: NSSwitch) {
        actions?.setAutoDownloadUpdates(sender.state == .on)
    }
}
