# exit-契约扫描器 (exit_contract.py) 实施计划

## 目标

- 新增 `tools/exit_contract.py`：只读静态扫描器，对 `ob` 断言三条 exit 纪律不变量——**X**（exit 值契约）、**Y**（叶子工具纯度）、**Z**（exit-3 remedy 覆盖），打印逐条裁决、违反则 exit 1。
- 把扫描器接入 `tools/ob_check.sh` 作为新增静态检查步，使目前只在 CLI 边界被测试、内部 seam 背后无检查的 exit 纪律变成可检查、可回归的事实。
- 就地处理 Z 揭露的 remedy 问题（require_path 空/回溯 + direct-exit-3 诊断-only），并对全 **29 个 exit-3 行为点**（20 direct `exit 3` + 9 `require_path … 3` 调用点）完成一次性人工审核。
- 本计划**不改** ob 的业务逻辑（除补/改 remedy 行）、**不动** `tools/reorder.py`。

## 架构快照

- `ob` 整体是深模块；本计划不动它的深度，只补一条**可检查的内部 seam**。grilling 已确认「函数语义分层」(L1/L2/L3) 是概念词汇、不是结构边界：全仓 **6 个 `cmd_*` 函数**（`cmd_status` 纯展示、不含 exit；其余 5 个含 exit），**26 个含真 exit 的函数**中 5 个是 `cmd_*`、21 个非 `cmd_*`（用全套 1/2/3 词汇直接 exit）。真正承重且可静态断言的不变量是 exit **值**、**叶子纯度**、**exit-3 remedy**——与 tier 地理无关。
- 扫描器与 `tools/extract_funcs.py`、`tools/reorder.py` 同族（只读 Python 体检工具）。为避免第三份函数边界解析逻辑的内联复制，`exit_contract.py` **通过子进程调用 `extract_funcs.py` 复用其 `start-end name` 函数清单**；`extract_funcs.py` 路径与仓库根一律用 `__file__` 解析（`ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))`），保证任意 CWD 都成立。
- 三条断言：
  - **X**：每个真·bash 进程 `exit` 的字面值 ∈ {0,1,2,3}；唯一允许的非字面 exit 是 `require_path` 的 `exit "$code"`。别的字面值或别的动态 exit → fail。现状已全绿。
  - **Y（option 1，自维护，对偶式）**：一条 **FAIL 级**集合相等断言——`{§2（utility 段，由 `# === §2`/`# === §3` 锚点界定）中含真 bash exit 的函数} == EXIT_EXCEPTIONS`，`EXIT_EXCEPTIONS = {fn_quit, resolve_npm_registry, require_path}`（§2 内当前仅这 3 个真 exit，终稿评审逐字核对）。语义即「**§2 函数绝不 exit，除这 3 个例外**」——字面是 §2 表头「L3 函数绝不 exit」的可执行版。`--seed-y` 打印 §2 真exit集供确认/固化。**自动纳保**：新增 §2 纯 helper → exit 集不变 → PASS、零登记；§2 函数新长出 exit（Y 要防的失败模式）→ exit 集 ≠ 例外集 → FAIL，须有意识登进例外集。§2-scoping 避开 `status_section_*`（§6 纯展示函数，本非叶子）误报。仅在检测到 § 锚点时生效（fixture 无锚点则跳过 Y）。比维护 ~20 个叶子的大清单摩擦更低、且自动覆盖新叶子。
  - **Z**：分两种约定，强度不同——
    - **(a) require_path**（**精确，FAIL 级**）：每个 `require_path <p> <label> <remedy> <code>` 调用点，`<code>`==`3` 且 `<remedy>` 非空。label 与第 3 入参 remedy 在接口上结构分离，故可精确断言。现状 9 个调用点中 3 个缺口（空×2 + 回溯诊断×1）。
    - **(b) direct `exit 3`**（**弱守**）：硬断言该 exit 同函数内、之前有 ≥1 条非空 `error/info/warn` 字面量（捕获 totally-bare）。**关键事实（二轮评审 R2-1 实证）**：当前 ob **没有任何 totally-bare direct-exit-3**（全函数窗口复扫为 0），故 (b) 的硬 FAIL 在现状 ob 上是**空跑**——它只作**回归保险**（防止未来新加一个裸 exit 3）。direct-exit-3 的「前置消息是否真 remedy vs 纯诊断」静态无法可靠区分（二者同为非空 error/info/warn 字面量），由**一次性人工审核全部 20 个 direct-exit-3**（Task 7）+ 扫描器**软告警**（前置消息疑似纯诊断时 WARN，**不致 exit 1**，仅作人工审核提示）兜底。
    - **echo 型 remedy 块**（如 `check_ports_available` 的 `echo "Set a different port: ob start-qemu …"`）：Z(b) 不直接解析 echo 载体，但这些站点都有伴随的 `error` 行使 (b) 判绿——判绿是**对的**（确有 remedy），无需改。
