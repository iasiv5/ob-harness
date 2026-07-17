#!/usr/bin/env bash
# shellcheck disable=SC1091
# tests/integration/ob_dev.sh — ob dev real integration (opt-in via --integration).
# 覆盖: modify/srctree + reset(moved/retained/noop) + cleanup trap(attic/external/modified recheck)。
# HARNESS_ROOT 仅 source devtool_reset.sh 调 resolve/locate(reset 端到端经 ./ob dev reset)。
# 安全: 入口清空继承的 EXTERNAL_SRCTREE(只清本次 mktemp 设的); cleanup 删 attic/external 前做
#       canonical parent + 字面 basename + 所有权校验; 成功路径不吞 cleanup rc。
set -uo pipefail

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# 仅加载 reset + finish leaf helper(resolve/locate/classify + parse_status_entry/resolve_layer_root/capture/detect);
# reset/finish 端到端经 ./ob dev reset|finish
# shellcheck disable=SC1091
source "$HARNESS_ROOT/lib/devtool_reset.sh"
# shellcheck disable=SC1091
source "$HARNESS_ROOT/lib/devtool_finish.sh"

devtool_in_env() {
    local machine="$1"
    shift
    (
        cd "$OPENBMC_DIR" &&
        set +u &&
        source setup "$machine" "$OPENBMC_DIR/build/$machine" >/dev/null 2>&1 &&
        devtool "$@"
    ) 2>/dev/null
}

# ob_dev_integration_status_has_recipe <recipe> <devtool-status-output>
ob_dev_integration_status_has_recipe() {
    local recipe="$1" status_output="$2"
    awk -F': ' -v recipe="$recipe" '$1 == recipe { found=1; exit } END { exit !found }' \
        <<<"$status_output"
}

# reset moved 产生的 attic/sources/<recipe>.<14位ts>(trap 清; 字面 basename + canonical parent 校验)
declare -a _ATTIC_DIRS=()
_EFF_WS=""   # effective workspace(main 设; cleanup 算 canonical attic root 用)

# _integration_attic_snapshot <eff_ws> <outfile> → find rc(把 attic/sources 下 maxdepth1 目录 NUL 写 outfile)
# 不存在 attic/sources → 空快照 rc 0(空集合); find 失败 → rc 非0(调用方必检)
_integration_attic_snapshot() {
    local eff_ws="$1" outfile="$2"
    : > "$outfile"
    [[ -d "$eff_ws/attic/sources" ]] || return 0
    find "$eff_ws/attic/sources" -maxdepth 1 -mindepth 1 -type d -print0 > "$outfile" 2>/dev/null
}

ob_dev_integration_cleanup() {
    local status_output="" status_rc=0

    # attic root canonical(cleanup 删 attic 前校验 parent 精确相等用)
    local _attic_root_canon
    _attic_root_canon="$(cd "${_EFF_WS:-}/attic/sources" 2>/dev/null && pwd -P)"

    # 1. 清 attic 数组(字面 basename "$RECIPE."+恰好14位数字 + canonical parent 精确==attic root)
    local _d _bn _par
    for _d in "${_ATTIC_DIRS[@]:-}"; do
        [[ -n "$_d" && -d "$_d" ]] || continue
        _bn="$(basename "$_d")"
        _par="$(cd "$(dirname "$_d")" 2>/dev/null && pwd -P)" || continue
        if [[ -n "$_attic_root_canon" && "$_par" == "$_attic_root_canon" \
              && "$_bn" == "$RECIPE".[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9] ]]; then
            rm -rf -- "$_d"
        fi
    done
    _ATTIC_DIRS=()

    # 2. 清 external srctree(仅本次 mktemp 设 + canonical parent 在 TMPDIR; 入口已清空继承值, 双重保险)
    if [[ -n "${EXTERNAL_SRCTREE:-}" && -d "$EXTERNAL_SRCTREE" ]]; then
        local _ext_canon _ext_tmp
        _ext_canon="$(cd "$EXTERNAL_SRCTREE" 2>/dev/null && pwd -P)"
        _ext_tmp="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
        if [[ -n "$_ext_canon" && "$(dirname "$_ext_canon")" == "$_ext_tmp" ]]; then
            rm -rf -- "$EXTERNAL_SRCTREE"
        fi
    fi

    # 3. 清 modified recipe(ADR-0008: 权威 status recheck, 不靠推断)
    [[ "${CLEANUP_NEEDED:-0}" == "1" && -n "${RECIPE:-}" ]] || return 0

    status_output="$(devtool_in_env "$MACHINE" status)" || status_rc=$?
    if [[ "$status_rc" -ne 0 ]]; then
        echo "WARN: cleanup status failed; recipe $RECIPE may remain modified, clean it manually" >&2
        return 1
    fi
    if ! ob_dev_integration_status_has_recipe "$RECIPE" "$status_output"; then
        CLEANUP_NEEDED=0
        return 0
    fi
    if ! devtool_in_env "$MACHINE" reset "$RECIPE" >/dev/null 2>&1; then
        echo "WARN: cleanup reset failed; recipe $RECIPE remains modified, clean it manually" >&2
        return 1
    fi
    CLEANUP_NEEDED=0
    return 0
}

