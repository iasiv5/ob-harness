# 端口解析链 leaf-pure module（抽端口复用 resolver + 统一 deploy 到 cli_first）实施计划

## 目标

- 把 `ob start-qemu`（restart）与 `ob deploy-to-qemu`（build-first restart）各自内联、且规则不对称的「旧实例端口 → `QEMU_*_PORT`」注入 ritual，抽成一个 leaf-pure module `resolve_qemu_port_reuse`。
- 两调用点统一走 cli_first（`-z` guard），消除不对称，修掉 `ob deploy-to-qemu --ssh-port N`（QEMU 在跑）被静默丢弃的 latent bug。
- prepare 的基础链 `${QEMU_*:-${OB_*:-default}}`（`lib/qemu.sh:97-100`）不动；interactive 协商 / `check_ports_available` 不动。
- 落 [ADR-0022](../adr/0022-port-reuse-resolver-module.md) 的全部决策（D1 Narrow / D2 Unify / D3 Keep sentinel / D4 新文件）。

## 架构快照

- 新 module `resolve_qemu_port_reuse <ssh> <redfish> <ipmi> <http>`：消费旧实例 4 端口（argv，不读全局 `PIDFILE_*`），按 cli_first 把非空旧端口注入到 `QEMU_*_PORT`（CLI flag 层），HTTP 额外跳过 `none` sentinel。恒 return 0、绝不 exit（leaf-pure）。
- 调用点：start 在 `qemu_instance_stop` 后传 `"$PIDFILE_*"`；deploy 在 stop 后传预先捕获的 `old_*` locals（capture 仍在 stop 前）。两处各换成一次 module 调用。
- 链序不变：`CLI > 旧实例(注入) > env > 默认`。Unify 只改 deploy 是否 guard CLI flag，不改链序。
- module 必须独立文件：`exit_contract` 的 Y 规则按 basename 判 leaf-pure，而 `lib/qemu.sh` 是 direct-exit module（exit 1 / exit 3），leaf-pure 函数塞进去会被文件级契约污染。

## 全局约束

- 命名规则：目录/文件 snake_case；`<domain>_<noun>.sh`（对照 `lib/machine_resolve.sh`）；函数走 `resolve_*` 族（对照 `resolve_command_machine` / `resolve_qemu_launch_profile`）。
- leaf-pure 契约：module 函数绝不直接 `exit`；副作用（set `QEMU_*_PORT` 全局）允许（"pure" 仅指 no-direct-exit，见 CONTEXT.md `function semantic layer`）。
- exit-code 契约不变：start/deploy 仍是 exit seam（L1 `cmd_*` 收口 exit）；新 module 恒 return 0。
- 文案规则：注入相关注释引用 ADR-0022（统一）/ ADR-0021（历史机制）。
- 无版本/依赖/平台约束。

## 输入工件

- 设计：[docs/adr/0022-port-reuse-resolver-module.md](../adr/0022-port-reuse-resolver-module.md)（4 个 Considered Options + Consequences）。
- 被 Amends：[docs/adr/0021-qemu-restart-port-reuse.md](../adr/0021-qemu-restart-port-reuse.md)（Status 回指已在 grill 阶段添加）。
- 先例模板：`lib/image_build.sh`（leaf-pure 头部 + return rc）、`tests/unit/image_build.sh`（stub + assert 三态）、`tests/protocol/machine_resolve_surface.sh`（extract_fn + call-count + forbidden interface-shrink）。

## 文件结构与职责

