# ob test-qemu help 补齐 + ob --help 全命令文案 agent 化 实施计划

## 目标

让一个新的 agent session 只靠 `./ob --help` 与 `./ob test-qemu --help` 就能掌握 test-qemu 的用法、示例与前置链条；同时修复 `ob --help` 其余子命令文案中 4 个 agent 可消费性问题。

## 架构快照

- 两处 help 均为硬编码 heredoc：顶层 `usage()`（`ob` 的 202-310 行），子命令 `test_qemu_usage()`（`lib/qemu_commands.sh` 的 646-732 行）。本次仅在这两个 heredoc 内增补/修订文案，不改 dispatch 与 help 触发机制。
- 事实核查修正：`test_qemu_usage` 已含凭据 env 清单（`OB_TQ_*` 系列，仅变量名+优先级，无明文密码）与谱系两行对照（community→`tests/baseline/<m>`、custom→`contexts/baseline/<m>`、缺失 fail-closed）。子命令 help 缺口为：Examples 段、Prerequisites 前置链条段，以及一处过期事实——Redfish 凭据行 "env wins over argv flags and over ar_probes.yaml auth"（`qemu_commands.sh:668`）：`cmd_test_qemu` 无任何 credential argv flag（解析仅 `--suite/--ar/--report/-v/-d/-h`），"over argv flags" 删除（评审 🟡4）。
- 顶层 `ob --help` 的 Examples 段（`ob` 289-308 行）test-qemu 为 0 条，补 2 条。
- env 归属事实（评审 🟡3 坐实）：`OB_QEMU_*_PORT`/`OB_QEMU_SERIAL_LOG` 在 `qemu_prepare_launch`（`lib/qemu.sh:86`）解析，`start-qemu`（`qemu_commands.sh:150`）与 `deploy-to-qemu`（`qemu_commands.sh:479`）均调用；`OB_NPM_REGISTRY` 在 build 路径解析（`lib/util.sh:313-328`），`build` 与 `deploy-to-qemu` 共享。

## 全局约束

- 文案规则：heredoc 散文中避免 "exit code"（exit 后空格）字样，统一写 "exit-code" 连字符（EXIT_RE 不解析 heredoc，误匹配触发 X 违反）。已有 heredoc 中出现的 "exit code" 保持不动（现状 baseline 通过），新增文案一律用连字符形式。
- 凭据：只写 env 变量名与优先级，不写任何明文密码/默认账号。
- 改 `ob` / `lib/*.sh` 后必须跑 `tools/ob_check.sh` 做配套自检。
- 遵循 test-qemu 既有 help 的结构风格（Boundary/段首关键词缩进对齐，80 列内换行）。

## 输入工件

- 本会话 `/grill-with-docs` 共识（Q1~Q8 全按推荐、Q9 选 c）
- 代码事实（已 grep 坐实，任务中直接引用）：
  - `cmd_build`（`lib/commands.sh:107`）：未 init → `require_path` exit 3 + "Run '$OB_CMD init' first."；未指定 machine 且非 TTY → exit 3 提示指定 machine。
  - `cmd_deploy_to_qemu`（`lib/qemu_commands.sh:343`）：build-first（QEMU 在跑也不先停，先 `bitbake obmc-phosphor-image`）；build 失败 → QEMU 不动，exit 1；QEMU running 时弹 confirm（N → exit 2）；build 期间实例变化/新实例出现 → exit 3；成功后 stop 旧实例 + 端口复用（仅原实例 running 时）+ start 新实例；QEMU 非 running 时 = build + 全新 start（默认端口，无复用）；`--dry-run` 短路为 notice 一行。
  - `-s/--skip-deps` 仅 init 有效（`ob:167`, `ob:220`, `lib/commands.sh:313`）；`--url`/`OB_OPENBMC_URL` 仅 init 有效（`lib/repo.sh:323-360`）。
  - `OB_QEMU_*_PORT`/`OB_QEMU_SERIAL_LOG` 仅 qemu 系命令消费（`lib/qemu.sh` 7 处引用）；`OB_QEMU_BINARY_URL` 仅 binary provisioning。

## 文件结构与职责

