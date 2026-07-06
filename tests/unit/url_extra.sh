#!/usr/bin/env bash
# tests/unit/url_extra.sh — URL/hostkey 半纯函数单测(unit 层)。
# 覆盖 detect_runtime_git_host / parse_hostkey_offending。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# parse_hostkey_offending:提取 "Offending TYPE key in <file>:<line>" → "<file> <line>"
assert_eq "hostkey parse"    "$(parse_hostkey_offending 'Offending ECDSA key in /home/u/.ssh/known_hosts:5')" "/home/u/.ssh/known_hosts 5"
assert_eq "hostkey no match" "$(parse_hostkey_offending 'no offending key here')" ""

assert_summary
