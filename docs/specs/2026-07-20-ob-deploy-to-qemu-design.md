# ob deploy-to-qemu 设计文档

Status: 草案（grill-with-docs 共识，2026-07-20，待 writing-plans）

Date: 2026-07-20

## 修订记录

- v1：grill-with-docs 共识初稿。shared understanding v2 的 10 条核心决策（前轮 grilling，2026-07-19/20）+ 本轮 4 个开放点（实现架构 / build-stop 顺序 / 错误处理 / 测试策略）经一对一 grilling 锁定。17 条决策零未决。
- v2（plan review feedback，2026-07-20）：同步实施计划评审 Y2/Y3 的伪代码精化。Y2：DRY-RUN 短路前移到探测 QEMU **之前**（避免 DRY-RUN + QEMU 在跑时弹 confirm 交互——与 cmd_build 的 confirm→DRY-RUN 顺序不同，理由：deploy 的 confirm 触发条件是"QEMU 在跑"，DRY-RUN 应早于 confirm 保持"不执行任何动作/不交互"契约）。Y3：Image Rebuilt stage 明确**简化版**（只 Machine/Image 两行，不复制 cmd_build 的 Size/Deploy 行，deploy 语境冗余）。
- v3（plan review round-2 🟢 收尾，2026-07-20）：Y-new（控制流图 :272-280 DRY-RUN 顺序与伪代码对齐——`[DRY_RUN] notice + exit 0` 前移到 `init-done` 后、`qemu_instance_load` 前；原滞后位置删除，消除"伪代码 vs 控制流图"矛盾）。G-new2（DRY-RUN 前移的下游影响写入注释：DRY-RUN 时也不探测 QEMU / 不读旧端口 / 不弹 banner，输出仅 notice 一行——行为变更点显式化）。

## 背景与目标

[ob dev build](../../rules/skills/workflow_02-obmc_dev_modify.md)（commit 7cd255a，feature/ob-dev-build 分支）补了 `modify → finish` 之间的单 recipe 内循环编译洞——`ob dev --machine <m> build <recipe>` 在 build env 里跑 `devtool build <recipe>`（秒-分钟，recipe 级）。但 build 是 recipe 级，**不重建整个 image**：改完代码单 recipe 编通了，BMC 上跑的还是旧 image。

开发者的完整内循环是：改 recipe 源码 → 单 recipe 编译验证（`ob dev build`）→ **image 级重建 + QEMU 重启验证新代码** → finish 落回。第三步目前没有 ob 路径——开发者被迫手动 `ob build`（1-4 小时）+ `ob stop-qemu` + `ob start-qemu` 三步跳出 ob 编排，且端口不复用（每次 `start-qemu` 默认 2222，撞上残留则要改端口）。

`ob deploy-to-qemu` 补这个洞：一键 image 级重建 + QEMU 重启，做"干净验证"。

**干净验证 = 明确拒绝 recipe hot push**（`devtool deploy-target` 那套）——热推让 BMC 半新半旧（推了的 recipe 是新的，没推的还是旧的，依赖链不一致），验证不权威。用户明确接受 image 重启的时间（最多十几分钟 stop+start）换取状态干净的权威验证（用户原话："为了避免新编译的 recipe 注入正在跑的 QEMU OPENBMC instance，会有状态不干净的问题，导致验证结果不权威，我个人是偏向于接受 image 重启的时间的"）。

### 成功标准

- `ob deploy-to-qemu <machine>` 重建整个 image（`bitbake obmc-phosphor-image`）+ 重启 QEMU（若在跑则 stop + start 端口复用；没跑则 start），让新代码在 QEMU 上跑起来。
- QEMU 在跑时**复用旧端口**（新 QEMU 的 ssh/redfish/ipmi/http 端口 == 旧实例的），不打乱用户的连接配置。
- exit-code 契约：0 = 成功（image 重建 + QEMU 启动），1 = 失败（build / setsid 失败），2 = 用户取消（banner 拒绝），3 = 前置缺失（machine 未 init）。
- 改 `ob` / `lib/*.sh` 后过 `tools/ob_check.sh` 全套自检（结构 / 函数登记 / shellcheck baseline / exit_contract / run_all）。
- `ob --help` 列出 `deploy-to-qemu`，描述指向"验证"。

## 范围

