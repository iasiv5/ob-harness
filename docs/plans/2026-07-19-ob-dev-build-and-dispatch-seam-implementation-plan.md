# ob dev build + cmd_dev dispatch/emit seam 实施计划

## 修订记录

- **v2.1（review round-2 🟢 收尾，2026-07-19）**：二轮评审放行（3 🔴 全闭环、无新 🔴/🟡）。顺手收 3 个 🟢 可读性建议：① B2 not_modified 路径改显式 `cat+rm`（原靠 relay"三条件不触发表"隐式行为，不直白）；② A4 commit 信息补"status warn 路径位置未变"；③ B4 rc=3 注释纠正——status 自身失败走 exit 1 不到 rc=3，故 rc=3 必是 status 成功但 ob 漏判 modified（非 B1 🔴2 status-fail 回归）。
- **v2（review feedback，2026-07-19）**：吸收评审报告。关键修订：① **A1 relay 改 per-subcmd verbatim message 表**（原"统一 hint + token 末尾"假设错误——rc message 本就 per-subcmd 不一致：modify/reset/finish=`devtool failed (rc,stage)`、status=`devtool status failed (rc)`、refresh=`failed (stage)`；metadata phase 的 `(phase=metadata)` 在句中非句末）。② **refresh + list 不套 relay**（refresh 无 stage-case、stage 折进 rc message，结构特殊；list 是状态机）——relay 只服务 modify/status/reset/finish（共享 stage-case）。③ **B1 `devtool_build_run` 镜像 `devtool_modify_run`**（rc=0 显式初始化；status 失败回传 stage+rc 不继续 build，原实现 fall-through 带 bad env 跑 build）。④ **B2 arg parser 内层 case 加 build**（[:845](lib/commands.sh#L845)/[:854](lib/commands.sh#L854) 两处，否则 `ob dev build myrecipe` exit 1 unexpected argument）。⑤ A4 写完整 status 分支骨架；A1 单测加 `*)` 兜底 + rc 表 case；B2 写完整 build TTY 补参段代码；B4 加 rc=3 调试提示。
- v1：grill-with-docs 共识初稿（8 任务两 commit）。

## 目标

把已批准设计 `docs/specs/2026-07-19-ob-dev-build-and-dispatch-seam-design.md` 落地为两个严格顺序的 commit：

- **Commit A（纯重构，行为不变）**：抽两个 leaf-pure 深模块——`dev_relay_result`（failure-relay）和 `dev_emit_*`（per-shape result-encoder），把 `cmd_dev` 的 modify/refresh/status/reset/finish 分支从内联 boilerplate（cat/rm stderr + stage/phase/rc 诊断 + inline python encode）迁到新 seam。stdout/stderr/exit-code 字节级不变，既有测试即回归锁。
- **Commit B（新功能）**：在干净 seam 上加 `ob dev build`（`devtool_build_run` leaf-pure assembler + `cmd_dev` build 分支 + usage/菜单/测试）。

候选 2（seam）是候选 1（build）的交付载体。

## 架构快照

- 新 `lib/devtool_dispatch.sh`：`dev_relay_result <subcmd> <stderr_file> <stage> <phase> <rc>` —— 集中 cat/rm stderr + stage/phase/rc 诊断（**per-subcmd verbatim message 表**，逐字对齐现状），返回 0/1。leaf-pure（不 exit），`cmd_dev` 保留唯一 `exit`（ADR-0010）。服务 **modify/status/reset/finish**（共享 stage-case 的 4 个）。
- 扩 `lib/devtool_porcelain.sh`：加 `dev_emit_reset_json` / `dev_emit_finish_json` / `dev_emit_status_jsonl` —— python encode（argv 值不插值，字段序字节 faithful，空→null）→ tempfile → 复用既有 `devtool_emit_json`/`devtool_emit_jsonl` publish。
- `cmd_dev` modify/status/reset/finish 分支收成：`devtool_X_run …; dev_relay_result … || exit 1; dev_emit_<shape> … || exit 1; exit 0`（modify 无 encoder，直接 `printf srctree`）。
- `lib/devtool_build.sh`：`devtool_build_run`（**镜像 `devtool_modify_run` status-first**：rc=0 显式初始化、status 失败回传 stage+rc 不继续），单次 `devtool build`，无 phase。
- **refresh + list 不套 relay**：refresh 无 stage-case（stage 折进 rc message `failed (stage=X)`，结构特殊），list 是状态机（missing/stale/fresh）——两者本轮保持 inline 不动。relay 只覆盖共享 stage-case 结构的 4 个分支。

## 全局约束

从设计文档逐字继承（实施约束段）：

1. **严格两 commit**：A 全绿（既有测试全过）才进 B。
2. **A 的 JSON 字节 faithful**：encoder 字段序 + None 强转逐字对齐现有 inline python（reset 7 字段序 `recipe,srctree,srctreebase,disposition,destination_parent,destination,cleaned_bbappend`；finish 12 字段序上述 7 + `landing_mode,landing_layer,patches,recipe_files,srcrev`；status JSONL key 集 `{recipe,srctree}`）。
3. **phase-token 不变量**：`dev_relay_result` 每条 hint 含 `(phase=<phase>)`；stage 失败含 `build env`；rc 失败含 `devtool`。
4. **exit 只在 cmd_dev**：新 helper 全 leaf-pure（返回码）；`tools/exit_contract.py` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 显式加新 basename（否则 check_Y 对新文件返回 None，静默不守卫）。
5. **build 不碰 workspace**：不创建/删除 externalsrc/`.bbappend`，与 ADR-0008/0009 无关。
6. **环境**：Linux + bash；验证命令用 bash/python3/expect。`expect` 需已装（跑 .exp）。
7. **命名**：lib 文件 `devtool_*.sh`（snake_case）；新文件 header 注释 + 纯函数体（过 `extract_funcs` 三段门禁）。

## 输入工件

- 设计文档：`docs/specs/2026-07-19-ob-dev-build-and-dispatch-seam-design.md`（零未决）。
- 伴生已落：`docs/adr/0010-ob-dev-dispatch-leaf-pure-exit.md`、`CONTEXT.md`（`ob dev build` 术语 + porcelain stdout 补 build）。计划引用，不重述。

## 文件结构与职责

**Create:**
- `lib/devtool_dispatch.sh`（Commit A）—— `dev_relay_result`，leaf-pure failure-relay。
- `lib/devtool_build.sh`（Commit B）—— `devtool_build_run`，leaf-pure build assembler。
- `tests/unit/devtool_dispatch.sh`（Commit A）—— `dev_relay_result` 单测。
- `tests/unit/devtool_build.sh`（Commit B）—— `devtool_build_run` 单测。

**Modify:**
- `lib/devtool_porcelain.sh`（Commit A）—— 加 3 个 encoder。
- `lib/commands.sh::cmd_dev`（Commit A：改 modify/status/reset/finish 分支到 relay + 删 inline python；refresh/list 不动；Commit B：加 `build)` 分支 + arg parser 内层 case 加 build + TTY 菜单第 7 项 + build recipe 补参段）。
- `ob`（Commit B）—— usage dev 行加 `build`（`list|modify|build|refresh|reset|status|finish`）。
- `tools/exit_contract.py`（Commit A：加 `devtool_dispatch.sh`；Commit B：加 `devtool_build.sh`，均 `set()`）—— `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` dict。
- `rules/03_WORKSPACE.md`（Commit A：lib 索引补 `devtool_dispatch.sh`；Commit B：补 `devtool_build.sh`）。
- `tests/unit/devtool_porcelain.sh`（Commit A）—— 加 3 encoder case。
- `tests/orchestration/cmd_dev.sh`（Commit B）—— 加 build 分支 case（not-modified→3 / success→0 空 stdout / stage-rc fail→1 / DRY_RUN）。
- `tests/protocol/usage_dispatch_sync.sh`（Commit B）—— 加 build 登记块。
- `tests/protocol/dev_interactive.exp`（Commit B）—— line 122/147 `[1-6]`→`[1-7]` + 可选 build TTY 场景。
- `tests/integration/ob_dev.sh`（Commit B）—— modify 后插 build e2e。
- `rules/skills/workflow_02-obmc_dev_modify.md`（Commit B）—— 补 build 条目 + porcelain。

**接口依赖：** A3/A4 Consumes `dev_relay_result`（A1 Produces）；A4 Consumes `dev_emit_*`（A2 Produces）；B2 Consumes `devtool_build_run`（B1 Produces）+ `dev_relay_result`（A1）。

---

## 任务清单

### Task A1: 创建 `dev_relay_result` leaf-pure 模块

- 目标：抽出 failure-relay 深模块，集中 cat/rm stderr + stage/phase/rc 诊断。
- Files:
  - Create: `lib/devtool_dispatch.sh`
  - Create: `tests/unit/devtool_dispatch.sh`
  - Modify: `tools/exit_contract.py`（`LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 加 `'devtool_dispatch.sh': set(),`）
  - Modify: `rules/03_WORKSPACE.md`（lib 索引加 `devtool_dispatch.sh` 条目）
- 验证范围：`bash tests/unit/devtool_dispatch.sh` exit 0；`python3 tools/exit_contract.py` 输出含 `Y: PASS` 且 devtool_dispatch 无违反；`python3 tools/extract_funcs.py lib/devtool_dispatch.sh` 无 `_TOPLEVEL`/`GAP`。
- 接口契约:
  - Consumes: 无（首个任务）。
  - Produces: `dev_relay_result <subcmd> <stderr_file> <stage> <phase> <rc>`（leaf-pure，返回 0=干净继续 / 1=已诊断失败）。A3、A4、B2 消费。

- [ ] Step 1: 写失败单测 `tests/unit/devtool_dispatch.sh`
  - 照 `tests/unit/devtool_modify.sh` scaffold：`source tests/lib/ob_loader.sh` + `tests/lib/assert.sh` + `assert_reset` + `assert_summary`。捕获 stderr 到变量（`err="$(dev_relay_result ... 2>&1 >/dev/null)"`）做**整行断言**（非子串——锁字节 faithful，防 🔴1 类 drift）。
  - 断言点（逐字对齐 cmd_dev 现状）：
    - ① stage=setup（任意 subcmd）→ 整行 `ob dev reset: build env not ready (stage=setup).`，return 1。
    - ② **phase=metadata subcmd=reset** → 整行 `ob dev reset: metadata error (phase=metadata); cannot safely reset.`（**token 在句中、`;` 副句**——这是 🔴1 的关键 case）。
    - ③ phase=metadata subcmd=finish → 整行 `ob dev finish: metadata error (phase=metadata); cannot safely finish.`。
    - ④ phase=finish subcmd=finish → `ob dev finish: devtool finish failed (phase=finish).`。
    - ⑤ phase=landing subcmd=finish → `ob dev finish: landing detection failed; verify patches landed manually (phase=landing).`。
    - ⑥ phase=postcondition（reset 或 finish）→ `ob dev reset: postcondition failed (phase=postcondition).`。
    - ⑦ **`*)` 兜底**：phase=unknown subcmd=reset → `ob dev reset: failed (phase=unknown).`（锁兜底文案契约，防未来 reset 新 phase 漏表）。
    - ⑧ **rc 表 per-subcmd**：rc=2 stage=command subcmd=modify → `ob dev modify: devtool failed (rc=2, stage=command).`；subcmd=status → `ob dev status: devtool status failed (rc=2).`（**无 stage、多 "status"**——锁 status 的 rc 差异）；subcmd=finish → `ob dev finish: devtool failed (rc=2, stage=command).`。
    - ⑨ stage=command phase="" rc=0 → return 0，无 stderr 诊断（cat 仍执行）。
    - ⑩ 调用后 stderr_file 被 rm（`test ! -e`）；stderr_file 内容被 cat 到 >&2。
  - Run: `bash tests/unit/devtool_dispatch.sh`
  - Expected: 失败（`lib/devtool_dispatch.sh` 不存在，source 报错或函数未定义）。

- [ ] Step 2: 运行并确认失败
  - Run: `bash tests/unit/devtool_dispatch.sh 2>&1 | tail -5`
  - Expected: source/函数未定义错误，非 0 退出。

- [ ] Step 3: 写最小实现 `lib/devtool_dispatch.sh`
  - header 注释（说明 leaf-pure、调用者 cmd_dev 负责 exit、per-subcmd verbatim message 表）+ 单函数 `dev_relay_result`。**关键：message 逐字对齐 cmd_dev 现状**（metadata 的 `(phase=metadata)` 在句中、rc 表 per-subcmd——见 Step 1 断言）：

```bash
#!/usr/bin/env bash
# lib/devtool_dispatch.sh — cmd_dev 分支共享的 failure-relay(leaf-pure module)。
#   dev_relay_result: 调完 devtool_*_run 后的标准动作 — cat+rm stderr_file + stage/phase/rc 诊断 → 返回 0/1。
#   被 cmd_dev(modify/status/reset/finish/build)消费。per-subcmd verbatim message 表(逐字对齐 cmd_dev 现状,
#   字节 faithful); refresh/list 不套本 relay(结构特殊)。token (phase=<phase>)/(stage=<stage>)/(rc=<rc>) 保留。
#   ob loader source 全部 lib; bash 运行时按名解析。术语见 CONTEXT.md function semantic layer / ob dev porcelain stdout。
# Exit: leaf-pure module(函数绝不 exit; 允许文件/进程副作用); 调用者(cmd_dev)负责 exit-code/remedy/诊断(ADR-0010)。

