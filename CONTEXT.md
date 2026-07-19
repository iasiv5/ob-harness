# ob-harness

OpenBMC 开发环境的一键初始化、源码管理、编译和 QEMU 仿真工具链。核心命令是 `ob init`（准备 BitBake 构建环境、解析依赖、克隆源码、注入构建配置）、`ob build`（交互选择已初始化的 machine，或用 `ob build <machine>` 非交互直构，执行 bitbake 编译）、`ob start-qemu`（构建产物通过 QEMU 仿真真实 BMC 硬件启动）和 `ob stop-qemu`（安全停止 QEMU 实例）。

## Language

**externalsrc**:
BitBake 内置类，通过 `EXTERNALSRC_pn-<recipe>` 将 recipe 的源码指向本地目录，使 `do_fetch` 和 `do_unpack` 被跳过。
_Avoid_: 外部源码, external source

**bare mirror**:
存放在 `DL_DIR/git2/` 中的 `--bare` git 仓库，按 BitBake 命名规则（`gitsrcname`）组织。ob-harness 用于跨 machine 源码去重。
_Avoid_: mirror cache, git mirror

**bare mirror provisioning**:
`ob init` Step 5 的 bare mirror 填充流程，由 leaf-pure `lib/bare_mirror.sh` 拥有。消费 `deps.json`，在 effective `DL_DIR/git2`（`bare mirror` 目录）下，一次性 NUL-framed planner 展开 clone URL / 应用 URL rewrite / 算 gitsrcname mirror path / command-scoped `git clone --bare` / 记录 new/existing/failed disposition 与 report state。individual clone failure 非致命（记录后让 BitBake 后续 fetch）；损坏 `deps.json` 或 planner protocol failure 由 `clone_sub_repos` adapter 收口为 exit 1。public interface：`bare_mirror_provision` / `bare_mirror_base` / `bare_mirror_print_status`；provisioning 状态是 module 私有，不再经 `ob` 全局变量泄漏。与 `source manifest`、`machine snapshot` 正交。
_Avoid_: 把 provisioning 状态读成 ob 全局变量, 在 clone_sub_repos 内维护 URL rewrite 表

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

**runtime Git mirror host**:
`init_openbmc_repo.sh` 改写后写入 vendor 脚本（`meta-*/git-mirror-url.sh`，legacy `github-gitlab-url.sh`）的 `GIT_MIRROR_HOST`（或 legacy `GITLAB_IP`）的值，表达这台 harness 绑定的 vendor Git mirror 的 host。ob 在 clone 子仓库、设 git insteadOf、生成依赖图时提取它（vendor 脚本优先，fallback 主仓 origin）。它是 vendor 子仓 mirror 归属，与 `source manifest`（主仓 source 归属）正交：source manifest 记主仓从哪来，runtime Git mirror host 记 vendor 子仓 mirror 在哪。
_Avoid_: GIT_MIRROR_HOST（变量名非概念）, git mirror, mirror host（口语化）, 把它当 source manifest

**init-done marker**:
`workspace/configs/<machine>.init-done` 文件，由 `ob init` 在全部 8 步完成后原子写入，重跑时先删除再重新写入。`ob build` 用它判定哪些 machine 可以编译。
_Avoid_: 完成标记, completion flag

**firmware-image-ready machine**:
已经完成 `ob init`，且存在可供后续消费的 OpenBMC firmware image artifact 的 machine。它表达 firmware image artifact 是否就绪，不表达最近一次 BitBake 流程是否成功，也不限定消费点是 QEMU。
_Avoid_: image-ready machine, built, build succeeded, image-present, image=yes, QEMU image

**orphan firmware image artifact**:
存在 firmware image artifact，但对应 machine 尚未由 `init-done marker` 确认为 initialized 的状态诊断事实。它可以在 `ob status` 中解释残留产物，但不能让 machine 进入 `firmware-image-ready machine`。
_Avoid_: invalid image, broken image, QEMU-ready artifact

**machine lifecycle state**:
ob 对单个 machine 当前生命周期事实的组合判断，由 `machine snapshot`、`init-done marker` 和 firmware image artifact 共同决定。它回答 machine 是否 initialized、是否 partial、是否是 `firmware-image-ready machine`、是否存在 `orphan firmware image artifact` 等状态问题；不包含 `ob status` 表格排版、`remedy line`、`exit-code 契约` 或用户交互策略。
_Avoid_: UI state, command policy, 把展示文本当 lifecycle state

