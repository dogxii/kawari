import Foundation

/// 接入 Claude Code 的两处改动，都可以完整撤销：
/// - status line：Claude Code 每次刷新时把额度交给它，它记下来再转给原来的 status line
/// - ~/.zshrc：每条命令前读一次当前账号，已打开的终端也会跟着切换
enum Integration {
    static func installed(_ paths: Paths) -> Bool { Hook.installed(paths) && Zsh.installed(paths) }

    /// 任何一处失败就撤回另一处，不留半接入的状态
    static func install(_ paths: Paths) throws {
        do {
            try Hook.install(paths)
            try Zsh.install(paths)
        } catch {
            try? uninstall(paths)
            throw error
        }
    }

    /// 两处各自撤销，一处失败不影响另一处
    static func uninstall(_ paths: Paths) throws {
        var failure: Error?
        do { try Hook.uninstall(paths) } catch { failure = error }
        do { try Zsh.uninstall(paths) } catch { failure = failure ?? error }
        if let failure { throw failure }
    }
}

enum Hook {
    /// 写进 settings.json 的命令。用 ~ 而不是绝对路径，同步 dotfiles 到别的机器也能用
    static let command = "~/.config/kawari/statusline.sh"

    /// 账号由 CLAUDE_CONFIG_DIR 区分，额度写到 usage/<账号>.json（先写临时文件再改名，App 不会读到半截）。
    /// 输入先落到临时文件，原来的 status line 收到的字节与直接调用时完全一样（包括末尾换行）
    static let script = #"""
    #!/bin/sh
    # kawari：记下 Claude Code 交给 status line 的额度，再原样转给原来的 status line。
    dir=${CLAUDE_CONFIG_DIR%/}
    case $dir in "" | "$HOME/.claude") key=default ;; *) key=${dir##*/} ;; esac
    out=$HOME/.config/kawari/usage
    tmp=$out/.$key.$$
    trap 'rm -f "$tmp" "$tmp.json"' EXIT
    trap 'exit 1' HUP INT TERM
    mkdir -p "$out" && cat > "$tmp" || exit 0
    grep -q '"rate_limits"' "$tmp" && cp "$tmp" "$tmp.json" && mv -f "$tmp.json" "$out/$key.json"
    orig=$HOME/.config/kawari/statusline-original.sh
    [ -s "$orig" ] && sh "$orig" < "$tmp"
    exit 0

    """#

    /// 已接入时，把旧版本的脚本换成当前版本，并清掉旧版留下的会话记号目录
    static func upgrade(_ paths: Paths) {
        let fm = FileManager.default
        guard let current = try? String(contentsOf: paths.hook, encoding: .utf8), current != script else { return }
        try? Data(script.utf8).write(to: paths.hook, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.hook.path)
        for entry in (try? fm.contentsOfDirectory(at: paths.usage, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            try? fm.removeItem(at: entry)
        }
    }

    static func installed(_ paths: Paths) -> Bool {
        let line = JSONFile.read(paths.settings)?["statusLine"] as? [String: Any]
        return line?["command"] as? String == command
            && FileManager.default.isExecutableFile(atPath: paths.hook.path)
    }

    static func install(_ paths: Paths) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.usage, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: paths.hook, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.hook.path)

        var settings = try readSettings(paths)
        var line = settings["statusLine"] as? [String: Any] ?? [:]
        switch line["command"] as? String {
        case command?: break  // 已经是自己：保留之前记下的原命令
        case let original?: try Data(original.utf8).write(to: paths.originalStatusLine, options: .atomic)
        case nil: try? fm.removeItem(at: paths.originalStatusLine)  // 原来没有：别还原上一次的旧命令
        }
        line["type"] = "command"
        line["command"] = command
        settings["statusLine"] = line
        try fm.createDirectory(at: paths.primary, withIntermediateDirectories: true)
        try JSONFile.write(settings, to: paths.settings)
    }

    /// 还原原来的 status line；原来没有就去掉整项
    static func uninstall(_ paths: Paths) throws {
        var settings = try readSettings(paths)
        if var line = settings["statusLine"] as? [String: Any], line["command"] as? String == command {
            var original: String?
            do { original = try String(contentsOf: paths.originalStatusLine, encoding: .utf8) }
            catch CocoaError.fileReadNoSuchFile {}  // 原来就没有 status line
            if let original, !original.isEmpty {
                line["command"] = original
                settings["statusLine"] = line
            } else {
                settings["statusLine"] = nil
            }
            try JSONFile.write(settings, to: paths.settings)
        }
        try? FileManager.default.removeItem(at: paths.originalStatusLine)
        try? FileManager.default.removeItem(at: paths.hook)
    }

    /// 文件不存在或为空当作空设置；读不了或解析不了就报错，绝不覆盖用户的文件
    private static func readSettings(_ paths: Paths) throws -> [String: Any] {
        let data: Data
        do { data = try Data(contentsOf: paths.settings) } catch CocoaError.fileReadNoSuchFile { return [:] }
        guard !data.isEmpty else { return [:] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: paths.settings.path])
        }
        return json
    }
}

enum Zsh {
    static let begin = "# >>> kawari >>>", end = "# <<< kawari <<<"

    /// 在命令执行前（preexec）读取：停在提示符时切换，下一条 claude 就用新账号。
    /// read 是内建命令，多花的时间可以忽略
    static let snippet = """
    \(begin)
    # 每条命令执行前跟随菜单栏里选中的 Claude 账号（由 kawari 管理，可整段删除）
    _kawari() {
      [[ -r ~/.config/kawari/current ]] || return
      local dir; read -r dir < ~/.config/kawari/current
      if [[ -n $dir ]]; then export CLAUDE_CONFIG_DIR=$dir; else unset CLAUDE_CONFIG_DIR; fi
    }
    preexec_functions+=(_kawari)
    _kawari
    \(end)

    """

    static func installed(_ paths: Paths) -> Bool { (try? read(paths))?.contains(begin) ?? false }

    /// 已接入时，把旧版本的片段换成当前版本
    static func upgrade(_ paths: Paths) {
        guard let text = try? read(paths), let range = block(text), text[range] != snippet else { return }
        try? write(text.replacingCharacters(in: range, with: snippet), paths)
    }

    static func install(_ paths: Paths) throws {
        var text = try read(paths)
        guard !text.contains(begin) else { return }
        if !text.isEmpty { text += text.hasSuffix("\n") ? "\n" : "\n\n" }
        try write(text + snippet, paths)
    }

    static func uninstall(_ paths: Paths) throws {
        let text = try read(paths)
        guard let range = block(text) else { return }
        var head = String(text[..<range.lowerBound])
        if head.hasSuffix("\n\n") { head.removeLast() }
        try write(head + text[range.upperBound...], paths)
    }

    /// 从开始标记到结束标记后的换行
    private static func block(_ text: String) -> Range<String.Index>? {
        guard let start = text.range(of: begin), let stop = text.range(of: end, range: start.upperBound..<text.endIndex)
        else { return nil }
        let upper = text[stop.upperBound...].hasPrefix("\n") ? text.index(after: stop.upperBound) : stop.upperBound
        return start.lowerBound..<upper
    }

    /// 文件不存在当作空；读不了（权限、编码）就报错，绝不拿空内容覆盖用户的 .zshrc
    private static func read(_ paths: Paths) throws -> String {
        do { return try String(contentsOf: paths.zshrc, encoding: .utf8) } catch CocoaError.fileReadNoSuchFile { return "" }
    }

    private static func write(_ text: String, _ paths: Paths) throws {
        try Data(text.utf8).write(to: paths.zshrc.resolvingSymlinksInPath(), options: .atomic)
    }
}
