// SPDX-License-Identifier: GPL-3.0-only
// 仅供显式测试生成器启动；普通审计拒绝此表。
use super::language::{Lookup, Phrase as LanguagePhrase};
use super::table_storage::{Slice, StrMap, WordsMap};
use super::units::Matcher;

pub(super) const GENERATED: bool = false;
pub(super) static LANGUAGE: Lookup<LanguagePhrase> = Lookup {
    nodes: Slice::Borrowed(&[]), edges: Slice::Borrowed(&[]), values: Slice::Borrowed(&[]),
};
pub(super) static MATCHER: Matcher = Matcher {
    by_first: StrMap { entries: &[] },
    abbreviations: StrMap { entries: &[] },
    zone_words: StrMap { entries: &[] },
    sem_langs: WordsMap { entries: &[] },
};
