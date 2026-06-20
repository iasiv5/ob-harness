#!/usr/bin/env bash
# tests/unit/source_lock.sh — source lock 读写单测(unit 层,文件 IO)。
# 覆盖 read_kv_field / read_source_label / write_source_lock(含 DRY_RUN 分支)。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
FIX="$(cd "$(dirname "$0")/.." && pwd)/fixtures/source_lock.sample"
assert_reset

# --- read_kv_field ---
assert_eq "kv source_label"  "$(read_kv_field "$FIX" source_label)" 'community'
assert_eq "kv origin_url"    "$(read_kv_field "$FIX" origin_url)"   'https://github.com/openbmc/openbmc.git'
read_kv_field "$FIX" no_such_key >/dev/null 2>&1;       assert_eq "kv missing key rc"  "$?" 1
read_kv_field /nonexistent/path key >/dev/null 2>&1;    assert_eq "kv missing file rc" "$?" 1

# --- read_source_label: 依全局 SOURCE_LOCK_FILE ---
SOURCE_LOCK_FILE="$FIX"
assert_eq "label from lock" "$(read_source_label)" 'community'
SOURCE_LOCK_FILE="/nonexistent/path"
assert_eq "label default when no lock" "$(read_source_label)" 'community'

# --- write_source_lock: tmpdir + 全局,DRY_RUN vs 实写 ---
TMP="$(mktemp -d)"
CONFIGS_DIR="$TMP/configs"; SOURCE_LOCK_FILE="$CONFIGS_DIR/openbmc-source.lock"
OPENBMC_REPO_URL='https://github.com/openbmc/openbmc.git'; MACHINE='romulus'
# DRY_RUN=1: 在 mkdir 前返回,不创建文件
DRY_RUN=1; write_source_lock >/dev/null 2>&1
assert_false "dry-run no file" test -f "$SOURCE_LOCK_FILE"
# DRY_RUN=0: 写文件,含字段
DRY_RUN=0; write_source_lock >/dev/null 2>&1
assert_true "write creates file" test -f "$SOURCE_LOCK_FILE"
body="$(cat "$SOURCE_LOCK_FILE")"
assert_contains "lock normalized_source" "$body" 'normalized_source=github.com/openbmc/openbmc'
assert_contains "lock origin_url"        "$body" 'origin_url=https://github.com/openbmc/openbmc.git'
assert_contains "lock source_label"      "$body" 'source_label=community'
assert_contains "lock machine_first"     "$body" 'machine_first_init=romulus'
rm -rf "$TMP"

assert_summary
