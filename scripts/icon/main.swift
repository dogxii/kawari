// 生成 App 图标的 iconset：每个尺寸都直接矢量绘制，不从大图缩小。由 scripts/icon.sh 调用。
import AppKit
import ImageIO

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, Icon.render(px: base * scale), nil)
        CGImageDestinationFinalize(dest)
    }
}
