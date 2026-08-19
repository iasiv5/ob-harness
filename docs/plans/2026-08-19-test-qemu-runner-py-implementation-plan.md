# ob test-qemu runner python 化实施计划（run.sh bash 粘合全量下沉 runner.py）

## 目标

把 `tests/baseline/romulus/runner/run.sh` 的 bash 编排（`\x1f` 帧解析、assemble argv 协议、mktemp/trap、两段内联 `python3 -c` live 行格式化）全量下沉为单一 python 入口 `runner.py`，`run.sh` 降为薄 shim。消灭 5 类已复发 bug 的结构性根因（skip 双打 / reason 双打 / E2BIG / `\uXXXX` 解码 / verbose 双打）：全部落在 bash↔python 记录边界无归属模块这一浅 seam 上。

对外可观测契约（stderr live 行、report 输出、exit 0/1/2/3、precondition 报错文案）逐字节冻结，三层现有测试原样通过是等价性主证据。

## 架构快照

```
现状:  run.sh(bash 编排) ──subprocess+argv/\x1f 帧──> plan.py / assemble.py / report.py / probe_redfish.py
目标:  run.sh(薄 shim: 双 export + exec) ──> runner.py ──in-process import──> plan / assemble / report 函数
                                                      └──subprocess(不动)──> probe_redfish.py
```

- record 以 `list[dict]` 在 runner.py 内存流转，不再有 JSONL 中转文件。
- live 行格式（含截断 120 / 换行替空格 / `[source]` 拼接）收敛为 report.py 的 `oneline()` + `live_line()`，live 行与 report 逐条行同源。
- probe_redfish.py 完全不动（rc 0/1/3 契约是 probe seam，仍走 subprocess）。

## 全局约束

- 契约冻结：stderr live 行格式（`  {:<14}` 对齐、skip 行 `skip | reason [source]`、`-v` 时 fail/error 行追加 reason、截断 120）、report stdout（`--compact-rows` 跳过 pass/skip 行、401 HINT、VERDICT 末行）、exit 0/1/2/3 语义、precondition 报错文案（含前缀 `run.sh:` 字面量——入口仍是 run.sh，不改称 runner.py）逐字节不变。
- 双 export（`PYTHONIOENCODING=utf-8` + `PYTHONUTF8=1`）保留在 run.sh shim，防御面不减（probe 子进程仍继承；runner.py 自身进程也继承）。
- `report.py` CLI 形态保留（`tests/unit/test_qemu_runner.sh:313` 以 `--results -` stdin 直调）；`plan.py` / `assemble.py` 的 `__main__` CLI 删除（全量 grep 确认无外部消费方）。
- contexts 侧 `contexts/baseline/b865g8-a2-bytedance/runner/` 完成后须与 romulus 侧的**六个运行时 runner 文件**（`run.sh runner.py plan.py assemble.py report.py probe_redfish.py`）保持逐字节相同，本计划产物同步拷贝过去（单点化 + ADR-0025 修订是另立任务，本轮不做）；custom 侧 `gen_baseline.py`/`reconcile.py` 落点私有，不参与逐字节一致性。
- 不新 ADR；更新 CONTEXT.md / tests/baseline/README.md / rules/03_WORKSPACE.md 的 runner 结构表述。
- 环境前提：bash + python3 + PyYAML（`python3 -c "import yaml"`）；shell 命令均按本仓 bash 惯例。

## 文件结构与职责

