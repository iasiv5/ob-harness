# ob deploy-to-qemu 实施计划

## 修订记录

- v1：基于已批准设计 `docs/specs/2026-07-20-ob-deploy-to-qemu-design.md`（grill-with-docs 共识，17 条决策零未决）拆 5 任务。纯增量（选项 C 零重构 cmd_*），无 Commit A/B 重构-功能切分。
- v2（review feedback，2026-07-20）：吸收评审 Y1-Y5 + G1-G3（8 条），**反驳 R1**（评审证据错误——见下）。逐条落位：Y1→T1 Step 1（usage_dispatch_sync 改顶层 echelon，不照 dev build DEV_ARGS）；Y2→T3 伪代码（DRY-RUN 前移到探测 QEMU 前，不交互）；Y3→T3 伪代码（image stage 明确简化版，只 Machine/Image 两行）；Y4→T2 Step 1（stage helper 拆 `stage_initialized_machine` + `stage_running_qemu` + 场景组合表）；Y5→T1 Step 4（空壳抽检改 OB_NO_MAIN source 模式）；G1→文件结构与职责（落位核对）；G2→T5 Step 3（抽检前置隔离）；G3→T3 Step 1（pick_machine 二次拉取说明）。
  - **R1 反驳**：评审称"integration 层无 exit 77/SKIP 惯例，grep 返回空"——独立 `grep -rn -E "exit 77|SKIP:" tests/integration/` 命中 **ob_dev.sh:172/177/241 三处** SKIP 门（`no init machine` / `refresh rc≠0` / `no safe candidate` → `echo SKIP: ...; exit 77`），run_all.sh:30 认 rc=77+`SKIP:`。评审只读 ob_dev.sh 1-45 行（SKIP 门在 172+）+ grep_search 返回空（工具问题），误判。T4 "照 ob_dev.sh SKIP 门模式"**正确，不修**。
- v3（review round-2 🟢 收尾，2026-07-20）：R1 反驳获评审接受撤回（评审确认 ob_dev.sh:172/177/241 SKIP 门，自承上轮只读 1-45 行失误）。新发现落位：G-new1→T1 Step 4（`cmd_build_bitbake_handoff` 行号 :33-36 订正为 `run_cmd_build` :35-44，实测 `run_cmd_build` 在 :35、`OB_NO_MAIN` 在 :39）；G-new2→T3 DRY-RUN 注释（补"前移后也不探测 QEMU / 不读旧端口 / 不弹 banner"）。Y-new（design 控制流图 DRY-RUN 顺序与伪代码对齐）在 design v3 侧改，**本计划无改动**——T3 按伪代码实现即可。
- v4（实施完成 + review 🟢 放行，2026-07-21）：T1-T5 全落地（feature/ob-deploy-to-qemu, commits b8520c6→d1770c9; ob_check ALL GREEN + run_all --full ALL GREEN + T4 e2e 真跑 romulus rc=0/BMC SSH ready）。实施期 4 处 deviation（供后人 replicate）:
  ① **T1 Step1 vs Step3c 自相矛盾**：Step1 测试 mock 用 `$@`（`GOT:romulus`, dev DEV_ARGS 模式）vs Step3c main dispatch 无参调用（cmd_start/stop_qemu 惯例, 靠全局 MACHINE）——不可能同时满足。实施选"无参 + 读 `$MACHINE`"路线（与同级 cmd 同构），mock 改 `DEPLOY_CALLED machine=%s`。
  ② **T2/T3 合并 commit 12297b3**：计划要求分步 commit，实际合并为一个 TDD commit（红灯基线只在 commit 内部存在过）。最终代码质量无影响。
  ③ **场景② port 2222→29222**：旧 .pid `ssh_port=2222`（== qemu_prepare_launch 默认）无法分辨"注入复用"vs"默认"；改 `29222`（非默认）+ 检查新 .pid `pid=12345`（分辨旧/新 .pid）。
  ④ **qemu_instance_is_alive if 包裹**：计划伪代码裸调 + `$?` 读，ob `set -euo` 下死实例 `return 1` 会 abort——实测 `set -e; f(){return 1;}; f; echo` → exit（不达 `$?` 读）。if 包裹规避。**附带既有债**：`cmd_start_qemu:491` / `cmd_stop_qemu:622` 同款裸调有同类 set -e 隐患（死实例 clean_stale 路径 abort, 既有测试用活实例未暴露）, 属独立既有债, 不在本次范围（约束 1 不改 cmd_*）, 建议独立 PR 修。

## 目标

把已批准设计 `docs/specs/2026-07-20-ob-deploy-to-qemu-design.md` 落地为 `ob deploy-to-qemu <machine>`：image 级重建（`bitbake obmc-phosphor-image`）+ QEMU 重启（在跑则 stop + start 端口复用 / 没跑则 start），做干净验证。自带编排调底层 module，cmd_* 零改动。

5 任务严格顺序：T1 骨架接线 → T2 失败测试基线（TDD）→ T3 完整实现 → T4 integration → T5 文档收尾 + 最终验证。

## 架构快照

