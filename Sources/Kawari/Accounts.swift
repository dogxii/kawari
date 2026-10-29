import Foundation

/// 所有落盘位置。测试中把 home 换成临时目录。
struct Paths: Sendable {
    let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    /// 主账号：不设 CLAUDE_CONFIG_DIR 时 Claude Code 的默认目录，也存着所有账号共用的数据
    var primary: URL { home.appending(path: ".claude") }
    var primaryConfig: URL { home.appending(path: ".claude.json") }
    var settings: URL { primary.appending(path: "settings.json") }
    var projects: URL { primary.appending(path: "projects") }
    /// 其余账号各占一个目录，按官方的 CLAUDE_CONFIG_DIR 方式隔离登录
    var accounts: URL { home.appending(path: ".claude-accounts") }
    /// 终端与 status line 也要读写，所以放在点目录而不是 Application Support
    var support: URL { home.appending(path: ".config/kawari") }
    var current: URL { support.appending(path: "current") }
    var usage: URL { support.appending(path: "usage") }
    var hook: URL { support.appending(path: "statusline.sh") }
    var originalStatusLine: URL { support.appending(path: "statusline-original.sh") }
    /// 每个账号一份，连续登录几个账号时互不覆盖
    func loginScript(_ key: String) -> URL { support.appending(path: "login-\(key).command") }
    var zshrc: URL { home.appending(path: ".zshrc") }
}

struct Account: Equatable, Sendable {
    static let primaryKey = "default"

    /// 主账号是 default，其余是 ~/.claude-accounts 下的目录名；status line 记录用量时也用它
    let key: String
    /// nil 表示主账号（~/.claude，不设 CLAUDE_CONFIG_DIR）
    let dir: URL?
    var email: String?
    var plan: String?

    var isPrimary: Bool { dir == nil }
    var signedIn: Bool { email != nil }

    func config(_ paths: Paths) -> URL { dir?.appending(path: ".claude.json") ?? paths.primaryConfig }
}

/// 从 .claude.json 的 oauthAccount 读出账号身份。这是 Claude Code 自己写的文件，只读不改。
enum Profile {
    static func read(_ url: URL) -> (email: String, plan: String?)? {
        guard let json = JSONFile.read(url),
              let oauth = json["oauthAccount"] as? [String: Any],
              let email = oauth["emailAddress"] as? String
        else { return nil }
        return (email, plan(oauth))
    }

    static func plan(_ oauth: [String: Any]) -> String? {
        let tier = ["userRateLimitTier", "organizationRateLimitTier"]
            .compactMap { oauth[$0] as? String }.joined(separator: " ")
        switch oauth["organizationType"] as? String {
        case "claude_max": return tier.contains("20x") ? "Max 20x" : tier.contains("5x") ? "Max 5x" : "Max"
        case "claude_pro": return "Pro"
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        default: return nil
        }
    }
}

/// 副账号目录里除了登录身份，其余全部软链接到 ~/.claude：
/// 会话记录、历史、设置、skills、插件都是同一份，换账号就像只换了一把钥匙。
enum Sharing {
    /// 各账号自己的：账号配置（含其锁与备份）和钥匙串写不进时的凭证文件
    static func isPrivate(_ name: String) -> Bool {
        name.hasPrefix(".claude.json") || name == ".credentials.json" || name == "backups" || name == ".DS_Store"
    }

    /// 预先在主目录建好：否则副账号先用到时会在自己目录里另建一份，记录就分开了
    static let seededDirectories = [
        "projects", "sessions", "todos", "plans", "file-history", "shell-snapshots", "session-env",
        "skills", "agents", "commands",
    ]
    static let seededFiles = ["history.jsonl": "", "settings.json": "{}\n"]

    static func seed(_ primary: URL) throws {
        let fm = FileManager.default
        for name in seededDirectories {
            try fm.createDirectory(at: primary.appending(path: name), withIntermediateDirectories: true)
        }
        for (name, content) in seededFiles where !fm.fileExists(atPath: primary.appending(path: name).path) {
            try Data(content.utf8).write(to: primary.appending(path: name))
        }
    }

    /// 补齐缺少的链接。已存在的条目（哪怕是副账号自己的文件）一律不动。
    static func link(_ dir: URL, to primary: URL) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: primary.path) where !isPrivate(name) {
            let target = dir.appending(path: name)
            if (try? target.checkResourceIsReachable()) == true || isSymlink(target) { continue }
            try fm.createSymbolicLink(at: target, withDestinationURL: primary.appending(path: name))
        }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// 新账号沿用主账号的引导完成状态、项目信任与 MCP 服务器，第一次打开就不用再走一遍
    static let inheritedKeys: Set = [
        "hasCompletedOnboarding", "lastOnboardingVersion", "theme", "projects", "mcpServers",
        "installMethod", "autoUpdates", "editorMode", "lastReleaseNotesSeen", "migrationVersion",
    ]

    static func inheritedConfig(_ primary: [String: Any]) -> [String: Any] {
        primary.filter { inheritedKeys.contains($0.key) || $0.key.hasSuffix("MigrationComplete") }
    }

    /// 之后主账号新增或改动的 MCP 服务器同步给副账号（单向，以主账号为准）。
    /// 这个文件 Claude Code 也在写：写之前确认读出后没被改过，改过就留到下次再同步
    static func syncMCP(_ servers: [String: Any], to config: URL) {
        let modified = { try? config.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let before = modified()
        guard var target = JSONFile.read(config) else { return }
        let existing = target["mcpServers"] as? [String: Any] ?? [:]
        guard !NSDictionary(dictionary: servers).isEqual(to: existing) else { return }
        target["mcpServers"] = servers
        guard modified() == before else { return }
        try? JSONFile.write(target, to: config)
    }

    static func nextKey(in accounts: URL) -> String {
        var n = 2
        while FileManager.default.fileExists(atPath: accounts.appending(path: "\(n)").path) { n += 1 }
        return "\(n)"
    }
}

enum JSONFile {
    static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 原子写入；目标若是软链接（比如 dotfiles 管理的），写到它指向的真实文件
    static func write(_ json: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url.resolvingSymlinksInPath(), options: .atomic)
    }
}

extension String {
    /// 单引号包起来，供 shell 脚本安全使用
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
}
