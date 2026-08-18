# ob test-qemu baseline 验证 实施计划

## 目标

实现 `ob test-qemu <machine>`:在**已在跑**的 QEMU-backed BMC 实例上,逐条跑该 machine 的 `baseline`(开发基线/功能基线)里 QEMU 可仿真子集的 AR(需求条目,如 `BMC-3-1-2`),产出 `pass / fail / skip / xfail / xpass` 逐条判定(`xfail` 预期失败、`xpass` 意外通过),exit 0/1/2/3 收口。本计划交付一个可跑通五态的 **spike**(单社区机 romulus × 5 条 AR × redfish probe),验证整条链路(probe 引擎 → AR 数据 → runner → porcelain → exit 契约)成立,再以此为模板扩展。

## 架构快照(自包含,无外部设计文档依赖)

本方案经 `/grill-with-docs`(grilling + domain-modeling)五轮盘问共识定型,核心决策:

- **范式**:`runtime 确定性`(probe 脚本 + assert 原语判定),LLM **不参与判定**。LLM 的角色限定在两处(均**超出本次 spike**,作后续独立计划):① 离线 authoring(读 Excel baseline → 翻译成 AR 数据);② 失败解说员(fail 时生成自然语言解释,不改判定结果)。**否决** "每条基线一个 goal-driven 提示词循环" 方案(颗粒度错配:秒级幂等探测套重型 master/subagent 自愈循环)。
- **per-machine 全栈独立**(ADR-0025):每个 machine 的 baseline 目录**自包含** AR 数据 + probe 引擎 + 本地 applicability,**不共享** AR 定义、**不共享** probe 引擎。决策动因是组织约束(权限隔离、按项目解耦、自包含分发),技术 DRY 让位于组织边界。**test-qemu 不复用 `ob smoke` 的 probe 原语**(`_smoke_probe_*`),probe 引擎是各 baseline 目录里独立的实现。
- **落点二分**:社区机 `tests/baseline/<machine>/`(随 ob-harness 上游);custom 机 `contexts/baseline/<machine>/`(不随上游,接 ADR-0017 的 `contexts/` 边界)。`cmd_test_qemu` porcelain 定位时 **custom 目录优先**(`contexts/` 命中先于 `tests/`),允许 custom 机覆盖/扩展社区基线。
- **命令**:`ob test-qemu <machine>`(probe-only,不 boot 不 teardown,无实例 exit 3 + remedy 指向 `ob start-qemu`)。与 `ob smoke`(浅冒烟 5 条哨兵、零 per-machine、守 per-push 绿灯)**正交姊妹**;test-qemu 是逐条深测、nightly/PR-to-main 频率。
- **术语**:`baseline`(开发基线/功能基线,固件领域 ubiquitous language)已立进 CONTEXT.md;`conformance` 弃用。

## 全局约束

- **exit 契约**(逐字沿用 `ob` 全局 0/1/2/3 + smoke 的 α 措辞):`0`=全部 applicable AR pass(skip/xfail/xpass 不影响);`1`=至少一条 applicable AR fail —— 这是"BMC 不满足 baseline 的真实一致性缺陷",不是 test-qemu broken(沿用 smoke exit 1 的 α 纪律);`2`=用户取消;`3`=前置缺失(无在跑实例 / machine 未 init / baseline 目录缺失)+ 恰好一行 remedy。
- **核心纪律**:skip / xfail / xpass 不使 exit 变 1,只有 applicable 且实测不符的 fail 才 exit 1。
- **probe-only**:`cmd_test_qemu` 不拥有 QEMU bring-up/teardown;从 `QEMU PID file` 读真实转发端口(对齐 smoke);死/stale 实例(存活状态非 `running`)→ `qemu_instance_clean_stale` + exit 3。
- **命名**:目录/数据名用 `baseline`(不用 `conformance`);命令名 `ob test-qemu`(动作 test + 底座 qemu,被测对象 baseline 隐含)。
- **改 `ob` / `lib/*.sh` 后必须跑 `bash tools/ob_check.sh`**(结构 / 函数登记 / shellcheck baseline / exit-contract / run_all)。
- **assert 原语用状态断言非计时断言**(零 flake):凡涉及绝对耗时(SEL dump、升级)一律不进 spike。
- **Python 依赖**:本仓 bash + python3。`probe_redfish.py` 用标准库 urllib/json(零外部依赖);`run.sh`/`report.py` 解析 AR 数据用 **PyYAML**(`import yaml`,环境已装 6.0,**非标准库**)。Task 2/3 前置必须加 `python3 -c "import yaml"` 检查,缺失则报 remedy 提示安装。不引入 requests。
- **Redfish 路径遵循 DMTF 标准**:Accounts 集合是 `/redfish/v1/AccountService/Accounts`(非 `/redfish/v1/Accounts`,后者 404);凡 AR 涉及 AccountService 子资源用 DMTF 标准路径。
- 无版本/平台额外约束。

## 输入工件

- [ADR-0025](../adr/0025-test-qemu-baseline-fullstack-per-machine.md):per-machine 全栈独立决策(权限隔离优先于 DRY)。
- [CONTEXT.md](../../CONTEXT.md) `baseline` 术语条目 + `ob smoke` / `test layer` / `QEMU PID file` / `exit-code 契约`。
- `/grill-with-docs` 共识(本计划架构快照即其固化)。
- 参照实现:`ob smoke`(dispatch 注册 / cmd_smoke probe-only 形态)、`lib/qemu_commands.sh:529` `cmd_smoke`、`lib/smoke_assertions.sh` judge 形态。
- 设计来源:本计划「架构快照」+ [ADR-0025](../adr/0025-test-qemu-baseline-fullstack-per-machine.md) + [CONTEXT.md](../../CONTEXT.md) `baseline` 词条(三者自包含,无外部设计文档依赖;早前的设计草案已删除,设计角色由这三者接管)。

