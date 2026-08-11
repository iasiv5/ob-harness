# 给 QEMU 模拟的 BMC EEPROM 注入 FRU 数据

## TL;DR · 30 秒决策

给 QEMU 里 BMC 板载 FRU EEPROM（i2c addr 0x50）填模拟数据，让 FruDevice（entity-manager）解析出 `PRODUCT_SERIAL_NUMBER` 等字段（供 set-hostname 等服务用）。两个致命陷阱先钉住：

1. **字段 type/length byte 必须用 `0xC0|len`，不是标准 IPMI 的 `0x80|len`**。entity-manager 的 `decodeFRUData`（`fru_utils.cpp:48-54`）把 `bits[7:6]=10`（`0x80|len`）当 `sixBitASCII` 解成乱码；`=11`（`0xC0|len`）才是 `languageDependent`（= 8-bit ASCII）。用错 → serial 解成 ")YF=..." 乱码。
2. **QEMU 源码重编后必须 cp binary 到 `workspace/qemu-bin/custom/`**。ob start-qemu 用的是这个复制，不是源树 `build/`。只 `ninja` 不 cp → 改动不生效（EEPROM boot 后仍空）。

终点定义：boot 时（无人手动写）EEPROM 自带有效 FRU → FruDevice 暴露 `PRODUCT_SERIAL_NUMBER` → set-hostname.service 首启 active。

## 元数据

- **类型**: BestPractice
- **适用场景**: QEMU bring-up 时 BMC 板载 EEPROM 空，导致依赖 FRU 字段的服务（set-hostname / inventory / psu-manager 等）失败；需要注入模拟 FRU 数据
- **创建日期**: 2026-08-11
- **所有权**: product（OpenBMC 通用：entity-manager 是上游组件、QEMU at24c 是通用模型、ob binary provisioning 是 ob-harness 自身）
- **来源**: QEMU bring-up 中 set-hostname 因板载 EEPROM 空而 FAILED 的修复；type 编码反常历经多轮 6-bit packing 反推失败，最终读 `fru_utils.cpp` 才破

## 目标与边界

**目标**：让 QEMU 模拟的 BMC EEPROM 含有效 IPMI FRU，使 entity-manager FruDevice 解析出 `PRODUCT_SERIAL_NUMBER` 等解码字段。

**边界**：
- 只动 QEMU board 文件（`hw/arm/aspeed_<machine>.c` 的 `i2c_init`）+ ob binary 复制；**不碰 image / recipe / customer layer**。真机零影响。
- FRU blob 是模拟数据，字段值（Manufacturer/Serial 等）任意合法值，不要求与真实硬件一致；serial 选 RFC1123 合法 hostname（字母起止、纯字母数字、≤63），避免 set-hostname 的 validate_hostname 二次失败。
- 不解决 psu-manager 等其他服务的 FRU 之外依赖（FRU 注入是必要不充分条件）。

## 验收标准

一个无上下文 agent 据此可判定注入是否成功：

1. `busctl get-property xyz.openbmc_project.FruDevice /xyz/openbmc_project/FruDevice/BUILTIN_FRU xyz.openbmc_project.FruDevice PRODUCT_SERIAL_NUMBER` 返回 `s "<值>"`（不是 "Unknown interface or property"）。
2. 固化后 **boot 时**（ob start-qemu 后无人手动 dd）`systemctl is-active set-hostname.service` = `active`；`hostname` = 注入的 serial 值。
3. runtime 验证阶段：`dd if=/sys/bus/i2c/devices/<bus>-0050/eeprom bs=1 count=<blob_len> | md5sum` 与写入的 blob 一致（或 hexdump 对照）。
4. FruDevice journal 无 "trying to parse empty FRU"；可接受 "Mandatory fields absent after PRODUCT_FRU_VERSION_ID" warning（部分 entity-manager fork 的 productFruAreas 在 Serial 之后还有 mandatory 字段，不影响 Serial 正确解析）。

## 可用资源

- **QEMU 注入 API**：`at24c_eeprom_init_rom(bus, addr, rom_size, init_rom, init_rom_size)`（`hw/nvram/eeprom_at24c.c:146`，realize 时 `memcpy` init_rom 到 mem）。`at24c_eeprom_init` 是其 `NULL` 包装。board 文件已 include `eeprom_at24c.h`。
- **entity-manager 解码源码**：`tmp/work/<arch>-openbmc-linux/entity-manager/*/git/src/fru_device/fru_utils.cpp` 的 `decodeFRUData`（type 编码 enum 在 `:48-54`，switch 在 `:122-186`）。这是判 type/len 编码的唯一权威。
- **runtime 写入通道**：BMC sysfs `/sys/bus/i2c/devices/<bus>-0050/eeprom`（QEMU at24 `writable=true` 默认，可 dd）。二进制传 BMC 用 scp（BMC 多无 base64）。
- **ob binary 实际路径**：`ob start-qemu` PID file（`workspace/qemu-bin/.pids/<machine>.pid`）的 `binary=` 字段是 ob 实际用的 binary 绝对路径。