- **真·bash exit 判定原语**（X/Y/Z 共用），**大小写敏感**，正则 `(?:^|[\s;\`&|])exit(?=$|[\s;)&|])(?:\s+(\S+))?`——**带尾部词界** `(?=$|[\s;)&|])`，使 `exited`/`exits`/`$bb_exit` 内的 `exit` 子串不命中（否则 `return 1 # Process exited` ob:2157 会被误判）。另排除：注释行、`sys.exit(...)`、`awk "...exit !(…)"`、echo/warn/info/error/printf 参数串里的散文 "exit"。判定规则由 Task 4 的 fixture 钉死。
- 接入点：`tools/ob_check.sh` 静态检查组（extract_funcs → reorder → shellcheck-baseline 之后、run_all 之前）新增一步。exit-contract 步只读、对 `OB_CHECK_READONLY`/`SKIP_TESTS` 两模式都安全。

## 输入工件

- 设计来源：本会话 grilling 共识 + 两轮评审（F1–F10、R2-1–R2-5）。
- 领域基线：`CONTEXT.md` 的 `exit-code 契约`、`remedy line`、`function semantic layer`。
- 已完成副作用（**不在本计划范围**）：`CONTEXT.md` 两处勘误——`function semantic layer`（概念词汇、非结构边界）、`remedy line`（智能 agent 的下一步描述、不锁死 ob、非空且向前看）。

## 文件结构与职责

- Create: `tools/exit_contract.py` — 静态 exit-契约扫描器，X/Y/Z 三断言，打印裁决 + exit 0/1；含 `--seed-y`。
- Modify: `tools/ob_check.sh` — 新增「exit-contract」检查步（静态组内，run_all 之前）。
- Modify: `ob` — 仅处理 Z 揭露的 remedy 问题（require_path 空/回溯 + direct-exit-3 诊断-only）；业务逻辑不动。
- Modify: `rules/03_WORKSPACE.md` — tools 路由表补 `exit_contract.py` 一行。
- Test: `tests/unit/exit_contract.sh` — 扫描器逻辑自测。
- 不动：`tools/reorder.py`、`tools/extract_funcs.py`（仅被子进程复用）、`tools/parse_bitbake_deps.py`。

## 任务清单

### Task 1: exit_contract.py — 函数边界复用 + 真·bash-exit 判定 + X 断言

- 目标：扫描器解析 ob 函数边界、用带尾界的真·bash-exit 原语扫描函数体，断言 X。
- Files
  - Create: `tools/exit_contract.py`
  - Modify: `rules/03_WORKSPACE.md`（tools 清单补 `exit_contract.py`）
- 验证范围：`python3 tools/exit_contract.py ob` 退出码 0、打印 X 通过；对注入 `exit 4` 的副本退出码 1、报 X 违反。

- [ ] Step 1: 写失败检查（注入违规副本，当前无扫描器）
  - Run: `sed 's/exit 3/exit 4/' ob > /tmp/ob_xfail && python3 tools/exit_contract.py /tmp/ob_xfail; echo "rc=$?"`
  - Expected: 扫描器不存在 → `can't open file`。

- [ ] Step 2: 运行并确认当前失败
  - Run: 同上
  - Expected: 无扫描器，无 X 裁决。

