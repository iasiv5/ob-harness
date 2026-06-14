# ob start-qemu host key 冲突主动检测 实施计划

## 目标

在 `ob` 脚本的 `cmd_start_qemu()` 就绪循环之后、Connect 段之前，插入一段 SSH host key 冲突主动检测 + 交互清理逻辑：镜像重建后 `~/.ssh/known_hosts` 里 `[localhost]:<port>` 的旧 key 会和新镜像冲突，导致手动 ssh 被拒；本次让 `ob start-qemu` 自动命中冲突、展示 offending 行、Y/N 确认后用 `ssh-keygen -R` 清掉那一条（自带 `.old` 备份）。

## 架构快照

- 新增两个 bash 函数，放在 `cmd_start_qemu()` 定义（`ob:3424`）之前：
  - `parse_hostkey_offending`：纯解析器，从 ssh 的 changed-key stderr blob 抽 `Offending <TYPE> key in <file>:<line>`，输出 `<file> <line>` 或空。
  - `check_ssh_hostkey_conflict <port>`：编排函数，跑一条「镜像手动 ssh」探测（`BatchMode`、不带密码、走真实 `~/.ssh/known_hosts` + 默认严格校验），命中 `REMOTE HOST IDENTIFICATION HAS CHANGED` 则展示 + Y/N 清理。
- 在 `cmd_start_qemu()` 内插入一行调用 `check_ssh_hostkey_conflict "$ssh_port"`，位置：就绪循环 `fi`（`ob:3728`）之后、`# ── Print connection summary ──`（`ob:3730`）之前。该调用无论就绪探测成功/超时、无论 `--no-wait` 都会执行。
- 与现有就绪探测（`ob:3712-3713`，`UserKnownHostsFile=/dev/null`，对 host key 免疫）完全隔离，不合并、不改它。
- **`set -euo pipefail` 安全**（`ob:4`）：镜像探测和 `ssh-keygen -R` 都必然可能返回非零，每次调用必须包在 `if` / `|| rc=$?` 里，沿用 `ob:2945` 的 "wrap in if" 模式；所有新增变量先用 `local x=""` 初始化，避免 `set -u` 误伤。

## 输入工件

- 设计文档：`docs/specs/2026-06-14-ob-start-qemu-hostkey-detection-design.md`（已批准）
- 父功能实现计划（背景）：`docs/plans/2026-06-09-start-qemu-implementation-plan.md`

## 文件结构与职责

- Modify: `ob`（仓库根，单文件 bash 脚本）
  - 新增 `parse_hostkey_offending()` —— 锚点：`cmd_start_qemu() {`（`ob:3424`）之前
  - 新增 `check_ssh_hostkey_conflict()` —— 同上锚点之前，紧邻 `parse_hostkey_offending`
  - 修改 `cmd_start_qemu()` —— 锚点：`# ── Print connection summary ──` 注释（`ob:3730`）之前插入调用
- Test: 无独立测试文件。ob 是交互式编排脚本，验证用「抽取函数到临时 harness + stub `ssh` + 真实 `ssh-keygen` 操作临时 known_hosts」的离线方式，外加 `bash -n` / `shellcheck` 静态检查；BMC 行为矩阵放最终验证。

## 任务清单

### Task 1: 新增纯解析器 `parse_hostkey_offending`

- 目标：加一个纯函数，从 ssh changed-key 的 stderr 文本里抽出 offending 的 `<file>` 和 `<line>`，供编排函数使用。
- 涉及文件：Modify `ob` —— 在 `cmd_start_qemu() {`（`ob:3424`）之前插入新函数。
- 验证范围：抽取该函数到临时脚本，喂三段样本 stderr，断言解析结果正确。

- [ ] Step 1: 写当前状态检查
  - 该函数尚不存在。
  - Run: `grep -n '^parse_hostkey_offending()' ob || echo "NOT FOUND"`
  - Expected: `NOT FOUND`

- [ ] Step 2: 运行并确认失败
  - Run: 同上
  - Expected: `NOT FOUND`（确认尚未实现）

- [ ] Step 3: 写最小实现
  - Change: 在 `cmd_start_qemu() {`（`ob:3424`）之前插入：
  ```bash
  # Parse "Offending <TYPE> key in <file>:<line>" from an ssh changed-key stderr blob.
  # Stdout: "<file> <line>" on match; empty otherwise. Always exits 0 (pure parser,
  # safe under `set -euo pipefail`).
  parse_hostkey_offending() {
      local stderr_blob="$1"
      if [[ "$stderr_blob" =~ Offending\ [A-Z0-9]+\ key\ in\ ([^:]+):([0-9]+) ]]; then
          printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      fi
  }
  ```

