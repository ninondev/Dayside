// SPDX-License-Identifier: GPL-3.0-only
//
//  WorldMapView.swift
//  Dayside
//
//  昼夜地图：Dayside 名字的本义。等距柱状投影的世界地图，此刻被太阳照亮的那一半铺上
//  与昼夜条相同的「昼」色，晨昏线描一条细线，已添加的地点是图上的点（本机一颗大一号的点），太阳符号
//  落在直射点上。几何全在 Rust `worldmap.scene`（陆地轮廓 Natural Earth 110m 随库编进去，19.7 KB），
//  这里只画形状与放符号，静态图使用纯形状，避免 Canvas 的图形缓冲；不依赖地图框架或联网。
//  跟穿梭走：拖时间滑块，晨昏线就跟着移；跳到某一刻时它滑过去而不是跳过去。
//
//  地图本身可以拖：抓住它左右拖，太阳跟着指针走、时间跟着太阳走（整幅宽 = 24 小时），
//  松手对齐到整刻钟；触控板左右轻扫同理，上下滚动仍交给面板。②与昼夜条同一套三档：昼 / 曙暮（太阳在地平线下
//  0.833°…6°）/ 夜。③月亮落在此刻头顶是月亮的那一点，画成当前的月相。④底色与陆地只按尺寸算一次，拖动时每帧
//  只重算昼夜、晨昏线与点。⑤面板那张双击（或悬停时右上角的按钮）放大成「地球」窗。
//
//  底图是 Rust 逐像素上色的天色（夜是墨、白天是纸、颜色只在晨昏线附近，海陆与地形来自
//  Natural Earth 灰度地形，城市灯火画在底图里），见 `MapRaster.swift`；裁掉两极（80°N … 58°S，2.61 : 1）；
//  晨昏线是一道细光（破晓玫瑰、黄昏琥珀），太阳常显（金盘 + 深浅两道细圈），月亮按月相画，地点的圈跟脚下的地面走，
//  地图上的字按底下那块地方实算对比度选墨或纸。手势、读屏、地球窗指针与拷贝海报照旧。
//

import SwiftUI
import AppKit
import Synchronization

/// 地图的一个地点（经纬度 + 是不是本机那一颗）。面板、导出的 PNG 名片都用它。
struct WorldMapPlace: Encodable, Hashable {
    let latitude: Double
    let longitude: Double
    let home: Bool
}

/// 地图上一个地点旁写的字：名字（衬线）与那一刻的当地时间（等宽数字，跨日时带「次日 / 前一日」）。
struct MapLabel: Hashable, Sendable {
    let name: String
    let time: String
}

/// 地图上的手势换算：纯函数，`MapScrubTests` 直接钉住。
nonisolated enum MapScrub {
    /// 松手时对齐到的刻度（分钟）。
    static let snapMinutes: Double = 15

    /// 横向拖动 `dx` pt 对应多少分钟。太阳每小时往西走 15°，整幅地图 360°，所以整幅宽 = 24 小时；
    /// 太阳跟着指针走：往右拖 = 太阳往东 = 时间往回倒（负），往左拖 = 往后。
    static func minutes(forDrag dx: CGFloat, width: CGFloat) -> Double {
        guard width > 0, dx.isFinite, width.isFinite else { return 0 }
        return -Double(dx / width) * 1440
    }

    /// 触控板横扫时手指实际往哪走（不管「自然滚动」开没开，太阳都跟着手指）。
    static func fingerDX(scrollingDeltaX: CGFloat, invertedFromDevice: Bool) -> CGFloat {
        invertedFromDevice ? scrollingDeltaX : -scrollingDeltaX
    }

    /// 松手对齐到整刻钟：按 UTC 取整。现行时区偏移都是 15 分钟的整数倍（加德满都 +5:45、查塔姆 +12:45 也是），
    /// 所以每个地方都落在当地的 :00 / :15 / :30 / :45。
    static func snapped(_ date: Date, minutes: Double = snapMinutes) -> Date {
        let step = minutes * 60
        return Date(timeIntervalSince1970: (date.timeIntervalSince1970 / step).rounded() * step)
    }

    /// 拖动中按整分钟取时刻：同一分钟里的多次指针事件只跳一次（整幅 288 pt 时 1 pt = 5 分钟，不会丢细节）。
    static func wholeMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    }

    /// 键盘 ← → 与读屏「调整」的一步：走到本机钟面上的下一个（上一个）整点或整刻钟，
    /// 不是简单地加减 60 分钟：4:57 按 → 到 5:00，再按到 6:00，图上的标签都是整齐的钟点。
    /// 按 `zone` 的钟面对齐（印度的整点是 UTC 的半点）；跨过换钟时钟面上的整点按换钟后的偏移算，但绝不走回头路。
    static func step(from date: Date, minutes: Int, forward: Bool, in zone: TimeZone) -> Date {
        let step = Double(max(1, minutes) * 60)
        let t = date.timeIntervalSince1970
        guard t.isFinite else { return date }
        let offset = Double(zone.secondsFromGMT(for: date))
        let wall = t + offset
        let target = forward ? (floor(wall / step) + 1) * step : (ceil(wall / step) - 1) * step
        var result = target - offset
        let newOffset = Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: result)))
        if newOffset != offset, (result + newOffset).truncatingRemainder(dividingBy: step) != 0 {
            let adjusted = target - newOffset
            if forward ? adjusted > t : adjusted < t { result = adjusted }
        }
        return Date(timeIntervalSince1970: result)
    }
}

