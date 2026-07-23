# npm passthrough 装配提取(apply_npm_registry)实施计划

## 目标

- 把 `cmd_build`(`lib/commands.sh`) 和 `cmd_deploy_to_qemu`(`lib/qemu_commands.sh`) 各自复制的一份 npm registry passthrough 装配逻辑，提取成 `lib/util.sh` 的 leaf-pure 函数 `apply_npm_registry`，两处调用点塌成 `resolve_npm_registry; apply_npm_registry` 两行。
- 消除 `qemu_commands.sh:353` 自标的"技术债:后续抽 build_obmc_image helper"复制粘贴。
- 给提取出的函数补 unit 单测，并登记进 coverage_matrix。

## 架构快照

- **现状**：`cmd_build`(commands.sh:342-358) 与 `cmd_deploy_to_qemu`(qemu_commands.sh:352-365) 各有一段近乎逐行相同的 npm passthrough 装配——消费 `resolve_npm_registry` 设的全局 `NPM_REGISTRY_RESOLVED`，非 `skip` 时 export 5 个 `npm_config_*` 并把变量名追加进 `BB_ENV_PASSTHROUGH_ADDITIONS`(前置保留)。两份已分叉:commands.sh 用多行 `if [[ -n ]]` + 带 `verbose ×2`;qemu_commands.sh 用单行 `[[ -n ]] &&` + 无 verbose。
- **本次方案**：提取 `apply_npm_registry` 到 `lib/util.sh`，紧跟 `resolve_npm_registry`(util.sh:311-385)。它是 `resolve_npm_registry`(决策)的对偶——apply 做"装配":内含 `skip` 早返回、export 5 变量、`_existing` 前置拼接、`verbose ×2` 诊断。两调用点塌成两行。
- **衔接**:`apply_npm_registry` 是 util.sh leaf-pure(与 `probe_npm_registry`/`resolve_npm_registry` 同族，npm 关注点收拢一处);消费 resolve 设的全局，不改变两调用点的 exit seam 性质(仍是 L1 `cmd_*` 编排)，只把内联装配换成函数调用。落点选 util.sh 而非 build_env.sh，依据是 locality 按概念族(probe/resolve/apply)归类，优于按副作用机制归类——probe/resolve 已在 util.sh，apply 同族同居，避免割裂。

## 全局约束

- **exit 契约**:`apply_npm_registry` 位于 `lib/util.sh`(leaf-pure module)，no-direct-exit，**不**进 `exit_contract.py` 的 `EXIT_EXCEPTIONS`(当前 = `{fn_quit, resolve_npm_registry, require_path}`;apply 不 exit 故不加)。两调用点 `cmd_build`/`cmd_deploy_to_qemu` 保持 exit seam，仍用 exit-code 契约值 0/1/2/3。
- **命名**:snake_case;函数 `apply_npm_registry`(与 `resolve_npm_registry` 对偶);测试 `tests/unit/npm_registry.sh`。
- **测试分层**:unit 层(零依赖、毫秒级、不碰网络)。apply 单测直接设全局 `NPM_REGISTRY_RESOLVED` 喂 apply，不调 `resolve_npm_registry`/`probe_npm_registry` 的网络 probe(两者当前零单测，属另一任务)。
- **改 ob/lib 后必跑** `tools/ob_check.sh` 配套自检。
- **文案**:`verbose` 受 `$VERBOSE` 控制(util.sh:16 `verbose()`,走 stdout);`apply_npm_registry` 不决定 exit-code/remedy，不打印 remedy line。
- **不立** CONTEXT.md npm 术语(apply 是实现函数，非领域概念，保 glossary 纯度);**不立** ADR(三条 gate 不全中:可逆、不 surprising、deletion test 已给明确判定)。
- 无版本/依赖/平台约束(纯 bash，linux/bash 环境)。

## 输入工件

