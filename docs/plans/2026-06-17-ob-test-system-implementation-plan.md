# ob 测试体系 实施计划

## 目标

按冻结版设计 [`docs/specs/2026-06-17-ob-test-coverage-design.md`](../specs/2026-06-17-ob-test-coverage-design.md) 建立 `ob` 的四层测试体系（protocol/unit/orchestration/integration），迁移现有 3 个测试脚本并修硬编码路径，建两核心层覆盖度视图（checklist × xtrace 雷达）。完成后 `bash tests/run_all.sh` 作为每次改 `ob` 后的回归入口。

## 架构快照

- 测试用语义名四层目录组织：`tests/{protocol,unit,orchestration,integration}/`，共享 `tests/lib/`（加载器/断言/stub）与 `tests/fixtures/`。
- unit/orchestration 通过 `OB_NO_MAIN=1 source ob` 加载函数（沿用 smoke 已验证机制），不触发 main。
- orchestration 隔离靠 PATH 注入：加法 stub（fake git/bitbake/curl）+ 减法 PATH（`command -v` 缺失分支）+ 函数 override。
- 覆盖度靠两核心层交叉：功能点 checklist（`tools/coverage_matrix.md`，人声明）× xtrace 雷达（`tools/coverage_radar.py`，运行时实测）。kcov 可选附录。
- 衔接现有：`tests/smoke_ob.sh`→`tests/protocol/`、`tests/manual_matrix.exp`→`tests/protocol/`、`tests/manual_matrix_qemu.exp`→`tests/integration/`，逻辑不变仅迁移 + 改加载。

## 输入工件

- 设计文档：`docs/specs/2026-06-17-ob-test-coverage-design.md`（冻结版，三轮评审）
- 被测对象：`ob`（4104 行，92 函数，`tools/extract_funcs.py` 可枚举）
- 术语：见 [CONTEXT.md](../../CONTEXT.md) 的 test layer 词条

## 文件结构与职责

**Create**
- `tests/lib/{ob_loader.sh, assert.sh, stub.sh}` — 公共加载 / 断言 / PATH stub
- `tests/run_all.sh` — 分层调度入口（collect-all）
- `tests/fixtures/{source_lock.sample, local.conf.sample, bitbake-e.<machine>.txt, deps.json.sample}` — 测试样本（bitbake-e 带版本戳）
- `tests/protocol/exit_codes.sh` — protocol 层退出码补全
- `tests/unit/{url.sh, paths.sh, source_lock.sh, qemu_manifest.sh, ports.sh, parse_args.sh, require_path.sh, interact.sh}` — unit 层按模块
- `tests/orchestration/{resolve_qb_vars.sh, clone_sub_repos.sh, generate_config.sh, prerequisites_check.sh}` — orchestration 层高价值子集
- `tests/integration/init_build_e2e.sh` — init→build 全流程定期门禁
- `tools/{coverage_radar.py, coverage_matrix.md}` — xtrace 雷达 / 功能点 checklist
- `.github/workflows/ob-tests.yml` — CI（PR 跑 protocol–orchestration，cron 跑 integration）

**Modify（迁移，逻辑不变）**
- `tests/smoke_ob.sh` → `tests/protocol/smoke_ob.sh`（顺带修 :56 硬编码路径）
- `tests/manual_matrix.exp` → `tests/protocol/manual_matrix.exp`
- `tests/manual_matrix_qemu.exp` → `tests/integration/manual_matrix_qemu.exp`

**稳定边界**：`ob` 源码不改；现有 3 个测试脚本的 case 与退出码断言不变。

## 任务清单

### Task 1: 建 tests/lib/ob_loader.sh 加载器

- 目标：提供 `source` 后即得 `$OB` 路径 + ob 全部函数 + 关闭 errexit 泄漏的公共加载器。
- Files: Create `tests/lib/ob_loader.sh`
- 验证范围：`source` 该文件后 `type normalize_repo_url` 显示函数定义、`$OB` 指向仓库根 ob。

- [ ] Step 1: 写失败检查（加载器不存在）
```bash
test ! -f tests/lib/ob_loader.sh && echo "missing" || echo "exists"
```
- Run: `bash -c 'test ! -f tests/lib/ob_loader.sh'`
- Expected: 退出 0（文件不存在，待建）

- [ ] Step 2: 确认当前失败
- Run: `bash -c 'source tests/lib/ob_loader.sh'`
- Expected: 报 `No such file`（无加载器）

- [ ] Step 3: 写最小实现
```bash
#!/usr/bin/env bash
# tests/lib/ob_loader.sh — 加载 ob 函数(不触发 main),处理 set -euo 泄漏。
# source 本文件后: $OB 指向仓库根 ob,ob 全部函数可用,errexit 已关。
# 原理: OB_NO_MAIN=1 让 ob 尾部 main 守卫跳过(line 4102);
#       ob 顶部 set -euo pipefail 经 source 泄漏,这里关 errexit 防首个非零
#       assert 整批中止(smoke_ob.sh 已验证此解法,保留 nounset/pipefail)。
OB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OB="$OB_DIR/ob"
OB_NO_MAIN=1 source "$OB" || { echo "source ob failed" >&2; exit 1; }
set +e
```
- Change: 创建加载器，`OB_DIR` 用 `BASH_SOURCE` 相对推导（可移植，不硬编码）

- [ ] Step 4: 运行并确认通过
```bash
bash -c 'source tests/lib/ob_loader.sh && type normalize_repo_url >/dev/null && test -f "$OB" && echo OK'
```
- Expected: 输出 `OK`

- [ ] Step 5: checkpoint commit
- Run: `git add tests/lib/ob_loader.sh && git commit -m "test(ob): add ob_loader.sh shared loader"`

### Task 2: 建 tests/lib/assert.sh 断言库

