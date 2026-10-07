// SPDX-License-Identifier: GPL-3.0-only
//! TTCITY12 城市索引的格式常量，读取端（`city_index.rs`）与生成器（`index_builder.rs`，编进
//! `build_city_index`）共用同一份，两侧不可能不一致。布局说明在 `city_index.rs` 文件头。
pub const MAGIC: &[u8; 8] = b"TTCITY12";
pub const VERSION: u32 = 12;
/// 搜索键每块的条数（TTCITY11 起 64：块表项与整存的块首键少一半，块内线性扫描仍是微秒级）。
pub const KEY_BLOCK: usize = 64;
/// 文种类别数：1 ASCII、2 带变音的拉丁、3 希腊 / 西里尔 / 亚美尼亚、4 其他（阿拉伯、希伯来、印度诸文、泰文…）、
/// 5 汉字与假名、6 谚文。表号 0 表示原样字节。文本与键各一组表。
pub const SCRIPT_CLASSES: usize = 6;
pub const TABLE_COUNT: usize = SCRIPT_CLASSES * 2;
/// 坐标定点：度 × 40000 存成有符号 24 位（±180° 在 ±7,200,000，24 位放得下）。
pub const COORDINATE_SCALE: f64 = 40_000.0;
/// 每条城市记录的字节数。TTCITY12 起 11 字节**列式**存放（段 0 里四列各自连续：名字编码后长度 1 B、打包字段 4 B、
/// 纬度 3 B、经度 3 B）；名字的文本偏移不再存——文本池开头按记录顺序连续摆放全部城市名（不去重），
/// 每 `CITY_BASE_GROUP` 条记一个 u32 基址（段 0 末尾的第五列），偏移 = 基址 + 本组前面各名长度之和。
/// TTCITY11 的记录是 14 字节（多一个 u24 偏移），转码器还认它。
pub const CITY_RECORD: usize = 11;
pub const CITY_RECORD_V11: usize = 14;
pub const CITY_BASE_GROUP: usize = 256;
/// 列式记录各列在段 0 里的起点（按记录数 n）：长度、打包字段、纬度、经度、基址。
pub fn record_columns(n: usize) -> [usize; 5] {
    [0, n, n * 5, n * 8, n * 11]
}
/// 段 0 的长度：n 条记录加 ceil(n / 256) 个 u32 基址。
pub fn city_blob_len(n: usize) -> usize {
    n * CITY_RECORD + n.div_ceil(CITY_BASE_GROUP) * 4
}
/// 打包字段：行政区 12 位（0xfff = 没有）| 时区 9 位 | 国家 8 位 | 文本表号 3 位。
pub const ADMIN_NONE: usize = 0xfff;
pub const TIMEZONE_LIMIT: usize = 1 << 9;
pub fn pack_fields(admin: usize, timezone: usize, country: usize, class: u8) -> u32 {
    (admin as u32 & 0xfff) | ((timezone as u32 & 0x1ff) << 12) | ((country as u32 & 0xff) << 21) | ((u32::from(class) & 0x7) << 29)
}
pub fn unpack_fields(packed: u32) -> (usize, usize, usize, u8) {
    ((packed & 0xfff) as usize, ((packed >> 12) & 0x1ff) as usize, ((packed >> 21) & 0xff) as usize, (packed >> 29) as u8)
}
/// 本地化条目（段 12 / 18，TTCITY12 起）是按城市序的字节流：每 `LOCALIZED_GROUP` 条一组，组首城市号写绝对值（varint），
/// 其余写「与前一条之差 − 1」（varint）；随后 u8 长度——非零表示字符串就在文本游标处（游标前进这么多字节），
/// 0 是转义引用：u24 文本偏移 + u8 长度（同一字符串早已写进文本池，去重）；最后 u8 表号。
/// 每语言一条 16 B 范围（段 11 / 17）：u32 流起点、u32 流长度、u32 稀疏索引起点（三者都在段 12 / 18 里）、u32 条数。
/// 稀疏索引每组 9 B：u24 组首城市号、u24 组首相对流起点的偏移、u24 组首处的文本游标——按城市号二分到组，再线性解 ≤ 64 条。
pub const LOCALIZED_GROUP: usize = 64;
pub const LOCALIZED_RANGE: usize = 16;
pub const LOCALIZED_INDEX_ENTRY: usize = 9;
pub fn localized_index_len(count: usize) -> usize {
    count.div_ceil(LOCALIZED_GROUP) * LOCALIZED_INDEX_ENTRY
}
/// LEB128，最多 4 字节（28 位，城市号 19 位足够）。
pub fn push_varint(out: &mut Vec<u8>, mut value: usize) {
    loop {
        let byte = (value & 0x7f) as u8;
        value >>= 7;
        if value == 0 {
            out.push(byte);
            return;
        }
        out.push(byte | 0x80);
    }
}
/// 只认规范写法：多字节时末字节不能是 0（同一个值只有一种字节），超过 4 字节拒绝。
pub fn read_varint(b: &[u8], at: &mut usize) -> Option<usize> {
    let mut value = 0usize;
    for i in 0..4 {
        let byte = *b.get(*at)?;
        *at += 1;
        value |= ((byte & 0x7f) as usize) << (7 * i);
        if byte & 0x80 == 0 {
            return (i == 0 || byte != 0).then_some(value);
        }
    }
    None
}
/// 倒排：每条 20 位（19 位记录号 + 1 位「这是主名」），按位连续排列，末尾补 3 个零字节让读取端能整字读。
pub const POSTING_BITS: usize = 20;
pub const POSTING_PRIMARY: u32 = 1 << 19;
pub const POSTING_LIMIT: usize = 1 << 19;
pub fn posting_bytes(count: usize) -> usize {
    (count * POSTING_BITS).div_ceil(8) + 3
}
/// 头部：8 字节魔数、u32 版本、6 × u32 计数、20 × u32 段偏移，共 116 字节，补到 128。
pub const HEADER: usize = 128;
pub const SECTIONS: usize = 20;
/// 人口文件绑定索引的构建指纹。
pub const FINGERPRINT_OFFSET: usize = 116;
pub const FINGERPRINT_LEN: usize = 12;
pub const FNV_OFFSET_BASE: u64 = 0xcbf29ce484222325;
pub const FNV_OFFSET_BASE_ALT: u64 = 0x6c62272e07bb0142;
pub const FNV_PRIME: u64 = 0x100000001b3;
pub const POP_MAGIC: &[u8; 4] = b"TTPP";
pub const POP_VERSION: u32 = 1;
pub const POP_HEADER: usize = 24;