- **设计来源**:本会话 `/pick-one-arch-task` → `/grill-with-docs` 的 grilling 共识(6 决策点锁定):scope=最小(只提取 passthrough 装配) / 落点=util.sh / 命名=apply_npm_registry / 封装=内含 skip 判断 + 带 verbose ×2 / 测试=skip·空 existing·非空 existing 三态 / 文档=只更 coverage_matrix + util.sh 注释。**评审后修订**:测试补第 4 态(空 registry,见 F2)→ 四态;态 3 注释措辞收敛(见 F1)。无独立 design doc，grilling 产出即设计依据。
- **术语参考**:`CONTEXT.md` function semantic layer / exit-code 契约 / test layer。
- **ADR**:不冲突 ADR-0011(deploy-to-qemu toplevel ownership)——deploy 调共享底层 `apply_npm_registry` 而非 `cmd_build`，仍符合"自带编排调底层 module"。

## 文件结构与职责

- **Create**: `tests/unit/npm_registry.sh` — `apply_npm_registry` leaf-pure 单测(3 态:skip / 空 existing / 非空 existing)。
- **Modify**: `lib/util.sh` — 新增 `apply_npm_registry`，紧跟 `resolve_npm_registry`(结尾 util.sh:385 `}` 之后、`read_kv_field` 注释之前)。
- **Modify**: `lib/commands.sh` — `cmd_build` 的 npm 段(342-358 resolve+if 块)替换为两行调用;保留 341 注释 `# === npm registry auto-detection ===`。
- **Modify**: `lib/qemu_commands.sh` — `cmd_deploy_to_qemu` 的 npm 段(352-365 resolve+技术债注释+if 块)替换为两行调用;删除 353 技术债注释;**不动** 376 的无关技术债(size/deploy 冗余)。
- **Modify**: `tools/coverage_matrix.md` — build 段补一行登记 `apply_npm_registry` → `unit/npm_registry.sh`。
- 边界稳定:两调用点仍是 L1 exit seam，只换实现不换职责;`resolve_npm_registry`/`probe_npm_registry` 不改。

## 任务清单

### Task 1: lib/util.sh 新增 apply_npm_registry(含 unit 单测)

- 目标:在 util.sh 实现 leaf-pure `apply_npm_registry`(消费 `NPM_REGISTRY_RESOLVED`，装配 npm passthrough)，并用 4 态单测钉死其行为(skip / 空 existing / 非空 existing / 空 registry)。
- Files:
  - Create: `tests/unit/npm_registry.sh`
  - Modify: `lib/util.sh`(符号锚点:`resolve_npm_registry` 结尾 `}` 即 util.sh:385 之后)
- 验证范围:`bash tests/unit/npm_registry.sh` 输出 `PASS=... FAIL=0` 且 rc=0。
- 接口契约:
  - Consumes: 全局 `NPM_REGISTRY_RESOLVED`(由调用点的 `resolve_npm_registry` 设置;单测里直接赋值)。
  - Produces: 函数 `apply_npm_registry`(lib/util.sh);文件 `tests/unit/npm_registry.sh`。后续 Task 2/3/4 消费此函数与测试文件。

- [ ] Step 1: 写失败单测 `tests/unit/npm_registry.sh`

