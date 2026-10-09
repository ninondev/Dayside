// SPDX-License-Identifier: GPL-3.0-only
//
//  CityIndexTests.swift
//  DaysideTests
//
//  离线城市索引与双层目录的回归护栏。
//
//  为什么这些用例存在:改版前目录只有 zone1970.tab 的 312 个「时区代表城市」,
//  实测 97 个常见城市里 78 个搜不到——Beijing / Munich / Boston / Mumbai / Oslo 全军覆没。
//  下面每一组都钉死一类当时失败的查询,防止索引生成器或折叠规则被改坏后悄悄退化。
//
//  折叠规则在 Python 生成器与 Swift 运行期各有一份实现,**必须逐字节一致**。
//  跨脚本用例(北京 / москва / 서울 / القاهرة)就是这条一致性的活体检验:
//  任何一侧的规范化改动只要不同步,这些用例立刻红。
//

import XCTest
import Testing
@testable import Dayside

final class CityIndexTests: XCTestCase {

    private func first(_ query: String, locale: Locale? = nil) -> ZoneOption? {
        ZoneCatalog.shared.search(query, locale: locale).first
    }

    private func names(_ query: String, locale: Locale? = nil) -> [String] {
        ZoneCatalog.shared.search(query, locale: locale).map(\.cityName)
    }

    // MARK: - 覆盖:改版前搜不到的城市

    func testCitiesThatUsedToBeUnreachable() throws {
        // 左边是用户会敲的,右边是它必须落到的时区。这些城市**都不是**任何时区的代表城市,
        // 所以只补时区别名解决不了——Beijing 的时区是 Asia/Shanghai。
        let cases: [(String, String)] = [
            ("Beijing", "Asia/Shanghai"), ("Munich", "Europe/Berlin"),
            ("Boston", "America/New_York"), ("Mumbai", "Asia/Kolkata"),
            ("Oslo", "Europe/Oslo"), ("Amsterdam", "Europe/Amsterdam"),
            ("San Francisco", "America/Los_Angeles"), ("Cape Town", "Africa/Johannesburg"),
            ("Shenzhen", "Asia/Shanghai"), ("Osaka", "Asia/Tokyo"),
            ("Manchester", "Europe/London"), ("Kuala Lumpur", "Asia/Kuala_Lumpur"),
        ]
        for (query, timezone) in cases {
            let hit = try XCTUnwrap(first(query), "搜不到:\(query)")
            XCTAssertEqual(hit.identifier, timezone, "\(query) 落错时区")
        }
    }

    // MARK: - 跨脚本(= 两侧折叠规则一致性的活体检验)

    func testNativeScriptQueries() throws {
        let cases: [(String, String)] = [
            ("北京", "Asia/Shanghai"), ("東京", "Asia/Tokyo"), ("서울", "Asia/Seoul"),
            ("москва", "Europe/Moscow"), ("القاهرة", "Africa/Cairo"),
            ("Αθήνα", "Europe/Athens"), ("münchen", "Europe/Berlin"),
            ("São Paulo", "America/Sao_Paulo"), ("İstanbul", "Europe/Istanbul"),
        ]
        for (query, timezone) in cases {
            let hit = try XCTUnwrap(first(query), "搜不到:\(query)")
            XCTAssertEqual(hit.identifier, timezone, "\(query) 落错时区")
        }
    }

    /// 旧称/别称必须仍然可搜——GeoNames 主名已改,但用户还在用老名字。
    func testFormerNamesStillResolve() throws {
        for (query, timezone) in [("Bangalore", "Asia/Kolkata"), ("Bombay", "Asia/Kolkata"),
                                  ("Calcutta", "Asia/Kolkata"), ("Saigon", "Asia/Ho_Chi_Minh"),
                                  ("Peking", "Asia/Shanghai")] {
            let hit = try XCTUnwrap(first(query), "搜不到旧称:\(query)")
            XCTAssertEqual(hit.identifier, timezone, "\(query) 落错时区")
        }
    }

    /// 标点归一化:句点、连字符、撇号都不该挡住命中。
    func testPunctuationIsNormalised() throws {
        XCTAssertEqual(first("St. Petersburg")?.identifier, first("St Petersburg")?.identifier)
        XCTAssertEqual(first("Saint Petersburg")?.identifier, first("St Petersburg")?.identifier)
        XCTAssertNotNil(first("Baden-Baden"))
        XCTAssertNotNil(first("N'Djamena"))
    }

    // MARK: - 排序

    /// 严格分层会让「york」的十几座同名小镇按精确命中排满前排、把 New York 挤出结果。
    /// 乘性打分让极热门的次名命中压得过冷门的精确命中。
    func testPopularityOutranksObscureExactMatches() throws {
        let results = names("York")
        let newYork = try XCTUnwrap(results.firstIndex { $0.contains("New York") }, "New York 必须出现在 york 的结果里")
        XCTAssertLessThan(newYork, 3, "New York 应排在前列,而不是被同名小镇挤到后面")
    }

    /// 同名城市之间按人口定序:开罗(埃及)必须压过开罗(美国佐治亚州)。
    func testSameNameDisambiguatesByPopulation() throws {
        XCTAssertEqual(first("Cairo")?.countryCode, "EG")
        XCTAssertEqual(first("moscow")?.identifier, "Europe/Moscow")
        XCTAssertEqual(first("Paris")?.identifier, "Europe/Paris")
        XCTAssertEqual(first("San Jose")?.identifier, "America/Los_Angeles")
    }

    /// 副标题要能把同名城市区分开,否则 23 万座城市里一堆 San Jose 没法选。
    func testSubtitleDisambiguates() throws {
        let results = ZoneCatalog.shared.search("Springfield", locale: nil)
        XCTAssertGreaterThan(results.count, 2)
        let subtitles = Set(results.map { $0.subtitle(locale: Locale(identifier: "en")) })
        XCTAssertEqual(subtitles.count, results.count, "同名城市的副标题必须两两不同")
    }

    // MARK: - 显示名的正确性

    private func localizedName(_ query: String, _ localeID: String) -> String? {
        guard let option = ZoneCatalog.shared.search(query, locale: nil).first,
              let index = option.cityIndex else { return nil }
        return CityNameLanguage.name(from: CityIndex.shared.localizedNames(cityIndex: index),
                                     locale: Locale(identifier: localeID))
    }

    /// GeoNames 有大量条目把语言列留空,中国有 4,745 座城市的中文名因此被整批丢掉,
    /// 中文界面只能显示 name 字段的拼音——用户能用中文**搜到**它,却看不懂显示的是什么。
    func testUntaggedNativeNamesAreRecovered() throws {
        // 成县:GeoNames 主名是 "Chengxian Chengguanzhen",三条中文名(成县 / 城关镇 /
        // 成县城关镇)全都没有语言标注。这是实际报上来的那一条。
        XCTAssertEqual(localizedName("成县", "zh-Hans"), "成县")
        XCTAssertEqual(localizedName("Chengxian Chengguanzhen", "zh-Hans"), "成县")
        XCTAssertEqual(localizedName("Zepu", "zh-Hans"), "泽普")
        XCTAssertEqual(localizedName("Xitieshan", "zh-Hans"), "锡铁山")
    }

    /// 最硬的一条判据:候选的**读音**与拉丁主名对得上——GeoNames 自己的两种写法互证。
    /// 汉字→读音表是从它自带的机器音译学来的(7.6 万组对齐样本,2,700 多字),不引外部词典。
    func testPinyinCrossCheckResolvesTheRightName() throws {
        // 慈溪(146 万人)的候选里混着老驻地名「浒山」,读音只有慈溪对得上 Cixi
        XCTAssertEqual(localizedName("Cixi", "zh-Hans"), "慈溪")
        XCTAssertEqual(localizedName("Taicang", "zh-Hans"), "太仓")
        XCTAssertEqual(localizedName("Yongji", "zh-Hans"), "永济")
        // 沈高的候选是「丁家舍 / 沈高 / 沈高镇」,丁家舍是同地异名;
        // 读音表从别的城市学到 沈→shen,于是认得出哪个才是 Shengao
        XCTAssertEqual(localizedName("Shengao", "zh-Hans"), "沈高")
    }

