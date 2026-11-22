import AppKit
import StatsAdapters
import StatsCore

private final class OnboardingWindow: NSWindow {
  override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
  private weak var actions: StatsSettingsActions?
  private let root = SettingsSurface()
  private var launchSwitch: NSSwitch?
  private var kimiNote: NSTextField?
  private var lastAuthorized: Bool?
  private var lastInApps: Bool?

  init(actions: StatsSettingsActions) {
    self.actions = actions
    let window = OnboardingWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered, defer: false)
    super.init(window: window)
    window.title = "欢迎使用 \(Product.name)"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.level = .normal
    window.isOpaque = true
    window.backgroundColor = .windowBackgroundColor
    window.isMovableByWindowBackground = true
    window.delegate = self

    root.fill = .windowBackgroundColor
    window.contentView = root
    window.center()
    rebuild()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func present() {
    refresh()
    NSApp.activate(ignoringOtherApps: true)
    showWindow(nil)
    window?.center()
    window?.makeKeyAndOrderFront(nil)
  }

  func refresh() {
    guard let actions else { return }
    let authorized = actions.isAccessibilityAuthorized
    let inApps = actions.isInStandardApplicationsLocation
    if authorized != lastAuthorized || inApps != lastInApps {
      rebuild()
      return
    }
    launchSwitch?.state = actions.isLaunchAtLoginEnabled ? .on : .off
    kimiNote?.stringValue = "Kimi 生命周期联动：\(actions.kimiPluginStatusText)"
  }

  func windowWillClose(_ notification: Notification) {
    actions?.completeOnboarding(keepPendingUpgrade: !(actions?.isAccessibilityAuthorized ?? true))
  }