- 目标：提供 `assert_eq/assert_match/assert_contains/assert_rc/assert_true/assert_false/assert_summary`，统一 PASS/FAIL 计数。
- Files: Create `tests/lib/assert.sh`
- 验证范围：`source` 后 `assert_eq "t" "a" "a"` 计 PASS=1、`assert_summary` 返回 0。

- [ ] Step 1: 失败检查
- Run: `bash -c 'test ! -f tests/lib/assert.sh'`
- Expected: 退出 0（待建）

- [ ] Step 2: 确认失败
- Run: `bash -c 'source tests/lib/assert.sh'`
- Expected: `No such file`

- [ ] Step 3: 写最小实现
```bash
#!/usr/bin/env bash
# tests/lib/assert.sh — 断言库。source 后用 assert_*;末尾 assert_summary 决定退出码。
ASSERT_PASS=0; ASSERT_FAIL=0
assert_reset()  { ASSERT_PASS=0; ASSERT_FAIL=0; }
_assert_ok()    { ASSERT_PASS=$((ASSERT_PASS+1)); echo "ok   $1"; }
_assert_bad()   { ASSERT_FAIL=$((ASSERT_FAIL+1)); echo "FAIL $1"; }
assert_eq()      { local l="$1" a="$2" e="$3"; [[ "$a" == "$e" ]] && _assert_ok "$l" || _assert_bad "$l (got '$a' want '$e')"; }
assert_match()   { local l="$1" a="$2" r="$3"; [[ "$a" =~ $r ]] && _assert_ok "$l" || _assert_bad "$l (got '$a' want /$r/)"; }
assert_contains(){ local l="$1" h="$2" n="$3"; [[ "$h" == *"$n"* ]] && _assert_ok "$l" || _assert_bad "$l (missing '$n')"; }
assert_true()    { local l="$1"; shift; if "$@"; then _assert_ok "$l"; else _assert_bad "$l"; fi; }
assert_false()   { local l="$1"; shift; if "$@"; then _assert_bad "$l"; else _assert_ok "$l"; fi; }
assert_rc() { # <exp_rc> <label> <cmd...>  子进程跑,断言退出码
    local exp="$1" l="$2"; shift 2; local rc=0; "$@" >/dev/null 2>&1 || rc=$?
    [[ "$rc" == "$exp" ]] && _assert_ok "$l (rc=$rc)" || _assert_bad "$l (rc=$rc want $exp)"
}
assert_summary() { echo ""; echo "PASS=$ASSERT_PASS FAIL=$ASSERT_FAIL"; [[ "$ASSERT_FAIL" -eq 0 ]]; }
```
- Change: 创建断言库

- [ ] Step 4: 确认通过
```bash
bash -c 'source tests/lib/assert.sh; assert_eq t a a; assert_false f false; assert_summary' ; echo "exit=$?"
```
- Expected: 末行 `exit=0`（PASS=2 FAIL=0）

- [ ] Step 5: checkpoint commit
- Run: `git add tests/lib/assert.sh && git commit -m "test(ob): add assert.sh assertion library"`

### Task 3: 建 tests/lib/stub.sh（PATH 注入 + 减法 PATH）

- 目标：提供 `mkfake_bin`（生成 fake 命令）、`with_stub`（当前 shell 前置 PATH 跑命令并恢复）、`empty_path`（减法 PATH 测 `command -v` 缺失分支）。
- Files: Create `tests/lib/stub.sh`
- 验证范围：`mkfake_bin` 造 fake `git` 后，`with_stub <dir> -- git foo` 输出被记录到 `<dir>/.git.calls`；`empty_path command -v git` 返回非 0。

- [ ] Step 3: 写最小实现
```bash
#!/usr/bin/env bash
# tests/lib/stub.sh — PATH 注入 stub 生成器 + 减法 PATH。
# mkfake_bin <dir> <cmd...>     在 <dir> 生成 fake 命令(记录调用,输出预设)
# stub_out   <dir> <cmd> <text> 设 fake <cmd> 的预设输出
# with_stub  <dir> -- <cmd...>  当前 shell 前置 PATH 跑 <cmd>,跑完恢复(函数调用可见)
# empty_path <cmd...>           减法 PATH: PATH=<空dir> 跑(测 command -v 缺失分支)
mkfake_bin() {
    local dir="$1"; shift; mkdir -p "$dir"
    local c
    for c in "$@"; do
        cat > "$dir/$c" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$dir/.$c.calls"        # 记录调用参数(供断言序列)
[[ -f "$dir/.$c.out" ]] && cat "$dir/.$c.out"   # 预设输出
[[ -f "$dir/.$c.sh" ]] && source "$dir/.$c.sh"  # 自定义逻辑(按 \$@ 分支,供失败路径)
[[ -f "$dir/.$c.rc" ]] && exit "\$(cat "$dir/.$c.rc")"  # 指定退出码
exit 0
STUB
        chmod +x "$dir/$c"
    done
}
stub_out()    { printf '%s' "$3" > "$1/.$2.out"; }   # fake <cmd> 输出 <text>
stub_script() { printf '%s\n' "$3" > "$1/.$2.sh"; }  # fake <cmd> source 自定义逻辑(按参数分支)。注意:失败路径须 `exit <rc>`,不要 `return <rc>`——source 的 return 后 fake 仍继续到 exit 0
stub_exit()   { printf '%s' "$3" > "$1/.$2.rc"; }    # fake <cmd> 返回 <rc>(失败路径)
with_stub() {
    local dir="$1"; shift; [[ "${1:-}" == "--" ]] && shift
    local _sp="$PATH"; PATH="$dir:$PATH"; "$@"; local _r=$?; PATH="$_sp"; return $_r
}
empty_path() {
    local _sp="$PATH"; PATH="$(mktemp -d)"; "$@"; local _r=$?; PATH="$_sp"; return $_r
}
```
- Change: 创建 stub 库；`with_stub`/`empty_path` 用 save/restore 避免污染当前 shell（因 ob 函数 source 在当前 shell，不能用子进程隔离 PATH）