- Modify: `ob`（`usage()` heredoc）——Examples 补 test-qemu 2 条；deploy-to-qemu 补 Boundary 说明；build 行补前置语义；`-s`/`-u` 标注方式调整；Env Vars 段补命令归属。
- Modify: `lib/qemu_commands.sh`（`test_qemu_usage` heredoc）——新增 `Prerequisites:` 段与 `Examples:` 段；修正 Redfish 凭据行 "over argv flags" 过期文案。
- Modify: `tests/protocol/test_qemu_surface.sh`——把新增 help surface 契约锁进协议断言（评审 🟢1）。
- 不新增文件；know-how 专文按共识另开任务。

## 任务清单

### Task 1: `test_qemu_usage` 补 Prerequisites + Examples 段

- 目标：子命令 help 自足——新 agent 不看别的文档就能知道前置链条与可照抄命令。
- 涉及文件：`lib/qemu_commands.sh`（`test_qemu_usage` heredoc）。插入位置唯一确定（评审 🟢2）：Prerequisites 插在 Options 段后、Environment 段前；Examples 插在 Exit codes 段后、heredoc `EOF` 前。
- 接口契约
  - Consumes: 既有 heredoc 段落结构与 `$OB_CMD` 变量。
  - Produces:
    - `Prerequisites:` 段——区分"推荐链条"与"真实检查"（评审 🟡1，对齐 `cmd_test_qemu` 真实检查顺序，不把链条写成被检查的前置）：
      ```text
      Prerequisites:
        Typical setup path: init → build → start-qemu → test-qemu.
        test-qemu itself checks PyYAML, source manifest lineage, and the
        lineage-routed baseline dir (see baseline dir below). Probe runs also
        require credentials (env or ar_probes.yaml auth, see Environment) and
        a running QEMU instance. --dry-run skips credentials and
        running-instance checks, but still checks local baseline assets.
        exit-code 3 means a missing precondition/config/infra gate — follow
        the printed remedy and retry.
      ```
    - `Examples:` 段（2 条：`$OB_CMD test-qemu romulus --suite smoke` 注释 "Run the 8-AR smoke gate on a running romulus instance"；`$OB_CMD test-qemu romulus --ar SMOKE-03 -v` 注释 "Re-run one AR with per-AR fail detail"）。
    - Redfish 凭据行修正：`qemu_commands.sh:668` "env wins over argv flags and over / ar_probes.yaml auth" 改为 "env wins over / ar_probes.yaml auth"（无 credential argv flag，删除过期表述）。
- 验证范围：heredoc 渲染正确、EXIT_RE 不误报、ob_check 通过。

- [ ] Step 1: 确认当前缺失（失败检查）
- Run: `! ./ob test-qemu --help 2>&1 | grep -qE '^Prerequisites:|^Examples:'`
- Expected: 命令退出 0（两段均不存在；grep 不命中，取反后整条退出 0）
- [ ] Step 2: 编辑 heredoc 增补两段 + 修正凭据行
- Change: 按 Produces 契约插入 Prerequisites 段与 Examples 段，并删除 `qemu_commands.sh:668` 的 "over argv flags and" 过期表述；缩进与相邻段对齐，新增文案一律用 "exit-code" 连字符。
- [ ] Step 3: 确认渲染（两段头各自独立断言，评审 🟢1）
- Run: `bash -c './ob test-qemu --help 2>&1 | grep -q "^Prerequisites:" && ./ob test-qemu --help 2>&1 | grep -q "^Examples:" && ./ob test-qemu --help 2>&1 | grep -q "SMOKE-03" && ! ./ob test-qemu --help 2>&1 | grep -q "over argv flags"'`
- Expected: 退出 0（四项全过；任一缺失即非 0）
- [ ] Step 4: 把 help surface 契约锁进协议测试（评审 🟢1）
- Change: 在 `tests/protocol/test_qemu_surface.sh` 用例 (1b) 之后追加断言（沿用文件内既有 `assert_true`/`$out`/`$_obhelp` 变量模式）：
  ```bash
  # (1c) help surface 契约(2026-08-24 help 补齐): Prerequisites/Examples 段 + 示例锚点
  assert_true "test-qemu help has Prerequisites" grep -q "^Prerequisites:" <<<"$out"
  assert_true "test-qemu help has Examples" grep -q "^Examples:" <<<"$out"
  assert_true "test-qemu help has SMOKE-03 example" grep -q "SMOKE-03" <<<"$out"
  assert_false "test-qemu help 无过期 'over argv flags' 表述" grep -q "over argv flags" <<<"$out"
  ```
  注意：本步骤只加 test-qemu 子命令 help 的 4 条断言；"顶层 usage 有 test-qemu smoke 示例"断言属 Task 2（依赖其产出），不在此处落（评审二轮 🔴1）。
