# test-qemu live 行恒显 fail/error reason + `-v` 重赋义为 live 行额外带 `code=` 实施计划

## 目标

`ob test-qemu` 千级 AR 场景下，用户不必等全部 probe 跑完就能在 live 流式行看到 fail/error 的 reason。据此调整 `-v` 语义：

1. **live 行 fail/error 恒带 reason**（原来只有 `-v` 才带）。
2. **`-v` 重赋义**：live 行 fail/error 额外带 `code=`（原来额外带的是 reason）。
3. **收尾逐条行不变**：fail/error 行恒保留 `code=` + reason（现状已如此，不动）。

## 架构快照

- live 行生成：`runner/report.py` 的 `live_line(record, verbose)`（runner.py 两处调用，stderr 流式）。
- 收尾逐条行：`report.py` `run_report()`，`compact_rows=True` 只跳过 pass/skip，fail/error 行带 `code=` + reason——本次不动。
- 双副本约定：`tests/baseline/romulus/runner/` 与 `contexts/baseline/b865g8-a2-bytedance/runner/` 的 `report.py`/`runner.py` 当前逐字节一致（已 diff 验证），改完必须重新一致。
- `-v` 透传链：`ob test-qemu -v` → `lib/qemu_commands.sh` `cmd_test_qemu` → `run.sh -v` → `runner.py` `opts["verbose"]` → `live_line(rec, verbose)`。链路各点不动结构，只改文案与 `live_line` 内部。
- reason 一行化恒走 `oneline()`（转字符串 + 换行替空格 + 截断 120），本次不引入新格式化路径。

## 全局约束

- live 行格式仍满足"每条 AR 恒一行"（reason 经 `oneline` 已保证）。
- 收尾 fail/error 行格式 `'  {:<14} {} | code={} | {}'` 逐字不动（`test_qemu_runner.sh:185` 断言依赖）。
- skip live 行行为不动：恒带 `reason [source]`，与 `-v` 无关。
- `code` 为 `None` 或缺失时，`-v` 的 live 行省略 `code=` 段（不打印 `code=None`）。
- `ob`/`lib/*.sh` 改动后必跑 `tools/ob_check.sh`。
- exit 契约不动：0/1/3 语义与文案原样。

## 新 live 行格式（fail/error）

- 不加 `-v`：`  <AR 补齐 14> fail <reason oneline 摘要>`、`  <AR> error <reason>`
- 加 `-v` 且 code 非 None：`  <AR> fail code=401 <reason>`
- 加 `-v` 且 code 为 None/缺失：同不加 `-v`（`code=` 段省略）
- pass 行、skip 行：格式不变

## 文件结构与职责

| 文件 | 动作 | 职责 |
|---|---|---|
| `tests/baseline/romulus/runner/report.py` | 修改 | `live_line` 逻辑：reason 恒显、`-v` 加 code |
| `tests/baseline/romulus/runner/runner.py` | 修改 | USAGE 里 `-v` 帮助文案 |
| `contexts/baseline/b865g8-a2-bytedance/runner/report.py` | 同步 | 与 romulus 副本逐字节一致 |
| `contexts/baseline/b865g8-a2-bytedance/runner/runner.py` | 同步 | 同上 |
| `tests/unit/test_qemu_runner.sh` | 修改 | 流式 UX 断言 + `live_line` 直调断言 + 相关注释 |
| `lib/qemu_commands.sh` | 修改 | `test_qemu_usage` 的 `-v` 帮助文案 |

## 任务清单

### Task 1: romulus `report.py` `live_line` 改造

修改 `tests/baseline/romulus/runner/report.py` `live_line()`：

- 现状（`report.py:48-50`）：
  ```python
  if verbose and st in ("fail", "error"):
      st += " " + oneline(record.get("reason", ""))
  return "  {:<14} {}".format(ar, st)
  ```
- 改为：fail/error 恒追加 reason；`verbose=1` 且 `record.get("code")` 非 None 时，在 reason 前插入 ` code=<code>`：
  ```python
  if st in ("fail", "error"):
      if verbose:
          code = record.get("code")
          if code is not None:
              st += " code={}".format(code)
      st += " " + oneline(record.get("reason", ""))
  ```
