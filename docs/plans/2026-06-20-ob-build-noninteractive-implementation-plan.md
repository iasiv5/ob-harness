# ob build 非交互路径 + dry-run 实施计划

## 目标

给 `ob build` 补齐非交互快路径 `ob build <machine>`，对齐 `init` / `start-qemu` 的形态，并让 build 与 stop-qemu 正确支持已被全局接受的 `-d/--dry-run`。具体交付：

1. `parse_args` 接受 `build <machine>` 位置参数（现状落进选项循环 → `exit 1 "Unknown option"`）。
2. `cmd_build` 显式 machine 快路径：校验 `init-done` marker，命中直奔 bitbake（跳过列表/选择/确认），未命中走"诊断行 + remedy line"两段式 → `exit 3`。
3. `cmd_build` 无参数非 TTY 的 remedy line 改写为 `Specify a machine: ob build <machine>`（把"无 TTY 伪前置"纠正为可补全前置）。
4. `cmd_build` 支持 `-d`：machine 解析 + marker 校验后、`source setup`/`bitbake` 副作用前加 dry-run 闸 → `exit 0`。
5. **姊妹修复** `cmd_stop_qemu` 的同款 footgun：`-d` 当前被忽略，加 dry-run 闸（放在 confirm/force 守卫之前，使非 TTY 无 `--force` 也能零副作用预览）。
6. 文档与测试随动：usage、协议测试、`CONTEXT.md` build 描述、`bestpractice_06` 已知缺口关闭。
7. **顺带收敛 L3352**：`cmd_start_qemu` no-built-machines 的两命令 remedy 拆为两条单命令子分支（无 init-done → `ob init`；init-done 未 built → `ob build`），同时修正评审指出的语义不准（init-done-未-built 时不再误导去 init）。

非目标（本次不做）：build 的 `--target <recipe>`（写死 `obmc-phosphor-image`）、build 的 `--force`、quiet/agent 输出模式、JSON 输出。（L3352 单命令收敛已纳入本计划任务 9，不再是 follow-up。）

设计依据：本仓 `docs/adr/0003-ob-first-front-door.md`（含"消费侧契约：诊断行 + remedy line"）、`CONTEXT.md` 的 `remedy line` / `confirmation banner` / `init-done marker` / `exit-code 契约` 词条。

## 环境前提

- 执行环境：Linux + bash（WSL Ubuntu）。所有验证命令为 bash 原生，在仓库根 `/home/iasi/ob-harness` 执行。
- 改 `ob` 后**必须**跑 `tools/ob_check.sh`（extract_funcs GAPS → reorder → shellcheck baseline → run_all）。
- 改了退出码 / 交互路径，最终验证用 `tests/run_all.sh --full`（含 `.exp` 矩阵），不只默认 `.sh` 子集。
- **已知仓库 gotcha**：编辑**已存在**的 `.md`（`CONTEXT.md`、`bestpractice_06`）时，VS Code 编辑工具可能静默不落盘；改后用 `grep` 核对磁盘字节，必要时用 `python3` 读改写。新建文件不受此影响。

## 架构快照

只描述本次方案与现有结构的衔接，不复述仓库背景。

`cmd_build`（`ob` §6，约 L3142–L3334）当前是纯交互单路径：prereq → 发现 init-done machines → 零机器守卫 → 打印 → **非 TTY 守卫 `exit 3`** → `select_from_list` → `confirm_action` → `source setup` + `bitbake`。

本次把它改成"显式 machine / 无参数交互"双路径，结构对齐 `cmd_start_qemu`（L3335，显式 machine 跳过发现块）：

```raw
cmd_build:
  require_path .git / lock                      # 不变，两路径共用
  if [[ -n "$MACHINE" ]]; then                  # 【新】显式快路径
      [[ -f $CONFIGS_DIR/$MACHINE.init-done ]] || { 诊断行(B) + remedy line; exit 3; }
      BUILD_DIR=...; info "Selected: $MACHINE (from argument)"
  else                                          # 交互路径（现有逻辑，整体下移进 else）
      发现 + 零机器守卫 + 打印
      [[ ! -t 0 ]] && { remedy line "Specify a machine: ob build <machine>"; exit 3; }   # 【改】文案
      select_from_list → confirm_action
  fi
  [[ "$DRY_RUN" -eq 1 ]] && { info "[DRY-RUN] Would ..."; exit 0; }   # 【新】dry-run 闸，两路径共用
  cd $OPENBMC_DIR; source setup; bitbake ...    # 不变
```