## 方法论（enabling，非 SOP）

四阶段，每阶段有独立验收，agent 按实际情况调整顺序与命令：

**A. 构造最小 FRU blob。** 只需 Common Header（8B）+ Product Info Area。字段链顺序：Manufacturer, ProductName, PartNumber, Version, Serial, AssetTag, FRU_FILE_ID。每个字段 = type/length byte（`0xC0|len`，空字段 `0xC0`）+ data；FRU_FILE_ID 位用 `0xC1`（end-of-fields）。Area 末尾 pad 到 8 字节倍数 + zero-sum checksum。用脚本生成并校验 checksum（别手算）。Common Header 的 Product Area Offset 字段 = PIA 起始的 8 字节块偏移（通常 1）。

**B. runtime 验证（不动 QEMU/image）。** 先用 dd 把 blob 写进 sysfs eeprom → `systemctl restart xyz.openbmc_project.FruDevice.service` → 等重扫（~5s）→ busctl 查 property。这把"blob 格式对不对"和"QEMU 编译"解耦，避免重编循环。通过才进 C。

**C. 固化进 QEMU board。** 把验证过的 blob 作为 `static const uint8_t[]` 写进 board 文件（带注释说明 `0xC0|len` 缘由），把该 EEPROM 的 `at24c_eeprom_init` 换成 `at24c_eeprom_init_rom(..., blob, sizeof(blob))`。

**D. 重编 + 让 ob 用新 binary + 回归。** `ninja -C <qemu>/build qemu-system-aarch64` → **cp binary 到 ob custom 目录** → `ob stop-qemu + start-qemu` → boot 后查 EEPROM + set-hostname（应首启成功，无人手动 dd）。

## 已知陷阱（均真实踩过）

| 陷阱 | 表现 | 应对 |
|---|---|---|
| **type/length 用 `0x80\|len`**（标准 IPMI 8-bit ASCII） | entity-manager 当 sixBitASCII 解，serial 解成 ")YF=..." 乱码；反推 6-bit packing 多轮失败 | 一律用 `0xC0\|len`。佐证：`setField()` 写字段也用 `0xC0\|size`。源码 `fru_utils.cpp:48-54` |
| **只重编源树不 cp binary** | ob 用 `workspace/qemu-bin/custom/` 旧复制，boot 后 EEPROM 仍全零、FruDevice "trying to parse empty FRU" | `cp -f <qemu>/build/qemu-system-aarch64 workspace/qemu-bin/custom/`。适用**任何** QEMU 源码改动（不止 FRU） |
| **UpdateFruField 凭空注入单字段** | 返回 `b false`（EEPROM 无 FRU 骨架，FruDevice 拒绝更新） | runtime 验证必须写**完整 FRU blob**（i2c/dd），不能靠 D-Bus 单字段注入 |
| **空字段用 `0x00`** | 部分 entity-manager fork 把 0x00 当异常，字段链定位错乱，报 "Mandatory fields absent" | 空字段用 `0xC0`（type=11 len0，与 `createDummyArea` 一致）；只有 end-of-fields 用 `0xC1` |
| **凭标准 IPMI 规范构造** | 标准 type 编码（00=binary 01=6bit 10=8bit 11=unicode）与 entity-manager 实现反 | 信源码不信规范；不同 OpenBMC fork 的 FRU 解码器可能有各自偏离，构造前读目标 BMC 实际用的解码器源码 |
| **scp 传二进制被 base64 假设卡住** | BMC 多为 BusyBox，无 base64/xxd | 用 sshpass+scp 传二进制文件（无损），md5 两端对照 |

## 输出规格

- QEMU board 文件：`static const uint8_t <machine>_fru[]`（带 `0xC0|len` 缘由注释）+ `at24c_eeprom_init_rom` 调用替换。
- 不产生 image / recipe 改动。binary 更新落在 `workspace/qemu-bin/custom/`（gitignore，非仓库）。

## 与现有体系的关系

- **[bestpractice_06-ob_first](bestpractice_06-ob_first.md)**：BMC 生命周期走 ob。本条的 binary cp 是 ob provisioning 的内部行为（ob 不提供"重编后刷新 binary"命令，手动 cp）。
- **[bestpractice_03-ai_debugging_diagnosis](bestpractice_03-ai_debugging_diagnosis.md)**：type 编码乱码一例——表层乱码解释不了时，顺控制路径读到解码器源码（`decodeFRUData`）才定位根因。
