// SPDX-License-Identifier: GPL-3.0-only
//
//  SharingLensView.swift
//  TahoeTime
//
//  分享我的时间：一张印着我这边的天的明信片。页面从它开始：
//  主语行（分享哪个地点，就是一个菜单）→ 明信片（收方打开看到的就是这一张）→ 怎么给出去（拷贝文字、图片、存成网页、二维码）
//  → 可约时段 → 更多选项（名字、预约邮箱）→ 一句脚注（谁能看到、不查日历、不经服务器）。
//  只能从自己的地点里挑，不再手填时区标识符，也不再让人填自己托管的网页地址（诚实评估 C-8）。
//

import SwiftUI

struct SharingLensView: View {
    @Environment(TimeCore.self) private var core
    @Bindable var store: SharingStore
    @State private var showingCode = false

    private var localTimeZoneID: String { TimeZone.autoupdatingCurrent.identifier }

    /// 名片上的地名、拉丁写法与坐标：已保存的地点用它自己的城市名（按城市语言，不带自定义名与 emoji）与坐标；
    /// 「本机」用这个时区的城市名与随包坐标表里的代表城市（与面板的框、页首天色带同一个「这里」）。
    private var placeFacts: SharingPlaceFacts {
        switch store.zoneChoice {
        case .place(let id)?:
            guard let entry = core.zones.first(where: { $0.id == id }) else { return .none }
            let name = core.cityName(for: entry)
            return Self.postcardPlaceFacts(name: name, city: entry.cityName, coordinate: entry.coordinate)
        case .local?:
            let entry = TimeZoneEntry(timezoneID: localTimeZoneID, cityName: Self.exemplarCity(localTimeZoneID))
            let name = core.cityName(for: entry)
            return Self.postcardPlaceFacts(name: name, city: entry.cityName,
                                           coordinate: SkyPanel.homeCoordinate(zones: core.zones))
        case nil:
            return .none
        }
    }

    /// 只有非拉丁字母的地名才附拉丁写法；重音、组合音标与标点不另算一种文字。
    static func postcardPlaceFacts(name: String, city: String, coordinate: Coordinate?) -> SharingPlaceFacts {
        let place = name.isEmpty ? city : name
        let nonLatin = place.range(of: #"[\p{L}&&[^\p{Latin}\p{Common}\p{Inherited}]]"#,
                                   options: .regularExpression) != nil
        return SharingPlaceFacts(name: place, city: nonLatin ? city : "", coordinate: coordinate)
    }

