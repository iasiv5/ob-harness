# ob § 编号深度清理 + lib 文件头统一 实施计划

## 目标

- 清除 ob 入口与 lib 文件头里残留的 § 分区编号(单文件时代的注释锚点,拆分 lib 后已退役但未清扫,且 bitbake_env/build_env/machine_state 后加文件未标、已自相矛盾)
- 把 8 个 `lib/*.sh` 文件头统一成同一个 **2 行中文模板**(职责+CONTEXT.md 指针 / Exit 契约),顺带修掉语言(中/英/混)、"被 ob source"表述的不一致
- Exit 字段按 `exit_contract.py` 权威**三态分类**(leaf-pure / direct-exit / exit seam)填写,不再凭注释臆测;util 列全三个例外
- 让 basename 权威清单只有 `exit_contract.py` 一个源:CONTEXT.md 与 WORKSPACE.md 都不维护文字 basename 副本
- 重写 CONTEXT.md `function semantic layer` 词条:区分"函数角色轴(L1/L2/L3)"与"文件级 exit 契约轴"两条正交轴;澄清 `leaf-pure` 只指 no-direct-exit、不指函数纯度;定义三态术语
- 保留"解释为什么不用 §"的决策理由注释与冻结历史

## 架构快照

- **统一模板(2 行,中文)**:
  - 第 1 行 `# lib/<name>.sh — <职责>. 术语见 CONTEXT.md <词条>.`(职责描述按需点明该模块的副作用性质,如 build_env 的"cd+source 副作用留在当前 shell"、bitbake_env 的"子进程隔离不泄漏")
  - 第 2 行 `# Exit: <契约>[; 调用者负责 exit-code/remedy].`
- **Exit 三态分类**(文件级,以 `exit_contract.py` 为权威):
  - `leaf-no-exit（leaf-pure module）`:Y 规则覆盖、函数不直接 exit(util/bitbake_env/build_env/machine_state);util 列例外 fn_quit/resolve_npm_registry/require_path
  - `direct-exit module（非 leaf-pure, 使用 exit-code 契约值 0/1/2/3）`:函数体内直接 exit,受 X/Z 规则约束,但非 L1 收口(repo/qemu/init_pipeline)
  - `exit seam（L1 cmd_* 顶层编排, 使用 exit-code 契约值 0/1/2/3）`:对用户命令收口的顶层编排(commands)
- **砍掉独立"副作用"字段**(v3 核心修正,回应评审 🔴):核实发现调用副作用是多类复杂事实(文件/网络/进程/current-shell),且几乎所有 lib 模块都有某种实质副作用(util 的 DL_DIR 可写性/npm registry 探测、repo 写 manifest、init git clone+网络、qemu/machine_state 写文件、commands rm/kill 进程、build_env 改当前 shell),既不是 build_env vs 其他的干净二分,也不适合作为文件头独立字段——source-time 字段零区分度,调用副作用字段会膨胀成四类标注,且维护"哪个文件有何副作用"的分类清单会像 basename 清单一样漂移出错。副作用信息改为**按需融入职责行**(只对有 shell 语义的 build_env/bitbake_env 点明),Exit 字段已覆盖可机器校验的纯度面(exit 契约);**本计划不维护副作用分类清单**(util 亦有探测副作用,早期"util 无"判断是 head 截断误判,已修正)
- **leaf-pure 术语澄清**(回应评审 🔴):`leaf-pure` 只表示"Y 规则覆盖的 no-direct-exit module",**不指函数纯度**——leaf-pure module 的函数仍可有文件/进程/网络副作用(如 build_env 的 cd+source、machine_state 写 snapshot)。这消除 build_env "leaf-pure + 有副作用"的表面冲突
- **两条正交轴**:函数角色轴(L1 cmd_* / L2 前置检查 / L3 底层工具) ≠ 文件级 exit 契约轴。一个文件可含多种角色函数;exit 契约按整文件归类
- 砍掉"被 ob source"全称命题(8 文件都成立),改由 ob 入口 source 区一行注释统一声明
- § 编号作为模板统一的副产品被消除;CONTEXT.md 保留 1 处"曾用 § 锚点"历史括注

## 输入工件

