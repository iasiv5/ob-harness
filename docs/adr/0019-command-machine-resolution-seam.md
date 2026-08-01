# `command machine resolution` seam：把 cmd_* 的 machine 解析编排收口成 leaf-pure module（own exit/remedy + return 契约）

`cmd_build` / `cmd_dev` / `cmd_deploy_to_qemu`（+ out-of-scope 的 `cmd_start_qemu`）各自内联一份「given 快路径 verify / empty 路径 guard+pick（dev/deploy 另带 post-pick verify）+ exit-3 remedy + rc 映射」machine 解析 ritual（三命令并非完全同形：build 的 empty 路径无 post-pick verify，dev/deploy 有；代码自标「同 cmd_build/cmd_dev」4 处；verify-init 前置逐字重复 4 处；exit_on_user_cancel 半迁移——dev 已迁、build/start/deploy 未迁）。经 `/pick-one-arch-task` + `/grill-with-docs` 七项决策锁定：抽 leaf-pure module `lib/machine_resolve.sh`（入口 `resolve_command_machine`），按 **路 A**——seam own remedy、return `exit-code 契约` 0/1/2/3、`cmd_*` 字面 case 收口 exit——收口此 ritual。本 ADR 记录这条 load-bearing 决策及其 scope 边界。术语见 CONTEXT.md `command machine resolution`。

Status: accepted

Amends: CONTEXT.md `machine selection guard` 术语的 _Avoid_（消歧「machine resolution」曾误指 guard vs 现指本 seam）。新增 CONTEXT.md `command machine resolution` 术语。
References: [ADR-0010](0010-ob-dev-dispatch-leaf-pure-exit.md) / [ADR-0012](0012-ob-dev-subcmd-handler-leaf-pure-exit.md)（leaf-pure return 契约 + L1 字面 case 收口 pattern 先例）、[ADR-0016](0016-defer-init-intake-guard-reuse.md)（`cmd_init` 永久 out + guard 消费方）。

## Considered Options

1. **路 A（接受）——seam own exit/remedy，leaf-pure + return 契约**。seam 消费 guard+selection+verify，return 0/1/2/3，`cmd_*` 字面 case 收口；`exit_on_user_cancel` 退役。deletion test 真过（4 份 case+remedy+rc 集中）；对齐仓库正在迁往的 intake 派（`dev_intake_*` / `init_intake`）。代价：逆转 `machine selection guard` 术语曾明写的「exit/remedy归调用方」边界——但 intake 系列已先行把 remedy 搬进 module，本 ADR 把 machine 解析层正式迁到 intake 派，guard 本体（检测原语）不变。
2. **路 B（拒绝）——seam 只编排调用，exit/remedy 留 caller**。不碰 guard 术语边界，但 seam 偏薄——caller 省下的只有 guard/pick 调用几行，case/remedy/exit 仍各写一遍，退化成「为测试而抽、bug 藏在别处」（与 gather-seam 否决理由同构）。
3. **路 A + start_qemu 现在就接 seam（拒绝）**。技术可行（`machine_state_is_firmware_image_ready` 先调 `is_initialized`，故 firmware-image-ready ⊊ initialized，seam 的 verify-init 对 start_qemu 的 pick 必通过；empty 子分类用可选 `empty_remedy_fn` hook、image-file 前置留 caller）。但 hook 参数只服务 1 个 consumer，违「一个 adapter 是假 seam，两个才是真」；且 PR 变大、行为面变宽、3 命令 seam 形状未跑稳即叠加 image-ready 复杂度。留 future-candidate。

## Consequences

- **scope（v1）**：消费方 = `cmd_build` / `cmd_dev` / `cmd_deploy_to_qemu`（initialized 命令族，协议同形：list_fn=`initialized_machines`、verify=`is_initialized`）。`cmd_start_qemu` 的 **resolution 不接 seam**——其 image-ready 协议（list_fn=`firmware_image_ready_machines` + empty 子分类 + image-file 前置）维持 inline；仅它的 2 行 rc 映射随 `exit_on_user_cancel` 退役迁 case+warn（碰 rc 风格、不碰 resolution 协议，故不违本 ADR 的 start_qemu 排除）。`cmd_init` 永久 out（[ADR-0016](0016-defer-init-intake-guard-reuse.md)）。
- **guard 术语边界迁移**：`machine selection guard` 术语曾明写「exit/remedy/展示归调用方」——那是 guard 单独存在时立的规矩；intake 系列已先行把 remedy 搬进 module，本 ADR 把 machine 解析层正式迁到 intake 派。guard 本体（检测原语，恒返回 0、outvar status 回传 empty/nontty/ok）**不变**。
- **`exit_on_user_cancel` 退役**：4 命令（含 start_qemu）的 rc 映射全迁字面 case + cancel warn（warn 不丢、搬进 seam/caller，对齐 intake 派；护 `tests/unit/interact.sh:21` 的 `"Build cancelled by user."` 断言）。函数从 `lib/commands.sh` 删除。
- **exit_contract**：登记 `'machine_resolve.sh': set()`（Y 白名单 leaf-pure——函数不直接 exit、return 契约值）。
- **verify-init 统一**：seam 拥有；canonical remedy（保留 build 的括号诊断「(no completed init-done marker - a previous init may have been interrupted)」）；删 dev/deploy 的 2 处冗余 post-pick verify（empty 路径 pick 自 `initialized_machines` 已保证 initialized，无 TOCTOU——单次命令内 init-done 不消失）。3 个 verify remedy 漂移变体（"is not (parenthetical)" / "$dev_machine is not" / "has not been"）→ canonical。钉精确串的 protocol test 需 re-baseline。
- **return 机制**：沿用 `$MACHINE` 全局（pick_machine 本就 set 它；不造 nameref outvar 假对称，同 `ob init command intake` 决策）。后置条件：`resolve_command_machine` return 0 ⟹ `$MACHINE` 已 initialized。
- **seam/caller 边界**：seam 拥 fastpath fork + empty/nontty/verify remedy + pick + rc→contract；caller 拥 confirm + repo 显示 + DRY_RUN + 展示块。pick 输出流（stdout/stderr——dev 须 stderr 护 `ob dev porcelain stdout` 契约）与 nontty remedy 文案（CLI 形态各异）作参数传入。
- **surface 回归锁**：新增 protocol gate 锁 production Bash 不再内联 guard-case+pick+verify ritual（bestpractice_10 形态 A 的 interface-shrink 断言），防旧路径回潮。
- **可逆性**：seam 抽取有测试网（既有 golden + 新 unit/protocol）兜底；术语边界迁移由本 ADR + CONTEXT 改动记录，回退即重开本 ADR。
- **future-candidate 重开触发（start_qemu 接 seam）**：出现第二个 image-ready 命令（真·两 adapter），或 start_qemu 的 resolution 进入高频改动区——届时加 `empty_remedy_fn` hook 重开评估。重开前须先消解：image-ready empty 子分类用 hook 不污染 leaf-pure seam、image-file 前置落点。
