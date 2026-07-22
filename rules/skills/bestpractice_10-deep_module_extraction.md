# 深模块抽取族（收敛散落逻辑 + leaf-pure 静态门禁）

## 元数据

- **类型**: BestPractice
- **适用场景**: 在 `ob`/`lib/*.sh` 里把散落在多个 helper / 多个 `cmd_*` 的同类判断收敛到一个深 module 时；拆 god-function 时；为新增 module 配纯度门禁时
- **创建日期**: 2026-07-06
- **来源**: 五次同构抽取提炼（`machine_state`(06-24)→`qemu_launch_profile`(07-01)→`qemu_binary`/`qemu.sh` runtime 拆(07-04)→`machine_picker`(07-05)→`qemu_instance`(07-06)）；后续 `devtool_pick`(modified recipe selection)→`devtool_dispatch`/`devtool_porcelain`(relay/emit，ADR-0010)→`devtool_subcmd`(subcommand handler，ADR-0012) 等沿用同一模式。通用深模块词汇见 [codebase-design DEEPENING](.claude/skills/codebase-design/DEEPENING.md)，本 skill 是它在 ob/lib 的落地形态 + 本仓库特有的静态门禁机制。

## 目标

让"收敛散落逻辑到深 module"从一次性手艺变成可工业化复制的动作，且抽取后的纯度（leaf-pure module 不 exit）由静态工具门禁守住，而非靠人记。

判定该动手的信号：CONTEXT.md / ADR 已确立 canonical term，但代码层滞后（仍读写旧名、状态判断穿透存储 implementation、决策散在多个 helper 各自做运行时分支）。此时新增深 module 收敛迫使上下层一致，比到处打补丁清晰。

## 验收标准

一个无上下文 agent 自检"这次深模块抽取是否做齐"：

