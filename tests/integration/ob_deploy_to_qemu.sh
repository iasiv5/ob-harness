#!/usr/bin/env bash
# tests/integration/ob_deploy_to_qemu.sh — ob deploy-to-qemu real integration (opt-in via --integration)。
# 覆盖: image rebuild(bitbake obmc-phosphor-image) + QEMU 重启(端口复用) + 新 .pid + BMC SSH 端到端。
# gate: 默认不跑(run_all --integration 追加); SKIP 门 exit 77(无 init machine)。
# 真跑 1-4h bitbake build + 占端口, 仅 CI / 手动 --integration 触发; SKIP 门照 ob_dev.sh:172 模式。
# 成功边界 = deploy rc=0(image 重建 + QEMU 启动); BMC SSH ready 是 boot 过程, 信心检查(warn 不 exit 1)。
set -uo pipefail

root_dir="${OB_INTEGRATION_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$root_dir" || exit 1

# 探测 init machine(env 覆盖 > 扫 workspace/configs/*.init-done; 照 ob_dev.sh:165-172)
MACHINE="${OB_INTEGRATION_MACHINE:-}"
if [[ -z "$MACHINE" ]]; then
    _marker=""
    for _marker in workspace/configs/*.init-done; do
        [[ -f "$_marker" ]] && MACHINE="$(basename "$_marker" .init-done)" && break
    done
fi
[[ -n "$MACHINE" ]] || { echo "SKIP: no initialized machine for deploy-to-qemu integration"; exit 77; }
echo "[integration] deploy-to-qemu machine=$MACHINE"

# e2e: ob deploy-to-qemu(真跑 bitbake obmc-phosphor-image + QEMU 重启; 1-4h)
deploy_out="$(mktemp "${TMPDIR:-/tmp}/ob-deploy-integ-XXXXXX")"
deploy_rc=0
./ob deploy-to-qemu "$MACHINE" >"$deploy_out" 2>&1 || deploy_rc=$?
echo "deploy rc=$deploy_rc"
if [[ "$deploy_rc" -ne 0 ]]; then
    sed 's/^/  | /' "$deploy_out"
    rm -f "$deploy_out"
    echo "FAIL: deploy rc=$deploy_rc"
    exit 1
fi
rm -f "$deploy_out"

# 断言: 新 QEMU .pid 写入(execute_launch 启动成功; deploy rc=0 的物证)
pid_file="workspace/qemu-bin/.pids/$MACHINE.pid"
if [[ ! -f "$pid_file" ]]; then
    echo "FAIL: no .pid after deploy (QEMU not started)"
    exit 1
fi
ssh_port="$(grep '^ssh_port=' "$pid_file" | cut -d= -f2)"
echo "new QEMU pid file: $pid_file (ssh_port=$ssh_port)"

# BMC SSH ready 信心检查(失败 warn 不 exit 1; deploy rc=0 即成功, BMC ready 是 boot 过程, 超时 warn 不算 deploy 失败)
if command -v sshpass >/dev/null 2>&1; then
    if sshpass -p 0penBmc ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
         -o UserKnownHostsFile=/dev/null -p "$ssh_port" root@localhost echo "OK" >/dev/null 2>&1; then
        echo "[integration] BMC SSH ready on port $ssh_port"
    else
        echo "WARN: BMC SSH not ready on port $ssh_port (may still be booting; deploy rc=0 already succeeded)"
    fi
else
    echo "WARN: sshpass not installed, skipping BMC SSH readiness check"
fi

echo "[integration] OK (deploy-to-qemu: image rebuilt + QEMU restarted for $MACHINE)"