# dev_relay_result <subcmd> <stderr_file> <stage> <phase> <rc>
# cat+rm stderr_file → stage(cd/setup/postcondition → "build env not ready", 4 subcmd 共享)
#   → phase(reset/finish verbatim 表, metadata token 在句中) → rc(per-subcmd 表: modify/reset/finish="devtool failed (rc,stage)";
#   status="devtool status failed (rc)", 无 stage) → 返回 0(干净) / 1(已诊断, 调用者 exit 1)。
dev_relay_result() {
    local subcmd="$1" stderr_file="$2" stage="$3" phase="$4" rc="$5"
    cat -- "$stderr_file" >&2 2>/dev/null || true
    rm -f -- "$stderr_file" 2>/dev/null || true
    case "$stage" in
        cd|setup|postcondition)
            error "ob dev $subcmd: build env not ready (stage=$stage)." >&2
            return 1 ;;
    esac
    if [[ -n "$phase" ]]; then
        case "$subcmd:$phase" in
            reset:metadata)  error "ob dev reset: metadata error (phase=metadata); cannot safely reset." >&2 ;;
            finish:metadata) error "ob dev finish: metadata error (phase=metadata); cannot safely finish." >&2 ;;
            reset:status|finish:status) error "ob dev $subcmd: devtool status failed (phase=status)." >&2 ;;
            reset:reset)     error "ob dev reset: devtool reset failed (phase=reset)." >&2 ;;
            finish:finish)   error "ob dev finish: devtool finish failed (phase=finish)." >&2 ;;
            finish:landing)  error "ob dev finish: landing detection failed; verify patches landed manually (phase=landing)." >&2 ;;
            reset:postcondition|finish:postcondition) error "ob dev $subcmd: postcondition failed (phase=postcondition)." >&2 ;;
            *)               error "ob dev $subcmd: failed (phase=$phase)." >&2 ;;
        esac
        return 1
    fi
    if [[ "$rc" -ne 0 ]]; then
        case "$subcmd" in
            status) error "ob dev status: devtool status failed (rc=$rc)." >&2 ;;
            *)      error "ob dev $subcmd: devtool failed (rc=$rc, stage=$stage)." >&2 ;;   # modify/reset/finish
        esac
        return 1
    fi
    return 0
}
```

  - 在 `tools/exit_contract.py` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME`（devtool_workspace.sh 行后）加 `'devtool_dispatch.sh': set(),`。
  - 在 `rules/03_WORKSPACE.md` lib 索引段加 `devtool_dispatch.sh` 条目（照 `devtool_porcelain.sh` 行格式：`devtool_dispatch.sh cmd_dev 分支共享 failure-relay(cat/rm stderr + stage/phase/rc verbatim 诊断, modify/status/reset/finish/build; leaf-pure)`）。
  - Change: 新建 dispatch 模块（per-subcmd verbatim 表）+ 注册 exit_contract + WORKSPACE 索引。

