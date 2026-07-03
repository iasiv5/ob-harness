#!/usr/bin/env bash
# tests/lib/qemu_stubs.sh — 共享 PATH-stub 构造器 for qemu tests。
# 依赖 tests/lib/stub.sh 的 mkfake_bin/stub_out/stub_script。
# 每个 make_* 在给定 <dir> 生成 fake 命令;<dir> 的生命周期(mktemp -d / 清理)由调用者负责。
#
# 设计要点:fake 命令的真实分支逻辑用 stub_script(source 语义,$@ 可用)实现,
# 使被测的 orchestrator 真实跑在假外部命令上——PATH-injection 而非函数 override,
# 避开 coverage radar 的 override 虚高(见 bestpractice_09 / coverage_radar docstring)。

# make_qemu_curl_fake <dir>
#   fake curl:URL 含 api/json → stdout 吐 Jenkins {"number":N}(供 query_jenkins_build_number);
#   否则按 -o <path> 写假 qemu 字节(供 download_qemu_binary_core)。
#   环境变量(用例须 export;fake curl 跑在子进程,非 export 的 shell 变量不可见):
#     QEMU_FAKE_JENKINS_BUILD  Jenkins build 号(默认 42)
#     QEMU_FAKE_ARCHIVE        若指向真实文件,下载时 cp 它到 -o 目标(测归档解压路径)
make_qemu_curl_fake() {
    local dir="$1"
    mkfake_bin "$dir" curl
    # 直接写 .curl.sh(quoted heredoc,免 stub_script 嵌套引号),保留 mkfake_bin 的调用记录。
    cat > "$dir/.curl.sh" <<'CURL_SH'
case "$*" in
    *api/json*)
        printf '{"number":%s}\n' "${QEMU_FAKE_JENKINS_BUILD:-42}"
        ;;
    *)
        out=""; prev=""
        for a in "$@"; do
            [[ "$prev" == "-o" ]] && out="$a"
            prev="$a"
        done
        if [[ -n "$out" ]]; then
            if [[ -n "${QEMU_FAKE_ARCHIVE:-}" && -f "$QEMU_FAKE_ARCHIVE" ]]; then
                cp "$QEMU_FAKE_ARCHIVE" "$out"
            else
                printf '#!/usr/bin/env bash\necho fake-qemu\n' > "$out"
            fi
        fi
        ;;
esac
CURL_SH
}

# make_setsid_sentinel <dir> <sentinel_file>
#   fake setsid:把 "$@" 写进 sentinel 文件,不真启动(供 qemu_execute_launch smoke
#   断言 QEMU_CMD 装配正确,又不触发真实 QEMU)。
make_setsid_sentinel() {
    local dir="$1"; local sentinel="$2"
    mkfake_bin "$dir" setsid
    # unquoted heredoc:$sentinel 插值, \$* 保留到 sourced 时展开。
    cat > "$dir/.setsid.sh" <<SETS_SH
printf '%s\n' "\$*" > "$sentinel"
SETS_SH
}

# make_pgrep_fake <dir> <pid>
#   fake pgrep:恒输出给定 PID(单行),供 _qemu_post_launch/execute_launch 的 PID 发现。
make_pgrep_fake() {
    local dir="$1"; local pid="$2"
    mkfake_bin "$dir" pgrep
    stub_out "$dir" pgrep "$pid"
}

# make_bitbake_env_fake <dir> [qb_machine] [qb_mem] [qb_system_name]
#   fake bitbake -e:吐 QB_* 变量(格式同 qemu_launch_profile structure 测试),
#   供 resolve_qemu_launch_profile 的 bitbake fallback 路径解析。
make_bitbake_env_fake() {
    local dir="$1"
    local qb_machine="${2:--machine romulus}"
    local qb_mem="${3:--m 512}"
    local qb_system="${4:-qemu-system-arm}"
    mkfake_bin "$dir" bitbake
    stub_out "$dir" bitbake "QB_MACHINE=\"$qb_machine\"
QB_MEM=\"$qb_mem\"
QB_SYSTEM_NAME=\"$qb_system\""
}
