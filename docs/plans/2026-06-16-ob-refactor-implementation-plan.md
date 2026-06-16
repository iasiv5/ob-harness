# ob 脚本重构与编码规范 实施计划

## 目标

按已批准设计 `docs/specs/2026-06-16-ob-refactor-design.md`，在单文件 `ob` 内完成：抽 5 个公共函数、统一退出码协议（含 L2 `exit 1→3` 迁移）、确立分层/分区规范。全程在阶段 0 建立的 smoke test 保护下小步推进，外部 CLI 接口（参数/子命令/--help/正常 stdout）不变。

## 架构快照

- **物理结构不变**：`ob` 维持单文件；改动收敛到一个文件 + 新增 `tests/smoke_ob.sh`。
- **四层分层**：L0 入口（`main`/`parse_args`）→ L1 编排（`cmd_*`）→ L2 领域（`ensure_*`/`resolve_*` 等）→ L3 通用工具（本次新抽）。新抽函数归 L3，绝不 `exit`。
- **退出码**：CLI 模式 `main` 直接调 `cmd_*`，`cmd_*` 的 `exit N` 即进程退出码；统一靠对齐 `cmd_*` 及 L2 调用链的码值（0/2/3/1），不依赖 `main` 的 `return`。
- **测试钩子**：`OB_NO_MAIN=1 source ob` 跳过 `main`，可单独调用函数做 smoke test。

## 输入工件

- 设计文档：`docs/specs/2026-06-16-ob-refactor-design.md`（两轮评审闭环、已批准）
- 评审记录：`docs/specs/2026-06-16-ob-refactor-design-review.md`、`2026-06-16-ob-refactor-design-review-v2-final.md`

## 文件结构与职责

- Create: `tests/smoke_ob.sh` — 零依赖 bash smoke test，覆盖 parse_args/dispatch/前置检查/dry-run/退出码
- Modify: `ob` — 全部代码改动（公共函数、退出码、分区锚点）
- Modify: `rules/03_WORKSPACE.md` — 增补 `tests/` 路由条目
- Create: 本计划文档

## 全局执行纪律

- **开始前**：批判性复查整份计划与设计；发现缺项/矛盾/命名不一致/验证命令无效，先修计划。
- **行号以符号名 grep 重锚**：本计划的 `ob#Lxxx` 仅为参考，会随实现漂移（复审中已出现 agent 行号偏差）。开工每个任务前，用 `grep -n` 按函数名/文案重新定位，不按死行号下刀。
- **每任务验证**：完成后必须运行该任务定义的验证；`ob` 改动后一律先 `bash -n ob` 查语法，再跑 `bash tests/smoke_ob.sh`。
- **遇阻停下**：行为不等价、计划与仓库现实不符、归类拿不准时立即停下说明，不猜、不无声合并步。
- **分支**：当前在 `main`。开始实现前与用户确认是否先切工作分支（如 `refactor/ob-cleanup`）。
- **提交**：每个任务 Step 5 在自然边界 checkpoint commit，commit message 前缀 `refactor(ob):`。

## 任务清单

---

### Task 1: 创建 smoke test 框架并验证 OB_NO_MAIN source 可行性

- 目标：建立 `tests/smoke_ob.sh`，验证 `OB_NO_MAIN=1 source ob` 能加载函数而不触发 main，且 `set -euo pipefail` 被正确隔离。
- Files
  - Create: `tests/smoke_ob.sh`
- 验证范围：`bash tests/smoke_ob.sh` 退出 0；能看到"OB_NO_MAIN source OK"且未触发 main（无 logo/菜单输出）。

- [ ] Step 1: 写失败检查 — 确认当前无测试基线
  - Run: `ls tests/smoke_ob.sh 2>/dev/null; echo "exit=$?"`
  - Expected: 文件不存在，`exit=1`（或无输出）

- [ ] Step 2: 确认 source 可行性（手动探针）
  - Run: `bash -c 'OB_NO_MAIN=1 source ./ob; echo "loaded=$?"; type log >/dev/null && echo "log() defined"'`
  - Expected: `loaded=0`、`log() defined`；无 logo/菜单输出（说明 main 未触发）。若报 nounset/errexit 干扰，记下需要 `set +e` 隔离的点。

- [ ] Step 3: 写最小实现 — smoke test 框架
  ```bash
  #!/usr/bin/env bash
  # Smoke test for ob — non-interactive paths only. Zero dependencies.
  # Usage: bash tests/smoke_ob.sh
  set -uo pipefail
  # NOTE: do NOT set -e here — ob's `set -euo pipefail` would otherwise abort on first non-zero assert.

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  OB="$SCRIPT_DIR/../ob"
  PASS=0; FAIL=0

  assert_exit() {
      # assert_exit <expected_rc> <label> <cmd...>
      local exp="$1"; local label="$2"; shift 2
      local rc=0
      ( "$@" ) >/dev/null 2>&1 || rc=$?
      if [[ "$rc" -eq "$exp" ]]; then PASS=$((PASS+1)); echo "ok   $label (rc=$rc)";
      else FAIL=$((FAIL+1)); echo "FAIL $label (expected rc=$exp got $rc)"; fi
  }

  # Load ob without triggering main. ob's own `set -euo pipefail` leaks into
  # this harness via source; re-disable errexit so a non-zero assert doesn't
  # abort the whole run. Keep nounset/pipefail.
  OB_NO_MAIN=1 source "$OB" || { echo "source failed"; exit 1; }
  set +e
  echo "OB_NO_MAIN source OK"

  # (parse_args / dispatch / exit-code tests added in Task 2/3)

  echo ""
  echo "PASS=$PASS FAIL=$FAIL"
  [[ "$FAIL" -eq 0 ]]
  ```
  - Change: 新建 smoke test 框架；`set -uo pipefail` 但**不** `set -e`；`assert_exit` 用子 shell 捕获退出码。

- [ ] Step 4: 运行确认通过
  - Run: `bash tests/smoke_ob.sh`
  - Expected: 退出 0，输出 `OB_NO_MAIN source OK` 和 `PASS=0 FAIL=0`（此时还没有断言用例）。

- [ ] Step 5: checkpoint commit
  - Run: `git add tests/smoke_ob.sh && git commit -m "test(ob): add smoke test harness with OB_NO_MAIN source"`

---

### Task 2: smoke test 覆盖 parse_args