- 同步更新 `live_line` docstring：fail/error 行恒带 reason；`-v` 额外带 `code=`（skip 行恒带 reason `[source]`，与 `-v` 无关）。

验证（直调，注意 `_py` 是测试内 helper，此处直接用 python3）：

```bash
cd /bmc/iasi/ob-harness/tests/baseline/romulus/runner && python3 - <<'PY'
import sys; sys.path.insert(0, ".")
import report
ll = report.live_line({"ar": "A", "status": "fail", "reason": "boom", "code": 401}, 0)
assert ll == "  A              fail boom", ll
ll = report.live_line({"ar": "A", "status": "fail", "reason": "boom", "code": 401}, 1)
assert ll == "  A              fail code=401 boom", ll
ll = report.live_line({"ar": "A", "status": "error", "reason": "x", "code": None}, 1)
assert ll == "  A              error x", ll
ll = report.live_line({"ar": "A", "status": "fail", "reason": "boom"}, 1)
assert ll == "  A              fail boom", ll
ll = report.live_line({"ar": "A", "status": "skip", "reason": "r", "source": "unit"}, 0)
assert ll == "  A              skip | r [unit]", ll
print("ok")
PY
```

预期输出 `ok`（python 退出码 0 作为门禁）。

### Task 2: romulus `runner.py` USAGE 文案 + 同步双副本

1. `tests/baseline/romulus/runner/runner.py` USAGE 中 `-v` 两行改为：
   ```
     -v, --verbose   per-AR live fail/error lines also carry code= when
                     available (reason is always shown; skip lines always
                     carry reason [source])
   ```
2. 同步副本：
   ```bash
   cp /bmc/iasi/ob-harness/tests/baseline/romulus/runner/report.py \
      /bmc/iasi/ob-harness/contexts/baseline/b865g8-a2-bytedance/runner/report.py
   cp /bmc/iasi/ob-harness/tests/baseline/romulus/runner/runner.py \
      /bmc/iasi/ob-harness/contexts/baseline/b865g8-a2-bytedance/runner/runner.py
   diff /bmc/iasi/ob-harness/tests/baseline/romulus/runner/report.py \
        /bmc/iasi/ob-harness/contexts/baseline/b865g8-a2-bytedance/runner/report.py
   diff /bmc/iasi/ob-harness/tests/baseline/romulus/runner/runner.py \
        /bmc/iasi/ob-harness/contexts/baseline/b865g8-a2-bytedance/runner/runner.py
   ```
   预期：两个 diff 均无输出且退出码为 0（不要写成 `! diff`——那会把门禁语义取反；需要静默门禁时用 `cmp -s`）。

### Task 3: 更新 `tests/unit/test_qemu_runner.sh`

按新语义改断言（保持验证驱动：先改测试，跑一次确认失败，再做 Task 1 前——执行顺序上本任务可与 Task 1 互换，若严格 TDD 则先做本任务并确认失败）：

1. `# 流式 UX 回归` 段注释（约 `test_qemu_runner.sh:140`）：改为 "live 行 fail/error 恒带 reason 摘要（一行化规则同 report.py 逐条行）；`-v` 额外带 `code=`；VERDICT 恒为 stdout 最后一行"。
2. 断言 3（`-v`，`test_qemu_runner.sh:158-162`）：fixture `good-fail-multiline` 的 stub payload 为 `{"pass": False, "code": 500, ..., "reason": "line1\nline2 bad"}`（`test_qemu_runner.sh:85-86`），期望行改为：
   ```bash
   assert_true "verbose live line carries code + flattened reason" \
     grep -Eq '^  TEST-A[[:space:]]+fail code=500 line1 line2 bad$' <<<"$out"
   ```
3. 断言 4（不带 `-v`，`test_qemu_runner.sh:163-167`）：反转为 "non-verbose live line carries inline reason"：
   ``` bash
   assert_true "non-verbose live line carries inline reason" \
     grep -Eq '^  TEST-A[[:space:]]+fail line1 line2 bad$' <<<"$out"
   ```
