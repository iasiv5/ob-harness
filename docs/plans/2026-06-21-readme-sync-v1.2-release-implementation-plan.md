# README 同步与 v1.2 发布 实施计划

## 目标

把 README 从 v1.0 时代补课到现状（v1.1 的 qemu、v1.2 的非交互 build / 退出码契约都没进 README），在底部新增 `## 版本历史`，定稿 v1.2 release notes，并顺手补掉 `ob --help` 漏列 `OB_OPENBMC_URL` 的文档缺口。v1.2 正文一处维护、三处合一：README 版本史最新条目 = `v1.2` tag 注释 = release 说明。

## 架构快照

- **版本号落点**：版本号只进 README（顶部不出现，底部 `## 版本历史`），不新增 `VERSION` / `CHANGELOG` 文件。策略沿用里程碑式递增（1.0→1.1→1.2），不立 semver 契约；大版本规则留待将来再议。
- **三处合一**：v1.2 release notes 正文只写一遍——作为 README `## 版本历史` 的最新条目，再原样用作 `git tag -a v1.2` 的注释。
- **先修 ob、再同步 README**：Task 1 先把 `OB_OPENBMC_URL` 补进 `ob --help`，这样 Task 4 重写 README 环境变量段时镜像的是「修正后」的 `--help`，README 与代码一次对齐。
- **与现有结构衔接**：README 的「入口 2：ob CLI」段继续用中文解说口吻镜像 `--help`，不直接粘贴英文 `--help`；版本史放在 `## 致谢` 之后（真·底部）。改动 `ob` 后按 AGENTS.md Working Mode 跑 `tools/ob_check.sh` 配套自检。

## 输入工件

- 设计来源：`/grill-with-docs` 会话结论（版本策略 = 里程碑递增；版本载体 = README 底部；结构 A；口径 = 中等：用户可感知打头 + 一段精炼内部质量；`--help` 漏列 `OB_OPENBMC_URL` 顺手补）。已批准。
- 现状基线：`ob usage()`（`ob` 内 `usage()` 函数，Environment Variables 段约 L4158–L4166）；README.md（简介 L21、场景索引表 L34–L44、入口 2 段 L60–L84）。
- 退出码考古：v1.1 已有 `exit 3`（10 处）/`exit 2`（1 处）但不成契约；HEAD 收敛并在 `--help` 首次公开 0/1/2/3——本版是「确立契约」而非「打破契约」，故不触发大版本。

## 文件结构与职责

- Modify: `ob`（`usage()` 函数内 Environment Variables 段）— 补 `OB_OPENBMC_URL` 一行，纯文档修，不动逻辑。
- Modify: `README.md`
  - 简介段（L21）— 补「和 QEMU 仿真」。
  - 场景索引表（L34–L44）— 补 qemu 启停两行。
  - 「入口 2：ob CLI」段（L60–L84）— 重写，镜像当前 `--help` 全貌（5 命令 / qemu 选项 / Exit Codes / 完整环境变量 / 示例）。
  - 底部（`## 致谢` 之后）— 新增 `## 版本历史`（v1.2 / v1.1 / v1.0）。
- Create: `docs/plans/2026-06-21-readme-sync-v1.2-release-implementation-plan.md`（本计划）。

环境前提：`bash`、`python3`、`shellcheck`（CI 与本地均已具备，前序轮次验证过）。

## 任务清单

### Task 1: 补 ob usage() 漏列的 OB_OPENBMC_URL

- 目标：在 `ob --help` 的 Environment Variables 段补上仍在使用（5 处引用）却漏列的 `OB_OPENBMC_URL`，让 `--help` 与代码一致。先做，使后续 README 环境变量段镜像的是修正后的 `--help`。
- Files
  - Modify: `ob`（`usage()` 函数内 `Environment Variables (lower priority than command-line options):` 段）
