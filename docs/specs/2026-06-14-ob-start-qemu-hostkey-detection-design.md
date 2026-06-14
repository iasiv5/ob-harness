# ob start-qemu host key 冲突主动检测 设计文档

> 关联实施计划：`docs/plans/2026-06-09-start-qemu-implementation-plan.md`（start-qemu 主体功能）。本设计是它的增量增强，落在 SSH 就绪流程的收尾段。

## 背景与目标

**为什么要做**

`ob start-qemu` 在启动 QEMU 后会用一个 SSH 就绪探测循环（`ob:3702-3728`）等 BMC 的 SSH 起来，最长 150s（30 次 × 5s）。探测用的是：

```
sshpass -p 0penBmc ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
     -o UserKnownHostsFile=/dev/null -p "$ssh_port" root@localhost echo "OK"
```

关键事实：`UserKnownHostsFile=/dev/null` 让这个探测**完全不读用户的 `~/.ssh/known_hosts`**，所以它对 host key 变化是免疫的——探测成功与否和 host key 无关。

但用户**手动** `ssh root@localhost -p 2222` 走的是默认 `~/.ssh/known_hosts` 和默认严格校验。OpenBMC 镜像每次重建都会重新生成 host key，于是 known_hosts 里 `[localhost]:2222` 的旧 key 和新镜像的 key 对不上，ssh 直接报 `REMOTE HOST IDENTIFICATION HAS CHANGED` 并拒绝连接。

结果是一个**很误导的体验**：`ob start-qemu` 打印 `✅ QEMU started` + 一堆 Connect 信息，用户照着 `ssh root@localhost -p 2222` 敲下去却被 host key 硬拒，会以为 BMC 没起来。实际 QEMU 实例正常运行，只是本地 known_hosts 有一条陈旧 key。

而且这个坑**与就绪探测成败无关**：哪怕探测 ✅，手动 ssh 照样被咬。

**这次要解决什么问题**

在 start-qemu 收尾阶段主动检测 `~/.ssh/known_hosts` 是否有 `[localhost]:<port>` 的旧 key 冲突，命中则透明展示冲突坐标 + 精确修复命令，经 Y/N 确认后由 ob 执行 `ssh-keygen -R` 清掉那一条。让用户不再因为陈旧 host key 被手动 ssh 拒之门外，也不用在「BMC 没起来」的误判上浪费时间。

**成功标准**

1. 镜像重建后跑 `ob start-qemu`：自动命中 known_hosts 冲突，展示 offending 行，Y 后清理，手动 ssh 直通。
2. 镜像未重建（key 匹配）：静默，不弹任何 host key 相关提示，不污染正常输出。
3. 首次连接（known_hosts 无该条目）：静默。
4. 清理动作只删 `[localhost]:<port>` 一条，原文件备份为 `known_hosts.old`，可回滚。

## 范围

- 在 `start_qemu` 函数（`ob`）的就绪循环之后、Connect 段之前，新增一段 host key 冲突检测 + 交互清理逻辑。
- 检测手段：复用 ssh 自己的诊断（一条「镜像手动 ssh」的探测），不引入新依赖（不依赖 `ssh-keyscan`）。
- 冲突时的处理：透明展示 offending 文件:行号 + 该行完整内容 + 精确 `ssh-keygen -R` 命令，Y/N 确认后执行清理。
- 在 `--no-wait` 模式下也运行检测（单次 ~3s 探测，不属于等待循环）。

## 非范围

1. 不重写 150s 就绪等待循环、不做分级诊断（QEMU 存活 / 端口 / sshd 应答 / 登录差分）。那是更广的方案，本次明确排除。
2. 不处理用户在 `~/.ssh/config` 里自定义 `UserKnownHostsFile` 的非常规配置——假设默认 `~/.ssh/known_hosts`。
3. 不固定或注入 BMC 端 host key（让重建镜像 key 稳定的另一层问题）。
4. 不扩展到 `ob stop-qemu` 或独立的重启命令。host-key 冲突只与「`~/.ssh/known_hosts` 现状」vs「当前镜像的 host key」有关，与 QEMU 运行态无关；ob 里唯一能卡在「即将 SSH」那一刻的拦截点是 `start-qemu`。任何真正加载新镜像的重启都会重新跑完整 `start_qemu` 流程并触发本检测：`ob start-qemu --force`（杀旧起新，见 `ob:3529` 的 `--force` 分支）或 `ob stop-qemu` + `ob start-qemu`。不带 `--force` 在已跑实例上再 `start-qemu` 会提前报错退出（`ob:3554-3555`），但这种情形没有加载新镜像、旧实例仍服务旧 key，known_hosts 仍匹配，本就没有冲突可检测。`stop-qemu` 只杀进程、不碰 known_hosts、不改变镜像 key，在它上面做 host-key 检测既语义错位又冗余。
5. 不写 `~/.ssh/known_hosts` 以外的任何文件。