## 文件结构与职责

Create(社区机 romulus spike,随上游):
- `tests/baseline/.gitkeep` — 社区机 baseline 根骨架。
- `tests/baseline/romulus/ar_probes.yaml` — romulus 的 AR 定义(ar + name + probe + suite + request + assert + depends_on + rationale)。
- `tests/baseline/romulus/applicability.yaml` — romulus 本地适用性(标 skip/xfail 的 AR + reason + source)。
- `tests/baseline/romulus/runner/probe_redfish.py` — romulus 的 Redfish probe 引擎 + assert 原语(per-machine,ADR-0025;host/port/auth 参数化;urllib 标准库)。
- `tests/baseline/romulus/runner/run.sh` — romulus runner:遍历 ar_probes.yaml × applicability 过滤 → 逐条调 probe_redfish.py(rc 捕获,不裸调)→ 收 pass/fail/skip/xfail/xpass → 调 report.py → exit 0/1。
- `tests/baseline/romulus/runner/report.py` — VERDICT 行 + skip/xfail/xpass 附录表(JSON + 人读摘要)。

Create(custom 机骨架,不随上游):
- `contexts/baseline/.gitkeep` — custom 机 baseline 根骨架(`.gitignore` 排除内容、保留骨架,对齐 `contexts/knowhow/`)。

Modify:
- `lib/qemu_commands.sh`(新增 `cmd_test_qemu`,文件头注释命令簇清单同步)。
- `ob`(dispatch case `test-qemu)` + `--help` test-qemu 段 + `COMMAND == test-qemu` guard,形态对照 smoke 注册)。

Test:
- `tests/protocol/test_qemu_surface.sh` — protocol 层:命令注册 / exit 契约 / baseline 目录定位优先级(custom > community > 缺失 exit 3)。
- `tests/integration/test_qemu_baseline_e2e.sh` — integration 层:真实 romulus QEMU 实例跑 5 条 AR 五态(无 image 则 exit 77 SKIP)。

接口依赖:`cmd_test_qemu`(porcelain)→ 定位 baseline 目录 → 调 `runner/run.sh`(per-machine)→ run.sh 读 `ar_probes.yaml` + `applicability.yaml` → 调 `probe_redfish.py` → `report.py` 汇总。

## 任务清单

### Task 1: 建 baseline 双目录骨架

- 目标:建立社区机 `tests/baseline/` 与 custom 机 `contexts/baseline/` 的根骨架,落实 ADR-0025 的分发边界二分。
- Files
  - Create: `tests/baseline/.gitkeep`
  - Create: `contexts/baseline/.gitkeep`
  - Modify: `.gitignore`(加 `contexts/baseline/*` + `!contexts/baseline/.gitkeep`,紧邻既有 `contexts/knowhow/*` 行 ~16-17;当前 .gitignore 只覆盖 knowhow,baseline 必须显式补)
- 接口契约
  - Consumes: ADR-0025(落点二分)、CONTEXT.md `baseline`。
  - Produces: `tests/baseline/<machine>/` 与 `contexts/baseline/<machine>/` 两条目录约定(后续 Task 2-4 落 `tests/baseline/romulus/`)。
- 验证范围:两根目录存在且 `.gitkeep` 入库;`contexts/baseline/` 内容被 `.gitignore` 排除但 `.gitkeep` 不被排除。

- [ ] Step 1: 写当前状态检查
- Run: `test -d tests/baseline && test -d contexts/baseline && echo "exists" || echo "missing"`
- Expected: `missing`(尚未建立)。
- [ ] Step 2: 运行并确认缺失
- Run: `test -d tests/baseline || echo MISSING`
- Expected: `MISSING`。
- [ ] Step 3: 建目录与骨架
- Change: 创建 `tests/baseline/.gitkeep`(内容一行注释 `# community-machine baseline data; ships with ob-harness. See ADR-0025 / CONTEXT.md "baseline".`);创建 `contexts/baseline/.gitkeep`(内容 `# custom-machine baseline data; NOT shipped upstream (gitignored content). See ADR-0025 / CONTEXT.md "baseline".`);确认 `.gitignore` 规则覆盖 `contexts/baseline/*` 但放行 `.gitkeep`(对齐 `contexts/knowhow/` 既有规则;若缺则补一条 `contexts/baseline/*` + `!contexts/baseline/.gitkeep`)。
- [ ] Step 4: 运行并确认通过
- Run: `touch contexts/baseline/fake.tmp; git check-ignore -q contexts/baseline/.gitkeep; s1=$?; git check-ignore -q contexts/baseline/fake.tmp; s2=$?; rm -f contexts/baseline/fake.tmp; test "$s1" = "1" && test "$s2" = "0" && echo OK || echo FAIL`
- Expected: `OK`(`.gitkeep` 未被忽略=check-ignore exit 1→`$s1=1`;`fake.tmp` 被忽略=check-ignore exit 0→`$s2=0`;两者同时成立才 OK)。fake.tmp 测后清理。

### Task 2: romulus Redfish probe 引擎 + assert 原语

- 目标:实现 romulus 的 per-machine Redfish probe 引擎(`probe_redfish.py`),含 spike 三种 assert 原语(`status_in` / `json_path_exists` / `json_path_match`)。host/port/auth 参数化,urllib 标准库。
- Files
  - Create: `tests/baseline/romulus/runner/probe_redfish.py`
