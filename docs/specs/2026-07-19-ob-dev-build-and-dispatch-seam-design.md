# ob dev build + cmd_dev dispatch/emit seam 设计文档

Status: 草案（grill-with-docs 共识，2026-07-19，待 writing-plans）

Date: 2026-07-19

## 修订记录

- v1：grill-with-docs 共识初稿。10 个决策经一对一 grilling 锁定（范围 / 交付粒度 / exit 归属 / encoder 形状 / 文件归属 / build 语义 / porcelain / 前置 / 注册 / 测试矩阵）。
- v1.1（实现期同步，2026-07-20）：build 分支 not_modified 路径伪代码改显式 cat+rm（实现 v2.1 澄清：不经 relay，避免依赖"三条件都不触发表"隐式行为；强化 ADR-0010 的"porcelain 副作用是 cmd_dev 显式决策"）。A1 relay per-subcmd verbatim 表 / B1 镜像 modify_run / 4 处执行期笔误修正详见 plan v2/v2.1。

## 背景与目标

`ob dev` 当前覆盖 `list`/`modify`/`refresh`/`reset`/`status`/`finish`，但 `build`/`deploy` 在 arg parser 已接线却是 stub（`lib/commands.sh:838` 解析、`:1220` 兜底 `reserved, not implemented yet`）。`ob dev modify` 把源码放进 srctree（externalsrc 激活）后，**没有 ob 路径编译这一个 recipe**——开发者被迫手动 `source setup` + `bitbake`，跳出 ob。这是 [workflow_02](../../rules/skills/workflow_02-obmc_dev_modify.md) 承认的闭环缺口（"增量 build / 部署（预留，待 ob 提供）"），也是 [ob_first](../../rules/skills/bestpractice_06-ob_first.md) 要消灭的绕过路径。

`ob build <machine>` 是整个 `obmc-phosphor-image`（1-4 小时），是错的工具——内循环要的是单 recipe 秒-分钟级 fast feedback。

本设计一次推进两件事：

1. **候选 1（功能补全）**：新增 `ob dev build`，补 `modify → build → finish` 内循环的编译洞。
2. **候选 2（深化）**：深化 `cmd_dev` 的 dispatch + emit seam——抽 failure-relay 和 result-encoder 两个 leaf-pure 深模块，把现有 6 个子命令分支各自内联的 `cat stderr / stage-fail / phase-map / rc-fail / JSON-encode` boilerplate 收成一份。

**候选 2 是候选 1 的交付载体**：先抽 seam（行为不变），再把 `build` 作为一个薄分支落进干净的 seam，而不是第 7 份 boilerplate 副本。

### 成功标准

- `ob dev --machine <m> build <recipe>` 对 modified recipe 编译（`devtool build`，do_build），空 stdout + exit code 承载成败；未 modified → exit 3 + remedy。
- `cmd_dev` 的 6 个既有分支重构到 `dev_relay_result` + `dev_emit_*`，**stdout/stderr/exit-code 字节级不变**（既有测试即回归锁，全绿）。
- 新代码过 leaf-pure 门禁（`exit_contract` Y 规则）+ `tools/ob_check.sh` 全套自检。
- `deploy` 维持 stub，零改动。

## 范围

- 新增 `lib/devtool_dispatch.sh`（`dev_relay_result`，leaf-pure）。
- 扩 `lib/devtool_porcelain.sh`：加 `dev_emit_reset_json` / `dev_emit_finish_json` / `dev_emit_status_jsonl`（encode + 复用既有 `devtool_emit_json`/`devtool_emit_jsonl` publish）。
- 新增 `lib/devtool_build.sh`（`devtool_build_run`，leaf-pure）。
- 重构 `lib/commands.sh`::`cmd_dev` 全部分支到新 seam；加 `build)` 分支。
- usage / TTY 菜单 / `usage_dispatch_sync.sh` 登记 `build`。

## 非范围

- **`ob dev deploy`**：需运行态 target（QEMU instance / 真机）+ 部署传输，与 `lib/qemu_*` 子系统纠缠，是独立工作项。本轮维持 stub。
- **build 的 task 参数（`-c compile`/`--task`）**：v1 固定 do_build。compile-only 快路径是后续增强（若内循环迭代速度成痛点再加）。
- **reset/finish 的 cleanup assembler 抽取**（架构评审候选 3）：reset/finish 已在 leaf helper 层共享，本轮不碰。
- **workspace 锁**（ADR-0009）：不重开。build 不改 workspace 状态（见下），与单 writer 假设无关。

## 方案比较

### 候选 2 — exit 归属（grilled Q3）

