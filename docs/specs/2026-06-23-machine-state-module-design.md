# Machine State Module 设计文档

Status: revised draft after review
Date: 2026-06-23

## 背景与目标

`CONTEXT.md` 和 ADR-0001 已经把 `machine snapshot` 定为当前 canonical term，并明确旧 `<machine>.lock` 已废弃、不再兼容。代码层还滞后：`init_pipeline.sh` 仍写 `<machine>.lock`，`commands.sh` 仍读取 `.lock` / `.init-done` / deploy image 路径来判断状态。本设计的一个目标是让代码追上当前领域模型和 ADR。

当前 `ob-harness` 已有 `partial` 显示语义：有旧 `.lock`、无 `init-done marker` 时，`ob status` 显示 `partial`。本设计不是新增 partial，而是把 partial 的数据源从旧 `.lock` 迁移到新 `.snapshot`，并保持 `init-done marker` 是唯一完成信号。

当前 Machine lifecycle state 判断散在多个路径：`cmd_status`、`cmd_build`、`cmd_start_qemu`、`cmd_init` 直接扫描 `workspace/configs/*.init-done`、旧 `<machine>.lock`、deploy image 目录；`repo.sh::print_previously_initialized` 也直接读取 `*.init-done`。这让上层和 repo selection UI 穿透状态存储 implementation，理解一个 Machine 状态需要反复跳到 `commands.sh`、`init_pipeline.sh`、`qemu.sh` 和 `repo.sh`。

本设计的目标是新增一个深的 `machine_state` module，把 Machine lifecycle state 的存储规则和状态转换收敛到一个 seam 后面。这里的 Machine lifecycle state 包括 persistent state（`machine snapshot`、`init-done marker`）和 build artifact view（deploy image / build directory），但不包括 QEMU runtime state。

成功标准：

1. `machine snapshot`、`init-done marker`、deploy image / build directory 查找由 `machine_state` module 拥有。
2. `commands.sh` 不再直接 glob/解析 Machine lifecycle state 的存储路径。
3. `repo.sh::print_previously_initialized` 不再直接 glob `*.init-done`，改为消费 `machine_state` 的 records。
4. 旧 `<machine>.lock` 硬切废弃，不兼容、不提示，只可在 `ob init <machine>` 过程中清理。
5. QEMU PID file 仍由 `qemu.sh` 拥有，保持 start-qemu / stop-qemu 的自包含 implementation。
6. `machine_state` module 不直接 `exit`，并由扩展后的 `exit_contract.py` 做静态门禁。
7. `ob status` 保留当前 build 三态：succeeded / failed / never。
8. `ob init <machine> --dry-run` 不修改 configs 下任何 marker/snapshot/legacy lock 文件。

## 范围

本次设计覆盖：

- 新增 `lib/machine_state.sh`，作为 Machine lifecycle state module。
- 将 `function semantic layer` 文档从五文件边界更新为六文件边界。
- 将 `<machine>.lock` 硬切为 `<machine>.snapshot`。
- 原子写入 `machine snapshot`。
- 原子写入 `init-done marker`。
- `ob init <machine>` 开始时清除旧 `init-done marker`、旧 `.snapshot`，并清理同名旧 `.lock`；`DRY_RUN==1` 时这些清理动作只预览、不执行。
- `ob status` 保留现有 partial 显示语义，但数据源从 `.lock` 迁到 `.snapshot`。
- `ob status` 保留现有 build 三态：有 image 为 succeeded，有顶层 `$OPENBMC_DIR/build/<machine>` 目录但无 image 为 failed，无顶层 build 目录为 never。
- `ob build` 继续只把 `init-done marker` 作为 initialized / buildable 资格。
- `ob start-qemu` 继续只把 `init-done marker` + deploy image 作为启动资格。
- deploy image 查找归 `machine_state`，多个 `*.static.mtd` 时确定性选择排序后的第一个。
- 迁移现有 4 个 deploy image 查找点：status summary、status tips、build success summary、start-qemu prerequisite。
- 新增或调整 unit / protocol / orchestration 测试，覆盖状态读取、写入、硬切、dry-run 和命令行为。
- 扩展 `exit_contract.py`，让 `machine_state.sh` 的“不 exit”成为 `ob_check.sh` 可验证门禁。

## 非范围

本次不做：

