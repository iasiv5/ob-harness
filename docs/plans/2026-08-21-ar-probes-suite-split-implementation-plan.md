# ar_probes.yaml 按 suite 拆分（布局 v2）实施计划

## 目标

把 per-machine baseline 的 `ar_probes.yaml` 从单巨文件升级为 **include 驱动薄顶层 + 按 suite 分片**（`ar_probes.d/<suite>.yaml`），`schema_version: 2`。动因与契约见 ADR-0025 / ADR-0027 各自的"数据布局 v2"增补节（2026-08-21）。改动范围：主仓 runner（plan.py）、主仓 romulus demo 数据、单元/协议/集成测试、baseline 仓（git root 为 `contexts/baseline/`）中 b865g8-a2-bytedance 的生成器与产物。**不保留单文件兼容层**，baseline 仓改造纳入同一任务收尾，不可用窗口归零。

## 架构快照

现状：`plan.py::load_inputs` 读单文件 → schema 门禁（`_SCHEMA_VERSIONS = (1,)`，两份 YAML 共用）→ `ars` 全量校验。runner 以 `OB_TQ_AR_PROBES` env 注入数据路径（`lib/qemu_commands.sh:1123`），该路径**保持不变**（薄顶层仍叫 `ar_probes.yaml`）。

目标布局（所有 machine 一致）：

```
<baseline-dir>/
├── ar_probes.yaml        # 薄顶层：注释头块 + schema_version: 2 + auth + include: [...]
├── ar_probes.d/          # 一 suite 一文件，每片 = 局部注释 + ars:（不重复 auth/schema_version）
└── applicability.yaml    # 布局不变，schema_version 保持 1
```

include 契约（loader 硬边界）：
- 顶层 `include:` 为相对顶层文件解析的路径列表，**条目必须是相对路径**（绝对路径条目即使仍在 baseline 目录内也 die——绝对路径使数据目录不可 relocatable，违反契约）；顶层**不允许** `ars:`（出现即 die）。
- 分片缺失 → die；include 路径越界 → die（以 `os.path.realpath` 后 `os.path.commonpath([base_real, target_real]) == base_real` 判定，**禁止字符串前缀判断**——sibling 目录如 `/tmp/base-evil/` 会误判）；分片无 `ars:` 键或 `ars` 非 list → die。
- 校验顺序：**先 schema_version 门禁，后结构契约**。旧 v1 单文件（`schema_version: 1` + 顶层 `ars:`）必须报 `bad schema_version`（而非 "top-level ars not allowed"），与 schema gate 测试矩阵一致。
- 分片 merge 后走既有 `validate_ar_ids`（跨分片 AR id 重复已覆盖）与 `resolve_status`（`depends_on` 跨 suite 合法，逻辑不变）。
- 所有 die 走既有 `die()`（stderr + exit 3，数据错不进 α truth）。

schema 门禁拆分：`ar_probes` 支持集 `{2}`（v2 include 方言），`applicability` 支持集 `{1}`（布局未变）。沿用 `type(v) is not int` 防 bool 穿透。

**顺序语义（接受的显式变化）**：v2 merge 顺序 = include 列表顺序 × 分片内原序，即 **suite-contiguous**。现状全局顺序（romulus 为 core, core, users, webui, users；b865g8 按 sheet 交错）在 v2 下**必然改变**。本计划接受该变化：AR 顺序只影响报告排列，不影响适用性判定与逐条结果。等价性门禁因此是**逐 AR 字段等价（按 AR id 对齐）+ 集合等价**，不是全局顺序逐字段等价；分片内条目保持该 suite 在原文件中的相对顺序。

## 全局约束

