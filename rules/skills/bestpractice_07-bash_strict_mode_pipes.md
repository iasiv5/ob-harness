# Bash strict mode 下的管道退出码陷阱

## 元数据

- **类型**: BestPractice
- **适用场景**: 在 `set -euo pipefail`（pipefail）下编写 Bash 脚本的管道命令时
- **创建日期**: 2026-06-22

---

## 目标

写脚本的人在 strict mode（`set -euo pipefail`）下用管道（`cmd | grep ...`、`cmd | awk ...`）时，能避免"管道下游命令无匹配/提前退出返回非零，被 pipefail 当成硬错误导致脚本意外中止"这一类 bug。

## 问题本质

`pipefail` 让管道的退出码 = 最后一个非零的管道组件退出码。`grep` 在无匹配时返回 1、`head` 在提前关闭管道时返回非零、`awk 'cond{exit 1}'` 等都是**预期的控制流信号**，但在 `pipefail` 眼里它们和"命令崩溃"不可区分，于是触发 `set -e` 把整个脚本干掉。

这不是 strict mode 的 bug，是它的设计——pipefail 无法区分"信号性非零"和"失败性非零"。判定权力必须交回给写脚本的人。

## 适用边界

- **适用**：strict mode（至少启用了 `pipefail`，通常还带 `set -e`）下的 Bash 脚本，且管道中存在"可能正常返回非零"的下游命令（grep/awk/head/sed 等）。
- **不适用**：未启用 pipefail 的脚本；或者管道下游命令的非零退出码本身就代表真实失败（如 `curl | jq`，curl 失败应当炸）。

## 处置模式

按"这个非零退出码是不是预期的控制流信号"分三类：

1. **纯布尔判断（最常见）**：用 `grep -q`/`awk` 只想知道"有没有匹配"，非零是正常。用 `if` 包裹或显式 `|| true` 吸收：

```bash
# 坏：无匹配时 grep 返回 1，pipefail 触发 set -e，脚本退出
cmd | grep -q "needle"

# 好：if 把退出码当布尔消费掉
if cmd | grep -q "needle"; then
    echo "hit"
fi

# 好：显式吸收（当你不想分支、只想要副作用）
cmd | grep -q "needle" || true
```

2. **保留输出、允许无匹配**：需要下游的输出，但下游空结果是合法状态。在管道末尾 `|| true`，或单独关闭 pipefail：

```bash
# 需要 grep 的过滤输出，但"过滤后为空"不应是 fatal
cmd | grep "pattern" || true

# 或局部放宽（仅这一段），用完恢复
set +o pipefail
cmd | some_filter
set -o pipefail
```

3. **下游命令的提前关闭**（如 `head -n1`、`sort | head`）：下游提前 close stdin 导致上游收到 SIGPIPE 返回非零。这通常不是错误，用 `|| true` 吸收或 `set +o pipefail` 局部放宽。

## 验收标准

一个无上下文 agent 据此自检 strict mode 脚本：

1. 脚本中每个 `| grep` / `| awk` / `| head` / `| sed` 管道，下游的非零退出码是否被正确处理（`if` 包裹 / `|| true` / 局部 `set +o pipefail`）？
2. 是否存在"裸 `cmd | grep -q`（没有被 if/|| 包裹）"的模式？这类一律是 bug 嫌疑。
3. 局部 `set +o pipefail ... set -o pipefail` 是否成对出现、且范围最小（只覆盖问题管道，不殃及正常管道）？

## 已知陷阱

| 陷阱 | 表现 | 应对 |
|------|------|------|
| 只想着 `set -e` 忘了 `pipefail` | 单独 `set -e` 不炸管道，一旦加 `pipefail` 才炸；排查时容易误判根因 | 判定管道异常先确认 `set -o` 当前状态（`set -o | grep pipefail`） |
| 用 `\|\| true` 一刀切 | 把真实失败的管道（如 `curl` 挂了）也吞掉，隐藏 bug | 仅对"下游非零是预期信号"的管道用；对"上游失败必须 fatal"的管道保留 pipefail 语义 |
| 局部放宽忘了恢复 | `set +o pipefail` 后漏 `set -o pipefail`，后续管道全失去保护 | 局部放宽必须成对，且范围收紧到单条管道；优先用 `\|\| true` / `if` 不动全局开关 |

## 相邻陷阱:无命令 `exec` 的持久重定向

`pipefail`/`set -e` 之外,strict mode 脚本里另一个易吞诊断的高发陷阱:`exec` 不带命令参数时,其重定向**作用于当前 shell 且持久**,而不是只作用于一条命令。

典型场景是关闭动态 FD 时想顺手隐藏 close 诊断:

```bash
# 错:exec 无命令,2>/dev/null 永久把当前 shell 的 fd2 指向 /dev/null。
#   后续所有写 stderr 的诊断(当前是 error();warn()/info()/verbose() 写 stdout,
#   不受影响)被静默吞掉;因 stderr 本身被吞,连"无诊断"都难发现
#   —— 表现为 rc 非零但完全无 error 文案。
exec {plan_fd}<&- 2>/dev/null

# 对:只关闭目标 FD,不附带 fd2 重定向;close 失败由 || true 防 set -e。
exec {plan_fd}<&- || true

# 如确实要隐藏 close 诊断:用块重定向(临时作用域,不污染当前 shell)。
{ exec {plan_fd}<&-; } 2>/dev/null || true
```

判定要点:`exec` 单独出现(后跟重定向、无命令词)= 持久重定向当前 shell;`exec cmd ...`(有命令词)= cmd 原地替换当前 shell 进程(PID 不变,不创建子进程),这些重定向成为 replacement program 的 fd 状态,成功后不存在返回原 shell 继续执行的路径。两者只差一个命令词,语义完全不同。本仓库 `lib/bare_mirror.sh` 的 plan_fd 关闭踩过此坑(round-1 用 `exec {plan_fd}<&- 2>/dev/null` 吞掉后续 `error()`,导致 fs-fatal 分支 rc=1 却无 error 输出,round-2 才定位)。

