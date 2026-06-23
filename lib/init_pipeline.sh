#!/usr/bin/env bash
# lib/init_pipeline.sh — ob §5 init 流水线(clone/snapshot/config),被 ob source。纯函数定义集。


prerequisites_check() {
    step_header "Step 1/8: Checking prerequisites..."

    # OS check
    if [[ "$(uname -s)" != "Linux" ]]; then
        error "This script must run on Linux. Current OS: $(uname -s)"
        exit 3
    fi
    verbose "OS: $(uname -s) OK"

    # Tool check
    for tool in git python3; do
        if ! command -v "$tool" &>/dev/null; then
            error "Required tool not found: $tool"
            error "Install '$tool' on this host, then retry."
            exit 3
        fi
        verbose "Tool: $tool OK"
    done

    # Network check (best-effort)
    if command -v curl &>/dev/null; then
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 https://github.com 2>/dev/null || echo "000")
        if [[ "$http_code" != "200" && "$http_code" != "301" && "$http_code" != "302" ]]; then
            warn "github.com may not be reachable (HTTP $http_code). Clone may fail."
        else
            verbose "Network: github.com reachable (HTTP $http_code)"
        fi
    fi

    # Disk space check (rough estimate: ~200 MB per repo × ~110 repos + main repo + build)
    if [[ -d "$WORKSPACE_DIR" ]]; then
        local avail_mb
        avail_mb=$(df -BM "$WORKSPACE_DIR" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'M')
        if [[ -n "$avail_mb" ]] && [[ "$avail_mb" -lt 25000 ]]; then
            warn "Only ${avail_mb}MB free disk space. ob init typically needs 20-30 GB."
            warn "If download fails due to disk space, free up space and re-run."
        fi
    fi

    info "Prerequisites OK."
}

clone_openbmc() {
    step_header "Step 2/8: Preparing OpenBMC main repository and resolving machine..."

    verify_source

    if [[ -d "$OPENBMC_DIR/.git" ]]; then
        info "Main repository already exists at $OPENBMC_DIR — skipping clone."
        info "To update manually: cd $OPENBMC_DIR && git pull"
        return 0
    fi

    select_openbmc_repo_url
    info "Downloading the small OpenBMC main repository (used to list machines, ~a few minutes)."
    info "Cloning $OPENBMC_REPO_URL -> $OPENBMC_DIR"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Would run: git clone $OPENBMC_REPO_URL $OPENBMC_DIR"
        return 0
    fi

    mkdir -p "$WORKSPACE_DIR"
    if ! git clone "$OPENBMC_REPO_URL" "$OPENBMC_DIR"; then
        error "Failed to clone openbmc main repository."
        exit 1
    fi
    write_source_manifest
    info "Main repository cloned successfully."
}

run_repo_init_script() {
    local init_script="$OPENBMC_DIR/init_openbmc_repo.sh"

    if [[ ! -f "$init_script" ]]; then
        verbose "No init_openbmc_repo.sh found in $OPENBMC_DIR — skipping custom repo initialization."
        return 0
    fi

    info "Detected init_openbmc_repo.sh — running custom repository initialization..."
    info "  This script clones/pulls vendor sub-repos (meta-iasi, etc.)"
    info "  Incremental-safe: existing repos are pulled, missing repos are cloned."

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Would run: cd $OPENBMC_DIR && bash init_openbmc_repo.sh"
        return 0
    fi

    # init_openbmc_repo.sh uses SCRIPT_DIR relative paths — must run from openbmc root.
    # Wrap in 'if' so set -e does not propagate a non-zero exit from the init script.
    local prev_dir="$PWD"
    cd "$OPENBMC_DIR"

    if bash init_openbmc_repo.sh; then
        info "Custom repository initialization completed."
    else
        cd "$prev_dir"
        error "init_openbmc_repo.sh failed — the OpenBMC repository is incomplete."
        error "Please fix the errors above and re-run: cd $OPENBMC_DIR && bash init_openbmc_repo.sh"
        error "Then re-run: ob init $MACHINE"
        exit 1
    fi

    cd "$prev_dir"
}