- 原始设计来自 2026-07-03 `/grill-with-docs` 五轮定稿(基于当时对副作用事实的错误假设——以为"build_env 有副作用、其他无"是干净二分)
- **v2 修订**:据评审第一轮修 exit 字段(exit_contract 权威二分)、WORKSPACE.md basename 单一源、"顶层副作用"改名"调用副作用"
- **v3 修订(本版)**:据评审第二轮——🔴 砍掉"调用副作用"独立字段(grep 证实 repo.sh:82/99/110 write_source_manifest+mkdir+mv、init_pipeline.sh:28/69/73 curl+git clone+write_manifest、qemu.sh:30/58 write_qemu_*_manifest、machine_state.sh:62/141 write_snapshot+写 marker,均非"纯函数";v2 标"无(纯函数)"是错误事实),副作用信息融入职责行;澄清 leaf-pure 不指函数纯度。🟡 第三态改名 `direct-exit module`。🟢 最终验证 `grep -rc` 改 `! grep -R` 修退出码
- **v3.1 修订**:据评审第三轮——🟡 修正"util 无副作用"误判(util.sh:218-339 有 mkdir/touch/rm/curl/mktemp 做 DL_DIR 可写性与 npm registry 探测);副作用不维护分类清单。🟡 util Exit 行措辞修正(仅 require_path 代 caller,fn_quit 自 exit 0、resolve_npm_registry 自 exit 1)
- 教训记录:v1(exit)、v2(副作用)、v3(util 无副作用)的错误同源——grilling/核实阶段未全量 grep 函数体,凭文件名/旧注释/head 截断臆测。本版 exit 判定与关键副作用反例(各 lib 均非纯函数)经 grep -c 全量坐实;副作用不作分类清单维护

## 文件结构与职责

- Modify: `ob`(入口 3 处注释:去 §1/§7 编号 + source 区改权威声明)
- Modify: `lib/util.sh` `lib/repo.sh` `lib/qemu.sh` `lib/init_pipeline.sh` `lib/commands.sh` `lib/machine_state.sh` `lib/bitbake_env.sh` `lib/build_env.sh`(文件头套统一 2 行模板,Exit 三态)
- Modify: `lib/util.sh` `detect_harness_root()` 定义处(下沉 OB_ENTRY_DIR 耦合注释)
- Modify: `CONTEXT.md`(`function semantic layer` 词条重写:双轴正交 + 三态术语 + leaf-pure 澄清 + 指向 exit_contract.py)
- Modify: `rules/03_WORKSPACE.md:8`(leaf-pure basename 文字罗列改为指向 exit_contract.py 配置)
- Modify: `tests/unit/exit_contract.sh`(注释 §2 → util.sh)
- 不动(显式保留): `tools/exit_contract.py:156` / `tools/extract_funcs.py:43`(决策理由) / `tools/archive/reorder.py`(冻结历史)
- 无 Create,无新 Test

## 任务清单

### Task 1: 更新 ob 入口注释

- 目标:去掉 ob:6/74 的 §1/§7 编号,把 ob:68 source 区注释改写为"所有 lib/*.sh 被 ob source"的权威声明
- Files: `ob`(行 6 / 68 / 74)
- 验证范围: `grep § ob` 无输出;ob:68 含"均被 ob source"

- [ ] Step 1: 改动前检查
- Run: `grep -n '§' ob`
- Expected: 命中两行——`:6:# === §1 全局变量 (Global Variables) ===` 与 `:74:# === §7 入口 (parse_args / usage / main) ===`(§ 仍在,目标未达)

- [ ] Step 2: 写最小实现
- Change: 三处替换
  - ob:6 `# === §1 全局变量 (Global Variables) ===` → `# === 全局变量 (Global Variables) ===`
  - ob:68 `# === ob 入口: sourced lib 分区(OB_ENTRY_DIR 须在 source lib 前算好) ===` → `# === sourced lib 分区(以下 lib/*.sh 均被 ob source; OB_ENTRY_DIR 须在 source 前算好) ===`
  - ob:74 `# === §7 入口 (parse_args / usage / main) ===` → `# === 入口 (parse_args / usage / main) ===`

- [ ] Step 3: 改动后验证
- Run: `grep -n '§' ob`
- Expected: 无输出
- Run: `sed -n '6p;68p;74p' ob`
- Expected: 三行依次为 `# === 全局变量 (Global Variables) ===` / `# === sourced lib 分区(以下 lib/*.sh 均被 ob source; OB_ENTRY_DIR 须在 source 前算好) ===` / `# === 入口 (parse_args / usage / main) ===`

- [ ] Step 4: 可选 checkpoint commit
- Run: `git add ob && git commit -m "refactor(ob): 去掉 §1/§7 编号, source 区注释改为 lib source 权威声明"`

