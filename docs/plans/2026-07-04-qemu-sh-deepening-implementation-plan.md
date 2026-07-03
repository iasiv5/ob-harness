# lib/qemu.sh 一次搞定 deepening 实施计划

> 修订 R1（2026-07-04）：吸收评审 F1-F6 + 2 条轻量提示。主要变更——F1 重画 Task 1.3 seam（冲突检测+kill+决策整块留 cmd_*、置于 prepare 之前，保"kill 先于端口检查"不变量，新增 `--force` 重启回归测试）；F2 结构锁重定向下沉到 1.1/1.2/1.3 同任务（不再全押 4.1）；F3 去重收窄为 start↔stop（cmd_status 不同源，单列）；F4 迁移清单改 grep 自验证枚举、用全限定名；F5/F6 措辞订正。
>
> 修订 R2（2026-07-04）：评审放行 F1(a)（行为等价核验通过，仅 AST2700 mid-run 工件删除极窄边界差异，接受）；补 F7（`qemu_binary_supports_machine` 归属夹缝——唯一调用者在 `qemu_launch_profile_apply_binary_machine_override` body 内，名带 `qemu_binary_` 前缀会被 grep 漏，必须显式纳入迁移，否则孤儿化且无 gate 报错）；修正 grep 正则 `[a-z_]+`→`[a-z0-9_]+`（覆盖 `ast2700` 数字名）；Task 1.3 加 F1 行为差异显式注；Task 3.4 detect/stop 对偶标可选 polish；结构锁重定向按断言 label 锚定（行号会顺移）。
>
> 修订 R3（2026-07-04）：评审收敛放行，无新增阻塞。评审自我更正（R2 凭眼读正则判错 🟢1，实跑 `comm` 确认 `[a-z_]+` 真漏 ast2700 两函数、我的升级判断与修法正确）。唯一动作：Task 1.1 防孤儿 grep 标注为**时点性断言**（仅 1.1 完成点为 0；1.3 后跨 module 调用合法重现，勿作常驻不变量）。计划定稿。

## 目标

把 `lib/qemu.sh`（1337 行、6 个 concern 交错）沿已可见的内部 seam 物理拆成 3 个深 module，并把 `cmd_start_qemu` god-function 收成薄 L1 wrapper + runtime 深函数（prepare/execute）。一次性完成"文件拆分 + god-function 拆解 + binary 决策可测化 + on-path 去重"，过程中先建测试网再动结构。

设计来源：本仓 grill-with-docs 会话定稿的 8 条决策 + ADR-0007（已修订，反转"不拆文件"deferral）。

## 架构快照

- **拓扑**：`lib/qemu.sh` → 拆出 `lib/qemu_launch_profile.sh`（启动画像决策，ADR-0007 已背书）+ `lib/qemu_binary.sh`（binary provisioning），`lib/qemu.sh` 收为 runtime（端口/PID/hostkey/build_qemu_cmd + 新 prepare/execute）。`ob` 的 `for f in lib/*.sh` glob source、`ob_check.sh` 的 `OB_SOURCES+=(lib/*.sh)`、`exit_contract.py`、`coverage_radar.py`（第 40 行 `glob`）、`extract_funcs.py`（按路径级 lib 判定）均按 basename/glob 工作 → 新增文件零 import、零工具配置改动。
- **launch seam（Shape 2）**：runtime 出 `qemu_prepare_launch "$MACHINE"`（resolve_profile→provision→端口协商→build_qemu_cmd）+ `qemu_execute_launch`（setsid+post_launch）；`cmd_start_qemu` 夹在中间做 banner+confirm+倒计时。
  - **冲突处理不变量（F1）**：`cmd_start_qemu` 的"已有实例冲突检测+kill 决策"**整块留在 cmd_*、且在调 prepare 之前**——因为 prepare 内含 `check_ports_available`（端口被旧实例占即 `exit 3`），若 detection(kill) 与 action 分到 seam 两侧，旧实例未杀就查端口 → `--force` 重启退 `exit 3`。prepare **不做**冲突检测（冲突已由 cmd_* 先解决）。
