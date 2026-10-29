import Foundation

/// 全部状态：账号、当前账号、各账号额度、本地 token 用量。状态变化通过 `onChange` 通知界面。
@MainActor
final class Kawari {
    let paths: Paths
    private(set) var accounts: [Account] = []
    private(set) var activeKey = Account.primaryKey
    private(set) var limits: [String: Limits] = [:]
    private(set) var totals = Ledger.Totals()
    private(set) var integrated = false
    /// 正在终端里登录的新账号
    private(set) var pending: String?
    /// 正在退出登录、移走的账号：目录还在，但不再列出，也不能切过去
    private var removing: Set<String> = []
    /// 各账号上次看到的邮箱：换了身份就丢掉旧身份的额度
    private var emails: [String: String] = [:]

    var onChange: () -> Void = {}
    private let effects: Effects
    private let clock: () -> Date
    private let ledger: Ledger
    private var loginPoll: Timer?

    init(paths: Paths = Paths(), effects: Effects = SystemEffects(), clock: @escaping () -> Date = Date.init) {
        self.paths = paths
        self.effects = effects
        self.clock = clock
        ledger = Ledger(root: paths.projects)
        Hook.upgrade(paths)
        Zsh.upgrade(paths)
        reload()
    }

    /// launchctl 的环境变量重启后就没了，App 启动时补上；没选过账号就不碰
    func restoreEnvironment() {
        if FileManager.default.fileExists(atPath: paths.current.path) { effects.setEnvironment(active.dir?.path) }
    }

    var active: Account { accounts.first { $0.key == activeKey } ?? accounts[0] }

    // MARK: 读取

    /// 打开面板时调用：账号可能在终端里登录、退出过
    func reload() {
        accounts = scanAccounts()
        activeKey = readActive()
        integrated = Integration.installed(paths)
        // 主配置读不了（不存在、损坏）就不同步，免得把副账号的 MCP 清空
        let servers = JSONFile.read(paths.primaryConfig).map { $0["mcpServers"] as? [String: Any] ?? [:] }
        for account in accounts where !account.isPrimary && account.signedIn {
            if let dir = account.dir { try? Sharing.link(dir, to: paths.primary) }
            if let servers { Sharing.syncMCP(servers, to: account.config(paths)) }
        }
        for account in accounts {
            if let old = emails[account.key], old != account.email {
                try? FileManager.default.removeItem(at: paths.usage.appending(path: "\(account.key).json"))
            }
            emails[account.key] = account.email
        }
        reloadUsage()
    }

    /// status line 写入新的额度时调用
    func reloadUsage() {
        limits = accounts.reduce(into: [:]) { limits, account in
            let file = paths.usage.appending(path: "\(account.key).json")
            limits[account.key] = (try? Data(contentsOf: file)).flatMap(Limits.parse)
        }
        onChange()
    }

    /// 在后台增量统计，完成后通知界面
    func refreshTotals() {
        ledger.refresh(now: clock()) { totals in
            Task { @MainActor [weak self] in
                guard let self, self.totals != totals else { return }
                self.totals = totals
                onChange()
            }
        }
    }

    /// 账号按顺序标 A、B、C…，比首字母好认，也不会撞
    func letter(_ account: Account) -> String {
        let index = accounts.firstIndex { $0.key == account.key } ?? 0
        return index < 26 ? String(UnicodeScalar(UInt8(65 + index))) : "#"
    }

    /// 5 小时窗口的已用比例（0–1）；没有数据为 nil
    func fiveHour(_ account: Account) -> Double? {
        guard let limits = limits[account.key] else { return nil }
        return (limits.fiveHour?.used(at: clock()) ?? 0) / 100
    }

    private func scanAccounts() -> [Account] {
        func make(_ key: String, _ dir: URL?) -> Account {
            var account = Account(key: key, dir: dir)
            if let profile = Profile.read(account.config(paths)) {
                account.email = profile.email
                account.plan = profile.plan
            }
            return account
        }
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: paths.accounts, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        return [make(Account.primaryKey, nil)] + dirs
            .filter { $0.lastPathComponent != Account.primaryKey && !removing.contains($0.lastPathComponent) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { make($0.lastPathComponent, $0) }
    }

    /// 指向的目录已经不在了（比如在访达里手动删掉），就把终端和 launchctl 也一起切回主账号，
    /// 否则 Claude Code 会在原处建出一个空的未登录目录
    private func readActive() -> String {
        guard let text = try? String(contentsOf: paths.current, encoding: .utf8) else { return Account.primaryKey }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return Account.primaryKey }
        let dir = URL(filePath: path).standardizedFileURL.path
        if let account = accounts.first(where: { $0.dir?.standardizedFileURL.path == dir }) { return account.key }
        if (try? Data().write(to: paths.current, options: .atomic)) != nil { effects.setEnvironment(nil) }
        return Account.primaryKey
    }