### Task 2: 更新 lib 文件头第一批(util/repo/qemu/init_pipeline/commands)

- 目标:5 个文件头替换为统一 2 行模板。Exit 按 exit_contract.py 三态:util=leaf-pure(列全 3 例外);repo/qemu/init_pipeline=`direct-exit module`(函数体直接 exit,核实 repo 13 处/init 8 处/qemu ~20 处);commands=`exit seam`(L1 cmd_*)。util 的 OB_ENTRY_DIR 耦合提示下沉
- Files: `lib/util.sh` `lib/repo.sh` `lib/qemu.sh` `lib/init_pipeline.sh` `lib/commands.sh`
- 验证范围: `grep §` 这 5 文件无输出;各 `head -3` 符合 2 行模板;util 例外三函数齐全;repo/qemu/init 非纯函数(有副作用函数)

- [ ] Step 1: 改动前检查
- Run: `grep -n '§' lib/util.sh lib/repo.sh lib/qemu.sh lib/init_pipeline.sh lib/commands.sh`
- Expected: 5 文件各命中 1 行(§2/§3/§4/§5/§6 仍在)
- Run: `grep -cE '^\s*exit\b' lib/repo.sh lib/qemu.sh lib/init_pipeline.sh lib/commands.sh`
- Expected: 4 文件均 >0(核实 direct-exit/exit seam 判定有据)
- Run: `grep -cE '\b(mkdir|mv|rm|cp)\b|git clone|curl|write_' lib/repo.sh lib/init_pipeline.sh lib/qemu.sh lib/commands.sh`
- Expected: 4 文件均 >0(核实它们确有文件/网络副作用,印证 v2"无(纯函数)"是错的——副作用信息不进文件头字段、不标"纯函数")

- [ ] Step 2: 写最小实现
- Change: 5 个文件头替换为 2 行(精确 old→new)

  `lib/util.sh` 行 2-3 替换为:
  ```
  # lib/util.sh — 底层通用工具(log/select_from_list/read_kv_field/require_path). 术语见 CONTEXT.md function semantic layer.
  # Exit: leaf-no-exit（leaf-pure module; 例外 fn_quit/resolve_npm_registry/require_path 可 direct exit, require_path 使用 caller code）; 调用者负责 exit-code/remedy.
  ```
  并在 `detect_harness_root()` 定义行(约 277,先 `grep -n 'detect_harness_root()' lib/util.sh` 定位)上方加:
  ```
  # 用 OB_ENTRY_DIR(由 ob 入口在 source lib 前算好)定位 HARNESS_ROOT。
  ```

  `lib/repo.sh` 行 2 替换为:
  ```
  # lib/repo.sh — 仓库与 machine 解析(require_openbmc_repo/write_source_manifest). 术语见 CONTEXT.md source manifest.
  # Exit: direct-exit module（非 leaf-pure, 使用 exit-code 契约值 0/1/2/3）.
  ```

  `lib/qemu.sh` 行 2 替换为:
  ```
  # lib/qemu.sh — QEMU runtime(binary/firmware/ports/SoC/pid/hostkey). 术语见 CONTEXT.md QEMU launch profile / QEMU manifest.
  # Exit: direct-exit module（非 leaf-pure, 使用 exit-code 契约值 0/1/2/3）.
  ```

  `lib/init_pipeline.sh` 行 2 替换为:
  ```
  # lib/init_pipeline.sh — init 流水线(clone/snapshot/config). 术语见 CONTEXT.md.
  # Exit: direct-exit module（非 leaf-pure, 使用 exit-code 契约值 0/1/2/3）.
  ```

  `lib/commands.sh` 行 2 替换为:
  ```
  # lib/commands.sh — cmd_* 命令编排(status/init/build/start-qemu/stop-qemu/menu). 术语见 CONTEXT.md function semantic layer / exit-code 契约.
  # Exit: exit seam（L1 cmd_* 顶层编排, 使用 exit-code 契约值 0/1/2/3）.
  ```

- [ ] Step 3: 改动后验证
- Run: `grep -n '§' lib/util.sh lib/repo.sh lib/qemu.sh lib/init_pipeline.sh lib/commands.sh`
- Expected: 无输出
- Run: `for f in util repo qemu init_pipeline commands; do echo "--- lib/$f.sh ---"; head -3 "lib/$f.sh"; done`
- Expected: 5 文件第 2-3 行符合 2 行模板;util 第 2 行例外含三函数;repo/qemu/init_pipeline 第 3 行为 `direct-exit module（...）`,commands 第 3 行为 `exit seam（...）`;无任何文件标"纯函数"
- Run: `grep -n 'OB_ENTRY_DIR' lib/util.sh`
- Expected: detect_harness_root 定义处上方新增注释命中

