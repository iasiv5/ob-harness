# ob 脚本交互菜单模式设计文档

## 背景与目标

当前 `ob` 脚本是纯 CLI 模式：`./ob init`、`./ob build`、`./ob status`，用户需要记住命令和参数。对于不常使用或初次接触的用户，缺乏引导性。

**目标**：为 `ob` 脚本增加交互菜单模式。用户执行 `./ob`（不带参数）后进入一个数字选择的菜单循环，执行完任务后自动回到菜单，直到用户主动退出。

**成功标准**：
1. `./ob` 无参数进入菜单，`./ob <command>` 保持现有 CLI 行为不变。
2. 菜单覆盖现有三个命令：init、build、status，外加清屏和退出。
3. 子命令执行失败不会退出菜单循环，用户能回到菜单重新选择。
4. 菜单模式不破坏 CLI 模式的任何现有行为。

## 范围

- 新增 `cmd_menu()` 函数作为菜单循环主入口。
- 重构 `main()`：将 init 的 8 个步骤抽出为 `cmd_init()`。
- 调整 `main()` 的入口逻辑：无参数走菜单，有参数走 CLI。
- 将 `show_logo` 调用从 `main()` 首行挪到 CLI 分支内，避免菜单模式 logo 重复。
- 统一所有 `read` 提示符为 `ob-harness>` 前缀（黄色高亮）。
- 为正常退出和异常退出添加仪式感提示信息。

## 非范围

- 不新增 CLI 子命令（如 `ob dev` 等未来命令不在本次范围）。
- 不修改 init、build、status 的内部业务逻辑。
- 不处理终端宽度自适应（菜单宽度按固定格式）。
- 不做国际化或菜单项可配置化。

## 方案比较

### 方案 A：逐个替换 exit 为 return

- 核心思路：将 `cmd_build`、`cmd_init` 及其调用链中所有 `exit` 替换为 `return`，由调用方根据 return code 决定退出脚本还是回到菜单。
- 优点：精确控制每个退出点的语义。
- 缺点：改动点多（10+ 处 exit 分布在多层调用链中），需要逐层传播 return code；对深层函数（如 `verify_source` → `require_openbmc_repo` → `cmd_init`）的 exit 需要全链路改造。

### 方案 B：子 shell 隔离

- 核心思路：在 `cmd_menu()` 的 while 循环中，用子 shell `(cmd_xxx)` 包裹每个命令调用。子 shell 内的 `exit` 只退出子 shell，主脚本不受影响。用 `if` 包裹子 shell 调用以捕获 exit code 且不受 `set -e` 干扰。
- 优点：不改动任何现有 `exit` 调用；天然隔离 `cd`、`source setup`、环境变量等副作用；同时解决 exit、set -e、环境污染三类问题。
- 缺点：子 shell 内的变量修改不回传父 shell（但菜单模式下每个 cmd 是自包含的，不需要跨调用共享状态）。

## 推荐方案

**方案 B：子 shell 隔离。**

选择理由：
- 改动最小——现有 `exit` 调用一个都不用动。
- 一石三鸟——同时解决 exit 隔离、`set -e` 冲突、环境/目录污染。
- `cmd_build` 和 `cmd_status` 都是自包含的（通过扫描 `.init-done` 文件发现可用 machine），不依赖上一次调用留下的全局变量。

主要 trade-off：子 shell 内的变量赋值和 `cd` 不会回传，但这恰好是菜单模式下期望的行为（每轮循环从干净状态开始）。

## 关键边界与组件职责

### `cmd_menu()` 函数

- 菜单循环的主控函数，与 `cmd_init()`、`cmd_build()`、`cmd_status()` 平级。
- 职责：显示菜单、读取用户选择、分发给对应 cmd、处理成功/失败、循环回到菜单。
- 无参数调用时由 `main()` 进入。

### `cmd_init()` 函数（新增，从 main 抽出）

- 包含 init 的 8 个步骤：`prerequisites_check` 到 `print_report`。
- 前置准备（`parse_args`、`detect_harness_root`）留在 `main()` 公共层，不在 `cmd_init()` 内。
- 可被 CLI 模式和菜单模式共同调用。

### `main()` 入口重构

```
main() {
    parse_args "$@"
    detect_harness_root

    if [[ -z "$COMMAND" ]]; then
        cmd_menu       # 菜单模式，内部自己管 logo
        return $?
    fi

    show_logo           # CLI 模式才在这里打 logo
    if COMMAND == status → cmd_status()
    if COMMAND == build  → cmd_build()
    else                 → cmd_init()
}
```

### 退出函数

- `fn_quit()`：正常退出，打印 `ob-harness> ...... 退出 [ ob-harness · OpenBMC Development Environment ]`（默认色）。
- `fn_err_quit()`：异常退出，打印 `ob-harness> ...... 异常退出 [ ob-harness · OpenBMC Development Environment ]`（红色/黄色警示）。

## 数据流 / 控制流

### 菜单模式主循环

