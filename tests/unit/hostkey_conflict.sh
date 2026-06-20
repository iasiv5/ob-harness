#!/usr/bin/env bash
# tests/unit/hostkey_conflict.sh — check_ssh_hostkey_conflict 双轨检测单测(unit 层)。
# 覆盖 4 条分支:
#   S1 无条目         → 静默(ssh probe 都不调)
#   S2 Track A 确证失效 → 删除菜单(非交互 → 跳过,不自动删)
#   S3 Permission denied → 条目仍匹配 → 静默
#   S4 Track B sshd 未就绪 → 强提示 + 给命令,不自动删
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
assert_reset

# ssh-keygen stub: -F 命中(输出条目) / -F 未命中(exit 1) / 其余(-R)落到 .calls
mk_kg_found()  { stub_script "$1" ssh-keygen 'if [[ "$1" == "-F" ]]; then echo "# Host [localhost]:2222 found: line 6"; echo "|1|fake= fakekey AAAA"; exit 0; fi'; }
mk_kg_absent() { stub_exit "$1" ssh-keygen 1; }

# 断言 stub 的 ssh-keygen 未被以 -R 调用(即未自动删除 known_hosts 条目)。
assert_not_ran_clear() {
    local dir="$1" label="$2"
    if grep -q -- '-R' "$dir/.ssh-keygen.calls" 2>/dev/null; then
        _assert_bad "$label (ssh-keygen -R was called: $(cat "$dir/.ssh-keygen.calls" 2>/dev/null))"
    else
        _assert_ok "$label"
    fi
}

# --- S1: known_hosts 无条目 → 静默, ssh probe 都不调 ---
D1=$(mktemp -d); mkfake_bin "$D1" ssh ssh-keygen; mk_kg_absent "$D1"
out=$(with_stub "$D1" -- check_ssh_hostkey_conflict 2222 </dev/null 2>/dev/null)
assert_eq   "S1 no-entry silent"        "$out" ""
assert_true "S1 no-entry ssh not probed" test ! -s "$D1/.ssh.calls"

# --- S2: Track A — sshd 就绪 + 确证失效 → 删除菜单(非交互 → 跳过删除) ---
D2=$(mktemp -d); mkfake_bin "$D2" ssh ssh-keygen; mk_kg_found "$D2"
stub_out  "$D2" ssh "$(printf '@@@ REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nOffending ED25519 key in /tmp/fake_kh:6\nHost key verification failed.')"
stub_exit "$D2" ssh 255
out=$(with_stub "$D2" -- check_ssh_hostkey_conflict 2222 </dev/null 2>/dev/null)
assert_contains      "S2 track-A stale warning"  "$out" "Stale SSH host key"
assert_contains      "S2 track-A clear command" "$out" 'ssh-keygen -f'
assert_not_ran_clear "$D2" "S2 track-A non-interactive → no auto-delete"

# --- S3: Permission denied — 条目仍匹配 → 静默(verbose 默认无输出) ---
D3=$(mktemp -d); mkfake_bin "$D3" ssh ssh-keygen; mk_kg_found "$D3"
stub_out  "$D3" ssh "Permission denied (publickey,password)."
stub_exit "$D3" ssh 255
out=$(with_stub "$D3" -- check_ssh_hostkey_conflict 2222 </dev/null 2>/dev/null)
assert_eq "S3 perm-denied silent (entry still valid)" "$out" ""

# --- S4: Track B — sshd 未就绪 + 有条目 → 强提示 + 命令, 不自动删 ---
D4=$(mktemp -d); mkfake_bin "$D4" ssh ssh-keygen; mk_kg_found "$D4"
stub_out  "$D4" ssh "ssh: connect to host 127.0.0.1 port 2222: Connection refused"
stub_exit "$D4" ssh 255
out=$(with_stub "$D4" -- check_ssh_hostkey_conflict 2222 </dev/null 2>/dev/null)
assert_contains      "S4 track-B warning"   "$out" "Found a known_hosts entry"
assert_contains      "S4 track-B clear cmd" "$out" "ssh-keygen -R '[localhost]:2222'"
assert_not_ran_clear "$D4" "S4 track-B → no auto-delete"

assert_summary
