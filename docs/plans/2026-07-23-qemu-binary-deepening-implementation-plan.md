# qemu_binary.sh god-function 深化实施计划

## 目标

- 把 `lib/qemu_binary.sh` 的两个未测 god-function 深化成可测结构，闭合 `tools/coverage_matrix.md:76-77` 全表仅剩的两个覆盖 test 完全留空的硬盲区。
- `download_and_replace_community_qemu` 拆成 acquire/commit 切面（`_dlqbc_stage_binary` + `_replace_community_binary`），flock 留 wrapper，让 swap-fail-rollback 不变量可机器验证。
- `ensure_qemu_binary_custom` 的纯路径解析抽成 leaf-pure（`resolve_custom_binary_candidate` / `resolve_custom_pcbios_candidate`），交互循环留 wrapper。
- 顺手把 jenkins job_url 的 magic regex 去重成 `jenkins_job_url_from_url`。

## 架构快照

- **现状**：`download_and_replace_community_qemu`(qemu_binary.sh:151-223) 把 flock→download→verify→backup→swap→rollback→manifest→cleanup 7 步线性串联在一个函数、一把 flock 包全程；`ensure_qemu_binary_custom`(417-524) 把纯路径解析（dir→补 arch、`ast27x0_bootrom.bin` 查找 + `pc-bios/` 子目录回退）埋在两段 `while true; prompt` 交互循环里。两者都是 coverage 盲区。
- **本次方案**：
  - **事务切面**：wrapper `download_and_replace_community_qemu` 退化为 flock 编排——acquire 段（`_dlqbc_stage_binary`: download_qemu_binary_core + chmod+x 校验，只动 tmp_dir）**在 flock 外**；commit 段（`_replace_community_binary`: backup→swap→rollback→manifest→cleanup，契约 caller 已持锁）**在 flock 内**。acquire 与 commit 各自独立可测（前者 stub core + tmp，后者真实 fs tmp，均不持锁）。行为变化：锁范围从原"全程持锁（flock→download→verify→backup→swap→unlock）"缩到"仅包 commit 段"——download 到各自 tmp_dir 不碰 QEMU_BIN_FILE、无需锁保护，故良性。swap+rollback 作为原子组整块留 commit（副作用整块留纪律，OBSERVATIONS 07-04：rollback 依赖 swap 失败状态，拆开会破坏不变量）。
  - **路径解析**：`resolve_custom_binary_candidate <input> <arch> <outvar>` / `resolve_custom_pcbios_candidate <input> <outvar>`，恒 return 0、结果经 outvar 编码回传（`ok:<path>` / `err_dir_no_arch` / `err_not_file` / `err_not_dir` / `err_no_bootrom`）。caller 的 while 循环 direct call 一次、`case "$out"` 分支。
  - **jenkins 去重**：`jenkins_job_url_from_url <url>` 收敛两处逐字复制的 `sed -E 's|/lastSuccessfulBuild/.*||; s|/artifact/.*||'`（check_jenkins_update @273 用 `$manifest_url`、ensure_qemu_binary_community @392 用 `$qemu_url`）。
- **衔接**：qemu_binary.sh 仍是 direct-exit basename（ensure_qemu_binary_community/custom 的 7 个 exit 1/2/3 不动）；新抽的 5 个原语自愿 leaf-pure（no-direct-exit），由 ob_check surface gate 用函数体静态锁钉死。
- **对 grilling 共识的三处实现细化**（writing-plans 阶段核实代码后修正，理由见下，审阅时可回退）：
  1. **接口形态**：grilling 决策4 锁的是"echo token + outvar path"。核实发现这会让 caller 和测试都踩 `$()` 子 shell 内 `printf -v` 不回传父 shell 的陷阱（memory「bash outvar 回传两类陷阱」）。plan 改用 outvar 编码 `ok:<path>`/`err_*`（devtool_pick 先例），direct call 一次即可，仍符合"token+outvar、避多态返回码"的决策精神。
  2. **backup 名派生不抽函数**：grilling 决策3 提的"backup 名派生抽纯决策"，核实发现实际是单行 `bak_suffix="${old_build:-unknown}"` 参数扩展（qemu_binary.sh:192），抽函数是 over-engineering，保留内联。
  3. **acquire 出锁的实现位置（评审 M1）**：grilling 决策3 选项 A 的流程描述写成 `acquire flock → _dlqbc_stage_binary → _replace_community_binary → release`（flock 包整个），但其 label「acquire 出锁 + flock 留 wrapper」与行为声明「锁持有时间缩短（download 出锁）」都指 acquire 在 flock 外。流程描述是笔误——plan 实现 acquire 在 flock 外、仅 commit 进 flock（与 label/行为声明一致，锁范围真缩小）。`DLQB_BIN_PATH`/`DLQB_SHA256` 是全局，acquire 设好后跨 flock 边界 commit 自然可读，无跨边界传值复杂度。审阅时若实际意图是 flock 包整个（评审推荐的选项1），回退只需把 acquire 段移回 flock acquire 之后、文案改"全程持锁"。acquire 出锁的固有代价（评审二审知情项）：并发 update 时败者会完整下载一次后才发现锁被占、丢弃 binary（wasteful download）——触发罕见（同 harness 同 machine 并发交互更新概率极低，该函数由 check_jenkins_update 在交互终端确认后触发）、后果可逆（不损坏 binary，commit 仍在锁内串行），换取锁范围缩小至 commit 临界区；Task 6 实现的 commit message 应注明此权衡，让代价成为有意记录的决策。

## 全局约束

- **exit 契约**：qemu_binary.sh 是 direct-exit module（不在 `exit_contract.py` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 白名单），ensure_qemu_binary_community/custom 合法 own exit 1/2/3，**不进白名单、exit 不移走**。新抽的 5 个原语（`jenkins_job_url_from_url` / `resolve_custom_binary_candidate` / `resolve_custom_pcbios_candidate` / `_dlqbc_stage_binary` / `_replace_community_binary`）自愿 leaf-pure（恒 return、绝不 exit）；exit_contract Y 规则按 basename 够不着 direct-exit 文件内的单原语，改用 ob_check surface gate（函数体静态锁）守纯度——延续 07-07 detect_runtime_git_host 变体。
- **命名**：snake_case；私有原语用下划线前缀（`_dlqbc_stage_binary` / `_replace_community_binary`）；纯决策/去重用公共名（`jenkins_job_url_from_url` / `resolve_custom_*`）。
- **测试分层**：纯决策走 unit 层（零依赖、毫秒级、here-string）；acquire/commit 走 orchestration 层（PATH/函数 stub + 真实 fs tmp）。不碰网络（download_qemu_binary_core 用函数 override stub）。
- **outvar 纪律**：resolve 函数 caller 传下划线前缀变量名（`_bres` / `_pres`），不与函数内 local（`input`/`arch`/`out`/`cand`）同名——避动态作用域遮蔽（memory）。
- **改 ob/lib 后必跑** `tools/ob_check.sh` 配套自检。
- **不立** CONTEXT.md 术语（抽出的是实现机制——事务切面/路径解析/URL 提取，非领域概念；QEMU binary provisioning 领域术语已齐）；**不立** ADR（acquire/commit 切面 + 局部 leaf-pure 是 bestpractice_10 形态E + 07-07 detect_runtime_git_host 的延续，无 surprising 新架构决策；锁范围缩小在 commit message 记）。
- 无版本/依赖/平台约束（纯 bash，linux/bash 环境）。

