// SPDX-License-Identifier: GPL-3.0-only
//! 文本折叠与切词（「听懂时间」引擎）。
//!
//! 折叠后的每个字符都记着它来自原文的哪一段（UTF-16 偏移，宿主拿它在输入框下标出读懂了哪几个字）。
//! 折叠只为匹配：全角转半角、各种破折号与波浪号归成 `-`、拉丁 / 希腊 / 西里尔字母去掉附加符号并小写
//! （`ı` / `İ` → `i`、`ł` → `l`、`đ` → `d`、`ß` → `ss`），中日韩字母原样（假名的浊点、谚文的音节都不拆）。
//! 词表里的词按同一个函数折叠，所以两边永远对得上；越南语、土耳其语用户不打声调符号也认。
use unicode_normalization::UnicodeNormalization;

/// 折叠后的文本：`chars[i]` 来自原文 UTF-16 区间 `span[i]`。
#[derive(Debug, Clone)]
pub struct Folded {
    pub chars: Vec<char>,
    pub span: Vec<(usize, usize)>,
    /// 原文的字符（与 `chars` 一一对应，一个原文字符折成两个时重复），缩写要看原文大小写（`ET` 与 `et`）。
    pub original: Vec<char>,
    source: String,
    source_bytes: Vec<usize>,
}

impl Folded {
    /// 折叠后 `from..to`（非空）对应的那段原文字节。
    pub(super) fn source_text(&self, from: usize, to: usize) -> &str {
        &self.source[self.source_bytes[from]..self.source_bytes[to - 1] + self.original[to - 1].len_utf8()]
    }

    /// 附近名字核对原始字节，保留折叠时略过的附加符号和连接字符。
    pub(super) fn nearby_original(&self, from: usize, to: usize) -> &str {
        let start = if from == 0 { 0 } else { self.source_bytes[from - 1] + self.original[from - 1].len_utf8() };
        let end = self.source_bytes.get(to).copied().unwrap_or(self.source.len());
        &self.source[start..end]
    }
}

pub fn is_han(c: char) -> bool {
    matches!(c as u32, 0x4e00..=0x9fff | 0x3400..=0x4dbf | 0xf900..=0xfaff | 0x20000..=0x2ffff)
}
pub fn is_kana(c: char) -> bool {
    matches!(c as u32, 0x3040..=0x30ff | 0x31f0..=0x31ff | 0xff66..=0xff9f)
}
pub fn is_hangul(c: char) -> bool {
    matches!(c as u32, 0xac00..=0xd7a3 | 0x1100..=0x11ff | 0x3130..=0x318f)
}
pub fn is_cjk(c: char) -> bool {
    // 中日韩字母都在 U+1100（谚文字母）之后；前面的字符不必逐段比较。
    (c as u32) >= 0x1100 && (is_han(c) || is_kana(c) || is_hangul(c) || c == '々' || c == 'ー')
}

fn decomposable(c: char) -> bool {
    // 拉丁（含越南语用的扩展区）、希腊、西里尔：去附加符号。中日韩不动。
    (c as u32) < 0x0530 || (0x1e00..=0x1eff).contains(&(c as u32))
}

/// ASCII 字符的折叠：与 `fold_char` 相同（回车→空格、垂直制表与换页→换行、~→-、`→'，再小写），总是正好一个字符。
#[inline]
fn fold_ascii(c: char) -> char {
    match c {
        '\r' => ' ',
        '\u{b}' | '\u{c}' => '\n',
        '~' => '-',
        '`' => '\'',
        _ => c.to_ascii_lowercase(),
    }
}

