# 质量门禁与 Eval 模式库

## 元数据

- **类型**: BestPractice
- **适用场景**: 给某个 action / 流水线 / 产出设计质量门禁时；判断"这个环节该怎么验证"时；缓存命中率下降要排查时
- **创建日期**: 2026-06-24
- **来源**: 克谦方法论质量门禁原则 × 本仓库 eval 设施归纳

## 这个 skill 干什么

本仓库的 eval 实践（`exit_contract.py` / `ob_check.sh` / `coverage_radar.py` / 四层测试）散落在工具脚本和 OBSERVATIONS 里。这个 skill 把它们**反向归纳成可复用的门禁模式**，让你遇到"怎么给某个 action 加门禁"时有现成范式可套，而不是每次重新发明。

它不是 SOP——给的是模式 + 本仓库实例锚定 + 已知陷阱，具体怎么用由你按场景判断。核心原则是 [V6 概率乘](../axioms/v06_probability_multiplication.md)：每个 action 配一个 eval，让概率乘的分母里没有黑箱环节。

## 四种门禁模式（用本仓库实例锚定）

### 模式 1：Action-Eval 对（细粒度，逐 action）

每个 action 对应一个可执行 eval，不通过就修复。适用于高质量要求的核心流程。

- **本仓库实例**：`exit_contract.py` 的 X/Y/Z 三条 exit 纪律，每条都有 `tests/protocol/` 自测钉死（usage_dispatch_sync.sh 断言 dispatch 与 --help 一致防漂移）。exit 码契约从"死约定"升级为"可机器验证的纪律"。
- **成本**：高，但缓存命中也高（同一段规则被反复检查）。

### 模式 2：阶段门禁（粗粒度，阶段结束聚合）

每个开发阶段结束时做一次综合 eval，不通过回滚到阶段起点。适用于非代码产出（文档、设计）和"改完一类东西"的配套自检。

- **本仓库实例**：`ob_check.sh`——改完 ob/lib 后一站式跑 4 项（extract_funcs GAPS / shellcheck baseline / exit_contract / run_all）。规则钩子落在 `AGENTS.md` Working Mode。
- **关键纪律**：baseline 判定式重生成——纯行号平移/告警减少自动修复，**新增告警机器报错不静默吸收**（不架空 CI 硬门禁）。

### 模式 3：持续监控（后台扫描漂移）

定时扫描，发现偏差触发修复。适用于长期维护、防文档/代码漂移。

- **本仓库实例**：CI shellcheck baseline（行号无关判定防退化）+ AI Heartbeat 的 reflector（L2 每周反思，清理低价值观测、候选规则晋升）。

### 模式 4：CICD 集成式复盘（批量验证 + 失败模式分析）

跑测试套件出报告，分析失败模式改进 harness。适用于可自动化测试的代码产出。

- **本仓库实例**：`run_all.sh` 四层测试（protocol/unit/orchestration/integration）+ `coverage_radar.py` 盲区透明化（ob + lib/*.sh 全部函数按五档列全自动化归属，不制造覆盖率虚高；F5 修复 radar scope：06-22 模块化后曾失效只测 ob 入口 3 函数，扩到 ob+lib ~134（06-22 时；随模块增长现已更多），cross_check 不再静默丢弃 out-of-scope 声明）。覆盖率定义 = 分层各司其职，**非单一行覆盖**。

## acceptable threshold

不同业务阈值不同，关键是在【期望预算内、期望时间内】出【期望结果】。AI-Native 迭代 3-5 轮是较理想的 threshold（见 [V6](../axioms/v06_probability_multiplication.md) 应用判定表）。不要指望一次成型。

本仓库实际阈值：unit 冲函数级 ≥95%、protocol 覆盖子命令×分支退出码、orchestration 覆盖高价值编排、integration 兜端到端。

## 缓存飞轮的可观测（反直觉：多烧 ≠ 多花钱）

严格门禁 → 同一段 context 被反复访问 → 高缓存命中 → 缓存 token 近乎免费 → 迭代修复实际成本坍塌。这是 [V6](../axioms/v06_probability_multiplication.md) 2.6 的正向飞轮。

**别手动省 token**——它往往在破坏飞轮（宽松门禁→一次通过→低缓存命中→质量差→返工→总成本更高）。

观测飞轮健康度：`python3 tools/cache_hit_rate.py`。命中率持续走低 = 门禁在松或 context 在碎。本仓库实测长会话 95-98%、整体 96%。

## 可用资源

- `tools/exit_contract.py` — exit 纪律静态门禁（模式 1）
- `tools/ob_check.sh` — ob/lib 改动一站式配套自检（模式 2）
- `tools/coverage_radar.py` — 覆盖度雷达，盲区透明化（模式 4）
- `tools/cache_hit_rate.py` — 缓存命中率观测（飞轮健康度）
- `tests/run_all.sh` — 四层测试调度（模式 4）
- `contexts/memory/OBSERVATIONS.md` — 历史门禁设计决策背景

## 已知陷阱

| 陷阱 | 表现 | 应对 |
|------|------|------|
| baseline 静默吸收新告警 | ob_check baseline 重生成时把新增 shellcheck 告警也吸收，架空 CI 硬门禁 | baseline 判定式：告警减少自动修复，**新增机器报错不静默**（06-22 真实教训） |
| 文档 eval 比代码 eval 难 | 代码能跑测试，文档质量难自动化 | 技术栈选择模板化；功能点别只给 3 个用例敷衍，但防过度设计 |
| 黑箱 action | action 没 eval，成功率未知 | 每个 action 配 eval；拿不准就配（概率乘的隐形炸弹） |
| 优化错环节 | 给已 0.99 的环节加投入 | 杠杆点是最弱环节，加修复轮数而非堆严格度 |
| 忘记更新 SKILLS_INDEX | 新门禁设施没人知道 | 写完工具立即更新 `rules/03_WORKSPACE.md` 路由 + 本 skill 可用资源 |

## 与现有 skill 的关系

- 是 [bestpractice_02 AI 编程核心方法论](bestpractice_02-ai_programming_mindset.md)「70% 问题 / 成功标准」的落地形态——02 讲为什么要有 feedback loop，08 讲门禁的具体模式。
- 与 [bestpractice_06 ob 优先](bestpractice_06-ob_first.md) 同属"可机器验证的纪律"族：exit 码契约是门禁，ob 优先是门禁。
- 上游公理：[V6 概率乘](../axioms/v06_probability_multiplication.md)（第一性原理）、[V2 可验证性](../axioms/v02_verifiability.md)（地基）、[M1 闭环校准](../axioms/m01_closed_loop_calibration.md)。