    // MARK: 操作

    /// 切换账号：已打开的终端在下一条命令生效，之后打开的 App 也会使用它。正在运行的会话不受影响
    func activate(_ account: Account) {
        guard account.signedIn else { return login(account) }
        setActive(account)
    }

    @discardableResult
    private func setActive(_ account: Account) -> Bool {
        guard account.key != activeKey else { return true }
        do {
            try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
            try Data((account.dir?.path ?? "").utf8).write(to: paths.current, options: .atomic)
        } catch {
            return false
        }
        activeKey = account.key
        effects.setEnvironment(account.dir?.path)
        onChange()
        return true
    }

    /// 建好共用数据的新目录，然后在终端里走官方登录
    func addAccount() throws {
        let fm = FileManager.default
        let key = Sharing.nextKey(in: paths.accounts)
        let dir = paths.accounts.appending(path: key)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Sharing.seed(paths.primary)
        try Sharing.link(dir, to: paths.primary)
        let config = dir.appending(path: ".claude.json")
        try JSONFile.write(Sharing.inheritedConfig(JSONFile.read(paths.primaryConfig) ?? [:]), to: config)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        accounts = scanAccounts()
        if let account = accounts.first(where: { $0.key == key }) { login(account) }
    }

    func login(_ account: Account) {
        let environment = account.dir.map { "export CLAUDE_CONFIG_DIR=\($0.path.shellQuoted)" } ?? "unset CLAUDE_CONFIG_DIR"
        let done = String(localized: "登录完成，可以关闭这个窗口。")
        let script = """
        #!/bin/zsh -l
        # kawari：登录 Claude 账号
        clear
        \(environment)
        \(Claude.path?.shellQuoted ?? "claude") auth login && printf '\\n%s\\n' \(done.shellQuoted)

        """
        let file = paths.loginScript(account.key)
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: paths.support, withIntermediateDirectories: true)
            try Data(script.utf8).write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        } catch {
            return
        }
        effects.open(file)
        guard !account.signedIn else { return }
        pending = account.key
        onChange()
        watchLogin(account)
    }

    /// 等新账号在终端里登录完成，最多 10 分钟
    private func watchLogin(_ account: Account) {
        loginPoll?.invalidate()
        let deadline = clock() + 600
        loginPoll = .onMain(after: 2, every: 2, tolerance: 0.5) { [weak self] in
            guard let self else { return }
            let done = Profile.read(account.config(paths)) != nil
            guard done || clock() > deadline else { return }
            loginPoll?.invalidate()
            loginPoll = nil
            pending = nil
            reload()
        }
    }

    /// 退出登录并把目录移到废纸篓。目录里共用的数据都是软链接，主目录不受影响。
    /// 退出登录失败时保留目录（否则钥匙串里会留下凭证），回调 false；force 跳过退出登录
    func remove(_ account: Account, force: Bool = false, then done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard let dir = account.dir, !removing.contains(account.key),
              dir.deletingLastPathComponent().standardizedFileURL == paths.accounts.standardizedFileURL,
              account.key != activeKey || setActive(accounts[0])
        else { return }
        removing.insert(account.key)
        accounts.removeAll { $0.key == account.key }
        if pending == account.key {
            loginPoll?.invalidate()
            pending = nil
        }
        onChange()
        let usage = paths.usage.appending(path: "\(account.key).json")
        let script = paths.loginScript(account.key)
        effects.remove(dir, logout: !force) { [weak self] removed in
            self?.removing.remove(account.key)
            if removed {
                try? FileManager.default.removeItem(at: usage)
                try? FileManager.default.removeItem(at: script)
            }
            self?.reload()
            done(removed)
        }
    }

    func setIntegrated(_ on: Bool) throws {
        defer {
            integrated = Integration.installed(paths)
            onChange()
        }
        if on { try Integration.install(paths) } else { try Integration.uninstall(paths) }
    }

    /// 当前账号下一次有窗口重置的时间
    func nextReset() -> Date? { limits[activeKey]?.nextReset(after: clock()) }

    var now: Date { clock() }
}
