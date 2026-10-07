// SPDX-License-Identifier: GPL-3.0-only
// Fixed GeoNames correction and administrative suffix tables, migrated without changing their scope.
// ADMIN1_ZH only fills missing region labels; ERRATA only selects an existing candidate or removes a bad one.
pub const ADMIN1_ZH: &[(&str, &str, &str)] = &[
    ("HK.HSO", "南区", "南區"),
    ("HK.KSS", "深水埗区", "深水埗區"),
    ("HK.KWT", "黄大仙区", "黃大仙區"),
    ("HK.NSK", "西贡区", "西貢區"),
    ("HK.NTP", "大埔区", "大埔區"),
    ("HK.NTW", "荃湾区", "荃灣區"),
    ("HK.NYL", "元朗区", "元朗區"),
    ("MO.11875154", "花地玛堂区", "花地瑪堂區"),
    ("UA.20", "塞瓦斯托波尔市", "塞瓦斯托波爾市"),
];
/// 一级行政区中文名补充表（`data/admin1_zh_supplement.tsv`）：补充 GeoNames 没给中文名的行政区，
/// 1,177 条来自 Wikidata（按 GeoNames ID 取 zh 标签）、347 条由 LLM 翻译；与 `ADMIN1_ZH` 同一条准入——只填缺失，从不覆盖。
/// 每行 `code\thans\thant\tsource\tenglish`，hant 可空（显示时由简体转换）；`#` 开头是注释。
pub fn admin1_supplement() -> impl Iterator<Item = (&'static str, &'static str, &'static str)> {
    include_str!("../data/admin1_zh_supplement.tsv")
        .lines()
        .filter(|line| !line.starts_with('#') && !line.trim().is_empty())
        .filter_map(|line| {
            let mut parts = line.split('\t');
            let code = parts.next()?;
            let hans = parts.next()?;
            let hant = parts.next().unwrap_or("");
            (!code.is_empty() && !hans.is_empty()).then_some((code, hans, hant))
        })
}
pub const ERRATA: &[(&str, &str, Option<&str>)] = &[
    ("709930", "ja", None),
    ("709930", "ko", None),
    ("2633866", "zh-Hans", Some("温布尔登")),
    ("2392308", "pt-BR", None),
    ("5797582", "pt-BR", None),
    ("12542131", "pt-BR", None),
    ("3407377", "pt-BR", None),
    ("12542060", "pt-BR", None),
    ("12542319", "pt-BR", None),
    ("1673820", "zh-Hant", None),
];
/// 主名改选（2026-10-07）：纽约显示为人们常写的 New York（已是它的别名之一），旧主名仍是搜索键。
pub const PRIMARY_NAME_ERRATA: &[(&str, &str, &str)] = &[("New York City", "US", "New York")];

/// 搜索键补丁。只给既有城市追加倒排键，不改显示名、坐标、时区。
/// 每行 = (主名, 国家码, 要补的名字)；名字在入表前过与 `pick_alternates` 同一套 `fold`，不另立规则。
/// 镜像里没有 GeoNames id（城市记录 20 字节只有名字、行政区、时区、国家、坐标），所以转码器按
/// 「主名 + 国家码」找城市，要求恰好一座命中，撞名或找不到都报错而不是静默跳过；同一城市已有
/// 该键时视为已补过（转码幂等）。来源都是探针 `stored_names_of_big_cities_find_their_city_first`
/// 生成器遗漏的搜索键，每行写明当初为什么没建键。
/// 单字键读取端本来就认：`secondary_keys` 早已给「Sector 1」「Shek O」这类名字留下 23 个单字符键，
/// `locate` 的块首二分与 `KeyCursor` 只比字节串，不看长度。
pub const SEARCH_KEY_ERRATA: &[(&str, &str, &[&str])] = &[
    // 探针 #7 [pt-BR]「Cidade de Ho Chi Minh」→ nothing：拉丁名含 4 个空格，超出 pick_alternates 的 ≤3 空格上限。
    ("Ho Chi Minh City", "VN", &["Cidade de Ho Chi Minh"]),
    // 探针 #36 [de]「Chongqing (Chongqing Shi)」→ nothing：25 字符，超出拉丁名 ≤24 字符上限（fold 去括号后为 chongqing chongqing shi）。
    ("Chongqing", "CN", &["Chongqing (Chongqing Shi)"]),
    // 探针 #267 [ko]「빈」→ 滨州（只剩前缀命中）：单字名，pick_alternates 只收 2–40 字符。
    ("Vienna", "AT", &["빈"]),
    // 探针 #633 [ko]「쿰」→ Cwmbran（只剩前缀命中）：同上，单字名。
    ("Qom", "IR", &["쿰"]),
    // 探针 #718 [ko]「빈」→ 滨州：同上；与维也纳同名，补后按人口维也纳第一、荣市第二，转入「同名相撞」类。
    ("Vinh", "VN", &["빈"]),
    // 探针 #878 [pt-BR]「Cidade do Santo Nome de Deus de Macau」→ nothing：37 字符、7 个空格，两条上限都超。
    ("Macau", "MO", &["Cidade do Santo Nome de Deus de Macau"]),
];
pub const ADMIN_UNITS: &[&str] = &[
    "特別自治市",
    "특별자치도",
    "특별자치시",
    "劳动者区",
    "勞動者區",
    "노동자구",
    "区役所",
    "城关镇",
    "城厢镇",
    "城廂鎮",
    "城關鎮",
    "市役所",
    "广域市",
    "広域市",
    "廣域市",
    "开发区",
    "村役場",
    "特別市",
    "特别市",
    "町役場",
    "直轄市",
    "直辖市",
    "自治区",
    "自治區",
    "自治县",
    "自治州",
    "自治旗",
    "自治縣",
    "開發區",
    "광역시",
    "직할시",
    "특별시",
    "地区",
    "地區",
    "城关",
    "城厢",
    "城廂",
    "城郊",
    "城關",
    "役場",
    "役所",
    "新区",
    "新區",
    "街道",
    "乡",
    "区",
    "區",
    "县",
    "州",
    "市",
    "府",
    "旗",
    "村",
    "町",
    "盟",
    "省",
    "県",
    "縣",
    "郡",
    "都",
    "鄉",
    "鎮",
    "镇",
    "구",
    "군",
    "동",
    "리",
    "면",
    "시",
    "읍",
];
