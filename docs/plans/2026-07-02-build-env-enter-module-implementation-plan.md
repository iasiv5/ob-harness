# build_env_enter module（current-shell build environment）实施计划

## 目标

把散落在 3 处、近乎逐字相同的「`cd OPENBMC_DIR` + `source setup <machine> <build_dir>` + nounset save/restore」胶水，收口到新 module `lib/build_env.sh` 的单一函数 `build_env_enter`。消除复制、消除 `2>/dev/null` 在调用点间的漂移、把 build 路径「进入 BitBake 环境」这个零覆盖的关键动作变成可通过 interface 测试的对象。

收口后：3 个调用点各一行 `build_env_enter`；nounset 保护约定集中 1 处；`build_env_enter` 受 `exit_contract` 的 leaf-no-exit 守护；orchestration 层有用假 setup stub 驱动的行为测试；protocol 层有结构回归锁防内联 `source setup` 回潮。

## 架构快照

新建 `lib/build_env.sh`，承载 `current-shell build environment` 进入原语，与既有 `lib/bitbake_env.sh` 构成对偶：

- `bitbake_env.sh` = one-shot 查询，把 `source setup` 关在子进程 `( )` 里**隔离副作用**，pure、leaf-pure。
- `build_env.sh`（本计划）= current-shell 进入，`source setup` 的副作用（cwd 漂移到 build dir、shell 变量）**刻意留在当前 shell** 供后续 `bitbake` 消费，有副作用、leaf-no-exit。

对偶轴是「隔离 vs 泄漏」，术语已落 [CONTEXT.md](../../../CONTEXT.md) `current-shell build environment` 条目。

interface 形状（grill 已定）：

```bash
build_env_enter() {                    # lib/build_env.sh, leaf-no-exit
    local machine="$1" build_dir="$2"
    cd "$OPENBMC_DIR" || return 1
    local prev_opts
    prev_opts=$(set +o | grep nounset)
    set +u
    # shellcheck disable=SC1091
    source setup "$machine" "$build_dir"   # 返回码 silent；stderr 透传
    eval "$prev_opts"
}
```

- 显式传参 `<machine> <build_dir>`，与对偶的 [bitbake_env_query_vars](../../../lib/bitbake_env.sh) 同形；`$OPENBMC_DIR` 保持全局（session 级常量）。
- 返回码 silent：当前 custom setup（`workspace/openbmc/setup`）末尾 `iec-set-env` 污染返回码恒≈0；本仓 community/custom 两份 setup **抽样**上返回码不可靠，调用者统一查产物（[init_bitbake_env](../../../lib/init_pipeline.sh) 已用 `local.conf` 产物检查，是先例）。注意：此判断基于本仓两份 setup 抽样，**不表述为所有 OpenBMC tree 的普遍事实**——若未来接入返回码可靠的 tree，可在调用者侧加返回码检查。
- stderr 透传：module 内部不重定向，调用者按需 `build_env_enter ... 2>/dev/null`。`2>/dev/null` 的差异从此显式化为调用者选择（init 透传看首次输出、build/dep_graph 静默重进 banner 噪音）。

