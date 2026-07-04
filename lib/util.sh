#!/usr/bin/env bash
# lib/util.sh — 底层通用工具(log/select_from_list/read_kv_field/require_path). 术语见 CONTEXT.md function semantic layer.
# Exit: leaf-no-exit（leaf-pure module; 例外 fn_quit/resolve_npm_registry/require_path 可 direct exit, require_path 使用 caller code）; 调用者负责 exit-code/remedy.


log()   { echo -e "$*"; }

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }

warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

verbose() { if [[ "$VERBOSE" -eq 1 ]]; then echo -e "[DEBUG] $*"; fi; }

# Print the 3-line confirmation banner (visual only — no confirmation logic).
# See CONTEXT.md "confirmation banner". Usage: print_confirm_banner "<verb>" "$object"
print_confirm_banner() {
    local verb="${1:-}"
    local object="${2:-}"
    echo "============================================================"
    echo ""
    warn "  You are about to ${verb}:  >>> ${object} <<<"
    warn "  You are about to ${verb}:  >>> ${object} <<<"
    warn "  You are about to ${verb}:  >>> ${object} <<<"
    echo ""
    echo "============================================================"
    echo ""
}

trim_whitespace() {
    local value="$1"

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    echo "$value"
}

# Convert ISO 8601 UTC timestamp to local display format (UTC+8).
# Input:  "2026-06-06T17:13:41Z" or empty/unparseable
# Output: "2026-06-07 01:13 UTC+8" or "<unknown>"
format_timestamp() {
    local raw="$1"

    if [[ -z "$raw" ]]; then
        echo "<unknown>"
        return 0
    fi

    # date -d understands ISO 8601 with trailing Z as UTC.
    # On a UTC+8 system, it automatically converts to local time.
    local ts_local
    ts_local=$(date -d "$raw" '+%Y-%m-%d %H:%M UTC+8' 2>/dev/null) || {
        echo "<unknown>"
        return 0
    }

    echo "$ts_local"
}

step_header() {
    local sep
    sep=$(printf '\u2500%.0s' {1..60})
    echo -e "${CYAN}${sep}${NC}"
    echo -e "  ${BOLD}${CYAN}$*${NC}"
    echo -e "${CYAN}${sep}${NC}"
}

show_logo() {
    echo -e ""
    echo -e "\033[38;2;255;216;106m      ██████╗ ██████╗ ███████╗ ███╗   ██╗ ██████╗ ███╗   ███╗ ██████╗\033[0m"
    echo -e "\033[38;2;220;220;90m     ██╔═══██╗██╔══██╗██╔════╝ ████╗  ██║ ██╔══██╗████╗ ████║██╔════╝ \033[0m"
    echo -e "\033[38;2;180;215;100m     ██║   ██║██████╔╝█████╗   ██╔██╗ ██║ ██████╔╝██╔████╔██║██║      \033[0m"
    echo -e "\033[38;2;160;210;115m     ██║   ██║██╔═══╝ ██╔══╝   ██║╚██╗██║ ██╔══██╗██║╚██╔╝██║██║      \033[0m"
    echo -e "\033[38;2;140;200;150m     ╚██████╔╝██║     ███████╗ ██║ ╚████║ ██████╔╝██║ ╚═╝ ██║╚██████╗ \033[0m"
    echo -e "\033[38;2;125;195;185m      ╚═════╝ ╚═╝     ╚══════╝ ╚═╝  ╚═══╝ ╚═════╝ ╚═╝     ╚═╝ ╚═════╝ \033[0m"
    echo -e "\033[38;2;115;195;215m     ██╗  ██╗  █████╗  █████╗   ███╗   ██╗ ███████╗ ███████╗ ███████╗ \033[0m"
    echo -e "\033[38;2;115;195;235m     ██║  ██║ ██╔══██╗ ██╔══██╗ ████╗  ██║ ██╔════╝ ██╔════╝ ██╔════╝ \033[0m"
    echo -e "\033[38;2;135;190;240m     ███████║ ███████║ ██████╔╝ ██╔██╗ ██║ █████╗   ███████╗ ███████╗ \033[0m"
    echo -e "\033[38;2;165;185;240m     ██╔══██║ ██╔══██║ ██╔══██╗ ██║╚██╗██║ ██╔══╝   ╚════██║ ╚════██║ \033[0m"
    echo -e "\033[38;2;195;180;240m     ██║  ██║ ██║  ██║ ██║  ██║ ██║ ╚████║ ███████╗ ███████║ ███████║ \033[0m"
    echo -e "\033[38;2;208;184;240m     ╚═╝  ╚═╝ ╚═╝  ╚═╝ ╚═╝  ╚═╝ ╚═╝  ╚═══╝ ╚══════╝ ╚══════╝ ╚══════╝ \033[0m"
    echo    "    ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
    echo -e "    ┃      OpenBMC Development Environment · \\033[38;2;255;210;80mob-harness\033[0m · 𝓲𝓪𝓼𝓲      ┃"
    echo    "    ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
}