- [ ] Step 5: 协议测试 + ob_check 配套自检
- Run: `bash tests/protocol/test_qemu_surface.sh && bash tools/ob_check.sh`
- Expected: 两者均退出 0

### Task 2: 顶层 `ob --help` Examples 补 test-qemu 2 条

- 目标：消除顶层 Examples 中 test-qemu 0 条的缺口。
- 涉及文件：`ob`（`usage()` heredoc Examples 段，deploy-to-qemu 行后插入）。
- 接口契约
  - Consumes: Examples 段既有行格式 `$OB_CMD <cmd> ... # comment`。
  - Produces: 两行示例——`  $OB_CMD test-qemu romulus --suite smoke  # Run the 8-AR smoke gate (needs a running instance: start-qemu first)` 与 `  $OB_CMD test-qemu romulus --ar SMOKE-03 -v    # Re-run one AR with fail detail`。
- 验证范围：局部 help/protocol 验证；ob_check 由 Task 5 统一兜底。

- [ ] Step 1: 失败检查
- Run: `! ./ob --help 2>&1 | grep -q 'test-qemu romulus'`
- Expected: 命令退出 0（当前无该示例，grep 不命中）
- [ ] Step 2: 插入两行示例
- Change: 按 Produces 契约，插入位置在 `deploy-to-qemu` 示例行之后、`dev` 示例行之前。
- [ ] Step 3: 把顶层示例断言锁进协议测试（评审二轮 🔴1：断言随其依赖的产出同任务落地，避免 Task 1 验证必红）
- Change: 在 `tests/protocol/test_qemu_surface.sh` 用例 (1b) 的 `$_obhelp` 之后追加：
  ```bash
  # (1d) 顶层 usage 有 test-qemu smoke 示例(2026-08-24 help 补齐)
  assert_true "顶层 usage 有 test-qemu smoke 示例" grep -q "test-qemu romulus --suite smoke" <<<"$_obhelp"
  ```
- [ ] Step 4: 确认通过（逐条独立断言，评审二轮 🟡1）
- Run: `bash -c './ob --help | grep -q "test-qemu romulus --suite smoke" && ./ob --help | grep -q "test-qemu romulus --ar SMOKE-03 -v" && bash tests/protocol/test_qemu_surface.sh'`
- Expected: 退出 0（两条示例各自命中 + 协议测试全绿）

### Task 3: deploy-to-qemu 与 build 的 Boundary/前置文案（基于已坐实代码行为）

- 目标：把调研出的行为事实写进 `ob --help`，消除 deploy 语义歧义与 build 前置空白。
- 涉及文件：`ob`（`usage()` heredoc）。
- 接口契约
  - Consumes: 输入工件中已坐实的 `cmd_deploy_to_qemu` / `cmd_build` 行为。
  - Produces:
    - 新增 `deploy-to-qemu Options:` 段（在 `stop-qemu Options:` 段后）。Boundary 文案采用评审 🟡2 版本（真实不变量是"build 成功前不 stop/kill/mutate"，不是"完全不碰 QEMU"——deploy 会先探测旧实例、读旧端口、running 时弹 confirm，见 `qemu_commands.sh:374-423`）：
      ```text
      deploy-to-qemu Options:
        Boundary: build-first mutation — deploy may inspect the current QEMU
                  instance and ask for confirmation first, but it does not stop
                  or mutate QEMU until after a successful image build. Build
                  failure leaves QEMU untouched and exits 1. If a previous
                  instance was running, its forwarded ports are reused unless
                  CLI port flags were provided; otherwise deploy starts fresh
                  with default/env ports. User abort exits 2; instance drift
                  during build exits 3.
      ```
      （该 heredoc 段为散文段；"exits 1/2/3" 处避免 "exit code" 空格形式，沿用 "exits N" 或 "exit-code" 连字符。）
    - `build` 行（Commands 表 210 行）描述改为含前置语义：`Build an initialized machine's image (interactive if omitted; uninitialized → exit-code 3, run init first)`。
