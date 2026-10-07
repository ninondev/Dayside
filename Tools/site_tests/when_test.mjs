// SPDX-License-Identifier: GPL-3.0-only
// site/when.html 的脚本级测试：在 Node 里用最小 DOM 跑真实脚本，断言解码、内嵌名片、时钟与计时器、预约起点、邮件、.ics、十语与安全策略，
// 以及明信片：天色与 App 的 Rust 一致（同一份夹具 sky_fixture.json）、那边今天的天与可约时段的细轨、那边比你快慢多少。
// 运行：node Tools/site_tests/when_test.mjs
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import assert from "node:assert/strict";
import { makeDocument } from "./minidom.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(root, "site", "when.html"), "utf8");
const script = html.match(/<script>([\s\S]*)<\/script>/)[1];

const ids = {
  heading: "h1", status: "p", content: "main", "their-label": "p", "your-label": "p", "availability-title": "h2",
  "converted-title": "h2", "no-availability": "p", privacy: "p", "snapshot-note": "p", "their-time": "time", "your-time": "time",
  "their-date": "p", "your-date": "p", "their-zone": "p", "your-zone": "p", availability: "section", schedule: "div", snapshot: "p",
  "window-status": "p", windows: "ul", booking: "section", "booking-title": "h2", "booking-start-label": "label", "booking-start": "select",
  "booking-length-label": "label", "booking-length": "select", "booking-name-label": "label", "booking-name": "input", "booking-note-label": "label",
  "booking-note": "textarea", "booking-preview": "p", "booking-no-email": "p", "booking-mail": "a", "booking-ics": "button", "booking-copy": "button", "booking-close": "button",
  card: "article", sky: "div", ruler: "div", track: "div", lane: "div", rail: "div", "now-line": "div", free: "p", offset: "p",
};

// embedded：App 存下来的独立页面，RustCore/src/sharing.rs 把 __MEANTIME_PAYLOAD__ 换成 mt1. 名片，打开时没有 # 片段。
function loadPage(fragment, { language = "zh-CN", now = Date.now(), timeZone = "America/Los_Angeles", embedded = null, clipboardFailure = false } = {}) {
  const document = makeDocument(ids);
  const created = [];
  const blobs = [];
  const clip = { text: null };
  const realDTF = Intl.DateTimeFormat;
  const timers = new Map(); let timerID = 0; const delays = [];
  // 页面脚本按测试替身把天色函数交出来（浏览器里没有这个名字，什么都不交）。
  const hooks = {};
  // window 与 document 的监听器记在一处（hashchange、pagehide、visibilitychange 不重名），测试用 fire 触发。
  const listeners = {};
  const on = (type, fn) => { (listeners[type] ||= []).push(fn); };
  document.addEventListener = on;
  let network = 0;
  function deny() { network += 1; throw new Error("分享页不该连网"); }
  const env = {
    document, navigator: { language, clipboard: { writeText: async t => { if (clipboardFailure) throw new Error("Clipboard unavailable"); clip.text = t; } } },
    location: { hash: fragment ? "#" + fragment : "" }, addEventListener: on,
    setTimeout: (fn, ms) => { timers.set(++timerID, fn); delays.push(ms); return timerID; }, clearTimeout: id => { timers.delete(id); },
    fetch: deny, XMLHttpRequest: deny, WebSocket: deny,
    Date: class extends Date { constructor(...a) { super(...(a.length ? a : [now])); } static now() { return now; } },
    URL: { createObjectURL: b => { blobs.push(b); return "blob:x"; }, revokeObjectURL() {} },
    Blob: class { constructor(parts, opts) { this.parts = parts; this.type = opts?.type; } async text() { return this.parts.join(""); } },
    Intl: { ...Intl, DateTimeFormat: function (loc, opts) { return new realDTF(loc, { ...opts, timeZone: opts?.timeZone ?? timeZone }); }, ListFormat: Intl.ListFormat, NumberFormat: Intl.NumberFormat },
    TextDecoder, atob: s => Buffer.from(s, "base64").toString("binary"), encodeURIComponent, Math, console, Number, String, Array, Object, JSON, RegExp, Error, Uint8Array, Buffer,
    __DAYSIDE_TEST__: hooks,
  };
  env.Intl.DateTimeFormat.prototype = realDTF.prototype;
  env.Intl.DateTimeFormat.supportedLocalesOf = realDTF.supportedLocalesOf;
  // resolvedOptions.timeZone 走真实实现；这里让「访客时区」可控。
  const resolved = realDTF.prototype.resolvedOptions;
  realDTF.prototype.resolvedOptions = function () { const r = resolved.call(this); return { ...r, timeZone: r.timeZone || timeZone }; };
  try {
    new Function(...Object.keys(env), embedded ? script.replaceAll("__MEANTIME_PAYLOAD__", embedded) : script)(...Object.values(env));
  } finally { realDTF.prototype.resolvedOptions = resolved; }
  assert.equal(network, 0, "加载时发了网络请求");
  return { document, blobs, clip, location: env.location, timers, delays, hooks, fire: type => { for (const fn of listeners[type] || []) fn(); }, byID: id => document.getElementById(id) };
}