/// 字符串的文种类别（决定用哪张符号表）；坏 UTF-8 归「其他」。
pub fn script_class(bytes: &[u8]) -> u8 {
    if bytes.is_ascii() {
        return 1;
    }
    let Ok(text) = std::str::from_utf8(bytes) else {
        return 4;
    };
    let top = text.chars().map(|c| c as u32).max().unwrap_or(0);
    match top {
        0..=0x036f => 2,
        0x0370..=0x05ff => 3,
        0x1100..=0x11ff | 0x3130..=0x318f | 0xac00..=0xd7af => 6,
        0x2e80..=0x9fff | 0xf900..=0xfaff | 0x20000..=0x3ffff => 5,
        _ => 4,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn scripts_are_classified_by_their_highest_code_point() {
        assert_eq!(script_class(b"tokyo"), 1);
        assert_eq!(script_class("münchen".as_bytes()), 2);
        assert_eq!(script_class("москва".as_bytes()), 3);
        assert_eq!(script_class("Ελλάδα".as_bytes()), 3);
        assert_eq!(script_class("القاهرة".as_bytes()), 4);
        assert_eq!(script_class("東京".as_bytes()), 5);
        assert_eq!(script_class("서울".as_bytes()), 6);
        assert_eq!(script_class(&[0xff, 0xfe]), 4);
        assert_eq!(script_class(b""), 1);
        const { assert!(SCRIPT_CLASSES == 6 && TABLE_COUNT == 12) };
        const { assert!(180.0 * COORDINATE_SCALE < 8_388_607.0) };
    }
    #[test]
    fn varints_round_trip_and_reject_non_canonical_bytes() {
        for value in [0, 1, 127, 128, 16_383, 16_384, 235_739, (1 << 28) - 1] {
            let mut out = Vec::new();
            push_varint(&mut out, value);
            let mut at = 0;
            assert_eq!(read_varint(&out, &mut at), Some(value));
            assert_eq!(at, out.len());
        }
        assert_eq!(read_varint(&[0x80, 0x00], &mut 0), None);
        assert_eq!(read_varint(&[0x80, 0x80, 0x80, 0x80, 0x01], &mut 0), None);
        assert_eq!(read_varint(&[0x80], &mut 0), None);
        assert_eq!(city_blob_len(0), 0);
        assert_eq!(city_blob_len(256), 256 * 11 + 4);
        assert_eq!(city_blob_len(257), 257 * 11 + 8);
        assert_eq!(localized_index_len(0), 0);
        assert_eq!(localized_index_len(65), 18);
    }
}