`cmd_stop_qemu`（`ob` §6，L3638–L3786）在 per-target 循环里 `validate_pid` 之后、stale 清理/confirm 之前插一道零副作用 dry-run 闸（covers running/stale/recycled 三态，`continue` 不 kill 不 rm）。

不新增函数（只编辑 `parse_args` / `cmd_build` / `cmd_stop_qemu` / `usage`），故 `ob` 的 §1–§7 函数分层与 `extract_funcs`/`reorder` 登记不受影响。

## 文件结构与职责

**修改：**
- `ob` — `parse_args`（build 位置参数）、`cmd_build`（双路径 + dry-run 闸 + remedy 文案）、`cmd_stop_qemu`（dry-run 闸）、`usage`（build 行 + examples）。
- `tests/protocol/exit_codes.sh` — 加 1 例：`build <machine>` 位置参数在空 workspace 被接受（→ 3，证明不再 `exit 1` unknown option）。
- `CONTEXT.md` — 头部 `ob build` 描述补"非交互 `ob build <machine>` 直构"。
- `rules/skills/bestpractice_06-ob_first.md` — 关闭/改写"已知缺口"节。
- `tests/.shellcheck-baseline` — 若行号平移，由 `ob_check.sh` 自动重生成（git diff 确认）。

**新建：**
- `tests/protocol/build_noninteractive.sh` — 种 fixture（`.git` 目录 / lock / 可选 marker），断言 build 三新行为的退出码 + remedy line 文本。
- `tests/protocol/stop_qemu_dryrun.sh` — 种 stale pid fixture，断言 `stop-qemu --all -d` → exit 0 且 pid 文件仍在（零副作用）。

两个新 `.sh` 落 `tests/protocol/` 即被 `run_all.sh` 的 `for f in tests/$layer/*.sh` 自动收录。

## 任务清单

按顺序执行。代码任务用"先写失败测试 → 确认失败 → 最小实现 → 确认通过"。

### 任务 1 — `parse_args` 接受 `build <machine>` 位置参数

1. 在 `tests/protocol/exit_codes.sh` 的断言区（`assert_ob_rc 3 "build empty workspace" build` 一行之后）加：
   assert_ob_rc 3 "build <machine> 位置参数被接受(empty ws)" build romulus
2. **Run**：`bash tests/protocol/exit_codes.sh`
   **预期（失败）**：该例 `FAIL ... (rc=1 want 3)`——现状 `romulus` 落进选项循环触发 `exit 1`。
