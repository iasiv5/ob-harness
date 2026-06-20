# ob-harness

OpenBMC 开发环境的一键初始化、源码管理、编译和 QEMU 仿真工具链。核心命令是 `ob init`（准备 BitBake 构建环境、解析依赖、克隆源码、注入构建配置）、`ob build`（交互选择已初始化的 machine，执行 bitbake 编译）、`ob start-qemu`（构建产物通过 QEMU 仿真真实 BMC 硬件启动）和 `ob stop-qemu`（安全停止 QEMU 实例）。

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

**init-done marker**:
`workspace/configs/<machine>.init-done` 文件，由 `ob init` 在全部 8 步完成后原子写入，重跑时先删除再重新写入。`ob build` 用它判定哪些 machine 可以编译。
_Avoid_: 完成标记, completion flag

**QEMU source**:
QEMU binary 的来源，取值 `community` 或 `custom`，与 `openbmc-source.lock` 中的 `source_label` 对齐。`community` 从 OpenBMC Jenkins 下载，`custom` 从企业配置的 URL 下载。
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
`ob` 在面向用户的破坏性确认前输出的视觉块：横线边框 + 3 行重复 `warn`，内容形如 `You are about to <verb>: >>> <object> <<<`。它只负责视觉强调，不含确认逻辑——Y/N 循环、3 秒倒计时、批量处理由各确认点自行管理。覆盖门槛是"破坏性够分量"，太轻的确认（如清理一条 stale SSH host key）不套。
_Avoid_: 三次重复提示, heavy gate, 确认门

**function semantic layer**:
`ob` 脚本内部对函数的调用层级标注，自上而下为 L1（`cmd_*` 命令编排，用 `exit 3` 表前提不满足）、L2（前置检查点，如 `require_path`，exit code 由调用方传入）、L3（底层通用工具，如 `log`/`select_from_list`/`read_kv_field`，**绝不 exit，只 return 码**）。标注写在函数注释里（如 `# L3 — never exits`）。这是函数的**语义属性**，与测试无关。
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
