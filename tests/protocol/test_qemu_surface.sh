#!/usr/bin/env bash
# tests/protocol/test_qemu_surface.sh — ob test-qemu protocol surface 断言(零 QEMU, 毫秒级)。
#   (1) 命令注册: ob test-qemu --help 含 test-qemu
#   (2) parse_args 私有参数穿透(评审 🔴1): --suite/--ar/--report 越过全局 option parser,
#       不被 "Unknown option" 拦, 到达 cmd_test_qemu 的 liveness 前置 → exit 3
#   (3) machine 必填(评审 🟡5): ob test-qemu 无 machine → exit 3
#   (4) test_qemu_resolve_baseline_dir 目录优先级(评审 🔴2, 直测 leaf-pure helper, 零 QEMU):
#       contexts/baseline/<m> (custom, 优先) > tests/baseline/<m> (community) > MISSING
#       —— cmd 层的 "No baseline dir" remedy 需先过 liveness, 属 integration, 不在此测。
set -uo pipefail
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# (1) 命令注册: --help 含 test-qemu
out=$("$OB" test-qemu --help 2>&1) || true
assert_true "test-qemu registered (--help mentions test-qemu)" grep -q "test-qemu" <<<"$out"

# (2) parse_args 私有参数穿透(🔴1): --suite/--ar/--report 越过全局 parser, 不被 Unknown option 拦
rc=0; "$OB" test-qemu fake-m --suite users --ar BMC-3-1-2 --report /tmp/tq_proto.out >/tmp/tq_proto.run 2>&1 || rc=$?
assert_false "private flags NOT blocked as 'Unknown option'" grep -qi "Unknown option" /tmp/tq_proto.run
assert_eq "private flags reach cmd_test_qemu (exit 3 at liveness, no instance)" "$rc" "3"

# (3) machine 必填(🟡5): 无 machine → exit 3
rc=0; "$OB" test-qemu >/tmp/tq_nomachine.run 2>&1 || rc=$?
assert_eq "no machine → exit 3" "$rc" "3"

# (4) test_qemu_resolve_baseline_dir 目录优先级(🔴2, 零 QEMU 直测 leaf-pure helper)
TMP="$(mktemp -d)"
_tq_helper_priority() {
    local out=""
    HARNESS_ROOT="$TMP"
    # 双目录都在 → custom (contexts) 优先
    mkdir -p "$TMP/contexts/baseline/fake-m" "$TMP/tests/baseline/fake-m"
    test_qemu_resolve_baseline_dir fake-m out
    [[ "$out" == "$TMP/contexts/baseline/fake-m" ]] || { echo "custom-prefer FAIL: got '$out'" >&2; return 1; }
    # 删 custom → community (tests) 回退
    rm -rf "$TMP/contexts/baseline/fake-m"
    test_qemu_resolve_baseline_dir fake-m out
    [[ "$out" == "$TMP/tests/baseline/fake-m" ]] || { echo "community-fallback FAIL: got '$out'" >&2; return 1; }
    # 都删 → MISSING
    rm -rf "$TMP/tests/baseline/fake-m"
    test_qemu_resolve_baseline_dir fake-m out
    [[ "$out" == "MISSING" ]] || { echo "missing FAIL: got '$out'" >&2; return 1; }
    return 0
}
_tq_helper_priority; _hrc=$?
rm -rf "$TMP"
assert_eq "helper baseline dir priority (custom > community > MISSING)" "$_hrc" "0"

assert_summary