- 新增 `lib/commands.sh::cmd_deploy_to_qemu`（L1 exit seam，与 `cmd_start_qemu` / `cmd_stop_qemu` 同级）。
- `ob` 主入口：usage 加 `deploy-to-qemu` 行 + `parse_args` case + `main` dispatch。
- `tests/orchestration/` 加 deploy-to-qemu 编排测试（7 场景）。
- `tests/protocol/usage_dispatch_sync.sh` 加 deploy-to-qemu 登记块。
- `tests/integration/` 加 deploy-to-qemu e2e（gate `--integration`）。
- `CONTEXT.md` 加 `ob deploy-to-qemu` 术语。
- `rules/skills/workflow_02-obmc_dev_modify.md` 补完整验证链（modify → build → **deploy-to-qemu** → finish）。
- `docs/adr/0011-ob-deploy-to-qemu-toplevel-ownership.md`（deploy 归属）。

## 非范围

- **recipe hot push（`devtool deploy-target`）**：拒绝。热推状态不干净、验证不权威（决策 2）。
- **service restart**：不碰。recipe→service 映射是非平凡问题（recipe 名 ≠ service 名，如 `phosphor-ipmi-host` → `xyz.openbmc_project.Ipmi.Host`），是当初否决"自动 restart"方案的核心原因。deploy-to-qemu 重建整个 image，service 随 QEMU 重启自然重启。
- **真机部署**：v1 只 QEMU（community OpenBMC QEMU image，SSH 凭证硬编码 root / `0penBmc`）。真机要新建 target 配置模型（凭证 / 传输 / 认证），独立工作项。
- **端口 flag（`--ssh-port` 等）**：v1 无 flag，端口复用旧 `.pid` 或默认。`start-qemu` 已有 flag，deploy-to-qemu v1 不暴露（YAGNI）。
- **advisory next-step（`ob dev build` 成功后提示 `deploy-to-qemu`）**：不做。`ob dev build` 是 agent-facing（空 stdout 契约），agent 不保证读 stderr，advisory 不可靠（决策 8）。agent 衔接走 workflow_02 + `ob --help` + CONTEXT。
- **build task 参数 / image 类型选择**：v1 固定 `obmc-phosphor-image`。
- **`ob dev deploy`**：stub 已退役（commit a0837c4），不复活。

## 方案比较（本轮 grill 决策）

### 实现架构（开放点 1）— 自带编排，调底层 module（采纳）

deploy-to-qemu 编排 build + stop + start。三个动作的现状分三层（代码事实）：

