# Coverage Radar Scope 修复 + 告警落地实施计划 (F5)

## 目标

- 修 `coverage_radar.py` 的 `list_funcs()` 枚举范围，从"只 ob 入口（3 函数）"扩到"ob + lib/*.sh（~134 函数）"，恢复 ob 模块化后失效的覆盖观测价值。
- 同次给 radar 加 `--fail-if-uncovered` + `UNCOVERED` 展示能力，并把 CI coverage step 接成**告警形态**（基线 N5 = F5 后 ob+lib 口径，不阻断）——**原 F4 阶段1 整体并入本计划**，避免落一个 ob-only 临时口径。
- 修 `cross_check()` 静默丢弃 out-of-scope 声明的根因（matrix 声明但不在 radar 全集的 typo/过期名不再隐身）。
- 同步 SDD 文档面（`bestpractice_08` / `coverage_matrix` / docstring / OBSERVATIONS）。
- 本计划是 **F4 阶段2 阻断门禁的硬前置**；F4 仅留阶段2（阻断升级，待 F5 后议）。

## 架构快照

- **根因（实跑坐实）**：`list_funcs()` 只 `extract_funcs ob`（3 函数）；06-22 模块化后真实逻辑全在 lib（131 函数），radar scope 未同步。`trace_collect.sh` 的 xtrace 已透传 sourced lib（trace 含 cmd_*/require_path/read_kv_field/build_qemu_cmd 等），故**只需扩 `list_funcs` 全集、`parse_trace` 不变**。
- **方案**：`list_funcs()` 循环 `extract_funcs`（ob + sorted lib/*.sh）去重保序；加 `--fail-if-uncovered`/`UNCOVERED`；`cross_check()` 打印 out-of-scope 声明；CI coverage step 告警（N5）；不动 `extract_funcs.py` 单文件接口（`exit_contract` 复用）。
- **同名口径（实跑）**：awk 解析 ob+lib = 134 唯一函数、`uniq -d` 空，**无跨文件同名**，去重安全。

## 输入工件

- 评审 F5 + F5-3（cross_check 静默丢弃）+ F5-4（awk 同名，grep 漏数字函数名）+ 认可"F5 优先于 F4 告警版、合并避免 ob-only 临时口径"。
- 实测：radar 当前 `TOTAL 3`；awk ob+lib = 134 唯一、无同名；`cross_check` 的 `if fn in all_funcs: declared.add(fn)` 静默丢弃（`coverage_radar.py:62`）；带数字函数名 2 个（`qemu_launch_profile_resolve_ast2700_bootloaders` 等）。

## 评审决策点（交评审定）

- **D1**：cross-check 口径。A（推荐）= radar 全集 = ob+lib 去重集合；B = ob/lib 分档。建议 A。
- **D2**：文档同步。A（推荐）= 同步 `bestpractice_08`+`coverage_matrix`+docstring+OBSERVATIONS；B = 只改代码。建议 A。
- **D3**：同名去重——实测无同名（awk 134 唯一），去重口径安全，**定**。
- **D4**（新）：CI 告警是否在 F5 内接。A（推荐）= F5 Task 5 接 CI 告警（N5）；B = F5 只修 radar，CI 告警留 F4。建议 A（吸收 F4 阶段1，避免 ob-only 临时口径）。

## 文件结构与职责

- Modify：`tools/coverage_radar.py`（`import glob` + `list_funcs` 扩 + `main` 加 `--fail-if-uncovered`/`UNCOVERED` + `cross_check` 打印 out-of-scope + docstring）。
- Modify：`rules/skills/bestpractice_08-eval_gate_patterns.md`（"92 函数"表述改 ob+lib 口径）。
- Modify：`tools/coverage_matrix.md`（cross-check 口径 + 5 个 surface gate 标 `out-of-radar`）。
- Modify：`.github/workflows/ob-tests.yml`（coverage step 告警形态，基线 N5）。
- Append：`contexts/memory/OBSERVATIONS.md`（F5 观测，不改历史）。
- 不改：`tools/extract_funcs.py`、`tools/trace_collect.sh`、`README.md`（评审确认无"92 函数"残留）。

## 任务清单

### Task 1: 同名核对（awk）+ 记录改前基线

- 目标：用鲁棒的 awk 确认无跨文件同名，记录改前 `TOTAL 3`。
- Files：读 `coverage_radar.py`、`lib/*.sh`（无改动）。
- 验证范围：awk ob+lib 134 唯一、`uniq -d` 空；改前 `TOTAL 3`。

- [ ] Step 1: 改前基线
  - Run: `tools/trace_collect.sh 2>/dev/null | python3 tools/coverage_radar.py - 2>/dev/null | grep TOTAL`
  - Expected: `TOTAL 3  COVERED 2  (66%)`。
- [ ] Step 2: 同名核对（**用 awk 第3列，不用 grep**——grep `[a-z_]+$` 会漏带数字函数名，评审 F5-4）
  - Run: `for f in ob lib/*.sh; do python3 tools/extract_funcs.py "$f" 2>/dev/null; done | awk '/^[[:space:]]*[0-9]+-[[:space:]]*[0-9]+[[:space:]]+[A-Za-z_][A-Za-z0-9_]*$/ {print $3}' | sort | uniq -d`
  - Expected: 空（无同名）。若非空，记录并在 D3 决策。
- [ ] Step 3: 无代码改动。
- [ ] Step 4: 确认同名清单空 + 改前基线已记录。

### Task 2: list_funcs 扩 ob+lib + 加 --fail-if-uncovered/UNCOVERED + docstring

- 目标：radar 全集扩 ob+lib，加退出码语义与 UNCOVERED 展示。
- Files：Modify `tools/coverage_radar.py`（顶部 `import glob` + `list_funcs` + `main` + docstring）。
- 验证范围：新 `TOTAL` ≈ 134、`COVERED` 上升、`UNCOVERED N5`；构造 trace 验证退出码。

- [ ] Step 1: 写失败检查——list_funcs 只 extract ob 且无 --fail-if-uncovered
  - Run: `grep -nE 'OB =|fail-if-uncovered|import glob' tools/coverage_radar.py`
  - Expected: 看到 `OB = REPO / "ob"`；无 `fail-if-uncovered`；无 `import glob`。
- [ ] Step 2: 确认现状（同上）。
- [ ] Step 3: 顶部 import 改 `import glob, re, subprocess, sys`；`list_funcs()` 替换为：
  ```python
  def list_funcs():
      """调 extract_funcs.py 拿 ob + lib/*.sh 全部函数名(单一来源;改边界判定需与 extract_funcs.py 同步)。

      ob 模块化(06-22)后真实逻辑在 lib/*.sh,radar 全集须含 lib(ob 入口仅
      parse_args/usage/main)。函数名集合去重保序——source 后同名覆盖是 ob 侧
      问题,不在 radar scope(F5 Task 1 已 awk 核对无同名)。"""
      seen, seen_set = [], set()
      files = [str(OB)] + sorted(glob.glob(str(REPO / "lib" / "*.sh")))
      for path in files:
          out = subprocess.run(
              [sys.executable, str(TOOLS / "extract_funcs.py"), path],
              capture_output=True, text=True, check=True).stdout
          for line in out.splitlines():
              m = re.match(r'\s*\d+\s*-\s*\d+\s+(\w+)', line)
              if m and m.group(1) not in seen_set:
                  seen_set.add(m.group(1)); seen.append(m.group(1))
      return seen
  ```
  `main()` 替换为（加 `--fail-if-uncovered` + `UNCOVERED` 展示）：
  ```python
  def main():
      args = sys.argv[1:]
      cross = "--cross-check" in args
      if cross:
          args = [a for a in args if a != "--cross-check"]
      fail_n = None
      filtered = []
      i = 0
      while i < len(args):
          if args[i] == "--fail-if-uncovered" and i + 1 < len(args):
              fail_n = int(args[i + 1]); i += 2
          else:
              filtered.append(args[i]); i += 1
      args = filtered
      src = args[0] if args else "-"
      text = sys.stdin.read() if src == "-" else Path(src).read_text()
      called = parse_trace(text)
      funcs = list_funcs()
      total = len(funcs)
      covered = set(f for f in funcs if f in called)
      if cross:
          cross_check(TOOLS / "coverage_matrix.md", covered, set(funcs))
          return 0
      for f in funcs:
          print(f"  {'✓' if f in called else '✗'} {f}")
      pct = 100 * len(covered) // total if total else 0
      uncovered = total - len(covered)
      print(f"\nTOTAL {total}  COVERED {len(covered)}  ({pct}%)  UNCOVERED {uncovered}")
      missing = [f for f in funcs if f not in called]
      if missing:
          print(f"\n未覆盖 ({len(missing)}):")
          for f in missing:
              print(f"  - {f}")
      if fail_n is not None and uncovered > fail_n:
          print(f"FAIL: uncovered {uncovered} > baseline {fail_n}", file=sys.stderr)
          return 1
      return 0


  if __name__ == "__main__":
      sys.exit(main())
  ```
  docstring 顶部第 4 行"枚举 ob 92 函数" → "枚举 ob + lib/*.sh 全部函数（模块化后 ob 入口 3 + lib ~131）"。
- [ ] Step 4: 跑 radar + 构造 trace 验证退出码
  - Run:
    ```bash
    tools/trace_collect.sh 2>/dev/null | python3 tools/coverage_radar.py - 2>/dev/null | tail -3
    printf '@@main@@\n@@parse_args@@\n' > /tmp/trace_min.log
    python3 tools/coverage_radar.py /tmp/trace_min.log --fail-if-uncovered 0; echo "rc_over=$?"
    ```
  - Expected: 新 `TOTAL` ≈ 134、含 `UNCOVERED N5`；`rc_over=1`。
- [ ] Step 5: checkpoint commit
  - Run: `git add tools/coverage_radar.py && git commit -m "fix(coverage): radar list_funcs 扩 ob+lib + 加 --fail-if-uncovered/UNCOVERED(F5)"`
  - Expected: commit 成功。

### Task 3: cross_check 修静默丢弃 + surface gate 标注

- 目标：`cross_check()` 打印 out-of-scope 声明（matrix 声明但不在 radar 全集），surface gate 显式标注——修"覆盖口径漂移静默化"根因（评审 F5-3）。
- Files：Modify `tools/coverage_radar.py`（`cross_check`）+ `tools/coverage_matrix.md`（surface gate 标注）。
- 验证范围：`--cross-check` 输出含 out-of-scope 段（5 个 surface gate）。

- [ ] Step 1: 写失败检查——当前 cross_check 静默丢弃
  - Run: `tools/trace_collect.sh 2>/dev/null | python3 tools/coverage_radar.py - --cross-check 2>/dev/null | grep -iE 'out-of-scope|out-of-radar' || echo "静默丢弃"`
  - Expected: `静默丢弃`（当前 `if fn in all_funcs: declared.add(fn)` 不打印 out-of-scope）。
- [ ] Step 2: 确认现状。
- [ ] Step 3: 改 `cross_check()`——收集所有声明（不过滤），分 in_scope/out_of_scope 打印
  - Change：把 `cross_check()` 里 `declared = set()` + `if fn in all_funcs: declared.add(fn)` 改为：
    ```python
    declared_all, declared = set(), set()
    for line in Path(matrix_path).read_text().splitlines():
        if not line.startswith('|') or '功能点' in line or '---' in line:
            continue
        cols = [c.strip() for c in line.split('|')]
        if len(cols) > 2:
            for fn in re.split(r'[;,]', cols[2]):
                fn = fn.strip()
                if not fn:
                    continue
                declared_all.add(fn)
                if fn in all_funcs:
                    declared.add(fn)
    out_of_scope = sorted(declared_all - all_funcs)
    if out_of_scope:
        print(f"\nmatrix 声明但不在 radar 全集({len(out_of_scope)};应为 surface gate 等刻意 out-of-radar,其它是 typo/过期名待修):")
        for f in out_of_scope:
            print(f"  - {f}")
    ```
    并在 `tools/coverage_matrix.md` 横切行（5 个 `_commands_collect_machine_state_records`/`_commands_machine_record_field`/`_commands_record_has_discovery_source`/`machine_state_records`/`_repo_machine_record_field`）备注补 `out-of-radar(surface gate 回归锁)`。
- [ ] Step 4: 跑 cross-check 确认 out-of-scope 段
  - Run: `tools/trace_collect.sh 2>/dev/null | python3 tools/coverage_radar.py - --cross-check 2>/dev/null | grep -A8 '不在 radar 全集'`
  - Expected: 输出 5 个 surface gate。
- [ ] Step 5: checkpoint commit
  - Run: `git add tools/coverage_radar.py tools/coverage_matrix.md && git commit -m "fix(coverage): cross_check 打印 out-of-scope 声明 + surface gate 标注(F5)"`
  - Expected: commit 成功。

### Task 4: 文档同步（bestpractice_08 + matrix 口径 + OBSERVATIONS）

- 目标：SDD 文档-工具一致性——无"92 函数"残留；OBSERVATIONS 加 F5 观测。
- Files：Modify `bestpractice_08-eval_gate_patterns.md`、`tools/coverage_matrix.md`；Append `OBSERVATIONS.md`。
- 验证范围：`grep '92 函数'` 无残留；OBSERVATIONS 新增 F5 条目。

- [ ] Step 1: 写失败检查——bestpractice_08 仍有"92 函数"
  - Run: `grep -rn '92 函数\|92函数' rules/ tools/ 2>/dev/null`
  - Expected: 命中 bestpractice_08（docstring 已在 Task 2 改）。
- [ ] Step 2: 确认。
- [ ] Step 3: 改 bestpractice_08 的"92 函数按五档列全自动化归属" → "ob + lib/*.sh 全部函数按五档列全自动化归属（F5 修复 radar scope：模块化后曾失效只测 ob 入口 3 函数，扩到 ob+lib ~134；cross_check 不再静默丢弃 out-of-scope 声明）"；coverage_matrix.md 顶部 cross-check 说明补"radar 全集 = ob + lib/*.sh（F5 修复后）"。
- [ ] Step 4: 核对无残留
  - Run: `grep -rn '92 函数\|92函数' rules/ tools/ 2>/dev/null || echo "无残留"`
  - Expected: `无残留`。
- [ ] Step 5: OBSERVATIONS 追加 F5 观测
  - Change：末尾加 Date: 2026-07-03 🔴 High 条目，记录：radar list_funcs 模块化后失效（只测 ob 入口 3）→ 扩 ob+lib（awk 实测 134 唯一、无同名）；trace 已透传 lib 故只扩全集；同次加 --fail-if-uncovered/UNCOVERED + CI 告警（吸收 F4 阶段1）；修 cross_check 静默丢弃 out-of-scope（typo/过期名不再隐身）；同步 bestpractice_08/coverage_matrix docstring。方法论：模块化重构必须同步依赖 ob 单文件假设的工具，否则工具静默失效——docstring 仍写旧数是漂移信号；cross_check 静默丢弃是漂移的放大器。
- [ ] Step 6: checkpoint commit
  - Run: `git add rules/skills/bestpractice_08-eval_gate_patterns.md tools/coverage_matrix.md contexts/memory/OBSERVATIONS.md && git commit -m "docs(coverage): 同步 radar scope 修复到 bestpractice_08/matrix/OBSERVATIONS(F5)"`

### Task 5: 重测 N5 + CI coverage step 告警形态（D4=A）

- 目标：CI coverage step 接告警（`--fail-if-uncovered N5 || true`），不阻断。
- Files：Modify `.github/workflows/ob-tests.yml`。
- 验证范围：本地 `rc=0`；CI coverage step ✓ 不阻断，日志含新 TOTAL/UNCOVERED。

- [ ] Step 1: F5 后基线
  - Run: `tools/trace_collect.sh 2>/dev/null | python3 tools/coverage_radar.py - 2>/dev/null | grep -E 'TOTAL|UNCOVERED'`
  - Expected: `TOTAL` ≈ 134、`UNCOVERED N5`（记录 N5）。
- [ ] Step 2: 改 CI coverage step 告警形态
  - Change：
    ```yaml
    - name: coverage radar 告警(ob+lib 口径;F5 scope 修复后;阶段1 不阻断,阶段2 阻断待 F5 稳定后议)
      run: |
        tools/trace_collect.sh | python3 tools/coverage_radar.py - --fail-if-uncovered N5 || true
    ```
    `N5` 替换 Task 5 Step 1 实测整数（以 list_funcs/cross_check/doc 全部完成后的最终实测为准，评审指出）。
- [ ] Step 3: 本地确认 rc=0
  - Run: `tools/trace_collect.sh 2>/dev/null | python3 tools/coverage_radar.py - --fail-if-uncovered N5; echo "rc=$?"`
  - Expected: `rc=0`。
- [ ] Step 4: 推分支验证 CI
  - Run: `git push -u origin <branch>` + `gh run watch` + `gh run view --log 2>/dev/null | grep -E 'TOTAL|UNCOVERED' | tail`
  - Expected: coverage step ✓（`|| true` 不阻断），日志含新 TOTAL/UNCOVERED。
- [ ] Step 5: checkpoint commit
  - Run: `git add .github/workflows/ob-tests.yml && git commit -m "ci: coverage step 告警(ob+lib 口径 N5,吸收 F4 阶段1)(F5)"`
  - Expected: commit 成功。

## 执行纪律

- F5 是 F4 阶段2 阻断的硬前置；F5 内已落地告警（吸收 F4 阶段1），F4 仅留阻断升级。
- `extract_funcs.py` 单文件接口不动（exit_contract 复用）；radar 自己 `glob lib/*.sh` 循环调。
- Task 1 同名检测必须用 awk 第3列（grep `[a-z_]+$` 漏带数字函数名，评审 F5-4，实跑漏 2 个）。
- Task 3 `cross_check` out-of-scope 打印是修"覆盖口径漂移静默化"根因，不能漏（评审 F5-3）。
- Task 4 文档同步是 scope 漂移文档面，不能漏（否则 bestpractice_08 仍说"92 函数"）。
- OBSERVATIONS 只追加新条目，不改历史。
- 若当前在 main，开始实现前先切分支。

## 最终验证

- Run: `tools/trace_collect.sh 2>/dev/null | python3 tools/coverage_radar.py - 2>/dev/null | tail -3` + `grep -rn '92 函数\|92函数' rules/ tools/ 2>/dev/null || echo 无残留` + `tools/trace_collect.sh 2>/dev/null | python3 tools/coverage_radar.py - --cross-check 2>/dev/null | grep -A8 '不在 radar 全集'`
- Expected: radar `TOTAL` ≈ 134；无"92 函数"残留；cross-check 含 out-of-scope 段（5 个 surface gate）。

## 审阅 Checkpoint

- 计划正文结束。请评审对 F5 取舍：D1（A 统一全集）/D2（A 同步文档）/D4（A F5 内接 CI 告警）；确认 F4 阶段1 吸收进 F5、F4 仅留阶段2 阻断（建议执行序：F2 → F1 → F5 → F3 试点 → F4 阶段2 待 F5 稳定后议）。
