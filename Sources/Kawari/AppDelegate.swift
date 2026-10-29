import AppKit

/// 菜单栏入口。
/// 左键：账号面板 · 右键（或面板里的 ⋯）：菜单
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private let kawari = Kawari()
    private var item: NSStatusItem!
    private var icons: [Ring: NSImage] = [:]
    private var nextRefresh: Timer?
    private var watch: DirectoryWatch?

    private lazy var menu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        return menu
    }()

    /// 面板在第一次打开时才创建
    private var panel: PanelView?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(click)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("kawari")
        }
        kawari.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    // MARK: 点击

    @objc private func click() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button else { return }
        let (panel, popover) = loadPanel()
        kawari.reload()
        kawari.refreshTotals()
        panel.show()
        popover.contentSize = panel.frame.size
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        panel.window?.makeFirstResponder(panel)
    }

    private func loadPanel() -> (PanelView, NSPopover) {
        if let panel, let popover { return (panel, popover) }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let panel = PanelView(kawari: kawari, menu: menu) { [unowned self] in rowMenu($0) }
        panel.onResize = { [weak popover] in popover?.contentSize = $0 }
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = panel
        self.panel = panel
        self.popover = popover
        return (panel, popover)
    }

    func popoverDidClose(_ notification: Notification) {
        panel?.hide()
    }

    // MARK: 菜单栏图标

    /// 当前账号 5 小时窗口的细圆环，中间是账号字母。按 24 档缓存
    private struct Ring: Hashable {
        var step: Int?  // nil：还没有额度数据
        var warn: Bool
        var initial: String
    }

    private func refresh() {
        if watch == nil, kawari.integrated {
            watch = DirectoryWatch(kawari.paths.usage) { [weak self] in self?.kawari.reloadUsage() }
        }
        if popover?.isShown == true { panel?.sync() }
        guard let button = item?.button else { return }

        let active = kawari.active
        let level = kawari.fiveHour(active)
        let key = Ring(step: level.map { Int(($0 * 24).rounded()) }, warn: (level ?? 0) >= 0.8,
                       initial: kawari.letter(active))
        if icons[key] == nil { icons[key] = Self.ring(key) }
        button.image = icons[key]
        button.setAccessibilityValue([
            active.email,
            level.map { String(localized: "5 小时额度已用 \(Int(($0 * 100).rounded()))%") },
        ].compactMap { $0 }.joined(separator: "，"))

        // 到下一次窗口重置时刷新，平时不唤醒
        nextRefresh?.invalidate()
        if let reset = kawari.nextReset() {
            nextRefresh = .onMain(after: reset.timeIntervalSinceNow + 1, tolerance: 10) { [weak self] in self?.refresh() }
        }
    }

    private static func ring(_ ring: Ring) -> NSImage {
        let image = NSImage(size: CGSize(width: 18, height: 18), flipped: false) { rect in
            let circle = rect.insetBy(dx: 1.5, dy: 1.5)
            let center = CGPoint(x: circle.midX, y: circle.midY), radius = circle.width / 2
            let track = NSBezierPath(ovalIn: circle)
            track.lineWidth = 1.5
            NSColor.labelColor.withAlphaComponent(0.3).setStroke()
            track.stroke()
            if let step = ring.step, step > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                              endAngle: 90 - 360 * CGFloat(step) / 24, clockwise: true)
                arc.lineWidth = 2
                arc.lineCapStyle = .round
                (ring.warn ? NSColor.systemOrange : NSColor.labelColor).setStroke()
                arc.stroke()
            }
            let font = NSFont.systemFont(ofSize: 8.5, weight: .bold)
            let letter = NSAttributedString(string: ring.initial, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            let size = letter.size()
            letter.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2 + 0.5))
            return true
        }
        image.isTemplate = !ring.warn
        return image
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(Item(String(localized: "添加账号…")) { [unowned self] in
            do { try kawari.addAccount() } catch { NSSound.beep() }
        })
        menu.addItem(.separator())
        menu.addItem(Item(String(localized: "接入 Claude Code"), on: kawari.integrated) { [unowned self] in
            try? kawari.setIntegrated(!kawari.integrated)
        })
        if Bundle.main.isApp {
            menu.addItem(Item(String(localized: "开机启动"), on: LoginItem.enabled) { LoginItem.toggle() })
            // 装了不止一个终端时，可以选登录用哪个
            let terminals = Terminal.installed
            if terminals.count > 1 {
                let choices = NSMenu(), current = Terminal.selectedID
                let system = Terminal.systemDefault.map { String(localized: "跟随系统（\(Terminal.name($0))）") }
                choices.addItem(Item(system ?? String(localized: "跟随系统"), on: current == nil) { Terminal.select(nil) })
                choices.addItem(.separator())
                for app in terminals {
                    let id = Bundle(url: app)?.bundleIdentifier
                    choices.addItem(Item(Terminal.name(app), on: id == current) { Terminal.select(app) })
                }
                let terminal = NSMenuItem(title: String(localized: "登录用的终端"), action: nil, keyEquivalent: "")
                terminal.submenu = choices
                menu.addItem(terminal)
            }
            let languages = NSMenu()
            let selected = Language.selected
            languages.addItem(Item(String(localized: "跟随系统"), on: selected == nil) { Language.select(nil) })
            languages.addItem(.separator())
            for (code, name) in Language.choices {
                languages.addItem(Item(name, on: selected == code) { Language.select(code) })
            }
            let language = NSMenuItem(title: String(localized: "语言"), action: nil, keyEquivalent: "")
            language.submenu = languages
            menu.addItem(language)
        }
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        menu.addItem(Item(["kawari", version, "· GitHub"].compactMap { $0 }.joined(separator: " ")) {
            NSWorkspace.shared.open(URL(string: "https://github.com/dogxii/kawari")!)
        })
        menu.addItem(Item(String(localized: "退出 kawari"), key: "q") { NSApp.terminate(nil) })
    }

    /// 账号行的右键菜单
    private func rowMenu(_ account: Account) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(Item(account.signedIn ? String(localized: "重新登录…") : String(localized: "登录…")) {
            [unowned self] in kawari.login(account)
        })
        menu.addItem(Item(String(localized: "在访达中显示")) { [unowned self] in
            NSWorkspace.shared.activateFileViewerSelecting([account.dir ?? kawari.paths.primary])
        })
        if !account.isPrimary {
            menu.addItem(.separator())
            menu.addItem(Item(String(localized: "移除账号…")) { [unowned self] in confirmRemove(account) })
        }
        return menu
    }

    private func confirmRemove(_ account: Account) {
        let alert = NSAlert()
        alert.messageText = String(localized: "移除 \(account.email ?? String(localized: "这个账号"))？")
        alert.informativeText = String(localized: "会退出它的登录，并把它的目录移到废纸篓。会话记录与设置是共用的，不受影响。")
        alert.addButton(withTitle: String(localized: "移除"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        kawari.remove(account) { [weak self] removed in if !removed { self?.removeFailed(account) } }
    }

    /// 退出登录或移到废纸篓失败（比如找不到 claude）：目录还留着，让用户决定是否直接移走
    private func removeFailed(_ account: Account) {
        let alert = NSAlert()
        alert.messageText = String(localized: "没能移除 \(account.email ?? String(localized: "这个账号"))")
        alert.informativeText = String(localized: "退出登录时出错，目录已保留。仍然移除会跳过退出登录，它在钥匙串里的登录凭证可能会留下。")
        alert.addButton(withTitle: String(localized: "仍然移除"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.buttons[0].hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { kawari.remove(account, force: true) }
    }
}

@MainActor
private final class Item: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, on: Bool = false, key: String = "", _ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        state = on ? .on : .off
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