- 新 `lib/commands.sh::cmd_deploy_to_qemu`（L1 exit seam，插在 `cmd_stop_qemu` 后 [commands.sh:682](lib/commands.sh#L682) 后）：自带编排 build-first 链——前置 init-done → 探测 QEMU 在跑 + 预读旧端口（`qemu_instance_load`）→ 仅在跑时 confirm banner → build（`build_env_enter` + `bitbake obmc-phosphor-image`）→ 在跑则 `qemu_instance_stop` + 注入 `QEMU_*_PORT` 端口复用 → `qemu_prepare_launch` + `qemu_execute_launch`。exit 0/1/2/3。
- `ob` 主入口接线：usage Commands 段加 `deploy-to-qemu` 行 + Examples 段加示例 + `parse_args` case 加 `deploy-to-qemu)`（[ob:120-125](ob#L120) stop-qemu 模式）+ `main` dispatch 加 `if [[ "$COMMAND" == "deploy-to-qemu" ]]` 块（[ob:283-286](ob#L283) stop-qemu 模式）。
- 复用底层 module（不改）：`build_env_enter` / `resolve_npm_registry` / `bitbake` / `machine_state_*` / `derive_qemu_paths` / `qemu_instance_load`/`is_alive`/`stop`/`clean_stale`/`summarize_full` / `qemu_prepare_launch` / `qemu_execute_launch` / `print_confirm_banner` / `step_header` / `info`/`warn`/`error`/`notice` / `exit_on_user_cancel` / `pick_machine`。

## 全局约束

从设计文档"实施约束"段逐字继承：

1. **自带编排，零重构 cmd_***：只调底层 module，不改 `cmd_build`/`cmd_start_qemu`/`cmd_stop_qemu`/`lib/qemu.sh`/`lib/qemu_instance.sh`/`lib/build_env.sh` 行为。bitbake + npm registry + image 信息打印 ~20 行与 `cmd_build` 重复（技术债，后续抽 `build_obmc_image` helper）。
2. **端口复用时序**：必须在 `qemu_instance_stop` 之前 `qemu_instance_load` 读端口；读后设进 `QEMU_*_PORT` 全局（`qemu_prepare_launch` 端口来源 CLI > env > default，[qemu.sh:98](lib/qemu.sh#L98)）；`http_port` 字面 `none`（[qemu.sh:161](lib/qemu.sh#L161)）不设 `QEMU_HTTP_PORT`。
3. **build-first**：build 在 stop 之前。build 失败 → exit 1，QEMU 不动（不调 `qemu_instance_stop`）。
4. **confirm 仅 QEMU 在跑时**：无 QEMU 时无 banner（显式快路径）。遵循 `confirmation banner` 术语"路径风险"原则，用 `print_confirm_banner`（cmd_start_qemu 冲突块 [:504](lib/commands.sh#L504) 模式）。
5. **成功边界 = QEMU 启动即成功**：BMC-ready 超时 warn 不 exit（沿用 `qemu_execute_launch` 现状 [qemu.sh:188](lib/qemu.sh#L188)，不改 qemu.sh）。
6. **stage 标记 + 恢复引导**：build 成功打 `Image Rebuilt`；start 前打恢复引导（`ob start-qemu <machine>`）——因 `qemu_execute_launch` exit 1 后无法再打印。
7. **exit-code 契约**：0 = image 重建 + QEMU 启动；1 = build / setsid 失败；2 = banner 拒绝；3 = machine 未 init。`cmd_deploy_to_qemu` 是 exit seam（`commands.sh`），非 leaf-pure。
8. **环境**：Linux + bash；验证命令用 bash / python3 / expect。stub 套路复用 `tests/lib/stub.sh` + `qemu_stubs.sh`。
9. **命名**：`cmd_deploy_to_qemu`（snake_case，与 `cmd_start_qemu` 同构）；usage `deploy-to-qemu`（连字符，与 `start-qemu`/`stop-qemu` 同构）。
10. **改 ob/lib 后每任务跑 `tools/ob_check.sh`**（AGENTS.md 约束：结构 / 函数登记 / shellcheck baseline / exit_contract / run_all）。

## 输入工件

- 设计文档：`docs/specs/2026-07-20-ob-deploy-to-qemu-design.md`（零未决，含完整编排伪代码 + 7 测试场景）。
- 伴生已落：`docs/adr/0011-ob-deploy-to-qemu-toplevel-ownership.md`、`CONTEXT.md`（`ob deploy-to-qemu` 术语）、`rules/skills/workflow_02-obmc_dev_modify.md`（验证链 modify→build→deploy-to-qemu→finish）。计划引用，不重述。

## 文件结构与职责

**Create:**
- `tests/orchestration/deploy_to_qemu.sh`（T2，7 场景）—— cmd_deploy_to_qemu 编排 stub 测试。
- `tests/integration/ob_deploy_to_qemu.sh`（T4，gate `--integration`）—— build + QEMU e2e，SKIP 门 exit 77。

**Modify:**
- `lib/commands.sh`（T1 加 `cmd_deploy_to_qemu` 空壳；T3 填完整编排）。
- `ob`（T1：usage Commands 加 `deploy-to-qemu` 行 + Examples 加示例 + `parse_args` case 加 `deploy-to-qemu)` + `main` dispatch 加 if 块）。
- `tests/protocol/usage_dispatch_sync.sh`（T1：加 deploy-to-qemu 手动登记块；顶部 awk 自动断言自动覆盖）。
- `rules/03_WORKSPACE.md`（T5：ob 条目补 `deploy-to-qemu`）。

**不改**（约束 1）：`cmd_build`/`cmd_start_qemu`/`cmd_stop_qemu`/`lib/qemu.sh`/`lib/qemu_instance.sh`/`lib/build_env.sh`/`tools/exit_contract.py`（deploy-to-qemu 在 `commands.sh` exit seam，非 leaf-pure basename）。

**已落（本轮 grill，T1–T5 不再变更；评审 G1 落位核对）**：`CONTEXT.md`（`ob deploy-to-qemu` 术语，`grep -c deploy-to-qemu CONTEXT.md` 命中）、`rules/skills/workflow_02-obmc_dev_modify.md`（第 8 步验证链 modify→build→deploy-to-qemu→finish 已含）、`docs/adr/0011-ob-deploy-to-qemu-toplevel-ownership.md`（Status: accepted）。

**接口依赖：** T2 Consumes `cmd_deploy_to_qemu`（T1 Produces 骨架）；T3 Consumes orchestration 测试（T2 Produces 失败基线）+ 底层 module（既有）；T4 Consumes 完整 `ob deploy-to-qemu`（T3）。

---

## 任务清单

### Task T1: ob 接线 + cmd_deploy_to_qemu 骨架 + usage_dispatch_sync 登记

- 目标：让 `ob deploy-to-qemu <machine>` 能 dispatch 到 `cmd_deploy_to_qemu`（空壳 exit 0），ob 能力清单登记 deploy-to-qemu。
- Files:
  - Modify: `lib/commands.sh`（`cmd_stop_qemu` 后 [:682](lib/commands.sh#L682) 插 `cmd_deploy_to_qemu` 空壳）
  - Modify: `ob`（usage Commands 段 [:184-189](ob#L184) + Examples 段 [:228-247](ob#L228) + `parse_args` case [:120-125](ob#L120) + `main` dispatch [:283-286](ob#L283))
  - Modify: `tests/protocol/usage_dispatch_sync.sh`（加 deploy-to-qemu 手动登记块）
- 验证范围：`bash tests/protocol/usage_dispatch_sync.sh` exit 0（顶部 awk 自动断言 dispatch==usage 覆盖 deploy-to-qemu + 手动登记块 main 真调 cmd_deploy_to_qemu）；`./ob --help` 含 `deploy-to-qemu`。
- 接口契约:
  - Consumes: 无（首个任务）。
  - Produces: `cmd_deploy_to_qemu` 骨架（空壳，T2/T3 消费）+ ob 接线（deploy-to-qemu 可调）。

- [ ] Step 1: 写失败 protocol 断言（加进 `tests/protocol/usage_dispatch_sync.sh`）
  - **deploy-to-qemu 是顶层命令（同 init/status/build/start-qemu/stop-qemu），不走 DEV_ARGS**（评审 Y1：不照 [:111-122](tests/protocol/usage_dispatch_sync.sh#L111) 的 ob **dev** build 登记——那是 `parse_args dev --machine m build` → DEV_ARGS 模式）。顶层命令的 dispatch consistency 靠顶部 awk 自动断言（[:9-38](tests/protocol/usage_dispatch_sync.sh#L9)，dispatch `case "$COMMAND"` 集合 == usage Commands 集合）自动覆盖；顶层命令在 usage_dispatch_sync 无手动登记块。
  - 手动补充断言（加在 ob dev build 登记 [:111-122](tests/protocol/usage_dispatch_sync.sh#L111) 段后、`assert_summary` 前）——顶层 echelon，**不写 DEV_ARGS**：
    - `assert_contains "usage 含 deploy-to-qemu" "$_usage_out3" "deploy-to-qemu"`。
    - `parse_args deploy-to-qemu romulus` → `assert_eq "COMMAND=deploy-to-qemu" "$COMMAND" "deploy-to-qemu"` + `assert_eq "MACHINE=romulus" "$MACHINE" "romulus"`。
    - `cmd_deploy_to_qemu() { printf 'GOT:%s\n' "$@"; return 0; }` + `main deploy-to-qemu romulus 2>/dev/null` → `assert_contains "main deploy-to-qemu 调 cmd_deploy_to_qemu" "$_dispatch_out_deploy" "GOT:romulus"`（重设捕获，验证 main dispatch if 块真调）。
  - Run: `bash tests/protocol/usage_dispatch_sync.sh`
  - Expected: 失败（`cmd_deploy_to_qemu` 未定义 + usage 不含 deploy-to-qemu）。

- [ ] Step 2: 运行并确认失败
  - Run: `bash tests/protocol/usage_dispatch_sync.sh >/dev/null 2>&1; test $? -ne 0`
  - Expected: 测试非 0 退出（TDD 红灯——usage-contains-deploy-to-qemu 断言 FAIL / cmd_deploy_to_qemu 未定义）。不用 `| tail`（吞 rc），直接 `>/dev/null 2>&1` + `test $? -ne 0` 显式断言失败。

- [ ] Step 3: 写最小实现（4 处改动）
  - **(a) `lib/commands.sh` 加 `cmd_deploy_to_qemu` 空壳**（`cmd_stop_qemu` 结束 `}` [:682](lib/commands.sh#L682) 后、`cmd_init` [:684](lib/commands.sh#L684) 前）：

```bash
cmd_deploy_to_qemu() {
    detect_harness_root
    # T1 骨架: T3 填完整编排(build-first + 端口复用 + confirm + stage 标记)
    notice "ob deploy-to-qemu: skeleton (not yet implemented)" >&2
    exit 0
}
```

  - **(b) `ob` parse_args case 加 `deploy-to-qemu)`**（[:120-125](ob#L120) `stop-qemu)` 后）：

```bash
        deploy-to-qemu)
            if [[ $# -gt 0 ]] && [[ "$1" != -* ]]; then
                MACHINE="$1"
                shift
            fi
            ;;
```

  - **(c) `ob` main dispatch 加 if 块**（[:283-286](ob#L283) `stop-qemu` if 块后、`cmd_init` [:288](ob#L288) 前）：

```bash
    if [[ "$COMMAND" == "deploy-to-qemu" ]]; then
        cmd_deploy_to_qemu
        return $?
    fi
```

  - **(d) `ob` usage Commands 段加行**（[:188](ob#L188) `stop-qemu` 行后）：

```bash
  deploy-to-qemu [<machine>]  Rebuild image and restart QEMU for clean verification
```

    Examples 段（[:237](ob#L237) `stop-qemu --all` 行后）加：
```bash
  ob deploy-to-qemu romulus       # Rebuild romulus image + restart QEMU (port-reuse if running)
```

  - Change: cmd_deploy_to_qemu 空壳 + parse_args/main/usage 接线 + 示例。

- [ ] Step 4: 运行并确认通过
  - Run: `bash tests/protocol/usage_dispatch_sync.sh && ./ob --help | grep -q deploy-to-qemu && bash -c 'OB_NO_MAIN=1 source ./ob >/dev/null 2>&1; cmd_deploy_to_qemu romulus </dev/null >/dev/null 2>&1; test $? -eq 0'`
  - Expected: usage_dispatch_sync exit 0（awk 自动断言 dispatch==usage 含 deploy-to-qemu + 手动补充断言 main 真调）；`./ob --help` 含 deploy-to-qemu（grep -q exit 0）；空壳可调（评审 Y5：OB_NO_MAIN source 模式规避 main 链路 detect_harness_root 真路径副作用 + set -e 不确定性，照 [cmd_build_bitbake_handoff.sh](tests/orchestration/cmd_build_bitbake_handoff.sh) 的 `run_cmd_build` 子 shell 模式（:35-44，G-new1 订正：原写 :33-36 不准——`run_cmd_build` 在 :35、`OB_NO_MAIN` 在 :39））；空壳 notice + exit 0。三段 `&&` 串联。

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add lib/commands.sh ob tests/protocol/usage_dispatch_sync.sh && git commit -m "feat(deploy): ob deploy-to-qemu skeleton + dispatch wiring"`
  - Expected: commit 成功。

---

### Task T2: orchestration 编排测试 7 场景（TDD 失败基线）

- 目标：先写 cmd_deploy_to_qemu 编排的 7 场景 stub 测试，对 T1 空壳失败（TDD 红灯），锁定编排顺序 / 端口复用 / build-first 三个不变量。
- Files:
  - Create: `tests/orchestration/deploy_to_qemu.sh`
- 验证范围：`bash tests/orchestration/deploy_to_qemu.sh` 对 T1 空壳失败（空壳不 build/stop/start）；T3 实现后全过。
- 接口契约:
  - Consumes: `cmd_deploy_to_qemu` 骨架（T1）+ stub 套路（`tests/lib/stub.sh` + `qemu_stubs.sh`）。
  - Produces: 7 场景测试（失败基线，T3 让它过）。

- [ ] Step 1: 写测试文件 `tests/orchestration/deploy_to_qemu.sh`
  - 照 `tests/orchestration/start_qemu_force_restart.sh` + `cmd_build_bitbake_handoff.sh` + `qemu_execute_launch.sh` scaffold：`source tests/lib/ob_loader.sh` + `assert.sh` + `stub.sh` + `qemu_stubs.sh` + `assert_reset`。假 harness root = `$TMP`（`OB_ENTRY_DIR=$TMP`），stage `$TMP/workspace/{configs,qemu-bin/.pids,openbmc}` + `.init-done` marker + `.manifest` + deploy dir image + `.qemuboot.conf`（让 profile 从它解析，不走 bitbake -e）+ fake qemu binary。
  - 共享 stage helper（在 7 场景前定义，**拆两个**——评审 Y4：场景 ③/④/⑤ 的 `kill -0 $fake_pid` 断言依赖 fake_qemu 存活，"可选"措辞不对，fake_qemu + `.pid` 在这些场景是**必备**）：
    - `stage_initialized_machine`（**场景 ①②③④⑤⑦ 必备，⑥ 不调**）：stage `$TMP/workspace/{configs,qemu-bin/.pids,openbmc}` + `romulus.init-done` marker + `openbmc-source.manifest` + deploy dir image + `.qemuboot.conf`（让 profile 从它解析，不走 bitbake -e）+ fake qemu binary。照 [start_qemu_force_restart.sh:23-40](tests/orchestration/start_qemu_force_restart.sh#L23)。
    - `stage_running_qemu`（**场景 ②③④⑤ 必备，①⑥⑦ 不调**）：造"在跑"实例——fake_qemu（`printf '#!/usr/bin/env bash\nsleep 300\n'`，cmdline 含 `romulus qemu-system-arm` 让 is_alive 匹配，照 [:43-47](tests/orchestration/start_qemu_force_restart.sh#L43)）+ `.pid`（含 `ssh_port=2222`/`redfish_port=2443`/`ipmi_port=2623`，照 [:48-58](tests/orchestration/start_qemu_force_restart.sh#L48)）。
  - **场景 stage 组合表**：① `stage_initialized_machine`；② ③ ④ ⑤ `stage_initialized_machine` + `stage_running_qemu`；⑥ 不 stage `.init-done`（测前置缺失 exit 3）；⑦ `stage_initialized_machine`（DRY-RUN，不 stage running）。
  - stub：`make_qemu_curl_fake "$DB"` + `make_bitbake_env_fake "$DB"`（bitbake -e 兜底，qemuboot.conf 存在不触发）+ `mkfake_bin "$DB" ss` + `make_setsid_sentinel` + `make_pgrep_fake` + `mkfake_bin ssh-keygen`；**build 步骤的 `bitbake obmc-phosphor-image`** 用 `mkfake_bin "$DB" bitbake` + `stub_script`/`stub_exit` 控制（注意：`make_bitbake_env_fake` 也是 fake bitbake，会覆盖——要么 build stub 用 `stub_script bitbake` 处理 `obmc-phosphor-image` 分支，要么先 make_bitbake_env_fake 再 stub_script 追加 build 分支）。设 `OB_NPM_REGISTRY=`（禁用 npm registry 解析，照 cmd_build_bitbake_handoff [:36](tests/orchestration/cmd_build_bitbake_handoff.sh#L36)）。
  - 运行被测：`( cmd_deploy_to_qemu romulus ) </dev/null >"$TMP/out" 2>&1` 或 `OB_NO_MAIN=1` source + 子 shell（照 cmd_build_bitbake_handoff run_cmd_build 模式），`PATH="$DB:$PATH"`。
  - **7 场景断言**（逐字对齐设计文档"orchestration 层"7 场景）：
    - ① QEMU 没跑 + build 成功 → exit 0 + setsid sentinel 写入 + 新 `.pid` 写入 + **输出不含 confirm banner 文本**（`assert_false "无 QEMU 无 banner" grep -q "Kill + rebuild" "$out"`）。
    - ② QEMU 在跑 + build 成功 → `<<<'y'` 喂 confirm → exit 0 + **fake_qemu 被 kill（`kill -0 $fake_pid` 失败）** + **新 `.pid` `ssh_port=2222`（端口复用不变量）**：`grep -q '^ssh_port=2222$' "$pid_file"`。
    - ③ build 失败（`stub_exit "$DB" bitbake 1`）→ exit 1 + **fake_qemu 仍存活（`kill -0 $fake_pid` 成功 = build-first 不变量：build 失败不 stop）** + bitbake `.calls` 计数 1 + setsid 未被调（sentinel 不存在）。
    - ④ confirm 拒绝（`<<<'n'`）+ QEMU 在跑 → exit 2 + fake_qemu 仍存活 + bitbake 未被调（`.calls` 不存在）。
    - ⑤ 部分成功（build 成功 + setsid 失败：`stub_exit "$DB" setsid 1`）→ exit 1 + 输出含 `Image Rebuilt`（stage 标记）+ 含恢复引导 `ob start-qemu`。
    - ⑥ 前置 init-done 缺失（不 stage `.init-done`）→ exit 3 + stderr 含 `ob init`。
    - ⑦ DRY_RUN（`DRY_RUN=1`）→ exit 0 + 输出含 `[DRY-RUN]` + bitbake/setsid 均未被调。
  - Run: `bash tests/orchestration/deploy_to_qemu.sh`
  - Expected: 失败（T1 空壳 notice + exit 0，不编排；场景 ① 的 setsid sentinel 断言失败、③ 的 exit 1 期望拿到 0 等）。

- [ ] Step 2: 运行并确认失败
  - Run: `bash tests/orchestration/deploy_to_qemu.sh >/dev/null 2>&1; test $? -ne 0`
  - Expected: 测试非 0（TDD 红灯——空壳不满足编排断言）。`test $? -ne 0` 显式断言失败。

- [ ] Step 3: 本任务无实现（TDD 红灯基线，实现归 T3）
  - 确认 7 场景断言已写全且对空壳失败。若某场景对空壳意外"过"（断言太弱），补强断言（如 ① 加 setsid sentinel 存在断言）。
  - Change: 仅测试文件（无实现改动）。

- [ ] Step 4: 确认仍是失败基线（不跑通过——这是 TDD 红灯）
  - Run: `bash tests/orchestration/deploy_to_qemu.sh >/dev/null 2>&1; rc=$?; test "$rc" -ne 0`
  - Expected: rc 非 0（红灯基线确立，等 T3 实现）。

---

### Task T3: cmd_deploy_to_qemu 完整编排实现

- 目标：填 cmd_deploy_to_qemu 完整编排（替换 T1 空壳），让 T2 的 7 场景全过。
- Files:
  - Modify: `lib/commands.sh::cmd_deploy_to_qemu`（替换 T1 空壳）
- 验证范围：`bash tests/orchestration/deploy_to_qemu.sh` 7 场景全过；`tools/ob_check.sh` 全绿。
- 接口契约:
  - Consumes: orchestration 测试 7 场景（T2）+ 底层 module（既有）。
  - Produces: `cmd_deploy_to_qemu` 完整编排（T4 integration 消费）。

- [ ] Step 1: 替换 T1 空壳为完整编排
  - 照设计文档"推荐方案"伪代码填 `cmd_deploy_to_qemu`。关键顺序与不变量（约束 1-7）：

```bash
cmd_deploy_to_qemu() {
    detect_harness_root

    # ── Resolve machine (cmd_start_qemu :422-460 模式; deploy 自己 build, 用 initialized 不要求 image-ready) ──
    #   评审 G3: 先判空 machines 数组再 pick_machine, 与 pick_machine 内部再拉一次 list_source 是二次拉取
    #   —— 有意为之(判空/TTY 检测在前, pick_machine 自渲染列表在后), 与 cmd_start_qemu 同构, 不去重。
    if [[ -z "$MACHINE" ]]; then
        local -a machines=()
        local _machine
        while IFS= read -r _machine; do
            [[ -n "$_machine" ]] && machines+=("$_machine")
        done < <(machine_state_initialized_machines)
        if [[ ${#machines[@]} -eq 0 ]]; then
            error "No initialized machines found."
            error "Run 'ob init <machine>' first."
            exit 3
        fi
        if [[ ! -t 0 ]]; then
            error "No interactive terminal. Specify machine: ob deploy-to-qemu <machine>"
            exit 3
        fi
        local pm_rc=0
        pick_machine machine_state_initialized_machines "Deploy to QEMU" || pm_rc=$?
        exit_on_user_cancel "$pm_rc" "Deploy to QEMU"
    fi

    BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"
    SOURCE_MANIFEST_FILE="$CONFIGS_DIR/openbmc-source.manifest"

    # ── 前置: init-done (约束: 前置 = init-done) ──
    if ! machine_state_is_initialized "$MACHINE"; then
        error "Machine '$MACHINE' has not been initialized."
        error "Run 'ob init $MACHINE' first."
        exit 3
    fi

    # ── DRY-RUN 短路(评审 Y2: 前移到探测 QEMU 前, 避免 DRY-RUN + QEMU 在跑时弹 confirm 交互;
    #   与 cmd_build 的 confirm→DRY-RUN 顺序不同——deploy 的 confirm 触发条件是"QEMU 在跑",
    #   DRY-RUN 应早于 confirm 保持"不执行任何动作/不交互"契约。
    #   v3/G-new2: 前移后 DRY-RUN 也不探测 QEMU / 不读旧端口 / 不弹 banner, 输出仅 notice 一行) ──
    if [[ "$DRY_RUN" -eq 1 ]]; then
        notice "[DRY-RUN] would bitbake obmc-phosphor-image + restart QEMU for '$MACHINE'" >&2
        exit 0
    fi

    derive_qemu_paths   # 算 QEMU_PID_FILE 等 (qemu.sh:6)

    # ── 探测 QEMU 在跑 + 预读旧端口(必须在 stop 前, 约束 2) ──
    local qemu_running=0
    local old_ssh_port="" old_redfish_port="" old_ipmi_port="" old_http_port=""
    if qemu_instance_load "$MACHINE"; then
        qemu_instance_is_alive "$PIDFILE_PID" "$PIDFILE_BINARY" "$PIDFILE_MACHINE"
        local pid_status=$?
        if [[ $pid_status -eq 0 ]]; then
            qemu_running=1
            old_ssh_port="$PIDFILE_SSH_PORT"
            old_redfish_port="$PIDFILE_REDFISH_PORT"
            old_ipmi_port="$PIDFILE_IPMI_PORT"
            old_http_port="$PIDFILE_HTTP_PORT"
        else
            qemu_instance_clean_stale "$MACHINE"
        fi
    fi

    # ── confirm: 仅 QEMU 在跑时 banner (约束 4, 路径风险原则) ──
    if [[ $qemu_running -eq 1 ]]; then
        echo ""
        warn "QEMU instance running for '$MACHINE' — deploy will kill it, rebuild image, and restart."
        qemu_instance_summarize_full
        print_confirm_banner "rebuild image and restart QEMU for" "$MACHINE"
        local answer
        if ! read -r -p "$(echo -e "${PROMPT_PREFIX} Kill + rebuild + restart? [y/N]: ")" answer; then
            exit 1
        fi
        [[ "$answer" == [yY] ]] || { info "Aborted."; exit 2; }
    fi

    # ── Step 1: build (build-first, 约束 3 — QEMU 在跑也不停) ──
    echo ""
    step_header "Building $MACHINE (image rebuild)"
    info "Running: bitbake obmc-phosphor-image"
    info "Estimated time: 1-4 hours depending on machine and cache state."

    build_env_enter "$MACHINE" "$BUILD_DIR" 2>/dev/null
    resolve_npm_registry
    # npm vars export(复用 cmd_build :343-358, ~20 行; 技术债: 后续抽 build_obmc_image helper)
    if [[ "$NPM_REGISTRY_RESOLVED" != "skip" ]]; then
        export npm_config_registry="$NPM_REGISTRY_RESOLVED"
        export npm_config_fetch_timeout=600000
        export npm_config_fetch_retry_maxtimeout=120000
        export npm_config_fetch_retry_mintimeout=30000
        export npm_config_fetch_retry_factor=2
        local _npm_vars="npm_config_registry npm_config_fetch_timeout npm_config_fetch_retry_maxtimeout npm_config_fetch_retry_mintimeout npm_config_fetch_retry_factor"
        local _existing="${BB_ENV_PASSTHROUGH_ADDITIONS:-}"
        BB_ENV_PASSTHROUGH_ADDITIONS="$_npm_vars"
        [[ -n "$_existing" ]] && BB_ENV_PASSTHROUGH_ADDITIONS="$_existing $BB_ENV_PASSTHROUGH_ADDITIONS"
        export BB_ENV_PASSTHROUGH_ADDITIONS
    fi

    if ! bitbake obmc-phosphor-image; then
        echo ""
        step_header "Build Failed"
        error "bitbake failed — image not rebuilt, QEMU unchanged (build-first)."
        exit 1                       # 约束 3: build 失败 QEMU 不动
    fi

    # ── build 成功 stage 标记(约束 6; 评审 Y3: 简化版——只 Machine/Image 两行) ──
    #   cmd_build 的 Size/Deploy 行不复制——deploy 语境已隐含 build 成功 + 即将重启,
    #   size/deploy dir 冗余; 若未来要 build 族输出对称再复刻(技术债)。
    local image_file=""
    image_file=$(machine_state_firmware_image_path "$MACHINE" 2>/dev/null || true)
    step_header "Image Rebuilt"
    echo "  Machine: $MACHINE"
    echo "  Image  : ${image_file:-<not found>}"

    # ── Step 2: stop 旧 QEMU(若在跑) + 端口复用注入(约束 2) ──
    if [[ $qemu_running -eq 1 ]]; then
        echo ""
        warn "Stopping old QEMU (PID $PIDFILE_PID)..."
        qemu_instance_stop "$PIDFILE_PID" "$QEMU_PID_FILE"
        info "Old QEMU stopped."
        QEMU_SSH_PORT="$old_ssh_port"
        QEMU_REDFISH_PORT="$old_redfish_port"
        QEMU_IPMI_PORT="$old_ipmi_port"
        [[ -n "$old_http_port" && "$old_http_port" != "none" ]] && QEMU_HTTP_PORT="$old_http_port"
    fi

    # ── Step 3: start 新 QEMU(端口复用) + 恢复引导(约束 5/6) ──
    echo ""
    step_header "Starting new QEMU for '$MACHINE'"
    info "If start fails, image is already rebuilt — recover manually: ob start-qemu $MACHINE"

    qemu_prepare_launch "$MACHINE" "$image_file"
    echo "  Machine   : $QEMU_LAUNCH_MACHINE_NAME"
    echo "  SoC       : $QEMU_LAUNCH_SOC_TYPE"
    echo "  Binary    : $QEMU_BIN_FILE"
    echo "  Image     : $image_file"
    echo "  Serial log: $QEMU_LAUNCH_SERIAL_LOG"
    echo ""

    qemu_execute_launch        # setsid + PID 写 + BMC-ready 等待(超时 warn 不 exit) + hostkey + summary
    # 到此 exit 0(QEMU 启动即成功, 约束 5); setsid 失败时 execute_launch 自己 exit 1
}
```

  - Change: 替换 T1 空壳为完整编排（自带 build-first + 端口复用 + confirm + stage 标记 + 恢复引导）。

- [ ] Step 2: 运行并确认通过（T2 7 场景全绿）
  - Run: `bash tests/orchestration/deploy_to_qemu.sh && test $? -eq 0`
  - Expected: 7 场景全过（exit 0）。若某场景红：
    - ② 端口复用断言红 → 查 `QEMU_SSH_PORT` 注入时序（必须在 stop 后、prepare_launch 前）。
    - ③ build-first 红 → 查 build 失败分支是否误调 `qemu_instance_stop`（应不调）。
    - ⑤ 恢复引导红 → 查 `ob start-qemu` 文本在 `qemu_execute_launch` 之前打印。
    - ① 无 banner 红 → 查 `qemu_running=0` 路径是否误进 confirm 块。

- [ ] Step 3: 跑 ob_check.sh 全套（约束 10）
  - Run: `tools/ob_check.sh; test $? -eq 0`
  - Expected: `ALL GREEN`（含 extract_funcs commands.sh 三段清 / shellcheck baseline CLEAN 或 REGEN 良性 / exit_contract X/Y/Z green——deploy-to-qemu 在 commands.sh exit seam，X 合法 / run_all 绿）。

- [ ] Step 4: 跑 run_all --full（含 protocol .exp）
  - Run: `bash tests/run_all.sh --full; test $? -eq 0`
  - Expected: ALL GREEN（protocol 含 usage_dispatch_sync + .exp / unit / orchestration 含新 deploy_to_qemu.sh）。

- [ ] Step 5: Commit checkpoint
  - Run: `git add lib/commands.sh tests/orchestration/deploy_to_qemu.sh && git commit -m "$(cat <<'EOF'
feat(deploy): ob deploy-to-qemu — image rebuild + QEMU restart for clean verification

Add cmd_deploy_to_qemu (lib/commands.sh) as ob top-level QEMU lifecycle command
(sibling of start-qemu/stop-qemu). Self-contained orchestration over low-level
modules (build_env_enter/bitbake/qemu_instance_*/qemu_prepare_launch/qemu_execute_launch),
no cmd_* changes. build-first: bitbake obmc-phosphor-image → if running, read old
.pid ports + qemu_instance_stop + inject QEMU_*_PORT for port-reuse → start; not
running → build + start. exit 0/1/2/3 (0 = image rebuilt + QEMU started; BMC-ready
timeout stays warn). confirm banner only when QEMU running (path-risk per
confirmation banner term). stage markers + recovery hint. Ownership per ADR-0011.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"`
  - Expected: commit 成功。

---

### Task T4: integration e2e（gate --integration）

- 目标：真实 build + 真起 QEMU + BMC ready 端到端，gate `--integration`（默认不跑），SKIP 门 exit 77（无 init machine）。
- Files:
  - Create: `tests/integration/ob_deploy_to_qemu.sh`
- 验证范围：`bash tests/integration/ob_deploy_to_qemu.sh` —— 无 init machine → exit 77 SKIP（不假失败）；有 env → exit 0 + 新 image 在跑 + BMC SSH ready。
- 接口契约:
  - Consumes: 完整 `ob deploy-to-qemu`（T3）。
  - Produces: 无（integration 锦上添花，gate --integration）。

- [ ] Step 1: 确认文件不存在（改动前可观察缺失）
  - Run: `test ! -f tests/integration/ob_deploy_to_qemu.sh && test $? -eq 0`
  - Expected: exit 0（文件不存在，待 Step 2 创建）。文件还不存在时跑它只会得 127（command-not-found 语义），无观察价值——用 `test ! -f` 断言缺失本身。

- [ ] Step 2: 写 integration 测试 `tests/integration/ob_deploy_to_qemu.sh`
  - 照 `tests/integration/ob_dev.sh` SKIP 门模式（无 init machine → `echo "SKIP: ..."; exit 77`，run_all.sh [:30-41](tests/run_all.sh#L30) 认 rc=77 + `SKIP:` 为合法跳过）。
  - 流程：探测 initialized machine（romulus / b865g8-bytedance 优先）；无 → `echo "SKIP: no initialized machine for deploy-to-qemu integration"; exit 77`。有 → `./ob deploy-to-qemu "$MACHINE"`；断言 exit 0 + 新 image（`machine_state_firmware_image_path` 存在）+ BMC SSH ready（`sshpass -p 0penBmc ssh -p <port> root@localhost echo OK`，端口从新 `.pid` 读）。
  - 注意：integration 真跑 1-4h build + 占端口，仅 `--integration` 触发；断言 exit 0（deploy 成功 = image 重建 + QEMU 启动；BMC ready 是 boot 过程，超时 warn 不算 deploy 失败，但 integration 可额外探 BMC SSH 作信心检查，失败 warn 不 exit 1）。
  - Change: 新建 integration 测试（SKIP 门 + e2e 断言）。

- [ ] Step 3: 运行确认 SKIP（无 env）或 e2e（有 env）
  - Run: `bash tests/integration/ob_deploy_to_qemu.sh >/dev/null 2>&1; rc=$?; test "$rc" -eq 77 -o "$rc" -eq 0`
  - Expected: rc=77（SKIP，无 init machine，合法）或 rc=0（有 env，e2e 绿）。rc=1 → e2e 失败，查 deploy 编排。

- [ ] Step 4: 可选 checkpoint commit
  - Run: `git add tests/integration/ob_deploy_to_qemu.sh && git commit -m "test(deploy): ob deploy-to-qemu integration e2e (gate --integration)"`
  - Expected: commit 成功。

---

### Task T5: 文档收尾 + 最终验证

- 目标：WORKSPACE ob 条目补 deploy-to-qemu；跑全套最终验证；输出修改摘要。
- Files:
  - Modify: `rules/03_WORKSPACE.md`（ob 条目 [:10](rules/03_WORKSPACE.md#L10) 补 `deploy-to-qemu`）
- 验证范围：全套 `tools/ob_check.sh` + `tests/run_all.sh --full` + （可选）`--integration`。
- 接口契约:
  - Consumes: T1-T4 全部产出。
  - Produces: 无（收尾）。

- [ ] Step 1: WORKSPACE ob 条目补 deploy-to-qemu
  - `rules/03_WORKSPACE.md` [:10](rules/03_WORKSPACE.md#L10) ob 条目（`./ob init [<machine>]` 一键初始化；`./ob dev ...`）补 `./ob deploy-to-qemu [<machine>]`（image 级重建 + QEMU 重启，干净验证；与 ob dev build 正交）。
  - Change: WORKSPACE 路由表补 deploy-to-qemu。

- [ ] Step 2: 最终全套验证
  - Run: `tools/ob_check.sh && bash tests/run_all.sh --full && test $? -eq 0`
  - Expected: `ob_check.sh` ALL GREEN + `run_all --full` ALL GREEN（protocol/unit/orchestration + .exp 全绿，含新 deploy_to_qemu.sh 7 场景 + usage_dispatch_sync deploy-to-qemu 登记）。

- [ ] Step 3: 抽检端口复用 + exit 契约
  - Run: `./ob --help | grep -q deploy-to-qemu && ( cd "${TMPDIR:-/tmp}" && env -u MACHINE ./ob deploy-to-qemu </dev/null >/dev/null 2>&1; test $? -eq 3 )`
  - Expected: `--help` 含 deploy-to-qemu（grep -q exit 0）；无 machine 非 TTY → exit 3（前置缺失，"No interactive terminal" 或 "No initialized machines"）。评审 G2：`cd ${TMPDIR:-/tmp}` + `env -u MACHINE` 隔离干净 shell，避免已有 machine 环境跑成 exit 0/2。

- [ ] Step 4: （可选）integration 验证
  - Run: `bash tests/run_all.sh --integration; rc=$?; test "$rc" -eq 0 -o "$rc" -eq 1`
  - Expected: ALL GREEN（含 integration ob_deploy_to_qemu.sh，有 env）或 integration 层 SKIP（无 env，rc=1 因其他 integration 也 SKIP/失败——看输出确认 ob_deploy_to_qemu.sh 自身 rc=77 SKIP 非 FAIL）。

- [ ] Step 5: 最终 commit + 修改摘要
  - Run: `git add rules/03_WORKSPACE.md && git commit -m "docs(workspace): register ob deploy-to-qemu in routing table"`
  - Expected: commit 成功。
  - 输出修改摘要：5 任务、新文件（cmd_deploy_to_qemu 编排 + 2 测试）、改动文件（ob 接线 / usage_dispatch_sync / WORKSPACE）、exit 契约、端口复用 + build-first 不变量测试覆盖。

---

## 执行纪律

- 开始实现前，先批判性复查整份计划 + 设计文档；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 严格按 T1→T2→T3→T4→T5 顺序，不跳步、不合并、不改任务目标。T2 是 TDD 红灯基线（对 T1 空壳失败），T3 让 T2 过——T2 不先写则 T3 无回归锁。
- 每任务 Step 的验证（Run 结尾用 `test`/`grep -q`/`! grep` 收尾，不让 echo/tail 吞 rc）必须过才进下一任务。
- 遇阻塞、重复失败或计划与仓库现实不符，立即停下说明，不猜。
- 当前分支 `feature/ob-dev-build`（未合并 main）。deploy-to-qemu 应另开分支：开始 T1 前与用户确认 `git checkout -b feature/ob-deploy-to-qemu`（从 main 或 feature/ob-dev-build 分叉，视合并策略——见设计文档"合并策略"）。
- 每任务 Step checkpoint commit 可选；T3 Step 5（编排实现）+ T5 Step 5（文档收尾）是强制自然边界。
- 改 ob/lib 后每任务跑 `tools/ob_check.sh`（约束 10）。

## 最终验证

全部任务完成后（Linux + bash）：

- Run: `tools/ob_check.sh && test $? -eq 0`
  - Expected: `ALL GREEN (PASS=…)`，含 extract_funcs commands.sh 三段清（cmd_deploy_to_qemu header/函数体/footer）/ shellcheck baseline CLEAN 或 REGEN（良性则 `git diff tests/.shellcheck-baseline` 确认）/ exit-contract X/Y/Z green（deploy-to-qemu 在 commands.sh exit seam，X 合法；无新 leaf-pure basename）/ run_all 绿。
- Run: `bash tests/run_all.sh --full && test $? -eq 0`
  - Expected: ALL GREEN（protocol 含 usage_dispatch_sync deploy-to-qemu 登记 + .exp / unit / orchestration 含 deploy_to_qemu.sh 7 场景）。
- Run: `bash tests/run_all.sh --integration`（若环境有 init machine）
  - Expected: integration ob_deploy_to_qemu.sh e2e 绿（或 exit 77 SKIP，合法）。
- Run: `./ob --help | grep -q deploy-to-qemu && test $? -eq 0`
  - Expected: usage Commands 段含 `deploy-to-qemu [<machine>]`。
- 抽检端口复用：T3 场景 ② orchestration 断言新 `.pid` `ssh_port=2222`（端口复用不变量）已在测试 lock。
- 抽检 build-first：T3 场景 ③ orchestration 断言 build 失败 fake_qemu 仍存活（build-first 不变量）已在测试 lock。
- 输出修改摘要：5 任务 commits、新文件（lib 无新文件——cmd_deploy_to_qemu 加进 commands.sh；tests/orchestration/deploy_to_qemu.sh + tests/integration/ob_deploy_to_qemu.sh）、改动文件（commands.sh / ob / usage_dispatch_sync.sh / WORKSPACE.md）、exit 契约 0/1/2/3、端口复用 + build-first 不变量覆盖、CONTEXT/ADR-0011/workflow_02（已落）。

## 审阅 Checkpoint

实施计划已写好并保存到 `docs/plans/2026-07-20-ob-deploy-to-qemu-implementation-plan.md`，完成 inline 自检。请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行（建议另开 `feature/ob-deploy-to-qemu` 分支）。审阅通过前不进入实现。
