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
| 非 TTY → exit 3 | cmd_init | protocol/manual_matrix.exp | TTY 真路径靠 expect |
| 取消 → exit 2 | cmd_init;confirm_action | protocol/manual_matrix.exp | confirm_action 见 unit/interact.sh |
| source manifest 读写 | read_source_label;write_source_manifest;normalize_repo_url;derive_source_label | unit/source_manifest.sh;unit/url.sh | |
| 前置检查 | prerequisites_check | orchestration/prerequisites_check.sh | exit 函数 |
| BitBake 环境初始化 | init_bitbake_env;build_env_enter | orchestration/build_env_enter.sh;protocol/build_env_enter_structure.sh | local.conf 产物检查仍在 init_bitbake_env |
| 子仓库克隆 | clone_sub_repos | orchestration/clone_sub_repos.sh | |
| machine snapshot 生成 | generate_machine_snapshot;machine_state_write_snapshot | orchestration/generate_config.sh;unit/machine_state.sh | |
| build config 生成 | generate_build_config | orchestration/generate_config.sh | |

## build

| 功能点 | 涉及函数 | 覆盖 test | 备注 |
|---|---|---|---|
| 空 workspace → exit 3 | cmd_build | protocol/smoke_ob.sh | |
| 取消 → exit 2 | cmd_build;confirm_action | protocol/manual_matrix.exp | |
| 进入 bitbake 环境 + bitbake handoff | build_env_enter;cmd_build | orchestration/build_env_enter.sh;orchestration/cmd_build_bitbake_handoff.sh;protocol/build_env_enter_structure.sh | build_env_enter=进入原语(副作用契约); cmd_build_bitbake_handoff=非 dry-run 调 bitbake + 失败 exit 1 兜底 |

## status

| 功能点 | 涉及函数 | 覆盖 test | 备注 |
|---|---|---|---|
| 空工作区 → exit 0 | cmd_status | protocol/exit_codes.sh | exit 函数,radar 低估 |
| machine lifecycle state 展示/诊断 | machine_state_display_machines;machine_state_orphan_firmware_image_machines;machine_state_init_state;machine_state_snapshot_state;machine_state_init_time;machine_state_firmware_image_mtime;machine_state_is_firmware_image_ready;machine_state_is_orphan_firmware_image | unit/machine_state.sh;protocol/status_machine_state.sh | public records surface 已删除 |

## start-qemu

| 功能点 | 涉及函数 | 覆盖 test | 备注 |
|---|---|---|---|
| QEMU binary 路径/manifest | derive_qemu_paths;read_qemu_url_config;write_qemu_url_config;write_qemu_binary_manifest;write_qemu_pcbios_manifest | unit/qemu_manifest.sh | |
| QEMU launch profile / QB 输入解析 | resolve_qemu_launch_profile | orchestration/qemu_launch_profile.sh;orchestration/resolve_qb_vars.sh;protocol/qemu_launch_profile_remedy.sh | exit 函数 |
| 端口检查 | check_ports_available;get_port_occupants | unit/ports.sh | check_ports_available exit 函数 |
| PID 校验 | qemu_instance_is_alive | unit/ports.sh | |
| 失效 host key 检测 | check_ssh_hostkey_conflict;_clear_stale_hostkey_menu | unit/hostkey_conflict.sh | Track A 删除菜单(确证失效);Track B sshd 未就绪仅提示不删 |
| 取消 → exit 2 | cmd_start_qemu | protocol/manual_matrix.exp | TTY |
| kill-restart | cmd_start_qemu | protocol/manual_matrix_qemu.exp | integration |
| launch prepare 半段(profile/binary/firmware/ports/build) | qemu_prepare_launch | orchestration/qemu_prepare_launch.sh | Shape 2 half 1 |
| launch execute 半段(setsid+PID+summary) | qemu_execute_launch | orchestration/qemu_execute_launch.sh | Shape 2 half 2;QEMU_NO_WAIT 跳 BMC-wait |
| --force 同端口重启顺序(F1) | cmd_start_qemu | orchestration/start_qemu_force_restart.sh | F1 不变量:kill 先于 check_ports |
| binary 下载链 | download_qemu_binary_core;ensure_qemu_binary_community | orchestration/qemu_binary_download.sh | flat-binary 路径;原 #1 盲区 |
| binary 更新/URL 决策 | qemu_binary_update_decision;qemu_binary_resolve_url | unit/qemu_binary_decision.sh | 纯决策 |
| 实例四行显示 | qemu_instance_summarize_full | unit/qemu_instance.sh | start↔stop 复用；status 走 summarize_brief |
| instance module（list/load/summarize_brief/clean_stale） | qemu_instance_list;qemu_instance_load;qemu_instance_summarize_brief;qemu_instance_clean_stale | unit/qemu_instance.sh | start/stop/status 共用；caller 不碰 .pids 物理布局 |
| binary 更新(flock+回滚) | download_and_replace_community_qemu | | 副作用残留(flock+backup+rollback) |
| custom binary 配置 | ensure_qemu_binary_custom | | 交互残留(非 TTY exit 3 / TTY prompt) |

## stop-qemu

| 功能点 | 涉及函数 | 覆盖 test | 备注 |
|---|---|---|---|
| 无实例 → exit 0 | cmd_stop_qemu | protocol/exit_codes.sh | exit 函数,radar 低估 |
| 取消/正常停止 | cmd_stop_qemu | protocol/manual_matrix_qemu.exp | integration |
| 统一 stop(kill+wait+SIGKILL+rm) | qemu_instance_stop | orchestration/qemu_stop_instance.sh | start 冲突 kill + cmd_stop_qemu 复用 |

## 横切(通用)

| 功能点 | 涉及函数 | 覆盖 test | 备注 |
|---|---|---|---|
| 路径推导 | detect_harness_root;derive_bitbake_git_mirror_path;derive_qemu_url_config_path | unit/paths.sh | |
| 并行度/WSL | calc_parallelism;detect_wsl | unit/paths.sh | |
| 交互叶子(stdin) | select_from_list;confirm_action;prompt_for_absolute_path | unit/interact.sh | |
| require_path 前置 | require_path | unit/require_path.sh | exit 函数,radar 低估 |
| 字符串/工具子函数 | is_valid_repo_url;read_kv_field;read_manifest_field;trim_whitespace | unit/url.sh;unit/source_manifest.sh | 子工具,被上层调用 |
| QEMU launch profile 纯规则 | qemu_launch_profile_apply_system_name;qemu_launch_profile_apply_machine_name;machine_conf_chain_contains | unit/soc.sh | start-qemu SoC/机型派生 |
| conf/url 工具 | read_local_conf_var;resolve_effective_dl_dir;resolve_effective_sstate_dir;is_private_url;parse_hostkey_offending;machine_conf_chain_contains | unit/conf_read.sh;unit/url_extra.sh | 子工具 |
| machine_state public records surface 门禁 | machine_state_records;_commands_machine_record_field;_commands_record_has_discovery_source;_commands_collect_machine_state_records;_repo_machine_record_field | tools/ob_check.sh;unit/repo_previously_initialized.sh;protocol/status_machine_state.sh | 禁止生产代码调用 machine_state_records / record parser helper;out-of-radar(surface gate 回归锁,不在 ob+lib 函数全集,cross-check out-of-scope 列) |
| current-shell build environment 进入 | build_env_enter | orchestration/build_env_enter.sh;protocol/build_env_enter_structure.sh | current-shell 副作用原语,leaf-no-exit |
