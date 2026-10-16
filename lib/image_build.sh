#!/usr/bin/env bash
# lib/image_build.sh — obmc-phosphor-image 整体构建执行编排 module。术语见 GLOSSARY.md obmc-phosphor-image build module.
# Exit: leaf-no-exit（leaf-pure module）; return bitbake rc(0/非0), exit 由 L1 cmd_* 收口。
# 消费 build_env_enter(build_env.sh) + resolve/apply_npm_registry(util.sh) + bitbake。
# ob build / ob deploy-to-qemu 共享; 不含 machine 选择/确认/展示/exit 收口(那些是 cmd_* L1); 不处理 DRY-RUN(调用点入口前短路)。
# 非 tty 托管运行(stdout 重定向/systemd)时抽取结构化进度到 CONFIGS_DIR/<machine>.build.progress;
# 交互 tty 保持 bitbake 原生呈现, 进度文件清空留置(空=本次无结构化进度, 防陈旧误读)。

# bitbake_progress_filter <progress_file> — stdin 逐行透传(stdout), 同时抽取进度行 append 到 progress_file。
# 抽取对象: "Running task N of M"(bitbake 派发计数, 非完成百分比) / "Tasks Summary:"(收尾汇总) / "ERROR: "。
# 时间戳 = 每条被抽取事件的 Unix epoch; close(pf) 逐行落盘, 监控端 tail 即时可读。
# leaf-pure: 无 exit; 管道末段, 调用方以 PIPESTATUS[0] 取 bitbake rc。
bitbake_progress_filter() {
    local progress_file="$1"
    awk -v pf="$progress_file" '
        function epoch( cmd, value ) {
            cmd = "date +%s"
            cmd | getline value
            close(cmd)
            return value
        }
        /Running task [0-9]+ of [0-9]+/ {
            if (match($0, /Running task [0-9]+ of [0-9]+/)) {
                print epoch() "\t" $0 >> pf
                close(pf)
            }
        }
        /Tasks Summary:/ || /ERROR: / {
            print epoch() "\t" $0 >> pf
            close(pf)
        }
        { print; fflush() }
    '
}

build_obmc_image() {
    local machine="$1" build_dir="$2"

    # 进入 current-shell build environment(cd+source setup)。|| return 1 防 if build_obmc_image
    # 条件形态下 errexit 关闭上下文里 enter 失败静默继续到 bitbake 坏环境(strict-mode 静默吞陷阱)。
    build_env_enter "$machine" "$build_dir" 2>/dev/null || return 1

    # npm registry 装配(resolve 决策→apply 装配, 对偶 leaf-pure)
    resolve_npm_registry
    apply_npm_registry

    # 结构化进度文件: 非 tty(重定向/systemd 托管)→ 过滤抽取; tty(交互)→ 清空留置(空=本次无结构化进度)。
    local progress_file=""
    if [[ -n "${CONFIGS_DIR:-}" ]]; then
        mkdir -p "$CONFIGS_DIR" 2>/dev/null || true
        progress_file="$CONFIGS_DIR/$machine.build.progress"
        : > "$progress_file" 2>/dev/null || progress_file=""
        if [[ -t 1 ]]; then
            progress_file=""   # 交互 tty: bitbake 原生呈现, 不抽取
        fi
    fi

    # 构建 obmc-phosphor-image; rc 经 PIPESTATUS[0]/$? 收敛到 return(leaf-pure 无 exit)。
    # || 挂 rc 防 caller bare-call + set -e 时管道/命令非零直穿 shell(bp_07)。
    local bitbake_rc=0
    if [[ -n "$progress_file" ]]; then
        bitbake obmc-phosphor-image | bitbake_progress_filter "$progress_file" || bitbake_rc=${PIPESTATUS[0]}
    else
        bitbake obmc-phosphor-image || bitbake_rc=$?
    fi
    return "$bitbake_rc"
}
