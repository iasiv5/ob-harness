#!/usr/bin/env bash
# tests/unit/devtool_status.sh — devtool_status_run 单测(env_exec → 全量解析 → outvar)。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"; export TMP; trap 'rm -rf "$TMP"' EXIT
_dsr_machine="testm" _dsr_build="$TMP/build"

# mock _devtool_env_exec: 把 status 内容写进 stdout_file($4)
_devtool_env_exec() {
    local m="$1" b="$2" sf="$3" of="$4" erf="$5"; shift 5; [[ "$1" == "--" ]] && shift
    echo command > "$sf"
    printf 'ipmi-host: %s/workspace/sources/ipmi-host (recipes-core/ipmi-host.bb)\n' "$_dsr_build" > "$of"
    printf 'web: %s/workspace/sources/web\n' "$_dsr_build" >> "$of"
    return 0
}
_status_entries="" _status_stage="" _status_stderr=""
devtool_status_run "$_dsr_machine" "$_dsr_build" _status_entries _status_stage _status_stderr
assert_eq "status_run rc 0" "$?" "0"
assert_eq "status_run stage=command" "$_status_stage" "command"
assert_eq "status_run entries 行数" "$(printf '%s\n' "$_status_entries" | grep -c .)" "2"
assert_contains "status_run entries ipmi-host" "$_status_entries" $'ipmi-host\t'"$_dsr_build/workspace/sources/ipmi-host"
rm -f "$_status_stderr"
# rc 失败(command 阶段) → entries 空 + rc 非零 + stage 传播
_devtool_env_exec() { local sf="$3" of="$4"; echo command > "$sf"; : > "$of"; return 1; }
devtool_status_run "$_dsr_machine" "$_dsr_build" _status_entries _status_stage _status_stderr
assert_false "status_run rc 失败返回非零" test $? -eq 0
assert_eq "status_run 失败时 entries 空" "$_status_entries" ""
assert_eq "status_run 失败 stage=command" "$_status_stage" "command"
rm -f "$_status_stderr"
# stage 失败(postcondition, build env 未 ready) → stage 传播 + entries 空 + rc 非零
_devtool_env_exec() { local sf="$3" of="$4"; echo postcondition > "$sf"; : > "$of"; return 1; }
devtool_status_run "$_dsr_machine" "$_dsr_build" _status_entries _status_stage _status_stderr
assert_false "status_run postcondition 失败返回非零" test $? -eq 0
assert_eq "status_run postcondition stage 传播" "$_status_stage" "postcondition"
assert_eq "status_run postcondition entries 空" "$_status_entries" ""
rm -f "$_status_stderr"

assert_summary
