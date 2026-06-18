#!/usr/bin/env bash
# tests/unit/url.sh — 纯逻辑函数单测(test layer unit 层示范)。
# 覆盖 normalize_repo_url / is_valid_repo_url / derive_source_label。
#
# 【怎么用】$ bash tests/unit/url.sh
# 【由来】unit 层第一个测试,示范加载模式(ob_loader + assert)+ 真实 case。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# normalize_repo_url: 去协议/.git/尾斜杠 + lowercase + port 处理
assert_eq "norm https" "$(normalize_repo_url 'https://GitHub.com/OpenBMC/openbmc.git')" 'github.com/openbmc/openbmc'
assert_eq "norm git@"  "$(normalize_repo_url 'git@github.com:openbmc/openbmc.git')"    'github.com/openbmc/openbmc'
assert_eq "norm slash" "$(normalize_repo_url 'https://github.com/openbmc/openbmc/')"    'github.com/openbmc/openbmc'

# is_valid_repo_url (return 0/1)
assert_true  "valid https"  is_valid_repo_url 'https://x'
assert_true  "valid git@"   is_valid_repo_url 'git@h:p.git'
assert_false "invalid bare" is_valid_repo_url 'not-a-url'

# derive_source_label: 依 OPENBMC_REPO_URL 推 community/custom(设全局 SOURCE_LABEL)
OPENBMC_REPO_URL='https://github.com/openbmc/openbmc.git'; derive_source_label
assert_eq "label community" "$SOURCE_LABEL" 'community'
OPENBMC_REPO_URL='https://gitlab.example.com/team/openbmc.git'; derive_source_label
assert_eq "label custom"    "$SOURCE_LABEL" 'custom'

assert_summary
