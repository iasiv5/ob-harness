# ob 脚本重构设计文档 审查意见

> 状态：待作者修订 · 创建于 2026-06-16
> 审查对象：[2026-06-16-ob-refactor-design.md](2026-06-16-ob-refactor-design.md)
> 审查方法：对 [ob](../../ob) 全文 4252 行逐函数核对（建立完整函数地图 + 全量 `exit`/`return` 码分布统计 + 死代码调用方核查 + 键值读取散点核查），每条 finding 附代码证据落点。
> 行号引用沿用原设计文档的 `ob#Lxxx` 标记风格，便于对照。

## 总体结论

方向认可：方案 A（单文件 + 分区 + 公共函数集中）符合最小改动原则；阶段 0 先行 smoke test 正确；行号引用和死代码断言**绝大多数准确**（见 G1）。

但**退出码协议这一章存在机制性误解 + 覆盖缺口 + 内部矛盾，不建议直接进 writing-plans**，需返工。核心问题：

1. 设计假设的"L1 用 `exit`、`main` 透传"传播模型在 bash 里不成立；
2. 退出码不一致的清单漏了 2 处等价 bug；
3. 新协议与脚本**已有的**头部协议声明冲突却未察觉；
4. 另有 4 个公共函数的抽取接口设计偏乐观，收益高估。

---

## 🔴 高（会让实施走偏 / 漏修等价 bug / 内部矛盾）

### R1 退出码传播模型有误：`main` 的 `return $?` 在 CLI 模式基本是 no-op