- [ ] Step 4: 运行并确认通过
  - Run: `bash tests/unit/devtool_dispatch.sh && python3 tools/exit_contract.py 2>&1 | grep -E 'Y: (PASS|FAIL)' && python3 tools/extract_funcs.py lib/devtool_dispatch.sh`
  - Expected: 单测 exit 0（PASS）；`Y: PASS`；extract_funcs 无 `_TOPLEVEL`/`GAP` 输出。

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add lib/devtool_dispatch.sh tests/unit/devtool_dispatch.sh tools/exit_contract.py rules/03_WORKSPACE.md && git commit -m "refactor(dev): extract dev_relay_result leaf-pure failure-relay module"`
  - Expected: commit 成功。

---

### Task A2: 扩 porcelain 加 3 个 per-shape encoder

- 目标：把 reset/finish/status 的 inline python encode 收进 leaf-pure encoder，字节 faithful。
- Files:
  - Modify: `lib/devtool_porcelain.sh`（加 `dev_emit_reset_json` / `dev_emit_finish_json` / `dev_emit_status_jsonl`）
  - Modify: `tests/unit/devtool_porcelain.sh`（加 3 encoder case）
- 验证范围：`bash tests/unit/devtool_porcelain.sh` exit 0（含既有 emit_json/jsonl case + 新 encoder case，断言精确 JSON 字节）。
- 接口契约:
  - Consumes: `devtool_emit_json` / `devtool_emit_jsonl`（既有，同文件）。
  - Produces: `dev_emit_reset_json`（7 字段）、`dev_emit_finish_json`（12 字段）、`dev_emit_status_jsonl`（JSONL）。A4 消费。

- [ ] Step 1: 写失败单测 case（加进 `tests/unit/devtool_porcelain.sh` 末尾，`assert_summary` 前）
  - **argv arity 契约**（与 Produces 一致）：`dev_emit_reset_json` 恰 6 参；`dev_emit_finish_json` 恰 11 参；`dev_emit_status_jsonl` 恰 1 参（entries 串）。**注意**：bash 位置参数缺失时为 `""`（空串→null），**不是 return 1**——encoder 信任调用方 arity（cmd_dev 总传齐），缺失参数被当空值→null 编码。encoder 的 return 1 路径是**python `json.dumps` 抛错**或 **`devtool_emit_json[_jsonl]` 校验失败**（多行/无尾换行/非法 JSON/key 集合错），不是 argv 计数。
  - 断言精确 stdout（字节 faithful，`python3 -c 'import json,sys;print(json.dumps(...))'` 比对）：
    - `dev_emit_reset_json recipeA /src/A /base/A moved "" cleaned.bbappend` → `{"recipe":"recipeA","srctree":"/src/A","srctreebase":"/base/A","disposition":"moved","destination_parent":null,"destination":null,"cleaned_bbappend":"cleaned.bbappend"}`（destination_parent 空串→null；destination 恒 null）。
    - `dev_emit_reset_json` 带 destination_parent 非空 → 该字段保留原值。
    - `dev_emit_finish_json` 11 参，patches/recipe_files 传 JSON 串 `'["a.patch"]'` / `'["r.bb"]'` → 数组；空串→`[]`；srcrev 空→null。
    - `dev_emit_status_jsonl`（entries=`recipeA<TAB>/src/A<LF>recipeB<TAB>/src/B`）→ 两行 JSONL，每行 `{"recipe":..,"srctree":..}`，key 集合恰好 `{recipe,srctree}`。
    - 失败路径：构造一个**非法 JSON 值**喂 encoder（如让 finish 的 patches_json 是非法 JSON 串 `'[oops'` → python `json.loads` 抛错 → encoder 删 tempfile + return 1 + stdout 空）。不要用"argv 不足"测失败路径（那不会 return 1）。
  - Run: `bash tests/unit/devtool_porcelain.sh`
  - Expected: 失败（encoder 函数未定义）。

- [ ] Step 2: 运行并确认失败
  - Run: `bash tests/unit/devtool_porcelain.sh 2>&1 | tail -5`
  - Expected: 新 case 报函数未定义，非 0 退出。

- [ ] Step 3: 写最小实现（加进 `lib/devtool_porcelain.sh`，在既有 `devtool_emit_jsonl` 后）
  - 3 个 encoder。每个 = python `json.dumps` 建 dict（**字段序与既有 inline 一致**）→ tempfile → `devtool_emit_json`/`devtool_emit_jsonl`。空值经 `or None`→null；finish 的 patches/recipe_files 经 `json.loads(argv) if argv else []`。参考现有 cmd_dev reset/finish/status 分支的 inline python（`lib/commands.sh:1110` reset / `:1166` finish / `:1210` status），逐字搬字段序与 None 规则。
  - 签名：`dev_emit_reset_json <recipe> <srctree> <srctreebase> <disposition> <destination_parent> <cleaned_bbappend>`；`dev_emit_finish_json <recipe> <srctree> <srctreebase> <disposition> <destination_parent> <cleaned_bbappend> <landing_mode> <landing_layer> <patches_json> <recipe_files_json> <srcrev>`；`dev_emit_status_jsonl <entries>`（entries 换行分隔 `recipe<TAB>srctree`）。
  - Change: porcelain.sh 加 3 encoder（leaf-pure，复用既有 emit publish）。

- [ ] Step 4: 运行并确认通过
  - Run: `bash tests/unit/devtool_porcelain.sh && python3 tools/extract_funcs.py lib/devtool_porcelain.sh`
  - Expected: exit 0（既有 + 新 case 全 PASS）；extract_funcs 无违规。

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add lib/devtool_porcelain.sh tests/unit/devtool_porcelain.sh && git commit -m "refactor(dev): add dev_emit_reset/finish/status porcelain encoders"`
  - Expected: commit 成功。

