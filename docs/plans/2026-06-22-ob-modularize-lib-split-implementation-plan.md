# ob 单文件深化为分区 sourced 模块 实施计划

## 目标

把单文件 `ob`（4251 行/93 函数）拆为入口 + `lib/*.sh` 六文件结构，退役 `reorder.py`，`exit_contract.py` 多文件化，消除 §3→§5 反向耦合。行为完全不变，全套测试绿。

## 架构快照

- 入口 `ob` 只留 §1（全局变量 + `OB_ENTRY_DIR`）+ §7（`parse_args`/`usage`/`main`）+ `source "$OB_ENTRY_DIR"/lib/*.sh`。
- §2–§6 物化为 `lib/{util,repo,qemu,init_pipeline,commands}.sh`，函数体不动（`detect_harness_root` 除外：改用 `OB_ENTRY_DIR`）。
- `exit_contract.py` 多文件化（B1+glob+Y-c basename）；`extract_funcs.py` 扩展三段纯函数定义检查；`ob_check.sh` 用 `OB_SOURCES` 契约（nullglob）；`reorder.py` 归档。
- 关键顺序：**工具与测试先行多文件化（Task 2–4，此时 lib 空、行为同单文件），再原子切换搬 §2（Task 5）**，避免"两份 §2 函数"中间态。exit_contract 的实现（Task 2）与单测 fixture 同 Task 处理，避免工具改完、单测未改的断裂窗口。

## 输入工件

- 设计文档：`docs/specs/2026-06-22-ob-modularize-lib-split-design.md`（v2.1，已批准）
- 评审落地要求：三段纯函数定义检查须为明确任务（Task 3），不得只复用现有 GAPS

### 修订记录

| # | 评审项 | 修订 |
|---|---|---|
| 🔴1（一审）| `OB_SOURCES+=(lib/*.sh)` 无 nullglob 会变字面量 | Task 4 加 `shopt -s nullglob` 包裹 glob 展开 |
| 🔴2（一审）| extract_funcs fixture 不含 `lib/`，三段检查不启用 | Task 3 fixture 改 `$TMP/lib/bad_lib.sh` + `mkdir -p` |
| 🔴3（一审）| Y-c 中间态预期矛盾 | Task 2–4 窗口接受 `Y: n/a`（窗口不改 ob 函数，纪律不降级） |
| 🔴4（一审）| Task 1 验证 grep 会命中 §6 新编排行 | 改两条命令：sed 验 §3 体内无 clone + grep 验 §6 有编排 |
| 🟡1（一审）| baseline 归一化表述矛盾 | 初版选"保留文件名"（文件感知）；**后被三审 🔴b 实验推翻，改纯文本 flat baseline**（见 🔴b） |
| 🟡2（一审）| 漏 ob_check_smoke.sh 注释 | Task 6 加 `ob_check_smoke.sh`；Task 4 同步清 ob_check.sh 注释 reorder 提及 |
| 🟢1（一审）| 预期无匹配的 grep 在 set -e 下误判 | 全部改 `! grep -q` / `! grep -qE` |
| 🔴（二审）| Task 4 在修 case 3 前跑 ob_check 撞未修单测 | **case 3 并入 Task 2**（exit_contract 实现+测试同一闭环），后续 Task 前移 |
| 🔴a（三审）| source loop 触发 ShellCheck SC1090 | Task 5 source loop 加 `# shellcheck disable=SC1090` |
| 🔴b（三审）| per-file shellcheck 产生 SC2034 跨文件假阳（ob §1 定义的 `CYAN`/`VERBOSE` 等被 lib 使用→扫 ob 报 unused） | Task 4 shellcheck 改**合成 flat 输入**（`cat ob + lib/*.sh`→临时文件，扫 flat 保留单文件可见性，实验验证 excess 0）；baseline 纯文本 multiset（非文件感知）；extract_funcs/exit_contract/bash -n 仍用 OB_SOURCES |

## 文件结构与职责

- Create: `lib/util.sh`、`lib/repo.sh`、`lib/qemu.sh`、`lib/init_pipeline.sh`、`lib/commands.sh`
- Modify: `ob`（入口化）、`tools/exit_contract.py`、`tools/extract_funcs.py`、`tools/ob_check.sh`、`tests/integration/init_dryrun_sanity.sh`、`tests/unit/exit_contract.sh`、`tests/protocol/ob_check_smoke.sh`、`rules/03_WORKSPACE.md`、`CONTEXT.md`
- Archive: `tools/reorder.py` → `tools/archive/reorder.py`