## 方案比较

### 方案 A：只改提示文案

- **核心思路**：不加检测逻辑，仅在就绪超时和 Connect 段补一句静态文案——重建镜像会重新生成 host key，手动 ssh 若报 `HOST IDENTIFICATION HAS CHANGED` 就跑 `ssh-keygen -R '[localhost]:<port>'`。
- **优点**：改动最小（~5 行），零风险。
- **缺点**：纯被动，只在用户已经被咬、且认真读文案时才帮上忙；探测成功路径下用户更可能忽略这行。

### 方案 B：主动检测冲突 + 交互清理（推荐）

- **核心思路**：就绪循环后跑一条「镜像手动 ssh」的探测（走真实 known_hosts + 默认严格校验），命中 changed-key 标记则透明展示冲突坐标 + 精确修复命令，Y/N 确认后由 ob 执行 `ssh-keygen -R`。即便探测成功也检测。
- **优点**：直接对准真实痛点（陈旧 known_hosts），探测成功路径下也生效；修复命令由 ssh 自己生成、由 ob 执行，省去用户复制带方括号命令的麻烦；只删一条且自带备份，风险可控。
- **缺点**：改动中等（新增一段检测 + 交互），且在交互模式下会多一个 Y/N。

### 方案 C：失败诊断升级

- **核心思路**：把 150s 超时路径重写成分级诊断（QEMU 进程存活？端口开？sshd 应答？登录通？host key 冲突？），打印差分结论，并把方案 B 叠进去。
- **优点**：覆盖就绪探测 30/30 超时的真实成因分析。
- **缺点**：改动最大，动到等待循环本身，超出本次「优化 host key 提示」的目标。

## 推荐方案

**方案 B。**

理由：用户实际踩中的痛点是「探测 ✅ 但手动 ssh 被 host key 拒」，方案 A 的静态文案在成功路径下基本被忽略，方案 C 的范围溢出。方案 B 用一条低成本的镜像探测精准定位冲突，且把修复落到一键 Y/N，正好匹配目标。`ssh-keygen -R` 的爆炸半径已实测确认（见「关键边界」），交互清理的风险足够低。

主要 trade-off：在交互模式下多一次 Y/N；脚本多一段检测逻辑（约 30-40 行）。两者都可接受。

## 关键边界与组件职责

1. **与现有就绪探测隔离**：现有探测（`ob:3712-3713`）用 `UserKnownHostsFile=/dev/null`，对 host key 免疫，保持不动。新增的是一条**独立**的镜像探测，走真实 `~/.ssh/known_hosts` + 默认 `StrictHostKeyChecking`。两条探测互不干扰，不合并。

2. **判定阈值严格**：只在镜像探测的 stderr 命中 changed-key 标记（`REMOTE HOST IDENTIFICATION HAS CHANGED`）时判定冲突。下列情况一律静默，不误报：
   - `Permission denied`（key 匹配但 BatchMode 无密码）。
   - 首次连接 unknown key（known_hosts 无该条目，stderr 只有 `Host key verification failed`，没有 changed-key 块）。
   - 正常连通。

3. **爆炸半径受控**：清理动作只删 `[localhost]:<port>` 一条。已实测：`ssh-keygen -R '[localhost]:2222'` 在 6 行样本（含相邻端口 `[localhost]:2223`、`localhost` 默认 22、`[localhost]:22`、`github.com`、`192.168.1.5`）里只删目标那一条，其余全保留，且自动生成 `known_hosts.old` 备份。ssh-keygen 还会打印 `# Host [localhost]:2222 found: line N`，明确动的是第几行。

4. **触发时机**：默认在就绪循环（`ob:3703-3728`）结束后、Connect 段（`ob:3730` 起）之前运行，**无论就绪探测成功还是超时**。`--no-wait`（`QEMU_NO_WAIT=1`，跳过就绪循环）也运行——检测是一次 ~3s 的单发探测，不属于等待循环。

## 数据流 / 控制流

**插入点**：`ob:3728`（就绪循环 `fi`）之后、`ob:3730`（`# ── Print connection summary ──`）之前。

**关键处理步骤**：

1. 跑镜像探测，捕获 stderr（不输出到终端，避免污染）：
   ```
   ssh -o BatchMode=yes -o ConnectTimeout=3 -p "$ssh_port" root@localhost true
   ```
   - host key 校验发生在认证之前，所以不需要密码 / sshpass。
   - 故意不 override `UserKnownHostsFile`、不关 `StrictHostKeyChecking`——和用户手动 ssh 完全一致。

