import AppKit

/// 面板，自上而下：
/// - 当前账号：身份与 5 小时 / 7 天两组额度（最常看的放最上面、最大）
/// - 账号：全部账号，点击或按字母键切换，右侧两个圆环是各自的 5 小时、7 天额度
/// - Token 用量：今天、7 天与近 14 天趋势
/// - 操作：添加账号、设置
///
/// 面板背景是半透明材质，文字只用一级、二级文字色，保证看得清。
@MainActor
final class PanelView: NSView {
    static let width: CGFloat = 268
    /// 内容边线：文字、图标都对齐到左右 14pt
    static let inset: CGFloat = 14
    /// 带底色的块（横幅、提示、行的悬停底色）比内容边线各宽出 8pt，里面的内容仍落在边线上
    static let bleed: CGFloat = 8
    /// 分隔线上下的留白
    private static let gap: CGFloat = 11

    private let kawari: Kawari
    private let more: NSMenu
    private let rowMenu: (Account) -> NSMenu
    private var banner: Banner?
    private let summary = Summary()
    private var rows: [AccountRow] = []
    private let usage = UsageView()
    private let footer = Footer()
    private var separators: [CGFloat] = []
    private var accountsTitle: CGFloat = 0
    private var ticker: Timer?
    var onResize: (NSSize) -> Void = { _ in }

    init(kawari: Kawari, menu: NSMenu, rowMenu: @escaping (Account) -> NSMenu) {
        self.kawari = kawari
        more = menu
        self.rowMenu = rowMenu
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: 100))
        self.menu = menu
        [summary, usage, footer].forEach(addSubview)
        footer.onAdd = { [unowned self] in add() }
        footer.onMore = { [unowned self] button in
            more.popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.maxY + 4), in: button)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// 面板打开期间每 30 秒刷新倒计时，关闭即停
    func show() {
        sync()
        ticker = .onMain(after: 30, every: 30, tolerance: 5) { [weak self] in self?.sync() }
    }

    func hide() {
        ticker?.invalidate()
        ticker = nil
    }

    func sync() {
        let accounts = kawari.accounts, now = kawari.now
        let active = kawari.active
        summary.update(active, letter: kawari.letter(active), limits: kawari.limits[active.key],
                       integrated: kawari.integrated, now: now)
        summary.contextMenu = { [unowned self] in rowMenu(active) }

        if rows.count != accounts.count {
            rows.forEach { $0.removeFromSuperview() }
            rows = accounts.map { _ in AccountRow() }
            rows.forEach(addSubview)
        }
        for (row, account) in zip(rows, accounts) {
            row.update(account, letter: kawari.letter(account), active: account.key == kawari.activeKey,
                       pending: kawari.pending == account.key, limits: kawari.limits[account.key], now: now)
            row.onClick = { [unowned self] in kawari.activate(account) }
            row.contextMenu = { [unowned self] in rowMenu(account) }
        }

        if kawari.integrated {
            banner?.removeFromSuperview()
            banner = nil
        } else if banner == nil {
            let banner = Banner()
            banner.onConnect = { [unowned self] in connect() }
            addSubview(banner)
            self.banner = banner
        }
        usage.update(kawari.totals)
        layoutPanel()
        needsDisplay = true
    }

    /// 各块的高度都是内容的实际高度，块之间统一用分隔线加上下 gap 隔开
    private func layoutPanel() {
        let width = Self.width, outer = Self.inset - Self.bleed
        var y: CGFloat = 12
        separators = []
        func separate() {
            separators.append(y + Self.gap)
            y += Self.gap * 2 + 1
        }

        if let banner {
            banner.frame = CGRect(x: outer, y: y - 4, width: width - outer * 2, height: Banner.height)
            y += Banner.height + 8
        }
        summary.frame = CGRect(x: 0, y: y, width: width, height: summary.height)
        y += summary.height
        separate()

        accountsTitle = y
        y += 21 - AccountRow.padding  // 与「Token 用量」一样，标题下 21pt 开始内容
        for row in rows {
            row.frame = CGRect(x: outer, y: y, width: width - outer * 2, height: AccountRow.height)
            y += AccountRow.height
        }
        y -= AccountRow.padding
        separate()

        usage.frame = CGRect(x: 0, y: y, width: width, height: UsageView.height)
        y += UsageView.height
        separate()

        // 按钮在操作栏里垂直居中，操作栏上下各留出与 gap 相当的空白
        footer.frame = CGRect(x: 0, y: y - Self.gap + 2, width: width, height: Footer.height)
        let size = CGSize(width: width, height: footer.frame.maxY)
        if frame.size != size {
            setFrameSize(size)
            onResize(size)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let hairline = 1 / (window?.backingScaleFactor ?? 2)
        NSColor.separatorColor.setFill()
        for y in separators { CGRect(x: Self.inset, y: y, width: bounds.width - Self.inset * 2, height: hairline).fill() }
        Text.section(String(localized: "账号"), at: CGPoint(x: Self.inset, y: accountsTitle))
    }

    private func add() {
        do { try kawari.addAccount() } catch { NSSound.beep() }
    }

    private func connect() {
        do {
            try kawari.setIntegrated(true)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = String(localized: "无法接入 Claude Code")
            alert.informativeText = error.localizedDescription + "\n\n" + String(localized: "kawari 已撤回这次的改动。")
            alert.runModal()
        }
    }

    /// 按账号字母（A、B、C…）或数字 1–9 直接切换
    override func keyDown(with event: NSEvent) {
        let key = (event.charactersIgnoringModifiers ?? "").uppercased()
        let index = Int(key).map { $0 - 1 } ?? kawari.accounts.firstIndex { kawari.letter($0) == key }
        if let index, kawari.accounts.indices.contains(index) {
            kawari.activate(kawari.accounts[index])
        } else {
            super.keyDown(with: event)
        }
    }
}