- [ ] Step 3: 写最小实现
  - Change: 创建 `tools/exit_contract.py`：
    1. `ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))`；`extract_funcs.py` = `os.path.join(ROOT,'tools','extract_funcs.py')`；被扫文件默认 `os.path.join(ROOT,'ob')`，也接受命令行路径。
    2. `parse_funcs(path)`：`subprocess.run(['python3', extract_funcs_path, path], capture_output=True, text=True)`，解析 stdout 中 `^\s*\d+-\s*\d+\s+\w+` 行为 `(name,start,end)`；`end` 为 `?`/None 记为「边界不明，跳过体扫描并 WARN」。
    3. 读 `path` 全文，按 `(start,end)` 切函数体。
    4. `real_bash_exits(body_lines, base_lineno) -> list[(abs_lineno, arg_token_or_None)]`：逐行 strip；跳过空行与首字符 `#` 行；跳过含 `sys.exit` 的行；跳过含 `awk` 且含 `exit` 的行；对**行首 token 是 echo/warn/info/error/printf/verbose 之一**的行跳过；剩余行用大小写敏感正则 `(?:^|[\s;\`&|])exit(?=$|[\s;)&|])(?:\s+(\S+))?` 捕获。
    5. `check_X`：真·exit 字面参数须 ∈ {'0','1','2','3'}；非字面（`"$code"`、`$rc`、bare）仅允许在 `require_path` 体内。
    6. `main(argv)`：默认跑 `check_X`，打印 `X: PASS/FAIL`+findings，非空 `sys.exit(1)`；`--seed-y` 留 Task 2。
    - 顶部 docstring 说明用途、零副作用、用法，风格对齐 extract_funcs.py。
    - 同步 `rules/03_WORKSPACE.md` 的 `### 项目与代码 → 工具脚本` 行补 `exit_contract.py`（exit 值/叶子纯度/remedy 覆盖静态断言）。

- [ ] Step 4: 运行并确认通过
  - Run: `python3 tools/exit_contract.py ob; echo "rc=$?"`
  - Expected: `X: PASS`，`rc=0`。
  - Run: `sed 's/exit 3/exit 4/' ob > /tmp/ob_xfail && python3 tools/exit_contract.py /tmp/ob_xfail; echo "rc=$?"`
  - Expected: `X: FAIL` 报 `exit 4`，`rc=1`。

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add tools/exit_contract.py rules/03_WORKSPACE.md && git commit -m "feat(tools): add exit_contract.py with X (exit-value contract)"`
  - Expected: commit 成功。

### Task 2: exit_contract.py — Y 断言（§2 对偶式自维护）+ 播种

- 目标：断言 Y——`{§2 中含真 bash exit 的函数} == EXIT_EXCEPTIONS`（§2 函数绝不 exit，除例外集）。`--seed-y` 打印 §2 真exit集供固化例外集。
- Files
  - Modify: `tools/exit_contract.py`
- 验证范围：`--seed-y` 列出 §2 真exit集（预期 3 个）；固化后 ob 上 `Y: PASS`；带 § 锚点的多行 fixture（§2 函数 exit 但不在例外集）触发 Y FAIL。

- [ ] Step 1: 写失败检查（带 § 锚点的多行 fixture：§2 函数 exit 但不在例外集）
  - Run: `printf '# === §2 util ===\nmyhelper() {\n  exit 1\n}\n# === §3 ===\n' > /tmp/ob_yfail && python3 tools/exit_contract.py /tmp/ob_yfail`
  - Expected: Y 未实现，无 `Y:` 行。

- [ ] Step 2: 运行并确认当前失败
  - Run: 同上
  - Expected: 无 Y 裁决。

- [ ] Step 3: 写最小实现
  - Change: 在 `exit_contract.py`：
    1. § 段定位：扫被扫文本找 `# === §2` 与 `# === §3` 锚点行号，界定 §2 区间；函数 def 行落其间者为 §2 函数。无锚点（fixture 无 § 标记）则 Y 跳过。
    2. `--seed-y`：打印 **§2 中含真 bash exit** 的函数名列表（供确认/固化例外集；对 ob 预期 `fn_quit, resolve_npm_registry, require_path`）。
    3. 固化模块级 `EXIT_EXCEPTIONS = {'fn_quit','resolve_npm_registry','require_path'}`（以 `--seed-y` 对 ob 的实际输出为准，人工确认这 3 个确属合理 exit）。
    4. `check_Y`：当检测到 § 锚点时，断言 `{§2 中含真 bash exit 的函数} == EXIT_EXCEPTIONS`；差额（§2 新长出 exit / 例外过期）记 FAIL，列出多出/缺失的函数名。无锚点则跳过 Y。
    5. `main` 默认跑 X+Y，分印裁决，任一 FAIL exit 1。

