# devtool_pick 抽取实施计划

## 目标

把 `cmd_dev`（`lib/commands.sh`）TTY 段 `reset`/`finish`/`build` 三分支逐字重复的「选 modified recipe」代码块，抽取为新文件 `lib/devtool_pick.sh` 的 leaf-pure helper `devtool_pick_modified_recipe`，消除复利式重复（加 `build` 子命令时刚抄过一遍），并把只能 expect 测的选号逻辑变成可 unit 测。

## 架构快照

- 新建 `lib/devtool_pick.sh`，封装 `modified recipe selection`（CONTEXT.md 术语已落）。helper 是 leaf-pure，内部复用 `dev_relay_result`（`lib/devtool_dispatch.sh`）收口 status 阶段失败，消费 `devtool_status_run`（`lib/devtool_status.sh`）取列表 + `read_list_choice`（`lib/machine_picker.sh`）选号。
- `cmd_dev` 的 TTY `reset|finish|build` 分支（当前 `lib/commands.sh` 的 TTY 引导段）各缩成一次 helper 调用 + 一个 `case` 信号→exit 映射。
- 与 `machine selection`（`pick_machine`）同构：独立 module、leaf-pure、CONTEXT.md 有术语。协议不同（见全局约束），今天不动 `pick_machine`。

## 全局约束

- **leaf-pure**：`devtool_pick_modified_recipe` 绝不 `exit`。由 `tools/exit_contract.py` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 登记 `'devtool_pick.sh': set()`（例外集空）锁定；函数若 exit，Y 规则报「add to leaf-pure exceptions, or remove the exit」。
- **恒返回码**：返回 0（仅 `mktemp` 等硬失败非零）；结果分类全走 `status_outvar` 字符串，**不用多态返回码**（避 `qemu_instance_is_alive` 0/1/2 在 `set -euo pipefail` 下的 footgun，commit `1ffe591`）。
- **status_outvar 5 态**：`ok:<recipe>` / `empty` / `cancel` / `read-fail` / `status-failed`。exit-code 契约映射（0/1/2/3）留在 `cmd_dev`。
- **副作用次序不变量**（`dev_interactive.exp` 是回归锁）：`devtool_status_run` → `dev_relay_result`(cat+rm stderr) → 解析 entries → 空→`empty` / 非空→渲染序号(`>&2`) → `read_list_choice` → `ok:<recipe>`/`cancel`/`read-fail`。
- **outvar 名约束**：caller 传入的 `status_outvar` 名不得与 helper 内 `local`（`_entries`/`_stage`/`_stderr`/`_rc`/`_recipes`/`_r`/`_i`/`_w`/`_sel`/`_plrc`）同名；helper 内一律 `printf -v "$status_outvar"`，receiver 名固定。caller 用业务名 `_pick_st`。
- **文案变化（行为变更）**：复用 `dev_relay_result` 后，`reset`/`finish`/`build` 的 status 失败 stderr 文案由原 `"ob dev <subcmd>: devtool status failed (rc=<n>)."` 变为 `dev_relay_result` 的 `"ob dev <subcmd>: devtool failed (rc=<n>, stage=command)."`（多带 stage，措辞略变）。`dev_interactive.exp` 测交互流不锁精确文案，预期不受影响，Task 4 验证。
- **ob dev porcelain stdout**：helper 全部诊断走 `>&2`，stdout 不输出（TTY 段本就 `>&2`）。
- **命名**：snake_case（仓库约定）。module 文件 `lib/devtool_pick.sh` 遵循 lib 三段结构（header / 函数定义 / 无顶层语句），过 `extract_funcs` 检查。

## 输入工件

- 设计：本会话 grill-with-docs 锁定的 5 决策（Q1 范围只抽选号块 / Q2 leaf-pure / Q3 恒返回码+5 态字符串+复用 dev_relay_result / Q4 新文件 devtool_pick.sh / Q5 全 5 态 unit）。
- 术语：`CONTEXT.md` 已落 `modified recipe selection`（含与 `machine selection` 的协议差异与不统一理由）。
- 无独立设计文档（grill 产出即设计）。

## 文件结构与职责

