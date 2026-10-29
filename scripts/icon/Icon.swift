// App 图标的几何与绘制，矢量绘制到任意尺寸。由 scripts/icon.sh 调用。
import AppKit

enum Icon {
    static let indigo = CGColor(srgbRed: 0.345, green: 0.337, blue: 0.839, alpha: 1)  // systemIndigo

    /// 菜单栏圆环的放大版：浅色底板上一圈灰色轨道，约七成是靛蓝的额度弧。
    /// 画到 1024×1024、y 轴向下的坐标系里
    static func draw(in ctx: CGContext) {
        // 底板：macOS 图标栅格 824×824，连续圆角，带轻微投影与自上而下的浅灰渐变
        let tile = continuousRect(CGRect(x: 100, y: 100, width: 824, height: 824), radius: 185)
        ctx.saveGState()
        // 投影的偏移和模糊按设备像素计算、不随坐标缩放，要自己乘上比例；否则小尺寸的阴影溢出画布被裁成方块。
        // 设备坐标 y 轴向上，向下投影是负值
        let scale = ctx.ctm.a
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale, color: CGColor(gray: 0, alpha: 0.22))
        ctx.addPath(tile)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(tile)
        ctx.clip()
        // 纵向渐变：逐个像素行填充纯色。CGGradient 会加入抖动噪点，让 PNG 体积翻倍
        let rows = Int(1024 * scale)
        for row in 0..<rows {
            let y = CGFloat(row) / scale
            ctx.setFillColor(gray: 1 - 0.07 * min(max((y - 100) / 824, 0), 1), alpha: 1)
            ctx.fill(CGRect(x: 0, y: y, width: 1024, height: 1 / scale))
        }
        ctx.restoreGState()

        let center = CGPoint(x: 512, y: 512)
        arc(ctx, center, 250, from: 0, to: 1, width: 104, color: CGColor(gray: 0.86, alpha: 1))
        arc(ctx, center, 250, from: 0, to: 0.7, width: 104, color: indigo)
    }

    /// 从 12 点方向顺时针，起止用圈数（0–1）表示
    static func arc(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, from: CGFloat, to: CGFloat, width: CGFloat, color: CGColor) {
        let start = -CGFloat.pi / 2 + from * 2 * .pi, end = -CGFloat.pi / 2 + to * 2 * .pi
        ctx.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: false)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(color)
        ctx.strokePath()
    }

    /// macOS 图标的连续圆角（与 shio 相同的曲线）
    static func continuousRect(_ r: CGRect, radius: CGFloat) -> CGPath {
        let k = min(radius, min(r.width, r.height) / 2 / 1.52866483)
        let corners: [(CGPoint, CGVector, CGVector)] = [
            (CGPoint(x: r.maxX, y: r.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
            (CGPoint(x: r.maxX, y: r.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
            (CGPoint(x: r.minX, y: r.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
            (CGPoint(x: r.minX, y: r.minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
        ]
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r.minX + 1.52866483 * k, y: r.minY))
        for (c, into, out) in corners {
            func p(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
                CGPoint(x: c.x - into.dx * u * k + out.dx * v * k, y: c.y - into.dy * u * k + out.dy * v * k)
            }
            path.addLine(to: p(1.52866483, 0))
            path.addCurve(to: p(0.66993427, 0.06549600), control1: p(1.08849323, 0), control2: p(0.86840689, 0))
            path.addLine(to: p(0.63149399, 0.07491100))
            path.addCurve(to: p(0.07491176, 0.63149399), control1: p(0.37282392, 0.16905899), control2: p(0.16906013, 0.37282401))
            path.addCurve(to: p(0, 1.52866483), control1: p(0, 0.86840701), control2: p(0, 1.08849299))
        }
        path.closeSubpath()
        return path
    }

    static func render(px: Int) -> CGImage {
        let s = CGFloat(px) / 1024
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: 0, y: 1024)
        ctx.scaleBy(x: 1, y: -1)
        draw(in: ctx)
        return ctx.makeImage()!
    }
}
