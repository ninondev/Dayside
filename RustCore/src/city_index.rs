// SPDX-License-Identifier: GPL-3.0-only
//! Owns the read-only TTCITY12 mapping. All file-derived offsets pass through
//! checked slices; the only unsafe operation is the OS read-only mmap itself.
//!
//! TTCITY12在 TTCITY11 上再去掉两处指针，读取端仍是 mmap 按需触页：
//! - 城市记录 11 字节列式（段 0：长度 1 B、打包字段 4 B、纬度 i24 × 40000、经度 i24 × 40000，
//!   末尾每 256 条一个 u32 基址）：城市名按记录顺序连续放在文本池开头，偏移 = 基址 + 本组前面各名长度之和。
//!   打包字段：行政区 12 位、时区 9 位、国家 8 位、文本表号 3 位。
//! - 文本池里的每条字符串按其文种用一张静态符号表（`fsst.rs`）编码；表号 0 = 原样字节。
//! - 本地化条目是每语言一条按城市序的字节流（`ttcity.rs` 有格式）：城市号 varint（组首绝对、其余差分）、
//!   长度、表号；字符串顺着文本游标写、重复的写成转义引用；每 64 条一个 9 B 稀疏索引项供二分。
//! - 搜索键仍按 `KEY_BLOCK` 一块前缀编码：段 1 每块一条 6 字节表项（u24 文本偏移、u24 首个倒排下标）
//!   加哨兵；段 2 每块以一个键表号字节开头，块首键整存（`len, bytes, count`，len / count 为「小字段」：
//!   一个字节，255 及以上为 `0xff` + u16），其余每键一个头字节 `h`：高 4 位共享前缀长（15 = 后跟小字段），
//!   低 4 位编码后后缀长（1–14 直接给出且倒排数为 1；15 = 后跟小字段长度、倒排数 1；0 = 后跟小字段
//!   长度与小字段倒排数），然后是用块表号那张表编码的后缀。
//! - 倒排 3 字节（bit 23 = 主名命中，低 23 位 = 城市下标）；本地化条目 8 字节（u24 键、u24 文本偏移、
//!   u8 编码后长度、u8 表号）。
//! - 段 19：符号表，u8 张数（恰好 `TABLE_COUNT`），文本表在前、键表在后，每类文种一张。
use crate::fsst;
use crate::ttcity::{self, COORDINATE_SCALE, KEY_BLOCK, SCRIPT_CLASSES, TABLE_COUNT};
use memmap2::{Mmap, MmapOptions};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    fs::File,
    path::Path,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex, OnceLock,
    },
};

#[cfg(test)]
pub(crate) mod test_work {
    use std::cell::Cell;

    #[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
    pub(crate) struct Work {
        pub exact_queries: usize,
        pub postings: usize,
        pub records: usize,
        pub localized_queries: usize,
        pub localized_entries: usize,
    }

    thread_local! {
        static WORK: Cell<Work> = Cell::new(Work::default());
    }

    pub(crate) fn reset() {
        WORK.set(Work::default());
    }

    pub(crate) fn snapshot() -> Work {
        WORK.get()
    }

    pub(super) fn add(update: impl FnOnce(&mut Work)) {
        WORK.with(|counter| {
            let mut work = counter.get();
            update(&mut work);
            counter.set(work);
        });
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CityRecord {
    pub name: String,
    pub region: String,
    pub admin_index: i64,
    pub country_code: String,
    #[serde(rename = "timezoneID")]
    pub timezone_id: String,
    pub latitude: f64,
    pub longitude: f64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Entry {
    pub index: usize,
    pub record: CityRecord,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Hit {
    pub city_index: usize,
    pub tier: usize,
}
impl Hit {
    /// Multiplicative score: popularity rank times a tier weight (exact primary, prefix primary,
    /// exact secondary, prefix secondary). With one or two characters a prefix match is almost no
    /// evidence while an exact secondary name is (빈 is Vienna in Korean, BH is Belo Horizonte), so
    /// short queries weigh an exact secondary match like a primary prefix instead of four times worse.
    fn rank(&self, short: bool) -> usize {
        let weights = if short { [1, 3, 3, 40] } else { [1, 3, 12, 40] };
        (self.city_index + 1) * weights[self.tier]
    }
}

#[derive(Debug)]
struct Layout {
    counts: [usize; 6],
    sections: [usize; 21],
}
fn u32_at(data: &[u8], offset: usize) -> Option<u32> {
    Some(u32::from_le_bytes(
        data.get(offset..offset.checked_add(4)?)?.try_into().ok()?,
    ))
}
fn u16_at(data: &[u8], offset: usize) -> Option<u16> {
    Some(u16::from_le_bytes(
        data.get(offset..offset.checked_add(2)?)?.try_into().ok()?,
    ))
}
/// Small field of the key text: one byte below 255, otherwise `0xff` + u16. Advances `at`.
fn small_at(data: &[u8], at: &mut usize) -> Option<usize> {
    let first = *data.get(*at)? as usize;
    *at += 1;
    if first != 0xff {
        return Some(first);
    }
    let value = u16_at(data, *at)? as usize;
    *at += 2;
    Some(value)
}
fn u24_at(data: &[u8], offset: usize) -> Option<u32> {
    let b = data.get(offset..offset.checked_add(3)?)?;
    Some(u32::from_le_bytes([b[0], b[1], b[2], 0]))
}
/// 有符号 24 位（补码，小端）。
fn i24_at(data: &[u8], offset: usize) -> Option<i32> {
    let raw = u24_at(data, offset)? as i32;
    Some(if raw >= 0x80_0000 { raw - 0x100_0000 } else { raw })
}
impl Layout {
    fn read(data: &[u8]) -> Result<Self, String> {
        if data.len() <= 128 || data.get(..8) != Some(ttcity::MAGIC) {
            return Err("invalid TTCITY12 header".into());
        }
        let mut counts = [0; 6];
        for (i, count) in counts.iter_mut().enumerate() {
            *count = u32_at(data, 12 + i * 4).ok_or("truncated count")? as usize;
        }
        let mut sections = [0; 21];
        for (i, section) in sections.iter_mut().take(20).enumerate() {
            *section = u32_at(data, 36 + i * 4).ok_or("truncated section")? as usize;
        }
        sections[20] = data.len();
        if sections[0] < 128 || sections.windows(2).any(|p| p[0] > p[1]) {
            return Err("invalid section bounds".into());
        }
        let l = Self { counts, sections };
        // Fixed-size table extents, including the terminal key sentinel. No full
        // scan is necessary: variable entries are checked only when accessed.
        if counts[0] >= ttcity::POSTING_LIMIT {
            return Err("city count exceeds the record number width".into());
        }
        for (section, count, stride) in [
            (0, ttcity::city_blob_len(counts[0]), 1),
            (
                1,
                counts[1]
                    .div_ceil(KEY_BLOCK)
                    .checked_add(1)
                    .ok_or("key count overflow")?,
                6,
            ),
            (5, counts[2], 6),
            (7, counts[3], 6),
            (9, counts[2], 4),
            (10, counts[3], 32),
            (11, counts[4], ttcity::LOCALIZED_RANGE),
            (13, counts[4], 6),
            (15, counts[5], 6),
            (17, counts[4], ttcity::LOCALIZED_RANGE),
        ] {
            let required = count.checked_mul(stride).ok_or("table size overflow")?;
            if required > sections[section + 1] - sections[section] {
                return Err("truncated fixed table".into());
            }
        }
        // 每语言的流与稀疏索引都得落在自己的段里（流的内容按需触页时再逐字节检查）。
        for section in [11, 17] {
            let entry_len = sections[section + 2] - sections[section + 1];
            for slot in 0..counts[4] {
                let at = sections[section] + slot * ttcity::LOCALIZED_RANGE;
                let field = |k: usize| u32_at(data, at + k * 4).ok_or("truncated language range").map(|v| v as usize);
                let (start, len, index, count) = (field(0)?, field(1)?, field(2)?, field(3)?);
                if start.checked_add(len).is_none_or(|end| end > entry_len)
                    || index
                        .checked_add(ttcity::localized_index_len(count))
                        .is_none_or(|end| end > entry_len)
                {
                    return Err("invalid localization range".into());
                }
            }
        }
        Ok(l)
    }
    fn slice<'a>(
        &self,
        data: &'a [u8],
        section: usize,
        offset: usize,
        length: usize,
    ) -> Option<&'a [u8]> {
        let start = self.sections[section].checked_add(offset)?;
        let end = start.checked_add(length)?;
        if end > self.sections[section + 1] {
            return None;
        }
        data.get(start..end)
    }
}

/// Upper bound on hits per query: the panel shows six rows, intents ask for a handful.
pub const MAX_SEARCH_HITS: usize = 200;

/// The generator's administrative-unit table, shared so query-time suffix stripping and
/// display-name tail rules never diverge.
#[allow(dead_code)]
#[path = "index_builder_rules.rs"]
pub(crate) mod rules;

/// Query-only expansions for abbreviations people type but GeoNames stores nowhere useful.
/// They never change a display name; they only decide which city answers first for a
/// two- or three-letter query that would otherwise be won by whoever sorts first by population.
const SEARCH_ALIASES: &[(&str, &str)] = &[
    ("sf", "san francisco"),
    ("la", "los angeles"),
    ("ny", "new york city"),
    ("nyc", "new york city"),
    ("dc", "washington"),
    ("hk", "hong kong"),
    ("sg", "singapore"),
    ("kl", "kuala lumpur"),
    ("bkk", "bangkok"),
    ("cdmx", "mexico city"),
    ("jhb", "johannesburg"),
    ("blr", "bengaluru"),
    ("hcmc", "ho chi minh city"),
];

/// Sequential decoder over the front-coded key text. After `advance` returns
/// `Some(true)`, `key` holds the current key, `posting` its first posting index
/// and `count` its posting count. Every read goes through checked slices; any
/// inconsistency ends the walk with `None` instead of trusting the bytes.
struct KeyCursor<'a> {
    index: &'a CityIndex,
    block: usize,
    slot: usize,
    at: usize,
    end: usize,
    posting: usize,
    count: usize,
    key: Vec<u8>,
    /// 本块的键表号（块文本的第一个字节），0 = 后缀原样。
    class: u8,
}
impl KeyCursor<'_> {
    fn advance(&mut self) -> Option<bool> {
        if self.count != 0 || self.slot != 0 {
            self.posting = self.posting.checked_add(self.count)?;
        }
        if self.slot == KEY_BLOCK || self.at >= self.end {
            if self.at != self.end {
                return None;
            }
            let next = self.block + 1;
            if next >= self.index.blocks() {
                return Some(false);
            }
            let (at, posting) = self.index.block_entry(next)?;
            let (end, _) = self.index.block_entry(next + 1)?;
            if at != self.at || posting != self.posting {
                return None;
            }
            self.block = next;
            self.slot = 0;
            self.end = end;
        }
        let bytes = self.index.slice(2, self.at, self.end - self.at)?;
        let mut at = 0;
        if self.slot == 0 {
            self.class = *bytes.first()?;
            if self.class as usize > SCRIPT_CLASSES {
                return None;
            }
            at += 1;
            let len = small_at(bytes, &mut at)?;
            self.key.clear();
            self.key
                .extend_from_slice(bytes.get(at..at.checked_add(len)?)?);
            at += len;
            self.count = small_at(bytes, &mut at)?;
        } else {
            let head = *bytes.get(at)?;
            at += 1;
            let lcp = match head >> 4 {
                15 => small_at(bytes, &mut at)?,
                v => v as usize,
            };
            let (len, count) = match head & 15 {
                0 => {
                    let len = small_at(bytes, &mut at)?;
                    (len, small_at(bytes, &mut at)?)
                }
                15 => (small_at(bytes, &mut at)?, 1),
                v => (v as usize, 1),
            };
            if lcp > self.key.len() {
                return None;
            }
            self.key.truncate(lcp);
            let coded = bytes.get(at..at.checked_add(len)?)?;
            self.index.decode(SCRIPT_CLASSES, self.class, coded, &mut self.key)?;
            at += len;
            self.count = count;
        }
        self.at += at;
        self.slot += 1;
        Some(true)
    }
}