- [ ] Step 4: 确认通过
```bash
bash -c '
source tests/lib/stub.sh
d=$(mktemp -d); mkfake_bin "$d" git
with_stub "$d" -- git clone url dst
test -f "$d/.git.calls" && grep -q "clone url dst" "$d/.git.calls" && echo STUB_OK
empty_path command -v git && echo HAS || echo MISSING
'
```
- Expected: `STUB_OK` 且 `MISSING`（减法 PATH 下 git 不可见）

- [ ] Step 5: checkpoint commit
- Run: `git add tests/lib/stub.sh && git commit -m "test(ob): add stub.sh PATH injection + empty-path"`

### Task 4: 建 tests/run_all.sh 调度入口

- 目标：按 protocol→unit→orchestration（可选 integration）顺序跑各层 `.sh`/`.exp`，collect-all 语义（遇失败记录继续，末尾汇总）。
- Files: Create `tests/run_all.sh`
- 验证范围：`bash tests/run_all.sh` 跑完所有层脚本并输出汇总；某层有失败时退出非 0 但仍跑完全部。

- [ ] Step 3: 写最小实现
```bash
#!/usr/bin/env bash
# tests/run_all.sh — 分层调度入口。collect-all: 跑完全部再汇总失败。
# 用法: tests/run_all.sh [--integration]
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR/.."   # 切到仓库根,使 expect 脚本的 `spawn ./ob` 成立
INTEGRATION=0; [[ "${1:-}" == "--integration" ]] && INTEGRATION=1
LAYERS=(protocol unit orchestration); [[ "$INTEGRATION" == 1 ]] && LAYERS+=(integration)
FAILED=()
for layer in "${LAYERS[@]}"; do
    echo "=== $layer ==="
    shopt -s nullglob
    for f in "tests/$layer"/*.sh "tests/$layer"/*.exp; do
        if [[ "$f" == *.exp ]]; then
            command -v expect >/dev/null 2>&1 || { echo "skip $f (no expect)"; continue; }
            if expect "$f" >/dev/null 2>&1; then echo "ok   $(basename "$f")"; else echo "FAIL $(basename "$f")"; FAILED+=("$f"); fi
        else
            if bash "$f"; then echo "ok   $(basename "$f")"; else echo "FAIL $(basename "$f")"; FAILED+=("$f"); fi
        fi
    done
    shopt -u nullglob
done
echo ""
if (( ${#FAILED[@]} > 0 )); then echo "FAILED (${#FAILED[@]}):"; printf '  %s\n' "${FAILED[@]}"; exit 1; fi
echo "ALL GREEN"
```
- Change: 创建调度入口，collect-all 语义（无 `set -e`，失败入 `FAILED[]` 继续）

- [ ] Step 4: 确认通过
- Run: `bash tests/run_all.sh; echo "exit=$?"`
- Expected: 此时 protocol 层尚空（迁移前）→ `ALL GREEN` 或仅跑现有目录；待 Task 6 迁移后 protocol 有内容。退出码 0。

- [ ] Step 5: checkpoint commit
- Run: `git add tests/run_all.sh && git commit -m "test(ob): add run_all.sh collect-all dispatcher"`

### Task 5: 建 tools/coverage_radar.py + xtrace spike

- 目标：复用 `extract_funcs.py` 边界逻辑枚举 92 函数；spike 验证 `BASH_XTRACEFD` + `PS4='@@${FUNCNAME[0]}@@ '` 对子 shell/命令替换的 transitive 捕获；产出函数级覆盖矩阵。
- Files: Create `tools/coverage_radar.py`
- 验证范围：spike 确认子 shell 内函数调用被 xtrace 捕获（设计未决事项 2）；雷达对一个含 `select_from_list` 调用的 trace 能识别它。

- [ ] Step 1: spike 直接调用捕获（设计未决事项 2）
  - **注意**：PS4 必须延迟展开——赋值时不能让 `${FUNCNAME[0]}` 展开。双引号 `"@@${FUNCNAME}@@"` 会在赋值时展开成 `main`，PS4 变固定串、xtrace 每行都打 `@@main@@`，grep `@@g@@` 恒为 0、误判 xtrace 不可用。须用转义单引号让 PS4 字面含 `${FUNCNAME[0]}`。
- Run: `bash -c 'PS4='\''@@${FUNCNAME[0]:-main}@@ '\''; set -x; f(){ g; }; g(){ :; }; f; set +x' 2>&1 | grep -c '@@g@@'`
- Expected: 输出 ≥1，证明直接调用被捕获
- [ ] Step 2: spike 子 shell transitive（关键未决项）
- Run: `bash -c 'PS4='\''@@${FUNCNAME[0]:-main}@@ '\''; set -x; g(){ :; }; f(){ x=$(g); }; f; set +x' 2>&1 | grep -c '@@g@@'`
- Expected: ≥1 则子 shell transitive 可捕获（方案成立）；=0 则退人工声明矩阵（见 Step 3 退路）。注意命令替换输出可能出现 `@@@g@@`（重复 PS4 首字符），parser 用 `@@(\w+)@@` 提取时按 `@@` 边界去重。

- [ ] Step 3: 写最小实现（按 spike 结果）
  - 若 spike 通过：生产实现用 `BASH_XTRACEFD=3` 导独立 fd（避免污染 stdout/stderr），PS4 用 `@@${FUNCNAME[0]:-main}@@ `（**延迟展开**，赋值时不展开 `${FUNCNAME}`）；解析 trace 用正则 `@@(\w+)@@` 取唯一函数集（命令替换可能产生 `@@@g@@`，按 `@@` 边界去重），与 `extract_funcs` 92 函数求交，输出矩阵 + 未覆盖清单 + 覆盖率%，区分"显式 target"vs"transitive 无主"（presentation/logging 档）。
  - 若 spike 失败：雷达数据源退人工声明（读 `tools/coverage_matrix.md` 的函数-功能点映射），标注"非运行时实测"。
  - 复用 `tools/extract_funcs.py` 的边界提取逻辑（import 或内联，改判定需两处同步）。