- 验证范围：`./ob --help` 输出含 `OB_OPENBMC_URL`；改完 `ob` 跑 `tools/ob_check.sh` 仍 ALL GREEN（结构 / 函数登记 / shellcheck baseline / 测试都不受影响，因为只在 heredoc 内加一行文本）。

- [ ] Step 1: 写失败检查（`--help` 漏列）
- Run: `./ob --help | grep -c 'OB_OPENBMC_URL'`
- Expected: `0`（环境变量段没有它；代码里却在用）

- [ ] Step 2: 确认当前失败
- Run: `./ob --help | sed -n '/Environment Variables/,/Examples/p'`
- Expected: 段内只见 `OB_QEMU_*` 与 `OB_NPM_REGISTRY`，无 `OB_OPENBMC_URL`

- [ ] Step 3: 写最小实现
- Change: 在 `ob` 的 `usage()` 里，`Environment Variables (lower priority than command-line options):` 这一行**之下**、`  OB_QEMU_SSH_PORT` **之前**，插入一行：
  ```text
    OB_OPENBMC_URL          Custom OpenBMC repository URL (init, non-interactive mode)
  ```

- [ ] Step 4: 确认通过 + ob 配套自检
- Run: `./ob --help | grep 'OB_OPENBMC_URL'`
- Expected: 命中那一行
- Run: `bash tools/ob_check.sh; echo "rc=$?"`
- Expected: `ALL GREEN (PASS=4)`，rc=0（heredoc 内加文本不影响 GAPS / reorder / baseline / 测试）

- [ ] Step 5: 可选 checkpoint commit
- Run: `git add ob && git commit -m "docs(ob): --help 补列 OB_OPENBMC_URL 环境变量"`
- Expected: commit 成功

### Task 2: 更新 README 简介（补 QEMU 仿真）

- 目标：简介从「init/build/status」口径扩到包含 QEMU 仿真，让首屏不再低估 ob 能力。
- Files
  - Modify: `README.md`（简介段，L21）
- 验证范围：grep 确认简介含「QEMU 仿真」。

- [ ] Step 1: 写失败检查
- Run: `sed -n '21p' README.md | grep -c 'QEMU 仿真'`
- Expected: `0`

- [ ] Step 2: 确认当前失败
- Run: `sed -n '21p' README.md`
- Expected: 现文「…覆盖环境初始化、镜像构建和工作区状态管理；内置 AI Agent 上下文框架…」，不含 QEMU

- [ ] Step 3: 写最小实现
- Change: 把 L21 改为：
  ```text
  OpenBMC 固件开发工作台。`ob` CLI 覆盖环境初始化、镜像构建、工作区状态管理和 QEMU 仿真；内置 AI Agent 上下文框架，用 Claude Code 或 GitHub Copilot 打开仓库即可用自然语言驱动开发任务。
  ```

- [ ] Step 4: 确认通过
- Run: `sed -n '21p' README.md | grep 'QEMU 仿真'`
- Expected: 命中

- [ ] Step 5: 可选 checkpoint commit（与 Task 3 合并提交亦可）
- Run: `git add README.md && git commit -m "docs(readme): 简介补 QEMU 仿真"`
- Expected: commit 成功

### Task 3: 扩充 README 场景索引表（补 qemu 启停）

- 目标：场景索引表补「在 QEMU 启动 / 停止 BMC」两行，与现有 7 行同格式。
- Files
  - Modify: `README.md`（场景索引表，L34–L44）
- 验证范围：表内出现 `start-qemu` 与 `stop-qemu` 两行。

- [ ] Step 1: 写失败检查
- Run: `grep -c 'start-qemu\|stop-qemu' README.md`
- Expected: `0`（README 全文目前不含这两个子命令）

- [ ] Step 2: 确认当前失败
- Run: `sed -n '/场景索引/,/提示/p' README.md`
- Expected: 表只有 init/build/status 等场景，无 qemu