1. **leaf-pure 纯度已门禁**：新 module 若约定叶子纯（不直接 exit），是否已登记进 `exit_contract.py` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME`（按 basename 配置例外集，纯 module 给 `set()`）？跑 `python3 tools/exit_contract.py` 通过。
2. **测试网先于结构**：是否按 extract→pin→deepen 顺序——先建/补测试钉住当前行为，再动结构，最后深化？
3. **退役靠 grep 自验证**：被消除的旧函数是否用 grep 枚举全限定名确认迁移清单完整、旧名零残留？是否配 surface gate protocol 回归锁防旧路径回潮？
4. **coverage 基线已校准**：抽取后是否实测 `coverage_radar.py` 并把新基线写进 CI `--fail-if-uncovered`（基线随模块化下降是正常，盲区透明化，不要制造覆盖率虚高）？
5. **副作用次序未破坏**：若拆 god-function，有副作用前置状态的决策块（检测+kill 等）是否整块留在调用者、置于依赖其前置状态的下游之前（见已知陷阱 F1）？是否配次序回归锁？
6. **规则面已同步**：`rules/03_WORKSPACE.md` 的 lib 路由表是否登记了新 module（角色 + leaf-pure 标注）？
7. **depth 证明形态对齐**：若待抽模块**已经是** function module（不是散落逻辑、不是 god-function），depth 不能靠"搬函数进新文件"证明——必须靠 (a) interface-shrink 断言（旧状态 token 在全部 production Bash 清零，caller 失去状态形状知识）+ (b) 非功能成本锁（进程数/调用面）先红后绿。此时顺序变体为 **pin → optimize → deepen**（optimizable 收益先行并锁住，再收 module），是 extract → pin → deepen 的特化。canonical 实例：2026-07-12 `lib/bare_mirror.sh`（旧 `clone_sub_repos` 已是 function module，用 NUL 批量 planning 把 $2+4N 次 Python 压成 1 次 + command-scoped `git -c` 取代 `git config --global`，两收益锁住后才收 module，并用旧 STATUS_*/MIRROR_BASE token 全 production 清零证 interface 收缩）。

## 可用资源与边界

- **静态门禁**：`tools/exit_contract.py`（Y 规则按 basename 配 leaf-pure 例外集）、`tools/extract_funcs.py`（lib 函数间不得有顶层语句，多文件 boundary 感知）、`tools/ob_check.sh`（改完 ob/lib 一站式自检，必跑）。
- **覆盖观测**：`tools/coverage_radar.py` + `trace_collect.sh`（xtrace 函数级命中，复用 extract_funcs，盲区透明化）+ `tools/coverage_matrix.md`（五档函数自动化归属清单）。
- **术语权威**：`CONTEXT.md`（canonical term 登记）、`docs/adr/`（架构决策背书）。
- **测试手法**：PATH-injection 优先（`tests/lib/stub.sh` 的 `mkfake_bin`/`stub_out`/`stub_script`），避开同 shell 函数 override 造成的 radar 虚高；调用次数/零调用断言见 [bestpractice_09](bestpractice_09-nonfunctional_regression_locks.md)。
- **边界**：本 skill 只讲 ob/lib 的 bash 深模块抽取 + 配套门禁；通用 module/seam/adapter 词汇和依赖分类（in-process / local-substitutable / ports&adapters / true-external）见 codebase-design DEEPENING，两者互补不重复。

## 处置模式

按"散落的是什么"选收敛形态。

### 形态 A：状态判断散落（→ lifecycle state module）

同类生命周期状态判断（snapshot marker / init-done / deploy image 查找 / 固件镜像就绪）散在多个 `cmd_*` 各自直查存储时，抽 lifecycle state module（先例 `machine_state.sh`）。module 暴露谓词式接口（`machine_state_*`），调用者只问不查。

### 形态 B：决策散落多 helper（→ profile module）

一个决策（QEMU 启动画像 / binary provisioning）散在多个 helper、调用者各自做运行时分支时，抽"画像"深 module（先例 `qemu_launch_profile.sh`、`qemu_binary.sh`）。统一决策变量命名空间（如 `QEMU_LAUNCH_*`）替换散落变量，下游只消费不判断。入口必 reset 全部决策变量防跨用例状态泄漏。

### 形态 C：重复选择逻辑（→ picker module）

同一种选择（machine 选择）在多个子命令重复实现、各自带显示循环和全局篡改时，抽 picker module（先例 `machine_picker.sh` 的 `pick_machine`）。四处选择点统一调用，退役所有重复实现。

### 形态 D：实例生命周期散落（→ instance module）

同一类 runtime 对象（QEMU 实例）的 list/describe/stop/clean 散在多个 `cmd_*` 内联时，抽 instance module（先例 `qemu_instance.sh`）。best-effort 操作（clean_stale）恒 rc 0，调用者不判错。

### 形态 E：god-function（→ 薄 wrapper + runtime 深函数）

一个 `cmd_*` 既做 banner/confirm/副作用决策又做 runtime 编排时，拆成薄 L1 wrapper（banner+confirm+副作用决策块）+ runtime 深函数（prepare/execute）。wrapper 夹在中间，runtime 出 prepare/execute 两个 seam。

## 已知陷阱

均为真实挖出，来自上述五次抽取的多轮对抗式评审。

| 陷阱 | 表现 | 应对 |
|------|------|------|
| 跨 seam 副作用次序（F1） | 拆 god-function 时把"冲突检测+kill"决策块分到 runtime seam 内，但 runtime 的 prepare 含端口检查（端口被旧实例占即 exit 3），旧实例未杀就查端口 → `--force` 同端口重启误退 exit 3 | 有副作用前置状态的决策块整块留调用者、置于调 prepare 之前；prepare 不做该检测。配次序回归锁（`start_qemu_force_restart.sh`）钉死 |
| 函数名前缀让 grep 漏（F7） | 迁移清单用 `grep qemu_binary_` 枚举，但某函数名带该前缀、唯一调用者在另一个同前缀函数 body 内，被 grep 当"已迁移"漏掉，孤儿化且无 gate 报错 | 迁移清单用全限定名 + 调用点 grep 双向核对；正则用 `[a-z0-9_]+` 覆盖含数字名（如 ast2700） |
| 工具依赖单文件假设漂移 | ob 模块化（ob→lib/*.sh）后，依赖"ob 单文件"假设的工具（`coverage_radar.py list_funcs`）静默失效——只 extract ob 入口 3 函数，真实逻辑全在 lib 但 radar 盲；docstring 仍写旧函数数 | 模块化重构必须同步更新依赖单文件假设的工具；docstring 旧数 + cross_check 静默丢弃是双重漂移信号 |
| 跨用例状态泄漏 | 同一 shell 进程连续解析不同 machine（AST2700 后再 AST2600），上一次的决策变量残留，bootloader 该空不空 | 入口必 reset 全部决策变量（`reset_qemu_launch_profile` 清空 `QEMU_LAUNCH_*`） |
| 把单点当模式硬抄 | 只做过一次抽取就把它当通用模式写进 skill，过早抽象 | 等到同构出现 ≥3 次再固化为模式（本 skill 的五次先例即是门槛）；少于三次保留在 OBSERVATIONS 单点记录 |

## 与现有 skill 的关系

- **上游通用词汇**：[codebase-design DEEPENING](.claude/skills/codebase-design/DEEPENING.md)（module/interface/seam/adapter、依赖分类、replace-don't-layer 测试策略）。本 skill 是它在 ob/lib bash 场景的落地 + 静态门禁。
- **同族门禁**：[bestpractice_08 质量门禁与 Eval 模式库](bestpractice_08-eval_gate_patterns.md)（门禁架构）、[bestpractice_09 非功能性回归锁](bestpractice_09-nonfunctional_regression_locks.md)（调用次数/零调用断言手法）。三者同属"可机器验证的纪律"族：08 讲门禁怎么配、09 讲测试代码怎么写断言、本 skill 讲深模块怎么抽 + 纯度怎么守。
- **上游公理**：[V2 可验证性](../axioms/v02_verifiability.md)（leaf-pure 纯度由静态工具验证才是资产）、呼应 [V6 概率乘](../axioms/v06_probability_multiplication.md)（每环配 eval，防黑箱回退）。
