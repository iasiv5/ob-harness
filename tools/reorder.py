#!/usr/bin/env python3
"""ob 函数物理重排器（阶段 3b：§1-§7 分区连续化）。

把 ob 单文件脚本的函数按 §1-§7 理想分层物理连续化，§ 锚点严格递增。
函数体字节零改动，仅重排顺序（顶部 §1 声明 + 底部 main 调用保留原位）。

用法：python3 tools/reorder.py ob        # 生成 /tmp/ob_new
验证（三重保证）：
  bash -n /tmp/ob_new                                                    # 语法
  diff <(bash -c 'OB_NO_MAIN=1 source ob;declare -f'|sort) \\
       <(bash -c 'OB_NO_MAIN=1 source /tmp/ob_new;declare -f'|sort)      # 函数体零变化
  cp ob /tmp/ob_orig && cp /tmp/ob_new ob && bash tests/smoke_ob.sh      # 行为

§ 归类在下方 sections dict（92 = 28+13+29+9+10+3）。调整某函数的 § 归属：
改 sections 映射重跑即可，函数体零改动纯机械。当前归类的主观判断见 commit f7f4d0b。

结构前提（重排安全的基础）：ob 顶层可执行语句只在头部（set/变量/Colors）和
尾部（main 调用），函数定义之间无夹杂——bash 函数顺序对执行无关（调用都在 main）。
"""
import re, sys

lines = open(sys.argv[1]).read().split('\n')
N = len(lines)

# 1. 函数边界（单行函数 + 范围内最后顶格 }）
func_starts = []
brace_ends = []
for i, line in enumerate(lines, 1):
    m = re.match(r'^([A-Za-z_]\w*)\s*\(\)', line)
    if m:
        func_starts.append((i, m.group(1)))
    if line == '}':
        brace_ends.append(i)
funcs = {}
order = []
for k, (start, name) in enumerate(func_starts):
    defline = lines[start-1]
    if defline.rstrip().endswith('}'):
        end = start
    else:
        ns = func_starts[k+1][0] if k+1 < len(func_starts) else N+1
        cands = [b for b in brace_ends if start < b < ns]
        end = max(cands)
    funcs[name] = (start, end)
    order.append(name)

# 2. 前导注释（不含 # === 分区锚点）
def lead(start):
    res = []
    i = start - 2
    while i >= 0:
        s = lines[i].strip()
        if s == '' or s.startswith('# ==='):
            break
        if s.startswith('#'):
            res.insert(0, lines[i]); i -= 1
        else:
            break
    return res

# 3. § 归类（可调整：改映射重跑，函数体零改动）
sections = {
    2: ['log','info','warn','error','verbose','print_confirm_banner','trim_whitespace','format_timestamp','step_header','show_logo','show_brand_line','fn_quit','read_local_conf_var','is_private_url','resolve_effective_dl_dir','resolve_effective_sstate_dir','derive_bitbake_git_mirror_path','detect_harness_root','detect_wsl','calc_parallelism','probe_npm_registry','resolve_npm_registry','read_kv_field','read_lock_field','select_from_list','confirm_action','prompt_for_absolute_path','require_path'],
    3: ['read_source_label','is_valid_repo_url','normalize_repo_url','derive_source_label','write_source_lock','ensure_bootstrap_local_conf','verify_source','select_openbmc_repo_url','list_available_machines','print_available_machines','require_openbmc_repo','print_previously_initialized','resolve_machine'],
    4: ['derive_qemu_paths','derive_qemu_url_config_path','read_qemu_url_config','write_qemu_url_config','write_qemu_binary_manifest','write_qemu_pcbios_manifest','query_jenkins_build_number','download_qemu_binary_core','download_and_replace_community_qemu','check_jenkins_update','ensure_qemu_binary_community','ensure_qemu_binary','ensure_qemu_binary_custom','find_ast2700_bootloaders','build_qemu_cmd','ensure_qemu_firmware','resolve_qb_vars','resolve_machine_conf_include','machine_conf_chain_contains','detect_soc_type','derive_qemu_machine_name','check_ports_available','get_port_occupants','prompt_for_available_port','resolve_qemu_ports_interactive','read_pid_file','validate_pid','parse_hostkey_offending','check_ssh_hostkey_conflict'],
    5: ['prerequisites_check','clone_openbmc','run_repo_init_script','init_bitbake_env','generate_dep_graph','clone_sub_repos','generate_lockfile','generate_build_config','print_report'],
    6: ['status_section_main_repo','status_section_machines','status_section_tips','cmd_status','cmd_build','cmd_start_qemu','_qemu_post_launch','cmd_stop_qemu','cmd_init','cmd_menu'],
    7: ['parse_args','usage','main'],
}
classified = set()
for v in sections.values():
    classified |= set(v)
assert set(order) == classified, f'mismatch missing={set(order)-classified} extra={classified-set(order)}'

titles = {
    2: '# === §2 通用工具 (Utility / L3) — L3 函数绝不 exit ===',
    3: '# === §3 仓库与 machine (repo source / machine resolution) ===',
    4: '# === §4 QEMU (binary / firmware / ports / SoC / pid) ===',
    5: '# === §5 构建流程 (init pipeline: dep graph / sub-repos / lockfile / config) ===',
    6: '# === §6 命令编排 (cmd_* orchestrators) ===',
    7: '# === §7 入口 (parse_args / usage / main) ===',
}

# 4. header（行1 到首个函数前；保留 §1，跳过散落 §2-§7 锚点，去尾空行）
first_start = func_starts[0][0]
header = []
for idx in range(first_start - 1):
    line = lines[idx]
    s = line.strip()
    if s.startswith('# === §') and '§1' not in s:
        continue
    header.append(line)
while header and header[-1].strip() == '':
    header.pop()

# 5. footer（main 函数体之后：main 调用 if/fi）
main_end = funcs['main'][1]
footer = [l for l in lines[main_end:]]
while footer and footer[0].strip() == '':
    footer.pop(0)
while footer and footer[-1].strip() == '':
    footer.pop()

# 6. 重组
out = list(header)
for sec in [2,3,4,5,6,7]:
    out.append('')
    out.append(titles[sec])
    for name in sections[sec]:
        s, e = funcs[name]
        out.append('')
        out.extend(lead(s))
        out.extend(lines[s-1:e])
out.append('')
out.extend(footer)

open('/tmp/ob_new', 'w').write('\n'.join(out) + '\n')
print('written /tmp/ob_new, lines:', len(out))