4. `live_line` 直调段（`test_qemu_runner.sh:344` 起）：
   - 注释改为 "skip 裸行带 [source] / fail 恒带 reason / -v=1 额外带 code="。
   - `("fail", "reason": "boom"), 0)` 断言由 `ll.endswith("fail") and "boom" not in ll` 改为 `ll.endswith("fail boom")`。
   - 新增：`({"ar": "A", "status": "fail", "reason": "boom", "code": 401}, 1)` 断言 `ll == "  A              fail code=401 boom"`；`({"ar": "A", "status": "error", "reason": "x", "code": None}, 1)` 断言 `ll.endswith("error x")`。
   - 截断断言（`"boom\nx" * 100`，`-v=1` 无 code）期望值 `fail ` + oneline 结果——现期望 `fail ` + `"boom x" * 20`，reason 部分不变，仅确认无 code 段时仍 120 截断，原断言保留可过。
5. 断言 5（通道分工）：pass 段三条断言不动；**fail 段的 stderr live 断言（`test_qemu_runner.sh:184`）须改**——该场景 fixture 正是 `good-fail-multiline`，新语义下 live 行变为 `fail line1 line2 bad`：
   ```bash
   assert_true "live fail line is on stderr with inline reason" \
     grep -Eq '^  TEST-A[[:space:]]+fail line1 line2 bad$' "$_sstderr"
   ```
   `:185` `fail \| code=` 收尾行断言不动（收尾格式未变）。

验证：

```bash
cd /bmc/iasi/ob-harness && bash tests/unit/test_qemu_runner.sh
```

预期：全部通过（退出码 0；脚本自身 assert 即门禁）。

### Task 4: `ob test-qemu` 帮助文案

`lib/qemu_commands.sh` `test_qemu_usage` 中 `-v` 两行（约 `qemu_commands.sh:866-867`）改为：

```
  -v, --verbose    Per-AR live fail/error lines also carry code= when
                   available (reason is always shown; live status lines
                   always stream to stderr)
```

验证：

```bash
cd /bmc/iasi/ob-harness && ./ob test-qemu --help | grep -q 'also carry code= when'
```

预期：grep 命中、退出码 0（grep 门禁：文案未更新则退出码 1 判失败）。

### Task 5: 最终验证

```bash
cd /bmc/iasi/ob-harness && bash tests/run_all.sh
cd /bmc/iasi/ob-harness && bash tools/ob_check.sh
cmp -s tests/baseline/romulus/runner/report.py \
       contexts/baseline/b865g8-a2-bytedance/runner/report.py
cmp -s tests/baseline/romulus/runner/runner.py \
       contexts/baseline/b865g8-a2-bytedance/runner/runner.py
```

（`run_all.sh`/`ob_check.sh` 均不含双副本一致性检查，cmp 需显式跑——防止 Task 3 验证失败后回头改了 `report.py` 却忘记重新同步 contexts 副本。）

预期：`run_all.sh`、`ob_check.sh`、两条 `cmp -s` 退出码均为 0（`ob_check.sh` 覆盖结构/函数登记/shellcheck baseline/exit-contract/测试聚合，`lib/qemu_commands.sh` 改动后必跑；cmp 兜双副本逐字节一致）。

## 任务间接口契约

- Task 1 产出新 `live_line(record, verbose)` 行为（fail/error 恒 reason；verbose + code 非 None 加 ` code=<n>`），Task 3 的直调断言与流式断言消费该契约。
- Task 2 产出的副本同步由 Task 2 的 `diff` 和 Task 5 的两条 `cmp -s` 显式验证；`run_all.sh`/`ob_check.sh` 不覆盖该约束（protocol 测试按谱系路由只碰 romulus，副本漂移属仓库约定违规，靠显式门禁兜住）。

## 执行纪律

- 开始实现前，先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行，不无声跳步、合并步或改变任务目标。
- 每完成一个任务，运行该任务定义的验证。
- 遇到阻塞、重复失败或计划与仓库现实不符（尤其 Task 3 中 fixture stub 的 code 实际值），立即停下来说明，不要猜。
- 当前在 `main` 分支：开始实现前先向用户确认是否直接在 main 上做或切分支。
- 全部任务完成后，运行最终验证（Task 5）并输出修改摘要。

## 最终验证

Task 5 的 `tests/run_all.sh`、`tools/ob_check.sh`、两条 `cmp -s` 均退出码 0。