/// 额度颜色：平时强调色，超过 80% 橙色，超过 95% 红色
@MainActor
private func meterColor(_ used: Double, calm: NSColor = .controlAccentColor) -> NSColor {
    used >= 95 ? .systemRed : used >= 80 ? .systemOrange : calm
}

/// 账号字母：当前账号实心强调色，其余浅底深字；未登录是虚线框
@MainActor
private func drawBadge(_ letter: String, in rect: CGRect, active: Bool, signedIn: Bool, font: NSFont) {
    let radius = rect.width * 0.28
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let color: NSColor
    if !signedIn {
        shape.lineWidth = 1
        shape.setLineDash([2, 2], count: 2, phase: 0)
        NSColor.secondaryLabelColor.setStroke()
        shape.stroke()
        color = .secondaryLabelColor
    } else if active {
        NSColor.controlAccentColor.setFill()
        shape.fill()
        color = .white
    } else {
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        shape.fill()
        color = .labelColor
    }
    let size = (letter as NSString).size(withAttributes: [.font: font])
    (letter as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                              withAttributes: [.font: font, .foregroundColor: color])
}

// MARK: - 当前账号

@MainActor
private final class Summary: NSView {
    private var account = Account(key: "", dir: nil)
    private var letter = "A"
    private var limits: Limits?
    private var integrated = false
    private var now = Date()
    var contextMenu: () -> NSMenu = { NSMenu() }

    override var isFlipped: Bool { true }

    /// 有额度：身份 + 两组额度；接入后还没数据或未登录：身份 + 提示；未接入（顶部已有横幅）：只有身份
    var height: CGFloat {
        if account.signedIn, limits != nil { return 141 }
        return account.signedIn && !integrated ? 26 : 70
    }

    func update(_ account: Account, letter: String, limits: Limits?, integrated: Bool, now: Date) {
        self.account = account
        self.letter = letter
        self.limits = limits
        self.integrated = integrated
        self.now = now
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu() }

    override func draw(_ dirtyRect: NSRect) {
        let left = PanelView.inset, right = bounds.width - PanelView.inset
        drawBadge(letter, in: CGRect(x: left, y: 0, width: 26, height: 26), active: true,
                  signedIn: account.signedIn, font: Text.badgeLarge)
        let title = account.email ?? String(localized: "未登录")
        Text.draw(title, Text.headline, .labelColor, in: CGRect(x: left + 36, y: -1, width: right - left - 36, height: 18))
        let detail = [account.plan, String(localized: "当前账号")].compactMap { $0 }.joined(separator: " · ")
        Text.draw(detail, Text.caption, .secondaryLabelColor, in: CGRect(x: left + 36, y: 16, width: right - left - 36, height: 15))

        guard account.signedIn, let limits else {
            guard !account.signedIn || integrated else { return }
            let hint = account.signedIn ? String(localized: "用这个账号运行一次 Claude Code 后显示额度")
                : String(localized: "右键这里登录")
            let box = CGRect(x: left - PanelView.bleed, y: 40, width: right - left + PanelView.bleed * 2, height: 30)
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
            Text.draw(hint, Text.caption, .secondaryLabelColor, in: box.insetBy(dx: 10, dy: 8), align: .center)
            return
        }
        meter(String(localized: "5 小时"), limits.fiveHour, y: 40, left: left, right: right)
        meter(String(localized: "7 天"), limits.sevenDay, y: 96, left: left, right: right)
    }