- [ ] Step 4: 运行并确认通过
  - Run:
    ```bash
    bash -n ob
    source <(sed -n '/^parse_hostkey_offending()/,/^}/p' ob)
    parse_hostkey_offending "@@ Offending ED25519 key in /home/iasi/.ssh/known_hosts:6 @@"
    parse_hostkey_offending "Offending RSA key in /tmp/x/known_hosts:42"
    parse_hostkey_offending "Host key verification failed."
    ```
  - Expected:
    - `bash -n ob` 无输出（语法通过）。
    - 第 1 行输出 `/home/iasi/.ssh/known_hosts 6`。
    - 第 2 行输出 `/tmp/x/known_hosts 42`。
    - 第 3 行无输出（空）。

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add ob && git commit -m "feat(ob): add parse_hostkey_offending helper for SSH host-key conflict detection"`
  - Expected: commit 成功

### Task 2: 新增编排函数 `check_ssh_hostkey_conflict`

- 目标：加编排函数，跑镜像探测 → 仅在 changed-key 冲突时展示 offending 行 + 清理命令 → Y/N 确认后执行 `ssh-keygen -R`；sshd 不可达给通用提示；其它情况静默。支持非交互（stdin EOF 时跳过、只打印命令）。
- 涉及文件：Modify `ob` —— 在 `parse_hostkey_offending` 之后、`cmd_start_qemu() {`（`ob:3424`）之前插入。
- 验证范围：抽取两个函数到临时 harness，stub `ssh` 模拟 changed-key / Permission denied / 不可达，喂 `y` / `n` / `/dev/null` 驱动 Y/N 与非交互分支，让真实 `ssh-keygen` 操作临时 known_hosts，断言每个分支的输出与文件副作用。

- [ ] Step 1: 写当前状态检查
  - Run: `grep -n '^check_ssh_hostkey_conflict()' ob || echo "NOT FOUND"`
  - Expected: `NOT FOUND`

- [ ] Step 2: 运行并确认失败
  - Run: 同上
  - Expected: `NOT FOUND`

- [ ] Step 3: 写最小实现
  - Change: 在 `parse_hostkey_offending` 之后插入（`set -euo pipefail` 安全，所有外部命令都包在 `if`/`|| rc=$?`，所有 `local` 先初始化）：
  ```bash
  # Detect a stale SSH host key for [localhost]:<port> in the user's real
  # known_hosts and offer to clear it. Runs ONE mirror ssh probe (BatchMode, no
  # password): host-key check happens before auth, so no password is needed.
  # Silent unless a *changed*-key conflict is found. Safe under `set -euo pipefail`.
  # Args: $1 = ssh_port
  check_ssh_hostkey_conflict() {
      local port="$1"
      [[ -z "$port" ]] && return 0

      local target="[localhost]:${port}"
      local probe_out="" parsed=""
      local file="" line=""
      local display_cmd="" confirm=""
      local rc=0

      # Mirror the user's manual ssh: real known_hosts, default strict checking.
      # Wrap in 'if' so set -e does not propagate ssh's non-zero exit (host-key
      # failure / Permission denied / unreachable are all expected here).
      if ! probe_out=$(ssh -o BatchMode=yes -o ConnectTimeout=3 \
                          -p "$port" root@localhost true 2>&1); then
          :
      fi

      # Only a *changed* key is a conflict worth acting on.
      if [[ "$probe_out" != *"REMOTE HOST IDENTIFICATION HAS CHANGED"* ]]; then
          if [[ "$probe_out" == *"Connection refused"* || "$probe_out" == *"Connection timed out"* ]]; then
              warn "BMC sshd not reachable on port ${port}; if you rebuilt the image and manual ssh later reports a host key error, run: ssh-keygen -R '[localhost]:${port}'"
          fi
          return 0
      fi

      parsed=$(parse_hostkey_offending "$probe_out")
      if [[ -n "$parsed" ]]; then
          read -r file line <<< "$parsed"
      fi

      warn "Stale SSH host key for ${target} in your known_hosts (image rebuilt -> host key regenerated); manual ssh will be rejected."
      if [[ -n "$file" && -n "$line" ]]; then
          echo "    Offending entry (${file}:${line}):"
          sed -n "${line}p" "$file" 2>/dev/null | sed 's/^/      /' || true
          display_cmd="ssh-keygen -f \"${file}\" -R \"${target}\""
      else
          display_cmd="ssh-keygen -R \"${target}\""
      fi
      echo "    Removes only the ${target} entry; original backed up as known_hosts.old."
      echo "    Clear command: ${display_cmd}"

      if ! command -v ssh-keygen >/dev/null 2>&1; then
          warn "ssh-keygen not found; run the clear command above manually."
          return 0
      fi

      if ! read -r -p "$(echo -e "${PROMPT_PREFIX} Type (Y/y) to clear the stale key, anything else to skip: ")" confirm; then
          info "Non-interactive mode; run the clear command above manually."
          return 0
      fi

      case "$confirm" in
          [Yy]*)
              if [[ -n "$file" ]]; then
                  ssh-keygen -f "$file" -R "$target" >/dev/null 2>&1 || rc=$?
              else
                  ssh-keygen -R "$target" >/dev/null 2>&1 || rc=$?
              fi
              if [[ "$rc" -eq 0 ]]; then
                  info "Cleared stale host key for ${target} (backup: known_hosts.old)."
              else
                  warn "ssh-keygen -R exited ${rc}; run the clear command above manually."
              fi
              ;;
          *)
              info "Skipped. Run manually: ${display_cmd}"
              ;;
      esac
  }
  ```

- [ ] Step 4: 运行并确认通过
  - Run（离线 harness，stub `ssh`，真实 `ssh-keygen` 操作临时文件）：
    ```bash
    set +e
    # 临时 known_hosts，含一条陈旧 [localhost]:2222
    KH=$(mktemp); printf '[localhost]:2222 ssh-ed25519 AAAAstale==\ngithub.com ssh-ed25519 AAAAgit==\n' > "$KH"
    KH_LINE=$(grep -n '\[localhost\]:2222' "$KH" | cut -d: -f1)
    # stub：ssh 不真正连，按 STUB_STDERR 模拟 BMC 侧报错
    STUB_STDERR="REMOTE HOST IDENTIFICATION HAS CHANGED! Offending ED25519 key in ${KH}:${KH_LINE}"
    ssh() { printf '%s\n' "$STUB_STDERR" >&2; return 255; }
    # 需要的 helper stub（ob 真实定义在别处，harness 里给最小实现）
    info() { echo "[INFO] $*"; }
    warn() { echo "[WARN] $*"; }
    PROMPT_PREFIX='ob>'
    # 抽取两个新函数
    source <(sed -n '/^parse_hostkey_offending()/,/^}/p;/^check_ssh_hostkey_conflict()/,/^}/p' ob)

    echo "--- A) Y 清理 ---"; echo y | check_ssh_hostkey_conflict 2222
    echo "--- 文件副作用 ---"
    grep -c '\[localhost\]:2222' "$KH"          # 期望 0（陈旧行已删）
    ls -1 "${KH}.old"                            # 期望备份存在
    grep -q 'github.com' "$KH" && echo "A github-preserved OK"
    ```
  - Expected：
    - 输出含 `[WARN] Stale SSH host key for [localhost]:2222`、`Offending entry`、`Cleared stale host key`。
    - `grep -c` 输出 `0`（陈旧行已删）。
    - `${KH}.old` 存在（备份生成）。
    - 打印 `A github-preserved OK`（爆炸半径受控，`github.com` 行保留）。
  - 再分别验证其余分支：
    ```bash
    # B) 跳过：输入 n，文件不变
    printf '[localhost]:2222 ssh-ed25519 AAAAstale==\n' > "$KH"
    echo n | check_ssh_hostkey_conflict 2222 | grep -q "Skipped" && echo "B OK"
    grep -q '\[localhost\]:2222' "$KH" && echo "B file-unchanged OK"
    # C) 非交互：stdin = /dev/null
    check_ssh_hostkey_conflict 2222 </dev/null | grep -q "Non-interactive" && echo "C OK"
    # D) 静默（无冲突）：ssh 模拟 Permission denied
    STUB_STDERR="root@localhost: Permission denied (publickey,password)."; ssh() { printf '%s\n' "$STUB_STDERR" >&2; return 255; }
    out=$(check_ssh_hostkey_conflict 2222); [[ -z "$out" ]] && echo "D silent OK"
    # E) 不可达提示：ssh 模拟 Connection refused
    STUB_STDERR="ssh: connect to host localhost port 2222: Connection refused"; ssh() { printf '%s\n' "$STUB_STDERR" >&2; return 255; }
    check_ssh_hostkey_conflict 2222 | grep -q "sshd not reachable" && echo "E OK"
    rm -f "$KH" "${KH}.old"
    ```
  - Expected：依次看到 `B OK` / `B file-unchanged OK` / `C OK` / `D silent OK` / `E OK`。

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add ob && git commit -m "feat(ob): add check_ssh_hostkey_conflict orchestrator for host-key conflict"`
  - Expected: commit 成功

