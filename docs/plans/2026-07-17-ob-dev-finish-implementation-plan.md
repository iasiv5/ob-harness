# ob dev finish 实施计划

## 目标

把 grilling 定型的 ob dev finish 设计实现为 `ob dev finish [--machine <machine>] <recipe>` 子命令（落回 recipe 原属 layer + source-preserving + 单 writer），分三个 commit 块交付在当前 `feature/ob-dev-devtool-modify` 分支：

1. **emit 抽取**：reset 单行 JSON + status JSONL 两处内联的"校验+cat+rm+rc"协议，抽成 leaf-pure `devtool_emit_json`/`devtool_emit_jsonl`，cmd_dev 改用——pure refactor，行为不变。
2. **reset 对齐 `cleaned_bbappend`**（porcelain **contract revision**）：locate_bbappend 多回传 bb 路径 → reset JSON 6→7 字段。
3. **finish 子命令**：`lib/devtool_finish.sh`（leaf-pure，镜像 reset 链 + light destination resolver + capture/detect landing 观测[status+digest]）+ `cmd_dev` finish 分支 + usage 暴露 + 四层测试 + harness 同步。

收口：`tools/ob_check.sh` ALL GREEN + `tests/run_all.sh --full` + `--integration` 通过。

## 架构快照

- **emit 原语落 `lib/devtool_porcelain.sh`**（新文件，leaf-pure）：`devtool_emit_json <tmpfile>`（python 校验恰好一物理行+尾换行+`json.loads` → cat → rm）、`devtool_emit_jsonl <tmpfile> <expected_lines> <keys_json>`（**全 python 校验**：尾 `\n` + 物理行数==expected + 每行非空 + `json.loads` + key 集合；不用 `grep -c .`）。emit 只管校验+发布。
- **reset 对齐**：`_devtool_reset_locate_bbappend` 的 `all_matches[0]` 已含 `bb` 路径，NUL framing 3→4 字段（+bbappend）；`devtool_reset_run` 加 `cleaned_bbappend` outvar；cmd_dev reset JSON 7 字段。
- **finish = 镜像 reset 链 + light destination resolver + capture/detect landing 观测（hybrid）**：
  - **light destination resolver**（解决 `devtool finish` 的 **destination 必填**——standard.py `finish()` 读 `args.destination` + `_get_layer`，不给 destlayer 不成立）：`_devtool_parse_status_entry`（扩展 `lib/devtool_workspace.sh`，从 `devtool status` 的 `recipe: srctree (recipefile)` 同时拿 srctree + recipefile）→ `_devtool_resolve_layer_root`（`lib/devtool_finish.sh`，**签名 `<base_dir> <file> <layer_root_out> <phase_out>`**，从 file 向上找最近的 `conf/layer.conf` → layer root **绝对路径**；base_dir 解析相对 file；找不到/歧义→phase=metadata）。不走 tinfoil、不升级 cache schema。
  - **landing snapshot capture**（finish 独有，**JSON snapshot 格式**）：`_devtool_finish_capture_landing_snapshot <openbmc_dir> <snapshot_outfile> <phase_out>`（`lib/devtool_finish.sh`）：内部 `git -C openbmc_dir status --porcelain=v1 -z --untracked-files=all` 采 entry → 过滤 `build/`/`workspace/`/`attic/` → 对相关 `.patch`/`.bb`/`.bbappend` 算 sha256 → 输出 **JSON `{"paths": {relpath: {"status":"XY","sha256":"..."}}}`** 到 snapshot_outfile（relpath 相对 openbmc_dir）；git 不可用→phase。T5 runtime + T8 integration 复用同一 helper（避免漂移）。
  - **devtool_finish_run** = resolve_workspace → status → parse_status_entry（recipefile）→ resolve_layer_root（origin_layer **绝对**，destination）→ locate_bbappend（复用 reset helper）→ classify（复用 reset helper）→ **safety copy srctreebase 到 workspace attic**（copy-before-finish；attic 在 `build/<machine>/workspace/` 下，`build/` gitignore 不进主仓 baseline）→ **`_devtool_finish_capture_landing_snapshot` pre** → `_devtool_env_exec -- devtool finish "$recipe" "$origin_layer"` → **capture post** → `_devtool_finish_detect_landing` diff 两份 JSON snapshot → postcondition。复用 `_devtool_env_exec`/`_devtool_parse_srctree`、reset resolve/locate/classify（loader source 全部 lib，**顺序无关**）。
  - **landing detect（status+digest diff）**：`_devtool_finish_detect_landing <openbmc_dir> <pre_snapshot_json> <post_snapshot_json> <mode_out> <patches_out> <recipe_files_out> <srcrev_out> <landing_layer_out> <phase_out>`（**openbmc_dir 作 base**：拼 abs 读 post recipe `SRCREV`、增量文件向上找 `conf/layer.conf`、landing_layer 输出相对 openbmc_dir），python 读两份 JSON snapshot → diff 规则 **"post 有 pre 无 / status 变 / digest 变"**（识别 dirty-to-dirty 内容变化；**deleted `.patch`/recipe[pre 有 post 无]→ phase=landing fail closed，不塞进 patches/recipe_files**）→ `.patch`→patches（新增+变化）、`.bb`/`.bbappend`→recipe_files、recipe `SRCREV`（post）→srcrev；**landing_layer = 每增量文件向上找 `conf/layer.conf`（复用 resolve 逻辑），所有增量必须同 layer root 否则 phase=landing fail closed**；landing_layer 输出**相对 openbmc_dir**。patches/recipe_files 输出 JSON array 字符串（相对 openbmc_dir，无 NUL）。