    /// 时区标识符的代表城市拉丁写法（`America/Los_Angeles` → Los Angeles）：「本机」没有已保存的地点时给名片的拉丁写法。
    static func exemplarCity(_ identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier).replacingOccurrences(of: "_", with: " ")
    }

    private func placeName(_ identifier: String) -> String { core.placeName(forTimeZoneID: identifier) }
    private func alignZoneChoice() {
        store.alignZoneChoice(places: core.zones, localTimeZoneID: localTimeZoneID)
        store.applyPlace(placeFacts)
    }
    private func relocalize() { store.relocalize(locale: core.uiLocale, now: core.now, placeName: placeName) }
    private func refresh() { store.refreshIfNeeded(now: core.now, locale: core.uiLocale, placeName: placeName) }
    /// 小时制同步进名片文字（复制出去的钟点跟它走）；变了只重排文字，名片本身不重建。
    private func applyHourStyle() { store.hourStyle = core.settings.hourStyle }

    /// 预览随输入自动生成，没有「生成预览」这一步。选项类改动（地点、可约时段、钟点、星期）立即重算；
    /// 文字输入（名字、邮箱）等停下 `typingSettleDelay` 再算，免得每个击键都生成一次名片和二维码。
    private struct ChoiceKey: Equatable {
        let zone: SharingZoneChoice?
        let place: SharingPlaceFacts
        let includesAvailability: Bool
        let startMinute: Int
        let endMinute: Int
        let workingWeekdays: [Int]
    }
    private struct TypedKey: Equatable {
        let displayName: String
        let contactEmail: String
    }
    private var choiceKey: ChoiceKey {
        ChoiceKey(zone: store.zoneChoice, place: placeFacts, includesAvailability: store.draft.includesAvailability,
                  startMinute: store.draft.startMinute, endMinute: store.draft.endMinute, workingWeekdays: store.draft.workingWeekdays)
    }
    private var typedKey: TypedKey { TypedKey(displayName: store.draft.displayName, contactEmail: store.draft.contactEmail) }
    private static let typingSettleDelay: Duration = .milliseconds(300)

    /// iPhone 版发布后才显示跨设备同步入口（`SharingPhoneSync`，代码留着）。
    static let iPhoneAppIsReleased = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            subject
            if let card = store.postcard(locale: core.uiLocale, placeName: placeName) {
                PostcardView(card: card, now: core.now)
                    .frame(maxWidth: 480, alignment: .leading)
                    .padding(.top, 14)
                actions
                    .padding(.top, 14)
            }
            ForEach(store.errors, id: \.self) { error in
                ErrorLine(Text(errorKey(error))).padding(.top, 10)
            }
            availabilitySection
                .padding(.top, 28)
            moreOptions
                .padding(.top, 20)
            Text("拿到名片的人都能看到上面写的，包括城市名和大致位置。可约时段是你未来 14 天的作息，不查日历，也不经过任何服务器。")
                .appFont(.caption).foregroundStyle(.readableSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 28)
            if Self.iPhoneAppIsReleased { SharingPhoneSync().padding(.top, 28) }
        }
        // 先按地点表对齐、写进地名与坐标；名片随地名、界面语言与小时制重排。
        .onAppear { alignZoneChoice(); applyHourStyle(); relocalize(); refresh() }
        .onChange(of: core.zones) { alignZoneChoice() }
        .onChange(of: placeFacts) { store.applyPlace(placeFacts) }
        .onChange(of: core.uiLocale.identifier) { relocalize() }
        .onChange(of: core.settings.hourStyle) { applyHourStyle(); relocalize() }
        .onChange(of: core.systemRevision) { store.syncLocalTimeZone(localTimeZoneID) }
        // 选项改动走 `onChange`，紧接着这轮更新就重算、不等待；文字改动走 `task(id:)`，键一换就取消上一次等待，等于去抖。
        .onChange(of: choiceKey) { refresh() }
        .task(id: typedKey) {
            try? await Task.sleep(for: Self.typingSettleDelay)
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    // MARK: 主语行：分享哪个地点

    /// 一个菜单：标签是所选地点（衬线 17 点中等，与面板行同一种地名字）加 9 点小箭头，整块一个读屏元素；
    /// 菜单里是自己的地点，最后是「本机」（这台 Mac 的时区不在地点表里时）。
    private var subject: some View {
        Menu {
            ForEach(core.zones) { entry in
                Button { choose(.place(entry.id)) } label: {
                    let title = entry.displayName(localizedCity: core.cityName(for: entry))
                    if store.zoneChoice == .place(entry.id) { Label(title, systemImage: "checkmark") } else { Text(verbatim: title) }
                }
            }
            if !core.zones.contains(where: { $0.timezoneID == localTimeZoneID }) {
                if !core.zones.isEmpty { Divider() }
                Button { choose(.local) } label: {
                    let title = String(format: L10n.string("本机（%@）", locale: core.uiLocale), placeName(localTimeZoneID))
                    if store.zoneChoice == .local { Label(title, systemImage: "checkmark") } else { Text(verbatim: title) }
                }
            }
        } label: {
            PlannerMenuLabel(text: subjectTitle, serif: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("分享哪个地点"))
                .accessibilityValue(Text(verbatim: subjectTitle))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(Text("分享哪个地点"))
        .accessibilityIdentifier("sharing-place")
    }

    private var subjectTitle: String {
        switch store.zoneChoice {
        case .place(let id)?:
            if let entry = core.zones.first(where: { $0.id == id }) { return entry.displayName(localizedCity: core.cityName(for: entry)) }
        case .local?:
            return String(format: L10n.string("本机（%@）", locale: core.uiLocale), placeName(localTimeZoneID))
        case nil: break
        }
        return placeName(store.draft.timeZoneID)
    }

    private func choose(_ choice: SharingZoneChoice) {
        store.chooseZone(choice, places: core.zones, localTimeZoneID: localTimeZoneID)
        store.applyPlace(placeFacts)
    }

    // MARK: 怎么给出去

    /// 拷贝文字（贴进聊天）、图片（拷贝或存储）、存成网页（对方用浏览器打开就是这张明信片）、二维码（Dayside 导入）；
    /// 定了公开的分享页地址之后多一个「拷贝链接」。下面一行是刚做完的那一件。
    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChipFlowLayout(spacing: 10, lineSpacing: 8) {
                Button("复制文字") { store.copyText() }.fixedSize()
                Menu {
                    Button("复制图片") { store.copyImage(locale: core.uiLocale, core: core, placeName: placeName) }
                    Button("存储图片…") { store.saveImage(locale: core.uiLocale, core: core, placeName: placeName) }
                } label: {
                    PlannerMenuLabel(text: L10n.string("图片", locale: core.uiLocale), style: nil)
                        .padding(.horizontal, 4)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("图片"))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                Button("保存 HTML…") { store.saveHTML() }.fixedSize()
                    .help(Text("存成一个网页文件，对方用浏览器打开就是这张明信片，还能直接约时间。"))
                if store.document?.shareURL != nil {
                    Button("复制分享链接") { store.copyLink() }.fixedSize()
                }
                if let code = store.qrCode {
                    Button { showingCode = true } label: { Label("二维码", systemImage: "qrcode") }
                        .fixedSize()
                        .popover(isPresented: $showingCode, arrowEdge: .bottom) {
                            SharingCodeView(code: code).environment(\.locale, core.uiLocale)
                        }
                }
            }
            statusText
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch store.status {
        case .idle: EmptyView()
        case .copied: Label("已复制", systemImage: "checkmark.circle").appFont(.caption)
        case .saved: Label("已保存 HTML 文件。", systemImage: "checkmark.circle").appFont(.caption)
        case .copyFailed: ErrorLine(Text("无法复制，请重试。")).appFont(.caption)
        case .saveFailed: ErrorLine(Text("无法保存文件。请选择可写入的位置后重试。")).appFont(.caption)
        }
    }

    // MARK: 可约时段

    private var availabilitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("分享可约时段", isOn: $store.draft.includesAvailability)
                .accessibilityIdentifier("sharing-availability")
            if store.draft.includesAvailability {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    DatePicker("开始", selection: minuteBinding(\.startMinute), displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, .gmt).fixedSize()
                        .accessibilityHint(Text("结束早于开始就是跨夜，起止相同就是全天"))
                    Text(verbatim: "–").accessibilityHidden(true)
                    DatePicker("结束", selection: minuteBinding(\.endMinute), displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, .gmt).fixedSize()
                        .accessibilityLabel(availabilityEndLabel)
                        .accessibilityHint(Text("结束早于开始就是跨夜，起止相同就是全天"))
                    if store.draft.endMinute < store.draft.startMinute { Text("次日").accessibilityHidden(true) }
                    else if store.draft.endMinute == store.draft.startMinute { Text("全天").accessibilityHidden(true) }
                }
                .help(Text("结束早于开始就是跨夜，起止相同就是全天"))
                .accessibilityHint(Text("结束早于开始就是跨夜，起止相同就是全天"))
                // 七个勾选框：勾上与没勾一眼分得清（按钮样式的开关两种状态只差一点灰，难认）。
                ChipFlowLayout(spacing: 14, lineSpacing: 6) {
                    ForEach(Self.weekOrder(), id: \.self) { weekday in
                        Toggle(isOn: Binding(get: { store.draft.workingWeekdays.contains(weekday) },
                                             set: { store.setWeekday(weekday, enabled: $0) })) {
                            Text(verbatim: ClockText.weekday(weekday, locale: core.uiLocale))
                        }
                        .fixedSize()
                        .accessibilityHint(Text("星期按时段开始那天算"))
                    }
                }
                .help(Text("星期按时段开始那天算"))
                .accessibilityHint(Text("星期按时段开始那天算"))
            }
        }
    }

    /// 一周从哪天排起：跟系统设置里的「每周第一天」（界面语言没写地区，按它排会把中国用户的一周排成从周日起）。
    private var availabilityEndLabel: Text {
        let marker = store.draft.endMinute < store.draft.startMinute ? "次日" : store.draft.endMinute == store.draft.startMinute ? "全天" : nil
        let words = [L10n.string("结束", locale: core.uiLocale)] + (marker.map { [L10n.string($0, locale: core.uiLocale)] } ?? [])
        return Text(verbatim: words.joined(separator: ", "))
    }

    static func weekOrder(_ calendar: Calendar = .autoupdatingCurrent) -> [Int] {
        let first = calendar.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    /// 墙钟分钟 ↔ DatePicker：日期部分无意义，按 UTC 的固定参照日读写（与人物编辑器同一个做法）。
    private func minuteBinding(_ keyPath: WritableKeyPath<SharingDraft, Int>) -> Binding<Date> {
        Binding(get: { Date(timeIntervalSince1970: Double(store.draft[keyPath: keyPath] % 1440) * 60) },
                set: { date in
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = .gmt
                    let parts = calendar.dateComponents([.hour, .minute], from: date)
                    store.draft[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                })
    }

    // MARK: 更多选项：名片上的名字、预约邮箱

    private var moreOptions: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("显示名（可选）") {
                    TextField(text: $store.draft.displayName, prompt: Text(verbatim: "")) { Text("显示名（可选）") }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("sharing-name")
                }
                LabeledContent("预约邮箱（可选）") {
                    TextField(text: $store.draft.contactEmail, prompt: Text(verbatim: "")) { Text("预约邮箱（可选）") }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("sharing-contact")
                }
                Text("对方选好时段就能一键给你发预约邮件；邮箱会写进链接。")
                    .appFont(.caption).foregroundStyle(.readableSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
        } label: {
            Text("更多选项").frame(minHeight: 22)   // 命中区 ≥ 20 pt（HIG）
        }
    }

    private func errorKey(_ error: String) -> LocalizedStringKey {
        switch error {
        case "timeZone": "请选择有效的时区。"
        case "name": "显示名最多 80 个字符，且不能包含换行或控制字符。"
        case "contact": "预约邮箱要写成 name@example.com 这样的形式，不能有空格或引号。"
        case "hours": "请选择有效的开始和结束时间。"
        case "weekdays": "请至少选择一天。"
        default: "无法生成分享预览。请检查所选时区和日期后重试。"
        }
    }
}

