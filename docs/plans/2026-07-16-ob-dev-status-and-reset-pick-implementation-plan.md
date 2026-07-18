# ob dev status 子命令 + reset TTY 列表 pick 实施计划

## 目标

- 新增 `ob dev status`：只读列出当前 devtool workspace 里已 modify 的 recipe，stdout 每行 `{"recipe","srctree"}` JSONL。
- 改造 `ob dev reset` 的 TTY 交互路径：reset 前先列出已 modify recipe，编号 pick 选要 reset 的 recipe；空列表则提示并 exit 3。
- 两者共享同一底层能力（跑 `devtool status` + 全量解析），不改动非 TTY / agent 路径的 porcelain 契约。

## 架构快照（含设计决策）

本次围绕一个共享能力展开：**列出 devtool workspace 里当前已 modify 的 recipe**。`ob dev status` 是它的独立出口，`ob dev reset` 的 TTY 提示是它的内嵌复用。底层落两个 leaf-pure 函数（`_devtool_parse_status_all` 纯解析 + `devtool_status_run` 组装器），commands.sh 只调 public 组装器，不直接碰 `_devtool_env_exec`。

设计决策（grill 已敲定，plan 自含以便未来回溯）：

1. **status stdout = 每行 `{"recipe","srctree"}` JSONL**，纯 `devtool status` 镜像。不含 `disposition`（那是 reset 的结果语义，status 在 reset 之前跑、无此概念）；不含 `srctreebase`（要扫 bbappend 解析，是 reset 的成本，不该搬进只读查询）。
2. **status 失败模型镜像 `modify`**：只分 stage（cd/setup/postcondition/command）、不分 phase；空列表 exit 0。
3. **status 空列表 = exit 0 + stdout 空 + stderr 总打** `warn "No modified recipes for <machine>."`（不判 TTY；单向告知，区别于 reset 的交互提示）。
4. **reset TTY 提示 = 编号 pick**：跑 `devtool_status_run` 拿列表 → 渲染序号 → 复用读入逻辑 pick。
5. **reset TTY 空列表 = warn + remedy + exit 3**（不进 pick、不让手输）；非 TTY 不变（argv recipe → reset_run 内部 noop JSON exit 0）。
6. **status = 菜单第 5 项不重排**；不接受参数；有 dry-run；TTY 选了直接执行（同 refresh）。

三个非显然点（避免未来"为什么这么写"）：

- **reset 空 exit 3 vs status 空 exit 0 不矛盾**：status 是只读查询（空 = 正常状态 → exit 0），reset 是动作（空 = 无可动作对象 = 前置缺失 → exit 3 + remedy）。语义层不同，exit 不同。
- **status 在 reset 流程里会被跑两次**（TTY 提示跑一次列列表，reset_run 内部 postcondition 再跑一次）。接受这个重复——reset 低频、status 在已 source 的 build env 里是秒级；不为省一次给 leaf-pure 组装器加 pre-fetched 入参（破坏 outvar 边界）。
- **新写 `read_list_choice` 而非泛化 `read_machine_choice`**：`ob_check.sh` 1d 段（`grep -q 'Select a machine for' lib/machine_picker.sh`）静态守 prompt 字面串。泛化 `read_machine_choice` 把 prompt 改成 `Select a ${noun} for` 会抹掉该字面串、撞守卫，且要同步 5 个调用点（pick_machine / cmd_stop_qemu / 3 处单测）。新写独立 `read_list_choice`（参数化 noun/verb）零调用点回归、守卫不破，读入循环仅 ~15 行，重复可接受。

## 全局约束

