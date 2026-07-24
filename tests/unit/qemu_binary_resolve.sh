#!/usr/bin/env bash
# tests/unit/qemu_binary_resolve.sh — qemu_binary 纯决策族 unit。
# jenkins URL 提取 + (Task 2 追加) resolve_custom_* 路径解析。纯函数、无 IO、不 exit。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# jenkins_job_url_from_url <url>  →  echo job base url(剥 lastSuccessfulBuild/artifact 后缀)
assert_eq "artifact 后缀剥离" \
  "$(jenkins_job_url_from_url 'https://jenkins.openbmc.org/job/latest-qemu-x86/lastSuccessfulBuild/artifact/qemu/build/qemu-system-arm')" \
  'https://jenkins.openbmc.org/job/latest-qemu-x86'
assert_eq "仅 lastSuccessfulBuild 后缀" \
  "$(jenkins_job_url_from_url 'https://jenkins.openbmc.org/job/latest-qemu-x86/lastSuccessfulBuild/api/json')" \
  'https://jenkins.openbmc.org/job/latest-qemu-x86'
assert_eq "无后缀原样返回" \
  "$(jenkins_job_url_from_url 'https://jenkins.openbmc.org/job/latest-qemu-x86')" \
  'https://jenkins.openbmc.org/job/latest-qemu-x86'

# --- resolve_custom_binary_candidate <input> <arch> <outvar> ---
# outvar 编码: ok:<path> / err_dir_no_arch / err_not_file
_RT="${TMPDIR:-/tmp}"
_mk() { mkdir -p "$1"; }            # helper 造目录
_bres=""
# 文件直传 → ok:input
printf 'NEW' > "$_RT/ob_res_bin"
resolve_custom_binary_candidate "$_RT/ob_res_bin" "qemu-system-arm" _bres
assert_eq "binary: file 直传 ok" "$_bres" "ok:$_RT/ob_res_bin"
# 目录 + 含 arch → ok:dir/arch
_mk "$_RT/ob_res_dir"; printf 'NEW' > "$_RT/ob_res_dir/qemu-system-arm"
resolve_custom_binary_candidate "$_RT/ob_res_dir" "qemu-system-arm" _bres
assert_eq "binary: dir+arch → ok:dir/arch" "$_bres" "ok:$_RT/ob_res_dir/qemu-system-arm"
# 目录 + 缺 arch → err_dir_no_arch
_mk "$_RT/ob_res_dir2"
resolve_custom_binary_candidate "$_RT/ob_res_dir2" "qemu-system-arm" _bres
assert_eq "binary: dir 缺 arch → err_dir_no_arch" "$_bres" "err_dir_no_arch"
# 既非 dir 也非 file → err_not_file
resolve_custom_binary_candidate "$_RT/ob_res_nope" "qemu-system-arm" _bres
assert_eq "binary: 不存在 → err_not_file" "$_bres" "err_not_file"
rm -rf "$_RT/ob_res_dir" "$_RT/ob_res_dir2" "$_RT/ob_res_bin"

# --- resolve_custom_pcbios_candidate <input> <outvar> ---
# outvar 编码: ok:<path> / err_not_dir / err_no_bootrom
_pres=""
# 目录 + 直接含 ast27x0_bootrom.bin → ok:input
_mk "$_RT/ob_res_pcbios"; : > "$_RT/ob_res_pcbios/ast27x0_bootrom.bin"
resolve_custom_pcbios_candidate "$_RT/ob_res_pcbios" _pres
assert_eq "pcbios: 直接含 bootrom → ok:input" "$_pres" "ok:$_RT/ob_res_pcbios"
# 目录 + 嵌套 pc-bios/ 含 bootrom → ok:input/pc-bios
_mk "$_RT/ob_res_pcbios2/pc-bios"; : > "$_RT/ob_res_pcbios2/pc-bios/ast27x0_bootrom.bin"
resolve_custom_pcbios_candidate "$_RT/ob_res_pcbios2" _pres
assert_eq "pcbios: 嵌套 pc-bios → ok:input/pc-bios" "$_pres" "ok:$_RT/ob_res_pcbios2/pc-bios"
# 目录 + 无 bootrom → err_no_bootrom
_mk "$_RT/ob_res_pcbios3"
resolve_custom_pcbios_candidate "$_RT/ob_res_pcbios3" _pres
assert_eq "pcbios: 无 bootrom → err_no_bootrom" "$_pres" "err_no_bootrom"
# 非 dir → err_not_dir
resolve_custom_pcbios_candidate "$_RT/ob_res_nope" _pres
assert_eq "pcbios: 非 dir → err_not_dir" "$_pres" "err_not_dir"
rm -rf "$_RT/ob_res_pcbios" "$_RT/ob_res_pcbios2" "$_RT/ob_res_pcbios3"

assert_summary