- [ ] Step 3: 写最小实现
- Change: 在场景索引表第 7 行（「给仓库添加新的自动化能力」）**之后**、表尾之前，追加两行（与既有列对齐）：
  ```text
  | 8 | 在 QEMU 中启动 BMC 实例 | `./ob start-qemu [machine]` | "在 QEMU 里启动 romulus" |
  | 9 | 停止 QEMU 实例 | `./ob stop-qemu [machine\|--all]` | "停掉 romulus 的 QEMU" |
  ```

- [ ] Step 4: 确认通过
- Run: `sed -n '/场景索引/,/提示/p' README.md | grep -E 'start-qemu|stop-qemu'`
- Expected: 命中新加的两行（本任务此时入口 2 段尚未重写，`grep -c 'start-qemu' README.md` 应恰为 `1`）

- [ ] Step 5: 可选 checkpoint commit
- Run: `git add README.md && git commit -m "docs(readme): 场景索引补 qemu 启停"`
- Expected: commit 成功

### Task 4: 重写 README「入口 2：ob CLI」段（镜像当前 --help）

- 目标：把停在 v1.0 的 3 命令 / 5 选项口径，整段替换为镜像当前 `--help` 的全貌（5 命令含 `build <machine>` 非交互、start/stop-qemu 选项、Exit Codes、完整环境变量含 Task 1 补的 `OB_OPENBMC_URL`、示例）。中文解说口吻，不直接贴英文 `--help`。
- Files
  - Modify: `README.md`（「入口 2：ob CLI」段，L60–L84 的 ```raw 代码块）
- 验证范围：该段含 `start-qemu`、`stop-qemu`、`Exit Codes`、`OB_OPENBMC_URL`、`ob build romulus` 示例。

- [ ] Step 1: 写失败检查
- Run: `sed -n '/入口 2/,/致谢/p' README.md | grep -cE 'Exit Codes|stop-qemu|--ssh-port'`
- Expected: `0`（现状该段无这些）

- [ ] Step 2: 确认当前失败
- Run: `sed -n '/入口 2/,/致谢/p' README.md`
- Expected: 现段只有 init/build/status 三命令与 5 个 global option，无 qemu 选项、无 Exit Codes、env 只有 `OB_OPENBMC_URL`

- [ ] Step 3: 写最小实现
- Change: 把「入口 2：ob CLI」段里那段 ```raw … ``` 代码块整体替换为下面这块（保留段标题与「两种使用方式」说明文字，只换 raw 块）：

  ````text
  ```raw
  ./ob [command] [options] [arguments]

  Commands:
    init         [<machine>]    初始化 OpenBMC 开发环境
    build        [<machine>]    构建已初始化 machine 的镜像（省略则交互选择）
    status                      查看工作区源码绑定状态
    start-qemu   [<machine>]    用已构建的镜像在 QEMU 中启动 BMC
    stop-qemu    [<machine>]    停止运行中的 QEMU 实例

  Global Options:
    -d, --dry-run         预览操作但不执行
    -s, --skip-deps       复用已有 deps.json，跳过依赖解析（仅 init）
    -u, --url <url>       使用自定义 OpenBMC 仓库 URL（仅 init）
    -v, --verbose         详细输出
    -h, --help            显示帮助

  start-qemu Options:
    --ssh-port <port>       SSH 端口转发    (默认 2222)
    --redfish-port <port>   Redfish 端口转发 (默认 2443)
    --ipmi-port <port>      IPMI 端口转发    (默认 2623, UDP)
    --http-port <port>      HTTP 端口转发    (无默认，设置即启用)
    --serial-log <path>     串口日志路径     (默认 ~/tmp/qemu-<machine>-serial.log)
    --no-wait               不等待 BMC 就绪
    --force                 不确认直接杀掉已有实例

  stop-qemu Options:
    --force                 不确认直接停止
    --all                   停止所有运行中的 QEMU 实例

  Exit Codes:
    0   成功（或良性无操作）
    1   失败 — 损坏或用法错误（如未知选项）
    2   用户取消（不算失败）
    3   前置缺失（如 machine 未初始化 / 未构建）；按提示用 ob 补前置后重试

  Environment Variables (优先级低于命令行选项):
    OB_OPENBMC_URL        非交互指定 OpenBMC 仓库 URL
    OB_QEMU_SSH_PORT      SSH 端口覆盖
    OB_QEMU_REDFISH_PORT  Redfish 端口覆盖
    OB_QEMU_IPMI_PORT     IPMI 端口覆盖
    OB_QEMU_HTTP_PORT     HTTP 端口覆盖
    OB_QEMU_SERIAL_LOG    串口日志路径覆盖
    OB_QEMU_BINARY_URL    自定义 QEMU binary 下载 URL
    OB_NPM_REGISTRY       覆盖 npm registry URL（置空可禁用自动检测）

  Examples:
    ob init                          # 列出 machine 交互选择
    ob init romulus                  # 初始化 romulus
    ob build romulus                 # 非交互构建 romulus
    ob start-qemu romulus            # 在 QEMU 中启动 romulus
    ob start-qemu romulus --ssh-port 22223
    ob stop-qemu romulus             # 停止 romulus 的 QEMU 实例
    ob stop-qemu --all               # 停止所有运行中的实例
  ```
  ````

- [ ] Step 4: 确认通过
- Run: `sed -n '/入口 2/,/致谢/p' README.md | grep -E 'Exit Codes|stop-qemu|--ssh-port|OB_OPENBMC_URL|ob build romulus'`
- Expected: 五个关键字均命中
- Run: `awk '/```raw/{f=1;c++} f&&/```$/&&c{f=0;print "block"c" closed"}' README.md`
- Expected: 每个 ```raw 块都能正确闭合（无残缺围栏，避免 README 渲染崩）

