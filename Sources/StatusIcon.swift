import AppKit

/// 菜单栏图标：把校徽的「圆章 + 旦」抽象成 18pt 的矢量图形。
///
/// 为什么不用 SF Symbol：系统盾牌跟复旦没有关系，而且十几个 App 都在用，
/// 菜单栏里一眼分不出是谁。这里用校徽的轮廓（圆 + 旦字）。
///
/// 四种状态都是空心线稿，只有颜色不同：
/// 未连接跟系统（模板图）、连接中橙、已连接浅蓝、失败红。
/// 不做实心填充——菜单栏是 18pt 的小图，填满一块色反而比细线条更"重"，
/// 跟旁边那一排单色图标也不协调。
///
/// 尺寸固定 18×18 pt，同时生成 @1x/@2x/@3x 三个位图，
/// 菜单栏、外接屏、缩放模式下都不会糊。
enum StatusIcon {

    enum State {
        case idle
        case connecting
        case connected
        case failed
    }

    /// 模板图交给系统按菜单栏明暗着色，彩色图保持原色。
    static func isTemplate(_ state: State) -> Bool {
        state == .idle
    }

    static func image(_ state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for scale in 1...3 {
            if let rep = bitmap(state: state, scale: CGFloat(scale)) {
                image.addRepresentation(rep)
            }
        }
        image.isTemplate = isTemplate(state)
        return image
    }

    // MARK: 绘制

    private static func bitmap(state: State, scale: CGFloat) -> NSBitmapImageRep? {
        let side = Int(18 * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }

        rep.size = NSSize(width: 18, height: 18)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.shouldAntialias = true
        context.cgContext.scaleBy(x: scale, y: scale)

        draw(state: state)

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func draw(state: State) {
        // 模板图只看 alpha，颜色随便给；这里给黑色是为了在预览里看得见。
        let ink = NSColor(calibratedWhite: 0.13, alpha: 1)
        // 浅蓝：比校徽本身的 #233781 亮，深色菜单栏上也够显眼；
        // 放在浅色菜单栏上又不会像纯蓝那样发灰。
        let lightBlue = NSColor(srgbRed: 0.29, green: 0.60, blue: 0.98, alpha: 1)
        let orange = NSColor(calibratedRed: 0.94, green: 0.62, blue: 0.12, alpha: 1)
        let red = NSColor(calibratedRed: 0.87, green: 0.22, blue: 0.24, alpha: 1)

        let center = NSPoint(x: 9, y: 9)
        let radius: CGFloat = 7.85

        func circle(_ r: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r,
                                        width: r * 2, height: r * 2))
        }

        /// 校徽中心的「旦」，用宋体保证是字，不是几何方块。
        func dan(_ color: NSColor, size: CGFloat = 10.0) {
            let font = NSFont(name: "Songti SC Bold", size: size)
                ?? NSFont.systemFont(ofSize: size, weight: .bold)
            let text = NSAttributedString(string: "旦", attributes: [
                .font: font,
                .foregroundColor: color
            ])
            let bounds = text.size()
            text.draw(at: NSPoint(x: center.x - bounds.width / 2,
                                  y: center.y - bounds.height / 2 + 0.55))
        }

        switch state {
        case .idle:
            // 空心章：没连。模板图，菜单栏是黑底就自动变白。
            ink.setStroke()
            let ring = circle(radius)
            ring.lineWidth = 1.35
            ring.stroke()
            dan(ink)

        case .connecting:
            // 橙色空心：正在换授权码 / 起隧道。
            orange.setStroke()
            let ring = circle(radius)
            ring.lineWidth = 1.35
            ring.stroke()
            dan(orange)

        case .connected:
            // 空心章 + 浅蓝：只换线稿颜色，内部不填。
            lightBlue.setStroke()
            let ring = circle(radius)
            ring.lineWidth = 1.35
            ring.stroke()
            dan(lightBlue)

        case .failed:
            // 红色空心 + 感叹号：跟「还没连」区分开。
            red.setStroke()
            let ring = circle(radius)
            ring.lineWidth = 1.35
            ring.stroke()

            red.setStroke()
            let bar = NSBezierPath()
            bar.move(to: NSPoint(x: center.x, y: center.y + 2.2))
            bar.line(to: NSPoint(x: center.x, y: center.y - 1.6))
            bar.lineWidth = 1.6
            bar.lineCapStyle = .round
            bar.stroke()

            red.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 1.05, y: center.y - 4.5,
                                        width: 2.1, height: 2.1)).fill()
        }
    }
}
