#!/usr/bin/env bash
# tests/unit/url_extra.sh — URL/hostkey 半纯函数单测(unit 层)。
# 覆盖 detect_runtime_git_host / parse_hostkey_offending。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# detect_runtime_git_host: vendor 脚本 GITLAB_IP/GIT_MIRROR_HOST 优先 → fallback origin → 空
# fallback case 用 $(...) 捕获(subshell 首次求值即可);缓存 case 必须 direct call($() 不穿透全局缓存)。
_save_openbmc="${OPENBMC_DIR:-}"
TMP2=$(mktemp -d)
mkdir -p "$TMP2/meta-x"

# case 1: vendor 脚本含 GITLAB_IP
OPENBMC_DIR="$TMP2"
printf 'GITLAB_IP=10.0.0.9\n' > "$TMP2/meta-x/git-mirror-url.sh"
assert_eq "host from GITLAB_IP script" "$(detect_runtime_git_host)" "10.0.0.9"
unset _RUNTIME_GIT_HOST_RESOLVED _RUNTIME_GIT_HOST

# case 2: vendor 脚本含 GIT_MIRROR_HOST
rm -f "$TMP2/meta-x/git-mirror-url.sh"; printf 'GIT_MIRROR_HOST=mirror.local\n' > "$TMP2/meta-x/git-mirror-url.sh"
assert_eq "host from GIT_MIRROR_HOST script" "$(detect_runtime_git_host)" "mirror.local"
unset _RUNTIME_GIT_HOST_RESOLVED _RUNTIME_GIT_HOST

# case 3: 无 vendor 脚本 → fallback origin(需真 git 仓)
rm -f "$TMP2/meta-x/git-mirror-url.sh"; rmdir "$TMP2/meta-x"
git init -q "$TMP2/openbmc-repo" 2>/dev/null
git -C "$TMP2/openbmc-repo" remote add origin git@gitlab.example.com:team/repo.git 2>/dev/null
OPENBMC_DIR="$TMP2/openbmc-repo"
assert_eq "host from git@ origin" "$(detect_runtime_git_host)" "gitlab.example.com"
git -C "$TMP2/openbmc-repo" remote set-url origin https://gitlab2.example.com/team/repo.git 2>/dev/null
unset _RUNTIME_GIT_HOST_RESOLVED _RUNTIME_GIT_HOST
assert_eq "host from https origin" "$(detect_runtime_git_host)" "gitlab2.example.com"
unset _RUNTIME_GIT_HOST_RESOLVED _RUNTIME_GIT_HOST

# case 4: 都没有 → 空 + return 0
OPENBMC_DIR="$TMP2/no-such"
assert_rc 0 "empty host returns 0" detect_runtime_git_host
assert_eq "empty host echoes nothing" "$(detect_runtime_git_host)" ""
unset _RUNTIME_GIT_HOST_RESOLVED _RUNTIME_GIT_HOST

# case 5: 缓存幂等——首次求值后改 script,第二次仍返回缓存值(钉"不重算")
#   detect 内全局缓存不穿透 $() subshell,故 case5/6 用 direct call + 读 _RUNTIME_GIT_HOST
mkdir -p "$TMP2/meta-x"
printf 'GITLAB_IP=10.0.0.9\n' > "$TMP2/meta-x/git-mirror-url.sh"
OPENBMC_DIR="$TMP2"
detect_runtime_git_host >/dev/null
first="${_RUNTIME_GIT_HOST:-}"
printf 'GITLAB_IP=10.0.0.10\n' > "$TMP2/meta-x/git-mirror-url.sh"   # 改 script,不 unset 缓存
detect_runtime_git_host >/dev/null
second="${_RUNTIME_GIT_HOST:-}"
assert_eq "cache returns first value" "$first" "10.0.0.9"
assert_eq "cache: 2nd call unchanged" "$second" "10.0.0.9"
unset _RUNTIME_GIT_HOST_RESOLVED _RUNTIME_GIT_HOST

# case 6: 哨兵区分"已求值空"vs"未求值"——首次空后补 script,未 unset 仍空(钉哨兵用 ${x+x} 而非 -n)
rm -f "$TMP2/meta-x/git-mirror-url.sh"
OPENBMC_DIR="$TMP2/no-such3"   # 无 vendor script 无 origin
detect_runtime_git_host >/dev/null
empty_first="${_RUNTIME_GIT_HOST:-}"
assert_eq "first call empty" "$empty_first" ""
OPENBMC_DIR="$TMP2"; printf 'GITLAB_IP=10.0.0.9\n' > "$TMP2/meta-x/git-mirror-url.sh"   # 补 script
detect_runtime_git_host >/dev/null   # 未 unset,用缓存(空)
still_empty="${_RUNTIME_GIT_HOST:-}"
assert_eq "cached empty sticks until unset" "$still_empty" ""
unset _RUNTIME_GIT_HOST_RESOLVED _RUNTIME_GIT_HOST

rm -rf "$TMP2"
OPENBMC_DIR="$_save_openbmc"
unset _RUNTIME_GIT_HOST_RESOLVED _RUNTIME_GIT_HOST

# parse_hostkey_offending:提取 "Offending TYPE key in <file>:<line>" → "<file> <line>"
assert_eq "hostkey parse"    "$(parse_hostkey_offending 'Offending ECDSA key in /home/u/.ssh/known_hosts:5')" "/home/u/.ssh/known_hosts 5"
assert_eq "hostkey no match" "$(parse_hostkey_offending 'no offending key here')" ""

assert_summary