| 文件 | 动作 | 职责 |
|---|---|---|
| `tests/baseline/romulus/runner/runner.py` | 新建 | 全流程编排：argv 解析（沿用 run.sh 现有旗标集）→ precondition → in-process 调 plan → dry-run 分支 → 主循环（skip 直装 record / probe subprocess + in-process assemble）→ live 行（调 report.live_line）→ in-process 调 report → exit code |
| `tests/baseline/romulus/runner/run.sh` | 重写为 shim | shebang + 结构指针注释 + 双 export + `exec python3 "$SCRIPT_DIR/runner.py" "$@"` |
| `tests/baseline/romulus/runner/report.py` | 修改 | 新增 `oneline(value)`、`live_line(record, verbose)`；`main()` 主体抽为 `run_report(records, report_path, compact_rows) -> int` 供 import；CLI `main()` 保留（stdin `--results -` 测试消费） |
| `tests/baseline/romulus/runner/plan.py` | 修改 | `validate_and_emit` 改 `build_plan(a, st) -> dict`（返回 record dict，不再 print 帧）；新增 `plan(ar_probes, appl, ar_filter, suite_filter) -> list[dict]` 收口 env 读取与过滤；`die()` 仍 `sys.exit(3)`（runner 捕获 SystemExit）；删 `__main__` |
| `tests/baseline/romulus/runner/assemble.py` | 修改 | 三形态改函数：`assemble_record(ar, appl, source, appl_reason, rc, probe_stdout) -> dict`、`skip_record(ar, reason, source) -> dict`、`fallback_record(ar) -> dict`；`emit()` 的 `print` 移除（record 直接返回）；删 `main`/`__main__` |
| `tests/unit/test_qemu_runner.sh` | 修改（追加） | 新增函数级直调段：`oneline`/`live_line` 单测 + live 行与 report 逐条行共用 `oneline` 的不变量断言 |
| `contexts/baseline/b865g8-a2-bytedance/runner/*` | 同步 | 逐字节拷贝 romulus 侧六个运行时 runner 文件（`gen_baseline.py`/`reconcile.py` 私有不动） |
| `CONTEXT.md` / `tests/baseline/README.md` / `rules/03_WORKSPACE.md` | 修改 | runner 结构表述：`run.sh 编排 + plan.py + assemble.py` → `run.sh 薄 shim + runner.py 编排（in-process import）` |

接口契约（后续任务消费）：
- `report.oneline(value) -> str`：`str(value or "").replace("\n", " ")[:120]`
- `report.live_line(record, verbose) -> str`：skip 行 `"  {:<14} skip | {}"`（reason 经 oneline，`[source]` 有则拼接）；probe 行 `"  {:<14} {}"`（status，`verbose=1` 且 status ∈ fail/error 时追加 `" " + oneline(reason)`）。与现状 run.sh 两段内联 python 输出逐字节一致。
- `plan.plan(ar_probes, appl, ar_filter, suite_filter) -> list[dict]`：元素 `{"ar","status","method","path","body","asserts","reason","source"}`（body/asserts 为已解析对象，reason/source 为原字符串——`\x1f` 帧 + `json.dumps` 转义形态消亡）。
- `assemble.assemble_record / skip_record / fallback_record`：签名如上表，返回 record dict。
- `report.run_report(records, report_path, compact_rows) -> int`：返回 exit code（0/1/3），stdout 副作用与现状 CLI 一致。

## 任务清单

### Task 1: report.py 抽 `oneline` / `live_line` / `run_report`

改 `tests/baseline/romulus/runner/report.py`：
1. 新增模块级 `oneline(value)` 与 `live_line(record, verbose)`（契约见上），逐条行格式化处（现 L105-112 的 reason/src coerce）改调 `oneline`。
2. `main()` 的汇总+输出+exit 判定主体抽为 `run_report(records, report_path, compact_rows) -> int`；CLI `main()` 变为 `load_records` + `run_report` 薄壳，argv 契约不变。

Run:
```bash
out=$(printf '%s' '{"ar":"A","status":"pass"}' | python3 tests/baseline/romulus/runner/report.py --results -); rc=$?
test "$rc" -eq 0 && grep -q 'VERDICT: PASS' <<<"$out"
printf '%s' '' | python3 tests/baseline/romulus/runner/report.py --results - >/dev/null 2>&1; test $? -eq 3
python3 - <<'PY'
import sys; sys.path.insert(0, "tests/baseline/romulus/runner")
import report
assert report.oneline("多行\nreason") == "多行 reason"
assert report.live_line({"ar":"A","status":"skip","reason":"r","source":"unit"}, 0) == "  A              skip | r [unit]"
assert report.live_line({"ar":"A","status":"fail","reason":"boom"}, 1).endswith("fail boom")
assert report.live_line({"ar":"A","status":"fail","reason":"boom"}, 0).endswith("fail")
print("live_line ok")
PY
```
Expected: 第一条命令链退出 0（rc 归位判定 + VERDICT 锁定，不以 echo 吞 rc）；第二条 rc=3 判真（`test` 退出 0）；heredoc 输出 `live_line ok`（heredoc 内 assert 失败会使 python 非零退出，命令链整体失败）。

