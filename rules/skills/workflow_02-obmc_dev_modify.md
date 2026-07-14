# OpenBMC recipe 源码开发（ob dev modify）

## 元数据

- **类型**: Workflow
- **适用场景**: 改 OpenBMC 某 recipe 的源码（devtool modify 阶段）：把 recipe 源码检出到本地、改、（预留）增量 build/deploy
- **创建日期**: 2026-07-13

---

## 目标

agent 遇到"改某功能/组件源码"意图时，用 `ob dev` 把 recipe 源码检出到本地工作区（devtool modify），而非手动进 build env 跑 devtool。`ob` 提供权威检索 + 执行，agent 做语义推理（功能→recipe）。

## 工作流

1. **识别意图**：用户要改某功能/组件的源码。
2. **已知 recipe 名** → `ob dev --machine <machine> modify <recipe>`。
3. **未知 recipe** → `ob dev --machine <machine> list [pattern]`（读 JSONL 缓存，毫秒级；未知时无 pattern 拉全量）→ 基于 `summary` 字段推理选定 recipe → `ob dev --machine <machine> modify <recipe>`。
4. **遇 `exit 3`** → 读 stderr 的 remedy 行，补前置（`ob init <machine>` / `ob dev --machine <m> refresh` / `ob dev --machine <m> list`）。
5. **modify 成功** → 从 stdout 读 srctree 绝对路径（恰好一行）→ `cd` 过去改源码。
6. **cache stale**（layer 变化）或 list 结果可疑 → `ob dev --machine <machine> refresh` 重生缓存。
7. **后续 build/deploy/finish** 待 `ob` 提供（预留闭环，本轮不实现）。

## porcelain 契约（agent 解析）

`ob dev` 是 agent-facing 命令。**stdout 只解析契约数据**(list JSONL / modify srctree);**非零退出时必须读 stderr** 取 remedy/诊断(exit 3 remedy 含下一条 ob 命令)。logo/进度/诊断全在 stderr:
- `ob dev --machine <m> list [pattern]` stdout：JSONL，每行 `{"recipe","layer","summary"}`。
- `ob dev --machine <m> modify <recipe>` stdout：恰好一行 srctree 绝对路径。
- `ob dev --machine <m> refresh` stdout：空。

## 边界

**ob dev 做**：recipe 元数据检索（`list`，读缓存）/ devtool modify 执行（`modify`，输出 srctree）/ 缓存重生（`refresh`）。

**ob dev 不做**（agent 自由区）：手改 recipe 元数据（.bb）、解析 bitbake 日志、recipe 依赖图分析、批量 modify、增量 build / 部署 / finish（预留闭环，待 ob 提供）。

## 验收标准

无上下文 agent 据此可自检：
- 动手改 recipe 源码前，是否先查 `ob --help` 确认 `ob dev` 能力？
- 命中时是否用 `ob dev modify` 而非手动 devtool？
- 遇 `exit 3` 是否读 remedy 补前置，不转手动？
- 是否按 stdout 契约解析（JSONL / srctree 恰好一行），忽略 stderr？
