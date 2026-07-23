#!/usr/bin/env bash
# tests/unit/qemu_binary_resolve.sh — qemu_binary 纯决策族 unit。
# jenkins URL 提取 + (Task 2 追加) resolve_custom_* 路径解析。纯函数、无 IO、不 exit。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# jenkins_job_url_from_url <url>  →  echo job base url(剥 lastSuccessfulBuild/artifact 后缀)
assert_eq "artifact 后缀剥离" \
  "$(jenkins_job_url_from_url 'https://jenkins.openbmc.org/job/latest-qemu-x86/lastSuccessfulBuild/artifact/qemu/build/qemu-system-arm')" \
  'https://jenkins.openbmc.org/job/latest-qemu-x86'
assert_eq "仅 lastSuccessfulBuild 后缀" \
  "$(jenkins_job_url_from_url 'https://jenkins.openbmc.org/job/latest-qemu-x86/lastSuccessfulBuild/api/json')" \
  'https://jenkins.openbmc.org/job/latest-qemu-x86'
assert_eq "无后缀原样返回" \
  "$(jenkins_job_url_from_url 'https://jenkins.openbmc.org/job/latest-qemu-x86')" \
  'https://jenkins.openbmc.org/job/latest-qemu-x86'

assert_summary
