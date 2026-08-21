#!/usr/bin/env bash
# tests/protocol/test_qemu_surface.sh — ob test-qemu protocol surface 断言(零 QEMU, 毫秒级)。
#   (1) 命令注册: ob test-qemu --help 含 test-qemu
#   (2) parse_args 私有参数穿透(评审 🔴1): --suite/--ar/--report 越过全局 option parser,
#       不被 "Unknown option" 拦, 到达 cmd_test_qemu 首个缺失前置 → exit 3
#       (具体落点由 (6) hermetic 锁定为 baseline-first; 此处只断言环境无关的 rc=3)
#   (3) machine 必填(评审 🟡5): ob test-qemu 无 machine → exit 3
#   (4) 谱系路由(评审 🔴2 → ADR-0026 改写, 直测 leaf-pure helper, 零 QEMU):
#       test_qemu_lineage 判定(source label 单维度: custom→custom, community→community) +
#       test_qemu_resolve_lineage strict 解析(ADR-0026 2026-08-18 修订: manifest 缺失/
#       字段空 → unknown fail-closed, 不 fallback community) +
#       test_qemu_resolve_baseline_dir 路由(community→tests/, custom→contexts/,
#       不跨谱系回退, 缺 → MISSING)—— 重排后 cmd 层 baseline remedy 无 QEMU 即可测,
#       见 (6); helper 直测保留覆盖路由分支细节。
#   (5) cmd_test_qemu --help 直调: 语义断言(usage 含 Usage: 行)+ radar trace 补偿
#       (6) baseline-first hermetic: fake 根 custom label 无 baseline dir → baseline
#       remedy 先于 liveness; (7) dry-run 前置集豁免: 无 QEMU/无凭据 exit 0 列 AR;
#       (8) probe 模式凭据前置: baseline 在 + auth/env 双缺 + 无 QEMU → 凭据 remedy
#       先于 liveness。(6)(7)(8) 共同锁定前置排序: 本地可判定前置(baseline/凭据)
#       先于 QEMU 运行态, dry-run 豁免 QEMU/凭据。
#       (coverage_matrix 备注"exit 函数 radar 低估": "$OB" 子进程 xtrace 不穿透,
#       当前进程直调对齐 bare_mirror 顶层调用补偿先例; 子 shell 封装防 exit 边界)。
set -uo pipefail
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# (1) 命令注册: --help 含 test-qemu
out=$("$OB" test-qemu --help 2>&1) || true
assert_true "test-qemu registered (--help mentions test-qemu)" grep -q "test-qemu" <<<"$out"

# (1b) smoke suite surface(ADR-0028 收编): --help 提及内建 smoke suite;
#      旧 `ob smoke` 顶层命令已退役 — 主 usage 不再注册该命令。
assert_true "--suite 说明提及 smoke suite" grep -q "smoke" <<<"$out"
_obhelp=$("$OB" --help 2>&1) || true
assert_false "顶层 usage 无 ob smoke 命令残留" grep -qE "^  smoke " <<<"$_obhelp"

# (2) parse_args 私有参数穿透(🔴1): --suite/--ar/--report 越过全局 parser, 不被 Unknown option 拦
_tq_p1="$(mktemp)"; _tq_p2="$(mktemp)"   # mktemp(评审 🟢3): 多用户并行跑 protocol 不互踩 /tmp 固定名
rc=0; "$OB" test-qemu fake-m --suite users --ar BMC-3-1-2 --report "$_tq_p1" >"$_tq_p2" 2>&1 || rc=$?
assert_false "private flags NOT blocked as 'Unknown option'" grep -qi "Unknown option" "$_tq_p2"
assert_eq "private flags reach cmd_test_qemu (exit 3 at first missing precondition)" "$rc" "3"
rm -f "$_tq_p1" "$_tq_p2"

# (3) machine 必填(🟡5): 无 machine → exit 3
rc=0; "$OB" test-qemu </dev/null >/tmp/tq_nomachine.run 2>&1 || rc=$?
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
assert_true "cmd_test_qemu -h renders usage (Usage: ob test-qemu)" grep -q "Usage: ./ob test-qemu" <<<"$out"

# (6) cmd 层 baseline-first hermetic 直测(前置重排): fake 根注入 OB_ENTRY_DIR
#     (用例 (5) 已验证的全局注入模式), custom label + 无 baseline dir + 无 QEMU →
#     exit 3 落 baseline remedy 而非 liveness remedy。hermetic: 不依赖宿主真实
#     openbmc-source.manifest(workspace/ gitignore, 干净 checkout 无此文件,
#     宿主 label 环境相关 — 用例 (2) 的 remedy 文案因此不可断言)。
#     env-prefix 只在函数执行期间生效; detect_harness_root 依它重设的路径全局
#     会残留, (6)(7)(8) 均用 env-prefix 注入 fake root — 每个 case 独立重设
#     detect_harness_root 所需路径, 后继 case 不依赖前 case 的残留。
_tq_bf_root="$(mktemp -d)"
mkdir -p "$_tq_bf_root/workspace/configs"
printf 'source_label=custom\n' > "$_tq_bf_root/workspace/configs/openbmc-source.manifest"
rc=0; out=$(MACHINE=fake-m OB_ENTRY_DIR="$_tq_bf_root" cmd_test_qemu 2>&1) || rc=$?
assert_eq "no-baseline no-QEMU → exit 3" "$rc" "3"
assert_true "baseline remedy first (reorder)" grep -q "No baseline dir for 'fake-m'" <<<"$out"
assert_false "liveness remedy not reached" grep -q "No QEMU instance running" <<<"$out"
rm -rf "$_tq_bf_root"