- 接口契约
  - Consumes: AR schema 的 `request` 段(method/path/body)与 `assert` 段(type/value)。
  - Produces: `probe_redfish.py` —— CLI 签名 `probe_redfish.py --host H --port P --user U --password W --method M --path PATH [--body JSON] --asserts 'JSON'`,stdout 打印一行 JSON `{"pass": bool, "code": int|null, "body": str, "actual": ..., "reason": str}`,exit 0=pass / 1=fail。三个 assert 原语函数 `status_in(code, value_list)` / `json_path_exists(body, jp)` / `json_path_match(body, jp, expected)`(jp 用点路径如 `FirmwareVersion` 或 `Managers.0.FirmwareVersion`,按 `.split('.')` 逐层取;**不支持带点 key 如 `@odata.count`**——会被拆成 `@odata`→`count`,spike AR 避开带点字段,未来扩 AR 涉及 @odata.* 时升级 resolver 为 literal-first)。**mutating cleanup fail-safe**(见评审六轮 🟡2):POST 类 probe 意外 2xx(201/200,即 BMC 违反 baseline 接受了本该拒绝的请求)时,从响应 `Location` header 或 body `@odata.id` 抽取资源 URI,best-effort DELETE 清理(防污染复用实例的后续重跑:残留账号→后续 409/权限漂移);cleanup 失败也写入 `reason`/raw,不阻断 fail 判定。
- 验证范围:`probe_redfish.py` 对合成输入(不起 QEMU)正确判定三原语 pass/fail。

- [ ] Step 1: 写失败检查(unit 断言三原语)
- Run: `python3 tests/baseline/romulus/runner/probe_redfish.py --selftest`
- Expected: 失败(`--selftest` 子命令尚未实现,exit 非 0 或 AttributeError)。
- [ ] Step 2: 运行并确认失败
- Run: `python3 tests/baseline/romulus/runner/probe_redfish.py --selftest; echo "rc=$?"`
- Expected: `rc!=0`(未实现)。
- [ ] Step 3: 写最小实现
- Change: 实现 `probe_redfish.py`:① `--selftest` 直接断言三原语(`status_in(200,[200,401])`→True、`status_in(200,[400])`→False、`json_path_exists('{"FirmwareVersion":"x"}','FirmwareVersion')`→True、`json_path_match(...)` 等),全过 exit 0;② 正常 probe 路径:urllib.request 发 Redfish 请求(Basic Auth header,`Content-Type: application/json`,body POST),捕 HTTPError(取其 code 作为响应)/ URLError(判 fail + reason);③ 读 `--asserts` JSON 数组,逐条调对应原语,全过 pass;④ stdout 一行 JSON `{"pass","code","body","actual","reason"}`。无网络依赖时 `--selftest` 仍可跑(纯函数判定)。
- [ ] Step 4: 运行并确认通过
- Run: `python3 tests/baseline/romulus/runner/probe_redfish.py --selftest; echo "rc=$?"`
- Expected: `rc=0`(三原语自检全过)。
- [ ] Step 5: 可选 checkpoint commit(执行前确认当前分支与用户授权;agent 环境未获明确授权不自动 commit,以 diff + 验证通过收口)
- Run: `git add tests/baseline/romulus/runner/probe_redfish.py && git commit -m "feat(test-qemu): romulus redfish probe engine + assert primitives (spike)"`(仅经用户确认后)

### Task 3: romulus AR 数据 + 本地 applicability

- 目标:填 romulus 的 5 条 spike AR(全 redfish probe,覆盖正向 GET / 字段存在 / 负向 POST 拒绝 / skip / xfail 五态)+ 本地 applicability。
- Files
  - Create: `tests/baseline/romulus/ar_probes.yaml`
  - Create: `tests/baseline/romulus/applicability.yaml`
- 接口契约
  - Consumes: `probe_redfish.py` 的 request/assert schema(Task 2)。
  - Produces: `ar_probes.yaml`(5 条 AR:① `BMC-2-2-1` Redfish 可达 GET `/redfish/v1` assert `status_in [200]`;② `BMC-3-15-1` 版本查询 GET `/redfish/v1/Managers/bmc` assert `json_path_exists FirmwareVersion`;③ `BMC-3-1-2` 用户名规则 POST `/redfish/v1/AccountService/Accounts`(DMTF 标准 AccountService 集合路径)body `{UserName:"9bad",Password:"Abcd1234!",RoleId:"ReadOnly"}` assert `status_in [400,403]`;**mutating negative**(BMC 违反 baseline 返回 2xx 会创建 9bad 账号,probe 引擎 cleanup fail-safe 从 Location/@odata.id 抽 URI best-effort DELETE,见 Task 2 + 评审六轮 🟡2);④ `BMC-7-7-1` Web banner(标 skip);⑤ `BMC-XF-1`(xfail 演示,预期 fail:GET `/redfish/v1/AccountService/Accounts` assert `json_path_exists Description`——romulus 集合顶层预期不填 `Description`→执行 probe 预期 fail→记 xfail,意外填→xpass;**避开 `@odata.count` 等带点字段**:Task 2 resolver 是 split('.'),带点 key 会被拆错,见评审二轮 🟡3)。顶层 `auth: {user: root, password: "0penBmc"}`);`applicability.yaml`(`BMC-7-7-1: {status: skip, reason: "romulus 未启用 banner 定制", source: manual}`、`BMC-XF-1: {status: xfail, reason: "romulus 预期不填 Accounts.Description,跟踪中", source: manual}`,其余 `default: applicable`)。
- 验证范围:两 YAML 合法可解析;5 条 AR 的 assert 类型均在 Task 2 三原语范围内。