## 输入工件

- **设计来源**：本会话 `/pick-one-arch-task` → `/grill-with-docs` 的 grilling 共识（6 决策点锁定）。无独立 design doc，grilling 产出即设计依据。
- **术语参考**：`CONTEXT.md` function semantic layer（L1/L2/L3 函数角色 + leaf-pure 三态）/ exit-code 契约 / test layer。
- **方法论参考**：`rules/skills/bestpractice_10-deep_module_extraction.md` 形态 E（god-function 拆：薄 wrapper + 深 prepare/execute）+ pin→deepen 顺序 + F1 跨 seam 副作用次序不变量。
- **先例**：`lib/devtool_pick.sh`（outvar 编码 `ok:<value>` 恒返回码模式）、07-07 `detect_runtime_git_host`（direct-exit basename 内自愿 leaf-pure + surface gate）。

## 文件结构与职责

- **Create**: `tests/unit/qemu_binary_resolve.sh` — 纯决策族 unit（jenkins URL 提取 + 两个 resolve_custom_* 路径解析）。
- **Create**: `tests/orchestration/qemu_binary_replace.sh` — acquire/commit 切面 orchestration（_dlqbc_stage_binary chmod+x 两态 + _replace_community_binary 正常事务 + stateful mv swap-fail-rollback）。
- **Modify**: `lib/qemu_binary.sh` — 抽 5 个 leaf-pure 原语；download_and_replace_community_qemu 退化为 flock wrapper；ensure_qemu_binary_custom 两段 while 循环改调 resolve_custom_*；jenkins 两处 sed 改调 jenkins_job_url_from_url；文件头注释更新。
- **Modify**: `tools/ob_check.sh` — 新增 qemu_binary leaf-pure surface gate（1c-quat，awk 提取 5 个函数体 grep exit）。
- **Modify**: `tools/coverage_matrix.md` — start-qemu 段 76-77 两行填 test。
- **Modify**: `.github/workflows/ob-tests.yml` — coverage 基线阈值（实测后更新）。
- **边界稳定**：ensure_qemu_binary_community 的下载链（已有 orchestration/qemu_binary_download.sh）行为不变；download_qemu_binary_core / write_qemu_binary_manifest / write_qemu_pcbios_manifest / check_jenkins_update 的对外语义不变；ensure_qemu_binary dispatcher 不动。

## 任务清单

### Task 1: 抽 jenkins_job_url_from_url 去重 + unit

- 目标：把 check_jenkins_update(qemu_binary.sh:273) 与 ensure_qemu_binary_community(qemu_binary.sh:392) 两处逐字复制的 jenkins job_url sed 提取，收敛成 leaf-pure `jenkins_job_url_from_url`，并补 unit。
- Files:
  - Create: `tests/unit/qemu_binary_resolve.sh`
  - Modify: `lib/qemu_binary.sh`（符号锚点：`check_jenkins_update` 内 @273 `job_url=$(echo "$manifest_url" | sed ...)`、`ensure_qemu_binary_community` 内 @392 `job_url=$(echo "$qemu_url" | sed ...)`；新函数插在 `query_jenkins_build_number` 之后即 @97 `}` 之后）
- 验证范围：`bash tests/unit/qemu_binary_resolve.sh` 输出 `PASS=... FAIL=0` 且 rc=0；qemu_binary.sh 无内联 `lastSuccessfulBuild` sed 残留、两处改调 `jenkins_job_url_from_url`。
- 接口契约:
  - Consumes: 无（纯字符串变换）。
  - Produces: 函数 `jenkins_job_url_from_url`(lib/qemu_binary.sh)；文件 `tests/unit/qemu_binary_resolve.sh`（后续 Task 2 追加 resolve_custom_* 测）。

- [ ] Step 1: 写失败 unit `tests/unit/qemu_binary_resolve.sh`

```bash
#!/usr/bin/env bash
# tests/unit/qemu_binary_resolve.sh — qemu_binary 纯决策族 unit。
# jenkins URL 提取 + (Task 2 追加) resolve_custom_* 路径解析。纯函数、无 IO、不 exit。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# jenkins_job_url_from_url <url>  →  echo job base url(剥 lastSuccessfulBuild/artifact 后缀)
assert_eq "artifact 后缀剥离" \
  "$(jenkins_job_url_from_url 'https://jenkins.openbmc.org/job/latest-qemu-x86/lastSuccessfulBuild/artifact/qemu/build/qemu-system-arm')" \
  'https://jenkins.openbmc.org/job/latest-qemu-x86'
assert_eq "仅 lastSuccessfulBuild 后缀" \
  "$(jenkins_job_url_from_url 'https://jenkins.openbmc.org/job/latest-qemu-x86/lastSuccessfulBuild/api/json')" \
  'https://jenkins.openbmc.org/job/latest-qemu-x86'
assert_eq "无后缀原样返回" \
  "$(jenkins_job_url_from_url 'https://jenkins.openbmc.org/job/latest-qemu-x86')" \
  'https://jenkins.openbmc.org/job/latest-qemu-x86'

assert_summary
```

- [ ] Step 2: 运行并确认失败（函数未实现）
- Run: `bash tests/unit/qemu_binary_resolve.sh; echo "rc=$?"`
- Expected: rc≠0，输出含 `FAIL`（`jenkins_job_url_from_url: command not found`）。

- [ ] Step 3: 在 lib/qemu_binary.sh 实现 `jenkins_job_url_from_url`（插在 `query_jenkins_build_number` 结尾 `}` 即 qemu_binary.sh:97 之后）

```bash
# jenkins_job_url_from_url <url>
# 纯决策(无 IO、不 exit): 从 QEMU binary 下载 URL 剥离 lastSuccessfulBuild/artifact 后缀，
# 得到 Jenkins job base URL(供 query_jenkins_build_number 查 lastSuccessfulBuild/api/json)。
# leaf-pure(绝不 exit)。
jenkins_job_url_from_url() {
    local url="$1"
    echo "$url" | sed -E 's|/lastSuccessfulBuild/.*||; s|/artifact/.*||'
}
```

  并把两处调用点改为函数调用：
  - check_jenkins_update @273 旧 `job_url=$(echo "$manifest_url" | sed -E 's|/lastSuccessfulBuild/.*||; s|/artifact/.*||')` → 新 `job_url=$(jenkins_job_url_from_url "$manifest_url")`
  - ensure_qemu_binary_community @392 旧 `job_url=$(echo "$qemu_url" | sed -E 's|/lastSuccessfulBuild/.*||; s|/artifact/.*||')` → 新 `job_url=$(jenkins_job_url_from_url "$qemu_url")`