- [ ] Step 5: 可选 checkpoint commit
- Run: `git add README.md && git commit -m "docs(readme): 入口2 ob CLI 段镜像当前 --help 全貌"`
- Expected: commit 成功

### Task 5: 新增 README「版本历史」段（底部，v1.2/v1.1/v1.0）

- 目标：在 `## 致谢` 之后新增 `## 版本历史`，最新条目即 v1.2 release notes（中等口径：用户可感知打头 + 一段精炼内部质量，用 CONTEXT.md 通用语言）。v1.2 正文同时是 Task 7 的 tag 注释来源。
- Files
  - Modify: `README.md`（文末，`## 致谢` 段之后追加）
- 验证范围：文末出现 `## 版本历史`，含 v1.2/v1.1/v1.0 三个小节，v1.2 含「退出码契约」「ob-first」等关键词。

- [ ] Step 1: 写失败检查
- Run: `grep -c '## 版本历史' README.md`
- Expected: `0`

- [ ] Step 2: 确认当前失败
- Run: `tail -5 README.md`
- Expected: 末尾是「致谢」段内容，无版本历史

- [ ] Step 3: 写最小实现
- Change: 在 `## 致谢` 整段**之后**（文末）追加：

  ```text
  ## 版本历史

  ### v1.2 — 2026-06-21

  **✨ 新增**
  - `ob build <machine>` 非交互直构：原仅交互菜单选择，现可 `ob build romulus` 一步直构，便于脚本 / agent 调用。
  - `ob start-qemu` 串口交互登录：BMC 起来后可直接在串口 console 登录调试。
  - `ob start-qemu` 只列出已构建的 machine，避免选到没镜像的机器白跑。

  **🛠 改进**
  - 退出码契约成文：全部子命令统一 `0` 成功 / `1` 失败 / `2` 用户取消 / `3` 前置缺失，写进 `ob --help`；exit 3 时给一行 remedy line（如 `Run 'ob init romulus' first.`），AI agent 据此稳定回退、不再瞎猜。
  - `ob start-qemu` PID 检测改 serial socket + 启动用户过滤，修复多用户共享环境误杀他人 QEMU 的风险；并主动检测、清理陈旧 SSH host key。
  - 交互菜单支持 `0` 取消，不再死循环。
  - `ob build` 修复 `DL_DIR`/`SSTATE_DIR` 用 `??=` 被默认值压过失效的问题（改条件强赋值）；生成的 `.inc` 增补 `BB_HASHSERVE_DB_DIR`。

  **🏗 内部质量**（本轮主体工作）
  - `ob` 大重构：抽公共函数、统一退出码、按 §1–§7 分区重排、删死码。
  - 测试体系从零搭建：protocol / unit / orchestration / integration 四层 + `run_all.sh` + 覆盖率矩阵与雷达 + GitHub Actions CI + shellcheck baseline。
  - 新增 `tools/ob_check.sh`：改完 `ob` 后一站式自检（结构 / 函数登记 / shellcheck baseline / 测试）。
  - 确立 ob-first 约定：OpenBMC 环境动作统一走 `ob` 前门（见 AGENTS.md 与 ADR 0003）。

  ### v1.1 — 2026-06-12

  - 新增 `ob start-qemu` / `ob stop-qemu`：在 QEMU 中启停 BMC 实例（SoC 自动检测、Jenkins 更新检查、端口与 PID 管理、多架构支持）。

  ### v1.0

  - 首发：`ob init` / `ob build` / `ob status` + 内置 AI Agent 上下文框架。
  ```