---

### Task A3: 重构 cmd_dev 的 modify 分支到 relay

- 目标：把 modify 分支（relay-only、无 JSON encode、无 phase）改用 `dev_relay_result`，stderr/exit 字节不变。
- Files:
  - Modify: `lib/commands.sh::cmd_dev` modify 分支（`lib/commands.sh:1022` 附近，`devtool_modify_run` 调用后）
- 验证范围：`bash tests/orchestration/cmd_dev.sh` 全绿（modify 既有断言不变，含 `:153 modify command 失败诊断(devtool)`）；`tools/ob_check.sh` 全绿。
- 接口契约:
  - Consumes: `dev_relay_result`（A1）。
  - Produces: 无（内部重构）。

- [ ] Step 1: 记录基线 + 观察目标
  - 改动前 cmd_dev.sh 全绿是回归锁。目标：modify 分支不再内联 `cat … >&2; rm` + `case stage` + `if rc`，改为 `dev_relay_result modify … || exit 1`。
  - Run: `bash tests/orchestration/cmd_dev.sh 2>&1 | tail -3 && grep -c 'cat "\$_' lib/commands.sh`
  - Expected: 测试 PASS；`cat "$_` 计数为当前基线值（记下来）。

- [ ] Step 2: 确认基线绿
  - Run: `bash tests/orchestration/cmd_dev.sh; echo "rc=$?"`
  - Expected: rc=0（全绿基线）。

- [ ] Step 3: 重构 modify 分支
  - 把 `cat "$_m_stderr_file" >&2 2>/dev/null || true; rm -f "$_m_stderr_file"` + `case "$_stage" in cd|setup|postcondition) error "ob dev modify: build env not ready (stage=$_stage)." >&2; exit 1;; esac` + `if [[ "$_mrc" -ne 0 ]]; then error "ob dev modify: devtool failed (rc=$_mrc, stage=$_stage)." >&2; exit 1; fi` 三段，换成单行 `dev_relay_result modify "$_m_stderr_file" "$_stage" "" "$_mrc" || exit 1`（phase 传空，modify 无 phase；rc 表 default 分支产 `devtool failed (rc,stage)`，与现状逐字一致）；保留 `printf '%s\n' "$_srctree"; exit 0`。
  - **refresh 不在本任务**（结构特殊：无 stage-case、stage 折进 rc message `failed (stage=X)`，套 relay 会 drift；保持 inline）。
  - Change: modify 分支 boilerplate 收成 relay 单行调用。

- [ ] Step 4: 运行并确认通过
  - Run: `bash tests/orchestration/cmd_dev.sh && grep -c 'cat "\$_' lib/commands.sh`
  - Expected: cmd_dev.sh rc=0（modify 既有断言全过——证明 relay 字节 faithful）；`cat "$_` 计数比基线少 1。

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add lib/commands.sh && git commit -m "refactor(dev): cmd_dev modify via dev_relay_result"`
  - Expected: commit 成功。

---

### Task A4: 重构 cmd_dev 的 status/reset/finish 分支到 relay + encoder

- 目标：把带 JSON encode 的 3 分支改用 `dev_relay_result` + `dev_emit_*`，**JSON 字节 faithful**（约束 2）。
- Files:
  - Modify: `lib/commands.sh::cmd_dev` status 分支（`:1179`）、reset 分支（`:1069`）、finish 分支（`:1121`）
- 验证范围：`bash tests/orchestration/cmd_dev.sh` 全绿（status/reset/finish 既有 JSON/phase 断言不变，含 `phase=finish`、`landing`、`metadata` 等子串）；`tools/ob_check.sh` 全绿；`grep -c 'python3 -c' lib/commands.sh` 显著下降（3 处 inline encode 移除）。
- 接口契约:
  - Consumes: `dev_relay_result`（A1）、`dev_emit_reset_json`/`dev_emit_finish_json`/`dev_emit_status_jsonl`（A2）。
  - Produces: 无（内部重构，Commit A 收口）。

- [ ] Step 1: 记录基线
  - Run: `bash tests/orchestration/cmd_dev.sh; echo "rc=$?"; grep -c "python3 -c" lib/commands.sh`
  - Expected: rc=0；记下 python3 -c 基线计数。

- [ ] Step 2: 确认基线绿
  - Run: `bash tests/orchestration/cmd_dev.sh; echo "rc=$?"`
  - Expected: rc=0。

- [ ] Step 3: 重构 status/reset/finish 分支
  - **status**（完整骨架——空 entries warn 路径位置必须明确，否则回归）：

```bash
        status)
            if [[ "${DRY_RUN:-0}" == "1" ]]; then
                notice "[DRY-RUN] ob dev status: would list modified recipes via devtool status." >&2
                exit 0
            fi
            local _st_entries="" _st_stage="" _st_stderr_file="" _st_rc=0
            devtool_status_run "$dev_machine" "$dev_build_dir" _st_entries _st_stage _st_stderr_file || _st_rc=$?
            dev_relay_result status "$_st_stderr_file" "$_st_stage" "" "${_st_rc:-0}" || exit 1
            if [[ -z "$_st_entries" ]]; then
                warn "No modified recipes for $dev_machine." >&2
                exit 0
            fi
            dev_emit_status_jsonl "$_st_entries" || { error "ob dev status: failed to encode result JSONL." >&2; exit 1; }
            exit 0
            ;;
