#!/usr/bin/env bash
# tools/smoke_regression.sh — α-safe temporal CI 回归闸门(改前/改后两次 smoke suite 时序比对)。
#
# 链路(ADR-0028: ob smoke 已收编为 ob test-qemu --suite smoke):
#   校验 <machine> 有在跑的 QEMU 实例(ob test-qemu 自带前置, exit 3 = 无实例) →
#   捕获 baseline smoke suite JSON report(运行时临时文件) → 执行 <change-cmd> →
#   重新捕获 current → tools/smoke_diff.py baseline current →
#   按 diff 的 exit 0/1 透传为 gate 的 exit 0/1。
#
# 【边界: α-safety(最关键)】
#   baseline/current 都是**运行时临时产物**(mktemp, 同机改前/改后两次 smoke suite 的时序比对),
#   绝不引入受版本管理、以具体 machine 命名的 baseline/profile 文件——那是 ADR-0020 option-3
#   明确拒绝的「per-machine expected-profile」形态(spatial 期望)。本闸门是 ADR-0020 option-1
#   背书的 **temporal diff**(机器无关, gate 归 caller 侧)。
#
# 【边界: 不拥有 QEMU 生命周期】
#   probe-only 假设: 实例全程在跑。本脚本不 start/stop QEMU(ob 优先——
#   生命周期归 ob start-qemu/stop-qemu)。ob test-qemu exit 3(前置缺失, 无在跑实例/infra
#   ERROR)→ 透传 exit 3 + remedy(指向 ob start-qemu), 不当成 gate 失败, 也不把 ERROR
#   report 交给 diff 后误放行。
#
# 【exit 语义】 透传 ob 约定的 0/1/2/3:
#   0 = 无回归(diff 放行); 1 = 检出回归(diff 拦截, pass→fail 或 新出现的 fail);
#   2 = 参数/工具错误; 3 = 前置缺失(无在跑 QEMU 实例, 先 ob start-qemu)。
#   注: ob test-qemu 自身 exit 1(某 AR fail, 合法真相)不算 gate 失败——
#   只要 baseline 与 current 两边一致(无退化), gate 仍 exit 0。gate 的 exit 由 diff 决定。
#
# 【可测性】 capture 经 PATH 找 `ob`(command -v ob, 测试时注入 stub `ob`);
#   未在 PATH 时回退仓库根 ./ob。capture 封成 _sr_capture 便于 stub 注入。
#
# 用法:
#   tools/smoke_regression.sh <machine> -- <change-cmd...>
#   tools/smoke_regression.sh b865g8-a2-bytedance -- true          # no-op: baseline vs current 应无退化
#   tools/smoke_regression.sh romulus -- ob deploy-to-qemu romulus  # 改后比对
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIFF_TOOL="$REPO_ROOT/tools/smoke_diff.py"

# ob 优先: 优先 PATH 里的 ob(测试 stub / 已安装), 否则回退仓库根 ./ob
if command -v ob >/dev/null 2>&1; then
    OB_CMD="ob"
else
    OB_CMD="$REPO_ROOT/ob"
fi

# 运行时临时产物(mktemp, 随进程消失; 绝不落盘 machine 命名 baseline)
TMP_FILES=()
_sr_cleanup() {
    local f
    for f in "${TMP_FILES[@]:-}"; do
        [[ -n "$f" ]] || continue
        rm -f "$f" 2>/dev/null || true
    done
}
trap _sr_cleanup EXIT

# _sr_capture <machine> <outfile> — 跑 ob test-qemu --suite smoke --report, JSON 落 outfile, 返回 0/2/3。
#   ob test-qemu rc 0/1 = α 真相(1 = 某 AR fail, 合法)→ 捕获 report, 返回 0(继续);
#   rc 3 = 前置缺失/infra ERROR → 把 remedy(已打到终端)透传给 caller, 返回 3
#     (不把 ERROR report 交给 diff — error 记录被丢弃后 diff 会误放行);
#   其他 = 异常 → 返回 2。
_sr_capture() {
    local machine="$1" outfile="$2" rc=0
    "$OB_CMD" test-qemu "$machine" --suite smoke --report "$outfile" || rc=$?
    case "$rc" in
        0|1) return 0 ;;
        3) return 3 ;;
        *)
            echo "smoke_regression: 'ob test-qemu $machine --suite smoke' exited $rc unexpectedly:" >&2
            return 2 ;;
    esac
}

_sr_usage() {
    cat <<'EOF'
Usage: tools/smoke_regression.sh <machine> -- <change-cmd...>
  α-safe temporal CI gate: baseline smoke suite report → change-cmd → current report → diff.
  Exit: 0 = no regression; 1 = regression (pass→fail or new fail); 2 = usage/error; 3 = no running QEMU instance.
Examples:
  tools/smoke_regression.sh b865g8-a2-bytedance -- true
  tools/smoke_regression.sh romulus -- ob deploy-to-qemu romulus
EOF
}

main() {
    # ── 解析: <machine> -- <change-cmd...> ──
    if [[ $# -lt 2 ]]; then
        case "${1:-}" in -h|--help) _sr_usage; exit 0 ;; esac
        _sr_usage >&2; exit 2
    fi

    local machine="" change_cmd=() seen_sep=0
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--" ]]; then
            seen_sep=1; shift; change_cmd=("$@"); break
        fi
        case "$1" in
            -h|--help) _sr_usage; exit 0 ;;
            *) if [[ -z "$machine" ]]; then machine="$1"; else _sr_usage >&2; exit 2; fi ;;
        esac
        shift
    done

    if [[ -z "$machine" || $seen_sep -eq 0 ]]; then
        _sr_usage >&2; exit 2
    fi
    # 空 change-cmd 默认 no-op(baseline vs current 双采, 亦可用于 flap 检测)
    if [[ ${#change_cmd[@]} -eq 0 ]]; then
        change_cmd=(true)
    fi

    # ── 临时快照文件(mktemp, 尊重 $TMPDIR) ──
    local base_file cur_file
    base_file="$(mktemp)" || { echo "smoke_regression: mktemp failed" >&2; exit 2; }
    cur_file="$(mktemp)"  || { echo "smoke_regression: mktemp failed" >&2; exit 2; }
    TMP_FILES+=("$base_file" "$cur_file")

    # ── baseline 捕获 ──
    echo "smoke_regression: capturing baseline (ob test-qemu --suite smoke)..." >&2
    local brc=0
    _sr_capture "$machine" "$base_file" || brc=$?
    if [[ $brc -ne 0 ]]; then
        echo "smoke_regression: baseline capture aborted (exit $brc)." >&2
        return "$brc"
    fi

    # ── 执行 change-cmd(失败不杀 gate: 仍采 current 比对; 仅 warn) ──
    echo "smoke_regression: running change command: ${change_cmd[*]}" >&2
    local crc=0
    "${change_cmd[@]}" || crc=$?
    if [[ $crc -ne 0 ]]; then
        echo "smoke_regression: change command exited $crc (proceeding to current capture)." >&2
    fi

    # ── current 捕获 ──
    echo "smoke_regression: capturing current (ob test-qemu --suite smoke)..." >&2
    local krc=0
    _sr_capture "$machine" "$cur_file" || krc=$?
    if [[ $krc -ne 0 ]]; then
        echo "smoke_regression: current capture aborted (exit $krc)." >&2
        return "$krc"
    fi

    # ── temporal diff(ADR-0020 option-1): exit 0/1 透传为 gate 的 exit ──
    echo "smoke_regression: diffing baseline vs current..." >&2
    python3 "$DIFF_TOOL" "$base_file" "$cur_file"
}

main "$@"