/// 地点标签的摆放（地球窗、面板悬停的那一个、海报）：标签先放在点的右边（报纸上时区图的读法：「• 东京 23:13」），
/// 贴边就往里收，与已放好的标签、地点圈、`avoid` 里的矩形相撞就依次试左边、上方、下方、右上、右下；
/// 六个方向都碰到圈、标签或避开区时，再试障碍边缘的空位；额外搜索限量，未找到空位时仍保留完整名字。
/// 宽度由调用方量（`NSFont` 按真实字体量，测试里给固定宽）。
nonisolated enum MapLabelLayout {
    struct Placed: Equatable {
        let index: Int
        let center: CGPoint
        let size: CGSize
    }

    static func place(points: [(index: Int, point: CGPoint)], sizes: [Int: CGSize], in bounds: CGSize, gap: CGFloat = 6,
                      avoid: [CGRect] = [], dotRadius: CGFloat = 4) -> [Placed] {
        var placed: [Placed] = []
        // 限制额外备选点，拥挤地图不随地点数生成整张交叉网格。
        var edgeBudget = 4096
        let dots = points.map { CGRect(x: $0.point.x - dotRadius, y: $0.point.y - dotRadius, width: 2 * dotRadius, height: 2 * dotRadius) }
        // 从西往东放：相邻城市的标签错开得更自然。
        for item in points.sorted(by: { $0.point.x < $1.point.x || ($0.point.x == $1.point.x && $0.index < $1.index) }) {
            guard let size = sizes[item.index] else { continue }
            let p = item.point
            let halfH = size.height / 2, halfW = size.width / 2
            let candidates: [CGPoint] = [
                CGPoint(x: p.x + gap + halfW, y: p.y),
                CGPoint(x: p.x - gap - halfW, y: p.y),
                CGPoint(x: p.x, y: p.y - gap - halfH),
                CGPoint(x: p.x, y: p.y + gap + halfH),
                CGPoint(x: p.x + gap + halfW, y: p.y - gap - size.height),
                CGPoint(x: p.x + gap + halfW, y: p.y + gap + size.height),
            ].map { clamp($0, size: size, in: bounds) }
            let box = { (c: CGPoint) in CGRect(x: c.x - halfW, y: c.y - halfH, width: size.width, height: size.height) }
            let hitsLabels = { (c: CGPoint) in placed.contains { rect($0.center, $0.size).intersects(box(c)) } }
            let hitsOthers = { (c: CGPoint) in
                avoid.contains { $0.intersects(box(c)) } || dots.contains { $0.intersects(box(c)) }
            }
            let clearOfAvoid = { (c: CGPoint) in !avoid.contains { $0.intersects(box(c)) } }
            let clear = { (c: CGPoint) in !hitsLabels(c) && !hitsOthers(c) }
            let order = { (lhs: CGPoint, rhs: CGPoint) in
                let leftX = lhs.x - p.x, leftY = lhs.y - p.y
                let rightX = rhs.x - p.x, rightY = rhs.y - p.y
                let left = leftX * leftX + leftY * leftY
                let right = rightX * rightX + rightY * rightY
                if left != right { return left < right }
                return lhs.y != rhs.y ? lhs.y < rhs.y : lhs.x < rhs.x
            }
            // 保留避开区原有的边缘顺序，已有空位不挪动。
            let edgeCandidates: [CGPoint]
            if !avoid.isEmpty, !candidates.contains(where: clearOfAvoid) {
                let xs = [p.x, halfW, bounds.width - halfW] + avoid.flatMap { [$0.minX - halfW - 1, $0.maxX + halfW + 1] }
                let ys = [p.y, halfH, bounds.height - halfH] + avoid.flatMap { [$0.minY - halfH - 1, $0.maxY + halfH + 1] }
                edgeCandidates = xs.flatMap { x in ys.map { y in clamp(CGPoint(x: x, y: y), size: size, in: bounds) } }
                    .filter(clearOfAvoid).sorted(by: order)
            } else { edgeCandidates = [] }
            var additionalEdges: [CGPoint] = []
            if edgeBudget >= 256, !candidates.contains(where: clear), !edgeCandidates.contains(where: clear) {
                // 把已放标签和所有地点圈也当成边界，寻找近处的空位。
                let obstacles = avoid + placed.map { rect($0.center, $0.size) }
                    + dots
                let xs = [p.x, halfW, bounds.width - halfW] + obstacles.flatMap { [$0.minX - halfW - 1, $0.maxX + halfW + 1] }
                let ys = [p.y, halfH, bounds.height - halfH] + obstacles.flatMap { [$0.minY - halfH - 1, $0.maxY + halfH + 1] }
                let xEdges = nearbyEdges(xs, around: p.x, minimum: halfW, maximum: bounds.width - halfW)
                let yEdges = nearbyEdges(ys, around: p.y, minimum: halfH, maximum: bounds.height - halfH)
                edgeBudget -= xEdges.count * yEdges.count
                additionalEdges = xEdges.flatMap { x in yEdges.map { y in CGPoint(x: x, y: y) } }
                    .filter(clearOfAvoid)
                    .sorted(by: order)
            }
            let chosen = candidates.first(where: clear)
                ?? edgeCandidates.first(where: clear)
                ?? additionalEdges.first(where: clear)
                ?? candidates.first { center in !hitsLabels(center) && !avoid.contains(where: { $0.intersects(box(center)) }) }
                ?? edgeCandidates.first { !hitsLabels($0) }
                ?? additionalEdges.first { !hitsLabels($0) }
                ?? candidates.first { center in !avoid.contains(where: { $0.intersects(box(center)) }) }
                ?? edgeCandidates.first
                ?? additionalEdges.first
                ?? candidates[0]
            placed.append(Placed(index: item.index, center: chosen, size: size))
        }
        return placed.sorted { $0.index < $1.index }
    }

    private static func nearbyEdges(_ edges: [CGFloat], around anchor: CGFloat, minimum: CGFloat, maximum: CGFloat) -> [CGFloat] {
        let upper = max(minimum, maximum)
        let boundary = Set([minimum, upper])
        let closest = Set(edges.map { min(max($0, minimum), upper) }).subtracting(boundary)
            .sorted { lhs, rhs in
                let left = abs(lhs - anchor), right = abs(rhs - anchor)
                return left != right ? left < right : lhs < rhs
            }
        return Array(boundary) + Array(closest.prefix(16 - boundary.count))
    }

    private static func rect(_ center: CGPoint, _ size: CGSize) -> CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    private static func clamp(_ c: CGPoint, size: CGSize, in bounds: CGSize) -> CGPoint {
        CGPoint(x: min(max(c.x, size.width / 2), max(size.width / 2, bounds.width - size.width / 2)),
                y: min(max(c.y, size.height / 2), max(size.height / 2, bounds.height - size.height / 2)))
    }
}

/// 昼夜地图的纯图形部分：Rust 逐像素画好的底图（天色、海陆、地形、城市灯火，`MapRaster`）上叠
/// 晨昏线的一道细光（破晓一侧玫瑰、黄昏一侧琥珀，贴着图边淡出）、月亮（按月相画在头顶是月亮的那一点）、
/// 太阳（金盘、一道深色外沿、一道浅色细圈，深浅地上都看得见）、地点（圈的颜色跟脚下的地面走，本机圈中一点）与标签。
/// 只读环境里的屏幕倍数，所以能放进 `ImageRenderer`（名片、海报）；面板的 `WorldMapView` 在它外面加手势与读屏文字。
/// 时刻变化发生在动画事务里时（`AppModel.jump` / `resetToNow`），晨昏线与太阳滑过去而不是跳过去：会动的那层
/// `Drawing` 是 `Animatable`，SwiftUI 按事务插值时刻、逐帧向 Rust 要底图与几何（面板 1.3 ms、地球窗 8.5 ms 一帧）。
/// 跳转分两拍时这里是第一拍（整段时长，`JumpTiming`）；面板行的天色与钟点跟在后面（`ScrubRowBeat`）。
struct WorldMapScene: View {
    let instant: Date
    let places: [WorldMapPlace]
    /// 读屏要的「谁在白天」：面板传回调拿到场景，导出时不用。只按**目标**时刻算一次，动画中间帧不算。
    var onScene: ((WorldMapScene.Scene) -> Void)? = nil
    /// 纬度范围：默认 80°N … 58°S（两极只有冰与空海，也是随包地形的范围），宽高比 360 : 138 ≈ 2.61。
    var latitudes: ClosedRange<Double> = WorldMapScene.standard
    /// 与 `places` 同序的标签（名字 + 当地时间），nil 不写字；`highlight` 只写那一个（面板悬停在某一行时）。
    var labels: [MapLabel]? = nil
    var highlight: Int? = nil
    /// 标签的字号（点）；nil 按图的大小取系统字号（大图正文、小图说明文字），跟「文字大小」设置走。
    var labelSize: CGFloat? = nil
    /// 大图（地球窗、海报）：太阳大一号，月亮带月光；小图（面板、帮助页、欢迎页、名片）只有一弯小小的月。
    var large = false
    /// 城市灯火的大小倍数（面板与小图 1、地球窗 1.15、海报 1.1）；0 不画。
    var lights: Double = 1
    /// 月亮下写月相名（地球窗）：`moonPhaseKey` 八个键本地化好的名字；nil 不写。
    var phaseNames: [String: String]? = nil
    /// 指针在地图上：太阳外多一道圈，提示「可以拖」。
    var sunHandle = false
    /// 拖动中：太阳外亮一道 sunRing 细圈，让用户看见动的是太阳。
    var sunDragging = false
    /// 不画月亮（海报：题字的地方留给字）。
    var showsMoon = true
    /// 位图的像素倍数：nil 跟屏幕走；离屏出图（名片、海报）给 2。
    var rasterScale: CGFloat? = nil
    /// 地点标签避开这些矩形（海报的题字），地点圈仍按坐标画。
    var avoid: [CGRect] = []
    /// 圆角：nil 时小图 6、大图 0；面板那张满幅贴边给 0。
    var cornerRadius: CGFloat? = nil
    var symbolScale: CGFloat = 1