- 验证范围：文案与代码行为一致、EXIT_RE 安全、ob_check 通过。

- [ ] Step 1: 失败检查
- Run: `! ./ob --help 2>&1 | grep -qE 'deploy-to-qemu Options:|build-first'`
- Expected: 命令退出 0（当前两者均不存在）
- [ ] Step 2: 写入 Boundary 段与 build 行修订
- Change: 按 Produces 契约；全部用 "exit-code" 连字符。
- [ ] Step 3: 确认通过（三个锚点独立断言，评审二轮 🟡1）
- Run: `bash -c './ob --help | grep -q "deploy-to-qemu Options:" && ./ob --help | grep -q "build-first mutation" && ./ob --help | grep -q "uninitialized → exit-code 3"'`
- Expected: 退出 0（三个锚点各自命中）
- [ ] Step 4: ob_check
- Run: `bash tools/ob_check.sh`
- Expected: 退出 0

### Task 4: `-s`/`-u` 标注与 Env Vars 命令归属

- 目标：消除 Global Options 混 per-command 限定、Env Vars 无归属两个对称性问题。
- 涉及文件：`ob`（`usage()` heredoc Global Options 段、Environment Variables 段）。
- 接口契约
  - Consumes: 引用计数事实（`-s` init-only：`lib/commands.sh:313`；`--url`/`OB_OPENBMC_URL` init-only：`lib/repo.sh:323-360`；`OB_QEMU_*` 在 `qemu_prepare_launch` 解析、start-qemu 与 deploy-to-qemu 双消费：`lib/qemu.sh:86`、`qemu_commands.sh:150/479`；`OB_NPM_REGISTRY` 走 build 路径、build 与 deploy-to-qemu 共享：`lib/util.sh:313-328`）。
  - Produces:
    - Global Options 段两行迁移：`-s, --skip-deps` 与 `-u, --url <url>` 移出 Global Options，在 Global Options 段后新增 `init Options:` 段收纳（与 start-qemu/stop-qemu Options 段同构），描述文字保留原义。
    - Environment Variables 段每个变量补命令归属（评审 🟡3 版本，与 Consumes 坐实事实一致）：
      ```text
      Environment Variables (command scope shown in parentheses; matching CLI
      flags override env values where available):
        OB_OPENBMC_URL          Custom OpenBMC repository URL (init)
        OB_QEMU_SSH_PORT        QEMU launch SSH port override (start-qemu/deploy-to-qemu)
        OB_QEMU_REDFISH_PORT    QEMU launch Redfish port override (start-qemu/deploy-to-qemu)
        OB_QEMU_IPMI_PORT       QEMU launch IPMI port override (start-qemu/deploy-to-qemu)
        OB_QEMU_HTTP_PORT       QEMU launch HTTP port override (start-qemu/deploy-to-qemu)
        OB_QEMU_SERIAL_LOG      QEMU launch serial log path (start-qemu/deploy-to-qemu)
        OB_QEMU_BINARY_URL      QEMU binary provisioning (start-qemu/deploy-to-qemu)
        OB_NPM_REGISTRY         Image build npm registry override (build/deploy-to-qemu)
      ```
      同时把原总标题 `(lower priority than command-line options)` 改掉——`OB_QEMU_BINARY_URL`/`OB_NPM_REGISTRY` 无对应 CLI option，原总括句不准确（评审 🟡3）；新标题采用中性表述（评审二轮 🟡2），不写 "no CLI-flag equivalent"（`OB_OPENBMC_URL`↔`--url`、`OB_QEMU_*_PORT`↔`--*port` 均有 CLI 对应项）。
- 验证范围：局部 help 验证（结构对称、归属准确）；ob_check 由 Task 5 统一兜底。

- [ ] Step 1: 失败检查
- Run: `! ./ob --help 2>&1 | grep -qE 'init Options:|OB_QEMU_SSH_PORT.*start-qemu'`
- Expected: 命令退出 0（当前两者均不存在）
- [ ] Step 2: 重组两段
- Change: 按 Produces 契约。
- [ ] Step 3: 确认通过（每个锚点独立断言，评审 🟢1）
- Run: `bash -c './ob --help | grep -q "init Options:" && ./ob --help | grep -q "OB_QEMU_SSH_PORT.*start-qemu/deploy-to-qemu" && ./ob --help | grep -q "OB_NPM_REGISTRY.*build/deploy-to-qemu"'`
- Expected: 退出 0（三个锚点各自命中）