- **leaf-pure module 边界**：`lib/devtool_modify.sh`、`lib/machine_picker.sh` 函数绝不 `exit`，只 return rc；`commands.sh` 只调 public 组装器（`devtool_status_run`），不直接碰 `_devtool_env_exec`。`exit_contract.py` 已把这两个 basename 列为 leaf-pure（`LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 值为 `set()`）；新增函数不引入 exit → baseline 不变。
- **porcelain stdout 契约**（`CONTEXT.md` `ob dev porcelain stdout`）：`ob dev` stdout 只输出机器解析数据；`logo`/`info`/`warn`/诊断走 stderr；`cmd_dev` 不调写 stdout 的 `log`/`info`/`warn`。status 的 JSONL 与空列表 warn 都受此约束。
- **exit-code 契约**：exit 1 = 真失败；exit 2 = 用户取消；exit 3 = 前置缺失（按提示用 ob 补再重试）。status/reset 的退出码严格遵循。
- **outvar 名遮蔽陷阱**：组装器用固定 receiver 前缀（`_status_*`）+ helper 的 outvar 用 `_resolved_*`/`_located_*` 等，不与 helper 内 local 同名；每步 `rc=0` 重置（见 `devtool_reset_run` 现有范式）。
- **prompt 文案契约**（`ob_check.sh` 1d）：`lib/machine_picker.sh` 必须保留字面串 `Select a machine for` 与 `0 to cancel`。`read_list_choice` 是新增函数、含 `0 to cancel`，不删既有串 → 守卫通过。
- **JSON argv 不插值**：status 的 JSONL 发布与 reset 一致——`recipe`/`srctree` 经 `python3 -c ... sys.argv` 传入，不插值进源码串（值可能含特殊字符）。
- 无版本下限、无平台要求、无外部依赖新增。

## 输入工件

- grill 决策（本对话）：status schema / 失败模型 / reset pick 形态 / 空列表语义 / 菜单。
- 现状代码：`lib/devtool_modify.sh`（`_devtool_env_exec`/`_devtool_parse_srctree`/`devtool_modify_run`）、`lib/devtool_reset.sh`（`devtool_reset_run` 范式）、`lib/commands.sh`（`cmd_dev` 825-1096）、`lib/machine_picker.sh`。
- devtool status 原始输出格式：每行 `<recipe>: <srctree> (<recipefile>)`（见 `tests/unit/devtool_modify.sh:113` mock）。

## 文件结构与职责

- **Modify** `lib/devtool_modify.sh`：加 `_devtool_parse_status_all`（纯函数，全量解析 status 行）+ `devtool_status_run`（leaf-pure 组装器，env_exec → 解析 → outvar）。文件边界即 function semantic layer，仍属 leaf-pure module。
- **Modify** `lib/machine_picker.sh`：加 `read_list_choice`（参数化 noun/verb 的索引选择 helper）。`read_machine_choice`/`pick_machine` 不动。
- **Modify** `lib/commands.sh`：`cmd_dev` 内 case 注册 `status`；交互菜单加第 5 项 + TTY 引导 case 加 `5)`；reset 的 TTY 交互段（924-934）改为列表 pick + 空列表 exit 3；新增 `status)` 分支。非 TTY 的 reset/status 路径走下方 case，不受 TTY 段影响。
- **Modify** `ob`：`usage()` 的 dev 行子命令枚举加 `status`（189 行）+ 加 status example（242 行后）。
- **Modify** `CONTEXT.md`：`ob dev porcelain stdout` 词条枚举补 status；新增 `modified recipe` 词条。
- **Modify** `tests/unit/devtool_modify.sh`：加 `_devtool_parse_status_all` + `devtool_status_run` 单测。
- **Modify** `tests/unit/pick_machine.sh`：加 `read_list_choice` 单测。
- **Modify** `tests/orchestration/cmd_dev.sh`：加 `devtool_status_run` mock + status 非 TTY 场景 + reset 非 TTY 回归。
- **Modify** `tests/protocol/dev_interactive.exp`：菜单 1-5 回归 + reset 选 4 空列表 exit 3 场景。
- **Modify** `tests/protocol/usage_dispatch_sync.sh`：加 status 的 usage 断言 + DEV_ARGS 交接断言。

接口依赖链：Task 1 → Task 2；Task 2 → Task 4、Task 5；Task 3 → Task 5；Task 4/5 → Task 6；全部 → 最终验证。

## 任务清单

### Task 1: lib/devtool_modify.sh — `_devtool_parse_status_all` 纯函数

- 目标：全量解析 devtool status 输出文件，每行输出 `recipe<TAB>srctree`，剥 `(recipefile)` 后缀，跳过 header/空行。
- 涉及文件：Modify `lib/devtool_modify.sh`（在 `_devtool_parse_srctree` 后新增）；Test `tests/unit/devtool_modify.sh`。
- 验证范围：`bash tests/unit/devtool_modify.sh` 通过，新增断言覆盖多行 / 单行 / 空 / 带 recipefile 后缀 / header 行跳过。
- 接口契约
  - Consumes：无（纯函数，读 file）。
  - Produces：`_devtool_parse_status_all <status_file>` → stdout 每行 `recipe<TAB>srctree`（无匹配则空输出），return 0，绝不 exit。

- [ ] Step 1: 写失败单测
- 在 `tests/unit/devtool_modify.sh` 末尾（`assert_summary` 前）加：
```bash
# === _devtool_parse_status_all: 全量解析 status 行 ===
_psa_tmp="$(mktemp)"
printf 'foorecipe: %s/workspace/sources/foorecipe (recipes-foo/foorecipe.bb)\n' "$TMP" > "$_psa_tmp"
printf 'barrecipe: %s/workspace/sources/barrecipe\n' "$TMP" >> "$_psa_tmp"
printf 'Currently working recipes:\n' >> "$_psa_tmp"   # header 行(应跳过)
_psa_out="$(_devtool_parse_status_all "$_psa_tmp")"
assert_eq "parse_status_all 行数(2 recipe,header 跳过)" "$(printf '%s\n' "$_psa_out" | grep -c .)" "2"
assert_contains "parse_status_all foorecipe+srctree" "$_psa_out" $'foorecipe\t'"$TMP/workspace/sources/foorecipe"
assert_false "parse_status_all 剥掉 recipefile 后缀" grep -q 'recipes-foo/foorecipe.bb' <<<"$_psa_out"
assert_false "parse_status_all 跳过 header" grep -q 'Currently working recipes' <<<"$_psa_out"
rm -f "$_psa_tmp"
# 空文件 → 空输出
_psa_empty="$(mktemp)"; assert_eq "parse_status_all 空文件无输出" "$(_devtool_parse_status_all "$_psa_empty" | grep -c .)" "0"; rm -f "$_psa_empty"
# 负例: NOTE 噪声 / WARNING+绝对路径(诊断 token) / recipe 含空白 / srctree 相对路径 → 全跳过
_psa_neg="$(mktemp)"
printf 'NOTE: some bitbake noise\n' > "$_psa_neg"
printf 'WARNING: /abs/path\n' >> "$_psa_neg"         # 诊断 token + 绝对路径 → 仍跳过(靠 token 排除)
printf 'foo bar: /tmp/x\n' >> "$_psa_neg"           # recipe 含空白 → 跳过
printf 'good: relative/path\n' >> "$_psa_neg"        # srctree 非绝对 → 跳过
assert_eq "parse_status_all 负例全跳过(0 行)" "$(_devtool_parse_status_all "$_psa_neg" | grep -c .)" "0"
rm -f "$_psa_neg"
```
- Run: `bash tests/unit/devtool_modify.sh`
- Expected: 失败——`_devtool_parse_status_all: command not found`（函数尚未定义），assert 报错非零退出。

- [ ] Step 2: 运行并确认当前失败
- Run: `bash tests/unit/devtool_modify.sh 2>&1 | tail -5`
- Expected: 看到 `command not found` 或 assert 失败行，退出码非 0。

- [ ] Step 3: 写最小实现
- 在 `lib/devtool_modify.sh` 的 `_devtool_parse_srctree` 函数后新增：
```bash
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
- Change: 新增 `_devtool_parse_status_all` 纯函数。