### Task 2: plan.py 改 `plan() -> list[dict]`，删 CLI

改 `tests/baseline/romulus/runner/plan.py`：
1. `validate_and_emit(a, st)` → `build_plan(a, st) -> dict`（校验逻辑逐行保留，返回 dict 不 print）。
2. 新增 `plan(ar_probes, appl, ar_filter, suite_filter) -> list[dict]`：现 `main()` 的 env 读取 + 过滤循环迁入，路径改参数注入；`die`/`load_inputs` 的 `sys.exit(3)` 与 stderr 文案原样保留（路径前缀文案里的 `plan.py:` 字面量不变）。
3. 删 `main()`/`__main__`。

Run:
```bash
python3 - <<'PY'
import sys; sys.path.insert(0, "tests/baseline/romulus/runner")
import plan
rows = plan.plan("tests/baseline/romulus/ar_probes.yaml", "tests/baseline/romulus/applicability.yaml", "", "")
assert rows and all(set(("ar","status","method","path","body","asserts","reason","source")) <= set(r) for r in rows)
try:
    plan.plan("/nonexistent.yaml", "tests/baseline/romulus/applicability.yaml", "", "")
    raise AssertionError("should exit 3")
except SystemExit as e:
    assert e.code == 3
print("plan ok")
PY
```
Expected: 输出 `plan ok`。

### Task 3: assemble.py 函数化，删 CLI

改 `tests/baseline/romulus/runner/assemble.py`：
1. `assemble_record(argv)` → `assemble_record(ar, appl, source, appl_reason, rc, probe_stdout) -> dict`：协议校验链逐行保留（含 rc 0/1/3 一致性判定、proto 错误 → error record）；`emit(d)` 改 `return d`。
2. `skip_record` / `fallback_record` 同改函数签名返回 dict；`reason_raw`/`source_raw` 的 `json.loads` 解码保留在 `plan()` 已产出原字符串后**不再需要**——但 skip 路径 reason/source 已是原字符串，直接透传（`\x1f` 帧转义形态消亡）。
3. 删 `main`/`__main__` 与 `import sys`（若无其他使用）。

Run:
```bash
python3 - <<'PY'
import sys; sys.path.insert(0, "tests/baseline/romulus/runner")
import assemble, json
probe = json.dumps({"pass": True, "code": 200, "body": "b", "actual": None, "reason": "", "error": False})
r = assemble.assemble_record("A", "applicable", "src", "", 0, probe)
assert r["status"] == "pass" and r["ar"] == "A"
r = assemble.assemble_record("A", "applicable", "", "", 0, "not-json")
assert r["status"] == "error"
r = assemble.skip_record("A", "不可仿真", "unit")
assert r == {"ar":"A","status":"skip","reason":"不可仿真","source":"unit","code":None,"actual":None}
r = assemble.fallback_record("A")
assert r["status"] == "error"
print("assemble ok")
PY
```
Expected: 输出 `assemble ok`。

### Task 4: 新建 runner.py + run.sh 降 shim