- [ ] Step 4: 可选 checkpoint commit
- Run: `git add lib/util.sh lib/repo.sh lib/qemu.sh lib/init_pipeline.sh lib/commands.sh && git commit -m "refactor(lib): util/repo/qemu/init_pipeline/commands 文件头统一 2 行模板; Exit 三态(direct-exit/exit seam/leaf-no-exit)"`

### Task 3: 更新 lib 文件头第二批(machine_state/bitbake_env/build_env)

- 目标:3 个 leaf-pure 文件头归一为 2 行模板。三者 Exit 均 `leaf-no-exit（leaf-pure module）`(在 Y 覆盖集内);副作用信息融入职责行——bitbake_env 点明"子进程隔离不泄漏",build_env 点明"cd+source 副作用留在当前 shell",与 bitbake_env 对偶;machine_state 点明"读写"
- Files: `lib/machine_state.sh` `lib/bitbake_env.sh` `lib/build_env.sh`
- 验证范围: `grep §` 无输出;各 `head -3` 符合 2 行模板;build_env 副作用/对偶信息零损失(在职责行)

- [ ] Step 1: 改动前检查
- Run: `for f in machine_state bitbake_env build_env; do echo "--- lib/$f.sh ---"; head -5 "lib/$f.sh"; done`
- Expected: 三文件头格式各异——machine_state 中文 2 行、bitbake_env 英文 2 行、build_env 中英混 4 行(目标"统一 2 行模板"未达)
- Run: `sed -n '53,58p' tools/exit_contract.py`
- Expected: `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 含 `bitbake_env.sh`/`build_env.sh`/`machine_state.sh`/`util.sh` 四 key(核实这 3 文件在 leaf-pure 覆盖集)
- Run: `grep -cE '\b(mkdir|mv|rm)\b|write_' lib/machine_state.sh`
- Expected: >0(核实 machine_state 有文件副作用——故其副作用信息只入职责行"读写",不标"纯函数",也不单列副作用字段)

- [ ] Step 2: 写最小实现
- Change: 3 个文件头替换为 2 行(精确 old→new)

  `lib/machine_state.sh` 行 2-3 替换为:
  ```
  # lib/machine_state.sh — machine lifecycle state(snapshot/init marker/build artifact 读写). 术语见 CONTEXT.md machine lifecycle state.
  # Exit: leaf-no-exit（leaf-pure module）; 调用者负责 exit-code/remedy.
  ```

  `lib/bitbake_env.sh` 行 2-3 替换为:
  ```
  # lib/bitbake_env.sh — BitBake environment one-shot 查询(子进程隔离, 副作用不泄漏到当前 shell). 术语见 CONTEXT.md BitBake environment support module.
  # Exit: leaf-no-exit（leaf-pure module）; 调用者负责 exit-code/remedy/诊断.
  ```

  `lib/build_env.sh` 行 2-5 替换为:
  ```
  # lib/build_env.sh — current-shell build environment 进入原语(cd+source setup, 副作用刻意留在当前 shell, 与 bitbake_env 子进程隔离对偶). 术语见 CONTEXT.md current-shell build environment.
  # Exit: leaf-no-exit（leaf-pure module）; 调用者负责 exit-code/remedy/诊断.
  ```

- [ ] Step 3: 改动后验证
- Run: `grep -n '§' lib/machine_state.sh lib/bitbake_env.sh lib/build_env.sh`
- Expected: 无输出
- Run: `for f in machine_state bitbake_env build_env; do echo "--- lib/$f.sh ---"; head -3 "lib/$f.sh"; done`
- Expected: 3 文件第 2-3 行符合 2 行模板,第 3 行均为 `leaf-no-exit（leaf-pure module）`;build_env 职责行含"cd+source 副作用刻意留在当前 shell"与"与 bitbake_env 子进程隔离对偶",信息零损失;bitbake_env 职责行含"子进程隔离, 副作用不泄漏"

- [ ] Step 4: 可选 checkpoint commit
- Run: `git add lib/machine_state.sh lib/bitbake_env.sh lib/build_env.sh && git commit -m "refactor(lib): machine_state/bitbake_env/build_env 文件头归一 2 行模板; 副作用信息融入职责行"`

### Task 4: 重写 CONTEXT.md function semantic layer 词条

- 目标:双轴正交(函数角色 vs 文件级 exit 契约);定义三态术语(leaf-pure / direct-exit module / exit seam);澄清 leaf-pure 只指 no-direct-exit、不指函数纯度(消除 build_env "leaf-pure+有副作用"冲突);basename 指向 exit_contract.py 不罗列;压 § 历史
- Files: `CONTEXT.md`(`function semantic layer` 词条,约 75-77 行)
- 验证范围: 新词条含"函数角色轴"+"文件级 exit 契约轴"+三态术语+leaf-pure 不指纯度的澄清;不含文件枚举/basename 罗列;保留"曾用 §"括注;其他词条未动

- [ ] Step 1: 改动前检查
- Run: `grep -n 'function semantic layer' CONTEXT.md`
- Expected: 命中词条起始行(约 75)
- Run: `grep -c 'bitbake_env.sh / util.sh / machine_state.sh' CONTEXT.md`
- Expected: 1(过时 basename 罗列仍在)

- [ ] Step 2: 写最小实现
- Change: `function semantic layer` 词条整段替换为:

  ```
  **function semantic layer**:
  `ob` 内部对函数角色的调用层级词汇：L1（`cmd_*` 命令编排，exit seam）、L2（前置检查点，如 `require_path`）、L3（底层通用工具，如 `log`/`select_from_list`/`read_kv_field`）。L1/L2/L3 是**函数角色**轴，与**文件级 exit 契约**轴正交。文件级 exit 契约由 `exit_contract` 的 Y 规则按 basename 划分三态：`leaf-pure module`（Y 规则覆盖；除配置例外外函数不直接 exit；"pure" 仅指 no-direct-exit，**不指函数纯度**——其函数仍可有文件/进程/网络副作用）、`direct-exit module`（函数体内直接 exit，受 `exit-code 契约` 约束，非 L1 收口）、`exit seam`（L1 `cmd_*` 顶层编排，对用户命令收口）。leaf-pure basename 归属与各 module 的 exit 例外集以 `exit_contract` 配置（`LEAF_EXIT_EXCEPTIONS_BY_BASENAME`）为唯一权威——不在此罗列，避免文字副本漂移。结构边界由 `lib/*.sh` 文件名承载——曾用 § 注释分区锚点，因会漂移已退役。
  _Avoid_: 调用层级, 函数分级；勿与 test layer（protocol/unit/orchestration/integration，曾用 L0–L3）混用
  ```

- [ ] Step 3: 改动后验证
- Run: `sed -n '75,77p' CONTEXT.md`
- Expected: 新词条含"函数角色轴,与文件级 exit 契约轴正交"、"三态"、"leaf-pure...不指函数纯度"、"direct-exit module"、"exit seam"、"曾用 § 注释分区锚点,因会漂移已退役"
- Run: `grep -c 'bitbake_env.sh / util.sh / machine_state.sh' CONTEXT.md`
- Expected: 0
- Run: `grep -c 'lib/{util,repo,bitbake_env' CONTEXT.md`
- Expected: 0
- Run: `git diff --stat CONTEXT.md`
- Expected: 仅 function semantic layer 词条区域变动

- [ ] Step 4: 可选 checkpoint commit
- Run: `git add CONTEXT.md && git commit -m "docs(context): function semantic layer 词条重写—双轴正交+三态(leaf-pure/direct-exit/exit seam)+leaf-pure 不指纯度澄清"`

### Task 5: WORKSPACE.md leaf-pure basename 罗列改指向

- 目标:WORKSPACE.md:8 当前写了"当前 bitbake_env.sh/util.sh/machine_state.sh"(漏 build_env.sh),改为指向 exit_contract.py 配置,使 basename 清单只有 exit_contract.py 一个权威源
- Files: `rules/03_WORKSPACE.md`(行 8)
- 验证范围: WORKSPACE.md 不再含 basename 文字罗列;保留 reorder.py"文件边界接管 § 分区"决策句

- [ ] Step 1: 改动前检查
- Run: `grep -n 'bitbake_env.sh/util.sh/machine_state.sh' rules/03_WORKSPACE.md`
- Expected: 命中行 8

- [ ] Step 2: 写最小实现
- Change: 行 8 子串替换
  - old: `Y leaf-pure module 叶子纯度（按 basename 配置，当前 bitbake_env.sh/util.sh/machine_state.sh）`
  - new: `Y leaf-pure module 叶子纯度（按 basename 配置，权威清单见 exit_contract.py LEAF_EXIT_EXCEPTIONS_BY_BASENAME）`

- [ ] Step 3: 改动后验证
- Run: `grep -n 'bitbake_env.sh/util.sh/machine_state.sh' rules/03_WORKSPACE.md`
- Expected: 无输出
- Run: `grep -n 'LEAF_EXIT_EXCEPTIONS_BY_BASENAME' rules/03_WORKSPACE.md`
- Expected: 命中行 8
- Run: `grep -c '文件边界接管 § 分区' rules/03_WORKSPACE.md`
- Expected: 1(reorder.py 归档决策句保留)

- [ ] Step 4: 可选 checkpoint commit
- Run: `git add rules/03_WORKSPACE.md && git commit -m "docs(workspace): leaf-pure basename 文字罗列改为指向 exit_contract.py 单一权威"`

### Task 6: 更新 tests/unit/exit_contract.sh 注释

- 目标:测试注释里的 §2 散文指代改成 util.sh,与文件头去 § 对齐
- Files: `tests/unit/exit_contract.sh`(行 4)
- 验证范围: `grep §2` 无输出;测试逻辑未动

- [ ] Step 1: 改动前检查
- Run: `grep -n '§2' tests/unit/exit_contract.sh`
- Expected: 命中行 4

- [ ] Step 2: 写最小实现
- Change: 行 4 子串 `exit 4/§2 误 exit/` → `exit 4/util.sh 误 exit/`

- [ ] Step 3: 改动后验证
- Run: `grep -n '§2' tests/unit/exit_contract.sh`
- Expected: 无输出
- Run: `git diff tests/unit/exit_contract.sh`
- Expected: 仅注释行 4 一处改动

- [ ] Step 4: 可选 checkpoint commit
- Run: `git add tests/unit/exit_contract.sh && git commit -m "test(exit-contract): 注释 §2 指代改为 util.sh"`

## 执行纪律

- 开始实现前先批判性复查整份计划;发现缺项、矛盾、命名不一致或验证命令无效,先修计划
- 按任务顺序执行,不无声跳步、合并步或改变任务目标
- 每完成一个任务,运行该任务的改动后验证(Step 3)
- 文件头替换用精确 old→new 整块匹配,避免误伤函数体;改完任一 lib 后若 extract_funcs 报 lib 三段违规,立即停下说明
- Exit 字段填写以 `tools/exit_contract.py` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 为唯一事实源;不在文件头标"纯函数"——副作用是四类复杂事实,只按需在职责行点明 shell 语义
- 遇到阻塞、重复失败或计划与仓库现实不符,立即停下说明,不要猜
- 若当前在 main/master 且用户未明确同意,开始实现前先确认分支策略
- 全部任务完成后,运行最终验证并输出修改摘要

## 最终验证

所有任务完成后,在仓库根依次运行:

- Run: `tools/ob_check.sh`
- Expected: 全部子检查 ✓,`FAIL=0`。注释改动不影响 shellcheck baseline 与 exit 纪律;若 baseline 出现差异,停下人工确认

- Run: `! grep -rn '§' ob lib/*.sh`
- Expected: 命令退出码 0(活代码 ob + lib 已无 §)。硬门禁:有 § 残留则退出码非零

- Run: `grep -rn '§' tools/exit_contract.py rules/03_WORKSPACE.md tools/extract_funcs.py`
- Expected: exit_contract.py:156 与 extract_funcs.py:43 保留命中;WORKSPACE.md 的 § 命中仅剩 reorder.py 归档句"文件边界接管 § 分区"。确认决策理由未被误删

- Run: `! grep -R 'bitbake_env.sh/util.sh/machine_state.sh' CONTEXT.md rules/03_WORKSPACE.md`
- Expected: 命令退出码 0(两文件 basename 文字罗列已清除,权威指向 exit_contract.py)。用 `! grep -R` 而非 `grep -rc`:两文件都 0 命中时 grep 退出码非零,`!` 反转为 0 作通过信号(回应评审 🟢)

- Run: `git diff --stat`
- Expected: 改动文件限于 `ob` / `lib/*.sh`(8 个) / `CONTEXT.md` / `rules/03_WORKSPACE.md` / `tests/unit/exit_contract.sh`,无意外文件