- Change: 创建雷达脚本；spike 结果写入 `coverage_radar.py` 顶部注释（"xtrace 子 shell transitive: 已验证/退人工"）

- [ ] Step 4: 确认通过
- Run: `echo '@@normalize_repo_url@@ @@main@@' | python3 tools/coverage_radar.py -`
- Expected: 输出含 `normalize_repo_url` 标记已覆盖、`TOTAL 92`、覆盖率%（从 stdin 读 trace，避免依赖 bash process substitution）

- [ ] Step 5: checkpoint commit
- Run: `git add tools/coverage_radar.py && git commit -m "test(ob): add coverage_radar.py xtrace function radar"`

### Task 6: 迁移 smoke_ob.sh → protocol/（示范，修硬编码路径）

- 目标：把 `tests/smoke_ob.sh` 迁到 `tests/protocol/smoke_ob.sh`，改用 `ob_loader.sh`，删除 :56 硬编码 `source /bmc/iasi/ob-harness/ob`，case 与退出码断言不变。
- Files: Create `tests/protocol/smoke_ob.sh`；Modify（删除原）`tests/smoke_ob.sh`
- 验证范围：`bash tests/protocol/smoke_ob.sh` 输出与原版一致的 PASS/FAIL，且仓库挪位置后仍跑通。

- [ ] Step 1: 失败检查（迁移目标不存在 + 原版硬编码仍在）
- Run: `grep -n '/bmc/iasi/ob-harness/ob' tests/smoke_ob.sh`
- Expected: 命中 `:56`（硬编码 bug 待修）

- [ ] Step 2: 确认原版当前能跑（基线）
- Run: `bash tests/smoke_ob.sh; echo "exit=$?"`
- Expected: `PASS=4 FAIL=0`，exit=0

- [ ] Step 3: 迁移 + 修硬编码
  - 复制 `tests/smoke_ob.sh` → `tests/protocol/smoke_ob.sh`
  - 头部加载段改为 `source "$(dirname "$0")/../lib/ob_loader.sh"`，删掉自带的 `OB=...` 与 `OB_NO_MAIN=1 source "$OB"`（由 ob_loader 统一）
  - :56 的 `bash -c '... source /bmc/iasi/ob-harness/ob ...'` 改为用 `$OB`：`bash -c 'OB_NO_MAIN=1 source "$1"; set +e; parse_args build; cmd_build' _ "$OB"`（`$OB` 由 ob_loader 提供，可移植）
  - 删除原 `tests/smoke_ob.sh`
- Change: 迁移 + 修硬编码路径（`$OB` 替代绝对路径）

- [ ] Step 4: 确认通过 + 可移植性
- Run: `bash tests/protocol/smoke_ob.sh; echo "exit=$?"`
- Expected: `PASS=4 FAIL=0`，exit=0（与基线一致）

- [ ] Step 5: checkpoint commit
- Run: `git add tests/protocol/smoke_ob.sh tests/smoke_ob.sh && git commit -m "test(ob): move smoke_ob.sh to protocol/, fix hardcoded ob path"`

### Task 7: 迁移 manual_matrix.exp + manual_matrix_qemu.exp

- 目标：迁 `manual_matrix.exp`→`tests/protocol/`、`manual_matrix_qemu.exp`→`tests/integration/`，脚本内 `./ob` 相对路径不变（expect 从仓库根跑），仅改位置。
- Files: Create `tests/protocol/manual_matrix.exp`、`tests/integration/manual_matrix_qemu.exp`；删原文件
- 验证范围：`expect tests/protocol/manual_matrix.exp` 与原版输出一致（非 TTY/菜单段全绿；取消段按 workspace 有无 skip/green）。

- [ ] Step 1: 失败检查
- Run: `test -f tests/manual_matrix.exp && echo "原位仍在"`
- Expected: 原位仍在（待迁）

- [ ] Step 2: 基线
- Run: `expect tests/manual_matrix.exp; echo "exit=$?"`
- Expected: 非 TTY/菜单段 green，取消段 skip 或 green

- [ ] Step 3: 迁移（内容不变，仅移动）
  - `git mv tests/manual_matrix.exp tests/protocol/manual_matrix.exp`
  - `git mv tests/manual_matrix_qemu.exp tests/integration/manual_matrix_qemu.exp`
  - 两者 `spawn ./ob` 依赖从仓库根运行——在 `run_all.sh`（Task 4）里 expect 调用已处理路径；若手动跑需 `cd` 仓库根。脚本顶部注释补一句"从仓库根运行"。
- Change: 移动两个 expect 脚本到对应层

- [ ] Step 4: 确认通过
- Run: `expect tests/protocol/manual_matrix.exp; echo "exit=$?"`
- Expected: 与 Step 2 基线一致

- [ ] Step 5: checkpoint commit
- Run: `git add -A && git commit -m "test(ob): move expect matrices to protocol/ and integration/"`

### Task 8: 建 tests/unit/url.sh（unit 示范）

- 目标：unit 层第一个测试，示范加载模式 + 真实 case，覆盖 `normalize_repo_url`/`is_valid_repo_url`/`derive_source_label`。
- Files: Create `tests/unit/url.sh`
- 验证范围：`bash tests/unit/url.sh` 全绿；雷达显示这 3 函数被覆盖。

- [ ] Step 1: 失败检查（函数未覆盖）
- Run: `python3 tools/coverage_radar.py <(true) 2>/dev/null | grep -E 'normalize_repo_url' || echo "无 trace:预期未覆盖"`
- Expected: 未覆盖（待建测试）