const b64 = o => Buffer.from(JSON.stringify(o)).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const now = 1789600000; // 2026-09-16 UTC 附近
const schedule = { startMinute: 540, endMinute: 1080, workingWeekdays: [2, 3, 4, 5, 6], isWholeDay: false, endDayOffset: 0 };
const card = (extra = {}) => "mt1." + b64({
  version: 1, timeZoneID: "Asia/Shanghai", displayName: "成都的 Alice", schedule,
  generatedAt: now - 3600, validUntil: now + 7 * 86400,
  windows: [{ start: now + 300, end: now + 300 + 35 * 60 }, { start: now + 7200, end: now + 7200 + 4 * 3600 }],
  contactEmail: "alice@example.com", ...extra,
});
// 只有时钟、没分享时段的名片。
const clock = () => "mt1." + b64({ version: 1, timeZoneID: "Asia/Tokyo", generatedAt: now - 3600, validUntil: now + 7 * 86400, windows: [] });

let passed = 0;
const tests = [];
function test(name, fn) { tests.push([name, fn]); }

test("合法名片解出两个时段并给每个时段一个「选这个时段」按钮", () => {
  const page = loadPage(card(), { now: now * 1000 });
  assert.equal(page.byID("content").hidden, false);
  assert.equal(page.byID("heading").textContent, "成都的 Alice");
  assert.equal(page.document.querySelectorAll("button.pick").length, 2);
});

test("坏名片、mt1 前缀外的文本、超长都判为无效", () => {
  for (const bad of ["mt1.!!!", "dp1.AAAA", "mt1." + b64({ version: 2 }), "mt1." + "A".repeat(40000)]) {
    const page = loadPage(bad, { now: now * 1000 });
    assert.equal(page.byID("content").hidden, true, bad.slice(0, 12));
  }
});

test("不合形的预约邮箱当没有：没有邮件按钮，只剩日历与复制", () => {
  const page = loadPage(card({ contactEmail: "not an email" }), { now: now * 1000 });
  page.document.querySelectorAll("button.pick")[1].click();
  assert.equal(page.byID("booking-mail").hidden, true);
  assert.equal(page.byID("booking-no-email").hidden, false);
  assert.equal(page.byID("booking-ics").disabled, false);
});

test("起点只在现在与窗口终点之间，且装得下所选时长；时长变了重列", () => {
  const page = loadPage(card(), { now: now * 1000 });
  const picks = page.document.querySelectorAll("button.pick");
  picks[1].click();
  const start = page.byID("booking-start"), length = page.byID("booking-length");
  const w = { start: now + 7200, end: now + 7200 + 4 * 3600 };
  const fits = len => start.options.every(o => Number(o.value) >= w.start && Number(o.value) + len * 60 <= w.end);
  assert.equal(length.value, "60");
  assert.ok(start.options.length >= 6 && fits(60));
  length.value = "120"; length.dispatchEvent({ type: "input" });
  assert.ok(fits(120) && start.options.length < 8);
  // 35 分钟的短窗口：60 分钟装不下 → 禁用；改 30 分钟 → 窗口自身起点成为候选
  picks[0].click();
  assert.equal(page.byID("booking-ics").disabled, true);
  assert.equal(page.byID("booking-mail").hidden, true);
  length.value = "30"; length.dispatchEvent({ type: "input" });
  assert.equal(start.options.length, 1);
  assert.equal(page.byID("booking-ics").disabled, false);
});

test("邮件链接与预览文字带两地时间、UTC 与名片时区标签", () => {
  const page = loadPage(card(), { now: now * 1000 });
  page.document.querySelectorAll("button.pick")[1].click();
  page.byID("booking-name").value = "Ana"; page.byID("booking-name").dispatchEvent({ type: "input" });
  const href = page.byID("booking-mail").href;
  assert.ok(href.startsWith("mailto:alice%40example.com?subject="), href.slice(0, 60));
  const body = decodeURIComponent(href.split("&body=")[1]);
  assert.ok(body.startsWith("Ana：我想和你约在："), body.slice(0, 30));
  assert.ok(body.includes("(America/Los_Angeles)") && body.includes("(Asia/Shanghai)") && body.includes("UTC："), body);
});

