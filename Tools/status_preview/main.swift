#!/usr/bin/env swift
import AppKit

// 菜单栏图标预览：四种状态 × 浅色/深色 + 一条模拟菜单栏。
// 用法：
//   swiftc Sources/StatusIcon.swift Tools/status_preview/main.swift -o /tmp/preview-icon
//   /tmp/preview-icon
//
// 输出 /tmp/status-icon-preview.png

let light = NSAppearance(named: .aqua)!
let dark = NSAppearance(named: .darkAqua)!

let states: [(String, StatusIcon.State)] = [
    ("未连接", .idle),
    ("连接中", .connecting),
    ("已连接", .connected),
    ("失败", .failed)
]

let cellW: CGFloat = 132
let width = cellW * CGFloat(states.count) + 30
let height: CGFloat = 300

let canvas = NSImage(size: NSSize(width: width, height: height))
canvas.lockFocus()

NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
NSRect(x: 0, y: height / 2, width: width, height: height / 2).fill()
NSColor(calibratedRed: 0.24, green: 0.29, blue: 0.40, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height / 2).fill()

func drawRow(appearance: NSAppearance, dark: Bool, yBase: CGFloat) {
    appearance.performAsCurrentDrawingAppearance {
        for (i, (title, state)) in states.enumerated() {
            let x = 15 + CGFloat(i) * cellW
            let image = StatusIcon.image(state)

            // 放大版：看笔画细节
            image.draw(in: NSRect(x: x + 6, y: yBase + 38, width: 54, height: 54))
            // 实际大小 @2x：菜单栏里的真实观感
            image.draw(in: NSRect(x: x + 70, y: yBase + 47, width: 36, height: 36))

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.65)
            ]
            title.draw(at: NSPoint(x: x + 6, y: yBase + 10), withAttributes: attrs)
        }
    }
}

drawRow(appearance: light, dark: false, yBase: height / 2 + 4)
drawRow(appearance: dark, dark: true, yBase: 4)
canvas.unlockFocus()

// 模拟菜单栏：深底一条、浅底一条，都只有四枚图标，没有文字
func makeStrip(dark: Bool) -> NSImage {
    let strip = NSImage(size: NSSize(width: 160, height: 24))
    strip.lockFocus()
    if dark {
        NSColor(calibratedRed: 0.30, green: 0.36, blue: 0.48, alpha: 1).setFill()
    } else {
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
    }
    NSRect(x: 0, y: 0, width: 160, height: 24).fill()
    var x: CGFloat = 14
    for state in [StatusIcon.State.idle, .connected, .connecting, .failed] {
        StatusIcon.image(state).draw(in: NSRect(x: x, y: 3, width: 18, height: 18))
        x += 32
    }
    strip.unlockFocus()
    return strip
}
let darkStrip = makeStrip(dark: true)
let lightStrip = makeStrip(dark: false)

// 拼到预览图底部
let final = NSImage(size: NSSize(width: width, height: height + 34))
final.lockFocus()
canvas.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
darkStrip.draw(in: NSRect(x: 0, y: height + 6, width: 160, height: 24))
lightStrip.draw(in: NSRect(x: 170, y: height + 6, width: 160, height: 24))
final.unlockFocus()

guard let tiff = final.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("渲染失败")
}
try png.write(to: URL(fileURLWithPath: "/tmp/status-icon-preview.png"))
print("已生成 /tmp/status-icon-preview.png")