# ob_dev_integration_finish_layer_restore <finish_json>
# 回滚 finish 落回的 layer 改动(recipe_files git restore tracked + patches rm untracked), 相对 OPENBMC_DIR。
# v6: 无 safety copy, finish 复用 reset disposition; 正常 finish 只动 .patch/.bb/.bbappend。
# 主仓库非 git / 路径越界 → 跳过(防误删), 记录由 caller 报告。
ob_dev_integration_finish_layer_restore() {
    local finish_json="$1"
    git -C "$OPENBMC_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    local _files
    _files="$(python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
out = []
for key in ("recipe_files", "patches"):
    for p in (d.get(key) or []):
        if isinstance(p, str) and p and not p.startswith("/") and ".." not in p:
            out.append(p)
print("\n".join(out))
' <<<"$finish_json" 2>/dev/null)" || return 0
    local _f
    while IFS= read -r _f; do
        [[ -n "$_f" ]] || continue
        case "$_f" in
            *.patch) rm -f -- "$OPENBMC_DIR/$_f" 2>/dev/null || true ;;                   # untracked 新增 patch
            *.bb|*.bbappend) git -C "$OPENBMC_DIR" restore -- "$_f" 2>/dev/null || true ;; # tracked recipe 改动
        esac
    done <<<"$_files"
}

# _integration_assert_disposition <stdout> <expected_disposition> [expected_dp_suffix]
_integration_assert_disposition() {
    local out="$1" exp="$2" dp_suffix="${3:-}"
    EXP_DISP="$exp" EXP_DP_SUFFIX="$dp_suffix" python3 -c '
import json, os, sys
d = json.loads(sys.stdin.read())
exp = os.environ["EXP_DISP"]
assert d["disposition"] == exp, ("disposition", d["disposition"], exp)
keys = sorted(d.keys())
assert keys == ["cleaned_bbappend","destination","destination_parent","disposition","recipe","srctree","srctreebase"], keys
if os.environ.get("EXP_DP_SUFFIX"):
    assert d["destination_parent"] is not None and d["destination_parent"].endswith(os.environ["EXP_DP_SUFFIX"]), ("dp", d["destination_parent"])
else:
    assert d["destination_parent"] is None, ("dp not None", d["destination_parent"])
' <<<"$out"
}

# _integration_load_snapshot <outfile> → 数组名 _attic_buf(填充 NUL 目录列表)
_integration_load_snapshot() {
    local outfile="$1"
    _attic_buf=()
    while IFS= read -r -d '' _ad; do _attic_buf+=("$_ad"); done < "$outfile"
}

