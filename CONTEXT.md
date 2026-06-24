# ob-harness

OpenBMC 开发环境的一键初始化、源码管理、编译和 QEMU 仿真工具链。核心命令是 `ob init`（准备 BitBake 构建环境、解析依赖、克隆源码、注入构建配置）、`ob build`（交互选择已初始化的 machine，或用 `ob build <machine>` 非交互直构，执行 bitbake 编译）、`ob start-qemu`（构建产物通过 QEMU 仿真真实 BMC 硬件启动）和 `ob stop-qemu`（安全停止 QEMU 实例）。

## Language

**externalsrc**:
BitBake 内置类，通过 `EXTERNALSRC_pn-<recipe>` 将 recipe 的源码指向本地目录，使 `do_fetch` 和 `do_unpack` 被跳过。
_Avoid_: 外部源码, external source

**bare mirror**:
存放在 `DL_DIR/git2/` 中的 `--bare` git 仓库，按 BitBake 命名规则（`gitsrcname`）组织。ob-harness 用于跨 machine 源码去重。
_Avoid_: mirror cache, git mirror

**working tree**:
`workspace/src/<machine>/<repo>/` 中的完整 git 仓库，开发者直接在其中编辑源码。externalsrc 将 recipe 指向这些目录。
_Avoid_: 源码目录, source directory

**deps.json**:
`parse_bitbake_deps.py` 产出的依赖解析结果，包含每个 recipe 的 SRC_URI、SRCREV 和 clone URL。
_Avoid_: 依赖文件, dependency list

**machine snapshot**:
`workspace/configs/<machine>.snapshot` 文件，由 `ob init` 在依赖图解析和 bare mirror 填充后生成，记录 machine、OpenBMC commit、target image 和每个子仓库的 recipe/SRC_URI/SRCREV/local_path。它是 source/deps snapshot，不是互斥锁，也不表示 `ob init` 已完成；完成信号只看 `init-done marker`。旧的 `<machine>.lock` 命名已废弃，不再兼容。
_Avoid_: lockfile, machine lock, state lock, 把 snapshot 当完成标记

**source manifest**:
harness 绑定的 OpenBMC 主仓库 source 的归属记录与漂移校验基准。物理文件为 `workspace/configs/openbmc-source.manifest`（kv 文本），由 `ob init` 写入，记录 normalized_source / origin_url / source_label / created_at。它表达"一个 harness 只绑定一个主仓库 source"这条 invariant，`verify_source` 据其检测 origin 是否被手动漂移。它是归属记录而非互斥锁（项目里真正的文件锁是 qemu 的 `.update.lock`，用 flock）；也非 per-machine（区别于现行 `machine snapshot`，旧的 `<machine>.lock` 已废弃）。
_Avoid_: source lock, source pin, source binding, 把它当文件互斥锁

**init-done marker**:
`workspace/configs/<machine>.init-done` 文件，由 `ob init` 在全部 8 步完成后原子写入，重跑时先删除再重新写入。`ob build` 用它判定哪些 machine 可以编译。
_Avoid_: 完成标记, completion flag

**state file format**:
ob 在 `workspace/configs/` 下的状态文件按数据形状选格式：扁平标量字段用 kv 文本（`key=value` + `#` 注释，如 `source manifest`，用 `read_kv_field` 读）；嵌套/列表结构用 JSON（如 `machine snapshot` 的 `sub_repos` 数组，用 python json 读写）。依据是数据形状匹配表达力，不为统一而把扁平数据塞进 JSON。
_Avoid_: 强制单一格式, 把扁平状态文件写成 JSON

**QEMU source**:
QEMU binary 的来源，取值 `community` 或 `custom`，与 `source manifest` 中的 `source_label` 对齐。`community` 从 OpenBMC Jenkins 下载，`custom` 从企业配置的 URL 下载。
_Avoid_: QEMU 版本, QEMU flavor

**QEMU manifest**:
`workspace/qemu-bin/<source>/.manifest` 文件，记录 QEMU binary 的来源 URL、Jenkins build number（社区源）、下载时间、sha256。用于版本管理和更新判断。
_Avoid_: QEMU 配置, QEMU metadata

**QEMU PID file**:
`workspace/qemu-bin/.pids/<machine>.pid` 文件，记录 QEMU 实例的 PID、启动用户、machine 名、binary 路径和启动时间。`ob stop-qemu` 通过此文件精确 kill，防止多用户共享环境下误杀。
_Avoid_: QEMU lock, QEMU state

**QB variable**:
BitBake 变量（`QB_MACHINE`、`QB_MEM` 等），定义在 OpenBMC machine conf 及其 include 链中。`ob start-qemu` 通过 `bitbake -e` 解析最终生效值，ob-harness 不提供 fallback。
_Avoid_: QEMU 配置变量, QEMU 参数