- 目标：为 `parse_args` 加退出码断言（`--help`→0、未知选项→1、缺值→1、`-d`/`-v`/`--skip-deps` 正确置位）。
- Files
  - Modify: `tests/smoke_ob.sh`（在 source 之后、汇总之前插入用例段）
- 验证范围：`bash tests/smoke_ob.sh` 退出 0，`PASS` 数 ≥ 6 且 `FAIL=0`。

- [ ] Step 1: 写失败检查 — parse_args 当前未被测试
  - Run: `bash tests/smoke_ob.sh | grep -c parse_args`
  - Expected: `0`（尚无 parse_args 用例）

- [ ] Step 2: 确认现状退出码（手动探针）
  - Run: `bash -c 'OB_NO_MAIN=1 source ./ob; parse_args --help >/dev/null 2>&1; echo rc=$?; parse_args --no-such-opt >/dev/null 2>&1; echo rc=$?'`
  - Expected: `--help` rc=0；`--no-such-opt` rc=1（`parse_args` 内 `exit`）。确认探针工作后再写断言。

- [ ] Step 3: 写最小实现 — 在 source 段后插入 parse_args 用例
  ```bash
  # --- parse_args exit codes ---
  assert_exit 0 "parse_args --help"      bash -c 'OB_NO_MAIN=1 source "$0"; parse_args --help' "$OB"
  assert_exit 1 "parse_args unknown opt" bash -c 'OB_NO_MAIN=1 source "$0"; parse_args start-qemu --bogus-opt' "$OB"
  assert_exit 1 "parse_args missing val" bash -c 'OB_NO_MAIN=1 source "$0"; parse_args start-qemu --ssh-port' "$OB"
  ```
  - Change: 加 3 条 parse_args 退出码断言。注意每条用例在子进程独立 source（避免 `parse_args` 的 `exit` 影响主 harness），通过 `"$0"="$OB"` 传脚本路径。**用合法命令（start-qemu）打底**，确保 unknown opt 打到选项循环 `*)` 行内 exit（469）、missing val 打到 `--ssh-port` 缺值行内 exit（452），而非 `case COMMAND *)` 的 Unknown command（432）——这样名副其实且覆盖行内 exit 路径。

- [ ] Step 4: 运行确认通过
  - Run: `bash tests/smoke_ob.sh`
  - Expected: 退出 0，parse_args 三条全 ok，`FAIL=0`。

- [ ] Step 5: checkpoint commit（与 Task 3 合并提交亦可）

---

### Task 3: smoke test 覆盖 dispatch + 前置检查 + dry-run

- 目标：覆盖 dispatch 路由、前置检查（空 workspace `ob build`→exit 3）。**`--dry-run` 转手动矩阵**：`cmd_start_qemu` 到达 dry-run 前须先过 `resolve_machine`，空 workspace 会先 exit 3，无 machineless 自动路径，smoke 无法覆盖——设计成功标准该条降级为手动（已在最终手动矩阵）。
- Files
  - Modify: `tests/smoke_ob.sh`
- 验证范围：`bash tests/smoke_ob.sh` 退出 0，新增断言全 ok、`FAIL=0`。

- [ ] Step 1: 写失败检查
  - Run: `bash tests/smoke_ob.sh | grep -cE 'dispatch|dry-run|prereq'`
  - Expected: `0`

- [ ] Step 2: 确认现状退出码
  - Run: `cd "$(mktemp -d)" && OB_NO_MAIN=1 source /bmc/iasi/ob-harness/ob; parse_args build; detect_harness_root 2>/dev/null; cmd_build >/dev/null 2>&1; echo "build_rc=$?"`
  - Expected: `build_rc=3`（空 workspace 缺 init-done）。若不是 3，记下真实码并在断言里用真实值（设计要求改到 3，但 Task 3 仅建立**现状基线**，基线断言用现状值，Task 16/17 后再更新预期到 3）。**关键：基线断言的 expected 值要反映现状，不是目标态。**

- [ ] Step 3: 写最小实现 — dispatch/前置/dry-run 用例
  ```bash
  # --- dispatch + prerequisites (baseline: capture CURRENT rc, update after Task 16/17) ---
  TMPWS="$(mktemp -d)"
  assert_exit 3 "ob build in empty workspace" \
      bash -c 'cd "$1"; OB_NO_MAIN=1 source /bmc/iasi/ob-harness/ob; parse_args build; detect_harness_root 2>/dev/null || true; cmd_build' _ "$TMPWS"
  # dry-run path (start-qemu --dry-run) — only add if a machineless dry-run path exists;
  # otherwise mark as manual and skip (see manual matrix in design).
  rm -rf "$TMPWS"
  ```
  - Change: 加空 workspace `cmd_build`→3 的基线断言。`detect_harness_root` 在空目录可能失败，用 `|| true` 容错；关键是 `cmd_build` 的前置检查 exit 3。dry-run 若无 machineless 路径则跳过自动化、归入手动矩阵（设计已列）。

- [ ] Step 4: 运行确认通过
  - Run: `bash tests/smoke_ob.sh`
  - Expected: 退出 0，`FAIL=0`。

- [ ] Step 5: checkpoint commit
  - Run: `git add tests/smoke_ob.sh && git commit -m "test(ob): cover parse_args, dispatch, prerequisites baseline"`

---

### Task 4: WORKSPACE.md 增补 tests/ 路由

- 目标：在 `rules/03_WORKSPACE.md` 的"项目与代码"区加 `tests/` 路由条目。
- Files
  - Modify: `rules/03_WORKSPACE.md`（"项目与代码"区，`tools/` 条目附近）
- 验证范围：`grep -n 'tests/' rules/03_WORKSPACE.md` 命中一条说明 smoke test 的条目。

- [ ] Step 1: 写失败检查
  - Run: `grep -c 'tests/' rules/03_WORKSPACE.md`
  - Expected: `0`

- [ ] Step 2: 确认插入位置
  - Run: `grep -n '工具脚本\|tools/' rules/03_WORKSPACE.md`
  - Expected: 命中"工具脚本（依赖解析等）：`tools/`"行，在其后插入。

- [ ] Step 3: 写最小实现
  - 在 `tools/` 条目后追加一行：
  ```
  - 测试脚本（smoke test）：`tests/`（如 `tests/smoke_ob.sh`，零依赖 bash，`bash tests/smoke_ob.sh` 运行）
  ```
  - Change: 增补路由条目。

