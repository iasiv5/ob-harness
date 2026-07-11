#!/usr/bin/env bash
# tests/orchestration/clone_sub_repos.sh — Step 5 bare mirror provisioning 行为金标(orchestration 层)。
# 只观察稳定行为(expanded clone URL / mirror path / disposition / 最终 report),不读 module 私有
# STATUS_*;让测试可跨 interface shrink 存活(pin -> optimize -> deepen 的 pin 层)。
# 覆盖:
#   1. dry-run 无 clone、无 git 调用、report mirror 区段为空
#   2. 成功 clone → `Mirrors: 2 new, 0 existing`
#   3. clone 全失败 → `2 mirrors failed` + entry 文案(非致命)
#   4. runtime Git mirror host(${GITLAB_IP})展开进 clone URL
#   5. mixed 5-entry gold:existing→new→malformed→unresolved→failed 的 normalized URL/path/disposition
#   6. 损坏 deps.json → CLI rc=1(整批 planning 失败)
# mock git:config 成功;clone 兼容旧 `git clone --bare url dest` 与新 `git -c k=v clone --bare url dest`
#          两种形状,destination 恒取最后一个参数;CLONE_FAIL=1 或 URL 含 /fail.git → clone exit 128。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
FIX="$(cd "$(dirname "$0")/.." && pwd)/fixtures/deps.json.sample"
assert_reset

# fake git adapter:config 直接成功;clone 识别 $1==clone 或 $3==clone(Task3 后 -c k=v clone 形状),
# destination 取最后一个参数,clone_url 取倒数第二个;CLONE_FAIL=1 或 URL 含 /fail.git 时 exit 128。
make_fake_git() {
    local dir="$1"; mkfake_bin "$dir" git
    stub_script "$dir" git 'case "$1" in
  config) exit 0 ;;
esac
if [[ "$1" == "clone" || "${3:-}" == "clone" ]]; then
  _dest="${@: -1}"
  _url="${@: -2:1}"
  if [[ -n "$CLONE_FAIL" ]] || [[ "$_url" == */fail.git ]]; then exit 128; fi
  mkdir -p "$_dest"
  exit 0
fi
exit 0'
}

# ============ case 1: DRY_RUN=1 → 无 clone、无 git 调用、report mirror 区段为空 ============
TMP="$(mktemp -d)"
WORKSPACE_DIR="$TMP"; MACHINE="romulus"
BUILD_DIR="$TMP/openbmc/build/romulus"; mkdir -p "$BUILD_DIR"
cp "$FIX" "$BUILD_DIR/deps.json"
DB="$(mktemp -d)"; make_fake_git "$DB"

out="$(with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"
WORKSPACE_DIR="'"$WORKSPACE_DIR"'"; BUILD_DIR="'"$BUILD_DIR"'"; MACHINE="'"$MACHINE"'"; DRY_RUN=1
CONFIGS_DIR="'"$TMP"'/configs"; mkdir -p "$CONFIGS_DIR"
clone_sub_repos
print_report
' _ "$OB" 2>/dev/null)"
assert_contains "dry-run banner"          "$out" "[DRY-RUN] Would populate bare mirrors"
assert_true  "dry-run mirror dir empty"   grep -qE 'Mirror dir:[[:space:]]*$' <<<"$out"
assert_false "dry-run no populated line"  grep -q 'Mirrors populated:' <<<"$out"
assert_false "dry-run no failed line"     grep -q 'Failed mirrors:' <<<"$out"
assert_false "dry-run no git invoked"     test -f "$DB/.git.calls"

# ============ case 2: 成功 clone 2 个 → `Mirrors: 2 new, 0 existing` ============
out="$(with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"
WORKSPACE_DIR="'"$WORKSPACE_DIR"'"; BUILD_DIR="'"$BUILD_DIR"'"; MACHINE="'"$MACHINE"'"; DRY_RUN=0
clone_sub_repos
' _ "$OB" 2>/dev/null)"
assert_contains "clone success counts" "$out" "Mirrors: 2 new, 0 existing"