- **cmd_dev finish**：parser（[:838](../../lib/commands.sh#L838)）已预留；TTY 菜单加 `6) finish`（recipe 复用 reset 的 status pick modified recipe，[:937-971](../../lib/commands.sh#L937-L971)）；case 加 finish 分支，调 `devtool_finish_run`，12 字段 JSON 经 `devtool_emit_json` 原子发布（标量 argv、数组 argv JSON 字符串、全可空标量 `or None`）。

## 全局约束

逐字继承 [CONTEXT.md](../../CONTEXT.md)（`ob dev finish`、`patch landing`、`ob dev porcelain stdout`、`ob dev cleanup/收尾语义`）+ [ADR-0008](../adr/0008-ob-dev-cleanup-fail-safe.md) + [ADR-0009](../adr/0009-ob-dev-workspace-single-writer.md)，全程不可违反：

- `ob` 不内嵌 LLM；finish 是 agent-facing 子命令，machine 用 `--machine` flag（省略时复用 cmd_dev 既有 machine 前置 [:862-884](../../lib/commands.sh#L862-L884)）。
- `lib/devtool_finish.sh`、`lib/devtool_porcelain.sh` **leaf-pure**（函数绝不 exit，允许文件/进程副作用），登记 `exit_contract.py` `LEAF_EXIT_EXCEPTIONS_BY_BASENAME`；exit/remedy 只在 `cmd_dev`。
- porcelain：`cmd_dev` 不调 `log`/`info`/`warn`，诊断走 `error`/`>&2`；stdout 只 JSON 单行；JSON 经 tempfile 原子发布（`devtool_emit_*`，编码/校验失败则 stdout 空 + exit 1）。
- exit-code 遵循 `exit-code 契约`（0/1/2/3）+ ADR-0008（status 权威 recheck 不缓存/不推断、cleanup-needed 前置、status-list 失败不降级空、无候选 exit 77；77 是 integration 协议码非主契约）。
- **ADR-0009 单 writer 假设**：finish 不引入 workspace 锁；landing 探测依赖单 writer（finish 期间无并发 ob 写主仓库）。锁触发条件=`--remove-work`。
- **destination 必填（standard.py 事实）**：`devtool finish` 必须传 destlayer；ob 用 light resolver（recipefile→`conf/layer.conf`→layer root **绝对路径**）算 origin_layer 传入；不指望 devtool 自动回原属 layer。
- **resolve_layer_root 契约**：签名 `_devtool_resolve_layer_root <base_dir> <file> <layer_root_out> <phase_out>`；base_dir 解析相对 file（destination 和 detect 统一传 OPENBMC_DIR，不写两套相对逻辑）；输出**绝对** layer root（destination 给 devtool 用）。
- **数据通道（无 NUL 进 outvar/env/argv）**：Bash 变量/环境变量/argv 是 C 字符串不能承载 NUL。`patches`/`recipe_files` 作为 JSON array 字符串 outvar，cmd_dev 经 argv 传 python `json.loads` 合入。NUL 只用于 helper 内部固定字段 tempfile 协议（detect_landing 7 字段、resolve_layer_root 3 字段、locate_bbappend 4 字段）+ capture 内部（`-z` 解析）；**snapshot 文件本身是 JSON**（无 NUL 边界歧义）。
- **landing snapshot 格式（JSON）**：`_devtool_finish_capture_landing_snapshot` 输出 `{"paths": {relpath: {"status":"XY","sha256":"<hex>"}}}`（relpath 相对 openbmc_dir，过滤 build/workspace/attic）；detect 读两份 JSON。不用混合 NUL 段（边界易误解析）。
- **landing 探测 = status + content digest diff**（不止 status）：detect diff 规则"post 有 pre 无 / status 变 / **digest 变**"。识别 finish 对 dirty 文件的二次修改（pre/post 都 ` M` 但 sha 变 → 进 recipe_files/patches）。纯 status diff 会漏报 dirty-to-dirty，禁用。**deleted `.patch`/recipe（pre 有 post 无）→ phase=landing fail closed**（unsupported，devtool finish 不删 patch；不塞进 patches/recipe_files，避免 integration 检查不存在文件）。
- **detect 接口需 openbmc_dir**：detect 签名 `_devtool_finish_detect_landing <openbmc_dir> <pre_json> <post_json> ...`——openbmc_dir 作 base（拼 abs 读 post recipe SRCREV、增量文件找 `conf/layer.conf`、landing_layer 相对输出），不偷读全局；capture JSON 只携 relpath（不携机器路径字段）。T5/T8 调用显式传 `"$OPENBMC_DIR"`。
- **capture/detect 复用**：T5 runtime 和 T8 integration 必须用同一 `_devtool_finish_capture_landing_snapshot`（不手写一套 snapshot 逻辑）。
- **JSON null 契约（CONTEXT.md）**：noop 时 `cleaned_bbappend`/`landing_mode`/`landing_layer`/`srcrev` 为 `null`、`patches`/`recipe_files` 为 `[]`。内部 outvar 可空串，JSON encoder 必须 `or None`（空→null）。
- **landing fields 相对路径**：patches/recipe_files/landing_layer/snapshot relpath 用相对 `$OPENBMC_DIR`；destination（resolve_layer_root 输出、给 devtool）用**绝对**。两者不混用。
- **patch landing = 新增或内容变化的 patch**：detect 用 status+digest diff 捕捉新增+修改，都进 `patches`。
- **landing_layer 来源 = conf/layer.conf 向上找**（非公共前缀）：每增量文件向上找最近 `conf/layer.conf` 得 layer root；所有增量必须同 layer root 否则 `phase=landing`；复用 destination resolver 逻辑。
- **patch-only refresh 合法**：只 `.patch` 变、recipe 不变（`recipe_files==[]`、`patches` 非空）→ `landing_mode="patch"`，不因 recipe_files 空 fail closed。
- **safety copy 不进 baseline**：safety copy 放 workspace attic（`build/<machine>/workspace/attic/sources/<recipe>.<timestamp>.finish-copy`，`build/` 是 bitbake 标准产物 gitignore、不进主仓 git status）；capture 过滤 `build/`/`workspace/`/`attic/` 路径。
- **source-preserving = copy-before-finish（safety copy）**：finish 前 **copy**（不 move）srctreebase 到 safety copy（命名 `<recipe>.<timestamp>.finish-copy`，区别 reset 的 `<recipe>.<timestamp>`）；finish 成功后：devtool 自己 reset 已归档→删 safety copy / devtool 删源未归档→safety copy 发布 attic（rename 到 `<recipe>.<timestamp>`）/ retained→删 safety copy；失败→safety copy 兜底不误删用户源。**避免双归档目录**。
- **reset 对齐是 porcelain contract revision**（非无条件 backward-compatible）：精确 key-set consumer 不兼容（六→七字段）；测试更新精确 key 断言。
- **runtime fail-closed（现场检查，非读 FACT_）**：FACT_ 是实施期记录/人工核对，**不是 runtime 数据源**；runtime 现场检查：`git -C "$OPENBMC_DIR" rev-parse --is-inside-work-tree` 不真→phase；destination layer root 不存在/无 `conf/layer.conf`→phase=metadata；`devtool finish` 调用失败收口 phase；snapshot JSON/digest 解析失败、多 layer root→phase=landing。
- **不破坏既有命令行为**：emit 抽取 pure refactor（reset 6 字段不变）；reset 对齐 contract revision；不改 modify/list/refresh/status/reset 既有语义，不改 `_devtool_env_exec`/`_devtool_parse_srctree`/`_devtool_parse_status_all`（`_devtool_parse_status_entry` 是 workspace.sh **新增**）。
- **outvar 命名**：cmd_dev→`devtool_finish_run` 传 `_finish_*`；run→helper 传 `_resolved_*`/`_located_*`/`_classified_*`/`_detected_*`/`_layered_*`；helper 内 `result_*`。
- **helper 不安装 trap**：单一 cleanup epilogue；单测验 trap 不变。
- **NUL framing + sentinel**：`__OB_NUL_END__\0` + 字段数 + 末字段断言（locate 4/resolve 3/detect 7）；capture 输出 JSON（无 sentinel，json.loads 校验）。
- **cleaned_bbappend 与 disposition 正交**；noop null。
- **路径能力边界**：bbappend/status/srctree 真实链只普通+空格；capture `-z`+digest 已处理 NUL/内容；quoted/rename/copy 特殊路径归 mock，真实链 fail closed。
- **验证命令严格保 rc**：正向 `bash tests/<file>.sh`；预期失败 `rc=0; ... || rc=$?; (( rc != 0 )) || exit 1`；`diff`/`git status`/`grep` 用 `rc=0; ... || rc=$?` 先存；不用 `| grep`/`| tail`/`echo`/`cp`/`cat`/`head`/`ls|head` 吞 rc 收尾。
- **落地前待核实（T0.5 先确认，FACT_ marker 写回，仅人工核对非 runtime）**：① destination 必填（评审已据 standard.py 确认=true，T0.5 复核）；② `devtool finish` 对 srctreebase 物理处置（删/不删/归档——定 safety copy 时序）；③ mode 是否非交互自动判；④ 主仓库 git 可用 + `build/` gitignore + 子仓库 layer 边界 + OPENBMC_DIR 实际布局。
- **checkpoint commit 可选**：Step 5 仅用户授权。分支运行时重查。

## T0.5 事实确认结果（FACT_ marker，2026-07-17，仅人工核对非 runtime）

实测 build env（init-done machine=`b865g8-bytedance`，`devtool finish --help` 完整输出 + `scripts/lib/devtool/standard.py` 源码核验）：

- **FACT_FINISH_DESTINATION=required**：`recipename destination` 是两个 positional argument，destination 不可省略；`finish()` @2178 经 `_get_layer(args.destination, ...)` 解析（layername→BBLAYERS basename 匹配，未命中当路径 `os.path.abspath`），@2183 `os.path.isdir` 校验、@2186 拒绝 workspace 层。ob light resolver（recipefile→`conf/layer.conf`→绝对 layer root）传 `destlayerdir`，命中 _get_layer "path to the base of a layer" 形态。✓ 与计划假设一致。

- **FACT_FINISH_SOURCE_POLICY=preserved（与 reset 同构，不删源）**：`finish()` @2323 调 `_reset([recipename], remove_work=args.remove_work=False, ...)`；`_reset()` @2070-2094 source 处置与独立 `reset` **完全同一段代码**：srctreebase 在 `workspace/sources` 下 → `shutil.move` 到 `<workspace>/attic/sources/<pn>.<timestamp>`（`%Y%m%d%H%M%S`，**move 非 copy**，命名与 reset 完全相同）；不在 → 原位 retained；空目录 → rmdir。**默认绝不删源**（仅 `--remove-work`/`-r` 才 rmtree，ob 不传）。`finish()` 与 `reset()` 走同一 `_reset`，srctreebase 物理处置 = reset disposition 五态（moved/retained/removed/absent/noop）。

- **FACT_FINISH_MODE_AUTO=yes**：`--mode (patch, srcrev, auto; default is auto)`，非交互自动判；ob 不传 --mode，交 devtool 判。✓ 与计划假设一致。

- **FACT_GIT_BASELINE_SUPPORTED=yes**：主仓库是 git 仓库（`git rev-parse --is-inside-work-tree=true`）；`.gitignore` 第1行 `build*/*`（build/ gitignore 不进 baseline）；`build/` 存在（workspace attic 宿主）；OPENBMC_DIR=`workspace/openbmc`。✓ 与计划假设一致。

### ✅ v6 修订（2026-07-17）：safety copy 删除 → finish 复用 reset disposition 五态（原 STOP 已解决）

计划全局约束（safety copy / source-preserving=copy-before-finish）基于"devtool finish 可能删源，需 ob copy-before-finish 兜底"的假设。FACT_② 推翻该假设：**devtool finish 默认（remove_work=False）绝不删源，已自带与 reset 同构的 source-preserving 归档**（srctreebase → `attic/sources/<pn>.<timestamp>` move / 原位 retained），归档命名 `<pn>.<timestamp>` 与 reset **完全相同**（无 `.finish-copy` 后缀）。

影响：
1. **T5 safety copy 整段逻辑应删除**：copy-before-finish、`<recipe>.<timestamp>.finish-copy` 命名、成功后三分支（删 copy / rename 发布 attic / retained 删 copy）、失败兜底——均无必要。finish 的 srctreebase 处置直接复用 reset disposition 五态（devtool 原生 `_reset` 已归档），与 reset 完全对称。
2. **capture 过滤 attic 仍保留**（attic 是 devtool 归档产物，不属于 landing；safety copy 专属过滤理由消失，但 attic 过滤本身仍需——devtool move 进来的归档不应算 landing）。
3. **CONTEXT.md / ADR-0008 复用确认**：finish 物理层与 reset 同构（ADR-0008 fail-safe 通则直接复用），进一步坐实"finish = reset 链 + landing 观测"，safety copy 是多余复杂度。

**结论**：T1（emit）/T2（reset 对齐）已完成并 commit（dbc26cd docs + 06b2b7f impl），不受 FACT_② 影响。本 v6 修订确立 T3-T10 执行规格：**finish 物理层复用 reset disposition 五态，无 safety copy**。plan 中所有 `safety copy` / `finish-copy` / `copy-before-finish` / `safety copy 时序` 字样（架构快照行20、全局约束行45-46、T5 行273-301、T8 行369-400、执行纪律行468、最终验证行484-485）一律按下述 v6 规格覆盖。

#### v6 规格 A：T5 `devtool_finish_run` 实际流程（无 safety copy，复用 reset disposition）

```
resolve_workspace(_resolved_*) → devtool status → _devtool_parse_status_entry(recipe, status_file → srctree + recipefile; recipefile 空→phase=metadata)
→ [status 无 recipe 行 → noop] → _devtool_resolve_layer_root(OPENBMC_DIR, recipefile → origin_layer 绝对; 无 conf/layer.conf→phase=metadata)
→ _devtool_reset_locate_bbappend(ws, recipe, srctree → srctreebase + bbappend; _located_*)
→ _devtool_reset_classify(build_dir, ws_raw, ws_eff, srctreebase → expected_disposition; _classified_*)
→ _devtool_finish_capture_landing_snapshot(OPENBMC_DIR, snap_pre)
→ _devtool_env_exec -- devtool finish "$recipe" "$origin_layer"   (phase=finish on fail)
→ _devtool_finish_capture_landing_snapshot(OPENBMC_DIR, snap_post)
→ _devtool_finish_detect_landing(OPENBMC_DIR, snap_pre, snap_post → landing_mode/patches/recipe_files/srcrev/landing_layer; _detected_*)
→ postcondition(二次 status + recipe 退出 workspace + srctreebase vs expected_disposition; phase=postcondition on fail)
→ 回传 13 outvar
```

- **srctreebase 处置 = reset 同构**：`devtool finish` 内部 `_reset(remove_work=False)` 已 source-preserving 归档（moved→`<ws>/attic/sources/<pn>.<timestamp>`、retained→原位、removed→空目录 rmdir、absent）。ob **不做 safety copy**；disposition=`_classified_expected`、destination_parent（moved 时=`<ws_eff>/attic/sources`）、cleaned_bbappend=`_located_bbappend`，与 reset 完全对称。
- **失败路径无兜底需求**：phase!=空 → cmd_dev exit 1 不发布 JSON；devtool finish 未执行或部分执行均不删源（FACT_②），workspace metadata 残留可重建（ADR-0008 fail-safe 覆盖串行内失败）。

#### v6 规格 B：T8 integration 实际形态（无 safety copy 时序实测）

- **删**：safety copy 时序实测、无 `<recipe>.<timestamp>.finish-copy` 残留、无双归档、safety copy 兜底项。
- **改为 disposition 归档实测**：finish 后 srctreebase 按 disposition 五态归档（moved→attic/sources 单一 `<pn>.<timestamp>`；retained→原位），与 reset 同构验证；无 `.finish-copy` 后缀。
- **safety fault-inject**（保 ADR-0008）：status-fail 不 finish、list-fail 不降级、finish-partial-fail 残留检测（残留=workspace metadata，devtool 不删源故无源丢失风险）。
- capture 过滤 build/workspace/attic 仍验证（devtool 归档 attic 不算 landing）。

## 输入工件

- 设计：grilling 共识（已落 [CONTEXT.md](../../CONTEXT.md) `ob dev finish`/`patch landing` + porcelain 七/十二字段 + cleanup→ADR-0009）+ [ADR-0009](../adr/0009-ob-dev-workspace-single-writer.md)。
- [ADR-0008](../adr/0008-ob-dev-cleanup-fail-safe.md)。
- 结构镜像参考：[reset 实施计划](./2026-07-15-ob-dev-reset-implementation-plan.md)、`lib/devtool_reset.sh`、`lib/devtool_workspace.sh`、`lib/devtool_modify.sh`。
- 先例测试：`tests/integration/ob_dev.sh`、`tests/unit/ob_dev_integration_safety.sh`、`tests/protocol/dev_interactive.exp`、`tests/protocol/usage_dispatch_sync.sh`。
- 评审 round-1（NUL/null/refresh/integration/copy）+ round-2（destination 必填→hybrid、probe 形态、`-z`、layer root、safety copy、runtime 断言、相对路径）+ round-3（status+digest diff、resolve 签名 base_dir、FACT_ 非 runtime、patch-only refresh、safety copy 不进 baseline、T0.5 自动、绝对/相对分明）+ round-4（**snapshot capture helper + JSON 格式**、T0.5 去 `ls|head`），本计划 v5 全吸收。

## 文件结构与职责

**Create:** `lib/devtool_porcelain.sh`（`devtool_emit_json`+`devtool_emit_jsonl`）、`lib/devtool_finish.sh`（`devtool_finish_run` + `_devtool_resolve_layer_root` + `_devtool_finish_capture_landing_snapshot` + `_devtool_finish_detect_landing`）、`tests/unit/devtool_porcelain.sh`、`tests/unit/devtool_finish.sh`。

**Modify:** `tools/exit_contract.py`（+2 leaf-pure basename）、`lib/devtool_workspace.sh`（新增 `_devtool_parse_status_entry`，不动既有）、`lib/devtool_reset.sh`（locate_bbappend 回传 bbappend + run outvar）、`lib/commands.sh`（reset/status 改 emit + reset 7 字段 + finish 分支 + TTY 菜单）、`ob`（usage + examples）、`tests/protocol/usage_dispatch_sync.sh`、`tests/protocol/dev_interactive.exp`、`tests/orchestration/cmd_dev.sh`、`tests/integration/ob_dev.sh`、`tests/unit/ob_dev_integration_safety.sh`、`tests/unit/devtool_reset.sh`、`rules/03_WORKSPACE.md`、`rules/skills/workflow_02-obmc_dev_modify.md`。

**接口契约主干:** `devtool_emit_json`/`devtool_emit_jsonl`（T1）→ reset/status refactor（T1）+ reset 7 字段（T2）→ `_devtool_parse_status_entry`+`_devtool_resolve_layer_root`（T3，destination resolver，绝对 layer root）→ `_devtool_finish_capture_landing_snapshot`+`_devtool_finish_detect_landing`（T4，JSON snapshot + status+digest 结果观测；**detect 接 `openbmc_dir` 作 base**，相对 layer）→ `devtool_finish_run`（T5，复用 reset 链 + T3 resolver + T4 capture/detect）→ cmd_dev finish（T6）→ usage/protocol（T7）→ integration（T8）→ harness（T9）→ 最终（T10）。**T0.5 必须先于 T3/T4/T5**。

---

### Task 0: 执行前置（分支 + state dir）

- 目标：运行时确认分支 + 唯一 state dir（存测试日志/baseline/devtool probe 输出）。
- Files: 无。
- 验证范围：分支正确 + state dir 生成。
- 接口契约: Consumes 无；Produces `$STATE_DIR`（agent 持有）。

- [ ] Step 1: 分支检查
  - Run: `git branch --show-current`
  - Expected: `feature/ob-dev-devtool-modify`（或用户确认分支）；main/master 先停下确认。
- [ ] Step 2: 建 state dir + baseline
  - Run: `STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ob-dev-finish.XXXXXX")" && git status --short > "$STATE_DIR/baseline.txt" && echo "STATE_DIR=$STATE_DIR" && test -f "$STATE_DIR/baseline.txt"`
  - Expected: 任一步失败即中止（`test` 收尾保 rc）；agent 保存 `$STATE_DIR`。
- [ ] Step 3-5: 无。

---

### Task 0.5: devtool finish 事实确认（前置，先于 T3/T4/T5）

- 目标：确认待核实①②③④，用 `FACT_` marker 写回全局约束（仅人工核对）；不确认则 T3/T4/T5 形态不定。
- Files: 无（只读探查 + 记录）。
- 验证范围：四项 FACT_ marker 有结论。
- 接口契约: Consumes build env（若有）/ `$OPENBMC_DIR/scripts/lib/devtool/standard.py`；Produces `FACT_FINISH_DESTINATION`/`FACT_FINISH_SOURCE_POLICY`/`FACT_FINISH_MODE_AUTO`/`FACT_GIT_BASELINE_SUPPORTED`（人工核对，**非 runtime 数据源**）。

- [ ] Step 1: probe devtool finish --help（若有可用 build env + initialized machine，用 `_devtool_env_exec` 形态，rc 不被 head 吞；**machine 用无管道 glob 取**）
  - Run: `OPENBMC_DIR="${OPENBMC_DIR:-$(pwd)/workspace/openbmc}"; init_done=""; for f in workspace/configs/*.init-done; do [[ -f "$f" ]] || continue; init_done="$f"; break; done; if [[ -z "$init_done" ]]; then echo "PROBE_UNAVAILABLE: no init-done machine"; else machine="$(basename "$init_done" .init-done)"; rc=0; ( cd "$OPENBMC_DIR" && set +u && source setup "$machine" "$OPENBMC_DIR/build/$machine" >/dev/null 2>&1 && devtool finish --help ) >"$STATE_DIR/devtool-finish-help.txt" 2>&1 || rc=$?; if (( rc == 0 )); then sed -n '1,80p' "$STATE_DIR/devtool-finish-help.txt"; else echo "PROBE_UNAVAILABLE rc=$rc"; fi; fi`（OPENBMC_DIR 默认按 ob 实际布局调整；machine 自动取第一个 init-done，无管道 glob）
  - Expected: `devtool finish` 选项/签名（destination 必填、--mode、--force、source 清理）；或 `PROBE_UNAVAILABLE`（无 init-done / OPENBMC_DIR 不存在 / build env 不可用）。
- [ ] Step 2: 静态源码核验（直接路径，不 find）
  - Run: `OPENBMC_DIR="${OPENBMC_DIR:-$(pwd)/workspace/openbmc}"; STANDARD_PY="$OPENBMC_DIR/scripts/lib/devtool/standard.py"; if test -f "$STANDARD_PY"; then rc=0; grep -nE 'def finish|args\.destination|_get_layer|_reset\(|update_recipe|remove_work|srctree' "$STANDARD_PY" > "$STATE_DIR/standard-finish-grep.txt" 2>/dev/null || rc=$?; sed -n '1,40p' "$STATE_DIR/standard-finish-grep.txt"; else echo "SOURCE_UNAVAILABLE: $STANDARD_PY"; fi`
  - Expected: 确认 destination 必填、mode 判定、source 处置（`_reset()`）、update_recipe；或 `SOURCE_UNAVAILABLE`（probe+static 都不可用→T0.5 STOP，停下说明，不进 T3）。
- [ ] Step 3: 写回结论（FACT_ marker）
  - Change: 全局约束写：`FACT_FINISH_DESTINATION=required|optional`（评审已确认 required，T0.5 复核）、`FACT_FINISH_SOURCE_POLICY=removed|preserved|archived`、`FACT_FINISH_MODE_AUTO=yes|no`、`FACT_GIT_BASELINE_SUPPORTED=yes|no`（主仓库 git + `build/` gitignore + 子仓库边界 + OPENBMC_DIR 布局）。
- [ ] Step 4: 确认 marker 落
  - Run: `rc=0; for m in FACT_FINISH_DESTINATION FACT_FINISH_SOURCE_POLICY FACT_FINISH_MODE_AUTO FACT_GIT_BASELINE_SUPPORTED; do grep -q "$m" docs/plans/2026-07-17-ob-dev-finish-implementation-plan.md || { echo "missing $m" >&2; rc=1; }; done; (( rc == 0 ))`
  - Expected: 四 marker 全在（`&&` 链收尾保 rc）。
- [ ] Step 5: 无 checkpoint（事实记录）。

---

### Task 1: emit 原语 + cmd_dev reset/status refactor（行为不变）

- 目标：建 `lib/devtool_porcelain.sh`（`devtool_emit_json`+`devtool_emit_jsonl` leaf-pure + 登记）+ unit；cmd_dev reset（[:1106-1126](../../lib/commands.sh#L1106-L1126)）/status（[:1152-1183](../../lib/commands.sh#L1152-L1183)）改调 emit——pure refactor，行为不变。
- Files: Create `lib/devtool_porcelain.sh`、`tests/unit/devtool_porcelain.sh`；Modify `tools/exit_contract.py`、`lib/commands.sh`。
- 验证范围：`bash tests/unit/devtool_porcelain.sh` + `bash tests/orchestration/cmd_dev.sh`（reset/status 不变）+ `tools/ob_check.sh`。
- 接口契约: Consumes exit_contract LEAF；Produces `devtool_emit_json`、`devtool_emit_jsonl`（T2/T6 消费）。

- [ ] Step 1: 写失败测试（`tests/unit/devtool_porcelain.sh`，emit 矩阵）
  - `devtool_emit_json <tmpfile>`：合法单行+尾换行 JSON → cat + return 0 + 删；多行/无尾换行/非法/空/缺文件 → return 1 + 删。trap 不变。
  - `devtool_emit_jsonl <tmpfile> <expected_lines> <keys_json>`：合法（尾 `\n` + 物理行数==expected + 每行非空 + 每行 `json.loads` + `set(d.keys())==set(json.loads(keys_json))`，keys_json 如 `["recipe","srctree"]`）→ cat + return 0 + 删；物理行数不等/含空行/key 不符/某行非法/无尾换行 → return 1 + 删。trap 不变。
  - Run: `bash tests/unit/devtool_porcelain.sh`
  - Expected: 失败。
- [ ] Step 2: 确认失败
  - Run: `rc=0; bash tests/unit/devtool_porcelain.sh || rc=$?; (( rc != 0 )) || { echo EXPECTED_FAIL_GOT_PASS >&2; exit 1; }`
  - Expected: 非零。
- [ ] Step 3: 写最小实现
  - `tools/exit_contract.py` 加 `'devtool_porcelain.sh': set(),`。
  - `lib/devtool_porcelain.sh`：header + `devtool_emit_json`（python 校验恰好一物理行+尾换行+`json.loads` → cat → rm，失败 rm+return 1）+ `devtool_emit_jsonl`（**全 python**：`endswith("\n")` + `len(splitlines())==expected` + 每行 strip 非空 + `json.loads` + `set(d.keys())==set(json.loads(keys_json))` → cat → rm；**不用 `grep -c .`**）。不 trap。
  - `lib/commands.sh`：reset 发布段→`devtool_emit_json "$_json_tmp" || { rm -f ...; exit 1; }`；status 发布段→`devtool_emit_jsonl "$_st_jsonl" "$_st_expected" '["recipe","srctree"]' || { rm -f ...; exit 1; }`。字段/argv/生成不变。
- Change: porcelain.sh + exit_contract +1；commands.sh reset/status 改 emit；unit 矩阵。
- [ ] Step 4: 运行确认通过（行为不变）
  - Run: `bash tests/unit/devtool_porcelain.sh`
  - Expected: 通过。
  - Run: `bash tests/orchestration/cmd_dev.sh`
  - Expected: 通过（reset 六字段/status JSONL 不变）。
  - Run: `tools/ob_check.sh`
  - Expected: ALL GREEN。
- [ ] Step 5: checkpoint（可选）
  - Run: `git add lib/devtool_porcelain.sh tools/exit_contract.py lib/commands.sh tests/unit/devtool_porcelain.sh && git commit -m "refactor(dev): extract devtool_emit_json/jsonl porcelain primitive"`
  - Expected: commit 成功或跳过。

---

### Task 2: reset 对齐 cleaned_bbappend（porcelain contract revision 6→7）

- 目标：locate_bbappend NUL framing 3→4 字段（回传 bbappend）→ `devtool_reset_run` 加 outvar → cmd_dev reset JSON 7 字段（emit_json，`or None`）→ unit/orchestration 断言（精确 key + noop None）。
- Files: Modify `lib/devtool_reset.sh`、`lib/commands.sh`、`tests/unit/devtool_reset.sh`、`tests/orchestration/cmd_dev.sh`。
- 验证范围：`bash tests/unit/devtool_reset.sh` + `bash tests/orchestration/cmd_dev.sh`（reset 七字段 + noop None）。
- 接口契约: Consumes `devtool_emit_json`（T1）、`_devtool_reset_locate_bbappend`（既有）；Produces reset 七字段契约（T5 复用）、`cleaned_bbappend` outvar。

- [ ] Step 1: 写失败测试（扩 `tests/unit/devtool_reset.sh` + `tests/orchestration/cmd_dev.sh`）
  - `_devtool_reset_locate_bbappend <workspace> <recipe> <status_srctree> <srctreebase_raw_out> <bbappend_out> <phase_out>`：命中→`bbappend_out`=`appends/<recipe>...bbappend`（普通+空格）；零/多/EXTERNALSRC≠status→phase=metadata 且 bbappend 空。receiver `_located_*`。trap 不变。
  - `devtool_reset_run` 加 `cleaned_bbappend_outvar`（11 参数）：moved/retained/removed/absent→bbappend 路径；noop→空串。
  - orchestration：精确 key 集合==七字段；moved/retained/removed/absent 的 `cleaned_bbappend` 非空；**noop `cleaned_bbappend is None`**（encoder `or None`）。
  - Run: `bash tests/unit/devtool_reset.sh`
  - Expected: 失败。
- [ ] Step 2: 确认失败
  - Run: `rc=0; bash tests/unit/devtool_reset.sh || rc=$?; (( rc != 0 )) || { echo EXPECTED_FAIL_GOT_PASS >&2; exit 1; }`
  - Expected: 非零。
- [ ] Step 3: 写最小实现
  - `lib/devtool_reset.sh` locate_bbappend：python emit 加 `bbappend_path`（`all_matches[0][0]`），NUL `srctreebase_raw\0bbappend\0phase\0sentinel`（4 字段）；签名加 `<bbappend_out>`。
  - `devtool_reset_run`：11 参数；locate 多传 `_located_bbappend`；回传 `cleaned_bbappend`；noop 空；末尾 `printf -v`。
  - `lib/commands.sh` reset：调 run 多传 `_reset_cleaned_bbappend`；JSON 加 `"cleaned_bbappend":sys.argv[N] or None`，经 emit。
- Change: locate 4 字段 + run outvar + cmd_dev 七字段（`or None`）+ 断言 None。
- [ ] Step 4: 运行确认通过
  - Run: `bash tests/unit/devtool_reset.sh`
  - Expected: 通过。
  - Run: `bash tests/orchestration/cmd_dev.sh`
  - Expected: 通过（七字段精确，noop None）。
  - Run: `tools/ob_check.sh`
  - Expected: ALL GREEN。
- [ ] Step 5: checkpoint（可选）
  - Run: `git add lib/devtool_reset.sh lib/commands.sh tests/unit/devtool_reset.sh tests/orchestration/cmd_dev.sh && git commit -m "feat(dev): reset cleaned_bbappend field (6→7 porcelain contract revision)"`
  - Expected: commit 成功或跳过。

---

### Task 3: finish 骨架 + exit_contract 登记 + light destination resolver（parse_status_entry + resolve_layer_root）

- 目标：`lib/devtool_finish.sh` header + exit_contract 登记 + `_devtool_parse_status_entry`（workspace.sh 新增）+ `_devtool_resolve_layer_root`（finish.sh，`<base_dir> <file> ...`，输出绝对 layer root）+ unit 矩阵。
- Files: Create `lib/devtool_finish.sh`（header + resolve_layer_root）、`tests/unit/devtool_finish.sh`；Modify `tools/exit_contract.py`、`lib/devtool_workspace.sh`。
- 验证范围：`bash tests/unit/devtool_finish.sh`（parse_status_entry + resolve_layer_root 矩阵 + trap 不变）+ `tools/ob_check.sh`。
- 接口契约: Consumes exit_contract LEAF + T0.5 `FACT_FINISH_DESTINATION`；Produces `_devtool_parse_status_entry`、`_devtool_resolve_layer_root`（T5 destination 绝对；T4 detect 复用 layer root 逻辑）、`devtool_finish.sh` leaf-pure 登记。

- [ ] Step 1: 写失败测试（`tests/unit/devtool_finish.sh`，矩阵，receiver `_layered_*`，trap 不变）
  - `_devtool_parse_status_entry <recipe> <status_file> <srctree_out> <recipefile_out>`（workspace.sh）：status 行 `recipe: srctree (recipefile)` → srctree + recipefile（剥括号；recipefile 绝对/相对原样交 resolve 用 base_dir 解析）；无 `(recipefile)`→recipefile 空、srctree 仍出；无匹配→两者空。
  - `_devtool_resolve_layer_root <base_dir> <file> <layer_root_out> <phase_out>`（finish.sh）：造 fixture（`<root>/meta-x/conf/layer.conf` + `<root>/meta-x/recipes-phosphor/foo/foo.bb`）→ layer_root=**绝对** `<root>/meta-x`；file 相对→按 base_dir 解析再向上找；无 `conf/layer.conf` 向上到根→phase=metadata；NUL framing `layer_root\0phase\0sentinel`（3 字段）。trap 不变。
  - **断言绝对**：resolve_layer_root 输出 layer_root 必须是绝对路径（`[[ "$layer_root" == /* ]]`）。
  - Run: `bash tests/unit/devtool_finish.sh`
  - Expected: 失败。
- [ ] Step 2: 确认失败
  - Run: `rc=0; bash tests/unit/devtool_finish.sh || rc=$?; (( rc != 0 )) || { echo EXPECTED_FAIL_GOT_PASS >&2; exit 1; }`
  - Expected: 非零。
- [ ] Step 3: 写最小实现
  - `tools/exit_contract.py` 加 `'devtool_finish.sh': set(),`。
  - `lib/devtool_workspace.sh` 新增 `_devtool_parse_status_entry`（awk 解析 `recipe: srctree (recipefile)`，输出 srctree + recipefile；不动 `_devtool_parse_srctree`）。
  - `lib/devtool_finish.sh`：header（leaf-pure，复用 workspace/reset helper，loader 顺序无关）+ `_devtool_resolve_layer_root <base_dir> <file> <layer_root_out> <phase_out>`（python：file 相对→`os.path.join(base_dir,file)`，`os.path.dirname` 向上找 `conf/layer.conf` → layer root **绝对** `os.path.abspath`；找不到→phase=metadata；NUL sentinel + epilogue rm 不 trap）。
- Change: exit_contract +1；workspace.sh +parse_status_entry；finish.sh header + resolve_layer_root；unit 矩阵（含绝对断言）。
- [ ] Step 4: 运行确认通过
  - Run: `bash tests/unit/devtool_finish.sh`
  - Expected: 通过；`tools/ob_check.sh` → ALL GREEN。
- [ ] Step 5: checkpoint（可选）
  - Run: `git add tools/exit_contract.py lib/devtool_workspace.sh lib/devtool_finish.sh tests/unit/devtool_finish.sh && git commit -m "feat(dev): scaffold devtool_finish.sh + light destination resolver (abs layer root)"`
  - Expected: commit 成功或跳过。

---

### Task 4: landing 观测 helper（capture_landing_snapshot JSON + detect_landing status+digest）

- 目标：`_devtool_finish_capture_landing_snapshot`（capture，输出 JSON snapshot）+ `_devtool_finish_detect_landing`（detect，读 JSON pre/post，status+digest diff）+ unit 矩阵（含 dirty-to-dirty digest 变、patch-only refresh、多 layer root fail closed、safety copy 过滤）。
- Files: Modify `lib/devtool_finish.sh`、`tests/unit/devtool_finish.sh`。
- 验证范围：`bash tests/unit/devtool_finish.sh`（capture + detect 矩阵 + trap 不变）。
- 接口契约: Consumes `_devtool_resolve_layer_root`（T3，per-file layer root）；Produces `_devtool_finish_capture_landing_snapshot`、`_devtool_finish_detect_landing`（T5 runtime + T8 integration 复用 capture）。

- [ ] Step 1: 写失败测试（扩 unit，capture + detect 矩阵，receiver `_detected_*`，trap 不变）
  - `_devtool_finish_capture_landing_snapshot <openbmc_dir> <snapshot_outfile> <phase_out>`：在 mock git 仓库（造 fixture `meta-x/conf/layer.conf` + `.patch`/`.bb` 文件，部分 dirty）跑 → snapshot_outfile 是合法 JSON `{"paths": {relpath: {"status":"XY","sha256":"<64hex>"}}}`；relpath 相对 openbmc_dir；**过滤 build/workspace/attic**（造 `build/<m>/workspace/attic/x` → 不在 paths）；非 git 仓库→phase。trap 不变。
  - `_devtool_finish_detect_landing <openbmc_dir> <pre_json> <post_json> <mode_out> <patches_out> <recipe_files_out> <srcrev_out> <landing_layer_out> <phase_out>`（读 capture 产出的 JSON fixture；**openbmc_dir 作 base**：在 fixture 下造真实 recipe 文件供读 SRCREV、造 `conf/layer.conf` 供 layer root 解析）：
    - patch mode：post 新增 `?? .../0001-bar.patch`（pre 无）+ ` M .../foo.bb`，同 layer root → mode="patch"、patches=`["meta-x/.../0001-bar.patch"]`（相对 openbmc_dir JSON array 字符串）、recipe_files=`["meta-x/.../foo.bb"]`、srcrev=null、landing_layer="meta-x"（相对）。
    - **dirty-to-dirty（🔴 round-3）**：pre/post 都是 ` M .../foo.bb`，但 sha A→B → digest 变 → 进 recipe_files（不能因 status 同漏报）。
    - **patch-only refresh（🟡3 round-3）**：post 只有 ` M .../existing.patch`（sha 变，recipe 不变）→ mode="patch"、patches=`["meta-x/.../existing.patch"]`、recipe_files=`[]`、landing_layer="meta-x"（不因 recipe_files 空 fail closed）。
    - srcrev mode：无 patch 变 + ` M .../foo.bb` + SRCREV 变 → mode="srcrev"、patches=`[]`、recipe_files=`[".../foo.bb"]`、srcrev="<值>"。
    - **deleted patch/recipe（round-5）**：pre 有 `meta-x/.../old.patch`、post 无 → phase=landing（fail closed，不塞进 patches）。
    - **多 layer root**：增量跨 `meta-x`/`meta-y` → phase=landing。
    - noop/无变化（status 同 + digest 同）→ phase=landing；JSON 解析失败 → phase=landing。
    - 输出 NUL framing `mode\0patches_json\0recipe_files_json\0srcrev\0landing_layer\0phase\0sentinel`（7 字段），mapfile 断言 7 + 末字段 sentinel。**landing_layer 相对 openbmc_dir**（detect 输出），与 resolve_layer_root 绝对（destination）区分。
  - trap 不变。
  - Run: `bash tests/unit/devtool_finish.sh`
  - Expected: 失败（capture/detect 未实现）。
- [ ] Step 2: 确认失败
  - Run: `rc=0; bash tests/unit/devtool_finish.sh || rc=$?; (( rc != 0 )) || { echo EXPECTED_FAIL_GOT_PASS >&2; exit 1; }`
  - Expected: 非零。
- [ ] Step 3: 写最小实现
  - `lib/devtool_finish.sh` `_devtool_finish_capture_landing_snapshot`：python `git -C openbmc_dir status --porcelain=v1 -z --untracked-files=all` → 解析 entry（XY + path，rename 取 dest）→ 过滤 `build/`/`workspace/`/`attic` → 对相关 `.patch`/`.bb`/`.bbappend` 算 sha256（`git hash-object` 或文件 sha）→ `json.dump({"paths": {relpath: {"status":xy,"sha256":hex}}})` 到 snapshot_outfile（relpath `os.path.relpath(path, openbmc_dir)`）；`git rev-parse` 不真→phase；leaf-pure 不 trap。
  - `lib/devtool_finish.sh` `_devtool_finish_detect_landing <openbmc_dir> <pre> <post> ...`：python 读两份 JSON snapshot → diff **"post 有 pre 无 / status 变 / digest 变"**（**deleted `.patch`/recipe[pre 有 post 无]→ phase=landing fail closed，不进 patches/recipe_files**）→ 按扩展名分类（`.patch`→patches、`.bb`/`.bbappend`→recipe_files）+ 用 openbmc_dir 拼 abs 读 recipe SRCREV（post 文件）→ 每增量文件调 layer-root 解析（复用 resolve_layer_root 的 `conf/layer.conf` 向上找，传 openbmc_dir 作 base_dir）→ 同 layer root 否则 phase=landing；mode 推断（patches 非空→patch，patch-only 也算；否则 recipe 改+SRCREV→srcrev；否则 anomaly）；输出 JSON array 字符串 + landing_layer（相对 openbmc_dir `os.path.relpath`）；NUL sentinel + epilogue rm。
- Change: capture_landing_snapshot（JSON）+ detect_landing（status+digest）+ unit 矩阵（含 dirty-to-dirty + patch-only + 多 layer fail closed + safety copy 过滤）。
- [ ] Step 4: 运行确认通过
  - Run: `bash tests/unit/devtool_finish.sh`
  - Expected: 通过。
- [ ] Step 5: checkpoint（可选）
  - Run: `git add lib/devtool_finish.sh tests/unit/devtool_finish.sh && git commit -m "feat(dev): landing capture(JSON) + detect(status+digest diff)"`
  - Expected: commit 成功或跳过。

---

### Task 5: devtool_finish_run 组装（resolver + reset 链 + safety copy + capture/detect + 13 outvar）

- 目标：`devtool_finish_run` 调 resolve/locate/classify（reset helper）+ parse_status_entry + resolve_layer_root（destination 绝对）+ safety copy（workspace attic）+ capture pre/post（JSON snapshot）+ `devtool finish "$recipe" "$origin_layer"` + detect_landing + postcondition，回传 13 outvar。
- Files: Modify `lib/devtool_finish.sh`、`tests/unit/devtool_finish.sh`。
- 验证范围：`bash tests/unit/devtool_finish.sh`（devtool_finish_run 各分支）+ `tools/ob_check.sh`。
- 接口契约: Consumes reset resolve/locate/classify（既有）、`_devtool_parse_status_entry`/`_devtool_resolve_layer_root`（T3）、`_devtool_finish_capture_landing_snapshot`/`_devtool_finish_detect_landing`（T4）、`_devtool_env_exec`/`_devtool_parse_srctree`（既有）、T0.5 全部 FACT_（人工核对）；Produces `devtool_finish_run`（T6 消费，16 参数）。

- [ ] Step 1: 写失败测试（扩 unit，devtool_finish_run 整体，mock build dir + 假 devtool[status/finish stub] + 真实 capture（mock git repo fixture）+ appends/ + devtool.conf，普通+空格路径）
  - 签名 16 参数：`<machine> <build_dir> <recipe>` + 13 outvar。
  - 用例：noop（status 无 recipe 行 → landing 全空/null、cleaned_bbappend=""）；patch mode（parse_status_entry→recipefile→resolve_layer_root→origin_layer **绝对**；capture pre（真实 capture 在 mock repo 跑）无 patch → finish stub 收 `"$recipe" "$origin_layer"` → capture post 含 `?? patch` → detect patch mode，patches=JSON array 字符串）；srcrev mode；**dirty-to-dirty**（finish 改了已 dirty 的 foo.bb，capture pre/post digest 变 → recipe_files 含 foo.bb）；postcondition 失败（二次 status 仍有 recipe → phase=postcondition rc!=0）；destination 解析失败（无 conf/layer.conf → phase=metadata）；主仓库非 git（`git rev-parse` 假 → phase）。
  - outvar round-trip：patches/recipe_files JSON array 字符串（无 NUL，相对 OPENBMC_DIR）含空格路径 → 原样；srctreebase/bbappend 含空格 → 13 outvar 原样（特殊字符归 T6 mock）。leaf-pure + 输出隔离。
  - **safety copy**：finish 前 srctreebase copy（不 move）到 `build/<m>/workspace/attic/sources/<recipe>.<timestamp>.finish-copy`（不进主仓 baseline，`build/` gitignore）；finish 成功 + devtool 归档→删 copy；devtool 删源未归档→copy 发 attic（rename `<recipe>.<timestamp>`）；retained→删 copy；失败→copy 兜底。
  - **capture 复用**：pre/post 都调 `_devtool_finish_capture_landing_snapshot`（不手写 snapshot）。
  - Run: `bash tests/unit/devtool_finish.sh`
  - Expected: 失败。
- [ ] Step 2: 确认失败
  - Run: `rc=0; bash tests/unit/devtool_finish.sh || rc=$?; (( rc != 0 )) || { echo EXPECTED_FAIL_GOT_PASS >&2; exit 1; }`
  - Expected: 非零。
- [ ] Step 3: 写最小实现（`lib/devtool_finish.sh` `devtool_finish_run`）
  - 16 参数；内部 stage/stdout/stderr/snap_pre/snap_post/safety_copy tempfiles（epilogue rm，不 trap）。
  - **runtime 现场断言**（不读 FACT_）：`git -C "$OPENBMC_DIR" rev-parse --is-inside-work-tree` 不真→phase=metadata。
  - resolve_workspace（`_resolved_*`）→ `_devtool_env_exec -- devtool status`→`_devtool_parse_status_entry`（拿 srctree + recipefile；recipefile 空→phase=metadata）（phase=status）→ 无行 noop → `_devtool_resolve_layer_root "$OPENBMC_DIR" "$recipefile" _layered_origin_layer _layered_phase`（destination **绝对**；phase=metadata on fail；现场检 layer root 存在且含 `conf/layer.conf`）→ locate_bbappend（`_located_*`）→ classify（`_classified_*`）→ **safety copy**（按 FACT_FINISH_SOURCE_POLICY：copy srctreebase 到 `$_resolved_workspace_effective/attic/sources/<recipe>.<timestamp>.finish-copy`；copy 不 move；workspace attic 在 build/ 下 gitignore 不进主仓 baseline）→ **`_devtool_finish_capture_landing_snapshot "$OPENBMC_DIR" "$snap_pre" _cap_pre_phase`**（pre JSON）→ `_devtool_env_exec -- devtool finish "$recipe" "$_layered_origin_layer"`（phase=finish on fail）→ **`_devtool_finish_capture_landing_snapshot "$OPENBMC_DIR" "$snap_post" _cap_post_phase`**（post JSON）→ `_devtool_finish_detect_landing "$OPENBMC_DIR" "$snap_pre" "$snap_post"`（`_detected_*`；phase=landing on fail/无变化/多 layer root/deleted patch）→ postcondition（二次 status + recipe 退出 workspace）→ **safety copy 处置**（devtool 归档→删 copy；devtool 删源未归档→copy rename 到 `<recipe>.<timestamp>` 发布 attic；retained→删 copy；失败→copy 兜底）。
  - 回传 13 outvar（`printf -v "$_finish_*"`）；moved 时 destination_parent=`$_resolved_workspace_effective/attic/sources`；cleaned_bbappend=`$_located_bbappend`；landing 字段来自 `_detected_*`（相对 OPENBMC_DIR）；返回 rc。不 exit。
- Change: `devtool_finish_run` 组装 + unit 用例（含 runtime 断言 + safety copy 时序 + dirty-to-dirty + capture 复用）。
- [ ] Step 4: 运行确认通过
  - Run: `bash tests/unit/devtool_finish.sh`
  - Expected: 通过；`tools/ob_check.sh` → ALL GREEN。
- [ ] Step 5: checkpoint（可选）
  - Run: `git add lib/devtool_finish.sh tests/unit/devtool_finish.sh && git commit -m "feat(dev): devtool_finish_run orchestration (resolver + safety copy + capture/detect)"`
  - Expected: commit 成功或跳过。

---

### Task 6: cmd_dev finish 分支 + TTY 菜单 + 十二字段 JSON（emit + argv JSON array + or None）

- 目标：cmd_dev case 加 finish（parser [:838](../../lib/commands.sh#L838) 已预留）+ TTY 菜单加 `6) finish`（recipe 复用 reset status pick，[:937-971](../../lib/commands.sh#L937-L971)）+ 调 `devtool_finish_run` + 12 字段 JSON（标量 argv + 数组 argv JSON 字符串 + `or None`）+ phase 映射 + DRY_RUN + orchestration 12 字段精确。
- Files: Modify `lib/commands.sh`、`tests/orchestration/cmd_dev.sh`。
- 验证范围：`bash tests/orchestration/cmd_dev.sh`（finish 节 + 12 字段精确 + argv JSON array round-trip + null 契约 + 编码失败 stdout 空）。
- 接口契约: Consumes `devtool_finish_run`（T5）+ `devtool_emit_json`（T1）+ machine 前置；Produces cmd_dev finish 分支。

- [ ] Step 1: 写失败测试（`tests/orchestration/cmd_dev.sh` 扩 finish 节，mock `devtool_finish_run`，OB_NO_MAIN=1，真实 `_finish_*`）
  - **12 字段精确 + null**：mock patch mode（patches/recipe_files JSON array 字符串）→ stdout 恰好一物理行 + `json.loads` 精确 key 集合==`{recipe,srctree,srctreebase,disposition,destination_parent,destination,cleaned_bbappend,landing_mode,landing_layer,patches,recipe_files,srcrev}`；patches/recipe_files 数组逐字匹配（含空格，相对路径）；patch mode srcrev is None、landing_mode=="patch"。srcrev mode→srcrev 非空、patches==[]。**noop→landing_mode/landing_layer/srcrev/cleaned_bbappend is None、patches/recipe_files==[]**。
  - **argv JSON array round-trip 含特殊字符**：mock 返回 patches JSON array 字符串含引号/反斜杠/换行（json.dumps 转义后无 NUL）→ argv → python `json.loads` → 合入 → 逐元素精确。
  - **编码失败收口**：REAL_PYTHON fake 让 JSON 编码失败 → exit 1 + stdout 空。
  - phase 映射（metadata/status/finish/landing/postcondition）+ parser（finish recipe/尾随 dry-run/双 recipe）+ 前置（无 recipe→exit 3；machine 未 init→exit 3）+ DRY_RUN + porcelain。
  - Run: `bash tests/orchestration/cmd_dev.sh`
  - Expected: 失败（finish reserved）。
- [ ] Step 2: 确认失败
  - Run: `rc=0; bash tests/orchestration/cmd_dev.sh || rc=$?; (( rc != 0 )) || { echo EXPECTED_FAIL_GOT_PASS >&2; exit 1; }`
  - Expected: 非零。
- [ ] Step 3: 写最小实现（`lib/commands.sh`，argv `"$dev_recipe"` 等，全可空标量 `or None`）
  - 两处 positional（[:843-847]+[:851-858]）`modify|reset)`→`modify|reset|finish)`。
  - TTY 菜单 [:897-903] 加 `6) finish   devtool finish a recipe (land patches back to layer)`；[:905] prompt `[1-6]`；case `6) dev_subcmd="finish"`；recipe 补参 `finish)`：复用 reset status pick（[:937-971](../../lib/commands.sh#L937-L971) `devtool_status_run` + `read_list_choice`，空→exit 3）；非 TTY 走 parser。
  - finish case（`*)` 前加 `finish)`）：无 recipe→exit 3+remedy；DRY_RUN→stderr 预览 exit 0；调 `devtool_finish_run "$dev_machine" "$dev_build_dir" "$dev_recipe" _finish_srctree _finish_srctreebase _finish_disposition _finish_destination_parent _finish_cleaned_bbappend _finish_landing_mode _finish_landing_layer _finish_patches _finish_recipe_files _finish_srcrev _finish_phase _finish_stage _finish_stderr_file`；`cat stderr`+rm；按 phase/stage/rc 映射 exit；成功→JSON。
  - **JSON 12 字段**：`JSON_TMP="$(mktemp)"`；`python3 -c 'import json,sys; patches=json.loads(sys.argv[9]) if sys.argv[9] else []; rf=json.loads(sys.argv[10]) if sys.argv[10] else []; print(json.dumps({"recipe":sys.argv[1],"srctree":sys.argv[2],"srctreebase":sys.argv[3],"disposition":sys.argv[4],"destination_parent":sys.argv[5] or None,"destination":None,"cleaned_bbappend":sys.argv[6] or None,"landing_mode":sys.argv[7] or None,"landing_layer":sys.argv[8] or None,"patches":patches,"recipe_files":rf,"srcrev":sys.argv[11] or None}))' "$dev_recipe" "$_finish_srctree" "$_finish_srctreebase" "$_finish_disposition" "$_finish_destination_parent" "$_finish_cleaned_bbappend" "$_finish_landing_mode" "$_finish_landing_layer" "$_finish_patches" "$_finish_recipe_files" "$_finish_srcrev" > "$JSON_TMP"`（argv[9]/[10] JSON array 字符串 `json.loads` 合入；cleaned_bbappend/landing_mode/landing_layer/srcrev `or None`）；rc!=0→rm+exit 1（stdout 空）；`devtool_emit_json "$JSON_TMP" || { rm -f ...; exit 1; }`。
- Change: 两处 positional + 菜单 + finish case + orchestration（12 字段 + argv JSON array + null + REAL_PYTHON）。
- [ ] Step 4: 运行确认通过
  - Run: `bash tests/orchestration/cmd_dev.sh`
  - Expected: 通过；`tools/ob_check.sh` → ALL GREEN。
- [ ] Step 5: checkpoint（可选）
  - Run: `git add lib/commands.sh tests/orchestration/cmd_dev.sh && git commit -m "feat(dev): cmd_dev finish branch + atomic 12-field JSON porcelain"`
  - Expected: commit 成功或跳过。

---

### Task 7: ob usage + 交互菜单 finish + dev_interactive.exp + usage_dispatch_sync

- 目标：usage 列 finish；菜单 finish 序号 6；`dev_interactive.exp` finish 交互；`usage_dispatch_sync.sh` 枚举串 + finish 断言；PTY 守卫。
- Files: Modify `ob`、`tests/protocol/usage_dispatch_sync.sh`、`tests/protocol/dev_interactive.exp`。
- 验证范围：`bash tests/protocol/usage_dispatch_sync.sh` + `expect tests/protocol/dev_interactive.exp`（PTY 守卫）。
- 接口契约: Consumes cmd_dev finish（T6）+ `$STATE_DIR`（T0）；Produces finish dispatch + 交互路径。

- [ ] Step 1: 写失败测试（扩 `usage_dispatch_sync.sh` + `dev_interactive.exp`，先加 finish 断言）
  - `usage_dispatch_sync.sh`：usage dev 行枚举含 finish（更新 [:90](../../tests/protocol/usage_dispatch_sync.sh#L90) `"refresh|reset|status"` → 含 finish）；新增 finish 段（DEV_ARGS `parse_args dev --machine m finish myrecipe` + `main dev ... finish` 调 cmd_dev）。
  - `dev_interactive.exp`：选 `6`→（status pick 或 recipe prompt，按 T6 菜单）→ dry-run/mock → 断言进 finish。
  - Run: `bash tests/protocol/usage_dispatch_sync.sh`
  - Expected: 失败。
- [ ] Step 2: 确认失败
  - Run: `rc=0; bash tests/protocol/usage_dispatch_sync.sh || rc=$?; (( rc != 0 )) || { echo EXPECTED_FAIL_GOT_PASS >&2; exit 1; }`
  - Expected: 非零。
- [ ] Step 3: 写最小实现
  - `ob` usage() dev 行 [:189](../../ob#L189)：`dev  [--machine <machine>] <list|modify|refresh|reset|status|finish>  Develop recipe sources via devtool`；Examples（[:239-244]）加 `ob dev --machine romulus finish phosphor-ipmi-host  # devtool finish, lands patches to layer, outputs JSON`。
  - `usage_dispatch_sync.sh`：枚举断言含 finish；加 finish DEV_ARGS/dispatch 断言（照 reset/status）。
  - `dev_interactive.exp`：finish 交互（选 6 + recipe，dry-run）。
- Change: ob usage + examples + protocol + .exp。
- [ ] Step 4: 运行确认通过（PTY 守卫）
  - Run: `bash tests/protocol/usage_dispatch_sync.sh`
  - Expected: 通过。
  - Run: `if command -v expect >/dev/null 2>&1; then expect tests/protocol/dev_interactive.exp > "$STATE_DIR/dev-exp.log" 2>&1 || { echo "expect rc=$?" >&2; cat "$STATE_DIR/dev-exp.log"; exit 1; }; if grep -qE '^skip |SKIP=[1-9][0-9]*' "$STATE_DIR/dev-exp.log"; then echo "PTY skip 假通过" >&2; cat "$STATE_DIR/dev-exp.log"; exit 1; fi; else echo "expect 不可用：交互路径未验证（记录，不 fail）" >&2; fi`
  - Expected: expect 可用→退出 0 且无行首 `skip `/`SKIP=[1-9]`；不可用→记录。
- [ ] Step 5: checkpoint（可选）
  - Run: `git add ob tests/protocol/ && git commit -m "feat(dev): register finish in usage + menu + dev_interactive.exp"`
  - Expected: commit 成功或跳过。

---

### Task 8: integration finish + safety fault-inject（ADR-0008，观测口径 + capture/detect + safety copy）

- 目标：真实 modify→finish（实测 mode，不预设）+ landing 探测实测（**integration 用 `_devtool_finish_capture_landing_snapshot` 自存 pre/post JSON + detect**）+ safety copy 时序实测 + cleaned_bbappend；safety fault-inject，保 ADR-0008 + ADR-0009 单 writer。
- Files: Modify `tests/integration/ob_dev.sh`、`tests/unit/ob_dev_integration_safety.sh`。
- 验证范围：`tests/run_all.sh --integration`（无并发 writer）+ `bash tests/unit/ob_dev_integration_safety.sh`。
- 接口契约: Consumes cmd_dev finish（T6）+ ob（T7）+ `ob_dev_integration_cleanup`（既有）+ reset/finish helper（source 真实 lib，仅 resolve/locate/parse_entry/resolve_layer_root/capture/detect 不调 run）+ T0.5 FACT_（人工核对）；Produces finish integration + safety。

- [ ] Step 1: 写失败测试（新增 finish integration 断言 + safety fault-inject）
  - `tests/integration/ob_dev.sh` finish 段（HARNESS_ROOT + 前置 + 同 RECIPE）：
    - HARNESS_ROOT source 真实 leaf（仅 `_devtool_reset_resolve_workspace`/`_devtool_reset_locate_bbappend`/`_devtool_parse_status_entry`/`_devtool_resolve_layer_root`/`_devtool_finish_capture_landing_snapshot`/`_devtool_finish_detect_landing`，**不调 `devtool_finish_run`**）。
    - 候选/SKIP 前置：modify 前 `ob dev list` + `devtool_in_env status`；无候选 `SKIP:`+`exit 77`。
    - 同一 `$RECIPE`：候选→managed modify→**finish 前 `_devtool_finish_capture_landing_snapshot "$OPENBMC_DIR" pre.json`** → `ob dev finish` → **`_devtool_finish_capture_landing_snapshot "$OPENBMC_DIR" post.json`** → stdout 12 字段 JSON 读 disposition/landing_mode/patches → **按实测 mode 断言**（patch→验 patches 文件真在 landing_layer、recipe_files 真改；srcrev→验 srcrev 值与 recipe 一致；不强制两种都出现）→ srctreebase 归档 attic（moved，safety copy 时序生效）→ status 确认 recipe 退出 workspace→清理后同 recipe finish 验 noop。失败 trap 权威 status recheck + 清 attic + 清 safety copy。
    - landing 探测实测：finish 后 `_devtool_finish_detect_landing "$OPENBMC_DIR" pre.json post.json` 独立校验 patches/recipe_files 与 ob stdout 一致（**复用同一 capture helper，不手写 snapshot**）。
    - **safety copy 时序实测**：验证 finish 前 srctreebase copy（不 move），finish 后 moved→attic 单一归档目录（无 `<recipe>.<timestamp>.finish-copy` 残留 + 无双归档）；safety copy 在 `build/`（gitignore）不进 landing baseline（capture pre 不含 attic 路径）。
    - **mode 覆盖口径**：报告区分"patch 已实测 / srcrev 未实测（候选未触发）"；两 mode 精确断言在 unit/orchestration。
  - `tests/unit/ob_dev_integration_safety.sh`：新增 finish cleanup fault-inject（status-fail 不 finish、list-fail 不降级、finish-partial-fail 残留检测 + safety copy 兜底不误删用户源），保 ADR-0008。
  - Run: `bash tests/unit/ob_dev_integration_safety.sh`
  - Expected: 失败。
- [ ] Step 2: 确认失败
  - Run: `rc=0; bash tests/unit/ob_dev_integration_safety.sh || rc=$?; (( rc != 0 )) || { echo EXPECTED_FAIL_GOT_PASS >&2; exit 1; }`
  - Expected: 非零。
- [ ] Step 3: 写最小实现（按 Step 1）
  - HARNESS_ROOT source 真实 leaf；候选前置；同 RECIPE modify→finish；**capture pre/post（复用 helper）**；按实测 mode 断言；safety copy 时序实测（无残留/无双归档/不进 baseline）；landing 独立校验（detect 读 capture JSON）；noop；safety fault-inject（含 safety copy 兜底）。
  - **T0.5②落地**：integration 按 FACT_FINISH_SOURCE_POLICY 验证 safety copy 处置。
- Change: ob_dev.sh finish 段 + safety fault-inject。
- [ ] Step 4: 运行确认（需真实 build env，无并发 writer）
  - Run: `bash tests/unit/ob_dev_integration_safety.sh`
  - Expected: 通过。
  - Run: `tests/run_all.sh --integration`
  - Expected: 退出 0（finish 实测 mode + HARNESS_ROOT + capture/detect landing 实测 + safety copy 时序 + safety fault-inject + noop smoke SKIP 77[modify 前]）；环境不具备→SKIP 记录，**不据总 rc 宣称已验证**；报告区分 patch/srcrev 实测。
- [ ] Step 5: checkpoint（可选）
  - Run: `git add tests/integration/ob_dev.sh tests/unit/ob_dev_integration_safety.sh && git commit -m "test(dev): integration finish (observed-mode + capture/detect + safety copy + ADR-0008 fault-inject)"`
  - Expected: commit 成功或跳过。

---

### Task 9: harness 同步（WORKSPACE + workflow_02 + 确认 CONTEXT/ADR 已落）

- 目标：登记路由；workflow_02 finish 收尾；确认 CONTEXT.md（finish/patch landing/porcelain 七十二字段，grilling 已落）+ ADR-0009 在场。
- Files: Modify `rules/03_WORKSPACE.md`、`rules/skills/workflow_02-obmc_dev_modify.md`；确认 `CONTEXT.md`、`docs/adr/0009-ob-dev-workspace-single-writer.md`。
- 验证范围：`tools/ob_check.sh` + 精确文档断言。
- 接口契约: Consumes finish 命令形态 + JSON 契约；Produces harness 登记。

- [ ] Step 1: 写失败检查
  - Run: `rc=0; grep -q 'devtool_finish.sh' rules/03_WORKSPACE.md || rc=$?; (( rc != 0 )) || { echo UNEXPECTED_HIT >&2; exit 1; }`
  - Expected: 非零（未登记；`rc=0` 先初始化）。
- [ ] Step 2: 确认缺失
  - Run: `rc=0; grep -q 'devtool_porcelain.sh' rules/03_WORKSPACE.md || rc=$?; (( rc != 0 )) || { echo UNEXPECTED_HIT >&2; exit 1; }`
  - Expected: 非零。
- [ ] Step 3: 写最小实现
  - `rules/03_WORKSPACE.md`：lib 加 `devtool_porcelain.sh`（emit 原语）+ `devtool_finish.sh`（finish 执行，leaf-pure）；ob dev 子命令枚举加 finish。
  - `rules/skills/workflow_02-obmc_dev_modify.md`：收尾段补 finish（`ob dev --machine <m> finish <recipe>` 落回原属 layer，stdout 12 字段 JSON 读 landing_mode/patches；moved→srctreebase safety-copy 归档 attic；reset 丢弃 / finish 落回 对称；单 writer，无并发；build/deploy 待 ob）。
  - 确认 `CONTEXT.md` `ob dev finish`/`patch landing` + porcelain 七/十二字段（`or None` null 契约）+ cleanup→ADR-0009 在场。
- Change: WORKSPACE + workflow_02；CONTEXT/ADR 核对。
- [ ] Step 4: 运行确认（精确文档断言）
  - Run: `tools/ob_check.sh`
  - Expected: ALL GREEN。
  - Run: `rc=0; grep -q 'devtool_finish.sh' rules/03_WORKSPACE.md && grep -q 'devtool_porcelain.sh' rules/03_WORKSPACE.md && grep -q 'finish' rules/03_WORKSPACE.md && grep -q 'landing_mode' CONTEXT.md && grep -q 'patch landing' CONTEXT.md && test -f docs/adr/0009-ob-dev-workspace-single-writer.md; rc=$?; (( rc == 0 )) || { echo "doc assert fail rc=$rc" >&2; exit 1; }`
  - Expected: 全部命中（`&&` 链 + `rc=$?` + `test -f` 收尾）。
- [ ] Step 5: checkpoint（可选）
  - Run: `git add rules/ && git commit -m "docs(dev): harness sync for finish"`
  - Expected: commit 成功或跳过。

---

### Task 10: 最终验证（全量回归 + integration + baseline 对比 + 安全清理）

- 目标：全量回归 + integration + baseline 对比（errexit 安全）+ 安全清理 state dir。
- Files: 无。
- 验证范围：整库绿。
- 接口契约: Consumes 全部前序 + `$STATE_DIR`；Produces 无。

- [ ] Step 1: ob_check 全绿
  - Run: `tools/ob_check.sh`
  - Expected: ALL GREEN（exit_contract 确认 `devtool_porcelain.sh`+`devtool_finish.sh` leaf-pure；extract_funcs 三段全清；shellcheck baseline 一致/良性；legacy 门禁过）。
- [ ] Step 2: 全量回归（含 .exp，PTY 守卫）
  - Run: `tests/run_all.sh --full`
  - Expected: 退出 0；dev_interactive.exp skip→记录"交互路径未验证"。
- [ ] Step 3: integration
  - Run: `tests/run_all.sh --integration`
  - Expected: 退出 0；77 SKIP 须分别报告"finish 通过（实测 mode，patch/srcrev 哪个）"或"环境缺失 SKIP"，**不据总 rc 宣称已验证**。
- [ ] Step 4: baseline 对比（errexit 安全）
  - Run: `CURRENT="$STATE_DIR/current.txt"; rc_git=0; git status --short > "$CURRENT" || rc_git=$?; (( rc_git == 0 )) || { echo "git status rc=$rc_git" >&2; exit 1; }; rc_diff=0; diff "$STATE_DIR/baseline.txt" "$CURRENT" > "$STATE_DIR/diff.txt" || rc_diff=$?; (( rc_diff <= 1 )) || { echo "diff rc=$rc_diff" >&2; exit 1; }; cat "$STATE_DIR/diff.txt"`
  - Expected: git rc==0；diff rc 0/1（>1 exit 1）；diff `>` 行仅本特性文件。
- [ ] Step 5: 安全清理（canonical + 存在性，失败 exit 1）
  - Run: `CANON_DIR="$(cd "$STATE_DIR" 2>/dev/null && pwd -P)"; CANON_TMP="$(cd "${TMPDIR:-/tmp}" && pwd -P)"; [[ -n "$CANON_DIR" && "$(dirname "$CANON_DIR")" == "$CANON_TMP" && "$(basename "$CANON_DIR")" == ob-dev-finish.* ]] || { echo "canonical 不匹配：拒绝 rm" >&2; exit 1; }; [[ -f "$STATE_DIR/baseline.txt" ]] || { echo "baseline 缺失：拒绝 rm" >&2; exit 1; }; rm -rf -- "$STATE_DIR" && git status --short`
  - Expected: canonical（`pwd -P`）+ baseline 存在；`rm -rf` 与 `git status` `&&` 串联；不符→exit 1；输出摘要。

## 执行纪律

- 实现前批判性复查整份计划 + CONTEXT + ADR-0008/0009 + 全局约束 + 评审 round-1/2/3/4（已吸收）；发现缺项/矛盾/命名不一致/验证命令无效，先修计划。
- **T0.5 必须先于 T3/T4/T5**：FACT_ 未确认→T3/T4/T5 形态不定；probe+static 都不可用→STOP。FACT_ 仅人工核对，runtime 现场检查为准。
- 按顺序 T0→T0.5→T1→T2→T3→T4→T5→T6→T7→T8→T9→T10。T1 先于 T2/T6；T3（resolver）先于 T4（detect 复用 layer root）+ T5；T4 先于 T5；T5 先于 T6；T6 先于 T7/T8。
- **destination 必填**：devtool finish 必须传 destlayer；light resolver（`<base_dir> <file>`，recipefile→conf/layer.conf）算 origin_layer **绝对**。
- **数据通道无 NUL**：patches/recipe_files JSON array 字符串 outvar+argv；NUL 只在 helper 内部 tempfile（detect 7/resolve 3/locate 4）+ capture 内部（`-z`）；**snapshot 文件是 JSON**。
- **snapshot = JSON**（`_devtool_finish_capture_landing_snapshot` 输出 `{"paths":{relpath:{"status","sha256"}}}`）；T5 runtime + T8 integration 复用同一 capture helper。
- **landing = status + digest diff**（识别 dirty-to-dirty）；patch = 新增+变化；**deleted `.patch`/recipe（pre 有 post 无）→ phase=landing fail closed**；landing_layer = conf/layer.conf 向上找（非前缀），多 root fail closed；landing fields 相对 OPENBMC_DIR，destination 绝对；**detect 接 `openbmc_dir` 作 base**（不偷读全局）。
- **patch-only refresh 合法**（recipe_files 空 + patches 非空 → patch mode）。
- **JSON null**：encoder 全可空标量 `or None`；测试断言 None；patches/recipe_files 数组（[]）。
- **safety copy**：finish 前 copy（不 move），命名 `<recipe>.<timestamp>.finish-copy`，放 workspace attic（`build/` gitignore 不进 baseline）；成功后按 FACT_FINISH_SOURCE_POLICY 处置（删/发 attic），避免双归档；capture 过滤 build/workspace/attic。
- **runtime fail-closed（现场检查）**：git rev-parse / destination 解析失败（无 conf/layer.conf）/ snapshot JSON 解析 / 多 layer root → phase。
- **验证命令保 rc**：正向 `bash ...`；预期失败 `rc=0; ...||rc=$?; ((rc!=0))||exit 1`；diff/git/grep `rc=0;...||rc=$?`；不 `|grep`/`|tail`/`echo`/`cp`/`cat`/`head`/`ls|head` 吞 rc。
- **outvar 命名**：`_finish_*`/`_resolved_*`/`_located_*`/`_classified_*`/`_detected_*`/`_layered_*`；helper 内 `result_*`；测试生产 receiver。
- **cleaned_bbappend 正交 disposition**；noop null。
- **helper 不 trap**；单测验 trap 不变。
- **NUL sentinel**：字段数 + 末字段断言（locate 4/resolve 3/detect 7）；capture 输出 JSON（json.loads 校验）。
- **PTY 守卫**：expect 可用 + 无 skip；否则记录。
- **integration 观测口径**：不预设 patch+srcrev；按实测 mode + 报告区分；capture/detect 复用 helper；两 mode 精确断言在 unit/orchestration。
- checkpoint 可选（用户授权）；运行时重查分支。
- 遇阻塞（T0.5 FACT_ 不可得、devtool finish 行为与 FACT_ 不符、build env 进不去、extract_funcs 不认新文件、resolver/capture/detect/safety copy 时序/原子 JSON/state 清理困难、expect 不可用等）立即停下说明，不猜。
- 全部完成运行 T10 + 输出摘要。

## 最终验证

- `tools/ob_check.sh` ALL GREEN（exit_contract 确认 `devtool_porcelain.sh`+`devtool_finish.sh` leaf-pure；extract_funcs 三段全清；shellcheck baseline 一致/良性；legacy 门禁过）。
- `tests/run_all.sh --full` 退出 0（emit 全 python 校验矩阵 + trap 不变；reset 七字段精确含 cleaned_bbappend + locate 回传 bbappend + noop None；finish parse_status_entry/resolve_layer_root[绝对]/capture_landing_snapshot[JSON]/detect_landing[接 openbmc_dir] 矩阵含 dirty-to-dirty digest + patch-only refresh + 多 layer fail closed + deleted patch fail closed + safety copy 过滤；devtool_finish_run 各分支含 runtime 断言 + safety copy 时序 + capture/detect 复用；cmd_dev finish 12 字段精确 + argv JSON array round-trip 含特殊字符 + null 契约 + 编码失败 stdout 空；dev_interactive.exp finish）。
- `tests/run_all.sh --integration` 退出 0（finish 实测 mode + HARNESS_ROOT[仅 source leaf] + capture/detect landing 实测[复用 helper] + safety copy 时序无双归档/不进 baseline + safety finish fault-inject[含 safety copy 兜底] + noop smoke SKIP 77[modify 前]）；77 SKIP 须分别报告 patch/srcrev 实测，不据总 rc 宣称已验证。
- harness 落地（WORKSPACE devtool_porcelain.sh+devtool_finish.sh+finish；workflow_02 finish 收尾）+ CONTEXT（finish/patch landing/七十二字段 + `or None`）+ ADR-0009 在场。
- baseline 对比：git rc==0 + diff rc≤1；无无关改动；state dir 安全清理（canonical + baseline）。

## 审阅 Checkpoint

实施计划 v5（吸收评审 round-1 + round-2 + round-3 + round-4 + round-5：round-4 是执行规格钉死——新增 `_devtool_finish_capture_landing_snapshot` helper + snapshot 用 **JSON object** 格式（`{"paths":{relpath:{"status","sha256"}}}`，T5 runtime + T8 integration 复用同一 helper 避免漂移）、T0.5 去 `ls|head` 改无管道 glob 循环；**round-5 是 detect 接口补全——detect_landing 签名加 `openbmc_dir` 作 base**（读 post SRCREV / 找 conf/layer.conf / landing_layer 相对输出，不偷读全局，capture JSON 只携 relpath）+ **deleted `.patch`/recipe fail closed**（不塞进 patches/recipe_files））已写好并保存到 `docs/plans/2026-07-17-ob-dev-finish-implementation-plan.md`。任务结构：T0/T0.5（前置+事实确认）→ T1（emit）→ T2（reset 对齐）→ T3（resolver）→ T4（capture+detect）→ T5（finish_run）→ T6（cmd_dev）→ T7（usage/protocol）→ T8（integration）→ T9（harness）→ T10（最终）。hybrid 主线已五轮评审确认（light resolver 负责 destination，capture/detect status+digest 负责结果观测）。请先确认这份计划；如果任务边界、接口契约、capture/detect 复用或验证命令要调整，我先改计划再复审。如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行（本 skill 不切入编码）。