- [ ] Step 4: 运行确认通过
  - Run: `grep -n 'smoke_ob' rules/03_WORKSPACE.md`
  - Expected: 命中。

- [ ] Step 5: checkpoint commit（可与 Task 1-3 合并）

---

### Task 5: 抽 read_kv_field 并归并键值读取

- 目标：新增 L3 `read_kv_field <file> <key>`，语义"从文件首条匹配、保留首个 `=` 后全部（`cut -f2-`）"；归并设计 abstraction 3 的全部目标——`read_lock_field`、`read_qemu_url_config`、`download_and_replace_community_qemu`/`check_jenkins_update` 内的 manifest 键值读取。
- Files
  - Modify: `ob`（§2 通用工具区新增函数；`read_lock_field` 改调）
- 验证范围：`bash -n ob` 通过；`bash tests/smoke_ob.sh` 全绿；`read_lock_field` 行为对照（同 lock 文件同 key 返回值不变）。

- [ ] Step 1: 写失败检查 — read_kv_field 尚不存在
  - Run: `bash -c 'OB_NO_MAIN=1 source ./ob; type read_kv_field >/dev/null 2>&1; echo "defined=$?"'`
  - Expected: `defined=1`（未定义）

- [ ] Step 2: 确认 read_lock_field 现状行为（基线）
  - Run: 构造临时 lock 文件写入 `machine_first_init=foo`，调 `read_lock_field machine_first_init`，记录输出。
  - Expected: 输出 `foo`（作为等价对照基线）。

- [ ] Step 3: 写最小实现
  ```bash
  # Read first `key=value` match from a file. Returns value (after first '='), rc 0=found / 1=not.
  read_kv_field() {
      local file="$1"
      local key="$2"
      [[ -f "$file" ]] || return 1
      local line
      line=$(grep -m1 "^${key//./\\.}=" "$file" 2>/dev/null) || return 1
      [[ -z "$line" ]] && return 1
      echo "${line#*=}"
      return 0
  }
  ```
  - 把 `read_kv_field` 放在 `read_local_conf_var` 附近（§2）。
  - `read_lock_field` 主体改为 `read_kv_field "$SOURCE_LOCK_FILE" "$1"`（保留其现有的 file 默认与返回语义；逐行对照确保行为等价——尤其 `head -1` vs `-m1`、值含 `=` 时 `${line#*=}` 保留首个 `=` 后全部）。
  - **归并其余目标**：`read_qemu_url_config`（`grep "^key=" | tail -1 | cut -d= -f2-`）改为调 `read_kv_field`（写入端已去重，tail/head 等价，见设计 F2 闭环）；`download_and_replace_community_qemu`/`check_jenkins_update` 内 manifest 读取（`grep '^build_number='`、`grep '^url='`）同样改调。
  - ⚠️ **等价陷阱**：`read_qemu_url_config` 缺文件时是 `[[ -f ]] || return 0`（返回 0 + 空串）并对结果跑 `trim_whitespace`；而 `read_kv_field` 缺文件是 `return 1`。改调须 `val=$(read_kv_field "$f" "$k" 2>/dev/null) || val=""` 再 `trim_whitespace`，保持"缺文件→空串"语义，避免返回码从 0 翻成 1 破坏调用方。manifest 的 `cut -d= -f2`（非 `-f2-`）若值含 `=` 会截断——manifest 字段（build_number/url）不含 `=`，逐点核对确认。
  - Change: 新增 `read_kv_field`；`read_lock_field` / `read_qemu_url_config` / manifest 读取改调。

- [ ] Step 4: 运行确认通过
  - Run: `bash -n ob && bash tests/smoke_ob.sh`；再跑 Step 2 同样输入调 `read_lock_field`。
  - Expected: 语法 OK；smoke 全绿；`read_lock_field` 输出仍为 `foo`（行为等价）。

- [ ] Step 5: checkpoint commit
  - Run: `git add ob && git commit -m "refactor(ob): extract read_kv_field, route read_lock_field through it"`

---

### Task 6: 抽 select_from_list 并替换 4 处菜单选择

- 目标：新增 L3 `select_from_list <title> <label> <array_name>`，选中值经全局 `SELECT_FROM_LIST_CHOICE`、状态经返回码（0=确认/2=取消）；替换 `cmd_build`/`resolve_machine`/`cmd_start_qemu`/`cmd_stop_qemu` 4 处。
- Files
  - Modify: `ob`（§2 新增；4 个 cmd_*/resolve_machine 的菜单段）
- 验证范围：`bash -n ob`；smoke 全绿；4 处交互手感对照（手动矩阵）。

- [ ] Step 1: 写失败检查
  - Run: `bash -c 'OB_NO_MAIN=1 source ./ob; type select_from_list >/dev/null 2>&1; echo "defined=$?"'`
  - Expected: `defined=1`

- [ ] Step 2: 确认 4 处现状（grep 锚点）
  - Run: `grep -nE 'Please choose|select.*machine|Enter.*number|Choose \[' ob`
  - Expected: 命中 4 处菜单循环（cmd_build/resolve_machine/cmd_start_qemu/cmd_stop_qemu）。记录每处的标题文案、提示、范围外处理差异（cmd_build 有专门 `Number out of range`，其余统一提示）。

- [ ] Step 3: 写最小实现
  - 在 §2 新增 `select_from_list`：`local -n _arr="$3"`；打印标题 + `for i` 编号列表；`read`；`0`→`return 2`；非数字/范围外→统一 `warn` 重输；合法→`SELECT_FROM_LIST_CHOICE=$selected; return 0`。**绝不 `exit`。**
  - 4 处替换为：`if ! select_from_list "title" "machine" machines_arr; then <cancel logic, exit 2/continue>; fi; idx=$SELECT_FROM_LIST_CHOICE; ...`。逐处保留原取消语义（exit 2 或 continue）。
  - Change: 新增函数 + 4 处改调。统一"范围外/非数字→统一提示重输"。

- [ ] Step 4: 运行确认通过
  - Run: `bash -n ob && bash tests/smoke_ob.sh`
  - Expected: 语法 OK；smoke 全绿。交互分支归入 Task 最终手动矩阵。

- [ ] Step 5: checkpoint commit
  - Run: `git add ob && git commit -m "refactor(ob): extract select_from_list, replace 4 menu sites"`

