# Know-how TL;DR 结构对齐实施计划

## 目标

把 `/grill-with-docs` 锁定的 8 个决策落成可执行改动：确立"长 know-how 必须配 TL;DR"为生产者硬义务，给 9 个存量长文件补 TL;DR、2 个文件做尾段归位，并用 ob_check 门禁 + advisory 漂移预警工具兜底，最后以 ADR-0015 记录决策。

完成后：消费速则②（长文件先找 TL;DR）不再扑空；9 个长文件顶部有 TL;DR；ob_check 把"长文件必有 TL;DR"做成 hard gate；新增 advisory 工具在正文改动而 TL;DR 未跟随时预警。

## 架构快照

本次确立一条新规则并配套 enforcement：

- **规则层**：消费速则②从消费者软措辞（"先找 TL;DR"）升级为生产者硬义务（"长文件必须配 TL;DR"）。措辞同步改 `KNOWHOW_INDEX` 与 `bp_01` 消费者视角节。
- **触发线**：行数 > 100 的 `rules/knowhow/*.md` 必须有 `## TL;DR` 标题；豁免走显式清单（照搬 `exit_contract.py` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 模式）。短文件（≤100 行）对消费速则①豁免尾段约束。
- **enforcement 双层**：
  - hard gate：`ob_check.sh` 加一项 lint，长文件（>100 行、非豁免）无 `## TL;DR` → `bad`，进 FAIL 链。
  - advisory：新增 `tools/knowhow_tldr_drift_check.py`，git diff 结构检测——长文件正文段改动而 `## TL;DR` 段未动 → flag "疑似漂移请人工复查"，不阻断（exit 0）。
- **提炼标准（分两式）**：路由/决策型文件 → TL;DR 写决策路由；线性/原则型文件 → TL;DR 写"这文件解决什么 + 1-2 条最该先知道的陷阱/边界"。定义写入 `bp_01` 消费者视角节，附样例。

> **advisory 工具的实现收敛（需评审确认）**：grilling 原拍板"LLM 漂移预警"，但本仓库无任何调 LLM 的工具先例，引入 LLM API 属新依赖；而最高发漂移（正文改了、TL;DR 没跟）用 git diff 结构检测即可捕获、零依赖。本计划把 v1 定为 git diff 结构检测，LLM 语义判断降为 v2 可选增强（不在本次范围）。advisory 定位（独立、只读、不阻断、与 `cache_hit_rate.py`/`coverage_radar.py` 同类）不变。

## 全局约束

- **命名规则**：know-how 文件名沿用 `<category>_<NN>-<name>.md`；TL;DR 段标题固定为 `## TL;DR`（ob_check 门禁 grep 此字面量）。
- **触发线**：行数阈值 100（`wc -l`）；豁免清单内联在 `ob_check.sh`，照 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 模式显式枚举。
- **ADR 编号**：本次为 ADR-0015（`docs/adr/` 现有最大 0014）。
- **退出码契约**：`ob_check.sh` 0=ALL GREEN / 1=FAIL；advisory 工具 0=正常输出（不阻断）。
- **文案规则**：消费速则与 `bp_01` 措辞须前后一致（硬义务口径）；TL;DR 内容不改正文，只加顶部段（bp_02/03 的尾段归位除外，属结构性挪段）。
- **ob_check 职责扩展**：加 know-how 门禁后，`ob_check.sh` 从"ob/lib 代码自检"扩展到"含 know-how 文档结构自检"，顶部注释需同步。
- **ob_check 最终档位顺序**（执行者心智模型）：`1 extract_funcs → 1b machine_state → 1c/1c-bis/ter/quat/quin surface gates → 1d 交互prompt文案 → 1e know-how TL;DR gate(新,Task 8) → 2 shellcheck → 3 exit-contract → 4 run_all → 5 know-how drift advisory(新,Task 9,SKIP_TESTS 连带跳过) → 汇总`。

## 输入工件