### Task 3: 在 `cmd_start_qemu` 插入调用

- 目标：在就绪循环之后、Connect 段之前调用 `check_ssh_hostkey_conflict "$ssh_port"`，让检测在每次 `ob start-qemu`（含 `--no-wait`）收尾时生效。
- 涉及文件：Modify `ob` —— `cmd_start_qemu()` 内，锚点 `# ── Print connection summary ──`（`ob:3730`）之前。
- 验证范围：语法通过；调用点存在且唯一；`$ssh_port` 在该作用域可用（已在就绪循环 `ob:3712` 与 Connect 段 `ob:3735` 使用）。

- [ ] Step 1: 写当前状态检查
  - Run: `grep -n 'check_ssh_hostkey_conflict "\$ssh_port"' ob`
  - Expected: 无输出（调用尚未插入）

- [ ] Step 2: 运行并确认失败
  - Run: 同上
  - Expected: 无输出

- [ ] Step 3: 写最小实现
  - Change: 在 `cmd_start_qemu()` 内、就绪循环 `fi`（`ob:3728`）之后、`# ── Print connection summary ──`（`ob:3730`）之前插入：
  ```bash
      # ── Detect stale SSH host key (image rebuild regenerates host keys) ──
      check_ssh_hostkey_conflict "$ssh_port"
  ```
  - 说明：该位置在 `if [[ "$QEMU_NO_WAIT" -eq 0 ]]; then ... fi` 之外，因此 `--no-wait` 也会执行；`$ssh_port` 在本函数作用域内已定义。