---

### Task 7: 抽 confirm_action 并替换 4 处确认循环

- 目标：新增 L3 `confirm_action <verb> <object>`（内部 `print_confirm_banner` + Y/y 循环，`return 0`=确认/`return 2`=取消）；替换 `check_jenkins_update`/`cmd_build`/`resolve_machine`/`cmd_start_qemu` 4 处，并处理 `cmd_stop_qemu` 的 `continue 2`→单层 `continue`。
- Files
  - Modify: `ob`（§2 新增；4 处确认段 + cmd_stop_qemu 确认段）
- 验证范围：`bash -n ob`；smoke 全绿；确认/取消交互对照（手动）。

- [ ] Step 1: 写失败检查
  - Run: `bash -c 'OB_NO_MAIN=1 source ./ob; type confirm_action >/dev/null 2>&1; echo "defined=$?"'`
  - Expected: `defined=1`

- [ ] Step 2: 确认现状锚点
  - Run: `grep -nE '\[yY\]|\[yN\]|while true' ob | grep -iE 'confirm|stop|build|machine|jenkins'`
  - Expected: 命中确认循环位置。记录提示文案差异（`[y/N]` vs `[Y/n]`）、`cmd_stop_qemu` 的 `continue 2`（跳出内层 while、继续 for target）。

- [ ] Step 3: 写最小实现
  - §2 新增 `confirm_action`：`print_confirm_banner "$verb" "$object"`；`while read`；`[yY]`→`return 0`；`[nN]`→`return 2`；其他→`warn` 重输。**绝不 `exit`。**
  - 4 处替换：`if ! confirm_action "build" "$MACHINE"; then warn "...cancelled"; exit 2; fi` 形态。
  - `cmd_stop_qemu`（在 `for target` 体内）：`if ! confirm_action "stop QEMU for" "$MACHINE"; then info "Skipped '$MACHINE'."; continue; fi`（confirm_action 内化了 while，调用点回到 for 体内，单层 `continue` 等价原 `continue 2`）；保留 `QEMU_FORCE` 短路（`if [[ "$QEMU_FORCE" -ne 1 ]]; then ... fi`）与 TTY 前置判断在调用方。
  - **退出码归属（与 Task 14 厘清）**：`resolve_machine` 确认-N（"Init cancelled"）与 `cmd_start_qemu` 启动确认-N（"QEMU start cancelled"）经 confirm_action 替换后，取消路径自然从 `exit 0` 抬到 `exit 2`——这两处退出码统一**由本任务完成，Task 14 不再处理**。注意 `cmd_start_qemu` 的 kill-restart 拒绝（单次 `read`+`if answer!=y`，非 while 循环）**不属** confirm_action，仍归 Task 14。
  - Change: 新增函数 + 5 处改调（含 cmd_stop_qemu）。

- [ ] Step 4: 运行确认通过
  - Run: `bash -n ob && bash tests/smoke_ob.sh`
  - Expected: 语法 OK；smoke 全绿。

- [ ] Step 5: checkpoint commit

---

### Task 8: 抽 prompt_for_absolute_path 并替换 2 处

- 目标：新增 L3 `prompt_for_absolute_path <label>`，只做"read+trim+非空+非选项(`-*`)+绝对路径格式(`/*`)"，路径经全局 `PROMPT_PATH_RESULT`、状态经返回码（0=确认/2=取消）；存在性/内容校验留调用方。替换 `ensure_qemu_binary_custom` 内 binary 与 pc-bios 两处输入循环。
- Files
  - Modify: `ob`（§2 新增；`ensure_qemu_binary_custom` 两处输入段）
- 验证范围：`bash -n ob`；smoke 全绿；自定义 QEMU 路径交互对照（手动）。

- [ ] Step 1: 写失败检查
  - Run: `bash -c 'OB_NO_MAIN=1 source ./ob; type prompt_for_absolute_path >/dev/null 2>&1; echo "defined=$?"'`
  - Expected: `defined=1`

- [ ] Step 2: 确认现状锚点
  - Run: `grep -nE 'Enter.*path|absolute path|must start with /' ob`
  - Expected: 命中 `ensure_qemu_binary_custom` 的 binary 输入段（接受文件或目录+拼 `$arch` 回退）与 pc-bios 输入段（要求 `ast27x0_bootrom.bin` + `pc-bios/` 子目录）。记录两处的存在性/内容校验差异。

- [ ] Step 3: 写最小实现
  - §2 新增 `prompt_for_absolute_path`：循环 `read`→`trim_whitespace`→空→重输或 return 2→`-*`→`warn` 重输→非 `/*`→`warn` 重输→`PROMPT_PATH_RESULT=$path; return 0`。**绝不 `exit`。**
  - 两处替换：`if ! prompt_for_absolute_path "QEMU binary path"; then exit 2; fi; path="$PROMPT_PATH_RESULT"`，之后保留各自的存在性/内容校验（binary 的 `$arch` 回退、pc-bios 的 bootrom 检查）在调用方。
  - Change: 新增函数 + 2 处改调。

- [ ] Step 4: 运行确认通过
  - Run: `bash -n ob && bash tests/smoke_ob.sh`
  - Expected: 语法 OK；smoke 全绿。

- [ ] Step 5: checkpoint commit

---

### Task 9: 抽 download_qemu_binary_core 并替换 2 处（最高风险）

- 目标：新增 L3 `download_qemu_binary_core <url> <dest_dir>`，只做"curl 下载→`file -b` 类型检测→`tar xf` 解压→定位 binary 候选→sha256"，经全局 `DLQB_BIN_PATH`/`DLQB_SHA256` 返回、`return 0`=成功/`return 1`=失败；**flock/备份/回滚/manifest/exit 全留调用方**。替换 `download_and_replace_community_qemu` 与 `ensure_qemu_binary_community` 中完全共享的骨架。
- Files
  - Modify: `ob`（§2 新增；两函数的下载段）
- 验证范围：`bash -n ob`；smoke 全绿；**两调用方逐行对照**确认抽出的骨架在两处行为等价（重点关注 curl 参数、`file -b` 分支、`tar` 的 `--strip-components`、binary 候选定位路径）。