- [ ] Step 4: 运行并确认通过
- Run: `bash tests/unit/devtool_modify.sh 2>&1 | tail -5`
- Expected: 全部 assert 通过，退出码 0，含 `parse_status_all` 相关 ok 行。

- [ ] Step 5: 可选 checkpoint commit
- Run: `git add lib/devtool_modify.sh tests/unit/devtool_modify.sh && git commit -m "feat(dev): add _devtool_parse_status_all pure parser"`

### Task 2: lib/devtool_modify.sh — `devtool_status_run` 组装器

- 目标：leaf-pure 组装器，跑 `devtool status` → `_devtool_parse_status_all` 全量解析 → outvar 回传 entries（换行分隔 `recipe<TAB>srctree` 串）+ stage + stderr_file。镜像 `devtool_modify_run` 结构。
- 涉及文件：Modify `lib/devtool_modify.sh`（在 `devtool_modify_run` 后新增）；Test `tests/unit/devtool_modify.sh`。
- 验证范围：`bash tests/unit/devtool_modify.sh` 通过，新增断言覆盖 mock `_devtool_env_exec` 成功回传列表 / stage 失败 / rc 失败。
- 接口契约
  - Consumes：`_devtool_env_exec`、`_devtool_parse_status_all`（Task 1 产出）。
  - Produces：`devtool_status_run <machine> <build_dir> <entries_outvar> <stage_outvar> <stderr_file_outvar>` → 设 entries（空列表则空串）/ stage（cd/setup/postcondition/command 之一）/ stderr_file（tempfile 路径，caller 负责 cat+rm）；return rc（0 成功，非零失败）。绝不 exit。

- [ ] Step 1: 写失败单测
- 在 `tests/unit/devtool_modify.sh` 加（用 mock `_devtool_env_exec` 写 status 输出到 stdout_file）：
```bash
# === devtool_status_run: env_exec → 全量解析 → outvar ===
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
```
- Run: `bash tests/unit/devtool_modify.sh`
- Expected: 失败——`devtool_status_run: command not found`。

- [ ] Step 2: 运行并确认当前失败
- Run: `bash tests/unit/devtool_modify.sh 2>&1 | tail -5`
- Expected: `command not found`，退出码非 0。

