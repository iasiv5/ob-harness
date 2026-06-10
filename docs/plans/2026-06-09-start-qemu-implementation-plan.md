# ob start-qemu / ob stop-qemu 实施计划

## 目标

在 `ob` 脚本中新增 `start-qemu` 和 `stop-qemu` 两个子命令，实现 OpenBMC 构建产物通过 QEMU 仿真真实 BMC 硬件自动启动和安全管理。设计决策已锁定，记录在对话上下文的 14 条决策清单、`CONTEXT.md` 术语表和 `docs/adr/0002-qb-variables-via-bitbake-e.md` 中。

## 架构快照

新增两个子命令 `cmd_start_qemu` 和 `cmd_stop_qemu`，遵循现有 `cmd_init` / `cmd_build` / `cmd_status` 的函数组织模式。核心设计：

- **QEMU 参数来源**：`QB_MACHINE` 和 `QB_MEM` 通过 `source setup <machine> <build_dir>` + `bitbake -e` 从 BitBake 展开变量中读取，ob-harness 不提供 fallback
- **QEMU binary 管理**：按 `source_label`（`community` / `custom`）隔离存放于 `workspace/qemu-bin/<source>/`，首次使用时按需下载
- **进程管理**：PID 文件 (`workspace/qemu-bin/.pids/<machine>.pid`) 记录实例信息，kill 前校验 `/proc/<pid>/cmdline` 防误杀
- **启动方式**：`setsid` + `-daemonize` + `-serial file:<path>` + `-monitor none`（避免 `-nographic` 的 tty 挂起问题）
- **等待机制**：默认轮询等待 SSH 可达后输出连接摘要，`--no-wait` 跳过

## 输入工件

- 14 条锁定决策（对话上下文）
- `CONTEXT.md` 术语表（已更新）
- `docs/adr/0002-qb-variables-via-bitbake-e.md`（已创建）

## 文件结构与职责

- Modify: `ob` — 新增 `cmd_start_qemu`、`cmd_stop_qemu`、辅助函数，修改 `usage()`、`parse_args()`、`cmd_menu()`、`cmd_status()`、`main()`
- Modify: `CONTEXT.md` — 已完成
- Modify: `docs/adr/0002-qb-variables-via-bitbake-e.md` — 已完成
- Create（运行时）: `workspace/qemu-bin/community/.manifest`
- Create（运行时）: `workspace/qemu-bin/custom/.manifest`
- Create（运行时）: `workspace/qemu-bin/.pids/<machine>.pid`

## 任务清单

### Task 1: 在 `parse_args()` 中注册 `start-qemu` 和 `stop-qemu` 子命令

- 目标：让 `ob start-qemu` 和 `ob stop-qemu` 能被参数解析器识别
- 涉及文件：`ob` (`parse_args()` 函数，约 L283-L339)
- 验证范围：`ob start-qemu --help` 和 `ob stop-qemu --help` 能打印 usage 不报错

- [ ] Step 1: 确认当前 `parse_args()` 只接受 `init`/`build`/`status`
- Run: `grep -A5 'case.*COMMAND' /bmc/iasi/ob-harness/ob | head -15`
- Expected: 只看到 `init)`、`status)`、`build)` 三个分支
- [ ] Step 2: 在 `case "$COMMAND"` 中增加 `start-qemu)` 和 `stop-qemu)` 两个分支
  - `start-qemu)`：接受可选的 `<machine>` 位置参数 + `--ssh-port`、`--redfish-port`、`--ipmi-port`、`--http-port`、`--serial-log`、`--no-wait`、`--force` 选项，解析到新的全局变量 `QEMU_SSH_PORT`、`QEMU_REDFISH_PORT`、`QEMU_IPMI_PORT`、`QEMU_HTTP_PORT`、`QEMU_SERIAL_LOG`、`QEMU_NO_WAIT`、`QEMU_FORCE`
  - `stop-qemu)`：接受可选的 `<machine>` 位置参数 + `--force`、`--all` 选项，解析到 `QEMU_FORCE`、`QEMU_STOP_ALL`
  - Change: 在 `parse_args()` 的 `case "$COMMAND"` 块中增加两个分支，在 `while [[ $# -gt 0 ]]` 循环中增加对应的选项解析