    @Environment(\.displayScale) private var displayScale
    @Environment(\.textScale) private var textScale
    @Environment(\.locale) private var locale

    /// 标准裁法 80°N … 58°S（与随包地形同一范围）。
    static let standard: ClosedRange<Double> = MapRelief.south...MapRelief.north
    /// 帮助页头图的裁法（−46 … 66：惠灵顿、雷克雅未克都还在；帮助页折叠着时全部内容要在 minHeight 内不滚动）。
    static let helpHeader: ClosedRange<Double> = -46...66

    private struct Input: Encodable {
        let instant: Double; let width: Double; let height: Double; let places: [WorldMapPlace]
        let latitudeMin: Double; let latitudeMax: Double
    }
    struct Pin: Decodable {
        let index: Int; let x: Double; let y: Double; let home: Bool
        /// 脚下的地面是深色（夜里）：圈用纸色；否则用墨色。
        var dark: Bool?
        /// 脚下地面的颜色（"#rrggbb"），圈里填它。
        var fill: String?
    }
    struct Subsolar: Decodable { let latitude: Double; let longitude: Double }
    /// 此刻月亮在头顶的那一点与月相（Rust 与天文页逐位相同的八个名字）；`illumination` 是被照亮的比例，
    /// `sunIsEast` 太阳在月亮东边（亮的那一侧朝东）。
    struct Moon: Decodable {
        let x: Double; let y: Double; let phase: String; let illumination: Double
        var sunIsEast: Bool?
    }
    struct Scene: Decodable {
        let sun: [Double]
        let subsolar: Subsolar
        let pins: [Pin]
        let lit: [Int]
        let moon: Moon?
    }

    /// 地图上的符号：地点、白天的地点、直射点、月下点与月相（底图在 `MapRaster` / `MapSurface` 的位图里）。
    nonisolated static func scene(instant: Date, size: CGSize, places: [WorldMapPlace], latitudes: ClosedRange<Double> = -90...90) -> Scene {
        RustCore.invoke("worldmap.scene", Input(instant: instant.timeIntervalSince1970, width: size.width, height: size.height, places: places,
                                                latitudeMin: latitudes.lowerBound, latitudeMax: latitudes.upperBound))
    }

    /// 月相名 → 文案键（与天文页同一套：新月 / 蛾眉月 / 上弦月 / 盈凸月 / 满月 / 亏凸月 / 下弦月 / 残月）。
    nonisolated static func moonPhaseKey(_ phase: String) -> String {
        switch phase {
        case "new": "新月"
        case "waxingCrescent": "蛾眉月"
        case "firstQuarter": "上弦月"
        case "waxingGibbous": "盈凸月"
        case "full": "满月"
        case "waningGibbous": "亏凸月"
        case "lastQuarter": "下弦月"
        default: "残月"
        }
    }

    static let moonPhases = ["new", "waxingCrescent", "firstQuarter", "waxingGibbous", "full", "waningGibbous", "lastQuarter", "waningCrescent"]

    /// 八个月相名在某种界面语言下的写法（地球窗传给 `phaseNames`）。
    static func phaseNames(locale: Locale) -> [String: String] {
        Dictionary(uniqueKeysWithValues: moonPhases.map { ($0, L10n.string(moonPhaseKey($0), locale: locale)) })
    }