show_brand_line() {
    echo -e "\n\033[38;2;255;210;80m━━━ >>> ob-harness <<< ━━━\033[0m\n"
}

fn_quit() {
    echo ""
    echo -e "${PROMPT_PREFIX} ...... Exit [ ob-harness · OpenBMC Development Environment ]"
    echo ""
    exit 0
}

read_local_conf_var() {
    local local_conf="$1"
    local var_name="$2"

    if [[ ! -f "$local_conf" ]]; then
        return 1
    fi

    python3 - "$local_conf" "$var_name" <<'PY'
import pathlib
import re
import sys

local_conf = pathlib.Path(sys.argv[1])
var_name = sys.argv[2]
pattern = re.compile(rf'^\s*{re.escape(var_name)}\s*(?:\?\?=|\?=|:=|=)\s*(.*)$')
value = None

for raw_line in local_conf.read_text().splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#"):
        continue

    match = pattern.match(raw_line)
    if not match:
        continue

    candidate = match.group(1).strip()
    if "#" in candidate:
        candidate = candidate.split("#", 1)[0].rstrip()

    if len(candidate) >= 2 and candidate[0] == candidate[-1] and candidate[0] in ('"', "'"):
        candidate = candidate[1:-1]

    value = candidate

if value is None:
    sys.exit(1)

print(value)
PY
}