- [ ] Step 2: 确认函数可加载
- Run: `bash -c 'source tests/lib/ob_loader.sh; type normalize_repo_url >/dev/null && echo LOADABLE'`
- Expected: `LOADABLE`

- [ ] Step 3: 写最小实现
```bash
#!/usr/bin/env bash
# tests/unit/url.sh — 纯逻辑函数单测(示范加载模式)。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# normalize_repo_url: 去协议/.git/尾斜杠 + lowercase + port 处理
assert_eq "norm https"   "$(normalize_repo_url 'https://GitHub.com/OpenBMC/openbmc.git')" 'github.com/openbmc/openbmc'
assert_eq "norm git@"    "$(normalize_repo_url 'git@github.com:openbmc/openbmc.git')"     'github.com/openbmc/openbmc'
assert_eq "norm slash"   "$(normalize_repo_url 'https://github.com/openbmc/openbmc/')"    'github.com/openbmc/openbmc'

# is_valid_repo_url (return 0/1)
assert_true  "valid https"  is_valid_repo_url 'https://x'
assert_true  "valid git@"   is_valid_repo_url 'git@h:p.git'
assert_false "invalid bare" is_valid_repo_url 'not-a-url'

# derive_source_label: 依 OPENBMC_REPO_URL 推 community/custom(设全局 SOURCE_LABEL)
OPENBMC_REPO_URL='https://github.com/openbmc/openbmc.git';  derive_source_label
assert_eq "label community" "$SOURCE_LABEL" 'community'
OPENBMC_REPO_URL='https://gitlab.example.com/team/openbmc.git'; derive_source_label
assert_eq "label custom"    "$SOURCE_LABEL" 'custom'

assert_summary
```
- Change: 创建 url.sh 示范（加载模式 + assert 用法 + 全局变量喂入）

- [ ] Step 4: 确认通过
- Run: `bash tests/unit/url.sh; echo "exit=$?"`
- Expected: PASS=8 FAIL=0，exit=0

- [ ] Step 5: checkpoint commit
- Run: `git add tests/unit/url.sh && git commit -m "test(ob): add unit/url.sh (normalize_repo_url/is_valid_repo_url/derive_source_label)"`

### Task 9: 建 tests/unit/paths.sh

- 目标：覆盖 `derive_bitbake_git_mirror_path`/`derive_qemu_url_config_path`/`detect_harness_root`/`detect_wsl`。
- Files: Create `tests/unit/paths.sh`
- 验证范围：全绿；覆盖设计 unit 明细"纯逻辑/路径"类。

- [ ] Step 1/2: 失败检查 + 可加载（同 Task 8 模式，函数名换 `derive_bitbake_git_mirror_path` 等）
- [ ] Step 3: 按 Task 8 模式建文件，覆盖：
  - `derive_bitbake_git_mirror_path <refroot> <src_uri>`：SRC_URI 带分号（`;branch=main` 截断）、带 netloc、空输入→非 0
  - `derive_qemu_url_config_path`：依赖 `WORKSPACE_DIR` 全局，输出 `qemu-bin/qemu-binary-urls.conf` 形态
  - `detect_harness_root`：tmpdir 喂入，断言定位
  - `detect_wsl`：断言当前环境返回值（mock `/proc/sys/kernel/osrelease` 较重，可仅测非 WSL 路径或 skip）
- Change: 创建 paths.sh
- [ ] Step 4: `bash tests/unit/paths.sh` 全绿
- [ ] Step 5: commit `test(ob): add unit/paths.sh`

### Task 10: 建 tests/unit/source_lock.sh（文件IO）

- 目标：覆盖 `read_kv_field`/`read_lock_field`/`read_source_label`/`write_source_lock`（含 DRY_RUN 分支），用 tmpdir + fixture。
- Files: Create `tests/unit/source_lock.sh`、`tests/fixtures/source_lock.sample`
- 验证范围：tmpdir 喂 fixture 后读出正确；`write_source_lock` 写出的文件含正确字段；DRY_RUN 分支不写文件。

- [ ] Step 1/2: 失败检查 + 可加载
- [ ] Step 3: 按 Task 8 模式建文件，覆盖：
  - `read_kv_field <file> <key>`：key 存在/不存在/文件缺失（return 1）、key 含点号（`\\.` 转义）
  - `read_source_label`：`SOURCE_LOCK_FILE` 喂 fixture → 读出 `community`；无文件 → 默认 `community`
  - `write_source_lock`：设 `CONFIGS_DIR`/`SOURCE_LOCK_FILE`/`OPENBMC_REPO_URL`/`MACHINE` 全局到 tmpdir，DRY_RUN=1 断言不写文件、DRY_RUN=0 断言写出 `normalized_source`/`source_label`/`machine_first_init` 字段
  - fixture `source_lock.sample`：含 `source_label=community` 等样本行
- [ ] Step 4: `bash tests/unit/source_lock.sh` 全绿
- [ ] Step 5: commit `test(ob): add unit/source_lock.sh + fixture`

### Task 11: 建 tests/unit/qemu_manifest.sh（文件IO）

- 目标：覆盖 `write_qemu_url_config`/`write_qemu_binary_manifest`/`write_qemu_pcbios_manifest`/`read_qemu_url_config`，断言写出文件内容。
- Files: Create `tests/unit/qemu_manifest.sh`
- 验证范围：全绿；写出的 manifest 含 url/sha256/jenkins build number 等字段。
- [ ] Step 3: 按 Task 8 模式，tmpdir 喂全局变量，断言各 `write_*` 产出文件的关键字段；`read_qemu_url_config` 往返一致。
- [ ] Step 4/5: 全绿 + commit `test(ob): add unit/qemu_manifest.sh`

### Task 12: 建 tests/unit/ports.sh（mock ss/lsof）

