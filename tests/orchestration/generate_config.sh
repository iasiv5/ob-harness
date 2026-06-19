#!/usr/bin/env bash
# tests/orchestration/generate_config.sh — generate_lockfile + generate_build_config 编排测试。
# mock:git rev-parse(stub)。残余风险:mock 不验证 lockfile/.inc 能喂真实 bitbake(靠 integration 兜)。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
FIX="$(cd "$(dirname "$0")/.." && pwd)/fixtures/deps.json.sample"
assert_reset

TMP="$(mktemp -d)"
WORKSPACE_DIR="$TMP"; MACHINE="romulus"
CONFIGS_DIR="$TMP/configs"; OPENBMC_DIR="$TMP/openbmc"; BUILD_DIR="$OPENBMC_DIR/build/romulus"
mkdir -p "$CONFIGS_DIR" "$BUILD_DIR/conf" "$OPENBMC_DIR"   # conf 预建(generate_build_config 不 mkdir conf)
cp "$FIX" "$BUILD_DIR/deps.json"

DB="$(mktemp -d)"; mkfake_bin "$DB" git
# generate_lockfile 用 `git -C OPENBMC_DIR rev-parse HEAD`($1=-C),按 $* 匹配 rev-parse
stub_script "$DB" git 'if [[ "$*" == *rev-parse* ]]; then echo "deadbeef1234"; exit 0; fi; exit 0'

# --- generate_lockfile DRY_RUN=1 → 不写 ---
with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"
CONFIGS_DIR="'"$CONFIGS_DIR"'"; MACHINE="'"$MACHINE"'"; OPENBMC_DIR="'"$OPENBMC_DIR"'"; BUILD_DIR="'"$BUILD_DIR"'"; DRY_RUN=1
generate_lockfile
test -f "$CONFIGS_DIR/$MACHINE.lock" && echo EXISTS || echo NOFILE
' _ "$OB" 2>/dev/null | grep -q NOFILE && _assert_ok "lockfile dry-run no file" || _assert_bad "lockfile dry-run no file"

# --- generate_lockfile 实写 → lockfile JSON 字段 ---
with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"
CONFIGS_DIR="'"$CONFIGS_DIR"'"; MACHINE="'"$MACHINE"'"; OPENBMC_DIR="'"$OPENBMC_DIR"'"; BUILD_DIR="'"$BUILD_DIR"'"; DRY_RUN=0
generate_lockfile
cat "$CONFIGS_DIR/$MACHINE.lock"
' _ "$OB" 2>/dev/null >"$TMP/lock"
body="$(cat "$TMP/lock")"
assert_contains "lockfile machine" "$body" '"machine": "romulus"'
assert_contains "lockfile commit"  "$body" '"openbmc_commit": "deadbeef1234"'
assert_contains "lockfile subrepo" "$body" '"name": "repo1"'

# --- generate_build_config DRY_RUN=1 → 不写 ---
with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"
BUILD_DIR="'"$BUILD_DIR"'"; MACHINE="'"$MACHINE"'"; WORKSPACE_DIR="'"$WORKSPACE_DIR"'"; DRY_RUN=1
generate_build_config
test -f "$BUILD_DIR/conf/externalsrc-$MACHINE.inc" && echo EXISTS || echo NOFILE
' _ "$OB" 2>/dev/null | grep -q NOFILE && _assert_ok "build_config dry-run no file" || _assert_bad "build_config dry-run no file"

# --- generate_build_config 实写 → .inc 字段 ---
with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"
BUILD_DIR="'"$BUILD_DIR"'"; MACHINE="'"$MACHINE"'"; WORKSPACE_DIR="'"$WORKSPACE_DIR"'"; DRY_RUN=0
generate_build_config
cat "$BUILD_DIR/conf/externalsrc-$MACHINE.inc"
' _ "$OB" 2>/dev/null >"$TMP/inc"
body="$(cat "$TMP/inc")"
assert_contains "inc externalsrc" "$body" 'INHERIT += "externalsrc"'
assert_contains "inc DL_DIR"      "$body" 'DL_DIR = "'
assert_contains "inc SSTATE_DIR"  "$body" 'SSTATE_DIR = "'
assert_contains "inc npm timeout" "$body" 'npm_config_fetch_timeout ??= "600000"'

# --- generate_build_config: user already defines DL_DIR/SSTATE_DIR in local.conf → not overridden ---
# 关键回归防护: ob 必须尊重用户已定义的 DL_DIR/SSTATE_DIR, 不在 .inc 写赋值 (否则覆盖用户配置,
# 如 NFS shared cache)。43b0e7a 曾把这里退化成无条件 ??= 导致失效, 此 case 防止再回归。
BUILD_DIR2="$TMP/openbmc/build/$MACHINE-userdef"; mkdir -p "$BUILD_DIR2/conf"
cat > "$BUILD_DIR2/conf/local.conf" <<EOF
DL_DIR = "$TMP/user-dl"
SSTATE_DIR = "$TMP/user-sstate"
EOF
with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"
BUILD_DIR="'"$BUILD_DIR2"'"; MACHINE="'"$MACHINE"'"; WORKSPACE_DIR="'"$WORKSPACE_DIR"'"; DRY_RUN=0
generate_build_config
cat "$BUILD_DIR/conf/externalsrc-'"$MACHINE"'.inc"
' _ "$OB" 2>/dev/null >"$TMP/inc2"
body="$(cat "$TMP/inc2")"
assert_contains "user dl not overridden"     "$body" 'DL_DIR defined in local.conf'
assert_contains "user sstate not overridden" "$body" 'SSTATE_DIR defined in local.conf'
assert_false  "user dl no assignment"     grep -q '^DL_DIR = '    "$TMP/inc2"
assert_false  "user sstate no assignment" grep -q '^SSTATE_DIR = ' "$TMP/inc2"

rm -rf "$TMP" "$DB"
assert_summary