- **无兼容层**：plan.py 落地后只认 v2 布局；v1 单文件数据（含旧 `schema_version: 1` + 顶层 `ars:`）须 exit 3 且报 `bad schema_version`。
- **入口路径不变**：`OB_TQ_AR_PROBES` / `OB_TQ_APPL` env 注入点、`lib/qemu_commands.sh` 路由零改动。
- **exit 语义不变**：数据错 exit 3 + stderr remedy；不新增退出码。
- **判定语义零变化**：逐 AR 字段（auth、request、assert、depends_on、fields）与现状逐字段等价（硬门禁）；**全局 AR/report 顺序变为 suite-contiguous 是接受的显式变化**。
- **romulus 与 b865g8 结构一致**；未来 `ob smoke` 收编 `--suite smoke` 不在本计划范围。
- shell 测试里 heredoc/文案避免 "exit code"（带空格）字样，防 EXIT_RE 误匹配（既有坑）。
- **仓库边界**：`contexts/baseline/` 是嵌套 git 仓（git root 即 `contexts/baseline`，非 machine 子目录），b865g8-a2-bytedance 是该仓内路径；子目录改动在该仓内 commit，主仓不 track。
- **commit 时机**：baseline 仓 commit 在其等价性验证全绿后（Task 5 末），主仓 commit 在全量回归全绿后（Task 6）；不存在"只认 v2 的 runner 已提交而 b865g8 仍 v1"的已提交状态。

## 文件结构与职责

| 文件 | 动作 | 职责 |
|---|---|---|
| `tests/unit/test_qemu_runner.sh` | 修改 | include 契约负例；schema 门禁矩阵更新（含 `ar_probes.d/` 拷贝与 v1→2 tamper） |
| `tests/baseline/runner/plan.py` | 修改 | schema 门禁拆分 + include 解析与硬边界校验 |
| `tests/baseline/romulus/ar_probes.yaml` | 重写 | 薄顶层（schema_version: 2 + auth + include） |
| `tests/baseline/romulus/ar_probes.d/{core,users,webui}.yaml` | 新建 | romulus 三个 suite 分片（条目从原文件逐字搬移，分片内保持原相对顺序） |
| `tests/integration/test_qemu_baseline_e2e.sh` | 修改 | 校验段 `yaml.safe_load` 直读 `d['ars']` 改为复用 `plan.load_inputs()` |
| `tests/baseline/README.md` | 修改 | 布局说明同步 v2 |
| `contexts/baseline/b865g8-a2-bytedance/tools/gen_baseline.py` | 修改（baseline 仓） | 输出改为薄顶层 + per-suite 分片；schema_version 盖章 2 |
| `contexts/baseline/b865g8-a2-bytedance/ar_probes.yaml` + `ar_probes.d/*.yaml` | 重新生成（baseline 仓） | 生成器重跑产物 |
| `tests/protocol/test_qemu_surface.sh` / `lib/qemu_commands.sh` | 只读核对 | 确认无 v1 形态断言残留 |

接口契约：`plan(ar_probes_path, appl_path, ar_filter, suite_filter)` 签名与返回结构不变；`load_inputs` 返回 `(d, appl)` 不变，其中 `d["ars"]` 为 include merge 后的全量列表（suite-contiguous 顺序）。E2E 复用方式：`sys.path.insert(0, <runner_dir>); import plan; d, appl = plan.load_inputs(argv[2], argv[3])`，后续 `d['ars']` 用法不变。

## 任务清单

### Task 1 — 单元测试先行：include 契约负例 + schema 门禁矩阵更新

**文件**：`tests/unit/test_qemu_runner.sh`

**Step 1**：新增 include 契约负例组（沿用该文件 tmpdir + assert_true 风格，fixture 在 tmpdir 内自建完整 v2 布局——顶层 + `ar_probes.d/` 分片，作为正例基底）：
- include 指向不存在文件 → exit 3 + stderr 含 `include` 与缺失路径；
- include 路径逃出 baseline 目录（`../../etc/passwd`）→ exit 3；
- **sibling 前缀逃逸**（专抓字符串 startswith 误判 bug），写法钉死：
  ```bash
  evil="${_tmp}-evil"; mkdir -p "$evil"; cat > "$evil/x.yaml" <<<'ars: []'
  rel="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$evil/x.yaml" "$_tmp")"
  # 把 v2 正例 fixture 的 include 首项替换为 "$rel" → exit 3
  ```
  （rel 是真正的相对路径且落在 base 外，只考验 commonpath 判界，不混入绝对路径行为）；