3. 改 `ob` 的 `parse_args`：把 `build)` 分支（现为 `# No arguments accepted for build`）改成与 `status)` 同形：
   build)
       if [[ $# -gt 0 ]] && [[ "$1" != -* ]]; then
           MACHINE="$1"
           shift
       fi
       ;;
4. **Run**：`bash tests/protocol/exit_codes.sh`
   **预期（通过）**：新例 `ok ...(rc=3)`，其余例不变；末行 `PASS=N FAIL=0`。
5. **补充根因断言**：另加一条隔离断言——子进程内 `OB_NO_MAIN=1 source ob; parse_args build romulus`，断言 `[[ "$MACHINE" == romulus ]]`，直接证明 `parse_args` 把位置参数赋给 `MACHINE`（任务 1 的 rc 用例是端到端 characterization，这条守根因）。

### 任务 2 — 新建 `build_noninteractive.sh`（失败测试）

1. 新建 `tests/protocol/build_noninteractive.sh`，仿 `tests/protocol/exit_codes.sh` 的隔离写法（`OB_NO_MAIN=1 source "$OB"`、子进程内 override `detect_harness_root` 指向 `$tmp/workspace`、`</dev/null` 制造非 TTY），**每个用例用独立 `mktemp -d`** 并捕获 rc + stderr；每个用例先种公共 fixture（`mkdir -p $tmp/workspace/openbmc/.git $tmp/workspace/configs`、`cp tests/fixtures/source_lock.sample $tmp/workspace/configs/openbmc-source.lock`），再按用例种 marker：
   - 用例 (a) 未 init-done：不建 marker，`parse_args build romulus; cmd_build`；断言 `rc==3`、stderr `assert_contains` 字面 `Run 'ob init romulus' first.`（含句号），并用 `assert_false` 反向断言该 stderr 不含 `, then:`（守住“单命令 remedy line”契约）。
   - 用例 (b) dry-run 命中：`touch $tmp/workspace/configs/romulus.init-done`，`parse_args build romulus -d; cmd_build`；断言 `rc==0`。
   - 用例 (c) 无参数非 TTY：建 marker（同 b），`parse_args build; cmd_build`；断言 `rc==3` 且 stderr `assert_contains` 字面 `Specify a machine: ob build <machine>`。
   - 末尾 `assert_summary`。
2. **Run**：`bash tests/protocol/build_noninteractive.sh`
   **预期（失败）**：(a) 文本不含 `Run 'ob init romulus' first`（现状打"No machines ready"）；(b) `rc` 非 0（现状 `-d` 被忽略，非 TTY 走 `exit 3`）；(c) 文本是旧的 `requires interactive mode`。三例均 FAIL。

### 任务 3 — `cmd_build` 显式 machine 快路径（让用例 a 通过）

1. 改 `ob` 的 `cmd_build`：在两处 `require_path`（`.git` / lock）之后、`# === Discover init-done machines ===` 之前，插入显式快路径，并把"发现 → 零机器守卫 → 打印 → 非 TTY 守卫 → select → confirm"整块包进 `else`：
   if [[ -n "$MACHINE" ]]; then
       if [[ ! -f "$CONFIGS_DIR/$MACHINE.init-done" ]]; then
           error "Machine '$MACHINE' is not initialized (no completed init-done marker — a previous init may have been interrupted)."
           error "Run 'ob init $MACHINE' first."
           exit 3
       fi
       BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"
       info "Selected: $MACHINE (from argument)"
   else
       # …现有发现/打印/非TTY守卫/select/confirm 整块下移进此 else…
   fi
   注意 `else` 块末尾原本设置 `MACHINE`/`BUILD_DIR` 的逻辑保持；`# === Re-enter bitbake environment ===` 起的 bitbake 尾保持在 `fi` 之后、两路径共用。
2. **Run**：`bash tests/protocol/build_noninteractive.sh`
   **预期**：用例 (a) `ok`（rc=3 且含 `Run 'ob init romulus' first`）；(b)(c) 仍 FAIL（待任务 4、任务 5）。

### 任务 4 — `cmd_build` 无参数非 TTY remedy 文案改写（让用例 c 通过）

1. 改 `ob` 的 `cmd_build` `else`（交互）块内的非 TTY 守卫，把
   error "No interactive terminal. ob build requires interactive mode."
   改为两行：
   error "No machine specified and no interactive terminal. Run 'ob status' to list initialized machines."
   error "Specify a machine: ob build <machine>"
   `exit 3` 不变。
2. **Run**：`bash tests/protocol/build_noninteractive.sh`
   **预期**：用例 (c) `ok`（rc=3 且含 `Specify a machine: ob build <machine>`）；(b) 仍 FAIL。

### 任务 5 — `cmd_build` dry-run 闸（让用例 b 通过）

1. 改 `ob` 的 `cmd_build`：在任务 3 的 `if/else` 之后、`# === Re-enter bitbake environment ===` / `cd "$OPENBMC_DIR"` 之前，插入：
   if [[ "$DRY_RUN" -eq 1 ]]; then
       info "[DRY-RUN] Would source setup $MACHINE $BUILD_DIR"
       info "[DRY-RUN] Would run: bitbake obmc-phosphor-image (machine=$MACHINE)"
       exit 0
   fi
2. **Run**：`bash tests/protocol/build_noninteractive.sh`
   **预期（全通过）**：(a)(b)(c) 三例 `ok`；末行 `PASS=3 FAIL=0`。

> 说明：dry-run 闸刻意放在 if/else 之后（与 `cmd_start_qemu` 的 dry-run 同位——也在 confirm 之后），故交互式 `ob build -d`（真 TTY）会先 select+confirm 再预览；主用例（显式 machine）走快路径跳过 confirm、立即预览，不受影响。此为与 start-qemu 对齐的有意选择，勿“顺手”提前短路。

### 任务 6 — `cmd_stop_qemu` dry-run 闸（先写失败测试）

1. 新建 `tests/protocol/stop_qemu_dryrun.sh`，仿隔离写法：
   - fixture：`mkdir -p $tmp/workspace/qemu-bin/.pids`；写 stale pid 文件 `$tmp/workspace/qemu-bin/.pids/romulus.pid`，内容为 `read_pid_file`（`ob` 约 L2131–L2141 的键集）可解析的 `key=value` 行，PID 取远超 pid_max 的值（如 `2147483647`，保证 /proc 无此项）使 `validate_pid` 返回 1（stale）：
     pid=2147483647
     machine=romulus
     binary=qemu-system-arm
     started_at=2026-06-20T00:00:00Z
     ssh_port=2222
   - **stale 用例（status=1）**：`parse_args stop-qemu --all -d; cmd_stop_qemu`，`</dev/null`；断言 `rc==0` 且 `assert_true "stale pid 文件仍在" test -f "$tmp/workspace/qemu-bin/.pids/romulus.pid"`。
   - **running 用例（status=0，证 dry-run 不杀活实例——stop-qemu dry-run 核心卖点）**：用 `setsid bash -c 'exec -a "qemu-system-arm-romulus" sleep 30' &` 起后台进程（argv 含 `qemu-system-arm` 与 `romulus` 两子串，使 `validate_pid` 返回 0），记其 PID 写 `binary=qemu-system-arm`/`machine=romulus` 的 pid 文件；跑 `parse_args stop-qemu romulus -d; cmd_stop_qemu`，断言 `rc==0`、`assert_true "进程仍活" kill -0 <pid>`、pid 文件仍在；用例末 `kill <pid>` 清理。
   - `assert_summary`。
2. **Run**：`bash tests/protocol/stop_qemu_dryrun.sh`
   **预期（失败）**：现状 `-d` 被忽略，`--all` 对 stale pid 执行 `rm -f` → pid 文件被删 → `assert_true` FAIL。
3. 改 `ob` 的 `cmd_stop_qemu`：在 per-target 循环里 `validate_pid ...; pid_status=$?` 之后、`if [[ $pid_status -eq 1 ]]` 之前插入：
   if [[ "$DRY_RUN" -eq 1 ]]; then
       case "$pid_status" in
           0) info "[DRY-RUN] Would stop QEMU for '$MACHINE' (PID $PIDFILE_PID)" ;;
           1) info "[DRY-RUN] Would clean stale PID file for '$MACHINE' (process exited)" ;;
           2) info "[DRY-RUN] Would clean stale PID file for '$MACHINE' (PID recycled)" ;;
       esac
       continue
   fi