环境前提：Linux + bash。所有验证命令沿用仓库惯例（`tools/ob_check.sh`、`tests/run_all.sh`）。**预期"无匹配"的 grep 一律用 `! grep -q` 形式**，避免 `set -e` 把退出码 1（无匹配）当失败。

---

## 任务清单

### 阶段 0 · 解耦（单文件内，逻辑改动）

### Task 1: 解耦 §3→§5 — require_openbmc_repo 改纯检查 + cmd_init 编排 clone

- 目标：`require_openbmc_repo` 退回"检查 + return 信号"，clone 由 cmd_init 编排，消除 §3→§5 反向依赖。
- Files: Modify `ob`（`require_openbmc_repo` [ob:948-958]、`cmd_init` 内 [ob:3864]）
- 验证范围：`ob_check` 全绿 + `ob init <machine> -d` dryrun 行为不变。

- [ ] Step 1: 写当前状态检查
  - 当前 `require_openbmc_repo` 体内含跨层调用 `clone_openbmc`。
  - Run: `sed -n '/^require_openbmc_repo()/,/^}/p' ob | grep -n clone_openbmc`
  - Expected: 命中 `clone_openbmc`（§3 调 §5 的反向耦合存在）
- [ ] Step 2: 运行并确认当前状态
  - Run: `OB_CHECK_SKIP_TESTS=1 bash tools/ob_check.sh`
  - Expected: 当前全绿（基线）
- [ ] Step 3: 写最小实现
  - `require_openbmc_repo`：删 `clone_openbmc` 行，改为 `return 3`（附注释：repo 未就绪，由调用方 cmd_init 编排 clone_openbmc）。
  - `cmd_init` [ob:3864]：`require_openbmc_repo` → `require_openbmc_repo || clone_openbmc`。
  - Change: 2 处改动，`clone_openbmc` 失败靠其显式 `exit 1`（[ob:2360]），`||` 不吞失败。
- [ ] Step 4: 运行并确认通过
  - Run: `bash tools/ob_check.sh && bash tests/run_all.sh --full`
  - Expected: 全绿
  - Run: `sed -n '/^require_openbmc_repo()/,/^}/p' ob | grep -q clone_openbmc && echo "FAIL: §3 仍调 clone_openbmc" || echo "ok: §3 解耦"`
  - Expected: `ok: §3 解耦`（require_openbmc_repo 体内无 clone_openbmc）
  - Run: `grep -n 'require_openbmc_repo || clone_openbmc' ob`
  - Expected: 命中 cmd_init 的编排行（§6 负责编排 clone）
- [ ] Step 5: 可选 checkpoint（commit 由用户决定，agent 不自动 commit）

### 阶段 1 · 机制切换（工具/测试先行，再原子搬 §2）

> Task 2–4 期间 `lib/` 为空或仅测试桩，`ob` 仍是自足单文件，每步 `ob_check` 全绿。**exit_contract 的 Y 在此窗口为 `n/a`**（Y-c basename 规则下，无 `util.sh` 即无可判定文件，从基线 PASS 变 n/a 是预期）；窗口内不改 ob 函数，exit 纪律不降级。Task 5 搬出 `util.sh` 后 Y 恢复 PASS。

### Task 2: exit_contract.py 多文件化 + 单测 case 3 迷你树（同一语义闭环）

- 目标：`exit_contract.py` 默认扫 `ob + lib/*.sh`，Y 按 basename(`util.sh`) 判定；**同步**把单测 case 3 从单文件 §2 marker 改成迷你目录树。实现与测试同 Task 完成，避免工具改完、单测未改的断裂窗口。
- Files: Modify `tools/exit_contract.py`（`main`/`parse_funcs`/`check_Y`/`section2_exiters`）、`tests/unit/exit_contract.sh`（case 3）
- 验证范围：`exit_contract` 默认扫描 `X: PASS / Y: n/a / Z: PASS`；`exit_contract.sh` 单测全过（含 case 3 迷你树）。

