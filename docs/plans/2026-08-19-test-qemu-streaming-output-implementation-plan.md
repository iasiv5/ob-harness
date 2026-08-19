# ob test-qemu 输出流式化 — 实施计划

日期：2026-08-19
状态：待用户审阅

## 目标

`ob test-qemu <machine>`（probe 深测，几十条 AR × 每条最长 10s timeout）当前在主循环全程静默、结束时由 report.py 一次性吐出全部结果，用户盯着空屏数十秒。目标 UX：

1. 测试开始时有一行明确"开始测试"信息（ob 层已有 `test-qemu: probing ...` info 行，保留）。
2. 每条 AR 完成即流式打印一行 `  <AR-id>  <status>`（现在是 `-v` 专属且走 stderr —— 转为默认行为）。
3. 汇总结论（VERDICT + counts）移到输出**最后一行**（现在在第一行）。

## 现状与根因

- `run.sh` 主循环（③段）：每条 probe 结果 append 进 `$results_file`，仅当 `VERBOSE=1`（`-v`）才向 stderr 打 `  <ar> <status>`。
- `report.py`：先打 `VERDICT: ...` 再打逐条行；`--compact-rows`（run.sh 在 `-v` 时传入）跳过 pass 行防双打。
- 结论：流式机制已存在，只是被 `-v` 门住；VERDICT 位置是 report.py 的打印顺序问题。

## 架构快照

```
ob (cmd_test_qemu, lib/qemu_commands.sh)
 └─ bash <baseline_dir>/runner/run.sh        ← 改：流式行默认开
     ├─ plan.py / probe_redfish.py / assemble.py   （不动）
     └─ python3 report.py --results ... --compact-rows   ← 改：行序、恒 compact
```

runner 是 per-machine 资产（ADR-0025），现有两份**逐字节相同**的副本，必须同步修改：

- `tests/baseline/romulus/runner/`（community，主仓 tracked）
- `contexts/baseline/b865g8-a2-bytedance/runner/`（custom，嵌套 git 仓 `contexts/baseline`，gitignored 于主仓）

## 全局约束

- 两份 runner 副本改后仍逐字节相同（`diff` 验证）；contexts 副本在其嵌套仓内 commit。
- exit-code 契约不变：run.sh/report.py 0/1/2/3 语义、`cmd_test_qemu` 的 rc 映射（lib/qemu_commands.sh:1108-1117）全部不动。
- report.py 仍输出到 stdout，run.sh 流式行仍走 stderr（保持 stdout 纯 report 语义；ob/测试均 2>&1 捕获，用户体验不受影响）。
- 流式行不得携带凭据或 response body（沿用现有 `  %-14s %s` ar+status 格式）。
- `-v` 语义收窄并保留：默认已流式，`-v` 追加效果 = 流式行带 fail/error 的 reason 摘要。usage 文案同步更新，不删 flag。
- heredoc 文案避开 "exit code"（exit+空格）字样，用 "exit-code"（EXIT_RE 不解析 heredoc 的防误匹配约束）。
- 现有测试对输出格式的断言面：unit 测试断言 exit-code 与 `No AR matched`/中文 reason 等 stderr 文案（不锁行序）；protocol 测试只锁 `Usage: ob test-qemu` 行；integration 断言 rc + JSON report（stdout 行序无关）。VERDICT 移位与流式行新增均不破坏现有断言 —— 以跑通为准。

## 文件结构与职责

| 文件 | 动作 | 职责变化 |
|---|---|---|
| `tests/baseline/romulus/runner/run.sh` | 修改 | ③段：流式行由 VERBOSE 门控改为恒打印；`-v` 时行尾追加 reason；④段：恒传 `--compact-rows`；usage 的 `-v` 文案更新 |
| `tests/baseline/romulus/runner/report.py` | 修改 | 行序：逐条行在前、VERDICT 最后（401 HINT 在 VERDICT 前）；docstring 更新 |
| `contexts/baseline/b865g8-a2-bytedance/runner/run.sh` | 修改 | 与 romulus 副本逐字节同步 |
| `contexts/baseline/b865g8-a2-bytedance/runner/report.py` | 修改 | 同上 |
| `lib/qemu_commands.sh` | 修改 | `test_qemu_usage` 的 `-v` 一行文案与新语义对齐 |
| `tests/unit/test_qemu_runner.sh` | 修改 | 新增：流式默认开 / VERDICT 末行 / `-v` reason 追加 三组断言 |