- 不兼容旧 `<machine>.lock`，不迁移旧文件，不在 `ob status` 提示 legacy `.lock`。
- 不把 QEMU PID file 的写入、读取、校验、清理迁入 `machine_state`。
- 不改变 QEMU binary、firmware、ports、SoC detection、hostkey 处理和 QEMU command 构造。
- 不接管 `repo.sh` 里的 machine selection / machine conf 解析；只让 `print_previously_initialized` 消费状态 records。
- 不把 `machine_state` 做成泛化状态数据库。
- 不改变 `ob-first` exit-code 契约和 remedy line 语义。
- 不重新设计 `deps.json` 或 bare mirror 填充流程。
- 不新增 partial-specific status tip；partial 只保留现有可见性和现有下一步语义，缺 marker 的命令 remedy 仍指向 `ob init <machine>`。

## 方案比较

### 方案 A：只读 Machine state module

核心思路：只把状态读取集中到新 module，写入仍留在 `commands.sh`、`init_pipeline.sh` 和 `qemu.sh`。

优点：

- 首次改动小。
- 对现有写入时机影响较低。
- 可以较快减少 `status` / `build` / `start-qemu` 的重复扫描。

缺点：

- locality 不闭合，状态转换仍散落。
- `init-done marker` 和 snapshot 写入规则仍不由同一个 module 拥有。
- 容易形成 shallow 查询 adapter，interface 先天不完整。

### 方案 B：Machine state module 同时拥有 lifecycle state 读写

核心思路：`machine_state` module 拥有 Machine lifecycle state 的读取和状态转换，包括 `machine snapshot`、`init-done marker` 和 build artifact view；QEMU runtime state 仍留在 `qemu.sh`。

优点：

- Machine lifecycle state 的 locality 闭合。
- `commands.sh` 和 `repo.sh` 不直接解释状态存储布局。
- `init-done marker` 和 snapshot 的原子写规则集中。
- 测试可以直接穿过一个 seam 验证 state records 和状态转换。
- 保留现有 status 的 partial 和 build failed 可见性。

缺点：

- 改动面大于只读方案。
- 需要同步文档、ADR、测试和命令调用点。
- 需要谨慎避免把 QEMU runtime state 或 repo/machine selection 吃进来。
- module 名称需要清楚说明它包含 build artifact view，而不只是 configs 下的 persistent files。

### 方案 C：把 QEMU PID file 也迁入 Machine state module

核心思路：把 initialized / built / running / stale 都集中在 `machine_state` module。

优点：

- `ob status` 可以从一个 module 取得完整 lifecycle 视图。
- running/stale 也能统一测试。

缺点：

- 会破坏 `qemu.sh` 对 start-qemu / stop-qemu 的自包含 implementation。
- `machine_state` 和 `qemu.sh` 会形成 sibling module 的 lateral coupling。
- QEMU PID file 包含 ports、serial log、binary、serial socket 等 QEMU runtime facts，不属于 Machine lifecycle state 的 persistent/build artifact 视图。

## 推荐方案

推荐方案 B。

核心取舍是：`machine_state` module deepen Machine lifecycle state（persistent state + build artifact view），不接管 QEMU runtime state。这样既能收敛当前最明显的 storage leakage，又保留 `qemu.sh` 作为 start-qemu / stop-qemu 的自包含 module。

推荐方案的关键决策：

1. 新 module 命名为 `lib/machine_state.sh`，不命名为 `machine.sh`。
2. `machine_state` 管 Machine lifecycle state：`machine snapshot`、`init-done marker`、deploy image / 顶层 build directory。
3. QEMU PID file 属于 QEMU runtime state，继续归 `qemu.sh`。
4. `commands.sh` 是聚合者：调用 `machine_state` 获取 init/build 状态，调用 `qemu.sh` 获取 QEMU runtime 状态。
5. `repo.sh::print_previously_initialized` 是状态 records 的消费者，不再直接读 `*.init-done`。
6. `<machine>.lock` 硬切废弃，不兼容、不提示。
7. `machine_state` 不 `exit`，上层命令决定 exit-code/remedy，`exit_contract.py` 负责守护该约束。

## 关键边界与 module 职责

### `lib/machine_state.sh`

职责：

