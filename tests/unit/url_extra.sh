#!/usr/bin/env bash
# tests/unit/url_extra.sh — URL/hostkey 半纯函数单测(unit 层)。
# 覆盖 is_private_url / parse_hostkey_offending。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# is_private_url:return 0=private,1=public(需 URL 形式,裸 IP 不匹配 protocol)
assert_true  "private 10/8"       is_private_url 'http://10.0.0.1/x'
assert_true  "private 192.168"    is_private_url 'http://192.168.1.1/x'
assert_true  "private 172.16"     is_private_url 'http://172.16.0.1/x'
assert_true  "bitbake var"        is_private_url 'http://${GIT_MIRROR_HOST}/x'
assert_false "public 8.8.8.8"     is_private_url 'http://8.8.8.8/x'
assert_false "public github"      is_private_url 'git@github.com:org/repo.git'
assert_false "bare ip no proto"   is_private_url '10.0.0.1'

# parse_hostkey_offending:提取 "Offending TYPE key in <file>:<line>" → "<file> <line>"
assert_eq "hostkey parse"    "$(parse_hostkey_offending 'Offending ECDSA key in /home/u/.ssh/known_hosts:5')" "/home/u/.ssh/known_hosts 5"
assert_eq "hostkey no match" "$(parse_hostkey_offending 'no offending key here')" ""

assert_summary