4. **Run**：`bash tests/protocol/stop_qemu_dryrun.sh`
   **预期（通过）**：`rc=0` 且 pid 文件仍在；末行 `PASS=N FAIL=0`。

### 任务 7 — `usage()` 更新

1. 改 `ob` 的 `usage()`：Commands 段 build 行改为（首 token 仍是 `build`，不破 `usage_dispatch_sync`）：
   build        [<machine>]    Build an initialized machine's image (interactive if omitted)
   Examples 段加：
   ob build romulus                 # Build romulus non-interactively
   ob build romulus -d              # Preview the build without running bitbake
2. **Run**：`./ob --help | grep -n 'build'` 且 `bash tests/protocol/usage_dispatch_sync.sh`
   **预期**：`--help` 显示 `build  [<machine>]`；usage_dispatch_sync `ok ... usage() Commands == dispatch 子命令集合`，`FAIL=0`。

### 任务 8 — 文档随动（已存在 `.md`，注意 gotcha）

> ⚠️ 前置：`CONTEXT.md` 与 `rules/skills/bestpractice_06-ob_first.md` 当前已带本轮（设计阶段）未提交改动（remedy line / banner / exit-3 协议）。任务 8 是在其上**叠加**编辑，不是重复落盘——开工前先 `git diff` 这两个文件确认既有改动就位、且与本任务编辑位置不冲突。

1. 改 `CONTEXT.md` 头部段：把 `ob build`（交互选择已初始化的 machine，执行 bitbake 编译）改为同时点出 `ob build <machine>` 非交互直构。
2. 改 `rules/skills/bestpractice_06-ob_first.md`：把"## 已知缺口"中 `ob build` 纯交互那条改写为"已补齐"——`ob build <machine>` 非交互路径 + dry-run 已落地；若该节再无其它缺口，整节移除或留一句"当前无已知缺口"。
3. **Run**（核对磁盘字节，因编辑工具可能静默不落盘）：
   grep -n "ob build <machine>" CONTEXT.md
   grep -n "已知缺口" rules/skills/bestpractice_06-ob_first.md
