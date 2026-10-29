import Foundation
import Testing
@testable import Kawari

/// 一个临时的家目录，测试结束即删
final class Sandbox {
    let home: URL
    var paths: Paths { Paths(home: home) }

    init() {
        home = FileManager.default.temporaryDirectory
            .appending(path: "kawari-\(UUID().uuidString)").resolvingSymlinksInPath()
        try! FileManager.default.createDirectory(at: home.appending(path: ".claude/projects"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    func write(_ text: String, _ path: String) {
        let url = home.appending(path: path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: url)
    }

    func read(_ path: String) -> String? { try? String(contentsOf: home.appending(path: path), encoding: .utf8) }

    func signIn(_ config: String, _ email: String, type: String = "claude_max", tier: String = "default_claude_max_20x") {
        write(#"{"oauthAccount":{"emailAddress":"\#(email)","organizationType":"\#(type)","organizationRateLimitTier":"\#(tier)"},"theme":"dark","mcpServers":{"a":{"command":"x"}}}"#, config)
    }

    /// 运行 shell 命令，HOME 指向沙盒
    @discardableResult
    func sh(_ command: String, input: String = "", env: [String: String] = [:]) -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"].merging(env) { $1 }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try! process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try! stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
    }
}

@MainActor
final class RecordingEffects: Effects {
    var environment: [String?] = []
    var opened: [URL] = []
    var removed: [URL] = []
    /// 模拟退出登录失败（比如找不到 claude）
    var logoutFails = false

    func setEnvironment(_ dir: String?) { environment.append(dir) }
    func open(_ script: URL) { opened.append(script) }
    func remove(_ dir: URL, logout: Bool, then done: @escaping @MainActor @Sendable (Bool) -> Void) {
        if logout && logoutFails { return done(false) }
        removed.append(dir)
        done(true)
    }
}

// MARK: - 账号

@MainActor
struct AccountTests {
    let box = Sandbox()
    let effects = RecordingEffects()

    @Test func planLabels() {
        #expect(Profile.plan(["organizationType": "claude_max", "userRateLimitTier": "default_claude_max_5x"]) == "Max 5x")
        #expect(Profile.plan(["organizationType": "claude_max", "organizationRateLimitTier": "default_claude_max_20x"]) == "Max 20x")
        #expect(Profile.plan(["organizationType": "claude_pro"]) == "Pro")
        #expect(Profile.plan(["organizationType": "something_new"]) == nil)
    }

    @Test func primaryAlwaysFirst() {
        box.signIn(".claude.json", "me@home.com", type: "claude_pro")
        let kawari = Kawari(paths: box.paths, effects: effects)
        #expect(kawari.accounts.count == 1)
        #expect(kawari.active.email == "me@home.com")
        #expect(kawari.active.plan == "Pro")
        kawari.restoreEnvironment()
        #expect(effects.environment.isEmpty)  // 没选过账号，不碰 launchctl
        box.write("", ".config/kawari/current")
        let reopened = Kawari(paths: box.paths, effects: effects)
        #expect(reopened.activeKey == "default" && effects.environment.isEmpty)  // 命令行也会创建 Kawari：只读不碰 launchctl
        reopened.restoreEnvironment()
        #expect(effects.environment == [nil])  // 选过之后，App 启动时补上
    }

    @Test func addAccountSharesEverythingButIdentity() throws {
        box.signIn(".claude.json", "me@home.com")
        box.write("{}", ".claude/settings.json")
        box.write("secret", ".claude/.credentials.json")
        let kawari = Kawari(paths: box.paths, effects: effects)
        try kawari.addAccount()

        let dir = box.home.appending(path: ".claude-accounts/2")
        let fm = FileManager.default
        #expect(try fm.destinationOfSymbolicLink(atPath: dir.appending(path: "projects").path)
            == box.home.appending(path: ".claude/projects").path)
        #expect((try? fm.destinationOfSymbolicLink(atPath: dir.appending(path: "settings.json").path)) != nil)
        #expect((try? fm.destinationOfSymbolicLink(atPath: dir.appending(path: "history.jsonl").path)) != nil)
        #expect(!fm.fileExists(atPath: dir.appending(path: ".credentials.json").path))

        // 继承引导状态与 MCP，但不带登录身份
        let config = try #require(JSONFile.read(dir.appending(path: ".claude.json")))
        #expect(config["oauthAccount"] == nil)
        #expect(config["theme"] as? String == "dark")
        #expect(config["mcpServers"] != nil)

        // 在终端里登录这个目录
        let script = try #require(box.read(".config/kawari/login-2.command"))
        #expect(script.contains("export CLAUDE_CONFIG_DIR='") && script.contains("/.claude-accounts/2'"))
        #expect(script.contains("auth login"))
        #expect(effects.opened.count == 1)
        #expect(kawari.pending == "2")

        // 第二个账号编号顺延
        try kawari.addAccount()
        #expect(kawari.accounts.map(\.key) == ["default", "2", "3"])
    }

    @Test func linkingNeverOverwrites() throws {
        box.write("{}", ".claude/settings.json")
        box.write("mine", ".claude-accounts/2/settings.json")
        try Sharing.link(box.home.appending(path: ".claude-accounts/2"), to: box.paths.primary)
        #expect(box.read(".claude-accounts/2/settings.json") == "mine")
    }

    @Test func switchingWritesPointerAndEnvironment() {
        box.signIn(".claude.json", "me@home.com")
        box.signIn(".claude-accounts/2/.claude.json", "me@work.com")
        let kawari = Kawari(paths: box.paths, effects: effects)
        let work = kawari.accounts[1]
        var changes = 0
        kawari.onChange = { changes += 1 }

        kawari.activate(work)
        #expect(kawari.activeKey == "2")
        #expect(box.read(".config/kawari/current") == work.dir!.path)
        #expect(effects.environment.last == work.dir!.path)
        #expect(changes == 1)

        // 重新读取后仍是它；切回主账号写空，表示不设 CLAUDE_CONFIG_DIR
        let reopened = Kawari(paths: box.paths, effects: effects)
        #expect(reopened.activeKey == "2")
        reopened.activate(reopened.accounts[0])
        #expect(box.read(".config/kawari/current") == "")
        #expect(effects.environment.last == .some(nil))
    }

    @Test func signedOutAccountOpensLoginInsteadOfSwitching() {
        box.write("{}", ".claude-accounts/2/.claude.json")
        let kawari = Kawari(paths: box.paths, effects: effects)
        kawari.activate(kawari.accounts[1])
        #expect(kawari.activeKey == "default")
        #expect(effects.opened.count == 1)
    }

    @Test func removeOnlyTouchesAccountDirectories() {
        box.signIn(".claude-accounts/2/.claude.json", "me@work.com")
        let kawari = Kawari(paths: box.paths, effects: effects)
        kawari.activate(kawari.accounts[1])
        kawari.remove(kawari.accounts[0])  // 主账号不能移除
        #expect(effects.removed.isEmpty)
        kawari.remove(kawari.accounts[1])
        #expect(effects.removed.map { $0.resolvingSymlinksInPath().path } == [box.home.appending(path: ".claude-accounts/2").path])
        #expect(kawari.activeKey == "default")
    }

    @Test func failedLogoutKeepsAccount() {
        box.signIn(".claude-accounts/2/.claude.json", "me@work.com")
        effects.logoutFails = true
        let kawari = Kawari(paths: box.paths, effects: effects)
        var result: Bool?
        kawari.remove(kawari.accounts[1]) { result = $0 }
        #expect(result == false)
        #expect(effects.removed.isEmpty)
        #expect(kawari.accounts.map(\.key) == ["default", "2"])
        kawari.remove(kawari.accounts[1], force: true) { result = $0 }
        #expect(result == true && effects.removed.count == 1)
    }

    @Test func deletedActiveDirectoryResetsPointer() throws {
        box.signIn(".claude-accounts/2/.claude.json", "me@work.com")
        let kawari = Kawari(paths: box.paths, effects: effects)
        kawari.activate(kawari.accounts[1])
        try FileManager.default.removeItem(at: box.home.appending(path: ".claude-accounts/2"))  // 在访达里手动删掉
        kawari.reload()
        #expect(kawari.activeKey == "default")
        #expect(box.read(".config/kawari/current") == "")  // 终端不再指向已删除的目录
        #expect(effects.environment.last == .some(nil))
    }

    @Test func reservedDirectoryNameIsIgnored() {
        box.signIn(".claude-accounts/default/.claude.json", "me@work.com")
        let kawari = Kawari(paths: box.paths, effects: effects)
        #expect(kawari.accounts.map(\.key) == ["default"])
    }

    @Test func unreadablePrimaryConfigKeepsMCP() {
        box.write("{ broken", ".claude.json")
        box.write(#"{"oauthAccount":{"emailAddress":"me@work.com"},"mcpServers":{"b":{"command":"y"}}}"#, ".claude-accounts/2/.claude.json")
        _ = Kawari(paths: box.paths, effects: effects)
        let config = JSONFile.read(box.home.appending(path: ".claude-accounts/2/.claude.json"))
        #expect((config?["mcpServers"] as? [String: Any])?["b"] != nil)
    }

    @Test func newIdentityDropsOldUsage() {
        box.signIn(".claude-accounts/2/.claude.json", "me@work.com")
        box.write("{}", ".config/kawari/usage/2.json")
        let kawari = Kawari(paths: box.paths, effects: effects)
        kawari.reload()
        #expect(box.read(".config/kawari/usage/2.json") == "{}")  // 同一身份：保留
        box.signIn(".claude-accounts/2/.claude.json", "other@work.com")
        kawari.reload()
        #expect(box.read(".config/kawari/usage/2.json") == nil)
    }

    @Test func mcpServersFollowPrimary() {
        box.signIn(".claude.json", "me@home.com")
        box.write(#"{"oauthAccount":{"emailAddress":"me@work.com"},"mcpServers":{}}"#, ".claude-accounts/2/.claude.json")
        _ = Kawari(paths: box.paths, effects: effects)
        let config = JSONFile.read(box.home.appending(path: ".claude-accounts/2/.claude.json"))
        #expect((config?["mcpServers"] as? [String: Any])?["a"] != nil)
        #expect((config?["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "me@work.com")
    }
}

// MARK: - 命令行

@MainActor
struct CLITests {
    let box = Sandbox()
    let effects = RecordingEffects()

    func run(_ args: String..., kawari: Kawari) -> (code: Int32, out: [String], err: [String]) {
        var out: [String] = [], err: [String] = []
        let code = CLI.run(args, kawari, out: { out.append($0) }, err: { err.append($0) })
        return (code, out, err)
    }

    func scene() -> Kawari {
        box.signIn(".claude.json", "me@home.com")
        box.signIn(".claude-accounts/2/.claude.json", "work@co.com", type: "claude_pro")
        box.write("{}", ".claude-accounts/3/.claude.json")
        let reset = Int(Date().timeIntervalSince1970) + 4800
        box.write(#"{"rate_limits":{"five_hour":{"used_percentage":62,"resets_at":\#(reset)},"seven_day":{"used_percentage":23,"resets_at":\#(reset)}}}"#,
                  ".config/kawari/usage/default.json")
        return Kawari(paths: box.paths, effects: effects)
    }

    @Test func listsAccountsWithLimits() {
        let result = run(kawari: scene())
        #expect(result.code == 0 && result.out.count == 3)
        #expect(result.out[0].hasPrefix("* A  me@home.com ") && result.out[0].contains("5h  62%  7d  23%"))
        #expect(result.out[1].hasPrefix("  B  work@co.com ") && result.out[1].contains("Pro") && result.out[1].contains("—"))
        #expect(result.out[2].hasPrefix("  C  "))
    }

    @Test func switchesByLetterNumberOrEmail() {
        let kawari = scene()
        #expect(run("use", "b", kawari: kawari).code == 0 && kawari.activeKey == "2")
        #expect(box.read(".config/kawari/current") == kawari.accounts[1].dir!.path)
        #expect(run("use", "1", kawari: kawari).code == 0 && kawari.activeKey == "default")
        #expect(run("use", "WORK", kawari: kawari).code == 0 && kawari.activeKey == "2")
        #expect(run("status", kawari: kawari).out == ["B"])  // 没有额度数据时只有字母
    }

    @Test func runLaunchesClaudeWithoutSwitching() {
        let kawari = scene()
        var launched: [(dir: URL?, args: [String])] = []
        func run(_ args: String...) -> Int32 {
            CLI.run(args, kawari, out: { _ in }, err: { _ in }) { launched.append(($0, $1)); return EACCES }
        }
        #expect(run("run", "b", "--resume") == 126)  // 启动失败如实报告
        _ = run("run", "a", "--", "-p", "hi")  // 主账号不设 CLAUDE_CONFIG_DIR；-- 之后原样交给 claude
        #expect(launched.map(\.dir) == [kawari.accounts[1].dir, nil])
        #expect(launched.map(\.args) == [["--resume"], ["-p", "hi"]])
        #expect(kawari.activeKey == "default" && box.read(".config/kawari/current") == nil)
        #expect(run("run", "c") == 1 && run("run") == 64 && launched.count == 2)  // 未登录或没给账号：不启动
    }

    @Test func fullEmailWinsAndAmbiguousPrefixIsRefused() {
        box.signIn(".claude.json", "me@co.com.cn")
        box.signIn(".claude-accounts/2/.claude.json", "me@co.com")
        let kawari = Kawari(paths: box.paths, effects: effects)
        #expect(run("use", "me@co.com", kawari: kawari).code == 0 && kawari.activeKey == "2")
        #expect(run("use", "me@co", kawari: kawari).code == 1 && kawari.activeKey == "2")
    }

    @Test func refusesUnknownOrSignedOut() {
        let kawari = scene()
        #expect(run("use", "z", kawari: kawari).code == 1)
        #expect(run("use", "c", kawari: kawari).code == 1)  // 未登录：不切换，也不打开终端
        #expect(kawari.activeKey == "default" && effects.opened.isEmpty)
        #expect(run("use", kawari: kawari).code == 64)
        #expect(run("nope", kawari: kawari).code == 64)
        #expect(run("status", kawari: kawari).out == ["A 62%"])
    }
}

// MARK: - 接入

@MainActor
struct IntegrationTests {
    let box = Sandbox()

    @Test func hookKeepsAndRestoresOriginalStatusLine() throws {
        box.write(#"{"model":"opus","statusLine":{"type":"command","command":"echo hi","padding":2}}"#, ".claude/settings.json")
        try Hook.install(box.paths)
        #expect(Hook.installed(box.paths))
        var line = try #require(JSONFile.read(box.paths.settings)?["statusLine"] as? [String: Any])
        #expect(line["command"] as? String == Hook.command)
        #expect(line["padding"] as? Int == 2)
        #expect(box.read(".config/kawari/statusline-original.sh") == "echo hi")

        try Hook.install(box.paths)  // 再装一次不会把自己当成原来的
        #expect(box.read(".config/kawari/statusline-original.sh") == "echo hi")

        try Hook.uninstall(box.paths)
        line = try #require(JSONFile.read(box.paths.settings)?["statusLine"] as? [String: Any])
        #expect(line["command"] as? String == "echo hi")
        #expect(JSONFile.read(box.paths.settings)?["model"] as? String == "opus")
    }

    @Test func hookWithoutOriginalRemovesStatusLine() throws {
        try Hook.install(box.paths)
        try Hook.uninstall(box.paths)
        #expect(JSONFile.read(box.paths.settings)?["statusLine"] == nil)
    }

    @Test func reinstallForgetsStaleOriginal() throws {
        box.write(#"{"statusLine":{"type":"command","command":"echo hi"}}"#, ".claude/settings.json")
        try Hook.install(box.paths)
        try Hook.uninstall(box.paths)
        box.write("{}", ".claude/settings.json")  // 用户自己去掉了 status line
        box.write("echo hi", ".config/kawari/statusline-original.sh")  // 假设旧备份还在
        try Hook.install(box.paths)
        try Hook.uninstall(box.paths)
        #expect(JSONFile.read(box.paths.settings)?["statusLine"] == nil)
    }

    @Test func installCreatesClaudeDirectory() throws {
        try FileManager.default.removeItem(at: box.paths.primary)
        try Integration.install(box.paths)
        #expect(Integration.installed(box.paths))
    }

    @Test func unreadableZshrcIsLeftAlone() throws {
        let bytes = Data([0x65, 0x63, 0x68, 0x6F, 0x20, 0xFF, 0xFE, 0x0A])  // 不是 UTF-8
        try bytes.write(to: box.paths.zshrc)
        #expect(throws: (any Error).self) { try Integration.install(box.paths) }
        #expect(try Data(contentsOf: box.paths.zshrc) == bytes)
        #expect(!Hook.installed(box.paths))  // 已装上的 status line 被撤回
    }

    @Test func oldZshSnippetIsUpgraded() throws {
        box.write("export A=1\n\n" + Zsh.snippet.replacingOccurrences(of: "preexec", with: "precmd") + "export B=2\n", ".zshrc")
        Zsh.upgrade(box.paths)
        #expect(box.read(".zshrc") == "export A=1\n\n" + Zsh.snippet + "export B=2\n")
    }

    @Test func invalidSettingsAreLeftAlone() {
        box.write("{ not json", ".claude/settings.json")
        #expect(throws: (any Error).self) { try Hook.install(box.paths) }
        #expect(box.read(".claude/settings.json") == "{ not json")
    }

    @Test func hookRecordsUsagePerAccountAndForwards() throws {
        try Hook.install(box.paths)
        box.write(#"printf 'orig:'; cat"#, ".config/kawari/statusline-original.sh")
        let input = #"{"session_id":"abc-123","rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":1900000000}}}"#
        let hook = box.paths.hook.path

        let out = box.sh(hook.shellQuoted, input: input, env: ["CLAUDE_CONFIG_DIR": box.home.path + "/.claude-accounts/2/"])
        #expect(out == "orig:" + input)
        #expect(box.read(".config/kawari/usage/2.json") == input)

        // 主账号；没有 rate_limits（如 API key 登录）时不写文件，原来的 status line 照常显示
        let plain = #"{"session_id":"def"}"#
        #expect(box.sh(hook.shellQuoted, input: plain) == "orig:" + plain)
        #expect(box.read(".config/kawari/usage/default.json") == nil)
        box.sh(hook.shellQuoted, input: input)
        #expect(box.read(".config/kawari/usage/default.json") == input)

        // 字节原样转发：依赖末尾换行的 `read` 也能读到
        box.write(#"read -r line && printf 'got:%s' "$line""#, ".config/kawari/statusline-original.sh")
        #expect(box.sh(hook.shellQuoted, input: plain + "\n") == "got:" + plain)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: box.paths.usage.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
    }

    @Test func oldHookIsUpgraded() throws {
        try Hook.install(box.paths)
        box.write("#!/bin/sh\nold\n", ".config/kawari/statusline.sh")
        box.write("", ".config/kawari/usage/default/session-mark")
        box.write("{}", ".config/kawari/usage/default.json")
        Hook.upgrade(box.paths)
        #expect(box.read(".config/kawari/statusline.sh") == Hook.script)
        #expect(box.read(".config/kawari/usage/default/session-mark") == nil)
        #expect(box.read(".config/kawari/usage/default.json") == "{}")
    }

    @Test func usageFlowsIntoKawari() throws {
        box.signIn(".claude.json", "me@home.com")
        try Hook.install(box.paths)
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        let reset = Int(now.timeIntervalSince1970) + 3600
        let input = #"{"session_id":"s1","rate_limits":{"five_hour":{"used_percentage":62,"resets_at":\#(reset)},"seven_day":{"used_percentage":23,"resets_at":\#(reset + 86400)}}}"#
        box.sh(box.paths.hook.path.shellQuoted, input: input)

        var clock = now
        let kawari = Kawari(paths: box.paths, effects: RecordingEffects(), clock: { clock })
        let limits = try #require(kawari.limits["default"])
        #expect(limits.fiveHour?.used == 62)
        #expect(kawari.fiveHour(kawari.active) == 0.62)
        #expect(kawari.nextReset() == now + 3600)

        clock = now + 3601  // 过了重置时间，不用新数据也知道已经清零
        #expect(kawari.fiveHour(kawari.active) == 0)
        #expect(limits.sevenDay?.used(at: clock) == 23)
    }

    @Test func zshSnippetIsIdempotentAndRemovable() throws {
        box.write("export A=1\n", ".zshrc")
        try Zsh.install(box.paths)
        try Zsh.install(box.paths)
        let text = try #require(box.read(".zshrc"))
        #expect(text.components(separatedBy: Zsh.begin).count == 2)
        #expect(text.hasPrefix("export A=1\n\n"))
        try Zsh.uninstall(box.paths)
        #expect(box.read(".zshrc") == "export A=1\n")
    }

    @Test func zshFollowsCurrentAccount() throws {
        try Zsh.install(box.paths)
        let zsh = #"/bin/zsh -fc 'source ~/.zshrc; print -r -- "[${CLAUDE_CONFIG_DIR-unset}]"; '"#
        #expect(box.sh(zsh, env: ["CLAUDE_CONFIG_DIR": "/keep"]) == "[/keep]\n")  // 还没选过账号：不动
        box.write("/tmp/acct 2\n", ".config/kawari/current")
        #expect(box.sh(zsh) == "[/tmp/acct 2]\n")
        box.write("", ".config/kawari/current")
        #expect(box.sh(zsh, env: ["CLAUDE_CONFIG_DIR": "/old"]) == "[unset]\n")
    }
}

// MARK: - 用量

struct UsageTests {
    @Test func parseLimits() throws {
        let data = Data(#"{"rate_limits":{"five_hour":{"used_percentage":120,"resets_at":100}}}"#.utf8)
        let limits = try #require(Limits.parse(data))
        #expect(limits.fiveHour == Window(used: 100, resets: Date(timeIntervalSince1970: 100)))
        #expect(limits.sevenDay == nil)
        #expect(Limits.parse(Data(#"{"model":{}}"#.utf8)) == nil)
    }

    @Test func formats() {
        #expect(Format.tokens(999) == "999")
        #expect(Format.tokens(1234) == "1.2K")
        #expect(Format.tokens(12_345_678) == "12M")
        #expect(Format.tokens(2_100_000_000) == "2.1B")
        let now = Date(timeIntervalSince1970: 0)
        #expect(Format.until(now + 45 * 60, now: now) == "45m")
        #expect(Format.until(now + 80 * 60, now: now) == "1h 20m")
        #expect(Format.until(now + 2 * 3600, now: now) == "2h")
        #expect(Format.until(now + 76 * 3600, now: now) == "3d 4h")
    }

    @Test func ledgerCountsEachMessageOnceAndReadsIncrementally() throws {
        let box = Sandbox()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15 08:00 UTC
        func line(_ id: String, _ day: String, _ usage: String) -> String {
            #"{"type":"assistant","timestamp":"\#(day)T07:00:00.000Z","message":{"id":"\#(id)","usage":\#(usage)}}"#
        }
        let today = "2027-01-15", yesterday = "2027-01-14"
        let lines = [
            #"{"type":"user","message":{"content":"hi"}}"#,
            // 同一条消息按内容块写了两行
            line("m1", today, #"{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100}"#),
            line("m1", today, #"{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100}"#),
            // 顶层为 0，数字在 iterations 里
            line("m2", yesterday, #"{"input_tokens":0,"output_tokens":0,"iterations":[{"input_tokens":2,"output_tokens":8}]}"#),
            // 超过 14 天
            line("m3", "2026-12-01", #"{"input_tokens":1000}"#),
        ]
        box.write(lines.joined(separator: "\n") + "\n", ".claude/projects/p/s1.jsonl")
        box.write(line("m4", today, #"{"output_tokens":7}"#) + "\n", ".claude/projects/p/s1/subagents/agent-a.jsonl")

        let touch = { (path: String) in
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: box.home.appending(path: path).path)
        }
        try touch(".claude/projects/p/s1.jsonl")
        try touch(".claude/projects/p/s1/subagents/agent-a.jsonl")
        let ledger = Ledger(root: box.paths.projects, calendar: calendar)
        var totals = ledger.totals(now: now)
        #expect(totals.today == 115 + 7)
        #expect(totals.daily[Ledger.days - 2] == 10)
        #expect(totals.week == 132)

        // 追加：一行完整，一行还没写完
        let handle = try FileHandle(forWritingTo: box.home.appending(path: ".claude/projects/p/s1.jsonl"))
        try handle.seekToEnd()
        handle.write(Data((line("m5", today, #"{"output_tokens":3}"#) + "\n" + #"{"type":"assis"#).utf8))
        try handle.close()
        try touch(".claude/projects/p/s1.jsonl")
        totals = ledger.totals(now: now)
        #expect(totals.today == 125)

        // 整个替换（比如被裁剪后重写）且比原来长：从头再读，新消息在开头也不会漏，旧消息不重复计
        let filler = String(repeating: #"{"type":"user","message":{"content":"x"}}"# + "\n", count: 20)
        let replaced = [line("m6", today, #"{"output_tokens":4}"#), line("m5", today, #"{"output_tokens":3}"#)]
        try Data((replaced.joined(separator: "\n") + "\n" + filler).utf8)
            .write(to: box.home.appending(path: ".claude/projects/p/s1.jsonl"), options: .atomic)
        try touch(".claude/projects/p/s1.jsonl")
        totals = ledger.totals(now: now)
        #expect(totals.today == 129)
    }
}