**machine selection**:
`lib/machine_picker.sh` 中 `pick_machine` 封装的交互选择 module。它在调用者已保证 machine 集合非空且为交互终端的前提下，渲染纯序号+名字选择表，读取用户输入（数字或名字），将选中的 machine 设入 `$MACHINE`，或以 return 2 表示取消。它是 leaf-pure L3（绝不 exit，不决定 `exit-code 契约`，不打印 `remedy line`）；不判断集合是否为空、不判断终端交互性、不做 arg 合法性校验——这些是调用者（L1 `cmd_*`）的命令级前置。它只管"选哪个 machine"，与 `machine lifecycle state`（machine 处于什么状态）正交。
_Avoid_: machine picker（口语化，术语用 selection）, 把 selection 当 lifecycle state, resolve_machine（init 旧函数，含 arg 快路径与 confirm，职责更宽）

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

**QEMU instance**:
workspace 里某个 machine 对应的、可能正在运行的 QEMU 进程的逻辑视图，由 `QEMU PID file` 记录。它回答"哪个 machine 的 QEMU 在跑 / 状态如何（存活、PID、转发端口）"，是 `ob status` 展示、`ob stop-qemu` 枚举、`ob start-qemu` 冲突检测共同关心的抽象；`QEMU PID file` 是它的物理载体，二者是实体与记录的关系。与 `machine lifecycle state` 正交：lifecycle state 回答 machine 处于 init/build 的哪个阶段，instance 回答 machine 的 QEMU 进程当前是否在跑——一个 `firmware-image-ready machine` 可以没有 QEMU instance（未 start-qemu），一个 stale QEMU instance 也不改 lifecycle state。instance 集合的增（start-qemu 写 PID file）删（stop-qemu / kill-restart 删 PID file）是 lifecycle 动作的副作用，不是 instance 视图自身的职责。
_Avoid_: QEMU process（OS 进程，太底层）, QEMU runtime（与 qemu.sh runtime 模块撞名）, 把 QEMU PID file 当 instance（记录 ≠ 实体）

**QB variable**:
BitBake 变量（`QB_MACHINE`、`QB_MEM` 等），定义在 OpenBMC machine conf 及其 include 链中。`ob start-qemu` 优先读取 deploy 产物 `*.qemuboot.conf` 中的最终 QEMU 启动值；缺少该产物时才回退 `bitbake -e` 解析最终生效值。变量缺失时是否采用兼容 fallback 由 `QEMU launch profile` 表达，fallback 不应被称为 QB variable。
_Avoid_: QEMU 配置变量, QEMU 参数, 把 legacy fallback 当 QB variable

**QEMU launch profile**:
`ob start-qemu` 启动某个 machine 前解析出的启动画像，汇总 SoC 类型、证据来源/置信度、QEMU system binary name（`QEMU_LAUNCH_SYSTEM_NAME`，来自 `QB_SYSTEM_NAME` 或 profile 推导）、QEMU machine 名、内存参数以及 AST2700 额外启动文件需求。已安装 QEMU binary 若支持由 machine 前缀派生的 `<prefix>-bmc` 平台机型（如 `sample-bmc`），会覆盖 qemuboot/BitBake 中的通用机型（如 `ast2700a1-evb`）。它表达“这台 machine 应该如何被 QEMU 启动”，不同于记录 QEMU binary 来源和 sha256 的 `QEMU manifest`。
_Avoid_: QEMU metadata, QEMU 配置, QEMU 启动配置

**confirmation banner**:
`ob` 在面向用户的高代价或破坏性动作前输出的视觉块：横线边框 + 3 行重复 `warn`，内容形如 `You are about to <verb>: >>> <object> <<<`。它只负责视觉强调，不含确认逻辑——Y/N 循环、3 秒倒计时、批量处理由各确认点自行管理。**是否触发取决于路径风险，不单看操作本身**：从列表交互选择、或撞上需杀掉的运行实例这类有误伤风险的路径才确认；显式表达意图的快路径（如 `ob init <machine>`、正常起 QEMU）一律跳过、无需 `--force`。够分量才配 banner（init 拉 20-30GB、build 1-4 小时、kill 运行中的 QEMU），太轻的（如清理一条 stale SSH host key）不套。
_Avoid_: 三次重复提示, heavy gate, 确认门, 破坏性够分量（旧口径，已收紧为路径风险）

