# ob 脚本迁移与 init machine 校验 实施计划

## 目标

- 将 `tools/ob` 干净迁移到仓库根目录 `ob`，并修正路径推断与全仓引用。
- 为 `ob init` 增加 machine 校验关卡：以 `source setup`（无参）输出为准，在主仓库就绪后、子仓库大下载前拦截无效/缺失 machine。
- `<machine>` 改为可选；主仓库缺失时引导克隆（菜单序号 + 等价 `--obmc-url` 命令）。
- 将 `--openbmc-url` 重命名为 `--obmc-url`，并重构下载提示分层。

## 架构快照

`ob` 是单文件 bash 脚本，`main()` 编排 8 步流程。本次在 `main()` 的 init 分支里，于 `clone_openbmc`（Step 2）与 `init_bitbake_env`（Step 3）之间插入两个新关卡：`require_openbmc_repo`（保证主仓库存在，缺失则引导克隆）和 `resolve_machine`（枚举/校验/交互选 machine）。machine 列表由新函数 `list_available_machines` 在 `$OPENBMC_DIR` 下运行 `source setup`（无参）捕获其 stderr/stdout 解析得到，与官方口径一致。`detect_harness_root` 因脚本上移一级，去掉 `/..`。`parse_bitbake_deps.py` 仍留在 `tools/`，脚本内 `$HARNESS_ROOT/tools/parse_bitbake_deps.py` 引用在迁移后自动正确解析，无需改动。

## 输入工件

- 设计文档：[docs/specs/2026-06-02-ob-relocate-and-machine-validation-design.md](2026-06-02-ob-relocate-and-machine-validation-design.md)
- 待改脚本：[tools/ob](../../tools/ob)

## 文件结构与职责

- Move: `tools/ob` → `ob`（git mv，保留历史）
- Modify: `ob`（`detect_harness_root` 去 `/..`；`parse_args` machine 可选；`--openbmc-url`→`--obmc-url`；新增 `list_available_machines`/`print_available_machines`/`require_openbmc_repo`/`resolve_machine`；`main()` 串接；下载提示分层；usage/注释文案）
- Modify: [rules/WORKSPACE.md](../../rules/WORKSPACE.md)（路由表 `tools/ob` → 根目录 `ob`）
- Modify: [rules/skills/workflow_obmc_env_init.md](../../rules/skills/workflow_obmc_env_init.md)（`tools/ob`→`ob`、`./tools/ob`→`./ob`、`--openbmc-url`→`--obmc-url`、补 machine 校验/可选说明）
- Modify: [docs/specs/2026-06-02-obmc-single-source-lock-design.md](2026-06-02-obmc-single-source-lock-design.md)（`tools/ob`→`ob`、`--openbmc-url`→`--obmc-url` 交叉引用）

## 任务清单

环境前提：所有验证命令在 Linux + bash 下运行，cwd 为仓库根 `/bmc/iasi/workspace/openbmc-aware-harness`。脚本用 `OB_NO_MAIN=1 source ./ob` 可只加载函数不执行 main（脚本末尾已有该 hook）。

### Task 1: git mv 迁移 ob 到根目录

- 目标：脚本物理移动到根目录，保留 git 历史。
- 涉及文件：`tools/ob` → `ob`
- 验证范围：根目录存在 `ob`，`tools/ob` 不存在。

- [ ] Step 1: 确认当前状态
- Run: `test -f tools/ob && test ! -e ob && echo MOVE_NEEDED`
- Expected: 输出 `MOVE_NEEDED`
- [ ] Step 2: 执行迁移
- Change: 运行 `git mv tools/ob ob`
- [ ] Step 3: 确认结果
- Run: `test -f ob && test ! -e tools/ob && echo MOVED`
- Expected: 输出 `MOVED`

### Task 2: 修正 detect_harness_root 路径推断

- 目标：脚本上移一级后，`HARNESS_ROOT` 应为脚本自身所在目录。
- 涉及文件：`ob`（`detect_harness_root`）
- 验证范围：`HARNESS_ROOT` 解析为仓库根。

