#!/usr/bin/env bash
# tests/unit/qemu_binary_decision.sh — binary 两纯决策 unit(update 判定 + URL 解析优先级)。
# 纯函数、无 IO、不 exit;锁住 aarch64 特例 / jenkins url guard / build 比较 / env>config>default 优先级。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# qemu_binary_update_decision <local_build> <remote_build> <manifest_url>
assert_eq "no local build → skip_no_build"      "$(qemu_binary_update_decision ""   "42" "https://jenkins.openbmc.org/x")" "skip_no_build"
assert_eq "non-jenkins url → skip_not_jenkins"  "$(qemu_binary_update_decision "40" "42" "https://example.com/x")"        "skip_not_jenkins"
assert_eq "no remote → skip_no_remote"          "$(qemu_binary_update_decision "40" ""   "https://jenkins.openbmc.org/x")" "skip_no_remote"
assert_eq "same build → up_to_date"             "$(qemu_binary_update_decision "42" "42" "https://jenkins.openbmc.org/x")" "up_to_date"
assert_eq "diff build → update_available"       "$(qemu_binary_update_decision "40" "42" "https://jenkins.openbmc.org/x")" "update_available"
# order: local_empty 检查先于 jenkins 检查
assert_eq "local-empty beats jenkins-check"     "$(qemu_binary_update_decision ""   "42" "https://example.com/x")"        "skip_no_build"

# qemu_binary_resolve_url <env_url> <config_url> <label> <arch>
assert_eq "env wins over config"          "$(qemu_binary_resolve_url "http://e" "http://c" community qemu-system-arm)"     "use_env"
assert_eq "config when no env"            "$(qemu_binary_resolve_url ""        "http://c" community qemu-system-arm)"     "use_config"
assert_eq "community+arm → default jenkins" "$(qemu_binary_resolve_url ""      ""        community qemu-system-arm)"     "default_jenkins"
assert_eq "community+aarch64 → none"      "$(qemu_binary_resolve_url ""        ""        community qemu-system-aarch64)" "none_aarch64"
assert_eq "non-community → needs_input"   "$(qemu_binary_resolve_url ""        ""        custom     qemu-system-arm)"     "needs_input"

assert_summary