- [ ] Step 1: 写当前状态检查
  - 当前 `main` 只吃单 `path`，`check_Y` 靠 `find_section_range(lines, 2)`；case 3 用单文件 `# === §2 util ===` marker。
  - Run: `python3 tools/exit_contract.py | grep -E '^(X|Y|Z):'; sed -n '42,50p' tests/unit/exit_contract.sh`
  - Expected: 三 verdict PASS（Y 靠 §2 marker）；case 3 见 `# === §2 util ===`
- [ ] Step 2: 运行并确认当前状态
  - Run: `python3 tools/exit_contract.py; echo "rc=$?"; bash tests/unit/exit_contract.sh`
  - Expected: exit_contract 三 PASS/rc=0；单测全过（基线）
- [ ] Step 3: 写最小实现
  - `exit_contract.py`：
    - `main`：不传参时默认扫描集 = `['ob'] + sorted(glob('lib/*.sh'))`；传参时扫指定文件（保留单文件 debug）。每文件调 `parse_funcs` 附来源文件，拼全函数表；`file_lines[file]` 各自维护。
    - `check_Y`：`section2_exiters` 改为"basename 为 `util.sh` 的文件里的函数"（不再 `find_section_range`）；无 `util.sh` 返回 None（Y: n/a）。
    - `check_X`/`check_Z`：全函数表 + `file_lines` 跨文件扫。报错文案"§2"→"`util.sh`"。
  - `tests/unit/exit_contract.sh` case 3：构造 `$TMP/lib/util.sh`（含 `myhelper() { exit 1; }`）+ `$TMP/ob`（空桩），调 `python3 "$EXIT_CONTRACT" "$TMP/ob" "$TMP/lib/util.sh"`，断言 rc=1（Y 捕获 util.sh 的 unexpected exit）。其余 case 不改。
  - Change: exit_contract 多文件全表 + Y basename + case 3 迷你树。
- [ ] Step 4: 运行并确认通过
  - Run: `python3 tools/exit_contract.py; echo "rc=$?"`
  - Expected: lib 空 → `X: PASS / Y: n/a / Z: PASS`，rc=0（Y 从 PASS 变 n/a 是预期）
  - Run: `bash tests/unit/exit_contract.sh`
  - Expected: 全过（含 case 3 迷你树）—— **此时 Task 4 跑 ob_check/run_all 不会撞 case 3**
- [ ] Step 5: 可选 checkpoint

### Task 3: extract_funcs.py 扩展三段纯函数定义检查（评审明确要求）

- 目标：对 `lib/*.sh` 严查三段（header/函数间/footer）无非注释顶层语句；`ob` 入口豁免。不得只复用现有函数间 GAPS。
- Files: Modify `tools/extract_funcs.py`
- 验证范围：对构造的违规 lib 桩（须在 `lib/` 路径下）能报 header/footer 违规；单文件 `ob` 仍只报 GAPS（入口豁免）。

- [ ] Step 1: 写当前状态检查 + 失败检查
  - 当前 `extract_funcs` 只检查函数间，不查 header/footer。构造 footer 违规桩（路径须含 `lib/` 才启用三段检查）：
    ```bash
    TMP="$(mktemp -d)"; mkdir -p "$TMP/lib"
    cat >"$TMP/lib/bad_lib.sh" <<'EOF'
    #!/usr/bin/env bash
    # lib 桩
    foo() { :; }
    echo "footer side effect"
    EOF
    ```
  - Run: `python3 tools/extract_funcs.py "$TMP/lib/bad_lib.sh" | tail -1`
  - Expected: 当前输出 `GAPS 0`（footer 的 `echo` 漏检——要修的口子）
- [ ] Step 2: 运行并确认当前漏检
  - Run: `python3 tools/extract_funcs.py "$TMP/lib/bad_lib.sh"`
  - Expected: 报 `GAPS 0`，未报 footer 违规
- [ ] Step 3: 写最小实现
  - 新增 lib 三段检查（仅对路径含 `lib/` 的文件启用，`ob` 入口豁免）：
    - header（首个函数前）：只允许 shebang、空行、注释，否则报 `HEADER_TOPLEVEL`。
    - 函数间：沿用现有 `GAPS` 逻辑。
    - footer（最后一个函数后）：只允许空行、注释，否则报 `FOOTER_TOPLEVEL`。
  - 任一段违规 → 退出码非 0。
  - Change: 新增 header/footer 检查 + lib/ 路径判定。