init_bitbake_env() {
    step_header "Step 3/8: Initializing bitbake environment for machine=$MACHINE..."

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Would run: cd $OPENBMC_DIR && source setup $MACHINE $BUILD_DIR"
        return 0
    fi

    cd "$OPENBMC_DIR"

    # Use OpenBMC's official `source setup <machine>` to initialize the build environment.
    # This handles TEMPLATECONF, bblayers.conf, and local.conf correctly.
    # Temporarily disable nounset — setup sources oe-init-build-env which references unset vars.
    local prev_opts
    prev_opts=$(set +o | grep nounset)
    set +u
    # shellcheck disable=SC1091
    source setup "$MACHINE" "$BUILD_DIR"
    eval "$prev_opts"

    # Verify build dir was created
    if [[ ! -f "$BUILD_DIR/conf/local.conf" ]]; then
        error "local.conf not found after source setup. Something went wrong."
        exit 1
    fi

    ensure_bootstrap_local_conf

    # Pre-create DL_DIR and SSTATE_DIR so bitbake sanity checks don't fail
    # when the .inc file (generated later in Step 7) references them.
    # Use resolve functions to respect overrides in local.conf (e.g. DL_DIR="/shared/downloads").
    if [[ -f "$BUILD_DIR/conf/externalsrc-$MACHINE.inc" ]]; then
        mkdir -p "$(resolve_effective_dl_dir)" "$(resolve_effective_sstate_dir)"

        # Fix legacy .inc files that use ${TOPDIR}/../../../.. relative paths.
        # Bitbake internally prepends '\/' to these resolved paths, causing mkdir
        # to create a spurious '\' directory under the build dir (e.g. build/romulus/\/).
        # Replace with absolute paths to prevent this.
        local inc_file="$BUILD_DIR/conf/externalsrc-$MACHINE.inc"
        if grep -q '\${TOPDIR}/\.\./\.\./\.\./downloads' "$inc_file" 2>/dev/null; then
            verbose "Fixing DL_DIR/SSTATE_DIR in existing $inc_file (relative -> absolute)"
            python3 -c "
import sys
content = open('$inc_file').read()
content = content.replace(
    'DL_DIR = \"\\\${TOPDIR}/../../../downloads\"',
    'DL_DIR = \"$WORKSPACE_DIR/downloads\"'
)
content = content.replace(
    'SSTATE_DIR = \"\\\${TOPDIR}/../../../sstate-cache\"',
    'SSTATE_DIR = \"$WORKSPACE_DIR/sstate-cache\"'
)
open('$inc_file', 'w').write(content)
"
        fi

        # Clean up spurious '\' directory that may have been created by a previous
        # run with relative-path DL_DIR/SSTATE_DIR (bitbake '\/' escaping bug)
        if [[ -d "$BUILD_DIR/"'\\' ]]; then
            warn "Removing spurious escaped directory under $BUILD_DIR"
            rm -rf "$BUILD_DIR/"'\\'
        fi
    fi

    info "Bitbake environment initialized. Build dir: $BUILD_DIR"
}