- [ ] Step 1: 写失败检查
  - Run: `bash -c 'OB_NO_MAIN=1 source ./ob; type download_qemu_binary_core >/dev/null 2>&1; echo "defined=$?"'`
  - Expected: `defined=1`

- [ ] Step 2: 逐行对照两调用方的下载段
  - Run: `grep -nE 'curl -fSL|file -b|tar xf|--strip-components|sha256sum' ob`
  - Expected: 命中 `download_and_replace_community_qemu` 与 `ensure_qemu_binary_community` 两段。**人工逐行比对**：列出两段完全一致的行（进公共函数）与不同的行（留调用方：flock+备份+回滚 vs 直落、`return` vs `exit`、build number 来源、解压目标差异）。

- [ ] Step 3: 写最小实现
  - §2 新增 `download_qemu_binary_core`：`curl -fSL -C - -o "$tmp"` → `file -b` 判 gzip/xz → `tar xf`（含两调用方一致的 strip 逻辑）→ 遍历候选定位 binary → `sha256sum|awk` → 设全局 `DLQB_BIN_PATH`/`DLQB_SHA256` → `return 0`；任一步失败 `return 1`。**绝不 `exit`、不碰 flock/备份/manifest。**
  - 两调用方：各自保留 flock/备份/回滚/manifest/build-number 与 `exit`；下载→解压→sha256 段改调 `download_qemu_binary_core` 并读全局变量。
  - Change: 新增函数 + 2 处改调。**本任务优先逐行核对，宁可少抽也不要把差异逻辑误并。**

- [ ] Step 4: 运行确认通过
  - Run: `bash -n ob && bash tests/smoke_ob.sh`；条件允许时手动跑一次 `ob start-qemu <已 init 的 machine> --dry-run`（若覆盖下载路径）或对照 manifest 输出。
  - Expected: 语法 OK；smoke 全绿；下载/解压/sha256 行为与改前一致。

- [ ] Step 5: checkpoint commit（单独提交，message 注明"逐行对照两调用方"）
  - Run: `git add ob && git commit -m "refactor(ob): extract download_qemu_binary_core (shared core only)"`

---

### Task 10: 抽 require_path 并替换 ~6 处前置检查

- 目标：新增 L3 `require_path <path> <hint> <exit_code>`（not found → error + hint + exit N）；替换 `cmd_build`/`cmd_start_qemu`/`find_ast2700_bootloaders` 等约 6 处"not found → error → hint → exit"模板。
- Files
  - Modify: `ob`（§2 新增；6 处前置检查）
- 验证范围：`bash -n ob`；smoke 全绿；空 workspace 前置路径 exit 码不变。

- [ ] Step 1: 写失败检查
  - Run: `bash -c 'OB_NO_MAIN=1 source ./ob; type require_path >/dev/null 2>&1; echo "defined=$?"'`
  - Expected: `defined=1`

- [ ] Step 2: 确认现状锚点
  - Run: `grep -nE "Run 'ob (init|build)' first|not found|does not exist" ob`
  - Expected: 命中约 6 处。记录每处的 `exit_code`（前提用 3）。**注意**：用于 L2 点（如 `find_ast2700_bootloaders` deploy_dir，现为 exit 1）会顺带把该点 `exit 1→3`——属 Task 16 的 L2 迁移范围，本任务在这些点先按目标 exit 3 落地（与 Task 16 一致，避免返工）。

- [ ] Step 3: 写最小实现
  - §2 新增 `require_path`：`if [[ ! -e "$1" ]]; then error "...not found: $1"; error "$2"; exit "$3"; fi`。
  - 6 处替换为 `require_path "$path" "Run 'ob init' first" 3` 等。`require_path` 是 L3，但内部 `exit` 是编排语义（由调用方传入 exit_code）——**例外**：本函数是前置守卫，保留 `exit` 以短路，归类时按调用方层级（L1 用 3、L2 前提用 3）。
  - Change: 新增函数 + 6 处改调。

- [ ] Step 4: 运行确认通过
  - Run: `bash -n ob && bash tests/smoke_ob.sh`
  - Expected: 语法 OK；smoke 全绿；空 workspace `ob build` 仍 exit 3。

- [ ] Step 5: checkpoint commit

---

### Task 11: check_ports_available 改调 get_port_occupants

- 目标：消除重复——`check_ports_available` 内联的 `ss | grep -v "^State"` 改调已存在的 `get_port_occupants`。
- Files
  - Modify: `ob`（`check_ports_available`）
- 验证范围：`bash -n ob`；smoke 全绿。

- [ ] Step 1: 写失败检查 — 确认重复存在
  - Run: `grep -nE "ss -(tl|ul)npH" ob`
  - Expected: 命中 `check_ports_available` 与 `get_port_occupants` 两处。

- [ ] Step 2: 确认 get_port_occupants 接口
  - Run: `grep -nA8 'get_port_occupants()' ob`
  - Expected: 看到 `get_port_occupants <port> <proto>` 的签名与输出（占用者列表）。

- [ ] Step 3: 写最小实现
  - `check_ports_available` 内把内联 `ss ... | grep -v "^State"` 换成循环调 `get_port_occupants "$port" "$proto"`，逻辑等价（有占用→报错）。
  - Change: 复用现有函数。

- [ ] Step 4: 运行确认通过
  - Run: `bash -n ob && bash tests/smoke_ob.sh`
  - Expected: 语法 OK；smoke 全绿。

- [ ] Step 5: checkpoint commit

---

### Task 12: cmd_status 改用 read_kv_field（遗漏修复）

- 目标：`cmd_status` Section 4 手写的 6 字段 `grep|cut` 改为对每个 PID 文件调 `read_kv_field` 局部读（不污染全局，不调 `read_pid_file`）。
- Files
  - Modify: `ob`（`cmd_status` 的 PID 文件读取段）
- 验证范围：`bash -n ob`；smoke 全绿；`ob status` 输出字段与改前一致（手动）。

- [ ] Step 1: 写失败检查 — 确认手写读取存在
  - Run: `grep -nE 'PIDFILE_(PID|BINARY|MACHINE|STARTED_AT|SSH_PORT)' ob | head`
  - Expected: 命中 `cmd_status` 内手写 `grep|cut` 读 PID 文件段（与 `read_pid_file` 重复）。

- [ ] Step 2: 确认字段集
  - Run: 读 `cmd_status` PID 段与 `read_pid_file` 写入的字段，对照 6 字段名（pid/binary/machine/started_at/ssh_port/redfish_port/ipmi_port 等）。