    /// 读音对不上就**不猜**:蒙、藏、粤语罗马化的拉丁主名不是汉语拼音,
    /// 拼音表无从互证,而候选里又混着旧名(乌兰浩特 / 王爷庙),没有带语言标注的名字时留拉丁名。
    /// 试过「取变体多的那一组」兜底,实测 Oroqen Zizhiqi 会被挑成「阿里河」
    /// 而正确答案是「鄂伦春自治旗」——有反例的判据不用。
    /// Wikidata 有「乌兰浩特市」strong 标签；裸名「乌兰浩特」依通名规则参与搜索。
    /// 这不是猜,是另一份数据源点名了它。「不猜」的性质由 Rust `unlabeled_disagreeing_names_do_not_guess_a_city` 守着。
    func testUnromanizableNamesStayLatin() throws {
        XCTAssertEqual(localizedName("Ulanhot", "zh-Hans"), "乌兰浩特")
    }

    /// 去尾只许去行政通名。只卡「是不是前缀」不够——实测按纯前缀截,
    /// 两座不同的城市会被截成同一个名字。
    func testTruncationNeverSwapsInAnotherPlace() throws {
        XCTAssertEqual(localizedName("Rostov-on-Don", "ru"), "Ростов-на-Дону")
        XCTAssertEqual(localizedName("Rostov Veliky", "ru"), "Ростов Великий")
        XCTAssertEqual(localizedName("San Francisco", "ko"), "샌프란시스코")
        // Ciudad Nezahualcóyotl 的 strong 标签优先于 GeoNames；Neza 仍不允许。
        XCTAssertEqual(localizedName("Ciudad Nezahualcoyotl", "es"), "Ciudad Nezahualcóyotl")
        // Wikidata 的德语标签「Frankfurt (Oder)」带括号,整条不收(去掉括号就成了另一座城的「Frankfurt」),留 GeoNames 的写法。
        XCTAssertEqual(localizedName("Frankfurt (Oder)", "de"), "Frankfurt an der Oder")
        // 反面:真的是行政通名就该去掉,别因为收紧而不敢去尾了
        XCTAssertEqual(localizedName("Busan", "ja"), "釜山")          // 釜山広域市
        XCTAssertEqual(localizedName("Seoul", "zh-Hans"), "首尔")      // 首尔特别市
        XCTAssertEqual(localizedName("Amakusa", "ja"), "天草")         // 天草市役所
        XCTAssertEqual(localizedName("Maidiping", "zh-Hans"), "麦地坪") // 麦地坪白族乡
    }

    /// 直辖单位的行政区名等于城市名,重复显示既不消歧也不好看,
    /// 而 GeoNames 恰好对这批缺中文名(Moscow/Delhi/Jakarta/Hanoi 都没有),
    /// 留着就会拼成「莫斯科 / Moscow, 俄罗斯」这种中英混排。
    func testRedundantAdminRegionIsOmitted() throws {
        let zh = Locale(identifier: "zh-Hans")
        let moscow = try XCTUnwrap(ZoneCatalog.shared.search("Moscow", locale: nil).first)
        XCTAssertEqual(moscow.subtitle(locale: zh), "俄罗斯")
        let beijing = try XCTUnwrap(ZoneCatalog.shared.search("Beijing", locale: nil).first)
        XCTAssertEqual(beijing.subtitle(locale: zh), zh.localizedString(forRegionCode: "CN"))
        // 反面:行政区是另一个地名时照常显示
        let springfield = try XCTUnwrap(ZoneCatalog.shared.search("Springfield", locale: nil).first)
        XCTAssertFalse(springfield.subtitle(locale: zh).hasPrefix("美国"))
    }

    /// 副标题过去是「Gansu, 中国大陆」这种中英混排——只有国家名走了本地化,
    /// 一级行政区名在索引里只有英文。
    func testAdminRegionIsLocalized() throws {
        let zh = Locale(identifier: "zh-Hans")
        let chengxian = try XCTUnwrap(ZoneCatalog.shared.search("成县", locale: nil).first)
        XCTAssertEqual(chengxian.subtitle(locale: zh), "甘肃, " + zh.localizedString(forRegionCode: "CN")!)
        XCTAssertEqual(chengxian.subtitle(locale: Locale(identifier: "en")), "Gansu, China mainland")

        let munich = try XCTUnwrap(ZoneCatalog.shared.search("Munich", locale: nil).first)
        XCTAssertTrue(munich.subtitle(locale: zh).hasPrefix("巴伐利亚州"),
                      "德国州名也要按界面语言,实得 \(munich.subtitle(locale: zh))")
        // 没有该语言写法时如实退回英文名,不留空
        XCTAssertFalse(munich.subtitle(locale: Locale(identifier: "ko")).isEmpty)
    }

    /// 行政区中文补充表覆盖 1,526 个行政区，搜索应能识别补充的名字。
    /// 中文副标题里的拉丁行政区名从 38,407 座城市降到 0（LU.LU / SM.07 与国家同名，靠严格相等去重消掉）。
    /// Wikidata 来源与 LLM 来源各挑一个，繁体没给的走简体转换。
    func testSupplementedAdminRegionsShowChineseNames() throws {
        let zh = Locale(identifier: "zh-Hans")
        let erfurt = try XCTUnwrap(ZoneCatalog.shared.search("Erfurt", locale: nil).first)
        XCTAssertEqual(erfurt.subtitle(locale: zh), "图林根州, 德国")                       // 补充表（秩 1）压过只有裸 zh 标签的 weak「圖林根邦」
        XCTAssertEqual(erfurt.subtitle(locale: Locale(identifier: "zh-Hant")), "圖林根邦, 德國") // Wikidata zh-tw 标签（strong）：台湾对德国各州叫「邦」
        let dubai = try XCTUnwrap(ZoneCatalog.shared.search("Dubai", locale: nil).first)
        XCTAssertEqual(dubai.subtitle(locale: zh), "阿拉伯联合酋长国", "迪拜酋长国与城市同名，照旧去重")
        let hanoi = try XCTUnwrap(ZoneCatalog.shared.search("Hanoi", locale: nil).first)
        XCTAssertEqual(hanoi.subtitle(locale: zh), "越南", "河内的行政区就是河内市本身，与城市名相同要去重")
        let daNang = try XCTUnwrap(ZoneCatalog.shared.search("Da Nang", locale: nil).first)
        XCTAssertEqual(daNang.subtitle(locale: zh), "越南")
        let cebu = try XCTUnwrap(ZoneCatalog.shared.search("Manila", locale: nil).first)
        XCTAssertEqual(cebu.subtitle(locale: zh), "马尼拉大都会, 菲律宾")                   // llm，按 Wikidata 同名项改
        XCTAssertEqual(cebu.subtitle(locale: Locale(identifier: "zh-Hant")), "馬尼拉大都會, 菲律賓") // 简体转换
        let luxembourg = try XCTUnwrap(ZoneCatalog.shared.search("Luxembourg", locale: nil).first)
        XCTAssertEqual(luxembourg.subtitle(locale: zh), "卢森堡", "行政区与国家同名只显示一次")
    }

    /// GeoNames 的俄文名里主格与变格形并存(`Каттак` / `Каттаке`),两条都无标记。
    /// 判据是拉丁主名的词尾:主名以辅音收尾、西里尔形却多一个元音 → 那是格尾。
    func testRussianCaseEndingsAreDropped() throws {
        XCTAssertEqual(localizedName("Cuttack", "ru"), "Каттак")
        XCTAssertEqual(localizedName("Dehradun", "ru"), "Дехрадун")
        XCTAssertEqual(localizedName("Woking", "ru"), "Уокинг")
        XCTAssertEqual(localizedName("Hereford", "ru"), "Херефорд")
    }

    /// 反面且更要紧:主名本身以元音收尾时,末尾那个元音是名字的一部分,去掉就成了另一个词。
    func testRussianNamesEndingInAVowelAreKept() throws {
        // 俄语 strong 标签「Мангалур」优先于 GeoNames「Мангалуру」。
        // 不是去尾；去尾规则本身由下面两条与 Rust 的 `inflected` 测试守着。
        XCTAssertEqual(localizedName("Mangaluru", "ru"), "Мангалур")
        XCTAssertEqual(localizedName("Chinari", "ru"), "Чинари")
        XCTAssertEqual(localizedName("Ts’khinvali", "ru"), "Цхинвали")
    }