# Check whether a URL points to a private/internal host.
# Mirrors parse_bitbake_deps.py _is_private_host() logic:
#   1. BitBake variable reference  (${GIT_MIRROR_HOST}, etc.)
#   2. RFC 1918 private IPs: 10.x.x.x, 172.16–31.x.x, 192.168.x.x
#   3. Host derived from runtime init script (meta-*/git-mirror-url.sh)
is_private_url() {
    local url="$1"

    # Extract host[:port] from common URL forms
    local host_port
    if [[ "$url" == git@* ]]; then
        # git@host:path or git@host:path.git
        host_port="${url#git@}"
        host_port="${host_port%%:*}"
    elif [[ "$url" == git://* ]]; then
        host_port="${url#git://}"
        host_port="${host_port%%/*}"
    elif [[ "$url" == http://* || "$url" == https://* || "$url" == ssh://* ]]; then
        host_port="${url#*://}"
        host_port="${host_port%%/*}"
        host_port="${host_port%%@*}"  # strip user@ prefix if any
    else
        return 1
    fi

    local host="${host_port%:*}"
    [[ "$host" == "$host_port" ]] && host="$host_port"

    # 1) BitBake variable reference (e.g. ${GIT_MIRROR_HOST})
    if [[ "$host" == *'${'* ]]; then
        return 0
    fi

    # 2) RFC 1918 private IP check (covers 10/8, 172.16-31/16, 192.168/16)
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local o1 o2
        IFS='.' read -r o1 o2 _ <<< "$host"
        if (( o1 == 10 )) \
            || (( o1 == 172 && o2 >= 16 && o2 <= 31 )) \
            || (( o1 == 192 && o2 == 168 )); then
            return 0
        fi
    fi

    # 3) Runtime init-script host (meta-*/git-mirror-url.sh GIT_MIRROR_HOST)
    local _rt_script=""
    for _candidate in "$WORKSPACE_DIR/openbmc"/meta-*/git-mirror-url.sh \
                      "$WORKSPACE_DIR/openbmc"/meta-*/github-gitlab-url.sh; do
        if [[ -f "$_candidate" ]]; then _rt_script="$_candidate"; break; fi
    done
    if [[ -f "$_rt_script" ]]; then
        local _rt_host
        _rt_host=$(grep -oP '^(GITLAB_IP|GIT_MIRROR_HOST)=["'"'"']?\K[^"'"'"'\s]+' "$_rt_script" 2>/dev/null | head -1 || true)
        if [[ -n "$_rt_host" && "$_rt_host" == "$host" ]]; then
            return 0
        fi
    fi

    return 1
}

resolve_effective_dl_dir() {
    local local_conf="$BUILD_DIR/conf/local.conf"
    local default_dl_dir="$WORKSPACE_DIR/downloads"
    local dl_dir=""

    # 1. Try reading DL_DIR from local.conf
    dl_dir=$(read_local_conf_var "$local_conf" "DL_DIR" 2>/dev/null || true)
    dl_dir=$(trim_whitespace "$dl_dir")

    # 2. Fall back to harness default if not configured
    if [[ -z "$dl_dir" ]]; then
        dl_dir="$default_dl_dir"
    fi

    # 3. Writability check — fallback to workspace/downloads/ if not writable
    mkdir -p "$dl_dir" 2>/dev/null
    if ! touch "$dl_dir/.ob-init-writable-test" 2>/dev/null; then
        warn "DL_DIR not writable: $dl_dir — falling back to $default_dl_dir"
        dl_dir="$default_dl_dir"
        mkdir -p "$dl_dir"
    else
        rm -f "$dl_dir/.ob-init-writable-test"
    fi

    echo "$dl_dir"
}

resolve_effective_sstate_dir() {
    local local_conf="$BUILD_DIR/conf/local.conf"
    local default_sstate_dir="$WORKSPACE_DIR/sstate-cache"
    local sstate_dir=""

    # 1. Try reading SSTATE_DIR from local.conf
    sstate_dir=$(read_local_conf_var "$local_conf" "SSTATE_DIR" 2>/dev/null || true)
    sstate_dir=$(trim_whitespace "$sstate_dir")

    # 2. Fall back to harness default if not configured
    if [[ -z "$sstate_dir" ]]; then
        sstate_dir="$default_sstate_dir"
    fi

    echo "$sstate_dir"
}

derive_bitbake_git_mirror_path() {
    local reference_root="$1"
    local src_uri="$2"

    python3 - "$reference_root" "$src_uri" <<'PY'
import pathlib
import sys
from urllib.parse import urlparse

reference_root = pathlib.Path(sys.argv[1])
src_uri = sys.argv[2].split(';', 1)[0].strip()

if not src_uri:
    sys.exit(1)

parsed = urlparse(src_uri)
host = parsed.netloc or parsed.path.split('/')[0]
path = parsed.path if parsed.netloc else parsed.path[len(host):]

if not host or not path:
    sys.exit(1)

gitsrcname = f"{host.replace(':', '.')}{path.replace('/', '.').replace('*', '.').replace(' ', '_').replace('(', '_').replace(')', '_')}"
if gitsrcname.startswith('.'):
    gitsrcname = gitsrcname[1:]

print(reference_root / gitsrcname)
PY
}

# 用 OB_ENTRY_DIR(由 ob 入口在 source lib 前算好)定位 HARNESS_ROOT。
detect_harness_root() {
    HARNESS_ROOT="$OB_ENTRY_DIR"
    WORKSPACE_DIR="$HARNESS_ROOT/workspace"
    OPENBMC_DIR="$WORKSPACE_DIR/openbmc"
    BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"
    SRC_DIR="$WORKSPACE_DIR/src/$MACHINE"
    CONFIGS_DIR="$WORKSPACE_DIR/configs"
    SOURCE_MANIFEST_FILE="$CONFIGS_DIR/openbmc-source.manifest"
    verbose "HARNESS_ROOT=$HARNESS_ROOT"
    verbose "WORKSPACE_DIR=$WORKSPACE_DIR"
    verbose "MACHINE=$MACHINE"
}

detect_wsl() {
    grep -qi microsoft /proc/version 2>/dev/null
}

calc_parallelism() {
    local mem_total_kb swap_total_kb mem_gb swap_gb total_gb cores budget
    mem_total_kb=$(grep -oP '^MemTotal:\s+\K\d+' /proc/meminfo 2>/dev/null || echo 0)
    swap_total_kb=$(grep -oP '^SwapTotal:\s+\K\d+' /proc/meminfo 2>/dev/null || echo 0)
    mem_gb=$((mem_total_kb / 1048576))
    swap_gb=$((swap_total_kb / 1048576))
    total_gb=$((mem_gb + swap_gb))
    cores=$(nproc 2>/dev/null || echo 1)
    # Each gcc process budgeted ~4 GB; cap at physical core count; minimum 1
    budget=$((total_gb / 4))
    if [[ "$budget" -lt 1 ]]; then budget=1; fi
    if [[ "$budget" -gt "$cores" ]]; then budget=$cores; fi
    echo "$budget"
}

# Probe both npm registries in parallel, return the URL of the faster one.
# Default preference: npmmirror.com (Chinese mirror).
# If npmjs.org is clearly faster (<3s AND <1.5× mirror time), prefer npmjs.org.
# Returns: echoes registry URL, or empty string if both fail.
probe_npm_registry() {
    local npmjs_url="https://registry.npmjs.org/uuid/-/uuid-9.0.0.tgz"
    local mirror_url="https://registry.npmmirror.com/uuid/-/uuid-9.0.0.tgz"
    local tmp_npmjs tmp_mirror

    if ! command -v curl &>/dev/null; then
        verbose "curl not available, defaulting to npmmirror.com"
        echo "https://registry.npmmirror.com/"
        return 0
    fi

    tmp_npmjs=$(mktemp /tmp/ob-npm-probe-npmjs-XXXXXX)
    tmp_mirror=$(mktemp /tmp/ob-npm-probe-mirror-XXXXXX)

    # Parallel probes — each writes download time (seconds) to a temp file
    { curl -s -o /dev/null -w '%{time_total}' --max-time 10 "$npmjs_url" > "$tmp_npmjs" 2>/dev/null; } &
    local pid_npmjs=$!
    { curl -s -o /dev/null -w '%{time_total}' --max-time 10 "$mirror_url" > "$tmp_mirror" 2>/dev/null; } &
    local pid_mirror=$!

    wait "$pid_npmjs" 2>/dev/null || true
    wait "$pid_mirror" 2>/dev/null || true

    local npmjs_time="" mirror_time=""
    npmjs_time=$(cat "$tmp_npmjs" 2>/dev/null | tr -d '[:space:]')
    mirror_time=$(cat "$tmp_mirror" 2>/dev/null | tr -d '[:space:]')
    rm -f "$tmp_npmjs" "$tmp_mirror"

    verbose "  npmjs.org: ${npmjs_time:-timeout}s | npmmirror.com: ${mirror_time:-timeout}s"

    # Both failed
    if [[ -z "$npmjs_time" ]] && [[ -z "$mirror_time" ]]; then
        echo ""
        return 0
    fi

    # Only one succeeded — use it
    if [[ -z "$npmjs_time" ]]; then
        echo "https://registry.npmmirror.com/"
        return 0
    fi
    if [[ -z "$mirror_time" ]]; then
        echo "https://registry.npmjs.org/"
        return 0
    fi

    # Both succeeded — pick the better one.
    # npmmirror.com is the safe default. Only switch to npmjs.org when
    # the mirror is genuinely slow and npmjs.org is clearly fast.
    local mirror_fast=0
    if awk "BEGIN { exit !($mirror_time < 2) }" 2>/dev/null; then
        mirror_fast=1
    fi

    if [[ "$mirror_fast" -eq 1 ]]; then
        echo "https://registry.npmmirror.com/"
    elif awk "BEGIN { exit !($npmjs_time < 1) }" 2>/dev/null; then
        echo "https://registry.npmjs.org/"
    else
        echo "https://registry.npmmirror.com/"
    fi
}

# Resolve which npm registry to use.
# Decision order: OB_NPM_REGISTRY env > cache (<24h) > probe > error.
# Sets NPM_REGISTRY_RESOLVED: the chosen URL, "" for npm default, or "skip".
resolve_npm_registry() {
    local cache_file="$CONFIGS_DIR/$MACHINE.npm-registry"
    local cache_ttl=86400  # 24 hours
    NPM_REGISTRY_RESOLVED=""

    # 1. Environment variable override
    if [[ -n "${OB_NPM_REGISTRY+x}" ]]; then
        if [[ -z "$OB_NPM_REGISTRY" ]]; then
            info "OB_NPM_REGISTRY is set (empty) — npm registry auto-detection disabled"
            NPM_REGISTRY_RESOLVED="skip"
            return 0
        fi
        info "OB_NPM_REGISTRY override: $OB_NPM_REGISTRY"
        NPM_REGISTRY_RESOLVED="$OB_NPM_REGISTRY"
        return 0
    fi

    # 2. Cache check
    if [[ -f "$cache_file" ]]; then
        local cache_epoch cache_url cache_age
        cache_epoch=$(sed -n '1p' "$cache_file" 2>/dev/null | grep -oP '^\d+$' || echo "")
        cache_url=$(sed -n '2p' "$cache_file" 2>/dev/null || true)
        if [[ -n "$cache_epoch" && -n "$cache_url" ]]; then
            cache_age=$(( $(date +%s) - cache_epoch ))
            if [[ "$cache_age" -lt "$cache_ttl" ]]; then
                local hours_ago=$(( cache_age / 3600 ))
                info "npm registry: $cache_url (cached, probed ${hours_ago}h ago)"
                NPM_REGISTRY_RESOLVED="$cache_url"
                return 0
            fi
            verbose "npm registry cache stale (${cache_age}s > ${cache_ttl}s), re-probing"
        fi
    fi

    # 3. Live probe
    info "Probing npm registries (npmjs.org vs npmmirror.com, max 10s)..."
    local chosen_url
    chosen_url=$(probe_npm_registry)
    if [[ -z "$chosen_url" ]]; then
        # Both registries timed out — check if this was a real timeout or curl missing
        if ! command -v curl &>/dev/null; then
            warn "curl not available for npm registry probe, using npmjs.org default"
            chosen_url="https://registry.npmjs.org/"
        else
            echo ""
            error "Both npm registries are unreachable (10s timeout):"
            error "  - registry.npmjs.org: timeout"
            error "  - registry.npmmirror.com: timeout"
            echo ""
            echo "  Possible causes:"
            echo "    1. No internet connectivity"
            echo "    2. Firewall blocking HTTPS to registry hosts"
            echo "    3. DNS resolution failure"
            echo ""
            echo "  To override manually:"
            echo "    export OB_NPM_REGISTRY=https://registry.npmmirror.com/"
            echo "    ob build"
            echo ""
            echo "  To skip npm configuration entirely:"
            echo "    export OB_NPM_REGISTRY="
            echo "    ob build"
            echo ""
            exit 1
        fi
    fi

    # Write cache
    {
        date +%s
        echo "$chosen_url"
    } > "$cache_file" 2>/dev/null || warn "Failed to write npm registry cache to $cache_file"

    info "npm registry: $chosen_url (auto-detected)"
    NPM_REGISTRY_RESOLVED="$chosen_url"
}

# Read first `key=value` match from a file. Echoes value (after first '=');
# returns 0 if found / 1 if file missing or key absent. L3 — never exits.
read_kv_field() {
    local file="$1"
    local key="$2"
    [[ -f "$file" ]] || return 1
    local line
    line=$(grep -m1 "^${key//./\\.}=" "$file" 2>/dev/null) || return 1
    [[ -z "$line" ]] && return 1
    echo "${line#*=}"
    return 0
}

read_manifest_field() {
    local key="$1"
    read_kv_field "$SOURCE_MANIFEST_FILE" "$key"
}

# confirm_action <verb> <object>
# Prints confirmation banner, loops until Y/y (confirm) or N/n (cancel).
# Returns 0=confirmed / 2=cancelled / 1=read failure. L3 — never exits.
confirm_action() {
    print_confirm_banner "$1" "$2"
    local confirm
    while true; do
        if ! read -r -p "$(echo -e "${PROMPT_PREFIX} Type (Y/y) to confirm, (N/n) to cancel: ")" confirm; then
            error "Unable to read confirmation from stdin."
            return 1
        fi
        case "$confirm" in
            [yY]) return 0 ;;
            [nN]) return 2 ;;
            *) warn "Invalid input. Please type Y or N." ;;
        esac
    done
}

# prompt_for_absolute_path <prompt>
# Reads+trims input, loops until non-empty / not an option / absolute path (/*).
# Sets global PROMPT_PATH_RESULT on success. Returns 0=ok / 1=read failure.
# Existence/content validation left to caller. L3 — never exits.
prompt_for_absolute_path() {
    local prompt="$1"
    local input
    while true; do
        if ! read -r -p "$(echo -e "${PROMPT_PREFIX} ${prompt}: ")" input; then
            error "Unable to read input."
            return 1
        fi
        input=$(trim_whitespace "$input")
        if [[ -z "$input" ]]; then
            error "Path cannot be empty."
            continue
        fi
        if [[ "$input" == -* ]]; then
            error "Path must be a filesystem path, not an option: $input"
            continue
        fi
        if [[ "$input" != /* ]]; then
            error "Must be an absolute path (starting with /). Got: $input"
            continue
        fi
        PROMPT_PATH_RESULT="$input"
        return 0
    done
}

# require_path <path> <label> <hint> <exit_code>
# Precondition guard: if <path> does not exist (-e), print
# "<label> not found: <path>", then <hint> (if non-empty), then exit <exit_code>.
# L3 helper; the internal exit is orchestration semantics — <exit_code> is supplied
# by the caller per its own layer (L1 cmd_* use 3, L2 precondition sites use 3).
require_path() {
    local path="$1"
    local label="$2"
    local hint="$3"
    local code="$4"
    if [[ ! -e "$path" ]]; then
        error "$label not found: $path"
        if [[ -n "$hint" ]]; then
            error "$hint"
        fi
        exit "$code"
    fi
}