设计文档第 2 章退出码方案的前提是"L1 `cmd_*` 用 `exit` 决定退出码，`main` 透传，`cmd_menu` 解码"。但事实是：CLI 模式下 `main`（[ob:4215](ob#L4215)）直接调用 `cmd_*`（非子 shell），`cmd_*` 内部的 `exit N` 会**直接终止整个进程**，`main` 的 `cmd_x; return $?`（[ob:4228-4235](ob#L4228-L4235)）在 `cmd_*` 走 `exit` 的失败/取消路径**根本不可达**。`main` 的 `return` 只在 `cmd_*` 正常返回（成功，码 0）时才执行。

- 推论：第 3 点"`main` 的 `return 0` → `return $?` 实现统一透传"对 CLI 退出码**几乎没有可观察效果**——成功都是 0，失败/取消由 `cmd_*` 的 `exit` 直接决定，`main` 改不改 `return` 结果一样。
- 真正让 `main` 成为传播点，需要 `cmd_*` 内部全部由 `exit` 改 `return`——而这正是被推给"未决事项 1"的大改动。
- 证据：`main`（[ob:4215-4249](ob#L4215-L4249)）；cmd_build 失败走 `exit "$bb_exit"`（[ob:2426](ob#L2426)）。
- 建议：要么承认 CLI 退出码完全由 `cmd_*` 的 `exit` 决定、把 `main` 这步降级为"语义清理（无行为变化）"；要么把"`cmd_*` 改 `return`"纳入本次范围，否则"`main` 统一透传"是空头支票。

### R2 "可见行为变化"第 3 条是事实错误

设计文档称"`ob build` bitbake 失败：CLI 退出码 `0 → 1`（原本被 `return 0` 屏蔽）"。但 cmd_build 失败走 `exit "$bb_exit"`（[ob:2426](ob#L2426)），CLI 下直接以 `bb_exit` 终止脚本，`main` 的 `return 0`（[ob:4235](ob#L4235)）不可达——**现状退出码就是 `bb_exit`（非零），从未被 `return 0` 屏蔽**。真实变化是 `bb_exit → 1`，且仅当 `bb_exit ≠ 1` 时才可见。

- 影响：直接误导"未决事项 4：外部脚本对 `ob build` 退出码的依赖"的风险评估——现状失败已是非零，前提判断站不住。

### R3 漏修两处与已识别 bug 完全等价的"取消被误报为成功"

退出码逐点对齐清单只列了 `2849 / 3646 / 3709` 三处 `exit 0`，但全脚本"用户取消语义的 `exit 0`"实际有 **5 处**，漏了：

- `ensure_qemu_binary_community`（[ob:831](ob#L831)）：`No URL provided — aborting`，`exit 0`
- `select_openbmc_repo_url`（[ob:2485](ob#L2485)）：`Init cancelled by user`，选 0 → `exit 0`

其中 [ob:2485](ob#L2485) 与已识别的 [ob:2849](ob#L2849) 是**同一个 bug 的两处**：`cmd_menu` case 1（[ob:4144-4151](ob#L4144-L4151)）用 `init_rc == 0` 判定 `Init succeeded`，用户在 source 选择（2485）或 machine 确认（2849）取消都 `exit 0` → 都会被误报为 `Init succeeded`。**只改 2849 不改 2485，menu init 在 source 选 0 时仍误报成功。**

- 证据：全量 `exit` 分布统计，业务 `exit 0` 共 5 处。
- 建议：把 831、2485 一并纳入"`exit 0 → exit 2`"清单；这是实质 bug，不是风格统一。

### R4 `cmd_menu` case 1 补 `== 3` 是死分支，第 4 点 ↔ 未决事项 2 ↔ 第 5 点自相矛盾

`cmd_init`（[ob:4005](ob#L4005)）调用链所有前置失败都用 `exit 1`（`prerequisites_check` [ob:2864](ob#L2864)/[ob:2872](ob#L2872)、`require_openbmc_repo`、`init_bitbake_env` [ob:2987](ob#L2987) 等），**永不 `exit 3`**；而未决事项 2 又明确"默认不改 init 子函数 `exit 1`"。于是第 4 点给 `cmd_menu` case 1（[ob:4144-4151](ob#L4144-L4151)）补的 `== 3` 分支**永远不会触发**（死分支），却与第 5 点"删 case 3 死分支"逻辑完全相反——一边删死分支一边加死分支。

- 证据：`exit` 分布显示 cmd_init 链路 0 处 `exit 3`。
- 建议：二选一——(a) 把 init 前置 `exit 1 → exit 3`（连带解决未决事项 2），case 1 的 `== 3` 才有意义；(b) 不补 `== 3`，把 case 1/2 直接改成 case 4/5 的 `!=0 && !=2 && !=3 → error` 统一风格。

### R5 未发现并对齐脚本**已有的**退出码协议声明，新协议与之冲突且未规定同步更新

`ob` 头部 line 13-17（[ob:13-17](ob#L13-L17)）**已经声明**了一份协议：`0 success / 1 general error / 2 user abort / 130 interrupted`。设计文档的新 4 类协议是 `0/1/2/3`——**新增了 3（前提不满足），漏掉了头部已声明的 130（Ctrl-C）**。更关键：代码现状已偏离头部注释（头部无 3，代码却有 11 处 `exit 3`），设计文档既没指出这个现存漂移，也没把"更新 [ob:13-17](ob#L13-L17)"列入动作。

- 后果：实施后会变成头部注释（`0/1/2/130`）vs 代码（`0/1/2/3`）vs 设计协议（`0/1/2/3`）三方不齐，比现状更乱。
- 建议：协议表补回 130；把"同步更新头部注释 line 13-17"列为阶段 2 必做项；在文档里点明"头部注释与代码已漂移"这一现状。

---

## 🟡 中（成功标准无法达成 / 抽取接口偏乐观）

### Y1 "4 类语义协议"在 L2 层完全未落地，成功标准"无不一致误报"不成立

`exit 3` 当前**只在 L1**（cmd_build / start-qemu / stop-qemu）出现；30+ 处 L2 函数（`ensure_qemu_*`、`resolve_qb_vars` [ob:1212](ob#L1212)/[ob:1221](ob#L1221)/[ob:1226](ob#L1226)、`prerequisites_check`、`clone_*`、`find_ast2700_bootloaders` [ob:1072](ob#L1072) 等）的"前提不满足"**全是 `exit 1`**。后果：同一命令 `ob start-qemu` 前提失败返回码不确定——自检走 `exit 3`（[ob:3579](ob#L3579)/[ob:3603](ob#L3603)/[ob:3611](ob#L3611)），但 `ensure_qemu_binary` 链走 `exit 1`（[ob:937](ob#L937)/[ob:954](ob#L954)/[ob:1002](ob#L1002)…）。L2 迁移被推给未决事项 1，却同时把"退出码协议统一为 4 类语义…无不一致误报"列为成功标准——L2 不迁移时该标准无法达成。

- 建议：要么把 L2"前提不满足 `exit 1 → 3`"纳入本次（量大但语义集中、可脚本化）；要么把成功标准下修为"L1 层协议统一"，并显式列出 L2 仍返回 1 的已知缺口。

### Y2 `download_qemu_binary_core`（抽取点 4）收益高估、失败语义未定义

`download_and_replace_community_qemu`（[ob:601-711](ob#L601-L711)）：flock 锁 + 下载到临时 `tmp_dir` + 备份旧 binary + `mv` 回滚 + 每步失败 `flock -u; return 1`。`ensure_qemu_binary_community` 下载段（[ob:848-906](ob#L848-L906)）：无锁 + 解压到 `QEMU_BIN_DIR` + 失败 `exit 1` + 末尾查 Jenkins build number。差异（失败 `return` vs `exit`、解压目标、是否备份/回滚、build number 来源）**渗透到"核心序列"每一步**，不是外围。"两调用方各自处理 replace-vs-fresh 差异"低估了渗透度，且未定义公共函数的失败语义。

- 建议：明确公共函数只做"下载 → 类型检测 → 解压 → 定位 binary → sha256"且**只 `return` 不 `exit`**，把 flock/备份/回滚/manifest/exit 全留调用方；据此重估收益（很可能远低于 60 行），或降级此点。这是 5 个高收益里风险最高的一个。

### Y3 `prompt_for_absolute_path`（抽取点 5）`kind=file/dir` 不足以覆盖两调用点

binary 输入（[ob:949-987](ob#L949-L987)）：接受文件或目录，目录则拼 `$arch` 文件名回退。pc-bios 输入（[ob:999-1038](ob#L999-L1038)）：只接受目录，要求 `ast27x0_bootrom.bin` 存在，含 `pc-bios/` 子目录回退。两者的存在性/内容校验差异**远超 file/dir 二分**。

- 建议：公共函数只做"读取 + 非空 + 非选项(`-*`) + 绝对路径格式"校验（约 15 行），存在性/内容校验留调用方；重复消除量从文档说的 ~40 行下修到 ~15-20 行。

### Y4 `read_kv_field`（抽取点 3）归并清单含三类语义冲突，"~12 处"偏乐观

- (a) **来源不一致**：`resolve_qb_vars` [ob:1246](ob#L1246)/[ob:1268](ob#L1268)/[ob:1284](ob#L1284) 是从 `$bitbake_output` **字符串** grep，不是文件，`<file>` 接口不适用，应剔除。
- (b) **选取策略冲突**：`read_qemu_url_config`（[ob:517](ob#L517)）用 `tail -1`，`read_lock_field`（[ob:1856](ob#L1856)）用 `head -1`。
- (c) **分隔保留冲突**：url/qb 用 `cut -f2-`，pid/manifest（[ob:2180-2185](ob#L2180-L2185)）用 `-f2`（值含 `=` 时行为不同）。
- 建议：`read_kv_field` 明确"从文件 / 首条匹配 / 保留首个 `=` 后全部"的统一语义，逐点验证行为等价；剔除 resolve_qb_vars；下修归并数量。

### Y5 `select_from_list` / `confirm_action`（抽取点 1、2）返回与控制流接口未定义

- `select_from_list`："返回选中索引，0=取消"未说清是返回码还是全局变量。返回码传索引会与 `0=取消`/`set -e`/`||` 冲突；stdout 返回又与"打印标题+列表"冲突。三个调用点还**行为不等价**：cmd_build（[ob:2300-2308](ob#L2300-L2308)）对范围外数字给专门提示（`Number out of range`）+ 嵌套 if，start（[ob:3552](ob#L3552)）/stop（[ob:3899](ob#L3899)）用单行 `&&` + 统一提示；cmd_stop_qemu read 失败（[ob:3904](ob#L3904)）无 error 文案。
- `confirm_action`：cmd_stop_qemu 拒绝走 `continue 2`（[ob:3960](ob#L3960)，跳过当前 target 继续 for 循环），**不是 exit/return**。`confirm_action` 的 `return 0/2` 无法直接表达，调用点须改成 `if ! confirm_action; then continue; fi`。文档把它当"提示参数化"，低估了控制流差异。
- 建议：先定义接口契约（建议**选中值走全局变量、状态走返回码 0=ok/2=cancel**），并在清单里逐点标注需统一的差异（提示文案、范围外处理、`continue 2`）。

---

## 🟢 低 / 优点 / plan 阶段需补

- **G1（优点）** 行号与死代码断言基本准确：抽查 `print_confirm_banner`（[ob:65](ob#L65)）、`main`（[ob:4215-4249](ob#L4215-L4249)）、`OB_NO_MAIN`（[ob:4251](ob#L4251)）、`2426/2849/3646/3709/3873/3920`、`check_ports_available`↔`get_port_occupants`（[ob:1486](ob#L1486)↔[ob:1520](ob#L1520)）均吻合；`write_pid_file`（[ob:1620](ob#L1620)）确认**零调用方**（死代码成立，且其 `pid=$!` 与现在 setsid 前台启动（[ob:3517](ob#L3517)）不兼容，更印证过时）。方案 A 选择与阶段 0 先行 smoke test 都认可。
- **G2（plan 需补）** smoke test 可行性前提未交代：`ob` 顶部 `set -euo pipefail`（[ob:24](ob#L24)）。`OB_NO_MAIN=1 source ob` 会把 errexit/nounset/pipefail 带入 harness——harness 主体需 `set +e` 隔离，否则首个非零断言即退出；`set -u` 下裸调被测函数要求其依赖的全局变量（`DRY_RUN/VERBOSE/SKIP_DEPS/QEMU_*`）已在顶层初始化。"source 后可单独调函数"过于乐观，需在 plan 验证。
- **G3** "遗漏修复 cmd_status 改调 read_pid_file"低估适配成本：`read_pid_file`（[ob:1644](ob#L1644)）读固定 `$QEMU_PID_FILE` 并写全局 `PIDFILE_*`，而 cmd_status Section 4（[ob:2180-2185](ob#L2180-L2185)）在 for 循环遍历 `$_pf` 用局部变量。改调需循环内先设 `QEMU_PID_FILE="$_pf"` 并接受全局变量污染，非无缝。
- **G4** `require_path` 抽取会顺带把若干 L2 `exit 1 → exit 3`（如 `find_ast2700_bootloaders` deploy_dir，[ob:1072](ob#L1072)），属可见行为变化，但"可见行为变化"清单只列了 cmd_build，未覆盖这些 L2 点（与 Y1 同源）。
- **G5** "重复行数下降 ≥ 250 行"目标偏乐观：结合 Y2/Y3/Y4，建议改用"消除的重复模式数 + 各点实测行数"衡量，不锁死总行数。

---

## 给作者的最小修订清单（按优先级）

1. 重写退出码方案的传播模型：澄清"CLI 退出码由 `cmd_*` 的 `exit` 决定，`main` 的 `return` 仅成功路径可达"，据此重判 `main return 0→$?` 的实际效果（R1）。
2. 修正"可见行为变化"第 3 条（R2），并同步修正未决事项 4 的前提。
3. `exit 0 → 2` 清单补 [ob:831](ob#L831)、[ob:2485](ob#L2485)（R3）。
4. 解决 case 1 `== 3` 死分支矛盾：选 R4 的 (a) 或 (b)。
5. 协议表补回 `130`，新增"更新头部注释 [ob:13-17](ob#L13-L17)"动作，点明现状漂移（R5）。
6. 对 Y1 二选一：扩范围迁移 L2，或下修成功标准。
7. 对 Y2–Y5 四个抽取点补"接口契约 + 行为等价验证"小节，重估收益。
