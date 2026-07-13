# ob devtool modify 实施计划

> v4:吸收评审 round-4——`_devtool_env_exec` 骨架改 **无 `exit` 字面量**的 `&&` 链(避开 exit_contract.py 静态门禁,它逐行扫 exit 不区分 subshell)+ 输出隔离(`source setup` stdout 单独进 stderr_file,只 cmd stdout 进 stdout_file,不对整个 subshell 外层重定向)+ T3 layer 不糊路径 basename(🟢)。
> v3:吸收评审 round-3 的 6 项 finding——首次 list 区分 missing/stale(🔴,missing 懒生成不被 stale 短路)、Task6 清理落点改 cmd_init+新增 devtool_recipes_clear_cache(🔴)、_devtool_env_exec 同一 subshell + 输出隔离协议(🔴)、cmd_dev 处理 pick_machine 无候选/非TTY(🟡)、parse_bitbake_recipes.py layer 来源钉死+schema test(🟡)、parse_args 开头重置 DEV_ARGS(🟢)。
> v2:吸收 round-2(DEV_ARGS 交接/devtool_modify_run 三段/取消自动 commit/stderr 由 cmd_dev 输出/modify 缺 recipe exit3/usage --machine/parse_bitbake_recipes.py/run_all --full)。

## 目标

把已批准的 [ob devtool modify 设计文档](../specs/2026-07-13-ob-devtool-modify-design.md)(v4 定稿)实现为 `ob dev {list|modify|refresh}` 命令组 + `lib/devtool_*.sh` + `tools/parse_bitbake_recipes.py` + recipe 元数据缓存 + harness 侧规则,配齐四层测试,`tools/ob_check.sh` 全绿。

## 架构快照