- [ ] Step 4: 运行并确认通过
  - Run: `python3 tools/extract_funcs.py "$TMP/lib/bad_lib.sh"`
  - Expected: 报 footer 违规（非 GAPS 0）
  - Run: `python3 tools/extract_funcs.py ob | tail -1`
  - Expected: `GAPS 0`（ob 入口豁免，行为不变）
  - Run: `rm -rf "$TMP"`
- [ ] Step 5: 可选 checkpoint

### Task 4: ob_check.sh 多文件化（OB_SOURCES 契约 + nullglob + 移除 reorder 检查）

- 目标：`ob_check.sh` 定义 `OB_SOURCES` 契约（nullglob 防 lib 空变字面量），shellcheck 改合成 flat + baseline 纯文本 multiset，extract_funcs 走 Task 3 三段检查，移除 reorder 检查项及注释。
- Files: Modify `tools/ob_check.sh`
- 验证范围：`ob_check` 全绿（lib 空，扫单 ob 同前；exit_contract.sh 已在 Task 2 修好，run_all 不撞）；不再调/提 reorder。

- [ ] Step 1: 写当前状态检查
  - 当前 `ob_check.sh` 第 2 步调 `reorder.py ob`，shellcheck 只扫 `ob`，顶部注释多处提 reorder。
  - Run: `grep -nE 'reorder|shellcheck' tools/ob_check.sh`
  - Expected: 命中 reorder 调用（行 24）+ reorder 注释（行 3/4/15/23）+ `shellcheck -f gcc ob`
- [ ] Step 2: 运行并确认当前状态
  - Run: `OB_CHECK_READONLY=1 OB_CHECK_SKIP_TESTS=1 bash tools/ob_check.sh`
  - Expected: 当前全绿（基线）
- [ ] Step 3: 写最小实现
  - 顶部定义 OB_SOURCES，**用 nullglob 防 lib 空时展开成字面量**：
    ```bash
    OB_SOURCES=(ob)
    shopt -s nullglob
    OB_SOURCES+=(lib/*.sh)
    shopt -u nullglob
    ```
  - 第 2 步 reorder 检查整段删除；**同步清理 ob_check.sh 顶部注释**（行 3「聚合: …reorder…」、行 4「固定顺序: …reorder…」、行 15「GAPS=0 是后续 reorder 的前提」）的 reorder 提及。
  - 第 3 步 shellcheck：**不 per-file 扫 OB_SOURCES**（per-file 会因跨文件变量可见性丢失产生 SC2034 假阳——`CYAN`/`VERBOSE` 等在 ob §1 定义、被 lib 函数使用，扫 ob 报 unused）。改**合成 flat 输入**：
    ```bash
    { cat ob; cat lib/*.sh 2>/dev/null; } > /tmp/ob_check_sc.flat   # lib 空时 flat=ob
    shellcheck -f gcc /tmp/ob_check_sc.flat > /tmp/ob_check_sc.new 2>&1 || true
    ```
    flat 保留单文件变量/函数可见性（三审实验验证搬 §2 后 flat 扫 excess 0）。source loop 的 SC1090 由 Task 5 suppress，flat 继承不报。
  - baseline parser 纯文本 multiset：`re.sub(r'^[^:]+:\d+:\d+:\s*', '', line)`（去 flat 路径 + 行列号，留告警文本）。搬迁告警文本不变 → CLEAN；真新增告警 → NEW_ALERT。
  - 第 1 步 extract_funcs / 第 4 步 exit-contract / `bash -n`：**仍用 OB_SOURCES 多文件**（不依赖跨文件变量可见性，无需 flat）。
  - 汇总 PASS/FAIL 逻辑不变。
  - Change: OB_SOURCES(nullglob，用于 extract_funcs/exit_contract/bash -n) + 删 reorder 步及注释 + shellcheck 改合成 flat + baseline 纯文本 multiset。
- [ ] Step 4: 运行并确认通过
  - Run: `OB_CHECK_READONLY=1 bash tools/ob_check.sh`
  - Expected: 全绿（含 run_all；exit_contract.sh 已 Task 2 修好，case 3 不撞）；输出不再含 reorder 项
  - Run: `! grep -q reorder tools/ob_check.sh`
  - Expected: 通过（ob_check.sh 无 reorder 残留）
- [ ] Step 5: 可选 checkpoint

### Task 5: 搬 §2 → lib/util.sh + 启用 source 机制（核心原子切换）

