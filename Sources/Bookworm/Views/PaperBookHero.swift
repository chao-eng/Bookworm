import SwiftUI
import ImageIO

/// 手绘翻页书的 G 帧序列。原始素材约 9.3fps、7 帧、750ms 一轮，
/// 这里按原始时长精确切帧，播放时整体放慢，避免翻页顿挫被放大。
private enum BookGIFTrack {
    struct Track {
        var frames: [CGImage] = []
        var durations: [Double] = []
        var total: Double = 0
    }

    static let shared: Track = {
        var track = Track()
        // 必须先查 Bundle.main：打包 .app 时 build-app.sh 把资源平铺进
        // Contents/Resources/。Bundle.module 的访问器在找不到 SPM bundle 时
        // 会直接 fatalError（历史上曾在分发版触发 SIGTRAP 首启动崩溃），
        // 不能作为第一查找路径，只用来兜底 swift run 的开发场景。
        guard let url = Bundle.main.url(forResource: "onboarding_book", withExtension: "gif")
                ?? Bundle.module.url(forResource: "onboarding_book", withExtension: "gif"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return track }

        for index in 0..<CGImageSourceGetCount(source) {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
                ?? 0.1
            track.frames.append(frame)
            track.durations.append(max(delay, 0.02))
        }
        track.total = track.durations.reduce(0, +)
        return track
    }()
}

/// 首页主视觉：直接播放手绘翻页书的透明 GIF 帧序列，
/// 只叠一层随插画轮廓生成的投影和缓慢浮动，让画面像浮在背景上。
struct PaperBookHero: View {
    var size: CGFloat = 360
    /// 相对原始帧时长整体放慢的倍率，越大越慢。
    var speed: Double = 2.4

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let float = sin(time * 0.7) * 5

            artwork(time: time)
                .offset(y: float)
        }
        .frame(width: size * 1.4, height: size * 1.4)
    }

    private func artwork(time: TimeInterval) -> some View {
        let frame = currentFrame(in: BookGIFTrack.shared, at: time)

        return ZStack {
            if let frame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.55), radius: size * 0.10, y: size * 0.06)
        .shadow(color: .black.opacity(0.25), radius: size * 0.03, y: size * 0.015)
    }

    private func currentFrame(in track: BookGIFTrack.Track, at time: TimeInterval) -> CGImage? {
        guard !track.frames.isEmpty else { return nil }
        let realLoop = track.total * speed
        guard realLoop > 0 else { return track.frames.first }

        let elapsed = time.truncatingRemainder(dividingBy: realLoop) / speed
        var accumulated = 0.0
        for (index, duration) in track.durations.enumerated() {
            if accumulated + duration > elapsed {
                return track.frames[index]
            }
            accumulated += duration
        }
        return track.frames.last
    }
}
