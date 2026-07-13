# Skills Index

本索引指向可复用的 Skills（技能）—— AI 可以调用的工作流程和最佳实践。

- **想使用某个能力** → 浏览下方分类，找到对应的 skill 文件
- **想添加新 skill** → 见底部[「如何添加你自己的 Skill」](#如何添加你自己的-skill)

---

## 分类索引

### Workflow（工作流）

特定任务的完整工作流程。

- [OpenBMC 开发环境初始化](skills/workflow_01-obmc_env_init.md) — 首次 `ob init` 或重建 OpenBMC 开发环境时使用。
- [OpenBMC recipe 源码开发（ob dev modify）](skills/workflow_02-obmc_dev_modify.md) — 改 recipe 源码时用 `ob dev modify`/`list`/`refresh`，而非手动 devtool。

### BestPractice（最佳实践）

通用的最佳实践和经验教训。

- [Skill 写作指南（Meta-Skill）](skills/bestpractice_01-skill_writing.md) — 创建或重写任何 skill 时使用。
- [AI 编程核心方法论](skills/bestpractice_02-ai_programming_mindset.md) — 启动新功能或新项目前，确认问题定义、成功标准和验证方式。
- [AI 辅助调试诊断](skills/bestpractice_03-ai_debugging_diagnosis.md) — 遇到构建失败、运行异常或接口报错时优先参考。
- [时间敏感信息验证](skills/bestpractice_04-temporal_info_verification.md) — 涉及版本号、spec 引用、发布时间等可能过时的信息时使用。
- [Yocto 编译中 npm 网络超时](skills/bestpractice_05-npm_network_timeout_in_yocto.md) — `do_compile` 阶段 npm install 报 ETIMEDOUT 时的诊断与修复策略。
- [ob 优先（统一前门）](skills/bestpractice_06-ob_first.md) — 做 OpenBMC 环境动作前，先查 ob 是否提供该能力并优先调用 `ob <cmd>`。
- [Bash strict mode 管道退出码陷阱](skills/bestpractice_07-bash_strict_mode_pipes.md) — 在 `set -euo pipefail` 下写 `cmd | grep/awk/head` 管道时，避免下游非零退出码被 pipefail 当硬错误中止脚本。
- [质量门禁与 Eval 模式库](skills/bestpractice_08-eval_gate_patterns.md) — 给某个 action/流水线设计门禁时；归纳本仓库 exit_contract/ob_check/coverage_radar/四层测试成 4 种可复用门禁模式 + 缓存飞轮观测。
- [非功能性改动的回归锁（调用次数 / 快路径断言）](skills/bestpractice_09-nonfunctional_regression_locks.md) — 做性能/去重/缓存这类不改输出的优化时，用调用次数或零调用断言把收益钉成可回归验证的硬约束。
- [深模块抽取族（收敛散落逻辑 + leaf-pure 静态门禁）](skills/bestpractice_10-deep_module_extraction.md) — 在 ob/lib 把散落 helper/决策/选择/实例逻辑收敛到一个深 module 时；含 god-function 拆解的副作用次序不变量 + leaf-pure 纯度门禁。

---

## 如何添加你自己的 Skill

创建或重写 skill 前，先读 [`bestpractice_01-skill_writing.md`](skills/bestpractice_01-skill_writing.md)。它说明如何用目标、验收标准、可用资源和输出规格定义一个 skill，而不是把 skill 写成机械步骤清单。

文件命名建议采用 `<category>_<NN>-<name>.md`，例如 `workflow_01-my_process.md`、`bestpractice_01-my_insight.md`。写完后在本 INDEX 的对应分类下添加入口，确保后续 agent 能找到。

## Progressive Disclosure

Skills 采用渐进式披露原则：
- **05_SKILLS_INDEX.md** 提供概览，快速定位
- **具体 skill 文件** 包含完整的操作步骤和示例