- **exit 归属**：三文件全 direct-exit（继承 qemu.sh 现分类），均**不加入** `exit_contract` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME`（该白名单含 bitbake_env.sh/build_env.sh/util.sh/machine_state.sh 四个 basename，本次不动它）。纯 helper（含新 `qemu_binary_*_decision`）"约定不 exit"，靠 unit test 锁（先例 `download_qemu_binary_core` 注释"L3 — never exits"）。
- **测试网**：extract→pin→deepen 顺序；PATH-injection 优先（`tests/lib/stub.sh` 的 `mkfake_bin`/`stub_out`/`stub_script`），避开同 shell 函数 override 造成的 radar 虚高。
- **scope 边界**：on-path 去重捆入（start↔stop 显示 / `qemu_stop_instance` / PID 写归属）；off-path（machine 选择 4×、BUILD_DIR 5×、**cmd_status 的多实例单行呈现**）**不碰**，留下一 pass。

## 输入工件

- 设计：grill-with-docs 会话（本仓当前会话上下文）8 条结晶决策。
- ADR：`docs/adr/0007-qemu-launch-profile-start-qemu-decision-seam.md`（已修订，line 17 deferral 反转）。
- 术语：`CONTEXT.md`（`QEMU launch profile`/`QB variable`/`function semantic layer`/`exit-code 契约`/`remedy line`）。

## 文件结构与职责

- Create: `lib/qemu_launch_profile.sh` — launch 画像决策 module（`resolve_qemu_launch_profile` + 全部 `qemu_launch_profile_*` helper + `resolve_machine_conf_include`/`machine_conf_chain_contains` walker）。
- Create: `lib/qemu_binary.sh` — binary provisioning module（`ensure_qemu_binary`/`_community`/`_custom`/`_firmware` + `download_qemu_binary_core`/`download_and_replace_community_qemu` + `query_jenkins_build_number`/`check_jenkins_update` + manifest/url-config IO + 新 `qemu_binary_update_decision`/`qemu_binary_resolve_url`）。
- Create: `tests/lib/qemu_stubs.sh` — 共享 PATH-stub 构造器（curl/setsid/bitbake/pgrep/sshpass/file/sha256sum/tar 的 fake）。
- Create: `tests/orchestration/qemu_prepare_launch.sh` — prepare 端到端 characterization。
- Create: `tests/orchestration/qemu_execute_launch.sh` — execute smoke。
- Create: `tests/orchestration/qemu_binary_download.sh` — 下载链 stub characterization。
- Create: `tests/orchestration/start_qemu_force_restart.sh` — **F1 冲突→端口顺序回归锁**（`--force` 同端口重启不 `exit 3`）。
- Create: `tests/unit/qemu_binary_decision.sh` — 两纯决策 unit。
- Create: `tests/orchestration/qemu_stop_instance.sh` — stop_instance orchestration。
- Modify: `lib/qemu.sh` — 收为 runtime：ports/PID/hostkey/`build_qemu_cmd`/`derive_qemu_paths` + 新 `qemu_prepare_launch`/`qemu_execute_launch`/`qemu_instance_describe`/`qemu_stop_instance`。
- Modify: `lib/commands.sh` — `cmd_start_qemu` 收薄（前置+冲突块保留于 prepare 之前+banner+confirm+调 prepare/execute+exit 收口）；`cmd_stop_qemu` 改调 `qemu_stop_instance`；`_qemu_post_launch` 折进 `qemu_execute_launch`。**`cmd_status` 的 QEMU 实例单行呈现不动**（不同源，见 F3）。
- Modify: `tests/protocol/qemu_launch_profile_structure.sh` — 文件路径常量随迁移**逐任务**重定向（1.1 改 77-78、1.2 改 72-76、1.3 改 67+加 Shape-2 锁）。
- Modify: `tools/coverage_matrix.md` — 残差清单更新。
- Modify: `.github/workflows/ob-tests.yml` — coverage `--fail-if-uncovered` 基线值更新（Phase 4 实测后）。
- Modify: `rules/03_WORKSPACE.md` — `lib/` 路由行同步（Phase 4）。

> 边界原则（执行者放置边缘函数时遵循）：launch 决策 → `qemu_launch_profile.sh`；binary/firmware 供给 → `qemu_binary.sh`（含 `ensure_qemu_firmware`，消费 `QEMU_LAUNCH_REQUIRES_PCBIOS`）；端口/PID/hostkey/命令装配/launch 编排 → `qemu.sh` runtime。`derive_qemu_paths` 留 runtime（cmd_* 冲突块与 prepare 共用，幂等）。

## 任务清单

### Task 0.1: 建 qemu 测试共享 stub 构造器

- 目标：给 Phase 2/3 测试提供可复用 PATH-injection fake，避免重复构造 curl/setsid 等。
- Files: Create `tests/lib/qemu_stubs.sh`。
- 验证范围：`source` 后能生成 fake curl 预设归档、fake setsid 写 sentinel、fake pgrep 返回 PID。

- [ ] Step 1: 写当前状态检查
- Run: `bash -c 'source tests/lib/stub.sh; source tests/lib/qemu_stubs.sh 2>/dev/null && declare -F make_qemu_curl_fake >/dev/null && echo HAS || echo MISSING'`
- Expected: `MISSING`。
- [ ] Step 2: 运行并确认缺失
- Run: 同上。
- Expected: `MISSING`。
- [ ] Step 3: 写最小实现
- Change: 在 `tests/lib/qemu_stubs.sh` 基于 `stub.sh` 的 `mkfake_bin`/`stub_out`/`stub_script` 封装：`make_qemu_curl_fake <dir>`（按 URL 分支吐假 qemu 归档字节 + Jenkins `{"number":N}` JSON）、`make_setsid_sentinel <dir>`（setsid 把 `"$@"` 写 sentinel 文件不真启动）、`make_pgrep_fake <dir> <pid>`、`make_bitbake_env_fake <dir>`（吐 `QB_*=` 供 profile 解析）。文件以 `# shared PATH-stub builders for qemu tests` 开头，纯函数定义、无顶层副作用。
- [ ] Step 4: 运行并确认通过
- Run: `bash -c 'source tests/lib/stub.sh; source tests/lib/qemu_stubs.sh; d=$(mktemp -d); make_qemu_curl_fake "$d"; make_setsid_sentinel "$d"; [[ -x "$d/curl" && -x "$d/setsid" ]] && echo OK'`
- Expected: `OK`。
- [ ] Step 5: checkpoint commit
- Run: `git add tests/lib/qemu_stubs.sh && git commit -m "test(qemu): 共享 PATH-stub 构造器 (curl/setsid/pgrep/bitbake)"`
- Expected: commit 成功。

### Task 1.1: 迁出 launch profile module + 同址改结构锁 77-78

- 目标：把 launch 画像决策簇从 `lib/qemu.sh` 迁到 `lib/qemu_launch_profile.sh`（纯文件移动），并**当场**把结构锁中提取本簇函数的两条断言重定向到新文件。
- Files: Create `lib/qemu_launch_profile.sh`；Modify `lib/qemu.sh`；Modify `tests/protocol/qemu_launch_profile_structure.sh`（line 77-78）。
- 验证范围：`tools/ob_check.sh` 全绿；`tests/orchestration/qemu_launch_profile.sh` 通过。

