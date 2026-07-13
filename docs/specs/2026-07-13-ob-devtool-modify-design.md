# ob devtool modify 能力设计文档

Status: draft v4（评审 round-3 全吸收后，待定稿）
Date: 2026-07-13

## 修订记录

- v1: brainstorming 初稿
- v2: grilling 评审后大改(砍状态文件/rebuild、补 recipe 元数据缓存、子 shell env、ob_first exit3 边界)
- v3: 评审 round-2 后大改(显式子命令、main fallthrough 标注、缓存 scope/生成器、source path 用 devtool status、.bbappend 归属、双 leaf-pure、JSONL、env helper)
- **v4: 评审 round-3 全吸收**——porcelain stdout 规则(🔴 show_logo/log/info/warn 污染)、`_devtool_env_exec` tempfile 协议、最小 postcondition(Q3 让步)、cache stale detection(Q4 让步)、dispatch 测试写具体(OB_NO_MAIN)、Q1-Q4 拍板落地。

## 背景与目标

`ob` 当前覆盖的生命周期是 `init → build → start-qemu`，全程没有"我要改某个 recipe 的源码"这一步。开发者要改 OpenBMC 某个组件的源码，目前必须手动进 bitbake build env、手动跑 `devtool modify <recipe>`、手动记源码落到了哪里。这条路径既不在 `ob` 的统一前门里，也不在 harness 的规则里。

[bestpractice_06-ob_first.md](../../rules/skills/bestpractice_06-ob_first.md) 早已预埋占位(第 17/25 行)。本轮把它**从"规划中"落地为"发布"**。本轮只做 devtool 工作流第一步 `modify`(devtool 自己创建 workspace `.bbappend` + `EXTERNALSRC`)，命令命名空间按"后续接 build/deploy/finish/reset"预留。

### 核心设计原则:能力(ob)与语义推理(agent)分层

`ob` 是确定性 bash CLI，agentic 性质体现在 agent 驱动 `ob`，而非 `ob` 内嵌 LLM。权威检索(`ob` 做)+ 语义推理(agent 做)，交接点是 `ob` 子命令的**结构化 stdout**。`ob` 不内嵌 LLM——可离线、确定性、无 token 依赖。

### 双交付线

能力(shell) + "知道怎么用能力"(harness) 两条都做:

- **交付线 1(shell 侧)**:`ob dev` 命令组 + `lib/devtool_*.sh` + recipe 元数据缓存(+ sidecar meta)
- **交付线 2(harness 侧)**:`ob --help`/`ob_first`/`WORKSPACE` 登记 + `workflow_02` skill + `SKILLS_INDEX`

### 成功标准

1. `ob dev modify <recipe>` 对已 `init` 的 machine 的合法 recipe 执行 `devtool modify`;modify 后调 `devtool status` 解析真实 srctree,**stdout 恰好一行权威绝对路径**(非拼接)。
2. `ob dev list [pattern]` 输出 JSONL,数据源是 recipe 元数据缓存;**stdout 每行合法 JSON,无 logo/诊断混入**;检测 cache stale 时 `exit 3`。
3. `ob dev`(无子命令)时 `exit 3` + remedy。
4. exit-code 映射遵循 [ob_first](../../rules/skills/bestpractice_06-ob_first.md):recipe 不存在 `exit 1`;machine 未 init `exit 3`;recipe 已 modify `exit 0` + stdout srctree;build env/devtool 真实失败 `exit 1`;缺子命令 `exit 3`;**cache stale `exit 3`**。
5. modify 现状/srctree 运行时查 `devtool status`,不缓存。
6. 命令命名空间预留闭环;本轮不建状态文件。
7. harness 侧落地(`ob --help`/`ob_first` 占位转正式 + exit 3 边界补充/`WORKSPACE`/`workflow_02`/`SKILLS_INDEX`)。
8. `devtool_search.sh` + `devtool_modify.sh` 双 leaf-pure,登记 `exit_contract.py`;exit/remedy 只在 `cmd_dev`。
9. `main()` dispatch 真实执行测试(OB_NO_MAIN source 法),不只 usage/parse_args 比对。
10. **porcelain stdout**:`ob dev` 跳过 `show_logo`,`cmd_dev` 诊断走 stderr,**stdout 只输出契约数据**(JSONL/srctree);测试断言 `list` stdout 每行合法 JSON、`modify` stdout 恰好一行。
11. 四层测试 + `tools/ob_check.sh` 全绿。