- 方案源（已 grilling）：`docs/plans/2026-07-28-knowhow-structure-alignment-proposal.md`
- ADR 格式：`.claude/skills/domain-modeling/ADR-FORMAT.md`；近期范本 `docs/adr/0013-skills-to-knowhow-rename.md`
- 豁免清单模式来源：`tools/exit_contract.py` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME`（line 53）
- advisory 工具范本：`tools/cache_hit_rate.py`（独立 python3、只读、不阻断）
- ob_check 门禁写法范本：`tools/ob_check.sh` 的 `1c-ter` bare mirror surface gate（line 79-90）

## 文件结构与职责

- **Create**: `docs/adr/0015-knowhow-tldr-mandatory-structure-alignment.md` — 记录 D1 升级决策、触发线、豁免清单、同步机制、分两式标准、术语区分（消费者规则 vs 生产者义务）。
- **Create**: `tools/knowhow_tldr_drift_check.py` — advisory 漂移预警（git diff 结构检测）。
- **Modify**: `rules/05_KNOWHOW_INDEX.md` — 消费速则②改硬义务措辞；①加短文件豁免注明。
- **Modify**: `rules/knowhow/bestpractice_01-knowhow_writing.md` — 消费者视角节硬义务化 + 新增"TL;DR 两式"标准与样例；自身补 `## TL;DR`（117 行长文件，属 A 档）。
- **Modify**: `tools/ob_check.sh` — 新增 know-how 长文件 TL;DR 门禁（hard gate）+ 豁免清单 + 顶部注释职责更新。
- **Modify**: `rules/knowhow/bestpractice_02-ai_programming_mindset.md` — 补 TL;DR + 尾段归位（"注意事项"重命名并挪到尾部约束位）。
- **Modify**: `rules/knowhow/bestpractice_03-ai_debugging_diagnosis.md` — 补 TL;DR + 尾段归位（"常见问题与解决"挪到尾部约束区，变更日志不再占据尾部）。
- **Modify**: `rules/knowhow/bestpractice_05-npm_network_timeout_in_yocto.md`、`bestpractice_07-bash_strict_mode_pipes.md`、`bestpractice_09-nonfunctional_regression_locks.md`、`bestpractice_11-interactive_prompt_bypass.md` — 各补 TL;DR（正文不动）。
- **Modify**: `rules/knowhow/workflow_01-obmc_env_init.md`、`workflow_03-knowledge_flywheel.md` — 各补 TL;DR（正文不动）。

边界稳定性：`bestpractice_12`（已有 TL;DR，范例，不动）、`bestpractice_04/06/08/10`（短文件或已符合，不动）、`workflow_02`（短文件，D4 豁免，不动）。9 个补 TL;DR 的长文件清单：bp_01/02/03/05/07/09/11 + wf_01/03。

## 已知风险（grilling 拍板时已接受）

- **D1 选硬义务**：给 know-how 体系引入第一份生产者合规负担（"消费者规则 ≠ 生产者义务"的口子），9 份 TL;DR 是双份维护债。靠 D2 三件套（hard lint + advisory + 人工 review）兜底；语义一致性无自动校验是已知限制。
- **D3 选全补一次性**：hard lint 门禁与分两式标准均未实战验证即套用到 9 个文件；若机制或标准有问题，9 个一起返工。缓解：Task 8（门禁）放在所有 TL;DR 补完后加，初始即全绿；Task 3 的两式标准先于批量补写定稿。

## 任务清单

### Task 1: 创建 ADR-0015 冻结 grilling 全部实质决策

- 目标：把 grilling 的全部实质决策落成 ADR-0015，作为它们**唯一的冻结载体**（proposal 自标"未立项草稿"不作为冻结来源；会话口头共识不持久）。后续所有任务以本 ADR 为可追溯政策依据。
- 涉及文件：Create `docs/adr/0015-knowhow-tldr-mandatory-structure-alignment.md`
- 接口契约
  - Consumes：grilling 8 决策（本 ADR 为其权威冻结落点）；ADR-FORMAT.md；ADR-0013 范本风格。
  - Produces：ADR-0015（后续 Task 2/3/8/9 的政策依据）；术语区分"消费者规则 vs 生产者义务"；advisory 手段收敛（v1 git diff / v2 LLM）的可追溯记录。
- 验证范围：文件存在；Considered Options 覆盖 D1+D5；Consequences 覆盖 D2（advisory 手段收敛理由）+ D3（一次性取舍）+ 触发线/两式标准/陷阱段归位口径。

- [ ] Step 1: 确认 ADR 编号与目录
  - Run: `ls docs/adr/ | tail -1`
  - Expected: 输出 `0014-defer-generate-build-config-deepening.md`（确认下一个是 0015）。