```

    - 注意顺序：`devtool_status_run` → **先 `dev_relay_result`**（cat/rm stderr + stage/rc 诊断；rc 表 status 分支产 `devtool status failed (rc=X)` 与现状一致）→ **再判空 entries warn**（空时 exit 0，不调 encoder）→ **再 emit**。relay 在 warn 前：rc=0 时 relay return 0（只 cat/rm），不干扰 warn。
  - **reset**：`devtool_reset_run` 调用后，`cat/rm` + `case stage` + `case phase` + `if rc` → `dev_relay_result reset "$_reset_stderr_file" "$_reset_stage" "$_reset_phase" "$_reset_rc" || exit 1`；inline python 7 字段 encode + `devtool_emit_json` → `dev_emit_reset_json "$dev_recipe" "$_reset_srctree" "$_reset_srctreebase" "$_reset_disposition" "$_reset_destination_parent" "$_reset_cleaned_bbappend" || { error "ob dev reset: result JSON malformed." >&2; exit 1; }`。
  - **finish**：同 reset 形态——`dev_relay_result finish "$_finish_stderr_file" "$_finish_stage" "$_finish_phase" "$_finish_rc" || exit 1` + `dev_emit_finish_json` 11 参数（含 landing_* + patches/recipe_files JSON 串 + srcrev）`|| { error …; exit 1; }`。
  - 关键：phase 映射交 relay 的 verbatim 表（含 metadata 句中 token），不再在 cmd_dev 内 `case "$_phase"`。rc 表 status 分支与 default 分支分别对齐。字段序/None 规则由 encoder 保证（A2 已锁字节）。
  - Change: 3 分支 boilerplate + inline python 收成 relay + encoder 调用。

- [ ] Step 4: 运行并确认通过（Commit A 收口门）
  - Run: `tools/ob_check.sh && bash tests/run_all.sh && grep -c "python3 -c" lib/commands.sh`
  - Expected: `ob_check.sh` ALL GREEN（含 run_all 全绿）；python3 -c 计数比基线降（reset+finish+status 三处 inline encode 移除）。
  - 若 cmd_dev.sh 红 → encoder 字节不 faithful，回 A2 修字段序/None 规则，**不**改测试断言（既有断言是契约）。

- [ ] Step 5: Commit A checkpoint
  - Run: `git add -A && git commit -m "$(cat <<'EOF'
refactor(dev): deepen cmd_dev dispatch/emit seam

Extract dev_relay_result (lib/devtool_dispatch.sh, per-subcmd verbatim message
table) + dev_emit_reset/finish/status encoders (lib/devtool_porcelain.sh) as
leaf-pure modules; migrate cmd_dev modify/status/reset/finish branches off
inlined cat/rm+stage/phase/rc+python-encode boilerplate (refresh/list stay
inline — structurally distinct; status warn path stays after relay / before
encoder, byte-identical to prior order). Behavior-preserving:
stdout/stderr/exit-code byte-faithful (existing tests are the regression lock).
cmd_dev retains sole exit ownership (ADR-0010). build/deploy remain stubs.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"`
  - Expected: commit 成功；Commit A 完成。

---

### Task B1: 创建 `devtool_build_run` leaf-pure 模块

- 目标：抽出 build assembler（status-first not-modified 信号 + devtool build）。
- Files:
  - Create: `lib/devtool_build.sh`
  - Create: `tests/unit/devtool_build.sh`
  - Modify: `tools/exit_contract.py`（`LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 加 `'devtool_build.sh': set(),`）
  - Modify: `rules/03_WORKSPACE.md`（lib 索引加 `devtool_build.sh`）
- 验证范围：`bash tests/unit/devtool_build.sh` exit 0；exit_contract `Y: PASS`（devtool_build）；extract_funcs 无违规。
- 接口契约:
  - Consumes: `_devtool_env_exec` / `_devtool_parse_status_all`（`lib/devtool_workspace.sh`，既有）。
  - Produces: `devtool_build_run <machine> <build_dir> <recipe> <stage_outvar> <stderr_file_outvar> <not_modified_outvar>`（leaf-pure，返回 rc）。B2 消费。

- [ ] Step 1: 写失败单测 `tests/unit/devtool_build.sh`
  - 照 `tests/unit/devtool_modify.sh` scaffold（mock devtool/setup/bitbake-layers on PATH + MOCK_*_RC）。mock devtool 加 `build)` 分支（记录调用 + exit `${MOCK_BUILD_RC:-0}`）。
  - 断言点（**显式锁 not_modified 与 stage 的配对**，防 🔴2 回归）：
    - ① recipe 未 modified（status 无该行）→ `not_modified_outvar=1`，devtool build **未被调**（mock build 调用计数 0），stage=command，rc=0。
    - ② recipe 已 modified → build 被调一次，`not_modified_outvar=""`，stage=command，stderr_file 存在，rc=0。
    - ③ **status 失败（MOCK_STATUS_RC=1，stage=setup）→ `not_modified_outvar=""`（不是 1！）+ `stage_outvar=setup`（非空）+ rc≠0**，且 devtool build **未被调**（build 调用计数 0——status 失败不 fall-through 跑 build）。这是 🔴2 的核心回归锁：status 失败必须走 stage 路径（→ cmd_dev exit 1 "build env not ready"），不得误报 not_modified（→ exit 3）。
    - ④ build 失败（MOCK_BUILD_RC=1，status 成功 + recipe modified）→ `not_modified=""`，stage=command，rc=1。
    - ⑤ leaf-pure：函数不 exit（`devtool_build_run … || rc=$?` 能捕获，rc 可被调用者读）。
  - Run: `bash tests/unit/devtool_build.sh`
  - Expected: 失败（模块不存在）。

- [ ] Step 2: 运行并确认失败
  - Run: `bash tests/unit/devtool_build.sh 2>&1 | tail -5`
  - Expected: source/函数未定义错误。

- [ ] Step 3: 写最小实现 `lib/devtool_build.sh`
  - **镜像 `devtool_modify_run`（`lib/devtool_modify.sh:9-41`）结构**：rc=0 显式初始化；status 失败 → 回传 stage + rc，**不继续 build**（防 🔴2 fall-through bug）；status 成功才查 modified。

```bash
#!/usr/bin/env bash
# lib/devtool_build.sh — ob dev build 执行(leaf-pure module)。
#   devtool_build_run: status-first(recipe 未 modified → not_modified 信号, 不 build; status 失败 → 回传 stage+rc, 不继续)
#   → devtool build。镜像 devtool_modify_run 结构。消费 lib/devtool_workspace.sh 的 _devtool_env_exec / _devtool_parse_status_all。
#   术语见 CONTEXT.md ob dev build。
# Exit: leaf-pure module(函数绝不 exit; 允许文件/进程副作用); 调用者(cmd_dev)负责 exit-code/remedy/诊断。

