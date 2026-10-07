// SPDX-License-Identifier: GPL-3.0-only
//! 静态符号表字符串压缩（FSST 的做法：Boncz / Neumann / Leis 2020），给城市索引 TTCITY10 用。
//!
//! 一张表最多 255 个符号，每个符号 1–8 字节；编码后每个字节要么是一个符号的码（0–254），要么是
//! 转义 `255` 加一个原样字节。解码只是查表拼接，随机访问一条字符串不需要上下文，所以名字
//! 与搜索键的后缀都能单独解、mmap 只碰用到的页；面板不开时仍不映射城市索引。
//!
//! 学表是确定性的：候选按（收益, 字节）排序，输入相同则表逐字节相同，转码才有不动点。
use std::cell::RefCell;
use std::collections::HashMap;

pub const ESCAPE: u8 = 255;
pub const MAX_SYMBOLS: usize = 255;
pub const MAX_SYMBOL_LEN: usize = 8;
/// 学表时每张表最多看这么多字节的样本（确定性地取前面的字符串）。
const SAMPLE_BUDGET: usize = 1_500_000;
const ROUNDS: usize = 5;

#[derive(Clone, Debug, PartialEq, Eq)]
struct Symbol {
    bytes: [u8; MAX_SYMBOL_LEN],
    len: u8,
}
impl Symbol {
    fn new(raw: &[u8]) -> Option<Self> {
        if !(1..=MAX_SYMBOL_LEN).contains(&raw.len()) {
            return None;
        }
        let mut bytes = [0; MAX_SYMBOL_LEN];
        bytes[..raw.len()].copy_from_slice(raw);
        Some(Self { bytes, len: raw.len() as u8 })
    }

    fn as_slice(&self) -> &[u8] {
        &self.bytes[..usize::from(self.len)]
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Table {
    /// 码 → 符号；长度 1–8。
    symbols: Vec<Symbol>,
}

impl Table {
    pub fn symbol_count(&self) -> usize {
        self.symbols.len()
    }

    /// 解码：坏码（≥ 符号数）或末尾悬空的转义返回 None。
    pub fn decode(&self, coded: &[u8], out: &mut Vec<u8>) -> Option<()> {
        let mut i = 0;
        while i < coded.len() {
            let code = coded[i];
            i += 1;
            if code == ESCAPE {
                out.push(*coded.get(i)?);
                i += 1;
            } else {
                out.extend_from_slice(self.symbols.get(code as usize)?.as_slice());
            }
        }
        Some(())
    }

    /// 线格式：u8 符号数，然后每个符号 u8 长度 + 字节。
    pub fn serialize(&self, out: &mut Vec<u8>) {
        out.push(self.symbols.len() as u8);
        for symbol in &self.symbols {
            out.push(symbol.len);
            out.extend_from_slice(symbol.as_slice());
        }
    }

    /// 从 `bytes[*at..]` 读一张表；越界、符号数超上限、符号长度不在 1–8 都是 None。
    pub fn parse(bytes: &[u8], at: &mut usize) -> Option<Self> {
        let count = *bytes.get(*at)? as usize;
        *at += 1;
        if count > MAX_SYMBOLS {
            return None;
        }
        let mut symbols = Vec::with_capacity(count);
        for _ in 0..count {
            let len = *bytes.get(*at)? as usize;
            *at += 1;
            if !(1..=MAX_SYMBOL_LEN).contains(&len) {
                return None;
            }
            symbols.push(Symbol::new(bytes.get(*at..*at + len)?)?);
            *at += len;
        }
        Some(Self { symbols })
    }

    /// 编码器：按首字节分桶、桶内按长度降序，每个位置取最长匹配的符号，没有就转义。
    pub fn encoder(&self) -> Encoder<'_> {
        let mut buckets: Vec<Vec<(u8, &[u8])>> = vec![Vec::new(); 256];
        for (code, symbol) in self.symbols.iter().enumerate() {
            let symbol = symbol.as_slice();
            buckets[symbol[0] as usize].push((code as u8, symbol));
        }
        for bucket in &mut buckets {
            bucket.sort_by(|a, b| b.1.len().cmp(&a.1.len()).then(a.1.cmp(b.1)));
        }
        Encoder { buckets, used: RefCell::new([false; 256]) }
    }

    /// 只留 `used[code]` 为真的符号（码重新编号）。去掉从未匹配的符号不改变其余符号的最长匹配，
    /// 所以再编一遍得到同样的切分，表里每个符号都被至少一条字符串用到。
    pub fn retain(&self, used: &[bool; 256]) -> Self {
        Self {
            symbols: self
                .symbols
                .iter()
                .enumerate()
                .filter(|(code, _)| used[*code])
                .map(|(_, s)| s.clone())
                .collect(),
        }
    }

    /// 从样本学一张表：先当作全转义，每轮用当前表贪心切分样本、统计符号与相邻符号拼接的
    /// 收益（次数 × 长度），取前 255。
    pub fn learn<'a>(samples: impl IntoIterator<Item = &'a [u8]>) -> Self {
        let mut budget = SAMPLE_BUDGET;
        let mut sample: Vec<&[u8]> = Vec::new();
        for s in samples {
            if s.is_empty() {
                continue;
            }
            if budget < s.len() {
                break;
            }
            budget -= s.len();
            sample.push(s);
        }
        let mut table = Self::default();
        for _ in 0..ROUNDS {
            let encoder = table.encoder();
            let mut gain: HashMap<Vec<u8>, usize> = HashMap::new();
            for s in &sample {
                let mut previous: Option<&[u8]> = None;
                let mut i = 0;
                while i < s.len() {
                    let symbol = match encoder.longest(&s[i..]) {
                        Some((_, symbol)) => symbol,
                        None => &s[i..i + 1],
                    };
                    *gain.entry(symbol.to_vec()).or_default() += symbol.len();
                    if let Some(p) = previous {
                        if p.len() + symbol.len() <= MAX_SYMBOL_LEN {
                            let mut pair = p.to_vec();
                            pair.extend_from_slice(symbol);
                            *gain.entry(pair).or_default() += p.len() + symbol.len();
                        }
                    }
                    previous = Some(symbol);
                    i += symbol.len();
                }
            }
            let mut candidates: Vec<(Vec<u8>, usize)> = gain.into_iter().collect();
            candidates.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
            candidates.truncate(MAX_SYMBOLS);
            let mut symbols: Vec<Vec<u8>> = candidates.into_iter().map(|(s, _)| s).collect();
            symbols.sort();
            table = Self {
                symbols: symbols.into_iter()
                    .map(|symbol| Symbol::new(&symbol).expect("learned symbol length is bounded"))
                    .collect(),
            };
        }
        table
    }
}

