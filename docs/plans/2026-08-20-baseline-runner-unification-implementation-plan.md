# baseline runner 归一化实施计划

## 目标

runner 六文件（run.sh / runner.py / plan.py / probe_redfish.py / assemble.py / report.py）从 per-machine 双副本（主仓 `tests/baseline/romulus/runner/` + 子仓 `contexts/baseline/b865g8-a2-bytedance/runner/`，当前逐字节人工同步）归一为**主仓单副本** `tests/baseline/runner/`；子仓 `contexts/baseline/<machine>/` 只承载 baseline 数据（ar_probes.yaml / applicability.yaml）+ 数据生产线（gen_baseline.py / reconcile.py）。两仓耦合由 YAML 顶层 `schema_version` 字段 + plan.py 校验（不匹配 exit 3）门禁。决策记录为 ADR-0027。

`ob test-qemu <machine>` 的调用方接口（argv/env/exit code）**零变化**。

## 架构快照

- 现状：`test_qemu_resolve_baseline_dir`（lib/qemu_commands.sh:836 附近）按谱系路由出 baseline 目录，cmd 层 `bash "$_dir/runner/run.sh"` 调 per-machine runner；runner.py 默认经 `script_dir/../ar_probes.yaml` 相对定位数据（runner.py build_plan_rows），`OB_TQ_AR_PROBES` / `OB_TQ_APPL` env 已可覆盖。
- 目标：谱系路由**只路由数据目录**（语义不变，ADR-0026 保留）；runner 目录固定 `$HARNESS_ROOT/tests/baseline/runner/`；cmd 层以 env 注入数据路径（复用现有 env 钩子，runner.py 零参数化改动）。runner.py 的 `script_dir/../` 默认值保留不动（env 注入是唯一真实路径，默认值退化为无人踩的兜底）。
- schema_version：两份 YAML 顶层加 `schema_version: 1`；plan.py `load_inputs` 后校验顶层存在、为 int、∈ 支持集 `{1}`，违规 `die()` exit 3（复用既有 "数据错不进 α truth" 通道）。

## 全局约束

- exit code 契约冻结：runner 0/1/3 字面透传（cmd 层 exit-contract X）；schema_version 违规走 exit 3，不得混入 exit 1。
- 凭据链路不变：env 注入（OB_TQ_USER/OB_TQ_PASSWORD），不落 argv。
- 谱系硬路由语义（ADR-0026）不变：`test_qemu_resolve_baseline_dir` 只改消费方（返回值语义收窄为数据目录），不改函数结构、不跨谱系回退。
- heredoc 文案：改 `test_qemu_usage` 或 usage 类 heredoc 时避免 "exit code"（空格）字样，用 "exit-code"（EXIT_RE 不解析 heredoc，误匹配触发 X 违反）。
- 主仓当前在 `main`：开始实现前先向用户确认开分支（如 `feat/baseline-runner-unify`）。
- 子仓是嵌套 git 仓（git dir 在 `contexts/baseline/`）。本次改动**不用 `sync.sh` 推送**（它是全仓 `git add -A` + push，见 Task 8），改为手动精确路径 commit + push。

## 文件结构与职责

**主仓**
| 文件 | 动作 | 职责 |
|---|---|---|
| `tests/baseline/runner/`（6 文件） | git mv 自 `tests/baseline/romulus/runner/` | 共享 runner 引擎，零 machine 定制 |
| `tests/baseline/romulus/` | 只剩 ar_probes.yaml / applicability.yaml | community 数据 |
| `tests/baseline/romulus/ar_probes.yaml` + `applicability.yaml` | 顶层加 `schema_version: 1` | 数据自带版本声明 |
| `tests/baseline/runner/plan.py` | load_inputs 后加 schema_version 校验 | 唯一 schema 关卡（现 plan.py:33-36 白名单的扩展） |
| `lib/qemu_commands.sh` | cmd_test_qemu：runner 路径改共享 + export OB_TQ_AR_PROBES/OB_TQ_APPL | ob 注入数据定位 |
| `tests/unit/test_qemu_runner.sh` | RUNNER 默认路径改共享 + 测试内 export 数据 env | runner 层单测锚定新副本 |
| `tests/protocol/test_qemu_surface.sh` | fixture (7)(8) 增 cp `tests/baseline/runner/` | fake 根补齐共享 runner |
| `lib/smoke_assertions.sh:93` 附近注释、`tests/baseline/README.md` | 路径文案更新 | 文档一致性 |
| `docs/adr/0027-*.md` | 新建 | 决策记录 |
| `docs/adr/0026-*.md` | References 加一行交叉引用 | 指路 0027 |
| `CONTEXT.md` | `baseline` / `ob test-qemu` 词条补"runner 单副本、子仓纯数据"语义 | 术语表（纯语言，无实现细节） |

