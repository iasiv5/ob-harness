#!/usr/bin/env bash
# tests/protocol/premirrors_injection.sh — 断言 ob init 注入 PREMIRRORS + local.conf 变量判定用 exit code。
# 覆盖 ADR-0004（PREMIRRORS 注入）与 ADR-0005（exit code 判定，空值=用户接管）。
set -uo pipefail

source "$(dirname "$0")/../lib/ob_loader.sh"   # source ob 函数, $OB; 内部 set +e
set +u   # generate_build_config 可能引用测试未设的全局; 容忍以聚焦 inc 输出断言
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

MACHINE="t"
WORKSPACE_DIR="$(mktemp -d)"
BUILD_DIR="$WORKSPACE_DIR/build"
mkdir -p "$BUILD_DIR/conf"
INC="$BUILD_DIR/conf/externalsrc-$MACHINE.inc"

gen_inc() {
    rm -f "$INC"
    DRY_RUN=0 generate_build_config >/dev/null 2>&1
    cat "$INC" 2>/dev/null
}

# 场景1: local.conf 无 PREMIRRORS/DL_DIR/SSTATE_DIR → ob 注入全部默认
printf 'MACHINE ??= "t"\n' > "$BUILD_DIR/conf/local.conf"
inc=$(gen_inc)
assert_contains "s1 PREMIRRORS injected" "$inc" "mirrors.tuna.tsinghua.edu.cn"
assert_contains "s1 DL_DIR default"       "$inc" 'DL_DIR = "'

# 场景2: local.conf 有自定义 PREMIRRORS → ob 不注入(注释跳过)
printf 'MACHINE ??= "t"\nPREMIRRORS = "https://mirrors.ustc.edu.cn/gnu/"\n' > "$BUILD_DIR/conf/local.conf"
inc=$(gen_inc)
if [[ "$inc" == *"mirrors.tuna.tsinghua.edu.cn"* ]]; then _assert_bad "s2 自定义 PREMIRRORS 时不应注入 tuna"; else _assert_ok "s2 自定义时跳过"; fi

# 场景3: local.conf PREMIRRORS="" (空) → ob 不注入(exit code 判定=用户接管)
printf 'MACHINE ??= "t"\nPREMIRRORS = ""\n' > "$BUILD_DIR/conf/local.conf"
inc=$(gen_inc)
if [[ "$inc" == *"mirrors.tuna.tsinghua.edu.cn"* ]]; then _assert_bad "s3 空值应禁用(被当接管)"; else _assert_ok "s3 空值=禁用"; fi

# 场景4: 已有 inc + DL_DIR="" → generate_build_config exit 3 + 无 inc 副作用(backup 前 preflight)
# pre-create $INC 锁住"preflight 在 backup 前": 若 preflight 被挪回 backup 后, $INC 会被 backup/改写。
# 子 shell 调用: generate_build_config 是 source 的函数, exit 3 会杀当前 shell。
printf 'old-inc\n' > "$INC"
rm -f "${INC}".bak.*
printf 'MACHINE ??= "t"\nDL_DIR = ""\n' > "$BUILD_DIR/conf/local.conf"
s4_out=$(DRY_RUN=0 generate_build_config 2>&1); s4_rc=$?
assert_eq "s4 existing inc + empty DL_DIR → exit 3" "$s4_rc" 3
assert_match "s4 empty DL_DIR → remedy line" "$s4_out" "Set DL_DIR to a valid absolute path"
assert_eq "s4 existing inc preserved" "$(cat "$INC")" "old-inc"
if compgen -G "${INC}.bak.*" >/dev/null; then _assert_bad "s4 no backup created on failure"; else _assert_ok "s4 no backup created on failure"; fi

# 场景5: SSTATE_DIR="" → generate_build_config exit 3 + SSTATE remedy + 无 inc 副作用
printf 'old-inc\n' > "$INC"
rm -f "${INC}".bak.*
printf 'MACHINE ??= "t"\nSSTATE_DIR = ""\n' > "$BUILD_DIR/conf/local.conf"
s5_out=$(DRY_RUN=0 generate_build_config 2>&1); s5_rc=$?
assert_eq "s5 empty SSTATE_DIR → exit 3" "$s5_rc" 3
assert_match "s5 empty SSTATE_DIR → remedy line" "$s5_out" "Set SSTATE_DIR to a valid absolute path"
assert_eq "s5 existing inc preserved" "$(cat "$INC")" "old-inc"
if compgen -G "${INC}.bak.*" >/dev/null; then _assert_bad "s5 no backup created on failure"; else _assert_ok "s5 no backup created on failure"; fi

assert_summary
rc=$?
rm -rf "$WORKSPACE_DIR"
exit $rc
