# know-how 编号稳定性：永久创建序号，删除留缺口不重排

ADR-0017 删除 `workflow_03-knowledge_flywheel.md` 并新建 `workflow_04-manual_sedimentation.md` 后，`rules/knowhow/` 的 workflow 分类出现 01/02/04 的缺口。这暴露一个此前未定义的策略：文件名 `<category>_<NN>-<name>.md` 里的 `<NN>` 语义是什么？`bestpractice_01` 和 `05_KNOWHOW_INDEX` 只把它写成"建议命名格式"，没规定语义——导致新人/agent 看到缺口会误判为笔误，甚至自作主张重排填补。

**Decision：** `<NN>` 是永久创建序号。删除 know-how 条目时编号不回收、后续条目不重排填补，缺口永久保留。删除动作 = rm 文件 + 移除 INDEX 入口 + 同步所有活跃引用；编号本身不动。适用全部 know-how（`rules/knowhow` product + `contexts/knowhow` user，workflow + bestpractice 两分类统一）。

Status: accepted

## Considered Options

1. **永久序号·保留缺口（接受）** —— 见 Decision。
2. **连续槽位·删后即重排（拒绝）** —— 视图最整洁，但每次删除引发改名涟漪（`workflow_04` 当前被 7 处活跃文件引用：CONTEXT.md / 03_WORKSPACE / 05_INDEX×2 / ADR-0017 / KNOWLEDGE_BASE / sediment 双版本入口），`docs/plans` 里冻结快照记录的旧号会与现状漂移，且重排抹去"第 N 个被创建"的历史。
3. **唯一标识·不承诺连续（拒绝）** —— 最省事，但等于无策略，缺口累积、无原则可循，新人继续问。

## Consequences

- `rules/knowhow/` 的 01/02/04 缺口是**正常状态**，非笔误，无需"修复"。
- `05_KNOWHOW_INDEX.md` 命名约定处补 NN 语义并指向本 ADR；`bestpractice_01` 格式参考段加交叉引用。NN 语义的单一真相源 = 本 ADR + INDEX 命名约定。
- 未来删除 know-how 条目 checklist：rm 文件 → 移除 INDEX 入口 → grep 同步所有活跃引用（CONTEXT.md / ADR / command 入口等）→ 编号保留缺口、不重排。
- 与 ADR 编号同哲学：ADR 0001-0017 连续只因未曾删除，非策略保证；ADR 若删除同样留缺口不重排。

`/grill-with-docs` 三个决策点（NN 语义 / 固化方式 / 适用范围）经 grilling 锁定，本 ADR 是其唯一冻结载体。Cross-ref：[ADR-0017](0017-knowhow-distribution-boundary.md)（删除 workflow_03 的触发决策）、[ADR-0013](0013-skills-to-knowhow-rename.md)（know-how 命名体系起点）。