- [ ] Step 3: 写最小实现
  - for 循环内对每个 `$_pf` 用局部变量：`local p; p=$(read_kv_field "$_pf" pid) || continue` 等，逐字段局部读；不设全局 `QEMU_PID_FILE`/不调 `read_pid_file`（避免全局污染，评审 G3）。
  - Change: 改调 `read_kv_field` 局部读。

- [ ] Step 4: 运行确认通过
  - Run: `bash -n ob && bash tests/smoke_ob.sh`；有运行中实例时手动 `ob status` 对照输出。
  - Expected: 语法 OK；smoke 全绿；status 字段输出不变。

- [ ] Step 5: checkpoint commit

---

### Task 13: 删 write_pid_file + fn_err_quit 死代码

- 目标：确认 `write_pid_file` 与 `fn_err_quit` 均零调用方后删除（`fn_err_quit` 经核验零调用方，是 `fn_quit` 的错误退出对称函数但从未接线）。
- Files
  - Modify: `ob`（删两个函数）
- 验证范围：`bash -n ob`；`grep -E 'write_pid_file|fn_err_quit' ob` 无命中；smoke 全绿。

- [ ] Step 1: 写失败检查 — 确认两者零调用方
  - Run: `grep -nE 'write_pid_file|fn_err_quit' ob`
  - Expected: 各仅命中函数定义处（共 2 处），无调用。若发现任一调用方，**停下**——说明非死代码，不删该函数，回到设计重评。

- [ ] Step 2: 确认 _qemu_post_launch 是唯一写入点
  - Run: `grep -nE 'QEMU_PID_FILE.*<<|> "\$QEMU_PID_FILE"' ob`
  - Expected: 命中 `_qemu_post_launch` 的 heredoc 写入；`write_pid_file` 不在其列。

- [ ] Step 3: 写最小实现
  - 删除 `write_pid_file` 与 `fn_err_quit` 整个函数定义。
  - Change: 删两处死代码。

- [ ] Step 4: 运行确认通过
  - Run: `bash -n ob && grep -cE 'write_pid_file|fn_err_quit' ob && bash tests/smoke_ob.sh`
  - Expected: 语法 OK；`grep -c` 输出 `0`；smoke 全绿。

- [ ] Step 5: checkpoint commit
  - Run: `git add ob && git commit -m "refactor(ob): remove dead write_pid_file and fn_err_quit"`

---

### Task 14: exit 0-as-cancel → exit 2（3 处，另 2 处由 Task 7 处理）

- 目标：把 3 处"用户取消却 exit 0"改为 exit 2：`ensure_qemu_binary_community` 交互留空（831）、`select_openbmc_repo_url` 选 Q（2485）、`cmd_start_qemu` kill-restart 拒绝（3646，单次 `read` 非 while 循环）。另 2 处——`resolve_machine` 确认-N（2849）、`cmd_start_qemu` 启动确认-N（3709）——经 Task 7 的 confirm_action 替换已自然抬到 exit 2，**本任务不重复处理**。
- Files
  - Modify: `ob`（3 处）
- 验证范围：`bash -n ob`；smoke 全绿；取消路径 exit 2 由手动矩阵确认。

- [ ] Step 1: 写失败检查 — 确认 3 处现状 exit 0
  - Run: `grep -nB3 'exit 0' ob | grep -E 'aborting|cancelled|No URL provided|Aborted'`
  - Expected: 命中 831（No URL provided）、2485（cancelled by user）、3646（Aborted）三处。**注意**：若 Task 7 已完成，2849/3709 已是 exit 2，grep `exit 0` 不再命中（归属 Task 7）。**保持 0** 的 4 处（fn_quit 321、parse_args 早期 --help 395、parse_args 选项循环内 --help 450、dry-run 3729）不动。

- [ ] Step 2: 确认现状退出码（探针）
  - Run: 手动触发其中可非交互触发的取消路径（如 `select_openbmc_repo_url` 在非 TTY 下的行为），记录现状 rc=0。

- [ ] Step 3: 写最小实现
  - 3 处 `exit 0` → `exit 2`（831/2485/3646，文案锚点定位，grep 重锚行号）。
  - Change: 3 处码值统一为取消。

- [ ] Step 4: 运行确认通过
  - Run: `bash -n ob && bash tests/smoke_ob.sh`
  - Expected: 语法 OK；smoke 全绿（不回归）。取消路径多需 TTY 交互、smoke 难自动覆盖，故 exit 2 的正确性归入最终手动矩阵逐项确认，不强求 smoke 断言。

- [ ] Step 5: checkpoint commit
  - Run: `git add ob && git commit -m "refactor(ob): unify user-cancel exit codes to 2 (3 sites)"`

---

### Task 15: exit "$bb_exit" → exit 1

- 目标：`cmd_build` 的 `exit "$bb_exit"`（bitbake 码透传）改为退出前 `error` 打印原始码、再 `exit 1`。
- Files
  - Modify: `ob`（`cmd_build` bitbake 调用失败段）
- 验证范围：`bash -n ob`；smoke 全绿。

- [ ] Step 1: 写失败检查
  - Run: `grep -n 'exit "\$bb_exit"' ob`
  - Expected: 命中 1 处（cmd_build）。

- [ ] Step 2: 确认上下文
  - Run: 读该处上下文，确认 `bb_exit` 来自 bitbake 调用的 `$?`。

- [ ] Step 3: 写最小实现
  - 改为 `error "bitbake failed (exit code: $bb_exit)"` 后 `exit 1`。
  - Change: 不透传 bitbake 码，避免撞上保留的 2/3；原始码保留在 error 输出。

- [ ] Step 4: 运行确认通过
  - Run: `bash -n ob && bash tests/smoke_ob.sh`
  - Expected: 语法 OK；smoke 全绿。

- [ ] Step 5: checkpoint commit

---

### Task 16: L2 前提失败 exit 1 → exit 3 迁移

- 目标：把 L2 领域函数中"前提不满足"语义的 `exit 1` 改为 `exit 3`（约 18 处），按准则逐点归类，**不可无脑 sed**。硬错误（约 19 处）保持 `exit 1`，灰色 1 处。
- Files
  - Modify: `ob`（约 18 处 L2 前提分支）