```
用户执行 ./ob（无参数）
  → main() 检测 COMMAND 为空
  → cmd_menu()
    → 首次：clear + show_logo()
    → 显示菜单
    → read -p "ob-harness> " 选择
    → case 分发：
        1) if (cmd_init); 成功/失败处理; read 等回车
        2) if (cmd_build); 成功/失败处理; read 等回车
        3) if (cmd_status); 成功/失败处理; read 等回车
        C) clear + 单行品牌行 + 菜单
        Q) fn_quit()
        *) 提示无效输入
    → 追加单行品牌行 + 菜单（不清屏）
    → 回到 read
```

### 子 shell 隔离模式

```bash
if (cmd_init); then
    info "初始化完成。"
else
    error "初始化过程中出现错误。"
fi
read -p "ob-harness> 按回车键继续..." _dummy
```

### 菜单显示格式

```
━━━ ob-harness ━━━   ← 黄色高亮 ob-harness

             1 - init - Initialize OpenBMC development environment
             2 - build - Build OpenBMC firmware image
             3 - status - Show current OpenBMC workspace status
             C - Clear terminal screen (c/C)
             Q - Quit this script (q/Q)

提示: CLI 模式 → ./ob init <machine> | ./ob build | ./ob --help

ob-harness> _
```

### 清屏规则

| 场景 | 清屏？ | 显示内容 |
|---|---|---|
| 首次进入菜单 | 清屏 | 全量 `show_logo()` + 菜单 |
| 命令开始执行前 | 不清屏 | 直接执行 |
| 命令完成后回到菜单 | 不清屏 | 追加单行品牌行 + 菜单 |
| 用户选 C) 清屏 | 清屏 | 单行品牌行 + 菜单 |
| 子命令内部交互 | 不清屏 | 不动 |

### 提示符规则

- 所有 `read` 调用统一使用 `ob-harness>` 前缀，黄色高亮。
- 纯 `echo` 输出不带前缀。
- 适用于菜单选择、子命令内部交互（选 machine、Y/N 确认等）。
- 大小写不敏感：所有字母选项（Y/N、C/Q）统一处理大小写。

### Logo 策略

- 首次进入菜单：调用现有 `show_logo()`（12 行渐变色 ASCII art + 框线）。
- 后续菜单刷新（命令完成后、清屏后）：显示单行品牌行 `━━━ ob-harness ━━━`（ob-harness 黄色高亮）。
- CLI 模式：`main()` CLI 分支内调用 `show_logo()`，行为不变。

## 错误处理与回退

| 失败模式 | 处理策略 |
|---|---|
| 子命令执行失败（init/build 中途出错） | 子 shell 内 `exit` 只退出子 shell；父 shell 捕获失败 exit code，打印醒目错误摘要，等用户按回车后回到菜单 |
| 子命令内部用户取消（如 build 选 N） | 子 shell 内 `exit 0` 退出子 shell；父 shell 视为成功完成，打印提示，回菜单 |
| `set -e` 触发非零退出 | 子 shell 内的 `set -e` 只终止子 shell；父 shell 用 `if` 包裹子 shell 调用，不受 `set -e` 影响 |
| 无效菜单输入 | 提示 `ob-harness> 无效输入，请选择 1/2/3/C/Q`，重新等待输入 |
| 非交互终端（stdin 非 tty） | `cmd_menu()` 入口检测 `[ -t 0 ]`，非终端时打印 `ob-harness> 检测到非交互式终端，请使用 CLI 模式: ./ob <command> [args]` 并退出 |
| Ctrl+C | 不做 trap 处理，直接终止整个脚本。用户重新 `./ob` 即可 |

## 测试策略

### 需要验证的核心行为

1. **CLI 模式不退化**：`./ob init`、`./ob build`、`./ob status` 行为与改造前完全一致。
2. **菜单模式基本流程**：`./ob` 进入菜单 → 选 1 执行 init → 完成后回菜单 → 选 Q 退出。
3. **失败不退出菜单**：init 或 build 失败后，菜单重新出现，用户可以继续选择。
4. **子 shell 隔离有效性**：build 执行后（会 `cd` 和 `source setup`），回到菜单时工作目录和全局变量未被污染。
5. **非交互模式拒绝**：`echo "1" | ./ob` 打印提示并退出，不进入菜单循环。
6. **大小写不敏感**：菜单中输入 `c` 或 `C`、`q` 或 `Q` 均有效。
7. **清屏规则**：验证首次进入清屏、命令完成后不清屏、用户选 C 清屏。
8. **logo 策略**：首次全量 logo，后续单行品牌行。
9. **退出信息**：正常退出和异常退出均有对应提示。

### 适合的测试层级

- **手动测试**：菜单模式的交互体验（显示、选择、循环、退出）只能手动验证。
- **脚本测试**：利用现有 `OB_NO_MAIN` 机制，可对 `cmd_menu` 的非交互逻辑（菜单渲染、case 分发）做单元级验证。

## 未决事项

无。所有设计点已在 grill 阶段逐一确认。