- [ ] Step 4: 运行并确认通过
  - Run: `python3 tools/exit_contract.py ob; echo "rc=$?"`
  - Expected: `X: PASS`、`Y: PASS`（§2 真exit集恰为 `{fn_quit, resolve_npm_registry, require_path}` == EXIT_EXCEPTIONS），`rc=0`。
  - Run: `python3 tools/exit_contract.py /tmp/ob_yfail; echo "rc=$?"`
  - Expected: `Y: FAIL`（`myhelper` 在 §2 含 exit 但不在例外集），`rc=1`。

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add tools/exit_contract.py && git commit -m "feat(tools): exit_contract.py adds Y (§2 dual self-maintenance) + --seed-y"`
  - Expected: commit 成功。

### Task 3: exit_contract.py — Z 断言（双约定，强度分级）

- 目标：断言 Z——(a) require_path 精确（第 3 入参非空、code=3）；(b) direct exit-3 弱守（同函数内向前 ≥1 非空 error/info/warn）+ 诊断疑似软告警。
- Files
  - Modify: `tools/exit_contract.py`
- 验证范围：Z 能裁决 ob；空-remedy require_path 与诊断-only direct exit-3 的 fixture 行为符合预期（前者 FAIL、后者 WARN）。

- [ ] Step 1: 写失败检查（多行 fixture：空-remedy require_path，Z 未实现）
  - Run: `printf 'r() {\n  require_path /x lab "" 3\n}\n' > /tmp/ob_zfail && python3 tools/exit_contract.py /tmp/ob_zfail`
  - Expected: Z 未实现，无 `Z:` 行。

- [ ] Step 2: 运行并确认当前失败
  - Run: 同上
  - Expected: 无 Z 裁决。

- [ ] Step 3: 写最小实现
  - Change: 加 `check_Z(funcs, path) -> (findings, warnings)`：
    1. **约定 (a) require_path（FAIL 级）**：正则扫全 ob 的 `require_path` 调用（容忍跨行/引号），取第 3 入参 `<remedy>` 与第 4 入参 `<code>`；断言 `<code>`==`3` 且 `<remedy>` 去引号去空白**非空**；否则记 FAIL。`require_path` 自身 `exit "$code"` 不单独判。
    2. **约定 (b) direct `exit 3`（FAIL 级，但现状空跑）**：对每个真·bash `exit 3`（且不在 require_path 体内），同函数内、**exit 行之前**扫 `error|info|warn\s+"..."|'...'` 字面量；若无任何非空前置消息 → 记 FAIL（totally-bare，回归用）。注意：fixture 必须把 error 与 exit 分放两行（镜像真实 ob 行规），否则单行内无「前置行」。
    3. **诊断疑似软告警（WARN，不致 exit 1）**：若 (b) 的前置消息存在但去标点后首词匹配 `Invalid|Neither|Required|Supported|This script|Error|Failed|Missing|No valid|Unable` 且不含 `Run|Provide|Use|Ensure|Define|Specify|Pass|Set|Configure|Install|Or use` → 记 WARN。启发是**尽力而为**的人工审核提示，非权威（最近前置消息可能是路径续行等噪声）。
    4. `main` 默认跑 X+Y+Z；打印 findings（FAIL）与 warnings（WARN）；findings 非空 exit 1。

- [ ] Step 4: 运行并确认通过（逻辑自洽；**以扫描器实际输出为准**，不硬编码具体行预测）
  - Run: `python3 tools/exit_contract.py ob; echo "rc=$?"`
  - Expected: `Z: FAIL`，列出 require_path 三处缺口（空×2 + `Previous step may have failed.`×1）；**direct-exit-3 的 totally-bare FAIL 清单预期为空**（R2-1：现状无 totally-bare），并打印若干诊断-only WARN；`rc=1`。（具体 WARN 站点以实际输出为准。）
  - Run: `printf 'r() {\n  require_path /x lab "" 3\n}\n' > /tmp/z1 && python3 tools/exit_contract.py /tmp/z1; echo "rc=$?"`
  - Expected: `Z: FAIL`（空 remedy），`rc=1`。
  - Run: `printf 'd() {\n  error "Run ob init first."\n  exit 3\n}\n' > /tmp/z2 && python3 tools/exit_contract.py /tmp/z2; echo "rc=$?"`
  - Expected: `Z: PASS`（无 WARN：含 `Run`），`rc=0`。

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add tools/exit_contract.py && git commit -m "feat(tools): exit_contract.py adds Z (require_path precise + direct exit-3 weak guard + diag warn)"`
  - Expected: commit 成功。

