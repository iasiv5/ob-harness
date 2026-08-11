# ob 测试覆盖 checklist(语义层,人声明)

功能点 × 涉及函数 × 覆盖 test。与 [coverage_radar.py](coverage_radar.py)(结构层,运行时实测)交叉校验:

```bash
tools/trace_collect.sh | python3 tools/coverage_radar.py - --cross-check
```

> radar 全集 = ob + lib/*.sh(F5 修复后;曾因 06-22 模块化未同步而只测 ob 入口 3 函数)。cross-check 会列出"matrix 声明但不在 radar 全集"的 out-of-scope 项(surface gate 等刻意 out-of-radar,其它是 typo/过期名)。

**规则**:涉及函数分号 `;` 分隔;覆盖 test 留空=未覆盖(TODO);备注标 `exit 函数`(radar 低估,良性)/ `TTY`(靠 expect)/ `integration`(需 QEMU)。

> 这是骨架(5 关键功能点 + 横切),随 test 扩充持续维护。

## init

| 功能点 | 涉及函数 | 覆盖 test | 备注 |
|---|---|---|---|
| 参数解析 | parse_args | protocol/smoke_ob.sh | exit 函数,radar 低估 |
| 命令入口机器解析+确认(intake module) | init_intake | unit/init_intake.sh;protocol/init_intake_surface.sh | leaf-pure(同 devtool_intake);return 0/1/2/3,exit 由 cmd_init 字面 case 收口;empty/arg-fastpath/nontty 三态 unit 覆盖,pick+confirm cancel/ok 留 .exp |
| 非 TTY → exit 3 | cmd_init;init_intake | protocol/manual_matrix.exp;unit/init_intake.sh | 决策在 intake,exit 在 cmd_init;TTY 真路径靠 expect |
| 取消 → exit 2 | cmd_init;init_intake;confirm_action | protocol/manual_matrix.exp | confirm/pick 在 intake;confirm_action 见 unit/interact.sh |
| source manifest 读写 | read_source_label;write_source_manifest;normalize_repo_url;derive_source_label | unit/source_manifest.sh;unit/url.sh | |
| 前置检查 | prerequisites_check | orchestration/prerequisites_check.sh | exit 函数 |
| BitBake 环境初始化 | init_bitbake_env;build_env_enter | orchestration/build_env_enter.sh;protocol/build_env_enter_structure.sh | local.conf 产物检查仍在 init_bitbake_env |
| 子仓库克隆 | clone_sub_repos;bare_mirror_provision;bare_mirror_base;bare_mirror_print_status;detect_runtime_git_host | orchestration/clone_sub_repos.sh;orchestration/bare_mirror_cost.sh;unit/bare_mirror.sh;unit/url_extra.sh | unit/bare_mirror.sh 顶层调用补偿 xtrace 子 shell 低估 |
| machine snapshot 生成 | generate_machine_snapshot;machine_state_write_snapshot | orchestration/generate_config.sh;unit/machine_state.sh | |
| build config 生成 | generate_build_config | orchestration/generate_config.sh | |

## build

| 功能点 | 涉及函数 | 覆盖 test | 备注 |
|---|---|---|---|
| 空 workspace → exit 3 | cmd_build | protocol/smoke_ob.sh | |
| 取消 → exit 2 | cmd_build;confirm_action | orchestration/build_confirm_cancel.sh;protocol/manual_matrix.exp | confirm 迁 inline case+warn(ADR-0019);cancel warn 锁 orchestration(stub,不依赖 workspace) |
| 进入 bitbake 环境 + bitbake handoff | build_env_enter;cmd_build | orchestration/build_env_enter.sh;orchestration/cmd_build_bitbake_handoff.sh;protocol/build_env_enter_structure.sh | build_env_enter=进入原语(副作用契约); cmd_build_bitbake_handoff=非 dry-run 调 bitbake + 失败 exit 1 兜底 |
| npm registry passthrough 装配 | apply_npm_registry | unit/npm_registry.sh | leaf-pure(util.sh); cmd_build/cmd_deploy_to_qemu 共享; skip/空 existing/非空 existing/空 registry 四态 |
| obmc-phosphor-image 构建编排 | build_obmc_image | unit/image_build.sh | leaf-pure(image_build.sh); cmd_build/cmd_deploy_to_qemu 共享 enter+npm+bitbake; 成功/失败/enter失败 三态 |

## status

| 功能点 | 涉及函数 | 覆盖 test | 备注 |
|---|---|---|---|
| 空工作区 → exit 0 | cmd_status | protocol/exit_codes.sh;protocol/status_golden.sh | exit 函数,radar 低估;golden 字节级回归(子壳+redirect N1+normalize run-specific TMP/PID) |
| machine lifecycle state 展示/诊断 | machine_state_display_machines;machine_state_orphan_firmware_image_machines;machine_state_init_state;machine_state_snapshot_state;machine_state_init_time;machine_state_firmware_image_mtime;machine_state_is_firmware_image_ready;machine_state_is_orphan_firmware_image | unit/machine_state.sh;protocol/status_machine_state.sh | public records surface 已删除 |
| 仪表盘呈现(表格/diagnostics 段/tips 排版+emoji 映射) | status_render_main_repo;status_render_machines;status_render_diagnostics;status_render_tips | unit/status_render.sh;protocol/status_render_surface.sh | leaf-pure(status_render.sh);纯参数注入不采集数据;§7 surface gate(forbidden token 清零,protocol/status_render_surface.sh) |

## dev

| 功能点 | 涉及函数 | 覆盖 test | 备注 |
|---|---|---|---|
| TTY modified recipe selection(reset/finish/build 共享选号前置) | devtool_pick_modified_recipe | unit/devtool_pick.sh | 选号往返靠 unit(here-string 喂 stdin, 非真实 PTY);protocol/dev_interactive.exp 仅锁 reset/finish empty 路径(不锁选号往返/build); 恒返回码 5 态 status_outvar, exit-code 映射在 cmd_dev |
| subcommand handler 编排(precondition→dry-run gate→execute→relay→emit→exit 映射) | dev_dispatch_subcmd;dev_subcmd_modify;dev_subcmd_refresh;dev_subcmd_status;dev_subcmd_reset;dev_subcmd_finish;dev_subcmd_build;dev_subcmd_list | unit/devtool_subcmd.sh | leaf-pure(ADR-0012),return exit-code 契约值 0/1/2/3,cmd_dev 字面 case 收口 exit |
| execute module(devtool_*_run 单步执行) | devtool_modify_run;devtool_build_run;devtool_reset_run;devtool_finish_run;devtool_status_run | unit/devtool_modify.sh;unit/devtool_build.sh;unit/devtool_reset.sh;unit/devtool_finish.sh;unit/devtool_status.sh | leaf-pure;各 run 单测钉 status-first + rc 回传 |
| recipe 元数据检索/缓存三态 | devtool_search_read;devtool_search_refresh | unit/devtool_search.sh | fresh/missing/stale 三态 |
| porcelain JSON/JSONL 编码+原子发布 | devtool_emit_json;devtool_emit_jsonl;dev_emit_reset_json;dev_emit_finish_json;dev_emit_status_jsonl | unit/devtool_porcelain.sh | leaf-pure(ADR-0010),cat+rm 原子发布 |
| 失败 relay(stage/rc/phase verbatim 诊断) | dev_relay_result | unit/devtool_dispatch.sh | per-subcmd 文案表,服务 modify/status/reset/finish/build |
| workspace 交互原语(env_exec/parse srctree/status) | _devtool_env_exec;_devtool_parse_srctree;_devtool_parse_status_all;_devtool_parse_status_entry | unit/devtool_workspace.sh | leaf-pure |
| cmd_dev dispatch 非 TTY 路径 | cmd_dev | orchestration/cmd_dev.sh | exit 函数,radar 低估;非 TTY dispatch 路径 |
| 命令入口 argv 解析 + TTY 子命令引导(intake module) | dev_intake_argv;dev_intake_tty | unit/devtool_intake.sh;protocol/devtool_intake_surface.sh | leaf-pure(ADR-0010/0012);argv return 0/1, tty return 0/1/2/3;nameref outvar 回填;-d 设全局 DRY_RUN |

## start-qemu

| 功能点 | 涉及函数 | 覆盖 test | 备注 |
|---|---|---|---|
| QEMU binary 路径/manifest | derive_qemu_paths;read_qemu_url_config;write_qemu_url_config;write_qemu_binary_manifest;write_qemu_pcbios_manifest | unit/qemu_manifest.sh | |
| QEMU launch profile / QB 输入解析 | resolve_qemu_launch_profile | orchestration/qemu_launch_profile.sh;orchestration/resolve_qb_vars.sh;protocol/qemu_launch_profile_remedy.sh | exit 函数 |
| 端口检查 | check_ports_available;get_port_occupants | unit/ports.sh | check_ports_available exit 函数 |
| instance 存活状态 | qemu_instance_liveness | unit/qemu_instance.sh | running/exited/recycled/nopid; ADR-0024 |
| 失效 host key 检测 | check_ssh_hostkey_conflict;_clear_stale_hostkey_menu | unit/hostkey_conflict.sh | Track A 删除菜单(确证失效);Track B sshd 未就绪仅提示不删 |
| 取消 → exit 2 | cmd_start_qemu | protocol/manual_matrix.exp | TTY |
| machine-selection 序言(empty/nontty/ok 走 guard) | cmd_start_qemu;machine_selection_guard | protocol/start_qemu_remedy.sh;protocol/qemu_commands_guard_surface.sh | empty 带子分类(先 build/先 init remedy 区分,留 cmd D2);与 cmd_build/cmd_dev 同构 |
| kill-restart | cmd_start_qemu | integration/manual_matrix_qemu.exp | integration |
| launch prepare 半段(profile/binary/firmware/ports/build) | qemu_prepare_launch | orchestration/qemu_prepare_launch.sh | Shape 2 half 1 |
| launch execute 半段(setsid+PID+summary) | qemu_execute_launch | orchestration/qemu_execute_launch.sh | Shape 2 half 2;QEMU_NO_WAIT 跳 BMC-wait |
| --force 同端口重启顺序(F1) | cmd_start_qemu | orchestration/start_qemu_force_restart.sh | F1 不变量:kill 先于 check_ports |
| restart 端口复用注入（cli_first + HTTP none）| resolve_qemu_port_reuse | unit/qemu_port_reuse.sh;orchestration/deploy_to_qemu.sh 场景⑧ | leaf-pure（ADR-0022）; cli_first 四端口对称矩阵 + HTTP none sentinel; deploy honor CLI 行为级锁（场景⑧） |
| binary 下载链 | download_qemu_binary_core;ensure_qemu_binary_community | orchestration/qemu_binary_download.sh | flat-binary 路径;原 #1 盲区 |
| binary 更新/URL 决策 | qemu_binary_update_decision;qemu_binary_resolve_url | unit/qemu_binary_decision.sh | 纯决策 |
| 实例四行显示 | qemu_instance_summarize_full | unit/qemu_instance.sh | start↔stop 复用；status 走 summarize_brief |
| instance module（list/load/liveness/summarize_brief/clean_stale） | qemu_instance_list;qemu_instance_load;qemu_instance_liveness;qemu_instance_summarize_brief;qemu_instance_clean_stale | unit/qemu_instance.sh | start/stop/status 共用；caller 不碰 .pids 物理布局 |
| binary 更新(flock+回滚) | download_and_replace_community_qemu;_dlqbc_stage_binary;_replace_community_binary | orchestration/qemu_binary_replace.sh | acquire/commit 切面; flock 留 wrapper; swap-fail-rollback 不变量 stateful mv 锁 |
| custom binary 配置 | ensure_qemu_binary_custom;resolve_custom_binary_candidate;resolve_custom_pcbios_candidate | unit/qemu_binary_resolve.sh | 路径解析 leaf-pure(outvar 编码); 交互循环留 wrapper; 非 TTY exit 3 仍靠 .exp |

## stop-qemu

| 功能点 | 涉及函数 | 覆盖 test | 备注 |
|---|---|---|---|
| 无实例 → exit 0 | cmd_stop_qemu | protocol/exit_codes.sh | exit 函数,radar 低估 |
| 取消/正常停止 | cmd_stop_qemu | integration/manual_matrix_qemu.exp | integration |
| 统一 stop(kill+wait+SIGKILL+rm) | qemu_instance_stop | orchestration/qemu_stop_instance.sh | start 冲突 kill + cmd_stop_qemu 复用 |

## deploy-to-qemu

| 功能点 | 涉及函数 | 覆盖 test | 备注 |
|---|---|---|---|
| build-first 编排(image 重建 + QEMU 重启,端口复用) | cmd_deploy_to_qemu | orchestration/deploy_to_qemu.sh;integration/ob_deploy_to_qemu.sh | exit 函数,radar 低估;build-first 链 + QEMU 在跑则端口复用(ADR-0011) |
| machine-selection 序言(经 resolve_command_machine) | cmd_deploy_to_qemu;resolve_command_machine | protocol/deploy_to_qemu_machine_selection.sh;protocol/qemu_commands_guard_surface.sh | 经 resolve_command_machine 同 cmd_build(ADR-0019);empty/nontty remedy 字节级不变 |

## smoke

| 功能点 | 涉及函数 | 覆盖 test | 备注 |
|---|---|---|---|
| probe-only 命令编排(前置 exit 3 + 读实例端口 + 5 断言 + verdict) | cmd_smoke | protocol/smoke_exit_contract.sh;protocol/smoke_surface.sh;protocol/smoke_substep_isolation.sh;integration/smoke_e2e.sh | exit 函数,radar 低估;exit 0/1/3 + 5 ✓ 行 + α-banner 存在性锁 |
| verdict 渲染(summary + 失败 breakdown + α-banner) | _smoke_render_verdict | unit/smoke_verdict.sh | leaf-pure 风格(return 0/1,不 exit);3 case + 通道锁(error 诊断行/α-banner→stderr,summary/✗/RAW/info→stdout) |
| 断言判定(Redfish root/Managers/SoftwareVersion + IPMI + system-ready) | smoke_judge_redfish_root;smoke_judge_redfish_managers;smoke_judge_redfish_swversion;smoke_judge_ipmi_lan;smoke_judge_system_ready | protocol/smoke_assertions_judgment.sh;orchestration/smoke_orchestration.sh | leaf-pure(lib/smoke_assertions.sh) |
| probe 采集(curl/ipmitool/tcp → nameref outvars) | _smoke_probe_redfish;_smoke_probe_redfish_managers;_smoke_probe_ipmi;_smoke_probe_ssh_tcp;_smoke_tcp_probe;_smoke_wait_ssh_tcp | orchestration/smoke_orchestration.sh | cmd_smoke 私有,PATH-stub 单测 |

## 横切(通用)

| 功能点 | 涉及函数 | 覆盖 test | 备注 |
|---|---|---|---|
| 路径推导 | detect_harness_root;derive_qemu_url_config_path | unit/paths.sh | |
| 并行度/WSL | calc_parallelism;detect_wsl | unit/paths.sh | |
| 交互叶子(stdin) | confirm_action;prompt_for_absolute_path;prompt_for_available_port | unit/interact.sh | rc→exit 映射 helper 已退役(ADR-0019; cancel warn 覆盖迁 machine_resolve unit + build_confirm_cancel); select_from_list 已退役(ob_check 回归锁禁复活) |
| machine 交互选择 | pick_machine | unit/pick_machine.sh | leaf-pure L3,多态返回码表达取消/失败 |
| machine selection guard(枚举+empty/nontty 检测) | machine_selection_guard | unit/machine_selection_guard.sh;protocol/machine_selection_guard_surface.sh | leaf-pure(横切惯例,同 machine_picker.sh);恒返回0+outvar empty/nontty/ok;cmd_build/cmd_dev/cmd_deploy_to_qemu 经 resolve_command_machine 间接消费、cmd_start_qemu 直接消费(cmd_stop_qemu 不经 guard), pick 留 seam/调用方 |
| command machine resolution(given/empty 解析 ritual 收口) | resolve_command_machine | unit/machine_resolve.sh | leaf-pure(ADR-0019);return 0/1/2/3,exit 由 cmd_build/cmd_dev/cmd_deploy_to_qemu 字面 case 收口;消费 guard+pick_machine+is_initialized, set $MACHINE;7 态 unit 覆盖,given+empty remedy 字节级 |
| require_path 前置 | require_path | unit/require_path.sh | exit 函数,radar 低估 |
| 字符串/工具子函数 | is_valid_repo_url;read_kv_field;read_manifest_field;trim_whitespace | unit/url.sh;unit/source_manifest.sh | 子工具,被上层调用 |
| QEMU launch profile 纯规则 | qemu_launch_profile_apply_system_name;qemu_launch_profile_apply_machine_name;machine_conf_chain_contains | unit/soc.sh | start-qemu SoC/机型派生 |
| conf/url 工具 | read_local_conf_var;resolve_effective_dl_dir;resolve_effective_sstate_dir;parse_hostkey_offending;machine_conf_chain_contains | unit/conf_read.sh;unit/url_extra.sh | 子工具 |
| machine_state public records surface 门禁 | machine_state_records;_commands_machine_record_field;_commands_record_has_discovery_source;_commands_collect_machine_state_records;_repo_machine_record_field | tools/ob_check.sh;unit/repo_previously_initialized.sh;protocol/status_machine_state.sh | 禁止生产代码调用 machine_state_records / record parser helper;out-of-radar(surface gate 回归锁,不在 ob+lib 函数全集,cross-check out-of-scope 列) |
| current-shell build environment 进入 | build_env_enter | orchestration/build_env_enter.sh;protocol/build_env_enter_structure.sh | current-shell 副作用原语,leaf-no-exit |