- 验证范围：`bash -n ob`；smoke 全绿（更新前置检查断言预期到 exit 3）；逐点归类有据。

- [ ] Step 1: 写失败检查 — 列出全部 L2 exit 1 候选
  - Run: `grep -nE '^[[:space:]]*exit 1\b' ob`
  - Expected: 列出 53 处（**行首口径**）。人工剔除 L0 = 3 处（行首可见：parse_args 432/444 + fn_err_quit 328）与 L1 = 12 处（cmd_*），**余下 38 处为 L2 候选**。⚠️ parse_args 另有 6 处**行内** `exit 1`（452/455/458/461/464/469，`if ...; exit 1; fi` 单行）**不被行首 grep 命中**——它们是 L0 的 CLI 参数校验、保持 `exit 1` 不迁移，本就不在 L2 范围，别算进 L2。另注：53/38 是**当前基线**；本任务在 Task 10（`require_path` 已迁走 `find_ast2700_bootloaders` 等前提点）与 Task 15（`exit "$bb_exit"`→`exit 1` 会新增一处 L1）之后执行，届时 `grep` 输出会**少于 53、L2 候选少于 38**——以届时实际 grep 为准对账即可。
  - **注意重叠**：Task 10（`require_path`）已将 `find_ast2700_bootloaders` 等被其替换的 L2 前提点改为 `exit 3`，这些点已不在 exit 1 候选内（grep 自然排除）。下方草案清单中凡标注"前提→3"的点，若已被 Task 10 改过则跳过；草案只是"若仍为 exit 1 时的归类参考"。

- [ ] Step 2: 按准则逐点归类（**核心步骤，不可跳过**）
  - 准则（设计文档 §对齐清单 C）：
    - **→改 exit 3（前提不满足）**：缺依赖工具/缺必要文件·目录/缺配置（conf 键·URL 未配置）/非 TTY 缺必要参数/输入格式非法。
    - **→保持 exit 1（硬错误）**：I/O 失败（clone·下载·写入）/子命令失败（bitbake·外部脚本非零）/校验失败（sha256·源一致性冲突）/read EOF/内部断言失败。
  - **初始分类草案**（来自设计评审调研，行号仅供 grep 重锚参考，逐点看上下文确认）：
  - **计数说明（重要）**：L2 共 **38 处**（行首 exit 1 共 53 − L0 行首 3 − L1 12；行内 6 处属 parse_args 参数校验、不迁移、不在 L2）。草案用文字概括同函数的多处，**注意每个函数常有"第二处"**：`select_openbmc_repo_url` 的 read EOF 含 2458**+2471**、格式非法含 2435**+2444**；`resolve_machine` 的 read EOF 含 2806**+2839**；`ensure_qemu_binary_custom` 的 read EOF 含 954**+1002**。这 4 个"第二处"（2471/2444/2839/1002）都是行首 exit 1、**在 38 候选内，不可漏**——尤其 2444 是该转 exit 3 的 URL 格式非法，漏迁会留 bug。分桶以 grep 逐点归类为准：**→3 约 18、保持 1 约 19、灰色 1（合 38）**。
    - **改 3（前提，约 18 处）**：`ensure_qemu_binary_community` 非 TTY 缺配置（`QEMU binary URL not configured`）与 URL 格式非法（`Invalid URL`）；`ensure_qemu_binary_custom` 非 TTY 缺 binary（`QEMU binary not found`）；`find_ast2700_bootloaders`（deploy dir 缺失、bootloader 缺失）；`ensure_qemu_firmware`（bootrom 缺失）；`resolve_qb_vars`（BUILD_DIR 缺失、setup 脚本缺失）；`detect_soc_type`（无法确定 SoC）；`derive_qemu_machine_name`（无法推导）；`check_ports_available`（端口被占）；`ensure_bootstrap_local_conf`（local.conf 缺失）；`select_openbmc_repo_url`（`--url` / `OB_OPENBMC_URL` 格式非法，**含 2435+2444 两处**）；`resolve_machine`（无 machine 且非 TTY）；`prerequisites_check`（非 Linux、缺 git/python3）；`clone_sub_repos`（deps.json 缺失）。
    - **保持 1（硬错误，约 19 处）**：`ensure_qemu_binary_community` 下载失败/解压后找不到 binary；`ensure_qemu_binary_custom`（954+1002）/`prompt_for_available_port`/`select_openbmc_repo_url`（2458+2471）/`resolve_machine`（2806+2839）的 read EOF（**每函数含第二处**）；`resolve_qb_vars` bitbake -e 空；`detect_soc_type` SoC 冲突；`verify_source` 3 处源一致性冲突；`clone_openbmc` clone 失败；`run_repo_init_script` 脚本非零；`init_bitbake_env` source setup 后 local.conf 缺；`generate_dep_graph` bitbake -g / parse 脚本失败。
    - **灰色地带（1 处，实施时定）**：`resolve_npm_registry` 的 `Both npm registries are unreachable`（文案锚点，非行号）。两面论证：网络不可达≈环境不具备→3；probe 执行了但失败≈I/O→1。**默认按硬错误保持 1**（与 clone 下载失败一致），除非团队明确要归 3。
  - 对草案中每一处，`grep -n` 重锚后读上下文，确认归类。拿不准的单独标记并停下与用户确认。

- [ ] Step 3: 写最小实现 — 逐处改 exit 1 → exit 3
  - 只改"前提"类（约 18 处），硬错误（约 19 处）不动。**一处一改，改完即 grep 确认**，禁止批量 sed。
  - Change: 约 18 处码值 1→3。

- [ ] Step 4: 运行确认通过
  - Run: `bash -n ob && bash tests/smoke_ob.sh`；更新 smoke 中前置检查断言：空 workspace `cmd_build`→3（基线本就是 3，确认仍 3）、`cmd_start_qemu` 前提路径→3。
  - Expected: 语法 OK；smoke 全绿；所有"前提"路径 exit 3、所有"硬错误"路径仍 exit 1。

- [ ] Step 5: checkpoint commit（单独提交，message 注明"按准则逐点归类"）
  - Run: `git add ob tests/smoke_ob.sh && git commit -m "refactor(ob): migrate L2 precondition failures exit 1->3 (per rubric)"`

---

### Task 17: cmd_menu 解码统一