- Create: `lib/qemu_port_reuse.sh` — leaf-pure resolver，`resolve_qemu_port_reuse`。
- Create: `tests/unit/qemu_port_reuse.sh` — cli_first 矩阵单测（纯函数，无 stub）。
- Create: `tests/protocol/qemu_port_reuse_surface.sh` — interface-shrink 回归锁（两调用点都经 module、不再内联 ritual）。
- Modify: `lib/qemu_commands.sh` — `cmd_start_qemu`（注入块 `:100-104`）+ `cmd_deploy_to_qemu`（注入块 `:375-378`）换成 module 调用。
- Modify: `tests/protocol/qemu_restart_port_reuse.sh` — 断言从「内联字面注入行」改写为「confirm 分支调 module / --force·stale 不调」。
- Modify: `tools/exit_contract.py` — `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 加 `'qemu_port_reuse.sh': set()`。
- Modify: `rules/03_WORKSPACE.md` — lib 路由表登记 `qemu_port_reuse.sh`。
- Modify: `tools/coverage_matrix.md` — start-qemu 段加 `resolve_qemu_port_reuse` 行。
- 边界保持稳定：`lib/qemu.sh`（prepare 基础链 / interactive / check 全不动）、`ob`（lib/*.sh glob 自动 source，无需改 source 列表）。
- ADR-0021 正文不再改：行号漂移（367-370→375-378）+ 注入 ritual 迁移已由其 Status 回指标注为 pre-0022 历史。
- CONTEXT.md `端口解析链` 术语订正（链序 old>env / HTTP opt-in / 机制细节归 ADR）已随 ADR-0022 起草阶段（grill）完成（见 CONTEXT.md:95 现状），本计划不含该改动——审阅者对照 ADR-0022 Consequences 的「CONTEXT.md」项不算缺项。

## 任务清单

### Task 1: PIN 基线——冻结当前 protocol/unit/orchestration 行为

- 目标：在动代码前确认现有测试网全绿，作为 characterization 基线。
- Files: 无（只读运行）。
- 接口契约：Consumes 无；Produces「基线绿」事实，供 Task 3 的「预期红窗口」对照。
- 验证范围：`tests/run_all.sh` 退出 0。

- [ ] Step 1: 跑快速三层。
- Run: `tests/run_all.sh`
- Expected: 退出 0，protocol/unit/orchestration 全绿；记录 `tests/protocol/qemu_restart_port_reuse.sh` 当前为 GREEN（它锁的是抽取前的内联形态，Task 3 后会短暂转红）。

### Task 2: 新建 module + unit 单测 + exit_contract 登记（TDD）

- 目标：leaf-pure resolver 落地，cli_first 矩阵单测通过，exit_contract 开始强制其纯度。
- Files:
  - Create: `lib/qemu_port_reuse.sh`
  - Create: `tests/unit/qemu_port_reuse.sh`
  - Modify: `tools/exit_contract.py`（`LEAF_EXIT_EXCEPTIONS_BY_BASENAME`）
- 接口契约：
  - Consumes: `QEMU_*_PORT` 全局（ob 顶部 ob:25-28 初始化为空串；ob_loader source ob 后可用）。
  - Produces: 函数 `resolve_qemu_port_reuse <ssh> <redfish> <ipmi> <http>`（set `QEMU_*_PORT`，恒 return 0）。
- 验证范围：`bash tests/unit/qemu_port_reuse.sh` 退出 0。

- [ ] Step 1: 写失败单测（module 尚不存在）。
- Create `tests/unit/qemu_port_reuse.sh`：

```bash
#!/usr/bin/env bash
# tests/unit/qemu_port_reuse.sh — resolve_qemu_port_reuse leaf-pure 单测(unit 层)。
# 纯函数(4 argv → set QEMU_*_PORT)，无 stub。锁 cli_first(ADR-0022) + HTTP none sentinel + 恒 return 0 契约。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

reset_ports(){ QEMU_SSH_PORT=""; QEMU_REDFISH_PORT=""; QEMU_IPMI_PORT=""; QEMU_HTTP_PORT=""; }

# --- cli_first: CLI flag 压旧实例端口 ---
reset_ports; QEMU_SSH_PORT=9999
resolve_qemu_port_reuse 2222 2443 2623 none; rc=$?
assert_eq "恒 return 0 (CLI set 路径)" "$rc" 0
assert_eq "CLI wins over old (SSH)" "$QEMU_SSH_PORT" 9999

# --- 旧实例填空 CLI（restart 复用主路径）---
reset_ports
resolve_qemu_port_reuse 2222 2443 2623 none; rc=$?
assert_eq "恒 return 0 (旧实例填空路径)" "$rc" 0
assert_eq "old fills empty CLI (SSH)"    "$QEMU_SSH_PORT" 2222
assert_eq "old fills empty CLI (Redfish)" "$QEMU_REDFISH_PORT" 2443
assert_eq "old fills empty CLI (IPMI)"   "$QEMU_IPMI_PORT" 2623

