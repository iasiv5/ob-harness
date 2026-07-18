# ob dev reset 实施计划

## 目标

把已批准的 [ob dev reset 设计文档 v6](../specs/2026-07-15-ob-dev-reset-design.md) 实现为 `ob dev reset [--machine <machine>] <recipe>` 子命令（默认 source-preserving reset，无 `--remove-work`）+ `lib/devtool_reset.sh`（leaf-pure `devtool_reset_run` + 3 个可单测私有 helper）+ `cmd_dev` reset 分支 + harness 同步，配齐四层测试，`tools/ob_check.sh` 全绿 + `tests/run_all.sh --integration` 通过。

## 架构快照

- `ob dev reset` 是 agent-facing 子命令，machine 用 `--machine` flag（省略时 cmd_dev 复用既有 machine 前置 [:862-884](../../lib/commands.sh#L862-L884)）。
- 新 leaf-pure 模块 `lib/devtool_reset.sh`：`devtool_reset_run`（组装器）+ 3 helper。**helper 调用用固定不碰撞 receiver（`_resolved_*`/`_located_*`/`_classified_*`），helper 内部 `result_*`；helper 用 epilogue `rm -f` 清 tempfile，不安装 EXIT/RETURN trap**。
  - `_devtool_reset_resolve_workspace <build_dir> <raw_out> <effective_out> <phase_out>`
  - `_devtool_reset_locate_bbappend <workspace> <recipe> <status_srctree> <srctreebase_raw_out> <phase_out>`
  - `_devtool_reset_classify <build_dir> <workspace_path_raw> <workspace_path_effective> <srctreebase_raw> <expected_out> <phase_out>`（内部按 build_dir 解析 candidate + stat pre_state + P/O + 重叠）
  - `devtool_reset_run <machine> <build_dir> <recipe> <_srctree_outvar> <_srctreebase_outvar> <_disposition_outvar> <_destination_parent_outvar> <_phase_outvar> <_stage_outvar> <_stderr_file_outvar>`（调三 helper 传 `_resolved_*`/`_located_*`/`_classified_*`，回传 7 outvar `_reset_*`）
- 复用 `lib/devtool_modify.sh` 的 `_devtool_env_exec`/`_devtool_parse_srctree`，靠 ob loader glob 字母序（[ob:73-76](../../ob#L73-L76)，m<r<s 已核实）。
- Python helper（workspace/bbappend/classify 内部 python3）↔ Bash 用 **tempfile NUL framing + sentinel 协议**。
- `cmd_dev`（[commands.sh](../../lib/commands.sh)）是唯一 exit seam + porcelain；`--remove-work` 落 [:850](../../lib/commands.sh#L850) `-*` exit 1；reset positional recipe 在 cmd_dev **两处** case（[:843-847](../../lib/commands.sh#L843-L847)+[:851-858](../../lib/commands.sh#L851-L858)）都需 `modify|reset)`。reset case 替换 [:1028-1031](../../lib/commands.sh#L1028-L1031)。

## 全局约束

逐字继承设计 v6 + 评审终审 5 条 + 实施计划评审 round-1~6，全程不可违反：

- `ob` 不内嵌 LLM；默认 source-preserving reset，无 `--remove-work`（收到 exit 1）。
- `lib/devtool_reset.sh` leaf-pure（不 exit），登记 `exit_contract.py`；exit/remedy 只在 `cmd_dev`。
- porcelain：`cmd_dev` 不调 `log`/`info`/`warn`，诊断 `error`/`>&2`；stdout 只 JSON 单行；JSON 经 tempfile 原子发布（失败 stdout 空）。
- exit-code 遵循 [exit-code 契约](../../CONTEXT.md) + [ADR-0008](../adr/0008-ob-dev-cleanup-fail-safe.md)（失败即止不降级，status 失败不降级空）。
- 不改 `modify`/`list`/`refresh` 既有行为；不改 `_devtool_env_exec`/`_devtool_parse_srctree`。
- **无并发 writer 前提**：reset/integration 不与其他 ob/devtool workspace writer 并发；二次 status + 文件检查只检测异常，不提供 snapshot isolation。
- **实施约束（评审终审 5 条）**：① workspace_path_raw=configparser.get 未 canonicalize；② 缺配置默认 `os.path.join(build_dir,"workspace")`；③ P 逐字 `srctreebase_raw.startswith(os.path.join(workspace_path_raw,"sources"))`；④ JSON 编码失败 cmd_dev exit 1；⑤ 验证 ob_check + 单独 `--integration`。
- **outvar 命名（固定不碰撞 receiver）**：cmd_dev→`devtool_reset_run` 传 `_reset_*`；`devtool_reset_run`→helper 传 `_resolved_*`/`_located_*`/`_classified_*`；helper 内 `result_*`。测试用生产 receiver 调用。
- **helper 不安装 trap**：helper 单一 cleanup epilogue，outvar 发布后 `rm -f -- "$tempfile"`，不修改调用方 EXIT/RETURN trap；单测验 trap 不变。
- **NUL framing + sentinel 协议**：python 写 tempfile（每字段 `\0`）+ 末尾 `__OB_NUL_END__\0`；bash 先检 python rc（非零→phase=metadata 不解析）；`mapfile -d ''` 后断言字段数==预期 + 末字段==sentinel；epilogue rm。不用 process substitution/`$(...)`。
- **state file 协议**（🔴1 round-6 修正）：T0 建**唯一** `$STATE_FILE`（`mktemp`，不固定 pointer，agent 持有路径）+ 唯一 `$STATE_DIR`（`mktemp -d ${TMPDIR}/ob-dev-reset.XXXXXX`）+ marker + baseline。**state file 用无标签 NUL 格式**：`printf '%s\0%s\0' "$STATE_DIR" "$MARKER" > "$STATE_FILE"`（**不写 `STATE_DIR=`/`MARKER=` 标签**）。**所有消费者（T5/T8）统一** `mapfile -d '' -t _sf < "$STATE_FILE"` 解析（`_sf[0]`=state_dir，`_sf[1]`=marker），断言字段数==2 + 非空，**禁止 `source`/`.`**。T8 清理前 `pwd -P` canonicalize state dir 与 `${TMPDIR}` 比 dirname+basename + marker + baseline + 所有权，全过才 `rm -rf` + 删 STATE_FILE；不可达/失败→exit 1 不跳过。
- **JSON stdout 精确契约 + 原子发布**（🔴2 round-6）：cmd_dev 字段值作 argv（**用 `"$dev_recipe"`**，非 `$_recipe`——cmd_dev 变量名是 `dev_recipe`，nounset 下 `$_recipe` 失败）传 python；python **先写 JSON 到 tempfile**，精确六字段：
  ```python
  {"recipe": ..., "srctree": ..., "srctreebase": ...,
   "disposition": ...,
   "destination_parent": <destination_parent or None>,   # 空→None，不输出 ""
   "destination": None}                                   # 恒 None
  ```
  noop 时 srctree/srctreebase 为空字符串 `""`。检 python rc（非零→删 tempfile + stderr + exit 1，**stdout 空**）；成功后校验 tempfile 恰好一物理行 + 尾换行 + json.loads，再 `cat` stdout + 删。
- **路径能力边界**：bbappend/status 真实链只普通路径 + 空格；引号/反斜杠/换行全归 T4 mock leaf → argv → json.dumps → json.loads。
- **验证命令严格保 rc + errexit 安全**：正向 `bash tests/<file>.sh`；预期失败 `rc=0; bash ... || rc=$?; (( rc != 0 )) || exit 1`；`diff`/`git status` 等**用 `|| rc=$?` 先存 rc 再断言**（不依赖 errexit/join）。
- **checkpoint commit 可选**：Step 5 仅用户授权。
- **分支运行时检查**：`git branch --show-current` 运行时重查。

## 输入工件

- 设计文档 `docs/specs/2026-07-15-ob-dev-reset-design.md`（v6 已审核通过）。
- 实施计划评审 round-1~6（5🔴+5🟡+🟢 / 6🔴+4🟡 / 4🔴+3🟡 / 5🔴+4🟡 / 4🔴+4🟡 / 3🔴+3🟡），本计划 v7 全吸收。
- [CONTEXT.md](../../CONTEXT.md) ob dev 术语、[ADR-0008](../adr/0008-ob-dev-cleanup-fail-safe.md)。
- 先例：`lib/devtool_modify.sh`、`tests/integration/ob_dev.sh`、`tests/protocol/dev_interactive.exp`（expect）、`REAL_PYTHON` mock 模式。

## 文件结构与职责

**Create:** `lib/devtool_reset.sh`（`devtool_reset_run` + 3 helper）、`tests/unit/devtool_reset.sh`（增量 T1/T2/T3）。
**Modify:** `tools/exit_contract.py`、`lib/commands.sh`、`ob`、`tests/protocol/usage_dispatch_sync.sh`、`tests/protocol/dev_interactive.exp`、`tests/orchestration/cmd_dev.sh`、`tests/integration/ob_dev.sh`、`tests/unit/ob_dev_integration_safety.sh`、`CONTEXT.md`、`rules/03_WORKSPACE.md`、`rules/skills/workflow_02-obmc_dev_modify.md`。

**接口契约主干:** `_devtool_reset_resolve_workspace`（T1，receiver `_resolved_*`）/`_devtool_reset_locate_bbappend`+`_devtool_reset_classify`（T2，`_located_*`/`_classified_*`）→ `devtool_reset_run`（T3，`_reset_*`）→ `cmd_dev` reset（T4）。

---

### Task 0: 执行前置（分支 + 安全 state file，无标签 NUL）

- 目标：运行时确认分支 + 唯一 `$STATE_FILE`/`$STATE_DIR` + marker + baseline（无标签 NUL），agent 持有 `$STATE_FILE`。
- Files: 无。
- 验证范围：分支正确 + state file/dir/marker 生成。
- 接口契约: Consumes 无；Produces `$STATE_FILE`（agent 持有）、`$STATE_DIR`/`$MARKER`（无标签 NUL 写 state file）。

- [ ] Step 1: 分支检查
  - Run: `git branch --show-current`
  - Expected: `feature/ob-dev-devtool-modify`（或用户确认分支）。
- [ ] Step 2: 建唯一 state file + dir + marker + baseline（🔴1：无标签 NUL 格式）
  - Run: `STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ob-dev-reset.XXXXXX")" && MARKER="$(head -c16 /dev/urandom | base32 | tr -d '=')" && printf '%s' "$MARKER" > "$STATE_DIR/.marker" && git status --short > "$STATE_DIR/baseline.txt" && STATE_FILE="$(mktemp "${TMPDIR:-/tmp}/ob-dev-reset-state.XXXXXX")" && printf '%s\0%s\0' "$STATE_DIR" "$MARKER" > "$STATE_FILE" && echo "STATE_FILE=$STATE_FILE STATE_DIR=$STATE_DIR MARKER=$MARKER"`
  - Expected: 任一步失败即中止；STATE_FILE/STATE_DIR 唯一；marker 随机；**无标签 NUL**（消费者 mapfile 读 `_sf[0]`=STATE_DIR 裸路径，无 `STATE_DIR=` 前缀）；agent 保存 `$STATE_FILE`。
- [ ] Step 3-5: 无实现/checkpoint。

---

### Task 1: exit_contract 登记 + 骨架 + _devtool_reset_resolve_workspace（完整矩阵 + sentinel + epilogue）

- 目标：leaf-pure 门禁；`_devtool_reset_resolve_workspace`（workspace 完整默认矩阵 + sentinel + epilogue rm 不 trap）+ unit。
- Files: Modify `tools/exit_contract.py`；Create `lib/devtool_reset.sh`（header + helper）、`tests/unit/devtool_reset.sh`。
- 验证范围：`bash tests/unit/devtool_reset.sh`（workspace helper 完整矩阵 + trap 不变）+ `tools/ob_check.sh`。
- 接口契约: Consumes exit_contract LEAF、devtool.conf configparser；Produces `_devtool_reset_resolve_workspace`、LEAF 登记。

- [ ] Step 1: 写失败测试（`tests/unit/devtool_reset.sh`，workspace helper，**生产 receiver `_resolved_*` + 完整矩阵 + trap 不变**）
  - `_devtool_reset_resolve_workspace <build_dir> _resolved_workspace_raw _resolved_workspace_effective _resolved_phase`，默认矩阵（无文件/无[General]/[General]无 workspace_path→默认；空/仅空白→metadata）；相对/绝对 workspace_path（raw 未 canonicalize，effective 按 build_dir）；**不可读配置**（devtool.conf 设为**目录**，不依赖 chmod 000）/语法损坏→metadata；configparser multiline（空格/换行）NUL 传输不截断。
  - trap 不变：调前 `trap 'echo TEST_TRAP' EXIT`，调后 `trap -p EXIT` 确认未改。
  - Run: `bash tests/unit/devtool_reset.sh`
  - Expected: 失败（helper 未实现）。
- [ ] Step 2: 确认失败
  - Run: `rc=0; bash tests/unit/devtool_reset.sh || rc=$?; (( rc != 0 )) || { echo EXPECTED_FAIL_GOT_PASS >&2; exit 1; }`
  - Expected: 断言通过（非零）。
- [ ] Step 3: 写最小实现
  - `tools/exit_contract.py` LEAF dict 加 `'devtool_reset.sh': set(),`。
  - `lib/devtool_reset.sh`：header + `_devtool_reset_resolve_workspace`：python3 configparser 读 devtool.conf（默认矩阵）；NUL sentinel 协议（tempfile raw\0effective\0phase\0`__OB_NUL_END__`\0 + 退出码；bash 先检 python rc，`mapfile -d ''` + 断言字段数==4 + 末字段==sentinel，否则 phase=metadata）；helper 内 `result_*`；**epilogue**：outvar 发布后 `rm -f -- "$tempfile"`（不 trap）。
- Change: exit_contract +1；lib + helper；unit 矩阵 + trap 用例。
- [ ] Step 4: 运行确认通过
  - Run: `bash tests/unit/devtool_reset.sh`
  - Expected: 通过；`tools/ob_check.sh` → ALL GREEN。
- [ ] Step 5: checkpoint（可选）
  - Run: `git add tools/exit_contract.py lib/devtool_reset.sh tests/unit/devtool_reset.sh && git commit -m "feat(dev): scaffold devtool_reset.sh + _devtool_reset_resolve_workspace"`
  - Expected: commit 成功或跳过。

---

### Task 2: _devtool_reset_locate_bbappend + _devtool_reset_classify（sentinel + epilogue）

- 目标：bbappend 字面定位 + classify（build_dir + 内部 pre_state/P/O/重叠）helper + unit。
- Files: Modify `lib/devtool_reset.sh`、`tests/unit/devtool_reset.sh`。
- 验证范围：`bash tests/unit/devtool_reset.sh`（bbappend + classify helper）。
- 接口契约: Consumes T1 骨架；Produces `_devtool_reset_locate_bbappend`、`_devtool_reset_classify`。

- [ ] Step 1: 写失败测试（扩 unit，bbappend + classify，**生产 receiver `_located_*`/`_classified_*` + trap 不变**）
  - `_devtool_reset_locate_bbappend <workspace> <recipe> <status_srctree> _located_srctreebase_raw _located_phase`：造 `appends/<pn>_<ver>.bbappend`（普通+空格，不含引号/反斜杠/换行）→ 命中；`gstreamer1.0`/PN 前缀相近/注释伪 EXTERNALSRC/多冲突行字面 ==；零/多/EXTERNALSRC≠status_srctree→metadata；无 `# srctreebase:`→srctreebase_raw=status_srctree。
  - `_devtool_reset_classify <build_dir> <workspace_path_raw> <workspace_path_effective> <srctreebase_raw> _classified_expected _classified_phase`（内部 build_dir canonical + stat pre_state + P/O + 重叠）：P/O 矩阵 moved/retained/sources-backup·symlink 出·alias../sources·symlink 入→metadata；重叠 appends/recipes→metadata；pre_state nonempty→P/O/empty_dir→removed/missing→absent/非目录·无法 stat→metadata。
  - trap 不变。
  - Run: `bash tests/unit/devtool_reset.sh`
  - Expected: 失败（两 helper 未实现）。
- [ ] Step 2: 确认失败
  - Run: `rc=0; bash tests/unit/devtool_reset.sh || rc=$?; (( rc != 0 )) || { echo EXPECTED_FAIL_GOT_PASS >&2; exit 1; }`
  - Expected: 断言通过（非零）。
- [ ] Step 3: 写最小实现（sentinel + epilogue rm 不 trap，内部 `result_*`）
  - `_devtool_reset_locate_bbappend`：python 字面 == + 校验 + 恰一；sentinel framing；无注释→srctreebase_raw=status_srctree。
  - `_devtool_reset_classify`：python build_dir+raw+effective+srctreebase_raw → canonical realpath + stat pre_state + P（约束 ③）+ O（commonpath）+ 重叠 → expected/phase（sentinel framing）。
- Change: 两 helper + unit 用例。
- [ ] Step 4: 运行确认通过
  - Run: `bash tests/unit/devtool_reset.sh`
  - Expected: 通过。
- [ ] Step 5: checkpoint（可选）
  - Run: `git add lib/devtool_reset.sh tests/unit/devtool_reset.sh && git commit -m "feat(dev): _devtool_reset_locate_bbappend + _devtool_reset_classify"`
  - Expected: commit 成功或跳过。

---

### Task 3: devtool_reset_run 组装 + 默认 reset + postcondition（普通+空格路径）

- 目标：`devtool_reset_run` 调三 helper（生产 receiver）+ status/noop + 默认 reset + postcondition。
- Files: Modify `lib/devtool_reset.sh`、`tests/unit/devtool_reset.sh`。
- 验证范围：`bash tests/unit/devtool_reset.sh`（devtool_reset_run 各分支）+ `tools/ob_check.sh`。
- 接口契约: Consumes 三 helper（T1/T2）；Produces `devtool_reset_run`（T4 消费）。

- [ ] Step 1: 写失败测试（扩 unit，devtool_reset_run 整体，**只测普通路径 + 空格**）
  - mock build dir + 假 devtool（status/reset stub）+ appends/（普通+空格）+ devtool.conf。
  - 调链：resolve_workspace（`_resolved_*`）→ status → locate_bbappend（`_located_*`）→ classify（`_classified_*`）→ reset → postcondition。
  - 用例：noop；moved；retained；removed（empty_dir）；absent（pre missing）；postcondition 失败→phase=postcondition rc!=0。
  - outvar round-trip：srctreebase/srctree 含空格 → 7 outvar 原样（引号/反斜杠/换行不在此测）。
  - leaf-pure + `_devtool_env_exec` 输出隔离。
  - Run: `bash tests/unit/devtool_reset.sh`
  - Expected: 失败（未组装）。
- [ ] Step 2: 确认失败
  - Run: `rc=0; bash tests/unit/devtool_reset.sh || rc=$?; (( rc != 0 )) || { echo EXPECTED_FAIL_GOT_PASS >&2; exit 1; }`
  - Expected: 断言通过（非零）。
- [ ] Step 3: 写最小实现（`lib/devtool_reset.sh` `devtool_reset_run`）
  - 10 参数（machine/build_dir/recipe + 7 outvar 名）；内部 stage/stdout/stderr tempfiles（epilogue rm，不 trap）。
  - resolve_workspace（`_resolved_*`，phase 非空返回）→ `_devtool_env_exec -- devtool status`→`_devtool_parse_srctree`（phase=status on fail）→ 无行 noop → locate_bbappend（`_located_*`）→ classify（`_classified_*`）→ `_devtool_env_exec -- devtool reset <recipe>`（phase=reset on fail）→ postcondition（二次 status + srctreebase vs `_classified_expected`）。
  - 回传 7 outvar（`printf -v "$_srctree_outvar"`，名=`_reset_*`）；moved 时 destination_parent=`$_resolved_workspace_effective/attic/sources`；返回 rc。不 exit。
- Change: `devtool_reset_run` 组装 + unit 用例。
- [ ] Step 4: 运行确认通过
  - Run: `bash tests/unit/devtool_reset.sh`
  - Expected: 通过；`tools/ob_check.sh` → ALL GREEN。
- [ ] Step 5: checkpoint（可选）
  - Run: `git add lib/devtool_reset.sh tests/unit/devtool_reset.sh && git commit -m "feat(dev): devtool_reset_run orchestration + postcondition"`
  - Expected: commit 成功或跳过。

---

### Task 4: cmd_dev reset 分支 + _reset_ outvar + JSON 六字段精确契约 + tempfile 原子 + REAL_PYTHON mock

- 目标：cmd_dev reset 分支（两处 positional `modify|reset)` + `_reset_*` + **JSON 六字段精确契约 + tempfile 原子** + phase 映射 + 编码失败 stdout 空 + DRY_RUN + `--remove-work` exit 1）+ orchestration（**逐 disposition 精确 key/类型/值断言**）。
- Files: Modify `lib/commands.sh`、`tests/orchestration/cmd_dev.sh`。
- 验证范围：`bash tests/orchestration/cmd_dev.sh`（reset 节 + JSON 六字段精确 + 原子 + 全链路特殊字符）。
- 接口契约: Consumes `devtool_reset_run`（T3）+ machine 前置；Produces cmd_dev reset 分支。

- [ ] Step 1: 写失败测试（`tests/orchestration/cmd_dev.sh` 扩 reset 节，mock `devtool_reset_run`，OB_NO_MAIN=1，**真实 `_reset_*`**）
  - **JSON 六字段精确契约**（🔴2 round-6 + 设计 v6 [:198-206]）：逐 disposition（moved/retained/removed/absent/noop）断言 stdout 恰好一物理行 + json.loads 后**精确 key 集合=={recipe,srctree,srctreebase,disposition,destination_parent,destination}** + 类型/值：
    - moved：srctree/srctreebase 非空（mock 普通+空格）、disposition="moved"、destination_parent=`<ws>/attic/sources`、destination=None。
    - retained/removed/absent：destination_parent=None、destination=None。
    - noop：srctree==""、srctreebase==""、destination_parent=None、destination=None。
  - **JSON 全链路 round-trip 含特殊字符**（引号/反斜杠/换行）：mock `devtool_reset_run` 经 `_reset_*` 返回特殊字符 → argv → json.dumps → json.loads 逐字段精确比较（验证原子发布 + 编码边界）。
  - **JSON 编码失败收口**（约束 ④，REAL_PYTHON）：fake python 只让 JSON 编码失败（其余 `exec "$REAL_PYTHON" "$@"`）→ cmd_dev **删 tempfile + exit 1 + stdout 空**（断言 exit 1 且 `stdout==""`）。
  - disposition/phase 映射 + parser（reset recipe/尾随 dry-run/双 recipe/`--remove-work`）+ 前置（无 recipe→exit 3；machine 未 init→exit 3）+ porcelain（不调 info/warn/log）。
  - Run: `bash tests/orchestration/cmd_dev.sh`
  - Expected: 失败（reset 分支仍 reserved 死路）。
- [ ] Step 2: 确认失败
  - Run: `rc=0; bash tests/orchestration/cmd_dev.sh || rc=$?; (( rc != 0 )) || { echo EXPECTED_FAIL_GOT_PASS >&2; exit 1; }`
  - Expected: 断言通过（非零）。
- [ ] Step 3: 写最小实现（`lib/commands.sh`，**dev_recipe 非 _recipe**）
  - 两处 positional case（[:843-847]+[:851-858]）`modify)`→`modify|reset)`。
  - reset case（[:937]，替换 [:1028-1031]）：无 recipe→exit 3+remedy；DRY_RUN=1→stderr 预览 exit 0；调 `devtool_reset_run "$dev_machine" "$dev_build_dir" "$dev_recipe" _reset_srctree _reset_srctreebase _reset_disposition _reset_destination_parent _reset_phase _reset_stage _reset_stderr_file`；`cat "$_reset_stderr_file" >&2`;rm；按 `_reset_phase`/`_reset_stage`/rc 映射 exit；成功→JSON。
  - **JSON 原子 + 六字段**：`JSON_TMP="$(mktemp)"`；`python3 -c 'import json,sys; print(json.dumps({"recipe":sys.argv[1],"srctree":sys.argv[2],"srctreebase":sys.argv[3],"disposition":sys.argv[4],"destination_parent":sys.argv[5] or None,"destination":None}))' "$dev_recipe" "$_reset_srctree" "$_reset_srctreebase" "$_reset_disposition" "$_reset_destination_parent" > "$JSON_TMP"`；python rc!=0→`rm -f "$JSON_TMP"; error ...; exit 1`（stdout 空）；成功→校验 `$JSON_TMP` 恰好一物理行 + 尾换行 + json.loads → `cat "$JSON_TMP"` → `rm -f "$JSON_TMP"`。（argv 用 `"$dev_recipe"`；destination_parent `or None` 空→None；destination 恒 None。）
- Change: cmd_dev 两处 positional + reset case + orchestration（六字段精确 + REAL_PYTHON mock）。
- [ ] Step 4: 运行确认通过
  - Run: `bash tests/orchestration/cmd_dev.sh`
  - Expected: 通过；`tools/ob_check.sh` → ALL GREEN。
- [ ] Step 5: checkpoint（可选）
  - Run: `git add lib/commands.sh tests/orchestration/cmd_dev.sh && git commit -m "feat(dev): cmd_dev reset branch + atomic 6-field JSON porcelain"`
  - Expected: commit 成功或跳过。

---

### Task 5: ob usage + 交互菜单 reset + dev_interactive.exp + protocol（PTY 守卫，mapfile 读 state file）

- 目标：usage 列 reset；交互菜单 reset 序号 4；`dev_interactive.exp`（expect）reset 交互；protocol 真实 dispatch；PTY 守卫。
- Files: Modify `ob`、`lib/commands.sh`（菜单）、`tests/protocol/usage_dispatch_sync.sh`、`tests/protocol/dev_interactive.exp`。
- 验证范围：`bash tests/protocol/usage_dispatch_sync.sh` + `expect tests/protocol/dev_interactive.exp`（PTY 守卫）。
- 接口契约: Consumes cmd_dev reset（T4）+ `$STATE_FILE`（T0）；Produces reset dispatch + 交互路径。

- [ ] Step 1: 写失败测试（扩 `usage_dispatch_sync.sh` + `dev_interactive.exp`，**先加 reset 断言**）
  - `usage_dispatch_sync.sh`：`ob --help` 含 `ob dev ... reset`（不含 `--remove-work`）；DEV_ARGS；OB_NO_MAIN dispatch；`--remove-work`→exit 1。
  - `dev_interactive.exp`（expect）：选 `4`→recipe prompt→输入 recipe（dry-run/mock）→断言进 reset。
  - Run: `bash tests/protocol/usage_dispatch_sync.sh`
  - Expected: 失败（断言未实现）。
- [ ] Step 2: 确认失败
  - Run: `rc=0; bash tests/protocol/usage_dispatch_sync.sh || rc=$?; (( rc != 0 )) || { echo EXPECTED_FAIL_GOT_PASS >&2; exit 1; }`
  - Expected: 断言通过（非零）。
- [ ] Step 3: 写最小实现
  - `ob` `usage()` dev 行 → `dev  [--machine <machine>] <list|modify|refresh|reset>  Develop recipe sources via devtool`；Examples 加 `ob dev --machine romulus reset phosphor-ipmi-host`。
  - cmd_dev 交互菜单（[:896-913]）：加 `4) reset`；`_sub_choice` `4) dev_subcmd="reset"`；recipe 补参 `reset)`。
  - dev_interactive.exp：reset 交互（选 4 + recipe prompt，dry-run）。
- Change: ob usage + 菜单 + protocol + .exp。
- [ ] Step 4: 运行确认通过（PTY 守卫；🔴1 state file mapfile 无标签读）
  - Run: `bash tests/protocol/usage_dispatch_sync.sh`
  - Expected: 通过。
  - Run: `mapfile -d '' -t _sf < "$STATE_FILE"; (( ${#_sf[@]} == 2 )) || exit 1; _sf_state_dir="${_sf[0]}"; [[ -n "$_sf_state_dir" ]] || exit 1; if command -v expect >/dev/null 2>&1; then expect tests/protocol/dev_interactive.exp > "$_sf_state_dir/dev-exp.log" 2>&1 || { echo "expect rc=$?" >&2; cat "$_sf_state_dir/dev-exp.log"; exit 1; }; if grep -qE '^skip |SKIP=[1-9][0-9]*' "$_sf_state_dir/dev-exp.log"; then echo "PTY skip 假通过" >&2; cat "$_sf_state_dir/dev-exp.log"; exit 1; fi; else echo "expect 不可用：交互路径未验证（记录，不 fail）" >&2; fi`
  - Expected: mapfile 读 `_sf[0]`=state_dir 裸路径（无标签，🔴1 修正）；expect 可用→退出 0 且 log 无行首 `skip `/`SKIP=[1-9]`；不可用→记录未验证。
- [ ] Step 5: checkpoint（可选）
  - Run: `git add ob lib/commands.sh tests/protocol/ && git commit -m "feat(dev): register reset in usage + menu + dev_interactive.exp"`
  - Expected: commit 成功或跳过。

---

### Task 6: integration reset（HARNESS_ROOT + 候选前置 + 同 RECIPE + attic 空集合 + noop smoke + safety）

- 目标：真实 modify→reset moved/retained/noop；**HARNESS_ROOT source 真实 leaf**（仅 source devtool_reset.sh 调 resolve/locate，**不调 devtool_reset_run**——否则需 _devtool_env_exec owner 🟡3）；候选/SKIP 前置；同一 `$RECIPE` moved→retained→noop；**attic/sources 不存在=空集合**（🔴3）；外部 srctree bbappend 读；noop smoke；safety fault-inject。
- Files: Modify `tests/integration/ob_dev.sh`、`tests/unit/ob_dev_integration_safety.sh`。
- 验证范围：`tests/run_all.sh --integration`（无并发 writer）+ `bash tests/unit/ob_dev_integration_safety.sh`。
- 接口契约: Consumes cmd_dev reset（T4）+ ob（T5）+ `ob_dev_integration_cleanup`（既有）+ `_devtool_reset_resolve_workspace`/`_devtool_reset_locate_bbappend`（T1/T2，source 真实 lib）；Produces reset integration + smoke + safety。

- [ ] Step 1: 写失败测试（**先新增** reset integration 断言 + safety fault-inject）
  - `tests/integration/ob_dev.sh` reset 段（HARNESS_ROOT + 前置 + 同 RECIPE + attic 空集合 + leaf source 作用域）：
    - **HARNESS_ROOT**：顶部 `HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"`；**仅 source `devtool_reset.sh`**（🟡3：只调 `_devtool_reset_resolve_workspace`/`_devtool_reset_locate_bbappend`，**不调 `devtool_reset_run`**——后者需 `_devtool_env_exec`/`_devtool_parse_srctree` owner module）；`root_dir`（`OB_DEV_INTEGRATION_ROOT` 可覆盖）分离。
    - **候选/SKIP 前置**：任何 modify 前 `ob dev --machine "$MACHINE" list`（rc+全集）+ `devtool_in_env status`（rc+modified）+ 候选要求 `appends/<recipe>` 不存在；无候选此时 `SKIP:`+`exit 77`。
    - **同一 `$RECIPE`**：候选→managed modify→moved reset→`CLEANUP_NEEDED=0`→external modify 重置 1→retained reset→status 确认退出 workspace→直接同 recipe reset 验 noop（不重选/不后置 SKIP）。失败 trap 权威 status recheck + 清 attic 数组 + external srctree。
    - **moved postcondition + attic 空集合**（🔴3+🟡2）：reset 前 `attic/sources` **不存在→空集合**（不创建/不报失败）；存在→`find "$_resolved_workspace_effective/attic/sources" -maxdepth 1 -type d -print0` 检 find rc + 解析 NUL；reset 后 moved 成功→**确认目录已出现** + find rc + 差集；断言恰好新增一个；trap 删前**字面**验证 basename 前缀 `"$RECIPE."` + 剩余 14 位数字（不插正则）+ canonical parent==effective attic/sources。
    - **外部 srctree**：`EXTERNAL_SRCTREE="$(mktemp -d)" && devtool_in_env "$MACHINE" modify "$RECIPE" "$EXTERNAL_SRCTREE"`；reset 前调 `_devtool_reset_locate_bbappend` 读 bbappend `# srctreebase`；断言==$EXTERNAL_SRCTREE 且非空；默认 reset→retained。
    - 所有 appends/attic/sources/destination_parent 断言基于 `_resolved_workspace_effective`（调 `_devtool_reset_resolve_workspace`）。
  - `tests/unit/ob_dev_integration_safety.sh`：新增 reset cleanup fault-inject（保 ADR-0008）。
  - Run: `bash tests/unit/ob_dev_integration_safety.sh`
  - Expected: 失败（reset fault-inject 未加）。
- [ ] Step 2: 确认失败
  - Run: `rc=0; bash tests/unit/ob_dev_integration_safety.sh || rc=$?; (( rc != 0 )) || { echo EXPECTED_FAIL_GOT_PASS >&2; exit 1; }`
  - Expected: 断言通过（非零）。
- [ ] Step 3: 写最小实现（按 Step 1）
  - HARNESS_ROOT source 真实 leaf（仅 resolve/locate）；resolve effective；候选前置；同 RECIPE moved→retained→noop；**attic 空集合**（`[[ -d "$eff/attic/sources" ]]` 判存在，不存在→空数组）；存在时 find -maxdepth 1 -print0 检 rc；moved 后确认目录出现；字面 basename（前缀+14 位）+ canonical parent 验证；CLEANUP_NEEDED 与 attic 数组分离；外部 srctree bbappend 读；safety fault-inject。
- Change: ob_dev.sh reset 段 + safety fault-inject。
- [ ] Step 4: 运行确认（需真实 build env，无并发 writer）
  - Run: `bash tests/unit/ob_dev_integration_safety.sh`
  - Expected: 通过。
  - Run: `tests/run_all.sh --integration`
  - Expected: 退出 0（reset moved/retained/noop + HARNESS_ROOT + effective + attic 空集合 + 差集 + trap 删 timestamp 目录 + 外部 srctree bbappend 读 + smoke SKIP 77[modify 前]）；环境不具备→SKIP。
- [ ] Step 5: checkpoint（可选）
  - Run: `git add tests/integration/ob_dev.sh tests/unit/ob_dev_integration_safety.sh && git commit -m "test(dev): integration reset (HARNESS_ROOT + attic empty-set + same-recipe)"`
  - Expected: commit 成功或跳过。

---

### Task 7: harness 同步（CONTEXT.md + WORKSPACE.md + workflow_02 + 五独立断言 + 否定语义）

- 目标：agent 知道 reset 存在、JSON 六字段契约、srctree 生命周期；登记路由；**五独立断言 + 否定语义**（🟡2）。
- Files: Modify `CONTEXT.md`、`rules/03_WORKSPACE.md`、`rules/skills/workflow_02-obmc_dev_modify.md`。
- 验证范围：`tools/ob_check.sh` + **精确文档断言**（五独立 grep + destination/destination_parent + workflow 否定语义）。
- 接口契约: Consumes reset 命令形态 + JSON 契约；Produces harness 登记。

- [ ] Step 1: 写失败检查
  - Run: `grep -rl "destination_parent\|devtool_reset.sh" rules/ CONTEXT.md 2>/dev/null | wc -l`
  - Expected: `0`（或仅 specs/plans）。
- [ ] Step 2: 确认缺失
  - Run: `rc=0; grep -rl "destination_parent" CONTEXT.md || rc=$?; (( rc != 0 )) || { echo UNEXPECTED_HIT >&2; exit 1; }`
  - Expected: 断言通过（无命中=非零）。
- [ ] Step 3: 写最小实现
  - `CONTEXT.md` `ob dev porcelain stdout` 补 reset JSON（精确六字段 `{"recipe","srctree","srctreebase","disposition","destination_parent","destination"}`，五 disposition moved/retained/removed/absent/noop，destination_parent 仅 moved 其余 null，destination 恒 null）。
  - `rules/03_WORKSPACE.md`：lib 加 devtool_reset.sh；ob dev 子命令加 reset。
  - `workflow_02-obmc_dev_modify.md`：第 7 步→正式 reset 收尾（`ob dev --machine <m> reset <recipe>` 解除 externalsrc；stdout JSON 读 disposition；moved→归档 `attic/sources/<recipe>.*`，**agent 不得自动清理 attic，需删除时用户手动**；retained→外部保留；无并发 writer；build/deploy/finish 待 ob）。
- Change: CONTEXT.md + WORKSPACE.md + workflow_02。
- [ ] Step 4: 运行确认（🟡2 五独立断言 + destination + 否定语义）
  - Run: `tools/ob_check.sh`
  - Expected: ALL GREEN。
  - 文档断言（**五独立 grep -q + destination + workflow 否定**，🟡2）：
    - CONTEXT 五 disposition 各自独立：`for d in moved retained removed absent noop; do grep -q "\"$d\"" CONTEXT.md || { echo "missing $d" >&2; exit 1; }; done`。
    - CONTEXT destination 字段：`grep -q '"destination"' CONTEXT.md`。
    - WORKSPACE：`grep -q 'devtool_reset.sh' rules/03_WORKSPACE.md && grep -q 'reset' rules/03_WORKSPACE.md`。
    - workflow reset 收尾 + **否定语义**：`grep -q 'reset' rules/skills/workflow_02-obmc_dev_modify.md && grep -qiE '不得自动清理|不自动清理 attic|需删除.*手动' rules/skills/workflow_02-obmc_dev_modify.md && grep -qiE '无并发|不.*并发' rules/skills/workflow_02-obmc_dev_modify.md`（reset + 禁自动清 attic 否定 + 无并发）。
  - Expected: 全部断言命中。
- [ ] Step 5: checkpoint（可选）
  - Run: `git add CONTEXT.md rules/ && git commit -m "docs(dev): harness sync for reset"`
  - Expected: commit 成功或跳过。

---

### Task 8: 最终验证（mapfile 读 state + errexit 安全 diff/git + 安全清理）

- 目标：全量回归 + integration + baseline 对比（errexit 安全）+ 安全清理。
- Files: 无。
- 验证范围：整库绿。
- 接口契约: Consumes 全部前序 + `$STATE_FILE`（agent 持有）；Produces 无。

- [ ] Step 1: ob_check 全绿
  - Run: `tools/ob_check.sh`
  - Expected: ALL GREEN。
- [ ] Step 2: 全量回归（含 .exp，PTY 守卫）
  - Run: `tests/run_all.sh --full`
  - Expected: 退出 0；dev_interactive.exp skip→记录"交互路径未验证"，不宣称已验证。
- [ ] Step 3: integration（约束 ⑤）
  - Run: `tests/run_all.sh --integration`
  - Expected: 退出 0；**integration 返回 77 SKIP 时 runner 总 rc 仍可能 0**——最终报告须分别写"integration 通过（moved/retained/noop 已验证）"或"因环境缺失 SKIP（真实 reset 未验证）"，**不只据总 rc 宣称已验证**；环境不具备→SKIP 记录。
- [ ] Step 4: baseline 对比（🔴1 mapfile 读 + 🟡1 errexit 安全 diff/git）
  - Run: `mapfile -d '' -t _sf < "$STATE_FILE"; (( ${#_sf[@]} == 2 )) || exit 1; _sf_state_dir="${_sf[0]}"; CURRENT="$_sf_state_dir/current.txt"; rc_git=0; git status --short > "$CURRENT" || rc_git=$?; (( rc_git == 0 )) || { echo "git status rc=$rc_git" >&2; exit 1; }; rc_diff=0; diff "$_sf_state_dir/baseline.txt" "$CURRENT" > "$_sf_state_dir/diff.txt" || rc_diff=$?; (( rc_diff <= 1 )) || { echo "diff rc=$rc_diff" >&2; exit 1; }; cat "$_sf_state_dir/diff.txt"`
  - Expected: mapfile 读 `_sf[0]`=state_dir 裸路径；git status rc==0（`|| rc_git=$?` 先存）；diff rc 0/1 合法（`|| rc_diff=$?` 先存，>1 exit 1）；diff `>` 行仅本特性文件。
- [ ] Step 5: **安全清理**（🔴1 mapfile 无标签 + canonical + marker + baseline，失败 exit 1）
  - Run: `mapfile -d '' -t _sf < "$STATE_FILE"; (( ${#_sf[@]} == 2 )) || exit 1; _sf_state_dir="${_sf[0]}"; _sf_marker="${_sf[1]}"; CANON_DIR="$(cd "$_sf_state_dir" 2>/dev/null && pwd -P)"; CANON_TMP="$(cd "${TMPDIR:-/tmp}" && pwd -P)"; [[ -n "$CANON_DIR" && "$(dirname "$CANON_DIR")" == "$CANON_TMP" && "$(basename "$CANON_DIR")" == ob-dev-reset.* ]] || { echo "canonical 不匹配：拒绝 rm" >&2; exit 1; }; [[ -f "$_sf_state_dir/.marker" && "$(cat "$_sf_state_dir/.marker")" == "$_sf_marker" ]] || { echo "marker 不匹配：拒绝 rm" >&2; exit 1; }; [[ -f "$_sf_state_dir/baseline.txt" ]] || { echo "baseline 缺失：拒绝 rm" >&2; exit 1; }; rm -rf -- "$_sf_state_dir" && rm -f -- "$STATE_FILE" && git status --short`
  - Expected: mapfile 读裸路径（无标签）；canonical（`pwd -P`）state dir 与 TMPDIR 比 dirname/basename；marker + baseline 全过才 `rm -rf`+删 STATE_FILE；**两次 rm 与 git status 用 `&&` 串联**（rm 失败不被 git status 掩盖，rc 传播）；任一不符/不可达→exit 1（不跳过）；输出修改摘要。

## 执行纪律

- 实现前批判性复查整份计划 + 设计 v6 + 全局约束（含实施计划评审 round-1~6 全部）；发现缺项/矛盾/命名不一致/验证命令无效，先修计划。
- 按任务顺序 T0→T8 执行（T1→T2→T3 helper 增量；T4 依赖 T3；T5 依赖 T4；T6 依赖 T4/T5 + T1/T2 helper[仅 source devtool_reset.sh]；T7 依赖 T4/T5；T8 最后）。
- **验证命令严格保 rc + errexit 安全**：正向 `bash tests/<file>.sh`；预期失败 `rc=0; ... || rc=$?; (( rc != 0 )) || exit 1`；`diff`/`git status` 用 `|| rc=$?` 先存 rc 再断言（不依赖 errexit）；不用 `| grep`/`| tail`。每任务 Step 4 退出 0 才进下一个。
- **TDD 顺序**：Step 1 写失败测试，Step 2 断言非零，Step 3 实现，Step 4 通过。
- **outvar 命名**：`_resolved_*`/`_located_*`/`_classified_*`/`_reset_*`，helper 内 `result_*`；测试用生产 receiver。
- **helper 不 trap**：epilogue `rm -f`，不安装 EXIT/RETURN trap；单测验 trap 不变。
- **NUL sentinel**：`__OB_NUL_END__\0` + 字段数 + 末字段断言。
- **state file 无标签**：`printf '%s\0%s\0'`（不带标签），全消费者 `mapfile -d '' -t` 读 `_sf[0]`/`_sf[1]`，字段数==2 校验，不 source。
- **JSON 六字段精确 + 原子**：argv 用 `"$dev_recipe"`；destination None、destination_parent `or None`、noop srctree/srctreebase ""；tempfile + rc + 恰好一尾换行行 + cat + 删；失败 stdout 空。
- **路径能力**：bbappend/status 真实链只普通 + 空格；特殊字符归 T4 mock。
- **PTY 守卫**：expect 可用 + 无 `^skip`(行首) + `SKIP=0`；否则记录未验证。
- **state 安全**：唯一（agent 持有）+ mapfile 不 source + canonical + marker + baseline 验证 + 失败 exit 1。
- checkpoint commit 可选（仅用户授权）。
- 遇阻塞（devtool 行为与设计未决不符、build env 进不去、extract_funcs 不认新文件、NUL/sentinel/原子 JSON/state 安全/HARNESS_ROOT source/attic 空集合协议困难、expect 不可用等）立即停下说明，不猜。
- 运行时重查分支；T0 安全 state file（agent 持有 `$STATE_FILE`），T8 五验证清理。
- 全部完成运行 Task 8 + 输出摘要。

## 最终验证

- `tools/ob_check.sh` ALL GREEN（exit_contract 确认 `devtool_reset.sh` leaf-pure）。
- `tests/run_all.sh --full` 退出 0（helper 单测含 devtool.conf 完整矩阵 + NUL sentinel + trap 不变 + 不可读配置[目录]；JSON 六字段精确契约 + tempfile 原子 + 全链路 round-trip 含引号/反斜杠/换行 + 编码失败 stdout 空；真实 `_reset_*`/`_resolved_*`/`_located_*`/`_classified_*` outvar；dev_interactive.exp reset[expect 可用+无 skip 前提]）。
- `tests/run_all.sh --integration` 退出 0（reset moved/retained/noop + HARNESS_ROOT[仅 source devtool_reset.sh] + effective + 候选/SKIP 前置 + 同一 RECIPE 生命周期 + **attic 空集合** + `find -print0` 差集 + trap 删 timestamp 目录[字面前缀+14 位+canonical] + 外部 srctree bbappend 读 + noop smoke SKIP 77[modify 前] + safety reset fault-inject）。
- harness 三处落地 + **五独立断言 + destination/destination_parent + workflow 否定语义**（CONTEXT reset JSON 六字段 + 五 disposition；WORKSPACE reset + devtool_reset.sh；workflow_02 reset 收尾 + **不得自动清 attic** + 无并发 writer）。
- baseline 对比：git rc==0 + diff rc≤1（errexit 安全）；无新增无关改动；state file 安全清理（mapfile + 五验证）。

## 审阅 Checkpoint

实施计划 v7（吸收实施计划评审 round-1 5🔴+5🟡+🟢、round-2 6🔴+4🟡、round-3 4🔴+3🟡、round-4 5🔴+4🟡、round-5 4🔴+4🟡、round-6 3🔴+3🟡）已写好并保存到 `docs/plans/2026-07-15-ob-dev-reset-implementation-plan.md`。请先确认这份计划；如果任务边界、接口契约或验证命令需要改动，我先改计划再请你复审。如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行（本 skill 不切入编码）。