test("预约预览只给访客两地时间，导出仍有完整请求与 UTC", () => {
  const page = loadPage(card(), { now: now * 1000 });
  page.document.querySelectorAll("button.pick")[1].click();
  const preview = page.byID("booking-preview").textContent;
  assert.ok(preview.startsWith("你的时间："));
  assert.ok(preview.includes("对方时间："));
  assert.ok(!preview.includes("UTC：") && !preview.includes("我想和你约在："));
  const body = decodeURIComponent(page.byID("booking-mail").href.split("&body=")[1]);
  assert.ok(body.includes("我这边：") && body.includes("你那边：") && body.includes("UTC："));
  assert.ok(body.includes("不会自动写进任何人的日历"));
});

test("时长装不下的局部反馈在改短后消失", () => {
  const page = loadPage(card(), { now: now * 1000, language: "en-US" });
  page.document.querySelectorAll("button.pick")[0].click();
  assert.equal(page.byID("booking-preview").textContent, "This time is too short for that length. Choose a shorter length or another time.");
  page.byID("booking-length").value = "30";
  page.byID("booking-length").dispatchEvent({ type: "input" });
  assert.ok(!page.byID("booking-preview").textContent.includes("too short"));
  assert.equal(page.byID("booking-copy").disabled, false);
});

test("复制失败给可选择的完整请求文本，编辑后收起", async () => {
  const page = loadPage(card(), { now: now * 1000, clipboardFailure: true });
  page.document.querySelectorAll("button.pick")[1].click();
  page.byID("booking-copy").click();
  await new Promise(r => setImmediate(r));
  const local = id => page.byID("booking").children.find(n => n.id === id);
  assert.equal(local("booking-error").hidden, false);
  assert.equal(local("booking-error").textContent, "无法复制预约文本，请手动选中复制。");
  const manual = local("booking-manual-copy");
  assert.equal(manual.hidden, false);
  assert.equal(manual.readOnly, true);
  assert.ok(manual.value.includes("UTC：") && manual.value.includes("不会自动写进任何人的日历"));
  page.byID("booking-note").value = "新的备注";
  page.byID("booking-note").dispatchEvent({ type: "input" });
  assert.equal(manual.hidden, true);
  assert.equal(local("booking-error").hidden, true);
});

test("固定偏移名片的标签印名片自己的时区名，不写成 UTC", () => {
  const page = loadPage(card({ timeZoneID: "GMT+0545", fixedOffsetSeconds: 20700 }), { now: now * 1000 });
  page.document.querySelectorAll("button.pick")[1].click();
  assert.ok(page.byID("booking-preview").textContent.includes("(GMT+0545)"));
  assert.ok(!page.byID("booking-preview").textContent.includes("(UTC)"));
});

test(".ics 是 CRLF、UTC 戳、转义过的 DESCRIPTION、没有 METHOD、每行 ≤ 75 字节且展开后原样", async () => {
  const page = loadPage(card(), { now: now * 1000 });
  page.document.querySelectorAll("button.pick")[1].click();
  page.byID("booking-note").value = "a;b,c\nline2 " + "备注很长".repeat(40); page.byID("booking-note").dispatchEvent({ type: "input" });
  page.byID("booking-ics").click();
  assert.equal(page.blobs.length, 1);
  const ics = await page.blobs[0].text();
  assert.ok(ics.includes("\r\nBEGIN:VEVENT\r\n") && /DTSTART:\d{8}T\d{6}Z/.test(ics), ics.slice(0, 80));
  assert.ok(!ics.includes("METHOD:"), "METHOD:PUBLISH 要 ORGANIZER，不该出现");
  assert.ok(ics.endsWith("END:VCALENDAR\r\n"));
  const lines = ics.split("\r\n");
  for (const line of lines) assert.ok(Buffer.byteLength(line, "utf8") <= 75, `超过 75 字节：${line}`);
  const unfolded = ics.replace(/\r\n /g, "");
  assert.ok(unfolded.includes("a\\;b\\,c\\nline2 " + "备注很长".repeat(40)), "折行展开后 DESCRIPTION 原样");
  assert.ok(lines.some(l => l.startsWith(" ")), "长 DESCRIPTION 确实被折了");
});

