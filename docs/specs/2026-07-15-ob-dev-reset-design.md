# ob dev reset 子命令设计文档

Status: 已审核通过（v6，评审 6 轮终审批准，2026-07-15，进入 writing-plans）

Date: 2026-07-15

## 修订记录

- v1：brainstorming 初稿。
- v2：吸收 round-1（reset 真实处置 / srctreebase 来自 bbappend / stdout JSON / managed-path / phase）。
- v3：吸收 round-2（bbappend 鲁棒定位 / disposition postcondition / destination_parent / json.dumps）。
- v4：吸收 round-3 裁决选 b（移除 `--remove-work`，只发默认 reset）+ 正确性吸收（二次 status / pre_state 四态 / effective workspace / 字面解析 / JSON argv）。
- **v5：吸收 round-4**。(1) disposition 从"reset 后反推 moved"改为"**reset 前算 expected_disposition + reset 后验证**"——修正 srctreebase 与 `appends/<pn>`/`recipes/` 重叠（preservedir 先于 srctreebase 处理，standard.py:2051-2068）及 `sources-*` 歧义（startswith 无边界，:2079）的反例；(2) proper-descendant 回到 reset 用于 moved 分类 + 歧义 fail closed（非删除准入）；(3) devtool.conf 严格解析（文件存在但解析失败 ≠ 未配置 → phase=metadata）；(4) "无破坏性"措辞改"source-preserving（无递归源码删除）"；(5) 并发契约明确（不支持并发 workspace writer，检查只检测异常不提供 snapshot isolation）；(6) workflow_02 链接修正。
- **v6：吸收 round-5 终审**。moved 分类改**双向 predicate 对齐**：P（raw 字面 startswith，镜像 Poky standard.py:2079）与 O（canonical proper-descendant）须一致；`P != O` **一律 fail closed**（phase=metadata，reset 前拒绝）——补全 v5 只处理 `P=true/O=false`（sources-backup）而遗漏 `P=false/O=true`（`alias/../sources`、外部 symlink 指入 sources）的方向。raw/canonical 分开保留（`workspace_path_raw`/`srctreebase_raw` 来自 devtool.conf/bbappend 原始字符串；canonical 按 `build_dir` 解析）；P 用 raw、O 用 canonical，正确支持相对 `workspace_path`。

## 背景与目标

`ob dev` 当前覆盖 `modify`/`list`/`refresh`，但 `modify` 创建的 externalsrc + devtool 生成 `.bbappend` 没有收尾命令——开发者被迫手动 `devtool reset`。这是 [ob_first](../../rules/skills/bestpractice_06-ob_first.md) 要消灭的绕过路径，也是 [workflow_02](../../rules/skills/workflow_02-obmc_dev_modify.md) 承认的闭环缺口。`reset` 是 `modify` 的镜像逆操作，是 ob dev 最小可发布闭环（`build`/`finish`/`reset`）的第一环。

### reset 的真实处置（已核实 standard.py:2041-2094）

默认 `devtool reset`（无 `--remove-work`）的执行顺序与处置：
1. 删 bbappend（:2044-2049）。
2. `preservedir(recipe 目录)` + `preservedir(<workspace>/appends/<pn>)`——移文件到 `attic/<pn>/<pn>`，rmdir 原目录（:2051-2068）。
3. srctreebase 处理（:2070-2094）：在 `<workspace>/sources` 下（字面 `startswith`，无边界）→ move 到 `attic/sources/<pn>.<timestamp>`；外部 → 保留；空 → rmdir；不存在 → 跳过。

关键事实：
- devtool 操作 `workspace[pn]['srctreebase']`（:2070），`devtool status` 输出 `['srctree']`（:1989），`S` 子目录时二者不同（:949）。
- bbappend 命名 `<pn>_<version>.bbappend`（:179/1118）；`srctreebase` 与 `EXTERNALSRC:pn-<pn>` 写在 bbappend（:979/983）。
- **反例（不需并发）**：srctreebase 与 `appends/<pn>`/`recipes/` 重叠时，步骤 2 preservedir 先处置（移到 `attic/<pn>/<pn>`），步骤 3 跳过——原路径消失但去向不是 `attic/sources`。`sources-backup/foo` 因 startswith 无边界也进 attic/sources 分支。
- 默认 reset 仍执行 `bitbake -c clean`、删 bbappend、移修改文件/srctree 到 attic、对空 srctreebase rmdir——**不是"零副作用"**，但**不递归删除非空 srctreebase**。
- **本轮不实现 `--remove-work`**（源码递归删除）；默认 reset 对非空 srctreebase 只 move/保留，不删除（空目录 rmdir 除外）。