    /// 上游勘误:GeoNames 自身标注有误、且它自己已给出正确名字的条目。
    /// 勘误只能在已有候选里改选,不能凭空造名(生成器里有机器断言兜底)。
    func testUpstreamErrata() throws {
        // Wimbledon 的 zh-CN 名被标成了赛事名「温布尔登网球锦标赛」
        XCTAssertEqual(localizedName("Wimbledon", "zh-Hans"), "温布尔登")
        // Dnipro 2016 年改名,英文旧名标了 isHistoric,日韩两条旧名音译却没标;
        // 没有当前名的音译,如实退回拉丁主名而不是显示旧城名
        XCTAssertNil(localizedName("Dnipro", "ja"))
        XCTAssertNil(localizedName("Dnipro", "ko"))
    }

    /// ICU 的繁简转换会改坏个别本就正确的字。例外字表是**实测**扩充的:
    /// 拿大陆地名当证据集,只认「整串确认是简体、ICU 却仍要改其中某字」,
    /// 再用「换成目标字后的串是否也在数据里」过滤掉简繁一对的情形。
    func testICUDoesNotCorruptCorrectCharacters() throws {
        XCTAssertEqual(localizedName("Qianwu", "zh-Hans"), "乾务")      // 不得变成「干务」
        XCTAssertEqual(localizedName("Ganfeng", "zh-Hans"), "乾丰")
        XCTAssertEqual(localizedName("Erfenzi", "zh-Hans"), "二份子")    // 不得变成「二分子」
        XCTAssertEqual(localizedName("Yuqian", "zh-Hans"), "於潜")      // 不得变成「于潜」
    }

    /// 结构性护栏:ICU 会把 BMP 内的字「简化」成扩展区汉字(埨→U+2BB62),
    /// 那些码位多数字体没有字形,用户看到豆腐块。无论字表上对不对,显示不出来一定是错的。
    func testNeverConvertIntoAstralCharacters() throws {
        // 「大埨」不用拉丁名查:Dalun 会先命中巴厘岛人口大得多的 Dalung(乘性打分按设计如此)
        for (query, expected) in [("大埨", "大埨"), ("Zhigong", "织篢"), ("Tuotang", "鮀塘")] {
            let name = try XCTUnwrap(localizedName(query, "zh-Hans"))
            XCTAssertEqual(name, expected)
            XCTAssertTrue(name.unicodeScalars.allSatisfy { $0.value <= 0xFFFF },
                          "\(query) 的显示名混进了星平面字符:\(name)")
        }
    }

    /// GeoNames 里有一批录入残渣:俄罗斯小镇的中文名普遍带 Wikipedia 消歧后缀的残尾
    /// (「莫什科沃_」——原标题是「莫什科沃_新西伯利亚州」,导入时从下划线处截断了),
    /// 另有零宽/方向控制字符与连续空格。生成器统一清洗,清的是残渣不是名字。
    func testDataEntryJunkIsCleaned() throws {
        XCTAssertEqual(localizedName("Moshkovo", "zh-Hans"), "莫什科沃")
        XCTAssertEqual(localizedName("Bashmakovo", "zh-Hans"), "巴什马科沃")
        XCTAssertEqual(localizedName("Belogorsk", "zh-Hans"), "别洛戈尔斯克")
    }

    /// 面上的护栏:人口最靠前的几千座城市,显示名不得带首尾杂字符 / 不可见字符 / 连续空格。
    /// 逐条列不现实,这里按覆盖面扫一遍,数据源换版本时能立刻发现新的脏数据。
    func testNoDisplayNameCarriesJunk() throws {
        let index = CityIndex.shared
        let invisible = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{FEFF}")
        let edgeJunk = CharacterSet(charactersIn: "_,/\\|;:·、-–— \t")
        for cityIndex in 0..<min(5_000, index.cityCount) {
            guard let record = index.city(at: cityIndex) else { continue }
            for name in [record.name] + Array(index.localizedNames(cityIndex: cityIndex).values) {
                XCTAssertNil(name.rangeOfCharacter(from: invisible), "不可见字符:\(name)")
                XCTAssertFalse(name.contains("  "), "连续空格:\(name)")
                XCTAssertFalse(name.unicodeScalars.first.map(edgeJunk.contains) ?? false,
                               "首部杂字符:\(name)")
                XCTAssertFalse(name.unicodeScalars.last.map(edgeJunk.contains) ?? false,
                               "尾部杂字符:\(name)")
            }
        }
    }

    /// GeoNames 的语言标签不保证内容真是那门语言:Amsterdam 的 ja 名存着罗马字
    /// 「Amusuterudamu」、ko 名存着「Amsŭt'erŭdam」,三巴旺的 zh 名存着拼音「Sanbawang」,
    /// Pryluky 的 ja 名干脆是缅甸文。按文种校验后,同条目里真正的母语写法就浮上来了。
    func testWrongScriptCandidatesAreRejected() throws {
        XCTAssertEqual(localizedName("Amsterdam", "ja"), "アムステルダム")
        XCTAssertEqual(localizedName("Amsterdam", "ko"), "암스테르담")
        XCTAssertEqual(localizedName("Sembawang Estate", "zh-Hans"), "三巴旺")
        XCTAssertEqual(localizedName("Suncheon", "ko"), "순천")
        // GeoNames 的 zh 罗马化「Línzhōu Xiàn」因文字系统不符被拒；Wikidata 的「林周县」是 strong 标签。
        // 没有 Wikidata 名时仍如实退回拉丁主名而不是显示罗马化(Rust `script_fits` 守着)。
        XCTAssertEqual(localizedName("Lhünzhub", "zh-Hans"), "林周县")
    }

    /// 面上的护栏:显示名的文种必须与语言槽相符,数据源换版本时能立刻发现新的错标。
    func testDisplayNamesMatchTheirLanguageScript() throws {
        func scripts(_ s: String) -> Set<String> {
            var out: Set<String> = []
            for scalar in s.unicodeScalars where CharacterSet.letters.contains(scalar) {
                switch scalar.value {
                case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: out.insert("HAN")
                case 0x3040...0x30FF:                                   out.insert("KANA")
                case 0xAC00...0xD7AF, 0x1100...0x11FF:                  out.insert("HANGUL")
                case 0x0400...0x04FF:                                   out.insert("CYRL")
                case 0..<0x0250, 0x1E00...0x1EFF:                       out.insert("LATN")
                default:                                                out.insert("OTHER")
                }
            }
            return out
        }
        let allowed: [String: Set<String>] = [
            "zh-Hans": ["HAN"], "zh-Hant": ["HAN"], "ja": ["HAN", "KANA"],
            "ko": ["HANGUL", "HAN"], "ru": ["CYRL"],
            "es": ["LATN"], "fr": ["LATN"], "de": ["LATN"], "pt-BR": ["LATN"],
        ]
        let index = CityIndex.shared
        for cityIndex in 0..<min(5_000, index.cityCount) {
            for (code, name) in index.localizedNames(cityIndex: cityIndex) {
                guard let want = allowed[code] else { continue }
                XCTAssertFalse(scripts(name).isDisjoint(with: want),
                               "\(code) 槽里的「\(name)」文种不符")
            }
        }
    }

    // MARK: - 时区层的确定性智能查询(不上模型、零成本)

    func testOffsetQuery() throws {
        XCTAssertEqual(ZoneCatalog.parseOffsetSeconds("utc+8"), 8 * 3600)
        XCTAssertEqual(ZoneCatalog.parseOffsetSeconds("gmt-5:30"), -(5 * 3600 + 1800))
        XCTAssertEqual(ZoneCatalog.parseOffsetSeconds("+9"), 9 * 3600)
        XCTAssertNil(ZoneCatalog.parseOffsetSeconds("8"), "裸数字不该被当成偏移,否则半个世界都会命中")
        XCTAssertNil(ZoneCatalog.parseOffsetSeconds("tokyo"))

        let results = ZoneCatalog.shared.search("utc+9", locale: nil)
        XCTAssertFalse(results.isEmpty, "偏移查询应给出结果")
        let now = Date()
        for option in results {
            XCTAssertEqual(TimeZone(identifier: option.identifier)?.secondsFromGMT(for: now), 9 * 3600)
        }
    }

    func testAbbreviationQuery() throws {
        let jst = try XCTUnwrap(ZoneCatalog.shared.search("JST", locale: nil).first)
        XCTAssertEqual(jst.identifier, TimeZone.abbreviationDictionary["JST"])
    }