**function semantic layer**:
`ob` 内部对函数角色的调用层级词汇：L1（`cmd_*` 命令编排，exit seam）、L2（前置检查点，如 `require_path`）、L3（底层通用工具，如 `log`/`select_from_list`/`read_kv_field`）。L1/L2/L3 是**函数角色**轴，与**文件级 exit 契约**轴正交。文件级 exit 契约由 `exit_contract` 的 Y 规则按 basename 划分三态：`leaf-pure module`（Y 规则覆盖；除配置例外外函数不直接 exit；"pure" 仅指 no-direct-exit，**不指函数纯度**——其函数仍可有文件/进程/网络副作用）、`direct-exit module`（函数体内直接 exit，受 `exit-code 契约` 约束，非 L1 收口）、`exit seam`（L1 `cmd_*` 顶层编排，对用户命令收口）。leaf-pure basename 归属与各 module 的 exit 例外集以 `exit_contract` 配置（`LEAF_EXIT_EXCEPTIONS_BY_BASENAME`）为唯一权威——不在此罗列，避免文字副本漂移。结构边界由 `lib/*.sh` 文件名承载——曾用 § 注释分区锚点，因会漂移已退役。
_Avoid_: 调用层级, 函数分级；勿与 test layer（protocol/unit/orchestration/integration，曾用 L0–L3）混用

**BitBake environment support module**:
`lib/bitbake_env.sh` 中封装的 one-shot BitBake environment 查询 module。它只负责隔离执行无参 `source setup` 的 machine 列表解析，以及 `source setup <machine> <build_dir> && bitbake -e` 的原始输出查询；需要把 setup 副作用留在当前 shell 的进入路径由对偶的 `current-shell build environment` 承接（不在本 module），不解析 `QB_*`，不打印 remedy，不决定 exit-code 契约。调用者负责前置检查、失败诊断、exit/remedy 和领域解释。
_Avoid_: BitBake environment manager, current-shell setup wrapper, 把 QEMU launch profile 决策下沉到 bitbake_env

**current-shell build environment**:
`lib/build_env.sh` 封装的 current-shell 构建环境进入原语：`cd OPENBMC_DIR` + `source setup <machine> <build_dir>`（带 nounset save/restore 保护），让后续 `bitbake` 调用运行在正确 cwd 与 source 注入的 shell 环境下。其副作用（cwd 漂移到 build dir、shell 变量）刻意留在当前 shell——与 `BitBake environment support module` 用子进程 `( )` 隔离副作用的纯查询形成对偶（泄漏 vs 隔离）。只管「进入」不管离开；不接管首次初始化的 conf 校验/bootstrap/mkdir（属 `init_pipeline`），不解析 `QB_*`，不打印 remedy，不决定 exit-code 契约；函数绝不 exit（允许受控副作用，不要求 pure）。
_Avoid_: BitBake environment session, build environment activation, 当作 bitbake_env 的扩展（二者机制对立）

**test layer**:
`ob` 测试体系的分层，自下而上为 protocol（退出码协议，非交互）、unit（纯函数单测，零依赖毫秒级）、orchestration（编排函数，PATH 注入 stub）、integration（真实集成，init→build→QEMU 全流程）。曾用 L0–L3 编号，为脱离与「function semantic layer」的 L1/L2/L3 撞名而改语义名。
_Avoid_: 测试等级, 覆盖等级, L0–L3（旧称已弃）, function semantic layer

**ob 优先 (ob-first)**:
做 OpenBMC 环境生命周期动作（init/build/status/start-qemu/stop-qemu 及未来子命令）前，先查 `ob --help` 是否提供对应能力；提供则走 `ob <cmd>`，仅当 exit 1 真实失败且 ob 确无此能力时才手动兜底。`ob --help` 是唯一权威能力清单。
_Avoid_: tool-first, ob first, 能力清单（并入本条）

