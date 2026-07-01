#!/usr/bin/env bash
# lib/machine_state.sh — Machine lifecycle state(snapshot/init marker/build artifact),被 ob source。
# 纯函数定义集;下层 module 不 exit,由 commands.sh 决定 exit-code/remedy。


machine_state_snapshot_path() {
    local machine="$1"
    echo "$CONFIGS_DIR/$machine.snapshot"
}

machine_state_legacy_lock_path() {
    local machine="$1"
    echo "$CONFIGS_DIR/$machine.lock"
}

machine_state_init_done_path() {
    local machine="$1"
    echo "$CONFIGS_DIR/$machine.init-done"
}

machine_state_build_dir() {
    local machine="$1"
    echo "$OPENBMC_DIR/build/$machine"
}

machine_state_deploy_dir() {
    local machine="$1"
    echo "$OPENBMC_DIR/build/$machine/tmp/deploy/images/$machine"
}

machine_state_is_initialized() {
    local machine="$1"
    [[ -f "$(machine_state_init_done_path "$machine")" ]]
}

machine_state_repo_count() {
    local machine="$1"
    local snapshot
    local count

    snapshot="$(machine_state_snapshot_path "$machine")"
    if [[ ! -f "$snapshot" ]]; then
        echo "?"
        return 0
    fi

    count=$(python3 - "$snapshot" <<'PY' 2>/dev/null
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
print(len(data.get("sub_repos", [])))
PY
) || count="?"
    if [[ -z "$count" ]]; then
        count="?"
    fi
    echo "$count"
}