- [ ] Step 4: 确认通过
- Run: `grep -c '## 版本历史' README.md`
- Expected: `1`
- Run: `sed -n '/## 版本历史/,$p' README.md | grep -E 'v1.2|v1.1|v1.0|退出码契约|ob-first'`
- Expected: 均命中

- [ ] Step 5: 可选 checkpoint commit
- Run: `git add README.md && git commit -m "docs(readme): 新增版本历史(v1.2 release notes)"`
- Expected: commit 成功

### Task 6: 最终验证

- 目标：端到端确认 README 与 ob 一致、ob 配套自检全绿、改动文件集符合预期。
- Files: 无（仅验证）
- 验证范围：ob_check 全绿；README 关键面齐全；`--help` 与 README 环境变量段一致；改动集正确。

- [ ] Step 1: ob 配套自检（Task 1 改过 ob）
- Run: `bash tools/ob_check.sh; echo "rc=$?"`
- Expected: `ALL GREEN (PASS=4)`，rc=0

- [ ] Step 2: README 关键面齐全
- Run: `grep -c 'start-qemu' README.md; grep -c '## 版本历史' README.md; grep -c 'Exit Codes' README.md; sed -n '21p' README.md | grep -c 'QEMU 仿真'`
- Expected: 依次 `>=2`、`1`、`1`、`1`

- [ ] Step 3: `--help` 与 README 环境变量段一致
- Run: `diff <(./ob --help | sed -n '/Environment Variables/,/Examples/p' | grep -oE 'OB_[A-Z_]+' | sort) <(sed -n '/Environment Variables/,/Examples/p' README.md | grep -oE 'OB_[A-Z_]+' | sort)`
- Expected: 输出为空（两边环境变量名集合一致，含 Task 1 补的 `OB_OPENBMC_URL`）

- [ ] Step 4: 确认改动文件集
- Run: `git status --short`
- Expected: 修改 `ob`、`README.md`；新增 `docs/plans/2026-06-21-readme-sync-v1.2-release-implementation-plan.md`（本计划）

### Task 7: 创建 v1.2 annotated tag（注释 = v1.2 release notes）

- 目标：内容全部 commit 后，打 `v1.2` annotated tag，注释用 Task 5 的 v1.2 正文（三处合一的第三处）。推送远端单独由用户确认，不在本任务自动执行。
- Files: 无（git 元数据）
- 验证范围：`git tag -l v1.2` 命中；`git show v1.2 --no-patch` 注释含 release notes 要点。

