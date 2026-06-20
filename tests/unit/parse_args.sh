#!/usr/bin/env bash
# tests/unit/parse_args.sh — parse_args 全选项单测(unit 层,exit 函数,子进程捕获全局)。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# 子进程 source ob + parse_args + 断言全局条件:rc 0=条件满足 / 99=不满足 / parse_args 自身 exit 码
_pa() { local cond="$1"; shift
    bash -c 'OB_NO_MAIN=1 source "$1"; shift; parse_args "$@"; '"$cond"' && exit 0 || exit 99' _ "$OB" "$@"; }
pa_rc() { local exp="$1" label="$2" cond="$3"; shift 3
    local rc=0; _pa "$cond" "$@" >/dev/null 2>&1 || rc=$?
    [[ "$rc" == "$exp" ]] && _assert_ok "$label (rc=$rc)" || _assert_bad "$label (rc=$rc want $exp)"; }

pa_rc 0 "no args → COMMAND empty"        '[[ -z "$COMMAND" ]]'
pa_rc 0 "build → COMMAND=build"          '[[ "$COMMAND" == build ]]'            build
pa_rc 0 "init romulus"                   '[[ "$COMMAND" == init && "$MACHINE" == romulus ]]' init romulus
pa_rc 0 "init --dry-run sets DRY_RUN"    '[[ "$DRY_RUN" == 1 ]]'                init romulus --dry-run
pa_rc 0 "start-qemu ports/no-wait"       '[[ "$QEMU_SSH_PORT" == 2222 && "$QEMU_NO_WAIT" == 1 ]]' start-qemu romulus --ssh-port 2222 --no-wait
pa_rc 0 "--help"                         'true'                                 --help
pa_rc 0 "-h"                             'true'                                 -h
pa_rc 1 "unknown command"                'true'                                 bogus-cmd
pa_rc 1 "unknown opt"                    'true'                                 start-qemu --bogus-opt
pa_rc 1 "missing --ssh-port val"         'true'                                 start-qemu --ssh-port
pa_rc 1 "missing --url val"              'true'                                 build --url

assert_summary