- [ ] Step 3: 确认 `ob start-qemu --help` 不报 "Unknown command"
- Run: `./ob start-qemu --help 2>&1; echo "exit=$?"`
- Expected: 输出 usage 信息，exit code 0
- [ ] Step 4: 确认 `ob stop-qemu --help` 不报 "Unknown command"
- Run: `./ob stop-qemu --help 2>&1; echo "exit=$?"`
- Expected: 输出 usage 信息，exit code 0

### Task 2: 在 `usage()` 中补充 `start-qemu` 和 `stop-qemu` 的帮助文本

- 目标：用户执行 `ob --help` 或 `ob start-qemu --help` 时看到完整的命令说明
- 涉及文件：`ob` (`usage()` 函数，约 L258-L281)
- 验证范围：帮助文本包含两个新命令的用法和参数说明

- [ ] Step 1: 确认当前 `usage()` 输出不包含 `start-qemu`
- Run: `./ob --help 2>&1 | grep -c 'start-qemu'`
- Expected: 输出 `0`
- [ ] Step 2: 在 `usage()` 的 Commands 区域增加 `start-qemu` 和 `stop-qemu` 条目，新增 Options 区域描述端口、日志、等待等参数
  - Change: 在 `Commands:` 块追加两行，在 `Options:` 块追加参数说明
- [ ] Step 3: 确认帮助文本包含新命令
- Run: `./ob --help 2>&1 | grep -c 'start-qemu\|stop-qemu'`
- Expected: 输出 `2`（两个命令各出现一次）

### Task 3: 在全局变量区新增 QEMU 相关变量

- 目标：为后续所有 Task 提供全局变量声明，避免未绑定变量错误（`set -u`）
- 涉及文件：`ob` (`# === Global Variables ===` 区，约 L6-L26)
- 验证范围：`ob` 顶层执行不因未绑定变量报错

- [ ] Step 1: 确认当前全局变量区没有 QEMU 相关变量
- Run: `head -30 /bmc/iasi/ob-harness/ob | grep -c 'QEMU'`
- Expected: 输出 `0`
- [ ] Step 2: 在全局变量区末尾（`MIRROR_BASE=""` 之后）追加 QEMU 相关变量声明

  ```bash
  # QEMU-related (start-qemu / stop-qemu)
  QEMU_SSH_PORT=""
  QEMU_REDFISH_PORT=""
  QEMU_IPMI_PORT=""
  QEMU_HTTP_PORT=""
  QEMU_SERIAL_LOG=""
  QEMU_NO_WAIT=0
  QEMU_FORCE=0
  QEMU_STOP_ALL=0
  QEMU_BIN_DIR=""       # derived: workspace/qemu-bin/<source>
  QEMU_BIN_FILE=""      # derived: workspace/qemu-bin/<source>/qemu-system-arm
  QEMU_PIDS_DIR=""      # derived: workspace/qemu-bin/.pids
  QEMU_PID_FILE=""      # derived: workspace/qemu-bin/.pids/<machine>.pid
  ```

  - Change: 追加上述变量声明
- [ ] Step 3: 确认 `ob --help` 正常执行
- Run: `./ob --help > /dev/null 2>&1; echo "exit=$?"`
- Expected: 输出 `exit=0`

### Task 4: 实现 `read_source_label()` 辅助函数

- 目标：从 `openbmc-source.lock` 读取当前 workspace 的 `source_label`（`community` 或 `custom`），供 QEMU binary 路径派生使用
- 涉及文件：`ob`（`# === Functions ===` 区域，约 L256 之后）
- 验证范围：对已有 lockfile 能正确读取 `source_label`

- [ ] Step 1: 确认 `read_lock_field` 函数已存在
- Run: `grep -n 'read_lock_field' /bmc/iasi/ob-harness/ob | head -5`
- Expected: 至少出现函数定义和调用点
- [ ] Step 2: 实现 `read_source_label()`，内部调用已有的 `read_lock_field source_label`
  - 若 `SOURCE_LOCK_FILE` 不存在或字段为空，fallback 到 `"community"`
  - Change: 在 `# === Functions ===` 区域（`normalize_repo_url` 之前）增加函数
- [ ] Step 3: 验证函数可被调用
  在 `ob` 临时测试点插入 `read_source_label && echo "label=$SOURCE_LABEL"` 并执行：
- Run: `grep -n 'read_source_label' /bmc/iasi/ob-harness/ob | head -3`
- Expected: 出现函数定义行
- [ ] Step 4: 测试完成后移除临时测试点

### Task 5: 实现 `derive_qemu_paths()` 辅助函数