  private func label(
    _ value: String, size: CGFloat, weight: NSFont.Weight = .regular,
    color: NSColor = .labelColor
  ) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: value)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.drawsBackground = false
    field.isBezeled = false
    field.isEditable = false
    field.isSelectable = false
    return field
  }

  private func measure(_ value: String, width: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
    let probe = NSTextField(wrappingLabelWithString: value)
    probe.font = .systemFont(ofSize: size, weight: weight)
    return ceil(probe.sizeThatFits(NSSize(width: width, height: 1000)).height)
  }

  private func makeCard(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> SettingsSurface {
    let card = SettingsSurface(frame: NSRect(x: x, y: y, width: width, height: height))
    card.fill = SettingsPalette.cardFill
    card.borderColor = SettingsPalette.cardBorder
    card.borderWidth = 1
    card.radius = 12
    root.addSubview(card)
    return card
  }

  private func makeBadge(symbol: String, tint: NSColor, size: CGFloat = 28) -> SettingsSurface {
    let box = SettingsSurface(frame: NSRect(x: 0, y: 0, width: size, height: size))
    box.fill = tint.withAlphaComponent(0.14)
    box.radius = 8
    let iconSize = size - 10
    let icon = NSImageView(frame: NSRect(x: 5, y: 5, width: iconSize, height: iconSize))
    icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    icon.imageScaling = .scaleProportionallyDown
    icon.contentTintColor = tint
    box.addSubview(icon)
    return box
  }

  private func rebuild() {
    guard let actions, let window else { return }
    let width: CGFloat = 480
    let pad: CGFloat = 24
    let cardWidth = width - pad * 2

    root.subviews.forEach { $0.removeFromSuperview() }
    launchSwitch = nil
    kimiNote = nil

    let authorized = actions.isAccessibilityAuthorized
    let inApps = actions.isInStandardApplicationsLocation
    lastAuthorized = authorized
    lastInApps = inApps

    var y: CGFloat = 34

    let heroBadge = SettingsSurface(frame: NSRect(x: pad, y: y, width: 42, height: 42))
    heroBadge.fill = .systemBlue
    heroBadge.radius = 11
    let heroIcon = NSImageView(frame: NSRect(x: 8, y: 8, width: 26, height: 26))
    heroIcon.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: nil)
    heroIcon.imageScaling = .scaleProportionallyDown
    heroIcon.contentTintColor = .white
    heroBadge.addSubview(heroIcon)
    root.addSubview(heroBadge)

    let title = label("欢迎使用 \(Product.name)", size: 17, weight: .semibold)
    title.frame = NSRect(x: pad + 54, y: y + 1, width: cardWidth - 54, height: 22)
    root.addSubview(title)

    let subtitle = label("Codex 与 Kimi Code 本地实时会话统计", size: 12, color: SettingsPalette.secondary)
    subtitle.frame = NSRect(x: pad + 54, y: y + 23, width: cardWidth - 54, height: 18)
    root.addSubview(subtitle)
    y += 58

    if !inApps {
      let note = "当前运行于临时或下载目录。移至「应用程序」后才能稳定保存系统权限与自动启动。"
      let textW = cardWidth - 68
      let noteH = measure(note, width: textW, size: 11.5)
      let cardH = max(92, 14 + 18 + 4 + noteH + 10 + 26 + 14)
      let card = makeCard(x: pad, y: y, width: cardWidth, height: cardH)

      let badge = makeBadge(symbol: "arrow.down.app.fill", tint: .systemOrange)
      badge.frame.origin = NSPoint(x: 14, y: 14)
      card.addSubview(badge)

      let h = label("建议移至「应用程序」文件夹", size: 13, weight: .medium)
      h.frame = NSRect(x: 54, y: 14, width: textW, height: 18)
      card.addSubview(h)

      let body = label(note, size: 11.5, color: SettingsPalette.secondary)
      body.frame = NSRect(x: 54, y: 36, width: textW, height: noteH)
      card.addSubview(body)

      let moveButton = NSButton(title: "移至应用程序并重启", target: self, action: #selector(relocateTapped))
      moveButton.bezelStyle = .rounded
      moveButton.font = .systemFont(ofSize: 12)
      moveButton.identifier = NSUserInterfaceItemIdentifier("onboarding-relocate")
      let btnW = max(148, moveButton.fittingSize.width + 12)
      moveButton.frame = NSRect(x: 54, y: 36 + noteH + 8, width: btnW, height: 26)
      card.addSubview(moveButton)

      y += cardH + 12
    }

    // Card 1: Menu bar ready
    do {
      let note = "无需授予任何系统权限，点击右上角菜单栏仪表盘图标即可随时查看实时速率、Token 与子代理。"
      let textW = cardWidth - 68
      let noteH = measure(note, width: textW, size: 11.5)
      let cardH = max(68, 14 + 18 + 4 + noteH + 14)
      let card = makeCard(x: pad, y: y, width: cardWidth, height: cardH)

      let badge = makeBadge(symbol: "checkmark.circle.fill", tint: .systemGreen)
      badge.frame.origin = NSPoint(x: 14, y: floor((cardH - 28) / 2))
      card.addSubview(badge)

      let h = label("菜单栏实时统计已就绪", size: 13, weight: .medium)
      h.frame = NSRect(x: 54, y: 14, width: textW, height: 18)
      card.addSubview(h)

      let body = label(note, size: 11.5, color: SettingsPalette.secondary)
      body.frame = NSRect(x: 54, y: 36, width: textW, height: noteH)
      card.addSubview(body)

      y += cardH + 12
    }

    // Card 2: Accessibility & HUD upgrade
    do {
      let textW = cardWidth - 68
      if authorized {
        let note = "已自动切换为窗口顶部悬浮条，可在菜单栏或设置中随时调整展示模式。"
        let noteH = measure(note, width: textW, size: 11.5)
        let cardH = max(68, 14 + 18 + 4 + noteH + 14)
        let card = makeCard(x: pad, y: y, width: cardWidth, height: cardH)

        let badge = makeBadge(symbol: "checkmark.seal.fill", tint: .systemGreen)
        badge.frame.origin = NSPoint(x: 14, y: floor((cardH - 28) / 2))
        card.addSubview(badge)

        let h = label("辅助功能已授权 · 悬浮条已启用", size: 13, weight: .medium)
        h.frame = NSRect(x: 54, y: 14, width: textW, height: 18)
        card.addSubview(h)

        let body = label(note, size: 11.5, color: SettingsPalette.secondary)
        body.frame = NSRect(x: 54, y: 36, width: textW, height: noteH)
        card.addSubview(body)

        y += cardH + 12
      } else {
        let note = "在「系统设置 → 辅助功能」勾选 \(Product.name) 后，将自动升级为宿主窗口顶部悬浮条并跟随 Kimi 对话。"
        let noteH = measure(note, width: textW, size: 11.5)
        let cardH = max(100, 14 + 18 + 4 + noteH + 10 + 26 + 14)
        let card = makeCard(x: pad, y: y, width: cardWidth, height: cardH)

        let badge = makeBadge(symbol: "accessibility", tint: .systemIndigo)
        badge.frame.origin = NSPoint(x: 14, y: 14)
        card.addSubview(badge)

        let h = label("开启窗口顶部悬浮条（推荐）", size: 13, weight: .medium)
        h.frame = NSRect(x: 54, y: 14, width: textW, height: 18)
        card.addSubview(h)

        let body = label(note, size: 11.5, color: SettingsPalette.secondary)
        body.frame = NSRect(x: 54, y: 36, width: textW, height: noteH)
        card.addSubview(body)

        let btnY = 36 + noteH + 8
        let authBtn = NSButton(title: "前往授权…", target: self, action: #selector(authorizeTapped))
        authBtn.bezelStyle = .rounded
        authBtn.font = .systemFont(ofSize: 12)
        authBtn.identifier = NSUserInterfaceItemIdentifier("onboarding-authorize")
        let authW = max(96, authBtn.fittingSize.width + 10)
        authBtn.frame = NSRect(x: 54, y: btnY, width: authW, height: 26)
        card.addSubview(authBtn)

        let revealBtn = NSButton(title: "在访达中定位", target: self, action: #selector(revealTapped))
        revealBtn.bezelStyle = .rounded
        revealBtn.font = .systemFont(ofSize: 12)
        revealBtn.identifier = NSUserInterfaceItemIdentifier("onboarding-reveal")
        let revealW = max(108, revealBtn.fittingSize.width + 10)
        revealBtn.frame = NSRect(x: 54 + authW + 8, y: btnY, width: revealW, height: 26)
        card.addSubview(revealBtn)

        y += cardH + 12
      }
    }

    // Card 3: Launch at login & Kimi sync
    do {
      let switchControl = NSSwitch()
      switchControl.target = self
      switchControl.action = #selector(toggleLaunchAtLogin(_:))
      switchControl.state = actions.isLaunchAtLoginEnabled ? .on : .off
      switchControl.identifier = NSUserInterfaceItemIdentifier("onboarding-launch-at-login")
      switchControl.setAccessibilityLabel("开机自动启动")
      launchSwitch = switchControl

      let statusText = "Kimi 生命周期联动：\(actions.kimiPluginStatusText)"
      let textW = cardWidth - 116
      let noteH = measure(statusText, width: textW, size: 11.5)
      let cardH = max(62, 12 + 18 + 4 + noteH + 12)
      let card = makeCard(x: pad, y: y, width: cardWidth, height: cardH)

      let badge = makeBadge(symbol: "bolt.horizontal.circle.fill", tint: .systemTeal)
      badge.frame.origin = NSPoint(x: 14, y: floor((cardH - 28) / 2))
      card.addSubview(badge)

      let h = label("开机自动启动", size: 13, weight: .medium)
      h.frame = NSRect(x: 54, y: 12, width: textW, height: 18)
      card.addSubview(h)

      let body = label(statusText, size: 11.5, color: SettingsPalette.secondary)
      body.frame = NSRect(x: 54, y: 34, width: textW, height: noteH)
      card.addSubview(body)
      kimiNote = body

      switchControl.frame = NSRect(
        x: cardWidth - 16 - 44, y: floor((cardH - 24) / 2), width: 44, height: 24)
      card.addSubview(switchControl)

      y += cardH + 18
    }

    // Bottom button bar
    let footerHeight: CGFloat = 32
    if authorized {
      let primary = NSButton(title: "开始使用", target: self, action: #selector(finishTapped))
      primary.bezelStyle = .rounded
      primary.keyEquivalent = "\r"
      primary.identifier = NSUserInterfaceItemIdentifier("onboarding-primary")
      let w = max(112, primary.fittingSize.width + 18)
      primary.frame = NSRect(x: width - pad - w, y: y, width: w, height: footerHeight)
      root.addSubview(primary)
    } else {
      let primary = NSButton(title: "前往授权辅助功能…", target: self, action: #selector(authorizeTapped))
      primary.bezelStyle = .rounded
      primary.keyEquivalent = "\r"
      primary.identifier = NSUserInterfaceItemIdentifier("onboarding-primary")
      let pw = max(148, primary.fittingSize.width + 18)
      primary.frame = NSRect(x: width - pad - pw, y: y, width: pw, height: footerHeight)
      root.addSubview(primary)

      let later = NSButton(title: "先用菜单栏模式", target: self, action: #selector(laterTapped))
      later.bezelStyle = .rounded
      later.identifier = NSUserInterfaceItemIdentifier("onboarding-later")
      let lw = max(118, later.fittingSize.width + 16)
      later.frame = NSRect(x: width - pad - pw - 10 - lw, y: y, width: lw, height: footerHeight)
      root.addSubview(later)
    }

    let totalHeight = y + footerHeight + 22
    root.frame = NSRect(x: 0, y: 0, width: width, height: totalHeight)
    window.setContentSize(NSSize(width: width, height: totalHeight))
  }

  @objc private func relocateTapped() {
    actions?.relocateToApplications()
  }

  @objc private func authorizeTapped() {
    actions?.authorizeWindowRecognition()
  }

  @objc private func revealTapped() {
    actions?.revealAppInFinder()
  }

  @objc private func toggleLaunchAtLogin(_ sender: NSSwitch) {
    actions?.setLaunchAtLogin(sender.state == .on)
    refresh()
  }

  @objc private func laterTapped() {
    actions?.completeOnboarding(keepPendingUpgrade: true)
    close()
  }

  @objc private func finishTapped() {
    actions?.completeOnboarding(keepPendingUpgrade: false)
    close()
  }
}