    /// 标题与百分比一行，粗一点的进度条，下面一行写什么时候重置；共 45pt 高
    private func meter(_ title: String, _ window: Window?, y: CGFloat, left: CGFloat, right: CGFloat) {
        let used = window?.used(at: now) ?? 0
        Text.draw(title, Text.label, .labelColor, in: CGRect(x: left, y: y, width: 120, height: 16))
        Text.draw("\(Int(used.rounded()))%", Text.percent, used >= 80 ? meterColor(used) : .labelColor,
                  in: CGRect(x: right - 70, y: y - 1, width: 70, height: 17), align: .right)

        let track = CGRect(x: left, y: y + 20, width: right - left, height: 6)
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        if used > 0 {
            meterColor(used).setFill()
            var fill = track
            fill.size.width = max(track.width * used / 100, track.height)
            NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
        }

        let caption: String
        if let window, window.resets > now {
            caption = String(localized: "\(Format.until(window.resets, now: now)) 后重置")
        } else {
            caption = String(localized: "已重置，额度充足")
        }
        Text.draw(caption, Text.caption, .secondaryLabelColor, in: CGRect(x: left, y: y + 30, width: right - left, height: 15))
    }
}

// MARK: - 账号行

@MainActor
private final class AccountRow: NSView {
    static let height: CGFloat = 30
    /// 行的悬停底色在内容上下各多出的部分
    static let padding: CGFloat = 6
    private var account = Account(key: "", dir: nil)
    private var letter = "A"
    private var active = false
    private var pending = false
    private var limits: Limits?
    private var now = Date()
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var overAction = false { didSet { if overAction != oldValue { needsDisplay = true } } }
    var onClick: () -> Void = {}
    var contextMenu: () -> NSMenu = { NSMenu() }

    override var isFlipped: Bool { true }

    /// 悬停时最右侧的操作：其他账号是「切换」，未登录是「登录」，当前账号不需要操作
    private var action: String? {
        if !account.signedIn { return pending ? nil : String(localized: "登录") }
        return active ? nil : String(localized: "切换")
    }

    private var actionRect: CGRect {
        guard let action else { return .zero }
        let width = Text.width(action, Text.action) + 18
        return CGRect(x: bounds.width - PanelView.bleed - width + 4, y: 5, width: width, height: 20)  // 胶囊比文字边线多出 4pt
    }

    func update(_ account: Account, letter: String, active: Bool, pending: Bool, limits: Limits?, now: Date) {
        self.account = account
        self.letter = letter
        self.active = active
        self.pending = pending
        self.limits = limits
        self.now = now
        toolTip = tooltip()
        setAccessibilityRole(.button)
        setAccessibilityLabel([letter, account.email ?? String(localized: "未登录"), active ? String(localized: "当前账号") : nil]
            .compactMap { $0 }.joined(separator: "，"))
        needsDisplay = true
    }

