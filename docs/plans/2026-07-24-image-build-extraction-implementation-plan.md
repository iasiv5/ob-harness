# obmc-phosphor-image build module 抽取实施计划

## 目标

把 `cmd_build`（[lib/commands.sh](../../lib/commands.sh)）和 `cmd_deploy_to_qemu`（[lib/qemu_commands.sh](../../lib/qemu_commands.sh)）各自内联的 obmc-phosphor-image 构建编排（`build_env_enter → resolve_npm_registry → apply_npm_registry → bitbake obmc-phosphor-image`）抽取为共享深 module `lib/image_build.sh::build_obmc_image`，消除两处重复、统一 build 逻辑防漂移，补齐 ADR-0011 预期但缺失的 build 侧深 module（QEMU 侧已有 `qemu_prepare_launch`/`qemu_execute_launch` 物化）。

## 架构快照

- 新建 `lib/image_build.sh`（leaf-pure module），单一 public 函数 `build_obmc_image <machine> <build_dir>`，封装四步并 return bitbake rc（0/非0）。
- `cmd_build` 与 `cmd_deploy_to_qemu` 各自把内联四步替换为一行 `build_obmc_image` 调用；展示（header/info/成功失败文案）与 exit-1 收口都留在 L1 `cmd_*`。
- 与现有结构衔接：复用 `build_env_enter`（[lib/build_env.sh](../../lib/build_env.sh)）、`resolve_npm_registry`/`apply_npm_registry`（[lib/util.sh](../../lib/util.sh)）；`ob` 顶部 `for f in lib/*.sh; source`（[ob:73](../../ob#L73)）自动加载新文件，无需改 source 循环。
- 形态对照：与 `bare_mirror.sh` 等 bestpractice_10 抽取族同构（leaf-pure 深 module + exit_contract Y 白名单 + surface gate 防回潮）。

## 全局约束

- **leaf-pure**：`build_obmc_image` 绝不 exit，return rc；`exit_contract.py` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 登记 `'image_build.sh': set()`；exit-1 收口由 L1 `cmd_*` owns。
- **行为不变**：`cmd_build`/`cmd_deploy_to_qemu` 对外行为（stdout 展示、exit-1 诊断、DRY-RUN 短路、bitbake stdout/stderr 透传）全部不变；既有 orchestration 测试（`cmd_build_bitbake_handoff.sh`、`deploy_to_qemu.sh`）作字节级行为金标回归锁。
- **ADR-0011 零重构**：不违背——抽共享底层 module 正是 ADR-0011 第 9/19 行预期的「通用底层 module」物化，不重构 `cmd_*` 的命令级语义。
- **DRY-RUN**：两调用点均在 module 入口前短路（[commands.sh:332](../../lib/commands.sh#L332) / [qemu_commands.sh:309](../../lib/qemu_commands.sh#L309)），module 不处理 DRY-RUN。
- **`build_env_enter` 最小检查**：module 内 `build_env_enter ... || return 1`，防 `if build_obmc_image` 条件形态下 errexit 关闭上下文里 enter 失败静默继续到 bitbake 坏环境（strict-mode 静默吞陷阱）；`resolve_npm_registry`/`apply_npm_registry` 保持现状不检查（非 fs 操作，现状未检查）。
- **`build_env_enter ... 2>/dev/null` 吞 setup stderr 是既有行为**：与 [commands.sh:339](../../lib/commands.sh#L339) / [qemu_commands.sh:351](../../lib/qemu_commands.sh#L351) 现状一致（[build_env.sh:12](../../lib/build_env.sh#L12) 注释「stderr 透传，调用者按需 2>/dev/null」），本次抽取原样搬移，不修也不恶化——若未来要诊断 enter 失败需另立任务。
- **exit_contract Y 双向检查**（[exit_contract.py:208-214](../../tools/exit_contract.py#L208-L214)）：`image_build.sh: set()` 登记后，若 `build_obmc_image` 内意外混入 `exit` 会立即 FAIL（真实exit不在例外集 → FAIL，正向保护）；**FAIL 时删 module 内 exit，不要改例外集去消告警**。
- **coverage 基线不涨**：当前 CI `--fail-if-uncovered 7`（[ob-tests.yml:28](../../.github/workflows/ob-tests.yml#L28)）；新函数 `build_obmc_image` 必须被 unit 命中，uncovered 保持 ≤7。
- 无版本/平台/文案额外约束。

## 输入工件

- grilling 共识（6 决策点，2026-07-24 本会话）：seam=四步+return rc、落点=新 lib/image_build.sh、展示完全留 L1、失败语义=return rc+enter 最小检查、测试=unit stub+surface gate、术语=obmc-phosphor-image build module。
- 设计背景：[docs/specs/2026-07-20-ob-deploy-to-qemu-design.md:383](../specs/2026-07-20-ob-deploy-to-qemu-design.md#L383)（YAGNI 留的技术债，apply_npm_registry 抽取是前序切片）。
- 已落术语：[CONTEXT.md](../../CONTEXT.md) `obmc-phosphor-image build module`；[rules/03_WORKSPACE.md](../../rules/03_WORKSPACE.md) `lib/` 路由已登记 `image_build.sh`。

## 文件结构与职责

- Create: `lib/image_build.sh` — `build_obmc_image` leaf-pure module（enter+npm+bitbake，return rc）。
- Create: `tests/unit/image_build.sh` — unit 单测（stub build_env_enter/resolve/apply + PATH fake bitbake，覆盖成功/失败/enter失败三态）。
- Modify: `lib/commands.sh` — `cmd_build` 四步内联（L338-351）替换为 `build_obmc_image` 调用。
- Modify: `lib/qemu_commands.sh` — `cmd_deploy_to_qemu` 四步内联（L346-355）替换为 `build_obmc_image` 调用。
- Modify: `tools/exit_contract.py` — `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 加 `'image_build.sh': set()`（L53-72 dict）。
- Modify: `tools/ob_check.sh` — 加 `1c-quin` surface gate（锁除 image_build.sh 外无直调 `bitbake obmc-phosphor-image`）。

接口契约：Task 1 产出 `build_obmc_image`（Consumes `build_env_enter`/`resolve_npm_registry`/`apply_npm_registry`/`bitbake`，Produces 函数 `build_obmc_image`）；Task 3/4 消费 `build_obmc_image`；Task 5 gate 锁 Task 3/4 的接线成果。

---

## 任务清单

### Task 1: 建 lib/image_build.sh + exit_contract Y 登记

- 目标：创建 `build_obmc_image` leaf-pure module，并在 exit_contract 白名单登记 `image_build.sh`。
- 涉及文件：Create `lib/image_build.sh`；Modify `tools/exit_contract.py`（`LEAF_EXIT_EXCEPTIONS_BY_BASENAME` dict）。
- 接口契约：
  - Consumes: `build_env_enter`（build_env.sh）、`resolve_npm_registry`/`apply_npm_registry`（util.sh）、`bitbake`（外部命令）。
  - Produces: 函数 `build_obmc_image <machine> <build_dir>` → return bitbake rc（0/非0）。
- 验证范围：module 存在且函数已定义；exit_contract Y PASS（image_build.sh 登记为 leaf-pure set()）。

- [ ] Step 1: 写当前状态检查
  - 当前无 `lib/image_build.sh`，`build_obmc_image` 未定义，exit_contract 未登记该 basename。
  - Run: `test -f lib/image_build.sh && echo EXISTS || echo MISSING`
  - Expected: `MISSING`
  - Run: `grep -q "'image_build.sh'" tools/exit_contract.py && echo REGISTERED || echo NOT_REGISTERED`
  - Expected: `NOT_REGISTERED`

- [ ] Step 2: 运行并确认当前失败
  - Run: `test -f lib/image_build.sh && echo EXISTS || echo MISSING`
  - Expected: `MISSING`
  - Run: `grep -q "'image_build.sh'" tools/exit_contract.py && echo REGISTERED || echo NOT_REGISTERED`
  - Expected: `NOT_REGISTERED`

- [ ] Step 3: 写最小实现
  - Create `lib/image_build.sh`：
    ```bash
    #!/usr/bin/env bash
    # lib/image_build.sh — obmc-phosphor-image 整体构建执行编排 module。术语见 CONTEXT.md obmc-phosphor-image build module.
    # Exit: leaf-no-exit（leaf-pure module）; return bitbake rc(0/非0), exit 由 L1 cmd_* 收口。
    # 消费 build_env_enter(build_env.sh) + resolve/apply_npm_registry(util.sh) + bitbake。
    # ob build / ob deploy-to-qemu 共享; 不含 machine 选择/确认/展示/exit 收口(那些是 cmd_* L1); 不处理 DRY-RUN(调用点入口前短路)。

    build_obmc_image() {
        local machine="$1" build_dir="$2"

        # 进入 current-shell build environment(cd+source setup)。|| return 1 防 if build_obmc_image
        # 条件形态下 errexit 关闭上下文里 enter 失败静默继续到 bitbake 坏环境(strict-mode 静默吞陷阱)。
        build_env_enter "$machine" "$build_dir" 2>/dev/null || return 1

        # npm registry 装配(resolve 决策→apply 装配, 对偶 leaf-pure)
        resolve_npm_registry
        apply_npm_registry

        # 构建 obmc-phosphor-image; 函数末条命令 rc 即函数返回码(0=成功/非0=失败); stdout/stderr 透传不变。
        bitbake obmc-phosphor-image
    }
    ```
  - Modify `tools/exit_contract.py`：在 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` dict 内（L53-72），`'devtool_subcmd.sh': set(),` 之后追加一行：
    ```python
        'image_build.sh': set(),
    ```
  - Change: 新建 leaf-pure module；登记 basename 例外集为空 set（无 exit 例外）。

- [ ] Step 4: 运行并确认通过
  - Run: `bash -c 'source tests/lib/ob_loader.sh; declare -F build_obmc_image' >/dev/null 2>&1`
  - Expected: rc 0（函数已定义）
  - Run: `python3 tools/exit_contract.py >/dev/null 2>&1`
  - Expected: rc 0（X/Y/Z 全 PASS；Y 含 image_build.sh: set() 登记后绿）

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add lib/image_build.sh tools/exit_contract.py && git commit -m "feat(image_build): extract build_obmc_image leaf-pure module + exit_contract Y"`
  - Expected: commit 成功

### Task 2: 建 tests/unit/image_build.sh 三态单测

- 目标：unit 层覆盖 `build_obmc_image` 的 rc 语义（成功/失败/enter 失败三态），钉死新函数被 coverage radar 命中（防 uncovered 涨）。
- 涉及文件：Create `tests/unit/image_build.sh`。
- 接口契约：
  - Consumes: Task 1 产出的 `build_obmc_image`；`tests/lib/ob_loader.sh`、`tests/lib/assert.sh`、`tests/lib/stub.sh`。
  - Produces: `tests/unit/image_build.sh`（被 `tests/run_all.sh` 自动发现）。
- 验证范围：unit 测试三态全 assert PASS。

- [ ] Step 1: 写当前状态检查
  - 当前无 `tests/unit/image_build.sh`。
  - Run: `test -f tests/unit/image_build.sh && echo EXISTS || echo MISSING`
  - Expected: `MISSING`

- [ ] Step 2: 运行并确认当前失败
  - Run: `test -f tests/unit/image_build.sh && echo EXISTS || echo MISSING`
  - Expected: `MISSING`

- [ ] Step 3: 写最小实现
  - Create `tests/unit/image_build.sh`：
    ```bash
    #!/usr/bin/env bash
    # tests/unit/image_build.sh — build_obmc_image leaf-pure 单测(unit 层)。
    # stub build_env_enter/resolve_npm_registry/apply_npm_registry(函数 override) + bitbake(PATH fake),
    # 覆盖 成功/失败/enter失败 三态。聚焦 enter→bitbake→rc 链; npm 装配由 tests/unit/npm_registry.sh 专门测。
    source "$(dirname "$0")/../lib/ob_loader.sh"
    source "$(dirname "$0")/../lib/assert.sh"
    source "$(dirname "$0")/../lib/stub.sh"
    assert_reset

    DB="$(mktemp -d)"
    mkfake_bin "$DB" bitbake
    trap 'rm -rf "$DB"' EXIT

    # stub: build_env_enter 默认 noop 成功, _BUILD_ENV_RC 控制 enter 失败; resolve/apply noop。
    build_env_enter() { [[ "${_BUILD_ENV_RC:-0}" -eq 0 ]] || return "$_BUILD_ENV_RC"; }
    resolve_npm_registry() { :; }
    apply_npm_registry() { :; }

    # --- 态 1: bitbake 成功 → build_obmc_image return 0 + calls=1 + target 正确 ---
    _BUILD_ENV_RC=0
    stub_exit "$DB" bitbake 0
    PATH="$DB:$PATH" build_obmc_image romulus /tmp/build >/dev/null 2>&1
    assert_eq "bitbake ok → rc 0" "$?" 0
    assert_eq "bitbake called once" "$(wc -l < "$DB/.bitbake.calls")" 1
    assert_eq "bitbake target" "$(cat "$DB/.bitbake.calls")" "obmc-phosphor-image"

    # --- 态 2: bitbake 失败 → build_obmc_image return 1 ---
    rm -f "$DB/.bitbake.calls"
    stub_exit "$DB" bitbake 1
    PATH="$DB:$PATH" build_obmc_image romulus /tmp/build >/dev/null 2>&1
    assert_eq "bitbake fail → rc 1" "$?" 1
    assert_eq "bitbake called once (fail)" "$(wc -l < "$DB/.bitbake.calls")" 1

    # --- 态 3: build_env_enter 失败 → build_obmc_image return 1, bitbake 不该被调 ---
    rm -f "$DB/.bitbake.calls"
    _BUILD_ENV_RC=1
    stub_exit "$DB" bitbake 0   # bitbake 设成功, 但 enter 失败不该到 bitbake
    PATH="$DB:$PATH" build_obmc_image romulus /tmp/build >/dev/null 2>&1
    assert_eq "enter fail → rc 1" "$?" 1
    assert_eq "enter fail: bitbake not called" "$(wc -l < "$DB/.bitbake.calls" 2>/dev/null || echo 0)" 0

    assert_summary
    ```
  - Change: 新建 unit 三态单测。

- [ ] Step 4: 运行并确认通过
  - Run: `bash tests/unit/image_build.sh >/dev/null 2>&1`
  - Expected: rc 0（全 assert PASS）

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add tests/unit/image_build.sh && git commit -m "test(image_build): unit 三态单测(成功/失败/enter失败)"`
  - Expected: commit 成功

### Task 3: 接线 cmd_build 调 build_obmc_image

- 目标：`cmd_build` 内联四步替换为 `build_obmc_image`，展示与 exit-1 收口留 L1；行为不变。
- 涉及文件：Modify `lib/commands.sh`（`cmd_build` 内 L338-351 四步）。
- 接口契约：
  - Consumes: Task 1 的 `build_obmc_image`；既有 `tests/orchestration/cmd_build_bitbake_handoff.sh`（行为金标）。
  - Produces: `cmd_build` 经 `build_obmc_image` 构建；commands.sh 无直调 `bitbake obmc-phosphor-image`。
- 验证范围：`cmd_build_bitbake_handoff.sh` 全绿。该金标（已读全文 [tests/orchestration/cmd_build_bitbake_handoff.sh:46-61](../../tests/orchestration/cmd_build_bitbake_handoff.sh#L46-L61)）锁四点：bitbake calls=1、target=obmc-phosphor-image、cwd=BUILD_DIR（fake setup 的 cd 验证）、cmd_build rc 0/1；**不**锁 build_env_enter 调用次数。抽取后 `build_obmc_image` 内部仍调 bitbake 一次、`build_env_enter` 仍 source fake setup cd 到 BUILD_DIR，四点全满足、金标不误报。另：commands.sh 无直调 bitbake。

- [ ] Step 1: 写当前状态检查
  - 当前 `cmd_build` 仍内联 enter+npm+bitbake 四步（直调 bitbake）。
  - Run: `grep -nE '^[[:space:]]*(if[[:space:]]*(![[:space:]]*)?)?bitbake[[:space:]]+obmc-phosphor-image' lib/commands.sh || echo NONE`
  - Expected: 命中 `lib/commands.sh:351:    if bitbake obmc-phosphor-image; then`（非 NONE）

- [ ] Step 2: 运行并确认当前状态
  - Run: `grep -cE '^[[:space:]]*(if[[:space:]]*(![[:space:]]*)?)?bitbake[[:space:]]+obmc-phosphor-image' lib/commands.sh || echo 0`
  - Expected: `1`

- [ ] Step 3: 写最小实现
  - Modify `lib/commands.sh`，把 `cmd_build` 的构建段（当前 L338-351）：
    ```bash
        # === Re-enter bitbake environment ===
        build_env_enter "$MACHINE" "$BUILD_DIR" 2>/dev/null

        # === npm registry auto-detection ===
        resolve_npm_registry
        apply_npm_registry

        # === Run bitbake ===
        echo ""
        step_header "Building $MACHINE"
        info "Running: bitbake obmc-phosphor-image"
        echo ""

        if bitbake obmc-phosphor-image; then
    ```
    替换为：
    ```bash
        # === Build obmc-phosphor-image(经 obmc-phosphor-image build module: enter+npm+bitbake, return rc) ===
        echo ""
        step_header "Building $MACHINE"
        info "Running: bitbake obmc-phosphor-image"
        echo ""

        if build_obmc_image "$MACHINE" "$BUILD_DIR"; then
    ```
  - Change: 四步内联塌为一行 `build_obmc_image`；header/info/echo 展示保留 L1；`if` 消费 rc。

- [ ] Step 4: 运行并确认通过
  - Run: `bash tests/orchestration/cmd_build_bitbake_handoff.sh >/dev/null 2>&1`
  - Expected: rc 0（行为金标全绿）
  - Run: `! grep -qE '^[[:space:]]*(if[[:space:]]*(![[:space:]]*)?)?bitbake[[:space:]]+obmc-phosphor-image' lib/commands.sh`
  - Expected: rc 0（commands.sh 无直调 bitbake）

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add lib/commands.sh && git commit -m "refactor(build): wire cmd_build to build_obmc_image"`
  - Expected: commit 成功

### Task 4: 接线 cmd_deploy_to_qemu 调 build_obmc_image

- 目标：`cmd_deploy_to_qemu` 内联四步替换为 `build_obmc_image`，展示与 exit-1/build-first 约束留 L1；行为不变。
- 涉及文件：Modify `lib/qemu_commands.sh`（`cmd_deploy_to_qemu` 内 L346-355 四步）。
- 接口契约：
  - Consumes: Task 1 的 `build_obmc_image`；既有 `tests/orchestration/deploy_to_qemu.sh`（7 场景行为金标）。
  - Produces: `cmd_deploy_to_qemu` 经 `build_obmc_image` 构建；qemu_commands.sh 无直调 `bitbake obmc-phosphor-image`。
- 验证范围：`deploy_to_qemu.sh` 7 场景全绿。该金标（已读全文 [tests/orchestration/deploy_to_qemu.sh](../../tests/orchestration/deploy_to_qemu.sh)）锁三点：① 编排序 build→(QEMU 在跑则 stop + 端口复用注入)→start（场景①②）；② build-first：build 失败不 stop QEMU + bitbake calls=1 + target=obmc-phosphor-image（场景③ `stub_exit bitbake 1`）；③ DRY_RUN 不调 bitbake（场景⑦，DRY_RUN 短路在 `build_obmc_image` 入口前）。抽取后 `build_obmc_image` 内部调 bitbake 仍命中 PATH stub，三场景不变。另：qemu_commands.sh 无直调 bitbake。

- [ ] Step 1: 写当前状态检查
  - 当前 `cmd_deploy_to_qemu` 仍内联 enter+npm+bitbake 四步。
  - Run: `grep -nE '^[[:space:]]*(if[[:space:]]*(![[:space:]]*)?)?bitbake[[:space:]]+obmc-phosphor-image' lib/qemu_commands.sh || echo NONE`
  - Expected: 命中 `lib/qemu_commands.sh:355:    if ! bitbake obmc-phosphor-image; then`（非 NONE）

- [ ] Step 2: 运行并确认当前状态
  - Run: `grep -cE '^[[:space:]]*(if[[:space:]]*(![[:space:]]*)?)?bitbake[[:space:]]+obmc-phosphor-image' lib/qemu_commands.sh || echo 0`
  - Expected: `1`

- [ ] Step 3: 写最小实现
  - Modify `lib/qemu_commands.sh`，把 `cmd_deploy_to_qemu` 的 build 段（当前 L346-355）：
    ```bash
        echo ""
        step_header "Building $MACHINE (image rebuild)"
        info "Running: bitbake obmc-phosphor-image"
        info "Estimated time: 1-4 hours depending on machine and cache state."

        build_env_enter "$MACHINE" "$BUILD_DIR" 2>/dev/null
        resolve_npm_registry
        apply_npm_registry

        if ! bitbake obmc-phosphor-image; then
    ```
    替换为：
    ```bash
        echo ""
        step_header "Building $MACHINE (image rebuild)"
        info "Running: bitbake obmc-phosphor-image"
        info "Estimated time: 1-4 hours depending on machine and cache state."

        if ! build_obmc_image "$MACHINE" "$BUILD_DIR"; then
    ```
  - Change: 四步内联塌为一行 `build_obmc_image`；header/estimated-time 展示保留 L1；`if !` 消费 rc（build 失败 exit 1，build-first QEMU 不动）。

- [ ] Step 4: 运行并确认通过
  - Run: `bash tests/orchestration/deploy_to_qemu.sh >/dev/null 2>&1`
  - Expected: rc 0（7 场景全绿）
  - Run: `! grep -qE '^[[:space:]]*(if[[:space:]]*(![[:space:]]*)?)?bitbake[[:space:]]+obmc-phosphor-image' lib/qemu_commands.sh`
  - Expected: rc 0（qemu_commands.sh 无直调 bitbake）

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add lib/qemu_commands.sh && git commit -m "refactor(deploy): wire cmd_deploy_to_qemu to build_obmc_image"`
  - Expected: commit 成功

### Task 5: ob_check.sh 加 1c-quin surface gate

- 目标：加静态 surface gate 锁「除 image_build.sh 外，ob/lib 不得直调 `bitbake obmc-phosphor-image`」，防 cmd_* 回潮直调。
- 涉及文件：Modify `tools/ob_check.sh`（在 `1c-quat` 块之后、`1d` 块之前插入 `1c-quin`）。
- 接口契约：
  - Consumes: Task 3/4 的接线成果（直调已清零，仅 image_build.sh 内部保留）。
  - Produces: `1c-quin` surface gate step。
- 验证范围：ob_check 输出含 `ok: obmc-phosphor-image 直调全经 build_obmc_image`。

- [ ] Step 1: 写当前状态检查
  - 当前 ob_check 无 1c-quin gate；但 Task 3/4 已完成，直调已清零（仅 image_build.sh）。
  - Run: `grep -c '1c-quin' tools/ob_check.sh || echo 0`
  - Expected: `0`
  - Run: `grep -RInE '^[[:space:]]*(if[[:space:]]*(![[:space:]]*)?)?bitbake[[:space:]]+obmc-phosphor-image' ob lib/*.sh | grep -v 'lib/image_build.sh' || true`
  - Expected: 空（直调已全收口到 image_build.sh，Task 3/4 成果）

- [ ] Step 2: 运行并确认当前状态
  - Run: `grep -c '1c-quin' tools/ob_check.sh || echo 0`
  - Expected: `0`

- [ ] Step 3: 写最小实现
  - Modify `tools/ob_check.sh`，在 `1c-quat` 块结尾（`fi` 之后、`# ── 1d.` 之前）插入：
    ```bash
    # ── 1c-quin. obmc-phosphor-image 直调清零门禁(必经 build_obmc_image) ──
    # 除 image_build.sh 内部, ob/lib 不得直接调用 bitbake obmc-phosphor-image(必经
    # build_obmc_image 深 module 收口 enter+npm+bitbake, ob build/deploy-to-qemu 共享)。
    # 精确正则只匹配命令位直调(行首/if/! 后的 bitbake), 排除 info/echo/notice 字符串内的
    # 展示文案(DRY-RUN 行、"Running: bitbake..." 等)——经实测, 抽取前命中 commands.sh:351
    # + qemu_commands.sh:355 两处直调, 字符串行 5 处不被误报。
    _img_build_direct_re='^[[:space:]]*(if[[:space:]]*(![[:space:]]*)?)?bitbake[[:space:]]+obmc-phosphor-image'
    _img_build_direct=$(grep -RInE "$_img_build_direct_re" ob lib/*.sh 2>/dev/null | grep -v 'lib/image_build.sh' || true)
    if [[ -n "$_img_build_direct" ]]; then
        bad "bitbake obmc-phosphor-image 直调未收口到 build_obmc_image(除 image_build.sh):"
        printf '%s\n' "$_img_build_direct"
    else
        ok "obmc-phosphor-image 直调全经 build_obmc_image"
    fi
    ```
  - Change: 新增 surface gate，正则经实测（抽取前命中 2 直调、排除 5 字符串行）。

- [ ] Step 4: 运行并确认通过
  - Run: `bash tools/ob_check.sh 2>&1 | grep -q 'obmc-phosphor-image 直调全经 build_obmc_image'`
  - Expected: rc 0（gate 绿）

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add tools/ob_check.sh && git commit -m "feat(check): add 1c-quin obmc-phosphor-image direct-call surface gate"`
  - Expected: commit 成功

### Task 6: 最终验证

- 目标：全仓库配套自检 + coverage 基线 + 全测试通过。
- 涉及文件：无（仅运行验证命令）。
- 接口契约：
  - Consumes: Task 1-5 全部产出。
  - Produces: 无。
- 验证范围：ob_check ALL GREEN；coverage uncovered ≤7；run_all 全绿。

- [ ] Step 1: 写当前状态检查
  - Task 1-5 已完成，进入收口验证。

- [ ] Step 2: 运行并确认前置就绪
  - Run: `test -f lib/image_build.sh && test -f tests/unit/image_build.sh && test -f tools/ob_check.sh`
  - Expected: rc 0（产出齐全）

- [ ] Step 3: 写最小实现
  - 无代码改动（纯验证任务）。如某项失败，回到对应 Task 修复。

- [ ] Step 4: 运行并确认通过
  - Run: `bash tools/ob_check.sh >/dev/null 2>&1`
  - Expected: rc 0（ALL GREEN，含新 1c-quin gate + exit_contract Y + shellcheck baseline + run_all）
  - Run: `tools/trace_collect.sh | python3 tools/coverage_radar.py - --fail-if-uncovered 7 >/dev/null 2>&1`
  - Expected: rc 0（uncovered ≤7，build_obmc_image 被 unit 命中不涨）
  - Run: `bash tests/run_all.sh >/dev/null 2>&1`
  - Expected: rc 0（protocol/unit/orchestration 全绿）

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行（Task 1→6），不要无声跳步、合并步或改变任务目标。
- 每完成一个任务，都运行该任务 Step 4 定义的验证。
- 遇到阻塞、重复失败或计划与仓库现实不符，立即停下来说明，不要猜。
- 当前在 `main` 分支；开始实现前先与用户确认分支策略（直接在 main 还是切 feature 分支）。
- 全部任务完成后，运行 Task 6 最终验证并输出修改摘要。

## 最终验证

- `bash tools/ob_check.sh` → ALL GREEN（exit 0），含 `1c-quin: obmc-phosphor-image 直调全经 build_obmc_image`。
- `tools/trace_collect.sh | python3 tools/coverage_radar.py - --fail-if-uncovered 7` → exit 0（uncovered ≤7）。
- `bash tests/run_all.sh` → exit 0（protocol/unit/orchestration 全绿）。
- 沿用当前 shell（bash）与仓库惯例（`tools/` + `tests/` 脚本均可直接 `bash` 执行）。

## 审阅 Checkpoint

- 计划正文结束。请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行。
- 审阅通过前，不进入实现。