pub struct CityIndex {
    data: Mmap,
    population_data: Option<Mmap>,
    layout: Layout,
    timezone_lookup: HashMap<String, usize>,
    country_lookup: HashMap<String, usize>,
    /// 段 19 的符号表：前 `SCRIPT_CLASSES` 张给文本池，后 `SCRIPT_CLASSES` 张给搜索键后缀。
    tables: Vec<fsst::Table>,
}

fn map_file(file: &File) -> Result<Mmap, String> {
    if !file.metadata().map_err(|e| e.to_string())?.is_file() {
        return Err("index is not a regular file".into());
    }
    // 安全：文件只读映射，句柄持有映射，所有访问经过边界检查。
    unsafe { MmapOptions::new().map(file) }.map_err(|e| e.to_string())
}

fn open_population(path: &str, index_header: &[u8], count: usize) -> Option<Mmap> {
    let fingerprint = index_header.get(ttcity::FINGERPRINT_OFFSET..ttcity::FINGERPRINT_OFFSET + ttcity::FINGERPRINT_LEN)?;
    if fingerprint.iter().all(|byte| *byte == 0) {
        return None;
    }
    let file = File::open(Path::new(path).with_extension("ttpop")).ok()?;
    let data = map_file(&file).ok()?;
    if data.len() != ttcity::POP_HEADER.checked_add(count)?
        || data.get(..4) != Some(ttcity::POP_MAGIC)
        || u32_at(&data, 4)? != ttcity::POP_VERSION
        || u32_at(&data, 8)? as usize != count
        || data.get(12..ttcity::POP_HEADER)? != fingerprint
    {
        return None;
    }
    Some(data)
}
/// 拼音检索表。
/// 每行「拼音 \t 首字母 \t 城市主名 \t 国家码 \t 中文名」，由 `Tools/make_pinyin_table.swift`
/// 用系统 ICU 的中文转写从索引里前 1,000 座城市的中文名生成（834 行——剩下的城市索引里没有中文名）。
/// 这是**查询侧**的表：只决定「输入 bj / beijing / niuyue 时该找哪座城」，
/// 既不进索引、也不改显示名。表里有外国城市（紐約 → niuyue、倫敦 → lundun），
/// 中文用户按中文名的拼音打字时同样找得到。
const PINYIN_KEYS: &str = include_str!("../data/pinyin_keys.tsv");

/// 查询是不是「可能是拼音」：只有 ASCII 小写字母、两到十六个。
fn looks_like_pinyin(query: &str) -> bool {
    (2..=16).contains(&query.chars().count())
        && query.bytes().all(|byte| byte.is_ascii_lowercase())
}

/// 按拼音或首字母精确命中的城市（主名、国家码），顺序同表（表按拼音排序，重名由调用方按人口再排）。
fn pinyin_candidates(query: &str) -> Vec<(&'static str, &'static str)> {
    let mut out: Vec<(&'static str, &'static str)> = Vec::new();
    for line in PINYIN_KEYS.lines() {
        if line.starts_with('#') || line.is_empty() {
            continue;
        }
        let mut parts = line.split('\t');
        let Some(full) = parts.next() else { continue };
        let Some(initials) = parts.next() else { continue };
        let Some(name) = parts.next() else { continue };
        let Some(country) = parts.next() else { continue };
        if full == query || initials == query {
            out.push((name, country));
        }
    }
    out
}

// 拼音表指向现主名，查询沿用旧主名键以保留原来的命中档位。
fn pinyin_search_key(name: &str, country: &str) -> String {
    let spelling = rules::PRIMARY_NAME_ERRATA.iter()
        .find(|(_, code, new)| *code == country && *new == name)
        .map(|(old, _, _)| *old).unwrap_or(name);
    crate::catalog::fold(spelling)
}