- [ ] Step 4: 运行并确认通过
  - Run:
    ```bash
    bash -n ob
    grep -n 'check_ssh_hostkey_conflict "\$ssh_port"' ob
    ```
  - Expected：
    - `bash -n ob` 无输出（语法通过）。
    - grep 命中恰好一行，位于 `ob:3728` 与 `ob:3730` 之间。

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add ob && git commit -m "feat(ob): wire host-key conflict check into start-qemu tail"`
  - Expected: commit 成功

## 执行纪律

- 开始实现前先复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行，不要无声跳步、合并步或改变任务目标。
- 每完成一个任务都运行该任务定义的验证；`bash -n ob` 是每个 Task Step 4 的最低门槛。
- 任何外部命令（`ssh` / `ssh-keygen`）在 `set -euo pipefail` 下都可能返回非零，必须沿用 `if` / `|| rc=$?` 包裹，参照 `ob:2945` 模式；不要写成裸调用。
- 遇到阻塞（如 `shellcheck` 未安装、或最终验证缺真实镜像/QEMU），立即停下说明，不要猜、不要伪造结果。
- 若当前在 `main` 分支且用户未明确同意，开始实现前先确认分支策略。

## 最终验证

前置环境：最终验证的 A–E 需要一条已构建的 BMC 镜像 + 可用的 QEMU binary（`ob start-qemu` 的常规前置）。若当前环境不具备，完成 Task 1–3 + 下面的静态检查后停下，把 A–E 交给具备环境者执行。

静态检查（无环境依赖，必跑）：
- Run: `bash -n ob`
- Expected: 无输出（语法通过）。
- Run: `shellcheck ob 2>/dev/null | sed -n '/parse_hostkey_offending\|check_ssh_hostkey_conflict/,+5p'` 或 `shellcheck ob`（若已安装）
- Expected: 新增两个函数无 error 级告警（style/warning 可接受）。
- Run: `grep -c 'check_ssh_hostkey_conflict "\$ssh_port"' ob`
- Expected: `1`（调用点存在且唯一）。

行为矩阵（A–E，需镜像 + QEMU；对应设计文档「测试策略」）：

| # | 场景 | 命令 | 期望 |
|---|---|---|---|
| A | 重建镜像后连接 | 重建 image → `./ob start-qemu <machine>` | 命中冲突，展示 offending 行，输入 `y` 后清理，`~/.ssh/known_hosts.old` 生成，随后 `ssh root@localhost -p 2222`（密码 `0penBmc`）直通 |
| B | 镜像未重建 | `./ob start-qemu <machine>`（known_hosts 里 key 与当前镜像一致） | 无 host key 相关输出、无 Y/N，输出与改动前一致 |
| C | 首次连接 | 删掉 `~/.ssh/known_hosts` 里 `[localhost]:2222` 条目后 `./ob start-qemu <machine>` | 无 host key 相关输出、无 Y/N |
| D | `--no-wait` + sshd 已起 | `./ob start-qemu <machine> --no-wait`（sshd 已监听） | 仍检测；若命中冲突走交互清理 |
| E | 非交互 | `./ob start-qemu <machine> --no-wait </dev/null`（或管道喂入） | 不改 `~/.ssh/known_hosts`，打印清理命令供手动执行 |

完成全部静态检查 + 可执行的 A–E 后，输出修改摘要（新增函数、调用点、命中分支）。

## 审阅 Checkpoint

实施计划已写好并保存到 `docs/plans/2026-06-14-ob-start-qemu-hostkey-detection-implementation-plan.md`。请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行。