- [ ] Step 2: 写 ADR 正文（完整收录 grilling 实质决策）
  - Change: 创建 `docs/adr/0015-knowhow-tldr-mandatory-structure-alignment.md`，含：
    - 决策陈述（D1）：消费速则②升级为生产者硬义务——`rules/knowhow/*.md` 行数 > 100 必须有 `## TL;DR`；短文件（≤100 行）对①豁免尾段。
    - Context：grilling 发现"消费者规则（怎么读）"与"生产者义务（文件必须有什么）"被混淆；经 8 决策点锁定选硬义务。术语区分记入本 ADR 防未来重复纠结。
    - Considered Options：D1 三项——(1) 消费者软规则→改速则措辞不动存量（拒绝）；(2) 生产者硬义务（接受）；(3) 新文件鼓励/存量不动（拒绝：存量欠债不补则规则持续扑空）。**D5**——"只改消费速则②措辞、不动存量"（拒绝：与选定的硬义务方向相悖，且放弃存量结构对齐价值）。
    - Consequences：
      - 触发线=行数 >100 + 豁免清单（照搬 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME`）。
      - **D2 同步机制 + advisory 手段收敛**：hard lint（ob_check 存在性）+ advisory 漂移预警 + 人工 review。**advisory v1 选 git diff 结构检测、LLM 语义判断降为 v2 可选**——理由：本仓库无任何调 LLM 的工具先例（cache_hit_rate/coverage_radar/exit_contract 全是纯 python3 只读），引入 LLM API 是首个 LLM 依赖，不应在文档对齐计划里悄悄引入；最高发漂移（正文改了忘改 TL;DR）零依赖即可捕获；v1 的语义盲区（正文换措辞、TL;DR 仍引旧措辞，字面段未动则无信号）由 v2 LLM 兜底。
      - **advisory 触发责任**：drift_check 接入 ob_check 第 5 项（run_all 之后），随 ob_check 自动跑——因 ob_check 加了 know-how hard gate（1e），"改 know-how 后跑 ob_check"即顺带漂移预警，零额外记忆成本；drift flag 不进 FAIL 计数、`OB_CHECK_SKIP_DRIFT=1` 或 `OB_CHECK_SKIP_TESTS=1`（smoke 反递归守护连带跳过）可跳过。避免沦为需人单独记得跑的 orphan 工具（区别于 cache_hit_rate/coverage_radar 那类纯人工观测工具）。
      - **D3 一次性取舍**：全补一次性，接受"机制/标准未实战验证即套用 9 文件、可能整体返工"的风险（缓解：门禁 Task 8 在补完后加、两式标准 Task 3 先于批量定稿）。
      - 提炼标准=分两式。
      - **陷阱段归位口径（统一规则）**：尾段归位目标=陷阱段落在**靠尾部约束区域**而非物理最末；变更日志/关系段惯例性最末是显式例外（解释 bp_03 陷阱段靠尾、bp_02 落最末的差异，避免未来 reviewer 用最末标准卡 bp_03）。
    - Status: accepted。
- [ ] Step 3: 验证 ADR 落盘且覆盖完整
  - Run: `test -f docs/adr/0015-knowhow-tldr-mandatory-structure-alignment.md && grep -c "硬义务\|Considered Options\|git diff 结构检测\|一次性\|靠尾部约束区域" docs/adr/0015-knowhow-tldr-mandatory-structure-alignment.md`
  - Expected: 文件存在且 grep 计数 ≥ 5（D1 决策、Considered Options、D2 advisory 收敛、D3 一次性、陷阱段归位口径五类都在）。

### Task 2: 更新 KNOWHOW_INDEX 消费速则措辞

- 目标：把消费速则②从软措辞改为硬义务，①加短文件豁免注明，与 ADR-0015 口径一致。
- 涉及文件：Modify `rules/05_KNOWHOW_INDEX.md`（「Know-how 消费速则（每会话强制）」段，当前 line 8-10）。
- 接口契约
  - Consumes：ADR-0015（Task 1）。
  - Produces：消费速则硬义务措辞（后续 agent 读到的权威口径）。
- 验证范围：②含"必须"硬措辞 + 触发线引用；①含短文件豁免注明。

- [ ] Step 1: 确认当前软措辞
  - Run: `sed -n '8,11p' rules/05_KNOWHOW_INDEX.md`
  - Expected: 看到②当前为"长文件（>100 行）先找顶部 TL;DR 拿核心判定"（软措辞"先找"），无"必须"、无短文件豁免。
- [ ] Step 2: 改写速则②与①
  - Change: ②改为硬义务表述——"长文件（>100 行）顶部**必须**配 TL;DR（30 秒核心判定），生产者义务见 ADR-0015；消费者先读 TL;DR 拿判定"。①末尾加注明——"短文件（≤100 行）整篇可扫完，尾段约束主要针对长文件"。
- [ ] Step 3: 验证措辞
  - Run: `grep -E "必须.*TL;DR|ADR-0015|短文件.*豁免|≤100" rules/05_KNOWHOW_INDEX.md`
  - Expected: 命中硬义务措辞、ADR-0015 引用、短文件豁免注明。

### Task 3: 在 bp_01 确立 TL;DR 硬义务口径与两式提炼标准（含自身示范）

- 目标：把"TL;DR 硬义务口径 + 两式提炼标准"在 bp_01 一次性立起来——改消费者视角节为硬义务、定义两式标准与样例，并给 bp_01 自身（117 行长文件）补 TL;DR 作为线性式的首个示范样本。这三件都在 bp_01 且互相引用（两式标准供 Task 4-7 套用、bp_01 的 TL;DR 即线性式样例），作为"确立标准"的一整块交付，不拆。
- 涉及文件：Modify `rules/knowhow/bestpractice_01-knowhow_writing.md`（消费者视角节 line 89-111；顶部补 TL;DR）。
- 接口契约
  - Consumes：ADR-0015（Task 1）。
  - Produces：「TL;DR 两式」标准定义（Task 4/5/6/7 的提炼依据）。
- 验证范围：bp_01 顶部有 `## TL;DR`；消费者视角节含硬义务措辞 + 两式标准 + 样例。