不新建文件。

## 任务清单

### Task 1 — report.py：行序重排（romulus 副本）

文件：`tests/baseline/romulus/runner/report.py`

修改 `main()`：
- 把逐条行打印循环（现 108-124 行段）移到 VERDICT 打印（现 86-88 行段）**之前**；401 HINT（现 94-101 行段）保持紧跟逐条行之后、VERDICT 之前，VERDICT 成为 stdout 最后一行输出。
- `--report` JSON 写盘逻辑位置不动（在最后，不影响 stdout）。
- 更新模块 docstring 的 Output 段描述（"per-AR rows first, VERDICT last"）。
- 同步 `--compact-rows` 的 argparse help（现 46-48 行段）与逐条行注释（现 103-107 行段）：两处仍写 "streamed live by run.sh -v"，改为 "streamed live by run.sh (always on)"，防止默认流式后文案过时。

验证（正向断言，均为"命令成功 = 通过"）：

```bash
rc=0
printf '%s\n' '{"ar":"A","status":"pass"}' '{"ar":"B","status":"fail","code":500,"reason":"bad","source":"auto"}' \
  | python3 tests/baseline/romulus/runner/report.py --results - > /tmp/tq-report.out || rc=$?
test "$rc" -eq 1                                   # α truth: 有 applicable fail
total=$(wc -l < /tmp/tq-report.out)
vline=$(grep -n '^VERDICT' /tmp/tq-report.out | head -1 | cut -d: -f1)
test "$total" -gt 1 && test "$vline" -eq "$total"  # VERDICT 行号 == 总行数 且 非唯一行
tail -1 /tmp/tq-report.out | grep -q '^VERDICT: FAIL (1 pass / 1 fail / 0 skip / 0 xfail / 0 xpass / 0 error)'
```

预期：四条全部通过（rc=1；VERDICT 在末行且前面有逐条行；末行文案精确）。

### Task 2 — run.sh：流式默认 + `-v` 收窄（romulus 副本）

文件：`tests/baseline/romulus/runner/run.sh`

修改 ③段主循环：
- skip/cascade_skip 分支：`[[ $VERBOSE -eq 1 ]] && printf ...` 改为恒 `printf '  %-14s %s\n' "$ar" "skip" >&2`。
- probe 分支：同理恒打印；`-v` 时（且 status 为 fail/error）行尾追加 reason。**reason 一行化摘要规则与 report.py 逐条行完全一致**：转字符串、换行替空格、截断 120 字符（`str(r).replace("\n"," ")[:120]` 的 bash 等价实现，在拼行的 python3 -c 内做）——保证"每条 AR 一行"契约不被换行 reason 撕裂，也不被超长 reason 冲刷。拼行仍用现有 `python3 -c 'import json,sys; ...'` 一次性取 status 与 reason，避免二次解析。
- ④段：`[[ $VERBOSE -eq 1 ]] && report_args+=(--compact-rows)` 改为恒 `report_args+=(--compact-rows)`（流式已默认，pass 行双打回归）。
- 主循环前加一行开始提示（stderr）：`echo "probing N ARs (timeout ${TIMEOUT}s per probe) — results stream below" >&2`，N 用已有 `_ar_count`。
- usage() 的 `-v` 行改为：`-v, --verbose   per-AR lines also carry fail/error reason (live status lines are always on)`。

验证：

```bash
tmp=$(mktemp -d)
cat > "$tmp/one.yaml" <<'YAML'
auth: {user: r, password: x}
ars:
  - {ar: TEST-A, name: f, probe: redfish, suite: fixture, request: {method: GET, path: /redfish/v1}, assert: [{type: status_in, value: [200]}], depends_on: [], rationale: f}
YAML
printf 'default: applicable\n' > "$tmp/appl.yaml"
# 流式默认 + 通道分离: 不加 -v, live 行只准出现在 stderr, stdout 只留 report
OB_TQ_PROBE=: OB_TQ_AR_PROBES="$tmp/one.yaml" OB_TQ_APPL="$tmp/appl.yaml" \
  bash tests/baseline/romulus/runner/run.sh --host 127.0.0.1 --port 1 --user r --password x \
  >"$tmp/stdout" 2>"$tmp/stderr"; echo "rc=$?"
grep -q "probing 1 AR" "$tmp/stderr"                 # 开始提示在 stderr
grep -Eq '^  TEST-A[[:space:]]+error' "$tmp/stderr"  # 流式行(格式 '  %-14s %s')在 stderr
! grep -Eq '^  TEST-A[[:space:]]+error$' "$tmp/stdout"  # live 行不得污染 stdout(report 的 error detail 行带 code=| 前缀, 可区分)
tail -1 "$tmp/stdout" | grep -q '^VERDICT'           # 汇总恒为 stdout 最后一行
```