### Task 4: tests/unit/exit_contract.sh — 扫描器逻辑自测（fixture 镜像 ob 行规）

- 目标：fixture 钉死真·bash-exit 判定的假阳排除（sys.exit/awk/散文/exited 子串）与真阳捕获（exit 4/叶子 exit/空 remedy），且**全部 fixture 严格多行、一行一语句、闭合 `}` 单独成行**（镜像 ob 真实行规；单行 `f(){...}` 虽被 extract_funcs 当单行函数识别，但 Z(b) 的「前置行」模型要求 error 与 exit 分行，故统一多行避免歧义）。
- Files
  - Create: `tests/unit/exit_contract.sh`
- 验证范围：`bash tests/unit/exit_contract.sh` 全 PASS。

- [ ] Step 1: 写失败检查
  - Run: `bash tests/unit/exit_contract.sh`
  - Expected: 文件不存在 → No such file。

- [ ] Step 2: 运行并确认当前失败
  - Run: 同上
  - Expected: 缺失。

- [ ] Step 3: 写最小实现
  - Change: 创建 `tests/unit/exit_contract.sh`，沿用 `tests/unit/require_path.sh` 模式（source `../lib/ob_loader.sh`+`../lib/assert.sh`，`assert_reset` 起、`assert_summary` 止）。`mktemp -d` 建 tmp 放 fixture（用完清理）。**每个 fixture 多行、一行一语句、`}` 单独成行**。`EXIT_CONTRACT`/`OB` 解析为绝对路径（ob_loader 同源）。用 heredoc 写 fixture 保证多行。断言：
    1. **假阳排除（rc 0）**：
       ```
       fp() {
           python3 - "$x" <<'PY'
       import sys
       sys.exit(1)
       PY
           awk "BEGIN { exit !(1 < 2) }"
           echo "Ctrl+] to exit socat session"
           warn "ssh-keygen -R exited ${rc}"
           return 1
           exit 1
       }
       ```
       `assert_rc 0 "false-positive exits (sys.exit/awk/prose/exited) not counted" python3 "$EXIT_CONTRACT" "$fix"`。
    2. **X 真阳（rc 1）**：fixture `bad()` 函数体独占一行的 `exit 4`。`assert_rc 1 "exit 4 caught" python3 "$EXIT_CONTRACT" "$fix"`。
    3. **Y 真阳（rc 1）**：带 § 锚点的多行 fixture——`# === §2 util ===` / `myhelper() { exit 1 }`（`myhelper` 各自独占行、`}` 独占行）/ `# === §3 ===`。`myhelper` 在 §2 含 exit 但不在 EXIT_EXCEPTIONS。`assert_rc 1 "§2 unexpected exit caught (Y dual)" python3 "$EXIT_CONTRACT" "$fix"`。
    4. **Z 空 remedy 真阳（rc 1）**：fixture `r()` 体独占一行的 `require_path /x lab "" 3`。`assert_rc 1 "empty require_path remedy caught" python3 "$EXIT_CONTRACT" "$fix"`。
    5. **Z 有 remedy 假阳（rc 0）**：fixture `d()`，**error 与 exit 分两行**：
       ```
       d() {
           error "Run 'ob init' first."
           exit 3
       }
       ```
       `assert_rc 0 "direct exit-3 with remedy OK" python3 "$EXIT_CONTRACT" "$fix"`。
    6. **Z 诊断-only（WARN 不 FAIL，rc 0）**：fixture `e()`，error 与 exit 分两行：
       ```
       e() {
           error "Invalid URL from env"
           exit 3
       }
       ```
       `out=$(python3 "$EXIT_CONTRACT" "$fix" 2>&1); rc=$?`；`assert_rc 0 "diagnostic-only warns not fails" ...`；`assert_contains "warns on diagnostic-only" "$out" "WARN"`。
    7. **ob 裁决可观察**：`out=$(python3 "$EXIT_CONTRACT" "$OB" 2>&1)`；`assert_contains "X verdict" "$out" "X:"`；`assert_contains "Y verdict" "$out" "Y:"`；`assert_contains "Z verdict" "$out" "Z:"`（Task 6/7 前可能 Z FAIL/WARN，只断言三行可观察）。

