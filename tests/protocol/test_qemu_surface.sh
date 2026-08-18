#!/usr/bin/env bash
# tests/protocol/test_qemu_surface.sh — ob test-qemu protocol surface 断言(零 QEMU, 毫秒级)。
#   (1) 命令注册: ob test-qemu --help 含 test-qemu
#   (2) parse_args 私有参数穿透(评审 🔴1): --suite/--ar/--report 越过全局 option parser,
#       不被 "Unknown option" 拦, 到达 cmd_test_qemu 的 liveness 前置 → exit 3
#   (3) machine 必填(评审 🟡5): ob test-qemu 无 machine → exit 3
#   (4) 谱系路由(评审 🔴2 → ADR-0026 改写, 直测 leaf-pure helper, 零 QEMU):
#       test_qemu_lineage 判定(source label 单维度: custom→custom, community→community) +
#       test_qemu_resolve_lineage strict 解析(ADR-0026 2026-08-18 修订: manifest 缺失/
#       字段空 → unknown fail-closed, 不 fallback community) +
#       test_qemu_resolve_baseline_dir 路由(community→tests/, custom→contexts/,
#       不跨谱系回退, 缺 → MISSING)—— cmd 层的 "No baseline dir" remedy 需先过
#       liveness, 属 integration, 不在此测。
#   (5) cmd_test_qemu --help 直调: 语义断言(usage 含 Usage: 行)+ radar trace 补偿
#       (coverage_matrix 备注"exit 函数 radar 低估": "$OB" 子进程 xtrace 不穿透,
#       当前进程直调对齐 bare_mirror 顶层调用补偿先例; 子 shell 封装防 exit 边界)。
set -uo pipefail
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# (1) 命令注册: --help 含 test-qemu
out=$("$OB" test-qemu --help 2>&1) || true
assert_true "test-qemu registered (--help mentions test-qemu)" grep -q "test-qemu" <<<"$out"

# (2) parse_args 私有参数穿透(🔴1): --suite/--ar/--report 越过全局 parser, 不被 Unknown option 拦
_tq_p1="$(mktemp)"; _tq_p2="$(mktemp)"   # mktemp(评审 🟢3): 多用户并行跑 protocol 不互踩 /tmp 固定名
rc=0; "$OB" test-qemu fake-m --suite users --ar BMC-3-1-2 --report "$_tq_p1" >"$_tq_p2" 2>&1 || rc=$?
assert_false "private flags NOT blocked as 'Unknown option'" grep -qi "Unknown option" "$_tq_p2"
assert_eq "private flags reach cmd_test_qemu (exit 3 at liveness, no instance)" "$rc" "3"
rm -f "$_tq_p1" "$_tq_p2"

# (3) machine 必填(🟡5): 无 machine → exit 3
rc=0; "$OB" test-qemu >/tmp/tq_nomachine.run 2>&1 || rc=$?
assert_eq "no machine → exit 3" "$rc" "3"

