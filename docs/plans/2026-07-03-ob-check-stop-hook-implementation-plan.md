# ob_check Stop Hook 自动门禁实施计划 (F3)

## 目标

- 把"改动 ob/lib 后跑 ob_check"从 `AGENTS.md:36` 的口头纪律升级为 harness 自动门禁：每轮 Claude Code 编辑结束时，若本轮触及 `ob` 或 `lib/*.sh`，自动跑 `tools/ob_check.sh`，失败则 block 并反馈让 Claude 继续修复，不再依赖 agent 自觉。

## 架构快照

- 本次方案：新建 `.claude/settings.json`（配 Stop hook）+ 新建 `.claude/hooks/ob-check-stop.sh`（过滤 + 跑 ob_check + JSON 反馈）。
- **选 Stop 而非 PostToolUse**（claude-code-guide 确认，来源 code.claude.com/docs/en/hooks）：(1) PostToolUse 每次 Edit 触发，n 次 Edit = n 次 ob_check，太重；(2) PostToolUse 的 exit 2 不能真阻断（工具已执行完），只有 Stop 的 `{decision:"block"}` 能让 Claude 停不下来、继续修复；(3) Stop 每轮一次，匹配"一批改完跑一次完整自检"语义。
- 文件路径过滤：matcher 只匹配 tool_name（`Edit|Write`），**不能匹配文件路径**。Stop 不支持 matcher（总是触发），脚本用 `git diff --name-only` 自行判断本轮是否触及 `ob`/`lib/*.sh`，未触及直接 exit 0。
- 失败反馈：脚本 exit 0 并打印 `{"decision":"block","reason":"ob_check 失败: <摘要>"}`；连续 block 上限 8 次。
- 衔接：复用现有 `tools/ob_check.sh`（不改）；`.claude/settings.json` 只服务 Claude Code，GitHub Copilot 不读它，互不影响。

## 输入工件

- 评审 finding F3（本次会话），落点：`.claude/settings.json`（当前不存在，`find .claude` 确认）、`AGENTS.md:36`（口头纪律）。
- 事实依据：claude-code-guide agent 本会话确认的 hook schema/语义（code.claude.com/docs/en/hooks）。
- 无独立设计文档。

## 评审决策点（交评审定）

- **D1**：触发事件。A（推荐）= Stop hook（每轮一次 + git diff 过滤）；B = PostToolUse（每次 Edit，async 轻量即时反馈但不能硬阻断）；C = A+B 叠加。
- **D2**：ob_check 跑全量还是静态子集。A = 全量 `tools/ob_check.sh`（含 run_all，实测 ~17s，hook 里太重）；B（推荐）= 静态子集 `OB_CHECK_SKIP_TESTS=1 OB_CHECK_READONLY=1`（extract_funcs + machine_state gate + shellcheck baseline + exit_contract，跳过 run_all，实测 ~3.6s；run_all 由 CI 兜底；READONLY 防 hook 改 baseline 文件）。
- **D3**：失败是 block 还是告警。A（推荐）= `decision:block`（逼修复）；B = `additionalContext`（告警不阻）。
- **D4**：timeout。静态子集建议 60s，全量 120s。

## 文件结构与职责

- Create：`.claude/settings.json`（Stop hook 配置，入库团队共享）。
- Create：`.claude/hooks/ob-check-stop.sh`（git diff 过滤 + 跑 ob_check + JSON 反馈，`chmod +x`）。
- 不改 `.gitignore`（本计划用入库的 settings.json，不用 settings.local.json）。

## 任务清单

### Task 1: 实测 ob_check 耗时，校准 D2/D4

- 目标：拿到全量与静态子集实测耗时，给 D2/D4 数据。
- Files：读 `tools/ob_check.sh`（无改动）。
- 验证范围：两组 real 时间。

- [ ] Step 1: 前置检查——ob_check 可跑
  - Run: `OB_CHECK_SKIP_TESTS=1 bash tools/ob_check.sh | tail -3`
  - Expected: 输出 `PASS=..`/`FAIL=..` 或 `ALL GREEN`。