- 目标：覆盖 `get_port_occupants`/`check_ports_available`/`validate_pid`，用 stub.sh 的 fake `ss`/`lsof` 或 tmpdir 假 PID 文件。
- Files: Create `tests/unit/ports.sh`
- 验证范围：全绿；端口占用/空闲分支、PID 文件有效/失效分支。
- [ ] Step 3: 按 Task 8 模式 + `stub.sh`：`mkfake_bin` 造 fake `ss`（`stub_out` 设占用/空闲两种输出），测 `get_port_occupants`/`check_ports_available` 退出码分支；`validate_pid` 用 tmpdir 造/不造 PID 文件。
- [ ] Step 4/5: 全绿 + commit `test(ob): add unit/ports.sh`

### Task 13: 建 tests/unit/parse_args.sh + require_path.sh（exit 函数）

- 目标：覆盖 `parse_args` 全选项组合（exit 函数，子进程捕获退出码）+ `require_path`/`fn_quit`。
- Files: Create `tests/unit/parse_args.sh`、`tests/unit/require_path.sh`
- 验证范围：`parse_args` 各分支退出码 0/1；`require_path` 路径缺失→exit 指定码。
- [ ] Step 3: 用 `assert_rc` 在子进程跑（exit 函数不能在当前 shell 直接调，会 exit 整个测试）：
  - `parse_args.sh`：`--help`(0)/每个子命令名/`--url`(缺值→1)/`--ssh-port`(缺值→1)/unknown opt(1)/无参(COMMAND 空)
  - `require_path.sh`：`require_path <missing> <label> '' 3` → exit 3；路径存在 → return 0 不 exit
- [ ] Step 4/5: 全绿 + commit `test(ob): add unit/parse_args.sh + require_path.sh`

### Task 14: 建 tests/unit/interact.sh（交互叶子函数 stdin 喂入）

- 目标：覆盖 `select_from_list`/`confirm_action`/`prompt_for_absolute_path`/`prompt_for_available_port`，用 `printf 'n\n' | func` 喂 stdin。
- Files: Create `tests/unit/interact.sh`
- 验证范围：全绿；各函数分支（confirm Y→0/N→2、select 0→2/有效→0/无效重试、path 空/选项/非绝对→重试）。
- [ ] Step 3: 按 Task 8 模式，stdin 喂入测分支；**caution**：管道喂足输入行 + 末尾 `< /dev/null` 兜底防 EOF 挂起（设计要求）。例：`printf 'n\n' | confirm_action init machine` → return 2。
- [ ] Step 4/5: 全绿 + commit `test(ob): add unit/interact.sh (stdin-driven)`

### Task 15: 建 tests/protocol/exit_codes.sh（L0 退出码补全，隔离 workspace）

- 目标：覆盖全子命令 × 分支退出码（设计退出码协议表），补 status/start-qemu/stop-qemu 前提分支。
- Files: Create `tests/protocol/exit_codes.sh`
- 验证范围：退出码表所有行被断言；**必须隔离 workspace**（见 Step 3），否则绑定真实仓库状态、结果环境相关。
- [ ] Step 1: 读码核对 cmd_status/cmd_stop_qemu 空 workspace 行为
- Run: `sed -n '3014,3081p;3579,3650p' ob | grep -nE 'exit|return|init-done|\.pids'`
- Expected: 确认 status 空工作区无 exit（=0）、stop-qemu 无实例无 exit（=0）；init/build/start-qemu 仍为 3
- [ ] Step 3: **隔离策略（关键）**：直接跑 `ob <cmd>` 会绑定真实仓库 workspace（若真实 `.pids/` 有实例，stop-qemu 结果环境相关）。每个 case 在子进程 `OB_NO_MAIN=1 source "$OB"` 后 **override `detect_harness_root()`** 指向 tmpdir 空工作区（`HARNESS_ROOT=...; WORKSPACE_DIR=.../workspace; CONFIGS_DIR=.../workspace/configs; QEMU_PIDS_DIR=...`），再 `parse_args <cmd>` + 对应 `cmd_*`，非 TTY（`</dev/null`）触发前提分支。预期（评审实测，已更新设计退出码表）：`status` 空工作区=0、`stop-qemu` 无实例=0、`build`/`start-qemu` 空工作区=3、`init` 非 TTY=3、取消分支=2。
- [ ] Step 4: `bash tests/protocol/exit_codes.sh` 全绿 + commit `test(ob): add protocol/exit_codes.sh (workspace-isolated)`

### Task 16: shellcheck 防退化（工具检查 + gcc 格式 baseline diff）

- 目标：`shellcheck ob` 纳入 run_all 作**防退化基线**（不永久红），因 `shellcheck ob` 实测 rc=1 且本计划不改 ob。
- Files: Modify `tests/run_all.sh`（加 baseline diff）；Create `tests/.shellcheck-baseline`（`shellcheck -f gcc ob` 输出快照）
- 验证范围：shellcheck 缺失→FAIL；存在→当前 `-f gcc` 输出无新增行（diff baseline）才 ok；既有 warning 不阻断。
- [ ] Step 1: 基线
- Run: `shellcheck -f gcc ob | tee tests/.shellcheck-baseline | wc -l; echo "exit=${PIPESTATUS[0]}"`
- Expected: 记录当前 gcc 格式 SC 输出作 baseline（rc 非 0 是已知，不阻断）
- [ ] Step 3: run_all.sh 加 wrapper：**先 `command -v shellcheck >/dev/null 2>&1 || { echo "FAIL shellcheck 未安装"; FAILED+=("shellcheck"); continue; }`**（shellcheck 缺失时 `wc -l` 行数少会误判 OK，必须显式检查）；再 `shellcheck -f gcc ob > /tmp/sc.new 2>&1; if ! diff -u tests/.shellcheck-baseline /tmp/sc.new >/dev/null; then echo "FAIL shellcheck regressed"; FAILED+=("shellcheck"); fi`（gcc 格式每问题一行，diff 精确识别新增而非只比行数）。`.shellcheck-ignore` 非原生故用 baseline diff；`# shellcheck disable=` 需改 ob，本计划不动。
- [ ] Step 4: `bash tests/run_all.sh` 不因 shellcheck 永久红（baseline 内 ok）+ commit `test(ob): wire shellcheck gcc-baseline diff into run_all.sh`