- [ ] Step 3: 写最小实现
- 在 `lib/devtool_modify.sh` 的 `devtool_modify_run` 后新增：
```bash
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
- Change: 新增 `devtool_status_run` leaf-pure 组装器。

- [ ] Step 4: 运行并确认通过
- Run: `bash tests/unit/devtool_modify.sh 2>&1 | tail -5`
- Expected: 全部 assert 通过，退出码 0，含 `status_run` 相关 ok 行。

- [ ] Step 5: 可选 checkpoint commit
- Run: `git add lib/devtool_modify.sh tests/unit/devtool_modify.sh && git commit -m "feat(dev): add devtool_status_run leaf-pure assembler"`

### Task 3: lib/machine_picker.sh — `read_list_choice` 新 helper

- 目标：参数化 noun/verb 的索引选择 helper（数字或名字，0 cancel），供 reset 的 recipe pick 复用。不动 `read_machine_choice`。
- 涉及文件：Modify `lib/machine_picker.sh`（文件末尾新增）；Test `tests/unit/pick_machine.sh`。
- 验证范围：`bash tests/unit/pick_machine.sh` 通过，新增断言覆盖数字选中 / 名字选中 / cancel(return 2) / 非法输入重试；`read_machine_choice` 既有断言不破。
- 接口契约
  - Consumes：无（独立读入循环，逻辑镜像 `read_machine_choice`）。
  - Produces：`read_list_choice <total> <noun> <verb> <items_nameref> <selected_outvar_nameref>` → 数字/名字选中时设 `selected_outvar` 并 return 0；`0` return 2（cancel）；read 失败 return 1。绝不 exit。prompt：`Select a ${noun} to ${verb} [1-${total}] (number or name, 0 to cancel)`。

- [ ] Step 1: 写失败单测
- 在 `tests/unit/pick_machine.sh` 末尾（`assert_summary` 前）加：
```bash
# === read_list_choice: 参数化 noun/verb 的索引选择 ===
RLC_SEL=""
_rlc_items=("ipmi-host" "bmcweb")
read_list_choice 2 "recipe" "reset" _rlc_items RLC_SEL <<< $'1\n' >/dev/null 2>&1
assert_eq "read_list_choice 数字选中 rc" "$?" "0"
assert_eq "read_list_choice 数字选中值" "$RLC_SEL" "ipmi-host"
RLC_SEL=""; read_list_choice 2 "recipe" "reset" _rlc_items RLC_SEL <<< $'bmcweb\n' >/dev/null 2>&1
assert_eq "read_list_choice 名字选中 rc" "$?" "0"
assert_eq "read_list_choice 名字选中值" "$RLC_SEL" "bmcweb"
RLC_SEL=""; read_list_choice 2 "recipe" "reset" _rlc_items RLC_SEL <<< $'0\n' >/dev/null 2>&1
assert_eq "read_list_choice cancel rc" "$?" "2"
# 非法输入(越界数字 + 不存在名字)后重试, 最终合法选中
RLC_SEL=""; read_list_choice 2 "recipe" "reset" _rlc_items RLC_SEL <<< $'9\nbadname\n1\n' >/dev/null 2>&1
assert_eq "read_list_choice 非法重试后选中 rc" "$?" "0"
assert_eq "read_list_choice 非法重试后选中值" "$RLC_SEL" "ipmi-host"
```
- Run: `bash tests/unit/pick_machine.sh`
- Expected: 失败——`read_list_choice: command not found`。

- [ ] Step 2: 运行并确认当前失败
- Run: `bash tests/unit/pick_machine.sh 2>&1 | tail -5`
- Expected: `command not found`，退出码非 0。

- [ ] Step 3: 写最小实现
- 在 `lib/machine_picker.sh` 末尾新增：
```bash
# read_list_choice <total> <noun> <verb> <items_nameref> <selected_outvar_nameref>
# 参数化 noun/verb 的索引选择(数字或名字, 0 cancel)。镜像 read_machine_choice 读入循环,
# 但 prompt 用 noun/verb(供 recipe 等 non-machine 选择)。caller 已渲染序号列表 + 集合非空 + 交互终端。
# 选中 → 设 selected_outvar + return 0; 0 → return 2(cancel); read 失败 → return 1。绝不 exit。
read_list_choice() {
    local total="$1" noun="$2" verb="$3"
    local -n _rlc_items="$4"
    local -n _rlc_sel="$5"
    local selected i
    while true; do
        if ! read -r -p "$(echo -e "${PROMPT_PREFIX} Select a ${noun} to ${verb} [1-${total}] (number or name, 0 to cancel): ")" selected; then
            error "Unable to read ${noun} selection from stdin."
            return 1
        fi
        [[ "$selected" == "0" ]] && return 2
        if [[ "$selected" =~ ^[0-9]+$ ]] && [[ "$selected" -ge 1 && "$selected" -le "$total" ]]; then
            _rlc_sel="${_rlc_items[$((selected - 1))]}"
            return 0
        fi
        for i in "${_rlc_items[@]}"; do
            if [[ "$i" == "$selected" ]]; then
                _rlc_sel="$i"
                return 0
            fi
        done
        warn "Invalid selection '$selected'. Enter a number (1-${total}) or a ${noun} name."
    done
}
```
- Change: 新增 `read_list_choice` helper；`read_machine_choice`/`pick_machine` 不动。

- [ ] Step 4: 运行并确认通过
- Run: `bash tests/unit/pick_machine.sh 2>&1 | tail -5`
- Expected: 全部 assert 通过（含 `read_list_choice` 新断言 + `read_machine_choice` 既有断言），退出码 0。

- [ ] Step 5: 可选 checkpoint commit
- Run: `git add lib/machine_picker.sh tests/unit/pick_machine.sh && git commit -m "feat(picker): add read_list_choice parameterized index picker"`

### Task 4: lib/commands.sh — `ob dev status` 子命令

- 目标：`cmd_dev` 注册 `status` 子命令 + `status)` 分支（devtool_status_run → JSONL 发布 / 空列表 warn exit 0 / 失败 exit 1 / dry-run）+ 交互菜单第 5 项 + TTY 引导选 status 直接执行。
- 涉及文件：Modify `lib/commands.sh`；Test `tests/orchestration/cmd_dev.sh`。
- 验证范围：`bash tests/orchestration/cmd_dev.sh` 通过，新增 status 场景（列表 JSONL exit 0 / 空 warn exit 0 / 失败 exit 1 / dry-run / **编码失败 stdout 空 exit 1**）；既有 list/modify/reset 场景不破。
- 接口契约
  - Consumes：`devtool_status_run`（Task 2 产出）。
  - Produces：`ob dev status` 子命令（非 TTY：`ob dev --machine <m> status` → stdout JSONL 或空）。

- [ ] Step 1: 写失败单测
- 在 `tests/orchestration/cmd_dev.sh` 的 mock 段加 `devtool_status_run` mock，并在 mock 段后加 status 场景：
```bash
# status mock: 5 参数(machine/build_dir + entries/stage/stderr_file outvar); MOCK_ST_ENTRIES 控制
devtool_status_run() {
    local m="$1" b="$2"
    printf -v "$3" '%s' "${MOCK_ST_ENTRIES:-}"
    printf -v "$4" '%s' "${MOCK_ST_STAGE:-command}"
    printf -v "$5" '%s' "$TMP/st_sterr"
    : > "$TMP/st_sterr"
    return "${MOCK_ST_RC:-0}"
}
# === status 列表 → exit 0 + JSONL(语义校验, 不锁空格格式) ===
MOCK_ST_ENTRIES=$'ipmi-host\t/build/m/sources/ipmi-host\nbmcweb\t/build/m/sources/bmcweb'; run_dev --machine testm status
assert_eq "status 列表 exit 0" "$RUN_RC" "0"
assert_eq "status stdout 恰好 2 行 JSONL" "$(grep -c . <<<"$RUN_OUT")" "2"
# 每行合法 JSON + 字段值正确 + key 集合(python json.loads, 容忍 json.dumps 默认空格; 不把空格变成契约)
# 捕获退出码(脚本成功不打印 stdout, $() 会得空串), 不是 stdout
_st_json_rc=0
python3 -c 'import json,sys
ok=True
for ln in sys.stdin:
    ln=ln.strip()
    if not ln: continue
    d=json.loads(ln)
    if set(d.keys()) != {"recipe","srctree"}: ok=False
    if d.get("recipe") not in ("ipmi-host","bmcweb"): ok=False
    if not d.get("srctree","").startswith("/"): ok=False