- [ ] Step 1: 确认当前无 TL;DR 且视角节为软措辞
  - Run: `grep -c "^## TL;DR" rules/knowhow/bestpractice_01-knowhow_writing.md; grep -n "设计良好的" rules/knowhow/bestpractice_01-knowhow_writing.md`
  - Expected: 第一条 `0`（无 TL;DR）；第二条命中"设计良好的长 know-how 会放 TL;DR"（软措辞）。
- [ ] Step 2: 消费者视角节硬义务化 + 新增两式标准（必须先于 Step 3）
  - Change: 把 line 106 附近"设计良好的长 know-how……会在顶部放 30 秒决策块"改为硬义务表述（"长 know-how 必须配 TL;DR，见 ADR-0015"）。在消费者视角节新增"TL;DR 两式"小节：①路由/决策型文件 → 写决策路由（命中即停），样例引用 `bp_12` 三问路由；②线性/原则型文件 → 写"这文件解决什么 + 1-2 条最该先知道的陷阱/边界"（样例见 Step 3 本文件自身 TL;DR）。
- [ ] Step 3: 顶部补 TL;DR（套用 Step 2 定稿的线性式，作为首个示范样本）
  - Change: 在 `# Know-how 写作与阅读指南（Meta）` 标题下、`## 元数据` 之前插入 `## TL;DR` 段，按 Step 2 定稿的"线性式"写：一句话说清这文件解决什么（怎么写 + 怎么读 know-how）+ 最该先知道的 1-2 条（"结果确定性优先于过程确定性"、"消费者必须读到尾部陷阱段，长文件顶部配 TL;DR"）。引用 ADR-0015。此 TL;DR 即 Step 2 线性式样例的实物。
- [ ] Step 4: 验证
  - Run: `grep -c "^## TL;DR" rules/knowhow/bestpractice_01-knowhow_writing.md; grep -E "TL;DR 两式|ADR-0015|必须.*TL;DR" rules/knowhow/bestpractice_01-knowhow_writing.md`
  - Expected: 第一条 `1`（有 TL;DR）；第二条命中两式标准、ADR-0015、硬义务措辞。

### Task 4: bp_02 补 TL;DR + 尾段归位

- 目标：给 bp_02（158 行）补 TL;DR；把非标准命名的"注意事项"段重命名为标准陷阱段并挪到尾部约束位。
- 涉及文件：Modify `rules/knowhow/bestpractice_02-ai_programming_mindset.md`。
- 接口契约
  - Consumes：TL;DR 两式标准（Task 3）。
  - Produces：bp_02 顶部有 TL;DR + 尾部为标准陷阱段（满足消费速则①）。
- 验证范围：顶部有 `## TL;DR`；尾部段为陷阱性质且命名标准；"注意事项"不再夹在中部。

- [ ] Step 1: 确认当前结构（标题级）
  - Run: `grep -n "^#" rules/knowhow/bestpractice_02-ai_programming_mindset.md`
  - Expected: 看到 `## 注意事项` 在中部（line 114），其后还有 `## AI 落地核心决策`（line 122）；顶部无 `## TL;DR`。