### Task 17: 建 fixtures/bitbake-e 样本 + tests/orchestration/resolve_qb_vars.sh

- 目标：抓真实 `bitbake -e` 输出作 fixture（带版本戳），mock bitbake 测 `resolve_qb_vars` 解析。
- Files: Create `tests/fixtures/bitbake-e.<machine>.txt`、`tests/orchestration/resolve_qb_vars.sh`
- 验证范围：fake `bitbake -e` 喂 fixture 后，`resolve_qb_vars` 解析出 QB_MACHINE/QB_MEM/QB_SYSTEM 正确。
- [ ] Step 1: 抓样本（需 workspace）
- Run: `cd workspace/openbmc && source setup <machine> <build> && bitbake -e > /tmp/bitbake-e.txt`（从现有 init+build 过的 machine 抓）
- Expected: 产出完整 bitbake -e 输出
- [ ] Step 3: fixture 头部加版本戳（`# ob-commit=<sha> machine=<m> bitbake=<ver>`）；`resolve_qb_vars.sh` 用 `mkfake_bin` 造 fake `bitbake`（`stub_out` 喂 fixture），设 `OPENBMC_DIR`/`MACHINE`/`BUILD_DIR` 全局，断言解析出的 QB_* 变量。
- [ ] Step 4/5: 全绿 + commit `test(ob): add orchestration/resolve_qb_vars.sh + bitbake-e fixture`
- **fixture 陈旧检测**：`tools/coverage_radar.py` 或独立脚本定期比对 fixture 版本戳与真实 workspace，失真告警（写入脚本注释与 run_all 的 warn 段）。

### Task 18: 建 tests/orchestration/clone_sub_repos.sh

- 目标：fake `git clone`（成功/失败/mirror 命中），测 `clone_sub_repos` 循环 + URL 处理 + mirror 去重逻辑。
- Files: Create `tests/orchestration/clone_sub_repos.sh`、`tests/fixtures/deps.json.sample`
- 验证范围：全绿；fake git 调用记录显示正确的 URL/目标路径序列；mirror 命中时跳过 clone。
- [ ] Step 3: `mkfake_bin` 造 fake `git`，用 Task 3 扩展的 `stub_script` 实现"git config 成功 / git clone --bare 失败"等参数分支、`stub_exit` 控返回码；喂 `deps.json.sample`（含多条 SRC_URI）；断言 clone 调用序列、mirror 去重、失败 fallback 路径。
- [ ] Step 4/5: 全绿 + commit `test(ob): add orchestration/clone_sub_repos.sh`

### Task 19: 建 tests/orchestration/generate_config.sh（lockfile + build_config）

- 目标：mock 上游依赖，测 `generate_lockfile`/`generate_build_config` 输出文件格式。
- Files: Create `tests/orchestration/generate_config.sh`
- 验证范围：全绿；产出 lockfile/build_config 含正确字段。
- **残余风险（设计错误处理表）**：mock 掉后不验证产物能否喂真实 bitbake——本 Task 只测格式，产物有效性靠 Task 22 integration 兜底，test 顶部注释写明。
- [ ] Step 3: mock 上游（依赖已 init 的全局态），断言 `generate_lockfile`/`generate_build_config` 写出的文件关键字段。
- [ ] Step 4/5: 全绿 + commit `test(ob): add orchestration/generate_config.sh`

### Task 20: 建 tests/orchestration/prerequisites_check.sh（选择性缺工具）

- 目标：测 `prerequisites_check` 的工具缺失分支（line 2270-2274 `command -v`）。
- Files: Create `tests/orchestration/prerequisites_check.sh`
- 验证范围：选择性缺 git/python3 → exit 3 且 stderr 含 "Required tool not found"；工具齐全 → 通过。
- [ ] Step 1: 读码确认检查的工具清单与提示语
- Run: `sed -n '2259,2300p' ob | grep -nE 'command -v|Required tool|exit'`
- Expected: 确认被检查工具（git/python3/…）与缺失提示语
- [ ] Step 3: **不能用 `empty_path`**（`PATH=<空dir>` 会让 uname 等先消失，失败在 OS check 而非工具检查，假绿）。改选择性 PATH：建 tmpbin，symlink 必要命令（uname/python3 等从 /usr/bin），**不放 git**，`PATH=$tmpbin` 跑 prerequisites_check，断言 exit 3 且 stderr 含 "Required tool not found: git"（按 Step 1 实际提示语）。同样手法测 python3 缺失分支。
- [ ] Step 4/5: 全绿 + commit `test(ob): add orchestration/prerequisites_check.sh (selective missing tool)`

### Task 21: 建 tools/coverage_matrix.md + 雷达交叉校验

- 目标：功能点 checklist（子命令 × 行为，每条声明涉及函数 + 覆盖它的 test）；`coverage_radar.py` 增交叉校验模式——checklist 标"已覆盖"但雷达无函数命中则报警。
- Files: Create `tools/coverage_matrix.md`；Modify `tools/coverage_radar.py`（加 `--cross-check`）
- 验证范围：matrix 覆盖 5 关键功能（init/build/status/start-qemu/stop-qemu）；交叉校验无矛盾。
- [ ] Step 3: `coverage_matrix.md` 按子命令 × 行为列功能点（粗粒度，如"init: machine 选择""start-qemu: 端口分配"），每条标涉及函数 + test 文件；雷达 `--cross-check` 读 matrix 与运行时覆盖比对，输出矛盾清单。
- [ ] Step 4: `python3 tools/coverage_radar.py --cross-check` 无矛盾（或矛盾均有合理解释）+ commit `test(ob): add coverage_matrix.md + radar cross-check`

