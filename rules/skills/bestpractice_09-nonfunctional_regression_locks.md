# 非功能性改动的回归锁（调用次数 / 调用面断言）

## 元数据

- **类型**: BestPractice
- **适用场景**: 做性能优化 / 去重 / 缓存 / 合并重复调用 / 惰性求值这类**不改可观察输出**的改动时，以及为它们写测试时
- **创建日期**: 2026-06-30
- **来源**: commit 5154242（perf 复用 machine_state records）配套测试 + code review 提炼

## 目标

让"不改输出但声称更好"的改动（性能/去重/缓存）也能被测试钉死：不只验证结果对，还验证**以期望的方式达成**（调用了几次、是否走了快路径、是否消除了冗余调用），把软性能收益变成可回归验证的硬约束，而不是口头声称。

## 问题本质

非功能性改动天然逃过传统测试。传统断言是"输出 == 预期"，而性能优化、去重、加缓存的定义就是**输出逐字不变、只是达成方式更优**。于是：

- 改完跑测试全绿——但这只能证明"没改坏"，证明不了"优化生效"。
- 三个月后有人重构，不小心把缓存/复用拆回多次调用——输出仍对，测试仍绿，优化悄悄回退，无人发现。

这是 [V2 可验证性](../axioms/v02_verifiability.md) 的缺口：优化若不可验证，它就不是工程资产，只是 intentions。补法是加一类**行为级断言**——断言"调用了几次 / 有没有调用 X"——把软收益变硬约束。

## 适用边界

- **适用**：非功能性改动——性能优化、去重、缓存、合并重复 discovery、惰性初始化、短路求值；以及为这类改动配防回退锁。
- **不适用**：功能性改动（改了输出或行为）。这类用传统输出断言已足够，硬加调用次数断言会把测试耦合到实现细节，下次合法重构（换实现方式但结果不变）时测试误红。判断标准：**输出断言已经能区分"对/错"时，不要再加调用次数断言**。
- **锁点选择**：即使是非功能性改动，断言也要锁在本次优化声称减少的**稳定成本中心或依赖边界**上（discovery / cache miss / external command / 跨模块调用），不要随手锁任意内部 helper。只有当"恰好 N 次"本身就是优化契约时才钉死 `==N`；锁错地方会把测试绑死在不稳定的实现细节上。

## 处置模式

按"优化想消除什么"选断言形态。

### 模式 1：调用次数断言（优化减少了调用次数）

适用于"把 N 次调用压成 M 次"。手法：monkey-patch 一个计数 wrapper，断言**恰好**调用 M 次。

本仓库实例（`tests/protocol/status_machine_state.sh`，commit 5154242）：`cmd_status` 原来对 records 调 3 次 discovery，优化后复用为 1 次。

```bash
# 1) 把原函数重命名为 shadow，再重定义同名 wrapper 注入计数
calls_file="$TMP/records_calls"
eval "$(declare -f machine_state_records | sed '1s/^machine_state_records/_shadow_machine_state_records/')"
machine_state_records() {
    printf 'called\n' >> "$calls_file"     # 写文件，不写变量（见陷阱）
    _shadow_machine_state_records "$@"
}

# 2) 清零、跑被测对象、断言恰好 N 次
: > "$calls_file"
output="$(cmd_status 2>&1)"
assert_eq "status discovers records once" "$(wc -l < "$calls_file")" 1
```

### 模式 2：零调用断言（优化消除了某个调用）

适用于"不再调用某个函数"。手法：在被消除的函数里写计数文件，断言文件**不存在**。

本仓库实例（`tests/unit/repo_previously_initialized.sh`，commit 5154242）：`print_previously_initialized` 改为从 records 过滤 initialized，不再调 `machine_state_initialized_machines`。

```bash
initialized_calls_file="$TMP/initialized_calls"
machine_state_initialized_machines() {
    printf 'called\n' >> "$initialized_calls_file"
    printf 'romulus\n'
}
# ... 跑被测函数 ...
assert_false "does not rediscover initialized list" test -f "$initialized_calls_file"
```

前提：计数 `printf >> file` 必须是 mock 入口第一行（前面不能有 early return），且测试前不预创建该文件。此条件下 `test -f` 为假才等价于"mock 未执行"——它证明的是"写文件副作用未发生"，**不**笼统等于"函数从未被进入"（写文件前 early return 的 bug 它抓不到）。