- [ ] Step 2: 计时（实测静态子集 vs 全量）
  - Run: `echo "静态子集:"; time OB_CHECK_SKIP_TESTS=1 OB_CHECK_READONLY=1 bash tools/ob_check.sh >/dev/null 2>&1; echo "全量:"; time bash tools/ob_check.sh >/dev/null 2>&1`
  - Expected: 两组 real 时间。本会话实测：静态子集 ~3.6s、全量 ~17.4s（hook 用静态子集，全量留 CI）。
- [ ] Step 3: 无代码改动。
- [ ] Step 4: 据 D2 校准——静态子集 ~3.6s 在 Stop hook（每轮一次）可接受；D2=B（静态子集）为默认。

### Task 2: 写 .claude/hooks/ob-check-stop.sh

- 目标：实现 Stop hook 脚本（过滤 + 跑 ob_check + JSON 反馈）。
- Files：Create `.claude/hooks/ob-check-stop.sh`。
- 验证范围：无 ob/lib 改动 → exit 0 无输出；有改动且 ob_check 绿 → exit 0 无输出；有改动且 ob_check 失败 → exit 0 打印 decision:block。

- [ ] Step 1: 写失败检查——脚本不存在
  - Run: `ls .claude/hooks/ob-check-stop.sh 2>&1`
  - Expected: `No such file or directory`。
- [ ] Step 2: 确认缺失（同上）。
- [ ] Step 3: 创建脚本
  - Change：
    ```bash
    #!/usr/bin/env bash
    # .claude/hooks/ob-check-stop.sh — Stop hook: 本轮 working tree 若改 ob/lib/*.sh 则跑 ob_check。
    set -uo pipefail
    cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}" || exit 0
    # 本轮 working tree 改动(committed 已在 CI 跑过,不重复)
    changed=$(git diff --name-only; git diff --cached --name-only; git ls-files --others --exclude-standard 2>/dev/null)
    if ! grep -qE '(^|/)lib/[^/]+\.sh$|^ob$' <<<"$changed"; then
      exit 0   # 未触及 ob/lib,放行
    fi
    out=$(mktemp)
    # 默认静态子集:SKIP_TESTS 跳 run_all(省 ~14s) + READONLY 不改 baseline(hook 不应改文件)
    # D2=A 全量时去掉这两个环境变量
    if OB_CHECK_SKIP_TESTS=1 OB_CHECK_READONLY=1 bash tools/ob_check.sh >"$out" 2>&1; then
      rm -f "$out"; exit 0
    else
      summary=$(grep -E '✗|FAIL=' "$out" | head -5 | tr '\n' '; ')
      rm -f "$out"
      # D3=A: decision:block 让 Claude 继续修;D3=B 改用 hookSpecificOutput.additionalContext
      # python3 json.dumps 生成 JSON,防 summary 含引号/反斜杠破坏 JSON(评审 F3-2)
      python3 -c 'import json,sys; print(json.dumps({"decision":"block","reason":f"ob_check 失败(改了 ob/lib 须先过自检): {sys.argv[1]}"}, ensure_ascii=False))' "$summary"
      exit 0
    fi
    ```
    按 D2/D3 调整环境变量与 JSON 字段；`chmod +x .claude/hooks/ob-check-stop.sh`。
- [ ] Step 4: 本地模拟三种场景
  - Run:
    ```bash
    chmod +x .claude/hooks/ob-check-stop.sh
    # 场景1:无 ob/lib 改动 → exit 0 无输出
    CLAUDE_PROJECT_DIR=$(pwd) bash .claude/hooks/ob-check-stop.sh </dev/null; echo "rc1=$?"
    # 场景2:伪造 lib 改动(给真实 lib 文件加一行注释再还原),ob_check 应仍绿
    cp lib/util.sh /tmp/util.sh.bak
    echo "# hook-probe" >> lib/util.sh
    CLAUDE_PROJECT_DIR=$(pwd) bash .claude/hooks/ob-check-stop.sh </dev/null; echo "rc2=$?"
    cp /tmp/util.sh.bak lib/util.sh && rm -f /tmp/util.sh.bak
    ```
  - Expected: `rc1=0`（无输出）；`rc2=0`（ob_check 对一行注释仍绿，无 decision:block 输出）。
- [ ] Step 5: checkpoint commit
  - Run: `git add .claude/hooks/ob-check-stop.sh && git commit -m "feat(hook): 加 ob_check Stop hook 脚本(F3)"`
  - Expected: commit 成功。

### Task 3: 写 .claude/settings.json 配 Stop hook