1. 新建 `tests/baseline/romulus/runner/runner.py`，移植 run.sh ①–④ 全流程：
   - argv 解析：`--host/--port/--user/--password/--ar/--suite/--report/--timeout/-v/--verbose/-d/--dry-run/-h/--help`，未知参数 → stderr `run.sh: unknown argument: X` + exit 2；`-h` 输出的 usage 文案从现 run.sh `usage()` 逐字迁入（`Usage: run.sh ...` 前缀字面量保留）。
   - precondition：dry-run 豁免逻辑、`--host/--port required`、凭据 argv/env 双源检查、PyYAML 检查——文案与 exit 2/3 逐字保留（含 `run.sh:` 前缀）。
   - 调 `plan.plan(...)`，包 `try/except SystemExit`：code 3 时补打 `run.sh: baseline parse/validate failed (see stderr above: ...)` 后 exit 3；0 条 AR → 三分支 remedy 文案逐字保留。
   - dry-run 分支：`dry-run: AR list + applicability (no probe)` + 逐行 `  %-14s status` 输出、exit 0。
   - 主循环：`skip/cascade_skip` → `assemble.skip_record` + live 行；`xfail/applicable` → subprocess `probe_redfish.py`（形态钉死：`subprocess.run(probe_args, stdout=subprocess.PIPE, stderr=None, text=True, encoding="utf-8", errors="replace", check=False)` —— 只捕获 stdout（与 bash `out=$(...)` 语义一致），probe stderr 自然继承到 runner stderr 不吞诊断；rc 捕获不因非零中断）→ `assemble.assemble_record`，装配自身异常（现 `_rec` 空串分支）→ `assemble.fallback_record`；未知 status → `run.sh: unknown applicability status ...` + exit 3。
   - body 传参规则写死：**body present iff plan dict 的 `body is not None`**（YAML 显式 `{}`/`""` 是合法 body，禁止 truthy 判断 `if body:`），传参时 `json.dumps(body)` 后作 `--body` 值——与现状 `plan.py` 的 `json.dumps(body) if body is not None else ""` + `run.sh` `[[ -n "$body" ]]` 语义逐字节对齐。
   - live 行经 `report.live_line(record, verbose)` 打 stderr（`print(..., file=sys.stderr, flush=True)`）。
   - 末段 `report.run_report(records, report_path, compact_rows=True)`，exit code 透传。
   - `OB_TQ_AR_PROBES/OB_TQ_APPL/OB_TQ_PROBE/OB_TQ_TIMEOUT` env 重定向语义保留。
2. 重写 `run.sh`：shebang + 指向 runner.py 的结构注释 + 双 export（论据注释改写为 probe 子进程继承 + 敌意 env 防御不减）+ `SCRIPT_DIR` 定位 + `exec python3 "$SCRIPT_DIR/runner.py" "$@"`。

Run:
```bash
bash tests/unit/test_qemu_runner.sh
```
Expected: 全部 assert 通过、`assert_summary` 无 FAIL（该文件锚 `run.sh` 顶层入口，shim 后自动穿透到 runner.py；这是重构等价性主证据）。

### Task 5: unit 测试新增 live_line 直调 + 共用不变量段

在 `tests/unit/test_qemu_runner.sh` 追加一段（沿用现有 `assert_eq`/`assert_contains`/临时目录惯例）：
1. `oneline` 截断 120、换行替换空格、非 str coerce。
2. `live_line`：skip 裸行带 `[source]`、`-v=0` fail 裸状态、`-v=1` fail 追加 reason、截断生效。
3. 共用不变量：同一 skip record 分别过 `live_line`（stderr 流）与 `run_report` 逐条行（stdout），断言两者 reason 片段一致（同源自 `oneline`，防未来分叉）。
4. probe stderr 透传：stub probe（`OB_TQ_PROBE` 重定向）向 stderr 打一行诊断标记，runner 跑完后断言该标记出现在 runner 的 stderr 捕获里（防 subprocess 形态把诊断吞掉）。
5. body 空 JSON 透传：fixture 的 POST AR 在 ar_probes.yaml 写 `body: {}`，stub probe 把收到的 `--body` argv 回显进 record reason，runner 以 `--report <tmp>.json` 跑完后从 JSON report 的 records 里断言 reason 含 `--body {}`（可观察通道走 `--report` JSON，不依赖 stderr 行——pass record 会被 `--compact-rows` 隐藏；锁 "present iff not None" 规则）。
6. 既有 report CLI stdin 用例（L313 起）保持不动继续通过。

Run:
```bash
bash tests/unit/test_qemu_runner.sh > /tmp/tq-runner.out 2>&1 && ! grep -qE '^FAIL|FAIL=[1-9]' /tmp/tq-runner.out
```
Expected: `&&` 串联退出 0——测试脚本自身成功（语法错误/import 崩溃/早退都会使其非零）**且**无失败用例（模式收紧以避开汇总行 `PASS=57 FAIL=0` 的字面 FAIL）；单次运行落文件判定。

