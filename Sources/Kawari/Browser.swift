import Foundation

/// 每个账号一份浏览器数据目录，重新登录时不用在 claude.ai 上来回换账号。
/// 登录状态由浏览器自己保存：kawari 只决定官方登录页在哪个目录里打开，
/// 不读取其中的 Cookie 或令牌，也不做任何自动操作。
enum BrowserData {
    /// 建好数据目录，写好给 BROWSER 用的脚本，返回脚本路径
    static func prepare(_ bundleID: String, _ key: String, _ paths: Paths) throws -> URL {
        let fm = FileManager.default
        let data = paths.browserData(bundleID, key)
        try fm.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = paths.browserOpener(key)
        try Data(opener(bundleID, data).utf8).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    /// -n 才会把参数交给新进程；目录已有实例在运行时，浏览器自己会把链接转给它
    static func opener(_ bundleID: String, _ data: URL) -> String {
        """
        #!/bin/sh
        # kawari：在这个账号专用的浏览器数据目录里打开官方登录页
        exec /usr/bin/open -n -b \(bundleID.shellQuoted) --args --user-data-dir=\(data.path.shellQuoted) --no-first-run --no-default-browser-check "$1"

        """
    }

    /// 所有留有数据目录的账号编号。这些编号不能给新账号：旧浏览器可能还开着，同一路径不能有两个主人
    static func keys(_ paths: Paths) -> Set<String> {
        Set(entries(paths).map(\.lastPathComponent))
    }

    /// 账号已经不在、浏览器也已退出的数据目录。keeping 是还没移除完的账号
    static func orphans(_ paths: Paths, keeping: Set<String>) -> [URL] {
        entries(paths).filter { data in
            let key = data.lastPathComponent
            return key != Account.primaryKey && !keeping.contains(key)
                && !FileManager.default.fileExists(atPath: paths.accounts.appending(path: key).path)
                && !inUse(data)
        }
    }

    /// 把孤儿目录改名隔离，返回所有待删的目录（包括上次没删完的）。
    /// 先改名再后台删：隔离后的名字不会重复，排队中的删除碰不到之后用同一编号新建的目录
    static func collect(_ paths: Paths, keeping: Set<String>) -> [URL] {
        let fm = FileManager.default
        for data in orphans(paths, keeping: keeping) {
            try? fm.moveItem(at: data, to: paths.browsers.appending(path: "\(discardPrefix)\(UUID().uuidString)"))
        }
        let items = (try? fm.contentsOfDirectory(at: paths.browsers, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix(discardPrefix) }
    }

    /// 以点开头：不算账号的数据目录，也就不占编号
    private static let discardPrefix = ".discard-"

    /// Chromium 运行时在数据目录里放一个指向「主机名-进程号」的 SingletonLock。
    /// 读不懂就当作还在用：多留一个目录无妨，删掉正在用的目录不行
    static func inUse(_ data: URL) -> Bool {
        let lock = data.appending(path: "SingletonLock")
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lock.path) else { return false }
        guard let last = target.split(separator: "-").last, let pid = pid_t(last) else { return true }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Browsers/<浏览器>/<账号>。Chrome 与 Edge 的数据不通用，所以按浏览器分开
    private static func entries(_ paths: Paths) -> [URL] {
        subdirectories(paths.browsers).flatMap(subdirectories)
    }

    private static func subdirectories(_ dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }
}

/// 在终端里运行的登录脚本
enum LoginScript {
    /// - email: 重新登录时账号原来的邮箱。预填到登录页，登录后核对；它只是提示，不保证登录的就是这个账号
    /// - opener: 给 BROWSER 用的脚本；nil 表示用系统默认浏览器，不碰 BROWSER
    static func render(claude: String, dir: URL?, email: String?, opener: URL?) -> String {
        let claude = claude.shellQuoted
        let done = "printf '\\n%s\\n' \(String(localized: "登录完成，可以关闭这个窗口。").shellQuoted)"
        let lines = [
            "#!/bin/zsh -l",
            "# kawari：登录 Claude 账号",
            "clear",
            dir.map { "export CLAUDE_CONFIG_DIR=\($0.path.shellQuoted)" } ?? "unset CLAUDE_CONFIG_DIR",
            opener.map { "export BROWSER=\($0.path.shellQuoted)" },
            email.map { checkedLogin(claude: claude, email: $0, done: done) } ?? "\(claude) auth login && \(done)",
        ]
        return lines.compactMap { $0 }.joined(separator: "\n") + "\n"
    }

    private static func checkedLogin(claude: String, email: String, done: String) -> String {
        let different = String(localized: "注意：这次登录的不是 \(email)，而是：").shellQuoted
        let advice = String(localized: "这个账号位现在属于上面的邮箱。登错了就在 kawari 里重新登录。").shellQuoted
        let unknown = String(localized: "没能确认这次登录的是哪个账号，请在 kawari 面板里核对邮箱。").shellQuoted
        return """
        expected=\(email.shellQuoted)
        if \(claude) auth login --email "$expected"; then
          # plutil 失败时会把错误信息写到 stdout，所以要看退出码，不能只看输出是否为空
          if ! actual=$(\(claude) auth status --json 2>/dev/null | /usr/bin/plutil -extract email raw -o - - 2>/dev/null) || [[ -z $actual ]]; then
            printf '\\n%s\\n' \(unknown)
          elif [[ ${(L)actual} != ${(L)expected} ]]; then
            printf '\\n%s\\n%s\\n%s\\n' \(different) "$actual" \(advice)
          fi
          \(done)
        fi
        """
    }
}
