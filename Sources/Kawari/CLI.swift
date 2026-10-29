import Foundation

/// 命令行：和菜单栏共用同一份账号与额度，切换后菜单栏与已打开的终端都会跟上。
///   kawari              列出账号与额度
///   kawari use <账号>    按字母、序号或邮箱开头切换
///   kawari status       一行状态，适合放进提示符或 tmux
@MainActor
enum CLI {
    /// 带参数运行，或经由 kawari 软链接运行时走命令行；从访达打开时没有参数（旧系统可能带 -psn_）
    static var invoked: Bool {
        CommandLine.arguments.dropFirst().contains { !$0.hasPrefix("-psn_") }
            || URL(filePath: CommandLine.arguments[0]).lastPathComponent == "kawari"
    }

    static func main() -> Int32 {
        // 经由软链接运行时找不到 App 包，本地化和语言设置都失效：按真实路径重新执行，argv 不变
        if Bundle.main.bundleIdentifier == nil, let real = Bundle.main.executableURL?.resolvingSymlinksInPath(),
           real.path != Bundle.main.executablePath {
            execv(real.path, CommandLine.unsafeArgv)
        }
        let effects = SystemEffects()
        let code = run(Array(CommandLine.arguments.dropFirst()), Kawari(effects: effects),
                       out: { print($0) }, err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
        effects.wait()
        return code
    }

    /// 返回退出码；输出经由 out / err，测试里可以收集
    static func run(_ args: [String], _ kawari: Kawari, out: (String) -> Void, err: (String) -> Void) -> Int32 {
        switch args.first {
        case nil, "ls", "list":
            list(kawari).forEach(out)
        case "use", "switch":
            guard args.count == 2 else {
                err(String(localized: "用法：kawari use <账号>（字母、序号或邮箱开头）"))
                return 64
            }
            return use(args[1], kawari, out: out, err: err)
        case "status":
            out(status(kawari))
        case "help", "-h", "--help":
            out(String(localized: """
            kawari              列出账号与额度
            kawari use <账号>    切换账号：字母、序号或邮箱开头
            kawari status       当前账号与 5 小时用量，适合放进提示符或 tmux
            """))
        default:
            err(String(localized: "未知命令：\(args[0])。运行 kawari help 查看用法"))
            return 64
        }
        return 0
    }

    /// 每个账号一行，当前账号前面标 *
    static func list(_ kawari: Kawari) -> [String] {
        let now = kawari.now
        let width = kawari.accounts.map { ($0.email ?? "").count }.max() ?? 0
        return kawari.accounts.map { account in
            let mark = account.key == kawari.activeKey ? "*" : " "
            let head = "\(mark) \(kawari.letter(account))  "
            guard let email = account.email else { return head + String(localized: "新账号 · 未登录") }
            var line = head + email.padding(toLength: width, withPad: " ", startingAt: 0)
                + "  " + (account.plan ?? "").padding(toLength: 8, withPad: " ", startingAt: 0)
            guard let limits = kawari.limits[account.key] else { return line + "  5h   —   7d   —" }
            func percent(_ window: Window?) -> String {
                let value = "\(Int((window?.used(at: now) ?? 0).rounded()))%"
                return String(repeating: " ", count: max(0, 4 - value.count)) + value
            }
            line += "  5h \(percent(limits.fiveHour))  7d \(percent(limits.sevenDay))"
            if let reset = limits.fiveHour?.resets, reset > now {
                line += "  " + String(localized: "\(Format.until(reset, now: now)) 后重置")
            }
            return line
        }
    }

    /// 例如「A 62%」；没有额度数据时只有字母
    static func status(_ kawari: Kawari) -> String {
        let active = kawari.active
        let letter = kawari.letter(active)
        return kawari.fiveHour(active).map { "\(letter) \(Int(($0 * 100).rounded()))%" } ?? letter
    }

    private static func use(_ query: String, _ kawari: Kawari, out: (String) -> Void, err: (String) -> Void) -> Int32 {
        let accounts = kawari.accounts, lowered = query.lowercased()
        // 邮箱先找完全相同的；只给开头时必须只对上一个，免得切错
        let prefixed = accounts.filter { $0.email?.lowercased().hasPrefix(lowered) == true }
        let target = Int(query).flatMap { (1...accounts.count).contains($0) ? accounts[$0 - 1] : nil }
            ?? accounts.first { kawari.letter($0).lowercased() == lowered }
            ?? accounts.first { $0.email?.lowercased() == lowered }
            ?? (prefixed.count == 1 ? prefixed[0] : nil)
        guard let target else {
            err(prefixed.count > 1
                ? String(localized: "\(query) 对应不止一个账号，请写得更完整，或用字母")
                : String(localized: "没有找到账号：\(query)"))
            return 1
        }
        guard let email = target.email else {
            err(String(localized: "\(kawari.letter(target)) 还没登录，请在菜单栏里登录"))
            return 1
        }
        kawari.activate(target)
        guard kawari.activeKey == target.key else {
            err(String(localized: "切换失败：写不进 ~/.config/kawari/current"))
            return 1
        }
        out(String(localized: "已切换到 \(kawari.letter(target)) · \(email)"))
        if !kawari.integrated {
            out(String(localized: "还没接入 Claude Code：在菜单栏打开「接入 Claude Code」后，已打开的终端也会跟着切换"))
        }
        return 0
    }
}