- [ ] Step 1: 写失败检查(YAML 合法性 + assert 类型范围)
- Run: `python3 -c "import yaml; d=yaml.safe_load(open('tests/baseline/romulus/ar_probes.yaml')); assert isinstance(d.get('ars'),list) and len(d['ars'])==5; allowed={'status_in','json_path_exists','json_path_match'}; bad=[(a['ar'],x['type']) for a in d['ars'] for x in a['assert'] if x['type'] not in allowed]; assert not bad, bad; print('5 ARs ok, types in', sorted(allowed))" 2>&1; echo "rc=$?"`
- Expected: 失败(文件不存在 → FileNotFoundError,rc 非 0)。
- [ ] Step 2: 运行并确认失败
- Run: `test -f tests/baseline/romulus/ar_probes.yaml || echo MISSING`
- Expected: `MISSING`。
- [ ] Step 3: 写数据文件
- Change: 写 `ar_probes.yaml`(顶层 `auth` + `ars:` 列表,每条按上述 schema,字段顺序 `ar/name/probe/suite/request{method,path,body}/assert[{type,value}]/depends_on/rationale`);写 `applicability.yaml`(`default: applicable` + `overrides:` 下两条)。YAML 仅用 safe_load 可解析的纯结构。
- [ ] Step 4: 运行并确认通过
- Run: 同 Step 1 命令
- Expected: 打印 5 条 AR 的 id 与 assert 类型(均在三原语范围内),`rc=0`。
- Run: `python3 -c "import yaml; d=yaml.safe_load(open('tests/baseline/romulus/applicability.yaml')); assert d['default']=='applicable' and 'BMC-7-7-1' in d['overrides']"; echo "rc=$?"`
- Expected: `rc=0`。

### Task 4: romulus runner + report

- 目标:实现 `run.sh`(遍历 AR × applicability → 逐条 probe → 收 pass/fail/skip/xfail/xpass → exit 0/1)+ `report.py`(VERDICT 行 + 附录)。host/port/auth 由 `cmd_test_qemu` 注入(不硬编码)。
- Files
  - Create: `tests/baseline/romulus/runner/run.sh`
  - Create: `tests/baseline/romulus/runner/report.py`
- 接口契约
  - Consumes: `ar_probes.yaml` + `applicability.yaml`(Task 3)、`probe_redfish.py`(Task 2)、调用方注入的 `--host/--port/--user/--password`。
  - Produces: `run.sh` —— CLI `run.sh --host H --port P --user U --password W [--ar ID] [--suite NAME] [--report PATH] [-v] [-d]`;遍历(经 `--ar`/`--suite` 过滤 + applicability 过滤)后的 AR 列表;`-d/--dry-run` 只列将跑的 AR + applicability 判定、不探测、exit 0;正常路径逐条调 `probe_redfish.py`,收集结果;applicability `skip` 不调 probe 直接计入;`xfail` **调 probe 执行**(预期失败→记 xfail;意外通过→记 xpass,xpass 不影响 exit,作改善信号);上游 AR `skip` 且本条 `depends_on` 命中 → cascade-skip(计 skip);末尾调 `report.py` 产 VERDICT 行;exit 0(全 applicable pass,skip/xfail/xpass 不影响)/ 1(有 applicable fail)。`report.py` 读结果 JSON 数组,算 `pass/fail/skip/xfail/xpass` 计数,打印 `VERDICT: PASS|FAIL (N pass / N fail / N skip / N xfail / N xpass)` + skip/xfail/xpass 附录(各附 reason + source),可选 `--report PATH` 落 JSON。
- 验证范围:`run.sh --dry-run` 正确列出 5 条 AR + applicability 判定(skip/xfail 标注正确),不探测。

- [ ] Step 1: 写失败检查(dry-run 列 AR)
- Run: `bash tests/baseline/romulus/runner/run.sh --host 127.0.0.1 --port 2443 --user root --password 0penBmc --dry-run; echo "rc=$?"`
- Expected: 失败(文件不存在 → bash 找不到脚本,rc=127)。
- [ ] Step 2: 运行并确认失败
- Run: `test -x tests/baseline/romulus/runner/run.sh || echo MISSING`
- Expected: `MISSING`。
- [ ] Step 3: 写 run.sh + report.py
- Change: `run.sh`(`#!/usr/bin/env bash`,`set -euo pipefail`;解析 argv → python 读 ar_probes.yaml+applicability.yaml 做过滤(用内联 `python3 -c` 或临时脚本,避免 bash 解析 YAML)→ 产待跑 AR 列表;`--dry-run` 打印列表 + applicability 标注后 exit 0;正常路径 **逐条 probe 用 rc 捕获,绝不裸调**(`set -euo pipefail` 下 probe fail exit 1 会中止 runner、report.py 不执行,见评审三轮 🔴1):`if _out=$(python3 probe_redfish.py --host ... --asserts <json>); then _rc=0; else _rc=$?; fi`,按 `_rc`(0=pass / 1=fail)+ applicability 分类(xfail 预期 `_rc=1`→记 xfail;xfail 意外 `_rc=0`→记 xpass;skip 不调 probe),收集每条 `{ar,status,code,body,reason}`;汇总后调 `python3 report.py --results <json> [--report PATH]`;按 fail 计数 exit 0/1);`report.py`(读 stdin/文件 JSON 数组,算 `pass/fail/skip/xfail/xpass` 五态计数,打印 VERDICT 行 + 附录,exit 0)。
- [ ] Step 4: 运行并确认通过
- Run: `bash tests/baseline/romulus/runner/run.sh --host 127.0.0.1 --port 2443 --user root --password 0penBmc --dry-run; echo "rc=$?"`
- Expected: 列出 5 条 AR,`BMC-7-7-1` 标 `skip`、`BMC-XF-1` 标 `xfail`(dry-run 仅标注;正常路径 xfail 执行 probe,预期 fail→xfail / 意外 pass→xpass),其余 `applicable`;`rc=0`(dry-run 不探测)。
- [ ] Step 5: 可选 checkpoint commit(执行前确认当前分支与用户授权;agent 环境未获明确授权不自动 commit)
- Run: `git add tests/baseline/romulus/runner/ tests/baseline/romulus/*.yaml && git commit -m "feat(test-qemu): romulus runner + report + 5 spike ARs"`(仅经用户确认后)