# devtool_build_run <machine> <build_dir> <recipe> <stage_outvar> <stderr_file_outvar> <not_modified_outvar>
# step1 devtool status(rc=0 显式初始化; 失败 → 回传 stage+rc, return rc, 不查 modified 不 build)
#   → status 成功 + recipe 不在 modified 列表 → not_modified=1, return 0(前置缺失, cmd_dev exit 3)
#   → 在列 → devtool build <recipe> → 回传 stage+rc。stderr_file 传 caller(dev_relay_result cat+rm)。
devtool_build_run() {
    local machine="$1" build_dir="$2" recipe="$3"
    local stage_outvar="$4" stderr_file_outvar="$5" not_modified_outvar="$6"
    local stage_file stdout_file stderr_file rc=0 entries=""
    stage_file="$(mktemp 2>/dev/null)"; stdout_file="$(mktemp 2>/dev/null)"; stderr_file="$(mktemp 2>/dev/null)"
    # 1. status 查 modified(失败 → 回传 stage+rc, 不继续)
    : > "$stdout_file"
    _devtool_env_exec "$machine" "$build_dir" "$stage_file" "$stdout_file" "$stderr_file" -- devtool status || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf -v "$not_modified_outvar" '%s' ""
        printf -v "$stage_outvar" '%s' "$(cat "$stage_file" 2>/dev/null || true)"
        printf -v "$stderr_file_outvar" '%s' "$stderr_file"
        rm -f "$stage_file" "$stdout_file"
        return "$rc"
    fi
    entries="$(_devtool_parse_status_all "$stdout_file")"
    if ! grep -qF "$recipe"$'\t' <<<"$entries"; then
        printf -v "$not_modified_outvar" '%s' "1"
        printf -v "$stage_outvar" '%s' "$(cat "$stage_file" 2>/dev/null || true)"
        printf -v "$stderr_file_outvar" '%s' "$stderr_file"
        rm -f "$stage_file" "$stdout_file"
        return 0
    fi
    # 2. modified → devtool build
    rc=0
    : > "$stdout_file"
    _devtool_env_exec "$machine" "$build_dir" "$stage_file" "$stdout_file" "$stderr_file" -- devtool build "$recipe" || rc=$?
    printf -v "$not_modified_outvar" '%s' ""
    printf -v "$stage_outvar" '%s' "$(cat "$stage_file" 2>/dev/null || true)"
    printf -v "$stderr_file_outvar" '%s' "$stderr_file"
    rm -f "$stage_file" "$stdout_file"
    return "$rc"
}
```

  - exit_contract.py `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 加 `'devtool_build.sh': set(),`。
  - WORKSPACE.md lib 索引加 `devtool_build.sh` 条目（照格式：`devtool_build.sh ob dev build 执行(status-first not-modified 信号 + devtool build, 镜像 modify_run; leaf-pure)`）。
  - Change: 新建 build 模块（镜像 modify_run）+ 注册 + 索引。

- [ ] Step 4: 运行并确认通过
  - Run: `bash tests/unit/devtool_build.sh && python3 tools/exit_contract.py 2>&1 | grep '^Y:' && python3 tools/extract_funcs.py lib/devtool_build.sh`
  - Expected: 单测 exit 0；`Y: PASS`；extract_funcs 无违规。

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add lib/devtool_build.sh tests/unit/devtool_build.sh tools/exit_contract.py rules/03_WORKSPACE.md && git commit -m "feat(dev): add devtool_build_run leaf-pure assembler"`
  - Expected: commit 成功。

---

### Task B2: cmd_dev 加 build 分支 + TTY 菜单第 7 项

- 目标：在干净 seam 上加 `ob dev build` 分支（非 TTY + TTY 两条路径）。
- Files:
  - Modify: `lib/commands.sh::cmd_dev`（arg parser `build)` 已在 `:838`；dispatch 加 `build)` 真分支；TTY 菜单加第 7 项 + build recipe 补参段；菜单 prompt `[1-6]`→`[1-7]`）
  - Modify: `tests/orchestration/cmd_dev.sh`（加 build 分支 case）
  - Modify: `tests/protocol/dev_interactive.exp`（line 122/147 的 `\[1-6\]`→`\[1-7\]`——菜单 prompt 变了，.exp 的 prompt 断言必须同步，否则 `run_all --full` 红；可选加一个 build TTY 场景，照 reset/finish mock 段 `:106-133`）
- 验证范围：`bash tests/orchestration/cmd_dev.sh` 全绿（build：not-modified→exit 3 + modify remedy；success→exit 0 空 stdout；stage/rc fail→exit 1；DRY_RUN→notice+exit 0）；`expect tests/protocol/dev_interactive.exp` 全绿（菜单 `[1-7]` 断言通过）。
- 接口契约:
  - Consumes: `devtool_build_run`（B1）、`dev_relay_result`（A1）。
  - Produces: `cmd_dev` build 分支（dispatch 真分支，不再是 `*) reserved`）。

- [ ] Step 1: 写失败 orchestration case（加进 `tests/orchestration/cmd_dev.sh`，照 reset/finish mock 段模式）
  - mock `devtool_build_run`：① not_modified=1 → 断言 exit 3 + stderr 含 `not modified` + 含 `ob dev --machine testm modify`；② not_modified="" stage=command rc=0 → exit 0 + stdout 空（`assert_eq "build success stdout 空" "$RUN_OUT" ""`）；③ stage=postcondition → exit 1 + stderr 含 `build env`；④ stage=command rc=2 → exit 1 + stderr 含 `devtool`；⑤ DRY_RUN → exit 0 + stderr 含 `[DRY-RUN] ob dev build`。
  - Run: `bash tests/orchestration/cmd_dev.sh`
  - Expected: 失败（build 分支仍走 `*) reserved → exit 1`，not-modified case 期望 3 拿到 1）。

- [ ] Step 2: 运行并确认失败
  - Run: `bash tests/orchestration/cmd_dev.sh 2>&1 | tail -8`
  - Expected: build case FAIL（exit 1 reserved，不符期望）。

- [ ] Step 3: 写最小实现（4 处改动）
  - **(a) arg parser 内层 case 加 build（🔴3，必做，否则 `ob dev build myrecipe` exit 1 unexpected argument）**：`lib/commands.sh:845` 和 `:854` 两处内层 `case "$dev_subcmd" in` 的 `modify|reset|finish)` → `modify|reset|finish|build)`（两处都改——第一处是 subcmd token 后的位置参数分支，第二处是 fallback positional 分支）。

```bash
                    case "$dev_subcmd" in
                        list)   [[ -z "$dev_pattern" ]] || { error "ob dev list: too many patterns" >&2; exit 1; }; dev_pattern="$1" ;;
                        modify|reset|finish|build) [[ -z "$dev_recipe" ]] || { error "ob dev $dev_subcmd: too many recipes" >&2; exit 1; }; dev_recipe="$1" ;;
                        *)      error "ob dev $dev_subcmd: unexpected argument '$1'" >&2; exit 1 ;;
                    esac
```

  - **(b) dispatch `case "$dev_subcmd"` 加 `build)` 分支**（status 后）：

```bash
        build)
            if [[ -z "$dev_recipe" ]]; then
                error "ob dev build: no recipe specified." >&2
                error "Run 'ob dev --machine $dev_machine status' to list modified recipes first." >&2
                exit 3
            fi
            if [[ "${DRY_RUN:-0}" == "1" ]]; then
                notice "[DRY-RUN] ob dev build $dev_recipe: would devtool build (do_build)." >&2
                exit 0
            fi
            local _b_stage="" _b_stderr="" _b_notmod="" _b_rc=0
            devtool_build_run "$dev_machine" "$dev_build_dir" "$dev_recipe" _b_stage _b_stderr _b_notmod || _b_rc=$?
            if [[ "$_b_notmod" == "1" ]]; then
                # not_modified: status 成功(stage=command/rc=0)但 recipe 不在 modified 列表。
                # 直接 cat+rm stderr, 不经 relay(避免依赖"三条件都不触发表"的隐式行为)。
                cat -- "$_b_stderr" >&2 2>/dev/null || true
                rm -f -- "$_b_stderr" 2>/dev/null || true
                error "Recipe '$dev_recipe' is not modified (not in devtool workspace)." >&2
                error "Run 'ob dev --machine $dev_machine modify $dev_recipe' first." >&2
                exit 3
            fi
            dev_relay_result build "$_b_stderr" "$_b_stage" "" "${_b_rc:-0}" || exit 1
            exit 0   # 空 stdout(exit code 承载成败)
            ;;