    /// 国家名不进索引,由系统按当前界面语言给出——所以任意语种都认。
    func testCountryQueryInAnyLanguage() throws {
        let english = ZoneCatalog.shared.search("Japan", locale: Locale(identifier: "en"))
        XCTAssertTrue(english.contains { $0.identifier == "Asia/Tokyo" }, "Japan 应给出日本的城市")
        let chinese = ZoneCatalog.shared.search("日本", locale: Locale(identifier: "zh-Hans"))
        XCTAssertTrue(chinese.contains { $0.identifier == "Asia/Tokyo" }, "「日本」也应给出日本的城市")
    }

    // MARK: - 可达性与性能

    /// 城市层再全,也不能让任何一个 IANA 时区变得不可达。
    func testEveryTimeZoneRemainsReachableByIdentifier() throws {
        for identifier in ["Asia/Kolkata", "Antarctica/Troll", "America/Adak",
                           "Pacific/Chatham", "Europe/Oslo", "UTC"] {
            let results = ZoneCatalog.shared.search(identifier, locale: nil)
            XCTAssertTrue(results.contains { $0.identifier == identifier },
                          "按标识搜不到:\(identifier)")
        }
        XCTAssertEqual(ZoneCatalog.shared.zones.count, Set(ZoneCatalog.shared.zones.map(\.identifier)).count,
                       "时区层不该有重复标识")
    }

    /// 逐键搜索是交互热路径。留足余量的上限:真实最坏(单字母查询)实测约 0.12ms。
    func testSearchStaysWellUnderInteractiveBudget() {
        let queries = ["a", "be", "tok", "new y", "springfield", "北京", "z", "san franc"]
        _ = ZoneCatalog.shared.search("warmup", locale: nil)
        let start = Date()
        let rounds = 25
        for _ in 0..<rounds {
            for q in queries { _ = ZoneCatalog.shared.search(q, locale: nil) }
        }
        let perQuery = Date().timeIntervalSince(start) / Double(rounds * queries.count)
        XCTAssertLessThan(perQuery, 0.010, "单次搜索不得超过 10ms(实测约 0.1ms),当前 \(perQuery * 1000)ms")
    }

    /// 索引缺失时不能崩、不能哑——要能降级到时区层并让界面说明原因。
    func testMissingIndexDegradesGracefully() {
        let absent = CityIndex(url: URL(fileURLWithPath: "/nonexistent/cities.ttcity"))
        XCTAssertFalse(absent.isAvailable)
        XCTAssertEqual(absent.cityCount, 0)
        XCTAssertTrue(absent.search(folded: "tokyo", limit: 8).isEmpty)
        XCTAssertNil(absent.city(at: 0))
    }

    // MARK: - 本地化显示名

    private func added(_ query: String) throws -> TimeZoneEntry {
        TimeZoneEntry(zone: try XCTUnwrap(first(query), "搜不到 \(query)"))
    }

    /// 加进列表后按界面语言显示当地写法——ICU 做不到这件事,它只认时区,
    /// 对慕尼黑(Europe/Berlin)会答"柏林"。
    func testLocalizedDisplayNames() throws {
        let beijing = try added("Beijing")
        let names = try XCTUnwrap(beijing.localizedNames)
        XCTAssertEqual(names["zh-Hans"], "北京")
        XCTAssertEqual(names["ko"], "베이징")
        XCTAssertEqual(names["ru"], "Пекин")
        XCTAssertEqual(names["fr"], "Pékin")

        let munich = try XCTUnwrap(added("Munich").localizedNames)
        XCTAssertEqual(munich["de"], "München")
        XCTAssertEqual(munich["zh-Hans"], "慕尼黑")
        XCTAssertEqual(munich["ja"], "ミュンヘン")
    }

    /// GeoNames 的裸 `zh` 标签**不保证是简体**(Tokyo 的 zh 名是「東京」、London 是「倫敦」)。
    /// 显示层必须归一化到用户选的字形,否则简体用户会看到繁体。
    func testChineseScriptIsNormalisedToTheRequestedForm() throws {
        let tokyo = try XCTUnwrap(added("Tokyo").localizedNames)
        XCTAssertEqual(CityNameLanguage.name(from: tokyo, locale: Locale(identifier: "zh-Hans")), "东京")
        XCTAssertEqual(CityNameLanguage.name(from: tokyo, locale: Locale(identifier: "zh-Hant")), "東京")

        let london = try XCTUnwrap(added("London").localizedNames)
        XCTAssertEqual(CityNameLanguage.name(from: london, locale: Locale(identifier: "zh-Hans")), "伦敦")
        XCTAssertEqual(CityNameLanguage.name(from: london, locale: Locale(identifier: "zh-Hant")), "倫敦")

        // 原生繁体条目只有一千多条,没有时由简体转出——繁体用户不该退回拉丁名
        let munich = try XCTUnwrap(added("Munich").localizedNames)
        XCTAssertNil(munich["zh-Hant"], "这条前提变了就要重看回退逻辑")
        XCTAssertEqual(CityNameLanguage.name(from: munich, locale: Locale(identifier: "zh-Hant")), "慕尼黑")
    }

    /// 行政全称去尾:较短候选若是所选名的前缀就取短的(「首尔」之于「首尔特别市」)。
    func testAdministrativeSuffixesAreTrimmed() throws {
        let seoul = try XCTUnwrap(added("Seoul").localizedNames)
        XCTAssertEqual(seoul["zh-Hans"], "首尔")
        XCTAssertEqual(seoul["ko"], "서울")
        XCTAssertEqual(seoul["ja"], "ソウル")
    }

    func testLanguageSlotResolution() {
        XCTAssertEqual(CityNameLanguage.code(for: Locale(identifier: "zh")), "zh-Hans")
        XCTAssertEqual(CityNameLanguage.code(for: Locale(identifier: "zh-TW")), "zh-Hant")
        XCTAssertEqual(CityNameLanguage.code(for: Locale(identifier: "zh-HK")), "zh-Hant")
        XCTAssertEqual(CityNameLanguage.code(for: Locale(identifier: "pt")), "pt-BR")
        XCTAssertEqual(CityNameLanguage.code(for: Locale(identifier: "ja")), "ja")
        XCTAssertEqual(CityNameLanguage.code(for: Locale(identifier: "it")), "it")
        XCTAssertEqual(CityNameLanguage.code(for: Locale(identifier: "id")), "id")
        XCTAssertEqual(CityNameLanguage.code(for: Locale(identifier: "tr-TR")), "tr")
        XCTAssertNil(CityNameLanguage.code(for: Locale(identifier: "sv")), "没有槽的语言退回拉丁主名")
        XCTAssertNil(CityNameLanguage.code(for: Locale(identifier: "en")), "英文直接用主名,不设槽")
    }

    /// 时区代表条目不带本地化名——它走系统 ICU,能随语言实时变。
    func testZoneEntriesDoNotCarryLocalizedNames() throws {
        let utc = try XCTUnwrap(ZoneCatalog.shared.search("UTC", locale: nil).first)
        XCTAssertEqual(utc.source, .zone)
        XCTAssertNil(TimeZoneEntry(zone: utc).localizedNames)
        XCTAssertTrue(TimeZoneEntry(zone: utc).usesExemplarName)
    }

    /// 本地化名必须能原样穿过一次编解码——它是随条目落盘的。
    func testLocalizedNamesSurvivePersistence() throws {
        let entry = try added("Munich")
        let data = try JSONEncoder().encode([entry])
        let back = try JSONDecoder().decode([TimeZoneEntry].self, from: data)
        XCTAssertEqual(back.first?.localizedNames?["de"], "München")
        XCTAssertEqual(back.first?.usesExemplarName, false)
    }
}

extension CityIndexTests {
    /// 繁简归一必须修好 GeoNames 的繁体误标(18% 的 zh 条目是繁体),
    /// 但**不得把已经正确的简体字改坏**——ICU 会把「大阪」改成「大坂」。
    func testScriptNormalisationDoesNotCorruptValidSimplifiedCharacters() throws {
        let hans = Locale(identifier: "zh-Hans")
        // 修好误标的繁体
        XCTAssertEqual(CityNameLanguage.name(from: ["zh-Hans": "東京"], locale: hans), "东京")
        XCTAssertEqual(CityNameLanguage.name(from: ["zh-Hans": "倫敦"], locale: hans), "伦敦")
        XCTAssertEqual(CityNameLanguage.name(from: ["zh-Hans": "開普敦"], locale: hans), "开普敦")
        // 不改坏本就正确的字
        XCTAssertEqual(CityNameLanguage.name(from: ["zh-Hans": "大阪市"], locale: hans), "大阪市")
        XCTAssertEqual(CityNameLanguage.name(from: ["zh-Hans": "俱知安町"], locale: hans), "俱知安町")
        // 混合:该简化的简化,例外字保持
        XCTAssertEqual(CityNameLanguage.name(from: ["zh-Hans": "大阪灣"], locale: hans), "大阪湾")
    }