### Task 6: protocol / integration 层回归

Run:
```bash
bash tests/protocol/test_qemu_surface.sh
bash tests/integration/test_qemu_baseline_e2e.sh
```
Expected: protocol 全过（锁 cmd 层 usage/排序快照，本计划未动 cmd 层应零影响）；integration 在 PyYAML+curl 齐备时跑 QEMU 实链路通过，环境缺前置时以 exit 77 SKIP 收场（非失败）。任一非 77 失败 → 停下按纪律报告，不猜。

### Task 7: b865g8 拷贝同步

Run:
```bash
for f in run.sh runner.py plan.py assemble.py report.py probe_redfish.py; do
  cp "tests/baseline/romulus/runner/$f" "contexts/baseline/b865g8-a2-bytedance/runner/$f"
done
for f in run.sh runner.py plan.py assemble.py report.py probe_redfish.py; do
  cmp -s "tests/baseline/romulus/runner/$f" "contexts/baseline/b865g8-a2-bytedance/runner/$f" || exit 1
done
```
Expected: 六个运行时 runner 文件逐字节一致（`cmp -s` 全过、退出 0）。**不做整目录 `diff -r`**：custom 侧 `gen_baseline.py`/`reconcile.py` 是落点私有工具，保留不动；禁删。

### Task 8: 文档同步（CONTEXT.md / README / WORKSPACE）

1. `CONTEXT.md`：ob test-qemu / runner 相关表述中 "run.sh 编排" 改为 "run.sh 薄 shim + runner.py 编排（in-process import plan/assemble/report；live 行格式同源 report.oneline/live_line）"，术语语义不变的不动。
2. `tests/baseline/README.md`：结构地图段（现 L59-64 一带）改为 5+1 件新职责描述。
3. `rules/03_WORKSPACE.md` L10：`run.sh 编排 + plan.py planner + assemble.py record 装配 + probe_redfish.py/report.py` → `run.sh 薄 shim + runner.py 编排 + plan.py/assemble.py/report.py 函数件 + probe_redfish.py`。

Run:
```bash
! grep -rn 'run.sh 编排' CONTEXT.md tests/baseline/README.md rules/03_WORKSPACE.md
grep -n 'runner.py 编排' CONTEXT.md tests/baseline/README.md rules/03_WORKSPACE.md
```
Expected: 第一条退出 0（无残留旧表述），第二条三处命中。

### Task 9: 最终验证

Run:
```bash
bash tests/unit/test_qemu_runner.sh && bash tests/protocol/test_qemu_surface.sh && tools/ob_check.sh &&
for f in run.sh runner.py plan.py assemble.py report.py probe_redfish.py; do
  cmp -s "tests/baseline/romulus/runner/$f" "contexts/baseline/b865g8-a2-bytedance/runner/$f" || exit 1
done
```
Expected: 串联全过（unit + protocol + ob_check 结构/函数登记/shellcheck baseline/测试自检 + 两落点六文件逐字节一致复验）；integration 已在 Task 6 单独判定。完成后输出修改摘要（消亡行数统计：`git diff --stat` 对比 run.sh 旧版）。

## 执行纪律

- 开始实现前，先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划再动手。
- 当前在 `main` 分支：开始实现前先征得用户同意切 feature 分支（建议 `feat/test-qemu-runner-py`）。
- 按任务顺序执行，不无声跳步、合并步或改变任务目标；每完成一个任务运行该任务定义的验证。
- 遇到阻塞、重复失败或计划与仓库现实不符，立即停下说明，不猜。
- 全部任务完成后运行最终验证并输出修改摘要。

## 最终验证

Task 9 的串联命令即最终验证；通过标准 = 三层测试 + ob_check 全绿，且六个运行时 runner 文件在两落点逐字节一致（custom 侧 `gen_baseline.py`/`reconcile.py` 落点私有，保留）。

另注：`--timeout`（及 `OB_TQ_TIMEOUT`）是 runner 私有入口参数，`ob test-qemu` cmd 层当前不透传；本计划不改变这一公开/私有分层，计划内所有旗标均按"runner 私有入口契约冻结"处理。