- [ ] Step 4: 运行并确认通过
  - Run: `bash tests/unit/exit_contract.sh`
  - Expected: `PASS=N FAIL=0`。

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add tests/unit/exit_contract.sh && git commit -m "test(tools): self-test for exit_contract.py (false-positive exclusion + true-positive capture)"`
  - Expected: commit 成功。

### Task 5: tools/ob_check.sh — 接入 exit-contract 检查步

- 目标：ob_check.sh 静态检查组新增「exit-contract」步，调 `tools/exit_contract.py ob`，按 `ok/bad` 计 PASS/FAIL。
- Files
  - Modify: `tools/ob_check.sh`
- 验证范围：`OB_CHECK_SKIP_TESTS=1 tools/ob_check.sh` 出现 `✓/✗ exit-contract` 行；Task 7 后随整体 ALL GREEN。

- [ ] Step 1: 写失败检查
  - Run: `OB_CHECK_SKIP_TESTS=1 tools/ob_check.sh 2>&1 | grep -c exit-contract`
  - Expected: `0`（未接入）。

- [ ] Step 2: 运行并确认当前失败
  - Run: `OB_CHECK_SKIP_TESTS=1 tools/ob_check.sh`
  - Expected: 无 exit-contract 行。

- [ ] Step 3: 写最小实现
  - Change: 在 shellcheck-baseline 步之后、run_all 之前插入：
    ```bash
    # ── N. exit-contract(静态 X/Y/Z)──
    if python3 tools/exit_contract.py ob >/tmp/ob_check_ec.out 2>&1; then
        ok "exit-contract (X/Y/Z green)"
    else
        bad "exit-contract 违反(详 /tmp/ob_check_ec.out):"
        cat /tmp/ob_check_ec.out
    fi
    ```
    顶部固定顺序注释更新为 `extract_funcs → reorder → baseline → exit-contract → run_all`。

- [ ] Step 4: 运行并确认通过（接入生效；Z 修前仍 ✗，属预期）
  - Run: `OB_CHECK_SKIP_TESTS=1 tools/ob_check.sh`
  - Expected: 出现 `✗ exit-contract 违反`（Z require_path 缺口未修），证明接入；其余步骤维持原结果。

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add tools/ob_check.sh && git commit -m "feat(ob_check): wire exit_contract.py as new static check step"`
  - Expected: commit 成功。

### Task 6: ob — 修复 require_path 的 Z 缺口（以扫描器为权威）

- 目标：把 require_path 空/回溯 remedy 改成非空向前看，使 Z 约定 (a) 转绿。
- Files
  - Modify: `ob`（三处 `require_path` 调用点，按符号/grep 定位）
- 验证范围：扫描器 Z 不再报 require_path 违反。

- [ ] Step 1: 写失败检查（以扫描器 Z 输出为权威清单）
  - Run: `python3 tools/exit_contract.py ob 2>&1 | grep -iE 'require_path|Z:'`
  - Expected: Z FAIL，列出 require_path 三处缺口（**以扫描器实际输出为准**；预期含 local.conf 检查、setup 脚本检查、deps.json 检查）。
  - 辅助定位（引号无关，复核）：`grep -nE 'require_path .+ (""|"Previous step may have failed\.") 3' ob`。