ob_dev_integration_main() {
    local root_dir refresh_rc list_rc cache_record_count candidates_rc status_rc modify_rc invalid_recipe_rc
    local candidate="" CACHE_OUT="" CANDIDATES="" STATUS_OUT=""

    root_dir="${OB_DEV_INTEGRATION_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
    cd "$root_dir" || exit 1

    OPENBMC_DIR="$(pwd)/workspace/openbmc"
    export OPENBMC_DIR

    # 安全: 清空继承的 EXTERNAL_SRCTREE(防环境传入任意路径被 cleanup 误删; 仅本次 mktemp 设的才清)
    EXTERNAL_SRCTREE=""
    _EFF_WS=""

    MACHINE="${OB_INTEGRATION_MACHINE:-}"
    if [[ -z "$MACHINE" ]]; then
        local machine_marker
        for machine_marker in workspace/configs/*.init-done; do
            [[ -f "$machine_marker" ]] && MACHINE="$(basename "$machine_marker" .init-done)" && break
        done
    fi
    [[ -n "$MACHINE" ]] || { echo "SKIP: no init machine"; exit 77; }
    echo "[integration] machine=$MACHINE openbmc=$OPENBMC_DIR"

    ./ob dev --machine "$MACHINE" refresh >/dev/null 2>&1
    refresh_rc=$?
    [[ "$refresh_rc" -eq 0 ]] || { echo "SKIP: refresh rc=$refresh_rc (build env not ready)"; exit 77; }

    list_rc=0
    CACHE_OUT="$(./ob dev --machine "$MACHINE" list 2>/dev/null)" || list_rc=$?
    [[ "$list_rc" -eq 0 ]] || { echo "FAIL: list rc=$list_rc"; exit 1; }
    cache_record_count="$(awk 'NF { count++ } END { print count + 0 }' <<<"$CACHE_OUT")"
    echo "list records=$cache_record_count"
    [[ "$cache_record_count" -gt 0 ]] || { echo "FAIL: list returned no JSONL records"; exit 1; }

    ./ob dev --machine "$MACHINE" modify nonexistent-recipe-xyz >/dev/null 2>&1
    invalid_recipe_rc=$?
    echo "invalid recipe rc=$invalid_recipe_rc (expect 1)"
    [[ "$invalid_recipe_rc" -eq 1 ]] || { echo "FAIL: invalid recipe should exit 1"; exit 1; }

    candidates_rc=0
    CANDIDATES="$(python3 -c '
import json
import sys

recipes = []
record_count = 0
for line_number, line in enumerate(sys.stdin, 1):
    line = line.strip()
    if not line:
        continue
    try:
        record = json.loads(line)
    except json.JSONDecodeError as error:
        sys.stderr.write(f"invalid JSONL record {line_number}: {error}\n")
        raise SystemExit(1)
    if not isinstance(record, dict) or not isinstance(record.get("recipe"), str) or not record["recipe"]:
        sys.stderr.write(f"invalid JSONL record {line_number}: missing recipe\n")
        raise SystemExit(1)
    record_count += 1
    if len(recipes) < 50:
        recipes.append(record["recipe"])

if record_count == 0:
    sys.stderr.write("list returned no JSONL records\n")
    raise SystemExit(1)
print("\n".join(recipes))
' <<<"$CACHE_OUT")" || candidates_rc=$?
    [[ "$candidates_rc" -eq 0 ]] || { echo "FAIL: list returned invalid JSONL"; exit 1; }

    # 候选/SKIP 前置: devtool status + effective workspace 解析
    status_rc=0
    STATUS_OUT="$(devtool_in_env "$MACHINE" status)" || status_rc=$?
    [[ "$status_rc" -eq 0 ]] || { echo "FAIL: devtool status rc=$status_rc"; exit 1; }

    local _rraw="" _reff="" _rphase=""
    _devtool_reset_resolve_workspace "$OPENBMC_DIR/build/$MACHINE" _rraw _reff _rphase || true
    [[ -n "$_reff" && -z "$_rphase" ]] || { echo "FAIL: resolve workspace phase=$_rphase"; exit 1; }
    _EFF_WS="$_reff"

    # 候选: status 未 modified AND appends/<recipe> 不存在(含 dangling symlink 排除, 防选用户遗留)
    RECIPE=""
    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        if ! ob_dev_integration_status_has_recipe "$candidate" "$STATUS_OUT" \
           && [[ ! -e "$_EFF_WS/appends/$candidate" && ! -L "$_EFF_WS/appends/$candidate" ]]; then
            RECIPE="$candidate"
            break
        fi
    done <<<"$CANDIDATES"
    [[ -n "$RECIPE" ]] || { echo "SKIP: no safe candidate (unmodified + no orphan appends)"; exit 77; }
    echo "modify recipe=$RECIPE (selected unmodified, no orphan appends)"

    CLEANUP_NEEDED=0
    trap ob_dev_integration_cleanup EXIT

    # === reset 段: 同一 RECIPE moved → retained → noop ===
    # moved: managed modify → ob dev reset → moved(attic/sources 出现)
    CLEANUP_NEEDED=1
    modify_rc=0
    SRCTREE="$(./ob dev --machine "$MACHINE" modify "$RECIPE" 2>/dev/null)" || modify_rc=$?
    echo "modify rc=$modify_rc srctree=$SRCTREE"
    [[ "$modify_rc" -eq 0 && -n "$SRCTREE" && -d "$SRCTREE" ]] || { echo "FAIL: modify/srctree"; exit 1; }

    # reset 前 attic/sources 空集合快照(tempfile + find rc 校验; 不存在→空)
    local _snap_file _snap_rc
    _snap_file="$(mktemp)"
    _integration_attic_snapshot "$_EFF_WS" "$_snap_file" || _snap_rc=$?
    [[ "${_snap_rc:-0}" -eq 0 ]] || { rm -f "$_snap_file"; echo "FAIL: attic before-snapshot find rc=$_snap_rc"; exit 1; }
    local -a _attic_before=()
    _integration_load_snapshot "$_snap_file"
    _attic_before=("${_attic_buf[@]}")
    rm -f "$_snap_file"

    local _reset_out="" _reset_rc=0
    _reset_out="$(./ob dev --machine "$MACHINE" reset "$RECIPE" 2>/dev/null)" || _reset_rc=$?
    echo "reset moved rc=$_reset_rc"
    [[ "$_reset_rc" -eq 0 ]] || { echo "FAIL: reset moved rc=$_reset_rc out=$_reset_out"; exit 1; }
    _integration_assert_disposition "$_reset_out" "moved" "attic/sources" || { echo "FAIL: reset moved JSON"; exit 1; }
    CLEANUP_NEEDED=0

    # moved postcondition: attic/sources 恰好新增一个 <RECIPE>.<14位ts>(再次 snapshot + 差集)
    _snap_file="$(mktemp)"; _snap_rc=0
    _integration_attic_snapshot "$_EFF_WS" "$_snap_file" || _snap_rc=$?
    [[ "$_snap_rc" -eq 0 ]] || { rm -f "$_snap_file"; echo "FAIL: attic after-snapshot find rc=$_snap_rc"; exit 1; }
    local -a _attic_after=()
    _integration_load_snapshot "$_snap_file"
    _attic_after=("${_attic_buf[@]}")
    rm -f "$_snap_file"
    local -a _new_attic=()
    local _x _y _found
    for _x in "${_attic_after[@]:-}"; do
        [[ -n "$_x" ]] || continue
        _found=0
        for _y in "${_attic_before[@]:-}"; do [[ "$_x" == "$_y" ]] && { _found=1; break; }; done
        [[ "$_found" -eq 0 ]] && _new_attic+=("$_x")
    done
    echo "attic new dirs=${#_new_attic[@]} (want 1)"
    [[ ${#_new_attic[@]} -eq 1 ]] || { echo "FAIL: attic 新增 ${#_new_attic[@]} (want 1)"; exit 1; }
    _ATTIC_DIRS+=("${_new_attic[@]}")

    # status 确认退出 workspace(recipe 不再 modified)
    local _post_status="" _psrc=0
    _post_status="$(devtool_in_env "$MACHINE" status)" || _psrc=$?
    [[ "$_psrc" -eq 0 ]] || { echo "FAIL: post-reset status rc=$_psrc"; exit 1; }
    ! ob_dev_integration_status_has_recipe "$RECIPE" "$_post_status" || { echo "FAIL: recipe 仍在 workspace after reset"; exit 1; }

    # retained: external modify → ob dev reset → retained(external 保留)
    CLEANUP_NEEDED=1
    EXTERNAL_SRCTREE="$(mktemp -d)"
    if ! devtool_in_env "$MACHINE" modify "$RECIPE" "$EXTERNAL_SRCTREE" >/dev/null 2>&1; then
        echo "FAIL: external modify"; exit 1
    fi
    # 读 bbappend srctreebase(HARNESS_ROOT source 的 _devtool_reset_locate_bbappend; 无 # srctreebase 注释 → 回退 status_srctree)
    local _lraw="" _lbbappend="" _lphase=""
    _devtool_reset_locate_bbappend "$_EFF_WS" "$RECIPE" "$EXTERNAL_SRCTREE" _lraw _lbbappend _lphase || true
    [[ -z "$_lphase" && "$_lraw" == "$EXTERNAL_SRCTREE" ]] || { echo "FAIL: locate bbappend phase=$_lphase raw=$_lraw (want $EXTERNAL_SRCTREE)"; exit 1; }

    _reset_rc=0
    _reset_out="$(./ob dev --machine "$MACHINE" reset "$RECIPE" 2>/dev/null)" || _reset_rc=$?
    [[ "$_reset_rc" -eq 0 ]] || { echo "FAIL: reset retained rc=$_reset_rc"; exit 1; }
    _integration_assert_disposition "$_reset_out" "retained" "" || { echo "FAIL: reset retained JSON"; exit 1; }
    [[ -d "$EXTERNAL_SRCTREE" ]] || { echo "FAIL: external srctree 未保留(retained)"; exit 1; }
    CLEANUP_NEEDED=0

    # noop: 同 RECIPE 已 reset → ob dev reset → noop
    _reset_rc=0
    _reset_out="$(./ob dev --machine "$MACHINE" reset "$RECIPE" 2>/dev/null)" || _reset_rc=$?
    [[ "$_reset_rc" -eq 0 ]] || { echo "FAIL: reset noop rc=$_reset_rc"; exit 1; }
    _integration_assert_disposition "$_reset_out" "noop" "" || { echo "FAIL: reset noop JSON"; exit 1; }

    # 成功路径不吞 cleanup rc(失败则 integration 报错)
    trap - EXIT
    ob_dev_integration_cleanup
    _snap_rc=$?
    [[ "$_snap_rc" -eq 0 ]] || { echo "FAIL: cleanup rc=$_snap_rc (recipe/attic 残留)" >&2; exit 1; }

    # === finish 段: 同一 RECIPE modify → srctree commit → capture pre → ob dev finish → capture post → 验证 ===
    # v6: 无 safety copy, finish 复用 reset disposition(devtool finish 内部 _reset 归档 srctreebase)
    CLEANUP_NEEDED=1
    trap ob_dev_integration_cleanup EXIT
    modify_rc=0
    SRCTREE="$(./ob dev --machine "$MACHINE" modify "$RECIPE" 2>/dev/null)" || modify_rc=$?
    echo "finish modify rc=$modify_rc srctree=$SRCTREE"
    [[ "$modify_rc" -eq 0 && -n "$SRCTREE" && -d "$SRCTREE" ]] || { echo "FAIL: finish modify/srctree"; exit 1; }

    # srctree 改动 + git commit(devtool finish 要求 srctree 是 clean git repo, FACT_ round-1)
    ( cd "$SRCTREE" && printf 'ob dev finish integration marker\n' > ob_finish_integration_marker.txt )
    git -C "$SRCTREE" add -A 2>/dev/null
    git -C "$SRCTREE" -c user.email=t@t -c user.name=t commit -q -m "ob dev finish integration" 2>/dev/null || true

    # capture pre(复用 helper, 不手写 snapshot)
    local _fin_snap_pre _fin_snap_post _fin_cap_phase=""
    _fin_snap_pre="$(mktemp)"; _fin_snap_post="$(mktemp)"
    _devtool_finish_capture_landing_snapshot "$OPENBMC_DIR" "$_fin_snap_pre" _fin_cap_phase || true
    [[ -z "$_fin_cap_phase" ]] || { rm -f "$_fin_snap_pre" "$_fin_snap_post"; echo "FAIL: finish capture pre phase=$_fin_cap_phase"; exit 1; }

    local _fin_out="" _fin_rc=0
    _fin_out="$(./ob dev --machine "$MACHINE" finish "$RECIPE" 2>/dev/null)" || _fin_rc=$?
    echo "finish rc=$_fin_rc"
    [[ "$_fin_rc" -eq 0 ]] || { echo "FAIL: finish rc=$_fin_rc out=$_fin_out"; exit 1; }

    # capture post + detect 独立校验(复用 helper; capture/detect 与 ob stdout 一致性)
    _fin_cap_phase=""
    _devtool_finish_capture_landing_snapshot "$OPENBMC_DIR" "$_fin_snap_post" _fin_cap_phase || true
    local _fd_mode="" _fd_patches="" _fd_recipe_files="" _fd_srcrev="" _fd_layer="" _fd_phase=""
    if [[ -z "$_fin_cap_phase" ]]; then
        _devtool_finish_detect_landing "$OPENBMC_DIR" "$_fin_snap_pre" "$_fin_snap_post" \
            _fd_mode _fd_patches _fd_recipe_files _fd_srcrev _fd_layer _fd_phase || true
    fi
    rm -f "$_fin_snap_pre" "$_fin_snap_post"

    # finish JSON 解析 + 按实测 mode 断言(不强制 patch/srcrev 都出现; 区分实测/未实测)
    local _fin_mode="" _fin_disp=""
    _fin_mode="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("landing_mode") or "")' <<<"$_fin_out" 2>/dev/null || true)"
    _fin_disp="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("disposition") or "")' <<<"$_fin_out" 2>/dev/null || true)"
    echo "finish disposition=$_fin_disp landing_mode=$_fin_mode (detect mode=${_fd_mode:-n/a} phase=${_fd_phase:-n/a})"
    [[ "$_fin_disp" == "moved" || "$_fin_disp" == "retained" || "$_fin_disp" == "removed" || "$_fin_disp" == "absent" ]] \
        || { echo "FAIL: finish disposition=$_fin_disp"; exit 1; }
    if [[ -n "$_fin_mode" ]]; then
        [[ "$_fin_mode" == "patch" || "$_fin_mode" == "srcrev" ]] || { echo "FAIL: finish landing_mode=$_fin_mode (want patch/srcrev)"; exit 1; }
    fi

    # disposition 归档实测(moved → attic/sources 单一 <RECIPE>.<ts>; v6 无 .finish-copy 残留)
    if [[ "$_fin_disp" == "moved" ]]; then
        local _fin_attic=""
        _fin_attic="$(find "$_EFF_WS/attic/sources" -maxdepth 1 -mindepth 1 -name "$RECIPE.*" -type d 2>/dev/null | head -1)"
        [[ -n "$_fin_attic" ]] || { echo "FAIL: finish moved 但 attic/sources 无 $RECIPE.* 归档"; exit 1; }
        [[ "$_fin_attic" != *.finish-copy ]] || { echo "FAIL: attic 残留 .finish-copy(v6 应无)"; exit 1; }
        _ATTIC_DIRS+=("$_fin_attic")
    fi

    # status 确认 recipe 退出 workspace
    local _fin_post_status="" _fpsrc=0
    _fin_post_status="$(devtool_in_env "$MACHINE" status)" || _fpsrc=$?
    [[ "$_fpsrc" -eq 0 ]] || { echo "FAIL: post-finish status rc=$_fpsrc"; exit 1; }
    ! ob_dev_integration_status_has_recipe "$RECIPE" "$_fin_post_status" || { echo "FAIL: recipe 仍在 workspace after finish"; exit 1; }

    # 清理: attic + reset if modified(复用 cleanup) + 回滚 finish layer 改动(recipe_files git restore + patches rm)
    CLEANUP_NEEDED=0
    trap - EXIT
    ob_dev_integration_cleanup
    ob_dev_integration_finish_layer_restore "$_fin_out"
    echo "[integration] OK (modify → moved reset → external → retained reset → noop → modify → finish[$_fin_disp/$_fin_mode])"
}

if [[ "${OB_DEV_INTEGRATION_NO_MAIN:-0}" != "1" ]]; then
    ob_dev_integration_main "$@"
fi