```bash
#!/usr/bin/env bash
# tests/unit/npm_registry.sh — apply_npm_registry leaf-pure 单测(unit 层)。
# 消费 NPM_REGISTRY_RESOLVED 全局, 直接设值喂 apply, 不碰 resolve 的网络 probe
# (resolve_npm_registry/probe_npm_registry 当前零单测, 属另一任务)。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

VERBOSE=0
EXP_VARS="npm_config_registry npm_config_fetch_timeout npm_config_fetch_retry_maxtimeout npm_config_fetch_retry_mintimeout npm_config_fetch_retry_factor"
_out="${TMPDIR:-/tmp}/ob_npm_unit.out"

# --- 态 1: skip → return 0, 不污染环境, 无 stdout ---
unset npm_config_registry npm_config_fetch_timeout npm_config_fetch_retry_maxtimeout \
      npm_config_fetch_retry_mintimeout npm_config_fetch_retry_factor BB_ENV_PASSTHROUGH_ADDITIONS
NPM_REGISTRY_RESOLVED="skip"
apply_npm_registry >"$_out"
assert_eq "skip rc=0" "$?" 0
assert_eq "skip 无 stdout" "$(cat "$_out")" ""
assert_eq "skip: npm_config_registry 未 export" "${npm_config_registry+x}" ""
assert_eq "skip: BB_ENV_PASSTHROUGH_ADDITIONS 未设" "${BB_ENV_PASSTHROUGH_ADDITIONS+x}" ""

# --- 态 2: resolve + 空 existing → 5 变量 export + BB=_vars(无前缀) ---
unset npm_config_registry npm_config_fetch_timeout npm_config_fetch_retry_maxtimeout \
      npm_config_fetch_retry_mintimeout npm_config_fetch_retry_factor BB_ENV_PASSTHROUGH_ADDITIONS
NPM_REGISTRY_RESOLVED="https://reg.example.com/"
apply_npm_registry >"$_out"
assert_eq "resolve rc=0" "$?" 0
assert_eq "npm_config_registry export" "$npm_config_registry" "https://reg.example.com/"
assert_eq "npm_config_fetch_timeout" "$npm_config_fetch_timeout" "600000"
assert_eq "npm_config_fetch_retry_maxtimeout" "$npm_config_fetch_retry_maxtimeout" "120000"
assert_eq "npm_config_fetch_retry_mintimeout" "$npm_config_fetch_retry_mintimeout" "30000"
assert_eq "npm_config_fetch_retry_factor" "$npm_config_fetch_retry_factor" "2"
assert_eq "BB empty-existing(无前缀)" "$BB_ENV_PASSTHROUGH_ADDITIONS" "$EXP_VARS"

# --- 态 3: resolve + 非空 existing → BB="FOO BAR <vars>" ---
# 锁 existing 前置方式(existing 必须在 vars 前); 5 变量内部相对顺序由态 2(空 existing, BB==$EXP_VARS)字面锁定。
unset npm_config_registry BB_ENV_PASSTHROUGH_ADDITIONS
NPM_REGISTRY_RESOLVED="https://reg.example.com/"
BB_ENV_PASSTHROUGH_ADDITIONS="FOO BAR"
apply_npm_registry >"$_out"
assert_eq "nonempty rc=0" "$?" 0
assert_eq "BB existing 前置" "$BB_ENV_PASSTHROUGH_ADDITIONS" "FOO BAR $EXP_VARS"

# --- 态 4: resolve="" (空串, 等价 npm 默认 registry) → 仍装配 ---
# apply 判定是 != "skip"(非 [ -n ]), 空串 != skip 为真 → export 空 registry + BB 含 vars。
# 锁死"!= skip 即装配"语义, 防将来误改成 [ -n ] && != skip 导致空 registry 不装配(行为偏移无告警)。
unset npm_config_registry BB_ENV_PASSTHROUGH_ADDITIONS
NPM_REGISTRY_RESOLVED=""
apply_npm_registry >"$_out"
assert_eq "empty-registry rc=0" "$?" 0
assert_eq "空 registry 已 export(设但空)" "${npm_config_registry+x}" "x"
assert_eq "空 registry 值为空" "$npm_config_registry" ""
assert_eq "空 registry: BB 含 vars" "$BB_ENV_PASSTHROUGH_ADDITIONS" "$EXP_VARS"

assert_summary
```

- 注:用 `apply_npm_registry >"$_out"`(输出重定向,非 `$()`)在当前 shell 跑，export 副作用能回传;若用 `$(apply_npm_registry)` 子 shell 则 export 不回传，会误判。

- [ ] Step 2: 运行并确认失败(apply 尚未实现)
- Run: `bash tests/unit/npm_registry.sh`
- Expected: rc≠0，输出含 `FAIL`(`apply_npm_registry: command not found` 或多态 export 断言失败)。

- [ ] Step 3: 在 lib/util.sh 实现 apply_npm_registry(插在 `resolve_npm_registry` 结尾 `}` 即 util.sh:385 之后)

