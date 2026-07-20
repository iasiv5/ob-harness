# OpenBMC recipe 源码开发（ob dev modify）

## 元数据

- **类型**: Workflow
- **适用场景**: 改 OpenBMC 某 recipe 的源码（devtool modify 阶段）：把 recipe 源码检出到本地、改、增量 build；image 级干净验证用 `ob deploy-to-qemu`（已设计 [../../docs/specs/2026-07-20-ob-deploy-to-qemu-design.md](../../docs/specs/2026-07-20-ob-deploy-to-qemu-design.md)，待实现；非 recipe 热推）
- **创建日期**: 2026-07-13

---

## 目标

agent 遇到"改某功能/组件源码"意图时，用 `ob dev` 把 recipe 源码检出到本地工作区（devtool modify），而非手动进 build env 跑 devtool。`ob` 提供权威检索 + 执行，agent 做语义推理（功能→recipe）。

## 工作流

1. **识别意图**：用户要改某功能/组件的源码。
2. **已知 recipe 名** → `ob dev --machine <machine> modify <recipe>`。
3. **未知 recipe** → `ob dev --machine <machine> list [pattern]`（读 JSONL 缓存，毫秒级；未知时无 pattern 拉全量）→ 基于 `summary` 字段推理选定 recipe → `ob dev --machine <machine> modify <recipe>`。
4. **遇 `exit 3`** → 读 stderr 的 remedy 行，补前置（`ob init <machine>` / `ob dev --machine <m> refresh` / `ob dev --machine <m> list`）。
5. **modify 成功** → 从 stdout 读 srctree 绝对路径（恰好一行）→ `cd` 过去改源码。改完用 `ob dev --machine <machine> build <recipe>` 做单 recipe 编译验证（devtool build / do_build；空 stdout，exit code 承载成败 0=编通/1=失败，bitbake log 在 stderr；未 modified → exit 3 + modify remedy）——补 modify→reset/finish 内循环编译洞，vs `ob build <machine>` 编整个 image。
6. **cache stale**（layer 变化）或 list 结果可疑 → `ob dev --machine <machine> refresh` 重生缓存。
7. **收尾 reset**（modify 的镜像逆操作）：源码改完不再需要 externalsrc 绑定时，`ob dev --machine <machine> reset <recipe>` 解除 externalsrc（默认 source-preserving，**不递归删源码**；无 `--remove-work`，收到即 exit 1）。从 stdout 读恰好一行 JSON 的 `disposition` 字段判断处置：
   - `moved`：srctreebase 归档到 `<devtool build workspace>/attic/sources/<recipe>.<timestamp>`（devtool build workspace = `<OPENBMC_DIR>/build/<machine>/workspace`，**非** ob-harness 顶层 `workspace/`；精确子目录不可用，`destination_parent` 只给到 `attic/sources`）。
   - `retained`：srctreebase 是外部目录，reset 保留不动。
   - `removed` / `absent`：空目录被 rmdir / 本来就不存在。
   - `noop`：未 modified，无需 reset。
   **agent 不得自动清理 attic，也不得按 mtime/name 猜最新 attic 子目录**——需删除归档时由用户明确检查后手动处理。reset 期间不得与其他 ob/devtool workspace writer 并发（不支持并发 writer，二次 status 仅检测异常不提供 snapshot isolation）。
8. **build 已实现**（内循环单 recipe 编译，见步骤 5）；**验证（image 级重建 + QEMU 重启）→ `ob deploy-to-qemu <machine>`**（干净验证；非 recipe 热推——热推状态不干净、验证不权威；已设计 [../../docs/specs/2026-07-20-ob-deploy-to-qemu-design.md](../../docs/specs/2026-07-20-ob-deploy-to-qemu-design.md)，待实现；编排 = build-first：`bitbake obmc-phosphor-image` → QEMU 在跑则读旧 `.pid` 端口 + `qemu_instance_stop` + 注入 `QEMU_*_PORT` 端口复用 → `qemu_prepare_launch` + `qemu_execute_launch`，没跑则 build + start；exit 0/1/2/3，BMC-ready 超时只 warn 不算失败）；**finish 已实现**——modify 的「落回」终态（与 reset「丢弃」对称）：源码改动 `git commit` 到 srctree 后，`ob dev --machine <machine> finish <recipe>` 把改动以 patch landing 形式落回 recipe 原属 layer（生成 `.patch` 加进 `SRC_URI`，或更新 `SRCREV` 指向 srctree HEAD；devtool 自动判定 mode），解除 externalsrc 让 recipe 退出 workspace。从 stdout 恰好一行 JSON 读 `landing_mode`（patch/srcrev/null，**ob 按落地文件落点观测分类**——`.patch` 变→patch、`.bb`/`.bbappend` 变→srcrev，非 devtool `_guess_recipe_update_mode` 上游分支判定的 mode 真值，混合脏 srctree 可能偏离，消费方需知晓此语义）+ `patches`/`recipe_files`（相对 layer 路径 array）+ `disposition`（srctreebase 物理去向，与 reset 同构五态：moved→归档 `<devtool build workspace>/attic/sources/<recipe>.<timestamp>`（路径同 reset moved 注）/ retained / removed / absent / noop）。物理层 source-preserving（devtool finish 内部 `_reset` 归档 srctreebase，ob 不做 safety copy）。单 writer 假设（无并发，见 ADR-0009）。**落回≠丢弃**：落回把改动持久化进 layer，丢弃只保留源码副本到 attic。