impl CityIndex {
    pub fn open(path: &str) -> Result<Self, String> {
        let file = File::open(path).map_err(|e| e.to_string())?;
        let data = map_file(&file)?;
        let layout = Layout::read(&data)?;
        let population_data = open_population(path, &data[..ttcity::HEADER], layout.counts[0]);
        let tables = {
            let bytes = layout
                .slice(&data, 19, 0, layout.sections[20] - layout.sections[19])
                .ok_or("truncated symbol tables")?;
            let mut at = 0;
            if bytes.first().copied() != Some(TABLE_COUNT as u8) {
                return Err("invalid symbol table count".into());
            }
            at += 1;
            let mut tables = Vec::with_capacity(TABLE_COUNT);
            for _ in 0..TABLE_COUNT {
                tables.push(fsst::Table::parse(bytes, &mut at).ok_or("invalid symbol table")?);
            }
            tables
        };
        let mut index = Self {
            data,
            population_data,
            layout,
            timezone_lookup: HashMap::new(),
            country_lookup: HashMap::new(),
            tables,
        };
        for i in 0..index.layout.counts[2] {
            let name = index
                .string(5, 6, i, index.layout.counts[2])
                .ok_or("invalid timezone table")?;
            if !name.is_empty() {
                index.timezone_lookup.insert(name, i);
            }
        }
        for i in 0..index.layout.counts[3] {
            let name = index
                .string(7, 8, i, index.layout.counts[3])
                .ok_or("invalid country table")?;
            if !name.is_empty() {
                index.country_lookup.insert(name, i);
            }
        }
        Ok(index)
    }
    pub fn city_count(&self) -> usize {
        self.layout.counts[0]
    }
    /// 人口按对数桶近似还原；零桶表示未知。
    pub fn population(&self, city_index: usize) -> Option<u64> {
        if city_index >= self.city_count() {
            return None;
        }
        let bucket = *self.population_data.as_ref()?.get(ttcity::POP_HEADER.checked_add(city_index)?)?;
        (bucket != 0).then(|| 1.1f64.powi(i32::from(bucket)).round() as u64)
    }
    fn slice(&self, section: usize, offset: usize, length: usize) -> Option<&[u8]> {
        self.layout.slice(&self.data, section, offset, length)
    }
    fn word(&self, section: usize, offset: usize) -> Option<u32> {
        u32_at(self.slice(section, offset, 4)?, 0)
    }
    fn u24(&self, section: usize, offset: usize) -> Option<u32> {
        u24_at(self.slice(section, offset, 3)?, 0)
    }
    fn i24(&self, section: usize, offset: usize) -> Option<i32> {
        i24_at(self.slice(section, offset, 3)?, 0)
    }
    /// 第 k 条倒排：20 位一条（19 位记录号 + 主名标志），读一个整字再移位；返回 (记录号, 是否主名)。
    fn posting(&self, k: usize) -> Option<(usize, bool)> {
        let bit = k.checked_mul(ttcity::POSTING_BITS)?;
        let word = self.word(3, bit / 8)?;
        let coded = (word >> (bit % 8)) & ((1 << ttcity::POSTING_BITS) - 1);
        Some(((coded & (ttcity::POSTING_PRIMARY - 1)) as usize, coded & ttcity::POSTING_PRIMARY != 0))
    }
    /// 把一段编码字节按表号解到 `out` 末尾：0 原样；1…`SCRIPT_CLASSES` 用 `tables[base + class - 1]`。
    fn decode(&self, base: usize, class: u8, coded: &[u8], out: &mut Vec<u8>) -> Option<()> {
        match class as usize {
            0 => {
                out.extend_from_slice(coded);
                Some(())
            }
            c if c <= SCRIPT_CLASSES => self.tables.get(base + c - 1)?.decode(coded, out),
            _ => None,
        }
    }
    /// 文本池里的一条字符串（`length` 是编码后的字节数）。
    fn text(&self, offset: usize, length: usize, class: u8) -> Option<String> {
        let mut raw = Vec::with_capacity(length * 2);
        self.decode(0, class, self.slice(4, offset, length)?, &mut raw)?;
        Some(String::from_utf8_lossy(&raw).into_owned())
    }
    fn string(&self, entries: usize, blob: usize, index: usize, count: usize) -> Option<String> {
        if index >= count {
            return None;
        }
        let e = self.slice(entries, index.checked_mul(6)?, 6)?;
        Some(
            String::from_utf8_lossy(self.slice(
                blob,
                u32_at(e, 0)? as usize,
                u16_at(e, 4)? as usize,
            )?)
            .into_owned(),
        )
    }
    /// 城市名在文本池里的（偏移, 编码后长度）：基址 + 本组前面各名的长度之和（最多 255 次加法，纳秒级）。
    fn name_span(&self, index: usize) -> Option<(usize, usize)> {
        let columns = ttcity::record_columns(self.city_count());
        let group = index / ttcity::CITY_BASE_GROUP;
        let first = group * ttcity::CITY_BASE_GROUP;
        let base = self.word(0, columns[4] + group * 4)? as usize;
        let lens = self.slice(0, columns[0] + first, index - first + 1)?;
        let before: usize = lens[..index - first].iter().map(|l| *l as usize).sum();
        Some((base + before, lens[index - first] as usize))
    }
    pub fn city(&self, index: usize) -> Option<CityRecord> {
        #[cfg(test)]
        test_work::add(|work| work.records += 1);
        if index >= self.city_count() {
            return None;
        }
        // 列式记录（TTCITY12）：五列各取一次。
        let columns = ttcity::record_columns(self.city_count());
        let (offset, length) = self.name_span(index)?;
        let (admin, timezone, country, class) = ttcity::unpack_fields(self.word(0, columns[1] + index * 4)?);
        let latitude = self.i24(0, columns[2] + index * 3)? as f64 / COORDINATE_SCALE;
        let longitude = self.i24(0, columns[3] + index * 3)? as f64 / COORDINATE_SCALE;
        Some(CityRecord {
            name: self.text(offset, length, class)?,
            region: if admin == ttcity::ADMIN_NONE {
                String::new()
            } else {
                self.string(15, 16, admin, self.layout.counts[5])
                    .unwrap_or_default()
            },
            admin_index: if admin == ttcity::ADMIN_NONE { -1 } else { admin as i64 },
            country_code: self
                .string(7, 8, country, self.layout.counts[3])
                .unwrap_or_default(),
            timezone_id: self
                .string(5, 6, timezone, self.layout.counts[2])
                .unwrap_or_default(),
            latitude,
            longitude,
        })
    }
    pub fn timezone(&self, index: usize) -> String {
        if index >= self.city_count() {
            return String::new();
        }
        let columns = ttcity::record_columns(self.city_count());
        self.word(0, columns[1] + index * 4)
            .map(|packed| ttcity::unpack_fields(packed).1)
            .and_then(|i| self.string(5, 6, i, self.layout.counts[2]))
            .unwrap_or_default()
    }
    pub fn representative(&self, id: &str) -> Option<Entry> {
        let ti = *self.timezone_lookup.get(id)?;
        let i = self.word(9, ti * 4)? as usize;
        Some(Entry {
            index: i,
            record: self.city(i)?,
        })
    }
    pub fn top(&self, country: &str, limit: usize) -> Vec<Entry> {
        let Some(ci) = self.country_lookup.get(country) else {
            return vec![];
        };
        (0..limit.min(8))
            .map_while(|slot| {
                let i = self.word(10, (ci * 8 + slot) * 4)? as usize;
                Some(Entry {
                    index: i,
                    record: self.city(i)?,
                })
            })
            .collect()
    }
    /// 地图上某一点附近是哪座城：只看人口前 `limit` 座（记录按人口
    /// 从多到少排，前 `limit` 条就是「够有名的城市」），每座城有一块「势力范围」：半径 = `radius` × 权重，
    /// 权重 = 1 + log10(`limit` / 名次)（第一名约 4.8 倍、第 `limit` 名 1 倍），按「距离 ÷ 权重」取最小的那座，
    /// 超出所有范围就不答。大城市从更远处就能指到（指在东京旁边 10 pt 还是东京），但指针正对着一座小城时
    /// 仍然是它（正对天津是天津，不被北京抢走；正对京都是京都，不是大阪）。
    /// 距离是**地图平面上的**（等距柱状投影，经纬度各按度算、经度不按纬度缩），因为问的是「指针下面那个点是谁」；
    /// 跨日界线取短的那边。指针本身有精度：`radius` / 6 以内（`radius` = 3 pt 时是半个点）的距离算作一样，
    /// 同一个像素里的两座城让大的那座答（正对新德里的坐标答德里，两者相距 0.05°）。
    /// 只回答「那座城和它的钟」，不回答「指针所在那一点属于哪个时区」：边界附近那是两回事。
    pub fn nearest(&self, latitude: f64, longitude: f64, radius: f64, limit: usize) -> Option<Entry> {
        if !latitude.is_finite() || !longitude.is_finite() || !radius.is_finite() || radius <= 0.0 {
            return None;
        }
        let radius = radius.min(180.0);
        let count = limit.min(self.city_count());
        let weight = |rank: usize| 1.0 + (count as f64 / (rank + 1) as f64).log10();
        let reach = radius * weight(0);
        let precision = radius / 6.0;
        let columns = ttcity::record_columns(self.city_count());
        let mut best: Option<(f64, usize)> = None;
        for i in 0..count {
            let lat = self.i24(0, columns[2] + i * 3)? as f64 / COORDINATE_SCALE;
            let dlat = lat - latitude;
            if dlat.abs() > reach {
                continue;
            }
            let lon = self.i24(0, columns[3] + i * 3)? as f64 / COORDINATE_SCALE;
            let dlon = (lon - longitude).rem_euclid(360.0);
            let dlon = dlon.min(360.0 - dlon);
            let score = (dlat * dlat + dlon * dlon).sqrt().max(precision) / weight(i);
            if score <= radius && best.is_none_or(|(b, _)| score < b) {
                best = Some((score, i));
            }
        }
        let (_, index) = best?;
        Some(Entry {
            index,
            record: self.city(index)?,
        })
    }
    /// 某语言流里这座城市的名字：稀疏索引按组首城市号二分到组，再顺着流解到它（≤ 64 条，每条几个字节）。
    fn localized(&self, ranges: usize, entries: usize, slot: usize, key: usize) -> Option<String> {
        #[cfg(test)]
        test_work::add(|work| work.localized_queries += 1);
        let at = slot * ttcity::LOCALIZED_RANGE;
        let field = |k: usize| self.word(ranges, at + k * 4).map(|v| v as usize);
        let (start, len, index_at, count) = (field(0)?, field(1)?, field(2)?, field(3)?);
        if count == 0 {
            return None;
        }
        let groups = count.div_ceil(ttcity::LOCALIZED_GROUP);
        let index = self.slice(entries, index_at, groups * ttcity::LOCALIZED_INDEX_ENTRY)?;
        // 最后一个组首城市号 ≤ key 的组。
        let (mut lo, mut hi) = (0usize, groups);
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            if u24_at(index, mid * ttcity::LOCALIZED_INDEX_ENTRY)? as usize <= key {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if lo == 0 {
            return None;
        }
        let group = lo - 1;
        let stream = self.slice(entries, start, len)?;
        let mut pos = u24_at(index, group * ttcity::LOCALIZED_INDEX_ENTRY + 3)? as usize;
        let mut cursor = u24_at(index, group * ttcity::LOCALIZED_INDEX_ENTRY + 6)? as usize;
        let mut previous = 0usize;
        let remaining = (count - group * ttcity::LOCALIZED_GROUP).min(ttcity::LOCALIZED_GROUP);
        for k in 0..remaining {
            #[cfg(test)]
            test_work::add(|work| work.localized_entries += 1);
            let city = if k == 0 {
                ttcity::read_varint(stream, &mut pos)?
            } else {
                previous + ttcity::read_varint(stream, &mut pos)? + 1
            };
            previous = city;
            let length = *stream.get(pos)? as usize;
            pos += 1;
            let (offset, length) = if length == 0 {
                let escaped = stream.get(pos..pos + 4)?;
                pos += 4;
                (u24_at(escaped, 0)? as usize, escaped[3] as usize)
            } else {
                cursor += length;
                (cursor - length, length)
            };
            let class = *stream.get(pos)?;
            pos += 1;
            if city == key {
                return self.text(offset, length, class).filter(|v| !v.is_empty());
            }
            if city > key {
                return None;
            }
        }
        None
    }
    pub fn names(&self, key: usize, region: bool) -> HashMap<String, String> {
        let mut names = HashMap::new();
        if key >= self.layout.counts[if region { 5 } else { 0 }] {
            return names;
        }
        let (ranges, entries) = if region { (17, 18) } else { (11, 12) };
        for slot in 0..self.layout.counts[4] {
            let Some(value) = self.localized(ranges, entries, slot, key) else {
                continue;
            };
            if let Some(code) = self.string(13, 14, slot, self.layout.counts[4]) {
                if !code.is_empty() {
                    names.insert(code, value);
                }
            }
        }
        names
    }
    /// 只解码英文与指定语言的显示名；同语言重复条目沿用最后一条。
    pub(crate) fn nearby_name_matches(&self, key: usize, language: &str, matches: impl Fn(&str) -> bool) -> bool {
        if key >= self.city_count() { return false; }
        // 封闭勘误表中的旧主名继续按原来的完整地名识别。
        if let Some(city) = self.city(key) {
            if rules::PRIMARY_NAME_ERRATA.iter().any(|(old, country, new)|
                city.name == *new && city.country_code == *country && matches(old)) { return true; }
        }
        let mut seen = Vec::new();
        for slot in (0..self.layout.counts[4]).rev() {
            let Some(code) = self.string(13, 14, slot, self.layout.counts[4]) else { continue; };
            let own = code == language || language == "zh" && code.starts_with("zh-")
                || code.split(['-', '_']).next() == Some(language)
                && !language.starts_with("zh");
            if !(code == "en" || own) || seen.contains(&code) { continue; }
            let Some(name) = self.localized(11, 12, slot, key) else { continue; };
            seen.push(code);
            if matches(&name) { return true; }
        }
        false
    }
    /// 显示名逐项检查，命中就停；重复语言沿用最后一条有效名字。
    pub(crate) fn any_name_matches(&self, key: usize, matches: impl Fn(&str) -> bool) -> bool {
        if key >= self.city_count() {
            return false;
        }
        let mut seen = std::collections::HashSet::new();
        for slot in (0..self.layout.counts[4]).rev() {
            let Some(code) = self.string(13, 14, slot, self.layout.counts[4]).filter(|code| !code.is_empty()) else { continue };
            if seen.contains(&code) {
                continue;
            }
            let Some(name) = self.localized(11, 12, slot, key) else { continue };
            seen.insert(code);
            if matches(&name) {
                return true;
            }
        }
        false
    }
    fn blocks(&self) -> usize {
        self.layout.counts[1].div_ceil(KEY_BLOCK)
    }
    /// Block table entry: text offset of the block's first record and its first posting index.
    fn block_entry(&self, block: usize) -> Option<(usize, usize)> {
        if block > self.blocks() {
            return None;
        }
        Some((
            self.u24(1, block * 6)? as usize,
            self.u24(1, block * 6 + 3)? as usize,
        ))
    }
    /// The first key of a block is stored whole after the block's table byte: one length byte
    /// (or `0xff` + u16), then the bytes.
    fn block_first_key(&self, block: usize) -> Option<&[u8]> {
        if block >= self.blocks() {
            return None;
        }
        let (at, _) = self.block_entry(block)?;
        let head = self.slice(
            2,
            at,
            4.min(self.layout.sections[3] - self.layout.sections[2] - at),
        )?;
        let mut used = 1;
        let len = small_at(head, &mut used)?;
        self.slice(2, at + used, len)
    }
    fn cursor(&self, block: usize) -> Option<KeyCursor<'_>> {
        if block >= self.blocks() {
            return None;
        }
        let (at, posting) = self.block_entry(block)?;
        let (end, _) = self.block_entry(block + 1)?;
        Some(KeyCursor {
            index: self,
            block,
            slot: 0,
            at,
            end,
            posting,
            count: 0,
            key: Vec::with_capacity(64),
            class: 0,
        })
    }
    /// 测试按键块顺序遍历全部搜索键及其倒排范围。
    #[cfg(test)]
    fn search_keys(&self) -> impl Iterator<Item = (String, usize, usize)> + '_ {
        let mut cursor = self.cursor(0);
        std::iter::from_fn(move || {
            let current = cursor.as_mut()?;
            if current.advance()? {
                Some((String::from_utf8_lossy(&current.key).into_owned(), current.posting, current.count))
            } else {
                None
            }
        })
    }
    /// Positions a cursor on the first key that is `>= q` in sorted order, or None when
    /// every key sorts before `q` (or the table is unreadable).
    fn locate(&self, q: &[u8]) -> Option<KeyCursor<'_>> {
        let blocks = self.blocks();
        if blocks == 0 {
            return None;
        }
        // Last block whose first key is <= q; binary search over whole first keys only.
        let (mut lo, mut hi) = (0, blocks);
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            if self.block_first_key(mid)? <= q {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        let mut cursor = self.cursor(lo.saturating_sub(1))?;
        while cursor.advance()? {
            if cursor.key.as_slice() >= q {
                return Some(cursor);
            }
        }
        None
    }
}