- 计算 Machine lifecycle state 相关路径。
- 原子写入 `workspace/configs/<machine>.snapshot`。
- 清除同 machine 的旧 `.snapshot` 和旧 `.lock`。
- 原子写入 `workspace/configs/<machine>.init-done`。
- 清除 `init-done marker`。
- 在 `DRY_RUN==1` 时预览清理/写入动作，不修改 configs 文件。
- 列出 machine state records。
- 查询单 machine 的 image path。
- 查询单 machine 的 repo count / snapshot presence / marker presence。
- 查找 deploy image，多个 `*.static.mtd` 时按排序选择第一个。
- 判断 build status：`succeeded` / `failed` / `never`，其中 `failed` 的目录判定路径固定为顶层 `$OPENBMC_DIR/build/<machine>`。

不负责：

- 不处理 QEMU PID file。
- 不解析 machine conf include 链。
- 不选择可用 machine。
- 不决定 exit-code/remedy。
- 不做 UI 时间格式化。
- 不输出面向用户的 error；失败通过 return code / stdout 约定交给调用方。

### `lib/commands.sh`

职责：

- 作为 `cmd_*` 命令编排 module 和 exit seam。
- `cmd_status` 聚合 machine lifecycle state 和 QEMU runtime state，并渲染 UI。
- `cmd_build` 用 `machine_state` 判断 initialized machines 和 build status。
- `cmd_start_qemu` 用 `machine_state` 获取 image path，但不改变 QEMU runtime ownership。
- 保持 exit-code/remedy line 契约。

不负责：

- 不直接 glob `configs/*.snapshot` / `*.init-done`。
- 不直接用 `ls/find` 判断 deploy image。
- 不解析 snapshot JSON。

### `lib/init_pipeline.sh`

职责：

- 保持 `ob init` 8 步流水线。
- Step 6 调用 `machine_state` 写 snapshot。
- Step 7 继续生成 build config。
- Step 8 继续打印 report。

不负责：

- 不直接写 `<machine>.snapshot` 目标文件。
- 不直接写 `init-done marker`。

### `lib/qemu.sh`

职责：

- 保持 QEMU runtime implementation 自包含。
- 继续拥有 QEMU PID file 的读写、校验和清理。
- 继续拥有 QEMU binary、manifest、firmware、ports、SoC、hostkey、command construction。

不负责：

- 不定义 built / failed / never 判定。
- 不直接查找 deploy image；消费 `machine_state` 给出的 image path。

### `lib/repo.sh`

职责：

- 保持 OpenBMC source、source lock、repo URL、machine selection 和 machine conf 解析。
- `print_previously_initialized` 保留为 machine selection UI，但改为消费 `machine_state` records。

不负责：

- 不直接 glob `*.init-done`。
- 不管理 persistent Machine state 写入。

## Interface 形状

具体函数名可在实施计划中微调，但 interface 语义固定如下。

### Records

`machine_state` 提供 list interface，一行一个 machine，字段使用 tab 分隔的 `key=value` records。list record 只包含短字段，不包含 image absolute path。该格式是 `machine_state` 到内部 shell 调用方的 data interface，不直接作为人类 UI 输出。

字段顺序固定：

```text
machine=<name>	init=<none|partial|done>	snapshot=<yes|no>	repos=<n|?>	build=<never|failed|succeeded>	image=<yes|no>	init_time=<UTC ISO or empty>
```

语义：

- `init=partial`：有 `.snapshot`、无 `init-done marker`，保留现有 partial 显示语义但迁移数据源。
- `init=done`：有 `init-done marker`。
- `snapshot=yes`：存在 `<machine>.snapshot`。
- `repos=?`：snapshot JSON 读取失败或 snapshot 不存在。
- `build=succeeded`：存在至少一个 `*.static.mtd`。
- `build=failed`：顶层 `$OPENBMC_DIR/build/<machine>` directory 存在，但没有 `*.static.mtd`。这是当前 `ob status` 行为，不严格等于“build 曾运行且失败”。
- `build=never`：顶层 `$OPENBMC_DIR/build/<machine>` directory 不存在。
- `image=yes`：存在至少一个 `*.static.mtd`。
- `init_time`：marker 中的原始 UTC ISO，不在 module 内格式化。

### 单 machine 查询

`machine_state` 需要支持单 machine 查询 image path。image path 不进入 list record，避免 list 输出过长。

