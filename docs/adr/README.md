# ADR 索引

Architecture Decision Records —— load-bearing 决策的记录。新 ADR 用下一个可用编号（`00NN-<slug>.md`）。

## 活文档原则

ADR 是活文档：内容过期时就地修订对齐现状，不做 superseded-by 链；新增仍须过 surprising 三重门槛（多方案真实取舍 / 决策载荷可追溯 / 未来 explorer 会问为什么）。

## 目录

| # | 标题 |
|---|---|
| [0001](0001-init-done-marker.md) | init done marker |
| [0002](0002-qb-variables-via-bitbake-e.md) | QB variables via bitbake -e |
| [0003](0003-ob-first-front-door.md) | ob 优先统一前门 |
| [0004](0004-gnu-mirror-via-premirrors.md) | GNU mirror via premirrors |
| [0005](0005-local-conf-var-detection-exit-code.md) | local.conf 变量探测退出码 |
| [0006](0006-machine-state-firmware-image-readiness.md) | machine state firmware image readiness |
| [0007](0007-qemu-launch-profile-start-qemu-decision-seam.md) | QEMU launch profile 决策 seam |
| [0008](0008-ob-dev-cleanup-fail-safe.md) | ob dev cleanup fail-safe |
| [0009](0009-ob-dev-workspace-single-writer.md) | ob dev workspace single-writer |
| [0010](0010-ob-dev-dispatch-leaf-pure-exit.md) | ob dev dispatch leaf-pure exit |
| [0011](0011-ob-deploy-to-qemu-toplevel-ownership.md) | ob deploy-to-qemu 顶层归属 |
| [0012](0012-ob-dev-subcmd-handler-leaf-pure-exit.md) | ob dev subcmd handler leaf-pure |
| [0013](0013-skills-to-knowhow-rename.md) | skills → knowhow 改名 |
| [0014](0014-defer-generate-build-config-deepening.md) | generate build config 深化暂缓 |
| [0015](0015-knowhow-tldr-mandatory-structure-alignment.md) | knowhow TL;DR 强制结构对齐 |
| [0016](0016-defer-init-intake-guard-reuse.md) | init intake guard 复用暂缓 |
| [0017](0017-knowhow-distribution-boundary.md) | knowhow 分发边界（contexts/） |
| [0018](0018-knowhow-numbering-stability.md) | knowhow 编号稳定性 |
| [0019](0019-command-machine-resolution-seam.md) | command machine resolution seam |
| [0020](0020-ob-smoke-probe-only-smoke-prober.md) | smoke 可达性门 probe-only 形态（现收编为 suite） |
| [0021](0021-qemu-restart-port-reuse.md) | QEMU restart 端口复用 |
| [0022](0022-port-reuse-resolver-module.md) | 端口复用 resolver 模块 |
| [0023](0023-defer-smoke-assertion-runner.md) | smoke 断言 runner 抽取暂缓（已由 0028 兑现） |
| [0024](0024-qemu-instance-liveness-outvar.md) | qemu_instance_liveness outvar 化 |
| [0025](0025-test-qemu-baseline-fullstack-per-machine.md) | test-qemu baseline 全栈 per-machine |
| [0026](0026-test-qemu-baseline-lineage-routing.md) | test-qemu baseline 谱系路由 |
| [0027](0027-baseline-runner-single-copy-in-main-repo.md) | baseline runner 主仓单副本 |
| [0028](0028-smoke-merged-into-test-qemu-suite.md) | smoke 收编为 test-qemu --suite smoke |