```bash
# Apply resolved npm registry to the current shell for bitbake passthrough.
# 对偶于 resolve_npm_registry(决策→装配): 消费 NPM_REGISTRY_RESOLVED, 非 "skip" 则
# export 5 个 npm_config_* 并把变量名追加进 BB_ENV_PASSTHROUGH_ADDITIONS(前置保留).
# leaf-no-exit; 前置: 调用者已 resolve_npm_registry. cmd_build / cmd_deploy_to_qemu 共享.
apply_npm_registry() {
    [[ "$NPM_REGISTRY_RESOLVED" != "skip" ]] || return 0
    export npm_config_registry="$NPM_REGISTRY_RESOLVED"
    export npm_config_fetch_timeout=600000
    export npm_config_fetch_retry_maxtimeout=120000
    export npm_config_fetch_retry_mintimeout=30000
    export npm_config_fetch_retry_factor=2
    local _vars="npm_config_registry npm_config_fetch_timeout npm_config_fetch_retry_maxtimeout npm_config_fetch_retry_mintimeout npm_config_fetch_retry_factor"
    local _existing="${BB_ENV_PASSTHROUGH_ADDITIONS:-}"
    BB_ENV_PASSTHROUGH_ADDITIONS="$_vars"
    [[ -n "$_existing" ]] && BB_ENV_PASSTHROUGH_ADDITIONS="$_existing $BB_ENV_PASSTHROUGH_ADDITIONS"
    export BB_ENV_PASSTHROUGH_ADDITIONS
    verbose "Exported npm config for bitbake passthrough"
    verbose "  npm_config_registry=$npm_config_registry"
}
```

- Change 1: 在 util.sh:385 `}` 与其后 `# Read first ...` 注释之间新增上述函数。
- Change 2: 更新 util.sh:2 顶部 module 注释，点明 npm registry 决策族(收拢术语漂移):
  - 旧: `# lib/util.sh — 底层通用工具(log/read_kv_field/require_path). 术语见 CONTEXT.md function semantic layer.`
  - 新: `# lib/util.sh — 底层通用工具(log/read_kv_field/require_path; npm registry 决策族 probe/resolve/apply). 术语见 CONTEXT.md function semantic layer.`

- [ ] Step 4: 运行并确认通过
- Run: `bash tests/unit/npm_registry.sh`
- Expected: rc=0，末行 `PASS=... FAIL=0`。

- [ ] Step 5: 可选 checkpoint commit
- Run: `git add lib/util.sh tests/unit/npm_registry.sh && git commit -m "feat(util): add apply_npm_registry leaf-pure npm passthrough + unit test"`
- Expected: commit 成功。

### Task 2: lib/commands.sh cmd_build 改调 apply_npm_registry

- 目标:把 `cmd_build` 的内联 npm passthrough 装配(commands.sh:342-358)替换为 `apply_npm_registry` 调用。
- Files: Modify `lib/commands.sh`(符号锚点:`cmd_build` 内 `# === npm registry auto-detection ===` 段)。
- 验证范围:commands.sh 无 `!= "skip"` 残留、有 `apply_npm_registry` 调用。
- 接口契约:
  - Consumes: `apply_npm_registry`(Task 1 产出，lib/util.sh)。
  - Produces: 无。

- [ ] Step 1: 确认当前残留(cmd_build 仍有内联 if-skip 块)
- Run: `grep -c '!= "skip"' lib/commands.sh`
- Expected: 输出 `1`(当前 1 处 if-skip 块待替换)。

- [ ] Step 2: 确认尚未调用 apply
- Run: `grep -c 'apply_npm_registry' lib/commands.sh`
- Expected: 输出 `0`。

- [ ] Step 3: 替换 cmd_build 的 npm 段

  将 commands.sh 中下面这段(保留其上方 `# === npm registry auto-detection ===` 注释):