/// 折叠后的查询里 NFD 拆不开的几个字母换成基本字母：ı → i（土耳其语）、đ → d（越南语；GeoNames 有的越南地名误用冰岛字母 ð，
/// 一并算）、ł → l（波兰语）。生成器给六种新语言的名字加搜索键时用同一张表（`index_builder::plain_letters`）。
pub fn plain_letters(folded: &str) -> String {
    folded
        .chars()
        .map(|c| match c {
            'ı' => 'i',
            'đ' | 'ð' => 'd',
            'ł' => 'l',
            c => c,
        })
        .collect()
}

impl CityIndex {
    /// 精确的键：主名或别名折叠后与查询逐字相等的城市（按人口名次，最多 `limit` 座），不做前缀、拼音与首字母的扩展。
    /// 「听懂时间」用：「bali」是巴黎的拼音，但「9am in bali」说的不是巴黎（search_smart 在这里
    /// 答了巴黎）。常用缩写（nyc、sf）照旧换成它指的城；ı / đ / ł 再按基本字母试一次（六语搜索同一条规矩）。
    pub fn exact(&self, query: &str, limit: usize) -> Vec<Hit> {
        if limit == 0 {
            return vec![];
        }
        let mut hits = self.exact_all(query);
        hits.truncate(limit.min(MAX_SEARCH_HITS));
        hits
    }

    /// 精确命中的全部城市，沿用缩写和字母回退，按索引顺序返回。
    pub fn exact_all(&self, query: &str) -> Vec<Hit> {
        if query.is_empty() {
            return vec![];
        }
        if let Some((_, expansion)) = SEARCH_ALIASES.iter().find(|(alias, _)| *alias == query) {
            return self.exact_key(expansion);
        }
        let hits = self.exact_key(query);
        let plain = plain_letters(query);
        if hits.is_empty() && plain != query {
            return self.exact_key(&plain);
        }
        hits
    }

    fn exact_key(&self, query: &str) -> Vec<Hit> {
        #[cfg(test)]
        test_work::add(|work| work.exact_queries += 1);
        let q = query.as_bytes();
        let Some(cursor) = self.locate(q) else { return vec![] };
        if cursor.key.as_slice() != q {
            return vec![];
        }
        let mut hits: Vec<Hit> = Vec::new();
        for k in 0..cursor.count {
            #[cfg(test)]
            test_work::add(|work| work.postings += 1);
            let Some((city_index, primary)) = cursor.posting.checked_add(k).and_then(|p| self.posting(p)) else { continue };
            if city_index >= self.city_count() {
                continue;
            }
            hits.push(Hit { city_index, tier: if primary { 0 } else { 2 } });
        }
        hits.sort_by_key(|h| h.city_index);
        hits.dedup_by_key(|h| h.city_index);
        hits
    }

    /// `search` plus two deterministic fallbacks: a known abbreviation answers with its city
    /// first, and a CJK query that carries an administrative suffix (东京都, 서울특별시) retries
    /// without it when the literal form finds nothing.
    pub fn search_smart(&self, query: &str, limit: usize) -> Vec<Hit> {
        if query.is_empty() || limit == 0 {
            return vec![];
        }
        if let Some((_, expansion)) = SEARCH_ALIASES.iter().find(|(alias, _)| *alias == query) {
            let mut hits = self.search(expansion, 1);
            for hit in self.search(query, limit) {
                if hits.len() >= limit {
                    break;
                }
                if !hits.iter().any(|h| h.city_index == hit.city_index) {
                    hits.push(hit);
                }
            }
            return hits;
        }
        // 土耳其语的无点 ı、越南语的 đ、波兰语的 ł 在 NFD 下不拆（ğ、ư、ó 会拆掉附加符号），打字时写了它们、索引里却只有
        // 基本字母的写法（GeoNames 的 ASCII 名「Igdir」「Da Lat」）时搜不到：再用换成基本字母的写法搜一次，接在字面结果后面
        // （「ığdır」「đà lạt」此前零结果）。
        let plain = plain_letters(query);
        if plain != query {
            let mut hits = self.search(query, limit);
            for hit in self.search(&plain, limit) {
                if hits.len() >= limit {
                    break;
                }
                if !hits.iter().any(|h| h.city_index == hit.city_index) {
                    hits.push(hit);
                }
            }
            return hits;
        }
        let hits = self.search(query, limit);
        // 拼音与首字母：查询正好是表里的拼音（niuyue）或首字母（bj）时，那几座城排在最前
        // （同一串对上几座就按人口，索引本身按人口降序），字面结果接在后面。
        // 两条都需要：「dongjing」字面能撞上一个叫 Dongjing 的小镇，而打这四个字的人要的是东京；
        // 「sz」字面会命中匈牙利语写法的 Szanghaj / Szöul，而打 sz 的人要的是深圳或苏州。
        // 表外的查询一个字都不动，排序照旧。
        // 一座城用自己的拉丁主名一定能找到自己（`stored_names_of_big_cities_find_their_city_first`
        // 钉住的性质）：所以「feicheng」这种既是费城的拼音、又是山东肥城主名的查询，字面优先，
        // 拼音的那座接在后面。不这么分的话探针会多出三条未命中（Anshan / Wanzhou / Feicheng）。
        let literal_owns_query = hits.iter().any(|hit| {
            self.city(hit.city_index)
                .is_some_and(|record| crate::catalog::fold(&record.name) == query)
        });
        if looks_like_pinyin(query) && !literal_owns_query {
            let candidates = pinyin_candidates(query);
            if !candidates.is_empty() {
                let mut by_pinyin: Vec<Hit> = Vec::new();
                for (name, country) in candidates {
                    for hit in self.search(&pinyin_search_key(name, country), 8) {
                        let matches = self.city(hit.city_index).is_some_and(|record| {
                            record.country_code == country
                                && crate::catalog::fold(&record.name) == crate::catalog::fold(name)
                        });
                        if matches {
                            if !by_pinyin.iter().any(|existing| existing.city_index == hit.city_index) {
                                by_pinyin.push(hit);
                            }
                            break;
                        }
                    }
                }
                by_pinyin.sort_by_key(|hit| hit.city_index);
                for hit in hits {
                    if by_pinyin.len() >= limit {
                        break;
                    }
                    if !by_pinyin.iter().any(|existing| existing.city_index == hit.city_index) {
                        by_pinyin.push(hit);
                    }
                }
                by_pinyin.truncate(limit);
                if !by_pinyin.is_empty() {
                    return by_pinyin;
                }
                return vec![];
            }
        }
        if !hits.is_empty() {
            // 字面拥有这个查询，但拼音表还指向别的城（「bali」是印度 Bāli 的主名，也是巴黎的拼音）：
            // 第一名留给字面那座（性质：一座城用自己的主名必须找到自己），拼音那几座紧跟其后——
            // 追加在末尾会被 5 条的上限挤掉，用户就看不见巴黎了。
            if looks_like_pinyin(query) {
                let mut by_pinyin: Vec<Hit> = Vec::new();
                for (name, country) in pinyin_candidates(query) {
                    for hit in self.search(&pinyin_search_key(name, country), 8) {
                        let matches = self.city(hit.city_index).is_some_and(|record| {
                            record.country_code == country
                                && crate::catalog::fold(&record.name) == crate::catalog::fold(name)
                        });
                        if matches {
                            if !by_pinyin.iter().any(|existing| existing.city_index == hit.city_index) {
                                by_pinyin.push(hit);
                            }
                            break;
                        }
                    }
                }
                if by_pinyin.is_empty() {
                    return hits;
                }
                by_pinyin.sort_by_key(|hit| hit.city_index);
                let mut merged: Vec<Hit> = Vec::with_capacity(limit);
                merged.push(hits[0].clone());
                for hit in by_pinyin.into_iter().chain(hits.into_iter().skip(1)) {
                    if merged.len() >= limit {
                        break;
                    }
                    if !merged.iter().any(|existing| existing.city_index == hit.city_index) {
                        merged.push(hit);
                    }
                }
                return merged;
            }
            return hits;
        }
        let mut stripped = query;
        while let Some(unit) = rules::ADMIN_UNITS
            .iter()
            .filter(|unit| stripped.len() > unit.len() && stripped.ends_with(*unit))
            .max_by_key(|unit| unit.len())
        {
            stripped = &stripped[..stripped.len() - unit.len()];
        }
        if stripped != query && !stripped.is_empty() {
            return self.search(stripped, limit);
        }
        vec![]
    }

    pub fn search(&self, query: &str, limit: usize) -> Vec<Hit> {
        if query.is_empty() || limit == 0 {
            return vec![];
        }
        // The result cannot exceed the finite city table, even with hostile input; and nobody reads
        // more than a screenful, so a hostile `limit` is capped before the O(limit) insertion below
        // turns a one-letter query into a 100 ms scan.
        let limit = limit.min(self.city_count()).min(MAX_SEARCH_HITS);
        let q = query.as_bytes();
        let short = query.chars().count() <= 2;
        let Some(mut cursor) = self.locate(q) else {
            return vec![];
        };
        let mut best: Vec<Hit> = Vec::with_capacity(limit.min(64));
        loop {
            if !cursor.key.starts_with(q) {
                break;
            }
            let exact = cursor.key.len() == q.len();
            let (start, count) = (cursor.posting, cursor.count);
            for k in 0..count.min(if exact { limit } else { 1 }) {
                let Some((city_index, primary)) = start.checked_add(k).and_then(|p| self.posting(p)) else {
                    continue;
                };
                if city_index >= self.city_count() {
                    continue;
                }
                let tier = match (exact, primary) {
                    (true, true) => 0,
                    (false, true) => 1,
                    (true, false) => 2,
                    (false, false) => 3,
                };
                let hit = Hit { city_index, tier };
                if let Some(at) = best.iter().position(|h| h.city_index == city_index) {
                    if best[at].tier <= tier {
                        continue;
                    }
                    best.remove(at);
                } else if best.len() >= limit
                    && best.last().is_some_and(|v| hit.rank(short) >= v.rank(short))
                {
                    continue;
                }
                let at = best
                    .iter()
                    .position(|v| v.rank(short) > hit.rank(short))
                    .unwrap_or(best.len());
                best.insert(at, hit);
                if best.len() > limit {
                    best.pop();
                }
            }
            if cursor.advance() != Some(true) {
                break;
            }
        }
        best
    }
}

