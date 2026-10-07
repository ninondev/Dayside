// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import Testing
@testable import TahoeTime

@MainActor
struct SharingTests {
    @Test(arguments: [(InterfaceLanguage.de, "Tokio", false), (.zhHans, "东京", true)])
    func postcardOnlyAddsLatinSpellingToNonLatinPlaceNames(language: InterfaceLanguage, name: String, addsCity: Bool) throws {
        let entry = TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: "Tokyo",
                                  localizedNames: ["de": "Tokio", "zh-Hans": "东京"])
        var settings = AppSettings()
        settings.interfaceLanguage = language
        let core = TimeCore(zones: [entry], settings: settings)
        let facts = SharingLensView.postcardPlaceFacts(name: core.cityName(for: entry), city: entry.cityName,
                                                       coordinate: entry.coordinate)
        #expect(facts.name == name)
        var draft = SharingDraft()
        draft.timeZoneID = entry.timezoneID
        draft.displayName = "Mei"
        draft.placeName = facts.name
        draft.placeCity = facts.city
        let document = try #require(SharingGenerator.build(draft: draft, hostURL: "",
                                                           now: Date(timeIntervalSince1970: 1_789_041_600)).document)
        let postcard = Postcard(document: document, locale: core.uiLocale, hourStyle: .force24, fallbackPlace: name)
        #expect(document.payload.city == (addsCity ? "Tokyo" : nil))
        #expect(postcard.subtitle == (addsCity ? "东京 · Tokyo" : "Tokio"))
    }

    @Test(arguments: [("München", "Munich", false), ("Sa\u{0303}o Paulo", "Sao Paulo", false),
                      ("Nukuʻalofa", "Nuku'alofa", false), ("Москва", "Moscow", true),
                      ("Αθήνα", "Athens", true), ("東京 Tokyo", "Tokyo", true)])
    func postcardRecognizesThePlaceNamesScript(name: String, city: String, addsCity: Bool) {
        let facts = SharingLensView.postcardPlaceFacts(name: name, city: city, coordinate: nil)
        #expect(facts.name == name)
        #expect(facts.city == (addsCity ? city : ""))
    }

    /// 复制的文字是明信片的文字版：跟界面语言走（不跟 Mac 的系统语言），第一行「名字 · 地名（UTC+9）」，标识符只留在名片数据里。
    @Test func previewTextFollowsTheInterfaceLanguage() throws {
        var draft = SharingDraft()
        draft.timeZoneID = "Asia/Tokyo"
        draft.displayName = "Mei"
        let now = Date(timeIntervalSince1970: 1_789_041_600)
        let document = try #require(SharingGenerator.build(draft: draft, hostURL: "", now: now).document)
        let english = SharingGenerator.text(document, locale: Locale(identifier: "en"), placeName: "Tokyo", now: now)
        #expect(english == "Mei · Tokyo (UTC+9)", Comment(rawValue: english))
        let chinese = SharingGenerator.text(document, locale: Locale(identifier: "zh-Hans"), placeName: "东京", now: now)
        #expect(chinese == "Mei · 东京（UTC+9）", Comment(rawValue: chinese))
        #expect(!chinese.contains("Asia/Tokyo") && !english.contains("Asia/Tokyo"))
        let german = SharingGenerator.text(document, locale: Locale(identifier: "de"), placeName: "Tokio", now: now)
        #expect(german == "Mei · Tokio (UTC+9)", Comment(rawValue: german))
        #expect(document.payload.timeZoneID == "Asia/Tokyo", "名片本身仍带标识符")
    }

    /// 复制的文字与卡片底部的钟点跟设置里的小时制（此前走 DateFormatter 的 `HH:mm`、`j` 模板与 `.short`，只跟系统）。
    @Test func sharedTextFollowsTheHourStyleSetting() throws {
        var draft = SharingDraft()
        draft.timeZoneID = "Asia/Tokyo"
        draft.includesAvailability = true
        let now = Date(timeIntervalSince1970: 1_789_041_600)
        let document = try #require(SharingGenerator.build(draft: draft, hostURL: "", now: now).document)
        let schedule = try #require(document.payload.schedule)
        let english = Locale(identifier: "en_US")
        // 钟点的写法跟系统语言走（中文系统是「下午5:00」而不是「5:00 PM」），所以不看上下午的字样，只看 17 点写成了什么。
        let twelve = SharingGenerator.text(document, locale: english, placeName: "Tokyo", hourStyle: .force12, now: now)
        let twentyFour = SharingGenerator.text(document, locale: english, placeName: "Tokyo", hourStyle: .force24, now: now)
        #expect(!twelve.contains("17:00"), Comment(rawValue: twelve))
        #expect(twentyFour.contains("17:00"), Comment(rawValue: twentyFour))
        #expect(!SharingGenerator.freeLine(schedule, placeName: "Tokyo", locale: english, hourStyle: .force12).contains("17:00"))
        let hours24 = SharingGenerator.freeLine(schedule, placeName: "Tokyo", locale: english, hourStyle: .force24)
        #expect(hours24.contains("17:00"), Comment(rawValue: hours24))
    }

    /// 名片的 PNG 是那张明信片：与预览同一个视图，420 点宽加 16 点白边、2 倍像素；标题是名字、下面是地名与拉丁写法，
    /// 有作息时一行「可约：…」；PNG 字节头对得上。排会那种（标题 + 各地时间行）仍走自己的渲染器。
    @Test func timeCardRendersToPNG() throws {
        var draft = SharingDraft()
        draft.timeZoneID = "Asia/Tokyo"
        draft.displayName = "Mei"
        draft.includesAvailability = true
        draft.placeName = "东京"
        draft.placeCity = "Tokyo"
        draft.latitude = 35.6895
        draft.longitude = 139.6917
        let now = Date(timeIntervalSince1970: 1_789_041_600)
        let (defaults, cleanup) = TestDefaults.make(prefix: "meantime.sharing.image"); defer { cleanup() }
        let store = SharingStore(defaults: defaults)
        store.draft = draft
        store.prepare(now: now, locale: Locale(identifier: "zh-Hans"))
        let card = try #require(store.postcard(locale: Locale(identifier: "zh-Hans")))
        #expect(card.title == "Mei")
        #expect(card.subtitle == "东京 · Tokyo")
        #expect(card.coordinate == Coordinate(latitude: 35.7, longitude: 139.7), "坐标进名片前四舍五入到 0.1°")
        #expect(card.free?.hasPrefix("可约：周一至周五") == true, Comment(rawValue: card.free ?? ""))
        var settings = AppSettings()
        settings.interfaceLanguage = .zhHans
        let core = TimeCore(zones: [], settings: settings)
        let image = try #require(PostcardImage.image(for: card, core: core))
        #expect(image.size.width == PostcardImage.width + 32)
        let png = try #require(TimeCardImage.pngData(image))
        #expect(png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), "PNG 文件头")
        let bitmap = try #require(NSBitmapImageRep(data: png))
        #expect(bitmap.pixelsWide == Int(PostcardImage.width + 32) * 2, "2 倍像素")
        // 目视证据：`TEST_RUNNER_MEANTIME_CARD_DUMP=1` 时把两张卡写进沙盒 tmp 并打印路径（宿主是沙盒，写不了别处）。
        let dump = ProcessInfo.processInfo.environment["MEANTIME_CARD_DUMP"] == "1" ? FileManager.default.temporaryDirectory : nil
        if let dump {
            let url = dump.appendingPathComponent("card-sharing.png")
            try png.write(to: url)
            print("MEANTIME_CARD_DUMP_PATH=\(url.path)")
        }
        // 排会卡：各地时间行
        let meeting = TimeCardImage.Card(title: "会议", subtitle: "9月17日 10:00–11:00",
                                         lines: [.init(name: "洛杉矶", text: "10:00–11:00"), .init(name: "伦敦", text: "18:00–19:00")], footer: "用 Dayside 规划")
        let meetingImage = try #require(TimeCardImage.image(for: meeting, locale: Locale(identifier: "zh-Hans")))
        if let dump, let data = TimeCardImage.pngData(meetingImage) {
            let url = dump.appendingPathComponent("card-meeting.png")
            try data.write(to: url)
            print("MEANTIME_CARD_DUMP_PATH=\(url.path)")
        }
    }

    /// 预约回执邮箱：草稿里的邮箱进名片、老草稿没有这个键也能解；写坏了整份草稿报 contact。
    @Test func contactEmailRidesInTheCardAndOldDraftsStillDecode() throws {
        var draft = SharingDraft()
        draft.timeZoneID = "Asia/Tokyo"
        draft.contactEmail = " mei@example.com "
        let now = Date(timeIntervalSince1970: 1_789_041_600)
        let document = try #require(SharingGenerator.build(draft: draft, hostURL: "", now: now).document)
        #expect(document.payload.contactEmail == "mei@example.com")
        #expect(document.html.contains("contactEmail"), "托管页要认这个键")
        draft.contactEmail = "not an email"
        #expect(SharingGenerator.build(draft: draft, hostURL: "", now: now).errors == ["contact"])
        let legacy = Data(#"{"timeZoneID":"Asia/Tokyo","displayName":"Mei","includesAvailability":false,"startMinute":540,"endMinute":1020,"workingWeekdays":[2,3]}"#.utf8)
        let decoded = try JSONDecoder().decode(SharingDraft.self, from: legacy)
        #expect(decoded.contactEmail == "" && decoded.displayName == "Mei" && decoded.workingWeekdays == [2, 3])
        let roundTrip = try JSONDecoder().decode(SharingDraft.self, from: JSONEncoder().encode(draft))
        #expect(roundTrip == draft)
    }

    /// Mac → iPhone 地点清单：链接按界面上显示的名字编，解回后合并时同时区且名字对得上的不重复；替换走另一条路。
    @Test func placeListLinkRoundTripsAndMergesWithoutDuplicates() throws {
        let tokyo = TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: "Tokyo", coordinate: Coordinate(latitude: 35.69, longitude: 139.69),
                                  usesExemplarName: false, localizedNames: ["zh-Hans": "东京"], countryCode: "JP")
        let chengdu = TimeZoneEntry(timezoneID: "Asia/Shanghai", customName: "老家", cityName: "Chengdu", countryCode: "CN")
        let link = try PlacesTransfer.link(for: [tokyo, chengdu], displayName: { $0.customName ?? $0.localizedNames?["zh-Hans"] ?? $0.cityName }).get()
        #expect(link.count == 2 && link.url.hasPrefix("dayside://import#dp1."))
        let decoded = try PlacesTransfer.decode("看这个 \(link.url) 谢谢").get()
        #expect(decoded.places.map(\.name) == ["东京", "老家"])
        #expect(decoded.places[0].latitude == 35.69 && decoded.places[1].latitude == nil)
        // 收方已有一个按英文名存的东京（本地化名里有「东京」）：不重复；老家是新的。
        let merged = PlacesTransfer.merge(decoded.places, into: [tokyo], displayName: { $0.cityName })
        #expect(merged.count == 2 && merged.last?.cityName == "老家" && merged.last?.timezoneID == "Asia/Shanghai")
        #expect(PlacesTransfer.merge(decoded.places, into: merged, displayName: { $0.cityName }).count == 2, "再合并一次不长")
        #expect(PlacesTransfer.link(for: [], displayName: { $0.cityName }).isFailure)
        #expect(PlacesTransfer.decode("mt1.AAAA").isFailure)
        // 200 个 77 字汉字名合法却编不进 65,536 字节：发方就报 tooLong。
        let fat = (0..<200).map { TimeZoneEntry(timezoneID: "UTC", cityName: String(repeating: "名", count: 77) + String($0)) }
        if case .failure(let error) = PlacesTransfer.link(for: fat, displayName: { $0.cityName }) { #expect(error.code == "tooLong") } else { Issue.record("应报 tooLong") }
    }

    /// 可约时段那一行也印地点名（「…· Tokyo time」）；片段、链接与托管页逐字节不变，只有渲染出来的文字变了。
    @Test func placeNameOnlyChangesTheRenderedTextNotTheCard() throws {
        let draft = scheduled("Asia/Tokyo", start: 540, end: 1080, weekdays: [2, 3, 4, 5, 6])
        let now = Date(timeIntervalSince1970: 1_789_041_600)
        let document = try #require(SharingGenerator.build(draft: draft, hostURL: "https://example.com/when.html", now: now).document)
        let again = try #require(SharingGenerator.build(draft: draft, hostURL: "https://example.com/when.html", now: now).document)
        #expect(document.fragment == again.fragment && document.shareURL == again.shareURL && document.html == again.html)
        let text = SharingGenerator.text(document, locale: Locale(identifier: "en"), placeName: "Tokyo", now: now)
        // 工作时段钟点走 ClockText，遵循小时制与系统写法。
        let hours = ClockText.range(ClockText.minute(540, hourStyle: .followSystem), ClockText.minute(1080, hourStyle: .followSystem))
        #expect(text.contains("Available: Mon–Fri · \(hours) · Tokyo time"), Comment(rawValue: text))
        #expect(!text.contains("Asia/Tokyo") && !text.contains("Europe/London"), Comment(rawValue: text))
        #expect(text.hasSuffix(document.shareURL!))
    }

    /// 星期与钟点的写法（收方网页同一个规矩）：连着三天以上写一段、一周按圈算、七天写每天；中文用「至」、日文用「〜」。
    @Test func freeLineNamesWeekdayRunsAndHours() {
        let english = Locale(identifier: "en_US")
        #expect(SharingGenerator.weekdaysText([2, 3, 4, 5, 6], locale: english) == "Mon–Fri")
        #expect(SharingGenerator.weekdaysText([1, 2, 3, 4, 5], locale: english) == "Sun–Thu")
        #expect(SharingGenerator.weekdaysText([2, 4, 6], locale: english) == "Mon, Wed, and Fri")
        #expect(SharingGenerator.weekdaysText([1, 2, 3, 4, 5, 6, 7], locale: english) == "Every day")
        #expect(SharingGenerator.weekdaysText([2, 3, 4, 5, 6], locale: Locale(identifier: "zh-Hans")) == "周一至周五")
        #expect(SharingGenerator.weekdaysText([2, 3, 4, 5, 6], locale: Locale(identifier: "ja")) == "月〜金")
        let overnight = SharingSchedule(startMinute: 1260, endMinute: 120, workingWeekdays: [2, 3, 4, 5, 6], isWholeDay: false, endDayOffset: 1)
        let line = SharingGenerator.freeLine(overnight, placeName: "东京", locale: Locale(identifier: "zh-Hans"), hourStyle: .force24)
        // 钟点的写法（补不补零）跟系统语言走，只看结构。
        #expect(line.hasPrefix("可约：周一至周五 · 21:00–次日 ") && line.hasSuffix(" · 东京时间"), Comment(rawValue: line))
        let whole = SharingSchedule(startMinute: 0, endMinute: 1440, workingWeekdays: [7, 1], isWholeDay: true, endDayOffset: 1)
        #expect(SharingGenerator.hoursText(whole, locale: english) == "All day")
    }

    // MARK: 第一格「分享哪个地点」

    private func places() -> [TimeZoneEntry] {
        [.init(timezoneID: "America/Los_Angeles", cityName: "Los Angeles"),
         .init(timezoneID: "Europe/London", cityName: "London"),
         .init(timezoneID: "Asia/Tokyo", cityName: "Tokyo")]
    }

    @Test func firstSavedPlaceIsTheDefaultAndTheLocalZoneWhenThereAreNone() {
        let fixture = SharingFixture()
        let saved = places()
        fixture.store.alignZoneChoice(places: saved, localTimeZoneID: "Europe/Paris")
        #expect(fixture.store.zoneChoice == .place(saved[0].id))
        #expect(fixture.store.draft.timeZoneID == "America/Los_Angeles")

        let empty = SharingFixture()
        empty.store.alignZoneChoice(places: [], localTimeZoneID: "Europe/Paris")
        #expect(empty.store.zoneChoice == .local)
        #expect(empty.store.draft.timeZoneID == "Europe/Paris")
    }

    /// 草稿里已经是某个已保存地点的标识符（截图夹具、或页面重新打开）时，对齐不能改写它，已生成的预览要留着。
    @Test func aligningKeepsAMatchingDraftAndItsPreview() {
        let fixture = SharingFixture()
        let saved = places()
        fixture.store.draft.timeZoneID = "Asia/Tokyo"
        fixture.store.prepare(now: date("2026-09-09T12:00:00Z"), locale: Locale(identifier: "en_US"))
        fixture.store.alignZoneChoice(places: saved, localTimeZoneID: "Europe/Paris")
        #expect(fixture.store.zoneChoice == .place(saved[2].id))
        #expect(fixture.store.document != nil)

        let local = SharingFixture()
        local.store.draft.timeZoneID = "Europe/Paris"
        local.store.alignZoneChoice(places: saved, localTimeZoneID: "Europe/Paris")
        #expect(local.store.zoneChoice == .local)

        // 草稿里是一个既不在地点表里、也不是本机的标识符（不再能手填）：回到第一个地点。
        let stray = SharingFixture()
        stray.store.draft.timeZoneID = "Asia/Kathmandu"
        stray.store.alignZoneChoice(places: saved, localTimeZoneID: "Europe/Paris")
        #expect(stray.store.zoneChoice == .place(saved[0].id))
        #expect(stray.store.draft.timeZoneID == "America/Los_Angeles")
    }

    /// 只能从自己的地点里挑：选一个地点写进它的标识符，「本机」跟着这台 Mac 的时区；不在表里的地点选不上。
    @Test func choosingWritesTheIdentifierAndOnlyTheLocalChoiceFollowsTheMac() {
        let fixture = SharingFixture()
        let saved = places()
        let store = fixture.store
        store.alignZoneChoice(places: saved, localTimeZoneID: "America/Los_Angeles")
        store.chooseZone(.place(saved[1].id), places: saved, localTimeZoneID: "America/Los_Angeles")
        #expect(store.zoneChoice == .place(saved[1].id))
        #expect(store.draft.timeZoneID == "Europe/London")
        store.chooseZone(.place(UUID()), places: saved, localTimeZoneID: "America/Los_Angeles")
        #expect(store.zoneChoice == .place(saved[1].id), "表里没有的地点选不上")
        // 本机时区恰好也是一个已保存地点：选项仍是「本机」，名片拿到的是同一个标识符。
        store.chooseZone(.local, places: saved, localTimeZoneID: "America/Los_Angeles")
        #expect(store.zoneChoice == .local)
        #expect(store.draft.timeZoneID == "America/Los_Angeles")
        store.syncLocalTimeZone("Europe/Paris")
        #expect(store.draft.timeZoneID == "Europe/Paris", "「本机」跟着 Mac 的时区走")
        store.chooseZone(.place(saved[2].id), places: saved, localTimeZoneID: "Europe/Paris")
        store.syncLocalTimeZone("Asia/Kolkata")
        #expect(store.draft.timeZoneID == "Asia/Tokyo", "选的是地点时不跟")
    }

    /// 名片上的地名、拉丁写法与坐标由所选地点给（视图按城市语言算好写进来）：写同样的值不作废名片，换了才重建；
    /// 拉丁写法与地名相同就不写第二遍。
    @Test func placeFactsEnterTheCardAndOnlyRealChangesRebuildIt() throws {
        let fixture = SharingFixture()
        let store = fixture.store
        store.draft.timeZoneID = "Asia/Tokyo"
        store.applyPlace(SharingPlaceFacts(name: "东京", city: "Tokyo", coordinate: Coordinate(latitude: 35.6895, longitude: 139.6917)))
        store.prepare(now: date("2026-09-09T12:00:00Z"), locale: Locale(identifier: "zh-Hans"))
        let document = try #require(store.document)
        #expect(document.payload.place == "东京" && document.payload.city == "Tokyo")
        #expect(document.payload.latitude == 35.7 && document.payload.longitude == 139.7)
        #expect(store.previewText.hasPrefix("东京（UTC+9）"), Comment(rawValue: store.previewText))
        store.applyPlace(SharingPlaceFacts(name: "东京", city: "Tokyo", coordinate: Coordinate(latitude: 35.6895, longitude: 139.6917)))
        #expect(store.document == document, "同样的地名与坐标不作废名片")
        store.applyPlace(SharingPlaceFacts(name: "Tokyo", city: "Tokyo", coordinate: nil))
        #expect(store.document == nil)
        store.prepare(now: date("2026-09-09T12:00:00Z"), locale: Locale(identifier: "en_US"))
        let english = try #require(store.document)
        #expect(english.payload.place == "Tokyo" && english.payload.city == nil && english.payload.latitude == nil)
    }

    @Test func deletingTheChosenPlaceFallsBackToTheDefault() {
        let fixture = SharingFixture()
        var saved = places()
        fixture.store.alignZoneChoice(places: saved, localTimeZoneID: "Europe/Paris")
        fixture.store.chooseZone(.place(saved[2].id), places: saved, localTimeZoneID: "Europe/Paris")
        #expect(fixture.store.draft.timeZoneID == "Asia/Tokyo")
        saved.removeLast()
        fixture.store.alignZoneChoice(places: saved, localTimeZoneID: "Europe/Paris")
        #expect(fixture.store.zoneChoice == .place(saved[0].id))
        #expect(fixture.store.draft.timeZoneID == "America/Los_Angeles")
        fixture.store.alignZoneChoice(places: [], localTimeZoneID: "Europe/Paris")
        #expect(fixture.store.zoneChoice == .local)
        #expect(fixture.store.draft.timeZoneID == "Europe/Paris")
    }

    /// 预览文字用页面传来的地名解析器排版；重排只换文字，名片本身不重建。
    @Test func previewUsesTheResolvedPlaceNameAndRelocalizesWithoutRebuilding() throws {
        let fixture = SharingFixture()
        fixture.store.draft.timeZoneID = "Asia/Tokyo"
        fixture.store.prepare(now: date("2026-09-09T12:00:00Z"), locale: Locale(identifier: "en_US")) { ["Asia/Tokyo": "Tokyo"][$0] ?? $0 }
        let document = try #require(fixture.store.document)
        #expect(fixture.store.previewText.hasPrefix("Tokyo (UTC+9)"), Comment(rawValue: fixture.store.previewText))
        fixture.store.relocalize(locale: Locale(identifier: "zh-Hans")) { _ in "东京" }
        #expect(fixture.store.previewText.hasPrefix("东京（UTC+9）"), Comment(rawValue: fixture.store.previewText))
        #expect(fixture.store.document == document)
    }

    @Test func defaultsContainNoIdentityOrPersonalScheduleAndOwnNoResources() {
        let fixture = SharingFixture()
        #expect(fixture.store.draft.timeZoneID.isEmpty)
        #expect(fixture.store.draft.displayName.isEmpty)
        #expect(!fixture.store.draft.includesAvailability)
        #expect(fixture.store.document == nil)
        #expect(fixture.store.activeResourceCount == 0)
        #expect(SharingStore.publicPageURL == nil, "公开的分享页地址定下来之前没有链接")
    }

    @Test func nativeTimezoneValidationRejectsUnknownIdentifiers() {
        var draft = SharingDraft()
        draft.timeZoneID = "Mars/Olympus_Mons"
        let result = SharingGenerator.build(draft: draft, hostURL: "", now: date("2026-09-09T12:00:00Z"))
        #expect(result.document == nil)
        #expect(result.errors == ["timeZone"])
    }

    @Test func clocksOnlyDocumentHasNoScheduleNameOrPublicLink() throws {
        var draft = SharingDraft()
        draft.timeZoneID = " Asia/Tokyo "
        let result = SharingGenerator.build(draft: draft, hostURL: "", now: date("2026-09-09T12:00:00Z"))
        let document = try #require(result.document)
        #expect(document.payload.timeZoneID == "Asia/Tokyo")
        #expect(document.payload.displayName == nil)
        #expect(document.payload.schedule == nil)
        #expect(document.payload.windows.isEmpty)
        #expect(document.shareURL == nil)
        #expect(document.html.contains("connect-src 'none'"))
        #expect(!document.html.contains("__MEANTIME_PAYLOAD__"))
    }

    @Test func unicodeIdentityRoundTripsSafelyInFragment() throws {
        var draft = SharingDraft()
        draft.timeZoneID = "Asia/Kathmandu"
        draft.displayName = "明 </title><script>alert(1)</script>"
        let result = SharingGenerator.build(draft: draft, hostURL: "https://example.com/when.html", now: date("2026-09-09T12:00:00Z"))
        let document = try #require(result.document)
        let encoded = String(document.fragment.dropFirst(4)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        let data = try #require(Data(base64Encoded: padded))
        let decoded = try JSONDecoder().decode(SharingPayload.self, from: data)
        #expect(decoded == document.payload)
        #expect(decoded.displayName == draft.displayName)
        #expect(!document.html.contains("<script>alert(1)</script>"))
        #expect(document.shareURL?.hasPrefix("https://example.com/when.html#mt1.") == true)
    }

    @Test(arguments: [("GMT+0545", 20700), ("GMT-0330", -12600), ("GMT+07:00", 25200), ("UTC+00:00", 0)])
    func fixedOffsetTimezonesKeepTheirExplicitOffset(zoneID: String, offset: Int) throws {
        var draft = SharingDraft()
        draft.timeZoneID = zoneID
        let document = try #require(SharingGenerator.build(draft: draft, hostURL: "", now: date("2026-09-09T23:00:00Z")).document)
        #expect(document.payload.timeZoneID == zoneID)
        #expect(document.payload.fixedOffsetSeconds == offset)
        #expect(document.payload.schedule == nil)
    }

    @Test func hostRejectsCredentialsQueryFragmentAndInsecureScheme() {
        var draft = SharingDraft()
        draft.timeZoneID = "UTC"
        for host in ["http://example.com/when.html", "https://user:password@example.com/when.html", "https://example.com/when.html?who=me", "https://example.com/when.html#old", "not a URL", "https://example.com:444/when.html"] {
            let result = SharingGenerator.build(draft: draft, hostURL: host, now: date("2026-09-09T12:00:00Z"))
            #expect(result.document == nil)
            #expect(result.errors == ["hostURL"])
        }
    }

    @Test func springGapProducesNoNonexistentSundayWindow() throws {
        var draft = scheduled("America/Los_Angeles", start: 135, end: 165, weekdays: [1])
        let now = date("2026-03-08T08:00:00Z")
        let result = SharingGenerator.build(draft: draft, hostURL: "", now: now)
        let document = try #require(result.document)
        #expect(document.payload.windows.first?.startDate == date("2026-03-15T09:15:00Z"))
        draft.startMinute = 90
        draft.endMinute = 210
        let spanning = SharingGenerator.build(draft: draft, hostURL: "", now: now)
        let window = try #require(spanning.document?.payload.windows.first)
        #expect(window.startDate == date("2026-03-08T09:30:00Z"))
        #expect(window.endDate == date("2026-03-08T10:30:00Z"))
    }

    @Test func fallBackRetainsBothOccurrencesOfRepeatedWallTime() throws {
        let draft = scheduled("America/Los_Angeles", start: 75, end: 105, weekdays: [1])
        let document = try #require(SharingGenerator.build(draft: draft, hostURL: "", now: date("2026-11-01T07:00:00Z")).document)
        let windows = document.payload.windows
        #expect(windows.count >= 2)
        #expect(windows[0].startDate == date("2026-11-01T08:15:00Z"))
        #expect(windows[0].endDate == date("2026-11-01T08:45:00Z"))
        #expect(windows[1].startDate == date("2026-11-01T09:15:00Z"))
        #expect(windows[1].endDate == date("2026-11-01T09:45:00Z"))
    }

    @Test func overnightBelongsToTheSelectedStartDayAndIncludesCurrentShift() throws {
        let draft = scheduled("UTC", start: 1320, end: 360, weekdays: [6])
        let now = date("2026-09-12T01:00:00Z") // Saturday, inside Friday's shift.
        let document = try #require(SharingGenerator.build(draft: draft, hostURL: "", now: now).document)
        #expect(document.payload.windows.first?.startDate == now)
        #expect(document.payload.windows.first?.endDate == date("2026-09-12T06:00:00Z"))
        #expect(document.payload.schedule?.endDayOffset == 1)
        #expect(document.payload.schedule?.isWholeDay == false)
    }

    @Test func freshPreviewInvalidatesOnEditAndClosingReleasesArtifact() throws {
        let fixture = SharingFixture()
        fixture.store.activate()
        fixture.store.draft.timeZoneID = "Asia/Tokyo"
        fixture.store.prepare(now: date("2026-09-09T12:00:00Z"), locale: Locale(identifier: "en_US"))
        #expect(fixture.store.document != nil)
        #expect(fixture.store.qrCode != nil)
        fixture.store.draft.displayName = "Changed"
        #expect(fixture.store.document == nil)
        #expect(fixture.store.previewText.isEmpty)
        #expect(fixture.store.qrCode == nil, "二维码与名片同生同灭")
        fixture.store.prepare(now: date("2026-09-09T12:00:00Z"), locale: Locale(identifier: "en_US"))
        #expect(fixture.store.document != nil)
        fixture.store.deactivate()
        #expect(fixture.store.document == nil)
        #expect(fixture.store.previewText.isEmpty)
        #expect(fixture.store.qrCode == nil)
        #expect(fixture.store.activeResourceCount == 0)
    }

    // MARK: 自动预览（没有「生成预览」这一步）

    /// 页面出现时输入合法就直接有名片、预览文字和二维码，不用点任何按钮。
    @Test func automaticPreviewAppearsForValidInputTogetherWithItsQRCode() throws {
        let fixture = SharingFixture()
        fixture.store.draft.timeZoneID = "Asia/Tokyo"
        fixture.store.draft.displayName = "Mei"
        let now = date("2026-09-09T12:00:00Z")
        fixture.store.refreshIfNeeded(now: now, locale: Locale(identifier: "en_US")) { ["Asia/Tokyo": "Tokyo"][$0] ?? $0 }
        let document = try #require(fixture.store.document)
        #expect(document.payload.generatedAt == now.timeIntervalSince1970)
        #expect(fixture.store.previewText.hasPrefix("Mei · Tokyo (UTC+9)"), Comment(rawValue: fixture.store.previewText))
        #expect(fixture.store.errors.isEmpty)
        let code = try #require(fixture.store.qrCode)
        #expect(code.width == code.height && code.width > 0)
    }

    /// 输入不合法就没有名片、没有二维码，只有错误；输入没变再来问一遍也不会凭空生成。改对之后名片才出现。
    @Test func invalidInputMakesNoPreviewUntilItIsFixed() throws {
        let fixture = SharingFixture()
        fixture.store.draft.timeZoneID = "Mars/Olympus_Mons"
        fixture.store.refreshIfNeeded(now: date("2026-09-09T12:00:00Z"), locale: Locale(identifier: "en_US"))
        #expect(fixture.store.document == nil)
        #expect(fixture.store.qrCode == nil)
        #expect(fixture.store.previewText.isEmpty)
        #expect(fixture.store.errors == ["timeZone"])
        fixture.store.refreshIfNeeded(now: date("2026-09-09T12:05:00Z"), locale: Locale(identifier: "en_US"))
        #expect(fixture.store.document == nil)
        #expect(fixture.store.errors == ["timeZone"])

        fixture.store.draft.timeZoneID = "Asia/Tokyo"
        #expect(fixture.store.errors.isEmpty, "改了输入，旧错误先清掉")
        fixture.store.refreshIfNeeded(now: date("2026-09-09T12:06:00Z"), locale: Locale(identifier: "en_US"))
        #expect(fixture.store.document != nil)
        #expect(fixture.store.qrCode != nil)
        #expect(fixture.store.errors.isEmpty)

        // 显示名超长也是一种不合法：名片消失、二维码消失、只剩错误。
        fixture.store.draft.displayName = String(repeating: "长", count: 81)
        fixture.store.refreshIfNeeded(now: date("2026-09-09T12:07:00Z"), locale: Locale(identifier: "en_US"))
        #expect(fixture.store.document == nil)
        #expect(fixture.store.qrCode == nil)
        #expect(fixture.store.errors == ["name"])
    }

    /// 输入没变就不重算：名片的生成时刻不动、二维码还是同一张位图；文本框获得焦点把同一个值写回去也一样。
    /// 真的改了才重新生成，二维码跟着换。
    @Test func unchangedInputDoesNotRebuildThePreviewOrRedrawTheQRCode() throws {
        let fixture = SharingFixture()
        fixture.store.draft.timeZoneID = "Asia/Tokyo"
        fixture.store.draft.displayName = "Mei"
        let first = date("2026-09-09T12:00:00Z")
        fixture.store.refreshIfNeeded(now: first, locale: Locale(identifier: "en_US"))
        let document = try #require(fixture.store.document)
        let code = try #require(fixture.store.qrCode)

        fixture.store.refreshIfNeeded(now: first.addingTimeInterval(600), locale: Locale(identifier: "en_US"))
        #expect(fixture.store.document == document, "十分钟后再问一遍：同一份名片")
        #expect(fixture.store.qrCode === code, "同一张二维码位图，没有重画")

        // SwiftUI 文本框获得焦点时会把没变的值写回绑定。
        let sameName = fixture.store.draft.displayName
        fixture.store.draft.displayName = sameName
        #expect(fixture.store.document == document)
        fixture.store.refreshIfNeeded(now: first.addingTimeInterval(900), locale: Locale(identifier: "en_US"))
        #expect(fixture.store.document == document)
        #expect(fixture.store.qrCode === code)

        fixture.store.draft.displayName = "Mei Lin"
        #expect(fixture.store.document == nil)
        let second = first.addingTimeInterval(1200)
        fixture.store.refreshIfNeeded(now: second, locale: Locale(identifier: "en_US"))
        let rebuilt = try #require(fixture.store.document)
        #expect(rebuilt.payload.generatedAt == second.timeIntervalSince1970)
        #expect(rebuilt.payload.displayName == "Mei Lin")
        #expect(fixture.store.qrCode !== code)
    }

    /// 页面隔了很久再打开：名片按现在重新生成（可约时段的 14 天和「截至」时刻跟着现在走）；一小时内不动。
    @Test func aStaleDocumentIsRebuiltWhenThePageComesBack() throws {
        let fixture = SharingFixture()
        fixture.store.draft.timeZoneID = "Asia/Tokyo"
        let first = date("2026-09-09T12:00:00Z")
        fixture.store.refreshIfNeeded(now: first, locale: Locale(identifier: "en_US"))
        fixture.store.refreshIfNeeded(now: first.addingTimeInterval(SharingStore.maxDocumentAge), locale: Locale(identifier: "en_US"))
        #expect(fixture.store.document?.payload.generatedAt == first.timeIntervalSince1970)
        let later = first.addingTimeInterval(SharingStore.maxDocumentAge + 1)
        fixture.store.refreshIfNeeded(now: later, locale: Locale(identifier: "en_US"))
        #expect(fixture.store.document?.payload.generatedAt == later.timeIntervalSince1970)
    }

    /// 界面语言变了只重排文字：名片与二维码都不动。
    @Test func relocalizingKeepsTheQRCode() throws {
        let fixture = SharingFixture()
        fixture.store.draft.timeZoneID = "Asia/Tokyo"
        fixture.store.refreshIfNeeded(now: date("2026-09-09T12:00:00Z"), locale: Locale(identifier: "en_US"))
        let code = try #require(fixture.store.qrCode)
        fixture.store.relocalize(locale: Locale(identifier: "zh-Hans")) { _ in "东京" }
        #expect(fixture.store.previewText.hasPrefix("东京（UTC+9）"))
        #expect(fixture.store.qrCode === code)
    }

    /// 分享页不往偏好里写任何东西：名字、作息与地点都只在这一页活着（以前存过自己填的托管地址，那一格拿掉了）。
    @Test func nothingPersists() throws {
        let fixture = SharingFixture()
        fixture.store.draft.timeZoneID = "Europe/Paris"
        fixture.store.draft.displayName = "Private name"
        fixture.store.prepare(now: date("2026-09-09T12:00:00Z"), locale: Locale(identifier: "en_US"))
        #expect(fixture.store.document != nil)
        #expect(fixture.defaults.persistentDomain(forName: fixture.suite)?.isEmpty ?? true)
        let reloaded = SharingStore(defaults: fixture.defaults)
        #expect(reloaded.draft.timeZoneID.isEmpty)
        #expect(reloaded.draft.displayName.isEmpty)
        #expect(!reloaded.draft.includesAvailability)
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func scheduled(_ zone: String, start: Int, end: Int, weekdays: [Int]) -> SharingDraft {
        var draft = SharingDraft()
        draft.timeZoneID = zone
        draft.includesAvailability = true
        draft.startMinute = start
        draft.endMinute = end
        draft.workingWeekdays = weekdays
        return draft
    }

    /// 名片顶上的昼夜地图：带地图的卡片能渲染、比不带的高；`TEST_RUNNER_MEANTIME_CARD_OUT` 指定路径时把 PNG 写出来供肉眼看。
    @MainActor @Test func cardWithMapRendersTaller() throws {
        let lines = [TimeCardImage.Line(name: "东京", text: "9:00"), TimeCardImage.Line(name: "伦敦", text: "1:00")]
        let plain = TimeCardImage.Card(title: "Mei", subtitle: "东京 · 工作日 9:00–18:00", lines: lines, footer: "用 Dayside 分享")
        let instant = Date(timeIntervalSince1970: 1_789_700_000)
        let mapped = TimeCardImage.Card(title: "Mei", subtitle: "东京 · 工作日 9:00–18:00", lines: lines, footer: "用 Dayside 分享",
                                        map: .init(instant: instant, places: [WorldMapPlace(latitude: 35.68, longitude: 139.69, home: true),
                                                                              WorldMapPlace(latitude: 51.5, longitude: -0.12, home: false)]))
        let locale = Locale(identifier: "zh-Hans")
        let a = try #require(TimeCardImage.image(for: plain, locale: locale))
        let b = try #require(TimeCardImage.image(for: mapped, locale: locale))
        #expect(b.size.height > a.size.height + 200)
        #expect(b.size.width == TimeCardImage.width)
        // 测试宿主在沙盒里，只能写自己的临时目录；路径打到日志里，外面 `cp` 出来看。
        if ProcessInfo.processInfo.environment["MEANTIME_CARD_OUT"] != nil, let png = TimeCardImage.pngData(b) {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("dayside-card-map.png")
            try png.write(to: out)
            print("MEANTIME_CARD_OUT=\(out.path)")
        }
    }
}

@MainActor
private final class SharingFixture {
    private let handle = TestDefaults.makeSuiteName(prefix: "meantime.sharing.tests")
    var suite: String { handle.name }
    let defaults: UserDefaults
    let store: SharingStore
    init() {
        defaults = UserDefaults(suiteName: handle.name)!
        store = SharingStore(defaults: defaults)
    }
    isolated deinit {
        store.deactivate()
        handle.cleanup()
    }
}


private extension Result {
    var isFailure: Bool { if case .failure = self { return true } else { return false } }

}