- 目标：建 `lib/util.sh`（§2 函数体不动），`ob` 入口加 `OB_ENTRY_DIR` + source loop + 删 §2 段 + `detect_harness_root` 改用 `OB_ENTRY_DIR`，integration 加 `cp -a lib`。一次完成（中间态不可用）。
- Files: Create `lib/util.sh`；Modify `ob`（§1 区域加 OB_ENTRY_DIR、加 source loop、删 §2 段 [ob:57-617]、`detect_harness_root` [ob:330-343]）；Modify `tests/integration/init_dryrun_sanity.sh`（加 cp lib）
- 验证范围：`ob_check` + `run_all --full` + integration 全绿；`HARNESS_ROOT` 在 init/start-qemu/stop-qemu 三路径都正确；搬出 util.sh 后 exit_contract Y 恢复 PASS。

- [ ] Step 1: 写当前状态检查
  - Run: `grep -n '# === §2' ob; ls lib/ 2>&1; grep -n 'BASH_SOURCE\[0\]' ob | head -1`
  - Expected: 命中 §2 锚点、`lib/` 不存在、`detect_harness_root` 用 BASH_SOURCE
- [ ] Step 2: 运行并确认当前状态
  - Run: `OB_CHECK_READONLY=1 bash tools/ob_check.sh`
  - Expected: 全绿（基线）
- [ ] Step 3: 写最小实现（原子，按序）
  - 建 `lib/util.sh`：shebang + 注释头（"ob §2 通用工具，被 ob source"）+ 从 `ob` §2 段（57–617，含前导注释）原样拷贝全部函数。**不含 `set -euo`**。
  - `ob` §1 区域（source lib 前）加：`OB_ENTRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`
  - `ob` §1 之后加 source loop（含 SC1090 suppress——flat 合成带上这行动态 source，suppress 后 flat 不报 SC1090）：
    ```bash
    for f in "$OB_ENTRY_DIR"/lib/*.sh; do
        # shellcheck disable=SC1090
        source "$f"
    done
    ```
  - 删 `ob` 里 §2 段（§1 之后、§3 之前，含 `# === §2` 锚点到 §3 锚点前）。
  - `lib/util.sh` 里 `detect_harness_root`：`HARNESS_ROOT="$OB_ENTRY_DIR"`（删掉原 `script_dir=...BASH_SOURCE...` 两行）。
  - `tests/integration/init_dryrun_sanity.sh` [行 16 后] 加：`cp -a "$ROOT/lib" "$TMPROOT/lib"`
  - Change: 建 lib/util.sh + ob 入口化 + detect_harness_root 用 OB_ENTRY_DIR + integration cp lib。
- [ ] Step 4: 运行并确认通过
  - Run: `bash -n ob && bash -n lib/util.sh`
  - Expected: 语法无误
  - Run: `./ob --help >/dev/null && echo "usage ok"`
  - Expected: `usage ok`（source 链通）
  - Run: `bash tools/ob_check.sh && bash tests/run_all.sh --full`
  - Expected: 全绿（含 integration init dryrun 到 Step 8/8，证明 HARNESS_ROOT 正确；exit_contract Y 恢复 PASS）
  - Run: `! grep -q '# === §2' ob`
  - Expected: 通过（§2 已搬出）
- [ ] Step 5: 可选 checkpoint

### Task 6: reorder.py 归档 + 清理现役门禁引用

- 目标：`reorder.py` 移到 `tools/archive/`，从 `rules/03_WORKSPACE.md`、`tests/protocol/ob_check_smoke.sh` 移除现役门禁引用（Task 4 已从 ob_check.sh 删调用与注释）。
- Files: Archive `tools/reorder.py` → `tools/archive/reorder.py`；Modify `rules/03_WORKSPACE.md`、`tests/protocol/ob_check_smoke.sh`
- 验证范围：`ob_check` 不依赖 reorder；文档/测试无现役门禁引用。

- [ ] Step 1: 写当前状态检查
  - Run: `grep -rn 'reorder' rules/03_WORKSPACE.md tests/protocol/ob_check_smoke.sh`
  - Expected: WORKSPACE.md 命中 reorder 描述（两处）；ob_check_smoke.sh 注释命中「extract_funcs/reorder/baseline」
- [ ] Step 2: 运行并确认当前状态
  - Run: `ls tools/reorder.py`
  - Expected: 文件存在（待归档）