- `ob dev` 是 agent-facing 命令组,显式子命令 `list`/`modify`/`refresh`,machine 用 `--machine` flag(省略时 cmd_dev **先枚举 initialized machines + 判 TTY**,无候选/非 TTY → exit 3,再走 `pick_machine`)。
- 两个新 leaf-pure 模块:`lib/devtool_modify.sh`(`_devtool_env_exec` + `devtool_modify_run`)、`lib/devtool_search.sh`(检索 + 缓存 + 三态 state + clear helper)。`_devtool_env_exec` 是共享原语,devtool_modify.sh 定义、devtool_search.sh 复用(glob 字母序 devtool_modify.sh 先加载)。
- recipe 生成器 `tools/parse_bitbake_recipes.py`(tinfoil 取 PN/layer/SUMMARY 输出 JSONL);`devtool_search_refresh` 经 `_devtool_env_exec` 调它。
- 缓存 `workspace/configs/<machine>.recipes.jsonl` + sidecar `<machine>.recipes.meta.json`;modify 现状/srctree 查 `devtool status` 不缓存。
- `cmd_dev`(commands.sh)是唯一 exit seam + porcelain + 诊断出口;leaf 不直接写用户可见 stderr。`ob dev` dispatch 放 `main()` 的 `show_logo` 之前。
- 参数交接:全局 `DEV_ARGS=()`(`parse_args` 开头重置),`dev)` 分支 `DEV_ARGS=("$@"); set --`,`main()` 调 `cmd_dev "${DEV_ARGS[@]}"`(既有 cmd_* 无参调用,见 [ob:246-265](../../ob#L246-L265))。
- init 清理:`cmd_init`([commands.sh:743](../../lib/commands.sh#L743))调完 `machine_state_clear_init_progress` 后,调 `devtool_recipes_clear_cache`(不在 init_pipeline.sh)。
- 复用:`bitbake_env.sh` 子 shell one-shot、`machine_state.sh` leaf-pure + records + `machine_state_clear_init_progress`([machine_state.sh:151](../../lib/machine_state.sh#L151))、`machine_picker.sh::pick_machine`(调用者保证非空+TTY)、`exit_contract.py` LEAF dict、`parse_bitbake_deps.py` tinfoil 先例。

## 全局约束

逐字继承自设计文档 + 评审约束,全程不可违反:

- `ob` 不内嵌 LLM;recipe 语义推理由 agent。
- modify 现状/srctree 查 `devtool status`,**不缓存**;recipe 元数据缓存。
- 显式子命令 `ob dev modify <recipe>`,强制显式。
- 缺子命令/缺 recipe → `exit 3`;recipe 不存在 → `exit 1`;已 modify → `exit 0` + stdout srctree。
- **list 缓存三态**:`cache missing`(无 cache 文件)→ **懒生成**(调 refresh 再 list,不 exit 3);`stale`(cache 存在但 meta 不匹配)→ `exit 3` + refresh remedy;`fresh` → 直接 list。
- **machine 前置**:无 `--machine` 时 cmd_dev 先枚举 initialized machines(`machine_state` records,init=done);无候选 → `exit 3` + `Run 'ob init <machine>' first.`;非 TTY → `exit 3` + `Specify a machine: ob dev --machine <machine> ...`;有候选+TTY → `pick_machine`(`pick_machine` 自身不判空/不判 TTY,见 [machine_picker.sh:37](../../lib/machine_picker.sh#L37))。
- `_devtool_env_exec` **同一 subshell + 输出隔离**:`cd`/`source setup`/postcondition/最终 `<cmd>` 必须在**同一个 subshell** `( cd ... && source setup && postcondition && cmd )` 完成(否则 setup 注入的环境丢失);只有最终 `<cmd>` 的 stdout → `stdout_file`;setup/postcondition 的所有输出(source setup 的 stderr、`command -v` 输出)→ `stderr_file` 或丢弃,**不进 stdout_file**;`_devtool_env_exec` 自身**不向调用者 stdout/stderr 直接输出**。postcondition 校验 `$build_dir/conf/local.conf` + `devtool`/`bitbake-layers` 可执行(对齐 [init_pipeline.sh:127](../../lib/init_pipeline.sh#L127))。
- leaf module 不直接写用户可见 stderr;devtool/env 失败详情经 stderr_file 回传,由 `cmd_dev` 统一读 stderr_file 写 stderr。
- porcelain stdout:`ob dev` 跳过 [ob:244](../../ob#L244) `show_logo`;`cmd_dev` 不调 `log`/`info`/`warn`([util.sh:6/8/10](../../lib/util.sh#L6-L10)),诊断走 `error`([util.sh:12](../../lib/util.sh#L12))或 `>&2`;不改 `util.sh`。
- `lib/devtool_search.sh` + `lib/devtool_modify.sh` 双 leaf-pure(不 `exit`),登记 `exit_contract.py`;exit/remedy 只在 `cmd_dev`。
- build env 用子 shell one-shot(仿 [bitbake_env.sh:27](../../lib/bitbake_env.sh#L27));source setup 返回码 silent,靠 `&&` 链 + postcondition 兜底。
- `main()` 只加 `if dev` 分支,不重构 dispatch(列 ob 待补项)。
- `ob init` 清理:在 `cmd_init`([commands.sh:743](../../lib/commands.sh#L743))调完 `machine_state_clear_init_progress` 后调 `devtool_recipes_clear_cache`。
- 不自动 commit:checkpoint 只 status/diff;commit 仅用户批准后。
- 不实现 build/deploy/finish/reset;不改既有命令行为。

## 输入工件

- 设计文档:`docs/specs/2026-07-13-ob-devtool-modify-design.md`(v4 定稿)
- 评审 round-1~4 拍板 + 计划评审 round-2/round-3 的 14 项 finding(本计划 v3 全吸收)

## 文件结构与职责

**Create:**
- `lib/devtool_modify.sh` — `_devtool_env_exec`(同一 subshell + 输出隔离 + postcondition)、`devtool_modify_run`(三段 modify + srctree + stderr 回传);leaf-pure
- `lib/devtool_search.sh` — `devtool_search_list`/`devtool_search_refresh`/`devtool_search_cache_state`/`devtool_recipes_clear_cache` + 路径函数;leaf-pure
- `tools/parse_bitbake_recipes.py` — tinfoil 取当前 bblayers 所有 target recipe 的 PN/layer/SUMMARY,输出 JSONL(layer 来源钉死,见 T3)
- `rules/skills/workflow_02-obmc_dev_modify.md`
- `tests/unit/devtool_modify.sh`、`tests/unit/devtool_search.sh`
- `tests/orchestration/cmd_dev.sh`

**Modify:**
- `tools/exit_contract.py` — `LEAF_EXIT_EXCEPTIONS_BY_BASENAME`(line 53-61)加 devtool_search.sh/devtool_modify.sh
- `lib/commands.sh` — 加 `cmd_dev`;`cmd_init`([:743](../../lib/commands.sh#L743))清理段调 `devtool_recipes_clear_cache`
- `ob` — 全局 `DEV_ARGS`、`usage`([:169](../../ob#L169))、`parse_args` case([:94](../../ob#L94))、`main` show_logo 前([:244](../../ob#L244))
- `tests/protocol/usage_dispatch_sync.sh` — ob dev 断言 + OB_NO_MAIN 真实 dispatch + DEV_ARGS + porcelain
- `rules/03_WORKSPACE.md`、`rules/05_SKILLS_INDEX.md`、`rules/skills/bestpractice_06-ob_first.md`

**接口契约主干:**
- `_devtool_env_exec <machine> <build_dir> <stage_file> <stdout_file> <stderr_file> -- <cmd...>` → 同一 subshell,只 `<cmd>` stdout→stdout_file;stage(`cd`/`setup`/`postcondition`/`command`)→stage_file;返回 rc(T2 Produces)
- `devtool_modify_run <machine> <build_dir> <recipe> <srctree_outvar> <stage_outvar> <stderr_file_outvar>` → 三段(status→未命中 modify→**再次** status 解析 srctree);回传 srctree+stage+stderr_file 路径;返回 rc(T2 Produces)
- `devtool_search_list <machine> <pattern>` → stdout JSONL(T3 Produces)
- `devtool_search_refresh <machine> <build_dir> <stage_outvar> <stderr_file_outvar>` → 经 `_devtool_env_exec` 跑 `parse_bitbake_recipes.py`,原子写 JSONL+meta(失败保留旧 cache),回传 stage+stderr_file;返回 rc(T3 Produces)
- `devtool_search_cache_state <machine> <state_outvar>` → 设 state 为 `fresh`/`missing`/`stale`(missing=无 cache 文件;stale=cache 存在但 meta 不匹配;fresh=都匹配)(T3 Produces)
- `devtool_recipes_clear_cache <machine>` → 删 `<machine>.recipes.jsonl` + `.meta.json`(`DRY_RUN` 预览)(T3 Produces)
- `devtool_recipes_cache_path`/`devtool_recipes_meta_path` → 路径(T3 Produces)
- `cmd_dev` → exit seam + porcelain + 诊断出口(T4 Produces)
- `DEV_ARGS` 全局 → parse_args 开头重置 + dev) 填充(T5 Produces)

---

### Task 1: exit_contract LEAF 登记 + lib/devtool_*.sh 骨架

- 目标:leaf-pure 门禁就位;两空骨架文件被 ob source 不破坏 ob_check。
- Files:
  - Modify: `tools/exit_contract.py`(`LEAF_EXIT_EXCEPTIONS_BY_BASENAME`)
  - Create: `lib/devtool_modify.sh`、`lib/devtool_search.sh`(header + leaf-no-exit 注释 + 空函数区,符合 extract_funcs 三段)
- 验证范围:`tools/ob_check.sh` 全绿。
- 接口契约:
  - Consumes: exit_contract LEAF dict(line 53-61);machine_state.sh leaf-pure 先例
  - Produces: LEAF dict 含 devtool_search.sh/devtool_modify.sh(`set()`);两骨架文件被 ob source

- [ ] Step 1: 写失败检查
- Run: `grep -nE "devtool_search.sh|devtool_modify.sh" tools/exit_contract.py`
- Expected: 无输出
- [ ] Step 2: 确认骨架缺失
- Run: `ls lib/devtool_modify.sh lib/devtool_search.sh 2>&1`
- Expected: No such file
- [ ] Step 3: 写最小实现
  - `tools/exit_contract.py` LEAF dict(在 `bare_mirror.sh` 后)加 `'devtool_modify.sh': set(),` + `'devtool_search.sh': set(),`
  - 创建两骨架,header 仿 machine_state.sh(首行 shebang + `# lib/devtool_*.sh — <职责>. 术语见 CONTEXT.md.` + `# Exit: leaf-no-exit（leaf-pure module）; 调用者负责 exit-code/remedy/诊断.` + 空函数区占位注释)。确保 extract_funcs 无 GAPS。
- Change: exit_contract LEAF +2 entry;两骨架文件
- [ ] Step 4: 运行 ob_check 确认全绿
- Run: `tools/ob_check.sh`
- Expected: 全绿;grep 命中两 basename
- [ ] Step 5: checkpoint status/diff
- Run: `git status --short`
- Expected: 显示 exit_contract.py + 两骨架

---

### Task 2: lib/devtool_modify.sh 实现(_devtool_env_exec + devtool_modify_run 三段)

- 目标:实现 `_devtool_env_exec`(**同一 subshell + 输出隔离 + postcondition**)和 `devtool_modify_run`(**三段**),leaf-pure 不 exit,stderr 经 file 回传不直接写。
- Files:
  - Modify: `lib/devtool_modify.sh`
  - Create: `tests/unit/devtool_modify.sh`
- 验证范围:unit + ob_check。
- 接口契约:
  - Consumes: Task1 门禁;bitbake_env.sh 子 shell source setup 模式;OPENBMC_DIR/BUILD_DIR 全局
  - Produces: `_devtool_env_exec`、`devtool_modify_run`(T3/T4 消费)

- [ ] Step 1: 写失败测试
- `tests/unit/devtool_modify.sh`(仿 machine_state.sh):
  - mock build dir:`$TMP/openbmc/setup`、`$TMP/build/conf/local.conf`(touch)、`$TMP/build/conf/bblayers.conf`;PATH 注入假 `devtool`(stub:`status` 子命令按 recipe 名输出 `<recipe>: <srctree>` 仅当已 modify;`modify` 标记已 modify)
  - `_devtool_env_exec` **输出隔离断言**:调 `... -- echo HELLO` → rc=0、stdout_file 含 `HELLO` 且**不含** setup/postcondition 噪声(如 MOCK_SETUP)、stage_file 含 `command`;**_devtool_env_exec 不直接向调用者 stdout/stderr 输出**(捕获调用者 stdout/stderr 为空);删 local.conf → rc!=0、stage_file 含 `postcondition`
  - `_devtool_env_exec` **同一 subshell 断言**:mock setup 注入导出变量 `export SETUP_DONE=1`;调 `... -- sh -c 'echo $SETUP_DONE'` → stdout_file 含 `1`(证明 cmd 与 source setup 在同一 subshell,环境未丢)
  - `devtool_modify_run` **三段用例**:初始 status 不含 target → 调 → 内部 modify(mock 标记)→ 再次 status 含 target → srctree_outvar 非空且为约定 srctree、stage_outvar=`command`、stderr_file_outvar 路径存在;已 modify(status 含 target)→ 不跑 modify、srctree_outvar 直接得
- Run: `bash tests/unit/devtool_modify.sh`
- Expected: 失败
- [ ] Step 2: 确认失败
- Run: `tests/run_all.sh 2>&1 | grep devtool_modify`
- Expected: FAIL
- [ ] Step 3: 写最小实现(`lib/devtool_modify.sh`)
  - `_devtool_env_exec <machine> <build_dir> <stage_file> <stdout_file> <stderr_file> -- <cmd...>`:**单一 subshell,无 `exit` 字面量**(exit_contract.py 逐行静态扫 `exit`、不区分 subshell,见 [:100-119](../../tools/exit_contract.py#L100-L119);用 `&&` 链代替 `exit`):
    ```bash
    (
      echo cd >"$stage_file"
      cd "$OPENBMC_DIR" &&
      echo setup >"$stage_file" &&
      source setup "$machine" "$build_dir" >>"$stderr_file" 2>&1 &&   # setup 自身 stdout 进 stderr_file,不污染 stdout_file
      echo postcondition >"$stage_file" &&
      [[ -f "$build_dir/conf/local.conf" ]] &&
      command -v devtool >>"$stderr_file" &&
      command -v bitbake-layers >>"$stderr_file" &&
      echo command >"$stage_file" &&
      "$@" >"$stdout_file"                                              # 只有 cmd 的 stdout 进 stdout_file
    ) 2>>"$stderr_file"                                                  # subshell 其余 stderr 进 stderr_file
    return $?
    ```
    要点:**同一 subshell** `&&` 链(任一失败则后续不跑,subshell 返回非零);**无 `exit` 字面量**(`&&` 链 + `return`,exit_contract 静态门禁可通过);**输出隔离**:`source setup`/`command -v` 的 stdout 单独 `>>"$stderr_file"`,**只有 `"$@"` 的 stdout `>"$stdout_file"`**——不对整个 subshell 外层 `>"$stdout_file"`(否则 setup 自身 stdout 会污染);`_devtool_env_exec` 自身不直接 echo 到调用者。全程 `return`(不 `exit`)。
  - `devtool_modify_run <machine> <build_dir> <recipe> <srctree_outvar> <stage_outvar> <stderr_file_outvar>`:内部创建 stage/stdout/stderr tempfiles。
    1. `_devtool_env_exec ... -- devtool status`(stdout_file=status 输出),解析 target recipe 行;命中 → 取 srctree,跳到回传。
    2. 未命中 → `_devtool_env_exec ... -- devtool modify <recipe>`。
    3. modify 成功 → **再次** `_devtool_env_exec ... -- devtool status`,解析 srctree(必命中)。
    回传:`printf -v` 设 srctree_outvar + 读 stage_file 设 stage_outvar + 设 stderr_file_outvar(stderr_file 路径);返回 rc。不 exit。
- Change: 两函数(三段 + 同一 subshell 协议)+ unit test
- [ ] Step 4: 运行确认通过
- Run: `tests/run_all.sh 2>&1 | grep -E "devtool_modify|=== unit"`;`tools/ob_check.sh`
- Expected: ok;ob_check 全绿
- [ ] Step 5: checkpoint status/diff
- Run: `git status --short`
- Expected: devtool_modify.sh + tests/unit/devtool_modify.sh

---

### Task 3: lib/devtool_search.sh + tools/parse_bitbake_recipes.py 实现

- 目标:缓存读写、三态 state(fresh/missing/stale)、refresh(调 parse_bitbake_recipes.py)、clear helper;leaf-pure;layer 来源钉死。
- Files:
  - Modify: `lib/devtool_search.sh`
  - Create: `tools/parse_bitbake_recipes.py`、`tests/unit/devtool_search.sh`
- 验证范围:unit + ob_check。
- 接口契约:
  - Consumes: `_devtool_env_exec`(T2);machine_state.sh 路径模式;CONFIGS_DIR/OPENBMC_DIR/BUILD_DIR 全局;parse_bitbake_deps.py tinfoil 先例
  - Produces: `devtool_search_list`/`devtool_search_refresh`/`devtool_search_cache_state`/`devtool_recipes_clear_cache`/路径函数;parse_bitbake_recipes.py;cache+meta 文件(T4/T6 消费)

- [ ] Step 1: 写失败测试
- `tests/unit/devtool_search.sh`:
  - list:造 `<m>.recipes.jsonl` 3 行 JSON;`devtool_search_list <m> ipmi` → 含 phosphor-ipmi-host;`<m> ""` → 3 行;每行 json.loads 合法
  - **cache_state 三态**:无 cache 文件 → `missing`;有 cache + meta 匹配当前 → `fresh`;有 cache + meta commit 不匹配 → `stale`;有 cache + 无 meta → `stale`
  - refresh:mock `_devtool_env_exec` 让 stdout_file 含假 JSONL → 调后 cache 重生 + meta 写入 + stage_outvar=`command` + stderr_file_outvar 有效;refresh 失败(mock rc!=0)→ **旧 cache 保留**
  - clear:`devtool_recipes_clear_cache <m>` 删 cache+meta;DRY_RUN=1 只预览不删
  - parse_bitbake_recipes.py **schema test**:跑 py(或 mock tinfoil)→ 输出 JSONL 每行 `layer` 非空、`recipe` 非空、summary 缺失时回退 DESCRIPTION
- Run: `bash tests/unit/devtool_search.sh`
- Expected: 失败
- [ ] Step 2: 确认失败
- Run: `tests/run_all.sh 2>&1 | grep devtool_search`
- Expected: FAIL
- [ ] Step 3: 写最小实现
  - `tools/parse_bitbake_recipes.py`(`--build-dir <dir> --machine <m>`):用 tinfoil parse 当前 bblayers 所有 target recipe,取 `PN`/`SUMMARY`(缺省回退 `DESCRIPTION` 压单行)/**layer**。**layer 来源钉死**:优先 tinfoil 的 layer collection(每个 recipe 的提供 layer 名);若 tinfoil 直取 layer 不可靠,改用 `bitbake-layers show-recipes`(输出含 layer 名)解析映射。逐行 `{"recipe","layer","summary"}` JSONL 写 stdout。**保证 layer 非空**(取不到则跳过该 recipe + stderr warn);**layer 必须是 BitBake layer collection/priority 的权威值,不把 recipe 路径 basename 当 layer 名**;tinfoil 取 layer 卡住则停下报告(执行纪律),不糊。parse 失败非 0 退出 + stderr 诊断。
  - `devtool_recipes_cache_path`/`devtool_recipes_meta_path`
  - `devtool_search_cache_state <machine> <state_outvar>`:cache 文件不存在 → `missing`;存在则读 meta 比对当前 bblayers.conf hash/mtime + OpenBMC commit,不匹配/无 meta → `stale`,匹配 → `fresh`;`printf -v` 设 state_outvar。不 exit。
  - `devtool_search_list <machine> <pattern>`:读 JSONL,pattern(子串匹配 recipe)过滤输出;空全部。不 exit。
  - `devtool_search_refresh <machine> <build_dir> <stage_outvar> <stderr_file_outvar>`:内部 tempfiles,`_devtool_env_exec ... -- python3 "$OB_ENTRY_DIR/tools/parse_bitbake_recipes.py" --build-dir "$build_dir" --machine "$machine"`(stdout_file=JSONL);**成功**才原子写(temp+mv)cache + 写 meta;**失败保留旧 cache**;回传 stage + stderr_file;返回 rc。不 exit。
  - `devtool_recipes_clear_cache <machine>`:`rm -f` cache+meta;DRY_RUN=1 只 `info` 预览。不 exit。
- Change: parse_bitbake_recipes.py + 五函数 + unit test
- [ ] Step 4: 运行确认通过
- Run: `tests/run_all.sh 2>&1 | grep -E "devtool_search|=== unit"`;`tools/ob_check.sh`
- Expected: ok;ob_check 全绿
- [ ] Step 5: checkpoint status/diff
- Run: `git status --short`
- Expected: devtool_search.sh + parse_bitbake_recipes.py + tests/unit/devtool_search.sh

---

### Task 4: cmd_dev 编排(commands.sh)

- 目标:实现 `cmd_dev`(exit seam + porcelain + 诊断出口 + machine 前置 + list 三态分支 + modify/refresh 调度 + stage 失败分类 + 读 stderr_file 输出诊断)。
- Files:
  - Modify: `lib/commands.sh`(加 `cmd_dev`,置 cmd_menu 前)
  - Create: `tests/orchestration/cmd_dev.sh`
- 验证范围:orchestration + ob_check。
- 接口契约:
  - Consumes: `devtool_search_list`/`refresh`/`cache_state`(T3);`devtool_modify_run`(T2);`machine_state` records(init=done 枚举)+ init-done 判定;`pick_machine`(非空+TTY 前置);DEV_ARGS(T5)
  - Produces: `cmd_dev`(T5 消费)

- [ ] Step 1: 写失败测试
- `tests/orchestration/cmd_dev.sh`:mock devtool_search_*/devtool_modify_run,OB_NO_MAIN=1 调 cmd_dev 各场景:
  - **machine 前置**:无 `--machine` 且非 TTY → exit 3 + remedy `Specify a machine: ob dev --machine <machine> ...`;无 initialized machine → exit 3 + `Run 'ob init <machine>' first.`;有候选+TTY → 正常 pick
  - **list 三态**:`cache_state=missing` → cmd_dev 调 refresh(懒生成)后输出 JSONL,exit 0(测试断言 refresh 被调);`cache_state=stale` → exit 3 + refresh remedy;`fresh` → 直接 list exit 0
  - `modify` 无 recipe → exit 3 + `ob dev --machine <m> list` remedy;recipe 不存在 → exit 1;已 modify → exit 0 + stdout 恰好一行 srctree;setup/postcondition 失败(stage)→ exit 1 + stderr 含 build env 诊断(**诊断由 cmd_dev 从 stderr_file 读出写 stderr,leaf mock 未直接写**);command 失败 → exit 1 + stderr devtool 错
  - 无子命令 → exit 3 + `ob dev list` remedy
  - porcelain:cmd_dev 不调 info/warn/log
- Run: `bash tests/orchestration/cmd_dev.sh`
- Expected: 失败
- [ ] Step 2: 确认失败
- Run: `tests/run_all.sh 2>&1 | grep cmd_dev`
- Expected: FAIL
- [ ] Step 3: 写最小实现(`cmd_dev`,接收 ${DEV_ARGS[@]})
  - 解析 `--machine <m>` + 二级子命令 + 剩余。
  - **machine 前置**(无 `--machine`):枚举 `machine_state` records 筛 init=done;无候选 → `exit 3` + `Run 'ob init <machine>' first.`;`[[ -t 0 ]]` 非 TTY → `exit 3` + `Specify a machine: ob dev --machine <machine> ...`;否则 pick_machine。
  - porcelain:不调 info/warn/log;诊断 error/>&2;stdout 只 list(JSONL)/modify(srctree 恰好一行)。
  - `list`:`devtool_search_cache_state` → `missing` 则调 `devtool_search_refresh` 懒生成(失败读 stderr_file 写诊断 exit 1)→ 再 `devtool_search_list` → stdout;`stale` → exit 3 + `Run 'ob dev --machine <m> refresh' first.`;`fresh` → list;exit 0。
  - `modify`:无 recipe → exit 3 + `Run 'ob dev --machine <m> list [pattern]'...`;前置 init-done(缺 → exit 3 + ob init remedy);调 `devtool_modify_run` 回传 srctree+stage+stderr_file+rc;**读 stderr_file 按 stage 写诊断到 stderr**(setup/postcondition→build env;command→devtool 错);成功→stdout srctree;已 modify→exit 0+srctree;exit 0。
  - `refresh`:前置 init-done;调 `devtool_search_refresh` 回传 stage+stderr_file+rc;失败读 stderr_file 写诊断 exit 1;成功 exit 0(stdout 空)。
  - 无子命令:exit 3 + `ob dev list` remedy。
- Change: cmd_dev + orchestration test
- [ ] Step 4: 运行确认通过
- Run: `tests/run_all.sh 2>&1 | grep -E "cmd_dev|=== orchestration"`;`tools/ob_check.sh`
- Expected: ok;ob_check 全绿
- [ ] Step 5: checkpoint status/diff
- Run: `git status --short`
- Expected: commands.sh + tests/orchestration/cmd_dev.sh

---

### Task 5: ob 主入口登记(DEV_ARGS 重置 + 交接 + porcelain)

- 目标:usage/parse_args/main 登记 ob dev;DEV_ARGS 在 parse_args **开头重置**;dev dispatch 放 show_logo 前;protocol 测试。
- Files:
  - Modify: `ob`(全局 DEV_ARGS、usage [:175](../../ob#L175)、parse_args case [:94](../../ob#L94)+开头重置、main show_logo 前 [:244](../../ob#L244))
  - Modify: `tests/protocol/usage_dispatch_sync.sh`
- 验证范围:protocol + ob_check。
- 接口契约:
  - Consumes: cmd_dev(T4);OB_NO_MAIN([:269](../../ob#L269));parse_args while *)([:160](../../ob#L160))
  - Produces: ob dev 端到端 + DEV_ARGS(parse_args 开头重置 + dev) 填充)

- [ ] Step 1: 写失败测试(扩 usage_dispatch_sync.sh)
  - `ob --help` 含 `ob dev`(文案 `dev [--machine <machine>] <list|modify|refresh>`,无 positional)
  - DEV_ARGS 正确 + **重置**:`OB_NO_MAIN=1 source ./ob; parse_args build x; parse_args dev --machine m list; [[ "${DEV_ARGS[0]}" == "--machine" && "${DEV_ARGS[1]}" == "m" && "${DEV_ARGS[2]}" == "list" ]]`(先调 build 证明旧 DEV_ARGS 不残留,再调 dev 填充正确)
  - OB_NO_MAIN 真实 dispatch + 参数:`OB_NO_MAIN=1 source ./ob; cmd_dev(){ printf 'GOT:%s\n' "$@"; return 0; }; main dev --machine m list` → 输出 GOT:--machine/m/list(**不含 dev**),不含 cmd_init Step 1/8
  - porcelain:main dev list(mock JSONL)→ stdout 无 logo;main dev modify(mock)→ stdout 恰好一行
- Run: `bash tests/protocol/usage_dispatch_sync.sh`
- Expected: 失败
- [ ] Step 2: 确认失败
- Run: `tests/run_all.sh 2>&1 | grep usage_dispatch_sync`
- Expected: FAIL
- [ ] Step 3: 写最小实现
  - 全局变量区(line 6-32 附近)加 `DEV_ARGS=()`
  - **parse_args() 开头**(`parse_args() {` 后第一行)加 `DEV_ARGS=()`(重置,防多次调用残留)
  - parse_args case(`stop-qemu)` 后)加 `dev)`:`DEV_ARGS=("$@"); set --`(存 dev 后所有参数 + 清空防 while *)
  - main(show_logo **前**)加 `if [[ "$COMMAND" == "dev" ]]; then cmd_dev "${DEV_ARGS[@]}"; return $?; fi`
  - usage Commands 段(stop-qemu 后)加 `  dev         [--machine <machine>] <list|modify|refresh>  Develop recipe sources via devtool`;Examples 加 2-3 例全用 --machine(如 `ob dev --machine romulus list ipmi`)
- Change: ob 全局+parse_args(重置+dev)+main+usage(--machine)+protocol test
- [ ] Step 4: 运行确认通过
- Run: `tests/run_all.sh 2>&1 | grep -E "usage_dispatch_sync|=== protocol"`;`tools/ob_check.sh`
- Expected: ok;ob_check 全绿
- [ ] Step 5: checkpoint status/diff
- Run: `git status --short`
- Expected: ob + usage_dispatch_sync.sh

---

### Task 6: ob init 清理 recipes cache(落点:cmd_init)

- 目标:`cmd_init` 调完 `machine_state_clear_init_progress` 后,调 `devtool_recipes_clear_cache` 清该 machine 的 recipes cache+meta(避免 init 重跑后旧索引残留)。
- Files:
  - Modify: `lib/commands.sh`(`cmd_init`,[machine_state_clear_init_progress 调用 :743](../../lib/commands.sh#L743) 之后)
  - Modify: `tests/orchestration/cmd_dev.sh`(加 cmd_init 清理链断言)或新增 init 清理断言
- 验证范围:orchestration + ob_check。
- 接口契约:
  - Consumes: `devtool_recipes_clear_cache`(T3);`machine_state_clear_init_progress` 调用点([commands.sh:743](../../lib/commands.sh#L743))
  - Produces: cmd_init 清理 recipes cache

- [ ] Step 1: 写失败检查
- 测试:造 `<m>.recipes.jsonl`+`<m>.recipes.meta.json` 在 CONFIGS_DIR;调 cmd_init 的清理路径(或 `ob init <m>` 触发清理段);断言两文件被 `devtool_recipes_clear_cache` 删
- Run: `bash tests/orchestration/cmd_dev.sh`(扩一节,断言 cmd_init 清理链调了 devtool_recipes_clear_cache)
- Expected: 失败(cmd_init 未调 clear_cache,文件残留)
- [ ] Step 2: 确认失败
- Run: `tests/run_all.sh 2>&1 | grep -E "cmd_dev|init"`
- Expected: FAIL
- [ ] Step 3: 写最小实现
  - 落点:`lib/commands.sh` 的 `cmd_init`([:743](../../lib/commands.sh#L743) `machine_state_clear_init_progress "$MACHINE"` 调用**之后**),加 `devtool_recipes_clear_cache "$MACHINE"`(T3 已实现的 leaf helper)。**不**改 init_pipeline.sh(那里没有清理 init progress 的代码;真正清理点在 cmd_init,见 [commands.sh:743](../../lib/commands.sh#L743))。
  - `devtool_recipes_clear_cache` 自身处理 DRY_RUN 预览(T3 实现)。
- Change: cmd_init 加一行调 devtool_recipes_clear_cache + test
- [ ] Step 4: 运行确认通过
- Run: `tests/run_all.sh 2>&1 | grep -E "cmd_dev|=== orchestration"`;`tools/ob_check.sh`
- Expected: ok;ob_check 全绿
- [ ] Step 5: checkpoint status/diff
- Run: `git status --short`
- Expected: commands.sh + test

---

### Task 7: harness 侧落地(workflow_02 + WORKSPACE + SKILLS_INDEX + ob_first)

- 目标:harness 四处落地,让 agent 知道 ob dev 存在、何时用、怎么用。
- Files:
  - Create: `rules/skills/workflow_02-obmc_dev_modify.md`
  - Modify: `rules/03_WORKSPACE.md`、`rules/05_SKILLS_INDEX.md`、`rules/skills/bestpractice_06-ob_first.md`
- 验证范围:ob_check + 人工核对落点。
- 接口契约:
  - Consumes: ob dev 命令形态(T5);exit3 边界(cmd_dev T4)
  - Produces: workflow_02 + 三处登记

- [ ] Step 1: 写检查
- Run: `grep -rl "ob dev\|workflow_02\|devtool_modify.sh" rules/`
- Expected: 无命中(或仅设计文档)
- [ ] Step 2: 确认缺失
- Run: `ls rules/skills/workflow_02-obmc_dev_modify.md 2>&1`
- Expected: No such file
- [ ] Step 3: 写最小实现
  - `workflow_02-obmc_dev_modify.md`:按设计"workflow_02 大纲"——类型 Workflow、适用场景、工作流(识别意图→已知 `ob dev --machine <m> modify <recipe>`/未知 `ob dev --machine <m> list`(首次自动懒生成)→推理→modify→exit3 读 remedy→srctree→refresh→预留闭环)、porcelain 提示(list stdout JSONL/modify stdout 恰好一行,忽略 stderr)、不适用、验收标准。命令示例全 --machine。
  - `WORKSPACE.md`:lib 行(line 11)登记 devtool_modify.sh/devtool_search.sh;ob 行(line 10)补 ob dev;tools 行(line 8)登记 parse_bitbake_recipes.py
  - `SKILLS_INDEX.md`:Workflow 分类加 workflow_02
  - `ob_first.md`:line 17 占位→正式;line 25 planned 移除;exit3 边界补充"缺可检索子命令/recipe 类比缺 machine"
- Change: workflow_02 + 三文档
- [ ] Step 4: 运行确认
- Run: `tools/ob_check.sh`;`grep -rl "ob dev\|workflow_02\|devtool_modify.sh\|devtool_search.sh\|parse_bitbake_recipes" rules/ | sort`
- Expected: ob_check 全绿;grep 命中四处
- [ ] Step 5: checkpoint status/diff
- Run: `git status --short`
- Expected: rules/ 四处

---

### Task 8: 最终验证

- 目标:全量回归 + porcelain 端到端 + integration 可选。
- Files: 无
- 验证范围:整库绿。
- 接口契约:
  - Consumes: 全部前序任务
  - Produces: 无

- [ ] Step 1: ob_check 全绿
- Run: `tools/ob_check.sh`
- Expected: 全绿(extract_funcs GAPS=0 + machine_state gate + shellcheck baseline 无新告警 + exit_contract devtool_*.sh leaf-pure + run_all 三层 ok)
- [ ] Step 2: 全量回归
- Run: `tests/run_all.sh --full`
- Expected: protocol/unit/orchestration 全 ok;`--full` 包含 .exp(有 expect 跑,无 expect skip 并记录)
- [ ] Step 3: porcelain 端到端(需真实 init 过的 machine;若无跳过记录)
- Run: `./ob dev --machine <m> list 2>/dev/null | python3 -c 'import sys,json;[json.loads(l) for l in sys.stdin if l.strip()]' && echo PORCELAIN_OK`
- Expected: PORCELAIN_OK
- [ ] Step 4: integration(可选,需真实 build env)
- Run: `tests/run_all.sh --integration 2>&1 | tail -20`
- Expected: integration 通过(真实 devtool modify + srctree 一致 + missing 懒生成 + stale 检测 + init 清理);环境不具备记录 deferral 不阻塞
- [ ] Step 5: 改动汇总(不要求 clean)
- Run: `git status --short`
- Expected: 只列本特性相关文件;有 commit 需求提示用户批准后;输出修改摘要

## 执行纪律

- 实现前先批判性复查整份计划 + 对照设计 v4;发现缺项/矛盾/命名不一致/验证命令无效,先修计划。
- 按任务顺序 T1→T8 执行(T1→T2→T3→T4→T5;T6 依赖 T3 可与 T4/T5 并行;T7 依赖 T4/T5;T8 最后)。
- 每任务运行 Step 4 验证;不绿不进下一个。
- 不自动 commit:Step 5 只 `git status --short`;commit 仅用户批准后。
- 遇阻塞(devtool 行为与设计未决 5 不符、build env 进不去、extract_funcs 不认新文件、parse_bitbake_recipes tinfoil/layer 取值问题等),立即停下说明,不猜。
- 若在 main/master 且用户未同意,实现前先确认分支。
- 全部完成后运行 Task 8 + 输出修改摘要。

## 最终验证

- `tools/ob_check.sh` 全绿(含 exit_contract 确认 devtool_search.sh/devtool_modify.sh leaf-pure)。
- `tests/run_all.sh --full` 全 ok(含 ob dev 新测试:usage_dispatch_sync 含 OB_NO_MAIN 真实 dispatch + DEV_ARGS 重置/交接 + porcelain、unit devtool_search(cache_state 三态 + layer schema)/devtool_modify(三段 + 同一 subshell + 输出隔离)、orchestration cmd_dev 含 machine 前置非TTY/无候选 + list missing 懒生成 + modify 缺 recipe exit3 + stderr 由 cmd_dev 输出))。.exp 在 --full 下包含,无 expect skip。
- porcelain 端到端:`./ob dev --machine <m> list` stdout 每行合法 JSON、`./ob dev --machine <m> modify <recipe>` stdout 恰好一行、stderr 含诊断(无 logo)。
- harness 四处落地(workflow_02 + WORKSPACE/SKILLS_INDEX/ob_first,全 --machine 文案)。
- integration(--integration):真实 devtool modify + missing 懒生成 + stale 检测 + init 清理(环境不具备记录 deferral)。
- 工作区:git status --short 只含本特性文件(不要求 clean,不自动 commit)。

## 审阅 Checkpoint

实施计划(v3)已写好并保存到 `docs/plans/2026-07-13-ob-devtool-modify-implementation-plan.md`。请先确认这份计划;如果没问题,下一步可以按计划由普通编码 agent 或人工继续执行(本 skill 不切入编码)。实现前若在 main/master,请先确认分支策略。