- 目标：根据 `source_label` 和 `machine` 派生所有 QEMU 相关路径（binary、manifest、PID 文件），供后续函数使用
- 涉及文件：`ob`（`# === Functions ===` 区域）
- 验证范围：函数正确设置 `QEMU_BIN_DIR`、`QEMU_BIN_FILE`、`QEMU_PIDS_DIR`、`QEMU_PID_FILE`

- [ ] Step 1: 确认路径规则定义明确
- Expected: `community` → `workspace/qemu-bin/community/`，`custom` → `workspace/qemu-bin/custom/`，PID → `workspace/qemu-bin/.pids/`
- [ ] Step 2: 实现 `derive_qemu_paths()`

  ```bash
  derive_qemu_paths() {
      local label
      label=$(read_source_label)
      QEMU_BIN_DIR="$WORKSPACE_DIR/qemu-bin/$label"
      QEMU_BIN_FILE="$QEMU_BIN_DIR/qemu-system-arm"
      QEMU_PIDS_DIR="$WORKSPACE_DIR/qemu-bin/.pids"
      QEMU_PID_FILE="$QEMU_PIDS_DIR/${MACHINE}.pid"
  }
  ```

  - Change: 在 `read_source_label()` 之后增加函数
- [ ] Step 3: 确认函数存在
- Run: `grep -n 'derive_qemu_paths' /bmc/iasi/ob-harness/ob | head -3`
- Expected: 出现函数定义行

### Task 6: 实现 `ensure_qemu_binary()` 辅助函数

- 目标：检测 QEMU binary 是否已下载，未下载则根据 `source_label` 自动下载并写 `.manifest`
- 涉及文件：`ob`（`# === Functions ===` 区域）
- 验证范围：binary 不存在时自动下载并写入 manifest；已存在时跳过

- [ ] Step 1: 确认 Jenkins 下载 URL
- Expected: `https://jenkins.openbmc.org/job/latest-qemu-x86/lastSuccessfulBuild/artifact/qemu/build/qemu-system-arm`
- [ ] Step 2: 实现 `ensure_qemu_binary()`

  核心逻辑：
  1. 调用 `derive_qemu_paths()`
  2. 检查 `QEMU_BIN_FILE` 是否存在且可执行 → 是则 return
  3. 创建 `QEMU_BIN_DIR` 目录
  4. 根据 `source_label` 决定下载源：
     - `community`：从 Jenkins URL 下载到 `QEMU_BIN_FILE`
     - `custom`：从 `OB_QEMU_BINARY_URL` 环境变量或企业 meta layer 约定文件获取 URL，下载到临时文件，检测是否为 tarball（`.tar.gz` / `.tar.xz`），tarball 则解压到 `QEMU_BIN_DIR` 并定位 `qemu-system-arm` 或 `qemu-system-aarch64`
  5. `chmod +x "$QEMU_BIN_FILE"`
  6. 写 `.manifest` 文件（source、url、downloaded_at、sha256）
  7. community 源额外记录 Jenkins build number（通过 API `.../lastSuccessfulBuild/api/json?tree=number` 获取）

  - Change: 新增函数
- [ ] Step 3: 确认函数存在
- Run: `grep -n 'ensure_qemu_binary' /bmc/iasi/ob-harness/ob | head -3`
- Expected: 出现函数定义行

### Task 7: 实现 `resolve_qb_vars()` 辅助函数

- 目标：通过 `source setup` + `bitbake -e` 从 BitBake 展开变量中读取 `QB_MACHINE` 和 `QB_MEM`
- 涉及文件：`ob`（`# === Functions ===` 区域）
- 验证范围：对已 init 的 machine 能正确返回 `QB_MACHINE` 和 `QB_MEM` 的值

- [ ] Step 1: 确认 `source setup` 的调用模式已在代码中存在
- Run: `grep -n 'source setup' /bmc/iasi/ob-harness/ob | head -5`
- Expected: 至少出现 `source setup "$MACHINE" "$BUILD_DIR"` 的调用
- [ ] Step 2: 实现 `resolve_qb_vars()`

  核心逻辑：
  1. 校验 `BUILD_DIR` 和 `$OPENBMC_DIR/setup` 存在
  2. 临时禁用 `set -u`（setup 内部引用未绑定变量）
  3. `cd "$OPENBMC_DIR" && source setup "$MACHINE" "$BUILD_DIR"`
  4. `bitbake -e | grep '^QB_MACHINE=' | head -1` 提取值
  5. `bitbake -e | grep '^QB_MEM=' | head -1` 提取值
  6. 校验两个值都非空，空则报错退出并提示用户在 machine conf 中配置
  7. 从 `QB_MACHINE` 值中提取 `-machine` 后面的参数部分作为 `QB_MACHINE_NAME`
  8. 从 `QB_MEM` 值中提取 `-m` 后面的参数部分作为 `QB_MEM_SIZE`
  9. 将结果写入全局变量供 `cmd_start_qemu` 使用

  - Change: 新增函数
