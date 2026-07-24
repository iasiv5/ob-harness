#!/usr/bin/env bash
# lib/image_build.sh — obmc-phosphor-image 整体构建执行编排 module。术语见 CONTEXT.md obmc-phosphor-image build module.
# Exit: leaf-no-exit（leaf-pure module）; return bitbake rc(0/非0), exit 由 L1 cmd_* 收口。
# 消费 build_env_enter(build_env.sh) + resolve/apply_npm_registry(util.sh) + bitbake。
# ob build / ob deploy-to-qemu 共享; 不含 machine 选择/确认/展示/exit 收口(那些是 cmd_* L1); 不处理 DRY-RUN(调用点入口前短路)。

build_obmc_image() {
    local machine="$1" build_dir="$2"

    # 进入 current-shell build environment(cd+source setup)。|| return 1 防 if build_obmc_image
    # 条件形态下 errexit 关闭上下文里 enter 失败静默继续到 bitbake 坏环境(strict-mode 静默吞陷阱)。
    build_env_enter "$machine" "$build_dir" 2>/dev/null || return 1

    # npm registry 装配(resolve 决策→apply 装配, 对偶 leaf-pure)
    resolve_npm_registry
    apply_npm_registry

    # 构建 obmc-phosphor-image; 函数末条命令 rc 即函数返回码(0=成功/非0=失败); stdout/stderr 透传不变。
    bitbake obmc-phosphor-image
}
