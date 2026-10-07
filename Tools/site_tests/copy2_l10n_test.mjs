// SPDX-License-Identifier: GPL-3.0-only
// site/when.html 的语言目录测试：把页面里的 strings 与 booking 两个字面量逐字取出，只把字面量放进 Node 的隔离 vm 求值（不做浏览器自动化，也不跑整个页面脚本）。
// 断言两套词典在十六种语言下语言集与键集完全一致；zh/pt 映射正确——zh-TW/HK/MO/Hant 进 zh-Hant，其余 zh-* 进 zh，pt-BR/pt-PT 进 pt，
// 映射与回退同样逐字取页面源码在 vm 里求值；每条文案非空、没有 @n/value: 一类标注路径残留。
// fill 不在页面 __DAYSIDE_TEST__ 暴露的钩子里（那里只有 decode/skyNow/laneStops/sunPosition/inkHex/paperHex），
// 于是也逐字取页面源码求值真 fill（不写替代实现），用互不相同的样本格式化每一条：
// 占位符集与 zh 的一致、格式化后不剩 {p}/{d}/{a}/{b}、每个原有占位符的样本都活着。
// 由 when_test.mjs 末尾的 await import 带跑：node Tools/site_tests/when_test.mjs
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import assert from "node:assert/strict";
import vm from "node:vm";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(root, "site", "when.html"), "utf8");
const script = html.match(/<script>([\s\S]*)<\/script>/)[1];

// 逐字取页面源码里的一条声明；找不到就失败，绝不静默改用替代实现。
function sourceOf(name, pattern) {
  const found = script.match(pattern);
  assert.ok(found, `site/when.html 里有 ${name}`);
  return found[1];
}
// 字面量只在隔离 vm 里求值成数据。
function objectLiteral(name) {
  const source = sourceOf(`const ${name} = {…}`, new RegExp(`const ${name} = (\\{[\\s\\S]*?\\r?\\n\\s*\\});`));
  return vm.runInNewContext("(" + source + ")", {});
}

const strings = objectLiteral("strings");
const booking = objectLiteral("booking");
const fill = vm.runInNewContext("(" + sourceOf("fill 格式化函数", /^[ \t]*const fill = (.+);\s*$/m) + ")", {});
const languageSource = sourceOf("language 推导", /^[ \t]*const language = (.+);\s*$/m);
const keySource = sourceOf("语言键推导", /^[ \t]*const key = (.+);\s*$/m);
const sPick = sourceOf("strings 回退", /^[ \t]*const s = (strings\[key\] \|\| strings\.en);\s*$/m);
const bPick = sourceOf("booking 回退", /^[ \t]*const b = (booking\[key\] \|\| booking\.en);\s*$/m);
// zh/pt 映射与回退都按页面自己的推导原样求值：navigator.language → 语言键 → 词典那一栏（缺了落 en）。
const pageKey = tag => vm.runInNewContext(`"use strict"; const language = ${languageSource}; const key = ${keySource}; key;`, { navigator: { language: tag } });
const pagePick = (pick, key) => vm.runInNewContext(`(${pick})`, { strings, booking, key });

// 十六种语言：两套词典的语言集一致，且就是页面在用的那十六个。
const LANGUAGES = ["en", "zh", "zh-Hant", "ja", "ko", "de", "fr", "es", "pt", "ru", "it", "nl", "pl", "tr", "vi", "id"];
assert.deepEqual(Object.keys(strings).sort(), [...LANGUAGES].sort(), "strings 的语言集");
assert.deepEqual(Object.keys(booking).sort(), [...LANGUAGES].sort(), "booking 的语言集");
for (const [name, dict] of [["strings", strings], ["booking", booking]]) {
  const zhKeys = Object.keys(dict.zh).sort();
  for (const language of LANGUAGES) assert.deepEqual(Object.keys(dict[language]).sort(), zhKeys, `${name}.${language} 的键集`);
}

// zh/pt 映射：繁体地区进 zh-Hant，其余 zh-* 进 zh，pt 系进 pt；映射到的那一栏两套词典都取得到。
for (const [tag, want] of [
  ["en-US", "en"], ["zh-CN", "zh"], ["zh-SG", "zh"], ["zh-Hans-CN", "zh"], ["zh", "zh"], ["zh-tw", "zh-Hant"],
  ["zh-TW", "zh-Hant"], ["zh-HK", "zh-Hant"], ["zh-MO", "zh-Hant"], ["zh-Hant", "zh-Hant"], ["zh-Hant-TW", "zh-Hant"],
  ["pt-BR", "pt"], ["pt-PT", "pt"], ["pt", "pt"],
]) {
  assert.equal(pageKey(tag), want, `${tag} 的语言键`);
  assert.equal(pagePick(sPick, want), strings[want], `${tag} 取到 strings.${want}`);
  assert.equal(pagePick(bPick, want), booking[want], `${tag} 取到 booking.${want}`);
}
// 页面没有的语言：按页面自己的回退落 en。
assert.equal(pageKey("xx-YY"), "xx");
assert.equal(pagePick(sPick, "xx"), strings.en, "未知语言回退 strings.en");
assert.equal(pagePick(bPick, "xx"), booking.en, "未知语言回退 booking.en");

// 接收页的前缀保留空格，紧跟日期时仍有分隔。
for (const [language, expected] of [["en", "Available: "], ["ru", "Время для встреч: "], ["nl", "Beschikbaar: "]]) {
  assert.equal(strings[language].free, expected);
  assert.match(fill(strings[language].free, {}) + "SampleDay", /: SampleDay$/);
}

const placeholders = value => [...value.matchAll(/\{(\w+)\}/g)].map(match => match[1]).sort();
// 样本互不相同：哪个占位符被换上、哪个被弄丢，都看得出来。
const samples = { p: "SampleP", d: "SampleD", a: "SampleA", b: "SampleB" };
assert.equal(new Set(Object.values(samples)).size, 4, "p/d/a/b 的样本互不相同");

// 每一条都过一遍：非空、没有标注路径、占位符集与 zh 一致、真 fill 格式化后不剩占位符且样本都活着。
let formattedCount = 0;
for (const [name, dict] of [["strings", strings], ["booking", booking]]) {
  for (const language of LANGUAGES) {
    for (const [key, value] of Object.entries(dict[language])) {
      const where = `${name}.${language}.${key}`;
      assert.equal(typeof value, "string", `${where} 是字符串`);
      assert.ok(value.length > 0, `${where} 非空`);
      assert.doesNotMatch(value, /@\d+\//, `${where} 没有标注路径（@n/value: 之类）`);
      assert.doesNotMatch(value, /^@\d+:/, `${where} 没有原样 @n: 标注`);
      const marks = placeholders(value);
      assert.deepEqual(marks, placeholders(dict.zh[key]), `${where} 的占位符集与 zh 一致`);
      const formatted = fill(value, samples);
      assert.doesNotMatch(formatted, /\{[pdab]\}/, `${where} 格式化后不剩 {p}/{d}/{a}/{b}`);
      for (const mark of marks) assert.ok(formatted.includes(samples[mark]), `${where} 的 {${mark}} 换上了自己的样本`);
      formattedCount += 1;
    }
  }
}
console.log(`copy2 l10n: ${LANGUAGES.length} 种语言、两套词典共 ${formattedCount} 条，键集 / zh·pt 映射 / 占位符 / fill 格式化全部通过`);