**exit-code 契约**:
`ob` 所有 `cmd_*` 统一退出码：0=成功/良性无操作，1=真实失败（坏了或用法错），2=用户主动取消（非失败），3=前置缺失（修复方式是用 ob 补前置）。agent 仅在 exit 1 触发回退。
_Avoid_: 返回码约定, exit status

**remedy line**:
`ob` 在 exit 3（前置缺失）报错里给调用方（主要是智能 agent）的**下一步描述**。输出固定两段式：先**诊断行**说明哪条前置没满足（如 `Machine 'X' has not been initialized.`），再**恰好一行 remedy line**——描述满足该前置所需的下一步。常见形态是 `Run 'ob init X' first.`，但**不锁死为 ob 命令**：消费者是智能 agent，可自行决定用 ob 解决、通知用户或自行探索。要求非空且向前看（是「下一步」，而非「上一步可能失败了」这类纯回溯诊断）。**恰好一条命令、不串接第二条**：多步前置由单命令循环逐轮接力（补一步 → 重试 → 下一轮 remedy 指向下一步），而非一行列链（列链需调用方判断哪条才是当前步，违背无需推断原则）。
_Avoid_: 提示语, hint, 错误提示, 锁死为 ob 命令

**ob-managed variable**:
`ob init` 注入到 `externalsrc-<machine>.inc` 的变量（当前 DL_DIR、SSTATE_DIR、PREMIRRORS）。注入规则：仅当 local.conf 中**无该变量的赋值行**时才注入——判定用 `read_local_conf_var` 的 exit code（有赋值行=用户接管，含空值；无赋值行=ob 写默认），**不**用值是否非空（`-n`）。即用户一旦显式赋值即视为接管、ob 不覆盖；无赋值行时 ob 写入默认（workspace 共享缓存、清华 mirror 等）。在 assignment-state 判定上，空值（有赋值行但值为空）仍表示用户接管、**不**表示 unset——理由见 [ADR-0005](docs/adr/0005-local-conf-var-detection-exit-code.md)。

assignment-state 判定（"用户是否接管某 ob-managed variable"）的底层事实由 `read_local_conf_var` 的 exit code 承载（generic local.conf reader，不专属 ob-managed variable 集合）：`generate_build_config`（注入决策）与 `resolve_effective_dl_dir` / `resolve_effective_sstate_dir`（缓存目录 effective 路径解析 + mkdir）共用这一 exit code 判定，**不**用值判定（`-z` / `-n`）。本次只做 existing seam alignment，**未**把 `ob-managed variable` 落成完整领域 module。**effective-path 失败语义只适用路径类变量 DL_DIR / SSTATE_DIR**：有赋值行但值为空、或路径不可用（unwritable）→ `resolve_effective_*` 静默 `return 1`，调用点 `exit 3` + remedy（因 bitbake 会用空/无效路径破坏 fetch / sstate，且 ob 会把 bare mirror 填到 bitbake 不会用的位置）。`PREMIRRORS = ""` 仍是 ADR-0004 / ADR-0005 明确支持的合法禁用语义，不进路径 resolver、不触发 exit 3。
_Avoid_: ob 配置变量, 自动配置变量, 把空值当"未配置", `-n` 判定（已统一为 exit code）, `-z` 判定（resolve_effective_* 已对齐 exit code）

**srctree**:
`ob dev modify` 后 recipe 源码检出到的本地目录（devtool workspace），由 `devtool status` 权威解析、不缓存、不拼接；它是 `ob dev modify` stdout 的契约对象（恰好一行绝对路径），externalsrc 将 recipe 指向它。
_Avoid_: source tree（口语化）, 源码目录, source directory（与 working tree 混）

**modified recipe**:
devtool workspace 里当前处于 modify 状态的 recipe，由 `devtool status` 实时列举（不缓存、不拼接）。是 `ob dev status` 的查询对象、`ob dev reset` 的候选范围；与 `recipe metadata cache`（`ob dev list` 的全量可 modify 索引，缓存）正交。
_Avoid_: tracked recipe, 已 modify 的 recipe

