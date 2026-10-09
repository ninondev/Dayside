// SPDX-License-Identifier: GPL-3.0-only
//
//  SuggestedPlaces.swift
//  Dayside
//
//  首启空态的建议地点：按系统地区、日历与通讯录里出现过的地点建议，用户确认才加。
//  本机所在地 → 已保存人物的所在地 → 系统「地区」设置对应国家的最大城市（与本机不在同一国家时：住在洛杉矶、
//  地区设成台湾的人，多半还关心台北几点）→ 日历里已经授权时未来 14 天日程带的时区 → 通讯录已授权时地址里最常见的
//  城市。绝不弹授权框：日历与通讯录都只在授权状态已经是完全访问时读一次；通讯录逐条枚举可能要几百毫秒，放在主线程外。
//

import Contacts
import EventKit
import Foundation

enum SuggestedPlaces {
    /// 纯排序：按来源顺序去重（同一时区只留第一个来源给的那条），认不出的时区跳过，最多 `limit` 个（面板空态最多三颗按钮）。
    static func merge(local: ZoneOption, people: [ZoneOption], region: ZoneOption?, calendar: [ZoneOption],
                      contacts: [ZoneOption], limit: Int = 3) -> [ZoneOption] {
        var seen: Set<String> = []
        var result: [ZoneOption] = []
        for option in [local] + people + (region.map { [$0] } ?? []) + calendar + contacts
        where TimeZone(identifier: option.identifier) != nil && seen.insert(option.identifier).inserted {
            result.append(option)
            if result.count == limit { break }
        }
        return result
    }

    /// 去重后的 IANA 标识符（本机永远第一）；给测试与不需要坐标的调用方。
    static func identifiers(local: TimeZone = .current, region: String? = nil, people: [PersonPlace], now: Date, limit: Int = 3) -> [String] {
        merge(local: option(identifier: local.identifier), people: people.map { option(identifier: $0.timeZoneID) },
              region: region.flatMap { homeCity(region: $0, local: local) }, calendar: calendarZones(now: now).map(option(identifier:)),
              contacts: [], limit: limit).map(\.identifier)
    }

    /// 面板空态用：本机、人物、系统地区与日历同步取，通讯录在主线程外枚举后再合并。
    @MainActor
    static func load(local: TimeZone = .current, region: String? = Locale.current.region?.identifier,
                     people: [PersonPlace], now: Date, limit: Int = 3) async -> [ZoneOption] {
        let home = region.flatMap { homeCity(region: $0, local: local) }
        let calendar = calendarZones(now: now).map(option(identifier:))
        let contactOptions = await contactCities().compactMap(cityOption)
        return merge(local: option(identifier: local.identifier), people: people.map { option(identifier: $0.timeZoneID) },
                     region: home, calendar: calendar, contacts: contactOptions, limit: limit)
    }

    /// 系统时区目录里的那条（带坐标，天文页才算得出日照）；目录没有就按标识符临时造一条。
    static func option(identifier: String) -> ZoneOption {
        ZoneCatalog.shared.option(for: identifier) ?? ZoneOption(identifier: identifier, coordinate: nil)
    }

    /// 系统「地区」所在国家人口最多的城市；本机时区的代表城市就在这个国家时不建议（本机那条已经在了）。
    static func homeCity(region: String, local: TimeZone) -> ZoneOption? {
        let index = CityIndex.shared
        let localCountry = index.representativeCity(forTimezone: local.identifier)?.record.countryCode ?? ""
        guard region.count == 2, region.uppercased() != localCountry.uppercased(),
              let top = index.topCities(inCountry: region.uppercased(), limit: 1).first else { return nil }
        return ZoneOption(cityIndex: top.index, record: top.record)
    }

    /// 日历授权已是完全访问时，未来 14 天非全天日程自带的时区（会议邀请常带发起方时区）；否则空。
    static func calendarZones(now: Date) -> [String] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(14 * 86_400), calendars: nil)
        var seen: Set<String> = []
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
            .compactMap { $0.timeZone?.identifier }
            .filter { seen.insert($0).inserted }
    }

    struct ContactCity: Hashable, Sendable {
        let city: String
        /// ISO 3166 两字母码，通讯录没填国家时为空（那时只按城市名找，同名城市按人口取第一个）。
        let country: String
        let count: Int
    }

    /// 通讯录授权已是完全访问时，所有联系人地址里的（城市, 国家）按出现次数从多到少；否则空。只读，不请求授权。
    static func contactCities() async -> [ContactCity] {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [] }
        let worker = Task.detached(priority: .utility) { () -> [ContactCity] in
            let store = CNContactStore()
            let request = CNContactFetchRequest(keysToFetch: [CNContactPostalAddressesKey as CNKeyDescriptor])
            var counts: [String: (city: String, country: String, count: Int, order: Int)] = [:]
            try? store.enumerateContacts(with: request) { contact, stop in
                if Task.isCancelled { stop.pointee = true; return }
                for labeled in contact.postalAddresses {
                    let city = labeled.value.city.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !city.isEmpty else { continue }
                    let country = labeled.value.isoCountryCode.uppercased()
                    let key = "\(city.lowercased())|\(country)"
                    if let seen = counts[key] { counts[key] = (seen.city, seen.country, seen.count + 1, seen.order) }
                    else { counts[key] = (city, country, 1, counts.count) }
                }
            }
            return counts.values.sorted { ($0.count, -$0.order) > ($1.count, -$1.order) }
                .map { ContactCity(city: $0.city, country: $0.country, count: $0.count) }
        }
        return await worker.value
    }

    /// 城市名（加国家码）在索引里的第一个命中；索引找不到就跳过，不猜。
    static func cityOption(_ contact: ContactCity) -> ZoneOption? {
        let index = CityIndex.shared
        let hits = index.search(folded: contact.city.searchFolded, limit: 8)
        for hit in hits {
            guard let record = index.city(at: hit.cityIndex) else { continue }
            if contact.country.isEmpty || record.countryCode.uppercased() == contact.country {
                return ZoneOption(cityIndex: hit.cityIndex, record: record)
            }
        }
        return nil
    }
}
