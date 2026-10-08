// SPDX-License-Identifier: GPL-3.0-only
//! 只读词表借用静态切片；测试保留原建表器的所有权。
use std::cmp::Ordering;
use std::hash::{BuildHasherDefault, Hasher};
use std::ops::Deref;

/// 只装静态词表的散列表用的快速散列（FxHash 同法）：键都来自词表，用户文字只用来查。
/// 查表结果与散列函数无关；这些表也不按迭代顺序产生输出。
#[derive(Clone, Copy, Default)]
pub(super) struct FxHasher(u64);

impl FxHasher {
    #[inline]
    fn add(&mut self, word: u64) {
        self.0 = (self.0.rotate_left(5) ^ word).wrapping_mul(0x51_7c_c1_b7_27_22_0a_95);
    }
}

impl Hasher for FxHasher {
    #[inline]
    fn write(&mut self, bytes: &[u8]) {
        let mut chunks = bytes.chunks_exact(8);
        for chunk in &mut chunks {
            self.add(u64::from_le_bytes(chunk.try_into().expect("eight bytes")));
        }
        let rest = chunks.remainder();
        if !rest.is_empty() {
            let mut word = [0u8; 8];
            word[..rest.len()].copy_from_slice(rest);
            self.add(u64::from_le_bytes(word));
        }
    }
    #[inline]
    fn write_u8(&mut self, value: u8) { self.add(u64::from(value)); }
    #[inline]
    fn write_usize(&mut self, value: usize) { self.add(value as u64); }
    #[inline]
    fn finish(&self) -> u64 { self.0 }
}

pub(super) type FastMap<K, V> = std::collections::HashMap<K, V, BuildHasherDefault<FxHasher>>;
pub(super) type FastSet<K> = std::collections::HashSet<K, BuildHasherDefault<FxHasher>>;

/// 与 `str::cmp` 相同的字节字典序。词表键很短，逐字节比较比调用 `memcmp` 省事。
#[inline]
pub(super) fn cmp_text(a: &str, b: &str) -> Ordering {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    for (x, y) in a.iter().zip(b) {
        if x != y { return x.cmp(y); }
    }
    a.len().cmp(&b.len())
}

#[derive(Debug)]
pub(super) enum Slice<T: 'static> {
    Borrowed(&'static [T]),
    #[cfg(test)]
    Owned(Box<[T]>),
}

impl<T: 'static> Slice<T> {
    pub(super) fn as_slice(&self) -> &[T] {
        match self {
            Self::Borrowed(values) => values,
            #[cfg(test)]
            Self::Owned(values) => values,
        }
    }
}

impl<T: 'static> Deref for Slice<T> {
    type Target = [T];
    fn deref(&self) -> &[T] { self.as_slice() }
}

impl<'a, T: 'static> IntoIterator for &'a Slice<T> {
    type Item = &'a T;
    type IntoIter = std::slice::Iter<'a, T>;
    fn into_iter(self) -> Self::IntoIter { self.iter() }
}

impl<T: PartialEq + 'static> PartialEq for Slice<T> {
    fn eq(&self, other: &Self) -> bool { self.as_slice() == other.as_slice() }
}

impl<T: Eq + 'static> Eq for Slice<T> {}

#[derive(Debug)]
pub(super) enum Text {
    Borrowed(&'static str),
    #[cfg(test)]
    Owned(Box<str>),
}

impl AsRef<str> for Text {
    fn as_ref(&self) -> &str {
        match self {
            Self::Borrowed(value) => value,
            #[cfg(test)]
            Self::Owned(value) => value,
        }
    }
}

/// 目录按完整键排序；同一键的候选列表保持原顺序。
pub(super) struct StrMap<V: ?Sized + 'static> {
    pub(super) entries: &'static [(&'static str, &'static V)],
}

impl<V: ?Sized + 'static> StrMap<V> {
    pub(super) fn get(&self, key: &str) -> Option<&'static V> {
        self.entries.binary_search_by(|(candidate, _)| cmp_text(candidate, key))
            .ok().map(|index| self.entries[index].1)
    }

    pub(super) fn contains_key(&self, key: &str) -> bool { self.get(key).is_some() }
}

pub(super) struct WordsMap<V: ?Sized + 'static> {
    pub(super) entries: &'static [(&'static [&'static str], &'static V)],
}

impl<V: ?Sized + 'static> WordsMap<V> {
    pub(super) fn get(&self, key: &[&str]) -> Option<&'static V> {
        self.entries.binary_search_by(|(candidate, _)| candidate.cmp(&key))
            .ok().map(|index| self.entries[index].1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn directories_keep_exact_unicode_and_complete_sequence_keys() {
        let text = StrMap { entries: &[("alpha", &1usize), ("東京", &2usize)] };
        assert_eq!(text.get("alpha"), Some(&1));
        assert_eq!(text.get("東京"), Some(&2));
        assert_eq!(text.get("alph"), None);
        assert_eq!(text.get("東京駅"), None);
        assert!(!text.contains_key("unknown"));
        const ONE: &[&str] = &["am"];
        const TWO: &[&str] = &["am", "pm"];
        let words = WordsMap { entries: &[(ONE, &3usize), (TWO, &4usize)] };
        assert_eq!(words.get(&["am"]), Some(&3));
        assert_eq!(words.get(&["am", "pm"]), Some(&4));
        assert_eq!(words.get(&[]), None);
        assert_eq!(words.get(&["am", "pm", "tail"]), None);
        let empty: WordsMap<usize> = WordsMap { entries: &[] };
        assert_eq!(empty.get(&[]), None);
    }
}