    /// 两个圆环各是什么、多久重置、套餐，都放在提示里，行本身保持干净
    private func tooltip() -> String? {
        guard account.signedIn else { return nil }
        var lines = [account.plan].compactMap { $0 }
        if let limits {
            for (title, window) in [(String(localized: "5 小时"), limits.fiveHour), (String(localized: "7 天"), limits.sevenDay)] {
                var line = "\(title) \(Int((window?.used(at: now) ?? 0).rounded()))%"
                if let window, window.resets > now {
                    line += " · " + String(localized: "\(Format.until(window.resets, now: now)) 后重置")
                }
                lines.append(line)
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        overAction = false
    }
    override func mouseMoved(with event: NSEvent) {
        overAction = actionRect.contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseDown(with event: NSEvent) {}
    /// 只有点在「切换」「登录」上才生效，点行的其他地方不会误切
    override func mouseUp(with event: NSEvent) {
        if actionRect.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu() }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        let left = PanelView.bleed, right = bounds.width - PanelView.bleed
        drawBadge(letter, in: CGRect(x: left, y: Self.padding, width: 18, height: 18), active: active,
                  signedIn: account.signedIn, font: Text.badge)
        let text = left + 26

        // 悬停时让出右侧：圆环隐藏，邮箱显示得更完整，最右侧是操作按钮（当前账号写「当前」）
        if hovered {
            var end = right
            if let action {
                let pill = actionRect
                NSColor.controlAccentColor.withAlphaComponent(overAction ? 0.28 : 0.16).setFill()
                NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
                Text.draw(action, Text.action, .controlAccentColor, in: pill.offsetBy(dx: 0, dy: 3), align: .center)
                end = pill.minX - 8
            } else if active {
                let label = String(localized: "当前")
                Text.draw(label, Text.caption, .secondaryLabelColor, in: CGRect(x: right - 60, y: 8, width: 60, height: 15), align: .right)
                end = right - Text.width(label, Text.caption) - 8
            }
            title(in: CGRect(x: text, y: 7, width: end - text, height: 16))
            return
        }
        title(in: CGRect(x: text, y: 7, width: right - text - (account.signedIn ? 86 : 0), height: 16))
        guard account.signedIn else { return }

        // 右侧：5 小时百分比 + 两个并排的小圆环（5 小时、7 天）
        let calm: NSColor = active ? .controlAccentColor : .secondaryLabelColor
        let five = limits.map { $0.fiveHour?.used(at: now) ?? 0 }
        let seven = limits.map { $0.sevenDay?.used(at: now) ?? 0 }
        let weekly = CGRect(x: right - 15, y: 7.5, width: 15, height: 15)
        let hourly = weekly.offsetBy(dx: -22, dy: 0)
        ring(hourly.insetBy(dx: 1, dy: 1), used: five, color: calm)
        ring(weekly.insetBy(dx: 1, dy: 1), used: seven, color: calm)
        Text.draw(five.map { "\(Int($0.rounded()))%" } ?? "—", Text.digits, .secondaryLabelColor,
                  in: CGRect(x: hourly.minX - 42, y: 8, width: 36, height: 15), align: .right)
    }

    private func title(in rect: CGRect) {
        if account.signedIn {
            Text.draw(account.email ?? "", active ? Text.bodyStrong : Text.body, .labelColor, in: rect)
        } else {
            let title = pending ? String(localized: "等待终端里完成登录…") : String(localized: "新账号 · 未登录")
            Text.draw(title, Text.body, .secondaryLabelColor, in: rect)
        }
    }

    private func ring(_ rect: CGRect, used: Double?, color: NSColor) {
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = 2
        NSColor.labelColor.withAlphaComponent(0.12).setStroke()
        track.stroke()
        guard let used, used > 0 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                      startAngle: -90, endAngle: -90 + 360 * used / 100)  // 视图是翻转的，顺时针
        arc.lineWidth = 2
        arc.lineCapStyle = .round
        meterColor(used, calm: color).setStroke()
        arc.stroke()
    }
}

// MARK: - 接入提示

@MainActor
private final class Banner: NSView {
    static let height: CGFloat = 52
    var onConnect: () -> Void = {}
    private var button: NSButton!

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        button = NSButton(title: String(localized: "接入"), target: self, action: #selector(connect))
        button.controlSize = .small
        button.bezelStyle = .push
        button.keyEquivalent = "\r"
        button.sizeToFit()
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        button.setFrameOrigin(CGPoint(x: bounds.width - button.frame.width - PanelView.bleed + 3,  // 按钮外框比可见部分宽 3pt
                                      y: (bounds.height - button.frame.height) / 2))
    }