### Task 5: cmd_test_qemu porcelain + ob 注册

- 目标:在 `lib/qemu_commands.sh` 实现 `cmd_test_qemu`(L1 编排,exit seam),在 `ob` 注册命令。probe-only:读 PID file 判实例存活 + 拿端口,定位 baseline 目录(custom 优先),调 `runner/run.sh`,exit 0/1/2/3 收口 + remedy。
- Files
  - Modify: `lib/qemu_commands.sh`(文件头注释命令簇清单加 `cmd_test_qemu`;新增 leaf-pure helper `test_qemu_resolve_baseline_dir` + L1 `cmd_test_qemu`)
  - Modify: `ob`(`ob:22` 附近加 `TEST_QEMU_ARGS=()` 全局声明,对齐 `DEV_ARGS`;`parse_args` 加 `test-qemu)` 分支 ~line 138 仿 `dev)`:先像 `smoke)` 取 machine 位置参数,再 `TEST_QEMU_ARGS=("$@"); set --`,且 `parse_args` 开头重置 `TEST_QEMU_ARGS=()`(防 OB_NO_MAIN 多次调用残留,见评审二轮补充建议);`main` 的 `COMMAND == test-qemu` guard 调 `cmd_test_qemu "${TEST_QEMU_ARGS[@]}"`;`--help` test-qemu 段 ~line 202 后)
- 接口契约
  - Consumes: `runner/run.sh`(per-machine,Task 4)、`qemu_instance` liveness/PID file 读端口(对齐 `cmd_smoke`)、`ob parse_args` 的 `TEST_QEMU_ARGS` 穿透(命令私有参数 `--suite/--ar/--report` 必须越过全局 option parser 到达 `cmd_test_qemu`,否则 `ob:184` Unknown option exit 1)。
  - Produces: leaf-pure helper `test_qemu_resolve_baseline_dir <machine> <outvar>`(`lib/qemu_commands.sh`,写 outvar=命中目录绝对路径或 `MISSING`,恒 return 0,对齐 `machine_selection_guard` outvar+恒0 范式 / ADR-0024;抽出为独立 helper 是为让 Task 6 protocol 测目录优先级时**不必构造 fake alive QEMU**,见评审 🔴2);L1 `cmd_test_qemu(argv...)`;`ob test-qemu <machine> [--suite <name>] [--ar <id>] [--report <path>] [-v] [-d] [-h]`(`<machine>` 必填,对齐 smoke);exit 0/1/2/3。目录定位序由 helper 实现:`contexts/baseline/<machine>/` → `tests/baseline/<machine>/` → `MISSING`(`cmd_test_qemu` 据 `MISSING` exit 3 + remedy `No baseline dir for '<machine>'; expected tests/baseline/<machine>/ or contexts/baseline/<machine>/.`)。无 running 实例 → exit 3 + remedy `Run 'ob start-qemu <machine>' first.`
- 验证范围:`ob test-qemu --help` 注册成功;`ob test-qemu` 无实例时 exit 3 + remedy;改 ob/lib 后 `ob_check.sh` 全绿。