- 目标：让 Claude Code 加载 Stop hook。
- Files：Create `.claude/settings.json`。
- 验证范围：JSON 合法 + `/hooks` 显示 Project 级 Stop hook。

- [ ] Step 1: 写失败检查——settings.json 不存在
  - Run: `ls .claude/settings.json 2>&1`
  - Expected: `No such file or directory`。
- [ ] Step 2: 确认缺失（同上）。
- [ ] Step 3: 创建 `.claude/settings.json`
  - Change：
    ```json
    {
      "hooks": {
        "Stop": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/ob-check-stop.sh",
                "args": [],
                "timeout": 60
              }
            ]
          }
        ]
      }
    }
    ```
    `args: []` 用 exec form 避免 `${CLAUDE_PROJECT_DIR}` 转义问题；timeout 按 D4（静态子集 60 / 全量 120）。
- [ ] Step 4: JSON 校验 + `/hooks` 确认
  - Run: `python3 -c "import json; json.load(open('.claude/settings.json')); print('json ok')"`
  - Expected: `json ok`。
  - 交互验证：Claude Code 内 `/hooks`，确认 Project 级出现 Stop → ob-check-stop.sh。
- [ ] Step 5: checkpoint commit
  - Run: `git add .claude/settings.json && git commit -m "feat(hook): 配置 ob_check Stop hook(F3)"`
  - Expected: commit 成功。

### Task 4: 端到端实测（真改 lib 触发 hook 反馈）

- 目标：真实 Claude Code 会话里改 `lib/*.sh`，确认 Stop hook 触发并按预期反馈。
- Files：临时改 lib（后还原）。
- 验证范围：违规时 hook block 反馈；还原后放行。

- [ ] Step 1: 前置检查——`/hooks` 可见 Project Stop hook。
- [ ] Step 2: 故意引入 ob_check 会抓到的违规（如在某 lib 文件函数之间加一行顶层非注释语句），观察本轮结束时 Stop hook 是否打印 `decision:block` 反馈。
  - 注：破坏性验证，验证完立即还原。
- [ ] Step 3: 还原 lib 改动（`git checkout -- lib/`）。
- [ ] Step 4: 确认——违规时 hook block；还原后再跑一轮，hook 放行（无 decision:block）。
- [ ] Step 5: 无 commit（验证 only，改动已还原）。

## 执行纪律

- JSON 输出必须经 `python3 json.dumps`（评审 F3-2）：`reason` 来自工具输出，含引号/反斜杠会破坏 JSON；不要用 `printf` 拼字符串。
- 本 hook 是 **working tree 级门禁，不是严格 per-turn**：`git diff` 看的是整个 working tree（含 cached/untracked），若仓库已有存量未提交的 ob/lib 改动，每轮 Stop 都会触发——这是已知行为，接受（评审 F3-2 指出）。
- 开始前复查；hook 脚本的 git diff 过滤逻辑必须用真实命令验证（Task 2 Step 4），不能假设 grep 正则。
- 失败 JSON 的 reason 用 `head -5` 截断，避免长输出吞 Claude 上下文。
- Stop hook `decision:block` 连续上限 8 次后强制结束——不要把 hook 设计成可能死循环（如 ob_check 持续失败时，Claude 8 轮后会停下，由人介入）。
- `settings.json` 入库团队共享；个人调试用 `settings.local.json` 并自行加入 `.gitignore`。
- 不影响 GitHub Copilot（不读 `.claude/settings.json`）。
- 若当前在 main，开始实现前先切分支。

## 最终验证

- Run：Claude Code 内 `/hooks` + `python3 -c "import json;json.load(open('.claude/settings.json'))"` + `CLAUDE_PROJECT_DIR=$(pwd) bash .claude/hooks/ob-check-stop.sh </dev/null; echo rc=$?`
- Expected：`/hooks` 显示 Project Stop hook；JSON 合法；无 ob/lib 改动时 rc=0 且无输出。

## 审阅 Checkpoint

- 计划正文结束。请评审对 F3 取舍：做 / 不做（F3 是 🟢 增强非缺陷）；若做，D1 选 A(Stop)/B(PostToolUse)/C(叠加)，D2 选 A(全量)/B(静态子集)，D3 选 A(block)/B(告警)，D4 timeout 取值。