2. 判定与分流（按 stderr 内容）：
   - 含 `REMOTE HOST IDENTIFICATION HAS CHANGED` → 判冲突，进入第 3 步。
   - 否则 → 静默，结束检测，进入 Connect 段。

3. 冲突展示（仅判冲突时）：
   - 解析 offending 坐标：正则 `Offending [A-Z0-9]+ key in ([^:]+):([0-9]+)` → `<file>` / `<line>`。
   - `warn`：检测到 `[localhost]:<port>` 在 `<file>:<line>` 的 host key 与当前镜像不匹配（镜像重建会重新生成 host key），手动 ssh 会被拒绝。
   - 展示该行完整内容：`sed -n "<line>p" "<file>"`（脚本内，非工具调用）。
   - 展示精确命令：`ssh-keygen -f "<file>" -R "[localhost]:<port>"`（用已知 `$ssh_port` + 解析到的 `<file>` 自己构造，不依赖解析 ssh 的 "remove with:" 块，跨 OpenSSH 版本更稳）。
   - 提示：只删这一条，原文件备份为 `known_hosts.old`。

4. 交互确认：复用 ob 现有 Y/N 风格（`ob:749-754` 的 `read -r -p "${PROMPT_PREFIX} Type (Y/y) to ..., (N/n) to cancel: " confirm` + `case`）。提示文案：`Type (Y/y) to clear the stale key, anything else to skip`。
   - 输入 `Y/y` → 执行 `ssh-keygen -f "<file>" -R "[localhost]:<port>"`，`info` 报成功 + 备份位置。
   - 其它 → `info`「已跳过。手动执行：<命令>」。
   - 两种结果都继续进入 Connect 段。

**关键输出**：仅在命中冲突时产生 warn + 展示 + Y/N；无冲突时零输出。

## 错误处理与回退

1. **解析 offending 坐标失败**（正则没匹配上，OpenSSH 版本措辞差异）：不展示具体行内容，但仍执行默认文件的 `ssh-keygen -R "[localhost]:<port>"`（不带 `-f`，走默认 `~/.ssh/known_hosts`）。降级但正确。
2. **sshd 没起来**（镜像探测连不上、拿不到 key）：不判冲突、不弹 Y/N，只打印一句通用提示——重建镜像后 host key 会变，若手动 ssh 报 host key 错，跑 `ssh-keygen -R '[localhost]:<port>'`。覆盖 `--no-wait` 且 sshd 未就绪的场景。
3. **`ssh-keygen` 不存在**（极少见）：降级为只打印修复命令，让用户手动执行。
4. **镜像未重建 / key 匹配**：镜像探测得到 `Permission denied`（BatchMode 无密码），非 changed-key 标记 → 静默。
5. **首次连接**（known_hosts 无 `[localhost]:<port>` 条目）：镜像探测 stderr 无 changed-key 块 → 静默。

## 测试策略

手工验证矩阵（ob 是交互式脚本，以实跑为准）：

| 场景 | 前置 | 期望 |
|---|---|---|
| 重建镜像后连接 | 重建 image → `ob start-qemu` | 命中冲突，展示 offending 行，Y 后清理，备份生成，手动 ssh 直通 |
| 镜像未重建 | known_hosts 里 key 与当前镜像一致 | 静默，无 Y/N，输出同改动前 |
| 首次连接 | 删掉 known_hosts 里 `[localhost]:<port>` 条目 | 静默，无 Y/N |
| `--no-wait` + sshd 已起 | `ob start-qemu <machine> --no-wait`，sshd 已监听 | 仍检测，命中则走交互清理 |
| `--no-wait` + sshd 未起 | 刚启动还没就绪 | 退化为通用提示，不弹 Y/N |
| 解析失败兜底 | 构造非标准 stderr | 不展示行但仍执行默认 `ssh-keygen -R` |
| 爆炸半径复核 | 跑「关键边界 3」的 6 行样本实验 | 只删目标一条，其余保留，`.old` 生成 |

复核脚本（爆炸半径）：用 `/tmp` 下含相邻端口和多 host 的样本 known_hosts，跑 `ssh-keygen -R '[localhost]:<port>'`，确认只删一条 + 生成 `.old`。

## 未决事项

无。原本列出的两点已澄清/解决：

- **三行重复 `warn`（`ob:3598-3600`）**：经确认为有意设计，与 `ob init`（`ob:2827-2829`）、`ob build`（`ob:2309-2311`）、QEMU binary 更新（`ob:742-744`）是同一套 3× 强调 block，不是 bug，本次不动。
- **`ob stop-qemu` / 重启路径**：经分析不纳入范围，理由见「非范围 4」。host-key 冲突的唯一相关拦截点是 `start-qemu`，所有加载新镜像的重启路径都会经它触发检测，无遗漏。