- [ ] Step 2: 顶部补 TL;DR
  - Change: 标题下插 `## TL;DR`。bp_02 属方法论/原则型，按线性式：一句话核心论点（AI 编程要结果确定性、定义成功标准）+ 1-2 条最该先知道的（"70% 问题"、"认知外包的界限"）。
- [ ] Step 3: 尾段归位
  - Change: 把 `## 注意事项` 段重命名为 `## 已知陷阱与注意事项`（标准命名），并整段移动到 `## AI 落地核心决策` 段之后（文件尾部约束位）。移动后通读确认逻辑连贯。
- [ ] Step 4: 验证
  - Run: `grep -c "^## TL;DR" rules/knowhow/bestpractice_02-ai_programming_mindset.md; grep -n "已知陷阱与注意事项" rules/knowhow/bestpractice_02-ai_programming_mindset.md; awk '/^## /{print NR": "$0}' rules/knowhow/bestpractice_02-ai_programming_mindset.md | tail -3`
  - Expected: 第一条 `1`；第二条命中重命名后的标题；第三条显示尾部最后几个 `## ` 段中"已知陷阱与注意事项"位于尾部区域（不再夹在中部）。

### Task 5: bp_03 补 TL;DR + 尾段归位

- 目标：给 bp_03（115 行）补 TL;DR；把陷阱段"常见问题与解决"挪到尾部约束区，使变更日志不再占据尾部。
- 涉及文件：Modify `rules/knowhow/bestpractice_03-ai_debugging_diagnosis.md`。
- 接口契约
  - Consumes：TL;DR 两式标准（Task 3）。
  - Produces：bp_03 顶部有 TL;DR + 尾部约束区可达陷阱段。
- 验证范围：顶部有 `## TL;DR`；"常见问题与解决"段位于"什么时候才是真正的架构问题"之后（靠尾部），变更日志在最末且不再掩盖陷阱段。

- [ ] Step 1: 确认当前结构
  - Run: `grep -n "^#" rules/knowhow/bestpractice_03-ai_debugging_diagnosis.md`
  - Expected: 看到 `## 常见问题与解决`（line 53，中部）、`## 什么时候才是真正的架构问题`（line 91）、`## 变更日志`（line 111，尾部）；顶部无 `## TL;DR`。
- [ ] Step 2: 顶部补 TL;DR
  - Change: 标题下插 `## TL;DR`。bp_03 含诊断决策树，按路由式：诊断入口路由（现象 → 上下文/成功标准/反馈通道三问命中即停）+ 提示"已知问题见尾部 §常见问题与解决"。
- [ ] Step 3: 尾段归位
  - Change: 把 `## 常见问题与解决` 段（含其 3 个子项）整段移动到 `## 什么时候才是真正的架构问题` 段之后。调整后顺序：诊断决策树 → 架构问题 → 常见问题与解决（陷阱段，靠尾）→ 与其他 Know-how 的关系 → 变更日志（最末）。移动后通读确认决策树到常见问题的逻辑连贯。
- [ ] Step 4: 验证
  - Run: `grep -c "^## TL;DR" rules/knowhow/bestpractice_03-ai_debugging_diagnosis.md; awk '/^## /{print NR": "$0}' rules/knowhow/bestpractice_03-ai_debugging_diagnosis.md`
  - Expected: 第一条 `1`；第二条显示"常见问题与解决"行号大于"什么时候才是真正的架构问题"行号（陷阱段已靠尾）。

### Task 6: 线性/枚举型批补 TL;DR（bp_05/07/09/11）

- 目标：给 4 个长文件补 TL;DR（正文不动），按线性式（问题 + 致命陷阱）。
- 涉及文件：Modify `bestpractice_05-npm_network_timeout_in_yocto.md`、`bestpractice_07-bash_strict_mode_pipes.md`、`bestpractice_09-nonfunctional_regression_locks.md`、`bestpractice_11-interactive_prompt_bypass.md`。
- 接口契约
  - Consumes：TL;DR 两式标准（Task 3）。
  - Produces：4 文件顶部各有 `## TL;DR`。
- 验证范围：4 文件各有 `## TL;DR`；正文未改（git diff 只见新增段）。

- [ ] Step 1: 确认当前 4 文件均无 TL;DR
  - Run: `for f in bestpractice_05-npm_network_timeout_in_yocto bestpractice_07-bash_strict_mode_pipes bestpractice_09-nonfunctional_regression_locks bestpractice_11-interactive_prompt_bypass; do echo -n "$f: "; grep -c "^## TL;DR" rules/knowhow/$f.md; done`
  - Expected: 4 行均输出 `0`。