- [ ] Step 1: 确认当前错误状态
- Run: `OB_NO_MAIN=1 source ./ob; MACHINE=x; detect_harness_root; echo "$HARNESS_ROOT"`
- Expected: 输出当前为仓库根的父级（错误，因仍有 `/..`），即不等于 `$PWD`
- [ ] Step 2: 修改实现
- Change: 在 `detect_harness_root` 中将
  `HARNESS_ROOT="$(cd "$script_dir/.." && pwd)"` 改为
  `HARNESS_ROOT="$script_dir"`
- [ ] Step 3: 确认修复
- Run: `OB_NO_MAIN=1 source ./ob; MACHINE=x; detect_harness_root; test "$HARNESS_ROOT" = "$PWD" && echo ROOT_OK`
- Expected: 输出 `ROOT_OK`

### Task 3: 将 init 的 machine 参数改为可选

- 目标：`ob init` 不带 machine 不再报 `Missing <machine>`。
- 涉及文件：`ob`（`parse_args` 的 `init)` 分支）
- 验证范围：不带 machine 时退出码非 1 且不打印 Missing。

- [ ] Step 1: 确认当前状态
- Run: `OB_NO_MAIN=1 bash -c 'OB_NO_MAIN=1 source ./ob; parse_args init 2>&1; echo rc=$?'`
- Expected: 输出包含 `Missing <machine> argument`
- [ ] Step 2: 修改实现
- Change: 把 `init)` 分支中
  if [[ $# -lt 1 ]] || [[ "$1" == --* ]]; then
      error "Missing <machine> argument for 'init'"
      usage
      exit 1
  fi
  MACHINE="$1"
  shift
  改为仅在存在非选项位置参数时取 machine：
  if [[ $# -gt 0 ]] && [[ "$1" != --* ]]; then
      MACHINE="$1"
      shift
  fi
- [ ] Step 3: 确认修复
- Run: `OB_NO_MAIN=1 bash -c 'OB_NO_MAIN=1 source ./ob; parse_args init; echo "MACHINE=[$MACHINE]"'`
- Expected: 输出 `MACHINE=[]`，且无 `Missing` 文案

### Task 4: 重命名 --openbmc-url 为 --obmc-url

- 目标：选项与环境变量提示统一为 `--obmc-url`。
- 涉及文件：`ob`（`parse_args` 选项分支、usage、`select_openbmc_repo_url` 报错文案）
- 验证范围：`--obmc-url` 可用，`--openbmc-url` 在脚本内无残留。

- [ ] Step 1: 确认当前状态
- Run: `grep -c -- '--openbmc-url' ob`
- Expected: 输出大于 0（当前为 4）
- [ ] Step 2: 修改实现
- Change: 将 `ob` 内所有 `--openbmc-url` 文本替换为 `--obmc-url`（含 `parse_args` 的 `case` 分支 `--openbmc-url)`、`Missing value for --openbmc-url`、usage 选项行与示例、`select_openbmc_repo_url` 中两处 `Use --openbmc-url <url> ...` 报错提示）。`OB_OPENBMC_URL` 环境变量名保持不变。
- [ ] Step 3: 确认修复
- Run: `grep -c -- '--openbmc-url' ob; grep -c -- '--obmc-url' ob`
- Expected: 第一行输出 `0`，第二行大于 0
- [ ] Step 4: 确认选项仍可解析
- Run: `OB_NO_MAIN=1 bash -c 'OB_NO_MAIN=1 source ./ob; parse_args init romulus --obmc-url https://x/openbmc.git; echo "URL=[$OPENBMC_REPO_URL]"'`
- Expected: 输出 `URL=[https://x/openbmc.git]`

### Task 5: 新增 machine 列表枚举与打印函数

- 目标：以 `source setup`（无参）输出为来源，提供枚举与打印能力。
- 涉及文件：`ob`（新增 `list_available_machines`、`print_available_machines`）
- 验证范围：在已克隆主仓库下，枚举结果包含 `romulus`。

- [ ] Step 1: 确认当前缺失
- Run: `grep -c 'list_available_machines' ob`
- Expected: 输出 `0`
- [ ] Step 2: 写最小实现
- Change: 在 `detect_harness_root` 之后新增两个函数：
  # 捕获 `source setup`（无参）输出，提取可用 machine 名（扁平集合，用于命中判断）
  list_available_machines() {
      [[ -d "$OPENBMC_DIR/.git" ]] || return 0
      local raw
      raw=$(cd "$OPENBMC_DIR" && set +u; source setup 2>&1 || true)
      # setup 在缺 machine 时打印 "Use one of:" 后的多列 machine 名
      echo "$raw" \
        | sed -n '/Use one of:/,$p' \
        | tail -n +2 \
        | tr -s ' \t' '\n' \
        | sed '/^$/d' \
        | sort -u
  }

  # 打印支持的 machine 列表（直接透传 setup 多列排版，便于阅读）
  print_available_machines() {
      local machines
      machines=$(list_available_machines)
      if [[ -z "$machines" ]]; then
          warn "No machines found. The OpenBMC main repository may be incomplete."
          warn "Try updating it: cd $OPENBMC_DIR && git pull"
          return 0
      fi
      info "Available machines in this repository:"
      echo "$machines" | column -c 80 2>/dev/null || echo "$machines"
  }
- [ ] Step 3: 确认枚举正确
- Run: `OB_NO_MAIN=1 bash -c 'OB_NO_MAIN=1 source ./ob; MACHINE=romulus; detect_harness_root; list_available_machines | grep -qx romulus && echo HAS_ROMULUS'`
- Expected: 输出 `HAS_ROMULUS`

### Task 6: 新增 require_openbmc_repo 引导克隆

- 目标：主仓库缺失时统一引导克隆（菜单序号 + 等价 `--obmc-url` 命令），带/不带 machine 均生效。
- 涉及文件：`ob`（新增 `require_openbmc_repo`、调整 `select_openbmc_repo_url` 菜单文案）
- 验证范围：主仓库存在时该函数为 no-op；菜单文案含等价命令。

- [ ] Step 1: 确认当前缺失
- Run: `grep -c 'require_openbmc_repo' ob`
- Expected: 输出 `0`
- [ ] Step 2: 写最小实现
- Change: 新增函数（置于 `clone_openbmc` 之后）：
  require_openbmc_repo() {
      if [[ -d "$OPENBMC_DIR/.git" ]]; then
          return 0
      fi
      info "No OpenBMC main repository found at $OPENBMC_DIR."
      info "A small main repository must be cloned first to list/validate machines (a few minutes)."
      clone_openbmc
  }
  并在 `select_openbmc_repo_url` 的交互菜单中，为两个选项追加等价命令提示：
  echo "  1) Community OpenBMC (GitHub.com)"
  echo "       equivalent: ob init --obmc-url $DEFAULT_OPENBMC_REPO_URL"
  echo "  2) Custom OpenBMC repository URL"
  echo "       equivalent: ob init --obmc-url <your-repo-url>"
- [ ] Step 3: 确认主仓库存在时为 no-op
- Run: `OB_NO_MAIN=1 bash -c 'OB_NO_MAIN=1 source ./ob; MACHINE=romulus; detect_harness_root; require_openbmc_repo; echo rc=$?'`
- Expected: 输出 `rc=0`，无克隆动作
- [ ] Step 4: 确认菜单含等价命令
- Run: `grep -c 'equivalent: ob init --obmc-url' ob`
- Expected: 输出 `2`

### Task 7: 新增 resolve_machine 校验关卡

- 目标：打印列表；machine 已提供且命中则通过；未提供或未命中则有 TTY 交互选、无 TTY 报错退出。
- 涉及文件：`ob`（新增 `resolve_machine`）
- 验证范围：有效 machine 通过；无效 + 无 TTY 报错退出（rc≠0）。

- [ ] Step 1: 确认当前缺失
- Run: `grep -c 'resolve_machine' ob`
- Expected: 输出 `0`
- [ ] Step 2: 写最小实现
- Change: 新增函数（置于 `require_openbmc_repo` 之后）：
  resolve_machine() {
      local machines
      machines=$(list_available_machines)
      print_available_machines

      if [[ -n "$MACHINE" ]] && echo "$machines" | grep -qx -- "$MACHINE"; then
          info "Machine '$MACHINE' confirmed."
          return 0
      fi

      if [[ -n "$MACHINE" ]]; then
          warn "Machine '$MACHINE' is not in the available list."
      else
          warn "No machine specified."
      fi

      if [[ ! -t 0 ]]; then
          error "No valid machine and no interactive terminal. Pass a valid machine: ob init <machine>"
          exit 1
      fi

      local selected
      while true; do
          if ! read -r -p "Enter a machine name from the list above: " selected; then
              error "Unable to read machine selection from stdin."
              exit 1
          fi
          if echo "$machines" | grep -qx -- "$selected"; then
              MACHINE="$selected"
              info "Machine '$MACHINE' confirmed."
              return 0
          fi
          warn "Invalid machine: $selected"
      done
  }
- [ ] Step 3: 确认有效 machine 通过
- Run: `OB_NO_MAIN=1 bash -c 'OB_NO_MAIN=1 source ./ob; MACHINE=romulus; detect_harness_root; resolve_machine >/dev/null; echo rc=$? MACHINE=$MACHINE'`
- Expected: 输出 `rc=0 MACHINE=romulus`
- [ ] Step 4: 确认无效 + 无 TTY 报错退出
- Run: `OB_NO_MAIN=1 bash -c 'OB_NO_MAIN=1 source ./ob; MACHINE=iasi-ast2700; detect_harness_root; resolve_machine </dev/null >/dev/null 2>&1; echo rc=$?'`
- Expected: 输出 `rc=1`

### Task 8: 在 main() 串接新关卡并重定位 BUILD/SRC 派生

- 目标：init 分支按"主仓库就绪 → 校验 machine → 大下载"顺序执行；交互改名后的 machine 能正确派生 `BUILD_DIR`/`SRC_DIR`。
- 涉及文件：`ob`（`main`）
- 验证范围：dry-run 全流程对有效 machine 正常结束。

- [ ] Step 1: 确认当前顺序缺少新关卡
- Run: `grep -n 'require_openbmc_repo\|resolve_machine' ob`
- Expected: 无匹配（main 中尚未调用）
- [ ] Step 2: 调整 main 流程
- Change: 在 `main()` 的 init 路径中：
  - 把 `prerequisites_check` 之后、`clone_openbmc` 之前替换为先 `prerequisites_check`，再 `require_openbmc_repo`（替代裸 `clone_openbmc`，因其内部已调用 `clone_openbmc`）。
  - 紧接 `resolve_machine`。
  - 在 `resolve_machine` 之后、`init_bitbake_env` 之前，因 machine 可能在交互中被改写，重新派生路径：
    `BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"; SRC_DIR="$WORKSPACE_DIR/src/$MACHINE"`
  - 注意：`is_rerun` 检测块依赖 `SRC_DIR/BUILD_DIR`，当 machine 来自交互时其判断需在 `resolve_machine` 之后。将"fresh/rerun 提示块"移动到 `resolve_machine` 之后、大下载提示之前。
  最终 init 顺序：
  prerequisites_check
  require_openbmc_repo      # 含 clone_openbmc
  resolve_machine
  BUILD_DIR/SRC_DIR 重派生
  [fresh/rerun 提示 + 大下载结构化提示]
  init_bitbake_env
  generate_dep_graph
  clone_sub_repos
  generate_lockfile
  inject_externalsrc
  print_report
- [ ] Step 3: 确认 dry-run 全流程通过
- Run: `./ob init romulus --dry-run`
- Expected: 打印 available machines + `Machine 'romulus' confirmed.`，各步 `[DRY-RUN]` 提示，正常退出（rc=0）
- [ ] Step 4: 确认无效 machine 在大下载前被拦
- Run: `./ob init iasi-ast2700 --dry-run </dev/null; echo rc=$?`
- Expected: 打印列表 + 报错，`rc=1`，且无 `Step 4` 及之后输出

### Task 9: 重构下载提示分层

- 目标：主仓库克隆为 INFO 轻量提示；大下载为结构化醒目提示并点明 machine 已确认。
- 涉及文件：`ob`（`clone_openbmc` 主仓提示、`main` 中 fresh-run 大下载提示）
- 验证范围：相关文案出现且语气分层。

- [ ] Step 1: 确认当前生硬提示
- Run: `grep -n 'This will download ~20-30 GB' ob`
- Expected: 命中 `main()` 中一行 `warn` 提示
- [ ] Step 2: 修改实现
- Change:
  - `clone_openbmc` 克隆前的 `info "Cloning ..."` 之上补一行：
    `info "Downloading the small OpenBMC main repository (used to list machines, ~a few minutes)."`
  - 将 `main()` fresh-run 块的单行
    `warn "This will download ~20-30 GB of source code. Estimated time: 20-60 minutes."`
    替换为结构化醒目提示（置于 machine 确认之后）：
    echo ""
    warn "============================================================"
    warn " Machine '$MACHINE' confirmed — about to fetch its sub-repos."
    warn " Download size : ~20-30 GB"
    warn " Estimated time: 20-60 minutes"
    warn " Resumable     : safe to Ctrl+C; re-run resumes incrementally."
    warn "============================================================"
    echo ""
```raw
- [ ] Step 3: 确认文案到位
- Run: `grep -c "Machine '\$MACHINE' confirmed — about to fetch" ob; grep -c 'small OpenBMC main repository' ob`
- Expected: 两行均输出 `1`

### Task 10: 更新 usage 与脚本内注释文案

- 目标：usage 反映 `<machine>` 可选、`--obmc-url`、根目录调用形态。
- 涉及文件：`ob`（`usage`、顶部注释、re-run 注释）
- 验证范围：usage 文本一致。

- [ ] Step 1: 确认当前 usage 旧态
- Run: `./ob --help | grep -- '--openbmc-url'`
- Expected: 仍命中旧选项（若 Task 4 已改则此处应无命中——以实际为准，命中说明遗漏）
- [ ] Step 2: 修改实现
- Change: 在 `usage()` 中：
  - `init <machine>` 行说明改为 `init [<machine>]   One-click initialize (machine optional; will list/prompt if omitted)`
  - 示例区补一条 `ob init                         # List machines and choose interactively`
  - 顶部注释 `# Usage: ob init <machine> [options]` 改为 `# Usage: ob init [<machine>] [options]`
- [ ] Step 3: 确认 usage 更新
- Run: `./ob --help | grep -E 'machine optional|ob init  *# List machines'`
- Expected: 两条均命中

### Task 11: 更新 WORKSPACE.md 路由表

- 目标：路由表指向根目录 `ob`。
- 涉及文件：`rules/WORKSPACE.md`
- 验证范围：无 `tools/ob` 残留，含根目录 `ob` 描述。

- [ ] Step 1: 确认当前状态
- Run: `grep -n 'tools/ob' rules/WORKSPACE.md`
- Expected: 命中第 10 行
- [ ] Step 2: 修改实现
- Change: 将 `- OpenBMC 环境初始化工具：\`tools/ob\`（\`ob init <machine>\` 一键初始化）` 改为
  `- OpenBMC 环境初始化工具：根目录 \`ob\`（\`./ob init [<machine>]\` 一键初始化）`
- [ ] Step 3: 确认更新
- Run: `grep -c 'tools/ob' rules/WORKSPACE.md; grep -c '根目录 `ob`' rules/WORKSPACE.md`
- Expected: 第一行 `0`，第二行 `1`

### Task 12: 更新 workflow_obmc_env_init.md 引用

- 目标：skill 文档反映新路径、可选 machine、`--obmc-url`、machine 校验。
- 涉及文件：`rules/skills/workflow_obmc_env_init.md`
- 验证范围：无 `tools/ob`、无 `--openbmc-url` 残留。

- [ ] Step 1: 确认当前状态
- Run: `grep -c 'tools/ob\|./tools/ob\|--openbmc-url' rules/skills/workflow_obmc_env_init.md`
- Expected: 输出大于 0
- [ ] Step 2: 修改实现
- Change: 将该文件中 `./tools/ob` → `./ob`、独立出现的 `tools/ob` → `ob`、`--openbmc-url` → `--obmc-url`；并在"可用资源/命令行选项"区补一行 `./ob init                          # 列出可用 machine 并交互选择`，在目标/边界处补一句"machine 在主仓库就绪后按 `source setup` 列表校验，无效或缺省时交互选择（无 TTY 报错退出）"。
- [ ] Step 3: 确认更新
- Run: `grep -c 'tools/ob\|--openbmc-url' rules/skills/workflow_obmc_env_init.md`
- Expected: 输出 `0`

### Task 13: 更新 single-source-lock 设计文档交叉引用

- 目标：消除遗留设计文档对旧路径/旧选项的引用漂移。
- 涉及文件：`docs/specs/2026-06-02-obmc-single-source-lock-design.md`
- 验证范围：该文档内 `tools/ob`、`--openbmc-url` 已更新。

- [ ] Step 1: 确认当前状态
- Run: `grep -c 'tools/ob\|--openbmc-url' docs/specs/2026-06-02-obmc-single-source-lock-design.md`
- Expected: 输出大于 0
- [ ] Step 2: 修改实现
- Change: 将该文档中 `tools/ob` → `ob`、`--openbmc-url` → `--obmc-url`（仅文本引用，不改其设计语义）。
- [ ] Step 3: 确认更新
- Run: `grep -c 'tools/ob\|--openbmc-url' docs/specs/2026-06-02-obmc-single-source-lock-design.md`
- Expected: 输出 `0`

## 执行纪律

- 开始实现前先复查本计划。
- 每个 Task 完成后运行其验证命令，确认预期信号再进入下一个。
- Task 1（git mv）后所有后续命令均以根目录 `ob` 为准。
- 遇到验证不通过立即停下定位，不跳步。
- 建议 checkpoint commit 边界：Task 1 后、Task 8 后、Task 13 后。

## 最终验证

- 全仓无悬挂旧引用：
  - Run: `grep -rn 'tools/ob' rules/ docs/ ob 2>/dev/null | grep -v 'parse_bitbake_deps' ; echo done`
  - Expected: 仅输出 `done`（无 `tools/ob` 行）
  - Run: `grep -rn -- '--openbmc-url' ob rules/ docs/ 2>/dev/null; echo done`
  - Expected: 仅输出 `done`
- 语法正确：
  - Run: `bash -n ob && echo SYNTAX_OK`
  - Expected: 输出 `SYNTAX_OK`
- 有效 machine 全流程（dry-run）：
  - Run: `./ob init romulus --dry-run; echo rc=$?`
  - Expected: 打印 machine 列表 + `Machine 'romulus' confirmed.` + 大下载结构化提示 + 各步 `[DRY-RUN]`，`rc=0`
- 无效 machine 无 TTY 拦截：
  - Run: `./ob init iasi-ast2700 --dry-run </dev/null; echo rc=$?`
  - Expected: 打印列表 + 报错，`rc=1`，无 Step 4 及之后输出
- 不带 machine 无 TTY 拦截：
  - Run: `./ob init --dry-run </dev/null; echo rc=$?`
  - Expected: 打印列表 + `No machine specified` + 报错，`rc=1`
- status 不受影响：
  - Run: `./ob status; echo rc=$?`
  - Expected: 正常打印绑定状态，`rc=0`

## 审阅 Checkpoint

- 本计划已完成 inline 自检。请审阅；批准后再进入实现。
- 实现将交接给执行者按 Task 顺序推进，本计划不在此阶段直接编码。

```