# --- 两皆空 → 保持空 + rc=0（三条 numeric guard 亦全 false）---
reset_ports
resolve_qemu_port_reuse "" "" "" ""; rc=$?
assert_eq "恒 return 0 (全空路径)" "$rc" 0
assert_eq "both empty stays empty (SSH)" "$QEMU_SSH_PORT" ""

# --- HTTP none sentinel: rc=0 + HTTP 不注入（🔴1 主路径; set -e 裸调中止的回归点）---
reset_ports
resolve_qemu_port_reuse 2222 2443 2623 none; rc=$?
assert_eq "恒 return 0 (HTTP none sentinel 主路径)" "$rc" 0
assert_eq "HTTP none sentinel skipped" "$QEMU_HTTP_PORT" ""

# --- HTTP 旧值有效 + CLI 空 → 注入 ---
reset_ports
resolve_qemu_port_reuse 2222 2443 2623 8080; rc=$?
assert_eq "恒 return 0 (HTTP 注入路径)" "$rc" 0
assert_eq "HTTP old set, CLI empty → set" "$QEMU_HTTP_PORT" 8080

# --- HTTP cli_first: CLI 压旧值 ---
reset_ports; QEMU_HTTP_PORT=9000
resolve_qemu_port_reuse 2222 2443 2623 8080; rc=$?
assert_eq "恒 return 0 (HTTP CLI wins 路径)" "$rc" 0
assert_eq "HTTP CLI wins over old" "$QEMU_HTTP_PORT" 9000

assert_summary
```

- [ ] Step 2: 确认失败（module 未定义）。
- Run: `bash tests/unit/qemu_port_reuse.sh`
- Expected: 非零退出。ob_loader 的 `set +e` 下 `command not found`（rc 127）不中止脚本；首条「CLI wins」因预设 `QEMU_SSH_PORT=9999` 假性通过，但其后「old fills empty（期望 2222，实际空）」「恒 return 0」等矩阵态 assert 失败 → `assert_summary` 退出 1。红是红的（rc 非零），勿被首条假绿误导。

- [ ] Step 3: 写最小实现 + 登记 exit_contract。
- Create `lib/qemu_port_reuse.sh`：

```bash
#!/usr/bin/env bash
# lib/qemu_port_reuse.sh — restart 端口复用注入 resolver。术语见 CONTEXT.md 端口解析链.
# Exit: leaf-no-exit（leaf-pure module）; 恒 return 0, exit 由 L1 cmd_* 收口。
# 消费旧实例 4 端口(argv), 按 cli_first（X-α, -z guard）注入到 QEMU_*_PORT（CLI flag 层）;
# HTTP 额外跳过 'none' sentinel（qemu.sh:160 空值回写 none）。
# ob start-qemu（restart）/ ob deploy-to-qemu（build-first restart）共享——
# ADR-0022 统一 deploy 到 cli_first（修 deploy+--ssh-port 静默丢弃; 0021 future-candidate #1）。
# 不含 interactive 协商 / check_ports_available（那些有 exit, 留 qemu_prepare_launch 消费）。
resolve_qemu_port_reuse() {
    local old_ssh="$1" old_redfish="$2" old_ipmi="$3" old_http="$4"
    [[ -z "$QEMU_SSH_PORT" ]]     && QEMU_SSH_PORT="$old_ssh"
    [[ -z "$QEMU_REDFISH_PORT" ]] && QEMU_REDFISH_PORT="$old_redfish"
    [[ -z "$QEMU_IPMI_PORT" ]]    && QEMU_IPMI_PORT="$old_ipmi"
    [[ -n "$old_http" && "$old_http" != "none" && -z "$QEMU_HTTP_PORT" ]] && QEMU_HTTP_PORT="$old_http"
    return 0   # 契约「恒 return 0」: 末条 AND-list 在 HTTP guard 不成立时 rc=1, set -e 下裸调会中止
               # restart(实测 bash 5.2.21 复现: inline 形态享 && 链豁免、函数调用不享)。显式 return 0 兜底。
}
```

- Change `tools/exit_contract.py`：在 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME`（L53 起）加一行（与 `'image_build.sh': set()` / `'machine_resolve.sh': set()` 同形）：