- [ ] Step 3: 确认函数存在
- Run: `grep -n 'resolve_qb_vars' /bmc/iasi/ob-harness/ob | head -3`
- Expected: 出现函数定义行

### Task 8: 实现 `check_ports_available()` 辅助函数

- 目标：检查端口是否被占用，被占用则报错并给出设置示例
- 涉及文件：`ob`（`# === Functions ===` 区域）
- 验证范围：端口空闲时静默通过；被占用时报错退出

- [ ] Step 1: 确认端口检查方式（`ss` 或 `lsof`）
- Run: `which ss && ss -tlnp 2>/dev/null | head -3`
- Expected: `ss` 可用并输出监听端口列表
- [ ] Step 2: 实现 `check_ports_available()`

  核心逻辑：
  1. 接收端口列表（tcp/udp 标记 + 端口号）
  2. 对每个端口，TCP 用 `ss -tlnpH "sport = :$port"` 检查，UDP 用 `ss -ulnpH "sport = :$port"` 检查
  3. 有占用则记录到数组
  4. 全部检查完后，有占用则报错退出，格式：

     ```
     [ERROR] Port(s) already in use:
       TCP 2222 — used by process 12345/sshd
     Set a different port: ob start-qemu romulus --ssh-port 22223
     Or export: export OB_QEMU_SSH_PORT=22223
     ```

  - Change: 新增函数
- [ ] Step 3: 确认函数存在
- Run: `grep -n 'check_ports_available' /bmc/iasi/ob-harness/ob | head -3`
- Expected: 出现函数定义行

### Task 9: 实现 PID 文件管理函数

- 目标：实现 `write_pid_file()`、`read_pid_file()`、`validate_pid()` 三个函数，支撑进程安全管理
- 涉及文件：`ob`（`# === Functions ===` 区域）
- 验证范围：写读 PID 文件正常；进程不存在时 `validate_pid` 返回失败；PID 被回收时检测到不匹配

- [ ] Step 1: 确认 PID 文件格式定义明确
- Expected: `pid=`、`user=`、`machine=`、`binary=`、`started_at=`、`ssh_port=`、`redfish_port=`、`ipmi_port=`
- [ ] Step 2: 实现三个函数

  `write_pid_file()`：
  1. 创建 `QEMU_PIDS_DIR` 目录
  2. 写 `QEMU_PID_FILE`，内容包括 pid、当前用户 (`$(whoami)`)、machine、binary 路径、时间戳、端口映射

  `read_pid_file()`：
  1. 检查 `QEMU_PID_FILE` 是否存在
  2. 解析各字段到全局变量

  `validate_pid()`：
  1. 检查 `/proc/<pid>/` 目录是否存在 → 不存在返回"进程已退出"
  2. 读取 `/proc/<pid>/cmdline`，检查是否包含 binary 路径和 machine 名 → 不匹配返回"PID 已回收"
  3. 匹配则返回成功

  - Change: 新增三个函数
- [ ] Step 3: 确认函数存在
- Run: `grep -c 'write_pid_file\|read_pid_file\|validate_pid' /bmc/iasi/ob-harness/ob`
- Expected: 输出 `>= 3`（每个函数至少出现一次定义）

### Task 10: 实现 `cmd_start_qemu()` 主函数

- 目标：实现 `ob start-qemu` 的完整执行流程
- 涉及文件：`ob`（`cmd_build()` 之后、`# === Main ===` 之前）
- 验证范围：对已 init 且已 build 的 machine 能完整启动 QEMU 并输出连接摘要

