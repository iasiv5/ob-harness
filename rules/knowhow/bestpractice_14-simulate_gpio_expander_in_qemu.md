# 给 QEMU 模拟缺失的 GPIO expander（让服务找 named GPIO 不 abort）

## TL;DR · 30 秒决策

OpenBMC 服务（psu-manager 等）启动时用 `gpiod::find_line("XXX")` 找 named GPIO line，找不到就 throw/abort。QEMU bring-up 时某 GPIO expander（pca9555/pca9554/pcf8574）没模拟 → kernel 没注册该 gpiochip → named line 不存在 → 服务 SIGABRT（崩溃极早，journal 往往空）。两个要点先钉住：

1. **定位 abort 用"手动跑 binary 捕获 stderr"**，比 gdb stripped/栈-corrupt core 高效：stderr 直接给 `Line does not exist: PSU0_PRESENT_N`（exception what）。gdb 只给 SIGABRT 地址（无符号、栈 corrupt）。
2. **QEMU 有 GPIO expander 模型**（hw/gpio/pca9555.c 等），一行创建 `i2c_slave_create_simple(bus, TYPE_PCA9555, 0x20)`。但要挂在 dts 匹配的总线（mux+ch+addr），kernel 才从 dts 的 gpio-line-names 注册 named line。

终点定义：`gpioinfo` 显示 named line；服务 `systemctl is-active` = active（不 SIGABRT）。

## 元数据

- **类型**: BestPractice
- **适用场景**: QEMU bring-up 中 OpenBMC 服务因 GPIO line 不存在而 SIGABRT（崩溃极早、journal 空）
- **创建日期**: 2026-08-11
- **所有权**: product（OpenBMC 通用：gpiod 找 named GPIO 是通用模式、QEMU expander 模型通用、dts line names 通用）
- **来源**: 某 QEMU bring-up 中 psu-manager（PSU Cold Redundancy）SIGABRT 修复——QEMU 缺 pca9555@20 PDB expander，PSU0-3 PRESENT_N line 不存在

## 目标与边界

**目标**：让 QEMU 模拟缺失的 GPIO expander，kernel 注册 named GPIO line，依赖该 line 的服务不 abort。

**边界**：
- 只动 QEMU board 文件（i2c_init 加 expander + mux 链）+ ob binary 复制；**不碰 image/recipe/dts**（line names 已在 dts，kernel 自动读）。真机零影响。
- 不解决服务自身的其他依赖（如 PSU i2c 设备）——但那些通常 graceful（log + return，不 abort）。本条只解决"GPIO line 不存在导致的 abort"。

## 验收标准

1. `gpioinfo | grep <line名>` 显示该 named line（修复前不存在）；`ls /dev/gpiochip*` 数量增加（新 expander 注册）。
2. 服务 `systemctl is-active <service>` = active（修复前 failed/restart 循环），journal 有 "Started ..."。
3. 手动跑 binary（`timeout 8 /usr/bin/<binary> 2>&1`）不再输出 "terminate called after throwing..."。

## 可用资源

- **QEMU GPIO expander 模型**：hw/gpio/ 有 pca9555/pca9554/pca9552/pcf8574。创建：`i2c_slave_create_simple(bus, TYPE_PCA9555, addr)`（多个 aspeed board 已用此模式，可 grep `TYPE_PCA9555` 找参考）。
- **dts 总线链 + line names**：expander 节点（如 pca9555@20）的 parent i2c bus + mux + ch，节点内 `gpio-line-names`。QEMU expander 要挂在同一总线链（kernel i2c client 匹配 dts 节点读 line names）。
- **mux 创建**：pca954x（TYPE_PCA9546 4-ch / TYPE_PCA9548 8-ch），`pca954x_i2c_get_bus(mux, ch)` 取子总线。
- **abort 定位**：手动跑 binary 捕获 stderr（不依赖 journal）。

## 方法论（enabling，非 SOP）

1. **定位 abort**：`systemctl stop <svc>; timeout 8 /usr/bin/<binary> 2>&1`，看 stderr 的 `Line does not exist: XXX` 或 `terminate called after throwing...`，拿 line 名。
2. **查 line 注册**：`gpioinfo | grep XXX` 确认 line 不存在；`ls /dev/gpiochip*` 看 gpiochip 数。
3. **追溯 dts**：grep devicetree 的 `gpio-line-names` 找 XXX 的 expander 节点（如 `pca9555@20`）+ 其总线链（`i2cN → mux(addr) → ch → expander(addr)`）。
4. **QEMU 加 expander**：board 文件 `i2c_init` 加该总线链 + expander（`i2c_slave_create_simple`），带注释说明对应 dts 节点 + line 用途。重编 + cp binary + 重启。
5. **验证**：gpioinfo 看 named line 注册 + 服务 active。

## 已知陷阱（均真实踩过）

| 陷阱 | 表现 | 应对 |
|---|---|---|
| **用 gdb 调 stripped core** | SIGABRT 地址无符号 + 栈 corrupt，定位不到 abort 点（浪费多轮） | 手动跑 binary 捕获 stderr，直接拿 "Line does not exist: XXX"（exception what） |
| **改 config 名字匹配 main GPIO** | main aspeed GPIO 可能只有部分 line（如只 PSU0/1，没 PSU2/3），改名不够 | 追溯 dts 该 line 的 expander，QEMU 模拟 expander（kernel 注册 expander 全部 named line） |
| **QEMU expander 挂错总线** | expander 不在 dts 节点对应总线 → kernel i2c client 不匹配 → line names 不注册 | 严格按 dts 总线链（i2cN→mux addr→ch→expander addr）挂 |
| **clone 错源码 repo** | OpenBMC fork 同一组件在不同 layer/recipe 可能指向不同 gitea repo（甚至不同分支 + SRCREV），clone 错版本源码对不上 binary | 看 machine 实际用的 layer（meta-\<vendor\>）的 .bb/.inc 确认 SRC_URI + SRCREV，clone 对应 repo + checkout SRCREV |
| **binary strings 误导** | binary 含 "bad optional access" 等字符串，但实际 abort 是 runtime_error（未执行路径的模板实例化） | 以手动跑 binary 的 stderr 为准（运行时实际异常），不靠 strings 猜 |
| **journal 完全空误判** | 服务崩溃极早（构造时），stderr/journal 还没写 | 手动跑 binary 捕获 stderr（绕过 journal） |

## 输出规格

- QEMU board 文件 i2c_init：加 expander 总线链（mux + ch + expander），带注释说明对应 dts 节点 + line 用途。
- 不产生 image/dts 改动（line names 已在 dts）。binary 更新落 `workspace/qemu-bin/custom/`（gitignore，非仓库）。

## 与现有体系的关系

- **[bestpractice_13](bestpractice_13-inject_fru_data_into_bmc_eeprom.md)（FRU 注入）**：姊妹篇，都是"QEMU 模拟缺失硬件让 OpenBMC 服务跑"。FRU 注入补 EEPROM 数据，GPIO expander 补 GPIO line。
- **[bestpractice_03](bestpractice_03-ai_debugging_diagnosis.md)**：abort 定位一例——手动跑 binary 捕获 stderr 比 gdb stripped core 高效。
- **[bestpractice_06](bestpractice_06-ob_first.md)**：binary cp 到 ob custom（重编后生效，见 [[ob-qemu-custom-binary-stale]] memory）。
