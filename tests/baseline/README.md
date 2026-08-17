# baseline 目录（per-machine，ADR-0025）

`ob test-qemu <machine>` 的被测数据：该 machine 的**开发基线**（baseline）里
QEMU 可仿真子集的 AR（需求条目）。每个 machine 目录**自包含** AR 数据 +
probe 引擎 + 本地 applicability，不与他机共享——组织权限边界优先于 DRY，
详见 [ADR-0025](../../docs/adr/0025-test-qemu-baseline-fullstack-per-machine.md)。

- `tests/baseline/<machine>/` — 社区机，随 ob-harness 上游分发
- `contexts/baseline/<machine>/` — custom 机本地目录（gitignored，不随上游；
  **定位优先于 tests/**，可覆盖/校准社区基线）

## AR 编号语义（为什么序号不连续）

AR ID（如 `BMC-3-15-2`）= `<域>-<章节>-<条目>-<变体>`，**沿引你们 baseline
需求文档（Excel/规格书）的原条目编号**，是需求追踪锚点。本目录只放
"QEMU 可验 + 对该机 applicable"的子集——子集化天然跳号，**不连续是正确形态**。
接入时保持你方 baseline 原编号，不要为连续性重编（会断 `AR ID ↔ 需求条目`
的追踪链）。

## 五态与 exit

逐条 AR 判定 `pass / fail / skip / xfail / xpass`（另：probe 拿不到干净
BMC 应答的传输/超时/schema 错误记 `error`）：

| 状态 | 含义 | 调 probe？ | 影响 exit？ |
|---|---|---|---|
| pass | applicable，实测符合 assert | ✓ | — |
| fail | applicable，实测不符 = **α truth**（BMC 不满足 baseline） | ✓ | exit 1 |
| skip | 不适用 / QEMU 不可仿真 | ✗ | — |
| xfail | 预期失败（跟踪中） | ✓ | — |
| xpass | xfail AR 意外通过（改善信号） | ✓ | — |
| error | infra 错误（非 baseline 缺陷） | — | exit 3 |

exit：`0` 全 applicable pass；`1` ≥1 applicable fail（**不是 test-qemu broken**，
读 fail 行 debug BMC 接口）；`3` 前置缺失或 VERDICT: ERROR（重跑/查连通性）。

## 接入第二台 machine

```bash
cp -r tests/baseline/romulus tests/baseline/<new-machine>   # 社区机
# custom 机放 contexts/baseline/<new-machine>/（不随上游分发）
```

然后：① 替换 `ar_probes.yaml` 为你方 baseline 的 QEMU 可仿真子集（编号沿引
原需求文档）；② 校准 `applicability.yaml`（见下节）；③ 按需扩展
`runner/` 的 probe 类型（当前仅 redfish；ipmi/ssh/console 的 auth 位已预留）。
runner 探测是确定性脚本 + assert 原语（状态断言非计时断言，零 flake），
LLM 不参与 runtime 判定。

## applicability 维护规则（xfail 不是永久停车场；降级锚点不是永久降级）

- 新 AR 默认 `applicable`；仅在**该机已验证**不适用（skip）或当前不符
  （xfail）时加 override，`reason` 写实测证据，`source: manual`。
- **xfail 是对"当前验证过的 image"的假设**：image 升级后假设可能失效。
- **稳定 xpass 后必须移除 override、恢复 applicable**——否则后续回归会被
  xfail 静默吞掉（又变 fail 时记 xfail、不 exit 1，回归不可见）。
- **降级锚点随 image 升级重评**：因接口缺口把 AR 锚点从正位降到弱断言
  （换端点/换字段，如 Managers/bmc.FirmwareVersion → FirmwareInventory
  非空）是过渡形态，不是终态——降级理由写进 `rationale` + 本文件校准
  记录；缺口接口恢复（连续多次实测稳定）后**升回正位锚点**，弱断言
  退役。长期停在降级锚点 = 用弱断言掩盖已恢复的能力，与 xfail 停车场
  同构（BMC-3-15-1 是先例：2026-08-17 重评升回）。
- runner 的 schema 校验兜底：未知 assert type / 未知 depends_on / 重复 AR ID
  / orphan override / 非白名单 HTTP method 均 exit 3（数据错 ≠ BMC fail）。
- skip 的 AR 可省略 `request:`（无可执行探测定义就不该编造占位请求）；
  带 `request:` 的仍须过 method 白名单校验。

## 谱系（provenance）与 custom 覆盖

被测对象的谱系 = OpenBMC 主仓 source（`ob init` 的 source label）+ QEMU
binary（community / custom）。**custom 谱系 + 社区 baseline 是错配**：测出的
fail 无法归因（上游也这样？还是你 fork/build 特有？）。`ob test-qemu` 在此
错配时打 WARN 提示（不可消音）——要安静的唯一出路是数据接管：把校准过的
baseline 放进 `contexts/baseline/<machine>/`（定位优先命中，谱系闭合）。
社区目录里的 xfail/xpass 结论只对**真正 community source+binary 构建的
image** 有效，fork 环境的观测请落在自己的 contexts 目录。