- Change: 新增 1 个 leaf-pure 函数；两处内联 sed 塌成函数调用。
- [ ] Step 4: 运行并确认通过 + 无内联残留
- Run: `bash tests/unit/qemu_binary_resolve.sh && ! grep -q 'lastSuccessfulBuild/\.\\*' lib/qemu_binary.sh && test "$(grep -c 'jenkins_job_url_from_url' lib/qemu_binary.sh)" -ge 3`
- Expected: rc=0（unit 末行 `PASS=... FAIL=0`；qemu_binary.sh 无内联 lastSuccessfulBuild sed 残留；`jenkins_job_url_from_url` 至少 3 处出现 = 1 定义 + 2 调用）。
- [ ] Step 5: 可选 checkpoint commit
- Run: `git add lib/qemu_binary.sh tests/unit/qemu_binary_resolve.sh && git commit -m "feat(qemu): extract jenkins_job_url_from_url leaf-pure + unit"`
- Expected: commit 成功。

### Task 2: 抽 resolve_custom_binary_candidate + resolve_custom_pcbios_candidate + unit

- 目标：把 ensure_qemu_binary_custom 两段 while 循环里的纯路径解析抽成两个 leaf-pure 函数，token/outvar 编码回传，并补 unit。本任务只抽函数 + 测，不改调用点（Task 3 改 caller）。
- Files:
  - Modify: `tests/unit/qemu_binary_resolve.sh`（追加 resolve_custom_* 测）
  - Modify: `lib/qemu_binary.sh`（新函数插在 `ensure_qemu_binary_custom` 之前即 @417 之前）
- 验证范围：`bash tests/unit/qemu_binary_resolve.sh` 输出 `PASS=... FAIL=0`。
- 接口契约:
  - Consumes: 无（纯路径判定，调 bash test `[ -d ]` / `[ -f ]`）。
  - Produces: 函数 `resolve_custom_binary_candidate` / `resolve_custom_pcbios_candidate`(lib/qemu_binary.sh)。Task 3 消费。

- [ ] Step 1: 追加失败 unit（在 `assert_summary` 之前插入）

```bash

# --- resolve_custom_binary_candidate <input> <arch> <outvar> ---
# outvar 编码: ok:<path> / err_dir_no_arch / err_not_file
_mk() { mkdir -p "$1"; }            # helper 造目录
_bres=""
# 文件直传 → ok:input
printf 'NEW' > "$TMPDIR/ob_res_bin"
resolve_custom_binary_candidate "$TMPDIR/ob_res_bin" "qemu-system-arm" _bres
assert_eq "binary: file 直传 ok" "$_bres" "ok:$TMPDIR/ob_res_bin"
# 目录 + 含 arch → ok:dir/arch
_mk "$TMPDIR/ob_res_dir"; printf 'NEW' > "$TMPDIR/ob_res_dir/qemu-system-arm"
resolve_custom_binary_candidate "$TMPDIR/ob_res_dir" "qemu-system-arm" _bres
assert_eq "binary: dir+arch → ok:dir/arch" "$_bres" "ok:$TMPDIR/ob_res_dir/qemu-system-arm"
# 目录 + 缺 arch → err_dir_no_arch
_mk "$TMPDIR/ob_res_dir2"
resolve_custom_binary_candidate "$TMPDIR/ob_res_dir2" "qemu-system-arm" _bres
assert_eq "binary: dir 缺 arch → err_dir_no_arch" "$_bres" "err_dir_no_arch"
# 既非 dir 也非 file → err_not_file
resolve_custom_binary_candidate "$TMPDIR/ob_res_nope" "qemu-system-arm" _bres
assert_eq "binary: 不存在 → err_not_file" "$_bres" "err_not_file"
rm -rf "$TMPDIR/ob_res_dir" "$TMPDIR/ob_res_dir2"

# --- resolve_custom_pcbios_candidate <input> <outvar> ---
# outvar 编码: ok:<path> / err_not_dir / err_no_bootrom
_pres=""
# 目录 + 直接含 ast27x0_bootrom.bin → ok:input
_mk "$TMPDIR/ob_res_pcbios"; : > "$TMPDIR/ob_res_pcbios/ast27x0_bootrom.bin"
resolve_custom_pcbios_candidate "$TMPDIR/ob_res_pcbios" _pres
assert_eq "pcbios: 直接含 bootrom → ok:input" "$_pres" "ok:$TMPDIR/ob_res_pcbios"
# 目录 + 嵌套 pc-bios/ 含 bootrom → ok:input/pc-bios
_mk "$TMPDIR/ob_res_pcbios2/pc-bios"; : > "$TMPDIR/ob_res_pcbios2/pc-bios/ast27x0_bootrom.bin"
resolve_custom_pcbios_candidate "$TMPDIR/ob_res_pcbios2" _pres
assert_eq "pcbios: 嵌套 pc-bios → ok:input/pc-bios" "$_pres" "ok:$TMPDIR/ob_res_pcbios2/pc-bios"
# 目录 + 无 bootrom → err_no_bootrom
_mk "$TMPDIR/ob_res_pcbios3"
resolve_custom_pcbios_candidate "$TMPDIR/ob_res_pcbios3" _pres
assert_eq "pcbios: 无 bootrom → err_no_bootrom" "$_pres" "err_no_bootrom"
# 非 dir → err_not_dir
resolve_custom_pcbios_candidate "$TMPDIR/ob_res_nope" _pres
assert_eq "pcbios: 非 dir → err_not_dir" "$_pres" "err_not_dir"
rm -rf "$TMPDIR/ob_res_pcbios" "$TMPDIR/ob_res_pcbios2" "$TMPDIR/ob_res_pcbios3"
```

- [ ] Step 2: 运行并确认失败（函数未实现）
- Run: `bash tests/unit/qemu_binary_resolve.sh; echo "rc=$?"`
- Expected: rc≠0，输出含 `FAIL`（`resolve_custom_binary_candidate: command not found`）。

- [ ] Step 3: 在 lib/qemu_binary.sh 实现两个函数（插在 `ensure_qemu_binary_custom` 即 @417 之前）

```bash
# resolve_custom_binary_candidate <input> <arch> <outvar>
# 纯决策(无 IO 副作用、不 exit): custom QEMU binary 路径解析。outvar 编码:
#   ok:<path>          input 是文件, 或目录下含 <arch>
#   err_dir_no_arch    input 是目录但缺 <arch>
#   err_not_file       input 既非目录也非文件
# leaf-pure; 调用者(ensure_qemu_binary_custom)负责交互循环 + exit。
resolve_custom_binary_candidate() {
    local input="$1" arch="$2" out="$3"
    if [[ -d "$input" ]]; then
        local cand="${input%/}/$arch"
        if [[ ! -f "$cand" ]]; then
            printf -v "$out" '%s' "err_dir_no_arch"
            return 0
        fi
        printf -v "$out" '%s' "ok:$cand"
        return 0
    elif [[ ! -f "$input" ]]; then
        printf -v "$out" '%s' "err_not_file"
        return 0
    fi
    printf -v "$out" '%s' "ok:$input"
    return 0
}

# resolve_custom_pcbios_candidate <input> <outvar>
# 纯决策(无 IO 副作用、不 exit): custom QEMU pc-bios 目录解析(ast27x0_bootrom.bin 查找 +
# pc-bios/ 子目录回退)。outvar 编码:
#   ok:<path>        input(或 input/pc-bios)含 ast27x0_bootrom.bin
#   err_not_dir      input 非目录
#   err_no_bootrom   input 是目录但无 ast27x0_bootrom.bin(含 pc-bios/ 回退)
# leaf-pure。
resolve_custom_pcbios_candidate() {
    local input="$1" out="$2"
    if [[ ! -d "$input" ]]; then
        printf -v "$out" '%s' "err_not_dir"
        return 0
    fi
    local cand="$input"
    if [[ ! -f "$cand/ast27x0_bootrom.bin" ]]; then
        if [[ -f "$cand/pc-bios/ast27x0_bootrom.bin" ]]; then
            cand="$cand/pc-bios"
        else
            printf -v "$out" '%s' "err_no_bootrom"
            return 0
        fi
    fi
    printf -v "$out" '%s' "ok:$cand"
    return 0
}
```