多个 image 时：

```text
find deploy-dir -maxdepth 1 -name "*.static.mtd" -type f -print | sort | head -1
```

查询失败时由 return code 表达，调用方决定是否 exit 3 和打印 remedy line。

## 数据流 / 控制流

### `ob init <machine>`

1. 解析 machine 后，`cmd_init` 调用 `machine_state` 清除旧 completion state：
   - 删除 `<machine>.init-done`
   - 删除 `<machine>.snapshot`
   - 删除废弃的 `<machine>.lock`
2. 如果 `DRY_RUN==1`，上述清理只输出预览，不修改任何 configs 文件，后续 snapshot / marker 写入也只预览。
3. Step 3 初始化 BitBake 环境。
4. Step 4 生成 `deps.json`。
5. Step 5 填充 bare mirror。
6. Step 6 调用 `machine_state` 原子写入 `<machine>.snapshot`。
7. Step 7 生成 build config。
8. Step 8 打印 report。
9. `print_report` 之后调用 `machine_state` 原子写入 `<machine>.init-done`。

### `ob status`

1. `cmd_status` 调用 `machine_state` list records。
2. `cmd_status` 调用 `qemu.sh` 现有 PID file 逻辑获取 QEMU runtime 视图。
3. `cmd_status` 渲染 Main Repository、Machines、QEMU Instances 和 tips。
4. `machine_state` 不参与 UI 格式化。
5. 旧 `.lock` 单独存在时，该 machine 不进入 status 列表，也不提示 legacy ignored。

### `ob build [machine]`

1. 指定 machine 时，`cmd_build` 调用 `machine_state` 判断 `init-done marker` 是否存在。
2. 未指定 machine 时，`cmd_build` 从 `machine_state` records 里筛选 `init=done` 的 machines。
3. `partial` 不授予 build 资格。
4. 缺 marker 时仍 exit 3，remedy line 为 `Run 'ob init <machine>' first.`。
5. build 成功摘要里的 image path 通过 `machine_state` 查询。

### `ob start-qemu [machine]`

1. 指定 machine 时，`cmd_start_qemu` 先通过 `machine_state` 判断 initialized，再获取 image path。
2. 未指定 machine 时，`cmd_start_qemu` 从 `machine_state` records 里筛选 `build=succeeded` 的 machines。
3. QEMU runtime 检查、PID file、ports 和启动仍在 `qemu.sh`。
4. 缺 init marker 时 remedy line 为 `Run 'ob init <machine>' first.`。
5. init done 但未 built 时 remedy line 为 `Run 'ob build' first.`。

### `repo.sh::print_previously_initialized`

1. `repo.sh` 仍负责 machine selection UI。
2. `print_previously_initialized` 从 `machine_state` records 读取 `init=done` 和 `init_time`。
3. `repo.sh` 使用 `format_timestamp` 做 UI 格式化。
4. `repo.sh` 不再直接 glob `*.init-done`。

## 状态语义

| snapshot | init-done marker | 顶层 build dir | image | status init | status build | build/start-qemu 资格 |
|---|---|---|---|---|---|---|
| no | no | no | no | none | never | no |
| no | no | yes | no | none | failed | no |
| no | no | yes | yes | none | succeeded | no |
| yes | no | no | no | partial | never | no |
| yes | no | yes | no | partial | failed | no |
| yes | no | yes | yes | partial | succeeded | no |
| no | yes | no | no | done | never | build yes, start-qemu no |
| yes | yes | no | no | done | never | build yes, start-qemu no |
| no | yes | yes | no | done | failed | build yes, start-qemu no |
| yes | yes | yes | no | done | failed | build yes, start-qemu no |
| no | yes | yes | yes | done | succeeded | build yes, start-qemu yes |
| yes | yes | yes | yes | done | succeeded | build yes, start-qemu yes |

说明：

- `init-done marker` 是唯一 initialized / buildable 信号。
- `machine snapshot` 不表示 init 完成。
- `.snapshot` 硬切后，旧 `.lock` 完全不参与状态计算。
- partial 只表示最近一次 init 已经生成 snapshot，但没有写入 marker。
- status build 三态独立于 init 状态，只由顶层 build dir 和 image 推导，record 中始终是 `never` / `failed` / `succeeded` 之一。
- `failed` 的目录判定路径固定为顶层 `$OPENBMC_DIR/build/<machine>`，用于保留当前 `ob status` 用户可见行为；它不严格等于“build 曾运行且失败”。