## 范围

**交付线 1(shell 侧):**

- 顶层命令组 `ob dev`,显式子命令语法:

```text
ob dev [--machine <m>] list [pattern]      # 检索,读 JSONL 缓存(含 stale 检测)
ob dev [--machine <m>] modify <recipe>     # devtool modify,stdout srctree
ob dev [--machine <m>] refresh             # 重生 JSONL 缓存 + sidecar meta
# 预留(本轮不实现):build / deploy / finish / reset
```

- 新增 `lib/devtool_search.sh`(检索/缓存/stale 检测)、`lib/devtool_modify.sh`(执行 + `_devtool_env_exec` helper)。
- [commands.sh](../../lib/commands.sh) 加 `cmd_dev`(exit seam + porcelain);`ob` 主入口注册 `dev` dispatch。
- recipe 缓存 `workspace/configs/<machine>.recipes.jsonl` + sidecar meta `<machine>.recipes.meta.json`;scope = 当前 bblayers 下所有 target recipe;首次 `list` 懒生成 + `refresh` 重生。
- **porcelain stdout 规则**:`ob dev` 跳过 [ob:244](ob#L244) `show_logo`;`cmd_dev` 不调用写 stdout 的 `log`/`info`/`warn`([util.sh:6/8/10](lib/util.sh#L6-L10)),诊断一律走 stderr(或用 [util.sh:12](lib/util.sh#L12) `error`);**不改 `util.sh`**(其他命令行为不变)。

**交付线 2(harness 侧):**

- `ob` 的 `usage()` 正式列 `ob dev`;`parse_args` case 加 `dev)`;`main()` 加 `if [[ "$COMMAND" == "dev" ]]`。
- [ob_first.md](../../rules/skills/bestpractice_06-ob_first.md) 占位转正式 + exit 3 边界补充。
- [WORKSPACE.md](../../rules/03_WORKSPACE.md) 登记 `lib/devtool_*.sh` + `ob dev` 路由。
- 新增 `rules/skills/workflow_02-obmc_dev_modify.md`;[SKILLS_INDEX.md](../../rules/05_SKILLS_INDEX.md) 登记。
- `ob init` 清理 progress 时删除 `<machine>.recipes.jsonl` + `<machine>.recipes.meta.json`(避免 init 后旧索引残留)。

**测试:** protocol(含真实 dispatch)/ unit / orchestration / integration,详见测试策略。

## 非范围

- 不实现 build/deploy/finish/reset(命名空间留口)。
- 不内嵌 LLM;不做"功能→recipe"映射;不做依赖图;不批量 modify。
- 不改变既有命令行为。
- **本轮不重构 `main()` 为统一 dispatch**(Q1 拍板:选项 A,只加 `if dev` + 测试兜底)。
- **不改 `util.sh`**(porcelain 通过 `ob dev` 路径绕开 show_logo + 不调写 stdout 的 info/warn/log,不动既有 module)。
- 本轮不建状态文件;不手写 `.bbappend`/`EXTERNALSRC`(devtool 管);不碰 init 的 `externalsrc-<machine>.inc`。

## 方案比较

分叉 1-9 维持 v3 决策(recipe 双路径/ob 检索-agent 推理/harness 通用+workflow/检索 recipe+layer+summary/检索性能缓存/本轮不建状态文件/子 shell env/exit3+ob_first/显式子命令)。round-3 新增/调整:

### 分叉 10:stdout 契约 → porcelain(round-3 🔴)

`ob dev list/modify` 的 stdout 是 agent 机器解析的契约(JSONL/srctree)。但 ob 既有 [ob:244](ob#L244) `show_logo` 在所有 dispatch 前,且 [util.sh:6/8/10](lib/util.sh#L6-L10) `log`/`info`/`warn` 都写 stdout(仅 [util.sh:12](lib/util.sh#L12) `error` 写 stderr)。不处理则 `list` stdout 混入 logo+诊断,JSON 解析破。

- **方案 A(选定):porcelain stdout 规则**。`ob dev` 跳过 `show_logo`;`cmd_dev` 诊断走 stderr(用 `error` 或直接 `>&2`),不调 `log`/`info`/`warn`;stdout 只输出 JSONL/srctree。不动 `util.sh`。
- 方案 B:给 `util.sh` 加 machine-readable 模式(全局 flag 让 info/warn 写 stderr)。缺点:改既有 module,影响所有命令。
- 方案 C:dev 子命令完全用独立输出函数。缺点:重复造轮子。

### 分叉 11:`_devtool_env_exec` 返回协议 → tempfile(round-3 🟡)

bash 函数只能 return 一个 rc;stdout 被 porcelain 契约占用;stderr 不能和用户诊断混。"返回 rc + stderr" 太模糊,实现会各模块随意用全局变量/临时文件。

- **方案 A(选定):tempfile 协议**。caller 提供 3 个 tempfile(stage_file/stdout_file/stderr_file),子 shell 把命令输出写 stdout_file、诊断写 stderr_file,函数追踪并写 stage(`cd`/`setup`/`postcondition`/`command`)到 stage_file,返回 rc。`cmd_dev` 读 rc+stage+stderr 决定 exit/remedy,**不靠 stderr 文本猜阶段**。
- 方案 B:全局变量传 rc+stage+stderr。缺点:可读性差、易错。
- 方案 C:stderr 文本启发式分类。缺点:devtool 输出不稳定时误判。

## 推荐方案

每分叉取方案 A。核心:`ob` 只做确定性能力(权威检索 + 执行),语义推理留给 agent;通过 porcelain stdout + 结构化 record 把两者粘合。

关键决策:

1. `ob dev` 显式子命令(`list`/`modify`/`refresh`,预留 `build`/`deploy`/`finish`/`reset`)。
2. `ob` 不内嵌 LLM。
3. recipe 元数据(静态)缓存 + sidecar meta(stale 检测);modify 现状/srctree(动态)查 `devtool status`。
4. 缓存 scope = 全量 target recipe;首次 `list` 懒生成 + `refresh` 重生。
5. 命名空间预留闭环;本轮不建状态文件。
6. `devtool_search.sh` + `devtool_modify.sh` 双 leaf-pure;exit/remedy 只在 `cmd_dev`。
7. `_devtool_env_exec` 子 shell one-shot + **tempfile 协议(stage/stdout/stderr)+ 最小 postcondition**。
8. 缺子命令 `exit 3`,补 ob_first exit 3 边界。
9. `main()` 加 `if dev` + 真实执行测试(不重构 main)。
10. **porcelain stdout**:`ob dev` 跳过 show_logo + 诊断走 stderr,stdout 只契约数据。

## ob 主入口 dispatch 风险(评审 F1)

**现状**:[ob:233-267](ob#L233-L267) `main()` 是显式 if 连串 + [ob:266](ob#L266) `cmd_init` fallthrough;`parse_args`([ob:78](ob#L78))的 case 只解析参数,真正 dispatch 在 main。加 `dev` 只到 parse_args case + usage 会漏测(`ob dev` 落到 `cmd_init`)。

**本轮处置**(Q1 拍板 选项 A):
1. `main()` 加 `if [[ "$COMMAND" == "dev" ]]; then cmd_dev; return $?; fi`。
2. `parse_args` case 加 `dev)`;`usage()` 列 `ob dev`。
3. **`ob dev` dispatch 放在 [ob:244](ob#L244) `show_logo` 之前**(porcelain:dev 不打印 logo)。
4. 真实执行 dispatch 测试(见测试策略 OB_NO_MAIN 法)。
5. "main 改统一 dispatch" 列 ob 待补项。

## 关键边界与组件职责

### `lib/devtool_search.sh`(新增,leaf-pure)

职责:

- `list`:读 `<machine>.recipes.jsonl`;**stale 检测**——读 sidecar `<machine>.recipes.meta.json`,比对当前 bblayers.conf hash/mtime + OpenBMC commit,不匹配返回 stale 标志(由 `cmd_dev` exit 3);匹配则按 pattern(子串匹配 recipe 名)过滤,输出 JSONL。缓存缺失触发懒生成。
- `refresh`:经 `_devtool_env_exec` 子 shell 跑 `bitbake-layers show-recipes` + tinfoil 取 layer/SUMMARY,原子写(temp+mv)`<machine>.recipes.jsonl`,并写 sidecar meta(bblayers.conf hash/mtime + OpenBMC commit + generated_at)。

不负责:不做语义推理;不调 LLM;不 `exit`(leaf-pure);不跑 `devtool modify`/`devtool status`。

### `lib/devtool_modify.sh`(新增,leaf-pure,含 env helper)

职责:

- **`_devtool_env_exec` helper**(devtool_search refresh 复用):签名 `_devtool_env_exec <machine> <build_dir> <stage_file> <stdout_file> <stderr_file> -- <cmd...>`。子 shell `( cd OPENBMC_DIR && source setup <m> <build_dir> && <cmd> )`,命令 stdout→stdout_file、stderr→stderr_file;函数追踪 stage(`cd`→`setup`→`postcondition`→`command`)写 stage_file,返回 rc。**最小 postcondition**(Q3):`source setup` 后校验 `$build_dir/conf/local.conf` 存在 + `devtool`/`bitbake-layers` 可执行(对齐 [init_pipeline.sh:127](lib/init_pipeline.sh#L127) 先例),失败写 stage=`postcondition`。
- `modify` 校验/执行:经 `_devtool_env_exec` 子 shell 跑 `devtool status`(判断已 modify)+ `devtool modify`;解析 `devtool status` 得真实 srctree(权威,非拼接)。
- 识别"已 modify"/"源码有未提交改动"等,转 return code + 结构化结果(stage_file/stderr_file)交 `cmd_dev`。

不负责:不决定 exit/remedy(由 cmd_dev);不手写 `.bbappend`/`EXTERNALSRC`;不读写 recipe 缓存;不 `exit`(leaf-pure)。

### `lib/commands.sh`(`cmd_dev`,exit seam + porcelain)

职责:

- `ob dev` 编排者 + **唯一 exit seam** + **porcelain 出口**。
- 解析 `--machine` + 二级子命令(`list`/`modify`/`refresh`)+ 参数;`--machine` 省略走 [machine_picker.sh](../../lib/machine_picker.sh)。
- **porcelain**:不调 `log`/`info`/`warn`(写 stdout);诊断用 `error`([util.sh:12](lib/util.sh#L12) 写 stderr)或直接 `>&2`;**stdout 只输出契约数据**(list→JSONL,modify→srctree 恰好一行)。
- `list`:`devtool_search` 读缓存/stale 检测/渲染 JSONL;stale→`exit 3` + remedy `Run 'ob dev --machine <machine> refresh' first.`;正常→`exit 0`(0 命中良性)。
- `refresh`:`devtool_search` 重生缓存+meta→`exit 0`。
- `modify`:前置校验(init)→ `devtool_modify`(`_devtool_env_exec` 跑 devtool status+modify+srctree 解析)→ stdout srctree → `exit 0`。
- 据 `_devtool_env_exec` 的 rc + stage_file + stderr_file 映射 exit 1/3/0 + remedy(**按 stage 判 setup/postcondition/command 失败,不靠 stderr 文本**)。

不负责:不语义推理;不直接 `bitbake-layers`/`devtool`。

### `ob` 主入口

- `main()` 在 show_logo **前**加 `if [[ "$COMMAND" == "dev" ]]; then cmd_dev; return $?; fi`(porcelain + dispatch)。
- `parse_args` case 加 `dev)`(解析 `--machine` + 透传二级子命令);`usage()` 列 `ob dev`。

## Interface 形状

### porcelain stdout 契约(round-3 🔴)

| 子命令 | stdout(契约数据,agent 解析) | stderr(诊断,人类) |
|---|---|---|
| `list` | JSONL,每行 `{"recipe","layer","summary"}` | logo(跳过)、info/warn/错误诊断 |
| `modify` | 恰好一行:srctree 绝对路径 | 同上 |
| `refresh` | 空 | 同上 |

`ob dev` 跳过 `show_logo`;`cmd_dev` 诊断走 stderr。测试断言 `list` stdout 每行 `python -c json.loads` 合法、`modify` stdout `[ $(wc -l) -eq 1 ]`。

### recipe 缓存(`<machine>.recipes.jsonl`)

JSONL,与 `list` stdout 同格式。scope = 当前 bblayers 下所有 target recipe。

### sidecar meta(`<machine>.recipes.meta.json`)

```json
{"bblayers_hash":"<sha>","bblayers_mtime":<epoch>,"openbmc_commit":"<sha>","generated_at":"<UTC ISO>"}
```

`list` 启动时比对当前 bblayers.conf hash/mtime + 当前 OpenBMC commit;不匹配 = stale → `exit 3`。

### `_devtool_env_exec` 协议

caller(`cmd_dev`/`devtool_search.refresh`)提供 3 个临时文件:stage_file、stdout_file、stderr_file。函数返回 rc,并写 stage 到 stage_file(`cd`/`setup`/`postcondition`/`command`,标识达到的最后阶段)。caller 读 rc + stage + stderr_file 决定处置:

- stage=`cd`/`setup`/`postcondition` 失败 → setup/env failure(exit 1,诊断"build env 不可用")
- stage=`command` 失败 → devtool failure(exit 1,诊断具体 devtool 错误)

## 数据流 / 控制流

### `ob dev modify <recipe>`

1. `cmd_dev` 解析 `--machine`+`modify`+recipe;machine 省略走 picker。
2. 前置校验:init-done。缺 → `exit 3` + `Run 'ob init <machine>' first.`
3. `devtool_modify` 经 `_devtool_env_exec` 跑 `devtool status`(stage=`command`),判目标 recipe 是否已 modify。
4. 已 modify → 解析 srctree → `exit 0` + stdout(恰好一行 srctree)。
5. 未 modify → 校验存在;不存在 → `exit 1`。
6. `_devtool_env_exec` 跑 `devtool modify`(stage=`command`);setup/postcondition 失败靠 stage 标识。
7. 成功 → 跑 `devtool status` 解析 srctree → `exit 0` + stdout srctree。

### `ob dev list [pattern]`

1. `cmd_dev` 解析 `--machine`+`list`+pattern。
2. **stale 检测**:`devtool_search` 读 sidecar meta,比对当前 bblayers.conf + commit;stale → `exit 3` + `Run 'ob dev --machine <machine> refresh' first.`
3. 读 `<machine>.recipes.jsonl`;缓存缺失懒生成(子 shell tinfoil,首次慢)。
4. pattern 子串匹配 recipe 名,渲染 JSONL 到 stdout。
5. `exit 0`(0 命中良性)。

### `ob dev refresh`

1. `cmd_dev` 解析 `--machine`。
2. 前置校验:init-done。缺 → `exit 3`。
3. `devtool_search` 经 `_devtool_env_exec` 跑 `bitbake-layers show-recipes` + tinfoil,原子写 `<machine>.recipes.jsonl` + 写 sidecar meta。
4. `exit 0`。

### `ob dev`(无子命令)

`exit 3` + `Run 'ob dev list [pattern]' to discover recipes first.`

### `ob init` 清理(新增)

`ob init <machine>` 清理 progress 时删除 `<machine>.recipes.jsonl` + `<machine>.recipes.meta.json`(init 重跑后旧索引必然过期)。

## 错误处理与回退

遵循 [ob_first](../../rules/skills/bestpractice_06-ob_first.md):

| 场景 | exit | remedy / 处置 |
|---|---|---|
| 无二级子命令 | 3 | `Run 'ob dev list [pattern]' to discover recipes first.` |
| machine 未 init | 3 | `Run 'ob init <machine>' first.` |
| **cache stale** | 3 | `Run 'ob dev --machine <machine> refresh' first.`(meta 不匹配 bblayers/commit) |
| recipe 不存在 | 1 | 改名重试或先 `list` |
| recipe 已 modify | 0 | stdout srctree(良性) |
| setup/postcondition 失败(stage 标识) | 1 | build env 不可用:诊断 conf/local.conf/devtool 可执行性 |
| `devtool modify` 失败(stage=`command`) | 1 | 读 stderr_file 定位 devtool 错误 |
| 源码有未提交改动 | 1 | 提示用户先处理(不自动 `--force`) |
| 检索 0 命中 | 0 | 空 JSONL |
| `DRY_RUN==1` | 0 | 预览(拼接 srctree),不进 env、不跑 devtool、不写缓存 |

**失败分类(不靠 stderr 文本)**:`_devtool_env_exec` 写 stage_file(`cd`/`setup`/`postcondition`/`command`),`cmd_dev` 按 stage + rc 判 setup/env failure vs devtool failure,给不同诊断。setup/postcondition 失败的归因有 postcondition 校验(conf/local.conf + devtool/bitbake-layers 可执行)兜底,不靠 stderr 启发式。

回退原则:`exit 1` 才诊断→根因→手动兜底;`exit 3` 按 remedy 补前置。手动兜底按 [ob_first:46](../../rules/skills/bestpractice_06-ob_first.md#L46) 记录绕过 + ob 待补项。

## 测试策略

### Static gates

`exit_contract.py` 同时登记 `devtool_search.sh` + `devtool_modify.sh` 为 leaf-pure(两 module 真 `exit` 让 ob_check 失败)。

### Unit tests

- `tests/unit/devtool_search.sh`:JSONL 读/渲染、pattern 子串、stale 检测(meta 比对)、refresh 重生(mock `_devtool_env_exec`)、函数不 `exit`。
- `tests/unit/devtool_modify.sh`:`devtool status` srctree 解析、已 modify 判定、`_devtool_env_exec` tempfile 协议(stage/stdout/stderr 写入正确)、postcondition 校验、函数不 `exit`。

### Orchestration tests

`cmd_dev` 编排(mock `_devtool_env_exec` + mock devtool):

- porcelain:`list` stdout 每行合法 JSON、无 logo;`modify` stdout 恰好一行路径。
- 执行路径:前置缺失→exit 3;recipe 不存在→exit 1;已 modify→exit 0+srctree;正常 modify→stdout srctree(从 mock devtool status 解析)。
- 检索路径:stale→exit 3+remedy;缓存缺失懒生成;0 命中 exit 0。
- 失败分类:stage=`setup`/`postcondition` → setup 诊断;stage=`command` → devtool 诊断。
- `DRY_RUN==1`→预览(拼接 srctree)、不进 env。

### Protocol tests

- `tests/protocol/usage_dispatch_sync.sh`:`ob --help` 列 `ob dev`,parse_args case 含 `dev`。
- **真实执行 dispatch(OB_NO_MAIN 法,round-3 🟢 具体写)**:`OB_NO_MAIN=1 source "$OB"; cmd_dev(){ echo __CMD_DEV__; return 0; }; main dev list`,断言输出 `__CMD_DEV__` marker 且**未进入 `cmd_init`** Step 1/8(无 init 流水线输出)。利用 [ob:269](ob#L269) 既有 `OB_NO_MAIN` 旁路,测真实 `main()` 分支。
- **porcelain stdout 断言**:`./ob dev list ... | python -c 'import sys,json;[json.loads(l) for l in sys.stdin if l.strip()]'`(每行合法);`[[ $(./ob dev modify ... | wc -l) -eq 1 ]]`(modify 恰好一行)。
- `ob dev` exit-code 契约:各场景 exit 码与上表一致。

### Integration tests(可选/CI)

真实 `devtool modify` + 真实缓存/meta 生成(`--integration`),需真实 build env。验证:`devtool status` srctree 与 ob stdout 一致、stale 检测(改 bblayers 后 list→exit 3)、`refresh` 生成 JSONL+meta 可被 list 读、init 后旧 cache 被清理。默认不在 `run_all.sh` 主路径,作 CI gate。

### Full check

改 `ob`/`lib/*.sh` 后跑 `tools/ob_check.sh`;检查 `tests/.shellcheck-baseline` diff。

## harness 侧改动清单

| 位置 | 改动 |
|---|---|
| `ob` `usage()` | `ob dev` 正式列入 |
| `ob` `parse_args` case | 加 `dev)` |
| `ob` `main()` | show_logo **前**加 `if [[ "$COMMAND" == "dev" ]]; then cmd_dev`(dispatch + porcelain) |
| [ob_first.md](../../rules/skills/bestpractice_06-ob_first.md) | 占位转正式 + exit 3 边界补充 |
| [WORKSPACE.md](../../rules/03_WORKSPACE.md) | 登记 `lib/devtool_*.sh` + `ob dev` |
| `ob init` 清理 | 删除 `<machine>.recipes.jsonl` + `<machine>.recipes.meta.json` |
| **新增** `workflow_02-obmc_dev_modify.md` | 见下方 |
| [SKILLS_INDEX.md](../../rules/05_SKILLS_INDEX.md) | Workflow 分类登记 |

### `workflow_02-obmc_dev_modify.md` 大纲

- 类型:Workflow;适用:agent 改 OpenBMC recipe 源码(modify 阶段)。
- 工作流:识别意图 → 已知 recipe 则 `ob dev modify <recipe>`;未知则 `ob dev list <pattern>`(读缓存快)→ 推理 → `ob dev modify`;遇 `exit 3` 读 remedy(`ob init`/`ob dev list`/`ob dev refresh`);modify 成功从 stdout 读 srctree(恰好一行)→ `cd` 改源码;cache stale 或结果可疑 → `ob dev refresh`;后续 build/deploy/finish 待 ob 提供。
- **porcelain 提示**:agent 解析 `ob dev list` stdout(每行 JSON)、`ob dev modify` stdout(恰好一行路径),忽略 stderr(诊断)。
- 验收标准:先查 `ob --help`?命中 `ob dev`?遇 exit 3 没转手动?按 stdout 契约解析?

## 预留闭环(本轮不实现)

1. 命令命名空间:`ob dev build/deploy/finish/reset`。
2. 状态文件:闭环命令将来真有 ob 独有状态时再设计(modify 现状仍查 devtool status)。
3. recipe 缓存扩展:可加 SRC_URI/依赖字段。

## 未决事项

1. `--machine` 与既有命令一致性(已确认吸收 flag 方案)。
2. 检索实现:`bitbake-layers show-recipes` + tinfoil 取 SUMMARY vs 统一 tinfoil(实施计划定;设计层锁 JSONL+scope)。
3. 缓存缺失时 `list` 行为:懒生成(当前选定)vs exit 3 提示 refresh。
4. 源码有未提交改动:`--force` flag 是否提供(实施计划定)。
5. devtool modify 前置:init-done 是否足够(integration test 验证)。
6. 缓存/meta 命名:`<machine>.recipes.jsonl`/`<machine>.recipes.meta.json` 暂定。

## 评审 round-3 拍板结果(Q1-Q4)

- **Q1**:选项 A(本轮只加 `if dev` + 真实 dispatch 测试,不重构 main)——**接受**。前提满足:OB_NO_MAIN 测试 + porcelain show_logo 处理已纳入 v4。
- **Q2**:强制显式 `ob dev modify <recipe>`——**接受**。
- **Q3**:最小 postcondition——**接受驳回**。v4 改为 `_devtool_env_exec` source 后校验 `conf/local.conf` + `devtool`/`bitbake-layers` 可执行(对齐 [init_pipeline.sh:127](lib/init_pipeline.sh#L127) 先例)。
- **Q4**:stale detection——**接受驳回**。v4 改为 sidecar meta(bblayers hash/mtime + commit)+ `list` 检测 stale→exit 3 + `ob init` 清理 cache。