| 层 | 函数 | 性质 |
|---|---|---|
| L1 cmd_* | `cmd_build` [commands.sh:259-420](lib/commands.sh#L259)、`cmd_start_qemu` [:422-560](lib/commands.sh#L422)、`cmd_stop_qemu` [:562-682](lib/commands.sh#L562) | 含 machine 交互选择 + confirm_action + DRY_RUN + exit；**bitbake 调用内联在 cmd_build**（无独立 build helper） |
| direct-exit module | `qemu_prepare_launch` / `qemu_execute_launch` [qemu.sh:86](lib/qemu.sh#L86)/[121](lib/qemu.sh#L121) | `check_ports_available` 占用 exit 3、setsid 失败 exit 1、BMC-ready 超时只 warn [:188-190](lib/qemu.sh#L188) |
| leaf-pure module | `build_env_enter`、`qemu_instance_load` / `is_alive` / `stop` / `clean_stale` [qemu_instance.sh](lib/qemu_instance.sh) | 返回码，不 exit |

- **选项 C（采纳）**：deploy-to-qemu 自带编排，直接调底层 module（`build_env_enter` + `bitbake` + `qemu_instance_load`/`stop` + `qemu_prepare_launch` + `qemu_execute_launch`），不碰 cmd_*。零重构（cmd_* 行为风险为零），编排 / 端口复用 / 错误处理完全自控，与上一轮 ob dev build 的 `devtool_build_run` 自带编排模式同构。
- 选项 A（拒）：编排 cmd_*。cmd_* 重复弹 confirm_action + 3 秒倒计时；`cmd_start_qemu` 冲突块（[:485-523](lib/commands.sh#L485)）与 deploy 的 stop 语义重叠，且端口复用注入不进去（冲突块不读 `.pid` 端口）；cmd_* exit 是命令级，build 后无法续接 stop+start。
- 选项 B（拒）：抽 cmd_* 核心成 leaf-pure helper（像 `dev_relay_result`），cmd_* 和 deploy-to-qemu 共用。重构面大（cmd_build 163 行 + cmd_start_qemu 140 行拆分，要保字节级行为不变的回归锁），独立深化工作项；cmd_build 的 bitbake 核心仅 ~20 行，抽取收益小、YAGNI 风险高。

**代价**：bitbake 调用 + npm registry export + image 信息打印 ~20 行与 `cmd_build` 重复，后续可抽 `build_obmc_image` leaf helper 消除（技术债，见下）。

### confirm 策略（开放点 1 子决策）— 仅 QEMU 在跑时 banner（采纳）

遵循 [CONTEXT.md](../../CONTEXT.md) `confirmation banner` 术语的"路径风险"原则：

- QEMU 没跑：直接 build + start，**无 banner**（显式快路径，与 `ob build <machine>` / `ob start-qemu <machine>` 显式一致）。
- QEMU 在跑：弹 confirmation banner（告知将 kill 运行中 QEMU + build + restart），确认后执行。

只有 kill 运行实例这条误伤风险路径才 banner，与 `cmd_start_qemu` 冲突块（[:499-513](lib/commands.sh#L499)，TTY 确认 kill+restart）模式一致。严格遵循已有术语，**无需新术语 / ADR**。

### build/stop 顺序（开放点 2）— build-first（采纳）

build → 成功 → 在跑则读旧端口 + stop + start / 没跑则 start。build 失败 exit 1，**旧 QEMU 不动**（环境不中断）。

- **文件安全性**：build 期旧 QEMU 持有 image fd（[qemu.sh:65](lib/qemu.sh#L65) `-drive file=$image_file,format=raw,if=mtf`），bitbake 覆盖 deploy dir 的 image。yocto image deploy 多用 `cp`（truncate+write 覆盖）→ 旧 QEMU 读半新半旧可能 crash；若 `mv`（rename）→ 旧 QEMU 读旧 inode 不受影响。**无论哪种，deploy 语义下用户不在 build 期用旧 QEMU 验证（旧 QEMU 是旧代码），crash 无害**（反正要 stop 重启），`is_alive` 兜底（crash 后 PID 文件残留，下次 deploy 走 stale clean 路径）。
- **build 失败恢复**：build-first 失败 → 旧 QEMU 仍在（环境不中断，用户可继续用旧环境）；build-before-stop 失败 → QEMU 已停（手动 `start-qemu` 恢复）。用户"接受十几分钟重启"指 stop+start 那段，不是 build 1-4h——build-first 让 QEMU 尽量保持可用，符合心智。

### 成功边界（开放点 3a）— QEMU 启动即成功（采纳）

exit 0 = build 成功 + QEMU setsid 启动（PID 写入）。BMC-ready 超时**只 warn**，仍 exit 0（BMC 可能还在 boot，150s 不够）。exit 1 = build 失败 / setsid 失败。

- 沿用 `qemu_execute_launch` 现状（BMC-ready 超时 warn 不 exit，[qemu.sh:188-190](lib/qemu.sh#L188)），**零改动 qemu.sh**，不影响 cmd_start_qemu（也调 execute_launch）。
- 语义：deploy 核心交付 = 新 image 在 QEMU 上跑起来；BMC ready 是 boot 过程，慢不代表 deploy 失败；用户 SSH 自查。
- 拒"BMC ready 才算成功"：要么改 qemu.sh 让 ready 回传（影响 cmd_start_qemu 行为），要么 deploy-to-qemu 自探 BMC（重复轮询）；150s 不够时 exit 1 误导（image 重建 + QEMU 起来了，只是 boot 慢）。

### 部分成功诊断（开放点 3b）— stage 标记 + 恢复引导（采纳）

build 成功后打 `[Image Rebuilt]`（**简化版 Machine/Image 两行**，不复制 cmd_build 的 Size/Deploy——v2/Y3：deploy 语境已隐含 build 成功 + 即将重启，size/deploy dir 冗余）→ stop 后打 `[Old QEMU stopped]`（PID + 端口释放）→ start 前打 `[Starting new QEMU]` + **恢复引导**（"失败可手动 `ob start-qemu <machine>` 恢复"）。start 失败时 `qemu_execute_launch` exit 1，但用户已看到 stage 标记 + 恢复引导，能定位是 start 阶段 + 知道 image 是新的。

`qemu_execute_launch` 是 direct-exit module，setsid 失败时它自己 exit 1，deploy-to-qemu 无法在它 exit 后再打印——所以恢复引导必须在 start **之前**的 stage 标记里给。

与 `cmd_build` / `cmd_start_qemu` 的 step_header 模式一致，符合 porcelain 用户交互式（stdout 透传进度）。

### 回滚（开放点 3c）— 不回滚（采纳）

ob 现有命令无回滚传统。best-effort 编排：失败即停，**不回滚 image**（bitbake 也不支持回滚到旧 image）。诊断引导手动恢复。与 `cmd_build`（bitbake 失败 exit 1 不回滚）一致。

### 测试策略（开放点 4）

- **protocol**：`usage_dispatch_sync.sh` 加 deploy-to-qemu 块（usage 含 deploy-to-qemu + parse_args handoff + main dispatch）+ `exit_codes.sh`。
- **unit**：**不加新测试**——编排逻辑在 L1 cmd_deploy_to_qemu（副作用密集），纯函数少；`qemu_instance.sh` 已测 load / is_alive / stop。端口复用解析（load 读 `PIDFILE_SSH_PORT` → 设 `QEMU_SSH_PORT`）一行赋值，不值得抽 helper。
- **orchestration（主测试）**：7 场景，复用 `cmd_build_bitbake_handoff` + `start_qemu_force_restart` + `qemu_execute_launch` 的 stub 套路（`tests/lib/stub.sh` + `qemu_stubs.sh`）。
- **integration**：完整 e2e（build + stop + start + BMC ready），gate `--integration`，复用 `build_e2e.exp` infrastructure + `ob_dev.sh` 的 SKIP 门（exit 77）。

## 推荐方案

`cmd_deploy_to_qemu` 自带编排伪代码（选项 C，调底层 module）：

```bash
cmd_deploy_to_qemu() {
    detect_harness_root

    # ── Resolve machine ── (同 cmd_start_qemu :422-460 模式)
    if [[ -z "$MACHINE" ]]; then
        local -a machines=()
        local _machine
        while IFS= read -r _machine; do
            [[ -n "$_machine" ]] && machines+=("$_machine")
        done < <(machine_state_initialized_machines)   # init-done 即可(不要求 image-ready, deploy 自己 build)

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

    # ── 前置: init-done ──
    if ! machine_state_is_initialized "$MACHINE"; then
        error "Machine '$MACHINE' has not been initialized."
        error "Run 'ob init $MACHINE' first."
        exit 3
    fi

    # ── DRY-RUN 短路(v2/Y2: 前移到探测 QEMU 前, 避免 DRY-RUN + QEMU 在跑时 confirm 交互;
    #   与 cmd_build 的 confirm→DRY-RUN 顺序不同——deploy confirm 触发条件是"QEMU 在跑",
    #   DRY-RUN 应早于 confirm 保持"不执行任何动作/不交互"契约。
    #   v3/G-new2: 前移后 DRY-RUN 也不探测 QEMU / 不读旧端口 / 不弹 banner, 输出仅 notice 一行) ──
    if [[ "$DRY_RUN" -eq 1 ]]; then
        notice "[DRY-RUN] would bitbake obmc-phosphor-image + restart QEMU for '$MACHINE'" >&2
        exit 0
    fi

    derive_qemu_paths   # 算 QEMU_PID_FILE 等(qemu.sh:6)

    # ── 探测 QEMU 是否在跑 + 端口复用预读(必须在 stop 前读, stop 会删 .pid) ──
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
            old_http_port="$PIDFILE_HTTP_PORT"          # .pid 里 http_port 可能是 "none"
        else
            qemu_instance_clean_stale "$MACHINE"         # stale(exited/recycled)PID 文件清理
        fi
    fi

    # ── confirm: 仅 QEMU 在跑时 banner(路径风险原则) ──
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

    # ── Step 1: build (build-first — QEMU 在跑也不停) ──
    step_header "Building $MACHINE (image rebuild)"
    info "Running: bitbake obmc-phosphor-image"
    info "Estimated time: 1-4 hours depending on machine and cache state."

    build_env_enter "$MACHINE" "$BUILD_DIR" 2>/dev/null          # cmd_build :339
    resolve_npm_registry                                            # cmd_build :342
    # ── npm vars export(复用 cmd_build :343-358, ~20 行; 技术债: 后续抽 build_obmc_image helper) ──
    if [[ "$NPM_REGISTRY_RESOLVED" != "skip" ]]; then
        export npm_config_registry="$NPM_REGISTRY_RESOLVED"
        # ... (同 cmd_build 的 fetch_timeout / retry 导出 + BB_ENV_PASSTHROUGH_ADDITIONS)
    fi

    if ! bitbake obmc-phosphor-image; then
        echo ""
        step_header "Build Failed"
        error "bitbake failed — image not rebuilt, QEMU unchanged (build-first)."
        exit 1                       # build-first: QEMU 状态不动(在跑则仍在跑旧 image)
    fi

    # ── build 成功 stage 标记(v2/Y3: 简化版——只 Machine/Image 两行; cmd_build 的 Size/Deploy 行不复制, deploy 语境冗余) ──
    local image_file=""
    image_file=$(machine_state_firmware_image_path "$MACHINE" 2>/dev/null || true)
    step_header "Image Rebuilt"
    echo "  Machine: $MACHINE"
    echo "  Image  : ${image_file:-<not found>}"

    # ── Step 2: stop 旧 QEMU(若在跑) + 端口复用注入 ──
    if [[ $qemu_running -eq 1 ]]; then
        echo ""
        warn "Stopping old QEMU (PID $PIDFILE_PID)..."
        qemu_instance_stop "$PIDFILE_PID" "$QEMU_PID_FILE"        # kill + 等 + SIGKILL 兜底 + 删 .pid
        info "Old QEMU stopped."
        # 端口复用: 旧端口设进 QEMU_*_PORT 全局(qemu_prepare_launch 的端口来源 CLI > env > default)
        QEMU_SSH_PORT="$old_ssh_port"
        QEMU_REDFISH_PORT="$old_redfish_port"
        QEMU_IPMI_PORT="$old_ipmi_port"
        [[ -n "$old_http_port" && "$old_http_port" != "none" ]] && QEMU_HTTP_PORT="$old_http_port"
    fi

    # ── Step 3: start 新 QEMU(端口复用) + 恢复引导 ──
    echo ""
    step_header "Starting new QEMU for '$MACHINE'"
    info "If start fails, image is already rebuilt — recover manually: ob start-qemu $MACHINE"

    qemu_prepare_launch "$MACHINE" "$image_file"                   # profile/binary/firmware/端口(check_ports)/build_cmd
    # 画像打印(复用 cmd_start_qemu :528-534)
    echo "  Machine   : $QEMU_LAUNCH_MACHINE_NAME"
    echo "  SoC       : $QEMU_LAUNCH_SOC_TYPE"
    echo "  Binary    : $QEMU_BIN_FILE"
    echo "  Image     : $image_file"
    echo "  Serial log: $QEMU_LAUNCH_SERIAL_LOG"
    echo ""

    qemu_execute_launch        # setsid + PID 写 + BMC-ready 等待(超时 warn 不 exit) + hostkey + summary
    # 到此 = exit 0(QEMU 启动即成功); qemu_execute_launch setsid 失败时它自己 exit 1
}
```

## 关键边界与组件职责

### `lib/commands.sh::cmd_deploy_to_qemu`（L1 exit seam，新增）

ob 顶层 QEMU 生命周期命令，与 `cmd_start_qemu` / `cmd_stop_qemu` 同族。自带编排 build + stop + start，调底层 module（不调 cmd_*）。exit-code 契约 0/1/2/3。用户交互式（stdout 透传 bitbake 日志 / QEMU 启动 / BMC-ready / 连接信息）。

### 端口复用机制

`.pid` 文件（[qemu_instance.sh:151-164](lib/qemu_instance.sh#L151) 写入，含 `ssh_port` / `redfish_port` / `ipmi_port` / `http_port`）是端口复用的数据源。机制链：

1. `qemu_instance_load <machine>` 读 `.pid` → 设 `PIDFILE_SSH_PORT` 等全局（[qemu_instance.sh:26-29](lib/qemu_instance.sh#L26)）。
2. **必须在 `qemu_instance_stop` 之前读**——stop 会删 `.pid`（[qemu_instance.sh:121](lib/qemu_instance.sh#L121)），删后端口丢失。
3. 读出的旧端口设进 `QEMU_SSH_PORT` 等全局变量——这是 `qemu_prepare_launch` 的端口来源最高优先级（`QEMU_SSH_PORT`(CLI) > `OB_QEMU_SSH_PORT`(env) > 2222，[qemu.sh:98-101](lib/qemu.sh#L98)）。
4. `qemu_prepare_launch` 用注入的 `QEMU_*_PORT` 装配 `QEMU_LAUNCH_*_PORT` + `check_ports_available`（此时旧 QEMU 已 stop，端口已释放，不撞）+ `build_qemu_cmd`。
5. `qemu_execute_launch` setsid 启动新 QEMU（复用旧端口）+ 写新 `.pid`（端口字段 == 旧）。

**http_port 特殊处理**：`.pid` 里 `http_port` 可能是字面 `none`（[qemu.sh:161](lib/qemu.sh#L161) `http_port=${QEMU_LAUNCH_HTTP_PORT:-none}`）——读出 `none` 时不设 `QEMU_HTTP_PORT`（保持空，prepare_launch 据此不加 http hostfwd）。

## 数据流 / 控制流

```
ob deploy-to-qemu <machine>
  → 前置: init-done(exit 3 否则)
  → [DRY_RUN] notice + exit 0   ← v2/Y2 前移到探测 QEMU 前(也不探测/不读端口/不交互; v3/Y-new 与伪代码对齐)
  → qemu_instance_load + is_alive
      ├─ 在跑(running): qemu_running=1, 预读 old_*_port
      ├─ stale(exited/recycled): clean_stale, qemu_running=0
      └─ 无 .pid: qemu_running=0
  → [qemu_running=1] confirm banner(kill+rebuild+restart)? exit 2 若拒绝
  → Step1 build:
      build_env_enter + resolve_npm_registry + bitbake obmc-phosphor-image
        ├─ 成功 → [Image Rebuilt] stage + image_file 解析
        └─ 失败 → exit 1(QEMU 不动, build-first)
  → [qemu_running=1] Step2 stop:
      qemu_instance_stop(kill old) + 注入 QEMU_*_PORT = old_*
  → Step3 start:
      [Starting new QEMU] + 恢复引导
      qemu_prepare_launch(复用旧端口, check_ports 此时端口已释放)
      qemu_execute_launch(setsid + PID 写 + BMC-ready warn + hostkey + summary)
        ├─ setsid 成功 → exit 0(QEMU 启动即成功)
        └─ setsid 失败 → execute_launch exit 1(诊断: serial log / binary)
```

**幂等**：再跑一次 `ob deploy-to-qemu <machine>` → 读到新 `.pid`（上次 start 写的）→ 在跑 → banner → stop + start（端口复用）。没跑 → build + start。两种路径都收敛。

## 错误处理与回退

| 阶段 | 失败 | exit | QEMU 状态 | 诊断 |
|---|---|---|---|---|
| 前置 | machine 未 init | 3 | 不动 | `Run 'ob init <machine>' first.` |
| confirm | 用户拒绝 banner | 2 | 不动 | `Aborted.` |
| Step1 build | bitbake 非零 | 1 | 不动（在跑则仍在跑旧 image） | bitbake 错误透传 stderr |
| Step2 stop | QEMU 卡死 kill -9 不死 | —（qemu_instance_stop best-effort 恒 0，删 .pid） | .pid 删但进程可能残留 | Step3 check_ports 可能 exit 3 端口冲突（罕见，沿用 cmd_stop_qemu 同行为） |
| Step3 start | setsid 失败 | 1（qemu_execute_launch exit） | image 已重建，QEMU 没起 | `Check serial log` / `Verify QEMU binary` + start 前给的恢复引导 `ob start-qemu <machine>` |
| Step3 BMC-ready | 超时（150s SSH 不通） | 0（warn） | QEMU 在跑（boot 中） | `BMC did not become SSH-ready... Check serial log` |

**部分成功**（build 成功 + start 失败）：image 已重建，QEMU 没起。用户从 stage 标记（`[Image Rebuilt]` + `[Starting new QEMU]`）+ 恢复引导知道"build 成功，是 start 挂了，手动 `ob start-qemu` 可恢复"。**不回滚 image**。

### porcelain stdout 契约

deploy-to-qemu 是**用户交互式**命令（非 agent-facing）：stdout 透传进度（step_header / info / bitbake 日志 / QEMU 启动 / BMC-ready / 连接 summary），exit code 承载成败（0/1/2/3）。与 `ob dev build`（agent-facing 空 stdout）**范式不同**——后者是 agent 编排的对象，前者是用户直接跑的命令。

## 测试策略

### Static gates

`tools/ob_check.sh`（改 ob/lib 后必跑）：结构 / 函数登记（`extract_funcs`）/ shellcheck baseline / `exit_contract`（deploy-to-qemu 在 `commands.sh` = exit seam，**不进** leaf-pure 配置）/ `run_all.sh`。

### protocol 层

- `tests/protocol/usage_dispatch_sync.sh`：加 deploy-to-qemu 登记块（usage 含 `deploy-to-qemu`；`parse_args deploy-to-qemu <machine>` MACHINE handoff；`main deploy-to-qemu <machine>` 真调 cmd_deploy_to_qemu）。
- `tests/protocol/exit_codes.sh`：deploy-to-qemu exit 0/1/2/3 契约（若该文件覆盖顶层命令 exit 矩阵）。

### orchestration 层（主测试）

复用 `tests/orchestration/start_qemu_force_restart.sh` + `cmd_build_bitbake_handoff.sh` + `qemu_execute_launch.sh` 的 stub 套路（`tests/lib/stub.sh` `mkfake_bin`/`stub_script`/`stub_exit` + `tests/lib/qemu_stubs.sh` `make_qemu_curl_fake`/`make_bitbake_env_fake`/`make_setsid_sentinel`/`make_pgrep_fake` + `OB_ENTRY_DIR=$TMP` 假 harness root + fake_qemu sleep 300 + `.pid` 文件含 ssh_port）。

7 场景（新文件 `tests/orchestration/deploy_to_qemu.sh`）：

1. **QEMU 没跑 + build 成功 → start（无 banner）**：无 `.pid`；bitbake stub 成功；setsid sentinel；断言 exit 0 + setsid 被调 + PID 文件写入 + 无 confirm banner 文本。
2. **QEMU 在跑 + build 成功 → banner → stop(kill fake_qemu) → start（端口复用）**：staged fake_qemu + `.pid` ssh_port=2222；bitbake 成功；`<<<y\n` 喂 confirm；断言 exit 0 + fake_qemu 被 kill + **新 `.pid` ssh_port == 2222（端口复用不变量）**。
3. **build 失败 → exit 1（build-first 不变量：fake_qemu 未被 kill，QEMU 不动）**：staged fake_qemu；`stub_exit bitbake 1`；断言 exit 1 + **fake_qemu 仍存活（kill -0 成功）** + bitbake 调用计数 1 + 未到 prepare_launch。
4. **confirm 拒绝 → exit 2**：staged fake_qemu；`<<<n\n`；断言 exit 2 + fake_qemu 仍存活 + 未调 bitbake。
5. **部分成功（build 成功 + start setsid 失败）→ exit 1 + stage 标记**：bitbake 成功；setsid stub 返非零（模拟启动失败）；断言 exit 1 + 输出含 `Image Rebuilt` + 含恢复引导 `ob start-qemu`。
6. **前置 init-done 缺失 → exit 3**：无 `.init-done` marker；断言 exit 3 + stderr 含 `ob init`。
7. **DRY_RUN → notice + exit 0**：`DRY_RUN=1`；断言 exit 0 + 输出含 `[DRY-RUN]` + 未调 bitbake / setsid。

**端口复用断言**（场景 2）是 deploy-to-qemu 独有不变量——lock 新 `.pid` 的 `ssh_port` 字段 == 旧，防未来回归丢失端口复用。

**build-first 不变量**（场景 3）——lock build 失败时旧 QEMU 不被 kill，防未来回归成 build-before-stop。

### integration 层

新文件 `tests/integration/ob_deploy_to_qemu.sh`（gate `--integration`）：完整 e2e（真 build + 真起 QEMU + BMC SSH ready 检查），复用 `build_e2e.exp` infrastructure + `ob_dev.sh` 的 SKIP 门（无 init machine → exit 77）。断言 exit 0 + 新 image 在跑 + BMC SSH ready。成本：1-4h + 占端口，需 initialized machine（romulus / b865g8-bytedance 可用）。

### Full check

`tools/ob_check.sh` + `tests/run_all.sh`（默认 protocol/unit/orchestration；`--full` 加 .exp；`--integration` 加 e2e）。

## harness 侧改动清单

**Create:**
- `tests/orchestration/deploy_to_qemu.sh`（7 场景）
- `tests/integration/ob_deploy_to_qemu.sh`（gate `--integration`，SKIP 门 exit 77）

**Modify:**
- `lib/commands.sh`（加 `cmd_deploy_to_qemu`，cmd_stop_qemu 后）
- `ob`（usage Commands 段加 `deploy-to-qemu` 行 + parse_args case + main dispatch + Examples 段加示例）
- `tests/protocol/usage_dispatch_sync.sh`（加 deploy-to-qemu 登记块）
- `rules/03_WORKSPACE.md`（顺手：ob 条目补 `deploy-to-qemu`）
- `CONTEXT.md`（新 `ob deploy-to-qemu` 术语）
- `rules/skills/workflow_02-obmc_dev_modify.md`（补完整验证链：modify → build → **deploy-to-qemu** → finish）
- `docs/adr/0011-ob-deploy-to-qemu-toplevel-ownership.md`（新）

**不改**（选项 C 零重构）：`cmd_build` / `cmd_start_qemu` / `cmd_stop_qemu` / `lib/qemu.sh` / `lib/qemu_instance.sh` / `lib/build_env.sh`。`tools/exit_contract.py` 不改（deploy-to-qemu 在 `commands.sh` exit seam，非 leaf-pure basename）。

## 实施约束（writing-plans 必须遵循）

1. **自带编排，零重构 cmd_***：deploy-to-qemu 只调底层 module（build_env_enter / bitbake / qemu_instance_* / qemu_prepare_launch / qemu_execute_launch），不改 cmd_build / cmd_start_qemu / cmd_stop_qemu 行为。bitbake + npm registry + image 信息 ~20 行重复留技术债。
2. **端口复用时序**：必须在 `qemu_instance_stop` 之前 `qemu_instance_load` 读端口；读后设进 `QEMU_*_PORT` 全局；`http_port` 字面 `none` 不设 `QEMU_HTTP_PORT`。
3. **build-first**：build 在 stop 之前。build 失败 → exit 1，QEMU 不动（不调 qemu_instance_stop）。
4. **confirm 仅 QEMU 在跑时**：无 QEMU 时无 banner（显式快路径）。遵循 confirmation banner 术语"路径风险"原则。
5. **成功边界 = QEMU 启动即成功**：BMC-ready 超时 warn 不 exit（沿用 qemu_execute_launch 现状，不改 qemu.sh）。
6. **stage 标记 + 恢复引导**：build 成功打 `[Image Rebuilt]`；start 前打恢复引导（`ob start-qemu <machine>`），因 execute_launch exit 1 后无法再打印。
7. **exit-code 契约**：0 = image 重建 + QEMU 启动；1 = build / setsid 失败；2 = banner 拒绝；3 = machine 未 init。cmd_deploy_to_qemu 是 exit seam（`commands.sh`），非 leaf-pure。
8. **环境**：Linux + bash；验证命令用 bash / python3 / expect。stub 套路复用 `tests/lib/stub.sh` + `qemu_stubs.sh`。
9. **命名**：`cmd_deploy_to_qemu`（snake_case，与 `cmd_start_qemu` 同构）；usage 行 `deploy-to-qemu`（连字符，与 `start-qemu` / `stop-qemu` 同构）。

## 技术债

- **bitbake + npm registry + image 信息打印 ~20 行与 `cmd_build` 重复**（选项 C 的代价）。后续若重复成痛点，抽 `build_obmc_image` leaf helper（`lib/build_env.sh` 或新 module），`cmd_build` 和 `cmd_deploy_to_qemu` 共用——消灭重复 + 统一 build 逻辑（防漂移）。本轮 YAGNI，留技术债。
- **端口 flag（`--ssh-port` 等）v1 不暴露**：用户要自定义端口时退到 `ob start-qemu <machine> --ssh-port ...` 手动两步。后续按需加。
- **真机部署**：v1 只 QEMU（community image 硬编码凭证）。真机要新建 target 配置模型。
- **advisory next-step 不做**：`ob dev build` 成功后不自动提示 `deploy-to-qemu`（agent 不保证读 stderr）。agent 衔接靠 workflow_02 + `ob --help` + CONTEXT。

## ADR 关系

- **ADR-0011（新，本设计伴生）**：deploy 归属决策——`ob deploy-to-qemu` 在 ob 顶层 QEMU 生命周期层，不在 `ob dev` recipe 级开发层。三条全中（hard to reverse + surprising + real trade-off）。
- **ADR-0003（ob 优先）**：deploy-to-qemu 进 `ob --help` 能力清单，agent 靠它发现。
- 与 ADR-0008 / 0009（ob dev workspace cleanup / single-writer）无关——deploy-to-qemu 不碰 devtool workspace。
- 与 ADR-0010（dev dispatch leaf-pure）无关——deploy-to-qemu 是 ob 顶层 cmd_*（exit seam），不属 dev dispatch helpers。