**recipe metadata cache**:
`ob dev list` 的权威数据源，物理为 `workspace/configs/<machine>.recipes.jsonl`（每行 recipe/layer/summary）+ sidecar `<machine>.recipes.meta.json`（bblayers hash/mtime + openbmc commit）。sidecar 决定 cache 三态 `fresh`/`missing`/`stale`（分别对应直接读、懒生成、`exit 3` + refresh remedy），scope 为当前 bblayers 全量 target recipe。
_Avoid_: recipe 索引, recipe list, 把 stale 当 missing（exit 码与 remedy 不同）

**ob dev porcelain stdout**:
`ob dev` 作为 agent-facing 命令组的 stdout 契约：stdout 只输出机器解析数据（`list` JSONL / `modify` 恰好一行 srctree / `build` 空（exit code 承载成败，bitbake log 走 stderr） / `refresh` 空 / `reset` 单行 JSON / `status` 每行 `{"recipe","srctree"}` JSONL / `finish` 单行 JSON），logo/info/warn/诊断一律走 stderr；`ob dev` dispatch 跳过 `show_logo`，`cmd_dev` 不调写 stdout 的 `log`/`info`/`warn`。`reset`/`finish` 各输出恰好一行 JSON（`python3 json.dumps` 生成，字段值经 argv 传入不插值源码串、tempfile 原子发布：编码/校验失败则 stdout 空 + exit 1）。`reset` 七字段 `{"recipe","srctree","srctreebase","disposition","destination_parent","destination","cleaned_bbappend"}`：`disposition` 五态 "moved"/"retained"/"removed"/"absent"/"noop"（默认 source-preserving reset：srctreebase 归档到 `attic/sources` / 外部保留 / 空目录被 rmdir / 本来就不存在 / 未 modified）；`destination_parent` 仅 `moved` 为 `<workspace>/attic/sources`，其余四态为 `null`（精确 attic 子目录不可用）；`destination` 恒 `null`；`cleaned_bbappend` 为被 devtool 移除的 workspace `.bbappend` 路径（`noop` 时 `null`），与 `disposition`（srctreebase 源码目录去向）正交。`finish` = reset 七字段 + 五个 `patch landing` 字段（见 `patch landing`）；finish 是 reset 的对称收尾（reset 丢弃 / finish 落回），物理层同 source-preserving、共享 `ob dev cleanup/收尾语义` fail-safe。**agent 不得自动清理 attic，也不得按 mtime/name 猜最新 attic 子目录**——需删除时用户明确检查后手动处理。
_Avoid_: machine-readable output, JSON output（泛称；list JSONL 与 reset 单行 JSON 是两种具体形态）

**ob dev cleanup/收尾语义**:
ob dev 收尾动作（`reset` 丢弃 / `finish` 落回 / integration harness 回滚）共享的故障安全不变量：cleanup target 由 `devtool status` 权威 recheck（不缓存/不推断），cleanup-needed 标志在产生副作用（`modify`）之前设置，`status`/`list` 失败是真失败不降级。**收尾命令**（reset/finish）对未 modified recipe 返回 `exit 0` + `disposition=noop`（良性，主契约 0/1/2/3 内）；**integration harness** 在环境不具备/无安全候选时用 `exit 77` SKIP（测试协议码，非主契约）。详见 [ADR-0008](docs/adr/0008-ob-dev-cleanup-fail-safe.md)。收尾命令（reset/finish）当前为 workspace 单 writer 假设、无 workspace 级互斥；锁协议触发条件是 `--remove-work`，见 [ADR-0009](docs/adr/0009-ob-dev-workspace-single-writer.md)。
_Avoid_: cleanup 逻辑（实现口语）, rollback（仅收尾的一种场景）