test("mailto 整条超过 2,000 字节时去掉备注并提示用复制", () => {
  const page = loadPage(card(), { now: now * 1000 });
  page.document.querySelectorAll("button.pick")[1].click();
  page.byID("booking-note").value = "备注".repeat(250); page.byID("booking-note").dispatchEvent({ type: "input" });
  const href = page.byID("booking-mail").href;
  assert.ok(href.length <= 2000, `mailto ${href.length} 字节`);
  const body = decodeURIComponent(href.split("&body=")[1]);
  assert.ok(!body.includes("备注备注"), "备注该被拿掉");
  assert.ok(body.includes("备注太长"), body.slice(-80));
  const localNote = page.byID("booking").children.find(n => n.id === "booking-mail-note");
  assert.equal(localNote.hidden, false);
  assert.equal(localNote.textContent, "备注太长，没放进邮件。请点“复制预约文本”，再粘贴进邮件。");
  // 短备注照常进邮件
  page.byID("booking-note").value = "短备注"; page.byID("booking-note").dispatchEvent({ type: "input" });
  assert.ok(decodeURIComponent(page.byID("booking-mail").href.split("&body=")[1]).includes("短备注"));
  assert.equal(localNote.hidden, true);
});

test("复制在无效状态下不写剪贴板", async () => {
  const page = loadPage(card(), { now: now * 1000 });
  page.document.querySelectorAll("button.pick")[0].click(); // 35 分钟窗口，默认 60 分钟装不下
  page.byID("booking-copy").click();
  await new Promise(r => setImmediate(r));
  assert.equal(page.clip.text, null);
});

test("十六种界面语言都有自己的页面文字与预约文字，不退回英文", () => {
  const english = loadPage(card(), { now: now * 1000, language: "en-US" });
  const englishLabel = english.byID("their-label").textContent;
  english.document.querySelectorAll("button.pick")[1].click();
  const englishBooking = english.byID("booking-title").textContent;
  for (const language of ["zh-CN", "zh-TW", "ja-JP", "ko-KR", "de-DE", "fr-FR", "es-ES", "pt-BR", "ru-RU",
                          "it-IT", "nl-NL", "pl-PL", "tr-TR", "vi-VN", "id-ID"]) {
    const page = loadPage(card(), { now: now * 1000, language });
    assert.equal(page.byID("content").hidden, false, language);
    assert.ok(page.byID("their-label").textContent.length > 0, language);
    assert.notEqual(page.byID("their-label").textContent, englishLabel, language);
    page.document.querySelectorAll("button.pick")[1].click();
    assert.notEqual(page.byID("booking-title").textContent, englishBooking, language);
  }
});

// 测试 DOM 支持 TextEncoder 与事件监听器，覆盖预约表单及名片解析。
// .ics 折行后的名片也必须能读出，避免测试替身提前失败而漏掉页面行为。
test("没有名片也没有内嵌数据：正文藏着，提示去开分享链接，不起计时器", () => {
  const page = loadPage("", { language: "en-US", now: now * 1000 });
  assert.equal(page.byID("content").hidden, true);
  assert.equal(page.byID("status").textContent, "Open a link or web page shared from Dayside.");
  assert.equal(page.timers.size, 0);
});

test("App 存下来的独立页面没有 # 片段，读内嵌名片", () => {
  const page = loadPage("", { embedded: clock(), language: "en-US", now: now * 1000 });
  assert.equal(page.byID("content").hidden, false);
  // 时区行 = IANA 标识符 + 括号里的 Intl shortOffset，偏移按页面的 new Date 取，这里钉在 now。
  assert.equal(page.byID("their-zone").textContent, "Asia/Tokyo (GMT+9)");
  assert.equal(page.byID("availability").hidden, true);
});

test("对方与访客的时钟各按自己的时区走", () => {
  const page = loadPage(clock(), { language: "en-US", now: now * 1000 });
  assert.equal(page.byID("your-zone").textContent, "America/Los_Angeles (GMT-7)");
  assert.notEqual(page.byID("their-time").textContent, page.byID("your-time").textContent);
  // 钟点只写到分钟（与 App 的明信片同一个样子；此前带秒、每秒跳一次）。
  assert.equal(page.byID("their-time").textContent, new Intl.DateTimeFormat("en-US", { timeZone: "Asia/Tokyo", timeStyle: "short" }).format(new Date(now * 1000)));
});