**confirmation banner**:
`ob` 在面向用户的高代价或破坏性动作前输出的视觉块：横线边框 + 3 行重复 `warn`，内容形如 `You are about to <verb>: >>> <object> <<<`。它只负责视觉强调，不含确认逻辑——Y/N 循环、3 秒倒计时、批量处理由各确认点自行管理。**是否触发取决于路径风险，不单看操作本身**：从列表交互选择、或撞上需杀掉的运行实例这类有误伤风险的路径才确认；显式表达意图的快路径（如 `ob init <machine>`、正常起 QEMU）一律跳过、无需 `--force`。够分量才配 banner（init 拉 20-30GB、build 1-4 小时、kill 运行中的 QEMU），太轻的（如清理一条 stale SSH host key）不套。
_Avoid_: 三次重复提示, heavy gate, 确认门, 破坏性够分量（旧口径，已收紧为路径风险）

**function semantic layer**:
`ob` 内部对函数角色的调用层级词汇：L1（`cmd_*` 命令编排，exit seam）、L2（前置检查点，如 `require_path`）、L3（底层通用工具，如 `log`/`select_from_list`/`read_kv_field`）。**已物化为 `lib/*.sh` 文件边界**：原 ob 内 §2-§6 注释分区现由 `lib/{util,repo,qemu,machine_state,init_pipeline,commands}.sh` 六文件承载（util=L3 底层、repo=仓库/machine 解析、qemu=QEMU runtime、machine_state=Machine lifecycle state、init_pipeline=init 流水线、commands=cmd_* 编排），结构边界从注释锚点转为文件名；`exit_contract` Y 规则按 basename 配置的 leaf-pure modules（当前 `util.sh` / `machine_state.sh`）断言下层 module 不 exit（除各自例外集）。讨论代码用的层级启发式语义仍适用（cmd_* 是 exit seam、util/machine_state 是下层 no-exit module），但结构边界已从注释转为文件。
_Avoid_: 调用层级, 函数分级；勿与 test layer（protocol/unit/orchestration/integration，曾用 L0–L3）混用

**test layer**:
`ob` 测试体系的分层，自下而上为 protocol（退出码协议，非交互）、unit（纯函数单测，零依赖毫秒级）、orchestration（编排函数，PATH 注入 stub）、integration（真实集成，init→build→QEMU 全流程）。曾用 L0–L3 编号，为脱离与「function semantic layer」的 L1/L2/L3 撞名而改语义名。
_Avoid_: 测试等级, 覆盖等级, L0–L3（旧称已弃）, function semantic layer

**ob 优先 (ob-first)**:
做 OpenBMC 环境生命周期动作（init/build/status/start-qemu/stop-qemu 及未来子命令）前，先查 `ob --help` 是否提供对应能力；提供则走 `ob <cmd>`，仅当 exit 1 真实失败且 ob 确无此能力时才手动兜底。`ob --help` 是唯一权威能力清单。
_Avoid_: tool-first, ob first, 能力清单（并入本条）

**exit-code 契约**:
`ob` 所有 `cmd_*` 统一退出码：0=成功/良性无操作，1=真实失败（坏了或用法错），2=用户主动取消（非失败），3=前置缺失（修复方式是用 ob 补前置）。agent 仅在 exit 1 触发回退；补充 `function semantic layer` 条目里关于 exit 3 的说法。
_Avoid_: 返回码约定, exit status

**remedy line**:
`ob` 在 exit 3（前置缺失）报错里给调用方（主要是智能 agent）的**下一步描述**。输出固定两段式：先**诊断行**说明哪条前置没满足（如 `Machine 'X' has not been initialized.`），再**恰好一行 remedy line**——描述满足该前置所需的下一步。常见形态是 `Run 'ob init X' first.`，但**不锁死为 ob 命令**：消费者是智能 agent，可自行决定用 ob 解决、通知用户或自行探索。要求非空且向前看（是「下一步」，而非「上一步可能失败了」这类纯回溯诊断）。
_Avoid_: 提示语, hint, 错误提示, 锁死为 ob 命令

**ob-managed variable**:
`ob init` 注入到 `externalsrc-<machine>.inc` 的变量（当前 DL_DIR、SSTATE_DIR、PREMIRRORS）。注入规则：仅当 local.conf 中**无该变量的赋值行**时才注入——判定用 `read_local_conf_var` 的 exit code（有赋值行=用户接管，含空值；无赋值行=ob 写默认），**不**用值是否非空（`-n`）。即用户一旦显式赋值即视为接管、ob 不覆盖；无赋值行时 ob 写入默认（workspace 共享缓存、清华 mirror 等）。空值的语义是"用户有意禁用/留空"，不是"配置缺失"——理由见 [ADR-0005](docs/adr/0005-local-conf-var-detection-exit-code.md)。
_Avoid_: ob 配置变量, 自动配置变量, 把空值当"未配置", `-n` 判定（已统一为 exit code）
