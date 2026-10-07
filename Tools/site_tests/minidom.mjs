// SPDX-License-Identifier: GPL-3.0-only
// 给 site/when.html 的脚本一个最小的 DOM：够 getElementById / createElement / 事件 / options / textContent 用，
// 不渲染、不排版。目的只是让页面脚本在 Node 里跑起来，断言它的解码、预约起点、邮件与 .ics 逻辑。
export class Element {
  constructor(tag, id) {
    this.tagName = tag.toUpperCase(); this.id = id || ""; this.children = []; this.attrs = {}; this.listeners = {};
    this.hidden = false; this.disabled = false; this.textContent = ""; this.className = ""; this._value = "";
    this.dateTime = ""; this.type = ""; this.download = ""; this.href = ""; this.selected = false;
    // 名片上的天与细轨按内联样式画（背景渐变、位置、宽度）：只记下写进去的值，不排版。
    this.style = {};
  }
  // 名片里的名字是别人写的，页面只该用 textContent；写 innerHTML 直接抛，不让测试悄悄放过。
  set innerHTML(_) { throw new Error("不安全的 HTML 写入"); }
  get options() { return this.tagName === "SELECT" ? this.children : []; }
  // <select> 像浏览器一样：显式设过且在选项里就用它，否则取标了 selected 的，再否则第一个。
  get value() {
    if (this.tagName !== "SELECT") return this._value;
    const opts = this.options;
    if (opts.some(o => o._value === this._value)) return this._value;
    return (opts.find(o => o.selected) || opts[0])?._value ?? "";
  }
  set value(v) { this._value = String(v); }
  append(...nodes) { for (const n of nodes) this.children.push(n); }
  appendChild(n) { this.children.push(n); return n; }
  replaceChildren(...nodes) { this.children = [...nodes]; }
  remove() {}
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  dispatchEvent(event) { for (const fn of this.listeners[event.type] || []) fn(event); return true; }
  click() { this.dispatchEvent({ type: "click", preventDefault() { this.defaulted = true; } }); }
  setAttribute(k, v) { this.attrs[k] = String(v); if (k === "href") this.href = String(v); }
  getAttribute(k) { return k === "href" ? this.href : (this.attrs[k] ?? null); }
  scrollIntoView() {}
  focus() {}
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  querySelectorAll(sel) {
    const out = [];
    const cls = sel.startsWith("button.") ? sel.slice(7) : null;
    const walk = n => { for (const c of n.children) { if (cls ? (c.tagName === "BUTTON" && c.className === cls) : c.tagName === sel.toUpperCase()) out.push(c); walk(c); } };
    walk(this); return out;
  }
}
export function makeDocument(ids) {
  const byId = new Map();
  const doc = {
    documentElement: new Element("html"), body: new Element("body"), title: "__MEANTIME_TITLE__", hidden: false,
    getElementById: id => byId.get(id) || null,
    createElement: tag => new Element(tag),
    addEventListener() {},
    querySelector(sel) { return doc.body.querySelector(sel); },
    querySelectorAll(sel) { return doc.body.querySelectorAll(sel); },
  };
  for (const [id, tag] of Object.entries(ids)) { const e = new Element(tag, id); byId.set(id, e); doc.body.appendChild(e); }
  return doc;
}