- [ ] Step 2: 逐文件补 TL;DR（线性式）
  - Change: 每个文件标题下插 `## TL;DR`，读全文后提炼——一句话这文件解决什么 + 1-2 条最该先知道的陷阱/边界。具体：bp_05（npm 超时诊断的关键判定）、bp_07（bash strict mode 陷阱族最易踩的几类）、bp_09（非功能性优化用调用次数断言钉收益）、bp_11（交互 prompt 先读逃生路径别逐行喂）。
- [ ] Step 3: 验证 4 文件均有 TL;DR 且正文未改
  - Run: `for f in bestpractice_05-npm_network_timeout_in_yocto bestpractice_07-bash_strict_mode_pipes bestpractice_09-nonfunctional_regression_locks bestpractice_11-interactive_prompt_bypass; do echo -n "$f: "; grep -c "^## TL;DR" rules/knowhow/$f.md; done; git diff --stat rules/knowhow/`
  - Expected: 4 行均输出 `1`；git diff --stat 显示这 4 文件改动行数小（仅新增 TL;DR 段，约 3-8 行/文件）。

### Task 7: 路由/方法论型批补 TL;DR（wf_01/03）

- 目标：给 2 个长文件补 TL;DR（正文不动），按路由式（决策路由 / 核心流程）。
- 涉及文件：Modify `workflow_01-obmc_env_init.md`、`workflow_03-knowledge_flywheel.md`。
- 接口契约
  - Consumes：TL;DR 两式标准（Task 3）。
  - Produces：2 文件顶部各有 `## TL;DR`。
- 验证范围：2 文件各有 `## TL;DR`；正文未改。

- [ ] Step 1: 确认当前 2 文件均无 TL;DR
  - Run: `for f in workflow_01-obmc_env_init workflow_03-knowledge_flywheel; do echo -n "$f: "; grep -c "^## TL;DR" rules/knowhow/$f.md; done`
  - Expected: 2 行均输出 `0`。
- [ ] Step 2: 逐文件补 TL;DR（路由式）
  - Change: wf_01（255 行多阶段流程）TL;DR 写初始化决策路由 + 提示"已知陷阱/故障排除/限制见尾部三段"；wf_03（174 行知识飞轮方法论）TL;DR 写四步飞轮核心 + 关键判定。
- [ ] Step 3: 验证
  - Run: `for f in workflow_01-obmc_env_init workflow_03-knowledge_flywheel; do echo -n "$f: "; grep -c "^## TL;DR" rules/knowhow/$f.md; done`
  - Expected: 2 行均输出 `1`。

### Task 8: ob_check.sh 加 know-how TL;DR 门禁 + 豁免清单

- 目标：在 ob_check.sh 加一项 hard gate——`rules/knowhow/*.md` 行数 > 100 且非豁免必须有 `## TL;DR`；豁免清单照搬 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 模式内联。本任务在 Task 3-7 完成后执行，加门禁时 9 个长文件已全部有 TL;DR，初始即全绿。
- 涉及文件：Modify `tools/ob_check.sh`（新增一项检查，编号 `1e`，紧随现有 `1d` 交互 prompt 文案契约之后、`2` shellcheck 之前，归类为静态结构门禁；更新顶部 line 2-5 注释）。
- 接口契约
  - Consumes：ADR-0015 触发线/豁免定义（Task 1）；9 文件已补 TL;DR（Task 3-7）。
  - Produces：ob_check 的 know-how TL;DR 门禁（Task 10 最终验证依赖）。
- 验证范围：门禁对"缺 TL;DR 的长文件"报 bad；对当前仓库（9 文件已补）报 ok；ob_check 自身 shellcheck baseline 不破。

- [ ] Step 1: 写门禁的失败用例（TDD）
  - Run: 在 `rules/knowhow/` 造临时文件 `_tldr_gate_probe.md`（>100 行、无 `## TL;DR`），例如 `python3 -c "print('# probe\n'+'\n'.join('x'*i for i in range(110)))" > rules/knowhow/_tldr_gate_probe.md`
  - Expected: 临时文件创建成功（101+ 行、无 `## TL;DR`），用于下一步证明门禁能抓到。