### 延伸：调用面 / 快路径断言（优化改了路径选择）

适用于"新加缓存/快路径，期望命中"。断言缓存命中的可观测副作用（缓存文件被写、命中计数递增、快路径被调而慢路径未被调）——本质是模式 1+2 的组合，按实际可观测点选。本仓库暂无实例，遇到时按 1/2 的手法套。

## 技术要点（bash 手法）

- **计数用文件，不用变量**：变量在子 shell（`$(...)`、`| while`、`< <(...)` 右侧）累加会丢；文件是磁盘共享的，跨子 shell 稳定。与 [bestpractice_07 strict mode 管道陷阱](bestpractice_07-bash_strict_mode_pipes.md) 同源的 bash 作用域问题。
- **monkey-patch 用 `declare -f orig | sed '1s/^orig/_shadow/'`**：`1` 限定只改第 1 行（declare -f 输出的函数定义首行，body 完全不碰）——**这才是防误伤 body 的关键**；`^` 是额外保险（防首行有意料外前缀），不是关键。再 eval 重定义 shadow，然后定义新的 orig wrapper。
- **断言期望值钉死**（`== N`，不是 `>= N`）：松断言发现不了回退，等于没断言。
- **mock 作用域**：bash 测试每文件独立进程，函数重定义不跨文件泄漏；同文件内计数 mock 要在被测调用之前定义。

## 验收标准

一个无上下文 agent 自检"这次改动的测试是否锁住了非功能性收益"：

1. 改动是否"输出不变但声称优化/去重/缓存"？若是——
2. 是否**同时保留**了传统输出/行为断言？调用次数断言是补充不是替代：先证明结果没坏，再证明达成方式符合优化目标。只测调用次数会漏掉功能退化。
3. 是否有对应的调用次数（模式 1）或零调用（模式 2）断言，钉死了优化的可观测效果？
4. 期望值是否精确（`==1` 而非 `>=1`）？
5. 计数是否用文件而非变量（子 shell 安全）？
6. 是否**没有**对纯功能性改动硬加调用次数断言（避免耦合实现细节）？

## 已知陷阱

| 陷阱 | 表现 | 应对 |
|------|------|------|
| 计数用变量累加 | wrapper 在 `$()`/`< <()` 子 shell 里跑，主 shell 的计数变量读不到，永远 0 | 计数写文件（`>> file`），`wc -l` 读 |
| 松断言（`>=1`） | 优化回退到多次调用，测试仍绿，回退无感 | 期望值钉死 `==N`；"恰好"是回归锁的灵魂 |
| sed 重命名误伤 body | 写成 `s/orig/.../` 漏了行号 `1`，body 里的 `orig`（递归调用、注释）也被替换 | 必须 `1s`（只改第 1 行）；防 body 误伤的关键是 `1`，`^` 是保险 |
| 对功能性改动滥用 | 给"改了输出"的改动也加调用次数断言，合法重构（换实现）时测试误红 | 只对"输出不变、仅优化达成方式"的改动加；功能性改动靠输出断言 |
| mock 泄漏错觉 | 担心重定义污染其他测试 | 每文件独立进程不跨文件泄漏；注意同文件内定义顺序 |

## 与现有 skill 的关系

- 是 [bestpractice_08 质量门禁与 Eval 模式库](bestpractice_08-eval_gate_patterns.md) **模式 4（四层测试）内部**的微观断言手法：08 讲门禁架构（环节怎么配 eval），本 skill 讲测试代码里**为非功能性改动**具体怎么写断言。这类断言在本仓库语义分层里通常落在 **unit 层**（mock 依赖函数，如 `repo_previously_initialized.sh`）或 **protocol 层**（命令行为 + 计数，如 `status_machine_state.sh`）；分层语义见 CONTEXT.md 的 test layer。
- 与 [bestpractice_07 bash strict mode 管道陷阱](bestpractice_07-bash_strict_mode_pipes.md) 同属"bash 作用域/写法手法"族——两者都源自子 shell 作用域（07 是退出码，本 skill 是计数变量可见性）。
- 上游公理：[V2 可验证性](../axioms/v02_verifiability.md)（让优化可验证才是资产）、呼应 [V6 概率乘](../axioms/v06_probability_multiplication.md)（每个优化配 eval，防黑箱回退）。
