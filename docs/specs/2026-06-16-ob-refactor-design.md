# ob 脚本重构与编码规范 设计文档

> 状态：待审批（v2，吸收评审 `2026-06-16-ob-refactor-design-review.md`）· 创建于 2026-06-16 · 来源：`/brainstorming`
> 对象：仓库根目录脚本 `ob`（4252 行，约 88 个 bash 函数）
> v2 变更：重写退出码传播模型（修正机制性误解）、精确化可见行为变化、补 L2 退出码迁移、重定义 4 个抽取点接口、下修收益估计。

## 背景与目标

`ob` 是 OpenBMC 开发环境的一键入口（`./ob init [<machine>]` / `build` / `status` / `start-qemu` / `stop-qemu`，无参进交互菜单）。经过多轮增量，脚本已长到 4252 行，暴露三类可维护性问题：

1. **重复模板未抽公共函数**：数字菜单选择、Y/y 确认循环、键值读取、QEMU 下载解压校验、绝对路径输入校验等模式各重复 2–4 处。最近一次只抽了 `print_confirm_banner`（[ob:65](ob#L65)），紧随其后的确认 `while read` 循环仍是手写。
2. **`main` 与分层不清晰**：`main`（[ob:4215-4249](ob#L4215-L4249)）本身已较简洁，但缺少明确的"main / cmd_ 编排 / 领域函数 / 通用工具"分层约定，函数物理顺序也较散。
3. **退出码协议不一致**：同一语义混用不同退出码（"用户取消"5 处用 `exit 0`、5 处用 `exit 2`），`exit "$bb_exit"`（[ob:2426](ob#L2426)）把 bitbake 任意码泄漏，L1 前提失败用 `exit 3` 而 L2 前提失败用 `exit 1`。`cmd_menu`（[ob:4106](ob#L4106)）把退出码当协议解码，协议不一致直接导致误报（如 init 取消被误报为"Init succeeded"）。

**目标：** 在守住外部可见行为可解释的前提下，抽公共函数消除重复、确立单文件分层与分区规范、统一退出码协议（含 L2 层迁移），让 `ob` 更易读、更易改、更易回归。

**成功标准：**
- 5 个重复模式抽成公共函数，调用点改调公共函数。收益按"消除的重复模式数 + 各点实测行数"衡量（不锁死总行数；评审指出原"≥250 行"偏乐观，各点经接口收敛后预估收益见抽取清单）。
- `main` 零业务逻辑、`cmd_*` 纯编排、领域逻辑下沉，分层有文档约定。
- 退出码协议统一为 4 类语义，**覆盖 L1 与 L2 两层**；消除已识别的 `exit 0`-as-cancel 误报 bug；`cmd_menu` 解码与协议一致。
- 落地零依赖 smoke test，覆盖 `parse_args` / dispatch / 前置检查 / `--dry-run` / 统一后的退出码；重构后全绿。
- 交互分支（依赖 `read`）走手动验证矩阵。

## 范围

本次明确要做：

1. **补 smoke test（阶段 0，先行）**：零依赖纯 bash，利用 `OB_NO_MAIN` 钩子（[ob:4251](ob#L4251)），重构前建立回归基线。
2. **抽公共函数（阶段 1）**：见"公共函数抽取清单"。
3. **统一退出码协议（阶段 2）**：见"退出码协议统一方案"，含 L1+L2 迁移、`cmd_menu` 解码统一。
4. **确立分层与分区规范（阶段 3）**：见"分层与分区规范"，含分区注释锚点；物理重排可选。
5. **顺势清理**：删死代码（`write_pid_file`，[ob:1620](ob#L1620)，零调用方）、补遗漏调用。

## 非范围

- **不改物理结构**：不拆分多文件、不引入 `lib/*.sh`（方案 A 已定）。
- **不改外部 CLI 接口**：参数名、子命令名、`--help` 文案、正常路径 stdout 格式不变。（退出码的统一属"借机统一内部语义"，见"可见行为变化"，不在本条"不变"之列。）
- **不重构领域算法**：QEMU 命令构造、bitbake 环境初始化、依赖图生成、lockfile 生成等只做行为等价搬运。
- **不做 L2 分层迁移（exit→return）**：本次 L2 仍用 `exit`，只统一码值（`exit 1→3`）。"L2 改 `return`、退出码交 L1 决定"的分层改造范围更大，列为后续独立项。
- **不补全量自动化测试**：交互 `read` 路径不自动化，归入手动矩阵。
- **不引入测试框架依赖**：不用 bats/shunit2。
- **不抽低收益模板**：`print_numbered_list`、`ensure_*` 幂等短路开头收益低、易过度抽象，作为注释约定。

## 方案比较

### 方案 A：单文件 + 分区规范（已选定）

- **核心思路**：`ob` 维持单文件；文件内注释分区 + 固定顺序规范；公共函数集中顶部；main/cmd_/领域/工具四层分层；退出码协议统一（含 L2）。smoke test 用零依赖纯 bash。
- **优点**：物理结构不变，回归面最小，符合 SOUL "最小改动/跟随现有模式"；分区锚点解决"找不到东西"；全局变量作用域不变。
- **缺点**：单文件认知负荷仍在（靠分区 + 编辑器符号大纲缓解）；公共函数无法跨脚本复用。

### 方案 B：物理拆分多文件 source（未选）

- **核心思路**：`ob` 拆成入口 + `lib/ob_common.sh` + `lib/ob_qemu.sh` + `lib/ob_init.sh`。
- **缺点**：改物理结构，全局变量作用域/source 顺序要逐一验证，回归面最大；偏离现有单文件模式；零测试基线下风险/收益不划算；属未请求重排，违反 YAGNI。

### 方案 C：混合——只抽无状态公共函数到 lib（未选）

- **缺点**：增加 source 复杂度，收益不抵成本。

## 推荐方案

**方案 A。** 理由：零测试基线下物理拆分（B）回归风险/收益不划算且属未请求重排；A 通过"分区规范 + 公共函数集中 + 四层分层 + cmd_ 编排模板 + 退出码统一（L1+L2）"即可正面回答"`main` 是否简洁、架构是否合理"。B 的长期收益应作为后续增量。

## 分层与分区规范

### 四层职责分层

| 层 | 职责 | 允许 | 禁止 |
|---|---|---|---|
| **L0 入口**（`main`/`parse_args`/`usage`） | 解析、根检测、dispatch | 调用下层、传播返回码 | 业务逻辑、领域判断 |
| **L1 编排**（`cmd_*`） | 单命令步骤编排 | 前置检查→调 L2→打印；用 `exit` 决定退出码 | 可复用领域算法 |
| **L2 领域函数**（`ensure_*`/`resolve_*`/`derive_*`/`clone_*`/`generate_*`） | 一个领域动作 | 实现业务、调 L3 | （本次不强制）`exit→return` 迁移留后续 |
| **L3 通用工具**（`log`/`select_from_list`/`confirm_action`/`read_kv_field` 等） | 无状态、可复用 | 纯输入→输出 | 依赖全局业务状态、`exit` |

> 关键约束：**`main` 零业务逻辑**（只 `parse_args` + `detect_harness_root` + dispatch）。本次在新抽/改动函数上落地"L3 绝不 `exit`"；L2 的 `exit→return` 分层迁移属未范围（见上）。退出码统一通过"码值对齐"实现，不依赖分层迁移。

### 单文件分区顺序（目标）

```
§1 全局变量与常量
§2 通用工具 (L3)         # log/interactive/kv/path 工具 + 本次新抽公共函数
§3 仓库与 machine (L2)   # repo 解析、lock、machine 解析、prerequisites
§4 QEMU (L2)             # 二进制管理、端口、PID、hostkey
§5 构建流程 (L2)         # clone/init_bitbake/dep_graph/lockfile/build_config/report
§6 命令编排 (L1)         # cmd_status/cmd_build/cmd_init/cmd_start_qemu/cmd_stop_qemu/cmd_menu
§7 入口 (L0)             # parse_args/usage/main/启动
```

落地两级：**阶段 3a**（必做）插入 `# === §N ... ===` 分区锚点 + 规范，不动物理顺序；**阶段 3b**（可选，单独 commit）物理重排，纯移动不改逻辑，须在 smoke test 就位后进行。

## 公共函数抽取清单

所有新函数归入 §2（L3），无状态、可独立测、**绝不 `exit`**（只 `return`）。每个函数先定义接口契约，再列替换点与预估收益。

### 1. `select_from_list <title> <label> <array_name>` — 数字菜单选择

- **接口契约**：传入标题、单项 label、数组名（bash nameref）。函数内打印标题 + 编号列表 + `read`。结果经**全局变量** `SELECT_FROM_LIST_CHOICE` 传出选中值（1-based），**状态经返回码**：`return 0`=确认、`return 2`=取消（选 0）。选中值走全局变量而非返回码，避免与 `0=取消`/`set -e`/`||` 冲突。
- **替换点**：`cmd_build`（[ob:2272-2309](ob#L2272-L2309)）、`resolve_machine`（[ob:2785-2828](ob#L2785-L2828)）、`cmd_start_qemu`（[ob:3543-3568](ob#L3543-L3568)）、`cmd_stop_qemu`（[ob:3882-3915](ob#L3882-L3915)）。
- **需统一的差异**：`cmd_build`（[ob:2300-2308](ob#L2300-L2308)）对范围外数字有专门 `Number out of range` 提示 + 嵌套 if，start/stop 用单行 `&&` + 统一提示；`cmd_stop_qemu` 的 `read` 失败（[ob:3904](ob#L3904)）无 error 文案。统一为"范围外/非数字 → 统一提示重输"。
- **预估收益**：~100 行 → 抽出 ~30 行函数 + 4 处各 ~6 行调用，净减 ~50 行（原估计偏乐观）。

### 2. `confirm_action <verb> <object>` — Y/y 确认循环

- **接口契约**：内部先 `print_confirm_banner`，再 `while read` 循环收 y/n。`return 0`=确认、`return 2`=取消。调用方用 `if ! confirm_action ...; then <cancel-logic>; fi`。
- **替换点**：`check_jenkins_update`（[ob:755-780](ob#L755-L780)）、`cmd_build`（[ob:2319-2337](ob#L2319-L2337)）、`resolve_machine`（[ob:2834-2855](ob#L2834-L2855)）、`cmd_start_qemu`（[ob:3694-3715](ob#L3694-L3715)）。
- **需统一的差异**：(1) `cmd_stop_qemu` 拒绝走 `continue 2`（[ob:3972](ob#L3972)，跳出内层 `while` 确认循环、继续 `for target` 下一个）——`confirm_action` 内化了确认 `while` 循环，调用点回到 `for` 体内（[ob:3924](ob#L3924)），单层 `continue` 即等价；调用方形态 `if ! confirm_action ...; then info "Skipped ..."; continue; fi`。(2) 各点提示文案不同（`[y/N]`（[ob:3963](ob#L3963)）vs `[Y/n]`），作为参数传入。(3) `cmd_stop_qemu` 的 `QEMU_FORCE` 短路（[ob:3959](ob#L3959)，强制时跳过确认）与 TTY 前置判断留调用方（L3 不依赖业务状态）。
- **预估收益**：~70 行 → 抽出 ~20 行 + 4 处调用，净减 ~40 行。

### 3. `read_kv_field <file> <key>` — 通用键值读取

- **接口契约**：从**文件**读取 `key=value`，返回**首条匹配**（统一为 `head -1`；`read_qemu_url_config` 现用 `tail -1`，但写入端 `write_qemu_url_config` [ob:539-543](ob#L539-L543) 先 `grep -v` 删同 key 旧行再 append，保证同 key 单条，故 tail/head 等价、无多值场景），保留**首个 `=` 后全部内容**（统一为 `cut -f2-`，避免值含 `=` 时被截断）。`return 0`=找到、`return 1`=未找到。
- **替换/归并**：`read_lock_field`（[ob:1856](ob#L1856)）改为调它；`read_qemu_url_config`（[ob:504](ob#L504)）、manifest 读取（[ob:674](ob#L674)、[ob:725](ob#L725)）。
- **剔除**：`resolve_qb_vars`（[ob:1246](ob#L1246)/[ob:1268](ob#L1268)/[ob:1284](ob#L1284)）是从 `$bitbake_output` **字符串** grep，不是文件，`<file>` 接口不适用，**不纳入**。
- **保留**：`read_pid_file`（[ob:1644](ob#L1644)）多字段批量读且写全局，语义不同，保留；`cmd_status`（[ob:2180-2185](ob#L2180-L2185)）的手写 6 字段读取改用 `read_kv_field` 局部读（见遗漏修复），**不改调 `read_pid_file`**（评审 G3：`read_pid_file` 读固定 `$QEMU_PID_FILE` 并污染全局，与 cmd_status for 循环局部变量不兼容）。
- **预估收益**：归并 ~6 处文件读取散点，净减 ~15 行（剔除字符串 grep后，原 "~12 处" 偏乐观）。

### 4. `download_qemu_binary_core <url> <dest_dir>` — 下载→类型检测→解压→定位→sha256

- **接口契约**：**只做** 下载（`curl -fSL -C -`）→ 文件类型检测（`file -b` 判 gzip/xz）→ 解压（`tar xf`）→ 在解压结果中定位 binary 候选 → 计算 sha256。**只 `return`，绝不 `exit`**。经全局/输出返回：binary 路径 + sha256（建议经全局变量 `DLQB_BIN_PATH`/`DLQB_SHA256`，`return 0`=成功、`return 1`=失败）。**flock/备份/回滚/manifest 写入/`exit` 全留调用方**。
- **替换点**：`download_and_replace_community_qemu`（[ob:616-701](ob#L616-L701)，含 flock+备份+回滚）与 `ensure_qemu_binary_community`（[ob:843-906](ob#L843-L906)，无锁直落）中**真正共享**的核心序列。
- **风险提示**：两调用方差异（flock/备份/回滚、`return` vs `exit`、解压目标、build number 来源）渗透到每一步，本函数只抽**两者完全一致**的下载→解压→sha256 骨架。是 5 个抽取点里风险最高的，实施时须逐行对照两调用方，确认抽出的骨架在两处行为等价。
- **预估收益**：~60 行 → 抽出 ~25 行可共享骨架，净减 ~25–30 行（原估计高估，差异部分留调用方）。

### 5. `prompt_for_absolute_path <label>` — 绝对路径输入 + 基础校验

- **接口契约**：**只做** 循环 `read` → `trim_whitespace` → 非空检查 → 非选项（拒绝 `-*`）→ 绝对路径格式（必须 `/*`）。经全局变量 `PROMPT_PATH_RESULT` 返回路径，`return 0`=确认、`return 2`=取消。**存在性/内容校验留调用方**（binary 接受文件或目录并拼 `$arch` 回退，pc-bios 要求 `ast27x0_bootrom.bin` + `pc-bios/` 子目录，差异远超 file/dir 二分，不适合塞进公共函数）。
- **替换点**：`ensure_qemu_binary_custom` 内 binary 输入（[ob:949-987](ob#L949-L987)）、pc-bios 输入（[ob:999-1038](ob#L999-L1038)）。
- **预估收益**：~40 行 → 抽出 ~15 行 + 2 处各补存在性校验，净减 ~15–20 行（原估计偏乐观）。

### 中收益（顺带）

6. **`require_path <path> <hint> <exit_code>`** — "not found → error → hint → exit N" 模板。替换 `cmd_build`（[ob:2209-2219](ob#L2209-L2219)）、`cmd_start_qemu`（[ob:3576-3612](ob#L3576-L3612)）、`find_ast2700_bootloaders`（[ob:1069-1073](ob#L1069-L1073)）等 ~6 处。**注意**：用于 L2 点（如 `find_ast2700_bootloaders`）时会顺带把该点 `exit 1→3`，属可见行为变化（见下）。

7. **`check_ports_available` 改调 `get_port_occupants`**（[ob:1486-1489](ob#L1486-L1489) → [ob:1520-1524](ob#L1520-L1524)），纯复用。

### 遗漏修复与死代码清理

- **`cmd_status` 改用 `read_kv_field`**：[ob:2180-2185](ob#L2180-L2185) 手写 6 字段 `grep|cut` → 循环内对每个 `$_pf` 调 `read_kv_field`（局部读，不污染全局）。
- **删 `write_pid_file`**：[ob:1620-1642](ob#L1620-L1642) 零调用方（其 `pid=$!` 与现在 `setsid` 前台启动 [ob:3517](ob#L3517) 不兼容，印证过时）。实施前再 `grep` 确认零调用方后删除；`_qemu_post_launch`（[ob:3776-3789](ob#L3776-L3789)）为唯一 PID 写入点。

## 退出码协议统一方案

### 传播模型（修正后）

> 评审 R1 指出原稿机制性误解，已修正。

**CLI 模式**（`main` → `cmd_*` 直接调用，非子 shell）：`cmd_*` 内部 `exit N` **直接终止整个进程**，`main` 的 `cmd_x; return $?`（[ob:4228-4248](ob#L4228-L4248)）在失败/取消路径**不可达**，仅在 `cmd_*` 正常返回（成功，码 0）时执行。因此：
- **CLI 退出码完全由 `cmd_*` 的 `exit` 码值决定**（成功=0，失败/取消=该 exit 码）。
- `main` 的 `return 0` vs `return $?` 对 CLI 退出码**无可观察效果**（成功路径 `$?` 必为 0）。把 `main` 的 `return 0` 改 `return $?` 只是**语义清理（无行为变化）**，不作为退出码统一的手段。

**菜单模式**（`cmd_menu` → `(cmd_x) || rc=$?` 子 shell，[ob:4143](ob#L4143) 等）：`cmd_x` 的 `exit N` 被子 shell 捕获成 `rc`，`cmd_menu` 解码。**这是唯一需要协议解码的地方**。

结论：退出码统一通过**对齐 `cmd_*` 及其调用链（含 L2）的 `exit` 码值**实现，不依赖 `main` 的 `return` 改动。

### 目标协议（码值语义）

| 退出码 | 语义 |
|---|---|
| **0** | 成功完成（正常结束、`--dry-run` 完成）|
| **2** | 用户主动取消（选 0、输入 N/Q、拒绝确认、URL 留空中止）|
| **3** | 前提条件不满足（未 init / 未 build / 缺镜像 / 缺依赖工具 / 缺配置 / 非 TTY 且缺必要参数）|
| **1** | 其他错误（I/O 失败、子命令失败、校验失败、未知错误）|
| 130 | Ctrl-C（bash 默认 SIGINT 处理，脚本不主动 `exit 130`，仅在协议表注明）|

> 退出码协议为本设计新立，脚本原无协议声明（头部是全局变量，全文无 exit-code 文档）；130 仅作协议完整性注记。

### 对齐清单

**A. `exit 0`-as-cancel → `exit 2`（5 处，含评审 R3 补的 2 处）**

| 行 | 位置 | 场景 |
|---|---|---|
| [ob:831](ob#L831) | `ensure_qemu_binary_community` | URL 留空 `No URL provided — aborting`（交互主动留空→取消 2；区别于同函数非 TTY 缺配置 [ob:819-823](ob#L819-L823)→前提 3）|
| [ob:2485](ob#L2485) | `select_openbmc_repo_url` | source 选 Q `cancelled by user` |
| [ob:2849](ob#L2849) | `resolve_machine` | machine 确认输 N |
| [ob:3646](ob#L3646) | `cmd_start_qemu` | 拒绝杀重启 |
| [ob:3709](ob#L3709) | `cmd_start_qemu` | 拒绝确认 |

> [ob:2485](ob#L2485) 与 [ob:2849](ob#L2849) 同属 cmd_init 链；cmd_menu case 1 用 `init_rc == 0` 判定成功（[ob:4144](ob#L4144)），两处 `exit 0` 都被误报为"Init succeeded"。只改一处不解决问题，必须两处同改。这是实质 bug，非风格统一。

**B. `exit "$bb_exit"` → `exit 1`（[ob:2426](ob#L2426)，cmd_build）**

bitbake 非零退出码不透传（避免撞上保留的 2/3）。退出前用 `error` 打印原始 `bb_exit` 保留可诊断性。

**C. L2 前提失败 `exit 1 → exit 3`（Y1=B，本次范围）**

现状 `exit 3` 全部在 L1（cmd_build/start/stop 的 10 处），L2 前提失败一律 `exit 1`（30+ 处）。本次迁移 L2 中"前提不满足"语义的 `exit 1 → exit 3`，使同一命令无论经 L1 自检还是 L2 `ensure_*` 链，前提失败都返回 3。

**判定准则（实施时逐个 exit 1 归类，不可无脑 sed）：**
- **→改 `exit 3`（前提不满足）**：缺少依赖工具（git/npm/wget 不存在）、缺少必要文件/目录（deploy_dir、镜像、binary 未配置 URL）、缺少配置（conf 找不到键）、非 TTY 且缺必要参数。
  - 典型：`prerequisites_check`（[ob:2864](ob#L2864)/[ob:2872](ob#L2872)）、`find_ast2700_bootloaders`（[ob:1072](ob#L1072)）、`ensure_qemu_binary_community` 的**非 TTY 缺配置**分支（[ob:819-823](ob#L819-L823)，`if [[ ! -t 0 ]]` + URL 未配置）。
  - ⚠️ 分治边界：`ensure_qemu_binary_community` 同函数另有**交互主动留空**分支（[ob:829-831](ob#L829-L831)，TTY 时用户留空），属"用户取消"，归对齐清单 A 的 `exit 2`，**不可**与上面的非 TTY 缺配置分支（→`exit 3`）混为一谈——这是"被动缺配置 vs 主动放弃"的边界。
- **→保持 `exit 1`（硬错误）**：I/O 失败（clone/下载/写入失败）、子命令失败（bitbake/外部命令返回非零）、校验失败（sha256 不匹配）、内部断言失败。
  - 典型：`clone_openbmc` 网络失败、`init_bitbake_env` 的 bitbake 调用失败、sha256 校验失败。

**D. `cmd_menu` 解码统一**

所有 case 统一为 `rc != 0 && rc != 2 && rc != 3 → error`，`==0/==2/==3` 静默（2 取消、3 前提，均不报崩溃）。迁移 L2 后 cmd_init 链会 `exit 3`，case 1 的 `==3` 静默成立（评审 R4 死分支矛盾随 L2 迁移自动解决）。

- case 3（status，[ob:4170-4176](ob#L4170-L4176)）：`cmd_status` 无退出码接口（总成功），删无法触发的失败分支，保留单行成功注释。

**E. `cmd_stop_qemu` return/exit 统一为 `exit`**（[ob:3873](ob#L3873)/[ob:3920](ob#L3920) 的 `return 0` → `exit 0`；"无实例"是正常"无事可做"，`exit 0` 合理）。

**F. `main` 的 `return 0` → `return $?`**（[ob:4230](ob#L4230)/[ob:4235](ob#L4235)）：语义清理，**无行为变化**（见传播模型）。

**G. `validate_pid` 内部码注释隔离**（[ob:1685](ob#L1685)/[ob:1692](ob#L1692)）：`return 1`/`return 2` 是诊断码（exited/recycled），加注释"与退出码协议无关"。

### 可见行为变化（精确版）

> 评审 R1/R2 指出原稿 3 条基于"`main` 屏蔽退出码"的错误前提，已重写。

**CLI 模式（退出码 = cmd_* 的 exit 码）：**
- `exit 0`-as-cancel 5 处 → `exit 2`：`ob init`（source 选 Q / machine 输 N）、`ob start-qemu`（拒绝杀重启 / 拒绝确认 / URL 留空）取消时，CLI 退出码 `0 → 2`。
- L2 前提失败 `exit 1 → 3`：凡经 L2 前提失败路径的命令，CLI `1 → 3`（需逐函数确认归类，见准则）。
- bitbake 失败 `bb_exit → 1`（[ob:2426](ob#L2426)）：当 `bb_exit ≠ 1` 时 CLI 退出码变化（如 `2 → 1`）；`bb_exit = 1` 时无变化。
- `main return 0→$?`：**无行为变化**。
- 原 `exit 3`（L1 现有 10 处）：不变。

**菜单模式（cmd_menu 解码）：**
- init 前提失败（迁移后 `exit 3`）：菜单原报"Initialization failed."，改后 `==3` 静默（修正误报——前提不满足不应算 init 崩溃）。
- 取消路径 `exit 0→2`：菜单原 `==0` 静默（取消当成功），改后 `==2` 静默（正确识别取消）；显示行为均为"静默 + 回菜单"，但语义修正。
- 所有 case 统一 `!=0&&!=2&&!=3→error` 后，报错文案更一致。

> 若有外部脚本依赖 `ob build` 的退出码：注意现状 `ob build` 失败/取消 CLI 退出码**本就是非零**（bitbake=`bb_exit`、取消=`2`、前提=`3`，由 cmd_build 的 exit 直接决定，从未被屏蔽）。本次变化主要在 `ob init`/`ob start-qemu` 的取消路径（0→2）与 L2 前提路径（1→3）。

## 控制流

```
main
 ├─ parse_args "$@"          # L0
 ├─ detect_harness_root      # L2
 ├─ COMMAND 空 → cmd_menu    # L1：子 shell (cmd_x)||rc=$? 捕获 exit，按协议解码
 └─ CLI：case "$COMMAND"     # 直接调 cmd_*，exit 即进程退出码；main return 仅语义清理
        status/build/start-qemu/stop-qemu/init → cmd_x
```

`cmd_*`（L1）内部：前置检查（`require_path` 等，前提失败 `exit 3`）→ 调 L2 领域函数（L2 前提失败 `exit 3`、硬错误 `exit 1`）→ 打印报告；用户取消 `exit 2`。

## 测试策略

### 阶段 0：smoke test（重构前先行，零依赖纯 bash）

技术基础：`OB_NO_MAIN=1 source ob` 不触发 `main`（[ob:4251](ob#L4251)）。**注意**（评审 G2）：`ob` 顶部 `set -euo pipefail`（[ob:4](ob#L4)），`source` 会把 errexit/nounset/pipefail 带入测试 harness——harness 主体须 `set +e` 隔离（否则首个非零断言即退出）；`set -u` 下裸调被测函数要求其依赖的全局变量已在 ob 顶层初始化（`DRY_RUN/VERBOSE/SKIP_DEPS/QEMU_*` 等已初始化，[ob:7-46](ob#L7-L46)）。`parse_args`/`cmd_*` 用 `exit`，测试用子 shell `( ... )` 捕获 `$?`。"source 后可单独调函数"需在阶段 0 实际验证可行。

覆盖项（非交互路径）：
- **`parse_args`**：`--help`/`-h`→exit 0；未知选项→exit 1；缺值→exit 1；`-d`/`-v`/`--skip-deps` 正确置位。
- **dispatch**：无参→`cmd_menu`（非 TTY 触发保护 [ob:4108](ob#L4108) exit 1）；各 COMMAND 路由。
- **前置检查**：空 workspace 跑 `ob build`→exit 3、`ob start-qemu`→exit 3。
- **`--dry-run`**：`cmd_start_qemu --dry-run`（[ob:3729](ob#L3729)）→exit 0，不启 QEMU。
- **退出码（阶段 2 后）**：取消路径 exit 2、前提路径 exit 3、硬错误 exit 1，CLI `$?` 正确。

落盘：`tests/smoke_ob.sh`（新增 `tests/`，更新 [rules/03_WORKSPACE.md](rules/03_WORKSPACE.md) 路由表）。运行 `bash tests/smoke_ob.sh`，退出 0=全绿。

### 阶段 1–3：抽函数与统一协议期间验证

- **行为等价对照**：每抽一个公共函数，调用点同输入跑"抽前/抽后"，比 stdout 与退出码。
- **回归基线**：每阶段结束跑 smoke test，全绿才进下一阶段。
- **L2 迁移验证**（阶段 2）：每个 `exit 1→3` 改动后，确认该路径属"前提不满足"而非"硬错误"（按准则）；smoke test 覆盖前提路径 exit 3。
- **working tree 提交**：每阶段/每函数一个 commit，便于回滚。

### 手动验证矩阵（交互分支，不自动化）

- `./ob` 菜单 1/2/3/4/5/C/Q 各分支；选 0/非数字/超范围。
- `./ob init` 交互选 machine、确认下载、增量重跑识别、source 选 Q 取消（验证不再误报成功）。
- `./ob build` 选 machine、确认、取消（验证 CLI exit 2）。
- `./ob start-qemu` 选 machine、端口冲突、拒绝杀重启/确认（验证取消 exit 2）、URL 留空（验证 exit 2）。
- `./ob stop-qemu` 选实例、确认。
- 抽出的 `select_from_list`/`confirm_action`/`prompt_for_absolute_path` 各调用点交互手感一致。

## 实施阶段（粗粒度，详细 step 交 writing-plans）

| 阶段 | 内容 | 依赖 | 风险 |
|---|---|---|---|
| 0 | 补 `tests/smoke_ob.sh`，验证 `OB_NO_MAIN` source 可行性 | — | 低 |
| 1 | 抽 5 个公共函数 + 中收益 2 项 + 遗漏修复 + 死代码清理 | 0 | 中（改动面广，行为等价）|
| 2 | 统一退出码：A(exit0→2)、B(bb_exit→1)、**C(L2 exit1→3 迁移)**、D(cmd_menu 解码统一)、E/F/G | 0、1 | **中高**（L2 迁移量大、含可见行为变化）|
| 3a | 分层/分区规范（注释锚点 + 规范文档）| 1、2 | 低 |
| 3b（可选）| 物理重排（纯移动，单独 commit）| 0–3a | 中 |

阶段顺序固定（0 最先）；阶段 2 的 C（L2 迁移）建议放该阶段最后，先用脚本辅助识别候选点再逐个判定归类。

### 实施约束

- **行号以符号名重锚**：本文档的 `ob#Lxxx` 仅为定位参考，会随实现演进漂移。writing-plans 与实施开工前，一律用 `grep -n` 按函数名/文案重新定位所有引用点，不按设计文档的静态行号下刀；判定准则 C 的 `exit 1→3` 归类尤其依赖实时核对上下文。

## 未决事项

1. **L2 分层迁移（`exit→return`）**：本次只统一码值（`exit 1→3`），L2 仍用 `exit`。"L2 改 `return`、退出码交 L1 决定"的分层改造范围更大，列后续独立项。
2. **L2 `exit 1→3` 的逐点归类**：判定准则已给（前提→3、硬错误→1），但 30+ 处需实施时逐个看上下文确认；归类有判断空间，writing-plans 阶段逐函数列清单。
3. **阶段 3b 物理重排是否执行**：取决于阶段 2 后 diff 量与 review 成本。
4. **外部脚本对退出码的依赖**：本次变化主要在 `ob init`/`ob start-qemu` 取消路径（0→2）与 L2 前提路径（1→3），需确认团队无脚本依赖这些路径返回 0/1。

> `read_qemu_url_config` 的 head/tail 已闭环（不列入未决）：写入端 `write_qemu_url_config` 去重保证同 key 单条，tail/head 等价，统一 `head -1`。