/// 名片的二维码（弹出框）：装的是名片本身（定了公开地址后是链接）。手机扫了得到同一张名片，在 Dayside 的人物页导入。
private struct SharingCodeView: View {
    let code: CGImage
    var body: some View {
        let side = SharingQRCode.displaySide(for: code)
        VStack(alignment: .leading, spacing: 10) {
            Image(code, scale: 1, label: Text("分享二维码"))
                .interpolation(.none)
                .resizable()
                .frame(width: side, height: side)
                .background(Color.white)
            Text("扫码得到同一张名片；对方在「人物时钟」页导入即可，不经过服务器。")
                .appFont(.caption).foregroundStyle(.readableSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: max(side, 220) + 28)
    }
}

/// 同步到 iPhone：把已保存地点编成 `dayside://import#dp1.…`，二维码给 iPhone 的 Dayside 扫，链接可复制后用任何方式
/// 发到手机上再点开；不经服务器。iPhone 版发布前不显示（诚实评估 C-7），代码留着。
private struct SharingPhoneSync: View {
    @Environment(TimeCore.self) private var core
    @State private var syncLink: PlacesTransferLink?
    @State private var syncCode: CGImage?
    @State private var syncCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("同步到 iPhone").appFont(.headline).accessibilityAddTraits(.isHeader)
            if core.zones.isEmpty {
                Text("添加地点后，这里会生成给 iPhone 扫的二维码。").foregroundStyle(.readableSecondary)
            } else if let syncLink {
                HStack(alignment: .top, spacing: 12) {
                    if let syncCode {
                        let side = SharingQRCode.displaySide(for: syncCode)
                        Image(syncCode, scale: 1, label: Text("同步到 iPhone 的二维码"))
                            .interpolation(.none)
                            .resizable()
                            .frame(width: side, height: side)
                            .background(Color.white)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if syncCode != nil {
                            Text("iPhone 上打开 Dayside › 从 Mac 导入，扫这个码（\(syncLink.count) 个地点）；改了地点再扫一次。")
                                .appFont(.caption).foregroundStyle(.readableSecondary)
                        } else {
                            Text("地点太多，二维码装不下：复制链接发到手机上，在 iPhone 的 Dayside 里点「从 Mac 导入 › 粘贴链接」。")
                                .appFont(.caption).foregroundStyle(.readableSecondary)
                        }
                        HStack {
                            Button("复制链接") {
                                NSPasteboard.general.clearContents()
                                syncCopied = NSPasteboard.general.setString(syncLink.url, forType: .string)
                            }
                            if syncCopied { Label("已复制", systemImage: "checkmark.circle").appFont(.caption) }
                        }
                    }
                }
            } else {
                Text("地点清单暂时生成不了二维码。").foregroundStyle(.readableSecondary)
            }
        }
        // 键是实际导出的内容（名字随界面语言与城市语言变），不是地点 id：切换城市语言后二维码也要跟着重算。
        .task(id: core.zones.map { TransferPlace(entry: $0, displayName: $0.displayName(localizedCity: core.cityName(for: $0))) }) {
            syncCopied = false
            switch PlacesTransfer.link(for: core.zones, displayName: { $0.displayName(localizedCity: core.cityName(for: $0)) }, now: core.now) {
            case .success(let link):
                syncLink = link
                syncCode = SharingQRCode.image(for: link.url)
            case .failure:
                syncLink = nil; syncCode = nil
            }
        }
    }
}