- [ ] Step 1: 确认插入位置
- Run: `grep -n 'cmd_build\|^# === Main' /bmc/iasi/ob-harness/ob | tail -5`
- Expected: `cmd_build()` 在 L788，`# === Main ===` 在 L1784
- [ ] Step 2: 实现 `cmd_start_qemu()`

  完整流程（对应决策 #6 的前置检查顺序）：
  1. `detect_harness_root`
  2. 解析 machine：命令行指定则直接用，未指定则扫描 `*.init-done` 交互选择（复用 `cmd_build` 的选择模式）
  3. 重算路径：`BUILD_DIR`、`CONFIGS_DIR` 等
  4. **前置检查 1**：`*.init-done` 是否存在 → 否则报错提示 `ob init <machine>`
  5. **前置检查 2-3**：`resolve_qb_vars()` → 读取 `QB_MACHINE` 和 `QB_MEM`，读不到报错
  6. **前置检查 4**：`ensure_qemu_binary()` → 自动下载 binary
  7. **前置检查 5**：检查 `.static.mtd` 文件是否存在 → 否则报错提示 `ob build`
  8. **端口应用优先级**：命令行参数 → 环境变量 → 默认值（2222/2443/2623，HTTP 无默认）
  9. **前置检查 6**：`check_ports_available()`
  10. **重复启动检查**：`read_pid_file()` + `validate_pid()` → 已有实例则根据 `--force` 和交互模式决定行为
  11. 构建并执行 QEMU 启动命令：

      ```bash
      setsid "$QEMU_BIN_FILE" \
        -machine "$QB_MACHINE_NAME" \
        "$QB_MEM_SIZE_FLAG" \
        -drive file="$IMAGE_FILE",format=raw,if=mtd \
        -net nic,netdev=net0 \
        -netdev user,id=net0,hostfwd=... \
        -serial file:"$SERIAL_LOG_PATH" \
        -serial null -monitor none \
        -daemonize
      ```

  12. `write_pid_file()`
  13. 等待就绪（除非 `--no-wait`）：轮询 SSH 端口可达，最长 150 秒（30 次 × 5 秒）
  14. 输出连接摘要（SSH / WebUI / Redfish / IPMI + 日志路径 + stop 命令）

  - Change: 新增函数
- [ ] Step 3: 确认函数存在
- Run: `grep -n 'cmd_start_qemu' /bmc/iasi/ob-harness/ob | head -3`
- Expected: 出现函数定义行

### Task 11: 实现 `cmd_stop_qemu()` 主函数

- 目标：实现 `ob stop-qemu` 的完整执行流程
- 涉及文件：`ob`（`cmd_start_qemu()` 之后）
- 验证范围：对运行中的 QEMU 实例能安全停止

- [ ] Step 1: 确认插入位置
- Run: `grep -n 'cmd_start_qemu' /bmc/iasi/ob-harness/ob | head -3`
- Expected: 出现 Task 10 新增的函数
- [ ] Step 2: 实现 `cmd_stop_qemu()`

  完整流程：
  1. `detect_harness_root`
  2. machine 解析：指定则用，未指定 + `--all` 则扫所有 PID 文件，未指定且无 `--all` 则扫所有 PID 文件列出运行中实例交互选择
  3. 重算路径
  4. 对每个目标 machine：
     a. `read_pid_file()` → 无 PID 文件则报"未运行"
     b. `validate_pid()` → 进程已退出则清理 PID 文件
     c. 展示进程信息（PID、启动时间、端口、serial log 路径）
     d. 非 `--force` + 交互模式 → 确认 `[y/N]`
     e. `kill <pid>`，等待 5 秒确认进程退出
     f. 清理 PID 文件

  - Change: 新增函数
- [ ] Step 3: 确认函数存在
- Run: `grep -n 'cmd_stop_qemu' /bmc/iasi/ob-harness/ob | head -3`
- Expected: 出现函数定义行

### Task 12: 修改 `main()` 分发逻辑

- 目标：在 `main()` 函数中增加 `start-qemu` 和 `stop-qemu` 的分发分支
- 涉及文件：`ob` (`main()` 函数，约 L1974-L2001)
- 验证范围：`ob start-qemu --help` 和 `ob stop-qemu --help` 正常执行

- [ ] Step 1: 确认当前 `main()` 只分发到 `cmd_status`、`cmd_build`、`cmd_init`
- Run: `grep -A10 'CLI mode' /bmc/iasi/ob-harness/ob | tail -15`
- Expected: 只看到 `status`、`build`、`init` 三个分支
- [ ] Step 2: 在 `if [[ "$COMMAND" == "build" ]]; then` 之后、`cmd_init` 之前增加两个分支

  ```bash
  if [[ "$COMMAND" == "start-qemu" ]]; then
      cmd_start_qemu
      return $?
  fi

  if [[ "$COMMAND" == "stop-qemu" ]]; then
      cmd_stop_qemu
      return $?
  fi
  ```

  - Change: 在 `main()` 中增加两个分发分支
