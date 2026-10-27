// 由一张源插画生成 macOS App 图标，流程：
//  1. 在 1024×1024 画布中央放置 824×824 的圆角主体（四周留 100px 安全区，容纳系统投影）。
//  2. 主体内铺暖米色渐变背景，并用正片叠底把白底线稿融进背景，只保留黑色线条。
//  3. 按 iconset 规格逐尺寸重新渲染（16…1024，1x/2x）。
//  4. 用 iconutil 打包为 AppIcon.icns。
//
// 运行：
//   swift scripts/make-appicon.swift Resources/AppIcon-source.png

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-appicon.swift <source.png>\n".utf8))
    exit(2)
}

let sourcePath = CommandLine.arguments[1]
guard FileManager.default.fileExists(atPath: sourcePath),
      let src = NSImage(contentsOfFile: sourcePath),
      let srcCG = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("无法读取源图：\(sourcePath)\n".utf8))
    exit(1)
}

let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resourcesDir = projectRoot.appendingPathComponent("Resources", isDirectory: true)
let iconsetDir = resourcesDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let canvas = 1024                       // 画布边长
let tile = 824                          // 主体圆角矩形边长（约 80%）
let tileOrigin = (canvas - tile) / 2    // 单边留白 100px
let cornerRadius = CGFloat(tile) * 0.2237   // Big Sur+ 圆角半径近似
let artInset = CGFloat(tile) * 0.045    // 线稿与主体边缘的内边距

let colorSpace = CGColorSpaceCreateDeviceRGB()

/// 扫描源图，返回线稿（非白底像素）的外接矩形，用于裁掉插画自带的空白边。
func artworkBounds(of image: CGImage) -> CGRect {
    let width = image.width
    let height = image.height
    let full = CGRect(x: 0, y: 0, width: width, height: height)
    guard let ctx = CGContext(data: nil,
                              width: width,
                              height: height,
                              bitsPerComponent: 8,
                              bytesPerRow: width * 4,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return full
    }
    ctx.draw(image, in: full)
    guard let raw = ctx.data else { return full }
    let pixels = raw.bindMemory(to: UInt8.self, capacity: width * height * 4)

    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        let rowOffset = y * width * 4
        for x in 0..<width {
            let i = rowOffset + x * 4
            let isInk = pixels[i] < 240 || pixels[i + 1] < 240 || pixels[i + 2] < 240
            if isInk {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }
    guard maxX >= minX, maxY >= minY else { return full }

    // CGContext 原点在左下，CGImage.cropping 以左上为原点，需翻转 y。
    let margin = 2
    let cropX = max(0, minX - margin)
    let cropY = max(0, height - 1 - maxY - margin)
    let cropW = min(width - cropX, maxX - minX + 1 + margin * 2)
    let cropH = min(height - cropY, maxY - minY + 1 + margin * 2)
    return CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
}

/// 裁掉源图自带的空白边后，取到的纯线稿。
let artwork: CGImage = srcCG.cropping(to: artworkBounds(of: srcCG)) ?? srcCG

/// 合成 1024 画布：透明安全区 + 暖米色圆角主体 + 正片叠底线稿。
func composeIcon() -> CGImage {
    guard let ctx = CGContext(data: nil,
                              width: canvas,
                              height: canvas,
                              bitsPerComponent: 8,
                              bytesPerRow: canvas * 4,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        FileHandle.standardError.write(Data("无法创建 \(canvas) 画布\n".utf8))
        exit(1)
    }

    let tileRect = CGRect(x: tileOrigin, y: tileOrigin, width: tile, height: tile)

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tileRect,
                       cornerWidth: cornerRadius,
                       cornerHeight: cornerRadius,
                       transform: nil))
    ctx.clip()

    // 背景：上浅下深的暖米色渐变，模拟纸张；避免纯白在浅色桌面上糊成一片。
    let top = NSColor(calibratedRed: 1.00, green: 0.98, blue: 0.93, alpha: 1).cgColor
    let bottom = NSColor(calibratedRed: 0.95, green: 0.88, blue: 0.74, alpha: 1).cgColor
    if let gradient = CGGradient(colorsSpace: colorSpace,
                                 colors: [top, bottom] as CFArray,
                                 locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: tileRect.maxY),
                               end: CGPoint(x: 0, y: tileRect.minY),
                               options: [])
    }

    // 线稿用正片叠底绘制：白底与背景相乘后自然消失，只剩黑色笔画。
    ctx.setBlendMode(.multiply)
    ctx.interpolationQuality = .high
    let box = tileRect.insetBy(dx: artInset, dy: artInset)
    let scale = min(box.width / CGFloat(artwork.width), box.height / CGFloat(artwork.height))
    let artW = CGFloat(artwork.width) * scale
    let artH = CGFloat(artwork.height) * scale
    ctx.draw(artwork, in: CGRect(x: box.midX - artW / 2,
                                 y: box.midY - artH / 2,
                                 width: artW,
                                 height: artH))
    ctx.restoreGState()

    guard let out = ctx.makeImage() else {
        FileHandle.standardError.write(Data("合成图标失败\n".utf8))
        exit(1)
    }
    return out
}

/// 把合成好的 1024 图缩放到指定尺寸并编码为 PNG。
func pngData(composed: CGImage, side: Int) -> Data {
    guard let ctx = CGContext(data: nil,
                              width: side,
                              height: side,
                              bitsPerComponent: 8,
                              bytesPerRow: side * 4,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        FileHandle.standardError.write(Data("无法创建 \(side) 画布\n".utf8))
        exit(1)
    }
    ctx.interpolationQuality = .high
    ctx.draw(composed, in: CGRect(x: 0, y: 0, width: side, height: side))

    guard let cgOut = ctx.makeImage() else {
        FileHandle.standardError.write(Data("无法生成 \(side) 位图\n".utf8))
        exit(1)
    }
    let mutable = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(mutable,
                                                      UTType.png.identifier as CFString,
                                                      1,
                                                      nil) else {
        FileHandle.standardError.write(Data("无法创建 \(side) 输出\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(dest, cgOut, nil)
    if !CGImageDestinationFinalize(dest) {
        FileHandle.standardError.write(Data("无法编码 \(side) PNG\n".utf8))
        exit(1)
    }
    return mutable as Data
}

// (物理像素尺寸, iconset 文件名)
let entries: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

let composed = composeIcon()

for (side, name) in entries {
    let data = pngData(composed: composed, side: side)
    try data.write(to: iconsetDir.appendingPathComponent(name))
    print("  ✓ \(name) (\(side)×\(side))")
}

print("正在用 iconutil 打包…")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns",
                  "-o", resourcesDir.appendingPathComponent("AppIcon.icns").path,
                  iconsetDir.path]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil 失败（状态 \(proc.terminationStatus)）\n".utf8))
    exit(1)
}

print("已写入 Resources/AppIcon.icns")