    /// 会动的那一层：`animatableData` 是时刻（Unix 秒），动画事务里 SwiftUI 逐帧改它、逐帧重画底图与几何。
    nonisolated private struct Drawing: View, Animatable {
        @Environment(\.textScale) private var textScale
        var seconds: Double
        let places: [WorldMapPlace]
        let size: CGSize
        let latitudes: ClosedRange<Double>
        let labels: [MapLabel]?
        let highlight: Int?
        let labelSize: CGFloat
        let locale: Locale
        let large: Bool
        let symbolScale: CGFloat
        let lights: Double
        let phaseNames: [String: String]?
        let sunHandle: Bool
        let sunDragging: Bool
        let showsMoon: Bool
        let scale: CGFloat
        let avoid: [CGRect]
        /// 离屏出图（名片、海报）：底图走 CGImage；屏幕上的地图走 IOSurface（`MapSurface`）。
        let offscreen: Bool
        var animatableData: Double {
            get { seconds }
            set {
                #if DEBUG
                if seconds != newValue { PerformanceRustCalls.animationFrame() }
                #endif
                seconds = newValue
            }
        }

        var body: some View {
            let instant = Date(timeIntervalSince1970: seconds)
            let raster = offscreen ? MapRaster.render(instant: instant, size: size, scale: scale, latitudes: latitudes, lights: lights, large: large) : nil
            let (size, scale, latitudes) = (size, scale, latitudes)
            let luma: @Sendable (CGRect) -> Double = { rect in MapRaster.luminance(instant: instant, size: size, scale: scale, latitudes: latitudes, in: rect) }
            let scene = WorldMapScene.scene(instant: instant, size: size, places: places, latitudes: latitudes)
            let unit = WorldMapScene.unit(width: size.width, scale: symbolScale)
            let inside = { (x: Double, y: Double) in x >= 0 && x <= size.width && y >= 0 && y <= size.height }
            let pins = scene.pins
            let moonAvoid = scene.moon.map { moon in
                showsMoon && inside(moon.x, moon.y)
                    ? WorldMapScene.moonBoxes(moon, large: large, name: phaseNames?[moon.phase],
                                              scale: symbolScale, textScale: textScale, locale: locale, in: size)
                    : []
            } ?? []
            ZStack(alignment: .topLeading) {
                if !offscreen {
                    MapSurface(seconds: seconds, size: size, scale: scale, latitudes: latitudes, lights: lights, large: large)
                        .frame(width: size.width, height: size.height)
                } else if let raster {
                    Image(decorative: raster.image, scale: raster.scale)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                } else {
                    Rectangle().fill(LightPalette.ink)
                }
                // 晨昏线（光晕 + 细线，破晓玫瑰、黄昏琥珀，贴图边淡出）与太阳的光晕都由 Rust 画在底图里：
                // SwiftUI 画渐变描边要在 64 位后备图层里软件渲染，窗口关了图层还留着（内存巡回量出 CoreAnimation 多 24 MB）。
                if showsMoon, let moon = scene.moon, inside(moon.x, moon.y) {
                    MoonMark(moon: moon, large: large, name: phaseNames?[moon.phase],
                             captionBox: moonAvoid.count > 1 ? moonAvoid.last : nil, luma: luma, scale: symbolScale)
                        .position(x: moon.x, y: moon.y)
                }
                if scene.sun.count == 2 {
                    MapSunMark(large: large, handle: sunHandle, dragging: sunDragging,
                            point: CGPoint(x: scene.sun[0], y: scene.sun[1]), luminance: luma, scale: symbolScale)
                        .position(x: scene.sun[0], y: scene.sun[1])
                }
                ForEach(pins, id: \.index) { pin in
                    PinMark(pin: pin, unit: unit)
                        .position(x: pin.x, y: pin.y)
                }
                if let labels {
                    PlaceLabels(pins: highlight.map { h in pins.filter { $0.index == h } } ?? pins, allPins: pins, labels: labels, size: size,
                                luma: luma, textSize: labelSize, locale: locale,
                                avoid: avoid + WorldMapScene.sunBox(scene.sun, large: large, scale: symbolScale) + moonAvoid,
                                scale: symbolScale)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .accessibilityHidden(true)
        }
    }

    /// 地点圈的尺度：面板那么宽（约 300 点）时 1，地球窗 1.5 封顶。
    nonisolated static func unit(width: CGFloat, scale: CGFloat = 1) -> CGFloat {
        min(1.5 * scale, max(0.85, width / 340))
    }

    /// 太阳占的地方（标签别压住太阳）。
    nonisolated static func sunBox(_ sun: [Double], large: Bool, scale: CGFloat = 1) -> [CGRect] {
        guard sun.count == 2 else { return [] }
        let r: CGFloat = (large ? 12 : 7) * scale
        return [CGRect(x: sun[0] - r, y: sun[1] - r, width: 2 * r, height: 2 * r)]
    }

    nonisolated static func moonRadius(large: Bool, scale: CGFloat) -> CGFloat {
        (large ? 5 : 1.9) * scale
    }

    nonisolated static func moonCaptionOffset(radius: CGFloat, scale: CGFloat) -> CGFloat {
        radius + 10 * scale
    }

    /// 地点标签与月相名共用同一块实际绘制区域。
    nonisolated static func moonBoxes(_ moon: Moon, large: Bool, name: String?, scale: CGFloat,
                          textScale: CGFloat, locale: Locale, in bounds: CGSize? = nil) -> [CGRect] {
        let radius = moonRadius(large: large, scale: scale)
        let glowRadius = large ? radius * 3.2 : radius
        var boxes = [CGRect(x: moon.x - glowRadius, y: moon.y - glowRadius,
                            width: 2 * glowRadius, height: 2 * glowRadius)]
        if let caption = moonCaptionBox(moon, large: large, name: name, scale: scale,
                                        textScale: textScale, locale: locale, in: bounds) {
            boxes.append(caption)
        }
        return boxes
    }

    nonisolated static func moonCaptionBox(_ moon: Moon, large: Bool, name: String?, scale: CGFloat,
                                          textScale: CGFloat, locale: Locale, in bounds: CGSize? = nil) -> CGRect? {
        guard let name else { return nil }
        let measured = TextMeasure.size(name, serif: false,
                                        size: AppFont.size(.caption) * scale * textScale,
                                        weight: .regular, locale: locale, monospacedDigits: false)
        let size = CGSize(width: ceil(measured.width) + 2, height: ceil(measured.height) + 2)
        let radius = moonRadius(large: large, scale: scale)
        let offset = moonCaptionOffset(radius: radius, scale: scale)
        let below = CGRect(x: moon.x - size.width / 2, y: moon.y + offset - size.height / 2,
                           width: size.width, height: size.height)
        guard let bounds, size.width <= bounds.width, size.height <= bounds.height else { return below }
        let above = below.offsetBy(dx: 0, dy: -2 * offset)
        let right = CGRect(x: moon.x + radius + 2 * scale, y: moon.y - size.height / 2,
                           width: size.width, height: size.height)
        let left = right.offsetBy(dx: -2 * (radius + 2 * scale) - size.width, dy: 0)
        let disk = CGRect(x: moon.x - radius, y: moon.y - radius, width: 2 * radius, height: 2 * radius)
        let candidates = below.maxY <= bounds.height ? [below, above, right, left] : [above, below, right, left]
        let clamped = candidates.map { box in
            CGRect(x: min(max(0, box.minX), bounds.width - size.width),
                   y: min(max(0, box.minY), bounds.height - size.height),
                   width: size.width, height: size.height)
        }
        return clamped.first { !$0.intersects(disk) } ?? clamped[0]
    }

    var body: some View {
        GeometryReader { proxy in
            let usesRasterImage: Bool = {
                #if DEBUG
                // 转储的离屏位图不含 IOSurface 图层，改用同一底图的 CGImage。
                if ApplicationSession.isTesting, ProcessInfo.processInfo.environment["MEANTIME_AX_DUMP"] == "1" { return true }
                #endif
                return rasterScale != nil
            }()
            Drawing(seconds: instant.timeIntervalSince1970, places: places, size: proxy.size, latitudes: latitudes, labels: labels,
                    highlight: highlight, labelSize: labelSize ?? AppFont.size(large ? .body : .callout) * textScale, locale: locale,
                    large: large, symbolScale: symbolScale, lights: lights, phaseNames: phaseNames, sunHandle: sunHandle, sunDragging: sunDragging, showsMoon: showsMoon,
                    scale: rasterScale ?? displayScale, avoid: avoid, offscreen: usesRasterImage)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? (large ? 0 : 6)))
                // 反色开着时，地图底图（AppKit 图层，`.colorInvert` 够得到）连同覆盖层（月亮、太阳、地点圈、标签）整块预反一次；
                // 面板整块反过时由 `skyPreInverted` 拦下，不反第二遍。离屏出图（名片、海报）环境里没有这个设置，不受影响。
                .modifier(SkyPreInvert())
                .onAppear { onScene?(Self.scene(instant: instant, size: proxy.size, places: places, latitudes: latitudes)) }
                .onChange(of: instant) { onScene?(Self.scene(instant: instant, size: proxy.size, places: places, latitudes: latitudes)) }
                .onChange(of: places) { onScene?(Self.scene(instant: instant, size: proxy.size, places: places, latitudes: latitudes)) }
        }
        // 等距柱状投影：宽高比 = 360° 对纬度跨度（标准裁法 2.61 : 1）。
        .aspectRatio(360 / (latitudes.upperBound - latitudes.lowerBound), contentMode: .fit)
        // 屏幕上的地图才记「有人在看」；离屏出图（给了 `rasterScale`）用过由调用方交代（`MapRelief.usedOffscreen`）。
        .onAppear { if rasterScale == nil { MapRelief.retain() } }
        .onDisappear { if rasterScale == nil { MapRelief.release() } }
    }
}

/// 太阳金盘保留物体色；四道圈都在金盘外，对脚下地图取墨纸。
/// 那一团淡金的光晕由 Rust 画在底图里（不用渐变图层）。
struct MapSunMark: View {
    let large: Bool
    let handle: Bool
    let dragging: Bool
    let point: CGPoint
    let luminance: @Sendable (CGRect) -> Double

    var scale: CGFloat = 1

    private func skyRing(radius: CGFloat) -> Color {
        let box = CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius)
        return SkyTextRole.mapGlyph.foreground(on: luminance(box))
    }

    var body: some View {
        let r: CGFloat = (large ? 8 : 4.5) * scale
        let glow: CGFloat = (large ? 30 : 16) * scale
        ZStack {
            Circle().fill(LightPalette.sun).frame(width: 2 * r, height: 2 * r)
            Circle().strokeBorder(skyRing(radius: r + 1), lineWidth: 1).frame(width: 2 * r + 2, height: 2 * r + 2)
            Circle().stroke(skyRing(radius: r + 1.8), lineWidth: 0.8).frame(width: 2 * r + 2.8, height: 2 * r + 2.8)
            if handle {
                Circle().stroke(skyRing(radius: r + 4.6), lineWidth: 1.2).frame(width: 2 * r + 8, height: 2 * r + 8)
            }
            if dragging {
                Circle().strokeBorder(skyRing(radius: 2.2 * r), lineWidth: 1.5).frame(width: 4.4 * r, height: 4.4 * r)
            }
        }
        .frame(width: 2 * glow, height: 2 * glow)
        .allowsHitTesting(false)
    }
}