```python
    'qemu_port_reuse.sh': set(),
```

- Change: 新建 module（cli_first 注入，HTTP none 跳过）；登记 basename 让 exit_contract Y 规则强制其无 exit。
- 前置：module 须 shellcheck-clean——flat 合成里 `QEMU_*_PORT` 由 `ob:25-28` 赋值（无 SC2154）、参数全引号（无 SC2086）、`[[ ]] && cmd` 无告警。**只有零新告警时** ob_check 才判「良性行号平移」并重生成 baseline（见 Task 6）；若误入新告警，ob_check 报「新增告警、未自动改」并失败，须先修 module。

- [ ] Step 4: 确认单测通过。
- Run: `bash tests/unit/qemu_port_reuse.sh`
- Expected: 退出 0，全部 assert PASS。
- [ ] Step 5: checkpoint commit。
- Run: `git add lib/qemu_port_reuse.sh tests/unit/qemu_port_reuse.sh tools/exit_contract.py && git commit -m "feat(qemu): add resolve_qemu_port_reuse leaf-pure module (ADR-0022)"`

### Task 3: 接线两调用点（替换内联注入为 module 调用）

- 目标：start/deploy 的内联注入 ritual 换成 `resolve_qemu_port_reuse` 调用，deploy 同步获得 cli_first。
- Files: Modify `lib/qemu_commands.sh`（`cmd_start_qemu` `:100-104`、`cmd_deploy_to_qemu` `:375-378`）。
- 接口契约：
  - Consumes: `resolve_qemu_port_reuse`（Task 2 Produces）。
  - Produces: 两调用点不再内联注入；`tests/protocol/qemu_restart_port_reuse.sh` 转红（预期，Task 4 修复）。
- 验证范围：`grep` 确认两处各剩一行 module 调用、无内联注入残留（Task 4 surface gate 正式锁）。

- [ ] Step 1: 改动前检查——确认当前内联形态（Task 1 基线）。
- Run: `grep -nF 'QEMU_SSH_PORT="$PIDFILE_SSH_PORT"' lib/qemu_commands.sh; grep -nF 'QEMU_SSH_PORT="$old_ssh_port"' lib/qemu_commands.sh`
- Expected: 命中 start（`:100` 附近）与 deploy（`:375` 附近）各一处内联注入。

- [ ] Step 2: （检查已在 Step 1 体现当前缺失状态：注入仍内联、未走 module。）

- [ ] Step 3: 替换两处。
- `cmd_start_qemu`：把 `:97-104`（既有 `# ── Port reuse` 注释 3 行 + **5 行** `-z` guard 注入——HTTP guard `\` 续行跨 `:103-104`；`:99` 的「deploy 用无条件赋值」在 Unify 后成假陈述，随块删除）整段替换为新注释 + 单行 module 调用：

```bash
                # ── Port reuse (restart 语义): 沿用旧实例端口, 经 leaf-pure module 统一 cli_first
                # (ADR-0022; X-α -z guard 保 CLI flag 优先。deploy 同款, 不再不对称)。
                resolve_qemu_port_reuse "$PIDFILE_SSH_PORT" "$PIDFILE_REDFISH_PORT" "$PIDFILE_IPMI_PORT" "$PIDFILE_HTTP_PORT"
```

- `cmd_deploy_to_qemu`：把 `:375-378` 的无条件赋值四行替换为单行（Unify：deploy 现在也 cli_first）：

```bash
        resolve_qemu_port_reuse "$old_ssh_port" "$old_redfish_port" "$old_ipmi_port" "$old_http_port"