- Change: 新增 2 个 leaf-pure 函数（不改调用点）。
- [ ] Step 4: 运行并确认通过
- Run: `bash tests/unit/qemu_binary_resolve.sh`
- Expected: rc=0，末行 `PASS=... FAIL=0`。
- [ ] Step 5: 可选 checkpoint commit
- Run: `git add lib/qemu_binary.sh tests/unit/qemu_binary_resolve.sh && git commit -m "feat(qemu): extract resolve_custom_* leaf-pure path resolvers + unit"`
- Expected: commit 成功。

### Task 3: ensure_qemu_binary_custom 改调 resolve_custom_*

- 目标：把 ensure_qemu_binary_custom 两段 while 循环的内联路径判定（binary @452-462、pc-bios @485-499）替换为 resolve_custom_* 调用，交互循环（prompt + exit 1 + continue/break）留 wrapper。
- Files: Modify `lib/qemu_binary.sh`（符号锚点：`ensure_qemu_binary_custom` 内 binary while 块 @444-465、pc-bios while 块 @477-502）
- 验证范围：qemu_binary.sh 无内联 `does not contain $arch` / `ast27x0_bootrom.bin` 判定残留、custom 调 resolve_custom_*；custom 的 3 个 exit（@430 exit 3 / @448 exit 1 / @481 exit 1）保留。
- 接口契约:
  - Consumes: `resolve_custom_binary_candidate` / `resolve_custom_pcbios_candidate`(Task 2)。
  - Produces: 无。

- [ ] Step 1: 确认当前内联判定在
- Run: `grep -c 'does not contain' lib/qemu_binary.sh`
- Expected: 输出 `2`（binary 段 + pc-bios 段各一处内联判定文案）。

- [ ] Step 2: 确认尚未调用 resolve_custom_*
- Run: `grep -c 'resolve_custom_binary_candidate\|resolve_custom_pcbios_candidate' lib/qemu_binary.sh`
- Expected: 输出 `2`（仅 Task 2 的两处函数定义；调用点 = 0，但定义已计 2）。
- 注：此处 `2` 是函数定义计数；改完后调用点加入，计数会上升。

- [ ] Step 3: 替换 binary while 块的内联判定

  将 ensure_qemu_binary_custom 内 binary 段（@444-465）的这段内联判定：

```bash
        input_binary="$PROMPT_PATH_RESULT"
        resolved_binary_path="$input_binary"
        if [[ -d "$input_binary" ]]; then
            resolved_binary_path="${input_binary%/}/$arch"
            if [[ ! -f "$resolved_binary_path" ]]; then
                error "Directory does not contain $arch: $input_binary"
                continue
            fi
        elif [[ ! -f "$input_binary" ]]; then
            error "File not found: $input_binary"
            continue
        fi

        break
```

  替换为：

```bash
        local _bres=""
        resolve_custom_binary_candidate "$PROMPT_PATH_RESULT" "$arch" _bres
        case "$_bres" in
            ok:*) resolved_binary_path="${_bres#ok:}"; break ;;
            err_dir_no_arch) error "Directory does not contain $arch: $PROMPT_PATH_RESULT"; continue ;;
            err_not_file)    error "File not found: $PROMPT_PATH_RESULT"; continue ;;
        esac
```

- Change 1: binary 段内联 13 行判定塌成 7 行 resolve 调用 + case。
- [ ] Step 4: 替换 pc-bios while 块的内联判定

  将 pc-bios 段（@485-502）的这段内联判定：

```bash
            input_pcbios="$PROMPT_PATH_RESULT"

            if [[ ! -d "$input_pcbios" ]]; then
                error "Directory not found: $input_pcbios"
                continue
            fi

            resolved_pcbios_path="$input_pcbios"
            if [[ ! -f "$resolved_pcbios_path/ast27x0_bootrom.bin" ]]; then
                if [[ -f "$resolved_pcbios_path/pc-bios/ast27x0_bootrom.bin" ]]; then
                    resolved_pcbios_path="$resolved_pcbios_path/pc-bios"
                else
                    error "Directory does not contain ast27x0_bootrom.bin: $input_pcbios"
                    error "Provide the pc-bios directory itself, or a QEMU root directory that contains pc-bios/."
                    continue
                fi
            fi

            break
```

  替换为：

```bash
            local _pres=""
            resolve_custom_pcbios_candidate "$PROMPT_PATH_RESULT" _pres
            case "$_pres" in
                ok:*) resolved_pcbios_path="${_pres#ok:}"; break ;;
                err_not_dir)   error "Directory not found: $PROMPT_PATH_RESULT"; continue ;;
                err_no_bootrom)
                    error "Directory does not contain ast27x0_bootrom.bin: $PROMPT_PATH_RESULT"
                    error "Provide the pc-bios directory itself, or a QEMU root directory that contains pc-bios/."
                    continue ;;
            esac
```

- Change 2: pc-bios 段内联 18 行判定塌成 9 行 resolve 调用 + case。
- [ ] Step 5: 确认无内联残留 + 调用已接入 + exit 保留
- Run: `! grep -qF 'does not contain $arch' lib/qemu_binary.sh && grep -q 'resolve_custom_binary_candidate "\$PROMPT_PATH_RESULT"' lib/qemu_binary.sh && grep -q 'resolve_custom_pcbios_candidate "\$PROMPT_PATH_RESULT"' lib/qemu_binary.sh && test "$(grep -cE '^[[:space:]]*exit [0-9]' lib/qemu_binary.sh)" -eq 7`
- Expected: rc=0（无内联 `$arch` 判定残留 + 两段调 resolve_custom_* + qemu_binary.sh 仍是 7 个 exit，custom 的 exit 1/3 保留）。
- 注：`does not contain ast27x0_bootrom.bin` 文案在 case 分支里保留（err_no_bootrom 分支打印），故只 grep `does not contain $arch`（带 `$arch` 变量的 binary 段文案）确认其已移出内联判定。

### Task 4: 抽 _dlqbc_stage_binary（acquire）+ orchestration 测