/// 月亮的亮面：朝太阳那一侧的半圆 + 一段明暗交界的半椭圆（凸月时往暗面鼓、蛾眉时往亮面收）。
/// 画在「亮面朝右」的方向上，太阳在西边时由调用方整个转 180°。
struct MoonLitShape: Shape {
    let illumination: Double

    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let lit = min(1, max(0, illumination))
        let a = r * abs(1 - 2 * lit)
        var path = Path()
        // 右半圆：从正上方顺时针到正下方。
        path.addArc(center: c, radius: r, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        // 交界线：半椭圆从正下方回到正上方；凸月（亮面过半）走左侧，蛾眉走右侧。
        let steps = 24
        for k in 1...steps {
            let t = Double.pi / 2 + Double.pi * Double(k) / Double(steps)   // 90° … 270°
            let x = lit >= 0.5 ? c.x + a * cos(t) : c.x - a * cos(t)
            path.addLine(to: CGPoint(x: x, y: c.y + r * sin(t)))
        }
        path.closeSubpath()
        return path
    }
}

/// 月亮：暗面是一枚深色小圆，亮面按月相画；大图外面一圈淡淡的月光（越圆越亮）、下面写月相名。
private struct MoonMark: View {
    let moon: WorldMapScene.Moon
    let large: Bool
    let name: String?
    let captionBox: CGRect?
    let luma: @Sendable (CGRect) -> Double
    var scale: CGFloat = 1
    @Environment(\.textScale) private var textScale

    var body: some View {
        let r = WorldMapScene.moonRadius(large: large, scale: scale)
        let east = moon.sunIsEast ?? true
        ZStack {
            if large {
                Circle()
                    .fill(RadialGradient(colors: [LightPalette.moonLit.opacity(0.2 * moon.illumination), LightPalette.moonLit.opacity(0)],
                                         center: .center, startRadius: r * 0.8, endRadius: r * 3.2))
                    .frame(width: r * 6.4, height: r * 6.4)
            }
            Circle().fill(LightPalette.moonDark.opacity(0.85)).frame(width: 2 * r, height: 2 * r)
            MoonLitShape(illumination: moon.illumination)
                .fill(LightPalette.moonLit)
                .frame(width: 2 * r, height: 2 * r)
                .rotationEffect(.degrees(east ? 0 : 180))
            if let name, let captionBox {
                MapText(paper: LightPalette.paperReads(on: luma(captionBox))) {
                    Text(verbatim: name).font(.system(size: AppFont.size(.caption) * scale * textScale))
                }
                .fixedSize()
                .offset(x: captionBox.midX - moon.x, y: captionBox.midY - moon.y)
            }
        }
        .allowsHitTesting(false)
    }
}

/// 地点：一个小圈，圈里填脚下地面的颜色、圈用墨或纸（看脚下是白天还是夜里）；本机圈中一点。
private struct PinMark: View {
    let pin: WorldMapScene.Pin
    let unit: CGFloat

    var body: some View {
        let r = (pin.home ? 3.6 : 3.0) * unit
        let ring = pin.fill.map { SkyTextRole.mapGlyph.foreground(on: LightPalette.luminance($0)) }
            ?? SkyTextRole.mapGlyph.foreground(paper: pin.dark ?? false)
        let fill = pin.fill.map(LightPalette.color) ?? LightPalette.paper
        ZStack {
            Circle().fill(fill).frame(width: 2 * r, height: 2 * r)
            Circle().strokeBorder(ring, lineWidth: max(1, 1.2 * unit)).frame(width: 2 * r, height: 2 * r)
            if pin.home {
                Circle().fill(ring).frame(width: 2.8 * unit, height: 2.8 * unit)
            }
        }
        .frame(width: 2 * r, height: 2 * r)
        .allowsHitTesting(false)
    }
}

/// 地图上的一行字：墨或纸（看底下那块地方的明暗实算对比度），外面衬一圈反色的描边；不画底板，地图照样透出来。
/// 描边是同一行字往上下左右各挪 1 点、画成衬底色——不做模糊阴影（阴影要离屏模糊，拖动时每帧每个标签一次）。
private let mapTextHaloOffsets: [CGSize] = [.init(width: 1, height: 0), .init(width: -1, height: 0), .init(width: 0, height: 1), .init(width: 0, height: -1)]

struct MapText<Content: View>: View {
    let paper: Bool
    var role: SkyTextRole = .mapLabel
    @ViewBuilder let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let halo = (paper ? LightPalette.haloDark : LightPalette.haloLight).opacity(contrast == .increased ? 1 : 0.85)
        ZStack {
            ForEach(0..<mapTextHaloOffsets.count, id: \.self) { k in
                content.foregroundStyle(halo).offset(mapTextHaloOffsets[k])
            }
            content.foregroundStyle(role.foreground(paper: paper))
        }
        .lineLimit(1)
    }
}

/// 地点旁的名字与当地时间：名字用衬线（本机加粗）、时间用等宽数字，墨或纸由标签底下那块地图的明暗实算决定。
private struct PlaceLabels: View {
    let pins: [WorldMapScene.Pin]
    let allPins: [WorldMapScene.Pin]
    let labels: [MapLabel]
    let size: CGSize
    let luma: @Sendable (CGRect) -> Double
    let textSize: CGFloat
    let locale: Locale
    let avoid: [CGRect]
    var scale: CGFloat = 1

    /// 名字与时间之间的空。
    private var gap: CGFloat { textSize * 0.4 }