- **绝对路径 include**：把 include 首项替换为 baseline 目录内某分片的绝对路径（路径合法、判界会放行）→ 仍须 exit 3（isabs 契约）；
- 顶层出现 `ars:` → exit 3；
- 两个分片含相同 AR id → exit 3 + `duplicate AR ID`；
- 分片缺 `ars:` 键 → exit 3；
- 顶层 `schema_version: 1` + 顶层 `ars:`（即旧 v1 单文件形态）→ exit 3 + stderr 含 `bad schema_version`（锁校验顺序：schema 先于结构契约）。

**Step 2**：schema 门禁矩阵拆分与适配：
- 拷贝改为 `cp "$_repo_data"/*.yaml "$_tmp5/" && cp -r "$_repo_data/ar_probes.d" "$_tmp5/"`（只拷顶层会在 ar_probes 侧 tamper 前就死在 include missing，测不到 gate 本体）；
- ar_probes 侧 tamper 基准 `schema_version: 2`：true / `"2"` / 99 / missing / **1（旧 v1）** → 全部 exit 3 + `bad schema_version`；
- applicability 侧基准保持 `1`：true / `"1"` / 99 / missing / 2 → exit 3 + `bad schema_version`。

**Step 3**：既有 ar_probes 侧 fixtures（heredoc 造的各临时 baseline）转为 v2 布局（顶层 `schema_version: 2` + `include:`，`ars:` 移入分片文件）；applicability 侧 fixtures 保持 `1`。**注意**：文件开头 `export OB_TQ_AR_PROBES=.../romulus/ar_probes.yaml` 默认 env 保持指向真实 romulus 不动——此时 romulus 尚未迁移（Task 2 做），且 Step 3 已把所有临时 ar_probes fixtures 转 v2，故 loader 实现前（Task 3 前）**所有 v2 fixture 相关 planner 用例 + 默认 romulus 用例均预期红**，属正常红态，Task 3 后全部转绿。

**验证**：
```bash
bash tests/unit/test_qemu_runner.sh
```
预期：失败——include 负例未过（loader 未实现）、默认 romulus 用例撞 v1 gate；记录失败清单作为 Task 3 的转绿对照。

### Task 2 — romulus 数据拆分（先于 loader，等价性验证不依赖 loader）

**文件**：`tests/baseline/romulus/ar_probes.yaml`（重写）、`tests/baseline/romulus/ar_probes.d/{core,users,webui}.yaml`（新建）

**Step 0**（改文件前先存 v1 快照，后续验证只消费它）：
```bash
_saved="$(mktemp /tmp/romulus_v1_saved.XXXXXX.yaml)" && cp tests/baseline/romulus/ar_probes.yaml "$_saved" && test -s "$_saved"
```
**Step 1**：按 suite 分组搬移（core: BMC-2-2-1 / BMC-3-15-1；users: BMC-3-1-2 / BMC-9-1-1；webui: BMC-7-7-1），条目**逐字搬移**，分片内保持原文件相对顺序；分片头放一行注释（suite 名 + 指回顶层）。
**Step 2**：顶层重写：原 1-19 行头块保留（schema 说明更新为 v2 include 方言）、`schema_version: 2`、`auth` 原样、`include: [ar_probes.d/core.yaml, ar_probes.d/users.yaml, ar_probes.d/webui.yaml]`。