```

- Change: start 传 `PIDFILE_*`（stop 后仍 in scope）；deploy 传 stop 前捕获的 `old_*` locals（capture `:325-328` 不动）。两处统一 cli_first。

- [ ] Step 4: 确认接线形态（注意：`qemu_restart_port_reuse.sh` 此时预期红——它仍锁旧内联形态，Task 4 改写）。
- Run: `grep -Fc 'resolve_qemu_port_reuse' lib/qemu_commands.sh` ； `grep -nF 'QEMU_SSH_PORT="$PIDFILE_SSH_PORT"' lib/qemu_commands.sh || echo CLEAN`
- Expected: module 调用计数 `2`（start + deploy 各一）；第二条输出 `CLEAN`（内联注入已消失）。
- ⚠️ 中间态：`bash tests/protocol/qemu_restart_port_reuse.sh` 此刻非零（预期红）。**不要**在 Task 3 与 Task 4 之间跑全量 `run_all.sh`。

### Task 4: 改写既有 gate + 新增 surface gate（恢复绿 + 防 回潮）

- 目标：把 `qemu_restart_port_reuse.sh` 的断言对齐 module 调用形态；新增 interface-shrink gate 锁两调用点都经 module、不再内联 ritual。
- Files:
  - Modify: `tests/protocol/qemu_restart_port_reuse.sh`
  - Create: `tests/protocol/qemu_port_reuse_surface.sh`
- 接口契约：Consumes `resolve_qemu_port_reuse`（Task 2）+ 两调用点接线（Task 3）；Produces「分支语义锁 + interface-shrink 锁」。
- 验证范围：两个 protocol gate 均 `bash` 退出 0。

- [ ] Step 1: 改动前检查——确认 Task 3 留下的红。
- Run: `bash tests/protocol/qemu_restart_port_reuse.sh; echo "rc=$?"`
- Expected: 非零（断言找不到旧的内联字面行）。

- [ ] Step 2: （同上，红信号即当前缺失状态。）

- [ ] Step 3a: 改写 `tests/protocol/qemu_restart_port_reuse.sh`。
- 把头部注释的 ADR 引用从 0021 扩到「0021 机制 / 0022 module 化」。断言逻辑改为：保留 `start_seg` / `confirm_seg` / `force_seg` / `stale_seg` 的 sed 切段不变，把四条「内联字面注入行 `grep -Fq`」与 `guard_count` 改为对 `resolve_qemu_port_reuse` 的调用断言：

```bash
# 1. 交互确认分支经 module 注入(全端口, module 内部 cli_first + HTTP none)
assert_true "confirm branch calls resolve_qemu_port_reuse" \
    grep -Fq 'resolve_qemu_port_reuse "$PIDFILE_SSH_PORT"' <<< "$confirm_seg"
# 2. start 段恰好一处 module 调用(防别处重复; 带参数形避注释干扰, 对照 machine_resolve_surface.sh)
assert_eq "resolve_qemu_port_reuse called once in cmd_start_qemu" \
    "$(grep -Fc 'resolve_qemu_port_reuse "$PIDFILE_SSH_PORT"' <<< "$start_seg")" 1
# 3. --force 分支不注入(不调 module)
assert_false "--force branch calls NO resolve_qemu_port_reuse" \
    grep -Fq 'resolve_qemu_port_reuse' <<< "$force_seg"
# 4. stale 清理分支不注入(不调 module)
assert_false "stale-cleanup branch calls NO resolve_qemu_port_reuse" \
    grep -Fq 'resolve_qemu_port_reuse' <<< "$stale_seg"
```

- Change: 断言对象从「字面注入行」改为「module 调用落点 + 分支独占」；分支语义（仅 restart 注入）不变。

- [ ] Step 3b: 新增 `tests/protocol/qemu_port_reuse_surface.sh`（仿 `machine_resolve_surface.sh` 的 extract_fn + call-count + forbidden）：

```bash
#!/usr/bin/env bash
# tests/protocol/qemu_port_reuse_surface.sh — port-reuse interface-shrink 回归锁(ADR-0022)。
# 防回潮: cmd_start_qemu / cmd_deploy_to_qemu 的端口复用必须经 resolve_qemu_port_reuse,
# 不再内联 -z guard / 无条件赋值 ritual(bestpractice_10 形态 A)。
set -uo pipefail
source "$(dirname "$0")/../lib/assert.sh"
assert_reset
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QC="$ROOT/lib/qemu_commands.sh"
test -f "$QC" || { echo "MISSING $QC" >&2; exit 1; }