    var body: some View {
        let sizes = Dictionary(uniqueKeysWithValues: pins.compactMap { pin -> (Int, CGSize)? in
            guard pin.index < labels.count else { return nil }
            let label = labels[pin.index]
            let name = TextMeasure.size(label.name, serif: true, size: textSize, weight: pin.home ? .semibold : .medium, locale: locale)
            let time = TextMeasure.size(label.time, serif: false, size: textSize, weight: .regular, locale: locale)
            let width = (label.name.isEmpty ? 0 : name.width + gap) + time.width
            return (pin.index, CGSize(width: ceil(width) + 2, height: ceil(max(name.height, time.height)) + 2))
        })
        // 所有地点圈都当障碍，只有量过尺寸的那些写字。
        let placed = MapLabelLayout.place(points: allPins.map { ($0.index, CGPoint(x: $0.x, y: $0.y)) },
                                          sizes: sizes, in: size, gap: 6 * scale, avoid: avoid, dotRadius: 4 * WorldMapScene.unit(width: size.width, scale: scale))
        let home = Set(pins.filter(\.home).map(\.index))
        ZStack(alignment: .topLeading) {
            ForEach(placed, id: \.index) { placedLabel in
                let label = labels[placedLabel.index]
                let box = CGRect(x: placedLabel.center.x - placedLabel.size.width / 2, y: placedLabel.center.y - placedLabel.size.height / 2,
                                 width: placedLabel.size.width, height: placedLabel.size.height)
                MapText(paper: LightPalette.paperReads(on: luma(box))) {
                    HStack(alignment: .firstTextBaseline, spacing: gap) {
                        if !label.name.isEmpty {
                            Text(verbatim: label.name)
                                .font(SerifFace.font(label.name, size: textSize, weight: home.contains(placedLabel.index) ? .semibold : .medium, locale: locale))
                        }
                        Text(verbatim: label.time).font(.system(size: textSize).monospacedDigit())
                    }
                }
                .fixedSize()
                .position(placedLabel.center)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// 地球窗「指到哪儿看哪儿几点」：指针下的地图坐标 → 人口前 6,000 座（约 10 万人以上）里
/// 「距离 ÷ 权重」最小的城（Rust `city.nearest`：每座城的势力范围 = 3 pt × 权重，第一名约 14 pt、第 6,000 名 3 pt；
/// 正对着一座小城时仍是它）。第一次指才映射城市索引。只回答「那座城和它的钟」，不回答「指针那一点的时区」。
struct MapProbe: Equatable {
    let index: Int
    let record: CityRecord
    let name: String
    /// 已经是用户的地点（图上已有它的标签）：不再画圈，右键也不给「添加」。
    let isPlace: Bool

    static let limit = 6000
    /// 最小的城（第 6,000 名）的势力范围；越大的城按 1 + log10(6000 / 名次) 倍放大。
    static let radiusPoints: CGFloat = 3

    /// 地图上的点 ↔ 经纬度（等距柱状投影，与 Rust `worldmap.scene` 同一套）。
    nonisolated static func coordinate(of point: CGPoint, in size: CGSize, latitudes: ClosedRange<Double>) -> (latitude: Double, longitude: Double)? {
        guard size.width > 0, size.height > 0 else { return nil }
        let longitude = Double(point.x / size.width) * 360 - 180
        let latitude = latitudes.upperBound - Double(point.y / size.height) * (latitudes.upperBound - latitudes.lowerBound)
        return (latitude, longitude)
    }

    nonisolated static func point(latitude: Double, longitude: Double, in size: CGSize, latitudes: ClosedRange<Double>) -> CGPoint {
        CGPoint(x: CGFloat((longitude + 180) / 360) * size.width,
                y: CGFloat((latitudes.upperBound - latitude) / (latitudes.upperBound - latitudes.lowerBound)) * size.height)
    }

    func point(in size: CGSize, latitudes: ClosedRange<Double> = -90...90) -> CGPoint {
        Self.point(latitude: record.latitude, longitude: record.longitude, in: size, latitudes: latitudes)
    }

    static func lookup(at point: CGPoint, in size: CGSize, latitudes: ClosedRange<Double>, zones: [TimeZoneEntry],
                       name: (Int, CityRecord) -> String) -> MapProbe? {
        guard let at = coordinate(of: point, in: size, latitudes: latitudes),
              let hit = CityIndex.shared.nearest(latitude: at.latitude, longitude: at.longitude,
                                                 radius: Double(radiusPoints / size.width) * 360, limit: limit) else { return nil }
        let (index, record) = hit
        let isPlace = zones.contains { zone in
            guard let c = zone.coordinate else { return false }
            return abs(c.latitude - record.latitude) < 0.05 && abs(c.longitude - record.longitude) < 0.05
        }
        return MapProbe(index: index, record: record, name: name(index, record), isPlace: isPlace)
    }
}

/// 指针下那座城的圈与标签：圈画在城的真实位置（不是指针处），标签与地点标签同一种写法、贴边往里收。
private struct MapProbeMark: View {
    let point: CGPoint
    let text: String
    let bounds: CGSize
    let luminance: (CGRect) -> Double

    var body: some View {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let measured = (text as NSString).size(withAttributes: [.font: font])
        let size = CGSize(width: ceil(measured.width) + 10, height: ceil(measured.height) + 4)
        let center = MapLabelLayout.place(points: [(0, point)], sizes: [0: size], in: bounds).first?.center ?? point
        let box = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        let paper = LightPalette.paperReads(on: luminance(box))
        let ring = SkyTextRole.mapGlyph.foreground(on: luminance(CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)))
        ZStack(alignment: .topLeading) {
            Circle()
                .strokeBorder(ring, lineWidth: 1.5)
                .frame(width: 12, height: 12)
                .position(point)
            Text(verbatim: text)
                .font(.callout.monospacedDigit())
                .foregroundStyle(SkyTextRole.mapProbe.foreground(paper: paper))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(paper ? LightPalette.ink : LightPalette.paper, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(SkyTextRole.mapProbe.foreground(paper: paper).opacity(0.2)))
                .position(center)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 触控板横扫的事件监听：只在指针停在地图上时装，离开就拆（本地监听，别的 App 的滚动不经过这里）。
/// 宽度放在引用里：监听闭包拿到的永远是地图此刻的宽。
@MainActor
private final class MapScrollMonitor {
    var width: CGFloat = 0
    private var token: Any?

    func install(scrub: @escaping @MainActor (Double) -> Void) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // 只接横向为主的轻扫；竖向交还给面板的滚动区。
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            guard abs(dx) > abs(dy) else { return event }
            let finger = MapScrub.fingerDX(scrollingDeltaX: dx, invertedFromDevice: event.isDirectionInvertedFromDevice)
            // 鼠标横向滚轮一格按 8 pt 算（精确滚动的触控板本来就是点）。
            let points = event.hasPreciseScrollingDeltas ? finger : finger * 8
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.width > 0 else { return false }
                scrub(MapScrub.minutes(forDrag: points, width: self.width))
                return true
            }
            return consumed ? nil : event
        }
    }

    func remove() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

struct WorldMapView: View {
    @Environment(AppModel.self) private var model
    @Environment(TimeCore.self) private var core
    @Environment(\.openWindow) private var openWindow
    @Environment(\.displayScale) private var displayScale
    @State private var lit: Set<Int> = []
    /// 场景带回的直射点（读屏值的第一句与三档分组靠它，与 `lit` 同一次回调一起来）。
    @State private var subsolar: WorldMapScene.Subsolar?
    @State private var dragStart: Date?
    @State private var lastDragMinute: Date?
    @State private var hovering = false
    @State private var monitor = MapScrollMonitor()
    /// 地球窗：指针附近那座城（`MapProbe.lookup`）与上一次查的指针位置（挪不到 1 pt 不重查）。
    @State private var probe: MapProbe?
    @State private var probedAt: CGPoint?
    @State private var copyResult: Bool?
    @State private var copyStamp = 0
    var latitudes: ClosedRange<Double> = WorldMapScene.standard
    /// 能用手改时间（面板、地球窗、欢迎页）；帮助页头图、名片只是看的。
    var interactive = false
    /// 双击或右上角的按钮放大成地球窗（面板那张）。
    var opensEarth = false
    /// 地球窗：每个地点旁写名字与当地时间，夜半球点亮城市灯火。
    var showsLabels = false
    /// 面板：指针停在这一行的地点上，地图上只写它的名字与时间。
    var highlightZone: UUID? = nil
    /// 圆角（面板那张满幅贴边给 0）。
    var cornerRadius: CGFloat? = nil
    /// 拖动真挪动了时间时回叫一次（欢迎页收起那句话用；面板与地球窗不用）。
    var onTimeDragged: (() -> Void)? = nil
    var scale: CGFloat = 1
    var avoid: [CGRect] = []
    var onCopied: ((Bool) -> Void)? = nil

    /// 图上的地点（有坐标的那些，面板顺序）与对应的点：面板、地球窗、「拷贝地图图片」共用一处。
    static func places(in core: TimeCore) -> (zones: [TimeZoneEntry], places: [WorldMapPlace]) {
        let zones = core.zones.filter { $0.coordinate != nil }
        let homeID = TimeZone.current.identifier
        let places = zones.compactMap { zone -> WorldMapPlace? in
            guard let c = zone.coordinate else { return nil }
            return WorldMapPlace(latitude: c.latitude, longitude: c.longitude, home: zone.timezoneID == homeID)
        }
        return (zones, places)
    }

    /// 地球窗的标签：名字 + 那一刻的当地时间（跟设置里的小时制走）。
    static func label(for zone: TimeZoneEntry, model: AppModel, core: TimeCore) -> MapLabel {
        MapLabel(name: zone.displayName(localizedCity: model.cityName(for: zone)),
                 time: clock(core.referenceDate, in: zone.timeZone, hourStyle: model.settings.hourStyle, locale: model.uiLocale))
    }

    /// 地图上写的钟点：那边已是次日 / 还是前一日时套「次日 %@ / 前一日 %@」（与面板行、排会结果同一套判据
    /// `ClockText.dayOffset` 与同两条文案；en 是「9:00 next day」）。同一天只写钟点。
    static func clock(_ date: Date, in zone: TimeZone, hourStyle: HourStyle, locale: Locale, reference: TimeZone = .current) -> String {
        let time = TimeFormatting.string(for: date, in: zone, format: ClockFormat(hourStyle: hourStyle, showSeconds: false))
        let offset = ClockText.dayOffset(of: date, in: zone, from: reference)
        guard offset != 0 else { return time }
        return String(format: L10n.string(offset > 0 ? "次日 %@" : "前一日 %@", locale: locale), time)
    }

    var body: some View {
        let (zones, places) = Self.places(in: core)
        let highlight = highlightZone.flatMap { id in zones.firstIndex { $0.id == id } }
        let labels: [MapLabel]? = showsLabels || highlight != nil ? zones.map { Self.label(for: $0, model: model, core: core) } : nil
        let scene = WorldMapScene(instant: core.referenceDate, places: places, onScene: { lit = Set($0.lit); subsolar = $0.subsolar }, latitudes: latitudes, labels: labels,
                                  highlight: showsLabels ? nil : highlight, labelSize: showsLabels ? 13 * scale * model.settings.textSize.scale : nil, large: showsLabels, lights: showsLabels ? 1.15 : 1,
                                  phaseNames: showsLabels ? WorldMapScene.phaseNames(locale: model.uiLocale) : nil,
                                  sunHandle: interactive && hovering && dragStart == nil, sunDragging: dragStart != nil, avoid: avoid, cornerRadius: cornerRadius, symbolScale: scale)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { monitor.width = $0 }
        Group {
            if interactive {
                scene
                    .contentShape(Rectangle())
                    .gesture(drag)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { if opensEarth { openEarth() } })
                    .pointerStyle(dragStart == nil ? .grabIdle : .grabActive)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hovering = true
                            monitor.install { minutes in scrub(by: minutes) }
                            if showsLabels { updateProbe(at: location, zones: zones) }
                        case .ended:
                            hovering = false
                            monitor.remove()
                        }
                    }
                    // 地球窗：指针停在一座城附近，就在那座城上画一个圈、写它的名字与此刻的当地时间；右键可以把它加进地点。
                    .overlay(alignment: .topLeading) {
                        if showsLabels, hovering, dragStart == nil, let probe, !probe.isPlace {
                            MapProbeMark(point: probe.point(in: mapSize, latitudes: latitudes), text: probeText(probe), bounds: mapSize,
                                         luminance: { MapRaster.luminance(instant: core.referenceDate, size: mapSize, scale: displayScale, latitudes: latitudes, in: $0) })
                        }
                    }
                    .contextMenu {
                        if opensEarth { Button("放大地图", action: openEarth) }
                        if showsLabels, let probe, !probe.isPlace {
                            Button(String(format: L10n.string("添加 %@", locale: model.uiLocale), probe.name)) {
                                model.addZone(ZoneOption(cityIndex: probe.index, record: probe.record))
                                self.probe = nil
                                probedAt = nil
                            }
                            Divider()
                        }
                        if opensEarth || showsLabels { Button("拷贝这张图", action: copyPicture) }
                        if showsLabels {
                            Button("复制全部各地时间") { reportCopy(model.copyAllPlaceTimes() != nil) }
                                .disabled(core.zones.isEmpty)
                        }
                    }
                    .overlay(alignment: .top) {
                        if opensEarth, let copyResult {
                            MapCopyReceipt(ok: copyResult, paper: dragHintPaper)
                                .padding(.top, 8)
                        }
                    }
                    .task(id: copyStamp) {
                        guard copyResult != nil else { return }
                        try? await Task.sleep(for: .seconds(1.5))
                        if !Task.isCancelled { copyResult = nil }
                    }
                    .overlay(alignment: .topTrailing) {
                        if opensEarth && hovering {
                            let paper = LightPalette.paperReads(on: MapRaster.luminance(instant: core.referenceDate,
                                size: mapSize, scale: displayScale, latitudes: latitudes,
                                in: CGRect(x: mapSize.width - 27, y: 5, width: 22, height: 22)))
                            Button { openEarth() } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .foregroundStyle(SkyTextRole.mapGlyph.foreground(paper: paper))
                                    .frame(width: 22, height: 22).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(paper ? LightPalette.ink : LightPalette.paper, in: RoundedRectangle(cornerRadius: 5))
                            .padding(5)
                            .help(Text("放大地图"))
                        }
                    }
                    .help(Text(mapHelp))
                    .onDisappear { monitor.remove() }
                    #if DEBUG
                    .task {
                        // 截图夹具：`MEANTIME_UI_TEST_EARTH_PROBE=纬度,经度` 假装指针停在那里（只在地球窗、只在测试宿主）。
                        guard showsLabels, ApplicationSession.isTesting,
                              let raw = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_EARTH_PROBE"] else { return }
                        let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                        guard parts.count == 2 else { return }
                        try? await Task.sleep(for: .milliseconds(600))
                        hovering = true
                        updateProbe(at: MapProbe.point(latitude: parts[0], longitude: parts[1], in: mapSize, latitudes: latitudes),
                                    zones: Self.places(in: core).zones)
                    }
                    #endif
            } else {
                scene
            }
        }
        .accessibilityElement(children: .ignore)
        // 合成一个图像元素（与排会时间轴、天文图同一做法），否则 VoiceOver 念「未知」（转储 R5）。
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(Text("昼夜地图"))
        .accessibilityValue(Text(verbatim: accessibilityValue(lit: lit, subsolar: subsolar, zones: zones)))
        .modifier(MapAccessibilityActions(enabled: interactive, opensEarth: opensEarth,
                                          adjust: { hours in model.jump(to: MapScrub.step(from: core.referenceDate, minutes: 60, forward: hours > 0, in: .current)) },
                                          enlarge: openEarth, copiesPicture: opensEarth || showsLabels, copiesTimes: showsLabels,
                                          copyPicture: copyPicture, copyTimes: { reportCopy(model.copyAllPlaceTimes() != nil) }))
    }

    /// 抓住地图左右拖：太阳跟着指针，时间跟着太阳；拖动中不动画、按整分钟跳，松手带动画对齐到整刻钟。
    private var drag: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let start = dragStart ?? core.referenceDate
                if dragStart == nil { dragStart = start }
                let target = MapScrub.wholeMinute(start.addingTimeInterval(MapScrub.minutes(forDrag: value.translation.width, width: monitor.width) * 60))
                guard target != lastDragMinute else { return }
                lastDragMinute = target
                model.jump(to: target, animated: false)
            }
            .onEnded { value in
                guard let start = dragStart else { return }
                dragStart = nil
                lastDragMinute = nil
                let target = start.addingTimeInterval(MapScrub.minutes(forDrag: value.translation.width, width: monitor.width) * 60)
                let landed = MapScrub.snapped(target)
                model.jump(to: landed, animated: true)
                // 学一次：真挪动了时间才算一次拖动——计数、熄掉滑块提示。
                if landed != start {
                    model.noteMapDrag()
                    onTimeDragged?()
                }
            }
    }

    private var mapSize: CGSize {
        CGSize(width: monitor.width, height: monitor.width * (latitudes.upperBound - latitudes.lowerBound) / 360)
    }

    /// 提示气泡：面板那张与地球窗各写全自己的招数；欢迎页只说拖与扫。
    private var mapHelp: LocalizedStringKey {
        if opensEarth { return "拖动或左右轻扫改变时间 · 连按两次放大" }
        if showsLabels { return "拖动改变时间 · ← → 走一小时 · ⌥ 走一刻钟 · ⌘C 拷贝地图" }
        return "拖动地图或左右轻扫改变时间"
    }

    /// 顶上那条（拷贝回执）的底色深浅：与地图标签同一判据，按底下那块地图实算选墨或纸。
    private var dragHintPaper: Bool {
        let width = monitor.width
        guard width > 0 else { return true }
        let strip = CGRect(x: width / 2 - 60, y: 0, width: 120, height: 26)
        return LightPalette.paperReads(on: MapRaster.luminance(instant: core.referenceDate, size: mapSize, scale: displayScale, latitudes: latitudes, in: strip))
    }

    /// 指针挪了 1 pt 以上才重查（`MapProbe.lookup`）。
    private func updateProbe(at location: CGPoint, zones: [TimeZoneEntry]) {
        guard dragStart == nil else { return }
        if let last = probedAt, hypot(location.x - last.x, location.y - last.y) < 1 { return }
        probedAt = location
        let found = MapProbe.lookup(at: location, in: mapSize, latitudes: latitudes, zones: zones) { index, record in
            // 还是同一座城就不重算本地化名字（名字要走索引与 ICU 转写，指针每挪 1 pt 都算一遍不值）。
            if let current = probe, current.index == index { return current.name }
            return model.displayName(for: ZoneOption(cityIndex: index, record: record))
        }
        if found != probe { probe = found }
    }

    private func probeText(_ probe: MapProbe) -> String {
        let time = Self.clock(core.referenceDate, in: TimeZone(identifier: probe.record.timezoneID) ?? .gmt,
                              hourStyle: model.settings.hourStyle, locale: model.uiLocale)
        return "\(probe.name) \(time)"
    }

    private func scrub(by minutes: Double) {
        guard minutes != 0 else { return }
        model.jump(to: core.referenceDate.addingTimeInterval(minutes * 60), animated: false)
    }

    private func copyPicture() {
        reportCopy(EarthPoster.copy(model: model, core: core))
    }

    private func reportCopy(_ ok: Bool) {
        if let onCopied { onCopied(ok) } else {
            copyResult = ok
            copyStamp += 1
            AccessibilityNotification.Announcement(L10n.string(ok ? "已复制" : "无法复制，请重试。", locale: core.uiLocale)).post()
        }
    }

    private func openEarth() {
        openWindow(id: "earth")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// 「太阳正照着×× · 白天：××× · 曙暮：××× · 夜里：×××」：读屏念这一句，肉眼看图。先说太阳正照着哪一段
    /// （直射点经度落在 `SunPhase.band` 八段里的哪段，名字用 `SunPhase.bandKeys` 对应的文案键），再按
    /// 白天 / 曙暮 / 夜 分组，空组不提；组内名字仍由 `ListFormatter` 按界面语言串，组间仍是「 · 」。
    /// 有坐标的地点按直射点实算太阳高度角分档（与昼夜条同一套三档判据），没坐标的（或场景还没回来时）
    /// 沿用 `lit` 的昼 / 夜两档。
    private func accessibilityValue(lit: Set<Int>, subsolar: WorldMapScene.Subsolar?, zones: [TimeZoneEntry]) -> String {
        let name = { (zone: TimeZoneEntry) in zone.displayName(localizedCity: model.cityName(for: zone)) }
        let locale = model.uiLocale
        let formatter = ListFormatter()
        formatter.locale = locale
        var day: [String] = [], twilight: [String] = [], night: [String] = []
        for (index, zone) in zones.enumerated() {
            let phase: SunPhase.Phase
            if let sun = subsolar, let c = zone.coordinate {
                phase = SunPhase.phase(altitude: SunPhase.altitude(latitude: c.latitude, longitude: c.longitude,
                                                                   subsolarLatitude: sun.latitude, subsolarLongitude: sun.longitude))
            } else {
                phase = lit.contains(index) ? .day : .night
            }
            switch phase {
            case .day: day.append(name(zone))
            case .twilight: twilight.append(name(zone))
            case .night: night.append(name(zone))
            }
        }
        let group = { (key: String, names: [String]) -> String? in
            names.isEmpty ? nil : String(format: L10n.string(key, locale: locale), formatter.string(from: names) ?? "")
        }
        var parts: [String] = []
        if let sun = subsolar {
            parts.append(String(format: L10n.string("太阳正照着%@", locale: locale),
                                L10n.string(SunPhase.bandKeys[SunPhase.band(longitude: sun.longitude)], locale: locale)))
        }
        parts += [group("白天：%@", day), group("曙暮：%@", twilight), group("夜里：%@", night)].compactMap { $0 }
        return parts.joined(separator: " · ")
    }
}