**验证**（纯 yaml 比较，不依赖 loader——按 AR id 对齐的逐字段等价 + 顶层 auth 全量等价 + 明确的新顺序；`$_saved` 为 Step 0 的拆前快照，此块不再重新 copy）：
```bash
python3 - "$_saved" <<'EOF'
import sys, yaml
old_top = yaml.safe_load(open(sys.argv[1]))
old = old_top["ars"]
top = yaml.safe_load(open("tests/baseline/romulus/ar_probes.yaml"))
merged = []
for inc in top["include"]:
    merged.extend(yaml.safe_load(open("tests/baseline/romulus/" + inc))["ars"])
assert "ars" not in top, "top-level ars must be absent"
assert top["schema_version"] == 2
assert [a["ar"] for a in merged] == ["BMC-2-2-1", "BMC-3-15-1", "BMC-3-1-2", "BMC-9-1-1", "BMC-7-7-1"], [a["ar"] for a in merged]
assert {a["ar"]: a for a in merged} == {a["ar"]: a for a in old}, "per-AR field equality failed"
assert top["auth"] == old_top["auth"], "auth must be identical (redfish/ipmi/ssh/console 全量)"
print("OK: per-AR equal, auth equal, suite-contiguous order accepted")
EOF
```
（先完成 Step 0-2 再跑此块。）预期：输出 `OK: per-AR equal, auth equal, suite-contiguous order accepted`。

### Task 3 — plan.py 实现 v2 include 解析

**Consumes**：Task 1 的失败基线、Task 2 的已迁移 romulus。
**文件**：`tests/baseline/runner/plan.py`

**Step 1**：`_SCHEMA_VERSIONS = (1,)` 拆为 `_AR_SCHEMA_VERSIONS = (2,)`、`_APPL_SCHEMA_VERSIONS = (1,)`；`load_inputs` 门禁循环按文档用各自集合（bool 防穿透注释原样保留并补一句两集合拆分原因）。
**Step 2**：新增 `load_ar_probes(path)`，**按以下顺序**：
1. `yaml.safe_load` 顶层 → 先走 schema_version 门禁（`_AR_SCHEMA_VERSIONS`）——保证旧 v1 单文件报 `bad schema_version` 而非结构错；
2. 顶层含 `ars` 键 → die("top-level 'ars' not allowed in v2; ARs live in ar_probes.d/<suite>.yaml fragments")；
3. `include` 必须为非空 list（缺失/非 list die）；逐项：**先 `os.path.isabs(item)` → 绝对路径条目直接 die**（可 relocatable 契约）→ 相对 `os.path.dirname(os.path.abspath(path))` 解析 → `os.path.realpath` 后以 `os.path.commonpath([base_real, target_real]) == base_real` 判界（禁止 startswith）→ 文件可读 → `yaml.safe_load` 后须有 `ars` 且为 list → 按文件顺序（文件内保持原序）拼接；
4. 返回 `{"schema_version": ..., "auth": ..., "ars": merged}`。
`load_inputs` 改调它；异常统一走既有 `cannot parse baseline YAML` 或各自 `die`（exit 3）。
**Step 3**：`plan()` 与下游零改动。

**验证**：
```bash
bash tests/unit/test_qemu_runner.sh
```
预期：全部通过（含 Task 1 全部负例、更新后的 schema 矩阵、以及依赖默认 romulus env 的 dry-run 用例——此时 romulus 已是 v2）。

### Task 4 — 主仓回归面收口（含 E2E 适配）