extract_fn() {  # 同 machine_resolve_surface.sh
    local file="$1" fn="$2"
    awk -v fn="$fn" '
        BEGIN { in_fn = 0 }
        $0 ~ "^" fn "[(][)] [{$]" || $0 ~ "^" fn "[(][)]$" { in_fn = 1; print; next }
        in_fn && $0 ~ "^[A-Za-z_][A-Za-z0-9_]*[(][)] [{$]" { in_fn = 0; exit }
        in_fn { print }
    ' "$file"
}

start_seg="$(extract_fn  "$QC" cmd_start_qemu)"
deploy_seg="$(extract_fn "$QC" cmd_deploy_to_qemu)"
assert_true "extracted cmd_start_qemu body"   test -n "$start_seg"
assert_true "extracted cmd_deploy_to_qemu body" test -n "$deploy_seg"

# required: 两段都恰好一次经 module(带参数形避注释干扰, 对照 machine_resolve_surface.sh)
assert_eq "cmd_start_qemu calls resolve_qemu_port_reuse"   "$(grep -Fc 'resolve_qemu_port_reuse "$PIDFILE_SSH_PORT"' <<< "$start_seg")" 1
assert_eq "cmd_deploy_to_qemu calls resolve_qemu_port_reuse" "$(grep -Fc 'resolve_qemu_port_reuse "$old_ssh_port"' <<< "$deploy_seg")" 1

# forbidden: 两段不再内联注入 ritual(赋值到 QEMU_*_PORT 的旧形态)
for pat in 'QEMU_SSH_PORT="$PIDFILE' 'QEMU_SSH_PORT="$old' 'QEMU_HTTP_PORT="$PIDFILE' 'QEMU_HTTP_PORT="$old'; do
    assert_false "cmd_start_qemu drops inline $pat"   grep -Fq "$pat" <<< "$start_seg"
    assert_false "cmd_deploy_to_qemu drops inline $pat" grep -Fq "$pat" <<< "$deploy_seg"
done