sys.exit(0 if ok else 1)' <<<"$RUN_OUT" || _st_json_rc=$?
assert_eq "status stdout 每行合法 JSON + recipe/srctree 字段" "$_st_json_rc" "0"
assert_false "status stdout 纯(无 [ERROR])" grep -q "\[ERROR\]" <<<"$RUN_OUT"
# === status 空列表 → exit 0 + stderr warn + stdout 空 ===
MOCK_ST_ENTRIES=""; run_dev --machine testm status
assert_eq "status 空 exit 0" "$RUN_RC" "0"
assert_eq "status 空 stdout 空" "$RUN_OUT" ""
assert_contains "status 空 stderr warn" "$RUN_ERR" "No modified recipes for testm"
# === status 失败 → exit 1(精确, 区分 exit 3 前置缺失) ===
MOCK_ST_RC=1; run_dev --machine testm status
assert_eq "status 失败 exit 1" "$RUN_RC" "1"
# === status dry-run → exit 0 + stderr 提示 ===
DRY_RUN=1; run_dev --machine testm status; DRY_RUN=0
assert_eq "status dry-run exit 0" "$RUN_RC" "0"
assert_contains "status dry-run stderr 提示" "$RUN_ERR" "[DRY-RUN] ob dev status"
# === status JSONL 编码失败(python3 -c 失败) → stdout 空 + exit 1(钉牢 partial stdout 契约) ===
# 显式重置 mock 成功态: 前一用例 MOCK_ST_RC=1 残留会让 devtool_status_run 直接 return 1,
# 在 status) 分支的 rc 检查处就 exit 1("devtool status failed"), 走不到 JSONL 生成循环, fake python3 没被调用
MOCK_ST_RC=0
MOCK_ST_STAGE="command"
MOCK_ST_ENTRIES=$'badrecipe\t/build/m/s/badrecipe'
python3() { return 1; }   # fake python3: json.dumps 编码失败(前两轮 partial stdout 反复踩坑的回归点)
run_dev --machine testm status
unset -f python3
assert_eq "status 编码失败 exit 1" "$RUN_RC" "1"
assert_eq "status 编码失败 stdout 空(不 partial 发布)" "$RUN_OUT" ""
assert_contains "status 编码失败 stderr 诊断" "$RUN_ERR" "result JSONL"
```
- Run: `bash tests/orchestration/cmd_dev.sh`
- Expected: 失败——`status)` 分支未实现，`ob dev status` 落到 `*)` reserved → exit 1，status 列表断言失败。

- [ ] Step 2: 运行并确认当前失败
- Run: `bash tests/orchestration/cmd_dev.sh 2>&1 | tail -5`
- Expected: status 相关 assert 失败（exit 1 而非 0，或 "reserved"），退出码非 0。

- [ ] Step 3: 写最小实现
- 改 `lib/commands.sh` 四处：
  1. case 注册（838 行 `list|modify|refresh|build|deploy|finish|reset)` → 加 `|status`）。
  2. 交互菜单（897-902 行）加第 5 项：
```bash
        echo "    5) status   List modified recipes (read-only, outputs JSONL)"
```
     并把提示 `Select subcommand [1-4]` 改 `[1-5]`、TTY 引导 case（908-915 行）加 `5) dev_subcmd="status" ;;`、按参数补全 case（917-936 行）`status` 不需补参数（归入 `refresh) ;;` 同类，直接 `;;`）。
  3. 新增 `status)` 分支（在 `reset)` 分支后、`*)` 前）：
```bash
        status)
            if [[ "${DRY_RUN:-0}" == "1" ]]; then
                error "[DRY-RUN] ob dev status: would list modified recipes via devtool status." >&2
                exit 0
            fi
            local _st_entries="" _st_stage="" _st_stderr_file="" _st_rc=0
            devtool_status_run "$dev_machine" "$dev_build_dir" _st_entries _st_stage _st_stderr_file || _st_rc=$?
            cat "$_st_stderr_file" >&2 2>/dev/null || true
            rm -f "$_st_stderr_file" 2>/dev/null
            case "$_st_stage" in
                cd|setup|postcondition)
                    error "ob dev status: build env not ready (stage=$_st_stage)." >&2
                    exit 1
                    ;;
            esac
            if [[ "$_st_rc" -ne 0 ]]; then
                error "ob dev status: devtool status failed (rc=$_st_rc)." >&2
                exit 1
            fi
            if [[ -z "$_st_entries" ]]; then
                warn "No modified recipes for $dev_machine." >&2
                exit 0
            fi
            # JSONL 原子发布: 逐行 json.dumps(argv 不插值) → tempfile → 行数+key+json.loads 校验 → cat → 删
            # (真原子: 记生成 rc + 输出行数==entries 行数, 杜绝 || true 吞错导致的 partial stdout 假成功)
            local _st_jsonl="" _st_r="" _st_s="" _st_json_rc=0 _st_expected=0 _st_actual=0
            _st_jsonl="$(mktemp 2>/dev/null)"
            : > "$_st_jsonl"
            while IFS=$'\t' read -r _st_r _st_s; do
                [[ -z "$_st_r" ]] && continue
                _st_expected=$((_st_expected + 1))
                python3 -c 'import json,sys
print(json.dumps({"recipe":sys.argv[1],"srctree":sys.argv[2]}))' "$_st_r" "$_st_s" >> "$_st_jsonl" 2>/dev/null || _st_json_rc=$?
            done <<< "$_st_entries"
            _st_actual="$(grep -c . "$_st_jsonl" 2>/dev/null || true)"
            # 行数全等 + 生成无错(任一行 json.dumps 失败 → 行数不等或 rc!=0 → exit 1, 不 partial 发布)
            if [[ "$_st_json_rc" -ne 0 || "$_st_actual" -ne "$_st_expected" ]]; then
                rm -f "$_st_jsonl" 2>/dev/null
                error "ob dev status: failed to encode result JSONL." >&2
                exit 1
            fi
            # 形状校验: 每行合法 JSON + key 集合恰为 {recipe,srctree}
            python3 -c 'import json,sys
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    d=json.loads(line)
    assert set(d.keys()) == {"recipe","srctree"}' "$_st_jsonl" 2>/dev/null || _st_json_rc=$?
            if [[ "$_st_json_rc" -ne 0 ]]; then
                rm -f "$_st_jsonl" 2>/dev/null
                error "ob dev status: result JSONL malformed." >&2
                exit 1
            fi
            cat "$_st_jsonl"
            rm -f "$_st_jsonl" 2>/dev/null
            exit 0
            ;;
