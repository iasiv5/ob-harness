# WORKSPACE.md - 目录路由速查

目标：让 AI 每轮 session 都能快速知道"去哪里找/放什么"。**找任何文件前先查这里。**

## 路由规则

### 项目与代码
- 工具脚本：`tools/`（`parse_bitbake_deps.py` 依赖解析；`extract_funcs.py` 只读体检/GAPS+三段检查（ob GAPS + lib header/函数间/footer 纯函数定义）；`exit_contract.py` exit 纪律静态断言——X exit 值 / Y util.sh 叶子纯度 / Z exit-3 remedy；`ob_check.sh` 改 ob/lib 后一站式配套自检（聚合 extract_funcs/shellcheck baseline(flat 合成+纯文本)/exit-contract/run_all），改完 ob 必跑；`cache_hit_rate.py` Claude Code transcript 缓存命中率观测（飞轮健康度，见 bestpractice_08/V6）；`reorder.py` 已归档 `tools/archive/`——ob 拆为 `lib/*.sh` 后由文件边界接管 § 分区，不再需要物理重排）
- 测试入口与分层调度：`tests/run_all.sh`（默认跑 protocol/unit/orchestration 的 .sh；`--full` 加 .exp 交互矩阵；`--integration` 加 E2E）；分层目录 `tests/{protocol,unit,orchestration,integration,lib}/`，何时用见 `run_all.sh` 顶部
- OpenBMC 环境初始化工具：根目录 `ob`（`./ob init [<machine>]` 一键初始化）（环境生命周期动作先走 ob，见 `rules/skills/bestpractice_06-ob_first.md`）
- `ob` 模块化主体：`lib/`（`util.sh` 底层工具 / `repo.sh` 仓库解析 / `qemu.sh` QEMU runtime / `machine_state.sh` 生命周期状态 / `init_pipeline.sh` init 流水线 / `commands.sh` cmd_* 编排；文件边界即 `function semantic layer`，见 `CONTEXT.md`）
- OpenBMC 工作区（主仓库、子仓库源码、状态文件）：`workspace/`（整体 gitignore，仅保留 `.gitkeep`）；machine/源码状态在 `workspace/configs/`（`<machine>.snapshot` 依赖快照 + `openbmc-source.manifest` 主仓库归属，术语见 `CONTEXT.md`）

### 系统与规则
- 可复用技术方案 / Skill：`rules/skills/`（索引见 `rules/05_SKILLS_INDEX.md`）
- 核心公理（Axioms）：`rules/axioms/`（索引见 `rules/06_AXIOMS_INDEX.md`）
- 记忆系统：`contexts/memory/`
- 领域术语表（canonical / avoid 用词）：根目录 `CONTEXT.md`（讨论 machine snapshot / source manifest / exit-code 契约 / function semantic layer 等术语时查阅）
- AI Heartbeat 心跳子系统（PRD、源码、测试、配置）：`periodic_jobs/ai_heartbeat/`
- GitHub Copilot 入口与 hooks：`.github/`
- GitHub Copilot/Claude Code 仓库级自定义 skills：`.claude/skills/`
- Claude Code 仓库级自定义命令：`.claude/commands/`（如 `/ai-heartbeat` 入口）
- 设计文档：`docs/specs/`（`/brainstorming` skill 落盘，命名 `<YYYY-MM-DD>-<topic>-design.md`；已批准文档为冻结快照，一般不修改）
- 实施计划：`docs/plans/`（`/writing-plans` skill 落盘，命名 `<YYYY-MM-DD>-<feature>-implementation-plan.md`；已完成文档为冻结快照，一般不修改）

> **如何对待 `docs/` 历史文档（设计文档 + 实施计划）：**
> 1. **定位**：它们是**历史决策记录**，说明“当时为什么这么设计/计划”，不保证与当前代码一致。文档越旧，与现状漂移的概率越高（已出现顶部状态标注过时的实例）。
> 2. **加载方式**：它们**不随 session 自动加载**，且已通过 `.vscode/settings.json` 的 `files.exclude` 排除出资源管理器、文本搜索与语义索引（`semantic_search`/`#codebase`/`grep_search` 默认不命中）。要访问时：先用 `list_dir` 列 `docs/specs/`、`docs/plans/` 枚举文件（`list_dir` 不受 `files.exclude` 影响），再用 `read_file` 按路径主动读取；不要预先通读整个目录。
> 3. **事实优先级**：判断**当前实现或行为**时，以代码、recipe、service、配置、日志为准；`docs/` 只用于回溯设计意图和决策背景。不要因为语义检索命中某篇历史文档，就把其中方案当成现状。
> 4. **定位某主题的最新设计**：同一主题可能有多篇演进文档，优先按文件名日期取最新，并用代码现状交叉验证。

## 命名规则
- 目录和文件名：小写 + 下划线 (snake_case)
- 临时一次性项目：`tmp_<name>/`

## 查找原则

- 先查本表，再搜索。
- 如果问题涉及外部 OpenBMC 源码树，在计划或上下文里明确源码根目录，不要假设它已经在本仓内。

<!-- 随着你的项目增长，在这里添加活跃项目的快捷路由 -->
<!-- 格式：- `romulus bmcweb recipe` → `workspace/src/romulus/bmcweb` (说明) -->