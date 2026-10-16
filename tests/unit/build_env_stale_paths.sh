#!/usr/bin/env bash
# tests/unit/build_env_stale_paths.sh — build_env_stale_conf_paths 单测(workspace 搬迁遗留旧绝对路径诊断)。
# 覆盖: 无 conf 目录 / bblayers 旧 token(含注释豁免) / local.conf 旧 export(含 ${VAR}、单引号、存在路径豁免) / 全部存在 → rc 0。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- case 1: build_dir/conf 不存在 → rc 0 + 空 records ---
_BUILD_ENV_STALE_RECORDS=()
build_env_stale_conf_paths "$TMP/build/none" 2>/dev/null
assert_eq "no conf dir → rc 0" "$?" 0
assert_eq "no conf dir → empty records" "${#_BUILD_ENV_STALE_RECORDS[@]}" 0

# --- case 2: 混合场景(bblayers 旧 token / local.conf 旧 export / 各类豁免) ---
BUILD_DIR="$TMP/build/m1"
CONF="$BUILD_DIR/conf"
mkdir -p "$CONF" "$TMP/exists" "$TMP/exists/downloads" "$TMP/exists/meta-valid"
cat > "$CONF/bblayers.conf" <<EOF
# LAYER_CONF_VERSION (comment with /nonexistent/comment-path must be skipped)
BBMASK += "/nonexistent/mask-path/intel-platforms.bb"
BBLAYERS = " \\
  \${TOPDIR}/../meta-var-entry \\
  $TMP/exists/meta-valid \\
  /nonexistent/old-root/workspace/openbmc/meta-phosphor \\
"
EOF
cat > "$CONF/local.conf" <<EOF
MACHINE ??= "m1"
DL_DIR = "$TMP/exists/downloads"
export XDG_CACHE_HOME = "/nonexistent/old-root/workspace/xdg-cache"
SANITY_SAMPLE = "\${COREBASE}/meta"
TZ = '/etc/localtime'
EOF

_BUILD_ENV_STALE_RECORDS=()
build_env_stale_conf_paths "$BUILD_DIR" 2>/dev/null
assert_eq "mixed stale → rc 1" "$?" 1
assert_eq "mixed stale → 2 records" "${#_BUILD_ENV_STALE_RECORDS[@]}" 2
assert_contains "bblayers stale token recorded" \
    "$(printf '%s\n' "${_BUILD_ENV_STALE_RECORDS[@]}")" "bblayers.conf|/nonexistent/old-root/workspace/openbmc/meta-phosphor"
assert_contains "local.conf stale export recorded" \
    "$(printf '%s\n' "${_BUILD_ENV_STALE_RECORDS[@]}")" "local.conf|/nonexistent/old-root/workspace/xdg-cache"
assert_false "valid bblayers dir not flagged" \
    grep -q "exists/meta-valid" <<< "$(printf '%s\n' "${_BUILD_ENV_STALE_RECORDS[@]}")"
assert_false "valid DL_DIR not flagged" \
    grep -q "exists/downloads" <<< "$(printf '%s\n' "${_BUILD_ENV_STALE_RECORDS[@]}")"
assert_false "comment path exempt" \
    grep -q "comment-path" <<< "$(printf '%s\n' "${_BUILD_ENV_STALE_RECORDS[@]}")"
assert_false "BBMASK mask-path exempt" \
    grep -q "mask-path" <<< "$(printf '%s\n' "${_BUILD_ENV_STALE_RECORDS[@]}")"
assert_false "\${TOPDIR} var entry exempt" \
    grep -q "meta-var-entry" <<< "$(printf '%s\n' "${_BUILD_ENV_STALE_RECORDS[@]}")"
assert_false "\${VAR} value exempt" \
    grep -q "COREBASE" <<< "$(printf '%s\n' "${_BUILD_ENV_STALE_RECORDS[@]}")"
assert_false "single-quoted value exempt" \
    grep -q "localtime" <<< "$(printf '%s\n' "${_BUILD_ENV_STALE_RECORDS[@]}")"

# --- case 3: 全部路径存在 → rc 0 + 空 records ---
mkdir -p "$TMP/exists/meta-another"
cat > "$CONF/bblayers.conf" <<EOF
BBLAYERS = " \\
  $TMP/exists/meta-valid \\
  $TMP/exists/meta-another \\
"
EOF
cat > "$CONF/local.conf" <<EOF
DL_DIR = "$TMP/exists/downloads"
XDG_CACHE_HOME = "$TMP/exists/xdg-cache"
EOF
mkdir -p "$TMP/exists/xdg-cache"

_BUILD_ENV_STALE_RECORDS=()
build_env_stale_conf_paths "$BUILD_DIR" 2>/dev/null
assert_eq "all paths exist → rc 0" "$?" 0
assert_eq "all paths exist → empty records" "${#_BUILD_ENV_STALE_RECORDS[@]}" 0

# --- case 4: 单行 BBLAYERS 赋值也解析完整(闭引号不能粘入路径 token) ---
printf 'BBLAYERS = "%s"\n' "$TMP/exists/meta-valid" > "$CONF/bblayers.conf"
_BUILD_ENV_STALE_RECORDS=()
build_env_stale_conf_paths "$BUILD_DIR" 2>/dev/null
assert_eq "single-line valid BBLAYERS → rc 0" "$?" 0
assert_eq "single-line valid BBLAYERS → empty records" "${#_BUILD_ENV_STALE_RECORDS[@]}" 0

printf 'BBLAYERS = "%s"\n' "/nonexistent/old-root/single-line-layer" > "$CONF/bblayers.conf"
_BUILD_ENV_STALE_RECORDS=()
build_env_stale_conf_paths "$BUILD_DIR" 2>/dev/null
assert_eq "single-line stale BBLAYERS → rc 1" "$?" 1
assert_contains "single-line stale BBLAYERS recorded" \
    "$(printf '%s\n' "${_BUILD_ENV_STALE_RECORDS[@]}")" "bblayers.conf|/nonexistent/old-root/single-line-layer"

assert_summary