machine_state_write_snapshot() {
    local machine="$1"
    local deps_json="$2"
    local openbmc_commit="$3"
    local snapshot
    local legacy_lock
    local tmp

    snapshot="$(machine_state_snapshot_path "$machine")"
    legacy_lock="$(machine_state_legacy_lock_path "$machine")"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Would write machine snapshot to $snapshot"
        return 0
    fi

    if [[ ! -f "$deps_json" ]]; then
        return 1
    fi

    mkdir -p "$CONFIGS_DIR"
    tmp=$(mktemp "$CONFIGS_DIR/$machine.snapshot.XXXXXX") || return 1

    if ! python3 - "$tmp" "$deps_json" "$machine" "$openbmc_commit" <<'PY'
import datetime
import json
import sys

target, deps_json, machine, openbmc_commit = sys.argv[1:5]
with open(deps_json, encoding="utf-8") as fh:
    deps = json.load(fh)

snapshot = {
    "machine": machine,
    "generated_at": datetime.datetime.now().astimezone().isoformat(),
    "openbmc_commit": openbmc_commit,
    "target_image": "obmc-phosphor-image",
    "sub_repos": [],
}
for dep in deps:
    snapshot["sub_repos"].append({
        "name": dep["name"],
        "src_uri": dep["src_uri"],
        "srcrev": dep["srcrev"],
        "local_path": "workspace/src/" + machine + "/" + dep["name"],
        "recipe": dep["recipe"],
    })

with open(target, "w", encoding="utf-8") as fh:
    json.dump(snapshot, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
    then
        rm -f "$tmp"
        return 1
    fi

    if ! mv "$tmp" "$snapshot"; then
        rm -f "$tmp"
        return 1
    fi

    rm -f "$legacy_lock"
}

machine_state_mark_init_done() {
    local machine="$1"
    local marker
    local tmp

    marker="$(machine_state_init_done_path "$machine")"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Would write init-done marker to $marker"
        return 0
    fi

    mkdir -p "$CONFIGS_DIR"
    tmp=$(mktemp "$CONFIGS_DIR/$machine.init-done.XXXXXX") || return 1
    if ! date -u +"%Y-%m-%dT%H:%M:%SZ" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$marker"; then
        rm -f "$tmp"
        return 1
    fi
}

machine_state_clear_init_progress() {
    local machine="$1"
    local marker
    local snapshot
    local legacy_lock

    marker="$(machine_state_init_done_path "$machine")"
    snapshot="$(machine_state_snapshot_path "$machine")"
    legacy_lock="$(machine_state_legacy_lock_path "$machine")"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Would clear init progress for $machine"
        return 0
    fi

    rm -f "$marker" "$snapshot" "$legacy_lock"
}

machine_state_firmware_image_path() {
    local machine="$1"
    local openbmc_dir
    local image_path
    local deploy_dir

    openbmc_dir="${OPENBMC_DIR:-}"
    if [[ -z "$openbmc_dir" ]]; then
        return 1
    fi

    deploy_dir="${openbmc_dir%/}/build/$machine/tmp/deploy/images/$machine"
    if [[ ! -d "$deploy_dir" ]]; then
        return 1
    fi

    image_path=$(find "$deploy_dir" -maxdepth 1 -name "*.static.mtd" -type f -print 2>/dev/null | sort | sed -n '1p')
    if [[ -z "$image_path" ]]; then
        return 1
    fi
    echo "$image_path"
}

_machine_state_file_mtime_iso() {
    local path="$1"
    local epoch

    epoch=$(stat -c '%Y' "$path" 2>/dev/null) || return 1
    date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null
}

_machine_state_add_machine() {
    local machine="$1"
    local -n machines_ref="$2"
    local -n seen_ref="$3"

    [[ -n "$machine" ]] || return 0
    if [[ -z "${seen_ref[$machine]:-}" ]]; then
        seen_ref["$machine"]=1
        machines_ref+=("$machine")
    fi
}

_machine_state_discover_machines() {
    local -a machines=()
    local -A seen=()
    local f machine

    if [[ -n "${CONFIGS_DIR:-}" ]]; then
        for f in "$CONFIGS_DIR"/*.snapshot "$CONFIGS_DIR"/*.init-done; do
            [[ -f "$f" ]] || continue
            machine=$(basename "$f" | sed -E 's/\.(snapshot|init-done)$//')
            _machine_state_add_machine "$machine" machines seen
        done
    fi

    local openbmc_dir="${OPENBMC_DIR:-}"
    local build_root=""
    if [[ -n "$openbmc_dir" ]]; then
        build_root="${openbmc_dir%/}/build"
    fi

    if [[ -n "$build_root" && -d "$build_root" ]]; then
        local had_nullglob=0
        local artifact rel build_machine rest image_machine
        shopt -q nullglob && had_nullglob=1
        shopt -s nullglob
        for artifact in "$build_root"/*/tmp/deploy/images/*/*.static.mtd; do
            [[ -f "$artifact" ]] || continue
            rel="${artifact#"$build_root/"}"
            build_machine="${rel%%/*}"
            rest="${rel#"$build_machine/tmp/deploy/images/"}"
            image_machine="${rest%%/*}"
            [[ -n "$build_machine" && "$build_machine" == "$image_machine" ]] || continue
            _machine_state_add_machine "$build_machine" machines seen
        done
        if [[ "$had_nullglob" -eq 0 ]]; then
            shopt -u nullglob
        fi
    fi

    if [[ ${#machines[@]} -eq 0 ]]; then
        return 0
    fi

    printf '%s\n' "${machines[@]}" | sort
}

machine_state_snapshot_state() {
    local machine="$1"

    if [[ -f "$(machine_state_snapshot_path "$machine")" ]]; then
        echo "present"
    else
        echo "missing"
    fi
}

machine_state_init_state() {
    local machine="$1"

    if machine_state_is_initialized "$machine"; then
        echo "initialized"
    elif [[ "$(machine_state_snapshot_state "$machine")" == "present" ]]; then
        echo "partial"
    else
        echo "uninitialized"
    fi
}

machine_state_init_time() {
    local machine="$1"
    local marker
    local init_time=""

    marker="$(machine_state_init_done_path "$machine")"
    if [[ -f "$marker" ]]; then
        IFS= read -r init_time < "$marker" || init_time=""
    fi
    echo "$init_time"
}

machine_state_firmware_image_mtime() {
    local machine="$1"
    local image_path
    local mtime=""

    image_path="$(machine_state_firmware_image_path "$machine" 2>/dev/null || true)"
    if [[ -n "$image_path" ]]; then
        mtime="$(_machine_state_file_mtime_iso "$image_path" 2>/dev/null || true)"
    fi
    echo "$mtime"
}

machine_state_is_firmware_image_ready() {
    local machine="$1"

    machine_state_is_initialized "$machine" || return 1
    machine_state_firmware_image_path "$machine" >/dev/null 2>&1
}

machine_state_is_orphan_firmware_image() {
    local machine="$1"

    machine_state_is_initialized "$machine" && return 1
    machine_state_firmware_image_path "$machine" >/dev/null 2>&1
}

machine_state_display_machines() {
    local machine

    while IFS= read -r machine; do
        [[ -n "$machine" ]] || continue
        if [[ -f "$(machine_state_snapshot_path "$machine")" || -f "$(machine_state_init_done_path "$machine")" ]]; then
            echo "$machine"
        fi
    done < <(_machine_state_discover_machines)
}

machine_state_orphan_firmware_image_machines() {
    local machine

    while IFS= read -r machine; do
        [[ -n "$machine" ]] || continue
        machine_state_is_orphan_firmware_image "$machine" && echo "$machine"
    done < <(_machine_state_discover_machines)
}

machine_state_initialized_machines() {
    local machine

    while IFS= read -r machine; do
        [[ -n "$machine" ]] || continue
        machine_state_is_initialized "$machine" && echo "$machine"
    done < <(_machine_state_discover_machines)
}

machine_state_firmware_image_ready_machines() {
    local machine

    while IFS= read -r machine; do
        [[ -n "$machine" ]] || continue
        machine_state_is_initialized "$machine" || continue
        machine_state_firmware_image_path "$machine" >/dev/null 2>&1 || continue
        echo "$machine"
    done < <(_machine_state_discover_machines)
}