- 目标：把 download_and_replace_community_qemu 的 acquire 段（download_qemu_binary_core + chmod+x 校验，@171-187）抽成 leaf-pure `_dlqbc_stage_binary`，stub download_qemu_binary_core 测 chmod+x 两态。本任务只新增函数 + 测，不改 download_and_replace（Task 6 串联）。
- Files:
  - Create: `tests/orchestration/qemu_binary_replace.sh`
  - Modify: `lib/qemu_binary.sh`（新函数插在 `download_qemu_binary_core` 之后即 @146 `}` 之后）
- 验证范围：`bash tests/orchestration/qemu_binary_replace.sh` 输出 `PASS=... FAIL=0`。
- 接口契约:
  - Consumes: `download_qemu_binary_core`(lib/qemu_binary.sh，设 DLQB_BIN_PATH/DLQB_SHA256 全局)。
  - Produces: 函数 `_dlqbc_stage_binary`(lib/qemu_binary.sh)；文件 `tests/orchestration/qemu_binary_replace.sh`（Task 5 追加 commit 测）。Task 6 消费 `_dlqbc_stage_binary`。

- [ ] Step 1: 写失败 orchestration 测 `tests/orchestration/qemu_binary_replace.sh`

```bash
#!/usr/bin/env bash
# tests/orchestration/qemu_binary_replace.sh — binary acquire/commit 切面 orchestration。
# _dlqbc_stage_binary(stub download_qemu_binary_core, chmod+x 两态) +
# (Task 5 追加) _replace_community_binary(真实 fs 正常事务 + stateful mv swap-fail-rollback)。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
QEMU_BIN_DIR="$TMP/qemu-bin/community"
mkdir -p "$QEMU_BIN_DIR"
MACHINE=romulus

# stub download_qemu_binary_core: case 1 成功(写假 binary + 设全局), case 2 失败(return 1)
install_ok_core() {
    download_qemu_binary_core() {
        printf 'NEW' > "$2/$3"
        DLQB_BIN_PATH="$2/$3"
        DLQB_SHA256="deadbeef"
        return 0
    }
}

# --- _dlqbc_stage_binary: core 成功 → chmod+x 校验通过 → return 0 ---
extract_dir="$(mktemp -d)"
install_ok_core
(
    _dlqbc_stage_binary "https://example.com/x" "$extract_dir" "qemu-system-arm"
    echo "RC=$?"
) > "$TMP/a1" 2>&1
assert_eq "acquire core 成功 → rc=0" "$(grep -o 'RC=[01]' "$TMP/a1")" "RC=0"
assert_true "acquire: DLQB_BIN_PATH 已 chmod+x" test -x "$extract_dir/qemu-system-arm"

# --- _dlqbc_stage_binary: core 失败(return 1) → return 1 ---
extract_dir2="$(mktemp -d)"
download_qemu_binary_core() { return 1; }
(
    _dlqbc_stage_binary "https://example.com/x" "$extract_dir2" "qemu-system-arm"
    echo "RC=$?"
) > "$TMP/a2" 2>&1
assert_eq "acquire core 失败 → rc=1" "$(grep -o 'RC=[01]' "$TMP/a2")" "RC=1"

rm -rf "$TMP" "$extract_dir" "$extract_dir2"
assert_summary
```

- [ ] Step 2: 运行并确认失败（函数未实现）
- Run: `bash tests/orchestration/qemu_binary_replace.sh; echo "rc=$?"`
- Expected: rc≠0，输出含 `FAIL`（`_dlqbc_stage_binary: command not found`）。

- [ ] Step 3: 在 lib/qemu_binary.sh 实现 `_dlqbc_stage_binary`（插在 `download_qemu_binary_core` 结尾 `}` 即 @146 之后）

```bash
# _dlqbc_stage_binary <url> <extract_dir> <arch>
# acquire 段: download_qemu_binary_core + chmod+x 校验。只动 extract_dir, 无 QEMU_BIN_FILE 副作用。
# 设 DLQB_BIN_PATH / DLQB_SHA256(on success)。return 0=成功 / 1=download·extract·不可执行失败。
# leaf-pure(绝不 exit); caller 拥有 tmp_dir 清理 + flock + exit。
_dlqbc_stage_binary() {
    local url="$1" extract_dir="$2" arch="$3"
    if ! download_qemu_binary_core "$url" "$extract_dir" "$arch"; then
        return 1
    fi
    chmod +x "$DLQB_BIN_PATH" 2>/dev/null || true
    if ! [[ -x "$DLQB_BIN_PATH" ]]; then
        warn "Downloaded file is not executable."
        return 1
    fi
    return 0
}
```

- Change: 新增 1 个 leaf-pure acquire 函数（不改 download_and_replace）。
- [ ] Step 4: 运行并确认通过
- Run: `bash tests/orchestration/qemu_binary_replace.sh`
- Expected: rc=0，末行 `PASS=... FAIL=0`。
- [ ] Step 5: 可选 checkpoint commit
- Run: `git add lib/qemu_binary.sh tests/orchestration/qemu_binary_replace.sh && git commit -m "feat(qemu): extract _dlqbc_stage_binary acquire + orchestration"`
- Expected: commit 成功。

### Task 5: 抽 _replace_community_binary（commit）+ orchestration 测（含 swap-fail-rollback）

- 目标：把 download_and_replace_community_qemu 的 commit 段（backup→swap→rollback→manifest→cleanup bak，@189-222）抽成 leaf-pure `_replace_community_binary`，真实 fs 测正常事务 + stateful mv 测 swap-fail-rollback 不变量。本任务只新增函数 + 测，不改 download_and_replace。
- Files:
  - Modify: `tests/orchestration/qemu_binary_replace.sh`（在 `assert_summary` 之前追加 commit 测）
  - Modify: `lib/qemu_binary.sh`（新函数插在 `_dlqbc_stage_binary` 之后）
- 验证范围：`bash tests/orchestration/qemu_binary_replace.sh` 输出 `PASS=... FAIL=0`（含 swap-fail-rollback case）。
- 接口契约:
  - Consumes: `read_kv_field` / `read_source_label` / `write_qemu_binary_manifest`(lib)；全局 `QEMU_BIN_FILE`。
  - Produces: 函数 `_replace_community_binary`(lib/qemu_binary.sh)。Task 6 消费。

- [ ] Step 1: 追加失败 orchestration 测（在 `assert_summary` 之前插入）