### 成功标准

1. `ob dev reset [--machine <m>] <recipe>` 对已 modified recipe 执行**默认** `devtool reset`（解除 externalsrc）。
2. stdout 输出**结构化 JSON 单行**（`python3 json.dumps` 生成，值经 `sys.argv`/stdin），字段 `recipe`/`srctree`/`srctreebase`/`disposition`/`destination_parent`/`destination`；报告**处置类别 + 归档父目录**（精确 attic 子目录不可用，`destination=null`）。
3. **disposition = reset 前 expected + reset 后验证**（非反推）：reset 前据 srctreebase 位置/状态算 `expected_disposition`（moved/retained/removed/absent），reset 后 postcondition 验证 srctreebase 状态符合 expected，不符 `phase=postcondition` exit 1。
4. **歧义/重叠路径 reset 前拒绝**（`phase=metadata` exit 1，不 reset）：srctreebase 与 `<workspace>/appends` 或 `<workspace>/recipes` 重叠；**P/O predicate 双向分歧**（Poky raw `startswith(sources)` 与 canonical proper-descendant 不一致——含 `sources-*`、`alias/../sources`、symlink 交错两个方向）；非目录/无法 stat。
5. bbappend 鲁棒定位：扫 `appends/*.bbappend` + 字面解析 `EXTERNALSRC:pn-<recipe>` + 校验 EXTERNALSRC==status srctree + 恰好一个；零/多/不一致 → `phase=metadata` exit 1，**不降级 noop**；无 `# srctreebase:` 注释 → `srctreebase=srctree`。
6. postcondition 含**二次 `devtool status`**：reset 后 status 成功 + 不再含 recipe；任一不符 `phase=postcondition` exit 1。
7. `<workspace>` 取 devtool effective `workspace_path`（严格解析 `<build>/conf/devtool.conf [General]`：不存在/无字段→默认，存在但无法读/解析/字段无效→`phase=metadata`）。
8. machine 模型沿用现有。
9. exit-code 遵循 [exit-code 契约](../../CONTEXT.md) + [ADR-0008](../adr/0008-ob-dev-cleanup-fail-safe.md)；phase 区分 status/metadata/reset/postcondition。
10. `devtool_reset.sh` leaf-pure，登记 `exit_contract.py`。
11. 四层测试（含 appends/recipes 重叠、sources-* 歧义、expected 验证、devtool.conf 严格解析、JSON round-trip）+ `ob_check.sh` 全绿；integration 单独 `tests/run_all.sh --integration`。

## 范围

- `ob dev reset [--machine <m>] <recipe>` 子命令（**默认 reset，source-preserving，无 `--remove-work`**）。
- 新增 `lib/devtool_reset.sh`（leaf-pure，`devtool_reset_run`）。
- `cmd_dev` 加 `reset` 分支（替换 reserved 死路）。
- `ob` usage + 交互菜单登记 reset。
- `workflow_02` 补收尾步骤。
- 四层测试。

## 非范围

- **不提供递归删除非空 srctreebase 的能力（无 `--remove-work`）**：默认 reset 解除 externalsrc，并由 Poky 清理 workspace metadata/sysroot（clean、删 bbappend、移修改文件/srctree 到 attic、空 srctreebase rmdir），同时**保留或归档非空 srctreebase**。破坏性清理（`--remove-work`）另立设计，门槛见技术债。
- 不实现 `build`/`finish`/`deploy`/`status`。
- 不暴露 `-a/--all`；不做跨 machine 扫描。
- 不改 `modify`/`list`/`refresh` 既有行为；不改 `_devtool_env_exec`/`_devtool_parse_srctree`。
- **不抽 `devtool_workspace.sh`**；**不引入 workspace 锁**（不存在递归源码删除路径，本轮无需 TOCTOU 强锁；锁协议随未来破坏性清理另立）。
- 不内嵌 LLM。

## 方案比较

### lib 拆分