**ob dev build**:
`ob dev` 的「单 recipe 增量编译」子命令，补 `modify → finish` 之间的内循环编译洞。`ob dev --machine <m> build <recipe>` 在 build env 里跑 `devtool build <recipe>`（do_build 默认，v1 不带 task 参数），编译该 recipe 的 `srctree` 改动（externalsrc 已激活）。与 `ob build <machine>`（整个 `obmc-phosphor-image`，1-4 小时）正交：ob dev build 是 fast inner-loop 单 recipe 编译（秒-分钟），不编整个 image——二者 depth 不同，不可混为"ob build 的 per-recipe 版"。**前置：recipe 必须当前在 devtool workspace（modified）**——未 modified → exit 3 + remedy `Run 'ob dev --machine <m> modify <recipe>' first.`（前置缺失，非失败；机制是 `devtool_build_run` 像 `devtool_modify_run` 那样先跑 status，recipe 不在 modified 列表则回传 not-modified 标志，exit-code 契约映射归 `cmd_dev`）。**stdout 契约：空**（结果由 exit code 承载，0=编通 / 1=失败；bitbake 编译 log 走 stderr，agent 定位 `[ERROR]` 行；镜像 `refresh` 形态，非 `reset`/`finish` 的 JSON 形态）。build 是单次 devtool 调用，**无 reset/finish 的多步 phase**（metadata/status/...），失败模型只有 stage（cd/setup/postcondition/command）+ rc。build 不改 devtool workspace 状态（只往 bitbake WORKDIR/TMPDIR 产出），与 `ob dev cleanup/收尾语义`（ADR-0008）无关——非收尾命令，无需 cleanup fault-inject。
_Avoid_: ob dev compile（与 bitbake task 混）, 把 build 当 ob build 的 per-recipe 版, 允许 build 非 modified recipe（那等于纯 bitbake，非 ob dev 内循环）

**ob dev finish**:
`ob dev` 的「落回」收尾子命令，`modify` 的两个终态出口之一（`reset` 丢弃 / `finish` 落回），对应 devtool `finish` 语义。把 `srctree` 改动以 `patch landing` 形式落回 recipe 原属 layer（生成 `.patch` 加进 `SRC_URI`，或更新 `SRCREV` 指向 srctree HEAD），解除 externalsrc 让 recipe 退出 workspace。物理层 source-preserving（`srctreebase` 归档 `attic/sources`，与 reset 同构 disposition 五态），porcelain 输出 reset 七字段 + 五个 landing 字段。复用 reset 的 resolve_workspace/locate_bbappend/classify 链 + `ob dev cleanup/收尾语义` fail-safe。不暴露 devtool 的 layer/mode 旋钮（极简默认：layer 取 recipe 原属、mode 让 devtool 判定），不引入 workspace 锁（单 writer 假设，见 [ADR-0009](docs/adr/0009-ob-dev-workspace-single-writer.md)）。落回≠丢弃：落回把改动持久化进 layer，丢弃只保留源码副本到 attic。
_Avoid_: commit（与 git 混）, update-recipe（devtool 中途存档，保留 workspace；finish 是终态落回）, land（口语化）

**patch landing (落回)**:
`ob dev finish` 把 `srctree` 改动写回 recipe 的落回结果，由 finish porcelain 的五个字段表达：`landing_mode`（"patch" 生成 `.patch` 加进 `SRC_URI` / "srcrev" 更新 `SRCREV` / `null` 当 noop；**ob 按落地文件落点观测分类**——`.patch` 变→patch、`.bb`/`.bbappend` 变→srcrev，非 devtool `_guess_recipe_update_mode` 上游分支判定的 mode 真值，混合脏 srctree 可能偏离 devtool 实际 mode）；`landing_layer`（落回的目标 layer，ob 取 recipe 原属 layer）；`patches`（patch mode 新增 `.patch` 路径列表，srcrev/noop 为 `[]`）；`recipe_files`（被 finish 修改的 layer recipe 文件 `.bb`/`.bbappend` 路径列表，noop 为 `[]`）；`srcrev`（srcrev mode 下 ob 抽取的新 `SRCREV` 值；抽取不到（纯 `.bbappend` 编辑 / `SRCREV` 用变量或续行写法 / recipe 无 `SRCREV` 行）时为 `null`，patch/noop 亦为 `null`）。**`landing_mode` 与 `srcrev` 解耦**：`landing_mode=srcrev` 只表示 recipe 文件被改（落点判），不保证 `srcrev` 非 `null`——即 `landing_mode:"srcrev"` + `srcrev:null` 合法，表示「recipe 改了但 SRCREV 未抓到」，非「未写 SRCREV」。落回结果不由 parse `devtool finish` 自由文本 stdout 获得，而由 ob 在 devtool finish 前后快照 `landing_layer` 文件树 diff 探测（在 ob dev 单 writer 假设下可靠）。与 `srctreebase`/`disposition`（源码副本物理去向）正交。
_Avoid_: 把 landing 字段当 parse devtool 输出可得（devtool finish stdout 自由文本不可靠 parse）