/// 读屏的两条路：可调（上下调 = 前后到整点，与键盘 ← → 同一步）与「放大地图」动作。只在能交互的地图上加。
private struct MapAccessibilityActions: ViewModifier {
    let enabled: Bool
    let opensEarth: Bool
    let adjust: (Double) -> Void
    let enlarge: () -> Void
    let copiesPicture: Bool
    let copiesTimes: Bool
    let copyPicture: () -> Void
    let copyTimes: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: adjust(1)
                    case .decrement: adjust(-1)
                    @unknown default: break
                    }
                }
                .accessibilityHint(Text("拖动地图或左右轻扫改变时间"))
                .modifier(EnlargeAction(enabled: opensEarth, enlarge: enlarge))
                .modifier(MapCopyActions(picture: copiesPicture, times: copiesTimes, copyPicture: copyPicture, copyTimes: copyTimes))
        } else {
            content
        }
    }
}

private struct EnlargeAction: ViewModifier {
    let enabled: Bool
    let enlarge: () -> Void
    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityAction(named: Text("放大地图"), enlarge)
        } else {
            content
        }
    }
}

/// 地图标签量字宽（省 CPU 一轮）：同一串字、同一字面只量一次（拖时间时钟点每分钟才变，名字不变），
/// 字体对象也只建一次。上限 256 条，满了整个清掉重来。
nonisolated enum TextMeasure {
    private struct Key: Hashable { let text: String; let serif: Bool; let size: CGFloat; let weight: CGFloat; let locale: String; let monospacedDigits: Bool }
    private static let cache = Mutex<[Key: CGSize]>([:])

    static func size(_ text: String, serif: Bool, size: CGFloat, weight: NSFont.Weight, locale: Locale,
                     monospacedDigits: Bool = true) -> CGSize {
        let key = Key(text: text, serif: serif, size: size, weight: weight.rawValue, locale: locale.identifier, monospacedDigits: monospacedDigits)
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let font = serif ? SerifFace.nsFont(text, size: size, weight: weight, locale: locale)
            : monospacedDigits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        let measured = (text as NSString).size(withAttributes: [.font: font])
        cache.withLock { entries in
            if entries.count >= 256 { entries.removeAll(keepingCapacity: true) }
            entries[key] = measured
        }
        return measured
    }
}


private struct MapCopyActions: ViewModifier {
    let picture: Bool
    let times: Bool
    let copyPicture: () -> Void
    let copyTimes: () -> Void
    func body(content: Content) -> some View {
        if times {
            content.accessibilityAction(named: Text("拷贝这张图"), copyPicture)
                .accessibilityAction(named: Text("复制全部各地时间"), copyTimes)
        } else if picture {
            content.accessibilityAction(named: Text("拷贝这张图"), copyPicture)
        } else { content }
    }
}

private struct MapCopyReceipt: View {
    let ok: Bool
    let paper: Bool
    var body: some View {
        MapText(paper: paper) {
            if ok { Label("已复制", systemImage: "checkmark") }
            else { ErrorLine(Text("无法复制，请重试。")) }
        }
        .appFont(.caption)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background((paper ? LightPalette.haloDark : LightPalette.haloLight).opacity(0.85), in: Capsule())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