/// 一个字符折成零到几个字符。
fn fold_char(c: char, out: &mut Vec<char>) {
    if c.is_ascii() {
        out.push(fold_ascii(c));
        return;
    }
    // Joiners and the byte-order mark are formatting; a zero-width space separates words.
    if matches!(c, '\u{200c}' | '\u{200d}' | '\u{feff}') { return; }
    let c = match c as u32 {
        0xff01..=0xff5e => char::from_u32(c as u32 - 0xfee0).unwrap_or(c),
        0x3000 | 0x00a0 | 0x2007 | 0x202f | 0x2009 | 0x200a | 0x200b => ' ',
        // 回车只是换行的伴生（\r\n），换行本身留着：装配要知道哪几处在同一行、哪里是空行。
        0x000d => ' ',
        0x2028 | 0x2029 | 0x000b | 0x000c => '\n',
        _ => c,
    };
    let c = match c {
        '–' | '—' | '−' | '‒' | '―' | '‐' | '‑' | '〜' | '～' | '~' | '－' | '∼' => '-',
        '：' => ':',
        '，' | '、' => ',',
        '’' | '‘' | '`' | '´' | 'ʼ' => '\'',
        '“' | '”' | '„' | '«' | '»' | '「' | '」' | '『' | '』' => '"',
        '（' => '(',
        '）' => ')',
        '／' => '/',
        _ => c,
    };
    // 常用字符不需要 Unicode 分解，前面的标点与控制符归一仍照常执行。
    if c.is_ascii() {
        out.push(c.to_ascii_lowercase());
        return;
    }
    match c {
        'ı' | 'İ' => out.push('i'),
        'ł' | 'Ł' => out.push('l'),
        'đ' | 'Đ' => out.push('d'),
        'ø' | 'Ø' => out.push('o'),
        'ß' => out.extend(['s', 's']),
        'æ' | 'Æ' => out.extend(['a', 'e']),
        'œ' | 'Œ' => out.extend(['o', 'e']),
        _ if decomposable(c) => {
            for d in c.nfd() {
                if unicode_normalization::char::is_combining_mark(d) {
                    continue;
                }
                // 分解后的基字也走同一套折叠，避免连字与大写字母留下第二次才会改变的字符。
                for lower in d.to_lowercase() {
                    if lower == c {
                        out.push(lower);
                    } else {
                        fold_char(lower, out);
                    }
                }
            }
        }
        _ => out.push(c),
    }
}

/// 词表里的词用同一个折叠（不记位置）。
pub fn fold_str(s: &str) -> String {
    let mut out = Vec::new();
    for c in s.chars() {
        fold_char(c, &mut out);
    }
    out.into_iter().collect()
}

pub fn fold(input: &str) -> Folded {
    // 折叠后的字符数通常不超过原文字节数：按它预留，不在逐字追加时反复扩容复制。
    let mut folded = Folded { chars: Vec::with_capacity(input.len()), span: Vec::with_capacity(input.len()), original: Vec::with_capacity(input.len()), source: input.to_owned(), source_bytes: Vec::with_capacity(input.len()) };
    let mut offset = 0usize;
    let mut buffer = Vec::new();
    for (byte, c) in input.char_indices() {
        if c.is_ascii() {
            folded.chars.push(fold_ascii(c));
            folded.span.push((offset, offset + 1));
            folded.original.push(c);
            folded.source_bytes.push(byte);
            offset += 1;
            continue;
        }
        let width = c.len_utf16();
        buffer.clear();
        fold_char(c, &mut buffer);
        for &f in &buffer {
            folded.chars.push(f);
            folded.span.push((offset, offset + width));
            folded.original.push(c);
            folded.source_bytes.push(byte);
        }
        offset += width;
    }
    folded
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Number,
    Word,
    Cjk,
    Punct,
    Space,
    /// 换行（一个字符一个记号；连续两个中间只隔空白就是空行）。
    Newline,
}

/// 一个词：种类与折叠后的文字（字符下标见 `spans`）。
#[derive(Debug, Clone)]
pub struct Token {
    pub kind: Kind,
    pub text: String,
}


fn is_word_char(c: char) -> bool {
    c.is_alphabetic() && !is_cjk(c)
}

/// 切词：数字串、字母串（撇号夹在字母中间算词内，`let's` / `l'est` / `o'clock`）、中日韩串、标点、空白、换行。
pub fn tokens(f: &Folded) -> Vec<Token> {
    spans(f).into_iter()
        .map(|(kind, start, end)| Token { kind, text: f.chars[start..end].iter().collect() })
        .collect()
}