# ============ case 3: clone 全失败(CLONE_FAIL=1)→ `2 mirrors failed` + entry 文案 ============
rm -rf "$WORKSPACE_DIR/downloads"
out="$(export CLONE_FAIL=1; with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"
WORKSPACE_DIR="'"$WORKSPACE_DIR"'"; BUILD_DIR="'"$BUILD_DIR"'"; MACHINE="'"$MACHINE"'"; DRY_RUN=0
clone_sub_repos
' _ "$OB" 2>/dev/null)"
assert_contains "clone fail count"  "$out" "2 mirrors failed"
assert_contains "clone fail entry"  "$out" "Failed to create bare mirror for repo1"

rm -rf "$TMP" "$DB"

# ============ case 4: ${GITLAB_IP} 展开 → clone URL 含展开 host、不含字面 ${GITLAB_IP} ============
# src_uri 用具体 host(10.0.0.9),避免它经 derive_bitbake_git_mirror_path 污染 mirror path 的 ${GITLAB_IP}。
TMP3="$(mktemp -d)"; OPENBMC3="$TMP3/openbmc"; mkdir -p "$OPENBMC3/meta-x"
printf 'GITLAB_IP=10.0.0.9\n' > "$OPENBMC3/meta-x/git-mirror-url.sh"
BUILD3="$TMP3/build"; mkdir -p "$BUILD3"
cat > "$BUILD3/deps.json" <<'JSON'
[{"name":"priv","clone_url":"https://${GITLAB_IP}/team/priv.git","src_uri":"git://10.0.0.9/team/priv.git;branch=main","srcrev":"abc","recipe":"r1"}]
JSON
DB3="$(mktemp -d)"; make_fake_git "$DB3"
with_stub "$DB3" -- bash -c 'OB_NO_MAIN=1 source "$1"
WORKSPACE_DIR="'"$TMP3"'"; OPENBMC_DIR="'"$OPENBMC3"'"; BUILD_DIR="'"$BUILD3"'"; MACHINE="romulus"; DRY_RUN=0
clone_sub_repos
' _ "$OB" 2>/dev/null
_calls="$(cat "$DB3/.git.calls" 2>/dev/null)"
assert_contains "GITLAB_IP expanded in clone URL" "$_calls" "10.0.0.9"
assert_false "no unresolved \${GITLAB_IP}" grep -qF '${GITLAB_IP}' "$DB3/.git.calls"
rm -rf "$TMP3" "$DB3"

# ============ case 5: mixed 5-entry gold(existing→new→malformed→unresolved→failed)============
case_root="$(mktemp -d)"
MIX_WS="$case_root"; MIX_BUILD="$case_root/openbmc/build/romulus"; MIX_CONFIGS="$case_root/configs"
mkdir -p "$MIX_BUILD" "$MIX_CONFIGS"
# 预建 existing mirror,证明 existing 不 clone 且目录保留
mkdir -p "$case_root/downloads/git2/example.com.existing.git"
cat > "$MIX_BUILD/deps.json" <<'JSON'
[
  {"name":"existing","clone_url":"https://example.com/existing.git","src_uri":"git://example.com/existing.git;branch=main"},
  {"name":"new","clone_url":"https://example.com/new.git","src_uri":"git://example.com/new.git;branch=main"},
  {"name":"malformed","clone_url":"https://example.com/malformed.git","src_uri":""},
  {"name":"unresolved","clone_url":"https://${UNSET_HOST}/unresolved.git","src_uri":"git://example.com/unresolved.git"},
  {"name":"failed","clone_url":"https://example.com/fail.git","src_uri":"git://example.com/fail.git"}
]
JSON
DB5="$(mktemp -d)"; make_fake_git "$DB5"
out5="$(with_stub "$DB5" -- bash -c 'OB_NO_MAIN=1 source "$1"
WORKSPACE_DIR="'"$MIX_WS"'"; OPENBMC_DIR="'"$case_root/openbmc"'"; BUILD_DIR="'"$MIX_BUILD"'"; CONFIGS_DIR="'"$MIX_CONFIGS"'"; MACHINE="romulus"; DRY_RUN=0; VERBOSE=1
clone_sub_repos
print_report
' _ "$OB" 2>/dev/null)"
# clone 调用面归一化(只留 clone 行,去可选 `-c http.postBuffer=536870912 ` 前缀),按 URL/path 锁 disposition
_calls5="$(cat "$DB5/.git.calls" 2>/dev/null)"
normalized_calls="$(grep -E '(^|[[:space:]])clone[[:space:]]' <<<"$_calls5" | sed 's/^-c http\.postBuffer=536870912 //')"
expected_calls="$(printf 'clone --bare https://example.com/new.git %s\nclone --bare https://example.com/fail.git %s' \
    "$case_root/downloads/git2/example.com.new.git" \
    "$case_root/downloads/git2/example.com.fail.git")"
