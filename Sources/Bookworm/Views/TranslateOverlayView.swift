import SwiftUI
import AppKit

/// Sits on top of a comic / manga page when translate mode is on. Vision OCR
/// returns one observation per *line* of text, which is the wrong unit to
/// translate against: a 3-line speech bubble would produce 3 disconnected
/// translations that each miss the context of the other two. So before
/// translation we group nearby line-observations into clusters (a cluster
/// is "probably one speech bubble or caption"), join their text in reading
/// order, and translate the joined sentence as a whole.
///
/// Coordinate system: the overlay is sized to `displaySize`. OCR clusters
/// carry normalized image-space rects (top-left origin, 0…1); their
/// `frameInView` runs the same aspect-fit math the underlying ZoomScrollView
/// uses so tooltips line up exactly with bubbles at .fitPage zoom. The
/// SwiftUI body re-evaluates whenever `displaySize` changes, so resizing
/// the window relocates every hit-rect automatically; ZoomScrollView's
/// resize-aware re-zoom keeps the image underneath aligned to match.
struct TranslateOverlayView: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject var settings: TranslationSettings
    let displaySize: CGSize

    @State private var image: NSImage?
    @State private var clusters: [OCRCluster] = []
    @State private var translations: [String: TranslationState] = [:]
    @State private var hoveredClusterID: String?
    @State private var pinnedClusterID: String?
    /// Hover events arriving while this is false are dropped. Flipped to
    /// true a beat after each page's OCR finishes so the cursor's resting
    /// position can't auto-show a tooltip the user didn't ask for.
    @State private var hoverActive: Bool = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let img = image {
                ForEach(Array(clusters.enumerated()), id: \.offset) { _, cluster in
                    let frame = cluster.frameInView(imageSize: img.size, displaySize: displaySize)
                    if frame.width > 2, frame.height > 2 {
                        clusterHitArea(cluster: cluster, frame: frame)
                    }
                }
                if let id = activeClusterID,
                   let cluster = clusters.first(where: { clusterID($0) == id }) {
                    let frame = cluster.frameInView(imageSize: img.size, displaySize: displaySize)
                    tooltip(for: cluster, anchor: frame)
                }
            }
        }
        .frame(width: displaySize.width, height: displaySize.height, alignment: .topLeading)
        .allowsHitTesting(true)
        .task(id: model.currentPage) {
            await loadAndScan()
        }
        .onChange(of: settings.engine) {
            // Engine swap mid-page: drop failed entries so a hover retries
            // with the new engine; keep loaded ones since the translation
            // itself is still valid.
            translations = translations.filter { _, v in
                if case .failed = v { return false } else { return true }
            }
        }
    }

    private var activeClusterID: String? { pinnedClusterID ?? hoveredClusterID }

    @ViewBuilder
    private func clusterHitArea(cluster: OCRCluster, frame: CGRect) -> some View {
        let id = clusterID(cluster)
        let isActive = (id == activeClusterID)
        Rectangle()
            .strokeBorder(Color.yellow.opacity(isActive ? 0.95 : 0.50),
                          lineWidth: isActive ? 1.6 : 1.0)
            .background(
                Rectangle().fill(Color.yellow.opacity(isActive ? 0.18 : 0.08))
            )
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .onHover { hovering in
                // Drop the initial-state hover SwiftUI fires when its
                // tracking area is installed under an already-resting
                // cursor. Once the user actually moves the mouse and
                // re-enters a bubble, hoverActive is true and the tooltip
                // shows normally.
                guard hoverActive else { return }
                if hovering {
                    hoveredClusterID = id
                    if translations[cluster.text] == nil {
                        // Lazy translation kicks in on first hover for engines
                        // we don't pre-translate (OpenAI).
                        kickOff(cluster: cluster)
                    }
                } else if hoveredClusterID == id {
                    hoveredClusterID = nil
                }
            }
            .onTapGesture {
                pinnedClusterID = (pinnedClusterID == id) ? nil : id
                if translations[cluster.text] == nil { kickOff(cluster: cluster) }
            }
            .contextMenu {
                Button("复制原文") { copyToPasteboard(cluster.text) }
                if case .loaded(let translation) = translations[cluster.text] {
                    Button("复制译文") { copyToPasteboard(translation) }
                }
            }
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @ViewBuilder
    private func tooltip(for cluster: OCRCluster, anchor: CGRect) -> some View {
        let state = translations[cluster.text] ?? .loading
        // Fixed width so the position math knows the tooltip's actual footprint.
        // Capped at ~45 % of the visible page so the translation has to wrap
        // onto several lines instead of stretching across the whole screen as
        // one long row.
        let width = tooltipWidth
        VStack(alignment: .leading, spacing: 4) {
            Text(cluster.text)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            switch state {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在翻译…").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            case .loaded(let translation):
                Text(translation)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: width, alignment: .leading)
        .background(.black.opacity(0.88))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.55), radius: 14, y: 6)
        .position(tooltipPosition(for: anchor, width: width))
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// Fixed pixel width for the tooltip — wide enough to hold a typical
    /// short sentence on one line, narrow enough to force a long sentence
    /// to wrap onto 2-3 lines instead of becoming a giant single row.
    /// Clamps to the page area so a small reader window still fits.
    private var tooltipWidth: CGFloat {
        max(200, min(320, displaySize.width * 0.45))
    }

    private func tooltipPosition(for anchor: CGRect, width: CGFloat) -> CGPoint {
        // Keep the WHOLE tooltip rect inside the display area, not just its
        // centre point — `.position(x:y:)` centres the view, so a tooltip of
        // width W whose centre is W/2 from the edge will paint partly
        // off-screen and get clipped. Clamping by halfWidth fixes the cropped
        // first/last characters the user was seeing on edge-adjacent bubbles.
        let edgePadding: CGFloat = 8
        let halfWidth = width / 2
        let minX = halfWidth + edgePadding
        let maxX = max(minX, displaySize.width - halfWidth - edgePadding)
        let x = min(max(anchor.midX, minX), maxX)

        let preferAbove = anchor.minY > 80
        let approxHeight: CGFloat = 100
        let y = preferAbove
            ? max(approxHeight / 2, anchor.minY - approxHeight / 2 - 6)
            : min(displaySize.height - approxHeight / 2,
                  anchor.maxY + approxHeight / 2 + 6)
        return CGPoint(x: x, y: y)
    }

    private func clusterID(_ cluster: OCRCluster) -> String {
        // Position + text so identical sentences at different points on the
        // page still get distinct hover state.
        "\(Int(cluster.rect.minX * 10000))-\(Int(cluster.rect.minY * 10000))-\(cluster.text.prefix(40))"
    }

    // MARK: - OCR + translation

    private func loadAndScan() async {
        guard model.translateMode else { return }
        // Suppress hover events until after the page is ready and the user
        // has had a moment — otherwise the cursor's resting spot triggers
        // an immediate auto-tooltip the moment translate mode flips on.
        hoverActive = false
        hoveredClusterID = nil
        translations = [:]
        clusters = []
        image = nil

        guard let img = await model.image(at: model.currentPage) else { return }
        image = img

        let lang = settings.sourceLanguage.visionRecognitionLanguage
        let detected = await OCRService.shared.recognize(in: img, recognitionLanguage: lang)
        let cleaned = detected.filter {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
        }
        let grouped = OCRService.cluster(cleaned).filter { !$0.text.isEmpty }
        clusters = grouped

        // Free engines pre-translate the whole page so hovers are instant.
        // OpenAI translates lazily on first hover so the user's quota isn't
        // spent on bubbles that may never get looked at.
        if settings.engine != .openai {
            for cluster in grouped where translations[cluster.text] == nil {
                kickOff(cluster: cluster)
            }
        }

        // Live Text fallback. Vision's recogniser returns zero observations
        // on stylised manga fonts in both Japanese and Chinese. When that
        // happens we ask VisionKit's `ImageAnalyzer` for the whole page's
        // transcript and surface it in the side panel — the only translation
        // path that actually works on those pages. Skipping the call when
        // Vision already found a useful number of clusters keeps the cost
        // off the happy path.
        let needsLiveTextFallback = grouped.count < 2 && isCJKOrAuto(lang)
        if needsLiveTextFallback {
            let lines = await OCRService.shared.recognizeFullPageTranscript(in: img)
            model.pageTranscriptLines = lines
            if !lines.isEmpty {
                model.translationPanelVisible = true
            }
        } else {
            // Vision found bubbles → tooltips do the work; clear any stale
            // panel content from the previous page so the panel header
            // doesn't show last page's lines after navigation.
            model.pageTranscriptLines = []
        }

        // Brief beat after the boxes appear before we start honouring hover.
        // SwiftUI's .onHover fires hover=true on tracking-area install if the
        // cursor is already inside; after this wait, hoverActive flips true
        // but no new tracking event fires, so the user has to actually move
        // the cursor onto a bubble for the first tooltip to appear.
        try? await Task.sleep(nanoseconds: 350_000_000)
        if !Task.isCancelled {
            hoverActive = true
        }
    }

    /// Live Text fallback is gated to CJK languages because Vision's
    /// blind spot is specifically on stylised CJK fonts (and pretty
    /// reliably handles Latin manga lettering). For other source
    /// languages a 0-cluster result is more likely "actually no text
    /// on this page" than "engine failed".
    private func isCJKOrAuto(_ language: String?) -> Bool {
        guard let language = language?.lowercased() else { return true }
        return language.hasPrefix("ja") || language.hasPrefix("zh") || language.hasPrefix("ko")
    }

    private func kickOff(cluster: OCRCluster) {
        let text = cluster.text
        translations[text] = .loading
        let sourceCode = settings.sourceLanguage == .auto ? nil : settings.sourceLanguage.rawValue
        let target = settings.targetLanguage.rawValue
        let settingsSnapshot = settings
        Task { @MainActor in
            do {
                let translation = try await Translator.translate(
                    text,
                    source: sourceCode,
                    target: target,
                    settings: settingsSnapshot
                )
                translations[text] = .loaded(translation)
            } catch {
                translations[text] = .failed(error.localizedDescription)
            }
        }
    }
}