```bash

# --- _replace_community_binary: 正常事务(backup→swap→manifest→cleanup bak) ---
# 显式设 SOURCE_MANIFEST_FILE: read_source_label(repo.sh:8) → read_manifest_field(util.sh:422)
# → read_kv_field "$SOURCE_MANIFEST_FILE" 读的是这个全局(非 CONFIGS_DIR); ob_loader 加载时
# 它为空(ob:15), 仅设 CONFIGS_DIR 会靠 fallback "community" 碰巧过——约束须在测试里显式成立。
CONFIGS_DIR="$TMP/configs"; mkdir -p "$CONFIGS_DIR"
SOURCE_MANIFEST_FILE="$CONFIGS_DIR/openbmc-source.manifest"
printf 'source_label=community\n' > "$SOURCE_MANIFEST_FILE"
QEMU_BIN_FILE="$QEMU_BIN_DIR/qemu-system-arm"
printf 'OLD' > "$QEMU_BIN_FILE"
printf 'build_number=40\nurl=https://jenkins.openbmc.org/job/latest-qemu-x86/lastSuccessfulBuild/artifact/qemu/build/qemu-system-arm\n' > "$QEMU_BIN_FILE.manifest"
new_binary="$TMP/newbin"; printf 'NEW' > "$new_binary"; chmod +x "$new_binary"
(
    _replace_community_binary "$new_binary" "deadbeef" "https://jenkins.openbmc.org/job/latest-qemu-x86/lastSuccessfulBuild/artifact/qemu/build/qemu-system-arm" "42" "qemu-system-arm"
    echo "RC=$?"
) > "$TMP/c1" 2>&1
assert_eq "commit 正常 → rc=0" "$(grep -o 'RC=[01]' "$TMP/c1")" "RC=0"
assert_true "commit 正常: binary 已换新" grep -q NEW "$QEMU_BIN_FILE"
assert_true "commit 正常: bak 已清理" test ! -f "$QEMU_BIN_FILE-40.bak"
assert_true "commit 正常: manifest build_number=42" grep -q 'build_number=42' "$QEMU_BIN_FILE.manifest"

# --- _replace_community_binary: swap-fail-rollback(stateful mv: 第1次 swap fail / 第2次 rollback real) ---
printf 'OLD' > "$QEMU_BIN_FILE"
printf 'build_number=40\nurl=https://jenkins.openbmc.org/job/latest-qemu-x86/lastSuccessfulBuild/artifact/qemu/build/qemu-system-arm\n' > "$QEMU_BIN_FILE.manifest"
new_binary2="$TMP/newbin2"; printf 'NEW' > "$new_binary2"; chmod +x "$new_binary2"
(
    _mv_n=0
    mv() { _mv_n=$((_mv_n+1)); if (( _mv_n == 1 )); then return 1; fi; command mv "$@"; }
    _replace_community_binary "$new_binary2" "deadbeef" "https://jenkins.openbmc.org/job/latest-qemu-x86/lastSuccessfulBuild/artifact/qemu/build/qemu-system-arm" "42" "qemu-system-arm"
    echo "RC=$?"
) > "$TMP/c2" 2>&1
assert_eq "swap-fail → rc=1(rollback 后)" "$(grep -o 'RC=[01]' "$TMP/c2")" "RC=1"
assert_true "rollback 恢复旧 binary" grep -q OLD "$QEMU_BIN_FILE"
```

- [ ] Step 2: 运行并确认失败（函数未实现）
- Run: `bash tests/orchestration/qemu_binary_replace.sh; echo "rc=$?"`
- Expected: rc≠0，输出含 `FAIL`（`_replace_community_binary: command not found`）。

- [ ] Step 3: 在 lib/qemu_binary.sh 实现 `_replace_community_binary`（插在 `_dlqbc_stage_binary` 之后）

```bash
# _replace_community_binary <new_binary> <new_sha256> <qemu_url> <remote_build> <arch>
# commit 段: backup→swap→rollback→manifest→cleanup bak。契约: caller 已持 flock + 提供 new_binary(已 chmod+x)。
# return 0=替换成功 / 1=swap 失败(已 rollback 旧 binary)。leaf-pure(绝不 exit);
# caller(download_and_replace_community_qemu)拥有 tmp_dir 清理 + flock 释放 + exit。
# swap+rollback 是紧耦合原子组(rollback 依赖 swap 失败状态), 整块留此函数(F1)。
_replace_community_binary() {
    local new_binary="$1" new_sha256="$2" qemu_url="$3" remote_build="$4" arch="$5"
    local manifest="${QEMU_BIN_FILE}.manifest"
    local old_build bak_suffix bak_file label
    old_build=$(read_kv_field "$manifest" build_number 2>/dev/null) || old_build=""
    bak_suffix="${old_build:-unknown}"
    bak_file="${QEMU_BIN_FILE}-${bak_suffix}.bak"

    info "Backing up current QEMU binary (build #${bak_suffix})..."
    cp "$QEMU_BIN_FILE" "$bak_file"

    if ! mv "$new_binary" "$QEMU_BIN_FILE"; then
        warn "Failed to replace QEMU binary."
        [[ -f "$bak_file" ]] && mv "$bak_file" "$QEMU_BIN_FILE"
        return 1
    fi
    chmod +x "$QEMU_BIN_FILE"

    label=$(read_source_label)
    write_qemu_binary_manifest "$label" "$arch" "url" "$qemu_url" "$new_sha256" "$remote_build"

    rm -f "$bak_file"
    info "QEMU binary updated to build #${remote_build}."
    verbose "  SHA256: $new_sha256"
    return 0
}
```

- Change: 新增 1 个 leaf-pure commit 函数；backup 名用内联 `${old_build:-unknown}`（不抽函数，见架构快照细化2）。
- [ ] Step 4: 运行并确认通过
- Run: `bash tests/orchestration/qemu_binary_replace.sh`
- Expected: rc=0，末行 `PASS=... FAIL=0`（含 c1 正常事务 + c2 swap-fail-rollback 两组断言）。
- [ ] Step 5: 可选 checkpoint commit
- Run: `git add lib/qemu_binary.sh tests/orchestration/qemu_binary_replace.sh && git commit -m "feat(qemu): extract _replace_community_binary commit + swap-fail-rollback test"`
- Expected: commit 成功。

### Task 6: download_and_replace_community_qemu 退化为 flock wrapper

- 目标：把 download_and_replace_community_qemu 的内联 acquire+commit+backup+cleanup（@166-222）退役，改成调 `_dlqbc_stage_binary` + `_replace_community_binary`，flock 与 tmp_dir 清理留 wrapper。
- Files: Modify `lib/qemu_binary.sh`（符号锚点：`download_and_replace_community_qemu` @151-223 整个函数体）
- 验证范围：download_and_replace 调两个新函数、无内联 cp backup / mv swap / write_qemu_binary_manifest 残留；ob_check 全绿（含 exit-contract X/Y + shellcheck baseline + run_all）。
- 接口契约:
  - Consumes: `_dlqbc_stage_binary`(Task 4) + `_replace_community_binary`(Task 5)。
  - Produces: 无。

- [ ] Step 1: 确认当前内联事务在
- Run: `awk '/^download_and_replace_community_qemu\(\)/{g=1} g{print; if($0=="}") exit}' lib/qemu_binary.sh | grep -cE 'cp .QEMU_BIN_FILE. .*\.bak|write_qemu_binary_manifest|chmod \+x .DLQB_BIN_PATH'`
- Expected: 输出 `3`（内联 backup cp + manifest write + chmod 各一处，待退役）。

- [ ] Step 2: 确认尚未调新函数
- Run: `awk '/^download_and_replace_community_qemu\(\)/{g=1} g{print; if($0=="}") exit}' lib/qemu_binary.sh | grep -c '_dlqbc_stage_binary\|_replace_community_binary'`
- Expected: 输出 `0`（download_and_replace 内尚未调新函数）。

- [ ] Step 3: 重写 download_and_replace_community_qemu 函数体（@151-223 整体替换）

  将整个函数替换为：