- **Create**: `lib/devtool_pick.sh` — `devtool_pick_modified_recipe`，leaf-pure，modified recipe selection module。
- **Create**: `tests/unit/devtool_pick.sh` — 全 5 态 unit 测，镜像 `tests/unit/devtool_build.sh`（mock devtool 二进制）+ `tests/unit/interact.sh`（here-string / `</dev/null` 喂 stdin）。`run_all.sh` 自动 glob 纳入，无需登记。
- **Modify**: `lib/commands.sh`（`cmd_dev` 的 TTY `reset|finish|build` 分支，当前行段 `lib/commands.sh:1084-1141`）— 替换内联选号块为 helper 调用 + `case` 信号映射。
- **Modify**: `tools/exit_contract.py`（`LEAF_EXIT_EXCEPTIONS_BY_BASENAME` dict，`tools/exit_contract.py:53-69`）— 加 `'devtool_pick.sh': set(),`。
- **Modify（ob_check.sh 自动重生成）**: `tests/.shellcheck-baseline` — 新增 lib 文件触发 flat 合成变化，Task 4 跑 `ob_check.sh` 后 git diff 确认良性。
- **Modify**: `rules/03_WORKSPACE.md`（`lib/` 路由行）+ `tools/coverage_matrix.md`（补 dev 选号行）— deferred doc，Task 5。

接口依赖：Task 1 Produces `devtool_pick_modified_recipe` → Task 2/3 Consumes；Task 3 Produces `cmd_dev` 接线 → Task 4 Consumes；Task 5 Consumes 全部完成后的文件/测试事实。

## 任务清单

### Task 1: 新建 lib/devtool_pick.sh + 登记 exit_contract LEAF

- 目标：创建 leaf-pure helper，并登记进 exit_contract 的 LEAF 集合，使 leaf-pure 门禁覆盖新文件。
- 涉及文件：Create `lib/devtool_pick.sh`；Modify `tools/exit_contract.py`。
- 接口契约
  - Consumes: `devtool_status_run`（`lib/devtool_status.sh`，签名 `<machine> <build_dir> <entries_outvar> <stage_outvar> <stderr_file_outvar>`）、`dev_relay_result`（`lib/devtool_dispatch.sh`，签名 `<subcmd> <stderr_file> <stage> <phase> <rc>`）、`read_list_choice`（`lib/machine_picker.sh`，签名 `<total> <noun> <verb> <items_nameref> <selected_outvar_nameref>`，多态 rc 0=选中/2=cancel/1=read-fail）。
  - Produces: `devtool_pick_modified_recipe <machine> <build_dir> <verb> <status_outvar>`，`status_outvar` ∈ {`ok:<recipe>`, `empty`, `cancel`, `read-fail`, `status-failed`}，恒返回 0。
- 验证范围：文件存在 + LEAF 已登记 + `exit_contract.py` exit 0 + `extract_funcs.py` 三段合规。

- [ ] Step 1: 写当前缺失检查
- Run: `test ! -f lib/devtool_pick.sh && ! grep -q "'devtool_pick.sh'" tools/exit_contract.py`
- Expected: 退出码 0（文件不存在且未登记，当前缺失状态成立）。
- [ ] Step 2: 运行并确认当前缺失
- Run: 同上
- Expected: 退出码 0。
- [ ] Step 3: 写最小实现
- Change:
  1. `tools/exit_contract.py` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` dict（`tools/exit_contract.py:53-69`）内，按字母序在 `'devtool_finish.sh': set(),` 之后加 `'devtool_pick.sh': set(),`。
  2. 新建 `lib/devtool_pick.sh`，内容：

```bash
#!/usr/bin/env bash
# lib/devtool_pick.sh — modified recipe selection 交互选择 module(leaf-pure)。
#   devtool_pick_modified_recipe: ob dev 的 reset/finish/build TTY 子命令共享的"先选一个 modified
#   recipe 再动手"前置。取 modified recipe 列表(devtool_status_run) → status 阶段失败复用 dev_relay_result
#   收口为 status-failed → 空 empty → 非空渲染序号 + read_list_choice 选号 → ok:<recipe>/cancel/read-fail。
#   消费 devtool_status_run / dev_relay_result / read_list_choice。术语见 CONTEXT.md modified recipe selection。
# Exit: leaf-pure module(函数绝不 exit; 允许文件/进程/交互副作用); 调用者(cmd_dev)负责 exit-code/remedy/诊断。