- [ ] Step 1: 写失败检查(--help 注册)
- Run: `./ob test-qemu --help 2>&1 | grep -q "test-qemu" && echo REGISTERED || echo UNREGISTERED`
- Expected: `UNREGISTERED`(尚未注册)。
- [ ] Step 2: 运行并确认失败
- Run: `./ob test-qemu --help; echo "rc=$?"`
- Expected: 命令未注册(`ob` 报 unknown command 或 usage,rc 非 0)。
- [ ] Step 3: 写实现
- Change: ① `ob`:`ob:22` 附近加 `TEST_QEMU_ARGS=()` 全局(对齐 `DEV_ARGS`);`parse_args` 开头重置 `TEST_QEMU_ARGS=()`(防 OB_NO_MAIN 多次调用残留),加 `test-qemu)` 分支——先像 smoke 取 machine 位置参数(首个非 `-` 参数),再 `TEST_QEMU_ARGS=("$@"); set --`(仿 `dev)` 行 141-142,防 ob:184 Unknown option 拦私有参数)。 ② `ob` main:`COMMAND == test-qemu` guard 调 `cmd_test_qemu "${TEST_QEMU_ARGS[@]}"`。 ③ `lib/qemu_commands.sh` 新增 leaf-pure `test_qemu_resolve_baseline_dir <machine> <outvar>`——**锚定 `$HARNESS_ROOT`**(`detect_harness_root` 只设它、不 cd,见 util.sh:210;从任意 cwd 调 ob 时相对路径会误报 MISSING,见评审二轮 🟡2):`local root="${HARNESS_ROOT:-$OB_ENTRY_DIR}"; [[ -d "$root/contexts/baseline/$1" ]] && printf -v "$2" '%s' "$root/contexts/baseline/$1"` elif `[[ -d "$root/tests/baseline/$1" ]]` → 写该路径,else `printf -v "$2" '%s' MISSING`;恒 return 0(对齐 machine_selection_guard / ADR-0024 outvar+恒0)。 ④ 新增 L1 `cmd_test_qemu(argv...)`:**先扫 -h|--help,命中打印 test-qemu usage + exit 0**(必须在 machine 必填/liveness 之前——`parse_args test-qemu)` 的 `set --` 让 --help 进 TEST_QEMU_ARGS 而非全局 parser,见评审四轮 🟡1,否则 `./ob test-qemu --help` 因 MACHINE 空走 no-machine exit 3);machine 用全局 `$MACHINE`(`parse_args` 已设置),**argv 只解析私有 flags**(`--suite/--ar/--report/-v/-d/-h`),不重复解析 machine(见评审四轮 🟡2);**machine 必填**(对齐 cmd_smoke:536-551:无 machine → 列 `qemu_instance_list` running candidates + exit 3);liveness 前置(对齐 cmd_smoke:556,死/stale→`qemu_instance_clean_stale` + exit 3 + remedy `Run 'ob start-qemu <machine>' first.`);`test_qemu_resolve_baseline_dir "$MACHINE" _dir`,`_dir == MISSING` → exit 3 + remedy `No baseline dir for '$MACHINE'; expected tests/baseline/$MACHINE/ or contexts/baseline/$MACHINE/.`;running→读 `PIDFILE_REDFISH_PORT` 等;cd `$_dir/runner`,auth 从 `$_dir/ar_probes.yaml` 顶层读(`python3 -c`,需 PyYAML),调 `bash run.sh --host 127.0.0.1 --port <redfish> --user <auth.user> --password <auth.pass> [--ar] [--suite] [--report] [-v] [-d]`;透传 run.sh exit 0/1。 ⑤ 文件头注释命令簇加 `cmd_test_qemu`。 ⑥ `ob` --help 加 test-qemu 段(命令行 `<machine>` 必填 + Options:probe-only 边界、exit codes α 措辞沿用 smoke、端口从 PID file 读不透传、baseline 目录定位序 + ADR-0025 引用)。
- [ ] Step 4: 运行并确认通过
- Run: `./ob test-qemu --help 2>&1 | grep -q "test-qemu" && echo REGISTERED || echo UNREGISTERED`
- Expected: `REGISTERED`。
- Run: `./ob test-qemu romulus --suite users --ar BMC-3-1-2 --report /tmp/x >/tmp/tq.out 2>&1; rc=$?; grep -qi "Unknown option" /tmp/tq.out && echo BLOCKED || echo PASSTHROUGH; echo "rc=$rc"`
- Expected: `PASSTHROUGH`(私有参数越过全局 parser 到 cmd_test_qemu,不被 ob:184 Unknown option 拦);`rc=3`(到 liveness 前置,无 romulus 实例)。
- Run: `./ob test-qemu romulus 2>&1; echo "rc=$?"`(假设无 romulus running 实例)
- Expected: exit 3 + remedy 行(`Run 'ob start-qemu romulus first.'`)。
- Run: `bash tools/ob_check.sh; echo "rc=$?"`
- Expected: `rc=0`(ob_check 全绿)。

### Task 6: protocol 层测试

- 目标:`tests/protocol/test_qemu_surface.sh` 断言命令注册、parse_args 参数穿透(🔴1)、`test_qemu_resolve_baseline_dir` 目录优先级(🔴2,直接测 leaf-pure helper,**不需 fake alive QEMU**)、exit 契约。
- Files
  - Create: `tests/protocol/test_qemu_surface.sh`
- 接口契约
  - Consumes: `test_qemu_resolve_baseline_dir` helper + `cmd_test_qemu`(Task 5)、`ob` parse_args `test-qemu)` 分支。
  - Produces: protocol 测试(非交互、零 QEMU 依赖、毫秒级)。
- 验证范围:`run_all.sh` protocol 层含本测试且通过。

- [ ] Step 1: 写失败检查(测试文件存在性)
- Run: `test -f tests/protocol/test_qemu_surface.sh || echo MISSING`
- Expected: `MISSING`。
- [ ] Step 2: 运行并确认失败
- Run: `bash tests/run_all.sh 2>&1 | grep -q test_qemu_surface && echo LISTED || echo ABSENT`
- Expected: `ABSENT`(未登记)。
- [ ] Step 3: 写测试
- Change: 写 `test_qemu_surface.sh`(`#!/usr/bin/env bash`,`set -uo pipefail`,source `tests/lib/ob_loader.sh` + `assert.sh` + `stub.sh`,形态对照 `smoke_exit_contract.sh`);断言:① 注册:`./ob test-qemu --help` 含 `test-qemu`。② parse_args 穿透(🔴1):`./ob test-qemu fake-m --suite x --report y` 输出不含 `Unknown option`,exit 3(到 liveness 前置)而非 exit 1(被 parser 拦)。③ machine 必填(🟡5):`./ob test-qemu`(无 machine)→ exit 3(对齐 cmd_smoke:536-551 列 candidates)。④ helper 目录优先级 + No-baseline-dir(🔴1+🔴2+🟡2,直接测 leaf-pure,零 QEMU):source `lib/qemu_commands.sh`,设 `HARNESS_ROOT="$tmp"`(`tmp=$(mktemp -d)`),在 `$tmp` 下构造 `contexts/baseline/fake-m/` + `tests/baseline/fake-m/` 双目录,调 `test_qemu_resolve_baseline_dir fake-m out`,断言 `out` 命中 `$tmp/contexts/baseline/fake-m`(custom 优先);删 contexts 目录后重测断言命中 `$tmp/tests/baseline/fake-m`;两者都删后断言 `out=MISSING`(**No baseline dir 只在 helper 层测**——cmd 层该 remedy 需先过 liveness,属 integration,不在 protocol 测,见评审二轮 🔴1)。
- [ ] Step 4: 运行并确认通过
- Run: `bash tests/run_all.sh >/tmp/ra.log 2>&1; rc=$?; grep -E "test_qemu_surface" /tmp/ra.log; test $rc -eq 0 && echo "GREEN rc=0" || echo "rc=$rc"`
- Expected: 输出含 `test_qemu_surface` 行;`GREEN rc=0`(protocol/unit/orchestration ALL GREEN)。
- Run: `bash tools/ob_check.sh; echo "rc=$?"`
- Expected: `rc=0`。