- [ ] Step 2: 运行并确认当前失败
  - Run: 同上
  - Expected: require_path 违反（空 remedy / 回溯诊断）。

- [ ] Step 3: 写最小实现
  - Change: 三处改第 3 入参为向前看 remedy（依据被检查对象的产生来源）：
    1. local.conf 缺失（init 产生）→ `"Run 'ob init' first."`。
    2. setup 脚本缺失（init 产生）→ `"Run 'ob init' first."`。
    3. deps.json 缺失（init dep-graph 步产生）→ `Previous step may have failed.` 改 `"Run 'ob init' first."`。
    - 不改第 4 入参（保持 `3`）；不动 require_path 本体；不碰其余 6 个已非空 require_path 调用点。具体三处以 Task 6 Step 1 扫描器输出 + grep 文案重锚，不以行号为唯一契约。

- [ ] Step 4: 运行并确认通过
  - Run: `python3 tools/exit_contract.py ob 2>&1 | grep -iE 'require_path' || echo NONE`
  - Expected: `NONE`（require_path 违反清空）。**direct-exit-3 的 FAIL 清单预期为空**（R2-1：现状无 totally-bare），故此时 Z 仅余可能的诊断-only WARN（Task 7 处理）。

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add ob && git commit -m "fix(ob): fill empty/backward require_path remedy lines (Z)"`
  - Expected: commit 成功。

### Task 7: ob — direct-exit-3 一次性人工审核（扫描器为权威，不预设逐站裁决）

- 目标：对全部 20 个 direct-exit-3 做一次性人工审核，把诊断-only（无向前看 remedy）的补成 remedy；扫描器 (b) 的 totally-bare FAIL 清单保持空（回归基线）。**不硬编码任何具体站的预测裁决——一切以扫描器输出为准**（R2-1/R2-5：手写逐站预测会与扫描器实际输出冲突）。
- Files
  - Modify: `ob`（扫描器 WARN 清单 + 人工抽查认定的诊断-only 站点 + §2 表头注释）
  - Modify: `tools/reorder.py`（`titles[2]` 字符串同步，防重排时漂移；只改注释字符串，不动 `sections` 映射）
- 验证范围：`python3 tools/exit_contract.py ob` 报 `Z: PASS`（无 FAIL）；WARN 清单经人工逐条复核（修复真诊断-only、保留可接受的）。

- [ ] Step 1: 写失败检查（扫描器列 direct-exit-3 的 FAIL 与 WARN）
  - Run: `python3 tools/exit_contract.py ob 2>&1 | sed -n '/Z:/,$p'`
  - Expected: Z 段 **FAIL 清单为空**（无 totally-bare，R2-1 实证）；WARN 清单列出疑似诊断-only 的 direct-exit-3（**以实际输出为准**）。

- [ ] Step 2: 运行并确认当前失败
  - Run: 同上
  - Expected: WARN 清单 ≥0（人工审核输入）。

- [ ] Step 3: 写最小实现（人工审核，扫描器权威）
  - Change: 拿 Step 1 的 WARN 清单，逐站人工判定：
    - **确认已是向前看 remedy**（如 `Run 'ob …'`、`Ensure 'ob build' …`、`Define QB_MACHINE …`、`Set OB_QEMU_BINARY_URL, or add a line …`、`Or use --all …`、`Specify a machine …` 等）→ 不动。注意有些站点的真 remedy 在**上面一两行**而非扫描器抓到的最近行（如 `ensure_qemu_binary_community` 的 `Set OB_QEMU_BINARY_URL, or add a line …` 在路径续行 `error "  $QEMU_URL_CONFIG_FILE"` 之上）——人工读全上下文，别被扫描器的「最近行」误导。
    - **echo 型 remedy 块**（如 `check_ports_available` 的 `Set a different port: ob start-qemu …` echo 块）→ 已是合法向前看 remedy，扫描器经伴随 error 判绿、判绿正确，**不动**。
    - **真诊断-only**（只有 `Invalid/Neither/Required tool not found/…` 这类回溯诊断、无任何向前看 remedy）→ 在 exit 前补一条向前看 remedy 行（`error "…"`），遵循 CONTEXT.md `remedy line`（智能 agent 的下一步描述；非空、向前看）。候选优先级（人工定，**非预测**）：要求装工具→`Install '<tool>' on this host, then retry.`；要求 machine→`Run 'ob init <machine>' first.`；要求前置产物→`Run 'ob build' first.`。
    - 每改一点重跑扫描器，WARN 清单收窄。
    - 仅加/改 remedy 输出行，**不改 exit 码、控制流、其他业务逻辑**。
    - **§2 表头注释对齐（顺手项）**：把 ob 的 §2 表头 `# === §2 通用工具 (Utility / L3) — L3 函数绝不 exit ===` 改成 `# === §2 通用工具 (Utility / L3) — L3 函数绝不 exit（例外：fn_quit / resolve_npm_registry / require_path）===`，与对偶式 Y 强制的例外集一致；同步改 `tools/reorder.py` 的 `titles[2]` 字符串为同款，避免日后重排时把旧表头写回。

