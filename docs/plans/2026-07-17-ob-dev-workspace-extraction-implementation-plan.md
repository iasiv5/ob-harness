# ob dev workspace 抽取实施计划

## 目标

把 `lib/devtool_modify.sh` 里四个跨子命令共享/寄生的函数,拆成两个 leaf-pure module,纯物理搬家、零行为变化:

- `lib/devtool_workspace.sh` = devtool workspace 交互原语(`_devtool_env_exec` + `_devtool_parse_srctree` + `_devtool_parse_status_all`)
- `lib/devtool_status.sh` = status 子命令底层组装器(`devtool_status_run`)

搬完后 `devtool_modify.sh` 只剩 `devtool_modify_run`,与 `devtool_reset.sh`/`devtool_search.sh`/`devtool_status.sh` 对称(一子命令一文件);四个消费者(modify/reset/search/status)显式依赖 workspace 原语,消除「靠 loader 字母序复用」这条假约束。

## 架构快照

本次只搬函数物理位置,不改函数体、不改调用点、不改协议。ob loader(`ob:73-76` `for f in lib/*.sh`)glob 所有 lib,新文件自动收录;bash 函数运行时按名解析,函数名不变 → 所有调用点零改动。单测经 `tests/lib/ob_loader.sh`(`OB_NO_MAIN=1 source "$OB"`)走同一加载入口,新 lib 自动可见。