test("固定偏移名片按刻钟换算对方的钟点、日期与时段，访客这边不跟着偏", () => {
  // now 是 UTC 23:06，+05:45 会跨到次日，日期也要跟着换。
  const utc = options => new Intl.DateTimeFormat("en-US", { timeZone: "UTC", ...options });
  for (const [timeZoneID, fixedOffsetSeconds] of [["GMT+0545", 20700], ["GMT-0330", -12600], ["UTC+00:00", 0]]) {
    const page = loadPage(card({ timeZoneID, fixedOffsetSeconds, windows: [{ start: now + 3600, end: now + 7200 }] }), { language: "en-US", now: now * 1000 });
    assert.equal(page.byID("content").hidden, false, timeZoneID);
    assert.equal(page.byID("their-zone").textContent, timeZoneID);
    const shifted = new Date((now + fixedOffsetSeconds) * 1000);
    assert.equal(page.byID("their-time").textContent, utc({ timeStyle: "short" }).format(shifted));
    assert.equal(page.byID("their-date").textContent, utc({ weekday: "short", month: "short", day: "numeric" }).format(shifted));
    assert.equal(page.byID("your-time").textContent, new Intl.DateTimeFormat("en-US", { timeZone: "America/Los_Angeles", timeStyle: "short" }).format(new Date(now * 1000)));
    const theirs = utc({ dateStyle: "medium", timeStyle: "short" }).formatRange(new Date((now + 3600 + fixedOffsetSeconds) * 1000), new Date((now + 7200 + fixedOffsetSeconds) * 1000));
    assert.ok(page.byID("windows").children[0].children[1].textContent.endsWith(theirs), timeZoneID);
  }
});

test("名字里的 Unicode 与像脚本的文字原样当文字显示", () => {
  const name = "明 <script>alert(1)</script>";
  const page = loadPage(card({ displayName: name, windows: [{ start: now + 3600, end: now + 7200 }] }), { now: now * 1000 });
  assert.equal(page.byID("heading").textContent, name);
  const items = page.byID("windows").children;
  assert.equal(items.length, 1);
  // 一个时段一项，预约按钮进入表单；minidom 的 innerHTML 必须支持页面更新。
  assert.deepEqual(items[0].children.map(c => c.tagName), ["P", "P", "BUTTON"]);
});

test("快照过期有明确的提示，一个时段也不列", () => {
  const page = loadPage(card(), { language: "en-US", now: (now + 8 * 86400) * 1000 });
  assert.match(page.byID("window-status").textContent, /expired/);
  assert.equal(page.byID("windows").children.length, 0);
});

test("切走标签停表，切回只续一只表，离开页面停表", () => {
  const page = loadPage(clock(), { now: now * 1000 });
  assert.equal(page.timers.size, 1);
  page.document.hidden = true; page.fire("visibilitychange"); assert.equal(page.timers.size, 0);
  page.document.hidden = false; page.fire("visibilitychange"); assert.equal(page.timers.size, 1);
  page.fire("pagehide"); assert.equal(page.timers.size, 0);
});

test("换成读不出的片段：标题不再是旧名字，正文藏起，计时器停掉", () => {
  const page = loadPage(card(), { now: now * 1000 });
  page.location.hash = "#mt1.invalid"; page.fire("hashchange");
  assert.equal(page.byID("content").hidden, true);
  assert.equal(page.document.title, "Dayside");
  assert.equal(page.timers.size, 0);
});

test("字段不合规的名片判为无效：正文藏起，不起计时器", () => {
  const bad = [card({ version: 2 }), card({ timeZoneID: "Mars/Olympus_Mons" }), card({ displayName: "bad\nname" }),
    ...[null, "20700", 64801, -64801, 0.5].map(fixedOffsetSeconds => card({ fixedOffsetSeconds })),
    card({ windows: [{ start: 0, end: 2 }] }), card({ schedule: { ...schedule, workingWeekdays: [] } })];
  bad.forEach((fragment, i) => {
    const page = loadPage(fragment, { now: now * 1000 });
    assert.equal(page.byID("content").hidden, true, `第 ${i} 张`);
    assert.equal(page.timers.size, 0, `第 ${i} 张`);
  });
});