注意：`OB_TQ_PROBE=:` 使实际执行为 `python3 :`（无法打开文件，rc≠0、无 stdout）→ assemble 记 error 记录、report rc=3 —— 本任务只断言输出形态与通道分工，rc=3 是预期副作用不作断言。期望：四条断言全过（第 3 条：report 的 error 行格式为 `code=...`，与 live 行 `^  AR error$` 行锚不同，通道混入可检出）。清理 `rm -rf "$tmp"`。

### Task 3 — 同步 contexts 副本 + 副本一致性

```bash
cp tests/baseline/romulus/runner/run.sh contexts/baseline/b865g8-a2-bytedance/runner/run.sh
cp tests/baseline/romulus/runner/report.py contexts/baseline/b865g8-a2-bytedance/runner/report.py
diff tests/baseline/romulus/runner/run.sh contexts/baseline/b865g8-a2-bytedance/runner/run.sh
diff tests/baseline/romulus/runner/report.py contexts/baseline/b865g8-a2-bytedance/runner/report.py
```

预期：两个 `diff` 无输出（逐字节相同）。

在嵌套仓 commit（`contexts/baseline` 自己的 git）：

```bash
git -C contexts/baseline add b865g8-a2-bytedance/runner/run.sh b865g8-a2-bytedance/runner/report.py
git -C contexts/baseline commit -m "runner: stream per-AR lines by default, VERDICT last (sync with ob-harness)"
```

### Task 4 — ob usage 文案对齐

文件：`lib/qemu_commands.sh`（`test_qemu_usage`，约 866 行）

`-v, --verbose    Print per-AR status to stderr` 改为与 run.sh usage 同义的一行，例如：

```
  -v, --verbose    Per-AR live lines also carry fail/error reason (live
                   status lines are always streamed to stderr; verdict prints last)
```

验证：

```bash
bash -c 'source lib/qemu_commands.sh; test_qemu_usage' | grep -A1 -- '-v, --verbose'
tools/ob_check.sh
```

预期：新文案出现；ob_check 全绿（结构 / 函数登记 / shellcheck baseline / 测试）。

### Task 5 — unit 测试锁行为（romulus runner）

文件：`tests/unit/test_qemu_runner.sh`

在现有 protocol-matrix fixture（`_tmp/one.yaml` + probe-stub）之后，**新增 capture helper `_run_protocol_capture`**（现有 `_run_protocol_case` 固定 `>/dev/null 2>&1` 只回 rc，拿不到流式行/tail——保留给旧断言，不动）：

```bash
_run_protocol_capture() {
  # 同 _run_protocol_case 的 fixture 注入, 但保留输出供断言: 函数 stdout 即 captured
  # output(2>&1 合并), 调用侧用 command substitution 捕获, rc 由调用侧 || rc=$? 保存。
  local mode="$1"; shift
  OB_TQ_STUB_MODE="$mode" OB_TQ_PROBE="$_tmp/probe-stub.py" \
    OB_TQ_AR_PROBES="$_tmp/one.yaml" OB_TQ_APPL="$_tmp/applicable.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x "$@" 2>&1
}
```

调用侧统一 `out=""; rc=0; out=$(_run_protocol_capture good-pass) || rc=$?`。并给 `probe-stub.py` 的 cases dict 加一个 `good-fail-multiline` mode（`good-fail` 同构，reason 改为 `"line1\nline2 bad"`，rc 1）。新增断言：