pub struct Encoder<'a> {
    buckets: Vec<Vec<(u8, &'a [u8])>>,
    /// 编码过程中用到过的码（`retain` 用）。
    used: RefCell<[bool; 256]>,
}
impl Encoder<'_> {
    fn longest(&self, rest: &[u8]) -> Option<(u8, &[u8])> {
        self.buckets[rest[0] as usize]
            .iter()
            .find(|(_, symbol)| rest.starts_with(symbol))
            .map(|(code, symbol)| (*code, *symbol))
    }
    pub fn used(&self) -> [bool; 256] {
        *self.used.borrow()
    }
    /// 放弃一次试编时把用量记录退回去：试过表编但整块最后按原样存，试编时标上的符号不算用过，
    /// 否则表里会留下没人引用的死符号；字节扫描测试应拦住这种情况。
    pub fn restore(&self, used: [bool; 256]) {
        *self.used.borrow_mut() = used;
    }
    pub fn encode(&self, raw: &[u8], out: &mut Vec<u8>) {
        let mut i = 0;
        while i < raw.len() {
            match self.longest(&raw[i..]) {
                Some((code, symbol)) => {
                    out.push(code);
                    self.used.borrow_mut()[code as usize] = true;
                    i += symbol.len();
                }
                None => {
                    out.push(ESCAPE);
                    out.push(raw[i]);
                    i += 1;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_and_shrinks_repetitive_names() {
        let names: Vec<&[u8]> = [
            "San Francisco", "San Antonio", "San Diego", "Santa Cruz", "Santiago", "São Paulo",
            "Saint Petersburg", "Saint-Denis", "San José", "Santa Fe", "Sankt Pölten", "Sandnes",
        ]
        .iter()
        .map(|s| s.as_bytes())
        .collect();
        let table = Table::learn(names.iter().copied());
        assert!(table.symbol_count() > 0 && table.symbol_count() <= MAX_SYMBOLS);
        let encoder = table.encoder();
        let (mut raw, mut coded) = (0, 0);
        for name in &names {
            let mut c = Vec::new();
            encoder.encode(name, &mut c);
            let mut back = Vec::new();
            table.decode(&c, &mut back).unwrap();
            assert_eq!(back, *name);
            raw += name.len();
            coded += c.len();
        }
        assert!(coded < raw, "{coded} >= {raw}");
        // 线格式往返；坏码与悬空转义被拒。
        let mut bytes = Vec::new();
        table.serialize(&mut bytes);
        let mut at = 0;
        assert_eq!(Table::parse(&bytes, &mut at).unwrap(), table);
        assert_eq!(at, bytes.len());
        assert!(table.decode(&[254], &mut Vec::new()).is_none() || table.symbol_count() == 255);
        assert!(table.decode(&[ESCAPE], &mut Vec::new()).is_none());
        assert!(Table::parse(&[1, 0], &mut 0).is_none());
        assert!(Table::parse(&[1, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0], &mut 0).is_none());
    }

    #[test]
    fn learning_is_deterministic_and_bytes_without_symbols_are_escaped() {
        let a: Vec<&[u8]> = vec![b"tokyo", b"toronto", b"torino", b"toulouse"];
        assert_eq!(Table::learn(a.iter().copied()), Table::learn(a.iter().copied()));
        let table = Table::learn(a.iter().copied());
        let mut coded = Vec::new();
        table.encoder().encode(b"zzz", &mut coded);
        assert_eq!(coded, vec![ESCAPE, b'z', ESCAPE, b'z', ESCAPE, b'z']);
        // 学出来却没用上的符号被 retain 剪掉，剪后编码逐字节相同。
        let full = Table::learn([b"tokyo".as_slice(), b"toronto"]);
        let encoder = full.encoder();
        let mut once = Vec::new();
        encoder.encode(b"tokyo", &mut once);
        let pruned = full.retain(&encoder.used());
        assert!(pruned.symbol_count() < full.symbol_count());
        let mut again = Vec::new();
        pruned.encoder().encode(b"tokyo", &mut again);
        let (mut a, mut b) = (Vec::new(), Vec::new());
        full.decode(&once, &mut a).unwrap();
        pruned.decode(&again, &mut b).unwrap();
        assert_eq!(a, b"tokyo");
        assert_eq!(b, b"tokyo");
        assert_eq!(pruned.encoder().used().iter().filter(|u| **u).count(), 0);
        let empty = Table::learn(std::iter::empty());
        assert_eq!(empty.symbol_count(), 0);
        let mut c = Vec::new();
        empty.encoder().encode(b"ab", &mut c);
        let mut back = Vec::new();
        empty.decode(&c, &mut back).unwrap();
        assert_eq!(back, b"ab");
    }

    #[test]
    fn parsed_lengths_binary_longest_matches_and_retained_wire_are_preserved() {
        let wire = [
            8, 1, 0, 2, 0, 255, 3, 0, 255, 1, 4, 0, 255, 1, 2,
            5, 0, 255, 1, 2, 3, 6, 0, 255, 1, 2, 3, 4,
            7, 0, 255, 1, 2, 3, 4, 5, 8, 0, 255, 1, 2, 3, 4, 5, 6,
        ];
        let mut at = 0;
        let table = Table::parse(&wire, &mut at).unwrap();
        assert_eq!(at, wire.len());
        let mut serialized = Vec::new();
        table.serialize(&mut serialized);
        assert_eq!(serialized, wire);
        let raw = [0, 255, 1, 2, 3, 4, 5, 6, 0, 255, 1, 0, b'z'];
        let encoder = table.encoder();
        let mut coded = Vec::new();
        encoder.encode(&raw, &mut coded);
        assert_eq!(coded, [7, 2, 0, ESCAPE, b'z']);
        let mut decoded = Vec::new();
        table.decode(&coded, &mut decoded).unwrap();
        assert_eq!(decoded, raw);
        let pruned = table.retain(&encoder.used());
        let mut pruned_wire = Vec::new();
        pruned.serialize(&mut pruned_wire);
        assert_eq!(pruned_wire, [3, 1, 0, 3, 0, 255, 1, 8, 0, 255, 1, 2, 3, 4, 5, 6]);
        let mut recoded = Vec::new();
        pruned.encoder().encode(&raw, &mut recoded);
        assert_eq!(recoded, [2, 1, 0, ESCAPE, b'z']);
        assert!(Table::parse(&wire[..wire.len() - 1], &mut 0).is_none());
        let empty = Table::parse(&[0], &mut 0).unwrap();
        let mut empty_wire = Vec::new();
        empty.serialize(&mut empty_wire);
        assert_eq!(empty_wire, [0]);
        assert!(empty.decode(&[0], &mut Vec::new()).is_none());
        let mut escaped = Vec::new();
        empty.decode(&[ESCAPE, 0], &mut escaped).unwrap();
        assert_eq!(escaped, [0]);
    }

    #[test]
    fn full_symbol_table_preserves_code_254_and_escape_255() {
        let mut wire = vec![MAX_SYMBOLS as u8];
        for byte in 0..MAX_SYMBOLS as u8 {
            wire.extend_from_slice(&[1, byte]);
        }
        let mut at = 0;
        let table = Table::parse(&wire, &mut at).unwrap();
        assert_eq!(table.symbol_count(), MAX_SYMBOLS);
        assert_eq!(at, wire.len());
        let mut serialized = Vec::new();
        table.serialize(&mut serialized);
        assert_eq!(serialized, wire);
        let mut coded = Vec::new();
        table.encoder().encode(&[0, 254, 255], &mut coded);
        assert_eq!(coded, [0, 254, ESCAPE, 255]);
        let mut decoded = Vec::new();
        table.decode(&coded, &mut decoded).unwrap();
        assert_eq!(decoded, [0, 254, 255]);
    }
}