衔接：`ob` 入口用 `for f in lib/*.sh; do source "$f"; done`（[ob:70-73](../../../ob#L70)）glob 自动 source 新文件；`tools/ob_check.sh` 与 `tools/exit_contract.py` 都用 `lib/*.sh` glob 自动扫描（[ob_check.sh:15](../../../tools/ob_check.sh#L15)、[exit_contract.py:124](../../../tools/exit_contract.py#L124)）；`tests/run_all.sh` 用 `tests/$layer/*.sh` glob 自动发现新测试（[run_all.sh:27-28](../../../tests/run_all.sh#L27)）。**新建文件无需注册**，唯有 `exit_contract.py` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 要显式加 `build_env.sh`（check_Y 只查 dict 里的 basename，不加就不受守护）。

## 设计决策（评审参考）

本计划由 `improve-codebase-architecture` + `grill-with-docs` 会话确立。关键决策与被否决方案：

1. **形态：补全 module 的另一半，不是 DRY 提取**。否决「提取私有 helper」——这 5 行承载微妙不变量（nounset save/restore、副作用留当前 shell），值得术语+契约守护。
2. **归属：新建独立 module，不放宽 bitbake_env.sh 的 pure**。否决「放宽 bitbake_env pure→no-exit 把 enter 塞进去」——查询的 pure **机制根基**是子进程隔离副作用，enter 的本质是泄漏副作用，二者同 module 会挖掉查询侧根基（机制对立，非偏好）。此选择附带收益：bitbake_env.sh 的 leaf-pure 契约完全不动。
3. **命名**：canonical term `current-shell build environment`，文件 `lib/build_env.sh`，函数 `build_env_enter`（遵循 `<module>_<verb>` 约束，对偶 `bitbake_env_query_vars`）。
4. **签名**：显式传参，不依赖全局 `$MACHINE/$BUILD_DIR`（对偶一致 + 可测 + 缩小隐式耦合）。
5. **失败语义**：silent 返回码（custom 不可靠）+ stderr 透传。
6. **测试**：orchestration 行为测试 + protocol 结构回归锁（对齐 `machine_state`/`qemu profile` 两次收口的做法，[bestpractice_09](../../../rules/skills/bestpractice_09-nonfunctional_regression_locks.md)）。

**ADR 评估**：hard-to-reverse 偏弱（代码可 git 回滚）、surprising 成立（未来 explorer 易想合并这两个文件）、real trade-off 成立。按项目「ADR 严格卡门槛」原则，(1) 不过线，**不起 ADR**；split 理由由 [CONTEXT.md](../../../CONTEXT.md) 对偶条目承载。若评审认为 split 理由足够 surprising 值得防 re-litigate，可补轻 ADR。

## 输入工件

- 设计：本仓库 `improve-codebase-architecture` + `grill-with-docs` 会话（决策见上）。
- 术语：[CONTEXT.md](../../../CONTEXT.md) `current-shell build environment` / `BitBake environment support module`（已落）。
- 先例计划：[docs/plans/2026-07-02-bitbake-env-one-shot-implementation-plan.md](2026-07-02-bitbake-env-one-shot-implementation-plan.md)（one-shot 查询那一半，本计划是其对偶收口）。
- 事实依据：`workspace/openbmc/setup`（custom，含 `iec-set-env`）与 `ob-harness-community/workspace/openbmc/setup`（community）两份脚本行为差异。

## 文件结构与职责

- Create: `lib/build_env.sh` — `build_env_enter`，current-shell 构建环境进入原语（leaf-no-exit）。
- Create: `tests/orchestration/build_env_enter.sh` — 行为测试（假 setup stub，断言 cwd / source 执行 / nounset 恢复）。
- Create: `tests/protocol/build_env_enter_structure.sh` — 结构回归锁（三处调用点不再内联 `source setup`、`build_env_enter` 必含 `source setup`）。
- Modify: `lib/commands.sh` — `cmd_build` 的 source 胶水段（[commands.sh:382-390](../../../lib/commands.sh#L382)）。
- Modify: `lib/init_pipeline.sh` — `init_bitbake_env`（[init_pipeline.sh:120-130](../../../lib/init_pipeline.sh#L120)）与 `generate_dep_graph`（[init_pipeline.sh:188-196](../../../lib/init_pipeline.sh#L188)）两处胶水段。
- Modify: `tools/exit_contract.py` — `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 加 `build_env.sh`（[exit_contract.py:53](../../../tools/exit_contract.py#L53)）。
- Modify: `tools/coverage_matrix.md` — 登记 `build_env_enter` 覆盖归属。

边界保持稳定：`lib/bitbake_env.sh`、`ob` 入口、`tools/ob_check.sh`、`tests/run_all.sh` 不改。

## 任务清单

### Task 1: 新建 lib/build_env.sh 与 orchestration 行为测试

- 目标：用失败测试驱动 `build_env_enter` 的实现，验证三条副作用契约（cwd 漂移 / source 真执行 / nounset 恢复）。
- Files
  - Create: `tests/orchestration/build_env_enter.sh`
  - Create: `lib/build_env.sh`
- 验证范围：`bash tests/orchestration/build_env_enter.sh` 退出码 0、四条 assert 全过。

- [ ] Step 1: 写行为测试（当前会失败：`build_env_enter` 未定义）

  创建 `tests/orchestration/build_env_enter.sh`：

  ```bash
  #!/usr/bin/env bash
  # tests/orchestration/build_env_enter.sh — build_env_enter 行为测试(orchestration 层)。
  # 假 setup stub 验证 current-shell build environment 进入原语的副作用契约:
  #   1. cwd 漂移到 build_dir(模拟 setup 的 oe-init-build-env 行为)
  #   2. source setup 真执行(标记变量)
  #   3. nounset 状态被 save/restore
  source "$(dirname "$0")/../lib/assert.sh"
  assert_reset

  ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
  OB="$ROOT/ob"

  TMP="$(mktemp -d)"
  FAKE_OPENBMC="$TMP/openbmc"
  BUILD_DIR="$FAKE_OPENBMC/build/romulus"
  mkdir -p "$FAKE_OPENBMC"
  # 假 setup: 先断言 source 时 PWD==OPENBMC_DIR(锁 build_env_enter 的 cd 契约),
  # 再模拟 setup 的 mkdir build_dir + cd build_dir + 标记.
  # 单靠 PATH 命中 stub 不够: bash 从 PATH 找 setup 不依赖 cwd(cd / && PATH=<fake>
  # source setup 也命中), 必须在 stub 里断言 PWD 才能锁住 cd 契约.
  cat > "$FAKE_OPENBMC/setup" <<'SETUP'
  #!/usr/bin/env bash
  [[ "$PWD" == "$__EXPECTED_OPENBMC" ]] || { echo "WRONG_PWD=$PWD"; return 7; }
  __FAKE_SETUP_SOURCED=1
  mkdir -p "$2"
  cd "$2"
  SETUP
  chmod +x "$FAKE_OPENBMC/setup"

  out=$(PATH="$FAKE_OPENBMC:$PATH" __EXPECTED_OPENBMC="$FAKE_OPENBMC" bash -c '
  set -uo pipefail
  OB_NO_MAIN=1 source "$1"
  OPENBMC_DIR="$2"
  build_env_enter romulus "$3"
  echo "CWD=$PWD"
  echo "MARKER=${__FAKE_SETUP_SOURCED:-0}"
  case $- in *u*) echo "NOUNSET=1";; *) echo "NOUNSET=0";; esac
  ' _ "$OB" "$FAKE_OPENBMC" "$BUILD_DIR" 2>&1)

  assert_contains "enter cds into build dir"     "$out" "CWD=$BUILD_DIR"
  assert_contains "enter actually sourced setup" "$out" "MARKER=1"
  assert_contains "enter restores nounset"       "$out" "NOUNSET=1"
  if grep -q "WRONG_PWD" <<<"$out"; then
      _assert_bad "enter cds to OPENBMC_DIR first ($out)"
  else
      _assert_ok "enter cds to OPENBMC_DIR first"
  fi
  rm -rf "$TMP"

  assert_summary
  ```

- Run: `bash tests/orchestration/build_env_enter.sh`
- Expected: 失败——`build_env_enter: command not found`（`lib/build_env.sh` 尚不存在，ob 的 `lib/*.sh` glob source 不到它），`assert_summary` 报非 0 退出。

- [ ] Step 2: 运行并确认当前失败
- Run: `bash tests/orchestration/build_env_enter.sh; echo "rc=$?"`
- Expected: 输出含 `command not found` / assert 失败，`rc` 非 0。

- [ ] Step 3: 写最小实现

  创建 `lib/build_env.sh`（注意：lib 文件不得有顶层语句，仅 shebang + 注释 header + 函数定义，否则 [extract_funcs.py](../../../tools/extract_funcs.py) 三段检查报 GAPS）：

  ```bash
  #!/usr/bin/env bash
  # lib/build_env.sh — current-shell build environment 进入原语.
  # Leaf module: 函数绝不 exit (leaf-no-exit), 调用者负责 exit-code/remedy/诊断.
  # 有副作用 (cd OPENBMC_DIR + source setup), 刻意非 pure — 与 lib/bitbake_env.sh
  # 的子进程隔离查询对偶 (泄漏 vs 隔离). 术语见 CONTEXT.md `current-shell build environment`.

  build_env_enter() {
      local machine="$1" build_dir="$2"
      cd "$OPENBMC_DIR" || return 1
      local prev_opts
      prev_opts=$(set +o | grep nounset)
      set +u
      # shellcheck disable=SC1091
      source setup "$machine" "$build_dir"   # 返回码 silent (跨 community/custom 不可靠);
                                              # stderr 透传, 调用者按需 2>/dev/null
      eval "$prev_opts"
  }
  ```

- Change: 新建 `lib/build_env.sh`，提供 `build_env_enter`。

- [ ] Step 4: 运行并确认通过
- Run: `bash tests/orchestration/build_env_enter.sh; echo "rc=$?"`
- Expected: 四条 assert 全过，`rc=0`。

- [ ] Step 5: 可选 checkpoint commit
- Run: `git add lib/build_env.sh tests/orchestration/build_env_enter.sh && git commit -m "feat(build-env): 新增 build_env_enter current-shell 进入原语 + 行为测试"`
- Expected: commit 成功。

### Task 2: exit_contract 登记 build_env.sh 守护 leaf-no-exit

- 目标：让 `exit_contract.py` 的 Y 规则守护 `build_env.sh`（函数绝不 exit），与 `bitbake_env.sh`/`machine_state.sh` 同列。
- Files
  - Modify: `tools/exit_contract.py`（`LEAF_EXIT_EXCEPTIONS_BY_BASENAME`，[exit_contract.py:53](../../../tools/exit_contract.py#L53)）
- 验证范围：`python3 tools/exit_contract.py` 通过；故意在 `build_env_enter` 加一个 `exit 1` 能被 Y 规则抓到（验证守护生效，验毕移除）。

- [ ] Step 1: 写当前状态检查

  `exit_contract.py` 的 check_Y 只遍历 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 的 key。当前 `build_env.sh` 不在 dict，故未被守护——在 `build_env_enter` 里塞一个 `exit 1` 应该无人报错。

- Run: `sed -n '53,57p' tools/exit_contract.py`
- Expected: 当前 dict 只有 `bitbake_env.sh` / `util.sh` / `machine_state.sh` 三项，无 `build_env.sh`。

- [ ] Step 2: 运行并确认当前未守护
- Run:
  ```bash
  bak=$(mktemp); cp lib/build_env.sh "$bak"
  sed -i '/^[[:space:]]*source setup/a\    exit 1' lib/build_env.sh
  python3 tools/exit_contract.py >/tmp/ec.out 2>&1; rc=$?
  cp "$bak" lib/build_env.sh; rm -f "$bak"
  cat /tmp/ec.out; echo "exit_contract rc=$rc"
  test "$rc" -eq 0   # Step 2: build_env.sh 尚未登记, Y 规则不查, 期望 rc=0
  ```
- Expected: `exit_contract rc=0`、末尾 `test "$rc" -eq 0` 退出 0（`build_env.sh` 不在 dict，Y 规则根本不查它；即便把 `exit 1` 插进函数体也没人报）。
  - **关键（验证对象）**：`sed '/source setup/a\    exit 1'` 把 `exit 1` 插到 `build_env_enter` 函数体内 `source setup` 的下一行——这正是 Y 规则（`leaf_exiters`，只扫 extract_funcs 解析的函数体行范围）的扫描范围。用 `>>` 追加到文件末尾会落在函数体外（footer），那是 extract_funcs 的 FOOTER_TOPLEVEL 管，**不是** Y 规则，验证错了对象。
  - **关键（恢复方式）**：用 `cp "$bak"` 恢复而非 `git checkout`——Task 1 的 checkpoint 是「可选」，此时 `lib/build_env.sh` 可能仍 untracked，`git checkout` 无法恢复 untracked 文件，残留的 `exit 1` 会让 ob 后续 source `lib/*.sh` 时退出 shell。
  - **关键（退出码）**：整条命令以 `test "$rc" -eq 0` 收尾，最终退出码反映 `exit_contract` 真实结果；不能用 `... ; echo rc; cp` 收尾——最后是 `cp`（恒 0），终端工具看到的最终退出码仍是 0，会掩盖真实结果。

- [ ] Step 3: 写最小实现

  在 [exit_contract.py:53](../../../tools/exit_contract.py#L53) 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 字典加一项（与 `bitbake_env.sh`/`machine_state.sh` 并列，`set()` 表示允许 0 个 exit）：

  ```python
  LEAF_EXIT_EXCEPTIONS_BY_BASENAME = {
      'bitbake_env.sh': set(),
      'build_env.sh': set(),
      'util.sh': EXIT_EXCEPTIONS,
      'machine_state.sh': set(),
  }
  ```

  按字母序保持与现有风格一致。

- Change: `tools/exit_contract.py` 加 `'build_env.sh': set()`。

- [ ] Step 4: 运行并确认通过
- Run: `python3 tools/exit_contract.py; echo "rc=$?"`
- Expected: `rc=0`，Y 检查通过（`build_env_enter` 无 exit == 例外集 `set()`，对偶式成立）。

  另验证守护确实生效：
  ```bash
  bak=$(mktemp); cp lib/build_env.sh "$bak"
  sed -i '/^[[:space:]]*source setup/a\    exit 1' lib/build_env.sh
  python3 tools/exit_contract.py >/tmp/ec.out 2>&1; rc=$?
  cp "$bak" lib/build_env.sh; rm -f "$bak"
  cat /tmp/ec.out; echo "exit_contract rc=$rc"
  test "$rc" -ne 0   # 已登记 build_env.sh, 函数体内 exit 1 应被 Y 规则抓到
  ```
  期望 `exit_contract rc` 非 0、末尾 `test "$rc" -ne 0` 退出 0、输出含 `build_env.sh function unexpectedly exits`（`exit 1` 在 `build_env_enter` 函数体内）；`cp "$bak"` 还原（理由同 Step 2），整条以 `test` 收尾保证最终退出码反映真实结果。

- [ ] Step 5: 可选 checkpoint commit
- Run: `git add tools/exit_contract.py && git commit -m "feat(exit-contract): 把 build_env.sh 纳入 leaf-no-exit 守护"`
- Expected: commit 成功。

### Task 3: 三处调用点改用 build_env_enter

- 目标：把 `cmd_build` / `init_bitbake_env` / `generate_dep_graph` 三处内联的 cd+source+nounset 胶水，各替换为一行 `build_env_enter`。行为不变（含 DRY_RUN 路径）。
- Files
  - Modify: `lib/commands.sh`（`cmd_build`，[commands.sh:382-390](../../../lib/commands.sh#L382)）
  - Modify: `lib/init_pipeline.sh`（`init_bitbake_env` [init_pipeline.sh:120-130](../../../lib/init_pipeline.sh#L120)、`generate_dep_graph` [init_pipeline.sh:188-196](../../../lib/init_pipeline.sh#L188)）
- 验证范围：三处不再含行首内联 `source setup`；`ob build --dry-run`（无 machine 时 exit 3，需先有 init；用 smoke/exit_codes protocol 测试覆盖）；现有 protocol/orchestration 测试不退化。

- [ ] Step 1: 写当前状态检查

  当前三处都内联 `cd ...; prev_opts=...; set +u; source setup ...; eval`。

- Run: `grep -nE '^[[:space:]]*source[[:space:]]+setup' lib/commands.sh lib/init_pipeline.sh`
- Expected: 命中 3 行（[commands.sh:389](../../../lib/commands.sh#L389)、[init_pipeline.sh:129](../../../lib/init_pipeline.sh#L129)、[init_pipeline.sh:195](../../../lib/init_pipeline.sh#L195)）。注意 DRY_RUN 的 `info "[DRY-RUN] Would source setup ..."` 不在此 pattern（`source` 不在行首）。

- [ ] Step 2: 运行并确认当前状态
- Run: 同上
- Expected: 3 行命中。

- [ ] Step 3: 写最小实现

  **`lib/commands.sh` `cmd_build`**（[commands.sh:382-390](../../../lib/commands.sh#L382)），把整段：

  ```bash
      # === Re-enter bitbake environment ===
      cd "$OPENBMC_DIR"

      local prev_opts
      prev_opts=$(set +o | grep nounset)
      set +u
      # shellcheck disable=SC1091
      source setup "$MACHINE" "$BUILD_DIR" 2>/dev/null
      eval "$prev_opts"
  ```

  替换为：

  ```bash
      # === Re-enter bitbake environment ===
      build_env_enter "$MACHINE" "$BUILD_DIR" 2>/dev/null
  ```

  **`lib/init_pipeline.sh` `init_bitbake_env`**（[init_pipeline.sh:120-130](../../../lib/init_pipeline.sh#L120)），把：

  ```bash
      cd "$OPENBMC_DIR"

      # Use OpenBMC's official `source setup <machine>` to initialize the build environment.
      # This handles TEMPLATECONF, bblayers.conf, and local.conf correctly.
      # Temporarily disable nounset — setup sources oe-init-build-env which references unset vars.
      local prev_opts
      prev_opts=$(set +o | grep nounset)
      set +u
      # shellcheck disable=SC1091
      source setup "$MACHINE" "$BUILD_DIR"
      eval "$prev_opts"
  ```

  替换为（保留注释说明，stderr 透传——首次 init 想看 setup 输出助诊断）：

  ```bash
      # Use OpenBMC's official `source setup <machine>` to initialize the build environment.
      # build_env_enter handles TEMPLATECONF/bblayers/local.conf + nounset protection;
      # stderr 透传(首次 init 想看 setup 输出).
      build_env_enter "$MACHINE" "$BUILD_DIR"
  ```

  紧随其后的 `if [[ ! -f "$BUILD_DIR/conf/local.conf" ]]` verify（[init_pipeline.sh:133](../../../lib/init_pipeline.sh#L133)）保留不动——它是首次语义的产物检查，属 `init_pipeline` 职责，不下沉。

  **`lib/init_pipeline.sh` `generate_dep_graph`**（[init_pipeline.sh:188-196](../../../lib/init_pipeline.sh#L188)），把：

  ```bash
      cd "$OPENBMC_DIR"

      # Re-enter build environment (needed after cd)
      local prev_opts
      prev_opts=$(set +o | grep nounset)
      set +u
      # shellcheck disable=SC1091
      source setup "$MACHINE" "$BUILD_DIR" 2>/dev/null
      eval "$prev_opts"
  ```

  替换为：

  ```bash
      # Re-enter build environment (needed after cd)
      build_env_enter "$MACHINE" "$BUILD_DIR" 2>/dev/null
  ```

  注意：三处原先 `cd "$OPENBMC_DIR"` 由 `build_env_enter` 内部承担（它先 cd 再 source），调用点删除外部 cd 不影响后续——source 后 cwd 一律为 BUILD_DIR（setup 的 oe-init-build-env 行为），与原状一致。

- Change: 三处胶水段各收敛为一行 `build_env_enter` 调用。

- [ ] Step 4: 运行并确认通过
- Run:
  ```bash
  # 调用点回潮硬门禁: 命中内联 source setup 则 ! 失败、整段中止(不能只打印不拦)
  ! grep -nE '^[[:space:]]*source[[:space:]]+setup' lib/commands.sh lib/init_pipeline.sh
  bash tests/run_all.sh >/tmp/run_all.out 2>&1; rc=$?
  tail -20 /tmp/run_all.out
  echo "run_all rc=$rc"
  test "$rc" -eq 0
  ```
- Expected: `! grep` 通过（调用点 0 行命中，DRY_RUN 的 echo 不匹配该 pattern）；`run_all rc=0`、末尾 `test "$rc" -eq 0` 退出 0（protocol 含 `exit_codes.sh`/`smoke_ob.sh`，orchestration 含 `build_env_enter.sh`，无退化）。
  - **关键（grep 门禁）**：第一行必须是 `! grep`（或 `if grep ...; then exit 1; fi`）——裸 `grep` 命中时返回 0、只打印不中止，调用点没改干净也会漏过；用 `! grep` 把「命中」翻成失败，才是硬门禁。
  - **关键（退出码）**：不能用 `run_all.sh 2>&1 | tail` 形式——管道退出码是 `tail` 的（恒 0），会掩盖测试失败。必须把 `run_all.sh` 的退出码单独捕获。

- [ ] Step 5: 可选 checkpoint commit
- Run: `git add lib/commands.sh lib/init_pipeline.sh && git commit -m "refactor(build-env): 三处 current-shell enter 胶水收口到 build_env_enter"`
- Expected: commit 成功。

### Task 4: 新增 protocol 结构回归锁

- 目标：防收口后内联 `source setup` 胶水悄悄回潮，并锁住 `build_env_enter` 必须真正调用 `source setup`。对齐 [qemu_launch_profile_structure.sh](../../../tests/protocol/qemu_launch_profile_structure.sh) 的先例。
- Files
  - Create: `tests/protocol/build_env_enter_structure.sh`
- 验证范围：`bash tests/protocol/build_env_enter_structure.sh` 退出码 0。

- [ ] Step 1: 写当前状态检查

  Task 3 后，三处调用点函数体不应再含行首 `source setup`；`build_env_enter` 函数体应含 `source setup`。本任务把这个不变量钉成可回归断言。当前还没有这个锁文件。

- Run: `ls tests/protocol/build_env_enter_structure.sh 2>&1`
- Expected: 文件不存在。

- [ ] Step 2: 运行并确认当前缺失
- Run: 同上
- Expected: `No such file`。

- [ ] Step 3: 写最小实现

  创建 `tests/protocol/build_env_enter_structure.sh`（复用 [qemu_launch_profile_structure.sh](../../../tests/protocol/qemu_launch_profile_structure.sh) 的 `extract_shell_function` / `assert_function_*` 模式）：

  ```bash
  #!/usr/bin/env bash
  # tests/protocol/build_env_enter_structure.sh — build_env_enter 结构回归锁。
  # 防三处调用点内联 source setup 回潮, 锁 build_env_enter 必调 source setup.
  set -uo pipefail

  source "$(dirname "$0")/../lib/assert.sh"
  assert_reset

  ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
  COMMANDS_SH="$ROOT/lib/commands.sh"
  INIT_PIPELINE_SH="$ROOT/lib/init_pipeline.sh"
  BUILD_ENV_SH="$ROOT/lib/build_env.sh"

  extract_shell_function() {
      local file="$1" function_name="$2"
      awk -v fn="$function_name" '
          BEGIN { in_fn = 0; found = 0 }
          $0 ~ "^" fn "[(][)] [{$]" || $0 ~ "^" fn "[(][)]$" { in_fn = 1; found = 1; print; next }
          in_fn && $0 ~ "^[A-Za-z_][A-Za-z0-9_]*[(][)] [{$]" { in_fn = 0; exit }
          in_fn { print }
          END { if (!found) exit 42 }
      ' "$file"
  }

  assert_function_contains() {
      local label="$1" file="$2" function_name="$3" needle="$4" body
      body=$(extract_shell_function "$file" "$function_name") || {
          _assert_bad "$label (function '$function_name' not found)"; return; }
      assert_contains "$label" "$body" "$needle"
  }

  assert_function_not_match() {
      local label="$1" file="$2" function_name="$3" pattern="$4" body
      body=$(extract_shell_function "$file" "$function_name") || {
          _assert_bad "$label (function '$function_name' not found)"; return; }
      if rg -q "$pattern" <<< "$body"; then
          _assert_bad "$label (matched /$pattern/)"
      else
          _assert_ok "$label"
      fi
  }

  # 正向 regex helper(先例 qemu_launch_profile_structure.sh 只有 not_match/contains,
  # 正向 match 是本计划新增): 函数体匹配 pattern 才算通过.
  assert_function_match() {
      local label="$1" file="$2" function_name="$3" pattern="$4" body
      body=$(extract_shell_function "$file" "$function_name") || {
          _assert_bad "$label (function '$function_name' not found)"; return; }
      if rg -q "$pattern" <<< "$body"; then
          _assert_ok "$label"
      else
          _assert_bad "$label (no match /$pattern/)"
      fi
  }

  # 行首 source setup 命令级正则(DRY-RUN 的 echo 不在行首不误匹配; 要求 setup 后是空白/行尾, 排除 source setupx)
  INLINE_RE='^[[:space:]]*source[[:space:]]+setup([[:space:]]|$)'

  assert_function_not_match "cmd_build no inline source setup"          "$COMMANDS_SH"      cmd_build          "$INLINE_RE"
  assert_function_not_match "init_bitbake_env no inline source setup"   "$INIT_PIPELINE_SH" init_bitbake_env   "$INLINE_RE"
  assert_function_not_match "generate_dep_graph no inline source setup" "$INIT_PIPELINE_SH" generate_dep_graph "$INLINE_RE"
  # 正向锁: build_env_enter 必须真正调用 source setup(行首命令级, 排除注释/说明文字)
  assert_function_match "build_env_enter must call source setup"        "$BUILD_ENV_SH"     build_env_enter    "$INLINE_RE"

  # 缺失函数必须 fail, 不能返回空体骗过扫描
  if extract_shell_function "$BUILD_ENV_SH" __missing >/dev/null 2>&1; then
      _assert_bad "extract_shell_function missing target fails"
  else
      _assert_ok "extract_shell_function missing target fails"
  fi

  assert_summary
  ```

- Change: 新增结构回归锁，钉住「三处不内联 / build_env_enter 必调」。

- [ ] Step 4: 运行并确认通过
- Run: `bash tests/protocol/build_env_enter_structure.sh; echo "rc=$?"`
- Expected: 5 条 assert 全过，`rc=0`（3 条 not_match 锁调用点无回潮 + 1 条 match 锁 `build_env_enter` 必调 `source setup` + 1 条 missing-target 防空体骗过扫描）。

- [ ] Step 5: 可选 checkpoint commit
- Run: `git add tests/protocol/build_env_enter_structure.sh && git commit -m "test(build-env): 加 build_env_enter 结构回归锁防内联回潮"`
- Expected: commit 成功。

### Task 5: coverage_matrix 登记与最终 ob_check 自检

- 目标：把 `build_env_enter` 登记进覆盖 checklist；跑一站式自检确认 extract_funcs / shellcheck baseline / exit-contract / run_all 全清。
- Files
  - Modify: `tools/coverage_matrix.md`
- 验证范围：`tools/ob_check.sh` 全过（含 shellcheck baseline 处理）。

- [ ] Step 1: 写当前状态检查

  `coverage_matrix.md` 未登记 `build_env_enter`；新增的 `lib/build_env.sh` 会被 ob_check 的 shellcheck flat 合成纳入，可能触发 baseline 差异。

- Run: `grep -n build_env_enter tools/coverage_matrix.md; echo "rc=$?"`
- Expected: `rc=1`（未登记）。

- [ ] Step 2: 运行并确认当前缺失
- Run: 同上
- Expected: 无命中。

- [ ] Step 3: 写最小实现

  在 [tools/coverage_matrix.md](../../../tools/coverage_matrix.md) **新增**条目（当前 `build` 段只有「空 workspace→exit 3」「取消→exit 2」两行，**无「Run bitbake」行**，不要写成修改现有行）：

  - `build` 段**新增**一行（覆盖「进入 bitbake 环境 + 运行 bitbake」）：

    ```markdown
    | 进入 bitbake 环境 + run bitbake | build_env_enter;bitbake | orchestration/build_env_enter.sh;protocol/build_env_enter_structure.sh | build_env_enter=current-shell 进入; bitbake 失败由 cmd_build exit 1 兜 |
    ```

  - 「横切(通用)」段**新增**一行：

    ```markdown
    | current-shell build environment 进入 | build_env_enter | orchestration/build_env_enter.sh;protocol/build_env_enter_structure.sh | current-shell 副作用原语,leaf-no-exit |
    ```

  - `init` 段**新增**一行（当前 init 段无 `init_bitbake_env`/BitBake 环境初始化行，不要写成修改现有行）：

    ```markdown
    | BitBake 环境初始化 | init_bitbake_env;build_env_enter | orchestration/build_env_enter.sh;protocol/build_env_enter_structure.sh | local.conf 产物检查仍在 init_bitbake_env |
    ```

- Change: `coverage_matrix.md` 登记 `build_env_enter` 归属。

- [ ] Step 4: 运行并确认通过
- Run:
  ```bash
  tools/ob_check.sh >/tmp/ob_check.out 2>&1; rc=$?
  tail -30 /tmp/ob_check.out
  echo "ob_check rc=$rc"
  test "$rc" -eq 0
  ```
- Expected: `ob_check rc=0`、末尾 `test "$rc" -eq 0` 退出 0，全部 `ok`：
  - `extract_funcs ob GAPS=0`
  - `extract_funcs lib 三段全清(N 个 lib 文件)`（N 比之前 +1）
  - `machine_state public surface` 门禁无命中（与本改动无关，应仍清）
  - `shellcheck baseline` —— 若报「新增告警」：修 `build_env.sh` 代码；若报「良性差异（行号平移/告警减少）」：按提示手动确认或重生成 baseline 后 `git diff` 确认；若报「baseline 自动重生成」：`git diff tests/.shellcheck-baseline` 确认仅新增文件的合理差异后 commit。
  - `exit-contract` 通过
  - `run_all` 全过（含新 orchestration/protocol 测试）

- [ ] Step 5: 可选 checkpoint commit
- Run: `git add tools/coverage_matrix.md tests/.shellcheck-baseline && git commit -m "docs(build-env): coverage_matrix 登记 build_env_enter + shellcheck baseline"`
- Expected: commit 成功（baseline 视 Step 4 实际是否变化决定是否 add）。

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 当前在 `main` 分支：开始实现前与用户确认是否新建分支（`git checkout -b feature/build-env-enter-module`）。
- 按任务顺序执行，不无声跳步、合并步或改变任务目标。
- 每完成一个任务，运行该任务的验证命令。
- 三处调用点改动（Task 3）是行为保持的重构：若 `run_all.sh` 任一测试退化，立即停下核对（最可能是 DRY_RUN 路径或 cwd 依赖），不要靠删测试绕过。
- `build_env.sh` 不得有顶层语句（仅 shebang + 注释 + 函数定义），否则 extract_funcs 三段检查报 GAPS。
- 遇阻塞、重复失败或计划与仓库现实不符，立即停下说明，不猜。
- 全部任务完成后运行最终验证并输出修改摘要。

## 最终验证

- Run: `tools/ob_check.sh; echo "ob_check rc=$?"`
- Expected: `ob_check rc=0`，四项（extract_funcs / shellcheck baseline / exit-contract / run_all）全 `ok`。
- 附加确认：
  - Run: `grep -rc 'build_env_enter' lib/` —— `commands.sh`、`init_pipeline.sh`、`build_env.sh` 各有命中（调用点 + 定义）。
  - Run（调用点无回潮 + `source setup` 只在合法 module 内）:
    ```bash
    # 三处调用点 0 行(回潮则 grep 命中 → ! 失败)
    ! grep -nE '^[[:space:]]*source[[:space:]]+setup' lib/commands.sh lib/init_pipeline.sh
    # source setup 只允许出现在 build_env.sh(新增) 与 bitbake_env.sh(既有 one-shot 查询) 内部
    grep -nE '^[[:space:]]*source[[:space:]]+setup' lib/build_env.sh lib/bitbake_env.sh
    ```
    预期：第一条 `! grep` 通过（调用点 0 行）；第二条命中 `lib/build_env.sh`（`build_env_enter` 内 1 行）+ `lib/bitbake_env.sh`（`bitbake_env_list_available_machines`/`bitbake_env_query_vars` 各 1 行，既有 one-shot 查询，不改）。**不**用 `grep lib/*.sh` 再期待「仅 1 行」——既有 `bitbake_env.sh` 本就合法含 `source setup`。
- 预期结果：三处胶水收敛为 `build_env_enter` 调用，nounset 约定集中守护，build 路径「进入 BitBake 环境」从零覆盖变为可通过假 setup stub 测试。

## 审阅 Checkpoint

实施计划已写好并保存到 `docs/plans/2026-07-02-build-env-enter-module-implementation-plan.md`。请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行（用户已说明会另找 agent 评审，审阅通过后再进入实现）。