# devtool_pick_modified_recipe <machine> <build_dir> <verb> <status_outvar>
# 前提(调用者保证): machine initialized + 交互终端 + status_outvar 名不与本函数 local 同名。
# 结果全经 status_outvar 回传(恒返回 0, 仅 mktemp 等硬失败非零):
#   ok:<recipe>    选中(recipe 嵌入) -> cmd_dev 取出继续
#   empty          status 成功但无 modified recipe -> cmd_dev exit 3 + remedy
#   cancel         read_list_choice rc=2 -> exit 2
#   read-fail      read_list_choice rc=1 -> exit 1
#   status-failed  status 阶段失败(stage 异常 或 rc!=0); 文案由 dev_relay_result 打印 -> exit 1
devtool_pick_modified_recipe() {
    local machine="$1" build_dir="$2" verb="$3" status_outvar="$4"
    local _entries="" _stage="" _stderr="" _rc=0
    devtool_status_run "$machine" "$build_dir" _entries _stage _stderr || _rc=$?
    # status 阶段失败(stage cd/setup/postcondition 或 rc!=0): dev_relay_result cat+rm stderr + 打印文案 + return 1
    dev_relay_result "$verb" "$_stderr" "$_stage" "" "${_rc:-0}" \
        || { printf -v "$status_outvar" '%s' "status-failed"; return 0; }
    # 解析 entries("recipe<TAB>srctree" 换行串) → recipe 列表
    local -a _recipes=()
    local _r
    while IFS=$'\t' read -r _r _; do
        [[ -n "$_r" ]] && _recipes+=("$_r")
    done <<< "$_entries"
    if [[ ${#_recipes[@]} -eq 0 ]]; then
        printf -v "$status_outvar" '%s' "empty"
        return 0
    fi
    # 渲染序号(>&2, 守 ob dev porcelain stdout 契约)
    local _i _w=${#_recipes[@]}
    for (( _i=0; _i<_w; _i++ )); do
        printf '  %d) %s\n' "$((_i + 1))" "${_recipes[$_i]}" >&2
    done
    # 选号(read_list_choice 多态 rc: 0=选中/2=cancel/1=read-fail)
    local _sel="" _plrc=0
    read_list_choice "$_w" "recipe" "$verb" _recipes _sel >&2 || _plrc=$?
    case "$_plrc" in
        0) printf -v "$status_outvar" '%s' "ok:$_sel" ;;
        2) printf -v "$status_outvar" '%s' "cancel" ;;
        *) printf -v "$status_outvar" '%s' "read-fail" ;;
    esac
    return 0
}
```

- [ ] Step 4: 运行并确认通过
- Run: `test -f lib/devtool_pick.sh && grep -q "'devtool_pick.sh': set()," tools/exit_contract.py && python3 tools/exit_contract.py && python3 tools/extract_funcs.py lib/devtool_pick.sh >/dev/null`
- Expected: 退出码 0（文件存在 + LEAF 登记 + exit_contract Y 规则覆盖且无真 exit + 三段结构合规）。shellcheck 留 Task 4（baseline 机制）。
- [ ] Step 5: 可选 checkpoint commit
- Run: `git add lib/devtool_pick.sh tools/exit_contract.py && git commit -m "feat(dev): add lib/devtool_pick.sh leaf-pure modified recipe selection + register exit_contract LEAF"`
- Expected: commit 成功。

### Task 2: 新增 tests/unit/devtool_pick.sh 全 5 态

- 目标：用 unit 层覆盖 helper 的 5 态，镜像 `devtool_build.sh` 的 mock devtool 二进制 + `interact.sh` 的 here-string/`</dev/null` 喂 stdin。
- 涉及文件：Create `tests/unit/devtool_pick.sh`。
- 接口契约
  - Consumes: Task 1 的 `devtool_pick_modified_recipe`。
  - Produces: `tests/unit/devtool_pick.sh`（`run_all.sh` 自动 glob 纳入）。
- 验证范围：`bash tests/unit/devtool_pick.sh` 退出码 0（assert_summary 全过）。

- [ ] Step 1: 写当前缺失检查
- Run: `test ! -f tests/unit/devtool_pick.sh`
- Expected: 退出码 0（测试不存在）。
- [ ] Step 2: 运行并确认当前缺失
- Run: 同上
- Expected: 退出码 0。
- [ ] Step 3: 写最小实现
- Change: 新建 `tests/unit/devtool_pick.sh`。基础结构沿用 `tests/unit/devtool_build.sh`（source `ob_loader.sh` + `assert.sh`；mktemp TMP + trap；mock `$TMP/bin/devtool` 按 `$1=status` 输出 `MOCK_DEVTOOL_STATE` + `exit MOCK_STATUS_RC`；`PATH=$TMP/bin:$PATH`）+ `tests/unit/interact.sh` 的 stdin 喂入。**两点与 devtool_build.sh 不同，必须显式处理（否则 case 必挂或假绿）**：
  - **(A) MOCK_DEVTOOL_STATE 格式 = 冒号-空格 + srctree 绝对路径**（**不是 `<TAB>`**）。`MOCK_DEVTOOL_STATE` 是 mock devtool 二进制的**原始 stdout**，经 `_devtool_parse_status_all`（`lib/devtool_workspace.sh:44-58`）解析——awk 按 `": "` 切分、srctree 必须 `^\//`，**输出**才是 `recipe<TAB>srctree`（entries 格式）。照 `devtool_build.sh:48` 写法：`printf '%s: %s\n' "phosphor-ipmi-host" "$TMP/workspace/sources/phosphor-ipmi-host" > "$MOCK_DEVTOOL_STATE"`。写 `<TAB>` 会让 ④⑤⑥ 解析为空而必挂、②③ 假绿。
  - **(B) setup-swap 是 devtool_build.sh 没有的新机制**（不是"镜像"）。devtool_build.sh 的 mock setup 恒成功；case ① 要 setup 失败，需中途替换 `$OPENBMC_DIR/setup`，且 ②-⑥ 跑前恢复。默认（成功）setup：`printf '#!/usr/bin/env bash\nexport SETUP_DONE=1\n' > "$OPENBMC_DIR/setup"`。
  - 6 case 覆盖 5 态（status-failed 拆 stage/rc 两子态），每 case 前 `: > "$MOCK_DEVTOOL_STATE"; unset MOCK_STATUS_RC` 重置：
    - ① `status-failed`(stage)：swap setup 为 `printf '#!/usr/bin/env bash\nexit 1\n' > "$OPENBMC_DIR/setup"` → `_devtool_env_exec` 在 `source setup` 失败写 `stage=setup` + rc≠0 → `dev_relay_result` 经 `error()` 打印 `"ob dev <verb>: build env not ready (stage=setup)."`（带 `[ERROR]`+颜色码前缀）+ return 1。断言 `_pick_st=status-failed` **且** stderr 主体文案：`out=$(devtool_pick_modified_recipe "$MACHINE" "$BUILD_DIR" reset _pick_st 2>&1 >/dev/null); assert_contains "① stage 文案" "$out" "build env not ready"`（用 `assert_contains` 而非裸 `grep -q`，与 `unit/devtool_dispatch.sh:29` 同款——glob 子串跳 `error()` 的 `[ERROR]`+颜色码前缀锁主体）。
    - ② `status-failed`(rc)：恢复成功 setup + `MOCK_STATUS_RC=1` + 空 state（devtool status exit 1，`stage=command`）→ `dev_relay_result` 打印 `"ob dev reset: devtool failed (rc=1, stage=command)."` + return 1。断言 `_pick_st=status-failed` **且** `assert_contains "② rc 文案" "$out" "devtool failed (rc=1, stage=command)"`（`$out` 捕获同 ①）。
    - ③ `empty`：`MOCK_STATUS_RC=0` + 空 state → `_pick_st=empty`。
    - ④ `ok:<recipe>`：state 写 `phosphor-ipmi-host: $TMP/workspace/sources/phosphor-ipmi-host`（冒号空格、绝对路径）+ 调用 `<<< $'1\n'` → `_pick_st=ok:phosphor-ipmi-host`。
    - ⑤ `cancel`：state 同 ④ + `<<< $'0\n'` → `_pick_st=cancel`。
    - ⑥ `read-fail`：state 同 ④ + `</dev/null`（EOF）→ `_pick_st=read-fail`。
  - 🔴 **格式契约自检**（防 `<TAB>` 回潮）：④ 前跑一次 `devtool_status_run "$MACHINE" "$BUILD_DIR" _e _s _se` 直读 `_e`，`assert_ne "MOCK_DEVTOOL_STATE 冒号格式解析非空" "$_e" ""`——锁定 state 格式正确。
  - 🔴 回归锁（对齐 `devtool_build.sh` 🔴2）：② status 失败必须 `_pick_st=status-failed`，不得误报 `empty`（误报让 cmd_dev exit 3 而非 1）。
  - leaf-pure 验证：失败态（①②）helper 恒返回 0（能跑到 assert 即证明 return 非 exit）。
  - 可选 nameref 负向 case：传 `_sel` 作 status_outvar（与 helper 内 local `_sel` 同名），断言不触发 bash circular / 行为正确——把 outvar 名约束固化成回归。
  - 收尾 `assert_summary`。
- [ ] Step 4: 运行并确认通过
- Run: `bash tests/unit/devtool_pick.sh && test -z "$(bash tests/unit/devtool_pick.sh 2>&1 | tail -1 | grep -i 'fail')"`
- Expected: 退出码 0（assert_summary 全过 + 无 FAIL 行）。
- [ ] Step 5: 可选 checkpoint commit
- Run: `git add tests/unit/devtool_pick.sh && git commit -m "test(dev): devtool_pick unit 5-state (status-failed x2/empty/ok/cancel/read-fail)"`
- Expected: commit 成功。

### Task 3: cmd_dev TTY reset/finish/build 分支接线 helper

- 目标：把 `cmd_dev` TTY 引导段的 `reset|finish`（当前 `lib/commands.sh:1084-1118`）和 `build`（当前 `lib/commands.sh:1119-1141`）两段内联选号块，替换为 `devtool_pick_modified_recipe` 调用 + `case` 信号→exit 映射。
- 涉及文件：Modify `lib/commands.sh`（`cmd_dev` TTY 段 `reset|finish|build` 分支）。
- 接口契约
  - Consumes: Task 1 的 `devtool_pick_modified_recipe`（`status_outvar` 5 态）。
  - Produces: `cmd_dev` 三分支各缩成 helper 调用 + 映射；`commands.sh` 内 `devtool_status_run` 调用从 3 处降到 1 处（仅 `status` dispatch 保留）。
- 验证范围：`commands.sh` 内 `devtool_status_run` 计数 = 1 + `orchestration/cmd_dev.sh` 回归过 + 三段结构合规。

- [ ] Step 1: 写当前状态检查
- Run: `test "$(grep -c 'devtool_status_run' lib/commands.sh)" -ge 3`
- Expected: 退出码 0（当前 TTY reset/finish + build + status dispatch 共 ≥3 处内联/直接调用，待降）。
- [ ] Step 2: 运行并确认当前状态
- Run: 同上
- Expected: 退出码 0。
- [ ] Step 3: 写最小实现
- Change: **定位用符号锚点（case 模式），行号仅辅助、动手前 `grep -n` 重锚**。把 `cmd_dev` TTY 引导段（`if [[ -z "$dev_subcmd" && -t 0 ]]; then` 块内）的 `reset|finish)` 分支与 `build)` 分支合并替换为单一 `reset|finish|build)` 分支。当前快照约在 `lib/commands.sh:1084-1141`（`reset|finish)` 头约 :1084、`build)` 头约 :1119、`;;` 收尾约 :1141，`refresh|status)` 紧随其后约 :1142）。**动手前先 `grep -n 'reset|finish)\|build)' lib/commands.sh` 按符号重对当前行段**，不把行号当唯一契约：

```bash
            reset|finish|build)
                # TTY 选 modified recipe → helper(leaf-pure, 5 态 status_outvar) + exit-code 映射留 cmd_dev
                local _pick_st=""
                devtool_pick_modified_recipe "$dev_machine" "$dev_build_dir" "$dev_subcmd" _pick_st
                case "$_pick_st" in
                    ok:*)
                        dev_recipe="${_pick_st#ok:}" ;;
                    empty)
                        warn "No modified recipes for $dev_machine." >&2
                        error "Run 'ob dev --machine $dev_machine modify <recipe>' first." >&2
                        exit 3 ;;
                    cancel)
                        exit 2 ;;
                    read-fail|status-failed)
                        # read-fail: read_list_choice 读失败; status-failed: 文案已由 dev_relay_result 打印
                        exit 1 ;;
                esac
                # ok 选号成功: dev_recipe 已填, fall through 出 TTY 引导段(fi);
                # 下游 dispatch case(reset/finish/build 各自跑 devtool_*_run + DRY_RUN/recipe 再校验)继续执行,
                # dev_recipe 非空 → 下游 [[ -z "$dev_recipe" ]] exit 3 check 不误触发。
                ;;
```

  说明：`empty` 的 remedy 文案与原 reset/finish/build 分支逐字一致（`Run 'ob dev --machine <m> modify <recipe>' first.`）。`status dispatch`（`lib/commands.sh:1274-1283`）与 `list`/`modify`/`refresh` 分支不动。
- [ ] Step 4: 运行并确认通过
- Run: `test "$(grep -c 'devtool_status_run' lib/commands.sh)" -eq 1 && bash tests/orchestration/cmd_dev.sh && python3 tools/extract_funcs.py lib/commands.sh >/dev/null`
- Expected: 退出码 0（`devtool_status_run` 降到 1 处 + orchestration 回归全过 + commands.sh 三段合规）。
- [ ] Step 5: 可选 checkpoint commit
- Run: `git add lib/commands.sh && git commit -m "refactor(dev): cmd_dev TTY reset/finish/build call devtool_pick_modified_recipe"`
- Expected: commit 成功。

### Task 4: 端到端回归 + ob_check.sh + baseline 确认

- 目标：跑完整自检与端到端回归，确认接线后副作用次序不变量与文案变化不破现有契约。
- 涉及文件：无新改动；验证 `tests/.shellcheck-baseline` 重生成后为良性差异。
- 接口契约
  - Consumes: Task 1-3 全部产出。
  - Produces: 全绿验证记录。
- 验证范围：`ob_check.sh` ALL GREEN + `run_all.sh --full` ALL GREEN（含 `dev_interactive.exp`）+ baseline diff 良性。

- [ ] Step 1: 写当前未回归检查
- Run: `test -n "$(git status --porcelain)"`
- Expected: 退出码 0（有未提交改动，尚未跑全量回归）。
- [ ] Step 2: 运行并确认当前未回归
- Run: 同上
- Expected: 退出码 0。
- [ ] Step 3: 跑回归
- Change: 依次执行：
  1. `tools/ob_check.sh`（extract_funcs → machine_state gate → shellcheck baseline → exit-contract → run_all 三层 .sh）。若 shellcheck baseline 自动重生成，`git diff tests/.shellcheck-baseline` 确认仅新增 `devtool_pick.sh` 相关行（良性）。
  2. `tests/run_all.sh --full`（加 `.exp`）。注意：`dev_interactive.exp` 的 reset/finish 场景用 wrapper override `devtool_status_run` 返回空 entries + rc=0，**只锁 `empty` 路径**（`warn "No modified recipes"` + exit 3）+ TTY 选号次序，**不经 `dev_relay_result` 的 rc 分支、不锁 status-failed 文案**。故 `--full` 验证的是"接线不破 empty 路径 + 选号次序"；**status-failed 新文案的唯一锁定是 Task 2 的 stderr grep 断言**（①②），不是 exp。
- [ ] Step 4: 运行并确认通过
- Run: `tools/ob_check.sh && tests/run_all.sh --full`
- Expected: 两命令均退出码 0（`ob_check` 末行 `run_all ALL GREEN` 或等价；`run_all.sh --full` 末行 `ALL GREEN`）。若 `dev_interactive.exp` 因文案变化失败，停下说明（回 Task 3 评估是否保留原文案）。
- [ ] Step 5: 可选 checkpoint commit
- Run: `git add tests/.shellcheck-baseline && git commit -m "chore(check): regenerate shellcheck baseline for devtool_pick.sh"`
- Expected: commit 成功（仅 baseline 良性差异）。

### Task 5: deferred doc 同步（WORKSPACE 路由 + coverage_matrix）

- 目标：把新文件登记进 workspace 路由表和覆盖矩阵，恢复 dev 区域的可观测性。
- 涉及文件：Modify `rules/03_WORKSPACE.md`（`lib/` 路由行，`rules/03_WORKSPACE.md:11`）；Modify `tools/coverage_matrix.md`。
- 接口契约
  - Consumes: Task 1-4（文件真存在 + 测试真写 + 全绿）。
  - Produces: 两处 doc 含 `devtool_pick` / `modified recipe selection`。
- 验证范围：两文件 grep 命中。

- [ ] Step 1: 写当前缺失检查
- Run: `! grep -q "devtool_pick.sh" rules/03_WORKSPACE.md && ! grep -qi "devtool_pick\|modified recipe selection" tools/coverage_matrix.md`
- Expected: 退出码 0（两文件均未收录）。
- [ ] Step 2: 运行并确认当前缺失
- Run: 同上
- Expected: 退出码 0。
- [ ] Step 3: 写最小实现
- Change:
  1. `rules/03_WORKSPACE.md` 的 `lib/` 路由行（`rules/03_WORKSPACE.md:11`），在 `devtool_modify.sh` 之后按族序插入 `devtool_pick.sh`（modified recipe selection 交互选择 module（leaf-pure））。
  2. `tools/coverage_matrix.md` 新增 `## dev` 章节。**注意：现有 `## build` 指 `ob build`/`cmd_build`（镜像编译），与 `ob dev build` 无关——新增 `## dev` 不冲突，勿误删或把 dev 子命令混入 `## build`**。dev 整段（`cmd_dev` 所有子命令）确未在矩阵中。列 modified recipe selection 功能点：涉及函数 `devtool_pick_modified_recipe`；覆盖 test `unit/devtool_pick.sh` + 端到端 `protocol/dev_interactive.exp` + `orchestration/cmd_dev.sh`；备注 `TTY（选号靠 expect）/ exit 函数映射在 cmd_dev`。
- [ ] Step 4: 运行并确认通过
- Run: `grep -q "devtool_pick.sh" rules/03_WORKSPACE.md && grep -qi "modified recipe selection" tools/coverage_matrix.md`
- Expected: 退出码 0（两文件均收录）。
- [ ] Step 5: 可选 checkpoint commit
- Run: `git add rules/03_WORKSPACE.md tools/coverage_matrix.md && git commit -m "docs(workspace): register devtool_pick.sh + coverage_matrix dev section"`
- Expected: commit 成功。

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 计划所引行号均为当前快照、会随改动漂移；每个 Task 动手前用 `grep -n` 按符号锚点（函数名 / case 模式 / dict key）重对一遍行段，不把行号当唯一契约。
- 按任务顺序执行，不无声跳步、合并步或改任务目标。
- 每完成一个任务，运行该任务定义的验证（退出码归位，grep 门禁化）。
- 遇阻塞、重复失败或计划与仓库现实不符，立即停下说明，不猜。
- 当前在 `main` 分支；开始实现前若用户未明确同意，先确认是否开 feature 分支。
- 全部任务完成后，运行最终验证并输出修改摘要。

## 最终验证

- Run: `tools/ob_check.sh && tests/run_all.sh --full && git diff --stat`
- Expected: `ob_check.sh` 与 `run_all.sh --full` 均退出码 0（`ALL GREEN`）；`git diff --stat` 显示新增 `lib/devtool_pick.sh` + `tests/unit/devtool_pick.sh`，修改 `lib/commands.sh` / `tools/exit_contract.py` / `tests/.shellcheck-baseline` / `rules/03_WORKSPACE.md` / `tools/coverage_matrix.md` / `CONTEXT.md`。
- 环境：bash + 仓库根目录；`expect` 需已安装（`run_all.sh --full` 的 `.exp` 层，缺失则该层 skip，非失败）。

## 审阅 Checkpoint

- 计划正文结束。请先确认这份计划；如果没问题，下一步可按计划由普通编码 agent 或人工继续执行。
- 审阅通过前，不进入实现。