### Task 5: 最终验证 + checkpoint commit

- 目标：全量自检并提交。
- 涉及文件：`ob`、`lib/qemu_commands.sh`、`tests/protocol/test_qemu_surface.sh`（评审二轮 🟢）。
- 接口契约
  - Consumes: Task 1-4 产出。
  - Produces: 一个 commit。
- 验证范围：ob_check 全绿 + 两级 help 目视抽查 + 门禁化收尾命令。

- [ ] Step 1: ob_check 全量
- Run: `bash tools/ob_check.sh`
- Expected: 退出 0
- [ ] Step 2: 两级 help 门禁抽查（rc 归位）
- Run: `bash -c './ob --help >/dev/null && ./ob test-qemu --help >/dev/null && ./ob --help | grep -q "test-qemu romulus --suite smoke" && ./ob test-qemu --help | grep -q "^Prerequisites:" && ./ob test-qemu --help | grep -q "^Examples:" && ! ./ob test-qemu --help | grep -q "over argv flags"'`
- Expected: 退出 0（任一缺失则非 0，可见失败）
- [ ] Step 3: 提交边界检查（评审 🔴1：暂存区已有本计划文档 `A docs/plans/2026-08-24-...md`，不得混入本次 commit）
- Run: `git diff --cached --name-only && git status --short`
- Expected: 确认 staged 区内容；本 commit 只允许 `ob`、`lib/qemu_commands.sh`、`tests/protocol/test_qemu_surface.sh` 三个路径
- [ ] Step 4: checkpoint commit（路径限定，不吞暂存区其他文件）
- Run: `git add ob lib/qemu_commands.sh tests/protocol/test_qemu_surface.sh && git commit --only ob lib/qemu_commands.sh tests/protocol/test_qemu_surface.sh -m "docs(help): test-qemu help 补齐 Prerequisites/Examples + ob --help 命令文案 agent 化"`
- Expected: 提交成功且 `git show --name-only --format= HEAD` 只含上述三个文件（当前分支 `feature/smoke-merge-into-test-qemu`，非 main；计划文档保持 staged 不被提交）
- [ ] Step 5: 提交后核验（真否定门禁，评审二轮 🔴2）
- Run: `bash -c '! git show --name-only --format= HEAD | grep -q "^docs/plans/" && git diff --cached --name-only | grep -qx "docs/plans/2026-08-24-ob-help-test-qemu-implementation-plan.md"'`
- Expected: 退出 0 —— HEAD 不含任何 docs/plans/ 路径，且计划文档仍在暂存区。如需同时核验 HEAD 恰好只含三条允许路径，可加跑：`git show --name-only --format= HEAD | sort | diff -u <(printf "lib/qemu_commands.sh\nob\ntests/protocol/test_qemu_surface.sh\n" | sort) -`

## 执行纪律

- 开始实现前，先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行，不无声跳步、合并步或改变任务目标。
- 每完成一个任务，运行该任务定义的验证。
- 遇到阻塞、重复失败或计划与仓库现实不符（尤其 Task 4 的 env 消费方与坐实事实不符时），立即停下说明，不猜。
- 全部任务完成后，运行最终验证并输出修改摘要。

## 最终验证

- `bash tests/protocol/test_qemu_surface.sh` 退出 0（help surface 契约已锁入协议断言）。
- `bash tools/ob_check.sh` 退出 0（含 EXIT_RE、shellcheck baseline、测试）。
- Task 5 Step 2 的组合门禁命令退出 0。
- 人工抽查：`./ob --help` 与 `./ob test-qemu --help` 通读一遍，确认无 "exit code"（空格形式）新增文案、无明文密码。
- `git show --name-only --format= HEAD | sort | diff -u <(printf "lib/qemu_commands.sh\nob\ntests/protocol/test_qemu_surface.sh\n" | sort) -` 输出为空（HEAD 恰好只含三条允许路径，计划文档不被误提交）。

## 审阅 Checkpoint

- 计划正文结束。请审阅；通过后由普通编码 agent 或人工按任务执行。
