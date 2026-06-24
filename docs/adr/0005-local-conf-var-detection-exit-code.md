# local.conf 变量判定用 exit code，不用 `-n`；DL_DIR/SSTATE_DIR/PREMIRRORS 统一

## 背景

`ob init` 向 `externalsrc-<machine>.inc` 注入 DL_DIR/SSTATE_DIR（现新增 PREMIRRORS），但仅当用户未在 local.conf 设定时。判定必须正确区分"用户配置了"与"用户想要默认"。

## 决策

用 `read_local_conf_var` 的 **exit code**（0 = 存在赋值行，即使值为空；1 = 无赋值行）作为信号，**不**用 `-n`（值非空）。对 DL_DIR、SSTATE_DIR、PREMIRRORS 统一适用。

## 为什么（非显而易见部分）

- `DL_DIR = ""` **不是**"用 bitbake 默认"——`=` 会覆盖 `bitbake.conf` 的 `?=` 默认（`${TOPDIR}/downloads`），得到空字符串、破坏 fetch。"想要默认"的正确做法是注释掉该行（无赋值行），而社区 local.conf 模板正是如此（已验证：所有 `meta-*/conf/templates/default/local.conf.sample` 均无 `DL_DIR =` 赋值行）。故空值是**用户的有意选择**（如禁用 PREMIRRORS），而非"缺失"。
- `-n` 把空当"未设"并悄悄补默认——这**覆盖了用户的有意选择**，且可观测性低。exit code 判定尊重任何显式赋值（含空）。
- 三变量统一到 exit code，消除"PREMIRRORS 需要 exit code（空=禁用）但 DL_DIR/SSTATE_DIR 用 `-n`"的不一致。

## 后果

- DL_DIR/SSTATE_DIR 行为变更：`VAR = ""` 现被尊重（用户接管）而非自动补默认。实际影响可忽略——社区模板从不赋空值，无人依赖旧的"补空值"行为。
- "禁用 ob 的 PREMIRRORS" = 在 local.conf 写 `PREMIRRORS = ""`（直觉）。
- `read_local_conf_var` 已返回正确的 exit code（定义在 `lib/util.sh`）；调用点据此判定，三变量共用。

Status: accepted