- [ ] Step 1: 写失败检查（tag 不存在）
- Run: `git tag -l v1.2`
- Expected: 空（v1.2 尚未打）

- [ ] Step 2: 确认当前失败
- Run: `git rev-parse v1.2 2>&1`
- Expected: `unknown revision` 类错误

- [ ] Step 3: 写最小实现
- Change: 确认 Task 6 改动文件集已全部 commit 后，打 annotated tag（注释取自 Task 5 的 v1.2 正文，可精简为无 markdown 加粗的纯文本）：
  ```bash
  git tag -a v1.2 -F - <<'EOF'
  v1.2 — README 同步 + 退出码契约成文 + 测试体系

  新增:
  - ob build <machine> 非交互直构
  - ob start-qemu 串口交互登录 / 只列已构建 machine
  改进:
  - 退出码契约成文 (0/1/2/3 写进 --help, exit-3 remedy line)
  - start-qemu PID 检测改 serial socket+用户过滤(多用户防误杀); 清理陈旧 host key
  - 交互菜单 0 取消; build DL_DIR/SSTATE_DIR 强赋值修复 + BB_HASHSERVE_DB_DIR
  内部质量:
  - ob 大重构 / 测试体系从零搭建(四层+CI) / tools/ob_check.sh / ob-first 约定(ADR 0003)
  EOF
  ```

- [ ] Step 4: 确认通过
- Run: `git tag -l v1.2`
- Expected: `v1.2`
- Run: `git show v1.2 --no-patch | grep -E '退出码契约|ob-first|非交互直构'`
- Expected: 均命中

- [ ] Step 5: 推送（需用户确认，非自动）
- Run: `git push origin v1.2`
- Expected: 仅在用户明确同意推送后执行；tag 上传成功

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划再动手。
- 按任务顺序执行（Task 1 必须先于 Task 4——README 环境变量段镜像的是修正后的 `--help`），不无声跳步、合并步或改变任务目标。
- 每完成一个任务，运行该任务定义的验证；验证不过不算完成。
- 遇阻塞、重复失败或计划与仓库现实不符，立即停下说明，不要猜。
- **当前分支为 `main`**：若用户未明确同意在 main 上直接实现，开始前先确认，或先开 `release/v1.2-readme-sync` 之类分支再动手。
- Task 1 改过 `ob`，Task 6 必须跑 `tools/ob_check.sh` 确认配套自检全绿（AGENTS.md Working Mode 要求）。
- Task 7 的 `git push` 是发布动作，必须用户明确同意后才执行。

## 最终验证

- `bash tools/ob_check.sh` → `ALL GREEN (PASS=4)`，rc=0
- `./ob --help | grep OB_OPENBMC_URL` → 命中（Task 1 文档缺口已补）
- `grep -c '## 版本历史' README.md` → `1`；`sed -n '/## 版本历史/,$p' README.md | grep -E 'v1.2|v1.1|v1.0'` → 三版本均命中
- `diff <(./ob --help | grep -oE 'OB_[A-Z_]+' | sort) <(sed -n '/Environment Variables/,/Examples/p' README.md | grep -oE 'OB_[A-Z_]+' | sort)` → 空（README 与 `--help` 环境变量一致）
- `git tag -l v1.2` → `v1.2`；`git show v1.2 --no-patch` 注释含 release notes 要点
- `git status --short` → 改动集为 `ob` / `README.md` / 本计划文件；ob 无残留探针

## 审阅 Checkpoint

- 计划正文结束。请先确认这份计划；如果没问题，下一步可按计划由普通编码 agent 或人工继续执行。
- 审阅通过前不进入实现。
- 注意：Task 7 涉及打 tag 与可选推送，属发布动作；执行前再次与用户确认。
