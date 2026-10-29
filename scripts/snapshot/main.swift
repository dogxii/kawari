// 用临时家目录里的假账号渲染面板，用于检查 UI 退化。由 scripts/snapshot.sh 调用。
import AppKit

@MainActor
final class Quiet: Effects {
    func setEnvironment(_ dir: String?) {}
    func open(_ script: URL) {}
    func remove(_ dir: URL, logout: Bool, then done: @escaping @MainActor @Sendable (Bool) -> Void) {}
}

/// 一个假的家目录：若干账号、各自的额度与近两周的会话记录
@MainActor
func scene(integrated: Bool) -> Kawari {
    let home = FileManager.default.temporaryDirectory.appending(path: "kawari-snapshot-\(UUID().uuidString)")
    let fm = FileManager.default
    func write(_ text: String, _ path: String) {
        let url = home.appending(path: path)
        try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: url)
    }
    func account(_ config: String, _ email: String, _ type: String, _ tier: String = "") {
        write(#"{"oauthAccount":{"emailAddress":"\#(email)","organizationType":"\#(type)","organizationRateLimitTier":"\#(tier)"}}"#, config)
    }
    let now = Int(Date().timeIntervalSince1970)
    func usage(_ key: String, _ five: Double?, _ fiveIn: Int, _ seven: Double, _ sevenIn: Int) {
        let fiveJSON = five.map { #""five_hour":{"used_percentage":\#($0),"resets_at":\#(now + fiveIn)},"# } ?? ""
        write(#"{"rate_limits":{\#(fiveJSON)"seven_day":{"used_percentage":\#(seven),"resets_at":\#(now + sevenIn)}}}"#,
              ".config/kawari/usage/\(key).json")
    }

    account(".claude.json", "dogxi@studio.dev", "claude_max", "default_claude_max_20x")
    if integrated {
        account(".claude-accounts/2/.claude.json", "ren@fieldnotes.app", "claude_pro")
        account(".claude-accounts/3/.claude.json", "night-shift@team.io", "claude_max", "default_claude_max_5x")
        write("{}", ".claude-accounts/4/.claude.json")
        usage("default", 62, 4800, 23, 3 * 86400)
        usage("2", nil, 0, 71, 2 * 86400 + 7200)
        usage("3", 91, 1500, 48, 5 * 86400)
        write(Hook.script, ".config/kawari/statusline.sh")
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appending(path: ".config/kawari/statusline.sh").path)
        write(#"{"statusLine":{"type":"command","command":"\#(Hook.command)"}}"#, ".claude/settings.json")
        write(Zsh.snippet, ".zshrc")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines: [String] = []
        for day in 0..<14 {
            let tokens = [0, 0, 12, 40, 31, 0, 55, 80, 62, 95, 70, 41, 88, 64][13 - day] * 1_000_000
            guard tokens > 0 else { continue }
            let stamp = formatter.string(from: Date() - Double(day) * 86400)
            lines.append(#"{"type":"assistant","timestamp":"\#(stamp)","message":{"id":"m\#(day)","usage":{"cache_read_input_tokens":\#(tokens)}}}"#)
        }
        write(lines.joined(separator: "\n") + "\n", ".claude/projects/p/s.jsonl")
    } else {
        write("{}", ".claude/settings.json")
    }

    let kawari = Kawari(paths: Paths(home: home), effects: Quiet())
    if integrated { kawari.activate(kawari.accounts[0]) }
    kawari.refreshTotals()
    let deadline = Date() + 5
    while !kawari.totals.loaded, Date() < deadline { RunLoop.main.run(until: Date() + 0.02) }
    return kawari
}

MainActor.assumeIsolated {
    // 未接入；已接入；已接入且鼠标悬停在 B 行（显示「切换」）和「添加账号」上
    let integrated = scene(integrated: true)
    let scenes: [(Kawari, hover: Int?)] = [(scene(integrated: false), nil), (integrated, nil), (integrated, 1)]
    let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]
    let scale: CGFloat = 2, gap: CGFloat = 24
    let panels = scenes.map { kawari, hover -> PanelView in
        let panel = PanelView(kawari: kawari, menu: NSMenu()) { _ in NSMenu() }
        panel.sync()
        if let hover {
            // 账号行是高 30pt 的子视图，按从上到下的顺序找到第 hover 行
            let rows = panel.subviews.filter { $0.frame.height == 30 }.sorted { $0.frame.minY < $1.frame.minY }
            let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            rows[hover].mouseEntered(with: event)
            // 底部操作栏（高 40pt）的「添加账号」也一起悬停
            panel.subviews.first { $0.frame.height == 40 }?.subviews.first?.mouseEntered(with: event)
        }
        return panel
    }
    let height = panels.map(\.frame.height).max()!
    let size = CGSize(width: gap + CGFloat(panels.count * appearances.count) * (PanelView.width + gap), height: height + gap * 2)

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: 0.5, alpha: 1).setFill()
    CGRect(origin: .zero, size: size).fill()

    var x = gap
    for name in appearances {
        let appearance = NSAppearance(named: name)!
        for panel in panels {
            panel.appearance = appearance
            panel.layoutSubtreeIfNeeded()
            let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(panel.bounds.width * scale),
                                         pixelsHigh: Int(panel.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            image.size = panel.bounds.size
            // 先铺近似弹出面板的底色，再按该外观绘制（cacheDisplay 会垫一层白底）
            let context = NSGraphicsContext(bitmapImageRep: image)!
            let outer = NSGraphicsContext.current
            NSGraphicsContext.current = context
            NSColor(white: name == .darkAqua ? 0.17 : 0.97, alpha: 1).setFill()
            CGRect(origin: .zero, size: panel.bounds.size).fill()
            appearance.performAsCurrentDrawingAppearance { panel.displayIgnoringOpacity(panel.bounds, in: context) }
            NSGraphicsContext.current = outer
            let frame = CGRect(x: x, y: size.height - gap - panel.frame.height, width: panel.frame.width, height: panel.frame.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12).addClip()
            image.draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()
            x += PanelView.width + gap
        }
    }
    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(filePath: CommandLine.arguments[1]))
}