## 相邻陷阱:errexit 禁用上下文吞失败

另一个 strict mode 下"失败被静默"的高发陷阱:`set -e`(errexit)在条件、`&&`/`||`、命令替换 `$()`、进程替换 `< <()` 等上下文中**不触发**——这些位置命令失败只设返回码、不中止脚本。所以当一个函数被 caller 以 `if ! func` / `func && ...` / `$(func)` 调用时,函数体内没有显式检查的 mkdir/rm/cp 等 fs 操作失败会被静默吞掉。

典型危害(本仓库 `lib/bare_mirror.sh` 踩过,2026-07-12 round-2 评审挖出):partial cleanup 的 `rm -rf "$partial_dir"` 失败被吞 → 残留目录下次被 `[[ -d ]]` 误判为 existing → 缓存污染致后续 fatal。表现为整批 rc=1 但定位不到哪个 fs 操作先失败。

```bash
# 错:adapter 以 `if ! func` 调用,func 体内 mkdir/rm 失败处于 errexit 禁用上下文,被静默。
if ! bare_mirror_provision "$deps"; then error "..."; exit 1; fi
#   (bare_mirror_provision 内部 `mkdir "$dir"` 失败时,set -e 不触发,静默继续)

# 对:leaf-pure module 不依赖 caller 的 errexit,显式检查每个 fs 操作返回码。
mkdir "$dir" || return 1
rm -rf "$partial" || return 1
```

判定要点:`set -e` 只在命令返回码被"直接观察"的最外层生效;一旦命令出现在 `if`/`while`/`&&`/`||`/`$()`/`< <()` 的条件位,它就退出 errexit 保护、失败只成返回码。约定:leaf-pure module(见 [bestpractice_10](bestpractice_10-deep_module_extraction.md))恒不假设 caller 开 errexit,所有 fs/外部命令失败必须显式 `|| return`;caller 的 `if ! func` 只兜 module 整体返回码,不兜 module 内部。与上面 exec 持久重定向同属"strict mode 静默吞诊断"族——一个吞 stderr 一个吞返回码,解药都是显式而非隐式。

## 相邻陷阱:输入重定向 `< 文件` 打开失败绕过子命令的 2>/dev/null

`cmd < file 2>/dev/null` 当 `file` 不存在时,`< file` 的打开由 **shell 在子命令启动前**完成,失败错误("No such file or directory")写到 **shell 的 stderr**;而 `2>/dev/null` 是**子命令的** fd2 重定向——子命令因重定向失败根本没启动,`2>/dev/null` 还没生效、吞不掉这条 shell 错误。表现为 rc 非零(重定向失败码)+ stderr 漏一行噪音,易误判成"测试脏输出"或"还有别的报错"。

典型是想用 `wc -l < file` 计数、又怕文件不存在加 `2>/dev/null` 吞错:

```bash
# 错:`< "$calls"` 不存在时,bash 层 open 失败的错误到 shell stderr,
#   `2>/dev/null`(wc 的)吞不掉(wc 没启动)。漏一行 "bash: ...: No such file" 噪音。
count=$(wc -l < "$calls" 2>/dev/null || echo 0)

# 对 A:改用文件参数(非重定向)——文件不存在时 wc 自己报错到 wc 的 stderr,2>/dev/null 可吞。
count=$(wc -l "$calls" 2>/dev/null | awk '{print $1+0}')
# 对 B:先判存在再重定向,把"不存在"显式化。
[[ -f "$calls" ]] && count=$(wc -l < "$calls") || count=0
# 对 C:本意是断言"文件不该存在"时,别用计数==0,直接 test -f。
```

判定要点:区分**谁打开文件**——`< file` 是 shell 重定向(open 发生在 fork/exec 子命令前,失败属 shell);`cmd file`(文件作参数)是子命令自己 open(失败属子命令,其 `2>/dev/null` 可吞)。所以"想静默文件缺失"用文件参数让子命令 own open,或显式 `[[ -f ]]` 前置;断言语义是"文件存在与否"时不要用 `wc -l < file` 计数间接表达,直接 `test -f`/`[[ -f ]]`。**不只 wc**——`cat < file`/`grep ... < file` 等所有 `< file` 形态同理。

本仓库案例:`tests/unit/image_build.sh` 态3(build_obmc_image 抽取时 enter 失败→bitbake 不调→`.bitbake.calls` 不存在)原写 `wc -l < "$DB/.bitbake.calls" 2>/dev/null || echo 0` 断言计数==0,实跑漏"没有那个文件或目录"噪音(assert 逻辑靠 `|| echo 0` 兜底仍正确);改 `assert_false test -f`(与 `tests/orchestration/deploy_to_qemu.sh` 场景④同款)。注意既有 `cmd_build_bitbake_handoff.sh`/`deploy_to_qemu.sh` 的同款写法在文件**存在**时无此问题,只有"文件可能不存在"的场景才中招。

与 exec 持久重定向、errexit 禁用上下文同属"bash 重定向/执行语义"族——作用域错(exec 持久 vs 单条)、时机错(输入重定向 open 早于子命令 fd2)、触发位错(set -e 在条件位不生效),解药都是把语义显式化(块作用域/文件参数/显式 `|| return`)而非靠隐式重定向。

## 与现有 skill 的关系

- `workflow_01-obmc_env_init.md` 记录的「BitBake `??=` 优先级陷阱」是 strict mode 之外的另一类"看起来赋值了实际没生效"的 shell 相邻陷阱，可互为补充。
