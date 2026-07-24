#!/usr/bin/env bash
# tests/lib/status_fixtures.sh — ob status 测试共享 fixture。
# status_build_fixture <tmp_root> → 设 WORKSPACE_DIR/CONFIGS_DIR/OPENBMC_DIR/SOURCE_MANIFEST_FILE/
#   QEMU_PIDS_DIR 全局 + 造 fixture:legacy.lock(应隐藏)/snaponly(snapshot only→partial)/
#   markeronly(marker 无 firmware→initialized 缺 firmware)/failm(marker+build dir)/
#   built(marker+deploy artifact→firmware-image-ready)/orphan(artifact 无 marker→orphan) +
#   stalebox(recycled PID=$$)/recycbox stale QEMU 实例。
# 调用者负责 TMP=mktemp + trap 清理;本 helper 只填 fixture,不创建/清理 TMP。

_status_write_snapshot() {
    local machine="$1"
    cat > "$CONFIGS_DIR/$machine.snapshot" <<EOF
{
  "machine": "$machine",
  "generated_at": "2026-06-23T00:00:00+00:00",
  "openbmc_commit": "deadbeef1234",
  "target_image": "obmc-phosphor-image",
  "sub_repos": [
    {
      "name": "repo1",
      "src_uri": "git://example/repo1",
      "srcrev": "1111",
      "local_path": "workspace/src/$machine/repo1",
      "recipe": "recipe1"
    }
  ]
}
EOF
}

_status_write_marker() {
    local machine="$1"
    printf '2026-06-23T01:02:03Z\n' > "$CONFIGS_DIR/$machine.init-done"
}

status_build_fixture() {
    local tmp_root="$1"
    WORKSPACE_DIR="$tmp_root/workspace"
    CONFIGS_DIR="$WORKSPACE_DIR/configs"
    OPENBMC_DIR="$WORKSPACE_DIR/openbmc"
    SOURCE_MANIFEST_FILE="$CONFIGS_DIR/openbmc-source.manifest"
    mkdir -p "$CONFIGS_DIR" "$OPENBMC_DIR" "$OPENBMC_DIR/.git"

    printf '{"sub_repos": []}\n' > "$CONFIGS_DIR/legacy.lock"
    _status_write_snapshot snaponly
    _status_write_marker markeronly
    _status_write_marker failm
    mkdir -p "$OPENBMC_DIR/build/failm"
    _status_write_marker built
    local deploy_dir="$OPENBMC_DIR/build/built/tmp/deploy/images/built"
    mkdir -p "$deploy_dir"
    touch "$deploy_dir/built.static.mtd"
    local orphan_dir="$OPENBMC_DIR/build/orphan/tmp/deploy/images/orphan"
    mkdir -p "$orphan_dir"
    touch "$orphan_dir/orphan.static.mtd"

    # 两类 stale QEMU 实例:exited(pid 不存在) + recycled(pid=$$ 测试进程,cmdline 不匹配 qemu)
    QEMU_PIDS_DIR="$WORKSPACE_DIR/qemu-bin/.pids"
    mkdir -p "$QEMU_PIDS_DIR"
    printf 'pid=99999999\nbinary=qemu-system-arm\nmachine=stalebox\nssh_port=2222\nredfish_port=2443\nipmi_port=2623\n' > "$QEMU_PIDS_DIR/stalebox.pid"
    printf 'pid=%s\nbinary=qemu-system-arm\nmachine=recycbox\nssh_port=2225\nredfish_port=2445\nipmi_port=2625\n' "$$" > "$QEMU_PIDS_DIR/recycbox.pid"
}