```
- Change: 注册 status 子命令；菜单第 5 项 + [1-5]；`status)` 分支（JSONL argv 发布 / 空 warn exit 0 / 失败 exit 1 / dry-run）。

- [ ] Step 4: 运行并确认通过
- Run: `bash tests/orchestration/cmd_dev.sh 2>&1 | tail -8`
- Expected: status 五场景（列表/空/失败/dry-run/编码失败）+ 既有 list/modify/reset 场景全通过，退出码 0。

- [ ] Step 5: 可选 checkpoint commit
- Run: `git add lib/commands.sh tests/orchestration/cmd_dev.sh && git commit -m "feat(dev): add 'ob dev status' subcommand"`

### Task 5: lib/commands.sh — reset TTY 列表 pick + 空列表 exit 3

- 目标：reset 的 TTY 交互段（924-934，`if [[ -z "$dev_subcmd" && -t 0 ]]` 内的 `modify|reset)` case）改为：跑 `devtool_status_run` 拿列表 → 空 warn+remedy+exit 3 → 非空渲染序号 + `read_list_choice` pick 选 recipe。非 TTY reset 路径（下方 `reset)` case）不动。
- 涉及文件：Modify `lib/commands.sh`；Test `tests/protocol/dev_interactive.exp`、`tests/orchestration/cmd_dev.sh`。
- 验证范围：`expect tests/protocol/dev_interactive.exp` 通过（reset 选 4 → 空列表 → exit 3）；`bash tests/orchestration/cmd_dev.sh` 既有 reset 非 TTY 场景不破。
- 接口契约
  - Consumes：`devtool_status_run`（Task 2）、`read_list_choice`（Task 3）。
  - Produces：reset TTY 列表 pick 行为；reset TTY 空列表 exit 3。

- [ ] Step 1: 写失败检查 + 更新 .exp（reset 场景改 wrapper mock **并移出 has_machine gate**）
- 当前 reset TTY 段是裸 `read -p "recipe name:"`（924-934）。`dev_interactive.exp` 现有 4 个场景全在 `if {!$has_machine} {incr SKIP 4} else {...}` 的 **else 内**（`dev_interactive.exp:43-122`），reset 场景（103-121）跑真实 `./ob dev` → reset 选 4 真跑 `devtool status`（经 `_devtool_env_exec`，要求 local.conf/devtool/bitbake-layers，见 `devtool_modify.sh:20-23`），环境不稳。改三步：
  1. **删除**原 reset 段（103-121）。
  2. **SKIP 4 → 3**（else 内只剩 cancel/modify-empty/invalid-subcmd 三个真实场景，仍受 `has_machine` gate）。
  3. **新增 wrapper mock 场景到 `if/else` 块之后、无条件跑**——它 mock 了 `machine_state_*`，不依赖真实 init-done machine；若留在 else 内，无 init-done 环境会被整体 skip → 假覆盖。目标结构：else 内三个真实场景受 gate；wrapper 场景在 else 之后（外层）无条件执行。下方代码块即该 wrapper 场景（独立于 else）：
```tcl
    # === reset TTY 空列表 + 菜单 [1-5](wrapper mock, 不依赖真实 devtool) ===
    spawn bash -c {OB_NO_MAIN=1 source ./ob 2>/dev/null
machine_state_initialized_machines() { echo testm; }
machine_state_is_initialized() { return 0; }
detect_harness_root() { return 0; }
devtool_status_run() { local _f; _f="$(mktemp)"; printf -v "$3" '%s' ''; printf -v "$4" '%s' 'command'; printf -v "$5" '%s' "$_f"; : >"$_f"; return 0; }
main dev
}
    expect -re "Select a machine for Develop"; send "1\r"
    # 先匹配菜单项 5) status(它出现在 prompt 之前), 再匹配 prompt——
    # 反序会先消费掉 prompt、把 5) status 从 buffer 吃掉, 后续 expect "5) status" 必超时
    expect "5) status"
    set _ok 1
    expect {
        -re {Select subcommand.*\[1-5\].*0 to cancel}   { }
        -re "no subcommand"                              { incr FAIL; puts "FAIL dev reset-mock: 引导菜单未出现"; set _ok 0 }
        timeout                                          { incr FAIL; puts "FAIL dev reset-mock: 超时"; set _ok 0 }
    }
    if {$_ok} {
        send "4\r"
        expect "No modified recipes"
        expect eof; catch wait r
        chk "dev reset 空列表(mock) → 3" [lindex $r 3] 3
    } else {
        catch {close}; catch {wait}
    }