**Step 1**：`tests/integration/test_qemu_baseline_e2e.sh` 校验段：把 `d = yaml.safe_load(open(sys.argv[2]))` 与 `appl = yaml.safe_load(open(sys.argv[3]))` 改为复用 loader（`sys.path.insert(0, runner 目录); import plan; d, appl = plan.load_inputs(sys.argv[2], sys.argv[3])`），下游 `d['ars']` 用法不动。
**Step 2**：`grep -n "ar_probes" tests/protocol/test_qemu_surface.sh lib/qemu_commands.sh` 核对无 v1 形态断言（如断言顶层 `ars:`）；有则适配。
**Step 3**：`tests/baseline/README.md` 布局小节改写为 v2（薄顶层 + `ar_probes.d/` + include 契约 + suite-contiguous 顺序说明）。
**Step 4**：静态验证（不依赖 QEMU）：
```bash
bash -n tests/integration/test_qemu_baseline_e2e.sh && bash tests/unit/test_qemu_runner.sh && bash tests/protocol/test_qemu_surface.sh
```
预期：全绿（bash -n 锁 E2E 语法未改坏；E2E 真跑属条件验证，环境可用时在 Task 6 一并跑）。

### Task 5 — baseline 仓：gen_baseline.py 改造 + 重跑 + 等价性验证 + commit

**文件**（均在 baseline 仓 `contexts/baseline/` 内的 `b865g8-a2-bytedance/` 路径下）：`tools/gen_baseline.py`、`ar_probes.yaml`、`ar_probes.d/*.yaml`

**Step 1**：生成器 `main()` 输出段改为：**输出前先 `shutil.rmtree(<out>/ar_probes.d, ignore_errors=True)` 再重建目录**（全量重建，不依赖旧目录状态——防 suite 改名/删除后旧分片残留被 `git add ar_probes.d` 带入）；按 `a["suite"]` 分组（suite 内保持 corpus 原序）；每组写 `ar_probes.d/<suite>.yaml`（首行局部注释：suite 名 + 生成来源）；顶层写 `AR_HEADER`（裁去 v1 单文件描述，补 include 方言说明）+ `schema_version: 2` + 既有 auth 块 + `include:` 列表（suite 分组顺序）。`applicability.yaml` 输出不变。
**Step 2**：备份旧产物（mktemp 防陈旧残留）→ 重跑生成 → 逐 AR 等价 + 顶层 auth 全量等价验证：
```bash
cd contexts/baseline/b865g8-a2-bytedance && _saved="$(mktemp /tmp/b865_v1_saved.XXXXXX.yaml)" && \
cp ar_probes.yaml "$_saved" && python3 tools/gen_baseline.py && python3 - "$_saved" <<'EOF'
import sys, yaml
old_top = yaml.safe_load(open(sys.argv[1]))
old = old_top["ars"]
top = yaml.safe_load(open("ar_probes.yaml"))
assert "ars" not in top and top["schema_version"] == 2
assert top["auth"] == old_top["auth"], "top-level auth must be identical"
merged = []
for inc in top["include"]:
    merged.extend(yaml.safe_load(open(inc))["ars"])
assert len(merged) == len(old) == 1366, (len(merged), len(old))
om, nm = {a["ar"]: a for a in old}, {a["ar"]: a for a in merged}
assert om.keys() == nm.keys(), "AR id set mismatch"
diff = [k for k in om if om[k] != nm[k]]
assert not diff, "per-AR field diff: %s" % diff[:5]
print("OK: 1366 ARs, auth equal, per-AR field equality (order suite-contiguous)")
EOF
```
预期：输出 `OK: 1366 ARs, auth equal, per-AR field equality (order suite-contiguous)`（suite 交错→连续的全局顺序变化已按架构快照接受；suite 内 corpus 原序保留）。
**Step 3**：主仓 loader 对 baseline 仓数据全量过一遍（回到主仓根目录执行）：
```bash
python3 - <<'EOF'
import sys
sys.path.insert(0, "tests/baseline/runner")
import plan as p
rows = p.plan("contexts/baseline/b865g8-a2-bytedance/ar_probes.yaml",
              "contexts/baseline/b865g8-a2-bytedance/applicability.yaml", None, None)
assert len(rows) == 1366, len(rows)
rf = [r for r in rows if r["method"]]
assert len(rf) == 44, len(rf)
print("OK: 1366 rows, 44 executable")
EOF
```
预期：输出 `OK: 1366 rows, 44 executable`。
**Step 4**：baseline 仓 commit（在 Step 2/3 验证绿后）：
```bash
git -C contexts/baseline add b865g8-a2-bytedance/ar_probes.yaml b865g8-a2-bytedance/ar_probes.d b865g8-a2-bytedance/tools/gen_baseline.py
git -C contexts/baseline commit -m "b865g8: ar_probes 布局 v2 按 suite 拆分 + gen_baseline.py 输出分片 (schema_version: 2, ADR-0025/0027)"
```