- [ ] Step 2: 写门禁实现并确认它抓到临时文件
  - Change: 在 ob_check.sh 加一段，定义豁免清单数组 `KNOWHOW_TLDR_EXEMPT=()`（初始空，机制预留；照搬 `1c-ter` 的 grep+bad/ok 写法），遍历 `rules/knowhow/*.md`：`wc -l` > 100 且 basename 不在豁免清单且无 `grep -qE '^## TL;DR'` → `bad`，否则累计 `ok`。同步更新顶部注释（line 2-5）注明"含 know-how 文档结构自检"。
  - Run: `bash tools/ob_check.sh 2>&1 | grep -E "know-how.*TL;DR|_tldr_gate_probe"`
  - Expected: 命中 `bad "know-how 长文件缺 ## TL;DR(ADR-0015): ... _tldr_gate_probe.md"`（证明门禁工作）。
- [ ] Step 3: 删除临时文件，确认全绿
  - Change: `rm rules/knowhow/_tldr_gate_probe.md`
  - Run: `bash tools/ob_check.sh 2>&1 | grep -E "know-how.*TL;DR|ALL GREEN|FAIL="`
  - Expected: 命中 `ok "know-how 长文件 TL;DR 门禁通过"` 且整体 `ALL GREEN`（9 文件已补，无缺 TL;DR 的长文件）。
- [ ] Step 4: 确认 ob_check 自身 shellcheck baseline 不破
  - Run: `bash tools/ob_check.sh >/tmp/oc.out 2>&1; tail -3 /tmp/oc.out`
  - Expected: 末尾 `ALL GREEN (PASS=N)`（shellcheck baseline 段无 NEW_ALERT，新加 bash 代码通过）。

### Task 9: 新增 advisory 漂移预警工具 knowhow_tldr_drift_check.py

- 目标：新增 advisory 工具，git diff 结构检测——长文件正文段改动而 `## TL;DR` 段未动 → flag 疑似漂移，不阻断（exit 0）。
- 涉及文件：Create `tools/knowhow_tldr_drift_check.py`；Modify `tools/ob_check.sh`（第 5 项接入 advisory 调用，见 Step 5）。
- 接口契约
  - Consumes：ADR-0015（advisory 定位）；`cache_hit_rate.py` 的 advisory 工具范式（独立 python3、只读、退出码 0/1/2、`--help` 打印 docstring）。
  - Produces：漂移预警工具 + ob_check advisory 接入（工具随 ob_check 自动触发，非 orphan）。
- 验证范围：工具对"正文改 TL;DR 没改"的 diff 报 flag；对"无改动 / TL;DR 也改了"不报；`--help` 输出 docstring；退出码 0（advisory 不阻断）。

- [ ] Step 1: 写失败检查（无工具时无漂移检测）
  - Run: `test -f tools/knowhow_tldr_drift_check.py || echo MISSING`
  - Expected: `MISSING`（工具尚未创建）。
- [ ] Step 2: 写工具实现
  - Change: 创建 `tools/knowhow_tldr_drift_check.py`，docstring 说明"advisory 漂移预警，不阻断；v1 git diff 结构检测，LLM 语义判断为 v2 可选"。逻辑：(1) `git diff` 默认 HEAD，取改动的 `rules/knowhow/*.md`；(2) 对每个改动的长文件（>100 行且有 `## TL;DR`），用 markdown `## ` 标题切出 TL;DR 段范围；(3) 检查 diff 的 hunk：若有 hunk 落在 TL;DR 段之外（正文改动）而无 hunk 落在 TL;DR 段内 → flag "疑似漂移：正文改动但 TL;DR 未更新，请人工复查"；(4) 输出 flag 列表，`exit 0`（advisory）。
- [ ] Step 3: 验证 flag 行为（造一个正文改、TL;DR 不改的场景）
  - Run: 给已跟踪长文件 `rules/knowhow/bestpractice_09-nonfunctional_regression_locks.md` 正文末尾追加唯一标记行 `<!-- DRIFT-PROBE -->`（落在 TL;DR 段之外），跑 `python3 tools/knowhow_tldr_drift_check.py; echo "exit=$?"`；随后**精确删除该 probe 行**（`sed -i '/<!-- DRIFT-PROBE -->/d' rules/knowhow/bestpractice_09-nonfunctional_regression_locks.md`）——切勿用 `git checkout` 撤销，以免误删 Task 6 补的 TL;DR。
  - Expected: 输出含"疑似漂移"flag（正文改动、TL;DR 段未动）；`exit=0`（不阻断）。删除 probe 行后重跑无 flag。
- [ ] Step 4: 验证 `--help` 与无改动场景
  - Run: `python3 tools/knowhow_tldr_drift_check.py --help | head -3; git stash list >/dev/null 2>&1; python3 tools/knowhow_tldr_drift_check.py; echo "exit=$?"`（工作区无 know-how 改动时）
  - Expected: `--help` 打印 docstring 首行；无改动时无 flag 输出、`exit=0`。
