#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../lib/assert.sh"
assert_reset
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RENDER="$ROOT/lib/status_render.sh"
test -f "$RENDER" || { echo "MISSING $RENDER" >&2; exit 1; }

# §7 interface-shrink + 调用面锁:status_render.sh 内 forbidden token 必须 0 命中(渲染器纯格式化层)。
# forbidden 只取 bash 标识符族 + 完整 git 子命令前缀;禁用裸英文词(裸 fetch / git 带空格会误伤
# 将来 renderer 文案如 "fetch latest firmware" / "dig into git log")。命中即真违规,零误报。
forbidden=( 'OPENBMC_DIR' 'SOURCE_MANIFEST_FILE' 'machine_state_' 'qemu_instance_' \
            'read_manifest_field' 'read_kv_field' \
            'git -C' 'git fetch' 'git remote' 'git rev-' 'git log' 'timeout ' )
# 只 grep 非注释行:header docstring 列了 forbidden token 作"不读"说明,裸 grep 会误伤。
body="$(grep -v '^[[:space:]]*#' "$RENDER")"
for tok in "${forbidden[@]}"; do
    assert_false "render forbids $tok" grep -Fq "$tok" <<< "$body"
done
assert_summary