- **Option A（采纳）**：新 helper leaf-pure（返回码），`cmd_dev` 留唯一 `exit`。守住"exit 只在 cmd_dev L1"全表面不变量，与现有 `devtool_*_run` 一致，`exit_contract` 零改动。
- Option B（拒）：新 helper own exit（变 direct-exit module）——第一次打破不变量，门禁重分类，exit 流散。
- Option C（拒）：混合（failure-relay own exit，result-encoder leaf-pure）——无原则折中。

### 候选 2 — result-encoder 形状（grilled Q4）

- **Option 2 per-shape（采纳）**：3 个 encoder（reset 7 字段 / finish 12 字段含 2 list / status JSONL）。今天只有 reset 是纯标量 json-obj，通用 field-map encoder 仅 1 个 call site（不够"两个 adapter 才值得 seam"门槛），且 finish 的 list 字段逼出 type-tag 协议，复杂度净增。
- Option 1 通用 field-map（拒）：YAGNI + list 字段协议税。
- Option 3 finish 兼容 reset（拒）：reset 契约恰好 7 字段，吐 12 个 null landing 违反 porcelain 契约。

### 候选 1 — build 语义（grilled Q6）

- **`devtool build <recipe>` do_build 默认（采纳）**：与 `modify`/`reset`/`finish` 全 wrap devtool 子命令对称；do_build = "完整编通"，与 `ob build` 的 build 动词对齐（per-recipe vs per-image）。
- 裸 `bitbake -c compile`（拒）：打破 devtool 对称，是 ob dev 里的异类。
- task 参数（拒，v1）：YAGNI，90% 场景是"build 这个 recipe"。

### 候选 1 — build porcelain（grilled Q7）

- **空 stdout + exit code 承载成败（采纳）**：build 结果二值，细节在 bitbake log（stderr）。镜像 `refresh`（空 stdout 是已文档化形态），非 reset/finish 的 JSON 形态。连锁简化：build 无 phase、不需 encoder。
- 一行 JSON（拒）：`success`/`recipe`/`task` 全是与 exit code 或输入冗余的噪声。
- JSON + artifact 路径（拒）：定位 deploy 目录非平凡且脆，deploy 的活。

## 推荐方案

两个 commit，严格顺序：

### Commit A — 纯重构（行为不变）

抽两个 leaf-pure 模块，把 `cmd_dev` 现有 6 分支（list/modify/refresh/reset/status/finish）改用新 seam。**stdout/stderr/exit-code 字节级不变**——既有测试即回归锁（[bestpractice_09](../../rules/skills/bestpractice_09-nonfunctional_regression_locks.md)）。

### Commit B — 加 build

在干净 seam 上加 `ob dev build`：新 `lib/devtool_build.sh` + `cmd_dev` `build)` 薄分支 + usage/菜单/测试。

## 关键边界与组件职责

### `lib/devtool_dispatch.sh`（新增，leaf-pure）

`dev_relay_result <subcmd> <stderr_file> <stage> <phase> <rc>`：集中"调完 `*_run` 之后的标准动作"——cat+rm stderr_file → stage/phase/rc 诊断 → 返回 0（干净，继续 emit）/ 1（已诊断失败，调用者 exit 1）。内含 per-subcmd phase→hint 小表，**每条 hint 强制内嵌 `(phase=<phase>)` token**（见 porcelain 不变量）。单深函数一个文件，与 `lib/devtool_modify.sh`（41 行单函数）同构。

### `lib/devtool_porcelain.sh`（扩，leaf-pure）

加 3 个 per-shape encoder：`dev_emit_reset_json` / `dev_emit_finish_json` / `dev_emit_status_jsonl`。每个 = python encode（argv 值不插值源码串，空值→null，finish 的 patches/recipe_files 经 argv JSON 字符串 `json.loads` 合入）→ tempfile → 复用既有 `devtool_emit_json`/`devtool_emit_jsonl`（validate + 原子 cat + rm）。porcelain.sh 从"只管 publish"深化成"encode shape + validate + 原子 publish"完整流水线。

### `lib/devtool_build.sh`（新增，leaf-pure）

`devtool_build_run <machine> <build_dir> <recipe> <stage_outvar> <stderr_file_outvar> <not_modified_outvar>`：镜像 `devtool_modify_run` 的 status-first 形态——step1 跑 `devtool status`（失败→stage），recipe 不在 modified 列表→回传 not_modified=1（前置缺失信号），在列→`devtool build <recipe>` → stage + rc。leaf-pure 不 exit。

### `lib/commands.sh`::`cmd_dev`（exit seam + porcelain）

