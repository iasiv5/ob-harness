#!/usr/bin/env bash
# tests/orchestration/resolve_qb_vars.sh — resolve_qb_vars 编排测试(orchestration 层)。
# mock:bitbake -e(stub 输出 fixture)+ setup 文件(no-op,供 source)。
# 覆盖:成功解析 QB_MACHINE/QB_MEM/QB_SYSTEM_NAME;空 bitbake -e → exit 1。
# 残余风险:mock 不验证产物能否喂真实 bitbake(靠 integration E2E 兜)。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
FIX="$(cd "$(dirname "$0")/.." && pwd)/fixtures/bitbake-e.sample.txt"
assert_reset

TMP="$(mktemp -d)"
OPENBMC_DIR="$TMP/openbmc"; BUILD_DIR="$OPENBMC_DIR/build/romulus"
mkdir -p "$BUILD_DIR"; : > "$OPENBMC_DIR/setup"   # no-op setup(供 `source setup`)

DB="$(mktemp -d)"; mkfake_bin "$DB" bitbake
stub_out "$DB" bitbake "$(cat "$FIX")"

# 成功:解析 QB_*
with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"
OPENBMC_DIR="$2"; BUILD_DIR="$3"; MACHINE="$4"
resolve_qb_vars
echo "M=$QB_MACHINE_NAME|MEM=$QB_MEM_SIZE_FLAG|SYS=$QB_SYSTEM_NAME|rc=$?"
' _ "$OB" "$OPENBMC_DIR" "$BUILD_DIR" romulus >"$TMP/out" 2>/dev/null
out="$(cat "$TMP/out")"
assert_contains "qb machine"  "$out" "M=romulus|"
assert_contains "qb mem"      "$out" "MEM=-m 512|"
assert_contains "qb system"   "$out" "SYS=qemu-system-arm|"
assert_contains "qb rc ok"    "$out" "|rc=0"

# 失败:bitbake -e 输出空 → exit 1
stub_out "$DB" bitbake ""
assert_rc 1 "empty bitbake -e exit 1" with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"
OPENBMC_DIR="'"$OPENBMC_DIR"'"; BUILD_DIR="'"$BUILD_DIR"'"; MACHINE=romulus
resolve_qb_vars' _ "$OB"

rm -rf "$TMP" "$DB"
assert_summary