**子仓**（`contexts/baseline/b865g8-a2-bytedance/`，嵌套 git）
| 文件 | 动作 |
|---|---|
| `runner/` 六文件 + `__pycache__/` | 删除（不留 stub） |
| `runner/gen_baseline.py`、`runner/reconcile.py` | 移到 `tools/`，CORPUS_DEFAULT 路径不动（`--corpus` 可覆盖） |
| `ar_probes.yaml`、`applicability.yaml` | 顶层加 `schema_version: 1`（gen_baseline.py 生成路径同步盖章） |

## 任务清单

### Task 1 — ADR-0027 + 0026 交叉引用 + CONTEXT 词条

写 `docs/adr/0027-baseline-runner-single-copy-in-main-repo.md`：标题方向 "baseline runner 单副本在主仓，子仓只承载数据 + 数据生产线（schema_version 门禁耦合两仓）"。References 引 0026（路由语义不变，路由标的收窄为数据目录）、0025、0017（contexts 不随上游分发——runner 是代码必须随上游，这是单副本落主仓的根因）。Considered Options：单副本+env 注入（接受）/ 维持逐字节人工同步（拒绝：分叉风险+双写成本）/ runner 加 --data-dir（拒绝：净负债）/ 子仓留 stub run.sh（拒绝：双路径假象）。Status: accepted。

`docs/adr/0026-test-qemu-baseline-lineage-routing.md` References 段加一行：路由标的经 [ADR-0027](0027-....md) 收窄为纯数据目录（runner 单副本于 `tests/baseline/runner/`）。

`CONTEXT.md` 的 `baseline` / `ob test-qemu` 词条补充：baseline = 数据 + 适用性（per-machine，谱系路由）；runner = 共享引擎（主仓单副本）。

验证：
```bash
ls docs/adr/0027-*.md && grep -c "0027" docs/adr/0026-test-qemu-baseline-lineage-routing.md
grep -q "schema_version" docs/adr/0027-*.md
grep -q "tests/baseline/runner" CONTEXT.md && grep -q "单副本" CONTEXT.md
```
（CONTEXT 锚定新语义关键词，不 grep 泛词 "runner"——旧 per-machine 语义也含该词，会假绿。）
预期：均 exit 0。

### Task 2 — runner 六文件 git mv 到共享目录

```bash
rm -rf tests/baseline/romulus/runner/__pycache__   # 当前确实存在, 不删会被目录级 git mv 带过去
git mv tests/baseline/romulus/runner tests/baseline/runner
ls tests/baseline/romulus/   # 只剩 ar_probes.yaml applicability.yaml
```
runner.py 零改动（env 钩子即契约）。此任务后主链路暂时红（qemu_commands 还指旧路径），由 Task 4 接回——若希望每步绿，可将 2/4 合并执行，验证以 Task 4 为准。

验证：
```bash
test "$(find tests/baseline/runner -maxdepth 1 -type f | wc -l)" -eq 6
! test -d tests/baseline/runner/__pycache__
```

### Task 3 — plan.py schema_version 校验 + romulus 数据盖章

先加失败检查（临时脚本验证缺失即 exit 3），再实现。plan.py `load_inputs()` 返回后、进入既有校验前，对两份 YAML 顶层校验：

```python
_SCHEMA_VERSIONS = (1,)
# load_inputs 内或紧后:
for name, doc in (("ar_probes", d), ("applicability", appl)):
    v = doc.get("schema_version") if isinstance(doc, dict) else None
    # type(v) is not int 而非 isinstance: bool 是 int 子类, YAML 的
    # schema_version: true 会因 True == 1 被当合法版本 1, 类型约束失真
    if type(v) is not int or v not in _SCHEMA_VERSIONS:
        die("bad schema_version {!r} in {} (want one of {})".format(
            v, name, ", ".join(map(str, _SCHEMA_VERSIONS))))
```

romulus 两份 YAML 顶层各加 `schema_version: 1`（放首行注释块之后、`default:` 之前）。

