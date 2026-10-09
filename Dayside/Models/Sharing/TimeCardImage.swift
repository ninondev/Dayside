// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

/// 一张能丢进 Slack / 微信的 PNG 卡片：标题、副标题、若干「地点 · 时间」行、署名。
/// 顶上可带一块昼夜地图（那一刻被太阳照亮的半球、地点的点），名片的图形表达放在这一块
/// （轻微、适量，不主宰设计），文字与分隔线照旧；亮色底，固定 560 pt 宽、2 倍像素，`ImageRenderer` 离屏渲染。
/// 复制到剪贴板（PNG + TIFF，聊天软件都收）或经存储面板存成文件；两条路都不联网、不写别的地方。
@MainActor
enum TimeCardImage {
    struct Line: Hashable {
        let name: String
        let text: String
    }

    struct Map: Hashable {
        let instant: Date
        let places: [WorldMapPlace]
    }

    struct Card: Hashable {
        let title: String
        let subtitle: String?
        let lines: [Line]
        let footer: String
        var map: Map? = nil
    }

    static let width: CGFloat = 560

    private struct CardView: View {
        let card: Card
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                if let map = card.map {
                    WorldMapScene(instant: map.instant, places: map.places, rasterScale: 2)
                        .frame(width: width - 56, height: ((width - 56) * 138 / 360).rounded())
                }
                Text(verbatim: card.title).appFont(.title2, weight: .semibold)
                if let subtitle = card.subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle).appFont(.callout).foregroundStyle(Color.primary.opacity(0.78))
                }
                Divider()
                ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: line.name).appFont(.headline)
                        Spacer(minLength: 16)
                        Text(verbatim: line.text).appFont(.body, monospacedDigit: true).multilineTextAlignment(.trailing)
                    }
                }
                Divider()
                Text(verbatim: card.footer).appFont(.caption).foregroundStyle(Color.primary.opacity(0.78))
            }
            .padding(28)
            .frame(width: width, alignment: .leading)
            .background(Color.white)
            .foregroundStyle(Color.black)
            .environment(\.colorScheme, .light)
        }
    }

    static func image(for card: Card, locale: Locale) -> NSImage? {
        let renderer = ImageRenderer(content: CardView(card: card).environment(\.locale, locale))
        renderer.scale = 2
        defer { if card.map != nil { MapRelief.usedOffscreen() } }
        return renderer.nsImage
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// 复制到剪贴板：PNG 与 TIFF 两种表示，Slack / 微信 / 备忘录都能直接粘贴。
    @discardableResult
    static func copy(_ card: Card, locale: Locale) -> Bool {
        guard let image = image(for: card, locale: locale), let png = pngData(image) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let tiff = image.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        return true
    }

    /// 存储面板存成 PNG；用户取消返回 false。
    @discardableResult
    static func save(_ card: Card, suggestedName: String, locale: Locale) -> Bool {
        guard let image = image(for: card, locale: locale), let png = pngData(image) else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName.hasSuffix(".png") ? suggestedName : suggestedName + ".png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do { try png.write(to: url, options: .atomic); return true } catch { return false }
    }
}