static REGISTRY: OnceLock<Mutex<HashMap<u64, Arc<CityIndex>>>> = OnceLock::new();
static NEXT: AtomicU64 = AtomicU64::new(1);
fn registry() -> &'static Mutex<HashMap<u64, Arc<CityIndex>>> {
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}
pub fn get(handle: u64) -> Option<Arc<CityIndex>> {
    registry().lock().ok()?.get(&handle).cloned()
}
fn field<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(Value::as_str).unwrap_or("")
}
fn index(v: &Value, key: &str) -> Option<usize> {
    v.get(key)?.as_u64()?.try_into().ok()
}
pub fn dispatch(operation: &str, payload: Value) -> Result<Value, String> {
    if operation == "city.open" {
        return match CityIndex::open(field(&payload, "path")) {
            Ok(city) => {
                let count = city.city_count();
                let handle = NEXT
                    .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |v| v.checked_add(1))
                    .map_err(|_| "city handle space exhausted")?;
                registry()
                    .lock()
                    .map_err(|_| "city registry poisoned")?
                    .insert(handle, Arc::new(city));
                Ok(json!({"handle":handle,"cityCount":count}))
            }
            Err(error) => Ok(json!({"handle":null,"cityCount":0,"error":error})),
        };
    }
    let handle = payload
        .get("handle")
        .and_then(Value::as_u64)
        .ok_or("missing city handle")?;
    if operation == "city.close" {
        return Ok(json!(registry()
            .lock()
            .map_err(|_| "city registry poisoned")?
            .remove(&handle)
            .is_some()));
    }
    let city = get(handle).ok_or("invalid or released city handle")?;
    let idx = index(&payload, "index");
    let limit = index(&payload, "limit").unwrap_or(0);
    Ok(match operation {
        "city.record" => json!(idx.and_then(|i| city.city(i))),
        "city.representative" => json!(city.representative(field(&payload, "timezone"))),
        "city.top" => json!(city.top(field(&payload, "country"), limit)),
        "city.names" => json!(idx
            .map(|i| city.names(i, field(&payload, "kind") == "region"))
            .unwrap_or_default()),
        "city.timezone" => json!(idx.map(|i| city.timezone(i)).unwrap_or_default()),
        "city.nearest" => {
            let number = |key: &str| payload.get(key).and_then(Value::as_f64).unwrap_or(f64::NAN);
            json!(city.nearest(number("latitude"), number("longitude"), number("radius"), limit))
        }
        "city.search" => json!(city.search_smart(field(&payload, "query"), limit)),
        "city.coordinate_candidates" => {
            let mut out: HashMap<String, Vec<CityRecord>> = HashMap::new();
            for id in payload
                .get("identifiers")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
            {
                let records = if let Some(entry) = city.representative(id) {
                    vec![entry.record]
                } else {
                    city.search(&crate::catalog::fold(&crate::catalog::tz_city(id)), 4)
                        .into_iter()
                        .filter(|h| h.tier == 0 || h.tier == 2)
                        .filter_map(|h| city.city(h.city_index))
                        .collect()
                };
                out.insert(id.to_owned(), records);
            }
            json!(out)
        }
        _ => return Err(format!("unknown city operation: {operation}")),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    /// 随包索引；`MEANTIME_TEST_INDEX` 指定候选镜像时改开它，刚转码出的文件可以先过完读取端
    /// 全部测试再替换资源。
    fn bundled() -> CityIndex {
        let path = std::env::var("MEANTIME_TEST_INDEX").unwrap_or_else(|_| {
            concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../TahoeTime/Resources/cities.ttcity"
            )
            .to_owned()
        });
        CityIndex::open(&path).unwrap()
    }
    fn population_fixture() -> (std::path::PathBuf, Vec<u8>, Vec<u8>) {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let directory = Path::new(env!("CARGO_MANIFEST_DIR")).join("target").join(format!(
            "tt-population-reader-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("cities.ttcity");
        let fingerprint = [1u8; ttcity::FINGERPRINT_LEN];
        let mut header = vec![0; ttcity::HEADER];
        header[ttcity::FINGERPRINT_OFFSET..ttcity::FINGERPRINT_OFFSET + ttcity::FINGERPRINT_LEN].copy_from_slice(&fingerprint);
        let mut population = Vec::new();
        population.extend_from_slice(ttcity::POP_MAGIC);
        population.extend_from_slice(&ttcity::POP_VERSION.to_le_bytes());
        population.extend_from_slice(&3u32.to_le_bytes());
        population.extend_from_slice(&fingerprint);
        population.extend_from_slice(&[0, 1, 8]);
        (path, header, population)
    }
    #[test]
    fn companion_header_validation_is_silent_and_uses_no_index_body() {
        let (path, header, population) = population_fixture();
        let path_text = path.to_str().unwrap();
        assert!(open_population(path_text, &header, 3).is_none());
        std::fs::write(path.with_extension("ttpop"), &population).unwrap();
        assert!(open_population(path_text, &header, 3).is_some());
        assert!(open_population(path_text, &header, 4).is_none());
        let mut variants = Vec::new();
        for (offset, value) in [(0, b'X'), (4, 2), (8, 4), (12, 2)] {
            let mut invalid = population.clone();
            invalid[offset] = value;
            variants.push(invalid);
        }
        variants.push(population[..population.len() - 1].to_vec());
        let mut extra = population.clone();
        extra.push(0);
        variants.push(extra);
        variants.push(population[..ttcity::POP_HEADER - 1].to_vec());
        for invalid in variants {
            std::fs::write(path.with_extension("ttpop"), invalid).unwrap();
            assert!(open_population(path_text, &header, 3).is_none());
        }
        std::fs::write(path.with_extension("ttpop"), &population).unwrap();
        let mut zero_header = header.clone();
        zero_header[ttcity::FINGERPRINT_OFFSET..ttcity::FINGERPRINT_OFFSET + ttcity::FINGERPRINT_LEN].fill(0);
        assert!(open_population(path_text, &zero_header, 3).is_none());
        assert!(open_population(path_text, &header[..ttcity::FINGERPRINT_OFFSET], 3).is_none());
    }
    #[test]
    fn population_decodes_unknown_and_bounds_checked_buckets() {
        let (path, header, population) = population_fixture();
        std::fs::write(path.with_extension("ttpop"), &population).unwrap();
        let mut data = memmap2::MmapMut::map_anon(ttcity::HEADER).unwrap();
        data.copy_from_slice(&header);
        let mut index = CityIndex {
            data: data.make_read_only().unwrap(),
            population_data: open_population(path.to_str().unwrap(), &header, 3),
            layout: Layout { counts: [3, 0, 0, 0, 0, 0], sections: [ttcity::HEADER; 21] },
            timezone_lookup: HashMap::new(),
            country_lookup: HashMap::new(),
            tables: Vec::new(),
        };
        assert_eq!(index.population(0), None);
        assert_eq!(index.population(1), Some(1));
        assert_eq!(index.population(2), Some(2));
        assert_eq!(index.population(3), None);
        assert_eq!(index.population(usize::MAX), None);
        index.population_data = None;
        assert!((0..index.city_count()).all(|city_index| index.population(city_index).is_none()));
    }
    #[test]
    #[ignore]
    fn same_name_zone_audit() {
        let index = bundled();
        let (mut keys, mut max_zones, mut over8) = (0usize, 0usize, 0usize);
        let mut visited = 0;
        let mut examples = Vec::new();
        for (key, posting, count) in index.search_keys() {
            visited += 1;
            let zones: std::collections::HashSet<_> = (0..count)
                .filter_map(|offset| posting.checked_add(offset).and_then(|p| index.posting(p)))
                .filter(|(city_index, _)| *city_index < index.city_count())
                .map(|(city_index, _)| index.timezone(city_index))
                .filter(|zone| !zone.is_empty())
                .collect();
            if zones.len() >= 2 {
                keys += 1;
                max_zones = max_zones.max(zones.len());
                if zones.len() > 8 {
                    over8 += 1;
                    if examples.len() < 20 {
                        examples.push((key, zones.len()));
                    }
                }
            }
        }
        assert_eq!(visited, index.layout.counts[1]);
        println!("SAMENAME keys={keys} max_zones={max_zones} over8={over8}");
        for (key, zones) in examples {
            println!("SAMENAME-OVER {key} {zones}");
        }
    }
    /// 「指到哪儿看哪儿几点」：正对着哪座城就是哪座（名古屋、天津、京都不被人口更多的邻居抢走），同一个像素里
    /// 让大的答（新德里的坐标答德里），大城市旁边一段距离仍是它（北京以北 0.6°），大洋中间不答，跨日界线找得到另一边。
    /// 判据用另一种写法：同一批记录把经度差按 −360 / 0 / +360 三种平移各算一遍取最小（不用取余），
    /// 逐点暴力算「距离 ÷ 权重」，核「返回的就是分最低的那座且在范围内；没返回就真的没有」。
    #[test]
    fn nearest_city_is_the_one_under_the_pointer() {
        let c = bundled();
        let name = |lat: f64, lon: f64, radius: f64| c.nearest(lat, lon, radius, 6000).map(|e| e.record.name);
        assert_eq!(name(35.18, 136.91, 1.2).as_deref(), Some("Nagoya"));
        assert_eq!(name(34.69, 135.50, 1.2).as_deref(), Some("Osaka"));
        assert_eq!(name(35.02, 135.75, 1.2).as_deref(), Some("Kyoto"));
        assert_eq!(name(35.69, 139.69, 1.2).as_deref(), Some("Tokyo"));
        assert_eq!(name(39.14, 117.18, 1.2).as_deref(), Some("Tianjin"));
        assert_eq!(name(40.5, 116.4, 1.2).as_deref(), Some("Beijing"), "北京以北 0.6°");
        assert_eq!(name(48.86, 2.35, 1.2).as_deref(), Some("Paris"));
        assert_eq!(name(28.61, 77.21, 1.2).as_deref(), Some("Delhi"), "正对新德里的坐标：同一个像素里让大的答");
        assert_eq!(name(0.0, -150.0, 1.2), None, "太平洋中间");
        assert_eq!(name(f64::NAN, 0.0, 1.0), None);
        assert_eq!(name(0.0, 0.0, -1.0), None);
        assert_eq!(name(0.0, 0.0, f64::INFINITY), None);
        // 日界线：在西经 179.9° 问，答案在东经那一边（斐济），不限人口。
        let fiji = c.nearest(-16.6, -179.9, 1.5, c.city_count()).expect("斐济北岛一带有城");
        assert!(fiji.record.longitude > 178.0, "{:?}", fiji.record);
        // 独立判据：伪随机 400 个点、三种基准半径。
        let limit = 6000;
        let columns = ttcity::record_columns(c.city_count());
        let coordinate = |i: usize| {
            (
                c.i24(0, columns[2] + i * 3).unwrap() as f64 / COORDINATE_SCALE,
                c.i24(0, columns[3] + i * 3).unwrap() as f64 / COORDINATE_SCALE,
            )
        };
        let mut seed = 0x2545_F491_4F6C_DD1Du64;
        let mut next = || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            (seed >> 11) as f64 / (1u64 << 53) as f64
        };
        for _ in 0..400 {
            let (lat, lon) = (next() * 140.0 - 60.0, next() * 360.0 - 180.0);
            for radius in [0.4, 1.2, 4.0] {
                let got = c.nearest(lat, lon, radius, limit);
                let score = |i: usize| {
                    let (a, b) = coordinate(i);
                    let dlon = [-360.0, 0.0, 360.0].iter().map(|k| (b - lon + k).abs()).fold(f64::MAX, f64::min);
                    ((a - lat).powi(2) + dlon.powi(2)).sqrt().max(radius / 6.0) / (1.0 + (limit as f64 / (i + 1) as f64).log10())
                };
                let best = (0..limit).map(|i| (score(i), i)).fold((f64::MAX, usize::MAX), |m, x| if x.0 < m.0 { x } else { m });
                match got {
                    Some(entry) => {
                        assert!(score(entry.index) <= radius + 1e-9, "({lat}, {lon}) r{radius}: {entry:?} 出了范围");
                        assert!((score(entry.index) - best.0).abs() < 1e-9, "({lat}, {lon}) r{radius}: 答 {} 不是分最低的 {}", entry.index, best.1);
                    }
                    None => assert!(best.0 > radius, "({lat}, {lon}) r{radius}: {} 分 {} 却没答", best.1, best.0),
                }
            }
        }
    }
    #[test]
    fn rejects_bad_headers_and_extents() {
        assert!(Layout::read(&[]).is_err());
        let mut b = vec![0; 129];
        b[..8].copy_from_slice(b"TTCITY10");
        assert!(Layout::read(&b).is_err());
        for i in 0..20 {
            b[36 + i * 4..40 + i * 4].copy_from_slice(&128u32.to_le_bytes());
        }
        b[12..16].copy_from_slice(&u32::MAX.to_le_bytes());
        assert!(Layout::read(&b).is_err());
    }
    #[test]
    fn six_new_languages_are_searchable_and_named() {
        // 随包索引带意、荷、波、土、越、印尼六个语言槽；ı、đ 写不写都搜得到（「ığdır」「Đà Lạt」
        // 此前零结果）；新语言的显示名读得到、搜得到，加名字时滤掉的错名不在。
        let index = bundled();
        let first = |query: &str| {
            index
                .search_smart(&crate::catalog::fold(query), 3)
                .first()
                .and_then(|hit| index.city(hit.city_index))
                .map(|record| record.name)
        };
        for (query, city) in [("ığdır", "Iğdır"), ("Iğdır", "Iğdır"), ("Đà Lạt", "Ðà Lạt"), ("Da Lat", "Ðà Lạt"), ("Luan Don", "London"),
                              ("Luân Đôn", "London"), ("Monachium", "Munich"), ("Münih", "Munich"), ("Parijs", "Paris")] {
            assert_eq!(first(query).as_deref(), Some(city), "{query}");
        }
        let names_of = |name: &str| {
            let hit = index.search_smart(&crate::catalog::fold(name), 1)[0].city_index;
            index.names(hit, false)
        };
        let munich = names_of("Munich");
        for (language, name) in [("it", "Monaco di Baviera"), ("pl", "Monachium"), ("tr", "Münih"), ("de", "München")] {
            assert_eq!(munich.get(language).map(String::as_str), Some(name), "{language}");
        }
        assert_eq!(names_of("London").get("vi").map(String::as_str), Some("Luân Đôn"));
        // 滤掉的：印尼语的「Kota Bandung」（去掉通名就是主名）、土耳其语给亚美尼亚城市的另起旧名（Stepanavan ≠ Celaloğlu）。
        assert_eq!(names_of("Bandung").get("id"), None);
        assert_eq!(names_of("Stepanavan").get("tr"), None);
        assert_eq!(names_of("Yerevan").get("tr").map(String::as_str), Some("Erivan"));
    }

    #[test]
    fn bundled_index_queries_and_bounds() {
        let c = bundled();
        assert!(c.city_count() > 235000);
        for q in [
            "beijing",
            "munich",
            "boston",
            "mumbai",
            "oslo",
            "北京",
            "москва",
            "서울",
            "القاهرة",
        ] {
            assert!(!c.search(q, 8).is_empty(), "{q}");
        }
        assert!(c.city(usize::MAX).is_none());
        assert!(c.names(usize::MAX, false).is_empty());
        assert!(c.search("a", 0).is_empty());
        // A hostile limit is capped, and the cap is honoured exactly for a query with thousands of hits.
        assert_eq!(c.search("a", usize::MAX).len(), MAX_SEARCH_HITS);
        assert!(c.city(0).unwrap().latitude.is_finite());
    }
    #[test]
    fn every_key_is_found_by_block_lookup_and_keys_are_sorted() {
        // Walks all front-coded blocks sequentially and checks that the binary search over
        // block heads lands on exactly the same record for every key; also proves the
        // stored order is strictly sorted, which prefix iteration relies on.
        let c = bundled();
        let mut walker = c.cursor(0).unwrap();
        let mut previous: Vec<u8> = Vec::new();
        let (mut seen, mut total_postings) = (0usize, 0usize);
        while walker.advance() == Some(true) {
            assert!(
                seen == 0 || walker.key > previous,
                "keys must be strictly sorted at ordinal {seen}"
            );
            let found = c
                .locate(&walker.key)
                .expect("lookup must find an existing key");
            assert_eq!(
                (
                    found.block,
                    found.slot,
                    found.posting,
                    found.count,
                    found.key.as_slice()
                ),
                (
                    walker.block,
                    walker.slot,
                    walker.posting,
                    walker.count,
                    walker.key.as_slice()
                ),
                "ordinal {seen}"
            );
            previous.clear();
            previous.extend_from_slice(&walker.key);
            total_postings += walker.count;
            seen += 1;
        }
        assert_eq!(seen, c.layout.counts[1]);
        assert_eq!(total_postings, c.block_entry(c.blocks()).unwrap().1);
        assert!(c.locate(b"\xff\xff").is_none());
        assert!(c.search("york", 8).iter().any(|h| h.tier == 0));
    }
    #[test]
    fn new_york_primary_name_preserves_all_requested_searches() {
        let c = bundled();
        for query in ["New York", "New York City", "NYC", "nyc", "纽约", "Nueva York"] {
            let hits = c.search_smart(&crate::catalog::fold(query), 8);
            let city = c.city(hits[0].city_index).unwrap();
            assert_eq!(city.name, "New York", "{query}: {hits:?}");
            assert_eq!(city.country_code, "US");
            assert_eq!(city.timezone_id, "America/New_York");
            assert!((city.latitude - 40.71427).abs() < 0.0001);
            assert!((city.longitude + 74.00597).abs() < 0.0001);
            println!("{query} => {} {} {} index={}", city.name, city.country_code, city.timezone_id, hits[0].city_index);
        }
        for query in ["niuyue", "ny"] {
            let hits = c.search_smart(query, 8);
            assert_eq!(c.city(hits[0].city_index).unwrap().name, "New York");
            assert_eq!(hits[0].tier, 0, "{query}: {hits:?}");
            println!("{query} => {}:{}", hits[0].city_index, hits[0].tier);
        }
    }

    #[test]
    fn abbreviations_and_cjk_suffixes_find_the_city_people_mean() {
        let c = bundled();
        let first = |q: &str| {
            c.search_smart(&crate::catalog::fold(q), 3)
                .first()
                .and_then(|h| c.city(h.city_index))
                .map(|r| r.name)
        };
        assert_eq!(first("sf").as_deref(), Some("San Francisco"));
        assert_eq!(first("la").as_deref(), Some("Los Angeles"));
        assert_eq!(first("sg").as_deref(), Some("Singapore"));
        assert_eq!(first("kl").as_deref(), Some("Kuala Lumpur"));
        assert_eq!(first("nyc").as_deref(), Some("New York"));
        assert_eq!(first("hk").as_deref(), Some("Hong Kong"));
        assert_eq!(first("东京都").as_deref(), Some("Tokyo"));
        assert_eq!(first("東京都").as_deref(), Some("Tokyo"));
        assert_eq!(first("서울특별시").as_deref(), Some("Seoul"));
        // Unaliased queries are untouched: the population-ranked answer stays.
        assert_eq!(first("sfax").as_deref(), Some("Sfax"));
        assert_eq!(first("lagos").as_deref(), Some("Lagos"));
        // A query that is only a suffix keeps its literal (prefix) results; nothing is stripped to empty.
        let _ = c.search_smart("市", 3);
        // An alias still lists the other matches after the intended city.
        let hits = c.search_smart("sf", 3);
        assert!(hits.len() >= 2);
    }

    /// 生成器搜索键补丁里的每个名字都按 app 自己的路径（`catalog.fold` + `search_smart`）以精确次名
    /// 命中自己的城市，且精确命中压过所有前缀命中，单字键也一样（빈 要赢 빈저우，쿰 要赢 쿰브란）。
    /// 丢掉补丁的重建在这里失败；索引侧的孪生测试是转码器的不动点测试。
    #[test]
    fn search_key_errata_find_their_city_as_an_exact_hit() {
        let c = bundled();
        for (name, country, names) in rules::SEARCH_KEY_ERRATA {
            let city = c
                .search(&crate::catalog::fold(name), 8)
                .into_iter()
                .filter(|h| h.tier == 0)
                .filter(|h| c.city(h.city_index).is_some_and(|r| r.country_code == *country))
                .map(|h| h.city_index)
                .collect::<Vec<_>>();
            let [city] = city[..] else {
                panic!("{name}, {country}: expected exactly one primary-name hit, got {city:?}");
            };
            for raw in *names {
                let hits = c.search_smart(&crate::catalog::fold(raw), 3);
                assert!(
                    hits.iter().any(|h| h.city_index == city && h.tier == 2),
                    "{raw:?} must reach {name} as an exact secondary hit: {hits:?}"
                );
                assert_eq!(hits[0].tier, 2, "{raw:?}: a prefix hit outranks the exact ones: {hits:?}");
            }
        }
        // 共用一个键：人口更多的城市先答，另一座仍在前三。
        let names: Vec<String> = c
            .search_smart("빈", 3)
            .iter()
            .filter_map(|h| c.city(h.city_index))
            .map(|r| r.name)
            .collect();
        assert_eq!(names[..2], ["Vienna".to_owned(), "Vinh".to_owned()], "{names:?}");
    }

    /// 拼音与首字母检索：按中文名的拼音（niuyue）与首字母（bj）都能找到城市；
    /// 字面搜得到时不抢字面的位置。判据是「这一条确实指到那座城」，不是「有结果」。
    #[test]
    fn pinyin_and_initials_find_the_city_people_mean() {
        let c = bundled();
        let first = |query: &str| -> Option<String> {
            c.search_smart(&crate::catalog::fold(query), 5)
                .first()
                .and_then(|hit| c.city(hit.city_index))
                .map(|record| format!("{} {}", record.name, record.country_code))
        };
        // 全拼：中国城市与外国城市都认（表里存的是中文名的拼音）。
        assert_eq!(first("beijing").as_deref(), Some("Beijing CN"));
        assert_eq!(first("niuyue").as_deref(), Some("New York US"));
        assert_eq!(first("lundun").as_deref(), Some("London GB"));
        // 「dongjing」既是东京的拼音、也是国内一个叫 Dongjing 的镇的主名：字面拥有这个查询，
        // 所以镇在前、东京紧跟其后（一座城用自己的主名必须找到自己，探针钉着这条性质）。
        let dongjing: Vec<String> = c
            .search_smart("dongjing", 5)
            .iter()
            .filter_map(|hit| c.city(hit.city_index))
            .map(|record| format!("{} {}", record.name, record.country_code))
            .collect();
        assert!(dongjing.contains(&"Tokyo JP".to_owned()), "{dongjing:?}");
        let bali: Vec<String> = c
            .search_smart("bali", 5)
            .iter()
            .filter_map(|hit| c.city(hit.city_index))
            .map(|record| format!("{} {}", record.name, record.country_code))
            .collect();
        assert!(bali.contains(&"Paris FR".to_owned()), "{bali:?}");
        // 首字母：两个字母也认，重名按人口排（sz = 深圳 / 苏州，深圳人口多）。
        assert_eq!(first("bj").as_deref(), Some("Beijing CN"));
        assert_eq!(first("gz").as_deref(), Some("Guangzhou CN"));
        let sz: Vec<String> = c
            .search_smart("sz", 5)
            .iter()
            .filter_map(|hit| c.city(hit.city_index))
            .map(|record| record.name.clone())
            .collect();
        assert!(sz.first().map(String::as_str) == Some("Shenzhen"), "{sz:?}");
        assert!(sz.contains(&"Suzhou".to_owned()), "{sz:?}");
        // 字面能搜到的不受影响：「xian」是西安的拼音，也是索引里的拉丁名，字面优先。
        assert!(first("xian").is_some());
        assert!(first("tokyo").as_deref() == Some("Tokyo JP"));
        // 不是拼音的串照旧（不认就不认，别乱给）。
        assert!(c.search_smart("zzzzzzq", 5).is_empty());
    }

    /// 拼音表的输入：把前 N 座城市的「主名 + 国家码 + 中文名」按 TSV 打到标准输出，
    /// 交 `Tools/make_pinyin_table.swift` 用系统 ICU 转成拼音与首字母。
    /// `cargo test --lib export_top_cities_for_pinyin -- --ignored --nocapture > /tmp/cities.tsv`
    #[test]
    #[ignore = "生成拼音表用，不进常规测试"]
    fn export_top_cities_for_pinyin() {
        let c = bundled();
        let limit = std::env::var("MEANTIME_PINYIN_CITIES")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(1000usize);
        println!("#index\tname\tcountry\tzh");
        for index in 0..limit.min(c.city_count()) {
            let Some(record) = c.city(index) else { continue };
            let names = c.names(index, false);
            let zh = names
                .iter()
                .find(|(lang, _)| lang.as_str() == "zh-Hans")
                .or_else(|| names.iter().find(|(lang, _)| lang.as_str() == "zh"))
                .or_else(|| names.iter().find(|(lang, _)| lang.starts_with("zh")))
                .map(|(_, name)| name.clone())
                .unwrap_or_default();
            if zh.is_empty() {
                continue;
            }
            println!("{index}\t{}\t{}\t{zh}", record.name, record.country_code);
        }
    }

#[test]
    #[ignore]
    fn stored_names_of_big_cities_find_their_city_first() {
        let c = bundled();
        let limit = std::env::var("MEANTIME_PROBE_CITIES").ok().and_then(|v| v.parse().ok()).unwrap_or(1000usize);
        let (mut total, mut misses) = (0usize, Vec::new());
        for index in 0..limit.min(c.city_count()) {
            let Some(record) = c.city(index) else { continue };
            let mut names: Vec<(String, String)> = vec![("primary".to_owned(), record.name.clone())];
            names.extend(c.names(index, false));
            for (lang, name) in names {
                if name.trim().is_empty() {
                    continue;
                }
                total += 1;
                // The app folds every query with `catalog.fold` before it reaches the index.
                let hits = c.search_smart(&crate::catalog::fold(&name), 3);
                match hits.first() {
                    Some(hit) if hit.city_index == index => {}
                    Some(hit) => {
                        let got = c.city(hit.city_index).map(|r| format!("{} / {} {}", r.name, r.region, r.country_code)).unwrap_or_default();
                        let want = format!("{} / {} {}", record.name, record.region, record.country_code);
                        let rank = hits.iter().position(|h| h.city_index == index).map(|p| p + 1);
                        misses.push(format!("#{index} [{lang}] {name:?} -> {got}   (want {want}; rank {rank:?})"));
                    }
                    None => misses.push(format!("#{index} [{lang}] {name:?} -> nothing")),
                }
            }
        }
        println!("{} names of the top {} cities probed, {} misses", total, limit, misses.len());
        for line in &misses {
            println!("{line}");
        }
    }

    /// Two characters: the exact secondary name (BH is how Brazilians write Belo Horizonte) beats the
    /// primary-name prefixes (Bhopal, Bhubaneswar); three or more characters keep the old weights, so
    /// the bigger Tangerang still precedes Tangier for "tanger".
    #[test]
    fn short_queries_let_an_exact_secondary_name_win() {
        let c = bundled();
        let name = |hit: &Hit| c.city(hit.city_index).map(|r| r.name).unwrap_or_default();
        let bh = c.search_smart("bh", 3);
        assert_eq!(name(&bh[0]), "Belo Horizonte", "{bh:?}");
        assert_eq!(bh[0].tier, 2);
        let tanger: Vec<String> = c.search_smart("tanger", 3).iter().map(name).collect();
        assert_eq!(tanger[..2], ["Tangerang".to_owned(), "Tangier".to_owned()]);
    }

    /// One query, top hits with tier and names: `MEANTIME_PROBE_QUERY=빈 cargo test … -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn single_query_probe() {
        let c = bundled();
        let query = std::env::var("MEANTIME_PROBE_QUERY").unwrap_or_default();
        let folded = crate::catalog::fold(&query);
        println!("query {query:?} folded {folded:?}");
        for hit in c.search_smart(&folded, 8) {
            let r = c.city(hit.city_index).unwrap();
            println!("  #{:<6} tier {}  {} / {} {}", hit.city_index, hit.tier, r.name, r.region, r.country_code);
        }
    }

    /// 换索引格式的判据（立，做成可复跑的测试）：把全部记录、前 3,000 城的本地化名、
    /// 全部行政区名、前 3,000 城主名的每个前缀 + 本地化名 + 缩写 + 单字的搜索答案逐行写到文件；
    /// 旧库对旧索引、新库对新索引各跑一次，`diff` 到零差异（坐标写 5 位小数）。
    /// `MEANTIME_INDEX_PATH=<索引> MEANTIME_DUMP_OUT=<文件> cargo test --lib --release dump_answers -- --ignored`
    /// 九语地名覆盖转储：每城一行「序号 国家 主名 语言=本地化名…」，没有本地化名的语言不写。
    /// `MEANTIME_INDEX_PATH=<索引> MEANTIME_DUMP_OUT=<文件> cargo test --release --lib dump_localized -- --ignored`
    #[test]
    #[ignore]
    fn dump_localized() {
        use std::io::Write;
        let (Ok(path), Ok(out)) = (std::env::var("MEANTIME_INDEX_PATH"), std::env::var("MEANTIME_DUMP_OUT")) else { return };
        let c = CityIndex::open(&path).unwrap();
        let mut w = std::io::BufWriter::new(std::fs::File::create(out).unwrap());
        for i in 0..c.city_count() {
            let r = c.city(i).unwrap();
            let mut keys: Vec<_> = c.names(i, false).into_iter().collect();
            keys.sort();
            let names: Vec<String> = keys.into_iter().map(|(l, n)| format!("{l}={n}")).collect();
            writeln!(w, "{i}\t{}\t{}\t{}", r.country_code, r.name, names.join("\t")).unwrap();
        }
        // 行政区同样一行一个（`MEANTIME_DUMP_REGIONS=1`）：「A 序号 英文名 语言=本地化名…」。
        if std::env::var("MEANTIME_DUMP_REGIONS").is_ok() {
            for i in 0..c.layout.counts[5] {
                let name = c.string(15, 16, i, c.layout.counts[5]).unwrap_or_default();
                let mut keys: Vec<_> = c.names(i, true).into_iter().collect();
                keys.sort();
                let names: Vec<String> = keys.into_iter().map(|(l, n)| format!("{l}={n}")).collect();
                writeln!(w, "A\t{i}\t{name}\t{}", names.join("\t")).unwrap();
            }
        }
    }

    /// 读取端热路径的绝对耗时（TTCITY12 把文本指针换成长度前缀和、本地化条目换成流之后要重新量）：
    /// `cargo test --release --lib reader_hot_paths_timing -- --ignored --nocapture`。
    #[test]
    #[ignore]
    fn reader_hot_paths_timing() {
        let c = bundled();
        let n = c.city_count();
        let t = std::time::Instant::now();
        let mut total = 0usize;
        for i in (0..n).step_by(n / 20_000) {
            total += c.city(i).unwrap().name.len();
        }
        let city_ns = t.elapsed().as_nanos() / 20_000;
        let t = std::time::Instant::now();
        for i in (0..n).step_by(n / 20_000) {
            total += c.names(i, false).len();
        }
        let names_ns = t.elapsed().as_nanos() / 20_000;
        let queries = ["b", "be", "bei", "beij", "m", "mu", "mun", "北", "北京", "мос", "москва", "서", "san", "san j", "new", "new y", "los", "par", "tok", "lon"];
        let t = std::time::Instant::now();
        for _ in 0..100 {
            for q in queries {
                total += c.search(q, 8).len();
            }
        }
        let search_ns = t.elapsed().as_nanos() / (100 * queries.len() as u128);
        println!("city() {city_ns} ns · names() {names_ns} ns · search() {search_ns} ns (checksum {total})");
    }

    /// 全部搜索键与倒排数逐行转储（估算别的键编码方案用）：`MEANTIME_INDEX_PATH=… MEANTIME_DUMP_OUT=… cargo test --release --lib dump_keys -- --ignored`。
    #[test]
    #[ignore]
    fn dump_keys() {
        use std::io::Write;
        let (Ok(path), Ok(out)) = (std::env::var("MEANTIME_INDEX_PATH"), std::env::var("MEANTIME_DUMP_OUT")) else { return };
        let c = CityIndex::open(&path).unwrap();
        let mut w = std::io::BufWriter::new(std::fs::File::create(out).unwrap());
        let mut walker = c.cursor(0).unwrap();
        while walker.advance() == Some(true) {
            w.write_all(&walker.key).unwrap();
            writeln!(w, "\t{}", walker.count).unwrap();
        }
    }

    #[test]
    #[ignore]
    fn dump_answers() {
        use std::io::Write;
        let (Ok(path), Ok(out)) = (std::env::var("MEANTIME_INDEX_PATH"), std::env::var("MEANTIME_DUMP_OUT")) else { return };
        let c = CityIndex::open(&path).unwrap();
        let mut w = std::io::BufWriter::new(std::fs::File::create(out).unwrap());
        let n = c.city_count();
        for i in 0..n {
            let r = c.city(i).unwrap();
            writeln!(w, "R {i} {} | {} | {} | {} | {:.5} {:.5} | {}", r.name, r.region, r.country_code, r.timezone_id, r.latitude, r.longitude, r.admin_index).unwrap();
        }
        let mut queries: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
        for i in 0..n.min(3000) {
            let names = c.names(i, true);
            let mut keys: Vec<_> = names.iter().collect();
            keys.sort();
            for (lang, name) in keys {
                writeln!(w, "L {i} {lang} {name}").unwrap();
                let folded = crate::catalog::fold(name);
                if !folded.is_empty() { queries.insert(folded); }
            }
            let folded = crate::catalog::fold(&c.city(i).unwrap().name);
            let chars: Vec<char> = folded.chars().collect();
            for k in 1..=chars.len() { queries.insert(chars[..k].iter().collect()); }
        }
        for (alias, _) in SEARCH_ALIASES { queries.insert(alias.to_string()); }
        for ch in "abcdefghijklmnopqrstuvwxyz".chars() { queries.insert(ch.to_string()); }
        // 改选短主名后仍转储旧主名的全部前缀，前后比较使用同一组查询。
        for (old, _, _) in rules::PRIMARY_NAME_ERRATA {
            let chars: Vec<_> = crate::catalog::fold(old).chars().collect();
            for length in 1..=chars.len() { queries.insert(chars[..length].iter().collect()); }
        }
        for q in &queries {
            let hits = c.search_smart(q, 8);
            let line: Vec<String> = hits.iter().map(|h| format!("{}:{}", h.city_index, h.tier)).collect();
            writeln!(w, "S {q} => {}", line.join(" ")).unwrap();
        }
        for id in ["Asia/Tokyo", "Europe/London", "America/Los_Angeles", "Asia/Kolkata", "Australia/Lord_Howe"] {
            if let Some(e) = c.representative(id) { writeln!(w, "T {id} {} {}", e.index, e.record.name).unwrap(); }
        }
        for cc in ["CN", "US", "JP", "GB", "IN", "BR", "RU", "DE"] {
            let line: Vec<String> = c.top(cc, 8).iter().map(|e| format!("{}:{}", e.index, e.record.name)).collect();
            writeln!(w, "C {cc} {}", line.join(" ")).unwrap();
        }
        w.flush().unwrap();
    }

    /// Exploratory: how real people type. Run with `--ignored --nocapture` and read the table.
    #[test]
    #[ignore]
    fn search_quality_probe() {
        let c = bundled();
        let queries = [
            "nyc",
            "new york",
            "sf",
            "san francisco",
            "la",
            "los angeles",
            "peking",
            "bombay",
            "saigon",
            "ho chi minh",
            "nuremberg",
            "nurnberg",
            "cologne",
            "koln",
            "munchen",
            "st petersburg",
            "sankt-peterburg",
            "leningrad",
            "hcmc",
            "kolkata",
            "calcutta",
            "bengaluru",
            "bangalore",
            "mumbai",
            "北京市",
            "东京都",
            "서울특별시",
            "tokio",
            "tokyo",
            "toquio",
            "moscou",
            "moskva",
            "pekin",
            "shanghai",
            "上海",
            "xi an",
            "xian",
            "hongkong",
            "hong kong",
            "hk",
            "sg",
            "singapore",
            "kuala lumpur",
            "kl",
            "dubai",
            "abu dhabi",
            "tel aviv",
            "jerusalem",
            "istanbul",
            "constantinople",
            "prague",
            "praha",
            "vienna",
            "wien",
            "warsaw",
            "warszawa",
            "athens",
            "athina",
            "lisbon",
            "lisboa",
            "geneva",
            "geneve",
            "zurich",
            "zürich",
            "brussels",
            "bruxelles",
            "copenhagen",
            "kobenhavn",
            "gothenburg",
            "goteborg",
            "mexico city",
            "cdmx",
            "sao paulo",
            "são paulo",
            "rio",
            "buenos aires",
            "bogota",
            "lima",
            "santiago",
            "cape town",
            "johannesburg",
            "joburg",
            "nairobi",
            "lagos",
            "cairo",
            "casablanca",
            "sydney",
            "melbourne",
            "auckland",
            "wellington",
            "honolulu",
            "anchorage",
            "vancouver",
            "toronto",
            "montreal",
            "montréal",
            "chicago",
            "seattle",
            "denver",
            "dallas",
            "houston",
            "miami",
            "boston",
            "washington",
            "washington dc",
            "dc",
            "philly",
            "philadelphia",
            "vegas",
            "las vegas",
        ];
        for q in queries {
            let folded = crate::catalog::fold(q);
            let hits = c.search(&folded, 3);
            let names: Vec<String> = hits
                .iter()
                .filter_map(|h| c.city(h.city_index))
                .map(|r| format!("{} [{}]", r.name, r.timezone_id))
                .collect();
            println!(
                "{q:20} -> {}",
                if names.is_empty() {
                    "(none)".to_owned()
                } else {
                    names.join(" | ")
                }
            );
        }
    }

    #[test]
    fn released_handles_cannot_be_used() {
        let value=dispatch("city.open",json!({"path":concat!(env!("CARGO_MANIFEST_DIR"),"/../TahoeTime/Resources/cities.ttcity")})).unwrap();
        let h = value["handle"].as_u64().unwrap();
        assert_eq!(dispatch("city.close", json!({"handle":h})).unwrap(), true);
        assert!(dispatch(
            "city.search",
            json!({"handle":h,"query":"beijing","limit":8})
        )
        .is_err());
    }
    #[test]
    fn header_and_language_table_mutations_are_rejected() {
        let original = bundled();
        let mut bytes = original.data.to_vec();
        for (at, value) in [
            (36, 127u32),
            (40, 127),
            (36 + 18 * 4, u32::MAX),
            (36 + 19 * 4, u32::MAX),
            (16, u32::MAX),
            (28, u32::MAX),
        ] {
            let saved = bytes[at..at + 4].to_vec();
            bytes[at..at + 4].copy_from_slice(&value.to_le_bytes());
            assert!(Layout::read(&bytes).is_err(), "header offset {at}");
            bytes[at..at + 4].copy_from_slice(&saved);
        }
        for section in [11, 17] {
            let at = original.layout.sections[section];
            let saved = bytes[at..at + 4].to_vec();
            bytes[at..at + 4].copy_from_slice(&u32::MAX.to_le_bytes());
            assert!(Layout::read(&bytes).is_err());
            bytes[at..at + 4].copy_from_slice(&saved);
        }
    }
    #[test]
    fn corrupt_variable_offsets_fail_without_dereferencing_out_of_bounds() {
        let c = bundled();
        assert!(c.slice(4, usize::MAX, 1).is_none());
        assert!(c.slice(4, 0, usize::MAX).is_none());
        let mut bytes = memmap2::MmapMut::map_anon(c.data.len()).unwrap();
        bytes.copy_from_slice(&c.data);
        // 最后一组城市名的基址改成 u32::MAX：那一组的名字偏移飞出文本池，读到 None 而不是越界；第一组不受影响。
        let last = c.city_count() - 1;
        let intact_names = c.names(last, false).len();
        let columns = ttcity::record_columns(c.city_count());
        let at = c.layout.sections[0] + columns[4] + (last / ttcity::CITY_BASE_GROUP) * 4;
        bytes[at..at + 4].copy_from_slice(&u32::MAX.to_le_bytes());
        let malformed = CityIndex {
            data: bytes.make_read_only().unwrap(),
            population_data: c.population_data,
            layout: c.layout,
            timezone_lookup: c.timezone_lookup,
            country_lookup: c.country_lookup,
            tables: c.tables,
        };
        assert!(malformed.city(last).is_none());
        assert!(malformed.city(0).is_some());
        assert!(malformed.names(last, false).len() <= intact_names);
    }
    #[test]
    fn missing_index_is_a_business_result_not_a_transport_failure() {
        let value = dispatch(
            "city.open",
            json!({"path":"/nonexistent/dayside-index.ttcity"}),
        )
        .unwrap();
        assert!(value["handle"].is_null());
        assert_eq!(value["cityCount"], 0);
        assert!(value["error"].is_string());
    }
}

