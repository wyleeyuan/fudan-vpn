#!/usr/bin/env swift
import AppKit
import CoreGraphics

// 生成 App 图标：复旦蓝渐变圆角方形 + 反白校徽。
// 用法：swift Tools/make_icon.swift
// 输入：Resources/icon-source.png（官方校徽，透明底蓝色线条）
// 输出：build/icon_1024.png 与 build/FudanVPN.iconset/

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("Resources/icon-source.png")
let outDir = root.appendingPathComponent("build", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let size = 1024
guard let source = NSImage(contentsOf: sourceURL),
      let srcCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("找不到校徽源图：\(sourceURL.path)\n".data(using: .utf8)!)
    exit(1)
}

let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil,
                          width: size, height: size,
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}

let S = CGFloat(size)
// 不翻转 CTM：`clip(to:mask:)` 会用当前变换矩阵绘制蒙版，
// 翻转后校徽会整个镜像（文字正常、图案左右反过来），很难发现。
// 所以统一用标准 CoreGraphics 坐标（原点左下），位置处各自换算。
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

// MARK: 底板

// macOS 图标网格：824×824 的圆角方形，四周留 100。矩形居中，翻不翻转都一样。
let inset: CGFloat = 100
let plate = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let radius: CGFloat = 180
let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()

// 复旦蓝的明暗两段：左上偏亮、右下偏深，模拟光从左上打过来。
let top = CGColor(red: 0.11, green: 0.30, blue: 0.62, alpha: 1.0)
let bottom = CGColor(red: 0.02, green: 0.10, blue: 0.26, alpha: 1.0)
if let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) {
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: S - inset),
                           end: CGPoint(x: S, y: inset),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// 右上角一团柔光，避免大面积纯色发闷。
if let glow = CGGradient(colorsSpace: space,
                         colors: [CGColor(red: 0.45, green: 0.65, blue: 1.0, alpha: 0.26),
                                  CGColor(red: 0.45, green: 0.65, blue: 1.0, alpha: 0.0)] as CFArray,
                         locations: [0, 1]) {
    let center = CGPoint(x: S * 0.78, y: S * 0.84)
    ctx.drawRadialGradient(glow,
                           startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: S * 0.62,
                           options: [])
}
ctx.restoreGState()

// MARK: 校徽（用 alpha 当蒙版填白）

let emblemSide: CGFloat = 596
let emblemRect = CGRect(x: (S - emblemSide) / 2,
                        y: (S - emblemSide) / 2,
                        width: emblemSide,
                        height: emblemSide)

ctx.saveGState()
ctx.clip(to: emblemRect, mask: srcCG)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(emblemRect)
ctx.restoreGState()

// MARK: 顶部高光描边

ctx.saveGState()
ctx.addPath(platePath)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
ctx.setLineWidth(4)
ctx.strokePath()
ctx.restoreGState()

// MARK: 输出

guard let image = ctx.makeImage() else { exit(1) }
let pngURL = outDir.appendingPathComponent("icon_1024.png")
guard let dest = CGImageDestinationCreateWithURL(pngURL as CFURL, "public.png" as CFString, 1, nil) else {
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("已生成 \(pngURL.path)")

// MARK: iconset

let iconset = outDir.appendingPathComponent("FudanVPN.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: size, height: size)

for (name, px) in variants {
    let target = iconset.appendingPathComponent("\(name).png")
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    proc.arguments = ["-z", "\(px)", "\(px)", pngURL.path, "--out", target.path]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
    proc.waitUntilExit()
}
print("已生成 iconset：\(iconset.path)")