- [ ] Step 3: 写最小实现
  - `mkdir -p tools/archive && git mv tools/reorder.py tools/archive/reorder.py`
  - `rules/03_WORKSPACE.md`：reorder.py 描述改为"已归档至 `tools/archive/`（§1-§7 物理重构历史工具）"，或从现役工具清单移除、仅在历史语境提及。
  - `tests/protocol/ob_check_smoke.sh`：注释里 smoke 覆盖范围去掉 `reorder`（改为 `extract_funcs/baseline` 等）。
  - Change: 归档 + 文档/测试去现役门禁引用。
- [ ] Step 4: 运行并确认通过
  - Run: `ls tools/archive/reorder.py && ! ls tools/reorder.py 2>/dev/null; echo done`
  - Expected: 归档成功，原位置无文件
  - Run: `OB_CHECK_READONLY=1 bash tools/ob_check.sh`
  - Expected: 全绿（ob_check 不依赖 reorder）
- [ ] Step 5: 可选 checkpoint

> 阶段 1 收口：此时 `ob` = 入口 + §3–§7，`lib/util.sh` 就位，工具矩阵多文件化完成。`ob_check` + `run_all --full` 全绿。

### 阶段 2 · 机械搬迁（拓扑序，每步 ob_check 绿）

> 每步：把对应 § 段从 `ob` 剪切到 `lib/<name>.sh`（含前导注释），`ob` 里该段消失。函数体不动。ob 入口 glob 自动覆盖新 lib 文件，无需改入口/工具/测试。

### Task 7: 搬 §3 → lib/repo.sh

- 目标：§3（仓库与 machine 解析，含解耦后的 `require_openbmc_repo`）移到 `lib/repo.sh`。
- Files: Create `lib/repo.sh`；Modify `ob`（删 §3 段）
- 验证范围：`ob_check` + `run_all --full` 绿。
- [ ] Step 1: Run: `grep -c '# === §3' ob` → Expected: `1`
- [ ] Step 2: Run: `OB_CHECK_READONLY=1 bash tools/ob_check.sh` → Expected: 全绿
- [ ] Step 3: 建 `lib/repo.sh`（shebang + 注释头 + §3 段原样拷贝）；删 `ob` §3 段。Change: §3 搬迁。
- [ ] Step 4: Run: `bash -n lib/repo.sh && bash tools/ob_check.sh && bash tests/run_all.sh --full` → Expected: 全绿
  - Run: `! grep -q '# === §3' ob` → Expected: 通过（§3 已搬出）
- [ ] Step 5: 可选 checkpoint

### Task 8: 搬 §4 → lib/qemu.sh

- 目标：§4（QEMU，29 函数）移到 `lib/qemu.sh`。
- Files: Create `lib/qemu.sh`；Modify `ob`（删 §4 段）
- 验证范围：`ob_check` + `run_all --full` 绿（含 start/stop-qemu dryrun 覆盖 §4）。
- [ ] Step 1: Run: `grep -c '# === §4' ob` → Expected: `1`
- [ ] Step 2: Run: `OB_CHECK_READONLY=1 bash tools/ob_check.sh` → Expected: 全绿
- [ ] Step 3: 建 `lib/qemu.sh`（§4 段原样拷贝）；删 `ob` §4 段。Change: §4 搬迁。
- [ ] Step 4: Run: `bash -n lib/qemu.sh && bash tools/ob_check.sh && bash tests/run_all.sh --full` → Expected: 全绿
  - Run: `! grep -q '# === §4' ob` → Expected: 通过（§4 已搬出）
- [ ] Step 5: 可选 checkpoint

### Task 9: 搬 §5 → lib/init_pipeline.sh

- 目标：§5（init 流水线，含 `clone_openbmc`）移到 `lib/init_pipeline.sh`。
- Files: Create `lib/init_pipeline.sh`；Modify `ob`（删 §5 段）
- 验证范围：`ob_check` + `run_all --full` 绿。
- [ ] Step 1: Run: `grep -c '# === §5' ob` → Expected: `1`
- [ ] Step 2: Run: `OB_CHECK_READONLY=1 bash tools/ob_check.sh` → Expected: 全绿
- [ ] Step 3: 建 `lib/init_pipeline.sh`（§5 段原样拷贝）；删 `ob` §5 段。Change: §5 搬迁。
- [ ] Step 4: Run: `bash -n lib/init_pipeline.sh && bash tools/ob_check.sh && bash tests/run_all.sh --full` → Expected: 全绿
  - Run: `! grep -q '# === §5' ob` → Expected: 通过（§5 已搬出）
