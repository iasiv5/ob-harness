#!/usr/bin/env bash
# tests/orchestration/clone_sub_repos.sh — clone_sub_repos 编排测试(orchestration 层)。
# mock:git(stub_script:config 成功 / clone --bare 受 $CLONE_FAIL 控制)。
# 覆盖:DRY_RUN return 0;成功 → STATUS_MIRROR_NEW;失败(stub_script)→ STATUS_FAILED。
# 实战验证 stub.sh 的 stub_script 失败路径 API(评审第四轮重点)。
# 残余风险:mock 不验证产物能否喂真实 bitbake(靠 integration 兜)。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
FIX="$(cd "$(dirname "$0")/.." && pwd)/fixtures/deps.json.sample"
assert_reset

TMP="$(mktemp -d)"
WORKSPACE_DIR="$TMP"; MACHINE="romulus"
BUILD_DIR="$TMP/openbmc/build/romulus"; mkdir -p "$BUILD_DIR"
cp "$FIX" "$BUILD_DIR/deps.json"

DB="$(mktemp -d)"; mkfake_bin "$DB" git
# config → exit 0;clone --bare → 受 CLONE_FAIL 控制(成功 mkdir,失败 exit 128)
stub_script "$DB" git 'case "$1" in
  config) exit 0 ;;
  clone)  if [[ -n "$CLONE_FAIL" ]]; then exit 128; fi; mkdir -p "$4"; exit 0 ;;
esac; exit 0'

# --- DRY_RUN=1 → return 0,STATUS 不变 ---
out="$(with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"
WORKSPACE_DIR="'"$WORKSPACE_DIR"'"; BUILD_DIR="'"$BUILD_DIR"'"; MACHINE="'"$MACHINE"'"; DRY_RUN=1
STATUS_MIRROR_NEW=(); STATUS_FAILED=()
clone_sub_repos
echo "NEW=${#STATUS_MIRROR_NEW[@]}|FAILED=${#STATUS_FAILED[@]}|"
' _ "$OB" 2>/dev/null)"
assert_contains "dry-run no clone" "$out" "NEW=0|FAILED=0|"

# --- 成功 clone → STATUS_MIRROR_NEW=2 ---
out="$(with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"
WORKSPACE_DIR="'"$WORKSPACE_DIR"'"; BUILD_DIR="'"$BUILD_DIR"'"; MACHINE="'"$MACHINE"'"; DRY_RUN=0
STATUS_MIRROR_NEW=(); STATUS_FAILED=()
clone_sub_repos
echo "NEW=${#STATUS_MIRROR_NEW[@]}|FAILED=${#STATUS_FAILED[@]}|"
' _ "$OB" 2>/dev/null)"
assert_contains "clone success NEW"     "$out" "NEW=2|"
assert_contains "clone success no FAIL" "$out" "FAILED=0|"

# --- clone 失败(CLONE_FAIL=1)→ STATUS_FAILED=2(先清成功 case 留下的 mirror)---
rm -rf "$WORKSPACE_DIR/downloads"
out="$(export CLONE_FAIL=1; with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"
WORKSPACE_DIR="'"$WORKSPACE_DIR"'"; BUILD_DIR="'"$BUILD_DIR"'"; MACHINE="'"$MACHINE"'"; DRY_RUN=0
STATUS_MIRROR_NEW=(); STATUS_FAILED=()
clone_sub_repos
echo "NEW=${#STATUS_MIRROR_NEW[@]}|FAILED=${#STATUS_FAILED[@]}|"
' _ "$OB" 2>/dev/null)"
assert_contains "clone fail FAILED" "$out" "FAILED=2|"

rm -rf "$TMP" "$DB"

# --- GITLAB_IP 展开分支(Task3 回归锁):clone_url 含 ${GITLAB_IP} → 展开成 vendor script host ---
# 现有 fixture 是普通 GitHub URL,不覆盖变量展开分支;此处构造含 ${GITLAB_IP} 的临时 deps.json,
# 设 OPENBMC_DIR 指向带 vendor script 的临时目录,stub git 记录 clone 收到的 URL,断言已展开。
# src_uri 用具体 host(10.0.0.9),避免它经 derive_bitbake_git_mirror_path 污染 mirror path 的 ${GITLAB_IP}。
TMP3="$(mktemp -d)"; OPENBMC3="$TMP3/openbmc"; mkdir -p "$OPENBMC3/meta-x"
printf 'GITLAB_IP=10.0.0.9\n' > "$OPENBMC3/meta-x/git-mirror-url.sh"
BUILD3="$TMP3/build"; mkdir -p "$BUILD3"
cat > "$BUILD3/deps.json" <<'JSON'
[{"name":"priv","clone_url":"https://${GITLAB_IP}/team/priv.git","src_uri":"git://10.0.0.9/team/priv.git;branch=main","srcrev":"abc","recipe":"r1"}]
JSON
DB3="$(mktemp -d)"; mkfake_bin "$DB3" git
stub_script "$DB3" git 'case "$1" in config) exit 0;; clone) mkdir -p "$4"; exit 0;; esac; exit 0'
with_stub "$DB3" -- bash -c 'OB_NO_MAIN=1 source "$1"
WORKSPACE_DIR="'"$TMP3"'"; OPENBMC_DIR="'"$OPENBMC3"'"; BUILD_DIR="'"$BUILD3"'"; MACHINE="romulus"; DRY_RUN=0
STATUS_MIRROR_NEW=(); STATUS_FAILED=()
clone_sub_repos
' _ "$OB" 2>/dev/null
_calls="$(cat "$DB3/.git.calls" 2>/dev/null)"
assert_contains "GITLAB_IP expanded in clone URL" "$_calls" "10.0.0.9"
assert_false "no unresolved \${GITLAB_IP}" grep -qF '${GITLAB_IP}' "$DB3/.git.calls"
rm -rf "$TMP3" "$DB3"

assert_summary