test("App 支持的十种语言都有页面文字", () => {
  for (const language of ["en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "de-DE", "fr-FR", "es-ES", "pt-BR", "ru-RU"]) {
    const page = loadPage(card(), { language, now: now * 1000 });
    assert.equal(page.byID("content").hidden, false, language);
    assert.ok(page.byID("privacy").textContent.length > 20, language);
    assert.notEqual(page.byID("their-label").textContent, "", language);
    if (!language.startsWith("en")) assert.notEqual(page.byID("their-label").textContent, "Their local time", language);
  }
});

test("安全策略：不连网、不引外部资源、不写 HTML", () => {
  assert.match(html, /default-src 'none'/);
  assert.match(html, /connect-src 'none'/);
  assert.doesNotMatch(html, /<script\s+src=|<link\s+rel=["']stylesheet|<iframe|<form\b|innerHTML/);
});

// —— 明信片（2026-10-02 起）——
// 新名片带地名、拉丁写法与那座城的坐标（四舍五入到 0.1°）；页面按坐标画那边此刻的天、今天的天。
const fixture = JSON.parse(readFileSync(join(root, "Tools", "site_tests", "sky_fixture.json"), "utf8"));
const channels = hex => [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16));
const near = (a, b) => channels(a).every((v, i) => Math.abs(v - channels(b)[i]) <= 1);
const tokyoCard = (extra = {}) => card({ timeZoneID: "Asia/Tokyo", displayName: "Mei", place: "东京", city: "Tokyo", latitude: 35.7, longitude: 139.7, ...extra });

test("天色与 App 的 Rust 一致：太阳高度、此刻的天、写墨还是写纸、要不要渐变、一天的色标（同一份夹具）", () => {
  const page = loadPage(clock(), { now: now * 1000 });
  const { skyNow, laneStops, sunPosition } = page.hooks;
  let exact = 0, total = 0;
  for (const c of fixture.panel) {
    const position = sunPosition(c.instant, c.latitude, c.longitude);
    assert.ok(Math.abs(position.altitude - c.altitude) < 0.002, `${c.instant} 高度 ${position.altitude} 对 ${c.altitude}`);
    assert.equal(position.rising, c.rising, `${c.instant}`);
    const got = skyNow(c.instant, c.latitude, c.longitude);
    assert.equal(got.ink, c.ink, `${c.instant} 墨还是纸`);
    assert.equal(got.gradient, c.gradient, `${c.instant} 渐变`);
    for (const k of ["top", "horizon", "mid"]) { total += 1; if (got[k] === c[k]) exact += 1; assert.ok(near(got[k], c[k]), `${c.instant} ${k} ${got[k]} 对 ${c[k]}`); }
  }
  for (const lane of fixture.lanes) {
    const got = laneStops(lane.start, lane.end, lane.latitude, lane.longitude);
    assert.equal(got.length, lane.stops.length);
    got.forEach((color, i) => { total += 1; if (color === lane.stops[i]) exact += 1; assert.ok(near(color, lane.stops[i]), `色标 ${i}：${color} 对 ${lane.stops[i]}`); });
  }
  console.log(`  天色夹具：${exact} / ${total} 个颜色逐位相同，其余每个通道相差不过 1`);
});

test("明信片：名字是标题，下面一行是地名与拉丁写法；标签页写「名字 · 地名」；上半涂那边此刻的天，字是墨或纸", () => {
  const page = loadPage(tokyoCard(), { now: now * 1000 });
  assert.equal(page.byID("heading").textContent, "Mei");
  assert.equal(page.byID("their-zone").textContent, "东京 · Tokyo");
  assert.equal(page.document.title, "Mei · 东京");
  const expected = page.hooks.skyNow(now, 35.7, 139.7);
  const sky = page.byID("sky").style;
  assert.ok(sky.background.includes(expected.gradient ? expected.top : expected.mid), sky.background);
  assert.equal(sky.color, expected.ink ? page.hooks.inkHex : page.hooks.paperHex);
  // 没有名字：地名当标题，下面只写拉丁写法；旧名片没有地名，写时区与偏移（上面几条测试）。
  const unnamed = loadPage(tokyoCard({ displayName: undefined }), { now: now * 1000 });
  assert.equal(unnamed.byID("heading").textContent, "东京");
  assert.equal(unnamed.byID("their-zone").textContent, "Tokyo");
  assert.equal(unnamed.document.title, "东京");
});

test("明信片下半：那边今天的天（每 10 分钟一个色标）、可约时段的细轨（跨午夜的分成两截）、此刻一根竖线、刻度 0 6 12 18", () => {
  // 东京今天是 9 月 17 日（东京零点 = 9 月 16 日 15:00 UTC）。每天 21:00–2:00：昨晚那段留到今天 2:00，今晚那段从 21:00 起。
  const dayStart = Date.UTC(2026, 8, 16, 15) / 1000;
  const windows = [{ start: dayStart - 3 * 3600, end: dayStart + 2 * 3600 }, { start: dayStart + 21 * 3600, end: dayStart + 26 * 3600 }];
  const overnight = { startMinute: 1260, endMinute: 120, workingWeekdays: [1, 2, 3, 4, 5, 6, 7], isWholeDay: false, endDayOffset: 1 };
  const page = loadPage(tokyoCard({ schedule: overnight, windows, generatedAt: dayStart - 4 * 3600, validUntil: dayStart + 10 * 86400 }), { now: now * 1000 });
  const stops = page.byID("lane").style.background.match(/#[0-9a-f]{6}/g);
  assert.equal(stops.length, 145);
  assert.deepEqual(stops, page.hooks.laneStops(dayStart, dayStart + 86400, 35.7, 139.7));
  const segments = page.byID("rail").children.map(c => [parseFloat(c.style.left), parseFloat(c.style.width)]);
  assert.equal(segments.length, 2, JSON.stringify(segments));
  assert.ok(Math.abs(segments[0][0]) < 0.01 && Math.abs(segments[0][1] - 100 * 2 / 24) < 0.01, JSON.stringify(segments));
  assert.ok(Math.abs(segments[1][0] - 100 * 21 / 24) < 0.01 && Math.abs(segments[1][1] - 100 * 3 / 24) < 0.01, JSON.stringify(segments));
  assert.ok(Math.abs(parseFloat(page.byID("now-line").style.left) - 100 * (now - dayStart) / 86400) < 0.01, page.byID("now-line").style.left);
  assert.equal(page.byID("ruler").children.map(c => c.textContent).join(" "), "0 6 12 18");
  assert.equal(page.byID("free").textContent, "可约：每天 · 21:00–次日 02:00 · 东京时间");
  // 没有分享可约时段：没有细轨，也没有那一行。
  const bare = loadPage(tokyoCard({ schedule: undefined, windows: [] }), { now: now * 1000 });
  assert.equal(bare.byID("rail").hidden, true);
  assert.equal(bare.byID("free").hidden, true);
});

test("那边比你快慢多少按面板的说法写（半小时的时区也写全），同一时区不写", () => {
  assert.equal(loadPage(tokyoCard(), { now: now * 1000 }).byID("offset").textContent, "东京 快 16小时");
  assert.equal(loadPage(tokyoCard({ place: "Tokyo", city: undefined }), { now: now * 1000, language: "en-US" }).byID("offset").textContent, "Tokyo 16 hours ahead");
  assert.equal(loadPage(card({ timeZoneID: "Asia/Kolkata", place: "加尔各答" }), { now: now * 1000 }).byID("offset").textContent, "加尔各答 快 12小时30分钟");
  assert.equal(loadPage(card({ timeZoneID: "Pacific/Honolulu", place: "檀香山" }), { now: now * 1000 }).byID("offset").textContent, "檀香山 慢 3小时");
  assert.equal(loadPage(card({ timeZoneID: "America/Los_Angeles", place: "洛杉矶" }), { now: now * 1000 }).byID("offset").hidden, true);
  // 旧名片没有地名：用时区标识符最后一段（下划线换空格）。
  assert.equal(loadPage(clock(), { now: now * 1000, language: "en-US" }).byID("offset").textContent, "Tokyo 16 hours ahead");
});

test("星期：连着三天以上写一段，一周按圈算（周日至周四），零散的列出来，七天写每天", () => {
  const free = (days, language = "en-US") =>
    loadPage(card({ schedule: { ...schedule, workingWeekdays: days }, timeZoneID: "Asia/Tokyo", place: "Tokyo" }), { now: now * 1000, language }).byID("free").textContent;
  assert.match(free([2, 3, 4, 5, 6]), /^Available: Mon–Fri · 9:00\s?AM/);
  assert.match(free([1, 2, 3, 4, 5]), /^Available: Sun–Thu · /);
  assert.match(free([2, 4, 6]), /^Available: Mon, Wed, and Fri · /);
  assert.match(free([1, 2, 3, 4, 5, 6, 7]), /^Available: Every day · /);
  assert.match(free([2, 3, 4, 5, 6], "zh-CN"), /^可约：周一至周五 · 09:00–18:00 · Tokyo时间$/);
  assert.match(free([2, 3, 4, 5, 6], "ja-JP"), /^予約可能: 月〜金 · /);
});

test("坏的地名与坐标当没有：名片照收，地名去控制符、截到 80 个字符，天按纸色", () => {
  const page = loadPage(card({ place: "a\u0007b", city: "x".repeat(200), latitude: 95, longitude: 10 }), { now: now * 1000 });
  assert.equal(page.byID("content").hidden, false);
  assert.equal(page.byID("heading").textContent, "成都的 Alice");
  assert.equal(page.byID("their-zone").textContent, "ab · " + "x".repeat(80));
  assert.equal(page.byID("sky").style.background, "");
  assert.equal(page.byID("lane").style.background, "");
});

test("可选明信片字段类型错误时仍收名片，坐标只保留完整的一对", () => {
  for (const key of ["place", "city", "latitude", "longitude"]) {
    const wrongScalar = ["place", "city"].includes(key) ? 17 : "35.7";
    for (const bad of [null, true, [], {}, wrongScalar]) {
      const fragment = tokyoCard({ [key]: bad });
      const page = loadPage(fragment, { now: now * 1000 });
      assert.equal(page.byID("content").hidden, false, `${key}=${JSON.stringify(bad)}`);
      const p = page.hooks.decode(fragment);
      assert.equal(p[key], undefined);
      assert.equal(p.timeZoneID, "Asia/Tokyo");
      assert.equal(p.displayName, "Mei");
      assert.equal(p.windows.length, 2);
      if (key === "place") assert.equal(p.city, undefined);
      if (["latitude", "longitude"].includes(key)) {
        assert.equal(p.latitude, undefined); assert.equal(p.longitude, undefined);
        assert.equal(p.place, "东京"); assert.equal(p.city, "Tokyo");
        assert.equal(page.byID("sky").style.background, "");
      } else {
        assert.equal(p.latitude, 35.7); assert.equal(p.longitude, 139.7);
      }
    }
  }
});

test("地名清理后相同或缺地名时不留拉丁写法", () => {
  for (const [place, city, wantPlace, wantCity] of [
    [undefined, "Tokyo", undefined, undefined], ["\u0007  ", "Tokyo", undefined, undefined],
    [" Tokyo\u0007 ", " Tokyo ", "Tokyo", undefined], ["长".repeat(81), "长".repeat(80), "长".repeat(80), undefined],
    [" 东京 ", " Tokyo ", "东京", "Tokyo"],
  ]) {
    const fragment = tokyoCard({ place, city });
    const page = loadPage(fragment, { now: now * 1000 });
    const p = page.hooks.decode(fragment);
    assert.equal(page.byID("content").hidden, false);
    assert.equal(p.place, wantPlace); assert.equal(p.city, wantCity);
    if (wantPlace && !wantCity) assert.equal(page.byID("their-zone").textContent, wantPlace);
  }
});

test("收方坐标舍入到 0.1 度，正负半格与边界同 App，缺失或越界丢掉整对", () => {
  for (const [latitude, longitude, wantLat, wantLon] of [
    [35.6895, 139.69171, 35.7, 139.7], [0.05, -0.05, 0.1, -0.1], [-35.65, -139.75, -35.7, -139.8],
    [90, 180, 90, 180], [-90, -180, -90, -180],
  ]) {
    const fragment = tokyoCard({ latitude, longitude });
    const page = loadPage(fragment, { now: now * 1000 });
    const p = page.hooks.decode(fragment);
    assert.equal(page.byID("content").hidden, false);
    assert.equal(p.latitude, wantLat); assert.equal(p.longitude, wantLon);
    const expected = page.hooks.skyNow(now, wantLat, wantLon);
    assert.ok(page.byID("sky").style.background.includes(expected.gradient ? expected.top : expected.mid));
  }
  for (const [latitude, longitude] of [[undefined, 10], [30, undefined], [90.01, 10], [30, 180.01]]) {
    const fragment = tokyoCard({ latitude, longitude });
    const page = loadPage(fragment, { now: now * 1000 });
    const p = page.hooks.decode(fragment);
    assert.equal(page.byID("content").hidden, false);
    assert.equal(p.latitude, undefined); assert.equal(p.longitude, undefined);
    assert.equal(page.byID("sky").style.background, "");
  }
});

test("钟点只写到分钟，计时器到下一分钟整点再走一格（此前每秒一次）", () => {
  const at = now * 1000 + 12_345;
  const page = loadPage(clock(), { now: at });
  assert.equal(page.delays.at(-1), 60000 - (at % 60000));
  assert.equal(page.byID("their-time").textContent, new Intl.DateTimeFormat("zh-CN", { timeZone: "Asia/Tokyo", timeStyle: "short" }).format(new Date(at)));
});

for (const [name, fn] of tests) { await fn(); passed += 1; console.log("✔", name); }
console.log(`site tests: ${passed} passed`);
await import("./copy2_l10n_test.mjs");
