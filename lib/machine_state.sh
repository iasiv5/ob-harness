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

machine_state_has_init_done() {
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

machine_state_image_path() {
    local machine="$1"
    local deploy_dir
    local image_path

    deploy_dir="$(machine_state_deploy_dir "$machine")"
    if [[ ! -d "$deploy_dir" ]]; then
        return 1
    fi

    image_path=$(find "$deploy_dir" -maxdepth 1 -name "*.static.mtd" -type f -print 2>/dev/null | sort | sed -n '1p')
    if [[ -z "$image_path" ]]; then
        return 1
    fi
    echo "$image_path"
}

machine_state_build_state() {
    local machine="$1"
    local build_dir

    if machine_state_image_path "$machine" >/dev/null 2>&1; then
        echo "succeeded"
        return 0
    fi

    build_dir="$(machine_state_build_dir "$machine")"
    if [[ -d "$build_dir" ]]; then
        echo "failed"
    else
        echo "never"
    fi
}

machine_state_list_records() {
    local -a machines=()
    local -A seen=()
    local f machine line

    for f in "$CONFIGS_DIR"/*.snapshot "$CONFIGS_DIR"/*.init-done; do
        [[ -f "$f" ]] || continue
        machine=$(basename "$f" | sed -E 's/\.(snapshot|init-done)$//')
        if [[ -z "${seen[$machine]:-}" ]]; then
            seen["$machine"]=1
            machines+=("$machine")
        fi
    done

    if [[ ${#machines[@]} -eq 0 ]]; then
        return 0
    fi

    while IFS= read -r line; do
        [[ -n "$line" ]] && machine_state_print_record "$line"
    done < <(printf '%s\n' "${machines[@]}" | sort)
}

machine_state_record_field() {
    local record="$1"
    local key="$2"
    local field
    local IFS=$'\t'

    for field in $record; do
        if [[ "$field" == "$key="* ]]; then
            echo "${field#*=}"
            return 0
        fi
    done
    return 1
}

machine_state_print_record() {
    local machine="$1"
    local snapshot_path init_done_path
    local snapshot="no"
    local init="none"
    local repos="?"
    local build
    local image="no"
    local init_time=""

    snapshot_path="$(machine_state_snapshot_path "$machine")"
    init_done_path="$(machine_state_init_done_path "$machine")"

    if [[ -f "$snapshot_path" ]]; then
        snapshot="yes"
        repos="$(machine_state_repo_count "$machine")"
    fi

    if [[ -f "$init_done_path" ]]; then
        init="done"
        if ! IFS= read -r init_time < "$init_done_path"; then
            init_time=""
        fi
    elif [[ "$snapshot" == "yes" ]]; then
        init="partial"
    fi

    build="$(machine_state_build_state "$machine")"
    if [[ "$build" == "succeeded" ]]; then
        image="yes"
    fi

    printf 'machine=%s\tinit=%s\tsnapshot=%s\trepos=%s\tbuild=%s\timage=%s\tinit_time=%s\n' \
        "$machine" "$init" "$snapshot" "$repos" "$build" "$image" "$init_time"
}