### Task 7: integration 层五态验证(真实 romulus QEMU)

- 目标:`tests/integration/test_qemu_baseline_e2e.sh` 在真实 romulus QEMU 实例上跑 5 条 AR,确认 pass/fail/skip/xfail 五态正确、exit 契约成立。无 romulus image 时 exit 77 SKIP(不阻断)。
- Files
  - Create: `tests/integration/test_qemu_baseline_e2e.sh`
- 接口契约
  - Consumes: `ob test-qemu`(Task 5)、romulus baseline 目录(Task 2-4)、romulus firmware image(`ob build romulus`)+ running 实例(`ob start-qemu romulus`)。
  - Produces: integration E2E 测试。
- 验证范围:`run_all.sh --integration` 含本测试;有 image+实例时跑通五态。

- [ ] Step 1: 写失败检查(测试文件存在性)
- Run: `test -f tests/integration/test_qemu_baseline_e2e.sh || echo MISSING`
- Expected: `MISSING`。
- [ ] Step 2: 运行并确认失败
- Run: `bash tests/run_all.sh --integration 2>&1 | grep -q test_qemu_baseline_e2e && echo LISTED || echo ABSENT`
- Expected: `ABSENT`。
- [ ] Step 3: 写测试
- Change: 写 `test_qemu_baseline_e2e.sh`(`#!/usr/bin/env bash`,形态对照 `tests/integration/smoke_e2e.sh` / `tests/integration/` 既有 E2E);**integration 拥有测试生命周期**(对齐 `smoke_e2e.sh` 的 start→probe→stop 模式,见评审五轮 🟡1,消除"无 running→SKIP"与"若未在跑 start-qemu"的同句冲突):romulus 无 firmware image / image not ready → `exit 77`(SKIP,测试协议码,非主契约,对齐 ADR-0008);**有 image**:若无 running 实例 → `ob start-qemu romulus` 并标记 `started_by_test=1`,若已有 running → 复用并标 `started_by_test=0`;**Redfish readiness gate**(对齐 `smoke_e2e.sh:45-85` Step 1b,见评审六轮 🟡1:`ob start-qemu` 的 BMC-ready 只等 SSH 不等 Redfish,bmcweb boot 窗口会 flap 200↔500,5 条 Redfish probe 必踩 race):读 PID file `redfish_port`,轮询 `https://localhost:<port>/redfish/v1` 要求连续 N 次 HTTP 200(默认 `OB_INTEG_REDFISH_DEBOUNCE=2`,间隔 5s,带上界 `OB_INTEG_REDFISH_ATTEMPTS=30`×5s),超时则 FAIL + 只 stop `started_by_test==1` 的实例;→ `ob test-qemu romulus --report <mktemp>` → 断言 exit 0 或 1(α truth:romulus 上 BMC-2-2-1/BMC-3-15-1 应 pass,BMC-3-1-2 视 phosphor-user-manager 行为 pass/fail,BMC-7-7-1 skip,BMC-XF-1 ∈ {xfail,xpass});解析 report JSON 断言:`skip>=1`(BMC-7-7-1)、`xfail+xpass>=1`(BMC-XF-1 verdict ∈ {xfail,xpass}:预期 fail→xfail,意外 pass→xpass;**不要求 `xfail>=1`**,否则 xpass 改善信号会误判 integration 失败,见评审三轮 🟡2);收尾**只 stop 自己启动的实例**(`[[ "${started_by_test:-0}" == "1" ]] && ob stop-qemu romulus`),不 stop 复用的既有实例。退出码经 marker file 确认(不用 `echo $?`,对齐 evidence-13 reaped-nohup 教训)。
- [ ] Step 4: 运行并确认通过
- Run: `bash tests/integration/test_qemu_baseline_e2e.sh; echo "rc=$?"`
- Expected: `rc=0`(有 romulus image+实例,五态正确:`skip>=1`、`xfail+xpass>=1`)或 `rc=77`(无 image,SKIP 不阻断)。直接跑测试脚本看 rc,避免经 `run_all.sh --integration` 的聚合 rc 语义干扰。

### Task 8: CONTEXT.md 新增 `ob test-qemu` 命令术语

- 目标:CONTEXT.md 新增 `ob test-qemu` 词条(对齐既有 `ob smoke` 完整词条深度),钉死 probe-only 边界、与 smoke 关系、per-machine baseline、目录优先级、skip/xfail/xpass 语义、exit contract。命令行为由 Task 5 实现,术语由本任务沉淀。
- Files
  - Modify: `CONTEXT.md`(在 `ob smoke` 词条后插入 `ob test-qemu` 条目)
- 接口契约
  - Consumes: Task 5 实现的 `cmd_test_qemu` 真实行为 + ADR-0025 + `baseline` 词条。
  - Produces: `ob test-qemu` CONTEXT 词条。
- 验证范围:词条存在;定义与 Task 5 行为一致(不漂移);`_Avoid_` 含 `conformance`。