- [ ] Step 5: 接入 ob_check 作为 advisory 尾巴（定义触发责任，防 orphan；含 smoke 联动）
  - Change: 在 `tools/ob_check.sh` 第 4 项（run_all）之后、汇总段之前，新增第 5 项 advisory 调用——跳过条件为 `OB_CHECK_SKIP_DRIFT=1` **或 `OB_CHECK_SKIP_TESTS=1`**（后者让 smoke 反递归守护连带跳过 drift——传导路径：`tests/protocol/ob_check_smoke.sh:13` **自身显式** `env OB_CHECK_SKIP_TESTS=1` 注入内层 ob_check，非 run_all 传递，第 5 项 drift 随之跳过，保持 smoke "纯代码自检三段"语义）；调 `python3 tools/knowhow_tldr_drift_check.py`，有 flag 则 `echo` 输出（**不进 FAIL 计数、不影响 exit**），无 flag 则 `ok "know-how TL;DR 无漂移信号"`。
  - Run（开发者场景，drift 接入）: `bash tools/ob_check.sh 2>&1 | grep -E "advisory drift|无漂移信号|ALL GREEN"`
  - Expected: 命中 advisory 输出行且 `ALL GREEN`（drift flag 不阻断）。
  - Run（smoke 场景，drift 被联动跳过）: `OB_CHECK_SKIP_TESTS=1 bash tools/ob_check.sh 2>&1 | grep -c "advisory drift\|无漂移信号"`
  - Expected: `0`（SKIP_TESTS 连带跳过 drift，smoke 链路无 drift 噪声）。

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行（Task 1→10），不要无声跳步、合并步或改变任务目标。Task 8（门禁）必须在 Task 3-7（补 TL;DR）之后，否则门禁初始 FAIL。
- 每完成一个任务运行该任务的验证命令；文档类任务用 grep 锚点验证，工具类任务用行为验证。
- bp_02/bp_03 尾段归位（Task 4/5 Step 3）移动段落后必须通读确认逻辑连贯，不能只靠 grep。
- 遇到阻塞、重复失败或计划与仓库现实不符，立即停下说明，不要猜。
- 当前在 `main` 分支；开始实现前与用户确认是否新建分支。
- 全部任务完成后运行最终验证并输出修改摘要。

## 最终验证

- [ ] Run: `bash tools/ob_check.sh`
  - Expected: `ALL GREEN`，含 `ok "know-how 长文件 TL;DR 门禁通过"`。
- [ ] Run: 9 长文件 TL;DR 存在性
  - 命令: `for f in bestpractice_01-knowhow_writing bestpractice_02-ai_programming_mindset bestpractice_03-ai_debugging_diagnosis bestpractice_05-npm_network_timeout_in_yocto bestpractice_07-bash_strict_mode_pipes bestpractice_09-nonfunctional_regression_locks bestpractice_11-interactive_prompt_bypass workflow_01-obmc_env_init workflow_03-knowledge_flywheel; do echo -n "$f: "; grep -c "^## TL;DR" rules/knowhow/$f.md; done`
  - Expected: 9 行均输出 `1`。
- [ ] Run: `python3 tools/knowhow_tldr_drift_check.py; echo "exit=$?"`
  - Expected: 无 flag（实现期间未引入漂移）或仅 advisory flag；`exit=0`。
- [ ] Run: 措辞一致性
  - 命令: `grep -l "ADR-0015" docs/adr/0015*.md rules/05_KNOWHOW_INDEX.md rules/knowhow/bestpractice_01-knowhow_writing.md`
  - Expected: 3 个文件均命中 ADR-0015 引用（决策、速则、写作指南三处口径一致）。
- [ ] Run: ob_check 注释职责已更新
  - 命令: `grep -c "know-how\|knowhow" tools/ob_check.sh`
  - Expected: 计数 ≥ 1（顶部注释已扩到"含 know-how 文档结构自检"，与新门禁职责一致）。
- [ ] Run: drift advisory 已接入 ob_check（非 orphan）
  - 命令: `grep -c "knowhow_tldr_drift_check\|OB_CHECK_SKIP_DRIFT" tools/ob_check.sh`
  - Expected: 计数 ≥ 1（ob_check 第 5 项已接入 drift advisory 调用，工具有自动触发归宿）。

## 审阅 Checkpoint

实施计划已写好并保存到 `docs/plans/2026-07-28-knowhow-tldr-structure-alignment-implementation-plan.md`。请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行。