#[cfg(test)]
mod golan_probe {
    use super::*;
    /// 探针：列出上游国家码为 IL、SY 或 LB、坐标落在戈兰高地大致范围内的居民点。
    /// `cargo test --lib golan_probe -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn list_israeli_records_in_the_golan_box() {
        let index = CityIndex::open(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../TahoeTime/Resources/cities.ttcity"
        ))
        .unwrap();
        for i in 0..index.city_count() {
            let Some(r) = index.city(i) else { continue };
            if ["IL", "SY", "LB"].contains(&r.country_code.as_str()) && (35.58..35.95).contains(&r.longitude) && (32.62..33.45).contains(&r.latitude) {
                println!("{}\t{}\t{}\t{:.4}\t{:.4}\t{}", r.country_code, r.name, r.region, r.latitude, r.longitude, r.timezone_id);
            }
        }
    }
}

#[cfg(test)]
mod rebuild_diff_probe {
    use super::*;
    /// 探针：比较两份索引的行政区本地化名，列出不同的条目（重建后核对「只改了该改的」）。
    /// `MEANTIME_INDEX_A=… MEANTIME_INDEX_B=… cargo test --lib rebuild_diff_probe -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn admin_region_names_differ_only_where_expected() {
        let (Ok(a), Ok(b)) = (std::env::var("MEANTIME_INDEX_A"), std::env::var("MEANTIME_INDEX_B")) else { return };
        let (a, b) = (CityIndex::open(&a).unwrap(), CityIndex::open(&b).unwrap());
        assert_eq!(a.city_count(), b.city_count());
        let mut seen = std::collections::HashSet::new();
        let mut diffs = 0;
        for i in 0..a.city_count() {
            let (ra, rb) = (a.city(i).unwrap(), b.city(i).unwrap());
            assert_eq!((&ra.name, &ra.country_code, ra.admin_index), (&rb.name, &rb.country_code, rb.admin_index), "城市 {i}");
            if ra.admin_index < 0 || !seen.insert(ra.admin_index) { continue }
            let (na, nb) = (a.names(ra.admin_index as usize, true), b.names(rb.admin_index as usize, true));
            if na != nb {
                diffs += 1;
                println!("{} / {}: {:?} -> {:?}", ra.country_code, ra.region, na.get("zh-Hans"), nb.get("zh-Hans"));
            }
        }
        println!("行政区本地化名不同：{diffs}");
    }
}