测试按 lib 对称拆(replace don't layer):搬走的原语在新 test surface 有自己的单测;`_devtool_parse_srctree` 现状只有 `devtool_modify_run` 间接覆盖,搬走后在 workspace 测试补独立单测(只锁输出、不锁 rc,见 Task 2 note)。

## 全局约束

- **零行为变化(核心不变量)**:函数体逐字搬移,不改逻辑、不改签名、不改 outvar 协议、不改 mock。每个 task 的验证要能证明调用点行为不变。
- **leaf-pure module**:新 lib 函数绝不 `exit`;`tools/exit_contract.py` `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 登记新 basename(例外集 `set()`)。
- **porcelain stdout 契约**:`ob dev` stdout 只输出数据(`CONTEXT.md` `ob dev porcelain stdout`);本次不碰 porcelain 发布逻辑,搬走的函数仍受约束。
- **改 `ob`/`lib/*.sh` 后必跑 `tools/ob_check.sh`**(AGENTS.md 约定)。
- **outvar 名遮蔽陷阱**:组装器用固定 receiver 前缀(`_status_*`/`_resolved_*`);本次逐字搬移不改 outvar 逻辑,不引入新遮蔽。
- **验证命令退出码归位**:所有 Run 命令必须让真实失败反映为非零退出码——多条验证用累积 `fail` + 末尾 `exit "$fail"`,禁止用末尾 `echo` 吞掉中间 rc;grep 门禁用 `test`/`! grep` 收尾;**grep 计数赋值(`grep -c`/`grep -oE|wc -l`)一律加 `|| true` 吞无匹配**,避免 strict shell(`set -euo pipefail`)下 grep 返回 1 在 `_n=$(...)` 赋值处提前退出、来不及打印计数与比较。
- 当前分支 `feature/ob-dev-devtool-modify`(非 main)。
- 无版本下限、无平台要求、无新增外部依赖。

## 输入工件

- grilling 7 条决策共识(本对话):步子=纯物理搬家 / scope=三原语都搬 / status_run 归新 devtool_status.sh / 测试按 lib 对称拆 + replace don't layer / 门禁 exit_contract 加两 basename / docs(WORKSPACE 改 + reset.sh:4 注释清理 + 新文件头写正确认知 + CONTEXT 不改 + 冻结 design 不改) / 单独合并。
- 已核实事实:`_devtool_env_exec`/`_devtool_parse_srctree`/`_devtool_parse_status_all`/`devtool_status_run` 定义全在 `lib/devtool_modify.sh`;消费者调用点(modify.sh:65/67/71/73/75、reset.sh:331/335/364/374/378、search.sh:368、commands.sh `cmd_dev` 调 `devtool_status_run`)零改动;窄基线 `devtool_modify/reset/search.sh` + `cmd_dev.sh` + `exit_contract` 均退出码 0。

## 文件结构与职责

- **Create** `lib/devtool_workspace.sh` — workspace 交互原语 leaf-pure module(`_devtool_env_exec` + `_devtool_parse_srctree` + `_devtool_parse_status_all`)。文件头声明 leaf-pure + 「运行时解析、不依赖 source 顺序」+ 文件级 `shellcheck disable=SC1091`(随 `_devtool_env_exec` 从 modify.sh:2 搬入)。
- **Create** `lib/devtool_status.sh` — status 子命令底层 leaf-pure module(`devtool_status_run`),消费 workspace 原语。
- **Create** `tests/unit/devtool_workspace.sh` — workspace 原语单测(从 modify 测试搬 env_exec/parse_status_all 断言 + 新建 parse_srctree 独立断言)。
- **Create** `tests/unit/devtool_status.sh` — status_run 单测(从 modify 测试搬 status_run 断言)。
- **Modify** `lib/devtool_modify.sh` — 移除四个搬走的函数,保留 `devtool_modify_run`;文件头注释更新(原 modify.sh:2 的 SC1091 disable 随 env_exec 搬走,modify.sh 不再 source setup,不需保留)。
- **Modify** `lib/devtool_reset.sh:4` — false constraint 注释改为指向 workspace.sh + 运行时解析认知。
- **Modify** `tools/exit_contract.py` — `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 加 `devtool_workspace.sh`/`devtool_status.sh`。
- **Modify** `rules/03_WORKSPACE.md` — `lib/` 路由段加两新文件。
- **Modify** `tests/unit/devtool_modify.sh` — 删搬走的断言,保留 `devtool_modify_run` 断言。

稳定边界(不改):所有消费者调用点、`CONTEXT.md`、冻结 design(`docs/specs/2026-07-13-*`/`2026-07-15-*`)、`ob` 主脚本 loader、`tests/run_all.sh`。

## 任务清单

### Task 1: 建 devtool_workspace.sh,从 modify.sh 移出三个原语

- 目标:新建 `lib/devtool_workspace.sh`,把 `_devtool_env_exec`/`_devtool_parse_srctree`/`_devtool_parse_status_all`(连同其上方注释)从 `lib/devtool_modify.sh` 逐字移入。一次原子移动,移出即删原位置。
- Files
  - Create: `lib/devtool_workspace.sh`
  - Modify: `lib/devtool_modify.sh`(移除三函数 + 文件头注释更新)
- 验证范围:三个函数**定义**只在 workspace.sh(锚定 `^funcname()` 行,非注释/调用点);modify/reset/search 消费者单测全绿(零行为变化);workspace.sh 通过 `extract_funcs` 三段合规。
- 接口契约
  - Consumes: 无(三函数定义从 modify.sh 原样移入)。
  - Produces: `lib/devtool_workspace.sh` 提供全局函数 `_devtool_env_exec`/`_devtool_parse_srctree`/`_devtool_parse_status_all`(供 Task 2/3 的测试、modify/reset/search/status 消费者调用)。

- [ ] Step 1: 改动前检查——三函数定义当前在 modify.sh、workspace.sh 不存在
- Run:
```bash
fail=0
_n=$(grep -cE '^(_devtool_env_exec|_devtool_parse_srctree|_devtool_parse_status_all)\(\)' lib/devtool_modify.sh || true); echo "modify 定义数=$_n"; [[ "$_n" -eq 3 ]] || fail=1
test ! -e lib/devtool_workspace.sh && echo 'workspace.sh absent OK' || fail=1
exit "$fail"
```
- Expected: `modify 定义数=3`;`workspace.sh absent OK`;退出码 `0`。

- [ ] Step 2: 确认现状(消费者测试当前绿,作为零行为变化基线)
- Run:
```bash
fail=0
bash tests/unit/devtool_modify.sh >/dev/null 2>&1; rc=$?; echo "modify=$rc"; [[ $rc -eq 0 ]] || fail=1
bash tests/unit/devtool_reset.sh >/dev/null 2>&1; rc=$?; echo "reset=$rc"; [[ $rc -eq 0 ]] || fail=1
bash tests/unit/devtool_search.sh >/dev/null 2>&1; rc=$?; echo "search=$rc"; [[ $rc -eq 0 ]] || fail=1
exit "$fail"
```
- Expected: `modify=0` `reset=0` `search=0`;退出码 `0`。

- [ ] Step 3: 写最小实现
- 新建 `lib/devtool_workspace.sh`,内容如下(文件头 + 三函数逐字从 modify.sh 移入,函数体不变):
```bash
#!/usr/bin/env bash
# shellcheck disable=SC1091   # source setup 是动态文件;_devtool_env_exec 在 && 链中 source,行级 disable 不可用(SC1126),故文件级(从原 modify.sh:2 随函数搬入)
# lib/devtool_workspace.sh — devtool workspace 交互原语(leaf-pure module)。
#   _devtool_env_exec(进 build env 跑 devtool 子命令 + tempfile 协议 + stage 追踪 + postcondition)
#   + _devtool_parse_srctree(单条 status→srctree) + _devtool_parse_status_all(全量 status→entries)。
#   被 devtool_modify/devtool_reset/devtool_search/devtool_status 消费(全局命名空间)。
#   ob loader(ob:73-76 for f in lib/*.sh)source 全部 lib; bash 函数运行时按名解析,
#   不依赖 source 顺序(字母序无关——曾误判为约束,已澄清)。术语见 CONTEXT.md function semantic layer / ob dev porcelain stdout。
# Exit: leaf-pure module(函数绝不 exit; 允许文件/进程副作用); 调用者(cmd_dev/各 *_run)负责 exit-code/remedy/诊断。

# _devtool_env_exec <machine> <build_dir> <stage_file> <stdout_file> <stderr_file> -- <cmd...>
# 同一 subshell(&& 链,无 exit 字面量);只有 <cmd> stdout → stdout_file;setup/postcondition 输出 → stderr_file。
# stage 写 stage_file: cd/setup/postcondition/command。返回 rc(不 exit)。
_devtool_env_exec() {
    local machine="$1" build_dir="$2" stage_file="$3" stdout_file="$4" stderr_file="$5"
    shift 5
    [[ "$1" == "--" ]] && shift
    (
        echo cd >"$stage_file"
        cd "$OPENBMC_DIR" &&
        echo setup >"$stage_file" &&
        set +u &&   # setup 脚本可能用未绑定变量(如 ZSH_NAME),关 nounset(仿 build_env_enter);子 shell 内不影响父
        source setup "$machine" "$build_dir" >>"$stderr_file" 2>&1 &&
        echo postcondition >"$stage_file" &&
        [[ -f "$build_dir/conf/local.conf" ]] &&
        command -v devtool >>"$stderr_file" &&
        command -v bitbake-layers >>"$stderr_file" &&
        echo command >"$stage_file" &&
        "$@" >"$stdout_file"
    ) 2>>"$stderr_file"
    return $?
}

# _devtool_parse_srctree <recipe> <status_file> → srctree(字面匹配 recipe 行,不把 recipe 当正则;
# 剥离可选 " (recipefile)" 后缀)。无匹配输出空,返回 1。
_devtool_parse_srctree() {
    local rcp="$1" file="$2"
    awk -v r="$rcp" 'index($0,r": ")==1{s=substr($0,index($0,": ")+2);sub(/ \([^)]*\)$/,"",s);print s;exit}' "$file" 2>/dev/null
}

# _devtool_parse_status_all <status_file> → stdout 每行 "recipe<TAB>srctree"
# 全量解析 devtool status: 行内首个 ": " 前=recipe(非空、不含空白),后=srctree(剥 "(recipefile)" 后缀)。
# 跳过 header/空行/无 ": "/recipe 空。纯函数(读 file, 输出 stdout), 绝不 exit。
_devtool_parse_status_all() {
    local file="$1"
    awk '{
        pos = index($0, ": ")
        if (pos <= 1) next
        recipe = substr($0, 1, pos - 1)
        if (recipe == "") next
        srctree = substr($0, pos + 2)
        sub(/ \([^)]*\)$/, "", srctree)
        if (recipe ~ /^(NOTE|WARNING|ERROR|DEBUG|CRITICAL)$/) next   # bitbake 诊断 token(防 WARNING: /abs/path 漏网)
        if (recipe !~ /^[A-Za-z0-9._+-]+$/) next                     # PN 字符集(挡含空白噪声行)
        if (srctree !~ /^\//) next                                   # srctree 必须绝对路径(devtool EXTERNALSRC)
        print recipe "\t" srctree
    }' "$file" 2>/dev/null
}
```
- 同时从 `lib/devtool_modify.sh` 删除上述三函数定义及其上方注释行(`_devtool_env_exec` 块 modify.sh:6-27、`_devtool_parse_srctree` 块 modify.sh:29-34、`_devtool_parse_status_all` 块 modify.sh:36-53),保留 `devtool_modify_run`(modify.sh:55-90)与 `devtool_status_run`(modify.sh:92-112,Task 3 处理)。
- 把 `lib/devtool_modify.sh` 文件头注释(modify.sh:1-4,含原 :2 的 SC1091 disable 行)更新为:
```bash
#!/usr/bin/env bash
# lib/devtool_modify.sh — devtool modify 执行(devtool_modify_run;消费 lib/devtool_workspace.sh 的
#   _devtool_env_exec / _devtool_parse_srctree)。devtool_status_run 暂留本文件,待后续整理。
# 术语见 CONTEXT.md。Exit: leaf-pure module(函数绝不 exit); 调用者(cmd_dev)负责 exit-code/remedy/诊断。
```
- Change: 新建 workspace.sh(三原语 + SC1091);modify.sh 删三函数 + 文件头更新(原 SC1091 disable 随 env_exec 搬走)。

- [ ] Step 4: 运行并确认通过
- Run:
```bash
fail=0
grep -qE '^_devtool_env_exec\(\)'      lib/devtool_workspace.sh || fail=1
grep -qE '^_devtool_parse_srctree\(\)' lib/devtool_workspace.sh || fail=1
grep -qE '^_devtool_parse_status_all\(\)' lib/devtool_workspace.sh || fail=1
! grep -qE '^(_devtool_env_exec|_devtool_parse_srctree|_devtool_parse_status_all)\(\)' lib/devtool_modify.sh && echo 'modify 无三函数定义 OK' || fail=1
bash tests/unit/devtool_modify.sh >/dev/null 2>&1; rc=$?; echo "modify=$rc"; [[ $rc -eq 0 ]] || fail=1
bash tests/unit/devtool_reset.sh  >/dev/null 2>&1; rc=$?; echo "reset=$rc";  [[ $rc -eq 0 ]] || fail=1
bash tests/unit/devtool_search.sh >/dev/null 2>&1; rc=$?; echo "search=$rc"; [[ $rc -eq 0 ]] || fail=1
python3 tools/extract_funcs.py lib/devtool_workspace.sh >/dev/null 2>&1; rc=$?; echo "extract=$rc"; [[ $rc -eq 0 ]] || fail=1
exit "$fail"
```
- Expected: `modify 无三函数定义 OK`;`modify=0` `reset=0` `search=0` `extract=0`;退出码 `0`。

- [ ] Step 5: 可选 checkpoint commit
- 仅当执行者本轮被明确要求提交时执行;否则保留 git diff/summary,不影响本 Task 完成判定。
- Run(授权时): `git add lib/devtool_workspace.sh lib/devtool_modify.sh && git commit -m "refactor(dev): extract devtool_workspace.sh (env_exec + parse helpers)"`
- Expected: commit 成功(仅授权时)。

### Task 2: 建 devtool_workspace.sh 单测,从 modify 测试搬断言 + 补 parse_srctree 独立断言

- 目标:新建 `tests/unit/devtool_workspace.sh`,从 `tests/unit/devtool_modify.sh` 搬入 `_devtool_env_exec` 与 `_devtool_parse_status_all` 的断言(含所需 mock build env setup),并为 `_devtool_parse_srctree` 新建独立断言(现状只有 modify_run 间接覆盖);从 modify 测试删除搬走的断言。
- **note(`_devtool_parse_srctree` 返回码)**:其注释「无匹配返回 1」是既存不准确描述——awk 无匹配实际返回 0、输出空。本次纯搬家不改注释、不改行为;独立单测**只锁输出(空)、不锁 rc**,避免与既存注释/实现矛盾。修正注释属另一轮 scope。
- Files
  - Create: `tests/unit/devtool_workspace.sh`
  - Modify: `tests/unit/devtool_modify.sh`(删 env_exec 断言 modify.sh-test:56-76、parse_status_all 断言 modify.sh-test:126-146)
- 验证范围:workspace 测试绿(env_exec/parse_srctree/parse_status_all);modify 测试绿(剩 modify_run + status_run)。
- 接口契约
  - Consumes: Task 1 产出的 `lib/devtool_workspace.sh` 三函数;`tests/lib/ob_loader.sh`+`tests/lib/assert.sh`。
  - Produces: `tests/unit/devtool_workspace.sh`(workspace 原语的 test surface)。

- [ ] Step 1: 改动前检查——断言当前在 modify 测试、workspace 测试不存在
- Run:
```bash
fail=0
_n=$(grep -cE '_devtool_env_exec|_devtool_parse_status_all' tests/unit/devtool_modify.sh || true); echo "modify 测试命中行=$_n"; [[ "$_n" -ge 2 ]] || fail=1
test ! -e tests/unit/devtool_workspace.sh && echo 'workspace test absent OK' || fail=1
exit "$fail"
```
- Expected: `modify 测试命中行` ≥2;`workspace test absent OK`;退出码 `0`。

- [ ] Step 2: 确认现状(modify 测试当前绿)
- Run:
```bash
bash tests/unit/devtool_modify.sh >/dev/null 2>&1; rc=$?; echo "modify=$rc"; [[ $rc -eq 0 ]] || exit 1
```
- Expected: `modify=0`;退出码 `0`。

- [ ] Step 3: 写最小实现
- 新建 `tests/unit/devtool_workspace.sh`,内容如下(头部 mock build env 复用 modify 测试 modify.sh-test:8-54 的模式;断言从 modify 测试搬入 + 新增 parse_srctree 独立断言):
```bash
#!/usr/bin/env bash
# tests/unit/devtool_workspace.sh — _devtool_env_exec + _devtool_parse_srctree + _devtool_parse_status_all 单测。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
export TMP
trap 'rm -rf "$TMP"' EXIT

# === mock build env(镜像 tests/unit/devtool_modify.sh 的 setup) ===
OPENBMC_DIR="$TMP/openbmc"
BUILD_DIR="$TMP/build"
export OPENBMC_DIR BUILD_DIR
mkdir -p "$OPENBMC_DIR" "$BUILD_DIR/conf" "$TMP/bin" "$TMP/workspace/sources"
cat > "$OPENBMC_DIR/setup" <<'EOF'
#!/usr/bin/env bash
export SETUP_DONE=1
echo "MOCK_SETUP_NOISE_TO_STDOUT"
EOF
chmod +x "$OPENBMC_DIR/setup"
cat > "$TMP/bin/devtool" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  status) exit "${MOCK_STATUS_RC:-0}" ;;
esac
EOF
chmod +x "$TMP/bin/devtool"
printf '#!/usr/bin/env bash\necho mock-bitbake-layers\n' > "$TMP/bin/bitbake-layers"
chmod +x "$TMP/bin/bitbake-layers"
export PATH="$TMP/bin:$PATH"
MACHINE="testm"
touch "$BUILD_DIR/conf/local.conf" "$BUILD_DIR/conf/bblayers.conf"

# === _devtool_env_exec: tempfile 协议 + 输出隔离(从 modify 测试搬入) ===
s="$TMP/s1"; o="$TMP/o1"; e="$TMP/e1"; : >"$s"; : >"$o"; : >"$e"
rc=0
_devtool_env_exec "$MACHINE" "$BUILD_DIR" "$s" "$o" "$e" -- echo HELLO || rc=$?
assert_eq     "_devtool_env_exec echo rc=0"        "$rc" 0
assert_contains "_devtool_env_exec stdout 含 HELLO"   "$(cat "$o")" "HELLO"
assert_false  "_devtool_env_exec stdout 不含 setup 噪声" grep -q "MOCK_SETUP_NOISE" "$o"
assert_contains "_devtool_env_exec stage=command"     "$(cat "$s")" "command"

# === _devtool_env_exec: 同一 subshell(setup 注入的 SETUP_DONE 在 cmd 可见) ===
s="$TMP/s2"; o="$TMP/o2"; e="$TMP/e2"; : >"$s"; : >"$o"; : >"$e"
_devtool_env_exec "$MACHINE" "$BUILD_DIR" "$s" "$o" "$e" -- sh -c 'echo "SETUP=$SETUP_DONE"' || true
assert_contains "_devtool_env_exec 同一 subshell(SETUP 可见)" "$(cat "$o")" "SETUP=1"

# === _devtool_env_exec: postcondition 失败(删 local.conf) ===
rm -f "$BUILD_DIR/conf/local.conf"
s="$TMP/s3"; o="$TMP/o3"; e="$TMP/e3"; : >"$s"; : >"$o"; : >"$e"; rc=0
_devtool_env_exec "$MACHINE" "$BUILD_DIR" "$s" "$o" "$e" -- echo HELLO || rc=$?
assert_false  "_devtool_env_exec postcondition 失败 rc!=0" test "$rc" -eq 0
assert_contains "_devtool_env_exec stage=postcondition" "$(cat "$s")" "postcondition"
touch "$BUILD_DIR/conf/local.conf"

# === _devtool_parse_srctree: 独立断言(现状仅 modify_run 间接覆盖,补 test surface;只锁输出不锁 rc) ===
_pst_tmp="$(mktemp)"
printf 'foorecipe: /ws/foorecipe (recipes-foo/foorecipe.bb)\n' > "$_pst_tmp"
printf 'other: /ws/other\n' >> "$_pst_tmp"
printf 'gstreamer1.0: /ws/gstreamer1.0\n' >> "$_pst_tmp"
assert_eq "parse_srctree 字面匹配+剥 recipefile" "$(_devtool_parse_srctree "foorecipe" "$_pst_tmp")" "/ws/foorecipe"
assert_eq "parse_srctree 精确匹配 other" "$(_devtool_parse_srctree "other" "$_pst_tmp")" "/ws/other"
assert_eq "parse_srctree 含 . 字面匹配(非正则)" "$(_devtool_parse_srctree "gstreamer1.0" "$_pst_tmp")" "/ws/gstreamer1.0"
assert_eq "parse_srctree 无匹配输出空" "$(_devtool_parse_srctree "nonexist" "$_pst_tmp")" ""
rm -f "$_pst_tmp"

# === _devtool_parse_status_all: 全量解析(从 modify 测试搬入) ===
_psa_tmp="$(mktemp)"
printf 'foorecipe: %s/workspace/sources/foorecipe (recipes-foo/foorecipe.bb)\n' "$TMP" > "$_psa_tmp"
printf 'barrecipe: %s/workspace/sources/barrecipe\n' "$TMP" >> "$_psa_tmp"
printf 'Currently working recipes:\n' >> "$_psa_tmp"
_psa_out="$(_devtool_parse_status_all "$_psa_tmp")"
assert_eq "parse_status_all 行数(2 recipe,header 跳过)" "$(printf '%s\n' "$_psa_out" | grep -c .)" "2"
assert_contains "parse_status_all foorecipe+srctree" "$_psa_out" $'foorecipe\t'"$TMP/workspace/sources/foorecipe"
assert_false "parse_status_all 剥掉 recipefile 后缀" grep -q 'recipes-foo/foorecipe.bb' <<<"$_psa_out"
assert_false "parse_status_all 跳过 header" grep -q 'Currently working recipes' <<<"$_psa_out"
rm -f "$_psa_tmp"
_psa_empty="$(mktemp)"; assert_eq "parse_status_all 空文件无输出" "$(_devtool_parse_status_all "$_psa_empty" | grep -c .)" "0"; rm -f "$_psa_empty"
_psa_neg="$(mktemp)"
printf 'NOTE: some bitbake noise\n' > "$_psa_neg"
printf 'WARNING: /abs/path\n' >> "$_psa_neg"
printf 'foo bar: /tmp/x\n' >> "$_psa_neg"
printf 'good: relative/path\n' >> "$_psa_neg"
assert_eq "parse_status_all 负例全跳过(0 行)" "$(_devtool_parse_status_all "$_psa_neg" | grep -c .)" "0"
rm -f "$_psa_neg"

assert_summary
```
- 从 `tests/unit/devtool_modify.sh` 删除:`_devtool_env_exec` 三段断言(modify.sh-test:56-76)、`_devtool_parse_status_all` 断言(modify.sh-test:126-146)。保留 `devtool_modify_run` 断言(modify.sh-test:78-124)与 `devtool_status_run` 断言(modify.sh-test:148-178,Task 3 处理)。
- Change: 新建 workspace 测试;modify 测试删两段搬走的断言。

- [ ] Step 4: 运行并确认通过
- Run:
```bash
fail=0
bash tests/unit/devtool_workspace.sh >/dev/null 2>&1; rc=$?; echo "workspace=$rc"; [[ $rc -eq 0 ]] || fail=1
bash tests/unit/devtool_modify.sh   >/dev/null 2>&1; rc=$?; echo "modify=$rc";   [[ $rc -eq 0 ]] || fail=1
exit "$fail"
```
- Expected: `workspace=0` `modify=0`;退出码 `0`。

- [ ] Step 5: 可选 checkpoint commit
- 仅当执行者本轮被明确要求提交时执行;否则保留 git diff/summary,不影响本 Task 完成判定。
- Run(授权时): `git add tests/unit/devtool_workspace.sh tests/unit/devtool_modify.sh && git commit -m "test(dev): split devtool_workspace unit tests (+ parse_srctree coverage)"`
- Expected: commit 成功(仅授权时)。

### Task 3: 建 devtool_status.sh + 单测,搬 devtool_status_run

- 目标:新建 `lib/devtool_status.sh`,把 `devtool_status_run`(含注释)从 `lib/devtool_modify.sh` 逐字移入;新建 `tests/unit/devtool_status.sh` 搬入 status_run 断言;modify.sh/modify 测试删除对应函数与断言,modify.sh 文件头收尾。
- Files
  - Create: `lib/devtool_status.sh`、`tests/unit/devtool_status.sh`
  - Modify: `lib/devtool_modify.sh`(移除 `devtool_status_run` + 文件头收尾)、`tests/unit/devtool_modify.sh`(删 status_run 断言 modify.sh-test:148-178)
- 验证范围:`devtool_status_run` 定义只在 status.sh;status 测试绿;modify 测试绿(只剩 modify_run);`cmd_dev` 经 status_run 的编排测试绿(orchestration/protocol)。
- 接口契约
  - Consumes: Task 1 的 `lib/devtool_workspace.sh`(`_devtool_env_exec`/`_devtool_parse_status_all`);`tests/lib/ob_loader.sh`+`assert.sh`。
  - Produces: `lib/devtool_status.sh`(`devtool_status_run`,cmd_dev 的 status 分支经它);`tests/unit/devtool_status.sh`。

- [ ] Step 1: 改动前检查——status_run 当前在 modify.sh、status.sh 不存在
- Run:
```bash
fail=0
grep -qE '^devtool_status_run\(\)' lib/devtool_modify.sh && echo 'status_run 在 modify OK' || fail=1
test ! -e lib/devtool_status.sh && echo 'status.sh absent OK' || fail=1
test ! -e tests/unit/devtool_status.sh && echo 'status test absent OK' || fail=1
exit "$fail"
```
- Expected: 三条 `OK`;退出码 `0`。

- [ ] Step 2: 确认现状(消费者测试绿)
- Run:
```bash
fail=0
bash tests/unit/devtool_modify.sh >/dev/null 2>&1; rc=$?; echo "modify=$rc"; [[ $rc -eq 0 ]] || fail=1
bash tests/orchestration/cmd_dev.sh >/dev/null 2>&1; rc=$?; echo "orch=$rc"; [[ $rc -eq 0 ]] || fail=1
exit "$fail"
```
- Expected: `modify=0` `orch=0`;退出码 `0`。

- [ ] Step 3: 写最小实现
- 新建 `lib/devtool_status.sh`:
```bash
#!/usr/bin/env bash
# lib/devtool_status.sh — devtool status 子命令底层组装器(leaf-pure module)。
#   devtool_status_run: 经 _devtool_env_exec 跑 devtool status → _devtool_parse_status_all 全量解析 → outvar。
#   消费 lib/devtool_workspace.sh 的 _devtool_env_exec / _devtool_parse_status_all(全局命名空间)。
#   ob loader source 全部 lib; bash 运行时按名解析,不依赖 source 顺序。术语见 CONTEXT.md ob dev porcelain stdout。
# Exit: leaf-pure module(函数绝不 exit; 允许文件/进程副作用); 调用者(cmd_dev)负责 exit-code/remedy/诊断。

# devtool_status_run <machine> <build_dir> <entries_outvar> <stage_outvar> <stderr_file_outvar>
# leaf-pure 组装器: env_exec 跑 devtool status → _devtool_parse_status_all 全量解析 → outvar 回传。
# entries = 换行分隔 "recipe<TAB>srctree" 串(空列表→空串); stage = cd/setup/postcondition/command;
# stderr_file 传 caller(cat+rm); 内部 stdout_file 解析后 rm。返回 rc(不 exit)。
devtool_status_run() {
    local machine="$1" build_dir="$2"
    local entries_outvar="$3" stage_outvar="$4" stderr_file_outvar="$5"
    local stage_file stdout_file stderr_file rc entries=""
    stage_file="$(mktemp)"; stdout_file="$(mktemp)"; stderr_file="$(mktemp)"
    rc=0
    : > "$stdout_file"
    _devtool_env_exec "$machine" "$build_dir" "$stage_file" "$stdout_file" "$stderr_file" -- devtool status || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        entries="$(_devtool_parse_status_all "$stdout_file")"
    fi
    printf -v "$entries_outvar" '%s' "$entries"
    printf -v "$stage_outvar" '%s' "$(cat "$stage_file" 2>/dev/null || true)"
    printf -v "$stderr_file_outvar" '%s' "$stderr_file"
    rm -f "$stage_file" "$stdout_file"
    return "$rc"
}
```
- 从 `lib/devtool_modify.sh` 删除 `devtool_status_run` 定义及其上方注释(modify.sh:92-112)。把 modify.sh 文件头(Task 1 已改为「modify_run;status_run 暂留」)收尾为:
```bash
#!/usr/bin/env bash
# lib/devtool_modify.sh — devtool modify 执行(devtool_modify_run;消费 lib/devtool_workspace.sh 的
#   _devtool_env_exec / _devtool_parse_srctree)。术语见 CONTEXT.md。
# Exit: leaf-pure module(函数绝不 exit); 调用者(cmd_dev)负责 exit-code/remedy/诊断。
```
- 新建 `tests/unit/devtool_status.sh`(status_run 三场景断言,从 modify 测试 modify.sh-test:148-178 搬入,含 mock `_devtool_env_exec`):
```bash
#!/usr/bin/env bash
# tests/unit/devtool_status.sh — devtool_status_run 单测(env_exec → 全量解析 → outvar)。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"; export TMP; trap 'rm -rf "$TMP"' EXIT
_dsr_machine="testm" _dsr_build="$TMP/build"

# mock _devtool_env_exec: 把 status 内容写进 stdout_file($4)
_devtool_env_exec() {
    local m="$1" b="$2" sf="$3" of="$4" erf="$5"; shift 5; [[ "$1" == "--" ]] && shift
    echo command > "$sf"
    printf 'ipmi-host: %s/workspace/sources/ipmi-host (recipes-core/ipmi-host.bb)\n' "$_dsr_build" > "$of"
    printf 'web: %s/workspace/sources/web\n' "$_dsr_build" >> "$of"
    return 0
}
_status_entries="" _status_stage="" _status_stderr=""
devtool_status_run "$_dsr_machine" "$_dsr_build" _status_entries _status_stage _status_stderr
assert_eq "status_run rc 0" "$?" "0"
assert_eq "status_run stage=command" "$_status_stage" "command"
assert_eq "status_run entries 行数" "$(printf '%s\n' "$_status_entries" | grep -c .)" "2"
assert_contains "status_run entries ipmi-host" "$_status_entries" $'ipmi-host\t'"$_dsr_build/workspace/sources/ipmi-host"
rm -f "$_status_stderr"
# rc 失败(command 阶段) → entries 空 + rc 非零 + stage 传播
_devtool_env_exec() { local sf="$3" of="$4"; echo command > "$sf"; : > "$of"; return 1; }
devtool_status_run "$_dsr_machine" "$_dsr_build" _status_entries _status_stage _status_stderr
assert_false "status_run rc 失败返回非零" test $? -eq 0
assert_eq "status_run 失败时 entries 空" "$_status_entries" ""
assert_eq "status_run 失败 stage=command" "$_status_stage" "command"
rm -f "$_status_stderr"
# stage 失败(postcondition, build env 未 ready) → stage 传播 + entries 空 + rc 非零
_devtool_env_exec() { local sf="$3" of="$4"; echo postcondition > "$sf"; : > "$of"; return 1; }
devtool_status_run "$_dsr_machine" "$_dsr_build" _status_entries _status_stage _status_stderr
assert_false "status_run postcondition 失败返回非零" test $? -eq 0
assert_eq "status_run postcondition stage 传播" "$_status_stage" "postcondition"
assert_eq "status_run postcondition entries 空" "$_status_entries" ""
rm -f "$_status_stderr"

assert_summary
```
- 从 `tests/unit/devtool_modify.sh` 删除 `devtool_status_run` 断言(modify.sh-test:148-178)。
- Change: 新建 status.sh + status 测试;modify.sh 删 status_run + 文件头收尾;modify 测试删 status_run 断言。

- [ ] Step 4: 运行并确认通过
- Run:
```bash
fail=0
! grep -qE '^devtool_status_run\(\)' lib/devtool_modify.sh && echo 'modify 无 status_run OK' || fail=1
_n=$(grep -cE '^devtool_status_run\(\)' lib/devtool_status.sh || true); echo "status.sh 定义=$_n"; [[ "$_n" -eq 1 ]] || fail=1
bash tests/unit/devtool_status.sh   >/dev/null 2>&1; rc=$?; echo "status=$rc"; [[ $rc -eq 0 ]] || fail=1
bash tests/unit/devtool_modify.sh   >/dev/null 2>&1; rc=$?; echo "modify=$rc"; [[ $rc -eq 0 ]] || fail=1
bash tests/orchestration/cmd_dev.sh >/dev/null 2>&1; rc=$?; echo "orch=$rc";   [[ $rc -eq 0 ]] || fail=1
exit "$fail"
```
- Expected: `modify 无 status_run OK`;`status.sh 定义=1`;`status=0` `modify=0` `orch=0`;退出码 `0`。

- [ ] Step 5: 可选 checkpoint commit
- 仅当执行者本轮被明确要求提交时执行;否则保留 git diff/summary,不影响本 Task 完成判定。
- Run(授权时): `git add lib/devtool_status.sh tests/unit/devtool_status.sh lib/devtool_modify.sh tests/unit/devtool_modify.sh && git commit -m "refactor(dev): extract devtool_status.sh (devtool_status_run)"`
- Expected: commit 成功(仅授权时)。

### Task 4: 清理 reset.sh:4 false constraint 注释

- 目标:把 `lib/devtool_reset.sh:4` 的「靠 ob loader glob 字母序 m<r<s」注释改为指向 `devtool_workspace.sh` + 运行时解析的正确认知。
- Files
  - Modify: `lib/devtool_reset.sh:4`
- 验证范围:reset.sh 无「字母序」字样;reset 测试绿(零行为变化)。
- 接口契约
  - Consumes: Task 1 的 `lib/devtool_workspace.sh`(注释指向它)。
  - Produces: 无(注释清理)。

- [ ] Step 1: 改动前检查——false constraint 注释当前存在
- Run:
```bash
grep -q '字母序' lib/devtool_reset.sh && echo '字母序注释存在 OK' || exit 1
```
- Expected: `字母序注释存在 OK`;退出码 `0`。

- [ ] Step 2: 确认现状(reset 测试绿)
- Run:
```bash
bash tests/unit/devtool_reset.sh >/dev/null 2>&1; rc=$?; echo "reset=$rc"; [[ $rc -eq 0 ]] || exit 1
```
- Expected: `reset=0`;退出码 `0`。

- [ ] Step 3: 写最小实现
- 把 `lib/devtool_reset.sh:4` 原文 `#   复用 lib/devtool_modify.sh 的 _devtool_env_exec / _devtool_parse_srctree(靠 ob loader glob 字母序 m<r<s)。` 改为:
```bash
#   复用 lib/devtool_workspace.sh 的 _devtool_env_exec / _devtool_parse_srctree(ob loader source 全部 lib; bash 运行时按名解析,不依赖 source 顺序)。
```
- Change: reset.sh:4 注释订正。

- [ ] Step 4: 运行并确认通过
- Run:
```bash
fail=0
! grep -q '字母序' lib/devtool_reset.sh && echo '无字母序 OK' || fail=1
bash tests/unit/devtool_reset.sh >/dev/null 2>&1; rc=$?; echo "reset=$rc"; [[ $rc -eq 0 ]] || fail=1
exit "$fail"
```
- Expected: `无字母序 OK`;`reset=0`;退出码 `0`。

- [ ] Step 5: 可选 checkpoint commit
- 仅当执行者本轮被明确要求提交时执行;否则保留 git diff/summary,不影响本 Task 完成判定。
- Run(授权时): `git add lib/devtool_reset.sh && git commit -m "docs(dev): fix reset.sh false loader-ordering constraint comment"`
- Expected: commit 成功(仅授权时)。

### Task 5: 门禁登记 + WORKSPACE 路由

- 目标:`tools/exit_contract.py` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 加两新 basename(`devtool_workspace.sh`/`devtool_status.sh`,例外集 `set()`);`rules/03_WORKSPACE.md` 的 `lib/` 路由段补两文件(建议各占独立片段,避免长单行;若沿用长单行,验证按匹配次数而非行数)。
- Files
  - Modify: `tools/exit_contract.py`(LEAF dict,line 53-64 段)、`rules/03_WORKSPACE.md`(`lib/` 路由段)
- 验证范围:exit_contract 认可两新 basename 为 leaf-pure(无真 exit 违例);ob_check 的 exit-contract 段通过;WORKSPACE 路由含两文件(按匹配次数)。
- 接口契约
  - Consumes: Task 1/3 产出的两新 lib(已存在且函数不 exit)。
  - Produces: exit_contract 对两新 basename 的 leaf-pure 认领;WORKSPACE 路由登记。

- [ ] Step 1: 改动前检查——两 basename 未登记、WORKSPACE 未含
- Run:
```bash
fail=0
_n=$(grep -cE 'devtool_workspace.sh|devtool_status.sh' tools/exit_contract.py || true); echo "exit_contract 命中行=$_n"; [[ "$_n" -eq 0 ]] || fail=1
_n=$(grep -oE 'devtool_workspace.sh|devtool_status.sh' rules/03_WORKSPACE.md | wc -l || true); echo "WORKSPACE 命中次数=$_n"; [[ "$_n" -eq 0 ]] || fail=1
exit "$fail"
```
- Expected: 两个计数均 `0`;退出码 `0`。

- [ ] Step 2: 确认现状(新文件未登记时 exit_contract 不覆盖它们,预期仍绿)
- Run:
```bash
python3 tools/exit_contract.py ob lib/*.sh >/dev/null 2>&1; rc=$?; echo "exit_contract=$rc"; [[ $rc -eq 0 ]] || exit 1
```
- Expected: `exit_contract=0`;退出码 `0`。

- [ ] Step 3: 写最小实现
- 在 `tools/exit_contract.py` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` dict(现有 `'devtool_modify.sh': set(),`/`'devtool_reset.sh': set(),`/`'devtool_search.sh': set(),` 三行附近)按字母序补两行:
```python
    'devtool_status.sh': set(),
    'devtool_workspace.sh': set(),
```
- 在 `rules/03_WORKSPACE.md` 的 `lib/` 路由段(现列 `devtool_modify.sh`/`devtool_reset.sh`/`devtool_search.sh` 的那句长描述)补入:`devtool_workspace.sh`(devtool workspace 交互原语 env_exec/parse,leaf-pure)与 `devtool_status.sh`(devtool status 底层 devtool_status_run,leaf-pure),措辞沿用既有「文件名(职责,leaf-pure)」格式。
- Change: exit_contract 登记两 basename;WORKSPACE 路由补两文件。

- [ ] Step 4: 运行并确认通过
- Run:
```bash
fail=0
_n=$(grep -cE "'devtool_workspace.sh': set\(\)|'devtool_status.sh': set\(\)" tools/exit_contract.py || true); echo "exit_contract 登记=$_n"; [[ "$_n" -eq 2 ]] || fail=1
_n=$(grep -oE 'devtool_workspace.sh|devtool_status.sh' rules/03_WORKSPACE.md | wc -l || true); echo "WORKSPACE 命中次数=$_n"; [[ "$_n" -ge 2 ]] || fail=1
python3 tools/exit_contract.py ob lib/*.sh >/dev/null 2>&1; rc=$?; echo "exit_contract=$rc"; [[ $rc -eq 0 ]] || fail=1
exit "$fail"
```
- Expected: `exit_contract 登记=2`;`WORKSPACE 命中次数` ≥2;`exit_contract=0`;退出码 `0`。

- [ ] Step 5: 可选 checkpoint commit
- 仅当执行者本轮被明确要求提交时执行;否则保留 git diff/summary,不影响本 Task 完成判定。
- Run(授权时): `git add tools/exit_contract.py rules/03_WORKSPACE.md && git commit -m "chore(dev): register devtool_workspace/status.sh as leaf-pure + WORKSPACE route"`
- Expected: commit 成功(仅授权时)。

### Task 6: 最终验证

- 目标:全量门禁 + 四层测试绿,坐实「零行为变化」。
- Files: 无(只跑验证)。
- 验证范围:ob_check 全段绿;run_all 默认三层绿;run_all --full 绿。
- 接口契约
  - Consumes: Task 1-5 全部产出。
  - Produces: 无。

- [ ] Step 1: ob_check 全段
- Run:
```bash
tools/ob_check.sh; rc=$?; echo "ob_check=$rc"; [[ $rc -eq 0 ]] || exit 1
```
- Expected: 全段通过(extract_funcs ob GAPS=0 + lib 三段含两新文件 / machine_state gate / shellcheck baseline 一致 / exit-contract 两新 basename leaf-pure / run_all 默认三层);`ob_check=0`,退出码 `0`。若 shellcheck baseline 因 flat 合成收录新文件出现 drift,确认是新文件无新增 SC 警告(函数体未变,SC1091 已文件级 disable)后按合法重构更新 `tests/.shellcheck-baseline`,再重跑至退出码 `0`。

- [ ] Step 2: run_all --full(含 .exp 交互矩阵)
- Run:
```bash
tests/run_all.sh --full; rc=$?; echo "full=$rc"; [[ $rc -eq 0 ]] || exit 1
```
- Expected: protocol/unit/orchestration 的 .sh + .exp 全绿(含 `dev_interactive.exp`、`usage_dispatch_sync.sh`、新 `devtool_workspace.sh`/`devtool_status.sh` 单测);`full=0`,退出码 `0`。

- [ ] Step 3(可选): run_all --integration
- Run:
```bash
tests/run_all.sh --integration; rc=$?; echo "integration=$rc"; [[ $rc -eq 0 ]] || exit 1
```
- Expected: 集成层(modify/reset 端到端)绿;搬家不改集成行为,退出码 `0`。环境无 initialized machine 时 run_all 以 SKIP 返回 0,不算失败。

- [ ] Step 4: 输出修改摘要
- 列出:新建 2 lib + 2 单测;modify.sh/reset.sh/exit_contract.py/WORKSPACE.md/modify 测试改动;确认调用点零改动。

## 执行纪律

- 开始实现前先批判性复查整份计划;发现缺项、矛盾、命名不一致或验证命令无效,先修计划。
- 按任务顺序执行(Task 1→6),不要无声跳步、合并步或改变任务目标。Task 2/3 依赖 Task 1;Task 4/5 依赖 Task 1;Task 6 依赖全部。
- 每完成一个任务,运行该任务 Step 4 的验证命令,**确认退出码为 0 再进下一个**;验证命令已用累积 `fail`+`exit "$fail"` 归位,禁止用末尾 `echo` 吞掉真实 rc。
- checkpoint commit 仅在执行者本轮被明确要求提交时执行;否则保留 git diff/summary,不影响任务完成判定。
- 遇到阻塞、重复失败或计划与仓库现实不符(尤其函数行号因前序 task 偏移),立即停下说明,不要猜。
- 全部任务完成后,运行 Task 6 最终验证并输出修改摘要。

## 最终验证

- Run:
```bash
tools/ob_check.sh && tests/run_all.sh --full
```
- Expected: ob_check 全段绿 + run_all --full(protocol/unit/orchestration .sh+.exp)全绿,退出码 `0`。证明四个搬走的函数行为不变(消费者测试全绿)、两新 leaf-pure module 合规、dispatch/usage/交互无回归。

## 审阅 Checkpoint

实施计划已写好并保存到 `docs/plans/2026-07-17-ob-dev-workspace-extraction-implementation-plan.md`。请先确认这份计划;如果没问题,下一步可以按计划由普通编码 agent 或人工继续执行。