## porcelain 契约（agent 解析）

`ob dev` 是 agent-facing 命令。**stdout 只解析契约数据**(list JSONL / modify srctree);**非零退出时必须读 stderr** 取 remedy/诊断(exit 3 remedy 含下一条 ob 命令)。logo/进度/诊断全在 stderr（含 devtool/tinfoil 初始化块——"Machine … found in"、"Common targets are"、devtool/bitbake-layers 路径、tinfoil "INFO"/"emitted=N skipped=N" 计数——等正常噪声；agent 取诊断/remedy 时定位 `[ERROR]`/`[WARN]` 行，不要把整段初始化日志当诊断）：
- `ob dev --machine <m> list [pattern]` stdout：JSONL，每行 `{"recipe","layer","summary"}`。
- `ob dev --machine <m> modify <recipe>` stdout：恰好一行 srctree 绝对路径。
- `ob dev --machine <m> refresh` stdout：空。
- `ob dev --machine <m> reset <recipe>` stdout：恰好一行 JSON `{"recipe","srctree","srctreebase","disposition","destination_parent","destination","cleaned_bbappend"}`，`disposition` ∈ {moved, retained, removed, absent, noop}（`destination_parent` 仅 moved 非 null；`cleaned_bbappend` 为被 devtool 移除的 workspace `.bbappend` 路径，noop 为 null）；`destination` **恒 `null`**（reset 不写 destination，moved 归档落点看 `destination_parent`）。
- `ob dev --machine <m> status` stdout：JSONL，每行 `{"recipe","srctree"}`；无 modified recipe 时 stdout 空 + stderr `[WARN] No modified recipes for <machine>.`。
- `ob dev --machine <m> finish <recipe>` stdout：恰好一行 JSON = reset 七字段 + 五个 landing 字段 `{"landing_mode","landing_layer","patches","recipe_files","srcrev"}`（共 12 字段；`landing_mode` ∈ {patch, srcrev, null}，`patches`/`recipe_files` 为 JSON array（相对 layer 路径），noop 时 landing 字段 null/`[]`）。消费方注意：reset 七字段中 `destination` **恒 `null`**（落回目标看相对路径的 `landing_layer`）；`disposition==noop` 表示 recipe 未 modified，finish 仍是成功 exit 0 + JSON（landing 字段全 null/`[]`，与 reset noop 对称，非错误）；`landing_mode=="srcrev"` 时 `srcrev` 可为 `null`（recipe 改了但 SRCREV 未抓到，见 CONTEXT.md patch landing）。
- `ob dev --machine <m> build <recipe>` stdout：**空**（exit code 承载成败，0=编通/1=失败；bitbake 编译 log 在 stderr，agent 定位 `[ERROR]` 行；镜像 `refresh` 形态，非 reset/finish 的 JSON）。前置：recipe 必须 modified（未 modified → exit 3 + `Run 'ob dev --machine <m> modify <recipe>' first.` remedy）。

## 边界

**ob dev 做**：recipe 元数据检索（`list`，读缓存）/ devtool modify 执行（`modify`，输出 srctree）/ 单 recipe 编译（`build`，devtool build，空 stdout + exit code 承载成败）/ 缓存重生（`refresh`）/ devtool reset 收尾（`reset`，默认 source-preserving，输出 disposition JSON）/ devtool finish 落回（`finish`，落回 recipe 原属 layer + landing 观测，输出 12 字段 JSON）。

**ob dev 不做**（agent 自由区）：手改 recipe 元数据（.bb）、解析 bitbake 日志、recipe 依赖图分析、批量 modify、image 级部署验证（image 级重建 + QEMU 重启 → `ob deploy-to-qemu`，已设计待实现，见步骤 8；非 ob dev 职责——碰运行态 + image 级，属 ob 顶层 QEMU 生命周期层，归属见 [ADR-0011](../../docs/adr/0011-ob-deploy-to-qemu-toplevel-ownership.md)）。

## 验收标准

无上下文 agent 据此可自检：
- 动手改 recipe 源码前，是否先查 `ob --help` 确认 `ob dev` 能力？
- 命中时是否用 `ob dev modify` 而非手动 devtool？
- 遇 `exit 3` 是否读 remedy 补前置，不转手动？
- 是否按 stdout 契约解析（list JSONL / modify srctree 恰好一行 / reset 单行 JSON 的 disposition），忽略 stderr？
- 收尾 reset 后是否只读 `disposition` 判断处置，**不自动清理 attic**（需删除归档时用户手动检查）？
- finish 遇 `phase=landing`（exit 1、stdout 空，recipe 已退出 workspace 但 landing 探测失败）时，是否人工 `git -C <OPENBMC_DIR> status` 检查 `<landing_layer>` 下 `.patch`/`.bb`/`.bbappend` 改动并决定保留或 `git restore -- <file>` 回退（**不 reset**，recipe 已落回）？