```bash
# Download a new QEMU binary and safely replace the existing one.
# Args: $1 = download URL, $2 = remote build number, $3 = arch
# flock wrapper: acquire(download+verify)在锁外(只动 tmp_dir, 不碰 QEMU_BIN_FILE);
# flock 仅包 commit 段(并发 replace 会互相覆盖)。锁范围比原全程持锁缩小(良性)。
# Returns: 0 on success, 1 on failure (caller should continue with old binary)。
download_and_replace_community_qemu() {
    local qemu_url="$1"
    local remote_build="$2"
    local arch="$3"
    local lock_file="${QEMU_BIN_FILE}.update.lock"
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/qemu-update-XXXXXX")
    local _rc=0

    # ── acquire: download + verify(锁外; 只动 tmp_dir, 不碰 QEMU_BIN_FILE) ──
    info "Downloading QEMU binary (build #${remote_build})..."
    if ! _dlqbc_stage_binary "$qemu_url" "$tmp_dir" "$arch"; then
        warn "Failed to download/extract QEMU binary from: $qemu_url"
        rm -rf "$tmp_dir"
        return 1
    fi

    # ── flock: 仅保护 commit 段(并发 replace 互相覆盖; acquire 已在锁外完成) ──
    exec 200>"$lock_file"
    if ! flock -n 200; then
        warn "Another QEMU binary update is in progress. Skipping."
        exec 200>&-
        rm -rf "$tmp_dir"
        return 1
    fi

    # ── commit: backup→swap→rollback→manifest(契约: 已持锁) ──
    _replace_community_binary "$DLQB_BIN_PATH" "$DLQB_SHA256" "$qemu_url" "$remote_build" "$arch" || _rc=$?

    # ── cleanup tmp + release lock ──
    rm -rf "$tmp_dir"
    flock -u 200 2>/dev/null; exec 200>&-
    return "$_rc"
}
```

- Change: download_and_replace 从 73 行内联事务塌成 ~45 行 flock wrapper；acquire（锁外）+ commit（锁内）退役内联，调两个 leaf-pure 函数。
- [ ] Step 4: 确认无内联残留 + 调用已接入 + ob_check 全绿
- Run: `awk '/^download_and_replace_community_qemu\(\)/{g=1} g{print; if($0=="}") exit}' lib/qemu_binary.sh | grep -q '_dlqbc_stage_binary' && awk '/^download_and_replace_community_qemu\(\)/{g=1} g{print; if($0=="}") exit}' lib/qemu_binary.sh | grep -q '_replace_community_binary' && ! awk '/^download_and_replace_community_qemu\(\)/{g=1} g{print; if($0=="}") exit}' lib/qemu_binary.sh | grep -qE 'cp .QEMU_BIN_FILE. .*\.bak'`
- Expected: rc=0（download_and_replace 调两个新函数 + 无内联 backup cp 残留）。
- [ ] Step 5: 跑 ob_check 配套自检
- Run: `tools/ob_check.sh`
- Expected: `ALL GREEN`——extract_funcs lib 三段全清、shellcheck baseline 一致、exit-contract X/Y/Z green（download_and_replace 退役后其内无字面 exit，仍符合 direct-exit basename 的 X 规则）、run_all ALL GREEN（含新 qemu_binary_resolve.sh + qemu_binary_replace.sh 自动发现并过）。

### Task 7: ob_check 加 qemu_binary leaf-pure surface gate

- 目标：给 5 个新 leaf-pure 原语加 ob_check surface gate（awk 提取函数体 grep exit，静态锁守纯度）。
- Files: Modify `tools/ob_check.sh`（在 1c-ter bare mirror 段之后、1d prompt 段之前新增 1c-quat 段）
- 验证范围：ob_check 含新 gate 且绿——塞临时 exit 时 gate 报 bad，删后报 ok。
- 接口契约:
  - Consumes: 5 个 leaf-pure 原语（`jenkins_job_url_from_url` / `resolve_custom_binary_candidate` / `resolve_custom_pcbios_candidate` / `_dlqbc_stage_binary` / `_replace_community_binary`，Task 1/2/4/5）。
  - Produces: 无。

- [ ] Step 1: 在 tools/ob_check.sh 新增 1c-quat gate（插在 1c-ter bare mirror 段 @90 之后、1d prompt 段 @92 之前）

```bash
# ── 1c-quat. qemu_binary 自愿 leaf-pure 原语函数体无 exit ──
# qemu_binary.sh 是 direct-exit basename(ensure_* own exit 1/2/3), exit_contract Y 规则够不着
# 这些单原语; 它们自愿 leaf-pure(恒 return, 绝不 exit), 用函数体静态锁守纯度。
_qbin_leaf_fns=(jenkins_job_url_from_url resolve_custom_binary_candidate resolve_custom_pcbios_candidate _dlqbc_stage_binary _replace_community_binary)
_qbin_leaf_bad=""
for _fn in "${_qbin_leaf_fns[@]}"; do
    _body=$(awk -v fn="^${_fn}\\(\\)" '$0 ~ fn {g=1} g {print; if($0=="}") exit}' lib/qemu_binary.sh)
    if printf '%s\n' "$_body" | grep -qE '^[[:space:]]*exit([[:space:]]|$)'; then
        _qbin_leaf_bad="$_qbin_leaf_bad $_fn"
    fi
done
if [[ -n "$_qbin_leaf_bad" ]]; then
    bad "qemu_binary leaf-pure 函数体含 exit(应恒 return):$_qbin_leaf_bad"
else
    ok "qemu_binary leaf-pure 原语无 exit"
fi
```

- [ ] Step 2: 临时塞 exit 验证 gate 有效(自检 gate 不是空操作; 用 cp 备份/恢复守可逆, 不靠人工删)
- Run: `cp lib/qemu_binary.sh /tmp/qb.bak && sed -i '/^_dlqbc_stage_binary()/a\    exit 1' lib/qemu_binary.sh && OB_CHECK_SKIP_TESTS=1 tools/ob_check.sh 2>&1 | grep -c 'qemu_binary leaf-pure 函数体含 exit'; mv /tmp/qb.bak lib/qemu_binary.sh`
- Expected: grep -c 输出 `1`(塞 exit 时 gate 报 bad); 恢复后跑 `git diff --quiet lib/qemu_binary.sh` rc=0(临时 exit 无残留)。
- [ ] Step 3: 确认删掉临时 exit 后 gate 绿
- Run: `OB_CHECK_SKIP_TESTS=1 tools/ob_check.sh 2>&1 | grep -E 'qemu_binary leaf-pure 原语无 exit'`
- Expected: 输出含 `✓ qemu_binary leaf-pure 原语无 exit`。

### Task 8: coverage_matrix 填 test + ob-tests.yml 基线收尾

- 目标：coverage_matrix.md:76-77 填 test（闭合盲区的文档侧）；跑 coverage radar 实测 uncovered 并更新 ob-tests.yml 基线阈值。
- Files:
  - Modify: `tools/coverage_matrix.md`（start-qemu 段 76-77 两行）
  - Modify: `.github/workflows/ob-tests.yml`（coverage 基线阈值，实测后定）
