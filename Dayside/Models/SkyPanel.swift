// SPDX-License-Identifier: GPL-3.0-only
//
//  SkyPanel.swift
//  Dayside
//
//  面板的天色（Rust `sky.panel`）。每个地点此刻的天（底色与字色：字只有墨与纸，底色给字让路，
//  小字 ≥ 5.5:1，系统「提高对比度」时 7:1）、一天里的词（破晓 / 下午 / 深夜…）、太阳弧上太阳在哪、当地这一天的日出日落；
//  面板的框用这里此刻的天顶（≥ 8:1，框里系统控件的次要文字也够读）；滑块的圆点画太阳还是月亮。
//  只算一次、按地点 id 取：面板每分钟走一格、拖时间时 ~30 Hz 重算（十个地点约 1 ms）。
//  滑块轨道不在这里（2026-10-02 起）：它与工具窗页首天色带同一个 `sky.strip`，只在每分钟与换中心时算（`SliderTrackMemo`）。
//

import SwiftUI

struct SkyPanel: Equatable, Sendable {
    /// 一块底色与写在上面的字色。`ink` = 字用墨（底是浅的），否则用纸；`ratio` 是字对底（渐变两端里差的那一端）的对比度。
    struct Colors: Decodable, Equatable, Sendable {
        let top: String
        let horizon: String
        let mid: String
        let ink: Bool
        let ratio: Double

        var foreground: Color { ink ? LightPalette.ink : LightPalette.paper }
        var topColor: Color { LightPalette.color(top) }
        var horizonColor: Color { LightPalette.color(horizon) }
        var midColor: Color { LightPalette.color(mid) }
        /// 这块底上系统控件该用的外观：墨字的底是浅色。
        var scheme: ColorScheme { ink ? .light : .dark }
    }

    /// 太阳弧上太阳的位置：`up` 白天在弧上（0 日出一端 … 1 日落一端），夜里在地平线下从落下的一端往升起的一端走。
    struct SunPath: Decodable, Equatable, Sendable {
        let up: Bool
        let fraction: Double
    }

    struct Row: Decodable, Equatable, Sendable {
        /// 有坐标、算得出天色；没有（UTC 这类）就是纸色、没有词。
        let known: Bool
        let colors: Colors
        /// 太阳贴着地平线（−10° … 8°）：天顶到地平线画渐变；其余一种颜色。
        let gradient: Bool
        let word: String?
        let path: SunPath?
        let sunrise: Double?
        let sunset: Double?
    }

    private struct Output: Decodable {
        let rows: [Row]
        let dividers: [Bool]
        let chrome: Colors
        let dayHere: Bool?
    }

    private struct Place: Encodable {
        let latitude: Double?
        let longitude: Double?
        let utcOffset: Double
    }

    private struct Input: Encodable {
        let instant: Double
        let now: Double
        let home: Place
        let places: [Place]
        let need: Double
        let flat: Bool
        /// 界面语言：一天里的词按这种语言自己的钟点表（Rust `day_words`）。
        let language: String
    }

    /// 按地点 id 取的行。
    let rows: [UUID: Row]
    /// 相邻天色接近时，在行顶画分隔线。
    let dividers: [UUID: Bool]
    /// 框（搜索栏、说明行、滑块、底栏）的底色与字色。
    let chrome: Colors
    /// 看的那一刻这里是白天（滑块的圆点画太阳）还是夜里（画月亮）；没有本机坐标时 nil。
    let dayHere: Bool?

    /// 界面语言 → `day_words` 认的语言码（简繁按文字系统分、葡萄牙语用巴西那张表）。
    static func languageCode(_ locale: Locale) -> String {
        let code = locale.language.languageCode?.identifier ?? "en"
        switch code {
        case "zh": return SerifFace.isTraditional(locale) ? "zh-Hant" : "zh-Hans"
        case "pt": return "pt-BR"
        default: return code
        }
    }

    /// `need`：小字要的对比度（5.5；系统「提高对比度」时 7）。`locale`：界面语言（一天里的词用）。
    /// 本机在哪：地点里有与本机同一时区的就用它的坐标，否则用随包坐标表里这个时区的代表城市（不碰城市索引）。
    /// 面板的框、滑块轨道与工具窗的页首天色带都按它画「这里的天」。
    static func homeCoordinate(zones: [TimeZoneEntry], home: TimeZone = .current) -> Coordinate? {
        zones.first { $0.timezoneID == home.identifier }?.coordinate ?? ZoneCatalog.shared.knownCoordinate(for: home.identifier)
    }

    static func compute(instant: Date, now: Date, zones: [TimeZoneEntry], need: Double, locale: Locale, flat: Bool = false) -> SkyPanel {
        let home = TimeZone.current
        let homeCoordinate = homeCoordinate(zones: zones, home: home)
        let place = { (coordinate: Coordinate?, zone: TimeZone) in
            Place(latitude: coordinate?.latitude, longitude: coordinate?.longitude, utcOffset: Double(zone.secondsFromGMT(for: instant)))
        }
        let output: Output = RustCore.invoke("sky.panel", Input(
            instant: instant.timeIntervalSince1970, now: now.timeIntervalSince1970,
            home: place(homeCoordinate, home), places: zones.map { place($0.coordinate, $0.timeZone) }, need: need, flat: flat,
            language: languageCode(locale)))
        return SkyPanel(rows: Dictionary(zip(zones.map(\.id), output.rows), uniquingKeysWith: { first, _ in first }),
                        dividers: Dictionary(zip(zones.map(\.id), output.dividers), uniquingKeysWith: { first, _ in first }),
                        chrome: output.chrome, dayHere: output.dayHere)
    }
}

extension EnvironmentValues {
    /// 面板的天色：面板根视图算好往下传；为 nil 时（设置里「跟着系统」之外的别处、测试）各视图按系统样式画。
    @Entry var panelSky: SkyPanel? = nil
    /// 面板的框是否跟着天色（设置「面板底色」）：true 时框涂这里的天顶、字用墨或纸。
    @Entry var panelFollowsSky: Bool = false
}
