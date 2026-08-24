# ob smoke 收编为 ob test-qemu --suite smoke 实施计划

## 目标

`ob smoke` 独立顶层命令退役，其 5 条可达性断言收编为每 machine 必备的专用 suite：`ob test-qemu <machine> --suite smoke`（决策见 [ADR-0028](../adr/0028-smoke-merged-into-test-qemu-suite.md)）。交付：

1. runner 新增 `ipmi` / `ssh_tcp` 两个 probe-type（probe seam 契约 rc 0/1/3 + stdout 一行 JSON，与 probe_redfish 同构）。
2. romulus 与 b865g8-a2-bytedance 各落一份 `ar_probes.d/smoke.yaml`（5 AR）并实测通过。
3. `ob smoke` 命令、`lib/smoke_assertions.sh`、`ob --help` smoke 段落整段删除，不留别名双轨。
4. `tools/smoke_diff.py` 重写为消费两份 `--report` JSON；`tools/smoke_regression.sh` temporal gate 保留 caller 侧，改调 `ob test-qemu --suite smoke --report`。
5. 旧 smoke 测试簇按新语义迁移；CONTEXT.md / ADR-0020/0023/0025 / bestpractice_06 就地修订（活文档原则）。

## 架构快照

现状：`cmd_test_qemu`（[lib/qemu_commands.sh:920-1148](lib/qemu_commands.sh#L920-L1148)）谱系路由 → env 注入（`OB_TQ_AR_PROBES`/`OB_TQ_APPL`/`OB_TQ_USER`/`OB_TQ_PASSWORD`）→ `tests/baseline/runner/run.sh` → `runner.py` 逐 AR 调 `probe_redfish.py`（硬编码单 probe 二进制，[runner.py:155](tests/baseline/runner/runner.py#L155)）。AR 数据已有 `probe:` 字段（romulus 分片全部 `probe: redfish`），但 plan.py 未校验它、runner 不按它分发。

目标形态：

- **probe-type 维度**：`plan.py` 校验 AR `probe` 字段 ∈ {redfish, ipmi, ssh_tcp, none}（缺省 redfish；`none` 是 planner-only sentinel——仅 skip/cascade_skip AR 合法，表示无可执行探测定义，**不进入 runner probe 分派**），并按 probe-type 校验 request/assert 组合（兼容矩阵，见 Task 1）。`runner.py` 按 `r["probe"]` 选 probe 二进制 `probe_<type>.py`，probe 参数构造按类型分派。
- **端口注入**：`cmd_test_qemu` 在非 dry-run 时额外 `export OB_TQ_SSH_PORT`/`OB_TQ_IPMI_PORT`（从 `PIDFILE_SSH_PORT`/`PIDFILE_IPMI_PORT`）；probe 脚本自 env 读端口（redfish 的 `--port` argv 通道不变）。
- **per-interface 凭据**：`cmd_test_qemu` 前置 3 扩展——读 `ar_probes.yaml` 的 `auth.ipmi`（缺省 fallback 顶层 `auth`），`export OB_TQ_IPMI_USER`/`OB_TQ_IPMI_PASSWORD`（env 优先，不落 argv，与 redfish 同范式）。ssh_tcp 无凭据。
- **schema_version**：保持 `_AR_SCHEMA_VERSIONS = (2,)` **不升 v3**（方言边界选择：新 probe-type/新 assert 原语对 v2 数据一并开放——版本门禁防的是布局方言，而"数据用了 runner 不认识的 probe/assert"已有独立防线：plan.py 白名单 `die()` exit 3，旧 runner 读新数据会 fail-closed 而非错跑。升 v3 而语义无差会让 schema_version 变装饰性数字）。两 machine 顶层 `ar_probes.yaml` 的 `schema_version: 2` 不动。
- **smoke suite = 纯数据**：5 AR 写进 `ar_probes.d/smoke.yaml`，include 进顶层；runner 零 smoke 特判。

AR 命名（两 machine 一致，便于 smoke_diff 配对）：

| AR ID | probe | request / assert 摘要 |
|---|---|---|
| `SMOKE-01` | redfish | GET `/redfish/v1`，`status_in [200]` + `body_contains_any ["@Redfish.Copyright", "RedfishVersion", "ServiceRoot.v1"]`（结构标记判定，等价旧 judge——防 placeholder/错误页误判 pass） |
| `SMOKE-02` | redfish | GET `/redfish/v1/Managers/bmc`，`status_in [200]` + `body_contains_any ["ManagerType", "\"UUID\"", "#Manager"]`（等价旧 judge 的 Manager 资源标记） |
| `SMOKE-03` | redfish | GET `/redfish/v1/Managers/bmc`，`json_path_nonempty_any ["FirmwareVersion", "SoftwareVersion"]`（等价旧 judge：接受规范名或 alias、且必须**非空**——`json_path_exists` 会把 `""` 误判 pass，只认 FirmwareVersion 会把 alias-only image 误判 fail） |
| `SMOKE-04` | ipmi | `request: {command: mc_info}`，`exitcode_zero`（对齐旧 judge 只验 rc==0；`output_contains` 原语保留但**不用于** smoke 可达性断言——mc info 输出无稳定可断子串） |
| `SMOKE-05` | ssh_tcp | `request: {attempts: 30, interval: 5}`（秒，默认 30×5 对齐旧 `OB_SMOKE_READY_ATTEMPTS`），`tcp_connectable` |

新 assert 原语（probe-type 兼容矩阵约束使用范围）：redfish 侧 `body_contains_any {value: [str,...]}`（body 子串任一命中，非空列表）、`json_path_nonempty_any {path: [dotted,...]}`（任一路径存在且值为非空字符串）；ipmi 侧 `exitcode_zero`、`output_contains {value: str}`（非空 str）；ssh_tcp 侧 `tcp_connectable`。

## 全局约束

- 逐字继承 ADR-0028 全部决策：不留别名/双轨；输出与其他 suite 完全同构；不设默认 suite；exit 3 触发面变宽接受。
- 凭据全程不落 argv/`ps`（env 注入，owner-only）。**ipmitool 强制 `-E` 形态**（密码经子进程 env `IPMI_PASSWORD` 传递，由 ipmitool 自行读取），**禁止 `-P "$password"`**——shell 展开后密码仍出现在进程 argv、`ps` 全局可见。probe_ipmi.py 须有单测断言构造出的 ipmitool argv 不含密码字面量。
- probe seam 契约冻结：probe stdout 恰好一行 JSON dict，字段 `pass/code/body/actual/reason`（+error），rc ∈ {0,1,3}；[assemble.py](tests/baseline/runner/assemble.py) 的协议校验不动。
- 数据错 ≠ BMC fail：schema/兼容矩阵违规 → plan.py `die()` exit 3，不进 α truth。
- 改动 `ob`/`lib/*.sh` 后跑 `tools/ob_check.sh` 收尾（结构/函数登记/shellcheck baseline/测试）。
- b865g8 实测前须核实 QEMU 网络 workaround 在位（`grep macs_mask`，见 memory；IPMI 用户名 `toutiao`，密码 `toutiao!@#`，Redfish `toutiao`，以 [contexts/baseline/b865g8-a2-bytedance/ar_probes.yaml](contexts/baseline/b865g8-a2-bytedance/ar_probes.yaml) auth 栏为准）。

## 文件结构与职责

**新建**

| 文件 | 职责 |
|---|---|
| `tests/baseline/runner/probe_ipmi.py` | ipmitool mc info probe（`--selftest` 免网络自测；端口/凭据走 env） |
| `tests/baseline/runner/probe_ssh_tcp.py` | TCP 就绪门 probe（retry attempts×interval 秒，`--selftest`） |
| `tests/baseline/romulus/ar_probes.d/smoke.yaml` | romulus smoke suite 5 AR |
| `contexts/baseline/b865g8-a2-bytedance/ar_probes.d/smoke.yaml` | b865g8 smoke suite 5 AR |
| `docs/adr/README.md` | ADR 目录索引 + 「活文档就地修订」原则声明 |

**修改**

| 文件 | 职责变化 |
|---|---|
| `tests/baseline/runner/plan.py` | probe 字段校验 + 兼容矩阵 + 新 assert 原语白名单（`_AR_SCHEMA_VERSIONS` 保持 `(2,)` 不动）；计划行新增 `probe` 键 |
| `tests/baseline/runner/probe_redfish.py` | 增 `body_contains_any`/`json_path_nonempty_any` assert 原语（等价旧 smoke judge 语义）+ selftest 四类用例 |
| `tests/baseline/runner/runner.py` | 按 `r["probe"]` 分派 probe 二进制与参数构造 |
| `lib/qemu_commands.sh` | cmd_test_qemu：端口 env + ipmi 凭据解析/export + usage 文案；**删除** smoke 段（约 :494-775） |
| `ob` | 删 `smoke)` dispatch 与 usage smoke 段 |
| `lib/smoke_assertions.sh` | **删除**（整文件） |
| `tools/smoke_diff.py` | 重写：两份 JSON report 的 AR 配对回归判定 |
| `tools/smoke_regression.sh` | capture 改 `ob test-qemu <m> --suite smoke --report <tmp>` |
| `tests/baseline/romulus/ar_probes.yaml` | auth.ipmi 补全 + include 追加 smoke.yaml（`schema_version: 2` 不动） |
| `contexts/baseline/b865g8-a2-bytedance/ar_probes.yaml` | include 追加 smoke.yaml（`schema_version: 2` 不动；auth.ipmi 已在） |
| `tests/unit/test_qemu_runner.sh`、`tests/protocol/test_runner_contract.sh` | 增 probe-type 分派/兼容矩阵用例 |
| `tests/protocol/test_qemu_surface.sh` | 增 `--suite smoke` surface 断言 |
| CONTEXT.md、ADR-0020/0023/0025、`rules/knowhow/bestpractice_06-ob_first.md`、`rules/03_WORKSPACE.md` | 术语/正文就地修订（Task 13） |

**删除（测试簇）**：`tests/protocol/smoke_exit_contract.sh`、`smoke_surface.sh`、`smoke_substep_isolation.sh`、`smoke_assertions_judgment.sh`、`tests/unit/smoke_verdict.sh`、`smoke_regression_alpha_safety.sh`、`tests/orchestration/smoke_orchestration.sh`、`smoke_regression.sh`、`tests/integration/smoke_e2e.sh`、`smoke_help_clarity.sh`、`tests/fixtures/smoke_help_cases.sh`（与 Task 11 正文清单一致）；`tests/unit/smoke_diff.sh`、`smoke_diff_contract.sh` 改断言格式保留（随 Task 9）；`tests/protocol/start_qemu_noninteractive.sh` 中 smoke 引用按需适配；`tests/protocol/smoke_ob.sh`、`ob_check_smoke.sh` **保留**（通用 sanity，非退役命令）。

## 任务清单

### Task 1 — plan.py probe-type schema 与兼容矩阵

**Produces**：计划行新增 `probe` 键（"redfish"/"ipmi"/"ssh_tcp"/"none"，none 为 planner-only sentinel）+ `attempts`/`interval` 键（ssh_tcp request 字段透传，其余 probe 为 None）；`_AR_SCHEMA_VERSIONS` 保持 `(2,)`；白名单 `_ALLOWED_PROBE`；**`probe: none` 兼容**（b865g8 v2 数据大量使用，如 ar_probes.d/bios.yaml——none 仅允许 applicability 为 skip/cascade_skip 且无 request 的 AR，plan 现有"request 缺省容忍"逻辑天然覆盖；`probe: none` 而 status 为 applicable/xfail → `die()`，堵住"无可执行探测定义却要跑"的数据错）；新 assert 原语 `exitcode_zero`/`output_contains`/`tcp_connectable` + redfish 侧 `body_contains_any {value: [str,...]}`（body 子串任一命中，等价旧 judge 结构标记）/ `json_path_nonempty_any {path: [dotted,...]}`（任一路径存在且值为非空字符串，等价旧 judge 的非空+alias 判定）；兼容矩阵（redfish→status_in/json_path_exists/json_path_match/body_contains_any/json_path_nonempty_any，ipmi→exitcode_zero/output_contains，ssh_tcp→tcp_connectable，none→无 assert）；**assert 字段校验**：`output_contains.value`/`body_contains_any.value[]`/`json_path_nonempty_any.path[]` 必须非空字符串/非空列表（空串在 `"" in body` 下恒 true 假 pass；缺失/空 → `die()`）、`exitcode_zero`/`tcp_connectable` 不带 `value` 字段（多余 → `die()`）；request schema 按 probe 分叉：ipmi `request: {command: mc_info}`（仅允许 `mc_info`）、ssh_tcp `request: {attempts: int, interval: int}`（可选，缺省 30/5）、redfish 沿用 method/path 白名单。矩阵违例 → `die()`（exit 3）。

**Steps**：
1. 在 `tests/baseline/runner/plan.py` 的 `build_plan` 前加 `probe` 解析：`p = a.get("probe", "redfish")`，不在 `_ALLOWED_PROBE` → `die`。
2. assert 白名单改为按 probe-type 查矩阵；`status_in.value` 校验仅 redfish。
3. request 校验分叉（ipmi command 白名单 / ssh_tcp attempts/interval 正整数 / redfish 现状不动）。
4. 返回 dict 加 `"probe": p`。
5. `tests/baseline/runner/probe_redfish.py` 的 `run_asserts`/`_allowed` 增两原语实现：`body_contains_any`（任一子串命中 body）、`json_path_nonempty_any`（任一路径 resolve 且值为非空 str）；`--selftest` 补四类用例——alias 命中（仅 SoftwareVersion 非空 → pass）、空串拒绝（`"FirmwareVersion": ""` → fail）、200 无结构标记拒绝（placeholder body + body_contains_any → fail）、marker 命中 pass。`schema_version` 门禁无改动（`(2,)` 不动）。

**Run/Expected**：
```bash
python3 - <<'PY'
import sys; sys.path.insert(0, "tests/baseline/runner")
import plan
rows = plan.plan("tests/baseline/romulus/ar_probes.yaml", "tests/baseline/romulus/applicability.yaml", "", "")
assert all(r["probe"] == "redfish" for r in rows), rows
print("romulus v2 legacy OK:", len(rows))
rows_b = plan.plan("contexts/baseline/b865g8-a2-bytedance/ar_probes.yaml", "contexts/baseline/b865g8-a2-bytedance/applicability.yaml", "", "")
print("b865g8 v2 legacy OK:", len(rows_b), "none:", sum(1 for r in rows_b if r["probe"] == "none"))
PY
```
预期：打印 `romulus v2 legacy OK: 5` 与 `b865g8 v2 legacy OK: <N> none: <M>`（两个 v2 数据集照常通过——probe: none 的 skip AR 不被新白名单打破，M>0）。再手工构造 tmp YAML 四组各调 `plan.plan` 断言 `SystemExit(3)`：`probe: ipmi` + `assert: [{type: status_in,...}]`（矩阵违例）；`probe: none` + applicability applicable + 无 request；`probe: ipmi` + `assert: [{type: output_contains}]`（缺 value）；`probe: ipmi` + `assert: [{type: output_contains, value: ""}]`（空串假 pass 防御）、redfish AR + `body_contains_any {value: []}`（空列表）与 `json_path_nonempty_any {path: []}`（空 path 列表）共六组。最后跑 `python3 tests/baseline/runner/probe_redfish.py --selftest && echo REDFISH-SELFTEST-OK`，预期四类新用例全过 + `REDFISH-SELFTEST-OK`。

### Task 2 — probe_ipmi.py

**Consumes**：Task 1 的 probe-type `ipmi`。**Produces**：`tests/baseline/runner/probe_ipmi.py`，CLI `--asserts '<JSON>'`（+`--selftest`）；host 固定 localhost（与旧 smoke 一致），端口读 env `OB_TQ_IPMI_PORT`（缺 → error record exit 3，reason 指名 env）；凭据 env `OB_TQ_IPMI_USER`/`OB_TQ_IPMI_PASSWORD`，缺则 fallback `OB_TQ_USER`/`OB_TQ_PASSWORD`，两源全缺 → error exit 3。命令固定 `ipmitool -I lanplus -E -H localhost -p $PORT mc info`，密码经子进程 env `IPMI_PASSWORD` 传递（ipmitool `-E` 自行读取），**禁止 `-P`**。输出契约：stdout 恰好一行 JSON `{pass, code(null|int rc), body(str 原始输出), actual, reason}`，rc 0/1/3（ipmitool 不存在/无法执行 → error 3 infra，非 fail）。

**Run/Expected**：
```bash
python3 tests/baseline/runner/probe_ipmi.py --selftest && echo IPMI-SELFTEST-OK
```
预期：`selftest OK` + `IPMI-SELFTEST-OK`（selftest 覆盖：assert 原语纯函数、缺 env 的 error 形态、JSON 输出契约 shape、**构造的 ipmitool argv 不含密码字面量**——把 argv 构造抽为纯函数 `_build_argv(port)` 供直测）。

### Task 3 — probe_ssh_tcp.py

**Consumes**：Task 1 的 `ssh_tcp`。**Produces**：`tests/baseline/runner/probe_ssh_tcp.py`，CLI `--asserts '<JSON>' --attempts N --interval S`（+`--selftest`）；端口 env `OB_TQ_SSH_PORT`（缺 → error 3）；socket 连接按 attempts×interval 有界轮询（对齐旧 `_smoke_wait_ssh_tcp`，超时不中止——交给 `tcp_connectable` 断言判 fail）；无凭据。输出契约同 Task 2。

**Run/Expected**：
```bash
python3 tests/baseline/runner/probe_ssh_tcp.py --selftest && echo SSH-SELFTEST-OK
```
预期：`selftest OK` + `SSH-SELFTEST-OK`。

### Task 4 — runner.py 按 probe-type 分派

**Consumes**：Task 1-3。**Produces**：`runner.py` 主循环按 `r.get("probe", "redfish")` 分派：probe 二进制 `os.path.join(script_dir, "probe_%s.py" % probe)`（`OB_TQ_PROBE` env override 仅对 redfish 保留现状；skip/cascade_skip 行不进分派，`none` sentinel 永不到达此处）；参数构造分派——redfish 现状不动；ipmi/ssh_tcp 只传 `--asserts`（+ssh_tcp 的 `--attempts`/`--interval`，从 request 字段来，plan 行已带）。usage 的 `--suite` 说明补 smoke 一句。**范围声明（本轮锁死）**：runner 的全局凭据前置（缺 OB_TQ_USER/OB_TQ_PASSWORD → exit 2，[runner.py:88-96](tests/baseline/runner/runner.py#L88-L96)）**保持不动**——本轮只支持含 redfish AR 的混合 suite（smoke 的 SMOKE-01..03 是 redfish）；纯 ipmi/ssh_tcp suite 的条件化凭据检查是未来扩展，不在本计划。

**Run/Expected**（smoke suite 尚未落地，用 romulus core suite 验证 redfish 分派零回归）：
```bash
OB_TQ_AR_PROBES=tests/baseline/romulus/ar_probes.yaml OB_TQ_APPL=tests/baseline/romulus/applicability.yaml bash tests/baseline/runner/run.sh --host 127.0.0.1 --port 1 --user u --password w --suite core --dry-run && echo DISPATCH-OK
```
预期：dry-run 列出 core AR + `DISPATCH-OK`。

### Task 5 — romulus smoke.yaml + 顶层 include/auth 更新

**Consumes**：Task 1-4。**Produces**：`tests/baseline/romulus/ar_probes.d/smoke.yaml`（5 AR，命名 SMOKE-01..05，字段序 ar/name/probe/suite/request/assert/rationale 对齐现有分片惯例）；顶层 `auth.ipmi: {user: root, password: "0penBmc"}`（替换占位注释行）、include 追加 smoke 分片（`schema_version: 2` 不动，见架构快照方言边界决策）。

**Run/Expected**：
```bash
OB_TQ_AR_PROBES=tests/baseline/romulus/ar_probes.yaml OB_TQ_APPL=tests/baseline/romulus/applicability.yaml bash tests/baseline/runner/run.sh --host 127.0.0.1 --port 1 --user root --password 0penBmc --suite smoke --dry-run && echo SMOKE-DRYRUN-OK
```
预期：dry-run 列出 SMOKE-01..05 全部 applicable + `SMOKE-DRYRUN-OK`。

### Task 6 — cmd_test_qemu 端口/凭据注入

**Produces**：前置 4 内非 dry-run 时 `export OB_TQ_SSH_PORT="$PIDFILE_SSH_PORT" OB_TQ_IPMI_PORT="$PIDFILE_IPMI_PORT"`；前置 3 扩展读 `auth.ipmi`（YAML 解析沿用现有内联 python，并列输出 redfish+ipmi 两组 user/password；`auth.ipmi` 缺则 fallback 顶层 `auth`，再缺则不 export——ipmi probe 自行 error 3），`export OB_TQ_IPMI_USER`/`OB_TQ_IPMI_PASSWORD`；usage 的 Environment/Boundary 段补 smoke suite 与新 env 说明。

**Run/Expected**：
```bash
./ob test-qemu romulus --suite smoke --dry-run && echo OB-DRYRUN-OK
```
预期：dry-run 5 AR + `OB-DRYRUN-OK`（dry-run 不需要实例，但需要 PyYAML/谱系/baseline 目录前置通过）。

### Task 7 — romulus 实测

**Steps**：起 romulus QEMU 实例（`./ob start-qemu romulus`，已有跑着实例则复用）→ `./ob test-qemu romulus --suite smoke` → 核对五态输出与 exit code（全过 exit 0；故意 stop 实例前置 → exit 3）。测完不新增 teardown（probe-only）。

**Run/Expected**：
```bash
./ob test-qemu romulus --suite smoke -v; echo "exit=$?"
```
预期：5 AR 全 pass、`exit=0`；`--report /tmp/smoke-romulus.json` 产出 JSON 可被 `python3 -m json.tool` 解析。

### Task 8 — b865g8 smoke.yaml + 顶层 include 更新 + 实测

**Produces**：`contexts/baseline/b865g8-a2-bytedance/ar_probes.d/smoke.yaml`（同 5 AR）；顶层 include 追加（`schema_version: 2` 不动；auth.ipmi 已在，核对 `user: toutiao`）。**注意**：该目录是嵌套 git 子仓（sync.sh 拓扑），改动需在子仓内 commit。

**Steps**：启动 b865g8 QEMU 前 `grep -rn "macs_mask"` 核实网络 workaround 在位（memory：易被 git 回退）→ `./ob start-qemu b865g8-a2-bytedance` → `./ob test-qemu b865g8-a2-bytedance --suite smoke --report /tmp/smoke-b865g8.json`。

**Run/Expected**：`echo "exit=$?"` 预期 `exit=0`（重点核验 SMOKE-04 pass——旧 smoke 在此因硬编码 root 恒 ✗，本次收编正是修它；若 IPMI ✗ 先按 memory 排查 toutiao 用户名/QEMU 网络，再判数据问题）。

### Task 9 — smoke_diff.py 重写 + smoke_regression.sh 改造

**Consumes**：Task 7/8 的 report JSON。**report schema 冻结**（以 [report.py](tests/baseline/runner/report.py) 实测为准，Task 7 取样核对后不得偏离）：顶层 `{verdict, counts, records}`，每条 record `{"ar", "status" ∈ pass/fail/skip/xfail/xpass/error, "reason", ...}`——**字段名是 `status` 不是 `verdict`**。**Produces**：`tools/smoke_diff.py` 输入改为两份 `ob test-qemu --report` JSON；配对键 = `records[].ar`；回归判定对齐旧语义：baseline pass → current fail = 回归；baseline 无此 AR 且 current fail = 新增失败回归；fail→pass 仍作 info；skip/error 行不参与（error 属 infra 非真相）。exit 0 放行 / exit 1 拦截。`tools/smoke_regression.sh` 的 capture 行改为 `ob test-qemu <machine> --suite smoke --report "$tmp"`（`command -v ob` stub 可测性保留）；**rc 纪律**：ob test-qemu rc ∈ {0,1} 才调 smoke_diff；rc 3（前置缺失/infra ERROR）直接透传 exit 3，不把 ERROR report 交给 diff 后误放行。`tests/unit/smoke_diff.sh`/`smoke_diff_contract.sh` 改造为喂两份 fixture JSON（fixture 从 Task 7 的真实 report 裁剪）。

**Run/Expected**：
```bash
bash tests/unit/smoke_diff.sh && bash tests/unit/smoke_diff_contract.sh && echo DIFF-OK
```
预期：两测试 PASS + `DIFF-OK`（含 pass→fail 拦截、新增 fail 拦截、fail→pass 放行三向用例）。

### Task 10 — 删除 ob smoke 命令面

**Produces**：删 [ob](ob) 的 `smoke)` dispatch（ob:141）与 `cmd_smoke` 调用（ob:390-391）、usage 的 smoke Options/exit-codes 段（ob:245-267）；删 [lib/qemu_commands.sh](lib/qemu_commands.sh) smoke 段（`# ob smoke` 注释块起至 `cmd_smoke` 结束，约 :492-775）；删 `lib/smoke_assertions.sh`。若 `tools/ob_check.sh` 的函数登记表含 `_smoke_*`/`smoke_judge_*`，同步移除。

**Run/Expected**：
```bash
rc=0; ./ob smoke romulus >/dev/null 2>&1 || rc=$?; test "$rc" -eq 1 && echo "cmd-rc=$rc"; ! grep -rq "_smoke_\|cmd_smoke\|smoke_judge_" lib/ ob && echo NO-SMOKE-RESIDUE
```
预期：`cmd-rc=1` 打印（unknown command 的原始 rc，显式 `|| rc=$?` 捕获，不经 `!` 取反污染）；`NO-SMOKE-RESIDUE` 打印（grep 门禁化：有残留则该行不打印且整条命令 rc≠0）。

### Task 11 — 旧 smoke 测试簇迁移/删除

**Produces**：
- **整体删除**（纯 smoke 专属）：`tests/protocol/smoke_exit_contract.sh`、`smoke_surface.sh`、`smoke_substep_isolation.sh`、`tests/protocol/smoke_assertions_judgment.sh`、`tests/unit/smoke_verdict.sh`、`tests/unit/smoke_regression_alpha_safety.sh`、`tests/orchestration/smoke_orchestration.sh`、`smoke_regression.sh`、`tests/integration/smoke_e2e.sh`、`smoke_help_clarity.sh`、`tests/fixtures/smoke_help_cases.sh`。
- **保留不动**（二轮评审核实：文件名里的 smoke 是通用 sanity/smoke 含义，非退役命令）：`tests/protocol/smoke_ob.sh`（通用 ob 冒烟测试，覆盖 parse_args/cmd_build，无旧 `ob smoke` 命令段）；`tests/protocol/ob_check_smoke.sh`（ob_check.sh 自检）。本需求不改这两个文件；命名误导问题不在本计划处理（如要重命名另开小步并同步 coverage_matrix）。
- **配套登记表同步**：`tools/coverage_matrix.md` 的 `## smoke` 节（:101-108）删除并把仍存函数的行改指新测试；`tools/exit_contract.py:79` 的 `'smoke_assertions.sh': set()` 条目删除。
- **新增**：`tests/protocol/test_qemu_surface.sh` 增 `--suite smoke` surface 用例（usage 含 smoke、无 `ob smoke` 命令残留）；`tests/protocol/start_qemu_noninteractive.sh` 的 smoke 引用改为 test-qemu 等价断言；`tests/unit/test_qemu_runner.sh` 增 probe-type 分派与兼容矩阵违例（ipmi AR 配 status_in → exit 3）用例。

**Run/Expected**（含遗留引用门禁）：
```bash
bash tests/protocol/test_qemu_surface.sh && bash tests/unit/test_qemu_runner.sh && bash tests/protocol/test_runner_contract.sh && ! grep -rqE "_smoke_|cmd_smoke|smoke_judge_|smoke_assertions|OB_SMOKE" tests/ tools/coverage_matrix.md tools/exit_contract.py --include="*.sh" --include="*.py" --include="*.md" && echo TESTS-OK
```
预期：三项测试 PASS + 无遗留引用 + `TESTS-OK`。

### Task 12 — smoke_regression 闸门 e2e 验证

**Run/Expected**（romulus 实例在跑，沿用 Task 7）：
```bash
bash tools/smoke_regression.sh romulus -- true; echo "exit=$?"
```
预期：baseline/current 两次 `--suite smoke` 快照全 pass、无退化、`exit=0`。

### Task 13 — 文档与 ADR 活文档修订

**Produces**（逐项就地修订，不新增 superseded 链）：
1. CONTEXT.md：`ob smoke` 词条改写为 `smoke suite`（保留 probe-only/regression 归 caller/死实例 exit 3 语义内核）；新增 `probe-type` 词条；`ob test-qemu` 词条删"正交姊妹/不复用 smoke probe 原语"、补 probe-type 与 per-interface auth；`baseline` 词条"与 smoke 正交"句改写。
2. ADR-0020：正文修订——probe 收编 suite 体系、"零 per-machine"限定为 temporal gate（caller 侧）；ADR-0023：删除"暂缓/等第二个 adapter"结论（已等到，正文改为指向 ADR-0028 的现状）；ADR-0025：v2 增补的"未来收编保持结构统一"句改为"已收编（ADR-0028）"。
3. 新建 `docs/adr/README.md`：目录索引（含 0028）+ 活文档原则一句（"ADR 是活文档：内容过期就地修订对齐现状，不做 superseded-by 链；新增仍须过 surprising 三重门槛"）。
4. `rules/knowhow/bestpractice_06-ob_first.md`：删 smoke α exit 1 例外段（38-49 行区域）。
5. `rules/03_WORKSPACE.md`：smoke 相关路径条目更新（smoke_assertions.sh 删除、smoke suite 数据落点）。
6. 配套清理（评审 🟢 补）：`rules/05_KNOWHOW_INDEX.md:22` 的 `ob smoke` 故障排除描述改指 `--suite smoke`；`rules/knowhow/workflow_01-obmc_env_init.md` 修订——:256-261 的 "ob smoke 阶段/`ob smoke <machine>`/smoke exit 1" 旧入口描述与 :299-300 的 "romulus smoke" 表述全部改为 `ob test-qemu --suite smoke` 等价新语义（故障排除内容本身保留，只换入口与判定语义）；`tools/coverage_matrix.md` smoke 节随 Task 11 已处理，此处复检；`tests/baseline/runner/probe_redfish.py` docstring 的 "NOT shared with `ob smoke`" 句删除；`tests/baseline/README.md` 修订——:72 的 "当前仅 redfish；ipmi/ssh/console 预留" 改为 redfish/ipmi/ssh_tcp 已支持（none 为 skip-only sentinel），:87-89 的 runner 文件构成补 `probe_ipmi.py`/`probe_ssh_tcp.py`。

**Run/Expected**：
```bash
! grep -rn "ob smoke" CONTEXT.md rules/ docs/adr/ tools/coverage_matrix.md --exclude="0028-*.md" && echo NO-DOC-RESIDUE; grep -q "活文档" docs/adr/README.md && echo DOC-OK
```
预期：`NO-DOC-RESIDUE` 打印（ADR-0028 是决策记录本身、合法含 "ob smoke"，故 exclude；其余活文档无残留——历史性 docs/plans 不追）；`DOC-OK`。

### Task 14 — 最终验证

**Run/Expected**：
```bash
bash tools/ob_check.sh; echo "ob_check=$?"
```
预期：`ob_check=0`（结构/函数登记/shellcheck baseline/全量测试四段全绿；smoke 旧函数已从登记表清除）。随后 `git status` 核对删除清单与新增文件齐全，输出修改摘要。

## 任务间接口契约

- Task 1 → Task 4：计划行 dict 新增 `probe` 键（str，四值 redfish/ipmi/ssh_tcp/none；none 为 planner-only sentinel，Task 4 的 probe 分派永不会收到 none）；Task 4 只读该键分派。
- Task 1 → Task 2/3：新 assert 原语语义 `exitcode_zero`（probe rc==0 即过）/ `output_contains{value}`（body 子串）/ `tcp_connectable`（TCP 连接成功即过）。
- Task 4 → Task 2/3：runner 只传 `--asserts`（+ssh_tcp `--attempts`/`--interval`）；端口/凭据全走 env（`OB_TQ_IPMI_PORT`/`OB_TQ_SSH_PORT`/`OB_TQ_IPMI_USER`/`OB_TQ_IPMI_PASSWORD`）。
- Task 6 → Task 7/8：env 名与上表逐字一致；`auth.ipmi` fallback 链 env > auth.ipmi > auth 顶层。
- Task 7 → Task 9：report JSON 契约冻结——顶层 `{verdict, counts, records}`，配对键 `records[].ar`、判定字段 `records[].status`（**非 `verdict`**）；Task 7 实测取样核对后 Task 9 方可实现。

## 执行纪律

- 开始实现前，先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行，不无声跳步、合并步或改变任务目标。
- 每完成一个任务，运行该任务定义的验证。
- 遇阻塞、重复失败或计划与仓库现实不符，立即停下说明，不猜。
- 当前在 `main` 分支：开始实现前先与用户确认分支策略。
- 全部任务完成后，运行最终验证（Task 14）并输出修改摘要。
- b865g8 实测（Task 8）涉及 QEMU 网络 workaround 核实与嵌套子仓 commit，若环境不满足（实例起不来/网络断）如实报告 partial，不跳过不伪造。
