# Know-how Index

本索引指向可复用的 Know-how（实操经验）—— AI 可以参考的工作流程和最佳实践。

- **想使用某个能力** → 浏览下方分类，找到对应的 know-how 文件
- **想添加新 know-how** → 见底部[「如何添加你自己的 Know-how」](#如何添加你自己的-know-how)

## Know-how 消费速则（每会话强制）

读任何 `knowhow/*.md` 全文时：① 必须读到尾部的"已知陷阱/故障排除/限制"段才算读够（最高价值的踩坑记录常沉在末段）；短文件（≤100 行）整篇可扫完，尾段约束主要针对长文件；② 长文件（>100 行）顶部**必须**配 TL;DR（30 秒核心判定），生产者义务见 ADR-0015；消费者先读 TL;DR 拿判定；③ 前半段的"能力清单/边界"不足以安全使用，只读前半截就动手是高发陷阱。规则详见 [`bestpractice_01`](knowhow/bestpractice_01-knowhow_writing.md)「消费者视角」节。

**④ 每会话 user 层注入（硬要求）**：加载本 INDEX 后，检查 `contexts/knowhow/07_USER_KNOWHOW_INDEX.md`——存在则读其全文注入上下文（user know-how 概览，与 product 层对称），不存在则跳过（新环境无 user 沉淀）。详见文末「User Know-how」段。

---

## 分类索引

### Workflow（工作流）

特定任务的完整工作流程。

- [OpenBMC 开发环境初始化](knowhow/workflow_01-obmc_env_init.md) — 首次 `ob init` 或重建 OpenBMC 开发环境时使用；含 `ob build`/`ob smoke` 故障排除（如 romulus smoke 第3条 FirmwareVersion 缺失、QEMU boot lockup）。
- [OpenBMC recipe 源码开发（ob dev modify）](knowhow/workflow_02-obmc_dev_modify.md) — 改 recipe 源码时用 `ob dev modify`/`list`/`refresh`/`build`/`reset`/`finish` 等子命令，而非手动 devtool。
- [手动经验沉淀（ob 沉淀四步）](knowhow/workflow_04-manual_sedimentation.md) — 踩坑/学到经验后，走"判所有权 → 判层 → 写 → 收口"四步，把它沉淀到正确的层（product/user）与子层，落盘即收口。

### BestPractice（最佳实践）

通用的最佳实践和经验教训。

- [Know-how 写作指南（Meta）](knowhow/bestpractice_01-knowhow_writing.md) — 创建或重写任何 know-how 时使用。
- [AI 编程核心方法论](knowhow/bestpractice_02-ai_programming_mindset.md) — 启动新功能或新项目前，确认问题定义、成功标准和验证方式。
- [AI 辅助调试诊断](knowhow/bestpractice_03-ai_debugging_diagnosis.md) — 遇到构建失败、运行异常或接口报错时优先参考。
- [时间敏感信息验证](knowhow/bestpractice_04-temporal_info_verification.md) — 涉及版本号、spec 引用、发布时间等可能过时的信息时使用。
- [Yocto 编译中 npm 网络超时](knowhow/bestpractice_05-npm_network_timeout_in_yocto.md) — `do_compile` 阶段 npm install 报 ETIMEDOUT 时的诊断与修复策略。
- [ob 优先（统一前门）](knowhow/bestpractice_06-ob_first.md) — 做 OpenBMC 环境动作前，先查 ob 是否提供该能力并优先调用 `ob <cmd>`。
- [Bash strict mode 管道/重定向/errexit 陷阱族](knowhow/bestpractice_07-bash_strict_mode_pipes.md) — `set -euo pipefail` 下"失败被静默"或"想静默却静默不掉"类 bug:管道下游非零退出码被 pipefail 当硬错误、无命令 `exec` 持久重定向吞 stderr、`if/||/$()` 禁用 errexit 吞 fs 失败、`< 文件` 打开失败早于子命令的 2>/dev/null。
- [质量门禁与 Eval 模式库](knowhow/bestpractice_08-eval_gate_patterns.md) — 给某个 action/流水线设计门禁时；归纳本仓库 exit_contract/ob_check/coverage_radar/四层测试成 4 种可复用门禁模式 + 缓存飞轮观测。
- [非功能性改动的回归锁（调用次数 / 快路径断言）](knowhow/bestpractice_09-nonfunctional_regression_locks.md) — 做性能/去重/缓存这类不改输出的优化时，用调用次数或零调用断言把收益钉成可回归验证的硬约束。
- [深模块抽取族（收敛散落逻辑 + leaf-pure 静态门禁）](knowhow/bestpractice_10-deep_module_extraction.md) — 在 ob/lib 把散落 helper/决策/选择/实例逻辑收敛到一个深 module 时；含 god-function 拆解的副作用次序不变量 + leaf-pure 纯度门禁。
- [CLI 交互 prompt 卡壳：读逃生路径，别逐行回答](knowhow/bestpractice_11-interactive_prompt_bypass.md) — ob 或其他 CLI 弹出交互菜单时，别用 send_to_terminal 逐行喂答案；先读 prompt/报错自带的逃生提示、查 --help 的 --flag/ENV_VAR，一步跳过。
- [经验沉淀的分层判定](knowhow/bestpractice_12-knowledge_layering.md) — 踩坑后有了一条经验，先走"三问路由"判定它该进哪层：源于 ob-harness 自身且别人会同样复发的进仓库分发层（rules/knowhow），纯环境/个人健忘的只记会话记忆。落盘即收口（覆盖检查 + 写入 + 更新入口）。
- [给 QEMU 模拟的 BMC EEPROM 注入 FRU 数据](knowhow/bestpractice_13-inject_fru_data_into_bmc_eeprom.md) — QEMU BMC 板载 EEPROM 空导致 set-hostname/inventory 等失败时；两个致命陷阱：entity-manager type 编码反常（字段用 `0xC0|len` 非 `0x80|len`）+ ob 用 custom binary 复制（重编后必须 cp）；四阶段（构造 blob→runtime dd 验证→固化 `at24c_eeprom_init_rom`→重编+cp+回归）。
- [给 QEMU 模拟缺失的 GPIO expander](knowhow/bestpractice_14-simulate_gpio_expander_in_qemu.md) — OpenBMC 服务（psu-manager 等）因 named GPIO line 不存在 SIGABRT（gpiod::find_line throw）时；定位用手动跑 binary 捕获 stderr（比 gdb stripped core 高效）；修法=查 dts expander 总线链+QEMU i2c_init 加 expander（pca9555/9554，kernel 从 dts 读 line names 注册 named line）；陷阱：改 config 名字不够、expander 要挂 dts 匹配总线、clone 错源码 repo。

---

## 如何添加你自己的 Know-how

创建或重写 know-how 前，先读 [`bestpractice_01-knowhow_writing.md`](knowhow/bestpractice_01-knowhow_writing.md)。它说明如何用目标、验收标准、可用资源和输出规格定义一个 know-how，而不是把 know-how 写成机械步骤清单。

文件命名建议采用 `<category>_<NN>-<name>.md`，例如 `workflow_01-my_process.md`、`bestpractice_01-my_insight.md`。`<NN>` 是**永久创建序号**：删除条目后编号不回收、不重排填补，缺口永久保留（所以 workflow 分类是 01/02/04——03 已删，属正常，见 [ADR-0018](../docs/adr/0018-knowhow-numbering-stability.md)）。写完后在本 INDEX 的对应分类下添加入口，确保后续 agent 能找到。

## Progressive Disclosure

Know-how 采用渐进式披露原则：
- **05_KNOWHOW_INDEX.md** 提供概览，快速定位
- **具体 know-how 文件** 包含完整的操作步骤和示例

---

## User Know-how（本地，可能不存在）

除上述随产品分发的 product know-how 外，本环境可能有**本地 user know-how**——不回上游、落在 `contexts/knowhow/`（`.gitignore` 排除，见 [ADR-0017](../docs/adr/0017-knowhow-distribution-boundary.md)），仅本环境有效。其索引为 `contexts/knowhow/07_USER_KNOWHOW_INDEX.md`。

**每次会话加载本 INDEX（05）后，执行一次 user 层注入检查**：检查 `contexts/knowhow/07_USER_KNOWHOW_INDEX.md` 是否存在——**存在则读取其完整内容**（把本环境 user know-how 概览注入上下文，与 product 层对称）；**不存在则跳过**（新环境或尚无 user 沉淀，正常，不报错）。沉淀 user know-how 的流程见 [`workflow_04`](knowhow/workflow_04-manual_sedimentation.md)。