验证（直调 runner，env 注入 romulus 数据）：
```bash
R=tests/baseline/runner
OB_TQ_AR_PROBES=tests/baseline/romulus/ar_probes.yaml \
OB_TQ_APPL=tests/baseline/romulus/applicability.yaml \
bash $R/run.sh --host 127.0.0.1 --port 1 --user r --password x --dry-run
# 预期 exit 0，列出 AR
tmp=$(mktemp -d) && cp tests/baseline/romulus/*.yaml $tmp/
sed -i 's/^schema_version: 1/schema_version: 99/' $tmp/ar_probes.yaml
OB_TQ_AR_PROBES=$tmp/ar_probes.yaml OB_TQ_APPL=$tmp/applicability.yaml \
bash $R/run.sh --host 127.0.0.1 --port 1 --user r --password x --dry-run
# 预期 exit 3 + stderr 含 "bad schema_version"；rm -rf $tmp
# 负测矩阵补全(两份 YAML × missing / string "1" / bool true / 99 各一):
#   sed -i 's/^schema_version: 1/schema_version: true/'  → bool, 须 exit 3
#   sed -i 's/^schema_version: 1/schema_version: "1"/'   → string, 须 exit 3
#   sed -i '/^schema_version: 1/d'                        → missing, 须 exit 3
#   applicability.yaml 单独篡改同上(ar_probes 保持合法) → exit 3
```

### Task 4 — qemu_commands.sh：共享 runner + env 注入

`cmd_test_qemu` 调用段（现 `local -a _run_args=(bash "$_dir/runner/run.sh")`，lib/qemu_commands.sh:1096 附近）改为：

- runner 路径：`local root="${HARNESS_ROOT:-$OB_ENTRY_DIR}"; local _runner="$root/tests/baseline/runner/run.sh"`（与 resolve_baseline_dir 同根锚定）
- 数据注入：调 runner 前 `export OB_TQ_AR_PROBES="$_dir/ar_probes.yaml" OB_TQ_APPL="$_dir/applicability.yaml"`（`$_dir` 仍是谱系路由结果，语义收窄为数据目录；`test_qemu_resolve_baseline_dir` 函数本体与注释中 "runner" 字样只做最小注释修正，不动结构）
- 顺带更新该段注释："调 per-machine runner" → "调共享 runner（数据 env 注入）"

注意 heredoc 约束（见全局约束）；本次不涉 usage 文案则无影响。

验证：
```bash
bash -n lib/qemu_commands.sh && echo OK
ob test-qemu romulus --dry-run   # 预期 exit 0 列 AR（无需 QEMU）
```

### Task 5 — protocol fixture 补共享 runner

`tests/protocol/test_qemu_surface.sh` fixture (7)(8)（现 141/164 行 `cp -r .../tests/baseline/romulus .../fake-m`）在各自 fake 根加一行：
```bash
cp -r "$OB_ENTRY_DIR/tests/baseline/runner" "$_tq_dry_root/tests/baseline/runner"
```
（(8) 的 `_tq_cred_root` 同理。）runner 内无 machine 数据，无需改内容。

验证：
```bash
bash tests/protocol/test_qemu_surface.sh
```
预期：exit 0，全 assert 通过，无 FAIL。（不接 `| tail -5`——pipeline rc 取 tail，测试脚本 exit 1 也会假绿。）

### Task 6 — unit 测试锚定新副本

`tests/unit/test_qemu_runner.sh:12` 默认值改为 `.../tests/baseline/runner/run.sh`；文件头注释（ADR-0025 per-machine 说法）同步修正为共享 runner 语境。每个 `bash "$RUNNER"` 调用前缀 env（或文件顶部统一 export）：
```bash
_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export OB_TQ_AR_PROBES="$_repo/tests/baseline/romulus/ar_probes.yaml"
export OB_TQ_APPL="$_repo/tests/baseline/romulus/applicability.yaml"
```
（`$_repo` 与同文件 RUNNER 行的根计算方式一致。）
OB_TQ_RUNNER env 钩子保留（未来仍可换指）。

**inline fixture 全量补 schema_version**（评审 🔴1）：本测试文件内所有覆盖 `OB_TQ_AR_PROBES` / `OB_TQ_APPL` 的临时 YAML fixture——heredoc 直写的（约 53/120/147/172/180/207/216/237-238/248-249/281/306/310/403/432/460 行等）与 Python `yaml.safe_dump(base, stream)` 生成的（274/277 行）——顶层一律加 `schema_version: 1`，否则 plan.py 新关卡会让这些用例先死于 exit 3，测不到原本的 unknown assert / method 白名单 / request 缺失 / probe 协议路径。`safe_dump` 的 `base` dict 直接加 `"schema_version": 1` 键。

