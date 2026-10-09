#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 优化的 Release 测试宿主；隔离身份与正式包使用同一预览生成器。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source_root="$root"
out=""
legacy=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) source_root="${2:?}"; shift 2 ;;
    --out) out="${2:?}"; shift 2 ;;
    --legacy) legacy=1; shift ;;
    --help) echo 'Tools/perf_build.sh --out <new scratch directory> [--source <checkout>] [--legacy]'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$out" && ! -e "$out" ]] || { echo 'Choose a new scratch output directory.' >&2; exit 1; }
source_root="$(cd "$source_root" && pwd)"
project_name=Dayside
if (( legacy )); then
  project_name="$(python3 - "$source_root" <<'PY'
from pathlib import Path
import sys
projects = [p for p in Path(sys.argv[1]).glob('*.xcodeproj') if (p / 'project.pbxproj').is_file()]
if len(projects) != 1:
    raise SystemExit('Expected exactly one pinned baseline project')
print(projects[0].stem)
PY
)"
fi
[[ -f "$source_root/$project_name.xcodeproj/project.pbxproj" ]] || exit 1
[[ -f "$source_root/$project_name/Models/Diagnostics/PerformanceProbe.swift" ]] || { echo 'The checkout needs the committed performance test-host hooks.' >&2; exit 1; }
out="$(python3 - "$out" <<'PY'
from pathlib import Path
import sys
import tempfile
output = Path(sys.argv[1]).resolve()
roots = {Path('/private/tmp').resolve(), Path(tempfile.gettempdir()).resolve()}
if not any(output != root and output.is_relative_to(root) for root in roots):
    raise SystemExit('Build output must be in temporary scratch storage.')
print(output)
PY
)"
mkdir -p "$out"
free_kib=$(df -k /System/Volumes/Data | awk 'NR == 2 { print $4 }')
(( free_kib >= 6291456 )) || { echo 'Less than 6 GiB is free; clean your build products before building.' >&2; exit 1; }
cleanup() { "$root/Tools/ls_unregister_copies.sh" >/dev/null 2>&1 || true; }
trap cleanup EXIT
flags='$(inherited) DEBUG MEANTIME_MAIN_APP'
if (( legacy )); then flags="$flags DAYSIDE_PRO DAYSIDE_PERF_LEGACY"; fi
nice -n 10 \
  /bin/bash -c '
    set -euo pipefail
    source_root=$1; out=$2; flags=$3; root=$4; project_name=$5
    printf "started\n" > "$out/command-started"
    trap '\''"$root/Tools/ls_unregister_copies.sh" >/dev/null 2>&1 || true'\'' EXIT
    cd "$source_root"
    git rev-parse HEAD > "$out/source-commit.txt"
    printf "%s\n" "$flags" > "$out/build-flags.txt"
    git diff --binary > "$out/source-overlay.patch"
    git ls-files --others --exclude-standard -z > "$out/untracked-paths.nul"
    xcodebuild -project "$project_name.xcodeproj" -scheme "$project_name" -configuration Release \
      -destination "platform=macOS,arch=arm64" -derivedDataPath "$out/dd" -jobs 3 \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
      "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$flags" build > "$out/build.log" 2>&1
    CARGO_TARGET_DIR="$out/tool-target" "$source_root/Tools/make_local_preview.sh" \
      "$out/dd/Build/Products/Release/Dayside.app" "$out/Dayside.app" > "$out/preview.log" 2>&1
    /usr/bin/codesign --verify --deep --strict "$out/Dayside.app"
    /usr/bin/codesign -d --verbose=2 "$out/Dayside.app" > "$out/signature.log" 2>&1
    /usr/bin/shasum -a 256 "$out/Dayside.app/Contents/MacOS/Dayside" > "$out/executable-sha256.txt"
    /usr/bin/ditto "$out/dd/Build/Products/Release/Dayside.app.dSYM" "$out/Dayside.app.dSYM"
    python3 - "$out" <<'\''PY'\''
from pathlib import Path
import shutil
import sys
out = Path(sys.argv[1])
for name in ("dd", "tool-target"):
    shutil.rmtree(out / name)
PY
    echo "$out/Dayside.app"
  ' perf-build "$source_root" "$out" "$flags" "$root" "$project_name"