generate_dep_graph() {
    step_header "Step 4/8: Generating dependency graph..."

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Would run: bitbake -g obmc-phosphor-image"
        info "[DRY-RUN] Would query recipe SRC_URI/SRCREV via Tinfoil API"
        return 0
    fi

    cd "$OPENBMC_DIR"

    # Re-enter build environment (needed after cd)
    local prev_opts
    prev_opts=$(set +o | grep nounset)
    set +u
    # shellcheck disable=SC1091
    source setup "$MACHINE" "$BUILD_DIR" 2>/dev/null
    eval "$prev_opts"

    # Generate pn-buildlist via bitbake -g (~3 min).
    # This gives us ~570 target-dependent recipes instead of ~4492 total.
    info "Running bitbake -g obmc-phosphor-image (generates pn-buildlist)..."
    info "This step takes 3-5 minutes..."
    if ! bitbake -g obmc-phosphor-image; then
        error "bitbake -g failed. Check machine name and bitbake environment."
        exit 1
    fi

    # Parse dependencies via Tinfoil API (single process, ~45s).
    # Uses pn-buildlist to only query ~570 target recipes.
    # Write to a temp file first, then atomically rename on success.
    # This prevents ctrl+C from leaving deps.json empty (shell `>` truncates immediately).
    local deps_json="$BUILD_DIR/deps.json"
    local deps_json_tmp="$BUILD_DIR/deps.json.tmp"
    info "Querying recipe metadata via Tinfoil API (~45s)..."
    if ! python3 "$HARNESS_ROOT/tools/parse_bitbake_deps.py" \
        --build-dir "$BUILD_DIR" \
        --machine "$MACHINE" \
        > "$deps_json_tmp"; then
        rm -f "$deps_json_tmp"
        error "Failed to parse bitbake dependency graph."
        exit 1
    fi
    mv "$deps_json_tmp" "$deps_json"

    local dep_count
    dep_count=$(python3 -c "import json; print(len(json.load(open('$deps_json'))))")
    info "Found $dep_count git-based sub-repositories."
}