- 迁移范围（**grep 自验证枚举，不手抄名**）：`lib/qemu.sh` 中所有 `qemu_launch_profile_*` + `reset_qemu_launch_profile` + `resolve_qemu_launch_profile` + **`qemu_binary_supports_machine`**（**F7**：名带 `qemu_binary_` 前缀但实为 launch-profile helper——唯一调用者在 `qemu_launch_profile_apply_binary_machine_override` body 内 [qemu.sh:212](lib/qemu.sh#L212)，必须同迁，否则调用者迁走后它孤儿化在 runtime 形成 profile→runtime 反向调用，且无 gate 报错）。外加两个非前缀 walker `resolve_machine_conf_include`（952）、`machine_conf_chain_contains`（974）。执行前先跑（**正则用 `[a-z0-9_]+` 覆盖 `ast2700` 数字名**）：
  - Run: `grep -nE '^(qemu_launch_profile_[a-z0-9_]+|qemu_binary_supports_machine|reset_qemu_launch_profile|resolve_qemu_launch_profile)\(\)' lib/qemu.sh`
  - Expected（实测 16 条 launch-profile 函数）：`reset_qemu_launch_profile`(97)、`qemu_launch_profile_apply_system_name`(113)、`qemu_launch_profile_extract_bitbake_var`(135)、`qemu_launch_profile_record_soc_evidence`(153)、`qemu_launch_profile_apply_machine_name`(171)、`qemu_binary_supports_machine`(194，**显式**)、`qemu_launch_profile_apply_binary_machine_override`(201)、`qemu_launch_profile_uses_external_ast2700_loaders`(221)、`qemu_launch_profile_system_name_for_soc`(233)、`qemu_launch_profile_apply_machine_conf`(242)、`qemu_launch_profile_find_machine_conf`(253)、`qemu_launch_profile_deploy_evidence`(257)、`qemu_launch_profile_resolve_ast2700_bootloaders`(285)、`qemu_launch_profile_find_qemuboot_conf`(312)、`qemu_launch_profile_extract_qemuboot_var`(332)、`resolve_qemu_launch_profile`(353)，连同 952/974 两条 = **共 18 个函数**。
- [ ] Step 1: 写当前状态检查
- Run: `grep -c 'resolve_qemu_launch_profile' lib/qemu.sh; [[ -f lib/qemu_launch_profile.sh ]] && echo EXISTS || echo MISSING`
- Expected: 第一项 ≥1，第二项 `MISSING`。
- [ ] Step 2: 运行并确认当前落点
- Run: 同上。
- [ ] Step 3: 写最小实现
- Change: (a) 建 `lib/qemu_launch_profile.sh`，把 grep 清单 + 952/974 两条原样迁入（保持函数体 + 文件头 module 职责注释）；(b) 从 `lib/qemu.sh` 删除这些定义；(c) 改 `tests/protocol/qemu_launch_profile_structure.sh`：文件头加 `QEMU_LAUNCH_PROFILE_SH="$ROOT/lib/qemu_launch_profile.sh"`；把 **line 77**（`qemu_launch_profile_find_machine_conf`）与 **line 78**（`resolve_machine_conf_include`）的 `$QEMU_SH` 改为 `$QEMU_LAUNCH_PROFILE_SH`。**其余断言本 task 不动**：line 67（cmd_start_qemu，Task 1.3）、line 70-71（build_qemu_cmd/derive_qemu_paths，留 qemu.sh）、line 72-76（ensure_qemu_*/check_jenkins_update/ensure_qemu_firmware，Task 1.2）。注：`resolve_qemu_launch_profile` 经 `source "$OB"` 行为测试覆盖（line 87-133），**不从 $QEMU_SH 提取 body**，无该项需改。**行号为辅助锚点**——后续 Task 1.3 加 Shape-2 断言会顺移，定位一律按断言 label（每条 `assert_function_*` 第一参数，如 `machine conf lookup stops after first hit`），不以行号为唯一契约。
- [ ] Step 4: 运行并确认通过
- Run: `OB_CHECK_SKIP_TESTS=0 tools/ob_check.sh`
- Expected: `ALL GREEN`（含 `extract_funcs lib 三段全清`、`exit-contract ok`、`run_all ALL GREEN`——结构锁 77-78 已重定向故不红）。
- Run: `bash tests/orchestration/qemu_launch_profile.sh; echo rc=$?`
- Expected: rc=0（迁移后行为不变）。
- Run: `grep -cE 'qemu_binary_supports_machine|qemu_launch_profile_apply_binary_machine_override' lib/qemu.sh`
- Expected: `0`（F7 防孤儿：helper 与其唯一调用者都已迁走，qemu.sh 不残留）。**时点性断言（R3）**：仅 Task 1.1 完成点为 0；Task 1.3 后 `qemu_prepare_launch`（qemu.sh）会跨 module 调 `qemu_launch_profile_apply_binary_machine_override`，qemu.sh 合法重现该字符串、届时 grep=1 属正常，勿当作常驻不变量。
- [ ] Step 5: checkpoint commit
- Run: `git add lib/qemu_launch_profile.sh lib/qemu.sh tests/protocol/qemu_launch_profile_structure.sh && git commit -m "refactor(qemu): 迁出 lib/qemu_launch_profile.sh + 结构锁 77-78 重定向 (ADR-0007)"`
- Expected: commit 成功。

### Task 1.2: 迁出 binary provisioning module + 同址改结构锁 72-76

- 目标：把 binary/firmware provisioning + manifest/url-config IO 迁到 `lib/qemu_binary.sh`，并当场把结构锁中提取本簇函数的断言重定向。
- Files: Create `lib/qemu_binary.sh`；Modify `lib/qemu.sh`；Modify `tests/protocol/qemu_launch_profile_structure.sh`（line 72-76）。
- 验证范围：`tools/ob_check.sh` 全绿；`tests/unit/qemu_manifest.sh` 通过。

- 迁移范围（grep 自验证）：`derive_qemu_url_config_path`(16)、`read_qemu_url_config`(20)、`write_qemu_url_config`(31)、`write_qemu_binary_manifest`(59)、`write_qemu_pcbios_manifest`(83)、`query_jenkins_build_number`(454)、`download_qemu_binary_core`(469)、`download_and_replace_community_qemu`(514)、`check_jenkins_update`(592)、`ensure_qemu_binary_community`(648)、`ensure_qemu_binary`(741)、`ensure_qemu_binary_custom`(751)、`ensure_qemu_firmware`(936)。`derive_qemu_paths`(6) **留** runtime。
- [ ] Step 1: 写当前状态检查
- Run: `grep -c 'ensure_qemu_binary_community' lib/qemu.sh; [[ -f lib/qemu_binary.sh ]] && echo EXISTS || echo MISSING`
- Expected: 第一项 ≥1，第二项 `MISSING`。
- [ ] Step 2: 运行并确认当前落点
- Run: 同上。
- [ ] Step 3: 写最小实现
- Change: (a) 建 `lib/qemu_binary.sh`，原样迁入上述函数 + 文件头 module 职责注释；(b) 从 `lib/qemu.sh` 删除；(c) 改结构锁：文件头加 `QEMU_BINARY_SH="$ROOT/lib/qemu_binary.sh"`；把 **line 72**（`check_jenkins_update`）、**73**（`ensure_qemu_binary_community`）、**74**（`ensure_qemu_binary_custom`）、**75**（`ensure_qemu_firmware no soc gating`）、**76**（`ensure_qemu_firmware uses pcbios flag`）的 `$QEMU_SH` 改为 `$QEMU_BINARY_SH`。line 70-71（build_qemu_cmd/derive_qemu_paths）仍指 `$QEMU_SH`（留 runtime）。
- [ ] Step 4: 运行并确认通过
- Run: `tools/ob_check.sh`
- Expected: `ALL GREEN`（含 qemu_manifest.sh 通过、结构锁 72-76 已重定向）。
- [ ] Step 5: checkpoint commit
- Run: `git add lib/qemu_binary.sh lib/qemu.sh tests/protocol/qemu_launch_profile_structure.sh && git commit -m "refactor(qemu): 迁出 lib/qemu_binary.sh + 结构锁 72-76 重定向"`
- Expected: commit 成功。

### Task 1.3: 切出 qemu_prepare_launch + 保留冲突块于 prepare 之前（F1）+ 同址改结构锁 67

- 目标：把 `cmd_start_qemu` 中"profile→provision→端口协商→check→build_qemu_cmd"切出 `qemu_prepare_launch "$MACHINE"`。**冲突检测+kill+决策整块留在 cmd_*、置于 prepare 调用之前**（保"kill 先于端口检查"不变量）。当场把结构锁 line 67 重定向并加 Shape-2 断言。
- Files: Modify `lib/qemu.sh`（新增 `qemu_prepare_launch`）；Modify `lib/commands.sh`（`cmd_start_qemu`）；Modify `tests/protocol/qemu_launch_profile_structure.sh`（line 67 + Shape-2 锁）。
- 验证范围：`tools/ob_check.sh` 全绿；`tests/protocol/start_qemu_remedy.sh` 通过；**新增** `tests/orchestration/start_qemu_force_restart.sh`（Task 2.4）后续锁 F1，本 task 先确保不引入 `exit 3` 回归。

- 全局契约（prepare 拥有写、consumer 只读）：resolve 出的端口从 `cmd_start_qemu` 的 `local`（ssh_port/redfish_port/ipmi_port/http_port/serial_log）升 module 全局 `QEMU_LAUNCH_SSH_PORT`/`QEMU_LAUNCH_REDFISH_PORT`/`QEMU_LAUNCH_IPMI_PORT`/`QEMU_LAUNCH_HTTP_PORT`/`QEMU_LAUNCH_SERIAL_LOG`/`QEMU_LAUNCH_SERIAL_SOCK`（注：`serial_sock` 本就未声明 local、已是隐式全局，一并归入命名空间）。prepare 还产出既有 `QEMU_LAUNCH_SOC_TYPE`/`QEMU_LAUNCH_MACHINE_NAME`、`QEMU_BIN_FILE`、`QEMU_CMD`。
- **切出进 prepare**：`resolve_qemu_launch_profile` → `ensure_qemu_binary`+`apply_binary_machine_override` → `ensure_qemu_firmware` → 端口解析（`resolve_qemu_ports_interactive`）→ `check_ports_available` → `build_qemu_cmd`。
- **留在 cmd_start_qemu**（L1，且在 prepare 之前）：machine 发现/选择、init-done/image 前置 guard、**冲突检测+决策+kill 整块**（`derive_qemu_paths`→`read_pid_file`→`validate_pid`→ `--force`/TTY-confirm/`exit 1`，kill 暂保留现有内联，Task 3.4 抽 `qemu_stop_instance`）。prepare 调用次序在冲突块**之后**。
- **行为差异（R2 F1 动作项，显式决策）**：相对现状，kill 从 provisioning（profile/binary/firmware）**之后**提前到**之前**。对**运行中**实例这三步走快路径/近幂等——`ensure_qemu_binary` 对已存在 binary 永不 exit（`[[ -x ]]`→`check_jenkins_update`→全程 `return 0`）、`ensure_qemu_firmware` 非 pcbios 直接 `return 0`、`resolve_qemu_launch_profile` 仅 AST2700 缺 bootloader 才 exit 3。故仅"AST2700 系 + mid-run bootloader/pc-bios 工件被删 + 此刻 `--force`/确认重启"极窄边界会"先杀后败"；romulus/evb 等常见路径三步全不 exit，(a) 与现状行为等价。接受此边界，不为它引入两段式 prepare。
- [ ] Step 1: 写当前状态检查
- Run: `grep -c 'qemu_prepare_launch' lib/qemu.sh; grep -c 'resolve_qemu_launch_profile' lib/commands.sh`
- Expected: 第一项 0，第二项 ≥1。
- [ ] Step 2: 运行并确认当前状态
- Run: 同上。
- [ ] Step 3: 写最小实现
- Change: (a) `lib/qemu.sh` 加 `qemu_prepare_launch "$MACHINE"`，搬入切出段，局部端口改写 module 全局；**不含**冲突检测；(b) `cmd_start_qemu` 删去该段、改调 prepare；冲突块保留于 prepare 调用之前；banner 读新全局端口；(c) 改结构锁 **line 67**：断言改为 `cmd_start_qemu` 含 `qemu_prepare_launch`（不再是 `resolve_qemu_launch_profile`），并加两条 Shape-2 锁——`cmd_start_qemu` 含 `qemu_execute_launch`、`qemu_prepare_launch`（从 `$QEMU_SH` 提取）含 `resolve_qemu_launch_profile`。
- [ ] Step 4: 运行并确认通过
- Run: `tools/ob_check.sh`
- Expected: `ALL GREEN`（结构锁 67 已重定向 + Shape-2 锁就位）。
- Run: `bash tests/protocol/start_qemu_remedy.sh; echo rc=$?`
- Expected: rc=0（guard 序列不变）。
- [ ] Step 5: checkpoint commit
- Run: `git add lib/qemu.sh lib/commands.sh tests/protocol/qemu_launch_profile_structure.sh && git commit -m "refactor(qemu): 切出 qemu_prepare_launch (冲突块留 cmd_* 保 F1 不变量) + 结构锁 67/Shape-2"`
- Expected: commit 成功。

### Task 1.4: 切出 qemu_execute_launch（折入 _qemu_post_launch）

- 目标：把 `cmd_start_qemu` 的 `setsid` 启动 + `_qemu_post_launch` 合成 runtime 深函数 `qemu_execute_launch`，cmd_* 只调它 + exit 收口。
- Files: Modify `lib/qemu.sh`（新增 `qemu_execute_launch`）；Modify `lib/commands.sh`（`cmd_start_qemu` 改调；删 `_qemu_post_launch`）。
- 验证范围：`tools/ob_check.sh` 全绿；`tests/protocol/stop_qemu_dryrun.sh` 通过。

- [ ] Step 1: 写当前状态检查
- Run: `grep -c 'qemu_execute_launch' lib/qemu.sh; grep -c '_qemu_post_launch' lib/commands.sh`
- Expected: 第一项 0，第二项 ≥1。
- [ ] Step 2: 运行并确认当前状态
- Run: 同上。
- [ ] Step 3: 写最小实现
- Change: (a) `lib/qemu.sh` 加 `qemu_execute_launch`，搬入 `setsid "${QEMU_CMD[@]}"` 启动 + 错误处理 + `_qemu_post_launch` 全部逻辑（读 prepare 产出的 `QEMU_LAUNCH_*` 全局，不再靠 7 个位置参数）；(b) `cmd_start_qemu` 改调 `qemu_execute_launch`，删 `_qemu_post_launch` 调用与定义。
- [ ] Step 4: 运行并确认通过
- Run: `tools/ob_check.sh`
- Expected: `ALL GREEN`。
- [ ] Step 5: checkpoint commit
- Run: `git add lib/qemu.sh lib/commands.sh && git commit -m "refactor(qemu): 切出 qemu_execute_launch (吸收 _qemu_post_launch)"`
- Expected: commit 成功。

### Task 2.1: qemu_prepare_launch characterization

- 目标：用 PATH-injection 锁住 `qemu_prepare_launch` 端到端行为（profile→provision→端口协商→build），顺带覆盖现未测的 port/profile/binary orchestrator。prepare **不含**冲突逻辑（F1 后由 cmd_* 先处理），故本测试无需造冲突。
- Files: Create `tests/orchestration/qemu_prepare_launch.sh`。
- 验证范围：测试通过；`coverage_radar` 显示 `qemu_prepare_launch`/`check_ports_available`/`resolve_qemu_ports_interactive`/`ensure_qemu_binary` 转 covered。

- 注意（F6）：prepare 含联网下载（`ensure_qemu_binary`→curl）与 TTY 交互（`resolve_qemu_ports_interactive` 端口冲突时 `read`），非 pure；故 stub 须含 `make_qemu_curl_fake` 与**非 TTY 环境或预设端口输入**（避免 `read` 阻塞）。
- [ ] Step 1: 写失败测试
- Change: 写 `tests/orchestration/qemu_prepare_launch.sh`：`source tests/lib/{assert,stub,qemu_stubs}.sh` + `OB_NO_MAIN=1 source ob`；构造 fake init-done + firmware image 的 MACHINE；`make_bitbake_env_fake`/`make_qemu_curl_fake`；**确保 stdin 非 TTY 且端口空闲**（`resolve_qemu_ports_interactive` 走默认值分支不 prompt）；调 `qemu_prepare_launch "$MACHINE"`；断言 `QEMU_CMD` 非空且含 `QEMU_LAUNCH_MACHINE_NAME`、端口全局已设。
- Run: `bash tests/orchestration/qemu_prepare_launch.sh; echo rc=$?`
- Expected: rc≠0。
- [ ] Step 2: 运行并确认失败
- Run: 同上。
- [ ] Step 3: 修到通过（暴露的 scoping/契约 bug 回 lib 修，不改测试预期）
- Change: 对齐 stub 分支与全局契约。
- [ ] Step 4: 运行并确认通过
- Run: `bash tests/orchestration/qemu_prepare_launch.sh; echo rc=$?`
- Expected: rc=0。
- Run: `tools/trace_collect.sh 2>/dev/null | python3 tools/coverage_radar.py - | grep -E 'qemu_prepare_launch|check_ports_available'`
- Expected: 出现在 covered 侧。
- [ ] Step 5: checkpoint commit
- Run: `git add tests/orchestration/qemu_prepare_launch.sh && git commit -m "test(qemu): qemu_prepare_launch characterization (PATH-stub)"`
- Expected: commit 成功。

### Task 2.2: qemu_execute_launch smoke

- 目标：fake setsid（写 sentinel 不真启动）+ fake pgrep/sshpass，验证 execute 写 PID 文件、触发 summary、hostkey 调用。
- Files: Create `tests/orchestration/qemu_execute_launch.sh`。
- 验证范围：测试通过；`coverage_radar` 显示 `qemu_execute_launch` covered（原 uncovered `_qemu_post_launch` 消失）。

- [ ] Step 1: 写失败测试
- Change: 先调 `qemu_prepare_launch` 建好全局（复用 2.1 setup），`make_setsid_sentinel`/`make_pgrep_fake`/fake sshpass；调 `qemu_execute_launch`；断言 sentinel 被写、PID 文件生成。
- Run: `bash tests/orchestration/qemu_execute_launch.sh; echo rc=$?`
- Expected: rc≠0。
- [ ] Step 2: 运行并确认失败
- Run: 同上。
- [ ] Step 3: 修到通过
- Change: 对齐 sentinel 与 PID 文件断言。
- [ ] Step 4: 运行并确认通过
- Run: `bash tests/orchestration/qemu_execute_launch.sh; echo rc=$?`
- Expected: rc=0。
- [ ] Step 5: checkpoint commit
- Run: `git add tests/orchestration/qemu_execute_launch.sh && git commit -m "test(qemu): qemu_execute_launch smoke (fake setsid/pgrep)"`
- Expected: commit 成功。

### Task 2.3: binary 下载链 stub characterization

- 目标：fake curl/file/sha256sum/tar 覆盖现零测试的 `download_qemu_binary_core`/`download_and_replace_community_qemu`/`ensure_qemu_binary_community`（含 flock 备份回滚），吃掉 #1 盲区。
- Files: Create `tests/orchestration/qemu_binary_download.sh`。
- 验证范围：测试通过；这些函数在 `coverage_radar` 转 covered。

- [ ] Step 1: 写失败测试
- Change: fake curl 按 URL 吐假归档；fake `file` 报 `gzip`；真/假 `tar`+`sha256sum`；`QEMU_BIN_FILE` 指临时路径；调 `ensure_qemu_binary_community`（label=community、arch=qemu-system-arm）与 `download_and_replace_community_qemu` 各一支；断言 manifest 写入、备份生成/清理、返回码。
- Run: `bash tests/orchestration/qemu_binary_download.sh; echo rc=$?`
- Expected: rc≠0。
- [ ] Step 2: 运行并确认失败
- Run: 同上。
- [ ] Step 3: 修到通过
- Change: 对齐归档字节/tar 解析/manifest 字段断言。
- [ ] Step 4: 运行并确认通过
- Run: `bash tests/orchestration/qemu_binary_download.sh; echo rc=$?`
- Expected: rc=0。
- Run: `tools/trace_collect.sh 2>/dev/null | python3 tools/coverage_radar.py - | grep -E 'download_qemu_binary_core|ensure_qemu_binary_community'`
- Expected: 出现在 covered 侧。
- [ ] Step 5: checkpoint commit
- Run: `git add tests/orchestration/qemu_binary_download.sh && git commit -m "test(qemu): binary 下载链 stub characterization (吃 #1 盲区)"`
- Expected: commit 成功。

### Task 2.4: start-qemu --force 同端口重启顺序回归锁（F1）

- 目标：锁住 F1 不变量——冲突 kill 必须发生在端口检查之前，`ob start-qemu <m> --force` 在默认端口被旧实例占用时**不** `exit 3`，而是杀旧重启。
- Files: Create `tests/orchestration/start_qemu_force_restart.sh`。
- 验证范围：测试通过；证明 kill 调用先于 `check_ports_available`。

- [ ] Step 1: 写失败测试（先于深化，确保 Task 3.4 抽 `qemu_stop_instance` 后顺序不破）
- Change: 起一个真实存活但可安全杀的假实例（`sleep 300 &` 取 `$!` 作 fake qemu PID），写其 PID 到 `$WORKSPACE_DIR/qemu-bin/.pids/<m>.pid`（含 binary/ports 字段）；设 `QEMU_FORCE=1`、非 TTY；`make_setsid_sentinel`/`make_qemu_curl_fake`/`make_bitbake_env_fake`；fake `kill`（记录调用到 `.kill.calls`）；调 `cmd_start_qemu <m>`；断言 (a) `.kill.calls` 含对 fake PID 的调用、(b) 进程未 `exit 3`（rc∈{0,2} 或到 setsid sentinel）、(c) `check_ports_available` 的调用记录（若 stub 化）在 kill 之后。
- Run: `bash tests/orchestration/start_qemu_force_restart.sh; echo rc=$?`
- Expected: rc≠0（测试或被测行为未就绪）。
- [ ] Step 2: 运行并确认失败
- Run: 同上。
- [ ] Step 3: 修到通过
- Change: 对齐冲突块→prepare→execute 的 stub 与断言；若 F1 不变量被某改动破坏，**回 lib 修顺序**，不改测试。
- [ ] Step 4: 运行并确认通过
- Run: `bash tests/orchestration/start_qemu_force_restart.sh; echo rc=$?`
- Expected: rc=0。
- [ ] Step 5: checkpoint commit
- Run: `git add tests/orchestration/start_qemu_force_restart.sh && git commit -m "test(qemu): --force 同端口重启顺序回归锁 (F1 不变量)"`
- Expected: commit 成功。

### Task 3.1: 抽 binary 两纯决策 + unit test

- 目标：把更新判定与 URL 解析的纯规则从 `check_jenkins_update`/`ensure_qemu_binary_community` 抽成 `qemu_binary_update_decision`/`qemu_binary_resolve_url`（无副作用、不 exit），orchestrator 退化成取输入→调决策→执行。
- Files: Modify `lib/qemu_binary.sh`；Create `tests/unit/qemu_binary_decision.sh`。
- 验证范围：unit 通过；`tools/ob_check.sh` 全绿（exit-contract：两新函数不 exit，qemu_binary.sh 仍 direct-exit 不变）。

- [ ] Step 1: 写失败测试（TDD）
- Change: 写 `tests/unit/qemu_binary_decision.sh`：(a) `qemu_binary_update_decision <local_build> <remote_build> <manifest_url>` → `up_to_date`/`update_available`/`skip_not_jenkins`/`skip_no_build`；(b) `qemu_binary_resolve_url <env_url> <config_url> <label> <arch>` → env>config>community+arm 默认 jenkins>community+aarch64 `none_aarch64`>其他 `needs_input`。覆盖 aarch64 特例与 Jenkins url guard。
- Run: `bash tests/unit/qemu_binary_decision.sh; echo rc=$?`
- Expected: rc≠0。
- [ ] Step 2: 运行并确认失败
- Run: 同上。
- [ ] Step 3: 写最小实现
- Change: `lib/qemu_binary.sh` 加两纯函数（`case`/`[[ ]]` 纯逻辑、echo 结果串、不 exit、不读文件不联网）；`check_jenkins_update` 的比较+guard、`ensure_qemu_binary_community` 的优先级链改为调它们。
- [ ] Step 4: 运行并确认通过
- Run: `bash tests/unit/qemu_binary_decision.sh; echo rc=$?`（rc=0）；`tools/ob_check.sh`（`ALL GREEN`）。
- Expected: rc=0 + ALL GREEN。
- [ ] Step 5: checkpoint commit
- Run: `git add lib/qemu_binary.sh tests/unit/qemu_binary_decision.sh && git commit -m "refactor(qemu_binary): 抽 update_decision/resolve_url 纯决策 + unit"`
- Expected: commit 成功。

### Task 3.2: PID 写归属收口到 runtime（writer 单点）

- 目标：把 PID 文件 **write** 确立为 qemu runtime 独占（已在 `qemu_execute_launch`，吸收自 `_qemu_post_launch`），字段格式契约由 writer 单点拥有。**cmd_status 的 read 路径不动**（F3：status 用 `read_kv_field` 循环读 .pid 文件、非 `PIDFILE_*` 全局、多实例单行）。
- Files: Modify `lib/qemu.sh`（确认 write 集中）；Modify `lib/commands.sh`（确认无第二处 write PID 文件）。
- 验证范围：`tools/ob_check.sh` 全绿；2.2 execute smoke 仍通过。

- [ ] Step 1: 写当前状态检查
- Run: `grep -nE 'QEMU_PID_FILE' lib/commands.sh | head`；再 `grep -nE 'cat > .*QEMU_PID_FILE|QEMU_PID_FILE.*<<' lib/qemu.sh lib/commands.sh`
- Expected: 确认 PID 文件 write 仅在 `qemu_execute_launch`（lib/qemu.sh）；`lib/commands.sh` 仅 read/delete（`rm -f`），无第二处 write heredoc。**不预期** status 读 `PIDFILE_*`（F3：status 用 `read_kv_field`，grep 应无 `PIDFILE_` 命中于 status 段）。
- [ ] Step 2: 运行并确认当前状态
- Run: 同上。
- [ ] Step 3: 写最小实现
- Change: 若 `lib/commands.sh` 仍有第二处 PID 文件 write，迁入 `qemu_execute_launch`；read/validate 已在 qemu runtime，确认同居。cmd_status/stop 的 **read** 路径保持现状（status 用 `read_kv_field`、stop 用 `read_pid_file`，不同读法服务不同上下文，不强并）。
- [ ] Step 4: 运行并确认通过
- Run: `tools/ob_check.sh && bash tests/orchestration/qemu_execute_launch.sh; echo rc=$?`
- Expected: `ALL GREEN` + rc=0。
- [ ] Step 5: checkpoint commit
- Run: `git add lib/qemu.sh lib/commands.sh && git commit -m "refactor(qemu): PID 文件 write 归口 runtime (字段契约单点 owned)"`
- Expected: commit 成功。

### Task 3.3: 抽 qemu_instance_describe 去重 start↔stop 显示（不含 status）

- 目标：把 start 冲突块与 stop 块两处**同源四行**（PID/Started/Ports/Serial log，读 `PIDFILE_*` 全局）收成一个 runtime 函数 `qemu_instance_describe`。**cmd_status 不并入**（F3：status 是多实例单行、无 Started/Serial、`/proc` 活性、不同源，强并会回归 status 输出）。
- Files: Modify `lib/qemu.sh`（新增 `qemu_instance_describe`）；Modify `lib/commands.sh`（start 冲突块 + stop 块两处改调）；Create `tests/unit/qemu_instance_describe.sh`。
- 验证范围：`tools/ob_check.sh` 全绿；describe 输出与原两处一致；status 输出未变。

- [ ] Step 1: 写失败测试
- Change: 写 `tests/unit/qemu_instance_describe.sh`：设 `PIDFILE_*` 全局后调 `qemu_instance_describe`，断言输出含 `PID`/`Started`/`Ports`/`Serial log` 四行且字段值正确。
- Run: `bash tests/unit/qemu_instance_describe.sh; echo rc=$?`（或 MISSING）
- Expected: rc≠0 / MISSING。
- [ ] Step 2: 运行并确认失败
- Run: 同上。
- [ ] Step 3: 写最小实现
- Change: `lib/qemu.sh` 加 `qemu_instance_describe`（读 `PIDFILE_*` 全局，echo 统一四行格式）；`cmd_start_qemu` 冲突块、`cmd_stop_qemu` 块两处改调它；**cmd_status 不动**。
- [ ] Step 4: 运行并确认通过
- Run: `tools/ob_check.sh`
- Expected: `ALL GREEN`（含 `stop_qemu_dryrun.sh`、`status_machine_state.sh` 通过——后者验证 status 输出未变）。
- [ ] Step 5: checkpoint commit
- Run: `git add lib/qemu.sh lib/commands.sh tests/unit/qemu_instance_describe.sh && git commit -m "refactor(qemu): qemu_instance_describe 去重 start↔stop 显示 (status 不并入)"`
- Expected: commit 成功。

### Task 3.4: 抽 qemu_stop_instance 统一 stop 逻辑

- 目标：把 `cmd_start_qemu` 冲突 kill（Task 1.3 暂留内联）与 `cmd_stop_qemu` kill 收成一个 runtime 函数 `qemu_stop_instance`，消除两套分歧实现。
- Files: Modify `lib/qemu.sh`（新增 `qemu_stop_instance`）；Modify `lib/commands.sh`（两处改调）；Create `tests/orchestration/qemu_stop_instance.sh`。
- **可选 polish（R2，非阻塞）**：引入 `qemu_stop_instance` 时可顺带引入对偶 `qemu_detect_running_instance`（封装 `derive_qemu_paths`+`read_pid_file`+`validate_pid`，消 cmd_* 冲突块与 prepare 各调一次 `derive_qemu_paths` 的重复、让冲突块可独立单测、与 stop 对称成 detect+stop 一对）。要做就并进本 task，**别单开增量、别阻塞进实现**；当前内联冲突块 + 幂等 `derive_qemu_paths` 完全可接受。
- 验证范围：`tools/ob_check.sh` 全绿；stop_instance 测试通过；**Task 2.4 的 `--force` 顺序锁仍绿**（F1 不变量未被破坏）。

- [ ] Step 1: 写失败测试
- Change: 写 `tests/orchestration/qemu_stop_instance.sh`：fake `kill`（记录调用+rc）、`sleep` 起假存活实例取 PID、设 `PIDFILE_PID`；调 `qemu_stop_instance`；断言 PID 文件被删、kill 调用预期次数。
- Run: `bash tests/orchestration/qemu_stop_instance.sh; echo rc=$?`
- Expected: rc≠0。
- [ ] Step 2: 运行并确认失败
- Run: 同上。
- [ ] Step 3: 写最小实现
- Change: `lib/qemu.sh` 加 `qemu_stop_instance`（kill→sleep→wait/proc 探测→SIGKILL 兜底→`rm -f QEMU_PID_FILE`，返回状态）；`cmd_start_qemu` 冲突 kill 与 `cmd_stop_qemu` kill 改调它。
- [ ] Step 4: 运行并确认通过
- Run: `bash tests/orchestration/qemu_stop_instance.sh; echo rc=$?`（rc=0）；`bash tests/orchestration/start_qemu_force_restart.sh; echo rc=$?`（rc=0，F1 锁不破）；`tools/ob_check.sh`（ALL GREEN）。
- Expected: 三项全过。
- [ ] Step 5: checkpoint commit
- Run: `git add lib/qemu.sh lib/commands.sh tests/orchestration/qemu_stop_instance.sh && git commit -m "refactor(qemu): qemu_stop_instance 统一 start 冲突 kill + cmd_stop_qemu"`
- Expected: commit 成功。

### Task 4.1: 结构锁终检（重定向已于 1.1/1.2/1.3 同址完成）

- 目标：确认结构锁所有断言的文件指针与新拓扑一致、Shape-2 锁就位，作为收口验证（重定向工作已分散在 1.1/1.2/1.3，本 task 不再集中改）。
- Files: 仅验证 `tests/protocol/qemu_launch_profile_structure.sh`。
- 验证范围：该测试通过；`tools/ob_check.sh` ALL GREEN。

- [ ] Step 1: 写当前状态检查
- Run: `grep -nE 'QEMU_LAUNCH_PROFILE_SH|QEMU_BINARY_SH|qemu_prepare_launch|qemu_execute_launch' tests/protocol/qemu_launch_profile_structure.sh`
- Expected: 命中新文件指针（launch_profile/binary）+ Shape-2 断言（prepare/execute）。
- [ ] Step 2: 确认无残留旧指针
- Run: `grep -nE 'ensure_qemu.*\$QEMU_SH|find_machine_conf.*\$QEMU_SH|resolve_machine_conf_include.*\$QEMU_SH' tests/protocol/qemu_launch_profile_structure.sh || echo NONE`
- Expected: `NONE`（已迁函数不再指 `$QEMU_SH`）。
- [ ] Step 3: 若有残留则补（应无）
- Change: 仅在 Step 2 命中时补齐指针；正常情况无改动。
- [ ] Step 4: 运行并确认通过
- Run: `bash tests/protocol/qemu_launch_profile_structure.sh; echo rc=$?`（rc=0）；`tools/ob_check.sh`（ALL GREEN）。
- Expected: rc=0 + ALL GREEN。
- [ ] Step 5: checkpoint commit（仅当 Step 3 有改动）
- Run: `git add tests/protocol/qemu_launch_profile_structure.sh && git commit -m "test(qemu): 结构锁终检 (1.1/1.2/1.3 重定向收尾)"` 或无改动跳过。
- Expected: commit 成功或无改动。

### Task 4.2: coverage 实测定固定基线 + 残差文档

- 目标：跑 radar 实测新 uncovered 数，定为固定基线，更新 CI 门禁值与残差清单。
- Files: Modify `.github/workflows/ob-tests.yml`；Modify `tools/coverage_matrix.md`。
- 验证范围：radar 实测 N；CI 门禁值匹配；残差清单列全。

- [ ] Step 1: 实测当前 N
- Run: `tools/trace_collect.sh | python3 tools/coverage_radar.py -`
- Expected: `TOTAL ... COVERED ... UNCOVERED <N>`，N 预期显著低于 21。记录 N。
- [ ] Step 2: 确认残差集合法（每条是 display/TTY/npm/真副作用且非本 pass 目标）
- Run: `tools/trace_collect.sh | python3 tools/coverage_radar.py - | sed -n '/UNCOVERED/,$p' | head -40`
- Expected: 残差为 display（log/show_logo/...）、cmd_menu、npm 探测、qemu_instance_describe（display）等合法类。出现非残差类（本应 stub 覆盖却漏）则回 Phase 2/3 补测试，不调高基线。
- [ ] Step 3: 更新 CI 门禁值与残差清单
- Change: `.github/workflows/ob-tests.yml` 的 `--fail-if-uncovered 21` 改为实测 N；`tools/coverage_matrix.md` 更新归属 + 残差函数 + 每条理由。
- [ ] Step 4: 运行并确认通过
- Run: `tools/trace_collect.sh | python3 tools/coverage_radar.py - --fail-if-uncovered <实测N>; echo rc=$?`
- Expected: rc=0。
- [ ] Step 5: checkpoint commit
- Run: `git add .github/workflows/ob-tests.yml tools/coverage_matrix.md && git commit -m "ci(coverage): 固定基线 21→<N> + 残差清单 (qemu deepening 后实测)"`
- Expected: commit 成功。

### Task 4.3: WORKSPACE.md lib/ 路由同步

- 目标：`lib/` 路由行更新为拆分后清单（文件此刻已真实存在）。
- Files: Modify `rules/03_WORKSPACE.md`（`lib/` 路由行）。
- 验证范围：路由行与 `ls lib/*.sh` 一致。

- [ ] Step 1: 写当前状态检查
- Run: `ls -1 lib/*.sh | sed 's#lib/##'`
- Expected: 含 `qemu_launch_profile.sh`/`qemu_binary.sh` 全量。
- [ ] Step 2: 确认路由行滞后
- Run: `grep 'qemu.sh QEMU runtime' rules/03_WORKSPACE.md`
- Expected: 命中旧行。
- [ ] Step 3: 写最小实现
- Change: `lib/` 路由行改为：`util.sh 底层工具 / repo.sh 仓库解析 / bitbake_env.sh BitBake environment one-shot 查询 / build_env.sh current-shell 构建环境进入 / machine_state.sh 生命周期状态 / init_pipeline.sh init 流水线 / commands.sh cmd_* 编排 / qemu_launch_profile.sh QEMU 启动画像决策 (ADR-0007) / qemu_binary.sh QEMU binary provisioning (下载/Jenkins/manifest) / qemu.sh QEMU runtime (端口/PID/hostkey/启动执行)`。
- [ ] Step 4: 运行并确认通过
- Run: `grep -c 'qemu_launch_profile.sh\|qemu_binary.sh' rules/03_WORKSPACE.md`
- Expected: ≥2。
- [ ] Step 5: checkpoint commit
- Run: `git add rules/03_WORKSPACE.md && git commit -m "docs(workspace): lib/ 路由同步 qemu 三 module 拆分"`
- Expected: commit 成功。

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划再动。
- **首个 commit**：切 feature 分支（如 `feature/qemu-sh-deepening`）后，把 main 上已 staged 的 ADR-0007 修订 + 本计划文档作为**首个 commit** 落下，再开始 Task 0.1。`main` 不直接动实现。
- 按任务顺序执行，不无声跳步、合并步或改目标；extract→pin→deepen 顺序不可乱（pin 必须紧跟对应 extract）。
- 每完成一个任务运行其验证；`tools/ob_check.sh` 是改 `ob`/`lib/*.sh` 后的统一配套自检，多数任务以它收尾。
- 遇阻塞、重复失败或计划与仓库现实不符（行段漂移、函数名对不上），立即停下说明，**用 grep 重新枚举符号**，不要猜路径或猜命令。
- 每个 Step 5 的 checkpoint commit 是回滚点；某 Phase 整体退废可 `git reset --hard <该 Phase 前 commit>`。
- **F1 不变量是硬约束**：冲突 kill 必须先于端口检查；任何改动若使 Task 2.4 的 `--force` 顺序锁变红，立即回滚该改动。
- `exit_contract` 配置零改动是硬约束：三新文件**不加入** `LEAF_EXIT_EXCEPTIONS_BY_BASENAME`（保持 direct-exit）；若误加需停下确认。
- off-path（machine 选择 4×、BUILD_DIR 5×、cmd_status 多实例单行呈现）严禁顺手改。

## 最终验证

- Run: `tools/ob_check.sh`
- Expected: `ALL GREEN`，含 `extract_funcs lib 三段全清`（10 个 lib 文件）、`exit-contract ok`（X/Y/Z green，两新文件未入 leaf-pure 白名单）、`run_all ALL GREEN`。
- Run: `bash tests/run_all.sh --full`
- Expected: 通过（含 `.exp` 交互矩阵，验证 start-qemu/stop-qemu 退出码动态协议不退化）。
- Run: `bash tests/orchestration/start_qemu_force_restart.sh; echo rc=$?`
- Expected: rc=0（F1 `--force` 同端口重启顺序不变量成立）。
- Run: `tools/trace_collect.sh | python3 tools/coverage_radar.py - --fail-if-uncovered <Task4.2实测N>`
- Expected: rc=0（uncovered ≤ 新基线）。
- Run: `git log --oneline feature/qemu-sh-deepening ^main`
- Expected: 见 Phase 0-4 各 checkpoint commit（首个为 ADR-0007+计划文档）。
- 观察: `wc -l lib/qemu.sh lib/qemu_launch_profile.sh lib/qemu_binary.sh` —— qemu.sh 显著 < 1337，三文件合计为原 1337 行等价集（加新函数后略增）。

## 审阅 Checkpoint

- 计划正文到此结束（R1 修订已吸收评审 F1-F6 + 2 条轻量提示，全部经代码核验成立）。
- 审阅通过前不进入实现；本计划默认执行方是普通编码 agent 或人工执行者。
- 若要调整，先改计划再跑同一轮 inline 自检。
