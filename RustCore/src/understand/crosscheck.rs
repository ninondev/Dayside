// SPDX-License-Identifier: GPL-3.0-only
//! 多处时间互相核对（`understand.crosscheck`）：同一行里只隔着分隔符或连接词的几处
//!（引擎给的 `Mention::group`）写的是不是不同时区的同一刻。引擎不知道夏令时，瞬间由宿主（Foundation）落好再交进来；
//! 差 30 分钟到 2 小时多半是有一处没按夏令时改，只提醒、不改读数。规则与测试同时覆盖一致、偏差和跨日的钟点。

use std::collections::{HashMap, HashSet};

/// 一条已由宿主解析到绝对时刻的时间提及。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Instant {
    /// 提及在整条消息中的序号。
    pub index: usize,
    /// 提及所属的分组（通常是同一行）。
    pub group: usize,
    /// 该提及对应的 Unix 秒数。
    pub seconds: i64,
    /// 时区名称字符串。
    pub zone: String,
    /// 是否带有显式时区。
    pub zoned: bool,
    /// 是否带有钟面时间（而非只有日期）。
    pub has_clock: bool,
}

/// 两条提及不一致时的分类。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// 差值在 30 到 120 分钟之间，疑似漏算夏令时。
    DstSuspect,
    /// 其余任何非零差异。
    Different,
}

/// 一条差异记录。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Note {
    /// 分组内基准提及的序号。
    pub a: usize,
    /// 被比较提及的序号。
    pub b: usize,
    /// 差值的分钟数，向零取整。
    pub delta_minutes: i64,
    /// 差异的分类。
    pub kind: Kind,
}

/// 交叉检查的结果。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Report {
    /// 每个出现一致项的分组：`[基准序号, 依次一致的序号]`。
    pub same: Vec<Vec<usize>>,
    /// 全部差异记录，按 `(a, b)` 升序。
    pub notes: Vec<Note>,
}

/// 判断同一分组内写成“不同时区的同一时刻”的提及是否真的吻合。
///
/// 同 `index` 只保留输入顺序里的第一条；只有带时区且带钟面时间的提及才参与比较；
/// 每个分组的基准是其中 `index` 最小的参与项，其余时区不同的参与项各与基准比较一次。
pub fn crosscheck(items: &[Instant]) -> Report {
    let mut report = Report::default();
    let mut seen: HashSet<usize> = HashSet::new();
    let mut groups: HashMap<usize, Vec<&Instant>> = HashMap::new();

    for item in items {
        // 去重：重复的 index 只认第一条；随后按条件筛掉不参与的提及。
        if seen.insert(item.index) && item.zoned && item.has_clock {
            groups.entry(item.group).or_default().push(item);
        }
    }

    for (_, mut members) in groups {
        members.sort_unstable_by_key(|item| item.index);
        let base = members[0];
        let mut agreeing: Vec<usize> = Vec::new();

        for item in members.iter().skip(1) {
            if item.zone == base.zone {
                continue;
            }
            // 用 i128 计算差值，任何输入都不会溢出。
            let delta = i128::from(item.seconds) - i128::from(base.seconds);
            if delta == 0 {
                agreeing.push(item.index);
                continue;
            }
            let kind = if (1800..=7200).contains(&delta.abs()) {
                Kind::DstSuspect
            } else {
                Kind::Different
            };
            report.notes.push(Note {
                a: base.index,
                b: item.index,
                delta_minutes: i64::try_from(delta / 60).unwrap_or(i64::MAX),
                kind,
            });
        }

        if !agreeing.is_empty() {
            agreeing.sort_unstable();
            let mut entry = vec![base.index];
            entry.extend(agreeing);
            report.same.push(entry);
        }
    }

    report.notes.sort_unstable_by_key(|note| (note.a, note.b));
    report.same.sort_unstable_by_key(|entry| entry[0]);
    report
}

#[cfg(test)]
mod tests {
    use super::{crosscheck, Instant, Kind, Note, Report};