1. **流式默认**：`good-pass`（不加 `-v`）→ `grep -Eq '^  TEST-A[[:space:]]+pass$' <<<"$out"`（流式行格式为 `printf '  %-14s %s\n'`，TEST-A 右侧由 %-14s 补空格；行尾锚定防 -v 语义混入）。
2. **VERDICT 末行**：同一次输出 `tail -1` 匹配 `^VERDICT: PASS`，rc=0。
3. **`-v` 追加 reason（一行化 + 截断）**：`good-fail-multiline` + `-v` → rc=1；流式行匹配 `^  TEST-A[[:space:]]+fail ` 且**该行内**含 `line1 line2 bad`（换行被替空格）；且整个输出中不存在任何 `^  TEST-A` 行包含裸换行拼接迹象（即所有 `  TEST-A` 开头的行都以单个状态词±reason 结尾——由断言 1/3 的行锚定共同锁定）。
4. **不带 `-v` 无行内 reason**：`good-fail-multiline` 不带 `-v` → rc=1；流式行精确匹配 `^  TEST-A[[:space:]]+fail$`。
5. **通道分工（分离捕获，锁全局约束"live→stderr / report→stdout"）**：`good-pass` 不加 `-v`，直接以 `>"$stdout" 2>"$stderr"` 分离跑一次 runner（不经 capture helper）：

```bash
stdout="$_tmp/split.out"; stderr="$_tmp/split.err"; rc=0
OB_TQ_STUB_MODE=good-pass OB_TQ_PROBE="$_tmp/probe-stub.py" \
  OB_TQ_AR_PROBES="$_tmp/one.yaml" OB_TQ_APPL="$_tmp/applicable.yaml" \
  bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x >"$stdout" 2>"$stderr" || rc=$?
```

   断言：rc=0；`grep -Eq '^  TEST-A[[:space:]]+pass$' "$stderr"`（live 行在 stderr）；`! grep -q 'TEST-A' "$stdout"`（compact-rows 下 pass 不落 stdout，live 行不污染 stdout）；`tail -1 "$stdout" | grep -q '^VERDICT: PASS'`。fail 通道用断言 3 的分离版补一组：`good-fail-multiline` 不带 `-v` 分离跑 → stderr 含 `^  TEST-A[[:space:]]+fail$`，stdout 含 report 的 fail detail 行（`TEST-A[[:space:]]+fail \| code=`）且末行 VERDICT: FAIL —— 证明两通道各自完整、互不混行。

断言用已有 `assert_true` / `assert_eq`，`assert_true "..." grep -Eq ... <<<"$out"` 形式。

验证：

```bash
bash tests/unit/test_qemu_runner.sh
```

预期：新增断言全过，原有断言不回归，`assert_summary` 0 fail。

### Task 6 — 最终验证

```bash
tools/ob_check.sh
bash tests/protocol/test_qemu_surface.sh
```

预期：全绿。

真实环境手工验收（用户侧，需 running QEMU，不阻塞计划完成）：

```bash
./ob test-qemu b865g8-a2-bytedance
```

预期体感：立即看到 `test-qemu: probing ...` + `probing N ARs ...` 两行，随后逐条 `  <AR> <status>` 流出，最后一行 `VERDICT: ...`。

## 任务间接口契约

- Task 1/2 都在 romulus 副本内，Task 3 `cp` 消费其产物同步到 contexts；Task 4 文案与 Task 2 的 usage 措辞保持同义；Task 5 消费 Task 1/2 定下的输出契约：流式行格式 `  %-14s %s\n`（stderr）、`-v` 时 fail/error 行尾追加 reason、VERDICT 恒为 stdout 最后一行、`--compact-rows` 恒传。

## 执行纪律

- 开始实现前，先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行，不无声跳步、合并步或改变任务目标。
- 每完成一个任务，运行该任务定义的验证。
- 遇到阻塞、重复失败或计划与仓库现实不符，立即停下说明，不猜。
- **双仓分支确认**：主仓与 `contexts/baseline` 嵌套仓当前都在 main（嵌套仓领先 origin 1 个 commit）。开始实现前分别展示 `git status --short --branch`（主仓 + `git -C contexts/baseline status --short --branch`）并向用户确认：若主仓开 feature 分支，嵌套仓是同开分支还是经同意留在 main 提交 —— 两仓策略须都落定才动手。
- 全部任务完成后，运行最终验证并输出修改摘要。