    /// 显示名一律取数据里的本名,不得由任何"更好听/更短"的判据换成别的名字。
    /// 成都的 成都/成都市/天府 三条在 GeoNames 里标记全为 0,早先按长度打破平局
    /// 就把它挑成了雅称「天府」。
    func testDisplayNameIsTheActualNameNotANickname() throws {
        let chengdu = try XCTUnwrap(added("Chengdu").localizedNames)
        XCTAssertEqual(chengdu["zh-Hans"], "成都", "显示名必须取城市本名，不能取别称")
        let guangzhou = try XCTUnwrap(added("Guangzhou").localizedNames)
        XCTAssertEqual(guangzhou["zh-Hans"], "广州")
    }
}

@MainActor
final class CityNameRefreshTests: XCTestCase {
    /// 老条目带着修正前的旧名字(成都曾被挑成雅称「天府」),面板打开时必须对齐到当前索引。
    func testStaleLocalizedNamesAreRefreshedAgainstTheIndex() throws {
        let option = try XCTUnwrap(ZoneCatalog.shared.search("Chengdu", locale: nil).first)
        let cityIndex = try XCTUnwrap(option.cityIndex)
        let fresh = CityIndex.shared.localizedNames(cityIndex: cityIndex)
        XCTAssertEqual(fresh["zh-Hans"], "成都", "索引本身必须是正确的本名")

        // 模拟一条修正前存下的条目
        var stale = TimeZoneEntry(zone: option)
        stale.localizedNames = ["zh-Hans": "天府"]
        XCTAssertNotEqual(stale.localizedNames, fresh)

        // 对齐逻辑走的是「按拉丁本名 + 时区」回查索引」这条路,验证它能找回同一条城市
        let match = ZoneCatalog.shared.search(stale.cityName, locale: nil)
            .first { $0.identifier == stale.timezoneID && $0.cityName == stale.cityName }
        XCTAssertEqual(match?.cityIndex, cityIndex, "必须能按存下的本名找回同一座城市")
    }

    // MARK: - 地区标注

    /// 非争议地点的国家 / 地区名取系统（Apple 框架，CLDR 数据）按界面语言给出的写法。
    private func regionName(_ code: String, _ localeID: String) -> String {
        Locale(identifier: localeID).localizedString(forRegionCode: code) ?? code
    }