### Task 6 — 最终验证 + 主仓 checkpoint commit

**Step 1**：全量回归：
```bash
bash tests/unit/test_qemu_runner.sh && bash tests/protocol/test_qemu_surface.sh && bash tools/ob_check.sh
```
预期：全绿。integration E2E（`tests/integration/test_qemu_baseline_e2e.sh`）涉及 QEMU 起机，环境可用时一并跑；不可用则以 Task 4 的 `bash -n` + 以下 loader 断言为替代，并在摘要中如实注明未跑原因：
```bash
python3 - <<'EOF'
import sys
sys.path.insert(0, "tests/baseline/runner")
import plan as p
for base, n in (("tests/baseline/romulus", 5), ("contexts/baseline/b865g8-a2-bytedance", 1366)):
    rows = p.plan(base + "/ar_probes.yaml", base + "/applicability.yaml", None, None)
    assert len(rows) == n, (base, len(rows))
print("OK: both baselines load under v2")
EOF
```
**Step 2**：主仓 checkpoint commit（含 ADR 增补节与计划；在 baseline 仓已 commit、全量回归绿后）：
```bash
git add docs/adr/0025-test-qemu-baseline-fullstack-per-machine.md docs/adr/0027-baseline-runner-single-copy-in-main-repo.md docs/plans/2026-08-21-ar-probes-suite-split-implementation-plan.md tests/baseline/runner/plan.py tests/unit/test_qemu_runner.sh tests/baseline/romulus/ tests/baseline/README.md tests/integration/test_qemu_baseline_e2e.sh
git commit -m "ar_probes 布局 v2: runner include 解析 + romulus 按 suite 拆分 (schema_version: 2, ADR-0025/0027 增补)"
```

## 执行纪律

- 开始实现前，先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划再动手。
- 按任务顺序执行，不无声跳步、合并步或改变任务目标。
- 每完成一个任务，运行该任务定义的验证；验证命令以最后一段的退出码为准，不让 echo/diff 后续命令吞掉 rc。
- 遇到阻塞、重复失败或计划与仓库现实不符，立即停下说明，不要猜。
- 提交顺序与时机按全局约束"commit 时机"执行：Task 5 末 commit baseline 仓，Task 6 末 commit 主仓；两个 commit 之前各自验证必须全绿。

## 最终验证

```bash
bash tests/unit/test_qemu_runner.sh && bash tests/protocol/test_qemu_surface.sh && bash tools/ob_check.sh && bash -n tests/integration/test_qemu_baseline_e2e.sh && ! grep -n "schema_version: 1" tests/baseline/romulus/ar_probes.yaml && python3 - <<'EOF'
import sys
sys.path.insert(0, "tests/baseline/runner")
import plan as p
for base, n in (("tests/baseline/romulus", 5), ("contexts/baseline/b865g8-a2-bytedance", 1366)):
    rows = p.plan(base + "/ar_probes.yaml", base + "/applicability.yaml", None, None)
    assert len(rows) == n, (base, len(rows))
print("OK: both baselines load under v2")
EOF
```
预期：全绿 + 确认 romulus 顶层已无 v1 残留 + 双 baseline 均可被主仓 v2 loader 读取（末段 loader 断言与 Task 6 Step 1 同款，无条件执行，防只复制末段时漏掉 b865g8）；输出修改摘要（主仓与 baseline 仓各自的 commit 与文件清单）。
