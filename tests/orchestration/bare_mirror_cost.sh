#!/usr/bin/env bash
# tests/orchestration/bare_mirror_cost.sh — Step 5 bare mirror provisioning 非功能成本锁(orchestration 层)。
# 锁两件事(Task2 Python 预算 / Task3 Git 调用面):
#   - N=0/N=2/N=20 的 Python 总调用数完全相等(固定前置开销不随 N 增长),planner-shaped 调用各恰好 1。
#   - `git config --global http.postBuffer` 恰好 0;clone 总数 == N;command-scoped clone 总数 == N。
# fake python3:记录每次调用 → PYTHON_CALLS_LOG;planner 谓词($#=3 && $1=- && $2=deps.json && $3=mirror_base)
#              单独计数 → PLANNER_CALLS_LOG;再 exec 真 python 透传实际工作。
# fake git:兼容 `git clone --bare url dest` 与 `git -c k=v clone --bare url dest` 两形状,dest 取末参数。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
assert_reset

# 真 python 路径:fake python3 是子进程,未 export 的 shell 变量不可见(计划 Task2 Step1.2)。
REAL_PYTHON="$(command -v python3)"; export REAL_PYTHON

# Bash 生成 N 条合法 deps.json,避免 fixture 生成本身进入 Python 计数(计划 Task2 Step1.4)。
write_deps_fixture() {
    local output="$1" count="$2" index
    printf '[' > "$output"
    for ((index = 1; index <= count; index++)); do
        [[ "$index" -eq 1 ]] || printf ',' >> "$output"
        printf '{"name":"repo%s","clone_url":"https://example.com/repo%s.git","src_uri":"git://example.com/repo%s.git;branch=main"}' \
            "$index" "$index" "$index" >> "$output"
    done
    printf ']\n' >> "$output"
}

# fake git:config 成功;clone 识别 $1==clone 或 $3==clone(Task3 后 -c k=v clone 形状),dest 取末参数。
make_fake_git() {
    local dir="$1"; mkfake_bin "$dir" git
    stub_script "$dir" git 'case "$1" in
  config) exit 0 ;;
esac
if [[ "$1" == "clone" || "${3:-}" == "clone" ]]; then
  mkdir -p "${@: -1}"
  exit 0
fi
exit 0'
}