    /// 极简 xorshift64 随机数发生器。
    struct Rng(u64);

    impl Rng {
        fn next(&mut self) -> u64 {
            let mut x = self.0;
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            self.0 = x;
            x
        }

        fn below(&mut self, n: u64) -> u64 {
            self.next() % n
        }

        fn flag(&mut self) -> bool {
            self.next() & 1 == 1
        }
    }

    const BASE: i64 = 1_790_600_400;
    const ZONES: [&str; 4] = ["A", "B", "C", "Asia/Tokyo"];

    /// 独立实现的对照参考：去重、筛选后对每个有序对分类。
    fn oracle(items: &[Instant]) -> Report {
        let mut unique: Vec<&Instant> = Vec::new();
        for item in items {
            if !unique.iter().any(|kept| kept.index == item.index) {
                unique.push(item);
            }
        }
        let active: Vec<&Instant> = unique
            .into_iter()
            .filter(|kept| kept.zoned && kept.has_clock)
            .collect();

        let mut same: Vec<Vec<usize>> = Vec::new();
        let mut notes: Vec<Note> = Vec::new();
        for x in &active {
            let is_base = !active
                .iter()
                .any(|other| other.group == x.group && other.index < x.index);
            if !is_base {
                continue;
            }
            let mut agreeing: Vec<usize> = Vec::new();
            for y in &active {
                if y.group != x.group || y.index == x.index || y.zone == x.zone {
                    continue;
                }
                let delta = y.seconds as i128 - x.seconds as i128;
                if delta == 0 {
                    agreeing.push(y.index);
                } else if (1800..=7200).contains(&delta.abs()) {
                    notes.push(Note {
                        a: x.index,
                        b: y.index,
                        delta_minutes: (delta / 60) as i64,
                        kind: Kind::DstSuspect,
                    });
                } else {
                    notes.push(Note {
                        a: x.index,
                        b: y.index,
                        delta_minutes: (delta / 60) as i64,
                        kind: Kind::Different,
                    });
                }
            }
            if !agreeing.is_empty() {
                agreeing.sort_unstable();
                let mut entry = vec![x.index];
                entry.extend(agreeing);
                same.push(entry);
            }
        }

        notes.sort_unstable_by_key(|note| (note.a, note.b));
        same.sort_unstable_by_key(|entry| entry[0]);
        Report { same, notes }
    }

    /// 一次迭代用的随机输入：index 可重复，但同 index 的内容一致，便于验证顺序无关。
    fn random_items(rng: &mut Rng) -> Vec<Instant> {
        let table: Vec<Instant> = (0..10)
            .map(|index| {
                let seconds = match rng.below(16) {
                    0 => i64::MIN,
                    1 => i64::MAX,
                    _ => {
                        let step = rng.below(33) as i64 - 16;
                        let mut s = BASE + step * 900;
                        if rng.flag() {
                            s += 37;
                        }
                        s
                    }
                };
                Instant {
                    index,
                    group: rng.below(3) as usize,
                    seconds,
                    zone: ZONES[rng.below(4) as usize].to_string(),
                    zoned: rng.flag(),
                    has_clock: rng.flag(),
                }
            })
            .collect();
        let len = rng.below(13) as usize;
        (0..len)
            .map(|_| table[rng.below(10) as usize].clone())
            .collect()
    }

    #[test]
    fn randomized_property_test() {
        let seed_offset = std::env::var("MEANTIME_FUZZ_SEED")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(0);
        let iterations = std::env::var("MEANTIME_FUZZ_ITERATIONS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(2000);
        let seed = 0x9E37_79B9_7F4A_7C15 ^ seed_offset;
        let mut rng = Rng(if seed == 0 { 0x1234_5678 } else { seed });

        for _ in 0..iterations {
            let items = random_items(&mut rng);
            let expected = oracle(&items);
            let got = crosscheck(&items);
            assert_eq!(got, expected);

            let mut reversed = items.clone();
            reversed.reverse();
            assert_eq!(crosscheck(&reversed), got);
        }
    }
}