**schema gate 回归锁**（评审 🟡，第三轮）：在 `test_qemu_runner.sh` 加 table-driven 负测——合法 romulus 数据为底，逐案篡改后断言 exit 3 + stderr 含 "bad schema_version"：
```bash
# 篡改矩阵: <sed 表达式> × <篡改哪份 YAML>
#   's/^schema_version: 1/schema_version: true/'    → bool(上轮真 bug: True == 1 穿透)
#   's/^schema_version: 1/schema_version: "1"/'     → string
#   's/^schema_version: 1/schema_version: 99/'      → 不支持版本
#   '/^schema_version: 1/d'                          → missing
# 各篡改分别施加于 ar_probes.yaml 与 applicability.yaml(另一份保持合法), 共 8 案
```
bool 穿透正是上一轮评审抓到的真 bug，必须进长期回归，不能停在一次性手工命令。

验证：`bash tests/unit/test_qemu_runner.sh` → 全 PASS（含新增负测）。

### Task 7 — 注释与 README 收口

- `lib/smoke_assertions.sh:93` 附近注释中 romulus runner 旧路径改共享路径
- **romulus `ar_probes.yaml` 头部路径更新**（评审 🟡，第三轮）：第 4 行 `tests/baseline/romulus/runner/probe_redfish.py` → `tests/baseline/runner/probe_redfish.py`（不更新则下方 grep 验证必红——我已核实该行现存）
- `tests/baseline/README.md`：目录结构说明改为 runner 共享 + per-machine 数据；接入新 machine 指引改为"只建数据目录"
- **runner 六文件头部文案收口**（评审 🟡）：`run.sh` / `runner.py` / `plan.py` / `probe_redfish.py` / `assemble.py` / `report.py` 的 docstring/头注释去掉 "romulus baseline runner" / "Per-machine (ADR-0025: ... ships its own engine)" 归属表述，改为共享 runner 语境（引 ADR-0027，机器差异只在数据 YAML）。保持"零参数化/逻辑改动"——只动文案。

验证：
```bash
! grep -rn "baseline/romulus/runner" lib/ tests/unit/ tests/protocol/ tests/baseline/ README.md CONTEXT.md
```
预期：无命中（`!` 取反为 0）。历史 ADR（docs/adr/）的旧状态描述不在清理范围——ADR 是决策史不改写，只要求 0027 交叉引用到位。

### Task 8 — 子仓 b865g8 清理 + 盖章 + 同步

全部命令**从主仓根执行**（`tools/` 目录当前不存在，先建）：
1. `mkdir -p contexts/baseline/b865g8-a2-bytedance/tools`
2. 删除 runner 六文件：`git -C contexts/baseline rm b865g8-a2-bytedance/runner/{run.sh,runner.py,plan.py,probe_redfish.py,assemble.py,report.py}`（`git rm` 直接删工作区+索引，不用 `--cached`+手动删）
3. `rm -rf contexts/baseline/b865g8-a2-bytedance/runner/__pycache__`
4. `git -C contexts/baseline mv b865g8-a2-bytedance/runner/gen_baseline.py b865g8-a2-bytedance/tools/gen_baseline.py`、`git -C contexts/baseline mv b865g8-a2-bytedance/runner/reconcile.py b865g8-a2-bytedance/tools/reconcile.py`（`runner/` 目录随之消亡）
5. ar_probes.yaml / applicability.yaml 顶层加 `schema_version: 1`；**头部旧路径文案同步更新**（评审 🟡，第三轮）：现有 YAML 头部 `生成: runner/gen_baseline.py`、`runner/probe_redfish.py` 字样改为 `tools/gen_baseline.py` 与主仓共享 runner 路径（`--out "$tmp"` 验证不回写现有 YAML，不改则头部永久陈旧）
6. `tools/gen_baseline.py` 生成输出顶层盖 `schema_version: 1`（写入两份 YAML 的 dump 前置字段；`--out` 缺省 = `dirname(dirname(__file__))`，移到 tools/ 后仍落 machine 目录，无需参数化）
7. **旧路径文案收口**（评审 🟡）：`tools/gen_baseline.py` docstring usage（`python3 runner/gen_baseline.py` → `python3 tools/gen_baseline.py`）与 `AR_HEADER` / `APPL_HEADER` 内写回 YAML 的路径说明（`runner/gen_baseline.py`、`runner/probe_redfish.py` 字样）同步更新为 tools/ 与主仓共享 runner 路径；`tools/reconcile.py` usage 同理
8. 子仓 commit + push：**不用 `sync.sh`**（评审 🟡：`sync.sh:36-54` 是全仓 `git add -A` + commit + push，子仓其它路径若有 dirty 会被一起推走），但**保留它的两个安全 gate**（评审 🔴，第三轮——本仓含 auth 凭据，remote 写错的外推后果重于普通代码仓）。push 前必须过：
   ```bash
   # gate 1: remote 指向防呆(等价 sync.sh:19-28)
   test "$(git -C contexts/baseline remote get-url origin)" = "git@github.com:iasiv5/baseline.git"
   # gate 2: 远仓可达性早暴露(等价 sync.sh:30-33)
   git -C contexts/baseline ls-remote origin >/dev/null
   ```
   然后手动精确路径提交：
   ```bash
   git -C contexts/baseline add b865g8-a2-bytedance
   git -C contexts/baseline commit -m "runner 归一化: 删 runner 六文件(单副本移主仓 tests/baseline/runner, 见主仓 ADR-0027); gen_baseline/reconcile 移 tools/; YAML 盖 schema_version: 1"
   git -C contexts/baseline push   # 🔴 外发操作: 须先向用户确认, 不得静默执行(见执行纪律)
   ```