```raw
   **预期**：`CONTEXT.md` 命中非交互描述；`bestpractice_06` 不再把 `ob build` 列为未补缺口（命中数为 0 或仅剩"无已知缺口"语句）。

### 任务 9 — `cmd_start_qemu` L3352 两命令 remedy 收敛为单命令（独立于 build，先写失败测试）

1. 新建 `tests/protocol/start_qemu_remedy.sh`，仿隔离写法（独立 `mktemp -d` + 子进程 `OB_NO_MAIN=1 source ob` + override `detect_harness_root` + `</dev/null`），两用例捕获 rc + stderr：
   - 用例 (a) 无任何 init-done：不种 marker，跑 `parse_args start-qemu; cmd_start_qemu`；断言 `rc==3`、stderr `assert_contains` 字面 `Run 'ob init <machine>' first.`，并 `assert_false` 反向断言不含 `then 'ob build'`（守单命令契约）。
   - 用例 (b) init-done 未 built：种 `$tmp/workspace/configs/romulus.init-done` 但不建 deploy 目录，跑 `parse_args start-qemu; cmd_start_qemu`；断言 `rc==3`、stderr `assert_contains` 字面 `Run 'ob build' first.`（证语义已纠正——不再误导去 init）。
   - 末尾 `assert_summary`。
2. **Run**：`bash tests/protocol/start_qemu_remedy.sh`
   **预期（失败）**：现状两用例都打 `Run 'ob init <machine>' then 'ob build' first.`——(a) 含 `then 'ob build'` 触发反向断言 FAIL；(b) 期望的 `Run 'ob build' first.` 不在，FAIL。
3. 改 `ob` 的 `cmd_start_qemu` 空 `machines` 守卫（约 L3349–L3353），按是否存在任一 `*.init-done` marker 拆两条单命令子分支：
   if [[ ${#machines[@]} -eq 0 ]]; then
       local _any_initdone=0
       for _f in "$CONFIGS_DIR"/*.init-done; do [[ -f "$_f" ]] && { _any_initdone=1; break; }; done
       if [[ "$_any_initdone" -eq 1 ]]; then
           error "No built machines found (initialized but not built)."
           error "Run 'ob build' first."
       else
           error "No initialized machines found."
           error "Run 'ob init <machine>' first."
       fi
       exit 3
   fi
4. **Run**：`bash tests/protocol/start_qemu_remedy.sh`
   **预期（通过）**：两用例 `ok`；末行 `PASS=2 FAIL=0`。

### 任务 10 — 最终验证

1. **Run**：`tools/ob_check.sh`
   **预期**：`extract_funcs GAPS=0`、`reorder 无 mismatch`、shellcheck baseline `CLEAN` 或良性 `REGEN`、`run_all ALL GREEN`；末行 `ALL GREEN`。若 baseline 自动重生成，`git diff tests/.shellcheck-baseline` 确认仅行号平移。
2. **Run**：`bash tests/run_all.sh --full`
   **预期**：protocol/unit/orchestration 全 `ok`，`.exp` 矩阵（含 `manual_matrix.exp`、`build_e2e.exp`）不回归；末行 `ALL GREEN`。
3. **Run**（真实 smoke，非 TTY remedy 形态）：`./ob build definitely-not-a-machine; echo "rc=$?"`
   **预期**：`rc=3`，stderr 含 `Run 'ob init definitely-not-a-machine' first`。

## 执行纪律

- 开始前先批判性复查整份计划；发现缺项/矛盾/命名不一致/验证命令失效，先修计划再动手。
- 按任务顺序执行，不无声跳步、合并步或改任务目标。
- 每完成一个任务跑该任务的验证；改 `ob` 的任务（1、3、4、5、6、7、9）完成后无需每步都 `ob_check.sh`，但任务 10 的 `ob_check.sh` 必须全绿。
- 编辑已存在 `.md`（任务 8）后用 `grep` 核对磁盘；若工具静默未落盘，改用 `python3` 读改写再核对。
- 遇阻塞、重复失败或计划与仓库现实不符，立即停下说明，不要猜。
- 当前若在 `main`/`master` 且用户未明确同意，开始实现前先确认。
- 全部完成后跑最终验证并输出修改摘要（改了哪些文件、新增哪些测试、退出码/文案变化）。

## 最终验证

- `tools/ob_check.sh` → `ALL GREEN`
- `bash tests/run_all.sh --full` → `ALL GREEN`
- `bash tests/protocol/build_noninteractive.sh` → `PASS=3 FAIL=0`
- `bash tests/protocol/stop_qemu_dryrun.sh` → `FAIL=0`
- `bash tests/protocol/start_qemu_remedy.sh` → `PASS=2 FAIL=0`
- `./ob --help` 显示 `build [<machine>]` + 两条 examples；`bash tests/protocol/usage_dispatch_sync.sh` → `FAIL=0`
- `grep` 确认 `CONTEXT.md` 非交互描述、`bestpractice_06` 已知缺口已关闭（均磁盘核对）

```