# fake python3:记录每次调用;planner 谓词成立时单独计数;再 exec 真 python 透传。
make_fake_python() {
    local dir="$1"; mkfake_bin "$dir" python3
    stub_script "$dir" python3 'echo "call" >> "$PYTHON_CALLS_LOG"
if [[ $# -eq 3 && "$1" == "-" && "$2" == "$PLANNER_DEPS_JSON" && "$3" == "$PLANNER_MIRROR_BASE" ]]; then
  echo "planner" >> "$PLANNER_CALLS_LOG"
fi
exec "$REAL_PYTHON" "$@"'
}

# 跑一个 N=count 的 provisioning case,收集成本计数到 CASE_* 全局。
run_cost_case() {
    local count="$1"
    local root build deps mirror_base dbg
    root="$(mktemp -d)"
    build="$root/openbmc/build/romulus"
    deps="$build/deps.json"
    mirror_base="$root/downloads/git2"
    mkdir -p "$build/conf"
    # comment-only local.conf:让 resolve_effective_dl_dir 固定调一次 read_local_conf_var(计划 Task2 Step1.5)。
    printf '# comment-only local.conf (no DL_DIR assignment)\n' > "$build/conf/local.conf"
    write_deps_fixture "$deps" "$count"
    export PLANNER_DEPS_JSON="$deps"
    export PLANNER_MIRROR_BASE="$mirror_base"
    export PYTHON_CALLS_LOG="$root/python.calls"
    export PLANNER_CALLS_LOG="$root/planner.calls"
    : > "$PYTHON_CALLS_LOG"; : > "$PLANNER_CALLS_LOG"
    dbg="$(mktemp -d)"; make_fake_git "$dbg"; make_fake_python "$dbg"
    with_stub "$dbg" -- bash -c 'OB_NO_MAIN=1 source "$1"
WORKSPACE_DIR="'"$root"'"; BUILD_DIR="'"$build"'"; MACHINE="romulus"; DRY_RUN=0
clone_sub_repos
' _ "$OB" 2>/dev/null
    CASE_TOTAL=$(wc -l < "$PYTHON_CALLS_LOG" | tr -d ' ')
    CASE_PLANNER=$(wc -l < "$PLANNER_CALLS_LOG" | tr -d ' ')
    CASE_CLONE=$(grep -cE '(^|[[:space:]])clone[[:space:]]' "$dbg/.git.calls" 2>/dev/null); CASE_CLONE=${CASE_CLONE:-0}
    CASE_GLOBAL_CONFIG=$(grep -cE 'config --global http\.postBuffer' "$dbg/.git.calls" 2>/dev/null); CASE_GLOBAL_CONFIG=${CASE_GLOBAL_CONFIG:-0}
    CASE_SCOPED_CLONE=$(grep -cE '^-c http\.postBuffer=536870912 [[:space:]]*clone' "$dbg/.git.calls" 2>/dev/null); CASE_SCOPED_CLONE=${CASE_SCOPED_CLONE:-0}
    rm -rf "$root" "$dbg"
}

run_cost_case 0;  total_0=$CASE_TOTAL;  planner_0=$CASE_PLANNER;  clone_0=$CASE_CLONE;  gconf_0=$CASE_GLOBAL_CONFIG;  scoped_0=$CASE_SCOPED_CLONE
run_cost_case 2;  total_2=$CASE_TOTAL;  planner_2=$CASE_PLANNER;  clone_2=$CASE_CLONE;  gconf_2=$CASE_GLOBAL_CONFIG;  scoped_2=$CASE_SCOPED_CLONE
run_cost_case 20; total_20=$CASE_TOTAL; planner_20=$CASE_PLANNER; clone_20=$CASE_CLONE; gconf_20=$CASE_GLOBAL_CONFIG; scoped_20=$CASE_SCOPED_CLONE

echo "diag: python total N=0/2/20 = $total_0/$total_2/$total_20; planner = $planner_0/$planner_2/$planner_20"
echo "diag: git global-config N=0/2/20 = $gconf_0/$gconf_2/$gconf_20; clone = $clone_0/$clone_2/$clone_20; scoped = $scoped_0/$scoped_2/$scoped_20"

# ---- Task 2: Python 预算锁(total 与 N 无关 + planner 恰好 1;Git 调用面锁见 Task3)----
assert_eq "python total N=0 == N=2"  "$total_0" "$total_2"
assert_eq "python total N=2 == N=20" "$total_2" "$total_20"
assert_eq "planner count N=0"  "$planner_0" 1
assert_eq "planner count N=2"  "$planner_2" 1
assert_eq "planner count N=20" "$planner_20" 1
assert_eq "N=0 no clone"       "$clone_0" 0

# ---- Task 3: Git 调用面锁(全局写入 0 + clone==N + command-scoped==N)----
assert_eq "global config N=0 == 0"  "$gconf_0" 0
assert_eq "global config N=2 == 0"  "$gconf_2" 0
assert_eq "global config N=20 == 0" "$gconf_20" 0
assert_eq "clone count N=2 == 2"    "$clone_2" 2
assert_eq "clone count N=20 == 20"  "$clone_20" 20
assert_eq "scoped clone N=2 == 2"   "$scoped_2" 2
assert_eq "scoped clone N=20 == 20" "$scoped_20" 20

# ---- Task 4: public-interface 断言(bare_mirror_base / bare_mirror_print_status 跨 public iface)----
# N=0 成功后:base 输出 effective mirror base;status 输出 `Mirrors populated: 0 new, 0 existing`。
_proot="$(mktemp -d)"; _pbuild="$_proot/openbmc/build/romulus"; mkdir -p "$_pbuild/conf"
printf '# comment-only local.conf\n' > "$_pbuild/conf/local.conf"
write_deps_fixture "$_pbuild/deps.json" 0
_pmbase="$_proot/downloads/git2"
_pdbg="$(mktemp -d)"; make_fake_git "$_pdbg"; make_fake_python "$_pdbg"
export PLANNER_DEPS_JSON="$_pbuild/deps.json" PLANNER_MIRROR_BASE="$_pmbase"
export PYTHON_CALLS_LOG="$(mktemp)" PLANNER_CALLS_LOG="$(mktemp)"
_piface="$(with_stub "$_pdbg" -- bash -c 'OB_NO_MAIN=1 source "$1"
WORKSPACE_DIR="'"$_proot"'"; BUILD_DIR="'"$_pbuild"'"; MACHINE="romulus"; DRY_RUN=0
clone_sub_repos >/dev/null
echo "=BASE="; bare_mirror_base; echo "=STATUS="; bare_mirror_print_status romulus
' _ "$OB" 2>/dev/null)"
assert_eq     "N=0 public base"     "$(sed -n '/=BASE=/{n;p}' <<<"$_piface")" "$_pmbase"
assert_contains "N=0 public status" "$_piface" "Mirrors populated: 0 new, 0 existing"
rm -rf "$_proot" "$_pdbg"

# 损坏 JSON:bare_mirror_provision return 1 后 initialized 保持 0,base 与 status 都空。
_broot="$(mktemp -d)"; _bbuild="$_broot/openbmc/build/romulus"; mkdir -p "$_bbuild/conf"
printf '# comment-only local.conf\n' > "$_bbuild/conf/local.conf"
printf '{bad json' > "$_bbuild/deps.json"
_bmbase="$_broot/downloads/git2"
_bdbg="$(mktemp -d)"; make_fake_git "$_bdbg"; make_fake_python "$_bdbg"
export PLANNER_DEPS_JSON="$_bbuild/deps.json" PLANNER_MIRROR_BASE="$_bmbase"
export PYTHON_CALLS_LOG="$(mktemp)" PLANNER_CALLS_LOG="$(mktemp)"
_bout="$(with_stub "$_bdbg" -- bash -c 'OB_NO_MAIN=1 source "$1"; set +e
bare_mirror_provision "'"$_bbuild"'/deps.json" "'"$_bmbase"'" "'"$_bbuild"'"; echo "rc=$?"
echo "=BASE=[$(bare_mirror_base)]=END="; bare_mirror_print_status romulus; echo "=STATUSEND="
' _ "$OB" 2>/dev/null)"
assert_eq    "bad JSON provision rc=1"            "$(grep -oP 'rc=\K[0-9]+' <<<"$_bout")" 1
assert_true  "bad JSON base empty after failure"  grep -qF '=BASE=[]=END=' <<<"$_bout"
assert_false "bad JSON status empty after failure" grep -q 'Mirrors populated' <<<"$_bout"
rm -rf "$_broot" "$_bdbg"

assert_summary
