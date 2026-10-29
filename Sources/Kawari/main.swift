import AppKit

// 带参数（或经由 kawari 软链接）运行时是命令行工具，否则是菜单栏 App
if CLI.invoked { exit(CLI.main()) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