```
  - mock 清单：`machine_state_initialized_machines`（返 testm，让 pick_machine 有候选）/ `machine_state_is_initialized`（true，过 init-done 前置）/ `detect_harness_root`（避免副作用，参考 `usage_dispatch_sync.sh:48`）/ `devtool_status_run`（entries 空 + stage=command + rc 0，模拟"无 modified recipe"）。`OB_NO_MAIN=1 source ./ob` 后调 `main dev`，spawn 提供 PTY 驱动交互。
  - 断言四件事：菜单 `Select subcommand [1-5]`（锁编号变化）、`5) status` 文本（锁第 5 项文案）、reset 选 4 → `No modified recipes` → exit 3（锁空列表路径，不依赖真实 devtool）、**无 init-done machine 时该场景仍跑**（移出 else，不被 has_machine skip）。pick 数字选中（非空列表）仍留盲区（见下）。
  - 失败信号（改动前，commands.sh 未改）：wrapper 场景无条件运行，但菜单 prompt 仍是 `[1-4]`、无 `5) status` 文本、reset 段仍是旧 "recipe name" 流 → expect `5) status` / `[1-5]` / `No modified recipes` 全不匹配 → 超时 FAIL。
- Run: `expect tests/protocol/dev_interactive.exp 2>&1 | tail -5`
- Expected: 失败——reset 段仍是旧 "recipe name" 提示，改后的 `.exp` expect "No modified recipes" 不匹配（或旧场景 send "" 后行为变了），FAIL>0。

- [ ] Step 2: 运行并确认当前失败
- Run: `expect tests/protocol/dev_interactive.exp 2>&1 | tail -5`
- Expected: FAIL>0（wrapper 场景三处 expect 全不匹配：菜单仍是 `[1-4]` 无 `[1-5]`、无 `5) status` 文本、reset 段仍是旧 recipe name 流），退出码 1。

- [ ] Step 3: 写最小实现
- 改 `lib/commands.sh` 的 TTY 交互段。把 `modify|reset)` 的 recipe 补全 case（924-934）拆分：modify 保持原样（裸 read），reset 改为列表 pick：
```bash
            modify)
                if ! read -r -p "$(echo -e "${PROMPT_PREFIX} recipe name: ")" dev_recipe; then
                    error "Unable to read recipe name." >&2
                    exit 1
                fi
                if [[ -z "$dev_recipe" ]]; then
                    error "ob dev modify: no recipe specified." >&2
                    error "Run 'ob dev --machine $dev_machine list [pattern]' to discover recipes first." >&2
                    exit 3
                fi
                ;;
            reset)
                # TTY reset: 跑 devtool status 列已 modify recipe → 空 exit 3 / 非空编号 pick
                local _rst_entries="" _rst_stage="" _rst_stderr_file="" _rst_rc=0
                devtool_status_run "$dev_machine" "$dev_build_dir" _rst_entries _rst_stage _rst_stderr_file || _rst_rc=$?
                cat "$_rst_stderr_file" >&2 2>/dev/null || true
                rm -f "$_rst_stderr_file" 2>/dev/null
                case "$_rst_stage" in
                    cd|setup|postcondition)
                        error "ob dev reset: build env not ready (stage=$_rst_stage)." >&2
                        exit 1
                        ;;
                esac
                if [[ "$_rst_rc" -ne 0 ]]; then
                    error "ob dev reset: devtool status failed (rc=$_rst_rc)." >&2
                    exit 1
                fi
                local -a _rst_recipes=()
                local _rst_r=""
                while IFS=$'\t' read -r _rst_r _; do
                    [[ -n "$_rst_r" ]] && _rst_recipes+=("$_rst_r")
                done <<< "$_rst_entries"
                if [[ ${#_rst_recipes[@]} -eq 0 ]]; then
                    warn "No modified recipes for $dev_machine." >&2
                    error "Run 'ob dev --machine $dev_machine modify <recipe>' first." >&2
                    exit 3
                fi
                local _rst_i _rst_width=${#_rst_recipes[@]}
                for (( _rst_i=0; _rst_i<_rst_width; _rst_i++ )); do
                    printf '  %d) %s\n' "$((_rst_i + 1))" "${_rst_recipes[$_rst_i]}" >&2
                done
                local _rst_pick_rc=0
                read_list_choice "$_rst_width" "recipe" "reset" _rst_recipes dev_recipe >&2 || _rst_pick_rc=$?
                if [[ "$_rst_pick_rc" -eq 2 ]]; then exit 2; fi   # cancel
                if [[ "$_rst_pick_rc" -ne 0 ]]; then exit 1; fi   # read 失败
                ;;
```
- Change：reset TTY 段改为 status 列表 + pick + 空列表 exit 3；modify TTY 段不动；非 TTY `reset)` case 不动。

- [ ] Step 4: 运行并确认通过
- Run: `expect tests/protocol/dev_interactive.exp 2>&1 | tail -5`
- Expected: PASS 含 "dev reset 空列表(mock) → 3"，FAIL=0，退出码 0（菜单 `[1-5]` + `5) status` 文本 + reset 空列表 exit 3 三件全锁住，且不依赖真实 devtool）。
- Run: `bash tests/orchestration/cmd_dev.sh 2>&1 | tail -5`
- Expected: reset 非 TTY 既有场景（argv recipe → reset_run mock）不破，退出码 0。

- [ ] Step 5: 可选 checkpoint commit
- Run: `git add lib/commands.sh tests/protocol/dev_interactive.exp && git commit -m "feat(dev): reset TTY lists modified recipes for pick"`

**覆盖盲区（透明化）**：reset TTY 的**空列表 → exit 3** 已被 wrapper mock 场景稳定覆盖（不依赖真实 devtool/recipe）。仍留盲区的是 **pick 数字选中（非空列表 → 输数字选中 → 走 devtool_reset_run）**：mock 非空 entries 后选中会进入真实 `devtool_reset_run`，要再 mock 它才能闭环，mock 链太长不值。该路径的核心读入逻辑（数字/名字/cancel 解析）由 Task 3 的 `read_list_choice` 单测覆盖；"渲染序号 + 选中"编排留人工验证。盲区已记录，不假装覆盖。

### Task 6: ob usage + usage_dispatch_sync — 注册 status 到 usage

- 目标：`ob` 的 `usage()` dev 行子命令枚举加 `status` + 加 example；`usage_dispatch_sync.sh` 加 status 的 usage 断言 + DEV_ARGS 交接断言。
- 涉及文件：Modify `ob`、`tests/protocol/usage_dispatch_sync.sh`。
- 验证范围：`bash tests/protocol/usage_dispatch_sync.sh` 通过，含 status 断言。
- 接口契约
  - Consumes：`ob dev status` 子命令存在（Task 4）。
  - Produces：`usage()` dev 行含 `status`；usage_dispatch_sync status 断言。

- [ ] Step 1: 写失败断言
- 在 `tests/protocol/usage_dispatch_sync.sh` 的 reset 登记段（73-86 行）后加 status 段：
```bash
# === ob dev status 登记: usage dev 行含 status(锚定 dev 行枚举, 避开顶层 status 命令) + DEV_ARGS 交接 + 真实 dispatch ===
_usage_out2="$(usage 2>/dev/null)"
assert_contains "usage dev 行枚举含 status" "$_usage_out2" "refresh|reset|status"

parse_args dev --machine m status
assert_eq "DEV_ARGS status [2]=status" "${DEV_ARGS[2]}" "status"
assert_eq "DEV_ARGS status 恰好 3 元素" "${#DEV_ARGS[@]}" "3"

cmd_dev() { printf 'GOT:%s\n' "$@"; return 0; }
_dispatch_out2="$(main dev --machine m status 2>/dev/null)"
assert_contains "main dev status 调 cmd_dev(status)" "$_dispatch_out2" "GOT:status"
assert_false "main dev status 不把 dev 字面传给 cmd_dev" grep -q "GOT:dev" <<<"$_dispatch_out2"
```
- Run: `bash tests/protocol/usage_dispatch_sync.sh`
- Expected: 失败——usage dev 行未含 status（189 行枚举无 status），`assert_contains "usage dev 行含 status"` 报错。

- [ ] Step 2: 运行并确认当前失败
- Run: `bash tests/protocol/usage_dispatch_sync.sh 2>&1 | tail -5`
- Expected: status 断言失败，退出码非 0。

- [ ] Step 3: 写最小实现
- 改 `ob`：
  1. usage dev 行（189 行）`<list|modify|refresh|reset>` → `<list|modify|refresh|reset|status>`。
  2. example 段（reset example 行 242 后）在 heredoc 内新增一行**纯文本**（不带 `echo`——usage 是 `cat <<EOF` heredoc 机制）：`  ob dev --machine romulus status             # List modified recipes (outputs JSONL)`
- Change：usage dev 行枚举 + example 加 status。

- [ ] Step 4: 运行并确认通过
- Run: `bash tests/protocol/usage_dispatch_sync.sh 2>&1 | tail -5`
- Expected: 含 `usage dev 行含 status` ok + DEV_ARGS/dispatch 断言全通过，退出码 0。

- [ ] Step 5: 可选 checkpoint commit
- Run: `git add ob tests/protocol/usage_dispatch_sync.sh && git commit -m "feat(dev): register 'ob dev status' in usage + dispatch sync test"`

### Task 7: CONTEXT.md — porcelain 枚举 + modified recipe 词条

- 目标：`ob dev porcelain stdout` 词条的 stdout 枚举补 status；新增 `modified recipe` 词条（status/reset 共享概念的权威定义）。
- 涉及文件：Modify `CONTEXT.md`。
- 验证范围：`grep` 确认两处更新落盘，且不破坏既有词条。
- 接口契约
  - Consumes：status 设计（Task 4）。
  - Produces：glossary 含 `modified recipe` 词条 + porcelain 枚举含 status。

- [ ] Step 1: 写失败检查
- Run: `grep -c 'status.*每行.*recipe.*srctree\|modified recipe' CONTEXT.md`
- Expected: `0`（两处均未落盘）。

- [ ] Step 2: 运行并确认当前失败
- Run: `grep -c 'modified recipe' CONTEXT.md`
- Expected: `0`。

- [ ] Step 3: 写最小实现
- 改 `CONTEXT.md`：
  1. `ob dev porcelain stdout` 词条（134 行附近）stdout 枚举补 status——在 `` `reset` 单行 JSON `` 后加：`` / `status` 每行 `{"recipe","srctree"}` JSONL（modified recipe 清单） ``。
  2. 在 `srctree`（125-126 行）与 `recipe metadata cache`（130 行）之间新增词条：
```markdown
**modified recipe**:
devtool workspace 里当前处于 modify 状态的 recipe，由 `devtool status` 实时列举（不缓存、不拼接）。是 `ob dev status` 的查询对象、`ob dev reset` 的候选范围；与 `recipe metadata cache`（`ob dev list` 的全量可 modify 索引，缓存）正交。
_Avoid_: tracked recipe, 已 modify 的 recipe
```
- Change：porcelain 枚举补 status；新增 `modified recipe` 词条。

- [ ] Step 4: 运行并确认通过
- Run: `grep -c 'modified recipe' CONTEXT.md && grep -q 'status` 每行' CONTEXT.md && echo OK`
- Expected: 第一行 `≥1`，第二行打印 `OK`（两处均落盘）。

- [ ] Step 5: 可选 checkpoint commit
- Run: `git add CONTEXT.md && git commit -m "docs(context): add 'modified recipe' term + status to porcelain stdout"`

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行（Task 1→7），不要无声跳步、合并步或改变任务目标。Task 1/2/3 是独立 helper，可并行起手；Task 4/5 依赖前序；Task 6/7 收尾。
- 每完成一个任务，运行该任务 Step 4 的验证命令，确认通过再进下一个。
- 遇到阻塞、重复失败或计划与仓库现实不符（尤其 `.exp` 真跑 devtool status 的环境差异），立即停下说明，不要猜。
- 当前分支 `feature/ob-dev-devtool-modify`（非 main/master），可直接提交；checkpoint commit 用 Task 给出的 message。
- 全部任务完成后，运行最终验证并输出修改摘要。

## 最终验证

- Run: `bash tools/ob_check.sh`
- Expected: 全段通过——extract_funcs（ob GAPS=0 + lib 三段纯函数，含新增 `_devtool_parse_status_all`/`devtool_status_run`/`read_list_choice`）、machine_state gate、shellcheck baseline 一致、exit-contract（两 basename 仍 leaf-pure）、1d prompt 文案契约（`Select a machine for` / `0 to cancel` 仍在）、run_all 默认三层 .sh 全绿。
- Run: `bash tests/run_all.sh --full`
- Expected: protocol/unit/orchestration 的 .sh + .exp 全绿（含 `dev_interactive.exp` 菜单 1-5 + reset 空列表 exit 3、`usage_dispatch_sync.sh` status 断言、`cmd_dev.sh` status 场景）。
- 退出码均 0。reset 空列表场景已 wrapper mock 化（不依赖真实 devtool，**且移出 has_machine gate、无论有无 init-done 都无条件跑**），稳定；pick 数字选中（非空列表）按"覆盖盲区"留人工确认。

## 审阅 Checkpoint

实施计划已写好并保存到 `docs/plans/2026-07-16-ob-dev-status-and-reset-pick-implementation-plan.md`。请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行。