- [ ] Step 1: 写失败检查(词条存在性)
- Run: `grep -q '^\*\*ob test-qemu\*\*' CONTEXT.md && echo EXISTS || echo MISSING`
- Expected: `MISSING`。
- [ ] Step 2: 运行并确认失败
- Run: 同上
- Expected: `MISSING`。
- [ ] Step 3: 写词条
- Change: 在 `CONTEXT.md` 的 `ob smoke` 词条后插入 `**ob test-qemu**:` 条目:定义(probe-only 深测命令,在已在跑 QEMU 实例上逐条跑该 machine `baseline` 的 QEMU 可仿真 AR 子集,产出 `pass/fail/skip/xfail/xpass`);与 `ob smoke` 正交姊妹(smoke 浅冒烟 5 哨兵 + 零 per-machine 守 per-push 绿灯;test-qemu 逐条深测 + 全栈 per-machine,nightly/PR-to-main 频率);baseline 目录优先级(`contexts/baseline/<machine>` custom 优先 > `tests/baseline/<machine>` 社区,见 ADR-0025);probe-only(不 boot/teardown,无实例 exit 3 + remedy 指向 `ob start-qemu`,端口从 PID file 读);`skip`(不适用/硬件依赖,不调 probe)/`xfail`(预期失败,调 probe:预期 fail→xfail,意外 pass→xpass,xpass 不影响 exit)/exit 0/1/2/3(0 全 applicable pass;1 有 fail = α BMC truth 非 broken;2 cancel;3 前置缺失 + remedy)。`_Avoid_:` conformance(弃用),test-qemu verify。
- [ ] Step 4: 运行并确认通过
- Run: `grep -q '^\*\*ob test-qemu\*\*' CONTEXT.md && echo "test-qemu词条EXISTS" || echo MISSING; awk '/^\*\*baseline \(开发基线/,/_Avoid_/' CONTEXT.md | grep -q 'xpass' && echo "baseline含xpass" || echo "baseline缺xpass"`
- Expected: `test-qemu词条EXISTS`;`baseline含xpass`(baseline 词条上轮已加 xpass,此处防漂移,见评审二轮 🟡4)。

## 执行纪律

- 开始实现前先批判性复查整份计划;发现缺项、矛盾、命名不一致或验证命令无效,先修计划。
- 按任务顺序执行,不无声跳步、合并步或改变任务目标。
- 每完成一个任务,运行该任务定义的验证。
- Task 5 / Task 6 改了 `ob` / `lib/*.sh`,完成后必须跑 `bash tools/ob_check.sh`。
- 遇到阻塞、重复失败或计划与仓库现实不符(如 `cmd_smoke` 的 machine 解析路径与预期不符、`qemu_instance` liveness 接口名漂移),立即停下说明,不猜。
- 若当前在 `main`/`master` 且用户未明确同意,开始实现前先确认/开分支。
- 全部任务完成后,运行最终验证并输出修改摘要。

## 最终验证

- Run: `before=$(ls workspace/qemu-bin/.pids/ 2>/dev/null | tr '\n' ' '); bash tools/ob_check.sh; echo "ob_check_rc=$?"; bash tests/run_all.sh --full --integration >/tmp/final.log 2>&1; echo "runall_rc=$?"; after=$(ls workspace/qemu-bin/.pids/ 2>/dev/null | tr '\n' ' '); [ "$before" == "$after" ] && echo "pids_nochange" || echo "pids_changed: before=[$before] after=[$after]"`
- Expected: `ob_check_rc=0`;`runall_rc=0`(protocol/unit/orchestration ALL GREEN;integration 层 `test_qemu_baseline_e2e` PASS 或 SKIP-77 不阻断);`pids_nochange`(PID 文件集合与测试前一致——**不要求全局空**,避免误伤环境里其他 machine 的 running instance,见评审 🟡7;本测试自起的 romulus 由 Task 7 的 `ob stop-qemu romulus` 清理)。
- 语义验证:在真实 romulus QEMU 上 `./ob test-qemu romulus`,确认 VERDICT 行打印 `pass/fail/skip/xfail/xpass` 计数,`BMC-7-7-1` 进 skip 附录、`BMC-XF-1` 进 xfail/xpass 附录(预期 fail→xfail,意外 pass→xpass);skip/xfail/xpass 不污染 exit。

## 后续扩展(超出本次 spike 计划,各自独立计划)

- **扩 AR 到全集**:以 spike 5 条为模板,补 romulus 的 QEMU 可仿真 AR(从 baseline Excel 重新拆分 AR;AR 原始来源是 baseline 文档,数据模型遵循本计划 per-machine 独立;这正是「LLM authoring 工具」独立计划的职责)。
- **custom 机 baseline**:为 `contexts/baseline/<custom-machine>/`(如 b865g8-bytedance)建同构目录,验证 custom 覆盖社区定位序。
- **LLM authoring 工具(独立计划)**:读 Excel baseline → 翻译成 `ar_probes.yaml`,人 review 后固化。这是降低 authoring 成本的离线工具,不碰 runtime 判定。
- **失败解说员(独立计划)**:`report.py` 的 fail 行附加 LLM 生成的自然语言解释(读 request/expected/actual),不改判定结果。
- **CI 挂载**:nightly 编排 `start-qemu → test-qemu → stop-qemu`,产报告 artifact;PR-to-main 调 `ob test-qemu`。

## 审阅 Checkpoint

实施计划已写好并保存到 `docs/plans/2026-08-12-ob-test-qemu-baseline-implementation-plan.md`。请先确认这份计划;如果没问题,下一步可以按计划由普通编码 agent 或人工继续执行。未获批准,不进入实现。