- [ ] Step 3: 确认分发生效
- Run: `./ob start-qemu --help 2>&1 | head -5`
- Expected: 输出 usage 信息，无 "Unknown command" 错误

### Task 13: 修改 `cmd_menu()` 增加菜单项

- 目标：交互式菜单中增加 `start-qemu` 和 `stop-qemu` 选项
- 涉及文件：`ob` (`cmd_menu()` 函数，约 L1889-L1972)
- 验证范围：菜单显示新选项，选择后能执行

- [ ] Step 1: 确认当前菜单只有 1/2/3 三个选项
- Run: `grep -A3 'echo.*Choose' /bmc/iasi/ob-harness/ob | head -10`
- Expected: 只看到 `init`/`build`/`status` 三个菜单项
- [ ] Step 2: 在菜单中增加选项 4（start-qemu）和 5（stop-qemu），在 `case "$choice"` 中增加对应分支
  - Change: 修改菜单 echo 和 case 分支
- [ ] Step 3: 确认菜单显示新选项
- Run: `grep 'start-qemu\|stop-qemu' /bmc/iasi/ob-harness/ob | head -5`
- Expected: 在 `cmd_menu()` 区域出现

### Task 14: 修改 `cmd_status()` 追加 QEMU 实例信息

- 目标：`ob status` 输出末尾追加当前用户正在运行的 QEMU 实例摘要，无实例则不显示
- 涉及文件：`ob` (`cmd_status()` 函数，约 L757-L786)
- 验证范围：有 QEMU 实例时显示摘要，无实例时该段不出现

- [ ] Step 1: 确认 `cmd_status()` 当前输出结构
- Run: `grep -n 'cmd_status\|step_header' /bmc/iasi/ob-harness/ob | grep -A5 'cmd_status'`
- Expected: 函数从 L757 开始，调用 `status_main_repo`、`status_machines`、`status_tips`
- [ ] Step 2: 在 `cmd_status()` 末尾（`status_tips` 之后）增加 QEMU 实例扫描逻辑

  ```bash
  # QEMU instances (only shown when instances exist)
  local _pid_files=()
  for _pf in "$WORKSPACE_DIR/qemu-bin/.pids/"*.pid; do
      [[ -f "$_pf" ]] || continue
      # read + validate, collect running instances
      ...
  done
  if [[ ${#_running_instances[@]} -gt 0 ]]; then
      step_header "QEMU Instances"
      # print table
  fi
  ```

  - Change: 在 `cmd_status()` 末尾追加逻辑
- [ ] Step 3: 确认代码存在
- Run: `grep -n 'QEMU Instances' /bmc/iasi/ob-harness/ob | head -3`
- Expected: 出现在 `cmd_status` 区域

## 执行纪律

- 开始实现前，先批判性复查整份计划；如果发现缺项、矛盾、命名不一致或验证命令无效，先修计划
- 按任务顺序执行，不要无声跳步、合并步或改变任务目标
- 每完成一个任务，都运行该任务定义的验证
- 遇到阻塞、重复失败或计划与仓库现实不符，立即停下来说明，不要猜
- 如果当前在 `main` 分支，开始实现前先确认或新建 feature 分支
- 全部任务完成后，运行最终验证并输出修改摘要

## 最终验证

- Run: `./ob --help 2>&1 | grep -c 'start-qemu\|stop-qemu'`
- Expected: `2`
- Run: `./ob start-qemu --help > /dev/null 2>&1; echo "exit=$?"`
- Expected: `exit=0`
- Run: `./ob stop-qemu --help > /dev/null 2>&1; echo "exit=$?"`
- Expected: `exit=0`
- Run: `grep -c 'cmd_start_qemu\|cmd_stop_qemu\|ensure_qemu_binary\|resolve_qb_vars\|check_ports_available\|write_pid_file\|read_pid_file\|validate_pid\|derive_qemu_paths\|read_source_label' /bmc/iasi/ob-harness/ob`
- Expected: `>= 10`（每个函数至少出现一次定义）
- Run: `bash -n /bmc/iasi/ob-harness/ob && echo "syntax OK"`
- Expected: `syntax OK`
