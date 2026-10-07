// SPDX-License-Identifier: GPL-3.0-only
//! 「听懂时间」引擎输出给宿主的结构（serde camelCase）。
use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Clock {
    pub hour: u8,
    pub minute: u8,
    pub second: u8,
    /// 午夜 = 次日 0 点、「晚上 12 点」= 次日 0 点。
    pub day_offset: i8,
}

impl Clock {
    pub(super) const fn at(hour: u8, minute: u8) -> Clock {
        Clock { hour, minute, second: 0, day_offset: 0 }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum DateSpec {
    #[serde(rename_all = "camelCase")]
    Absolute { year: i32, month: u8, day: u8 },
    /// 没写年：宿主取「最近的将来」那一年（今天之后第一个这个月日）。
    #[serde(rename_all = "camelCase")]
    MonthDay { month: u8, day: u8 },
    #[serde(rename_all = "camelCase")]
    Offset { days: i8 },
    /// 星期：`week` 是 this / next / last，None = 从今天起下一个这个星期几（今天就是也算今天）。
    #[serde(rename_all = "camelCase")]
    Weekday { weekday: u8, week: Option<&'static str> },
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ZoneRef {
    /// 随夏令时走的地区时间（ET、Central、北京时间、Berlin time）。
    #[serde(rename_all = "camelCase")]
    Region { iana: String },
    /// 固定偏移（UTC+8、PST = UTC−8、+05:30）。`region` 是这个缩写所指的地区（夏令时期间写了标准时间缩写时，宿主提示）。
    #[serde(rename_all = "camelCase")]
    Fixed { minutes: i32, region: Option<String> },
    /// 候选：`reason` 是 abbreviation（IST / CST / BST）、country（一国几个时区）、city（同名城市），
    /// 或 sentence（句中有位置线索的建议地点）、nearby（同分句前置地点，最后为本机）。
    /// 候选按常见程度排，宿主可按用户自己的地点改排。
    #[serde(rename_all = "camelCase")]
    Options { reason: &'static str, options: Vec<ZoneRef> },
    /// 城市索引认出来的地点。`population` 由匹配的伴随文件提供，没有时留空。
    #[serde(rename_all = "camelCase")]
    #[cfg_attr(feature = "intents-only", allow(dead_code))] // 快捷指令进程没有城市索引，只有测试会造
    City {
        city_index: usize,
        name: String,
        iana: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        population: Option<u64>,
    },
    /// 没有城市索引（快捷指令进程）时原样交给宿主。
    #[serde(rename_all = "camelCase")]
    Place { query: String },
    /// 「本地时间 / my time / 我这边」：本机时区，由宿主填。
    Local,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Part {
    /// date | time | end | duration | zone | place | target | instant。place 是句中建议地点的原文跨度。
    pub kind: &'static str,
    pub span: [usize; 2],
}

/// 同一段字的另一种读法（宿主放进「按哪种理解」菜单）。
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Alternative {
    /// 「10/3」另一种顺序。
    #[serde(rename_all = "camelCase")]
    DateOrder { date: DateSpec },
    /// 读成了钟点（「15.03」），也可能是这个日期。
    #[serde(rename_all = "camelCase")]
    DotDate { date: DateSpec },
    /// 另一种钟点读法：点号日期也可读成钟点，或小时没写上下午。旧的标签保持兼容。
    #[serde(rename_all = "camelCase")]
    DotClock { time: Clock },
}

/// 有明确线索却查不到的地名。
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Unresolved {
    pub text: String,
    pub span: [usize; 2],
    /// place | target。
    pub role: &'static str,
}

/// 读到了、但写得不成立的一段：这一处不算读成（宿主不换算它，说出哪一段不对），同一段文字里别的几处照常。
/// 此前不成立的部分被悄悄丢掉、照常换算（「2026-02-30 09:00 UTC」成了今天 9:00）。
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Issue {
    /// invalidDate（2026-02-30、13 月）| invalidTime（25:61、10:20:99）| invalidOffset（UTC+99）。
    pub kind: &'static str,
    pub text: String,
    pub span: [usize; 2],
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Mention {
    pub span: [usize; 2],
    pub parts: Vec<Part>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub date: Option<DateSpec>,
    /// 没写日期，沿用了前一处的（同一段落里往后沿用）。
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub date_inherited: bool,
    /// 沿用的日期来自第几处（`Output::mentions` 的下标）：宿主改了那一处的读法（「10/3」换成 3 月 10 日），沿用它的跟着变。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub date_from: Option<usize>,
    /// None = 只有日期（宿主列出、灰、不可选）。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub time: Option<Clock>,
    /// 钟点不是写出来的：`aoe`（AoE 截止默认 23:59）、`eod`（下班前，默认 17:00）、`dayend`（今天之内 23:59）、`midnight`（午夜前 23:59）。
    /// `before_noon` 是中文「中午前」给出的截止钟点 12:00；单独的中午仍是确切钟点。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub time_implied: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end: Option<Clock>,
    /// 「持续两小时」「for 90 minutes」；有起点没终点时宿主据此算终点。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_minutes: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub relative_minutes: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub instant: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<ZoneRef>,
    /// ISO country identity for a sentence suggestion whose display name is a country.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sentence_place_country: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<ZoneRef>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub alternatives: Vec<Alternative>,
    /// 有线索却查不到的地名（没有索引时由宿主查）。
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub unresolved: Vec<Unresolved>,
    /// 写得不成立的部分；非空时这一处不算读成。
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub issues: Vec<Issue>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub language: Option<&'static str>,
    /// 等价组：同一行里只隔着分隔符或连接词的几处同一个号（宿主只在同一组、不同时区之间核对是不是同一时刻）。
    pub group: usize,
    /// 同一串日子共享钟点；编号是整串第一处在输出中的下标。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub series: Option<usize>,
}

impl Mention {
    pub(super) fn empty(span: [usize; 2]) -> Mention {
        Mention {
            span,
            parts: Vec::new(),
            date: None,
            date_inherited: false,
            date_from: None,
            time: None,
            time_implied: None,
            end: None,
            duration_minutes: None,
            relative_minutes: None,
            instant: None,
            source: None,
            sentence_place_country: None,
            target: None,
            alternatives: Vec::new(),
            unresolved: Vec::new(),
            issues: Vec::new(),
            language: None,
            group: 0,
            series: None,
        }
    }
}

/// 写这句话的人说自己在哪儿（I'm in Berlin、我在上海、東京にいます）：整段只报第一个成立的说法；
/// 宿主拿它填「本地时间 / my time / 我这边」那类 `ZoneRef::Local` 的底。
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Writer {
    pub place: ZoneRef,
    /// 说法（cue 与地名）在原文里的位置（UTF-16）。
    pub span: [usize; 2],
}

/// `understand.parse` 的返回。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Output {
    pub mentions: Vec<Mention>,
    /// 文字太长只读了前面一截：读到的位置（原文的 UTF-16 下标）。宿主要说出来（「只读了前 N 字」），不悄悄截。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub truncated_at: Option<usize>,
    /// 这段文字命中的语言（按命中次数从多到少）。
    pub languages: Vec<&'static str>,
    /// 写这句话的人说自己在哪儿；没有说法就不给。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub writer: Option<Writer>,
}
