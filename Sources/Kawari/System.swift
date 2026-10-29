import AppKit
import ServiceManagement
import UniformTypeIdentifiers

extension Bundle {
    /// 作为 .app 运行（swift run / 测试中为 false）。开机启动依赖它。
    var isApp: Bool { bundleURL.pathExtension == "app" }
}

extension Timer {
    /// 在主 run loop 的 common 模式（菜单打开时也会触发）上调度。
    /// - every: 首次触发后按此间隔重复；为 nil 时只触发一次
    @MainActor
    static func onMain(after delay: TimeInterval, every interval: TimeInterval? = nil, tolerance: TimeInterval = 0,
                       _ action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(fire: Date() + delay, interval: interval ?? 0, repeats: interval != nil) { _ in
            MainActor.assumeIsolated(action)
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

/// 对系统的副作用。默认真的去做，测试中替换为记录用的替身。
@MainActor
protocol Effects: AnyObject {
    /// 让之后从访达、程序坞打开的 App 也用这个账号；nil 表示主账号
    func setEnvironment(_ dir: String?)
    /// 用默认终端运行 .command 脚本
    func open(_ script: URL)
    /// 先退出该目录的登录（Claude Code 会删掉对应的钥匙串条目），成功了再把目录移到废纸篓。
    /// logout 为 false 时直接移走；回调目录是否已移走
    func remove(_ dir: URL, logout: Bool, then done: @escaping @MainActor @Sendable (Bool) -> Void)
}

@MainActor
final class SystemEffects: Effects {
    /// 按顺序执行，快速连切时最后一次选择一定最后生效
    private let launchctl = DispatchQueue(label: "kawari.launchctl")

    func setEnvironment(_ dir: String?) {
        let arguments = dir.map { ["setenv", "CLAUDE_CONFIG_DIR", $0] } ?? ["unsetenv", "CLAUDE_CONFIG_DIR"]
        launchctl.async { Self.run("/bin/launchctl", arguments) }
    }

    func open(_ script: URL) {
        guard let app = Terminal.selected else {
            NSWorkspace.shared.open(script)
            return
        }
        NSWorkspace.shared.open([script], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func remove(_ dir: URL, logout: Bool, then done: @escaping @MainActor @Sendable (Bool) -> Void) {
        let claude = Claude.path
        Task.detached {
            if logout {
                guard let claude else { return await done(false) }
                // npm 装的 claude 需要同目录的 node；从访达打开的 App 的 PATH 里没有它
                let bin = URL(filePath: claude).resolvingSymlinksInPath().deletingLastPathComponent().path
                let path = [URL(filePath: claude).deletingLastPathComponent().path, bin, "/opt/homebrew/bin", "/usr/local/bin",
                            ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
                let ok = Self.run(claude, ["auth", "logout"], environment: ["CLAUDE_CONFIG_DIR": dir.path, "PATH": path])
                guard ok else { return await done(false) }
            }
            let recycled = (try? await NSWorkspace.shared.recycle([dir])) != nil
            await done(recycled)
        }
    }

    /// 运行并等待结束，返回是否成功退出
    @discardableResult
    nonisolated private static func run(_ path: String, _ arguments: [String], environment: [String: String] = [:]) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

enum Claude {
    /// 从访达打开的 App 拿不到 shell 的 PATH，按常见安装位置找
    static let path: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }()
}

/// 目录里有文件新增、改名或删除时回调（status line 写完用量会改名替换）
@MainActor
final class DirectoryWatch {
    private var source: DispatchSourceFileSystemObject?

    init?(_ url: URL, _ action: @escaping @MainActor () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated(action) }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }
}

@MainActor
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    static func toggle() {
        do {
            if enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSSound.beep()
        }
    }
}

/// 登录用哪个终端打开。macOS 没有「默认终端」的设置，默认跟随 .command 文件的打开方式
@MainActor
enum Terminal {
    /// 常见终端；只列出装了、并且能打开 .command 的
    private static let known = [
        "com.apple.Terminal", "com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.github.wez.wezterm", "net.kovidgoyal.kitty", "co.zeit.hyper",
    ]
    private static let key = "terminal"

    static var installed: [URL] {
        guard let command = UTType(filenameExtension: "command") else { return [] }
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: command)
        return known.compactMap { id in apps.first { Bundle(url: $0)?.bundleIdentifier == id } }
    }

    /// 系统里 .command 默认用的 App
    static var systemDefault: URL? {
        UTType(filenameExtension: "command").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }

    /// nil 表示跟随系统；选过的终端被卸载了也回到跟随系统
    static var selected: URL? {
        guard let id = UserDefaults.standard.string(forKey: key) else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    static var selectedID: String? { selected == nil ? nil : UserDefaults.standard.string(forKey: key) }

    static func select(_ app: URL?) {
        UserDefaults.standard.set(app.flatMap { Bundle(url: $0)?.bundleIdentifier }, forKey: key)
    }

    static func name(_ app: URL) -> String { FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "") }
}

/// 界面语言：写进 App 自己的 AppleLanguages，重启后生效。nil 表示跟随系统
@MainActor
enum Language {
    static let choices = [("zh-Hans", "中文"), ("en", "English")]

    static var selected: String? {
        (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"]
            as? [String])?.first
    }

    static func select(_ code: String?) {
        guard code != selected else { return }
        if let code { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
        else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        relaunch()
    }

    /// 等当前进程退出后再打开自己，避免菜单栏里短暂出现两个图标
    private static func relaunch() {
        let task = Process()
        task.executableURL = URL(filePath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"",
                          Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