**方案 A（推荐）：新 `lib/devtool_reset.sh`。** 文件边界对称（modify/search/reset 三 leaf）；modify 零改动。复用 `_devtool_env_exec`/`_devtool_parse_srctree` 靠 loader glob 字母序（[ob:73-76](../../ob#L73-L76)，已核实 m<r<s）——范围复用非优点，列技术债。

**方案 B：扩 `devtool_modify.sh`。** 拒绝——modify 已测试锁死，扩它违反"不改既有"。

### stdout 契约

**JSON 单行（推荐）：** reset 结果本质结构化（disposition + srctree/srctreebase + destination_parent），纯路径表达不了。reset 特例，modify/list 不变。`python3 json.dumps` 生成，值经 `sys.argv`/stdin。

**纯路径：** 拒绝——表达不了 disposition。

## 推荐方案

方案 A + JSON stdout + **默认 source-preserving reset** + **disposition expected 模型**（reset 前算 expected + reset 后 postcondition 验证）+ bbappend 鲁棒定位 + 二次 status。

主要 trade-offs：reset stdout JSON 是 ob dev porcelain 特例（必要）；attic 精确路径不可用（`destination=null`，收窄契约为处置类别 + 归档父目录）；本轮不提供源码删除（`--remove-work` 另立）。

## 关键边界与组件职责

### `lib/devtool_reset.sh`（新增，leaf-pure）

职责：
- `devtool_reset_run`：解析 effective workspace → status 确认 modified → bbappend 鲁棒定位取 srctreebase → **算 expected_disposition**（含重叠/歧义拒绝）→ 默认 reset → postcondition（二次 status + 验证 expected）。通过 outvar 回传，返回 rc。
- 复用 `_devtool_env_exec`/`_devtool_parse_srctree`（技术债）。
- 失败分类：`stage`（cd/setup/postcondition/command）+ `phase`（status/metadata/reset/postcondition）。

不负责：不决定 exit/remedy（cmd_dev）；不直接写用户可见 stderr；不 `exit`（leaf-pure）。

### `lib/commands.sh`::`cmd_dev`（exit seam + porcelain）

职责：
- `reset` 分支：参数解析 + machine 前置（复用）+ init-done 前置 + 调 `devtool_reset_run` + 按 disposition/phase/stage/rc 映射 exit + JSON stdout（`python3 json.dumps`，值经 `sys.argv`/stdin）+ stderr 诊断。
- porcelain：不调 `log`/`info`/`warn`；诊断 `error`/`>&2`；stdout 只 JSON 单行。

## 单元接口与依赖

### `devtool_reset_run`

```
devtool_reset_run <machine> <build_dir> <recipe> \
                  <srctree_outvar> <srctreebase_outvar> <disposition_outvar> \
                  <destination_parent_outvar> <phase_outvar> <stage_outvar> <stderr_file_outvar>
```

逻辑：
1. **effective workspace（严格解析）**：读 `<build_dir>/conf/devtool.conf` `[General] workspace_path`（configparser）：
   - 文件不存在 / 文件存在无 `[General].workspace_path` → 默认 `<build_dir>/workspace`。
   - 字段有效 → 用字段值（相对路径按 `<build_dir>` 解析）。
   - **文件存在但无法读/解析/字段无效/空字符串歧义 → phase=metadata, rc!=0, 返回**（不静默回退）。
2. `_devtool_env_exec ... -- devtool status` → `_devtool_parse_srctree` 取 srctree。失败 → phase=status, rc!=0, 返回。status 无 recipe 行（未 modified）→ disposition=noop, rc=0, 返回。
3. **bbappend 定位**：python 扫 `<workspace>/appends/*.bbappend`，**字面解析** `EXTERNALSRC:pn-<recipe>` 行取 PN（字符串 ==，不进 grep/awk 正则）；校验 EXTERNALSRC 值 == status srctree；**恰好一个**。零/多/不一致 → phase=metadata, rc!=0, 返回（**不降级 noop**）。读匹配 bbappend 的 `# srctreebase:` 注释；无注释 → srctreebase=srctree。
4. **算 expected_disposition（reset 前，含拒绝；moved 分类仅对 nonempty_dir）**：
   - srctreebase 与 `<workspace>/appends` 或 `<workspace>/recipes` 重叠（canonical proper descendant 或相等）→ phase=metadata, rc!=0, 返回（**与 devtool metadata 清理路径重叠，不 reset**）。
   - srctreebase 非目录/无法 stat → phase=metadata, rc!=0, 返回。
   - nonempty_dir 的 moved 分类用**双向 predicate 对齐**（详见下方 predicate 定义）：
     - P=true, O=true → expected=moved。
     - P=false, O=false → expected=retained。
     - P=true, O=false（如 `sources-backup/<recipe>`、sources 内 symlink 指外）→ phase=metadata, rc!=0, 返回。
     - P=false, O=true（如 `alias/../sources/<recipe>`、外部 symlink 指入 sources）→ phase=metadata, rc!=0, 返回。
     - 即 **P != O 一律 fail closed**（双向，修正 v5 只处理 P=true/O=false 的遗漏）。
   - 空目录 → expected=removed（Poky 不做 startswith 分类，直接 rmdir）。
   - missing → expected=absent（Poky 跳过）。
   - 记录 raw/canonical 路径用于 postcondition 验证。
5. `_devtool_env_exec ... -- devtool reset <recipe>`（**默认，无 --remove-work**）。失败 → phase=reset, stage=command, rc!=0, 返回。
6. **postcondition（验证 expected）**：
   - 二次 `_devtool_env_exec ... -- devtool status` → 失败 → phase=postcondition, rc!=0, 返回。
   - status 仍含 recipe（未退出 workspace）→ phase=postcondition, rc!=0, 返回。
   - 检查 srctreebase 原路径状态，与 expected 比对：
     - expected=moved：原路径必须不存在 → disposition=moved, destination_parent=`<workspace>/attic/sources`。
     - expected=retained：原路径必须仍存在 → disposition=retained。
     - expected=removed：原路径必须不存在 → disposition=removed。
     - expected=absent：原路径必须仍不存在 → disposition=absent。
   - 不符 → phase=postcondition, rc!=0, 返回（**不输出推测 JSON**）。
- 回传：`printf -v` 设 outvar；destination_parent 仅 moved 时非空；destination 恒空。返回 rc（不 exit）。
- 依赖：`_devtool_env_exec`/`_devtool_parse_srctree`、devtool.conf、bbappend、devtool `status`/`reset`、effective workspace。
- 对外契约稳定：签名 + outvar 语义；内部（bbappend 解析、expected 计算、postcondition、workspace_path 解析）可变。

predicate 定义（python，P/O 双向）：
- **P（镜像 Poky 字面 startswith，standard.py:2079）**：`srctreebase_raw.startswith(os.path.join(workspace_path_raw, "sources"))`，均用 **raw 字符串**（devtool.conf/bbappend 原始值，未经 canonicalize；`workspace_path_raw` 缺失用 devtool 默认）。
- **O（canonical proper-descendant）**：`srctreebase_canonical != sources_root_canonical and os.path.commonpath([srctreebase_canonical, sources_root_canonical]) == sources_root_canonical`，均 **canonical realpath**（相对路径按 `build_dir`——devtool 执行 cwd——解析后 realpath，解引用 symlink）。
- canonicalization 失败 → fail closed（phase=metadata）。
- moved 分类要求 P==O==true；**P != O → fail closed**（phase=metadata，不 reset）。

### `cmd_dev` reset 分支

- 解析 `--machine`/`reset`/`<recipe>`（**无 `--remove-work`；收到 → exit 1 unknown option**）。
- machine + init-done 前置（复用）。
- 无 recipe → exit 3 + remedy。
- `DRY_RUN==1` → 预览，exit 0。
- 调 `devtool_reset_run` → 按 disposition/phase/stage/rc 映射。
- JSON stdout：值经 stdin/argv 传 `python3 json.dumps`（**不插 `-c` 源码字符串**）。

## 数据流 / 控制流

1. 解析 `--machine`/`reset`/`<recipe>`；`--remove-work` → exit 1 unknown option。
2. machine 前置（[:862-884](../../lib/commands.sh#L862-L884)）+ init-done 前置；缺 → exit 3。
3. 无 recipe → exit 3 + remedy。
4. `DRY_RUN==1` → 预览，exit 0。
5. `devtool_reset_run`：effective workspace（严格）→ status → noop? → bbappend 定位 → **expected_disposition（含重叠/歧义拒绝）** → 默认 reset → postcondition（二次 status + 验证 expected）。
6. disposition=noop → stderr 提示, stdout JSON disposition=noop, exit 0。
7. phase=metadata（devtool.conf 解析失败 / bbappend 零多不一致 / appends|recipes 重叠 / sources-* 歧义 / 无法 stat）→ exit 1 + 诊断。
8. phase=status/reset/postcondition 失败 → exit 1 + 对应诊断。
9. stage=cd/setup/build-env 失败 → exit 1 + build env 诊断。
10. 成功 → stdout JSON（disposition=moved/retained/removed/absent + destination_parent）+ stderr 诊断, exit 0。

## 错误处理与回退

遵循 [exit-code 契约](../../CONTEXT.md) + [ADR-0008](../adr/0008-ob-dev-cleanup-fail-safe.md)：

| 场景 | exit | stdout | stderr / 处置 |
|---|---|---|---|
| `--remove-work`（任何子命令） | 1 | 空 | `ob dev: unknown option '--remove-work'`（本轮未实现） |
| 无 recipe | 3 | 空 | `Run 'ob dev --machine <m> list [pattern]'...` |
| machine 未 init | 3 | 空 | `Run 'ob init <machine>' first.` |
| 未 modified（noop） | 0 | JSON disposition=noop | `not modified, nothing to reset` |
| 默认 reset ob-managed → moved | 0 | JSON disposition=moved, destination_parent=attic/sources | `srctreebase moved to <workspace>/attic/sources/ (timestamped subdir)` |
| 默认 reset 外部 → retained | 0 | JSON disposition=retained | `srctreebase left as-is at <path>` |
| 空 srctreebase → removed（rmdir） | 0 | JSON disposition=removed | `srctreebase (empty) removed` |
| srctreebase 本来 missing → absent | 0 | JSON disposition=absent | `srctreebase already absent` |
| devtool.conf 解析失败/字段无效 | 1 | 空 | `metadata error: devtool.conf ...`（phase=metadata） |
| bbappend 零/多/EXTERNALSRC 不一致 | 1 | 空 | `metadata error: bbappend ...`（phase=metadata） |
| srctreebase 与 appends/recipes 重叠 | 1 | 空 | `metadata error: srctreebase overlaps devtool metadata path`（phase=metadata，不 reset） |
| `sources-*` 歧义 / 无法 stat | 1 | 空 | `metadata error: ambiguous srctreebase path`（phase=metadata） |
| status 失败 | 1 | 空 | `devtool status failed`（phase=status） |
| reset 失败 | 1 | 空 | `devtool reset failed`（phase=reset, stage=command, rc!=0） |
| 二次 status 失败 / recipe 仍在 / 状态与 expected 不符 | 1 | 空 | `postcondition failed: ...`（phase=postcondition） |
| setup/cd/build-env 失败 | 1 | 空 | build env 不可用诊断 |
| `DRY_RUN==1` | 0 | 空 | 预览 |

### porcelain stdout 契约（JSON 单行，python3 json.dumps，值经 stdin/argv）

| 形态 | stdout |
|---|---|
| moved | `{"recipe":"<pn>","srctree":"<status>","srctreebase":"<bbappend>","disposition":"moved","destination_parent":"<workspace>/attic/sources","destination":null}` |
| retained | `{...,"disposition":"retained","destination_parent":null,"destination":null}` |
| removed | `{...,"disposition":"removed","destination_parent":null,"destination":null}` |
| absent | `{...,"disposition":"absent","destination_parent":null,"destination":null}` |
| noop | `{"recipe":"<pn>","srctree":"","srctreebase":"","disposition":"noop","destination_parent":null,"destination":null}` |

契约承诺：**准确报告处置类别（disposition）+ 归档父目录（destination_parent，仅 moved）**。精确 attic 子目录不可用（`destination=null`）；**workflow_02 禁止指示 agent 自动清理 attic 或按 mtime/name 猜最新子目录**——需删除时用户明确检查后手动处理。

### ADR-0008 复用边界

reset 复用 ADR-0008"失败即止、不降级"：status/metadata/reset/postcondition 失败一律 exit 非 0，不降级 noop（bbappend 零/多/不一致、devtool.conf 解析失败、路径重叠/歧义尤其不能降级）。reset 的 postcondition 二次 status 对齐 modify 的"副作用后 status 验证"。

### 并发契约

`ob dev reset` **不支持与其他 ob/devtool workspace writer 并发执行**。status、bbappend 读取与 postcondition 跨多个 devtool snapshot；二次 status 与文件状态检查用于**检测结果异常**（recipe 未退出 workspace、srctreebase 状态与 expected 不符），**不提供 snapshot isolation**。准确报告 disposition 的承诺仅在无并发 writer 前提下成立。

## 测试策略

### Static gates

`exit_contract.py` LEAF dict 加 `devtool_reset.sh`。

### Unit `tests/unit/devtool_reset.sh`

mock build dir + 假 devtool（status/reset stub）+ 造 `appends/<pn>_<ver>.bbappend`（含 `EXTERNALSRC:pn-<pn>` + `# srctreebase:`）+ `conf/devtool.conf`：
- **moved 双向 predicate 矩阵（P=raw 字面 startswith, O=canonical proper-descendant）**：
  - 普通 managed（P=true,O=true）→ moved（reset 后消失 + destination_parent=attic/sources）。
  - 普通外部（P=false,O=false）→ retained（仍存在）。
  - `sources-backup/<recipe>` / sources 内 symlink 指外（P=true,O=false）→ phase=metadata 拒绝。
  - `alias/../sources/<recipe>` / 外部 symlink 指入 sources（P=false,O=true）→ phase=metadata 拒绝。
  - 相对 `workspace_path` + 相对 srctreebase → P 用 raw 与 Poky 一致。
  - canonicalization 失败 → 拒绝。
- **pre_state**：空目录 → removed（rmdir）；missing → absent。
- **重叠/其他拒绝**：srctreebase 位于 `appends/<pn>`、`recipes/`；非目录/无法 stat → phase=metadata。
- **postcondition 验证**：expected=moved 但 reset 后仍存在 / expected=retained 但消失 / 二次 status 仍含 recipe / 二次 status 失败 → phase=postcondition exit 1（不输出推测 JSON）。
- **devtool.conf 严格解析**：默认（不存在/无字段）；自定义有效（含相对路径按 build_dir 解析）；文件存在但无法读/解析/字段无效/空字符串 → phase=metadata exit 1。
- bbappend 命名带版本（`<pn>_1.2.bbappend`）扫描命中；字面解析 `gstreamer1.0`（PN 含 `.`）、PN 前缀相近、注释伪 `EXTERNALSRC`、单文件多冲突行。
- bbappend 零/多/EXTERNALSRC 不一致 → phase=metadata exit 1 不降级 noop；无 `# srctreebase:` → srctreebase=srctree。
- noop（status 无行）→ disposition=noop；status/reset 失败 → phase=status/reset。
- **JSON round-trip**：路径含空格/引号/反斜杠/换行 → `json.loads` 还原一致（验证 json.dumps + 值经 stdin/argv）。
- 函数不 exit（leaf-pure）；`_devtool_env_exec` 输出隔离。

### Orchestration `tests/orchestration/cmd_dev.sh`（扩 reset 节，mock devtool_reset_run）

- porcelain：各 disposition → stdout 恰好一行合法 JSON（json.loads）。
- `--remove-work`（任何子命令）→ exit 1 unknown option。
- 无 recipe → exit 3；machine 未 init → exit 3；noop → exit 0。
- phase=status/metadata/reset/postcondition → 独立诊断。
- dry-run 不调 devtool；cmd_dev 不调 info/warn/log。

### Protocol `tests/protocol/usage_dispatch_sync.sh`

- `ob --help` 含 `ob dev ... reset`（**不含 `--remove-work`**）；交互菜单含 reset（序号 4：list/modify/refresh/reset）。
- OB_NO_MAIN 真实 dispatch `main dev --machine m reset <recipe>` 进 cmd_dev reset 分支。
- DEV_ARGS 交接 reset。

### Integration `tests/integration/ob_dev.sh`（`--integration`）

- 真实 `devtool modify <recipe>` → `ob dev reset <recipe>` → 验证：srctreebase move 到 `attic/sources/<recipe>.*`、原 sources/ 路径消失、二次 `devtool status` 不再含 recipe、stdout JSON disposition=moved 且 destination_parent=attic/sources。
- 外部 srctree（手动建 srctree modify）默认 reset → retained。
- 未 modified reset → noop exit 0。
- **trap 清理**：attic 遗留（`attic/sources/<recipe>.*`）+ 外部测试目录 + 残留 workspace 状态。
- 单独执行 `tests/run_all.sh --integration`。

### Full check

改 `ob`/`lib/*.sh` 后跑 `tools/ob_check.sh`；检查 `tests/.shellcheck-baseline` diff。

## harness 侧改动清单

| 位置 | 改动 |
|---|---|
| `ob` `usage()` | `ob dev reset`（**无 `--remove-work`**） |
| `ob` 交互菜单 | reset 序号 4 |
| `lib/commands.sh` `cmd_dev` | reset 分支（替换 reserved 死路）+ phase 诊断 + JSON via json.dumps(stdin/argv) |
| `lib/devtool_reset.sh` | 新增 leaf-pure `devtool_reset_run`（effective workspace 严格解析 + bbappend 鲁棒定位 + expected_disposition + postcondition 二次 status 验证） |
| `tools/exit_contract.py` | LEAF dict 加 `devtool_reset.sh` |
| **[CONTEXT.md](../../CONTEXT.md) `ob dev porcelain stdout`** | 登记 reset JSON 契约（disposition + destination_parent/destination） |
| **[03_WORKSPACE.md](../../rules/03_WORKSPACE.md)** | `ob dev` 子命令清单加 reset；`lib/` 加 devtool_reset.sh |
| `workflow_02-obmc_dev_modify.md` | 补 reset 收尾 + srctree 生命周期（modify 生效 → reset disposition 五态）；**不建议 agent 自动清理 attic，需删除时用户手动** |

## 实施约束（评审终审，非阻塞但 writing-plans 必须遵循）

1. **`workspace_path_raw` 定义**：`configparser.get('General', 'workspace_path')` 得到的 effective string（**未 canonicalize**），不是从配置文件字节截取的原始文本。
2. **缺配置默认 raw**：精确镜像 devtool `os.path.join(build_dir, "workspace")`（配置文件不存在 / 无 `[General]` / 无 `workspace_path` 字段时）。
3. **P 逐字实现**：`srctreebase_raw.startswith(os.path.join(workspace_path_raw, "sources"))`——不手工字符串拼接、不用 canonical 路径比较（保 P 与 Poky standard.py:2079 一致）。
4. **JSON 编码失败收口**：`python3 json.dumps` 执行失败（非 0 退出/异常）由 `cmd_dev` 收口 exit 1；**不得出现 reset 已成功但 JSON 空输出导致命令返回 0**。
5. **实施验证**：`tools/ob_check.sh` 全绿 **+ 单独执行 `tests/run_all.sh --integration`**（二者覆盖范围不同，ob_check 只跑 .sh 子集）。

## 技术债

- **抽 `devtool_workspace.sh`**：`_devtool_env_exec`/`_devtool_parse_srctree` 三消费者（modify/search/reset），靠 loader 字母序。`build`/`finish` 出现时抽。
- **未来恢复 `--remove-work`（递归源码删除）的门槛**（满足任一）：(1) 同一 workspace snapshot 内完成路径解析 + proper-descendant 校验 + 删除；(2) 给 devtool 加 expected-srctreebase 条件参数，snapshot 变化时拒删；(3) ob 自己对已验证受管目录原子隔离后删除，再让 devtool 做非破坏性 metadata reset。届时还需 workspace 锁协议（按 **canonical effective workspace_path** 定位 `<effective-workspace>/.ob-workspace.lock`，覆盖 modify/reset/integration-cleanup/finish 所有 writer，从首次 status 持锁到 reset 后 postcondition）。**proper-descendant 约束**（`candidate != sources_root and commonpath(...) == sources_root`，不用 startswith；symlink realpath；canonicalization 失败 fail closed）作为该未来命令的设计约束保留，亦用于本轮 reset 的 moved 分类 + 歧义 fail closed。

## 未决事项

1. **`workflow_02` reset 步骤文案**：srctree 生命周期（modify 生效 → reset disposition 五态）表述——实施时定。
2. **跨 machine reset**：当前单 machine 为主，不做。未来多 machine 并行改同一 recipe 常见时再评估。