- 验证范围：matrix 76-77 不再 test 空、登记两个 test 文件；coverage radar uncovered ≤ ob-tests.yml 新阈值。
- 接口契约:
  - Consumes: `tests/unit/qemu_binary_resolve.sh` + `tests/orchestration/qemu_binary_replace.sh`（Task 1/4/5 产出）；5 个 leaf-pure 原语。
  - Produces: 无。

- [ ] Step 1: 填 coverage_matrix.md start-qemu 段 76-77

  将：

```markdown
| binary 更新(flock+回滚) | download_and_replace_community_qemu | | 副作用残留(flock+backup+rollback) |
| custom binary 配置 | ensure_qemu_binary_custom | | 交互残留(非 TTY exit 3 / TTY prompt) |
```

  替换为：

```markdown
| binary 更新(flock+回滚) | download_and_replace_community_qemu;_dlqbc_stage_binary;_replace_community_binary | orchestration/qemu_binary_replace.sh | acquire/commit 切面; flock 留 wrapper; swap-fail-rollback 不变量 stateful mv 锁 |
| custom binary 配置 | ensure_qemu_binary_custom;resolve_custom_binary_candidate;resolve_custom_pcbios_candidate | unit/qemu_binary_resolve.sh | 路径解析 leaf-pure(outvar 编码); 交互循环留 wrapper; 非 TTY exit 3 仍靠 .exp |
```

- Change: 76-77 两行 test 列填入覆盖归属。
- [ ] Step 2: 确认 matrix 填齐
- Run: `! grep -qE '^\| binary 更新\(flock\+回滚\) \| download_and_replace_community_qemu \| \|' tools/coverage_matrix.md && grep -q 'orchestration/qemu_binary_replace.sh' tools/coverage_matrix.md && grep -q 'unit/qemu_binary_resolve.sh' tools/coverage_matrix.md`
- Expected: rc=0（76-77 不再 test 空 + 两个 test 文件已登记）。
- [ ] Step 3: 跑 coverage radar 实测 uncovered，更新 ob-tests.yml 基线
- Run: `tools/trace_collect.sh | python3 tools/coverage_radar.py - --cross-check 2>&1 | grep -E 'TOTAL|UNCOVERED'`
- Expected: 输出实际 uncovered 数 N。grilling 目标 10→7。**硬约束：N 必须 < 10（至少降 1），否则停下来说明残差项（哪些函数仍 uncovered），不要把阈值平移成 10——那等于声称闭合盲区但覆盖率无实质提升。** 预期 N 在 7-9（残差来自 download_and_replace wrapper 的 flock 编排段难测 + ensure_qemu_binary_custom 的 TTY 段）；把 `.github/workflows/ob-tests.yml` 的 `--fail-if-uncovered 10` 改为 `--fail-if-uncovered <N>`，并在 commit message 注明降幅与残差项。
- [ ] Step 4: 最终 ob_check 全绿
- Run: `tools/ob_check.sh`
- Expected: `ALL GREEN`（含新 1c-quat gate + run_all 含两个新测试文件）。

## 执行纪律

- 开始实现前，先批判性复查整份计划；若发现缺项、矛盾、命名不一致或验证命令无效，先修计划。特别注意三处对 grilling 共识的细化（架构快照，含评审 M1 的 acquire 出锁）是否符合预期，不符则在审阅时回退。
- 按任务顺序（Task 1→8）执行，不要无声跳步、合并步或改变任务目标。依赖链：Task 2→3（resolve_*）；Task 4/5→6（acquire/commit）；Task 1/2/4/5→7（gate 检查的函数名）；Task 1/4/5→8（matrix 登记的 test 文件）。
- 每完成一个任务，运行该任务 Step 4/5 的验证命令，确认 rc=0/预期输出再进下一个。
- 每个任务的 grep 验证用 `grep -q` + `!` 反转 + `test "$(grep -c ...)" -eq N` 形式，确保退出码正确归位（`grep -c` 输出 0 时 rc=1 会误判）；Run 命令以 test/!grep/ob_check 收尾，不让中间 echo 吞 rc。
- 遇到阻塞、重复失败或计划与仓库现实不符，立即停下来说明，不要猜。
- working tree 内 commit 是安全迭代手段；开始实现前建议开新分支（如 `feature/qemu-binary-deepening`），或与用户确认分支策略。
- 计划里的行号锚点（@273、@392、@417 等）会随任务推进漂移；定位插入点用符号锚（函数名 + `grep -n '^funcname' lib/qemu_binary.sh` 重锚），行号仅作辅助。
- 改动 `lib/qemu_binary.sh` 后（Task 1-6），Task 6 及之后每个任务完成必跑 `tools/ob_check.sh` 做配套自检（见最终验证）。

## 最终验证

- Run: `tools/ob_check.sh`
- Expected: 全部 `ok`——
  - extract_funcs: ob GAPS=0 + lib 三段全清
  - 1b/1c/1c-bis/1c-ter 既有 surface gate: 通过
  - 1c-quat 新 gate: `qemu_binary leaf-pure 原语无 exit`
  - shellcheck baseline: 一致（无新增告警）
  - exit-contract: `Y: PASS`（5 个新原语不 exit，qemu_binary.sh 仍是 direct-exit basename，7 个 ensure_* exit 保留合法）
  - run_all: `ALL GREEN`（含 `tests/unit/qemu_binary_resolve.sh` + `tests/orchestration/qemu_binary_replace.sh` 自动发现并过）
- Run: `bash tests/unit/qemu_binary_resolve.sh && bash tests/orchestration/qemu_binary_replace.sh`
- Expected: 两个测试文件末行均 `PASS=... FAIL=0`，rc=0。
- Run: `tools/trace_collect.sh | python3 tools/coverage_radar.py - --cross-check`
- Expected: `coverage_matrix.md:76-77` 声明的函数不在 UNCOVERED 列；实际 uncovered ≤ ob-tests.yml 新阈值。
- 如 ob_check 任一段 `bad`，先修该段再继续；不要在 ob_check 红的情况下声称完成。

## 审阅 Checkpoint

- 计划正文结束。请先审阅这份计划（可交另一 agent 碰撞评审）；如需修改，指出后我修订并重跑 inline 自检。
- 审阅通过前，不进入实现。批准后默认由普通编码 agent 或人工按 Task 1→8 顺序执行。
- 三处需审阅确认的实现细化：(1) 接口形态从"echo token + outvar path"改为 outvar 编码 `ok:<path>`/`err_*`（避 `$()` 子 shell printf -v 陷阱）；(2) backup 名派生 `${old_build:-unknown}` 不抽函数（单行参数扩展，over-engineering）；(3) acquire 在 flock 外、仅 commit 进 flock（grilling 决策3 选项 A 流程描述「flock 包整个」与 label/行为声明「acquire 出锁」矛盾，plan 取 label 一致方向，Task 6 实现）。评审 M1 推荐反过来改文案为"全程持锁"（选项1），我不同意——那会架空 grilling 的「acquire 出锁」label 与「锁缩短」行为声明；理由见架构快照细化3。如不接受任一细化，回退到对应 grilling 字面，我相应调整。
