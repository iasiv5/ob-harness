# ob init 自动并行度调优 + managed block 迁移 设计文档

## 背景与目标

在 WSL（1 和 2）环境编译 OpenBMC 时，bitbake 默认 `make -j $(nproc)`。12 核 WSL2 实测中，12 个 gcc 并行编译大文件峰值内存 12-36GB，超出 16GB RAM + 8GB swap 总量，触发 Linux OOM killer，杀死 sshd 进程导致 SSH 断开。同样的问题也导致 sqlite3 amalgamation（9.5MB）编译时 gcc 被 OOM kill，留下 0 字节 `.o` 文件，后续链接全部 `undefined reference`。

**目标：** `ob init` 自动检测 WSL 环境，根据可用资源计算安全的并行度，写入构建配置。

**成功标准：**
- WSL 环境下 `ob init` 后直接 `bitbake obmc-phosphor-image` 不再 OOM
- 非原生 Linux（裸金属、CI runner）不受影响——不对这些环境注入并行度限制
- 用户在 `local.conf` 中显式覆盖 `PARALLEL_MAKE` / `BB_NUMBER_THREADS` 时，覆盖始终生效

## 范围

1. `ob` 脚本 `generate_build_config()` 增加 WSL 检测 + 资源公式计算，将 `BB_NUMBER_THREADS` 和 `PARALLEL_MAKE` 写入 `externalsrc-$MACHINE.inc`
2. 将 `local.conf` 中 `# BEGIN/END ob init managed settings` block（含 `CONNECTIVITY_CHECK_URIS`）迁入 `externalsrc-$MACHINE.inc`
3. 删除 `ensure_bootstrap_local_conf()` 中的 managed block 解析逻辑
4. `local.conf` 不再包含任何 `ob init` 管理的变量，只保留 `include externalsrc-$MACHINE.inc` 行

## 非范围

- 裸金属 Linux / CI runner 环境的并行度自动调优（本次不覆盖）
- recipe-specific 并行度覆盖（如 `PARALLEL_MAKE:pn-sqlite3 = "-j 2"`）——这是上游 recipe bug 的 workaround，不属于平台调优
- `.wslconfig` 的自动生成或修改
- bitbake server 资源占用的优化

## 方案比较

### 方案 A：纯资源检测（不区分平台）

读 `MemTotal + SwapTotal` 和 `nproc`，对所有环境统一应用公式。

- 优点：逻辑简单，不分平台
- 缺点：裸金属 16GB Linux 通常不会 OOM（swap 响应快、无宿主内存竞争），强制限并行度不必要且降低编译速度

### 方案 B：WSL 检测 + 资源公式

先检测 WSL（`grep -qi microsoft /proc/version`），仅 WSL 环境应用资源公式。原生 Linux 不注入任何并行度限制。

- 优点：精准打击问题环境，不影响原生 Linux 编译速度
- 缺点：WSL 特判，未来可能需要扩展到其他受限环境（Docker、CI runner）

## 推荐方案

**方案 B：WSL 检测 + 资源公式。**

- WSL 环境的 swap 本质是 Windows 宿主的虚拟内存，响应速度远慢于裸金属，OOM 行为更激进
- 原生 Linux 即使内存相同，swap 响应快，不容易触发 OOM
- 公式可后续扩展（增加新的环境检测分支），不会锁死架构

**主要 trade-off：** 如果用户在 WSL 中分配了大量内存（如 64GB），公式可能仍然保守。但保守比 OOM 好，且用户可以在 `local.conf` 中覆盖。

## 关键边界与组件职责

### `.inc` 文件（ob 全权管理）

`externalsrc-$MACHINE.inc` 成为 `ob init` 管理的**唯一**配置文件。每次 `ob init` 覆盖重写。

包含内容与操作符：

| 变量 | 操作符 | 原因 |
|---|---|---|
| `INHERIT += "externalsrc"` | `+=` | 追加到现有 INHERIT，不能替换 |
| `CONNECTIVITY_CHECK_URIS = ""` | `=` | 必须覆盖 OE-core 的 `?=` 默认值，`??=` 优先级不够 |
| `DL_DIR` | `??=` | 弱默认，用户在 `local.conf` 中用 `=` 即可覆盖 |
| `SSTATE_DIR` | `??=` | 同上 |
| `BB_NUMBER_THREADS`（仅 WSL） | `?=` | OE-core 用 `?=` 设默认值，`??=` 优先级更低会失效；用户用 `=` 可覆盖 |
| `PARALLEL_MAKE`（仅 WSL） | `?=` | 同上 |