## 错误处理与回退

### Snapshot JSON 坏掉

`machine_state` list records 返回 `repos=?`，不中断 `ob status`。snapshot JSON 读取失败不影响 `init=partial/done`，因为这些由文件存在性和 marker 决定。

### Snapshot 写入失败

写入同目录临时文件失败或 `mv` 失败时，函数返回非零，不留下半截目标文件。当前 `generate_lockfile` 直接 `open(target, 'w')` 的非原子行为要消除。调用方决定打印错误并 exit 1。

### Marker 写入失败

写入同目录临时文件失败或 `mv` 失败时，函数返回非零。因为 marker 是完成信号，调用方不得继续报告 init 成功。

### Dry-run 清理

`DRY_RUN==1` 时，清理旧 marker/snapshot/legacy lock 和写入新 snapshot/marker 都不得修改磁盘。现有 `cmd_init` 直接 `rm -f <machine>.init-done` 的行为是既有漏洞，本设计要求一并修正。

### 缺少 initialized 前置

`ob build <machine>` 和 `ob start-qemu <machine>` 缺 `init-done marker` 时 exit 3，diagnostic line 可以说明 marker 缺失，remedy line 保持一条可执行下一步：

```text
Run 'ob init <machine>' first.
```

### 已 init 未 build

`ob start-qemu <machine>` 找不到 image path 时 exit 3，remedy line 保持：

```text
Run 'ob build' first.
```

### 多个 image

不报错，排序后选择第一个，保持现有“找到一个 image 即可”的用户可见行为，同时让选择确定化。

## 测试策略

### Static gates

扩展 `tools/exit_contract.py`，把 Y 规则从“仅 `util.sh`”扩展为按 basename 配置 leaf-pure modules，例如：

```text
LEAF_EXIT_EXCEPTIONS_BY_BASENAME = {
  'util.sh': EXIT_EXCEPTIONS,
  'machine_state.sh': set(),
}
```

`machine_state.sh` 中任何真实 `exit` 都必须让 `tools/ob_check.sh` 失败。只跑现有 `ob_check.sh` 而不扩展 `exit_contract.py` 不足以验证成功标准 6。

### Unit tests

新增 `tests/unit/machine_state.sh`，覆盖：

- 无 snapshot / 无 marker 时不列出 machine。
- 有 snapshot / 无 marker 时 `init=partial`。
- 有 marker 时 `init=done`。
- marker 存在但 snapshot 不存在时仍 `init=done`，`repos=?`。
- snapshot JSON 坏掉时 `repos=?`，函数不失败。
- 顶层 `$OPENBMC_DIR/build/<machine>` directory 存在但 image 缺失时 `build=failed`。
- 无 build directory 时 `build=never`。
- 多个 image 时选择排序后的第一个。
- snapshot 原子写入，不直接写目标文件。
- marker 原子写入。
- 清理函数删除 marker、snapshot 和旧 `.lock`。
- `DRY_RUN==1` 时清理/写入函数不修改 configs 文件。
- `machine_state` 函数不直接 exit，并由 `exit_contract.py` 静态门禁验证。

### Orchestration tests

调整 `tests/orchestration/generate_config.sh` 或新增 orchestration 测试，覆盖：

- Step 6 写 `<machine>.snapshot`。
- dry-run 不写 snapshot。
- 旧 `<machine>.lock` 不再作为输出断言。
- report 中的 snapshot 路径文案与新命名一致。
- `repo.sh::print_previously_initialized` 使用 `machine_state` records，不直接 glob init-done。

### Protocol tests

调整现有 protocol 测试，覆盖：

- `ob init <machine> --dry-run` 不删除已有 marker/snapshot/legacy lock。
- `ob build <machine>` 缺 marker 仍 exit 3，remedy line 不变。
- `ob start-qemu <machine>` 缺 marker / 缺 image 的 remedy line 不变。
- 旧 `.lock` 单独存在时，该 machine 从 `ob status` 列表消失，不显示 partial，也不提示 legacy ignored。
- `.snapshot` 单独存在时 `ob status` 显示 partial。
- `ob status` 保留 build failed 显示能力。