- [ ] Step 4: 运行并确认通过
  - Run: `python3 tools/exit_contract.py ob; echo "rc=$?"`
  - Expected: `X: PASS`、`Y: PASS`、`Z: PASS`（无 FAIL），`rc=0`。WARN 清单经人工逐条复核：真诊断-only 已修；其余可接受（不强制 WARN 归零，因启发有假阳）。

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add ob && git commit -m "fix(ob): forward-looking remedies for diagnostic-only direct exit-3 (Z PASS)"`
  - Expected: commit 成功。

## 已定决策

- **Y 去留（F8）**：选定 **option 1 —— 保留 Y 并自维护**；并在终稿评审建议下采用**对偶式**：`{§2 真exit函数} == EXIT_EXCEPTIONS{fn_quit, resolve_npm_registry, require_path}`（§2 函数绝不 exit，除这 3 个例外）。比维护 ~20 个叶子的大清单摩擦更低、且新增 §2 纯 helper 零登记自动纳保。详见「架构快照」Y 条与 Task 2。

## 执行纪律

- 开工前先批判性复查本计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行；Task 7 是「扫描器列 WARN → 人工逐站判定 → 重跑」循环，不无声跳步。
- **不硬编码逐站预测裁决**（R2-1/R2-5）：一切以扫描器实际输出为权威，行号/文案以 grep 重锚。
- 每完成一个任务跑该任务验证；改了 `ob` 之后按 AGENTS.md 跑 `tools/ob_check.sh` 配套自检。
- 行号会漂移，一律以函数名/文案 grep 重锚，不以行号为唯一契约。
- 遇阻塞、重复失败或计划与仓库现实不符，立即停下说明，不猜。
- 如当前在 main 且用户未明确同意，开始实现前先确认分支策略。
- 全部任务完成后跑最终验证并输出修改摘要。

## 最终验证

- Run: `python3 tools/exit_contract.py ob; echo "rc=$?"`
  - Expected: `X: PASS`/`Y: PASS`/`Z: PASS`（无 FAIL），`rc=0`。
- Run: `bash tests/unit/exit_contract.sh`
  - Expected: `PASS=N FAIL=0`。
- Run: `tools/ob_check.sh`
  - Expected: `ALL GREEN`（含 `✓ exit-contract`）。
- Run: `bash tests/run_all.sh`
  - Expected: protocol/unit/orchestration 全 ok；`exit_codes.sh`、`start_qemu_remedy.sh`、`usage_dispatch_sync.sh` 不退化。
- 人工确认（非自动断言）：Task 7 的 WARN 清单已逐条复核（真诊断-only 已补向前看 remedy；echo 型 remedy 块与已有 remedy 站点保持不动），29 个 exit-3 行为点（20 direct + 9 require_path）全覆盖。

## 审阅 Checkpoint

- 计划正文到此结束，请先审阅（Y 已定 option 1，见「已定决策」）。
- 审阅通过前不进入实现。默认执行方为普通编码 agent 或人工执行者。
