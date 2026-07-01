#!/usr/bin/env bash
# tests/orchestration/resolve_qb_vars.sh — QB variable 解析经 QEMU launch profile 暴露。
# mock:bitbake -e(stub 输出 fixture)+ setup 文件(no-op,供 source)。
# 覆盖:成功解析到 QEMU_LAUNCH_*;空 bitbake -e → exit 1。
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

# 成功:解析为 QEMU_LAUNCH_*
with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"
OPENBMC_DIR="$2"; BUILD_DIR="$3"; MACHINE="$4"
resolve_qemu_launch_profile "$MACHINE"
echo "M=$QEMU_LAUNCH_MACHINE_NAME|MEM=$QEMU_LAUNCH_MEM_FLAG|SYS=$QEMU_LAUNCH_SYSTEM_NAME|SOC=$QEMU_LAUNCH_SOC_TYPE|rc=$?"
' _ "$OB" "$OPENBMC_DIR" "$BUILD_DIR" romulus >"$TMP/out" 2>/dev/null
out="$(cat "$TMP/out")"
assert_contains "launch machine"  "$out" "M=romulus|"
assert_contains "launch mem"      "$out" "MEM=-m 512|"
assert_contains "launch system"   "$out" "SYS=qemu-system-arm|"
assert_contains "launch soc"      "$out" "SOC=ast2600|"
assert_contains "launch rc ok"    "$out" "|rc=0"

# 失败:bitbake -e 输出空 → exit 1
stub_out "$DB" bitbake ""
assert_rc 1 "empty bitbake -e exit 1" with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"
OPENBMC_DIR="'"$OPENBMC_DIR"'"; BUILD_DIR="'"$BUILD_DIR"'"; MACHINE=romulus
resolve_qemu_launch_profile "$MACHINE"' _ "$OB"

rm -rf "$TMP" "$DB"
assert_summary
