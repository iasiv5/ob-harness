#!/usr/bin/env bash
# tests/unit/bare_mirror.sh — bare_mirror module leaf-pure 函数单测(unit 层)。
# 在当前 shell 顶层调用 bare_mirror_provision / bare_mirror_base / bare_mirror_print_status,
# 让 coverage radar 的 xtrace 采集整条 module 函数链(含私有 _bare_mirror_reset /
# _bare_mirror_emit_plan)。orchestration 层用 bash -c 子 shell,xtrace 不穿透,故 unit 层补偿。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
assert_reset

DB="$(mktemp -d)"; mkfake_bin "$DB" git
stub_script "$DB" git 'case "$1" in config) exit 0 ;; esac
if [[ "$1" == "clone" || "${3:-}" == "clone" ]]; then mkdir -p "${@: -1}"; exit 0; fi
exit 0'

# --- 成功 provision(1 new):顶层 with_stub 当前 shell 调用 → xtrace 采集 module 函数链 ---
root="$(mktemp -d)"; build="$root/openbmc/build/romulus"; mkdir -p "$build/conf"
printf '# comment-only local.conf\n' > "$build/conf/local.conf"
printf '[{"name":"r1","clone_url":"https://example.com/r1.git","src_uri":"git://example.com/r1.git;branch=main"}]\n' > "$build/deps.json"
mbase="$root/downloads/git2"
WORKSPACE_DIR="$root"; BUILD_DIR="$build"; MACHINE="romulus"; DRY_RUN=0; VERBOSE=0
with_stub "$DB" -- bare_mirror_provision "$build/deps.json" "$mbase" "$build" >/dev/null
assert_eq       "provision rc=0"            "$?" 0
assert_eq       "base after provision"      "$(bare_mirror_base)" "$mbase"
assert_contains "status counts"             "$(bare_mirror_print_status romulus)" "Mirrors populated: 1 new, 0 existing"
rm -rf "$root"

# --- 捐坏 JSON:bare_mirror_provision return 1,initialized 保持 0,base/status 空 ---
bad_root="$(mktemp -d)"; bad_build="$bad_root/openbmc/build/romulus"; mkdir -p "$bad_build/conf"
printf '# comment-only local.conf\n' > "$bad_build/conf/local.conf"
printf '{bad json' > "$bad_build/deps.json"
bad_mbase="$bad_root/downloads/git2"
WORKSPACE_DIR="$bad_root"; BUILD_DIR="$bad_build"
with_stub "$DB" -- bare_mirror_provision "$bad_build/deps.json" "$bad_mbase" "$bad_build" >/dev/null
assert_eq "bad provision rc=1"            "$?" 1
assert_eq "base empty after failure"      "$(bare_mirror_base)" ""
assert_eq "status empty after failure"    "$(bare_mirror_print_status romulus)" ""
rm -rf "$bad_root" "$DB"

assert_summary