    @objc private func connect() { onConnect() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        let left = PanelView.bleed, width = bounds.width - button.frame.width - left * 3
        Text.draw(String(localized: "接入 Claude Code"), Text.bodyStrong, .labelColor,
                  in: CGRect(x: left, y: 9, width: width, height: 17))
        Text.draw(String(localized: "同步额度，终端跟随切换"), Text.caption, .secondaryLabelColor,
                  in: CGRect(x: left, y: 27, width: width, height: 15))
    }
}

// MARK: - Token 用量

@MainActor
private final class UsageView: NSView {
    static let height: CGFloat = 52
    private var totals = Ledger.Totals()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = String(localized: "本地会话记录里的 token 数，含缓存读写")
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ totals: Ledger.Totals) {
        self.totals = totals
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let left = PanelView.inset, right = bounds.width - PanelView.inset
        Text.section(String(localized: "Token 用量"), at: CGPoint(x: left, y: 0))
        guard totals.loaded else {
            Text.draw(String(localized: "正在统计…"), Text.caption, .secondaryLabelColor,
                      in: CGRect(x: left, y: 24, width: right - left, height: 15))
            return
        }
        stat(String(localized: "今天"), totals.today, x: left)
        stat(String(localized: "7 天"), totals.week, x: left + 72)
        sparkline(CGRect(x: right - 98, y: 22, width: 98, height: 30))
    }

    private func stat(_ title: String, _ value: Int, x: CGFloat) {
        Text.draw(title, Text.caption, .secondaryLabelColor, in: CGRect(x: x, y: 21, width: 68, height: 15))
        Text.draw(Format.tokens(value), Text.stat, .labelColor, in: CGRect(x: x, y: 35, width: 68, height: 17))
    }

    /// 近 14 天，今天用强调色；没有用量的日子只留一道底线
    private func sparkline(_ rect: CGRect) {
        let count = totals.daily.count, gap: CGFloat = 2
        let barWidth = (rect.width - gap * CGFloat(count - 1)) / CGFloat(count)
        let peak = CGFloat(max(totals.daily.max() ?? 0, 1))
        for (i, value) in totals.daily.enumerated() {
            let height = value > 0 ? max(rect.height * CGFloat(value) / peak, 3) : 1.5
            let bar = CGRect(x: rect.minX + CGFloat(i) * (barWidth + gap), y: rect.maxY - height, width: barWidth, height: height)
            (i == count - 1 ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.2)).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

// MARK: - 操作

@MainActor
private final class Footer: NSView {
    static let height: CGFloat = 40
    var onAdd: () -> Void = {}
    var onMore: (NSButton) -> Void = { _ in }
    private var add: NSButton!
    private var more: NSButton!

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        add = HoverButton(title: String(localized: "添加账号"), image: symbol("plus.circle"), target: self, action: #selector(addTapped))
        add.imagePosition = .imageLeading
        add.imageHugsTitle = true
        add.font = Text.body
        more = HoverButton(image: symbol("gearshape"), target: self, action: #selector(moreTapped))
        more.toolTip = String(localized: "设置")
        more.setAccessibilityLabel(String(localized: "设置"))
        for button in [add!, more!] {
            button.isBordered = false
            button.contentTintColor = .labelColor
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))!
    }

    @objc private func addTapped() { onAdd() }
    @objc private func moreTapped() { onMore(more) }

    /// 悬停底色和账号行一样比内容边线宽出一截，图标和文字仍落在边线上
    override func layout() {
        super.layout()
        add.sizeToFit()
        let height: CGFloat = 26, pad = PanelView.bleed
        add.frame = CGRect(x: PanelView.inset - 1 - pad, y: (bounds.height - height) / 2,
                           width: add.frame.width + pad * 2, height: height)
        more.frame = CGRect(x: bounds.width - PanelView.inset - 20 - 3, y: (bounds.height - height) / 2,
                            width: height, height: height)
    }
}

/// 无边框按钮，悬停时显示和账号行一致的浅底色
@MainActor
private final class HoverButton: NSButton {
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.12 : 0.07).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        super.draw(dirtyRect)
    }
}

// MARK: - 文字

@MainActor
private enum Text {
    static let headline = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
    static let body = NSFont.systemFont(ofSize: 12.5)
    static let bodyStrong = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    static let label = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let caption = NSFont.systemFont(ofSize: 11)
    static let sectionFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let badge = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    static let badgeLarge = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let percent = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    static let digits = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
    static let action = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let stat = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)

    static func draw(_ string: String, _ font: NSFont, _ color: NSColor, in rect: CGRect, align: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = .byTruncatingTail
        // 截断前系统默认会先收紧字距：悬停时邮箱从截断变成完整，字形会整体挪动
        style.allowsDefaultTighteningForTruncation = false
        (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    static func width(_ string: String, _ font: NSFont) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    /// 分区标题
    static func section(_ title: String, at point: CGPoint) {
        draw(title, sectionFont, .secondaryLabelColor, in: CGRect(origin: point, size: CGSize(width: 200, height: 15)))
    }
}
