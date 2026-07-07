#!/usr/bin/env bash
# tests/unit/conf_read.sh — local.conf 读取类半纯函数单测(unit 层,文件 IO)。
# 覆盖 read_local_conf_var / resolve_effective_dl_dir / resolve_effective_sstate_dir。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"

# --- read_local_conf_var:python3 正则匹配 VAR ??=/?=/:=/=,去注释/引号 ---
cat > "$TMP/local.conf" <<EOF
DL_DIR = "/custom/dl"
SSTATE_DIR ?= "/custom/sstate"
MACHINE ??= "romulus"
# COMMENT = "ignored"
NPM = value # trailing comment
EOF
assert_eq "read DL_DIR"        "$(read_local_conf_var "$TMP/local.conf" DL_DIR)"      "/custom/dl"
assert_eq "read SSTATE_DIR"    "$(read_local_conf_var "$TMP/local.conf" SSTATE_DIR)"  "/custom/sstate"
assert_eq "read MACHINE"       "$(read_local_conf_var "$TMP/local.conf" MACHINE)"     "romulus"
assert_eq "read strip comment" "$(read_local_conf_var "$TMP/local.conf" NPM)"         "value"
read_local_conf_var "$TMP/local.conf" NOPE     >/dev/null 2>&1; assert_eq "missing var rc"  "$?" 1
read_local_conf_var /nonexistent/conf NOPE    >/dev/null 2>&1; assert_eq "missing file rc" "$?" 1

# --- read_local_conf_var: 空值赋值行 → exit 0 (ADR-0005 依赖) ---
# ob 的 DL_DIR/SSTATE_DIR/PREMIRRORS 判定靠这个 exit code 区分"用户写空(禁用)"与"未写(补默认)"。
# 有赋值行(即使值为空)→ exit 0; 无赋值行 → exit 1。
cat > "$TMP/empty.conf" <<EOF
PREMIRRORS = ""
EOF
read_local_conf_var "$TMP/empty.conf" PREMIRRORS >/dev/null 2>&1
assert_eq "empty-value assignment → rc 0" "$?" 0

# --- resolve_effective_dl_dir/sstate_dir:无 DL_DIR/SSTATE_DIR → 默认 WORKSPACE_DIR/* ---
WORKSPACE_DIR="$TMP/ws"; BUILD_DIR="$TMP/build"; mkdir -p "$BUILD_DIR/conf"
: > "$BUILD_DIR/conf/local.conf"   # 空 local.conf → 用默认
assert_eq "dl_dir default"    "$(resolve_effective_dl_dir)"    "$WORKSPACE_DIR/downloads"
assert_eq "sstate_dir default" "$(resolve_effective_sstate_dir)" "$WORKSPACE_DIR/sstate-cache"

# --- resolve_effective_dl_dir: assignment-state 对齐 read_local_conf_var exit code ---
# set 非空可用 → 用户值(rc 0); set 但空 → rc 1 静默; 非空不可用 → rc 1 静默(不 fallback);
# unset → 默认(rc 0, 上组 case 已覆盖)

printf 'DL_DIR = "%s"\n' "$TMP/custom-dl" > "$BUILD_DIR/conf/local.conf"
assert_eq "dl_dir set non-empty → user value" "$(resolve_effective_dl_dir)" "$TMP/custom-dl"

printf 'DL_DIR = ""\n' > "$BUILD_DIR/conf/local.conf"
dl_out=$(resolve_effective_dl_dir 2>"$TMP/dl_err") && dl_rc=0 || dl_rc=$?
assert_eq "dl_dir set empty → rc 1" "$dl_rc" 1
assert_eq "dl_dir set empty → empty stdout" "$dl_out" ""
assert_true "dl_dir set empty → silent (no warn)" test ! -s "$TMP/dl_err"

: > "$TMP/not-a-dir"   # 占位文件, 使 child 路径无法 mkdir
printf 'DL_DIR = "%s"\n' "$TMP/not-a-dir/child" > "$BUILD_DIR/conf/local.conf"
dl_out=$(resolve_effective_dl_dir 2>"$TMP/dl_err2") && dl_rc=0 || dl_rc=$?
assert_eq "dl_dir unwritable → rc 1 (no fallback)" "$dl_rc" 1
assert_eq "dl_dir unwritable → empty stdout" "$dl_out" ""
assert_true "dl_dir unwritable → silent" test ! -s "$TMP/dl_err2"

# probe 唯一性 (mktemp, 不删用户文件): pre-create fixed-name 文件, resolver 用 .XXXXXX 不撞它
printf 'DL_DIR = "%s"\n' "$TMP/user-dl-probe" > "$BUILD_DIR/conf/local.conf"
mkdir -p "$TMP/user-dl-probe"
: > "$TMP/user-dl-probe/.ob-init-writable-test"
assert_eq "dl_dir user value with existing fixed-name file" "$(resolve_effective_dl_dir)" "$TMP/user-dl-probe"
assert_true "user fixed-name probe file preserved" test -f "$TMP/user-dl-probe/.ob-init-writable-test"

# --- resolve_effective_sstate_dir: assignment-state 对齐(与 dl_dir 对称) ---

printf 'SSTATE_DIR = "%s"\n' "$TMP/custom-sstate" > "$BUILD_DIR/conf/local.conf"
assert_eq "sstate_dir set non-empty → user value" "$(resolve_effective_sstate_dir)" "$TMP/custom-sstate"

printf 'SSTATE_DIR = ""\n' > "$BUILD_DIR/conf/local.conf"
ss_out=$(resolve_effective_sstate_dir 2>"$TMP/ss_err") && ss_rc=0 || ss_rc=$?
assert_eq "sstate_dir set empty → rc 1" "$ss_rc" 1
assert_eq "sstate_dir set empty → empty stdout" "$ss_out" ""
assert_true "sstate_dir set empty → silent" test ! -s "$TMP/ss_err"

: > "$TMP/not-a-dir2"
printf 'SSTATE_DIR = "%s"\n' "$TMP/not-a-dir2/child" > "$BUILD_DIR/conf/local.conf"
ss_out=$(resolve_effective_sstate_dir 2>"$TMP/ss_err2") && ss_rc=0 || ss_rc=$?
assert_eq "sstate_dir unwritable → rc 1 (no fallback)" "$ss_rc" 1
assert_eq "sstate_dir unwritable → empty stdout" "$ss_out" ""
assert_true "sstate_dir unwritable → silent" test ! -s "$TMP/ss_err2"

# probe 唯一性 (SSTATE 对称): pre-create fixed-name 文件, resolver 用 .XXXXXX 不撞它
printf 'SSTATE_DIR = "%s"\n' "$TMP/user-sstate-probe" > "$BUILD_DIR/conf/local.conf"
mkdir -p "$TMP/user-sstate-probe"
: > "$TMP/user-sstate-probe/.ob-init-writable-test"
assert_eq "sstate_dir user value with existing fixed-name file" "$(resolve_effective_sstate_dir)" "$TMP/user-sstate-probe"
assert_true "sstate fixed-name probe file preserved" test -f "$TMP/user-sstate-probe/.ob-init-writable-test"

rm -rf "$TMP"
assert_summary
