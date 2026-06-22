# GNU 源加速用 PREMIRRORS，不用 GNU_MIRROR 变量覆盖

## 背景

GNU 源 tarball（gcc/glibc/gmp/mpfr 等）从 `ftpmirror.gnu.org` 拉取在本网络极慢（实测 ~3.6KB/s），单 gcc 就能让 build 卡 6+ 小时。需要 `ob init` 把快速 mirror（清华 tuna，实测 ~2.6MB/s）注入生成的 `externalsrc-<machine>.inc`。

## 决策

用 `PREMIRRORS`（重写 `https://ftpmirror.gnu.org/gnu/` → tuna），**不**覆盖 `GNU_MIRROR` 变量。

## 为什么（非显而易见部分）

`bitbake.conf:711` 定义 `GNU_MIRROR = "https://ftpmirror.gnu.org/gnu"`——所以覆盖 `GNU_MIRROR` 本是更简洁的一行方案，且能覆盖所有用 `${GNU_MIRROR}` 的 recipe。仍选 PREMIRRORS，因为：

1. **空值禁用语义安全**：`PREMIRRORS = ""` 干净地禁用注入；`GNU_MIRROR = ""` 会破坏 recipe（`${GNU_MIRROR}/gcc/...` 坍缩成相对路径）。这与"空 = 用户禁用"的判定契约（见 [ADR-0005](0005-local-conf-var-detection-exit-code.md)）契合。
2. **来源透明**：PREMIRRORS 在 fetcher 层重写，`SRC_URI`（及 SPDX/license 记录）保留真实上游 URL；`GNU_MIRROR` 覆盖会让记录的来源变成 mirror。

PREMIRRORS 也已实证有效（gcc 从 tuna 拉取成功，build 通过）。

## 后果

- 覆盖任何硬编码 `ftpmirror.gnu.org` 的 recipe（不止用 `${GNU_MIRROR}` 的）。
- 只需一条 PREMIRRORS（ftpmirror），因为 `GNU_MIRROR` 就是 ftpmirror——`ftp.gnu.org` / `ftp://` 变体冗余（oe-core 不产生这些 URL）。
- tuna 失效时 fetcher 回退上游 ftpmirror（慢但不炸）。

Status: accepted