    private static let interfaceLanguages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "de", "es", "fr", "ru", "pt-BR",
                                             "it", "nl", "pl", "tr", "vi", "id"]

    /// GeoNames 国家码为 TW 的城市：十六种界面语言都只显示城市与时区，不显示行政区或国家。
    func testTaiwanCitiesShowNoRegionOrCountry() throws {
        for query in ["Taipei", "Kaohsiung", "Taichung", "Tainan", "Hsinchu"] {
            let city = try XCTUnwrap(ZoneCatalog.shared.search(query, locale: nil)
                .first { $0.countryCode == "TW" }, "\(query) 应能命中一座台湾城市")
            XCTAssertEqual(city.identifier, "Asia/Taipei", query)
            for id in Self.interfaceLanguages {
                let locale = Locale(identifier: id)
                XCTAssertEqual(city.subtitle(locale: locale), "", "\(query) \(id)")
                XCTAssertEqual(city.subtitle(locale: locale, displayName: query), "", "\(query) \(id)")
                XCTAssertEqual(RegionDisplayName.localized("TW", locale: locale), "", id)
            }
        }
    }

    func testMainlandHongKongMacaoKeepSystemNamesInEveryLanguage() throws {
        for (query, code) in [("Beijing", "CN"), ("Kowloon", "HK"), ("Macau", "MO")] {
            let city = try XCTUnwrap(ZoneCatalog.shared.search(query, locale: nil)
                .first { $0.countryCode == code })
            for id in Self.interfaceLanguages {
                let locale = Locale(identifier: id)
                XCTAssertEqual(RegionDisplayName.localized(code, locale: locale), regionName(code, id), "\(code) \(id)")
                XCTAssertTrue(city.subtitle(locale: locale).hasSuffix(regionName(code, id)), "\(query) \(id)")
            }
        }
    }

    /// GeoNames 有一条无语言标注的「高雄巿」——末字是 U+5DFF「巿」而不是 U+5E02「市」。
    /// zh-Hant 槽没有任何带标注候选,这个错字就直接成了繁体显示名。
    func testKaohsiungTraditionalNameIsNotTheWrongGlyph() throws {
        let kaohsiung = try XCTUnwrap(ZoneCatalog.shared.search("Kaohsiung", locale: nil)
            .first { $0.countryCode == "TW" })
        let index = try XCTUnwrap(kaohsiung.cityIndex)
        let names = CityIndex.shared.localizedNames(cityIndex: index)
        for id in ["zh-Hans", "zh-Hant"] {
            let name = try XCTUnwrap(CityNameLanguage.name(from: names, locale: Locale(identifier: id)))
            XCTAssertEqual(name, "高雄")
            XCTAssertFalse(name.contains("\u{5DFF}"), "U+5DFF 是「芾」的本字,不是「市」")
        }
    }

    /// 港澳与其他地区同一条规则：区名照常显示（香港 325 座城市分在 18 个区，区名有消歧价值），地区名取系统写法。
    func testHongKongMacaoRegionLabel() throws {
        let hans = Locale(identifier: "zh-Hans"), hant = Locale(identifier: "zh-Hant")
        // 九龙：没有一级行政区，只剩地区名
        let kowloon = try XCTUnwrap(ZoneCatalog.shared.search("Kowloon", locale: nil)
            .first { $0.countryCode == "HK" })
        XCTAssertEqual(kowloon.subtitle(locale: hans), regionName("HK", "zh-Hans"))
        XCTAssertEqual(kowloon.subtitle(locale: hant), regionName("HK", "zh-Hant"))
        // 区名与城市名不同的照常显示两段
        // 用坚尼地城而不是 Victoria:后者在香港有多条同名记录,首条不一定落在中西区
        let hk = try XCTUnwrap(ZoneCatalog.shared.search("Kennedy Town", locale: nil)
            .first { $0.countryCode == "HK" })
        XCTAssertEqual(hk.subtitle(locale: hans), "中西区, " + regionName("HK", "zh-Hans"))
        XCTAssertEqual(hk.subtitle(locale: hant), "中西區, " + regionName("HK", "zh-Hant"))
        XCTAssertEqual(hk.subtitle(locale: Locale(identifier: "en")), "Central and Western, " + regionName("HK", "en"))

        let mo = try XCTUnwrap(ZoneCatalog.shared.search("Macau", locale: nil)
            .first { $0.countryCode == "MO" })
        XCTAssertEqual(mo.subtitle(locale: hans), regionName("MO", "zh-Hans"))
        XCTAssertEqual(mo.subtitle(locale: hant), regionName("MO", "zh-Hant"))
        XCTAssertEqual(mo.subtitle(locale: Locale(identifier: "ko")), regionName("MO", "ko"))
        for sub in [kowloon.subtitle(locale: hans), hk.subtitle(locale: hans), mo.subtitle(locale: hans)] {
            XCTAssertFalse(sub.contains("特别行政区"), "不再有自定义的特别行政区全称,实得 \(sub)")
        }
    }

    /// 中国大陆与巴勒斯坦也只取系统写法，中文界面不再另起一套名字。
    func testMainlandAndPalestineLabels() throws {
        let hans = Locale(identifier: "zh-Hans"), hant = Locale(identifier: "zh-Hant")
        let beijing = try XCTUnwrap(ZoneCatalog.shared.search("Beijing", locale: nil)
            .first { $0.countryCode == "CN" })
        XCTAssertEqual(beijing.subtitle(locale: hans), regionName("CN", "zh-Hans"))
        XCTAssertEqual(beijing.subtitle(locale: hant), regionName("CN", "zh-Hant"))
        let chengxian = try XCTUnwrap(ZoneCatalog.shared.search("成县", locale: nil).first)
        XCTAssertEqual(chengxian.subtitle(locale: hans), "甘肃, " + regionName("CN", "zh-Hans"))
        XCTAssertEqual(chengxian.subtitle(locale: Locale(identifier: "en")), "Gansu, " + regionName("CN", "en"))

        let gaza = try XCTUnwrap(ZoneCatalog.shared.search("Gaza", locale: nil)
            .first { $0.countryCode == "PS" })
        for id in ["zh-Hans", "zh-Hant", "en", "fr"] {
            let sub = gaza.subtitle(locale: Locale(identifier: id))
            XCTAssertTrue(sub.hasSuffix(regionName("PS", id)), "\(id) 实得 \(sub)")
        }
    }

    /// 科索沃与阿鲁纳恰尔邦没有按地区点名的覆盖：副标题是索引里的一级行政区名加上它国家码的系统写法（CLDR），
    /// 与其他地方同一条规则。时区照旧按当地实际用钟。
    func testNoTerritoryOverrides() throws {
        let hans = Locale(identifier: "zh-Hans"), hant = Locale(identifier: "zh-Hant")
        let en = Locale(identifier: "en")

        let pristina = try XCTUnwrap(ZoneCatalog.shared.search("Pristina", locale: nil)
            .first { $0.countryCode == "XK" })
        // 普里什蒂纳的行政区名与城市名同名,按既有规则不重复显示
        XCTAssertEqual(pristina.subtitle(locale: hans), regionName("XK", "zh-Hans"))
        XCTAssertEqual(pristina.subtitle(locale: hant), regionName("XK", "zh-Hant"))
        XCTAssertEqual(pristina.subtitle(locale: en), regionName("XK", "en"))
        let suvaReka = try XCTUnwrap(ZoneCatalog.shared.search("Suva Reka", locale: nil)
            .first { $0.countryCode == "XK" })
        XCTAssertEqual(suvaReka.subtitle(locale: en), "Prizren, " + regionName("XK", "en"))
        XCTAssertEqual(suvaReka.subtitle(locale: hans), "普里兹伦区, " + regionName("XK", "zh-Hans"))

        let tawang = try XCTUnwrap(ZoneCatalog.shared.search("Tawang", locale: nil)
            .first { $0.adminRegion == "Arunachal Pradesh" })
        XCTAssertEqual(tawang.subtitle(locale: hans), "阿鲁纳恰尔邦, " + regionName("IN", "zh-Hans"))
        XCTAssertEqual(tawang.subtitle(locale: en), "Arunachal Pradesh, " + regionName("IN", "en"))
        XCTAssertEqual(tawang.identifier, "Asia/Kolkata")
        let mumbai = try XCTUnwrap(ZoneCatalog.shared.search("Mumbai", locale: nil).first)
        XCTAssertEqual(mumbai.subtitle(locale: hans), "马哈拉施特拉邦, " + regionName("IN", "zh-Hans"))

        let ramallah = try XCTUnwrap(ZoneCatalog.shared.search("Ramallah", locale: nil)
            .first { $0.countryCode == "PS" })
        XCTAssertTrue(ramallah.subtitle(locale: hans).hasSuffix(regionName("PS", "zh-Hans")),
                      "实得 \(ramallah.subtitle(locale: hans))")
    }

    /// 归属有争议的居民点（GeoNames 归在 IL「Judea and Samaria Area」下的约旦河西岸定居点，与戈兰高地点名的
    /// 十二个居民点）：十六种界面语言都不写地区也不写国家，只留地名；时区照旧。旁边以色列本土的地方照常显示。
    func testDisputedLocalitiesShowNoRegionOrCountry() throws {
        // 戈兰高地那十二个居民点按名字点名，再用经纬度框兜底（与 Rust 同一个框），所以挑记录时也按框挑。
        func inGolanBox(_ zone: ZoneOption) -> Bool {
            guard let c = zone.coordinate else { return false }
            return (32.70...33.35).contains(c.latitude) && (35.60...35.90).contains(c.longitude)
        }
        var checked: [String] = []
        let queries: [(String, (ZoneOption) -> Bool)] = [
            ("Ariel", { $0.countryCode == "IL" && $0.adminRegion == "Judea and Samaria Area" }),
            ("Katzrin", { $0.countryCode == "IL" && inGolanBox($0) }),
            ("Marom Golan", { $0.countryCode == "IL" && inGolanBox($0) }),
            ("Ghajar", { $0.countryCode == "IL" && inGolanBox($0) }),
            ("Ramat Magshimim", { $0.countryCode == "IL" && inGolanBox($0) }),
        ]
        for (query, matches) in queries {
            let place = try XCTUnwrap(ZoneCatalog.shared.search(query, locale: nil).first(where: matches), "\(query) 应能命中")
            for id in Self.interfaceLanguages {
                XCTAssertEqual(place.subtitle(locale: Locale(identifier: id)), "", "\(query) \(id)")
            }
            XCTAssertEqual(place.identifier, "Asia/Jerusalem", query)
            checked.append(place.cityName)
        }
        XCTAssertEqual(checked.count, 5)
        let telAviv = try XCTUnwrap(ZoneCatalog.shared.search("Tel Aviv", locale: nil)
            .first { $0.countryCode == "IL" })
        XCTAssertTrue(telAviv.subtitle(locale: Locale(identifier: "zh-Hans")).hasSuffix(regionName("IL", "zh-Hans")),
                      "实得 \(telAviv.subtitle(locale: Locale(identifier: "zh-Hans")))")
        let snir = try XCTUnwrap(ZoneCatalog.shared.search("Snir", locale: nil)
            .first { $0.countryCode == "IL" && $0.cityName == "Snir" })
        XCTAssertEqual(snir.subtitle(locale: Locale(identifier: "zh-Hans")), "北部区, " + regionName("IL", "zh-Hans"))
    }

    func testAllFourteenDisputedIsraeliLocalitiesKeepEmptySubtitles() throws {
        let golanNames: Set<String> = ["Ghajar", "Al Buţayḩah", "H̱ad Nes", "Ramot", "Katzrin", "Fīq",
                                       "‘Ein Qunīya", "Mārom Golan", "Nov", "H̱ispin", "Ramat Magshimim", "Al Khushnīyah"]
        var westBankCount = 0
        var golanFound: Set<String> = []
        // 逐条走整个索引：「Nov」这类短名在搜索里会被同前缀的大城挤掉，按国家、行政区或名字 + 坐标框筛出这 14 处。
        for index in 0..<CityIndex.shared.cityCount {
            guard let record = CityIndex.shared.city(at: index), record.countryCode == "IL" else { continue }
            let westBank = record.region == "Judea and Samaria Area"
            let golan = golanNames.contains(record.name) && (32.70...33.35).contains(record.latitude)
                && (35.60...35.90).contains(record.longitude)
            guard westBank || golan else { continue }
            if westBank { westBankCount += 1 } else { golanFound.insert(record.name) }
            let city = ZoneOption(cityIndex: index, record: record)
            XCTAssertEqual(city.identifier, "Asia/Jerusalem", record.name)
            for id in Self.interfaceLanguages {
                XCTAssertEqual(city.subtitle(locale: Locale(identifier: id)), "", "\(record.name) \(id)")
            }
        }
        XCTAssertEqual(westBankCount, 2)
        XCTAssertEqual(golanFound, golanNames)
    }

    /// 港澳有 8 个区/堂区上游没有中文名,在 `ADMIN1_ZH` 里补录。
    func testHongKongDistrictsHaveChineseNames() throws {
        let hans = Locale(identifier: "zh-Hans")
        for query in ["Wong Tai Sin", "Sham Shui Po", "Tsuen Wan", "Yuen Long"] {
            let city = try XCTUnwrap(ZoneCatalog.shared.search(query, locale: nil)
                .first { $0.countryCode == "HK" })
            let sub = city.subtitle(locale: hans)
            XCTAssertTrue(sub.hasSuffix(regionName("HK", "zh-Hans")), "实得 \(sub)")
            XCTAssertFalse(sub.contains(where: { $0.isASCII && $0.isLetter }),
                           "中文界面下不该再有拉丁区名,实得 \(sub)")
        }
    }

    /// 俄乌相关的归属:GeoNames 上游**已经**按国际承认边界标注,这里只做回归护栏
    /// ——克里米亚、塞瓦斯托波尔与被侵占的四州都在乌克兰,德左在摩尔多瓦,
    /// 阿布哈兹在格鲁吉亚。任何一条被上游改动都要在这里炸出来。
    func testOccupiedTerritoriesStayWithTheirCountry() throws {
        let hans = Locale(identifier: "zh-Hans"), ru = Locale(identifier: "ru")
        func city(_ query: String, _ code: String) throws -> ZoneOption {
            try XCTUnwrap(ZoneCatalog.shared.search(query, locale: nil).first { $0.countryCode == code })
        }
        for (query, code, tail) in [("Simferopol", "UA", "乌克兰"),   // 克里米亚
                                    ("Sevastopol", "UA", "乌克兰"),
                                    ("Donetsk", "UA", "乌克兰"),
                                    ("Luhansk", "UA", "乌克兰"),
                                    ("Melitopol", "UA", "乌克兰"),   // 扎波罗热州
                                    ("Tiraspol", "MD", "摩尔多瓦"),  // 德左
                                    ("Sokhumi", "GE", "格鲁吉亚")] { // 阿布哈兹
            let sub = try city(query, code).subtitle(locale: hans)
            XCTAssertTrue(sub.hasSuffix(tail), "\(query) 应属 \(tail),实得 \(sub)")
            XCTAssertFalse(sub.contains("俄罗斯"), "\(query) 不得标为俄罗斯,实得 \(sub)")
        }
        // 俄文界面下同样如此
        XCTAssertTrue(try city("Simferopol", "UA").subtitle(locale: ru).hasSuffix("Украина"))
        // 塞瓦斯托波尔的中文区名是补录的(上游一条中文候选都没有)。
        // 用因克尔曼而不是塞瓦斯托波尔本身:后者城市名与区名互为前缀,区名不会显示。
        let inkerman = try city("Inkerman", "UA")
        XCTAssertEqual(inkerman.subtitle(locale: hans), "塞瓦斯托波尔市, 乌克兰")
    }

    /// 地区名的系统写法与英文写法都能当检索词用（前缀匹配）；台湾简繁查询保留，显示时不带地区名。
    func testRegionsAreSearchableBySystemNames() throws {
        // 「塞尔维亚」不在表里:它先命中 RS,而 RS 有 492 座城市,8 条上限下 XK 排不进来
        // ——那是乘性打分的既定行为(敲「科索沃」照常命中)。
        for (query, localeID, code) in [("台湾", "zh-Hans", "TW"), ("台灣", "zh-Hant", "TW"),
                                        ("台灣", "zh-Hans", "TW"), ("台湾", "zh-Hant", "TW"),
                                        ("taiwan", "en", "TW"),
                                        ("香港", "zh-Hans", "HK"), ("香港", "zh-Hant", "HK"),
                                        ("澳门", "zh-Hans", "MO"), ("macao", "en", "MO"),
                                        ("中国大陆", "zh-Hans", "CN"), ("中国", "zh-Hans", "CN"),
                                        ("中國大陸", "zh-Hant", "CN"),
                                        ("科索沃", "zh-Hans", "XK"), ("科索沃", "zh-Hant", "XK")] {
            let hits = ZoneCatalog.shared.search(query, locale: Locale(identifier: localeID))
            XCTAssertTrue(hits.contains { $0.countryCode == code },
                          "敲「\(query)」应能命中 \(code) 的城市")
            if code == "TW" {
                for city in hits where city.countryCode == "TW" {
                    XCTAssertEqual(city.subtitle(locale: Locale(identifier: localeID)), "", query)
                    XCTAssertEqual(city.identifier, "Asia/Taipei", query)
                }
            }
        }
    }

    /// 行政区名与地区名逐字相同就别重复一遍(「Monaco, Monaco」)。
    /// 判据必须是严格相等:西语的「Australia Occidental」以「Australia」开头,
    /// 可西澳州本来就该显示——用前缀判会把它一并吃掉。
    func testAdminRegionEqualToCountryIsOmitted() throws {
        let en = Locale(identifier: "en")
        // 按国家码定位,不能取首条:乘性打分下「Monaco」的头名是慕尼黑(它的意大利语名),
        // 「San Marino」的头名是加州那座。
        func city(_ query: String, _ code: String) throws -> ZoneOption {
            try XCTUnwrap(ZoneCatalog.shared.search(query, locale: nil).first { $0.countryCode == code })
        }
        for (query, code, localeID) in [("San Marino", "SM", "en"), ("Luxembourg", "LU", "en"),
                                        ("Monaco", "MC", "fr")] {
            let sub = try city(query, code).subtitle(locale: Locale(identifier: localeID))
            XCTAssertFalse(sub.contains(", "),
                           "\(query) 的副标题不该把同名行政区再写一遍,实得 \(sub)")
        }
        // 反面一:只是"包含"不算相等。摩纳哥的英文行政区名是 "Municipality of Monaco",
        // 与国家名 "Monaco" 不逐字相同,照常显示——判据故意不吃包含关系。
        XCTAssertEqual(try city("Monaco", "MC").subtitle(locale: en), "Municipality of Monaco, Monaco")
        // 反面二:前缀关系也不算。
        let perth = try XCTUnwrap(ZoneCatalog.shared.search("Perth", locale: nil)
            .first { $0.countryCode == "AU" })
        XCTAssertEqual(perth.subtitle(locale: Locale(identifier: "es")),
                       "Australia Occidental, Australia",
                       "州名只是以国家名开头,不是相等,必须照常显示")
    }
}