- [ ] Step 5: 可选 checkpoint

### Task 10: 搬 §6 → lib/commands.sh

- 目标：§6（cmd_* 编排，exit seam）移到 `lib/commands.sh`。
- Files: Create `lib/commands.sh`；Modify `ob`（删 §6 段）
- 验证范围：`ob_check` + `run_all --full` 绿。
- [ ] Step 1: Run: `grep -c '# === §6' ob` → Expected: `1`
- [ ] Step 2: Run: `OB_CHECK_READONLY=1 bash tools/ob_check.sh` → Expected: 全绿
- [ ] Step 3: 建 `lib/commands.sh`（§6 段原样拷贝）；删 `ob` §6 段。Change: §6 搬迁。
- [ ] Step 4: Run: `bash -n lib/commands.sh && bash tools/ob_check.sh && bash tests/run_all.sh --full` → Expected: 全绿
  - Run: `! grep -q '# === §6' ob` → Expected: 通过（§6 已搬出）
- [ ] Step 5: 可选 checkpoint

### 阶段 3 · 收尾

### Task 11: 收尾确认 + CONTEXT.md 物化语义

- 目标：确认 `ob` 只剩 §1 + §7；更新 `CONTEXT.md` 的 `function semantic layer` 条目（物化为文件边界）。
- Files: Modify `CONTEXT.md`
- 验证范围：`ob` 无 §2–§6 残留；最终全套验证绿。

- [ ] Step 1: 写当前状态检查
  - Run: `! grep -qE '# === §[2-6]' ob && wc -l ob lib/*.sh`
  - Expected: `! grep -qE` 通过（ob 无 §2–§6 锚点）；ob 行数 ~250，lib/*.sh 行数总和约等于原 ob
- [ ] Step 2: 运行并确认当前状态
  - Run: `bash tools/ob_check.sh`
  - Expected: 全绿
- [ ] Step 3: 写最小实现
  - `CONTEXT.md` 的 `function semantic layer` 条目：从"概念性、非强制结构边界"更新为"已物化为 `lib/*.sh` 文件边界（util/repo/qemu/init_pipeline/commands），`exit_contract` Y 规则按 basename(`util.sh`) 断言"。
  - Change: CONTEXT.md 术语物化。
- [ ] Step 4: 运行并确认通过
  - Run: `grep -A2 'function semantic layer' CONTEXT.md`
  - Expected: 含"物化为 lib/\*.sh 文件边界"
  - Run: `bash tests/run_all.sh --full --integration`
  - Expected: 全绿
- [ ] Step 5: 可选 checkpoint

---

## 执行纪律

- 开始实现前，先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行，不无声跳步、不合并步、不改任务目标。Task 5（搬 §2 + source 机制）是原子操作，必须一次完成全部子动作后再验证。
- 每完成一个任务，运行该任务的 Step 4 验证；未绿不进下一任务。
- **commit 由用户决定，实施 agent 不自动 commit**（Step 5 均为可选）。回退：未 commit 用 `git restore`；已 commit 用 `git revert`。
- 遇阻塞、重复失败或计划与仓库现实不符，立即停下说明，不猜。
- 当前在 `main` 分支：开始实现前与用户确认是否新建分支。

## 最终验证

- Run: `bash tools/ob_check.sh && bash tests/run_all.sh --full --integration`
- Expected: 全绿
- Run: `! grep -qE '# === §[2-6]' ob` → Expected: 通过（ob 只剩 §1+§7）
- Run: `ls lib/*.sh` → Expected: `util.sh repo.sh qemu.sh init_pipeline.sh commands.sh` 五文件齐
- Run: `./ob --help >/dev/null && echo "ob CLI ok"` → Expected: `ob CLI ok`（行为不变）
- 修改摘要：ob 行数从 4251 降至 ~250；lib/*.sh 五文件承载 §2–§6；reorder.py 归档；exit_contract/extract_funcs/ob_check 多文件化；§3→§5 解耦；CONTEXT.md 物化语义。

## 审阅 Checkpoint

计划正文结束。请先确认这份计划；如果没问题，下一步可按计划由普通编码 agent 或人工继续执行（默认执行方，不绑定 runtime）。