```

    - 注：`_b_notmod=1` 只在 status **成功** + recipe 不在列时发生（B1 🔴2 修订保证 status 失败走 rc≠0+not_modified="" → 不进此 if）→ 此时 `_b_stage=command`/`_b_rc=0`，relay 的 "cat+rm only" 调用安全（stage=command 不触发 stage-fail，rc=0 不触发 rc-fail）。
  - **(c) TTY 菜单第 7 项**（cmd_dev `:896-919` 附近）：菜单 echo 加 `echo "    7) build   devtool build a recipe (outputs nothing on stdout, exit code carries result)"`；prompt `Select subcommand [1-6]` → `[1-7]`；selection case 加 `7) dev_subcmd="build" ;;`。
  - **(d) build TTY 补参段**（cmd_dev `:921` 的 `case "$dev_subcmd" in` 内，`reset|finish)` 旁加 `build)`——照 reset/finish TTY pick 段 `:939-973` 同结构）：

```bash
            build)
                # TTY build: 跑 devtool status 列已 modify recipe → 空 exit 3 / 非空编号 pick(照 reset|finish)
                local _bst_entries="" _bst_stage="" _bst_stderr_file="" _bst_rc=0
                devtool_status_run "$dev_machine" "$dev_build_dir" _bst_entries _bst_stage _bst_stderr_file || _bst_rc=$?
                cat "$_bst_stderr_file" >&2 2>/dev/null || true
                rm -f "$_bst_stderr_file" 2>/dev/null
                case "$_bst_stage" in cd|setup|postcondition) error "ob dev build: build env not ready (stage=$_bst_stage)." >&2; exit 1;; esac
                if [[ "$_bst_rc" -ne 0 ]]; then error "ob dev build: devtool status failed (rc=$_bst_rc)." >&2; exit 1; fi
                local -a _bst_recipes=() _bst_r=""
                while IFS=$'\t' read -r _bst_r _; do [[ -n "$_bst_r" ]] && _bst_recipes+=("$_bst_r"); done <<< "$_bst_entries"
                if [[ ${#_bst_recipes[@]} -eq 0 ]]; then
                    warn "No modified recipes for $dev_machine." >&2
                    error "Run 'ob dev --machine $dev_machine modify <recipe>' first." >&2
                    exit 3
                fi
                local _bst_i _bst_w=${#_bst_recipes[@]}
                for (( _bst_i=0; _bst_i<_bst_w; _bst_i++ )); do printf '  %d) %s\n' "$((_bst_i + 1))" "${_bst_recipes[$_bst_i]}" >&2; done
                local _bst_prc=0
                read_list_choice "$_bst_w" "recipe" "build" _bst_recipes dev_recipe >&2 || _bst_prc=$?
                if [[ "$_bst_prc" -eq 2 ]]; then exit 2; fi
                if [[ "$_bst_prc" -ne 0 ]]; then exit 1; fi
                ;;
```

  - **(e) `tests/protocol/dev_interactive.exp`**：line 122 与 line 147 的 `-re {Select subcommand.*\[1-6\].*0 to cancel}` → `\[1-7\]`（菜单 prompt 已变）。可选：照 reset mock 段（`:106-133`）加 build TTY 场景（mock `devtool_status_run` 返空 → send 7 → expect `No modified recipes` → exit 3）。
  - Change: (a) parser 内层 case 加 build + (b) dispatch build 分支 + (c) 菜单第 7 项 + (d) build TTY 补参段 + (e) .exp prompt 断言同步。

- [ ] Step 4: 运行并确认通过
  - Run: `bash tests/orchestration/cmd_dev.sh && expect tests/protocol/dev_interactive.exp; echo "exp_rc=$?" && python3 tools/exit_contract.py 2>&1 | grep '^X:\|^Y:'`
  - Expected: cmd_dev.sh rc=0（含新 build case）；`.exp` exp_rc=0（PASS，菜单 `[1-7]` 断言通过）；exit_contract X/Y PASS（build 分支 exit 3 有 remedy 前置 error 过 Z；cmd_dev 是 exit seam，X 合法）。若 `.exp` 超时/FAIL → 多半漏改 `[1-7]` 或菜单第 7 项 echo 文案不符 `.exp` 既有 `5) status`/`6) finish` 字面断言（`:118-119,144`）。

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add lib/commands.sh tests/orchestration/cmd_dev.sh && git commit -m "feat(dev): cmd_dev build branch + TTY menu option 7"`
  - Expected: commit 成功。

---

### Task B3: usage 注册 build + usage_dispatch_sync 断言块

- 目标：usage dev 行加 build；protocol 测试锁登记。
- Files:
  - Modify: `ob`（usage dev 行 `:189`：`<list|modify|refresh|reset|status|finish>` → `<list|modify|build|refresh|reset|status|finish>`；examples 段 `:239` 后加 build 示例行）
  - Modify: `tests/protocol/usage_dispatch_sync.sh`（加 build 登记块）
- 验证范围：`bash tests/protocol/usage_dispatch_sync.sh` exit 0（usage 含 build；`refresh|reset|status|finish` 子串仍命中 `:90`；DEV_ARGS handoff；main dev build→cmd_dev）。
- 接口契约:
  - Consumes: `cmd_dev` build 分支（B2）。
  - Produces: 无。

- [ ] Step 1: 写失败 protocol 断言块（加进 `tests/protocol/usage_dispatch_sync.sh`，照 finish 段 `:101-109`）
  - `assert_contains "usage dev 行含 build" "$_usage_out3" "build"`；`assert_contains "usage dev 行枚举含 modify|build" "$_usage_out3" "modify|build"`；`parse_args dev --machine m build myrecipe` → DEV_ARGS[2]=build / [3]=myrecipe；`main dev --machine m build myrecipe`（mock cmd_dev 捕获）→ 含 `GOT:build` / `GOT:myrecipe`。
  - Run: `bash tests/protocol/usage_dispatch_sync.sh`
  - Expected: 失败（usage 不含 build）。

- [ ] Step 2: 运行并确认失败
  - Run: `bash tests/protocol/usage_dispatch_sync.sh 2>&1 | tail -5`
  - Expected: usage-contains-build 断言 FAIL。

- [ ] Step 3: 写最小实现
  - `ob` usage dev 行改为 `dev          [--machine <machine>] <list|modify|build|refresh|reset|status|finish>  Develop recipes via devtool (TTY prompts if omitted)`。
  - examples 段加：`  # ob dev --machine romulus build phosphor-ipmi-host  # devtool build (single recipe, do_build), exit code carries result`。
  - Change: usage 字符串 + example。

- [ ] Step 4: 运行并确认通过
  - Run: `bash tests/protocol/usage_dispatch_sync.sh; echo "rc=$?"`
  - Expected: rc=0（含新 build 块 + 既有 reset/status/finish 块 + `refresh|reset|status|finish` 子串 `:90` 仍命中）。

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add ob tests/protocol/usage_dispatch_sync.sh && git commit -m "feat(dev): register ob dev build in usage + dispatch sync test"`
  - Expected: commit 成功。

---

### Task B4: integration build e2e + workflow_02 文档

- 目标：modify→build→reset e2e（断言 ob rc==devtool 实际结果，自带 exit 77 SKIP）；workflow 补 build。
- Files:
  - Modify: `tests/integration/ob_dev.sh`（reset 段 modify 后 `:253` 插 build 步）
  - Modify: `rules/skills/workflow_02-obmc_dev_modify.md`（工作流补 build 步 + porcelain 段加 build 空 stdout）
- 验证范围：`bash tests/integration/ob_dev.sh` —— 无 init machine → exit 77 SKIP（不假失败）；有 env → build 步执行且断言 ob rc 反映 devtool build 实际结果（非"必须成功"）。
- 接口契约:
  - Consumes: `ob dev build`（B2/B3 完整链路）。
  - Produces: 无。

- [ ] Step 1: 改动前观察
  - Run: `bash tests/integration/ob_dev.sh 2>&1 | head -3; echo "rc=$?"`
  - Expected: rc=77（SKIP：无 init machine）或当前 e2e 结果——记录基线。

- [ ] Step 2: 确认当前 SKIP/基线
  - Run: `bash tests/integration/ob_dev.sh >/dev/null 2>&1; echo "rc=$?"`
  - Expected: rc=77（典型 dev 机无完整 OpenBMC env）——这是合法 SKIP，不是失败。

- [ ] Step 3: 插 build e2e 步
  - 在 `tests/integration/ob_dev.sh` reset 段 modify 后（`./ob dev --machine "$MACHINE" modify "$RECIPE"` 成功断言后、reset 前，约 `:253` 后）插：

```bash
    # === build 段: modify 后单 recipe 编译(ob rc 反映 devtool build 实际结果, 非"必须成功") ===
    CLEANUP_NEEDED=1   # modify 已置; build 不改 workspace, 但 recipe 仍 modified 需下游 reset 清
    local _build_rc=0
    ./ob dev --machine "$MACHINE" build "$RECIPE" >/dev/null 2>&1 || _build_rc=$?
    echo "build rc=$_build_rc (ob relay; 0=devtool build 成功 / 1=失败, 均合法)"
    # build 不改 workspace 状态, 不断言"必须编通"(recipe 自身依赖问题与 ob 正确性无关);
    # 只断言 ob 没误报 exit 2/3(build 无取消/前置缺失路径: recipe 已 modified, machine 已 init)。
    # 若 rc=3: 核对 `ob dev --machine $MACHINE status` 返回值——status 自身 rc!=0 时 ob 走 relay exit 1(不到 rc=3),
    #   故 rc=3 必是 status rc=0 但 ob 漏判 recipe 未 modified(B1 not_modified 检查漏了刚 modify 的 recipe:
    #   可能 _devtool_parse_status_all 解析问题, 或 modify 步骤未真正落 workspace)。这不是 B1 🔴2 回归(那是 status-fail 路径)。
    [[ "$_build_rc" -eq 0 || "$_build_rc" -eq 1 ]] || { echo "FAIL: build rc=$_build_rc (want 0/1; rc=3 见上方提示)"; exit 1; }
```

  - workflow_02 工作流第 5 步后加 build 步（modify→**build**→finish/reset）；porcelain 段加 `ob dev --machine <m> build <recipe>` stdout：空（exit code 承载，0=编通/1=失败，bitbake log 在 stderr）；边界段 ob dev 做/不做更新（build 列入"做"）。
  - Change: integration 加 build 步（rc-relay 断言）+ workflow 文档。

- [ ] Step 4: 运行并确认通过
  - Run: `bash tests/integration/ob_dev.sh >/dev/null 2>&1; echo "rc=$?"`
  - Expected: rc=77（SKIP，无 env，合法）或 rc=0（有 env，build 步 ob rc∈{0,1}）。若 rc=1 且非 SKIP → build 步 ob rc∉{0,1}，查 build 分支 exit-code。

- [ ] Step 5: Commit B checkpoint（最终）
  - Run: `git add -A && git commit -m "$(cat <<'EOF'
feat(dev): ob dev build — close the inner-loop compile gap

Add ob dev build <recipe> (devtool build, do_build) as the fast inner-loop
single-recipe compile between modify and reset/finish. Empty stdout + exit
code carries result (mirrors refresh). Requires modified recipe (exit 3 +
remedy otherwise). build is a single devtool call (no phase), doesn't touch
workspace state (orthogonal to ADR-0008/0009). deploy remains stub.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"`
  - Expected: commit 成功；Commit B 完成。

---

## 执行纪律

- 开始实现前，先批判性复查整份计划 + 设计文档；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 严格按 A1→A2→A3→A4→B1→B2→B3→B4 顺序，不跳步、不合并、不改任务目标。
- 每任务 Step 4 的验证必须过才进下一任务。Commit A 收口门（A4 Step 4）全绿才进 B1（约束 1）。
- 遇阻塞、重复失败或计划与仓库现实不符，立即停下说明，不猜。
- 当前在 `main` 分支：开始实现前与用户确认是否新建分支（`git checkout -b feature/ob-dev-build`）。
- 每任务 Step 5 checkpoint commit 可选；A4/B4 的 commit 是强制自然边界。
- 改 ob/lib 后每任务跑 `tools/ob_check.sh`（约束 4 的 exit_contract + shellcheck baseline + extract_funcs + run_all 聚合）。

## 最终验证

Commit B 完成后，跑全套（Linux + bash）：

- Run: `tools/ob_check.sh`
  - Expected: `ALL GREEN (PASS=…)`，含 extract_funcs lib 三段全清（含新 `devtool_dispatch.sh`/`devtool_build.sh`）、shellcheck baseline CLEAN/REGEN（REGEN 则 `git diff tests/.shellcheck-baseline` 确认良性）、exit-contract X/Y/Z green（Y 覆盖新两 basename）、run_all 绿。
- Run: `bash tests/run_all.sh --full`
  - Expected: protocol（含 `.exp`，dev_interactive.exp `[1-7]` 通过）/ unit（含新 devtool_dispatch/devtool_build/扩 porcelain）/ orchestration（cmd_dev build 分支）全绿。
- Run: `bash tests/run_all.sh --integration`（若环境有 init machine）
  - Expected: integration ob_dev.sh modify→build→reset→finish e2e 绿（或 exit 77 SKIP，合法）。
- 抽检 porcelain 字节 faithful：`./ob dev --machine <m> reset <recipe> 2>/dev/null`（对一 modified recipe）输出与重构前同字段序/同 None 规则（CONTEXT.md `ob dev porcelain stdout` 契约）。
- Run: `./ob dev --help | grep build`
  - Expected: usage dev 行含 `build`（`list|modify|build|refresh|reset|status|finish`）。
- 输出修改摘要：两 commit、新文件、exit_contract 新 basename、测试新增/改动清单。

## 审阅 Checkpoint

实施计划已写好并保存到 `docs/plans/2026-07-19-ob-dev-build-and-dispatch-seam-implementation-plan.md`，完成 inline 自检。请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行。审阅通过前不进入实现。