clone_sub_repos() {
    # SAFETY: This function is incremental.
    #   - If a bare mirror already exists, it is skipped.
    #   - BitBake's do_fetch maintains mirrors during builds.
    step_header "Step 5/8: Populating bare mirrors..."

    local deps_json="$BUILD_DIR/deps.json"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Would populate bare mirrors listed in $deps_json"
        return 0
    fi

    require_path "$deps_json" "deps.json" "Run 'ob init' first." 3

    local effective_dl_dir=""
    effective_dl_dir=$(resolve_effective_dl_dir)
    MIRROR_BASE="$effective_dl_dir/git2"
    mkdir -p "$MIRROR_BASE"
    info "Mirror cache: $MIRROR_BASE"

    # Read each repo from deps.json
    local total failed=0
    total=$(python3 -c "import json; print(len(json.load(open('$deps_json'))))")
    local current=0

    while IFS= read -r entry; do
        current=$((current + 1))
        local name clone_url src_uri
        name=$(echo "$entry" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
        clone_url=$(echo "$entry" | python3 -c "import sys,json; print(json.load(sys.stdin)['clone_url'])")
        src_uri=$(echo "$entry" | python3 -c "import sys,json; print(json.load(sys.stdin).get('src_uri',''))")
        info "[$current/$total] Processing: $name"

        # Expand any remaining ${VAR} references in clone_url.
        # These come from BitBake variables (e.g. ${GITLAB_IP}) that weren't
        # resolved during deps.json generation (e.g. variable not in config).
        if [[ "$clone_url" == *'${'* ]]; then
            # Prefer the same runtime host source used by init_openbmc_repo.sh:
            #   1) meta-*/git-mirror-url.sh (after GIT_MIRROR_HOST rewrite)
            #   2) workspace/openbmc/.git/config origin URL
            #   3) build/conf/local.conf as a manual fallback
            local _runtime_script=""
            for _candidate in "$WORKSPACE_DIR/openbmc"/meta-*/git-mirror-url.sh \
                              "$WORKSPACE_DIR/openbmc"/meta-*/github-gitlab-url.sh; do
                if [[ -f "$_candidate" ]]; then _runtime_script="$_candidate"; break; fi
            done
            local _openbmc_git_config="$WORKSPACE_DIR/openbmc/.git/config"
            local _local_conf="$BUILD_DIR/conf/local.conf"
            # Extract all ${VAR} names from clone_url
            local _var_names
            _var_names=$(echo "$clone_url" | grep -oP '\$\{[A-Za-z_][A-Za-z0-9_]*\}' | sort -u || true)
            for _vk in $_var_names; do
                local _vn="${_vk#\$\{}"
                _vn="${_vn%\}}"
                local _vv=""

                if [[ "$_vn" == "GITLAB_IP" || "$_vn" == "GIT_MIRROR_HOST" ]] && [[ -f "$_runtime_script" ]]; then
                    _vv=$(grep -oP '^(GITLAB_IP|GIT_MIRROR_HOST)=["'"'"']?\K[^"'"'"'\s]+' "$_runtime_script" 2>/dev/null | head -1 || true)
                fi

                if [[ -z "$_vv" ]] && { [[ "$_vn" == "GITLAB_IP" || "$_vn" == "GIT_MIRROR_HOST" ]] ; } && [[ -f "$_openbmc_git_config" ]]; then
                    local _remote_url=""
                    _remote_url=$(grep -E '^[[:space:]]*url = (git@|https?)' "$_openbmc_git_config" 2>/dev/null | head -1 | awk '{print $3}')
                    if [[ "$_remote_url" == git@* ]]; then
                        _vv=$(echo "$_remote_url" | sed -E 's/^git@([^:]+):.*/\1/')
                    elif [[ "$_remote_url" == http://* || "$_remote_url" == https://* ]]; then
                        _vv=$(echo "$_remote_url" | sed -E 's#^https?://([^/:]+).*#\1#')
                    fi
                fi

                if [[ -z "$_vv" && -f "$_local_conf" ]]; then
                    _vv=$(grep -oP "^$_vn\s*[:?]?=\s*[\"']?\\K[^\"'\s#]+" "$_local_conf" 2>/dev/null | head -1 || true)
                fi

                if [[ -n "$_vv" ]]; then
                    clone_url="${clone_url//$_vk/$_vv}"
                    verbose "Expanded $_vk -> $_vv in clone_url"
                fi
            done
            # If still unexpanded, warn and skip
            if [[ "$clone_url" == *'${'* ]]; then
                warn "Unresolved BitBake variable in clone_url for $name: $clone_url"
                STATUS_FAILED+=("$name (unresolved variable in clone URL)")
                failed=$((failed + 1))
                continue
            fi
        fi

        # ---------- URL rewrite table ----------
        # Rewrite unreachable git:// URLs to accessible HTTPS mirrors.
        # Each entry: original_url  rewritten_url
        # Add new entries here as needed.
        local _url_rewrites=(
            "git://git.infradead.org/mtd-utils.git"
            "https://github.com/sigma-star/mtd-utils.git"
        )
        for (( _i=0; _i<${#_url_rewrites[@]}; _i+=2 )); do
            if [[ "$clone_url" == "${_url_rewrites[_i]}" ]]; then
                verbose "URL rewrite: $clone_url -> ${_url_rewrites[_i+1]}"
                clone_url="${_url_rewrites[_i+1]}"
                break
            fi
        done
        # ----------------------------------------

        local _clone_err="$BUILD_DIR/clone-errors.log"
        # Increase http.postBuffer for large repos (default 1MB causes curl 18
        # "transfer closed with outstanding read data remaining" on big packs
        # like glibc). 512MB is safe for any single-pack transfer.
        git config --global http.postBuffer 536870912

        # --- Phase A: Ensure bare mirror exists in DL_DIR/git2/ ---
        local mirror_path=""
        mirror_path=$(derive_bitbake_git_mirror_path "$MIRROR_BASE" "$src_uri" 2>/dev/null || true)

        if [[ -z "$mirror_path" ]]; then
            # Cannot derive mirror path (malformed SRC_URI) — skip, BitBake will fetch from remote.
            verbose "Cannot derive mirror path for $name, skipping (BitBake will fetch from remote)"
        elif [[ -d "$mirror_path" ]]; then
            # Mirror exists — skip; BitBake maintains DL_DIR/git2/ during builds.
            verbose "Mirror already exists: $mirror_path"
            STATUS_MIRROR_EXISTING+=("$name")
        else
            # Mirror missing — create full bare clone from remote
            verbose "Creating bare mirror: $clone_url -> $mirror_path"
            mkdir -p "$(dirname "$mirror_path")"
            if git clone --bare "$clone_url" "$mirror_path" 2>>"$_clone_err"; then
                STATUS_MIRROR_NEW+=("$name")
            else
                rm -rf "$mirror_path" 2>/dev/null
                warn "Failed to create bare mirror for $name (BitBake will fetch from remote during build)"
                STATUS_FAILED+=("$name (bare mirror clone failed)")
                failed=$((failed + 1))
                continue
            fi
        fi
    done < <(python3 -c "
import json, sys
for item in json.load(open('$deps_json')):
    json.dump(item, sys.stdout)
    print()
")

    info "Mirrors: ${#STATUS_MIRROR_NEW[@]} new, ${#STATUS_MIRROR_EXISTING[@]} existing in $MIRROR_BASE"
    if [[ "$failed" -gt 0 ]]; then
        warn "$failed mirrors failed. See $BUILD_DIR/clone-errors.log"
    fi
}

generate_machine_snapshot() {
    step_header "Step 6/8: Generating machine snapshot..."

    local snapshot
    local deps_json
    local openbmc_commit

    snapshot="$(machine_state_snapshot_path "$MACHINE")"
    deps_json="$BUILD_DIR/deps.json"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Would write machine snapshot to $snapshot"
        return 0
    fi

    openbmc_commit=$(git -C "$OPENBMC_DIR" rev-parse HEAD)
    if ! machine_state_write_snapshot "$MACHINE" "$deps_json" "$openbmc_commit"; then
        error "Failed to write machine snapshot: $snapshot"
        exit 1
    fi

    info "Machine snapshot written to $snapshot"
}

generate_build_config() {
    step_header "Step 7/8: Generating build cache configuration (and externalsrc placeholder for future dev)..."

    local conf_dir="$BUILD_DIR/conf"
    local inc_file="$conf_dir/externalsrc-$MACHINE.inc"
    local local_conf="$conf_dir/local.conf"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Would generate $inc_file"
        info "[DRY-RUN] Would add include to $local_conf"
        return 0
    fi

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Backup existing .inc file (keep only the most recent backup)
    if [[ -f "$inc_file" ]]; then
        # Remove old backups before creating new one
        rm -f "${inc_file}".bak.* 2>/dev/null || true
        cp "$inc_file" "${inc_file}.bak.$(date +%Y%m%d%H%M%S)"
        info "Previous .inc backed up (old backups cleaned up)"
    fi

    # WSL parallelism detection
    local is_wsl=0
    local parallel_n=""
    if detect_wsl; then
        is_wsl=1
        parallel_n=$(calc_parallelism)
        info "WSL detected — parallelism limited to -j${parallel_n} (memory budget)"
    fi

    # Detect user-defined DL_DIR/SSTATE_DIR in local.conf so the generated .inc never
    # overrides them (e.g. NFS shared cache). Done OUTSIDE the redirect block below so the
    # helper's own stdout cannot leak into the .inc file.
    local _user_dl_dir="" _user_dl_set=0
    local _user_sstate_dir="" _user_sstate_set=0
    # Detection by exit code (see ADR-0005): an assignment line — even empty — means the
    # user manages this var; only the absence of a line triggers ob's default. Using `-n`
    # would mis-treat `VAR = ""` (a deliberate disable) as unset and silently fill it.
    if read_local_conf_var "$local_conf" "DL_DIR" >/dev/null 2>&1; then
        _user_dl_set=1
        _user_dl_dir=$(read_local_conf_var "$local_conf" "DL_DIR" 2>/dev/null || true)
    fi
    if read_local_conf_var "$local_conf" "SSTATE_DIR" >/dev/null 2>&1; then
        _user_sstate_set=1
        _user_sstate_dir=$(read_local_conf_var "$local_conf" "SSTATE_DIR" 2>/dev/null || true)
    fi
    [[ "$_user_dl_set" -eq 1 ]] && info "DL_DIR set in local.conf (${_user_dl_dir:-<empty>}) — not overriding in .inc"
    [[ "$_user_sstate_set" -eq 1 ]] && info "SSTATE_DIR set in local.conf (${_user_sstate_dir:-<empty>}) — not overriding in .inc"
    local _user_premirrors_set=0
    if read_local_conf_var "$local_conf" "PREMIRRORS" >/dev/null 2>&1; then
        _user_premirrors_set=1
    fi
    if [[ "$_user_premirrors_set" -eq 1 ]]; then
        info "PREMIRRORS set in local.conf — not overriding in .inc"
    else
        info "PREMIRRORS: GNU -> tuna (Tsinghua mirror); disable with PREMIRRORS=\"\" in local.conf"
    fi

    # Generate .inc file — ob init managed configuration.
    # Most variables use ??= (weak default). DL_DIR/SSTATE_DIR are the exception: they use a
    # conditional = (written only when absent in local.conf) because ??= cannot override
    # bitbake.conf's ?= default and would silently break do_unpack ("tar: Cannot open").
    {
        echo "# Auto-generated by ob init $MACHINE at $timestamp"
        echo "# Do not edit manually. Re-run 'ob init $MACHINE' to regenerate."
        echo ""
        echo "# Enable externalsrc class (no-op when no EXTERNALSRC_pn-* is set)."
        echo "# Use 'ob dev <recipe>' to add externalsrc entries for specific recipes."
        echo 'INHERIT += "externalsrc"'
        echo ""

        echo "# Disable OE connectivity probes by default; github fetches already validate network reachability."
        echo '# Note: uses = (not ??=) because OE-core sets CONNECTIVITY_CHECK_URIS ?= in default-distrovars.inc'
        echo '# and ??= would be too weak to override it.'
        echo 'CONNECTIVITY_CHECK_URIS = ""'
        echo ""

        echo "# Build cache directories. Written here only if NOT already defined in local.conf."
        echo "# Uses = (not ??=): bitbake.conf sets these with ?=, and ??= is too weak to override it."
        if [[ "$_user_dl_set" -eq 0 ]]; then
            echo "DL_DIR = \"$WORKSPACE_DIR/downloads\""
        else
            echo "# DL_DIR defined in local.conf (${_user_dl_dir:-<empty>}) — not overridden."
        fi
        if [[ "$_user_sstate_set" -eq 0 ]]; then
            echo "SSTATE_DIR = \"$WORKSPACE_DIR/sstate-cache\""
        else
            echo "# SSTATE_DIR defined in local.conf (${_user_sstate_dir:-<empty>}) — not overridden."
        fi

        echo ""
        echo "# GNU source mirror acceleration (see ADR-0004). Fetcher tries tuna first;"
        echo "# falls back to upstream ftpmirror on miss. Set PREMIRRORS = \"\" in local.conf"
        echo "# to disable, or your own to customize (see ADR-0005)."
        if [[ "$_user_premirrors_set" -eq 0 ]]; then
            echo "PREMIRRORS = \"https://ftpmirror.gnu.org/gnu/ https://mirrors.tuna.tsinghua.edu.cn/gnu/\""
        else
            echo "# PREMIRRORS defined in local.conf — not overridden."
        fi

        echo ""
        echo "# Hash equivalency database for shared sstate reuse across builds."
        echo "# When SSTATE_DIR is shared, put the hash database there too, not in build-specific dirs."
        echo "# See: https://docs.yoctoproject.org/bitbake/latest/manual/concepts.html#hashing"
        echo "BB_HASHSERVE_DB_DIR = \"\${SSTATE_DIR}\""

        echo ""
        echo "# npm network timeout defaults for Node.js recipes (e.g. webui-vue)."
        echo "# Override in local.conf with = if needed. Registry is auto-detected by 'ob build'."
        echo "npm_config_fetch_timeout ??= \"600000\""
        echo "export npm_config_fetch_timeout"
        echo "npm_config_fetch_retry_maxtimeout ??= \"120000\""
        echo "export npm_config_fetch_retry_maxtimeout"
        echo "npm_config_fetch_retry_mintimeout ??= \"30000\""
        echo "export npm_config_fetch_retry_mintimeout"
        echo "npm_config_fetch_retry_factor ??= \"2\""
        echo "export npm_config_fetch_retry_factor"
        echo "# npm_config_registry is NOT set here — it is injected dynamically by 'ob build'"
        echo "# via BB_ENV_PASSTHROUGH_ADDITIONS. Setting it to empty would break direct bitbake."

        if [[ "$is_wsl" -eq 1 ]] && [[ -n "$parallel_n" ]]; then
            echo ""
            echo "# WSL parallelism auto-tuning (WSL swap is slower than bare-metal, prone to OOM)."
            echo "# Formula: N = max(1, min(nproc, (MemTotal_GB + SwapTotal_GB) / 4))"
            echo "# Note: uses ?= (not ??=) because OE-core sets BB_NUMBER_THREADS/PARALLEL_MAKE"
            echo "# with ?= in bitbake.conf, and ??= would be too weak to override."
            echo "# Override in local.conf with plain = if needed: PARALLEL_MAKE = \"-j 8\""
            echo "BB_NUMBER_THREADS ?= \"$parallel_n\""
            echo "PARALLEL_MAKE ?= \"-j ${parallel_n}\""
        fi
    } > "$inc_file"

    mkdir -p "$(resolve_effective_dl_dir)" "$(resolve_effective_sstate_dir)"

    info "Generated $inc_file"
}

print_report() {
    step_header "Step 8/8: Status Report"

    local report_file="$CONFIGS_DIR/$MACHINE.report.txt"

    # Emit report to both terminal and file via tee
    {
        echo "============================================"
        echo "Machine:     $MACHINE"
        echo "Main repo:   $OPENBMC_DIR"
        echo "Build dir:   $BUILD_DIR"
        echo "Mirror dir:  $MIRROR_BASE"
        echo "Snapshot:    $CONFIGS_DIR/$MACHINE.snapshot"
        echo "Build conf:  $BUILD_DIR/conf/externalsrc-$MACHINE.inc"
        echo ""

        # --- Mirror stats ---
        if [[ -n "$MIRROR_BASE" ]]; then
            echo "Mirrors populated: ${#STATUS_MIRROR_NEW[@]} new, ${#STATUS_MIRROR_EXISTING[@]} existing"
            echo "  Mirror cache: $MIRROR_BASE"
            echo ""
        fi

        # --- Failed mirrors ---
        if [[ ${#STATUS_FAILED[@]} -gt 0 ]]; then
            echo "Failed mirrors: ${#STATUS_FAILED[@]}"
            for entry in "${STATUS_FAILED[@]}"; do
                echo "  [FAIL] $entry"
            done
            echo ""
            echo "[WARN] Troubleshooting guide:"
            echo "  A) Network flakiness      -> retry: ob init $MACHINE"
            echo "  B) Server network block   -> specific domains (e.g. infradead.org) may be unreachable"
            echo "  C) BitBake will fetch from remote during build if mirror is missing"
            echo ""
        fi

        # --- Elapsed time ---
        local elapsed_seconds=$SECONDS
        local elapsed_min=$((elapsed_seconds / 60))
        local elapsed_sec=$((elapsed_seconds % 60))
        echo "Total time: ${elapsed_min}m ${elapsed_sec}s"
        echo "============================================"
    } | tee "$report_file"

    echo ""
    info "Report saved to: $report_file"
    info "Next steps:"
    echo "  cd $OPENBMC_DIR"
    echo "  source setup $MACHINE"
    echo "  bitbake obmc-phosphor-image"
    echo ""
    info "Re-running ob init is safe — it is incremental and idempotent."
    echo "Safe to Ctrl+C at any time; re-run will resume from where it left off."
}