每分支收成：`devtool_X_run ...; dev_relay_result "$subcmd" "$stderr" "$stage" "$phase" "$rc" || exit 1; dev_emit_<shape> ... || exit 1; exit 0`。`build)` 分支特例：not_modified 信号 → exit 3 + remedy（前置，归 cmd_dev，不归 relay）；否则 relay + 空 stdout + exit 0。

## 单元接口与依赖

### `dev_relay_result`

```
dev_relay_result <subcmd> <stderr_file> <stage> <phase> <rc>
  → cat "$stderr_file" >&2; rm -f "$stderr_file"
  → case stage in cd|setup|postcondition) error "ob dev $subcmd: build env not ready (stage=$stage)." >&2; return 1;; esac
  → if [[ -n "$phase" ]]; then error "ob dev $subcmd: <hint> (phase=$phase)." >&2; return 1; fi   # hint 查 per-subcmd 表
  → if [[ "$rc" -ne 0 ]]; then error "ob dev $subcmd: devtool failed (rc=$rc, stage=$stage)." >&2; return 1; fi
  → return 0
```

phase→hint 表覆盖 reset（metadata/status/reset/postcondition）、finish（metadata/status/finish/landing/postcondition）；`*)` 兜底 `failed (phase=$phase)`。**每条 hint 必须含 `(phase=<phase>)` token**（测试子串断言依赖，见 porcelain 不变量）。

### `dev_emit_reset_json` / `dev_emit_finish_json` / `dev_emit_status_jsonl`

argv 传字段值（不插值源码串）→ python `json.dumps` 建 dict（**字段序与现有一致**，保字节 faithful）→ tempfile → `devtool_emit_json[_jsonl]`。编码失败 → 删 tempfile + return 1（调用者 exit 1，stdout 空）。

### `devtool_build_run`

```
devtool_build_run <machine> <build_dir> <recipe> <stage_outvar> <stderr_file_outvar> <not_modified_outvar>
  → step1: _devtool_env_exec ... devtool status（失败→stage）
  → _devtool_parse_status_all / _devtool_parse_srctree 查 recipe 是否 modified
  → 不在列: not_modified=1, return 0
  → 在列: _devtool_env_exec ... devtool build "$recipe" → stage + rc
  → 回传 stage / stderr_file（caller cat+rm 经 relay）/ not_modified
```

### `cmd_dev` build 分支

```
build)
  [[ -z "$dev_recipe" ]] && { error "ob dev build: no recipe specified." >&2; error "Run 'ob dev --machine $dev_machine status' to list modified recipes first." >&2; exit 3; }
  [[ "${DRY_RUN:-0}" == "1" ]] && { notice "[DRY-RUN] ob dev build $dev_recipe: would devtool build (do_build)." >&2; exit 0; }
  devtool_build_run "$dev_machine" "$dev_build_dir" "$dev_recipe" _b_stage _b_stderr _b_notmod || _b_rc=$?
  if [[ "$_b_notmod" == "1" ]]; then
      cat -- "$_b_stderr" >&2 2>/dev/null || true   # 显式 cat+rm(not_modified 路径不经 relay, v2.1)
      rm -f -- "$_b_stderr" 2>/dev/null || true
      error "Recipe '$dev_recipe' is not modified (not in devtool workspace)." >&2
      error "Run 'ob dev --machine $dev_machine modify $dev_recipe' first." >&2
      exit 3
  fi
  dev_relay_result build "$_b_stderr" "$_b_stage" "" "${_b_rc:-0}" || exit 1
  exit 0   # 空 stdout
  ;;
```

## 数据流 / 控制流

```
cmd_dev build 分支
  → (前置) machine init-done + recipe 非空 + DRY_RUN 短路
  → devtool_build_run（leaf-pure）→ status-first → not_modified | stage+rc
  → not_modified? → exit 3 + modify remedy（cmd_dev 决定 exit-code）
  → dev_relay_result（leaf-pure）→ cat/rm stderr + stage/rc 诊断 → 0/1
  → 0 → exit 0（空 stdout）；1 → exit 1
```

build 是单次 devtool 调用，**无 reset/finish 的多步 phase**（metadata/status/reset/landing/postcondition）——失败模型只有 stage（cd/setup/postcondition/command）+ rc。

## 错误处理与回退

- build 未 modified → **exit 3 + remedy**（前置缺失，非失败；与 init-done 前置同构）。
- stage=cd/setup/postcondition → exit 1（build env not ready）。
- stage=command + rc≠0 → exit 1（devtool build 失败，bitbake 编译错误在 stderr）。
- DRY_RUN → notice + exit 0（不调 `devtool_build_run`）。
- exit-code 契约：0=编通，1=失败，2=用户取消（machine pick），3=前置缺失（未 init / 未 modified / 无 recipe）。agent 仅 exit 1 触发回退。