```bash
    resolve_npm_registry
    if [[ "$NPM_REGISTRY_RESOLVED" != "skip" ]]; then
        export npm_config_registry="$NPM_REGISTRY_RESOLVED"
        export npm_config_fetch_timeout=600000
        export npm_config_fetch_retry_maxtimeout=120000
        export npm_config_fetch_retry_mintimeout=30000
        export npm_config_fetch_retry_factor=2
        local _npm_vars="npm_config_registry npm_config_fetch_timeout npm_config_fetch_retry_maxtimeout npm_config_fetch_retry_mintimeout npm_config_fetch_retry_factor"
        local _existing="${BB_ENV_PASSTHROUGH_ADDITIONS:-}"
        BB_ENV_PASSTHROUGH_ADDITIONS="$_npm_vars"
        if [[ -n "$_existing" ]]; then
            BB_ENV_PASSTHROUGH_ADDITIONS="$_existing $BB_ENV_PASSTHROUGH_ADDITIONS"
        fi
        export BB_ENV_PASSTHROUGH_ADDITIONS
        verbose "Exported npm config for bitbake passthrough"
        verbose "  npm_config_registry=$npm_config_registry"
    fi
```

  替换为:

```bash
    resolve_npm_registry
    apply_npm_registry
```

- Change: cmd_build npm 段从 17 行内联装配塌成 2 行函数调用。

- [ ] Step 4: 确认无残留 + 已调用
- Run: `! grep -q '!= "skip"' lib/commands.sh && grep -q 'apply_npm_registry' lib/commands.sh`
- Expected: rc=0(第一个 grep 找不到 if-skip 残留、`!` 反转为成功;第二个 grep 找到 apply 调用)。

### Task 3: lib/qemu_commands.sh cmd_deploy_to_qemu 改调 apply_npm_registry(删技术债注释)

- 目标:把 `cmd_deploy_to_qemu` 的内联 npm passthrough 装配(qemu_commands.sh:352-365)替换为 `apply_npm_registry` 调用，并删除 353 的"技术债"复制注释。
- Files: Modify `lib/qemu_commands.sh`(符号锚点:`cmd_deploy_to_qemu` 内 `resolve_npm_registry` 段)。
- 验证范围:qemu_commands.sh 无 `!= "skip"` 残留、有 `apply_npm_registry` 调用、353 技术债注释已删(376 无关技术债保留)。
- 接口契约:
  - Consumes: `apply_npm_registry`(Task 1 产出)。
  - Produces: 无。

- [ ] Step 1: 确认当前残留
- Run: `grep -c '!= "skip"' lib/qemu_commands.sh`
- Expected: 输出 `1`。

- [ ] Step 2: 确认技术债注释 353 在
- Run: `grep -c 'build_obmc_image helper' lib/qemu_commands.sh`
- Expected: 输出 `1`。

- [ ] Step 3: 替换 cmd_deploy_to_qemu 的 npm 段(含删技术债注释)

  将 qemu_commands.sh 中下面这段:

```bash
    resolve_npm_registry
    # npm vars export(复用 cmd_build :343-358, ~20 行; 技术债: 后续抽 build_obmc_image helper)
    if [[ "$NPM_REGISTRY_RESOLVED" != "skip" ]]; then
        export npm_config_registry="$NPM_REGISTRY_RESOLVED"
        export npm_config_fetch_timeout=600000
        export npm_config_fetch_retry_maxtimeout=120000
        export npm_config_fetch_retry_mintimeout=30000
        export npm_config_fetch_retry_factor=2
        local _npm_vars="npm_config_registry npm_config_fetch_timeout npm_config_fetch_retry_maxtimeout npm_config_fetch_retry_mintimeout npm_config_fetch_retry_factor"
        local _existing="${BB_ENV_PASSTHROUGH_ADDITIONS:-}"
        BB_ENV_PASSTHROUGH_ADDITIONS="$_npm_vars"
        [[ -n "$_existing" ]] && BB_ENV_PASSTHROUGH_ADDITIONS="$_existing $BB_ENV_PASSTHROUGH_ADDITIONS"
        export BB_ENV_PASSTHROUGH_ADDITIONS
    fi
```

  替换为:

```bash
    resolve_npm_registry
    apply_npm_registry
```

- Change:删技术债注释 + 14 行内联装配塌成 2 行。**不动** qemu_commands.sh:376 的无关技术债(size/deploy 冗余)。