# (4) 谱系路由(🔴2 → ADR-0026 改写, 零 QEMU 直测 leaf-pure helper)
TMP="$(mktemp -d)"
_tq_helper_lineage_routing() {
    local out=""
    HARNESS_ROOT="$TMP"

    # 4a. test_qemu_lineage 判定(单维度: source label 唯一权威; binary 目录由 label
    #     派生完全共线, 不构成独立信号 — ADR-0026): 字面二值 + unknown 防御
    test_qemu_lineage "community" out
    [[ "$out" == "community" ]] || { echo "lineage-community FAIL: got '$out'" >&2; return 1; }
    test_qemu_lineage "custom" out
    [[ "$out" == "custom" ]] || { echo "lineage-custom FAIL: got '$out'" >&2; return 1; }
    test_qemu_lineage "garbage" out
    [[ "$out" == "unknown" ]] || { echo "lineage-unknown FAIL: got '$out'" >&2; return 1; }
    test_qemu_lineage "" out
    [[ "$out" == "unknown" ]] || { echo "lineage-empty FAIL: got '$out'" >&2; return 1; }

    # 4a2. test_qemu_resolve_lineage strict 解析(ADR-0026 2026-08-18 修订): 谱系消费点
    #      绕过 read_source_label 的 community fallback(它把缺失映射成 community 后真假
    #      莫辨) — manifest 缺失/字段空 → unknown fail-closed; 字段非空 → 二值判定
    local _saved_smf="${SOURCE_MANIFEST_FILE:-}"
    printf 'source_label=custom\n' >"$TMP/mf.custom"
    printf 'source_label=community\n' >"$TMP/mf.community"
    printf 'source_label=garbage\n' >"$TMP/mf.garbage"
    printf 'normalized_source=x\n' >"$TMP/mf.nofield"   # 文件在, source_label 字段缺
    SOURCE_MANIFEST_FILE="$TMP/mf.custom"
    test_qemu_resolve_lineage out
    [[ "$out" == "custom" ]] || { echo "rl-custom FAIL: got '$out'" >&2; return 1; }
    SOURCE_MANIFEST_FILE="$TMP/mf.community"
    test_qemu_resolve_lineage out
    [[ "$out" == "community" ]] || { echo "rl-community FAIL: got '$out'" >&2; return 1; }
    SOURCE_MANIFEST_FILE="$TMP/mf.garbage"
    test_qemu_resolve_lineage out
    [[ "$out" == "unknown" ]] || { echo "rl-garbage FAIL: got '$out'" >&2; return 1; }
    SOURCE_MANIFEST_FILE="$TMP/mf.nofield"
    test_qemu_resolve_lineage out
    [[ "$out" == "unknown" ]] || { echo "rl-empty-field FAIL: got '$out'" >&2; return 1; }
    SOURCE_MANIFEST_FILE="$TMP/no-such-manifest"
    test_qemu_resolve_lineage out
    [[ "$out" == "unknown" ]] || { echo "rl-no-file FAIL: got '$out'" >&2; return 1; }
    SOURCE_MANIFEST_FILE="$_saved_smf"

    # 4b. 路由: community 谱系 → tests/, 即使 contexts/ 也存在(不跨谱系回退/覆盖)
    mkdir -p "$TMP/contexts/baseline/fake-m" "$TMP/tests/baseline/fake-m"
    test_qemu_resolve_baseline_dir community fake-m out
    [[ "$out" == "$TMP/tests/baseline/fake-m" ]] || { echo "community-routed FAIL: got '$out'" >&2; return 1; }
    # 4c. 路由: custom 谱系 → contexts/, 即使 tests/ 也存在
    test_qemu_resolve_baseline_dir custom fake-m out
    [[ "$out" == "$TMP/contexts/baseline/fake-m" ]] || { echo "custom-routed FAIL: got '$out'" >&2; return 1; }
    # 4d. 本谱系目录缺失 → MISSING(不回退他谱系目录)
    rm -rf "$TMP/contexts/baseline/fake-m"
    test_qemu_resolve_baseline_dir custom fake-m out
    [[ "$out" == "MISSING" ]] || { echo "custom-no-fallback FAIL: got '$out'" >&2; return 1; }
    rm -rf "$TMP/tests/baseline/fake-m"
    test_qemu_resolve_baseline_dir community fake-m out
    [[ "$out" == "MISSING" ]] || { echo "community-missing FAIL: got '$out'" >&2; return 1; }
    # 4e. 非法谱系值 → MISSING(防御: cmd 层不会传, helper 不 crash)
    test_qemu_resolve_baseline_dir bogus fake-m out
    [[ "$out" == "MISSING" ]] || { echo "bogus-lineage FAIL: got '$out'" >&2; return 1; }
    return 0
}
_tq_helper_lineage_routing; _hrc=$?
rm -rf "$TMP"
assert_eq "helper lineage routing (community→tests/, custom→contexts/, no cross-fallback, MISSING)" "$_hrc" "0"

# (5) cmd_test_qemu --help 直调: 语义(usage 渲染) + radar trace 补偿(exit seam 经 "$OB"
#     子进程的调用 xtrace 不可见, 当前进程子 shell 直调可见 — PS4 FUNCNAME 正常展开;
#     detect_harness_root 消费 OB_ENTRY_DIR 全局, 与 cwd 无关)
out=$(cmd_test_qemu -h 2>&1)
assert_true "cmd_test_qemu -h renders usage (Usage: ob test-qemu)" grep -q "Usage: ob test-qemu" <<<"$out"

assert_summary