### porcelain stdout 契约（build 新形态）

**build stdout 空**。结果由 exit code 承载（0/1），bitbake 编译 log 走 stderr，agent 定位 `[ERROR]` 行。镜像 `refresh`（空 stdout 已文档化形态），非 reset/finish 的 JSON 形态。详见 [CONTEXT.md](../../CONTEXT.md) `ob dev porcelain stdout` / `ob dev build`。

### porcelain 不变量（phase-token）

`dev_relay_result` 的每条失败 message 必须含 `(phase=<phase>)` token + stage 失败含 `build env` + rc 失败含 `devtool`。已核实 `tests/orchestration/cmd_dev.sh` 全用 `assert_contains` 子串断言（phase 失败断言 phase 名；finish 专断言字面 `phase=finish`，:437）——token 不变量天然满足全部既有断言，是 Commit A 行为保持的硬保证。

### JSON 字节 faithful（Commit A）

新 encoder 的 dict 字段序 + None 强转规则必须与现有 inline python 一致（python `json.dumps` 保插入序）。reset 7 字段序、finish 12 字段序、status JSONL key 集合 `{recipe,srctree}` 逐字保留。CONTEXT.md `ob dev porcelain stdout` 记录的字段集是契约基准。

### ADR 关系

- **ADR-0008（cleanup fail-safe）**：build **不是收尾命令**——不改 devtool workspace 状态（只往 bitbake WORKDIR/TMPDIR 产出），不创建/删除 externalsrc 或 `.bbappend`。故 ADR-0008 的 cleanup-needed 前置 / status 权威 recheck / exit 77 SKIP **不适用于 build**。build 无需 cleanup fault-inject 回归。
- **ADR-0009（workspace 单 writer）**：build 不写 workspace，与单 writer 假设无关，不重开锁决策。
- **ADR-0010（新，本设计伴生）**：dispatch helpers leaf-pure，`cmd_dev` 独占 exit——防未来 explorer 把 `dev_relay_result`/`dev_emit_*` "修"成 own-exit。

## 测试策略

### Static gates

`tools/ob_check.sh`（改 ob/lib 后必跑）：结构 / 函数登记（`extract_funcs`）/ shellcheck baseline / `exit_contract`（新 basename `devtool_dispatch`/`devtool_build` 进 leaf-pure 配置；encoder 进既有 leaf-pure `devtool_porcelain`）/ `run_all.sh`。

### Commit A — 纯重构

- **存活不变（回归锁）**：
  - `tests/orchestration/cmd_dev.sh` —— 已确认存活（子串断言全被 phase-token 不变量满足）。
  - `tests/unit/devtool_porcelain.sh`（emit_json/emit_jsonl 既有 case）+ `devtool_reset/finish/status/modify/workspace/search.sh` —— 模块未动。
  - `tests/protocol/*`、`tests/integration/ob_dev.sh`、`tests/unit/ob_dev_integration_safety.sh` —— 行为未变。
- **加**：
  - `tests/unit/devtool_dispatch.sh`（新）—— `dev_relay_result`：stage→"build env"、phase→hint+token、rc→"devtool"、cat/rm stderr、返回 0/1、leaf-pure no-exit。
  - `tests/unit/devtool_porcelain.sh` —— 加 3 个 encoder case（字段序、None 强转、finish list 处理、原子发布、malformed→return 1）。

### Commit B — build

- **加**：
  - `tests/unit/devtool_build.sh`（新）—— `devtool_build_run`：status-first not-modified 信号、devtool build 调用、stage/rc、stderr_file handoff、leaf-pure no-exit。
  - `tests/orchestration/cmd_dev.sh` —— 加 build 分支：not-modified→exit 3+remedy；success→exit 0 空 stdout；stage/rc fail→exit 1；DRY_RUN→notice+exit 0。
  - `tests/protocol/usage_dispatch_sync.sh` —— 加 build 登记块（usage 含 build；`parse_args dev --machine m build myrecipe` DEV_ARGS handoff；`main dev ... build` 真调 cmd_dev）。
  - `tests/integration/ob_dev.sh` —— modify→build→finish e2e（若 integration harness 支持 build；可能仅 `--integration` 跑，gate 视实环境）。
- **改（一处，实现时核实）**：
  - `tests/protocol/dev_interactive.exp` —— TTY 菜单加第 7 项 build。若 .exp 按子串断言菜单（"6) finish" 仍在）则存活；若 pin 完整菜单文本则改。