# (7) cmd 层 dry-run 前置集豁免: 无 QEMU、无凭据(env unset + YAML auth 删除) → exit 0 列 AR。
#     runner run.sh DRY_RUN 分支原生豁免 host/port/凭据; fake 根同 (6) 注入模式,
#     community label → tests/baseline/fake-m(复制真实 romulus 基线保 schema 真实,
#     再删 auth 使凭据豁免可证 — 否则 YAML auth 会掩盖"凭据段未豁免"的实现错误;
#     planner 不依赖 auth)。cp 在 OB_ENTRY_DIR 覆盖前用真实根取源(env-prefix 只在
#     cmd_test_qemu 执行期间生效, 不改进程变量)。否定断言必须 assert_false —
#     assert_true 直接执行 "$@", "! " 作参数传入会执行名为 "!" 的命令必失败。
_tq_dry_root="$(mktemp -d)"
mkdir -p "$_tq_dry_root/workspace/configs" "$_tq_dry_root/tests/baseline"
printf 'source_label=community\n' > "$_tq_dry_root/workspace/configs/openbmc-source.manifest"
cp -r "$OB_ENTRY_DIR/tests/baseline/romulus" "$_tq_dry_root/tests/baseline/fake-m"
# 共享 runner(ADR-0027): runner 不再随 machine 目录, fake 根须补齐, 否则 cmd 层
# 调 $root/tests/baseline/runner/run.sh 落空。
cp -r "$OB_ENTRY_DIR/tests/baseline/runner" "$_tq_dry_root/tests/baseline/runner"
python3 - "$_tq_dry_root/tests/baseline/fake-m/ar_probes.yaml" <<'PY'
import sys, yaml
p = sys.argv[1]
d = yaml.safe_load(open(p)) or {}
d.pop("auth", None)
yaml.safe_dump(d, open(p, "w"), allow_unicode=True, sort_keys=False)
PY
unset OB_TQ_USER OB_TQ_PASSWORD
rc=0; out=$(MACHINE=fake-m OB_ENTRY_DIR="$_tq_dry_root" cmd_test_qemu --dry-run 2>&1) || rc=$?
assert_eq "dry-run without QEMU/creds → exit 0" "$rc" "0"
assert_true "dry-run lists ARs (runner dry-run banner)" grep -q "dry-run: AR list" <<<"$out"
assert_false "dry-run touches no liveness" grep -q "No QEMU instance running" <<<"$out"
assert_false "dry-run touches no credentials gate" grep -q "No Redfish user" <<<"$out"
rm -rf "$_tq_dry_root"

# (8) probe 模式凭据前置持久回归(凭据段前移): baseline 在 + auth 删除 + env unset +
#     无 QEMU, 不带 --dry-run → 凭据 remedy 先于 liveness remedy。与 (7) 同构 fake 根
#     但走 probe 模式: 若凭据段被挪回 QEMU liveness 之后, 此处会先报
#     "No QEMU instance running" 而红 — 锁定"本地可判定前置先于 QEMU 运行态"。
_tq_cred_root="$(mktemp -d)"
mkdir -p "$_tq_cred_root/workspace/configs" "$_tq_cred_root/tests/baseline"
printf 'source_label=community\n' > "$_tq_cred_root/workspace/configs/openbmc-source.manifest"
cp -r "$OB_ENTRY_DIR/tests/baseline/romulus" "$_tq_cred_root/tests/baseline/fake-m"
cp -r "$OB_ENTRY_DIR/tests/baseline/runner" "$_tq_cred_root/tests/baseline/runner"   # 共享 runner(ADR-0027), 同 (7)
python3 - "$_tq_cred_root/tests/baseline/fake-m/ar_probes.yaml" <<'PY'
import sys, yaml
p = sys.argv[1]
d = yaml.safe_load(open(p)) or {}
d.pop("auth", None)
yaml.safe_dump(d, open(p, "w"), allow_unicode=True, sort_keys=False)
PY
unset OB_TQ_USER OB_TQ_PASSWORD
rc=0; out=$(MACHINE=fake-m OB_ENTRY_DIR="$_tq_cred_root" cmd_test_qemu 2>&1) || rc=$?
assert_eq "probe no-creds no-QEMU → exit 3" "$rc" "3"
assert_true "credentials remedy before liveness" grep -q "No Redfish user" <<<"$out"
assert_false "liveness remedy not reached" grep -q "No QEMU instance running" <<<"$out"
rm -rf "$_tq_cred_root"

assert_summary