- [ ] Step 4: 确认无残留 + 已调用 + 技术债注释已删
- Run: `! grep -q '!= "skip"' lib/qemu_commands.sh && grep -q 'apply_npm_registry' lib/qemu_commands.sh && ! grep -q 'build_obmc_image helper' lib/qemu_commands.sh`
- Expected: rc=0(无 if-skip 残留 + 有 apply 调用 + 353 技术债注释已删;376 无关技术债不含 `build_obmc_image helper` 故不影响)。

### Task 4: tools/coverage_matrix.md 登记 apply_npm_registry

- 目标:在 coverage_matrix build 段补一行，登记 `apply_npm_registry` 的覆盖归属。
- Files: Modify `tools/coverage_matrix.md`(章节锚点:`## build` 表格)。
- 验证范围:matrix 含 `apply_npm_registry` 与 `unit/npm_registry.sh`。
- 接口契约:
  - Consumes: `apply_npm_registry`(Task 1)、`tests/unit/npm_registry.sh`(Task 1)。
  - Produces: 无。

- [ ] Step 1: 确认当前未登记
- Run: `grep -c 'apply_npm_registry' tools/coverage_matrix.md`
- Expected: 输出 `0`。

- [ ] Step 2: 确认 0
- Run: `grep -c 'apply_npm_registry' tools/coverage_matrix.md`
- Expected: 输出 `0`。

- [ ] Step 3: 在 `## build` 表格末行(`进入 bitbake 环境 + bitbake handoff` 行)之后追加一行

```markdown
| npm registry passthrough 装配 | apply_npm_registry | unit/npm_registry.sh | leaf-pure(util.sh); cmd_build/cmd_deploy_to_qemu 共享; skip/空 existing/非空 existing/空 registry 四态 |
```

- Change:build 段新增 1 行登记。

- [ ] Step 4: 确认已登记
- Run: `grep -q 'apply_npm_registry' tools/coverage_matrix.md && grep -q 'unit/npm_registry.sh' tools/coverage_matrix.md`
- Expected: rc=0。

## 执行纪律

- 开始实现前，先批判性复查整份计划;若发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序(Task 1→2→3→4)执行，不要无声跳步、合并步或改变任务目标。Task 2/3/4 都依赖 Task 1 产出的 `apply_npm_registry`。
- 每完成一个任务，运行该任务 Step 4 的验证命令，确认 rc=0/预期输出再进下一个。
- 每个任务的 grep 验证都用 `grep -q` + `!` 反转形式，确保退出码正确归位(`grep -c` 输出 0 时 rc=1 会误判)。
- 遇到阻塞、重复失败或计划与仓库现实不符，立即停下来说明，不要猜。
- 当前分支 `feature/qemu-commands-extraction` 的 PR(#26)已 merge;开始实现前建议开新分支(如 `feature/npm-passthrough-extraction`)，或与用户确认分支策略。working tree 内 commit 是安全迭代手段。
- 改动 `lib/*.sh` 后，Task 4 完成必跑 `tools/ob_check.sh` 做配套自检(见最终验证)。

## 最终验证

- Run: `tools/ob_check.sh`
- Expected: 全部 `ok`——
  - extract_funcs: ob GAPS + lib 三段(header/函数间/footer)无违例
  - machine_state public surface gate: 通过
  - shellcheck baseline: 一致(无新增告警)
  - exit-contract: `Y: PASS`(apply_npm_registry 不 exit，util.sh leaf-pure 不破坏 Y 规则)
  - run_all: `ALL GREEN`(含新 `tests/unit/npm_registry.sh` 自动发现并跑过)
- 如 ob_check 任一段 `bad`，先修该段再继续;不要在 ob_check 红的情况下声称完成。

## 审阅 Checkpoint

- 计划正文结束。请先审阅这份计划(可交另一 agent 碰撞评审);如需修改，指出后我修订并重跑 inline 自检。
- 审阅通过前，不进入实现。批准后默认由普通编码 agent 或人工按 Task 1→4 顺序执行。