assert_eq "normalized clone URL/path calls" "$(LC_ALL=C sort <<<"$normalized_calls")" "$(LC_ALL=C sort <<<"$expected_calls")"
# per-entry disposition
assert_false "existing not cloned"        grep -qE 'clone[[:space:]].*existing\.git' "$DB5/.git.calls"
assert_true  "existing dir retained"      test -d "$case_root/downloads/git2/example.com.existing.git"
assert_true  "new dir created"            test -d "$case_root/downloads/git2/example.com.new.git"
assert_contains "malformed skip verbose"  "$out5" "Cannot derive mirror path for malformed, skipping"
assert_false "malformed not cloned"       grep -qE 'clone[[:space:]].*malformed\.git' "$DB5/.git.calls"
assert_false "unresolved not cloned"      grep -qE 'clone[[:space:]].*unresolved\.git' "$DB5/.git.calls"
assert_false "failed dir cleaned"         test -d "$case_root/downloads/git2/example.com.fail.git"
# report 文案、counts 与 failure 顺序(unresolved 后 failed;malformed 不计入 failure)
assert_contains "report new/existing"     "$out5" "Mirrors populated: 1 new, 1 existing"
assert_contains "report failed count"     "$out5" "Failed mirrors: 2"
assert_contains "report fail unresolved"  "$out5" "[FAIL] unresolved (unresolved variable in clone URL)"
assert_contains "report fail clone"       "$out5" "[FAIL] failed (bare mirror clone failed)"
_unresolved_line="$(grep -nF '[FAIL] unresolved' <<<"$out5" | head -1 | cut -d: -f1)"
_failed_line="$(grep -nF '[FAIL] failed' <<<"$out5" | head -1 | cut -d: -f1)"
assert_true "failure order unresolved<failed" test "${_unresolved_line:-0}" -lt "${_failed_line:-0}"
rm -rf "$case_root" "$DB5"

# ============ case 6: 损坏 deps.json → CLI rc=1(直接 source ob 保持入口 set -e)============
# 不走 ob_loader.sh 的 set +e:clone_sub_repos 内 total=<损坏 JSON 解析> 在入口 set -e 下 exit 1。
TMP6="$(mktemp -d)"; BUILD6="$TMP6/openbmc/build/romulus"; mkdir -p "$BUILD6"
printf '{not valid json' > "$BUILD6/deps.json"
bash -c 'OB_NO_MAIN=1 source "$1"
WORKSPACE_DIR="'"$TMP6"'"; BUILD_DIR="'"$BUILD6"'"; MACHINE="romulus"; DRY_RUN=0
clone_sub_repos
' _ "$OB" 2>/dev/null
rc6=$?
assert_eq "corrupt deps.json rc=1" "$rc6" 1
rm -rf "$TMP6"

assert_summary