### `local.conf`（用户领地）

`ob init` 只做一件事：确保 `include externalsrc-$MACHINE.inc` 行存在。不再写入任何变量值。

用户覆盖 `.inc` 默认值的方式：在 `local.conf` 中用 `=` 赋值即可。`??=` 和 `?=` 都弱于 `=`，用户的 `=` 始终优先。

### `ob` 脚本改动

**`generate_build_config()`**：
- 新增 WSL 检测函数
- 新增资源计算函数
- `.inc` 生成逻辑增加并行度 section 和 `CONNECTIVITY_CHECK_URIS`
- 仅在 WSL 环境注入并行度变量

**`ensure_bootstrap_local_conf()`**：
- 删除 `# BEGIN/END ob init managed settings` block 的写入和解析逻辑
- 删除 `CONNECTIVITY_CHECK_URIS` 写入（已移至 `.inc`）
- 保留 `include` 行添加逻辑
- 保留 `GITLAB_IP` 自动检测逻辑（这属于 local.conf 的用户侧配置，不是 ob 管理设置）

## 数据流 / 控制流

```
ob init Step 7: generate_build_config()

输入:
  /proc/version          → WSL 检测
  /proc/meminfo          → MemTotal, SwapTotal
  nproc                  → CPU 核数
  $local_conf            → 检测已有 DL_DIR/SSTATE_DIR（决定是否写 ??=）

处理:
  1. detect_wsl()        → is_wsl=true/false
  2. if is_wsl:
       calc_parallelism(MemTotal_GB, SwapTotal_GB, nproc)
       → N = max(1, min(nproc, (MemTotal_GB + SwapTotal_GB) / 4))
  3. 检查 local.conf 已有 DL_DIR/SSTATE_DIR → 决定是否写入 ??=

输出:
  externalsrc-$MACHINE.inc（覆盖重写）
  local.conf（仅确保 include 行存在）
```

### 公式细节

```
N = max(1, min(nproc, floor((mem_gb + swap_gb) / 4)))
```

- 每 gcc 进程预算 4GB（实测 sqlite3 amalgamation -O2 单进程峰值约 2-3GB，留余量）
- 与 nproc 取小值：并行度不超过物理核数
- 最小值 1：极端低内存环境也能编译

示例：
- WSL2 16GB RAM + 8GB swap + 12 核 → N = max(1, min(12, 6)) = 6
- WSL2 8GB RAM + 4GB swap + 8 核 → N = max(1, min(8, 3)) = 3
- 原生 Linux → 不注入，保持 bitbake 默认行为

## 错误处理与回退

| 场景 | 处理 |
|---|---|
| `/proc/version` 不可读（非 Linux） | 不触发 WSL 检测（Step 1 已验证 OS 为 Linux，此场景实际不会发生） |
| `/proc/meminfo` 不可读 | warn 并跳过并行度注入，不阻断 init |
| `nproc` 失败 | 回退到 `N=1` |
| 用户手动删除 `.inc` 中并行度行 | 下次 `ob init` 重跑会重新生成 |
| 用户在 `local.conf` 覆盖 | `?=` / `??=` 均弱于 `=`，用户 `=` 始终生效 |
| 已有 `local.conf` 含 managed block（存量用户） | `ob init` 不再写入 managed block，但也不主动删除已有的；存量 block 的 `=` 优先于 `.inc` 的 `??=`/`?=`，行为正确（等于用户显式设置） |

## 测试策略

1. **WSL2 环境**：`ob init` 后检查 `.inc` 包含 `BB_NUMBER_THREADS` 和 `PARALLEL_MAKE`，值符合公式
2. **原生 Linux 环境**：`ob init` 后检查 `.inc` 不包含 `BB_NUMBER_THREADS` 和 `PARALLEL_MAKE`
3. **用户覆盖**：`local.conf` 写 `PARALLEL_MAKE = "-j 8"` 后 `bitbake -e` 确认值为 `-j 8`
4. **存量 local.conf 兼容**：已有 managed block 的 `local.conf`，`ob init` 后不破坏已有内容，`.inc` 正常生成
5. **增量重跑**：`ob init` 两次，`.inc` 内容一致，`local.conf` 的 include 行不重复

## 未决事项

无。所有设计决策已通过 grill-with-docs 收敛。
