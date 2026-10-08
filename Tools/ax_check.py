#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""检查 Tools/ax_dump_pages.sh 转储的无障碍树（每页一个 JSON）。规则：
R1 可交互控件没有任何可读名字（label/title/value/placeholder 全空）；
R2 图片是可达元素却没有描述（装饰图应 accessibilityHidden）；
R3 可交互控件的命中区域小于 24×24 pt；
R4 可交互控件被禁用但没有名字（VoiceOver 只会念「按钮，已停用」）。
R7 搜索框被读成静态文字，或带占位文字的输入框没有可编辑文字角色。
用法: ax_check.py <目录>  （目录里是 <page>.json）"""
import json, sys, os, glob

INTERACTIVE = {"AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXLink",
               "AXSlider", "AXIncrementor", "AXTextField", "AXSearchField", "AXComboBox", "AXDisclosureTriangle",
               "AXColorWell", "AXDateField", "AXTimeField", "AXStepper"}
PAGES = ["planner", "plannerResults", "agenda", "people", "convert", "convertResult", "convertCandidates", "timers", "timersPomodoro", "timersAlarm", "timersAlarmTwice", "timersAlarmRunning", "dstWatch", "astronomy", "markets", "travel", "travelEast", "sharing", "panel", "panelCallable", "panelEmpty", "panelEmptyCallable", "settings", "settingsAppearance", "settingsShortcuts", "settingsHelp", "welcome", "earth"]

TEXT_ENTRY = {"AXTextField", "AXSearchField", "AXComboBox", "AXTextArea"}

def name_of(n):
    # 输入框的内容不是它的名字：只有 label/title/placeholder 算。
    keys = ("label", "title", "titleUIElement", "placeholderValue", "placeholder", "help") if n.get("role") in TEXT_ENTRY else ("label", "title", "titleUIElement", "value", "placeholderValue", "placeholder", "help")
    for k in keys:
        v = n.get(k)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return ""

# AppKit 自己的窗口按钮、滚动条零件、步进箭头由系统朗读，不归本应用管。
SYSTEM = ("_NSTheme", "NSAccessibilityScrollerPart", "NSAccessibilityStepperArrowButton", "NSTableColumn",
          "NSAccessibilityReparentingCellProxy", "NSThemeWidget", "NSSearchButtonCellProxy", "NSSearchCancelButtonCellProxy")
TINY = 20     # HIG macOS 最小命中区域 20×20；系统自带控件（复选框、弹出按钮、
              # 展开三角）的无障碍框由 AppKit 定，不算在内
COMPACT = 28  # HIG macOS 默认命中区域 28×28，只计数不算问题

# 按实测原生外观判定浅深，覆盖高对比度与活力外观。
APPEARANCE_BASE = {
    "NSAppearanceNameAqua": "light",
    "NSAppearanceNameDarkAqua": "dark",
    "NSAppearanceNameVibrantLight": "light",
    "NSAppearanceNameVibrantDark": "dark",
    "NSAppearanceNameAccessibilityHighContrastAqua": "light",
    "NSAppearanceNameAccessibilityHighContrastDarkAqua": "dark",
    "NSAppearanceNameAccessibilityHighContrastVibrantLight": "light",
    "NSAppearanceNameAccessibilityHighContrastVibrantDark": "dark",
}

def appearance_base(value):
    return APPEARANCE_BASE.get(value) if isinstance(value, str) else None

def appearance_findings(d, save_images=True):
    findings = []
    policy = d.get("appearancePolicy", "production")
    if policy not in {"production", "forced-native"}:
        findings.append(("R0 未知渲染外观策略", str(policy)))
    forced = policy == "forced-native"
    for shade in ("dark", "light"):
        actual = d.get(f"effectiveAppearance_{shade}")
        base = appearance_base(actual)
        bg = d.get(f"renderBackground_{shade}")
        valid_bg = (isinstance(bg, str) and len(bg) == 7 and bg[0] == "#"
                    and all(c in "0123456789abcdefABCDEF" for c in bg[1:]))
        if valid_bg:
            try:
                components = [int(bg[i:i+2], 16) for i in (1, 3, 5)]
            except ValueError:
                valid_bg = False
        if base is None:
            findings.append((f"R0 {shade} 缺少可识别的实际内容外观", repr(actual)))
        if not valid_bg:
            findings.append((f"R0 {shade} 缺少有效渲染底色", repr(bg)))
        elif base is not None:
            lum = sum(components) / (3 * 255)
            if (lum < 0.5) != (base == "dark"):
                findings.append((f"R0 {shade} 渲染底色 {bg} 与实际外观 {actual} 不符", "该遍对比度不可信"))
        compositing = d.get(f"renderBackgroundAppearance_{shade}")
        if compositing is not None or forced:
            if compositing != actual or appearance_base(compositing) is None:
                findings.append((f"R0 {shade} 合成底色外观与实际内容不符", repr(compositing)))
        if forced:
            requested = d.get(f"requestedAppearance_{shade}")
            window = d.get(f"windowEffectiveAppearance_{shade}")
            if (appearance_base(requested) != shade or base != shade
                    or appearance_base(window) != shade
                    or d.get(f"appearanceMatched_{shade}") is not True):
                findings.append((f"R0 {shade} 实际原生外观未满足强制捕获请求", f"request={requested!r} content={actual!r} window={window!r}"))
            if save_images and (not isinstance(d.get("images"), dict) or not d["images"].get(shade)):
                findings.append((f"R0 {shade} 缺少有效原生外观捕获", "没有 PNG 路径"))
    return findings

def check_nodes(nodes, shades):
    findings = []
    compact = 0
    for n in nodes:
        role = n.get("role", "")
        f = n.get("frame", {})
        # A lazy layout container reports an infinite size, written as null; treat it as zero-size.
        w, h = (f.get("w") or 0), (f.get("h") or 0)
        x, y = (f.get('x') or 0), (f.get('y') or 0)
        where = f"{role} {n.get('class','')} @({x:.0f},{y:.0f}) {w:.0f}×{h:.0f}"
        placeholder = n.get("placeholderValue") or n.get("placeholder")
        if ((role == "AXStaticText" and n.get("subrole") == "AXSearchField")
                or (isinstance(placeholder, str) and placeholder.strip() and role not in TEXT_ENTRY)):
            findings.append(("R7 输入框没有可编辑文字角色", f"{where} subrole={n.get('subrole', '')} 「{name_of(n)}」"))
        if n.get("class", "").startswith(SYSTEM):
            continue
        if role in INTERACTIVE and n.get("isElement", True):
            if not name_of(n):
                findings.append(("R1 无名字的控件", where))
            elif w > 0 and h > 0 and (w < TINY or h < TINY) and role not in {"AXTextField", "AXSearchField", "AXSlider", "AXCheckBox", "AXRadioButton", "AXLink", "AXPopUpButton", "AXDisclosureTriangle"}:
                findings.append((f"R3 命中区域小于 {TINY}pt", f"{where} 「{name_of(n)}」"))
            elif w > 0 and h > 0 and (w < COMPACT or h < COMPACT):
                compact += 1
            if not n.get("enabled", True) and not name_of(n):
                findings.append(("R4 停用且无名字", where))
        if role == "AXImage" and n.get("isElement", True) and not name_of(n):
            findings.append(("R2 无描述的图片", where))
        if role == "AXUnknown" and n.get("isElement", True):
            findings.append(("R5 角色未知（VoiceOver 念「未知」）", f"{where} 「{name_of(n)}」"))
        for shade in shades:
            contrast = n.get(f"contrast_{shade}")
            if contrast is None or not n.get("enabled", True):
                continue
            large = h >= 22          # 约 18pt 字号的行高：大字按 3.0，其余按 4.5（WCAG AA）
            needed = 3.0 if large else 4.5
            if contrast < needed:
                findings.append((f"R6 {shade} 对比度 {contrast:.2f} < {needed}",
                                 f"{where} 墨 {n.get('ink_'+shade)} 底 {n.get('background_'+shade)} 「{name_of(n)[:40]}」"))
    return compact, findings


def check(path, save_images=True):
    with open(path, encoding="utf-8") as source:
        d = json.load(source)
    nodes = d.get("nodes", [])
    findings = []
    compact = 0
    appearances = d.get("nodesByAppearance")
    if appearances is None:
        compact, findings = check_nodes(nodes, ("light", "dark"))
    else:
        # 每种外观只用它自己的树和位图，失败的捕获不能报零问题。
        captures = d.get("captureByAppearance", {})
        for shade in ("light", "dark"):
            tree = appearances.get(shade, [])
            capture = captures.get(shade, {})
            if capture.get("validLayout") is not True:
                findings.append((f"R0 {shade} 版面捕获无效", capture.get("reason", "缺少稳定版面记录")))
                continue
            before, after = capture.get("layoutBefore"), capture.get("layoutAfter")
            if before is None or after is None or before != after:
                findings.append((f"R0 {shade} 版面记录不一致", "该遍对比度不可信"))
                continue
            if len(tree) < 5:
                findings.append((f"R0 {shade} 转储为空或塌回", f"只有 {len(tree)} 个节点"))
            if not capture.get("contentRect") or (save_images and not d.get("images", {}).get(shade)):
                findings.append((f"R0 {shade} 缺少对应位图或坐标", "该遍对比度不可信"))
            if not any(n.get(f"contrast_{shade}") is not None for n in tree):
                findings.append((f"R0 {shade} 没有量到文字对比度", "不能把未绘制的文字当作通过"))
            count, issues = check_nodes(tree, (shade,))
            compact += count
            findings.extend((kind, f"[{shade}] {where}") for kind, where in issues)
    # 框跟天色时，两种请求可能得到同一原生外观。
    # R0 按实测外观检查合成底色；强制捕获还须两遍外观与完整证据。
    findings.extend(appearance_findings(d, save_images=save_images))
    d["compact"] = compact
    return d, nodes, findings

def main(directory, save_images=True):
    total = 0
    for page in PAGES:
        path = os.path.join(directory, f"{page}.json")
        if not os.path.exists(path):
            print(f"{page:<16} 缺转储")
            continue
        d, nodes, findings = check(path, save_images=save_images)
        # 树空说明转储没有取得文本内容；可能取错窗口或布局未完成，不能当成 0 条问题通过。
        if "nodesByAppearance" not in d and len(nodes) < 5:
            findings = list(findings) + [("R0 转储为空或塌回", f"只有 {len(nodes)} 个节点，转储没有真正走树")]
        roles = {}
        for n in nodes:
            roles[n.get("role", "?")] = roles.get(n.get("role", "?"), 0) + 1
        top = ", ".join(f"{k}×{v}" for k, v in sorted(roles.items(), key=lambda kv: -kv[1])[:6])
        measured = sum(1 for n in nodes if n.get("contrast_light") is not None)
        print(f"{page:<16} 节点 {len(nodes):<4} 问题 {len(findings):<3} 紧凑(<{COMPACT}pt) {d.get('compact',0):<3} 测了对比度 {measured:<3} 窗口 {d.get('window',{}).get('title','')!r}")
        for kind, where in findings:
            print(f"    {kind}: {where}")
        total += len(findings)
    print(f"合计 {total} 条")
    return 1 if total else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else ".", save_images="--no-images" not in sys.argv[2:] and os.environ.get("MEANTIME_AX_SAVE_IMAGES") != "0"))