- 目标：`cmd_menu` 所有 case 统一为 `rc != 0 && rc != 2 && rc != 3 → error`，`==0/==2/==3` 静默；删 case 3（status）无法触发的失败分支。
- Files
  - Modify: `ob`（`cmd_menu` 的 5 个 case）
- 验证范围：`bash -n ob`；smoke 全绿。

- [ ] Step 1: 写失败检查 — 确认现状 case 结构
  - Run: `grep -nE 'init_rc|build_rc|qemu_rc|stop_rc|Status query failed' ob`
  - Expected: 命中 5 个 case 的 rc 判断；case 1 缺 `==3`、case 3 有死分支。

- [ ] Step 2: 确认迁移后各 cmd_ 可能的码值
  - Expected: Task 14/15/16 后，init/build/start/stop 都可能返回 0/2/3/1；status 总 0。

- [ ] Step 3: 写最小实现
  - 5 个 case 统一：`(cmd_x) || rc=$?; if [[ $rc -ne 0 && $rc -ne 2 && $rc -ne 3 ]]; then error "...failed (exit code: $rc)"; fi`；2/3 静默回菜单。
  - case 3（status）：删失败分支，保留 `cmd_status` 调用 + 成功注释（status 总成功）。
  - Change: 解码风格统一 + 删死分支。

- [ ] Step 4: 运行确认通过
  - Run: `bash -n ob && bash tests/smoke_ob.sh`
  - Expected: 语法 OK；smoke 全绿。

- [ ] Step 5: checkpoint commit

---

### Task 18: cmd_stop_qemu return→exit 统一 + main 语义清理 + validate_pid 注释

- 目标：`cmd_stop_qemu` 的 `return 0`（无实例）→ `exit 0`；`main` 的 `return 0`→`return $?`（语义清理，无行为变化）；`validate_pid` 加注释说明其 return 1/2 是诊断码、与退出码协议无关。
- Files
  - Modify: `ob`（`cmd_stop_qemu`、`main`、`validate_pid`）
- 验证范围：`bash -n ob`；smoke 全绿。

- [ ] Step 1: 写失败检查
  - Run: `grep -nE 'cmd_stop_qemu|^[[:space:]]*return 0' ob | grep -i stop`；`grep -n 'return 0' ob`（找 main 的）
  - Expected: 命中 `cmd_stop_qemu` 的 `return 0` 与 `main` 的 `return 0`。

- [ ] Step 2: 确认锚点
  - Run: 读 `validate_pid` 的 return 1（exited）/return 2（recycled）、`cmd_stop_qemu` 无实例 `return 0`、`main` 的 status/build `return 0`。

- [ ] Step 3: 写最小实现
  - `cmd_stop_qemu` 两处 `return 0` → `exit 0`（L1 编排层统一用 exit）。
  - `main` 的 `return 0`（status/build 行）→ `return $?`。
  - `validate_pid` 函数头加注释：`# return 0=running&match, 1=exited, 2=pid recycled — diagnostic only, NOT part of exit-code protocol`。
  - Change: 风格统一 + 注释隔离。

- [ ] Step 4: 运行确认通过
  - Run: `bash -n ob && bash tests/smoke_ob.sh`
  - Expected: 语法 OK；smoke 全绿（main 的改动无行为变化）。

- [ ] Step 5: checkpoint commit
  - Run: `git add ob && git commit -m "refactor(ob): unify stop_qemu exit, main return semantics, annotate validate_pid"`

---

### Task 19: 插入分区注释锚点（阶段 3a）

- 目标：在 `ob` 内插入 `# === §N ... ===` 分区锚点（§1 全局变量/§2 通用工具/§3 仓库与 machine/§4 QEMU/§5 构建流程/§6 命令编排/§7 入口），建立分区规范文档；**不动物理顺序**。
- Files
  - Modify: `ob`（6 个分区分隔注释）
- 验证范围：`bash -n ob`；smoke 全绿；`grep -c '=== §' ob` ≥ 6。

- [ ] Step 1: 写失败检查
  - Run: `grep -cE '=== §[0-9]' ob`
  - Expected: `0`

- [ ] Step 2: 确认各分区起止函数
  - Run: 复用已建函数地图（log→§2、read_source_label/derive_qemu_paths→§3 或 §4 边界、cmd_*→§6、parse_args/main→§7）。确定每个 § 锚点插在哪个函数前。

- [ ] Step 3: 写最小实现
  - 在对应函数前插入单行注释：`# === §2 通用工具 (L3) ===` 等。**纯注释，不改任何代码、不移动函数。** 阶段 3b 物理重排为可选项，本任务不做（见最终验证后评估）。
  - Change: 加 6 个分区锚点。

- [ ] Step 4: 运行确认通过
  - Run: `bash -n ob && bash tests/smoke_ob.sh && grep -c '=== §' ob`
  - Expected: 语法 OK；smoke 全绿；计数 ≥ 6。

- [ ] Step 5: checkpoint commit
  - Run: `git add ob && git commit -m "docs(ob): add section anchor comments (§1-§7 layout spec)"`

---

## 最终验证

- 语法：`bash -n ob` 通过。
- 自动回归：`bash tests/smoke_ob.sh` 退出 0、`FAIL=0`，且退出码断言反映目标态（取消=2、前提=3、硬错误=1）。
- 退出码协议一致性（手动核对）：
  - `grep -nE '^[[:space:]]*exit [0-9]' ob` 逐处核对：取消路径全 2、L1+L2 前提全 3、硬错误全 1、成功 0；`exit "$bb_exit"` 已消失。
  - `cmd_menu` 所有 case 风格统一（`!=0&&!=2&&!=3→error`）。
- 手动矩阵（交互分支，设计 §测试策略）：菜单各分支、init 取消（不再误报成功）、build 取消（exit 2）、start-qemu 拒绝杀重启/确认/URL 留空（exit 2）、stop-qemu 选实例。
- 死代码：`grep -cE 'write_pid_file|fn_err_quit' ob` = 0。
- 修改摘要：输出各阶段 commit 列表 + 抽出的公共函数清单 + 退出码变化点。

## 审阅 Checkpoint

- 实施计划已写好并保存到 `docs/plans/2026-06-16-ob-refactor-implementation-plan.md`。
- 默认执行方是普通编码 agent 或人工执行者，按任务顺序执行、每任务验证、遇阻停下。
- 审阅通过后再开始实现；开始前确认是否从 `main` 切工作分支。