assert_summary
```

- Change: 新增 surface gate，锁两调用点经 module + 无内联回潮。

- [ ] Step 4: 确认两 gate 通过。
- Run: `bash tests/protocol/qemu_restart_port_reuse.sh && bash tests/protocol/qemu_port_reuse_surface.sh; echo "rc=$?"`
- Expected: 退出 0，两 gate 全绿。
- [ ] Step 5: checkpoint commit。
- Run: `git add tests/protocol/qemu_restart_port_reuse.sh tests/protocol/qemu_port_reuse_surface.sh lib/qemu_commands.sh && git commit -m "refactor(qemu): wire start/deploy to resolve_qemu_port_reuse, unify cli_first (ADR-0022)"`

### Task 5: 路由表 + 覆盖矩阵登记（描述性 docs）

- 目标：让 WORKSPACE 路由表与 coverage 矩阵收录新 module。
- Files:
  - Modify: `rules/03_WORKSPACE.md`（lib 路由表，`:11` 长列表）
  - Modify: `tools/coverage_matrix.md`（start-qemu 段）
- 接口契约：Consumes `resolve_qemu_port_reuse`（Task 2）；Produces 无（纯描述）。
- 验证范围：两文件含新 module 条目；`tools/ob_check.sh` 的 know-how/结构检查不报新漂移。

- [ ] Step 1: 改动前检查——确认两文件尚未收录。
- Run: `grep -c qemu_port_reuse rules/03_WORKSPACE.md tools/coverage_matrix.md`
- Expected: 计数 `0`（未登记）。

- [ ] Step 2: （缺失状态即未登记。）

- [ ] Step 3: 登记两处。
- `rules/03_WORKSPACE.md` lib 路由表（`:11` 的 `lib/（…）` 列表）追加一项（与同族 `qemu_instance.sh` 等同形）：

```text
`qemu_port_reuse.sh` restart 端口复用注入 resolver（resolve_qemu_port_reuse, leaf-pure ADR-0022; 消费旧实例 4 端口 argv, cli_first 注入 QEMU_*_PORT + HTTP none sentinel; start-qemu/deploy-to-qemu 共享; 不含 interactive/check）
```

- `tools/coverage_matrix.md` start-qemu 段加一行（五档表）：

```text
| restart 端口复用注入（cli_first + HTTP none）| resolve_qemu_port_reuse | unit/qemu_port_reuse.sh | leaf-pure（ADR-0022）; cli_first 矩阵 + HTTP none sentinel |
```

- Change: 路由表 + 覆盖矩阵收录新 module。

- [ ] Step 4: 确认登记。
- Run: `grep -c qemu_port_reuse rules/03_WORKSPACE.md tools/coverage_matrix.md`
- Expected: 两文件各计数 `≥1`。

### Task 6: 最终验证——ob_check.sh + 全量 run_all.sh

- 目标：跑配套自检 + 全量快速三层，确认零回归。
- Files: 无（只读运行）。
- 接口契约：Consumes 全部前序产出；Produces「实现完成」信号。
- 验证范围：`tools/ob_check.sh` 退出 0；`tests/run_all.sh` 退出 0。

- [ ] Step 1: 改动前检查——确认尚未跑过配套自检。
- （本任务是首次全量自检。）

- [ ] Step 2: （同上。）

- [ ] Step 3: 跑配套自检 + 全量。
- Run: `tools/ob_check.sh && tests/run_all.sh`
- Expected: ob_check.sh 退出 0（结构 / 函数登记 / exit-contract Y 规则覆盖新 `qemu_port_reuse.sh` leaf-pure / run_all / know-how TL;DR 全过）。⚠️ 新增 `lib/qemu_port_reuse.sh` 使 flat 合成 shellcheck 的后续文件行号平移 → ob_check 判「良性差异」并**重写 `tests/.shellcheck-baseline`**（见 ob_check.sh:189-195）；属预期、须 commit（见 Step 5），非脏工作区。run_all.sh 退出 0（含新 unit + 两 protocol gate）。

- [ ] Step 4: 确认通过。
- Run: `tools/ob_check.sh; echo "ob_check=$?"; tests/run_all.sh; echo "run_all=$?"`
- Expected: 两 `rc=0`。
- [ ] Step 5: checkpoint commit。
- Run: `git add rules/03_WORKSPACE.md tools/coverage_matrix.md tests/.shellcheck-baseline && git commit -m "docs(qemu): register qemu_port_reuse module in routing + coverage (ADR-0022)"`
- 注：`tests/.shellcheck-baseline` 由本步 ob_check 良性重生成（新文件致行号平移）；逻辑上属 Task 2 新 module 的副作用，但首次 ob_check 运行在此，故并入此 commit。

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行，不要无声跳步、合并步或改变任务目标。
- 每完成一个任务，运行该任务定义的验证。
- Task 3 与 Task 4 之间存在预期红窗口（`qemu_restart_port_reuse.sh` 短暂红）；这是抽取中间态，不要在两任务之间跑全量，不要据此回滚。
- 遇阻塞、重复失败或计划与仓库现实不符，立即停下说明，不要猜。
- 若当前在 `main`/`master` 且用户未明确同意，开始实现前先确认分支；本任务建议在 `better-harness/score-fix-loop-2026-08-08` 或新 feature 分支上做。
- 全部任务完成后，运行最终验证并输出修改摘要。

## 最终验证

- `tools/ob_check.sh` → 退出 0（exit_contract Y 规则覆盖新 `qemu_port_reuse.sh` 且其无 exit）。
- `tests/run_all.sh` → 退出 0（含新 `tests/unit/qemu_port_reuse.sh` + 新 `tests/protocol/qemu_port_reuse_surface.sh` + 改写后的 `tests/protocol/qemu_restart_port_reuse.sh`，以及既有 orchestration 网 `tests/orchestration/start_qemu_force_restart.sh` / `tests/orchestration/qemu_restart_port_reuse.sh` 全绿）。
- 行为变更确认：deploy honor——`ob deploy-to-qemu --ssh-port N`（QEMU 在跑）现 honor N（由 module cli_first + surface gate 接线共同保证，无需独立 orchestration 用例）。

## 审阅 Checkpoint

- 计划正文结束。请先审阅这份计划；如无问题，下一步可按计划由普通编码 agent 或人工继续执行（默认执行方为普通编码 agent / 人工，不在本 skill 内切入编码）。