### Full check

`tools/ob_check.sh` + `tests/run_all.sh`（默认 protocol/unit/orchestration；`--full` 加 .exp；`--integration` 加 e2e）。

## harness 侧改动清单

- `lib/devtool_dispatch.sh`（新）
- `lib/devtool_porcelain.sh`（扩 3 encoder）
- `lib/devtool_build.sh`（新，Commit B）
- `lib/commands.sh`::`cmd_dev`（重构 6 分支 + 加 build 分支 + TTY 菜单第 7 项 + usage 行）
- `ob`（usage dev 行加 `build`，逻辑序 `list|modify|build|refresh|reset|status|finish`）
- `tests/unit/devtool_dispatch.sh`、`tests/unit/devtool_build.sh`（新）
- `tests/unit/devtool_porcelain.sh`、`tests/orchestration/cmd_dev.sh`、`tests/protocol/usage_dispatch_sync.sh`、`tests/protocol/dev_interactive.exp`（扩/改）
- `rules/03_WORKSPACE.md`（顺手：lib 目录索引补 `devtool_dispatch.sh` / `devtool_build.sh` 条目）
- `rules/skills/workflow_02-obmc_dev_modify.md`（补 build 条目：modify→build→finish 内循环 + build porcelain 空 stdout 契约）
- `CONTEXT.md`（新 `ob dev build` 术语 + 更新 `ob dev porcelain stdout` 补 build 形态）
- `docs/adr/0010-ob-dev-dispatch-leaf-pure-exit.md`（新）

## 实施约束（writing-plans 必须遵循）

1. **严格两 commit**：A 行为不变（既有测试全绿才进 B）；B 纯增量。
2. **A 的 JSON 字节 faithful**：encoder 字段序/None 规则逐字对齐现有 inline python。
3. **phase-token 不变量**：`dev_relay_result` 每条 hint 含 `(phase=<phase>)`；stage 含 `build env`；rc 含 `devtool`。
4. **exit 只在 cmd_dev**：新 helper 全 leaf-pure（返回码），`exit_contract` 配置同步。
5. **build 不碰 workspace**：不创建/删除 externalsrc/`.bbappend`，与 ADR-0008/0009 无关。

## 技术债

- build v1 无 task 参数（do_build 默认）。compile-only 快路径（`--task compile`）待内循环迭代速度反馈后加。
- `ob dev deploy` 仍 stub（独立工作项，需 QEMU instance / target 设计）。
- 候选 3（reset/finish cleanup assembler 抽取）未做——reset/finish 已共享 leaf helper，sequencing glue 重复待后续评估。

## 已决事项（原未决，设计期读测试文件了结）

### `.exp` 菜单 —— 确定性 MODIFY（非"核实改/存活"）

`tests/protocol/dev_interactive.exp` 不是纯子串断言，pin 了菜单结构：
- **line 122、147**：prompt 正则 `\[1-6\]` —— build 加成第 7 项后 prompt 变 `[1-7]`，**这两行必改**（`[1-6]` → `[1-7]`）。
- **line 118、119、144**：字面 `5) status` / `6) finish` —— build **追加为 option 7**（不重编号 1-6）则仍命中，存活。

决策：build **追加为 TTY 菜单第 7 项**（不插中间重编号，保 1-6 稳定）；`.exp` Commit B 改 2 行 regex + 可选加 build TTY 场景。usage 字符串保持 Q9 的 `list|modify|build|refresh|reset|status|finish`（`.exp` 测菜单不测 usage enum；菜单与 usage 的 build 位置不同是可接受取舍——菜单编号稳定优先）。

### integration build e2e —— 形状已定，自然塞入

`tests/integration/ob_dev.sh` 现有流程 refresh→list→选候选→**modify**→reset→finish。build e2e 落点 = **modify 之后、reset 之前**（line 253 后插 `./ob dev --machine "$MACHINE" build "$RECIPE"`）。build 不改 workspace 状态，不扰动下游。测试自带 SKIP 门（line 172/177/241，无 init machine / refresh 失败 / 无安全候选 → exit 77），build 步骤无条件写入，env 不在自动 SKIP。

**唯一残留设计点**（writing-plans 定，非未知）：`devtool build <recipe>` 对随机候选 recipe 可能因 recipe 自身依赖失败（与 ob 正确性无关）。ob 契约是 **relay rc**（非"保证 build 成功"），故 integration 的 build 断言应为"**ob rc == devtool build 实际结果**"（devtool 成功→exit 0 / 失败→exit 1），而非"build 必须成功"——否则 recipe 选择引入假 FAIL。