/// 与 `tokens` 同样切分，只给（种类，起，止），需要文字的调用方自己取。
pub(super) fn spans(f: &Folded) -> Vec<(Kind, usize, usize)> {
    let chars = &f.chars;
    // 每段至少一个字符：按字符数预留，追加时不再扩容复制。
    let mut out = Vec::with_capacity(chars.len());
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        let start = i;
        let kind = if c.is_ascii_digit() {
            while i < chars.len() && chars[i].is_ascii_digit() {
                i += 1;
            }
            Kind::Number
        } else if is_cjk(c) {
            while i < chars.len() && is_cjk(chars[i]) {
                i += 1;
            }
            Kind::Cjk
        } else if is_word_char(c) {
            while i < chars.len()
                && (is_word_char(chars[i])
                    || (chars[i] == '\'' && i + 1 < chars.len() && is_word_char(chars[i + 1]) && i > start))
            {
                i += 1;
            }
            Kind::Word
        } else if c == '\n' {
            i += 1;
            Kind::Newline
        } else if c.is_whitespace() {
            while i < chars.len() && chars[i].is_whitespace() && chars[i] != '\n' {
                i += 1;
            }
            Kind::Space
        } else {
            i += 1;
            Kind::Punct
        };
        out.push((kind, start, i));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ascii_fast_path_preserves_controls_punctuation_and_offsets() {
        let input = "A\rB\u{b}C\u{c}D~E`F\0\t12";
        let expected = "a b\nc\nd-e'f\0\t12";
        let folded = fold(input);
        assert_eq!(folded.chars.iter().collect::<String>(), expected);
        assert_eq!(fold_str(input), expected);
        assert_eq!(folded.original.iter().collect::<String>(), input);
        assert_eq!(folded.span, (0..input.len()).map(|i| (i, i + 1)).collect::<Vec<_>>());
    }

    #[test]
    fn folding_matches_what_people_type_without_accents_and_keeps_offsets() {
        assert_eq!(fold_str("İstanbul"), "istanbul");
        assert_eq!(fold_str("Thứ Hai"), "thu hai");
        assert_eq!(fold_str("Łódź"), "lodz");
        assert_eq!(fold_str("Straße"), "strasse");
        assert_eq!(fold_str("１５：００"), "15:00");
        assert_eq!(fold_str("月曜日"), "月曜日", "中日韩不动");
        assert_eq!(fold_str("ガ"), "ガ", "假名的浊点不拆");
        assert_eq!(fold_str("월요일"), "월요일", "谚文不拆成字母");
        assert_eq!(fold_str("Завтра"), "завтра");
        assert_eq!(fold_str("13:00–15:00"), "13:00-15:00");
        let f = fold("Łódź 😀 3PM");
        assert_eq!(f.chars.iter().collect::<String>(), "lodz 😀 3pm");
        // 表情占两个 UTF-16 单元：后面的偏移跟着挪。
        let p = f.chars.iter().position(|c| *c == '3').unwrap();
        assert_eq!(f.span[p], (8, 9));
        assert_eq!(f.original[p], '3');
    }

    #[test]
    fn decomposed_ligatures_fold_once_and_keep_original_spans() {
        let folded = fold("ẞǢǼǾ");
        assert_eq!(fold_str("ẞǢǼǾ"), "ssaeaeo");
        assert_eq!(folded.chars.iter().collect::<String>(), "ssaeaeo");
        assert_eq!(folded.span, [(0, 1), (0, 1), (1, 2), (1, 2), (2, 3), (2, 3), (3, 4)]);
        assert_eq!(folded.original.iter().collect::<String>(), "ẞẞǢǢǼǼǾ");
    }

    #[test]
    fn tokens_split_digits_letters_and_scripts() {
        let f = fold("Let's meet 24T14:00 在东京3点 o'clock");
        let t: Vec<_> = tokens(&f).into_iter().filter(|t| t.kind != Kind::Space).map(|t| t.text).collect();
        assert_eq!(t, ["let's", "meet", "24", "t", "14", ":", "00", "在东京", "3", "点", "o'clock"]);
    }
}