/// 时区名和缩写按地点判断，偏移取正在显示的时刻。旧存档没有行政区字段也要遵守同一规则。
@MainActor
struct OffsetOnlyZoneNameTests {
    nonisolated private static let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "de", "es", "fr", "ru", "pt-BR",
                                    "it", "nl", "pl", "tr", "vi", "id"]
    nonisolated private static let places = ["Taipei", "Kaohsiung", "Taichung", "Tainan", "Hsinchu", "Ariel", "Hashmonaim",
        "Ghajar", "Al Buţayḩah", "H̱ad Nes", "Ramot", "Katzrin", "Fīq", "‘Ein Qunīya", "Mārom Golan", "Nov",
        "H̱ispin", "Ramat Magshimim", "Al Khushnīyah"]
    private let winter = ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z")!
    private let summer = ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z")!

    private func interfaceLanguage(_ identifier: String) throws -> InterfaceLanguage {
        try #require(InterfaceLanguage.allCases.first { $0.localeIdentifier == identifier })
    }

    private func place(_ name: String) throws -> ZoneOption {
        try #require(ZoneCatalog.shared.search(name, locale: nil, limit: 64).first {
            if $0.countryCode == "TW" { return true }
            guard $0.countryCode == "IL" else { return false }
            if $0.adminRegion == "Judea and Samaria Area" { return true }
            guard let c = $0.coordinate else { return false }
            return (32.70...33.35).contains(c.latitude) && (35.60...35.90).contains(c.longitude)
        }, "\(name) must resolve to its catalog record")
    }

    @Test(arguments: places, languages)
    func placeNamesAndAbbreviationsUseTheDisplayedOffset(name: String, language: String) throws {
        let option = try place(name)
        var saved = TimeZoneEntry(zone: option)
        saved.customName = "Renamed"
        // 按现有偏好存档的路径往返，不新增地点持久化字段。
        let entry = try JSONDecoder().decode(TimeZoneEntry.self, from: JSONEncoder().encode(saved))
        var settings = AppSettings()
        settings.interfaceLanguage = try interfaceLanguage(language)
        let core = TimeCore(zones: [entry], settings: settings)
        for (date, expected) in [(winter, option.countryCode == "TW" ? "UTC+8" : "UTC+2"),
                                 (summer, option.countryCode == "TW" ? "UTC+8" : "UTC+3")] {
            #expect(entry.offsetOnlyZoneName)
            #expect(ZoneNameDisplay.offsetOnly(identifier: option.identifier, code: option.countryCode,
                admin: option.adminRegion, city: option.cityName, coordinate: option.coordinate))
            #expect(entry.abbreviation(at: date) == expected)
            #expect(entry.label(mode: .abbreviation, at: date, localizedCity: "Renamed", withOffset: true) == expected)
            #expect(core.zoneCaption(for: entry.timeZone, entry: entry, at: date) == "Renamed · \(expected)")
            core.now = winter
            core.displayOffset = date.timeIntervalSince(winter)
            #expect(core.zoneCaption(for: entry.timeZone, entry: entry) == "Renamed · \(expected)")
        }
    }

    @Test(arguments: languages)
    func zoneOnlyTaipeiAndParsedTaiwanUseOffsets(language: String) throws {
        let locale = Locale(identifier: language)
        let taipei = try #require(TimeZone(identifier: "Asia/Taipei"))
        let jerusalem = try #require(TimeZone(identifier: "Asia/Jerusalem"))
        #expect(TimeZonePlaceCatalog.zoneName(taipei.identifier, locale: locale, at: winter) == "UTC+8")
        #expect(TimeZonePlaceCatalog.zoneName(jerusalem.identifier, locale: locale, at: summer)
            == jerusalem.localizedName(for: .generic, locale: locale))
        let style = UnderstandingText.Style(locale: locale, hourStyle: .force24, now: winter,
                                           name: { $0.identifier })
        let option = TimeUnderstanding.ZoneOption(id: "zone:Asia/Taipei", zone: taipei, kind: .region, anchor: taipei.identifier)
        #expect(UnderstandingText.zoneName(option, at: summer, style: style, pasted: false) == "UTC+8")
        #expect(UnderstandingText.zoneLabel(option, among: [option], at: summer, style: style, pasted: false) == "UTC+8")
        let output = TimeUnderstanding.read("9am in Taiwan", region: "US")
        let resolved = TimeUnderstanding.resolveAll(output,
            context: .init(reference: winter, now: winter, fallback: .gmt, home: .gmt))
        let first = try #require(resolved.first)
        #expect(first.zoneOption.city == nil)
        #expect(first.zone.identifier == "Asia/Taipei")
        #expect(UnderstandingText.zoneName(first.zoneOption, at: try #require(first.start), style: style, pasted: false) == "UTC+8")
    }

    @Test(arguments: languages)
    func nearbyPlacesKeepAppleZoneNamesWithoutBorrowingAnotherPlacesPolicy(language: String) throws {
        let golan = TimeZoneEntry(zone: try place("Katzrin"))
        let telAviv = TimeZoneEntry(zone: try #require(ZoneCatalog.shared.search("Tel Aviv", locale: nil).first { $0.countryCode == "IL" }))
        let jerusalem = try #require(TimeZone(identifier: "Asia/Jerusalem"))
        var settings = AppSettings()
        settings.interfaceLanguage = try interfaceLanguage(language)
        let core = TimeCore(zones: [golan, telAviv], settings: settings)
        let systemName = try #require(jerusalem.localizedName(for: .generic, locale: core.uiLocale))
        #expect(!telAviv.offsetOnlyZoneName)
        #expect(core.zoneCaption(for: jerusalem, entry: telAviv, at: winter).hasSuffix(" · \(systemName)"))
        #expect(core.zoneCaption(for: jerusalem, at: winter).hasSuffix(" · \(systemName)"))
        #expect(core.zoneCaption(for: jerusalem, at: winter).hasPrefix(
            LocalizedZoneNames.shared.cityName(jerusalem.identifier, locale: core.cityLocale) + " · "))
        #expect(telAviv.abbreviation(at: summer) == ZoneNameDisplay.abbreviation(jerusalem, at: summer))
        for entries in [[golan, telAviv], [telAviv, golan]] {
            core.zones = entries
            #expect(core.zoneAbbreviation(forTimeZoneID: jerusalem.identifier, placeID: golan.id, at: summer) == "UTC+3")
            #expect(core.zoneAbbreviation(forTimeZoneID: jerusalem.identifier, placeID: telAviv.id, at: summer)
                == ZoneNameDisplay.abbreviation(jerusalem, at: summer))
            #expect(core.zoneAbbreviation(forTimeZoneID: jerusalem.identifier, placeID: nil, at: summer)
                == ZoneNameDisplay.abbreviation(jerusalem, at: summer))
        }
        #expect(!ZoneNameDisplay.offsetOnly(identifier: jerusalem.identifier, code: "IL", city: "Ramot",
            coordinate: Coordinate(latitude: 31.8, longitude: 35.2)))
        #expect(!ZoneNameDisplay.offsetOnly(identifier: jerusalem.identifier, code: "IL", city: "Ariel"))
    }

    @Test(arguments: ["Ariel", "Hashmonaim", "Katzrin", "Taipei"])
    func transferredDisplayNamesKeepOriginalPlaceClassification(name: String) throws {
        let saved = TimeZoneEntry(zone: try place(name))
        let link = try PlacesTransfer.link(for: [saved], displayName: { _ in "自定义地点" }, now: winter).get()
        let decoded = try PlacesTransfer.decode(link.url).get()
        let transferred = try #require(decoded.places.first)
        #expect(transferred.name == "自定义地点")
        #expect(transferred.rawCityName == saved.cityName)
        let entry = transferred.entry
        #expect(entry.cityName == saved.cityName)
        #expect(entry.displayName(localizedCity: "Other") == "自定义地点")
        #expect(entry.offsetOnlyZoneName)
        #expect(entry.abbreviation(at: summer) == (saved.countryCode == "TW" ? "UTC+8" : "UTC+3"))
        let legacy = TransferPlace(name: "Legacy", timeZoneID: "Asia/Jerusalem").entry
        #expect(legacy.cityName == "Legacy")
        #expect(legacy.customName == nil)
        #expect(!legacy.offsetOnlyZoneName)
    }

    @Test(arguments: ["Ariel", "Hashmonaim", "Katzrin", "Taipei"])
    func peopleKeepThePlaceDisplayRuleAfterLinkedPlaceRemoval(name: String) throws {
        let option = try place(name)
        let saved = TimeZoneEntry(zone: option)
        var person = PersonProfile(name: "Person", timeZoneID: "UTC")
        person.bind(to: saved)
        let restored = try JSONDecoder().decode(PersonProfile.self, from: JSONEncoder().encode(person))
        #expect(restored.offsetOnlyZoneName == true)
        #expect(restored.plannerParticipant(places: []).offsetOnlyZoneName)
        #expect(restored.plannerParticipant(places: [saved]).offsetOnlyZoneName)
        person.choose(option)
        #expect(person.placeID == nil)
        #expect(person.plannerParticipant(places: []).offsetOnlyZoneName)
        let ordinary = try #require(ZoneCatalog.shared.search("Tel Aviv", locale: nil).first { $0.countryCode == "IL" })
        person.choose(ordinary)
        #expect(person.offsetOnlyZoneName == nil)
        #expect(!person.plannerParticipant(places: []).offsetOnlyZoneName)
        // 旧人物在绑定地点已删后没有地点事实，保留只按时区判断的默认规则。
        let legacy = PersonProfile(name: "Legacy", timeZoneID: "Asia/Jerusalem")
        let legacyJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        #expect(legacyJSON["offsetOnlyZoneName"] == nil)
    }

    @Test(arguments: languages)
    func repeatedWallTimeAndMeetingNotesPreservePlaceRules(language: String) throws {
        let golan = try place("Katzrin")
        let cityIndex = try #require(golan.cityIndex)
        let zone = try #require(TimeZone(identifier: golan.identifier))
        let option = TimeUnderstanding.ZoneOption(id: "city:\(cityIndex)", zone: zone, kind: .region, anchor: zone.identifier,
                                                 city: .init(index: cityIndex, name: golan.cityName))
        // 两个绝对时刻都在当地 01:30；它们跨过 2026 年的秋季回拨。
        let first = try #require(ISO8601DateFormatter().date(from: "2026-10-24T22:30:00Z"))
        let second = try #require(ISO8601DateFormatter().date(from: "2026-10-24T23:30:00Z"))
        let calendar = Calendar.gregorianUTC(zone)
        #expect(calendar.component(.hour, from: first) == 1)
        #expect(calendar.component(.hour, from: second) == 1)
        #expect(UnderstandingText.abbreviation(option, at: first) == "UTC+3")
        #expect(UnderstandingText.abbreviation(option, at: second) == "UTC+2")
        let event = MeetingEvent.make(start: first, end: second, names: ["Renamed", "Tel Aviv"], timeZones: [zone, zone],
                                     offsetOnlyZoneNames: [true, false], title: "Meeting", footer: "Dayside",
                                     locale: Locale(identifier: language), hourStyle: .force24)
        let restricted = try #require(event.lines.first)
        let ordinary = try #require(event.lines.last)
        #expect(restricted.text.contains("UTC+3"))
        #expect(restricted.text.contains("UTC+2"))
        #expect(ordinary.text.contains(ZoneNameDisplay.abbreviation(zone, at: first)))
        #expect(ordinary.text.contains(ZoneNameDisplay.abbreviation(zone, at: second)))
        let unfolded = event.icsText(uid: "test", stamp: winter).replacingOccurrences(of: "\r\n ", with: "")
        #expect(unfolded.contains("UTC+3"))
        #expect(unfolded.contains("UTC+2"))
    }
}