验证：
```bash
! ls contexts/baseline/b865g8-a2-bytedance/runner/run.sh 2>/dev/null
ls contexts/baseline/b865g8-a2-bytedance/tools/   # gen_baseline.py reconcile.py
# 数据生产线仍工作 + 盖章生效(评审 🟡: dry-run 只消费现有 YAML, 不能代替生成器验证)
python3 contexts/baseline/b865g8-a2-bytedance/tools/reconcile.py   # 预期 exit 0
_gen_out=$(mktemp -d)
python3 contexts/baseline/b865g8-a2-bytedance/tools/gen_baseline.py --out "$_gen_out"
grep -q '^schema_version: 1' "$_gen_out/ar_probes.yaml" && grep -q '^schema_version: 1' "$_gen_out/applicability.yaml"
rm -rf "$_gen_out"
ob test-qemu b865g8-a2-bytedance --dry-run   # 预期 exit 0（custom 谱系路由到子仓数据 + 共享 runner）
```
若 corpus（`/bmc/iasi/ob-harness/20260818/corpus`）不存在，gen_baseline 两条验证标"未验证：corpus 不存在"如实上报，**不得**用 dry-run 代替；reconcile 同理。

注意：本任务动子仓，属不可逆删除——前置检查用**状态而非历史**，且须**全仓 clean**（本次改为手动精确路径提交，但前置 dirty 仍会混淆归因）：
```bash
git -C contexts/baseline status --short    # 必须为空输出才继续
git -C contexts/baseline diff              # 复核确认无本地改动
```
commit 前再确认 staged 只含 `b865g8-a2-bytedance` 下预期路径（`git -C contexts/baseline diff --cached --name-only`）。

### Task 9 — 最终验证

```bash
tools/ob_check.sh
ob test-qemu romulus --dry-run
ob test-qemu b865g8-a2-bytedance --dry-run
```
预期：ob_check 全绿（结构/函数登记/shellcheck baseline/测试）；两个 dry-run 均 exit 0 列 AR。

## 任务间接口契约

- Task 3 Produces：plan.py 接受 `schema_version` 顶层字段（支持集 `{1}`）；romulus 数据已盖章。Task 4/5/6/8 消费同一支持集。
- Task 4 Produces：`cmd_test_qemu` 的 env 注入契约（OB_TQ_AR_PROBES/OB_TQ_APPL 指向谱系路由数据目录）+ runner 固定路径 `$HARNESS_ROOT/tests/baseline/runner/run.sh`。Task 5/6/8 的验证依赖此契约生效。
- Task 8 Produces：子仓纯数据形态 + schema_version: 1。Task 9 的 b865g8 dry-run 依赖它。

## 执行纪律

- 开始实现前，先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 当前在 `main`：开工前与用户确认开分支。
- **`git push` 是外发操作**：Task 8 的子仓 push（含主仓任何 push）前必须停下向用户确认，不得静默执行；commit 可先做。
- 按任务顺序执行，不无声跳步、合并步或改变任务目标；每个任务完成即跑其验证。
- 遇阻塞、重复失败或计划与仓库现实不符，立即停下说明，不猜。
- 全部完成后跑 Task 9 最终验证并输出修改摘要。