### Task 22: 建 tests/integration/ E2E（init dry-run + expect 驱动 build）

- 目标：integration 层验证 init 预览 + 真实 build 产物。**`cmd_build` 非 TTY 会 exit 3**（交互选 machine），故 build 部分需 expect 驱动；`init -d` 仅 dry-run、不准备 workspace。拆两段：
- Files: Create `tests/integration/init_dryrun_sanity.sh`、`tests/integration/build_e2e.exp`
- 验证范围：init dry-run 在预置 workspace 打印 8 步预览（exit 0）；build_e2e.exp 在预初始化 machine 上 expect 驱动选 machine + confirm，产出 `<machine>.static.mtd`。
- [ ] Step 1: 确认 build 的 TTY/交互依赖
- Run: `sed -n '3083,3160p' ob | grep -nE '\[\[ -t|select_from_list|confirm_action'`
- Expected: 确认 cmd_build 的交互点（需 expect 喂入）
- [ ] Step 3:
  - `init_dryrun_sanity.sh`：bash 跑 `ob init <machine> -d`（dry-run 非 TTY 安全），断言输出含 8 步预览、exit 0。
  - `build_e2e.exp`：expect 驱动——前置检查 `<machine>.init-done` 存在（无则 skip+warn）；`spawn ./ob build` → 喂 machine 选择 + confirm → 等 build 完成 → 断言 `workspace/.../images/*/*.static.mtd` 存在。顶部注释写明"定期门禁/手动，资源重，需预初始化 machine"。
- [ ] Step 4: 本地预置 workspace 跑两段通（或 skip）+ commit `test(ob): add integration init dry-run sanity + expect-driven build E2E`

### Task 23: CI workflow + pre-commit 提醒点

- 目标：`.github/workflows/ob-tests.yml`（PR/push 跑 protocol–orchestration；cron 跑 `--integration`）；pre-commit 自动提醒点（protocol+unit 秒级）——若无 pre-commit 基建则诚实记录为未决，不造假门禁。
- Files: Create `.github/workflows/ob-tests.yml`；可选 Create `.git/hooks/pre-commit` 或 `.pre-commit-config.yaml`（取决于未决事项 4 核查结果）
- 验证范围：workflow 语法合法；PR 跑 run_all（不含 integration）。
- [ ] Step 1: 核查未决事项 4
- Run: `ls .pre-commit-config.yaml .git/hooks/pre-commit 2>/dev/null; echo "---"`
- Expected: 确认是否有现成 pre-commit 基建
- [ ] Step 3: workflow PR job 跑 `bash tests/run_all.sh`，cron job 跑 `bash tests/run_all.sh --integration`（需 self-hosted runner，无则 cron job 仅跑 protocol–orchestration 并注释说明）；pre-commit 若有基建则挂 run_all 的 protocol+unit，否则在 AGENTS.md/README 记录"手动跑 run_all 作提醒点"。
- [ ] Step 4: workflow 语法 `actionlint .github/workflows/ob-tests.yml`（若有）或 YAML 校验 + commit `test(ob): add CI workflow + regression reminder`

## 执行纪律

- **实现前复查整份计划**：发现缺项、矛盾、命名不一致或验证命令无效，先修计划再动手。
- **按 Task 顺序执行**，不无声跳步、合并步或改任务目标；Task 间有依赖（lib 先于测试，url.sh 示范先于其他 unit）。
- **每完成一个 Task 跑该 Task 的验证**（Step 4），不绿不进下一个。
- **遇阻立即停下说明**：bitbake-e fixture 抓不到（无 workspace）、xtrace spike 失败、CI runner 跑不动 QEMU 等，停下报告，不猜、不伪造绿。
- **当前分支 `refactor/ob-cleanup` 非 main**，实现在此分支进行；若需另开分支先确认。
- **checkpoint commit 视执行 agent 权限**：各 Task Step 5 的 `git commit` 需执行 agent 有提交权限；若执行 agent 不允许主动 commit，改成 `git status` + `git diff` 留痕 checkpoint（不阻断，仅记录进度）。
- **全部完成后跑最终验证**并输出修改摘要。

## 最终验证

- Run: `bash tests/run_all.sh`
- Expected: `ALL GREEN`（protocol + unit + orchestration 全绿，collect-all 汇总无 FAILED）
- Run: `python3 tools/coverage_radar.py`（配合 run_all 的 xtrace 采集）
- Expected: unit 范围（~40 函数）覆盖率 ≥ 95%；presentation/logging 档标为 transitive 无主（良性）
- Run: `python3 tools/coverage_radar.py --cross-check`
- Expected: checklist × 雷达无未解释矛盾
- Run: `command -v shellcheck >/dev/null && shellcheck -f gcc ob > /tmp/sc.final 2>&1 && diff -u tests/.shellcheck-baseline /tmp/sc.final; echo "exit=$?"`
- Expected: diff 无新增行（exit=0）；既有 SC warning 不阻断，仅防退化（与 Task 16 一致）
- Run（mutation 抽查，设计测试策略）: 临时改 `ob` 的 `normalize_repo_url`（如把 `${normalized,,}` 改成不 lowercase），`bash tests/unit/url.sh` 应 FAIL；改回后 GREEN。每层抽 1-2 个代表性函数同理。
- Expected: 注入 bug 后对应层变红，证明测试有敏感度
- Run: `bash tests/run_all.sh --integration`（本地预置 workspace，分钟~小时级）
- Expected: integration 层 green 或 skip（无 workspace）

## 审阅 Checkpoint

- 计划正文结束。请先确认这份计划；如无问题，下一步可按计划由普通编码 agent 或人工继续执行。
- 注意 Task 5（xtrace spike）、Task 15/23（读码核对退出码、核查 pre-commit 基建）含设计未决事项的实证环节，结果可能反向影响计划（如 spike 失败则雷达退人工声明），执行时按实际结果调整并在该 Task 注释记录。