### Full check

修改 `ob` 或 `lib/*.sh` 后必须运行：

```bash
tools/ob_check.sh
```

当前 `tools/ob_check.sh` 的 `OB_SOURCES` 通过 `lib/*.sh` glob 自动包含新增 lib 文件，不需要手工登记 `machine_state.sh`。如果 shellcheck baseline 因新增文件发生自动重生成，必须检查 `tests/.shellcheck-baseline` diff，确认没有新增告警被误吞。

本设计还要求 `tools/exit_contract.py` 一并更新，否则 `ob_check.sh` 全绿也不能证明 `machine_state.sh` 不 exit。

## 文档更新

需要同步：

- `CONTEXT.md`：`machine snapshot` 已作为 canonical term；`function semantic layer` 需更新为六文件边界，并说明 `machine_state=Machine lifecycle state`。其中 `exit_contract` Y 规则描述也要同步为按 basename 配置的 leaf-pure modules（`util.sh` / `machine_state.sh`），不再写成只断言 `util.sh`。
- `docs/adr/0001-init-done-marker.md`：已修正为当前 `machine snapshot` 设计。
- 代码注释：`init_pipeline.sh` 中 Step 6 从 lockfile 改为 snapshot。
- 测试说明：不再使用 lockfile 作为 machine snapshot 的名称。

## 评审关注点

评审 agent 请重点检查：

1. `machine_state` 与 `qemu.sh` 的 seam 是否清楚，是否仍有 lateral coupling 风险。
2. `machine_state` interface 是否足够窄，尤其是 build artifact view 是否被约束住。
3. `.lock` 硬切不兼容是否会造成不可接受的用户体验或测试盲点。
4. partial 语义是否和 `init-done marker` ADR 一致。
5. list record 的 `key=value` 一行格式是否适合 Bash 消费。
6. build 三态是否完整保留当前 `ob status` 用户可见行为。
7. dry-run 零副作用是否被测试覆盖。
8. `machine_state` 不 exit 是否由 `exit_contract.py` 而不是人工约定守护。

## 本轮评审意见处理记录

已吸收：

- 扩展 exit-contract 门禁，守护 `machine_state.sh` 不 exit。
- 明确 `ob init --dry-run` 清理/写入零副作用，并把现有 marker dry-run 漏洞列入修复范围。
- 保留 `ob status` build failed 态，record 改为 `build=<never|failed|succeeded>`。
- 修正 partial 描述：保留现有显示语义，仅迁移数据源 `.lock` 到 `.snapshot`。
- 将 `repo.sh::print_previously_initialized` 纳入迁移范围。
- 在背景中明确文档/ADR 已切换而代码滞后的 drift。
- 点名 4 个 deploy image 查找点都要迁移。
- 补充 snapshot 非原子写入是现状问题。

部分吸收并修正口径：

- `ob_check.sh` 当前使用 `lib/*.sh` glob，新增 lib 文件不需要手工加入 `OB_SOURCES`；但 shellcheck baseline diff 仍需人工检查。
- image 查找仍归 `machine_state`，但 module 定位从“仅 persistent state”修正为“Machine lifecycle state：persistent state + build artifact view”，避免概念漂移。

未吸收为本次范围：

- 不新增 partial-specific status tip。该建议是 UX 改进，不是本次 deepening 的必要条件；缺 marker 的命令 remedy 仍由 `ob init <machine>` 承担，status tips 保持现状。

进一步评审已吸收：

- `build=failed` 的目录判定路径钉死为顶层 `$OPENBMC_DIR/build/<machine>`，保持当前 `ob status` 用户可见行为。
- 状态语义表不再使用 `derived`，build record 始终是 `never` / `failed` / `succeeded` 之一。
- 文档更新项补充 `CONTEXT.md` 中 `exit_contract` Y 规则描述也要同步为 leaf-pure modules 集合。

进一步评审转入实施计划注意事项：

- 扩展 `exit_contract.py` 后，Y 规则报错文案要按 basename 动态显示，不要继续写死 `util.sh`。
- 实施 `machine_state.sh` 时保持函数边界可被 `tools/extract_funcs.py` 解析，避免 leaf-pure exit 检查落空。

## 未决事项

无待确认事项。设计评审如提出新的阻塞意见，应先修订本设计文档，再进入实施计划。
