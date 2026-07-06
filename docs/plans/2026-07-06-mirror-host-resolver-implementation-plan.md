# mirror-host resolver 实施计划

## 目标

- 在 `lib/repo.sh` 抽出 leaf-pure 原语 `detect_runtime_git_host`，收敛「runtime Git mirror host 提取」在 bash 内的重复实现（`lib/repo.sh:ensure_bootstrap_local_conf` 与 `lib/init_pipeline.sh:clone_sub_repos` 的 GITLAB_IP 分支各写一遍）。
- 删除生产代码零调用的死函数 `lib/util.sh:is_private_url`，及其在 `tests/unit/url_extra.sh` 的测试 case。
- python 侧 `tools/parse_bitbake_deps.py:_detect_runtime_git_host` **维持独立，不动**（不跨语言 DRY）。
- 给 `detect_runtime_git_host` 补 unit 测试，更新 `tools/coverage_matrix.md`。

不在本次范围：`ensure_bootstrap_local_conf` 的 `git config --global` 副作用真测、`clone_sub_repos` 通用 `${VAR}` 展开器的 unit 覆盖、python 侧任何改动。

## 架构快照

「runtime Git mirror host 提取」当前在 bash 两处各写一遍，逻辑等价（vendor 脚本 `meta-*/git-mirror-url.sh` 的 `GITLAB_IP|GIT_MIRROR_HOST` 优先，fallback 主仓 origin），但实现细节不一致（origin 提取：repo.sh 用 `git remote get-url`，init_pipeline 用 `.git/config` 文件解析）。抽成一个 leaf-pure 原语 `detect_runtime_git_host` 放进 `lib/repo.sh`（与 `normalize_repo_url`/`is_valid_repo_url` 同族），两个调用方各改为一行调用。原语带一次性全局缓存——`clone_sub_repos` 遍历 ~570 个 dep repo，每个含 `${GITLAB_IP}` 的 clone_url 都会触发解析，不缓存会重算 N 次。

领域术语 `runtime Git mirror host` 已补进 `CONTEXT.md`（纯 glossary）。

## 全局约束

- **leaf-pure 契约**：`detect_runtime_git_host` 绝不 `exit`。`repo.sh` 是 direct-exit basename（不在 `exit_contract.py` 的 leaf-pure 集合），`exit_contract.py` **不会**检查该函数是否 exit——它只验全局 exit-code 契约。本次**自愿** leaf-pure，用 Task 1 Step 4 的函数体 `awk` 静态检查钉住（函数体内无命令词 `exit`）；拿到/拿不到 host 都 `return 0`，「拿不到 host」是配置缺失，由调用者决定 remedy。
- **缓存是硬要求**：必须用全局哨兵变量区分「已求值（值为空）」与「未求值」，不能用 `[[ -n "$var" ]]` 判断（host 本身可能合法为空）。
- **init_pipeline 边界保留**：`clone_sub_repos` 的通用 `${VAR}` 展开循环、local.conf fallback、URL rewrite 表**必须原样保留**；只替换 GITLAB_IP/GIT_MIRROR_HOST 的 script+origin 提取那一段。
- **不改 python**：`tools/parse_bitbake_deps.py` 一行不动。
- **改 lib 后必须跑 `tools/ob_check.sh`**（结构/函数登记/shellcheck baseline/exit-contract/run_all 一站式自检）。
- 命名：函数 `detect_runtime_git_host`（无前缀，跟随 `repo.sh` 现有函数风格）；缓存哨兵 `_RUNTIME_GIT_HOST` + `_RUNTIME_GIT_HOST_RESOLVED`。
- shell：`bash`；测试断言用 `tests/lib/assert.sh`（`assert_true`/`assert_eq`/`assert_rc`/`assert_false`）。

## 输入工件

- 设计决策来自 `/grill-with-docs` 会话（本仓库，2026-07-06）：范围/形状/归属/契约/落地五项已敲定。
- 领域术语：`CONTEXT.md` → `runtime Git mirror host`、`source manifest`。
- 无独立设计文档；本计划即设计落点。

## 文件结构与职责

- Modify: `lib/repo.sh` — 新增 `detect_runtime_git_host`（Task 1）；`ensure_bootstrap_local_conf` 改调它（Task 2）。
- Modify: `lib/init_pipeline.sh` — `clone_sub_repos` 的 GITLAB_IP/GIT_MIRROR_HOST 分支改调它（Task 3）。
- Modify: `lib/util.sh` — 删 `is_private_url`（Task 4）。
- Modify: `tests/unit/url_extra.sh` — 删 `is_private_url` case、加 `detect_runtime_git_host` 6 case（fallback 4 + cache 2，共 8 assert）（Task 4 + Task 5）。
- Modify: `tests/orchestration/clone_sub_repos.sh` — Task 3 Step 4b 新增 GITLAB_IP 展开分支回归锁（2 assert）。
- Modify: `tools/coverage_matrix.md` — 横切行去 `is_private_url`（Task 4）；init 行加 `detect_runtime_git_host`（Task 5）。
- 不动：`tools/parse_bitbake_deps.py`、`ob`、其余 `lib/*.sh`、`tests/` 其他文件（除上述 `tests/orchestration/clone_sub_repos.sh` 与 `tests/unit/url_extra.sh`）。
- 边界稳定：`ensure_bootstrap_local_conf` 的 `git config --global url.git@…:.insteadOf` 副作用段、`local.conf` include 注入段保持不变；`clone_sub_repos` 的通用 `${VAR}` local.conf fallback 与 URL rewrite 表保持不变。

## 任务清单

### Task 1: lib/repo.sh 新增 detect_runtime_git_host 原语

- 目标：在 `lib/repo.sh` 加一个带缓存的 leaf-pure 原语，提取 runtime Git mirror host。
- Files:
  - Modify: `lib/repo.sh`（在 `is_valid_repo_url` 之后、`normalize_repo_url` 之前插入）
- 接口契约:
  - Consumes: 全局 `$OPENBMC_DIR`（由 `detect_harness_root` 设置；未设时函数 gracefully 返回空）
  - Produces: 函数 `detect_runtime_git_host`（无参 → echo host 或空串 → 恒 `return 0`）；副作用：首次调用后设置全局 `_RUNTIME_GIT_HOST`、`_RUNTIME_GIT_HOST_RESOLVED`
  - 调用约定：**需要缓存生效的生产调用必须 direct call**（`detect_runtime_git_host >/dev/null`，再读 `${_RUNTIME_GIT_HOST:-}`）。`$(detect_runtime_git_host)` 在 subshell 执行，函数内设置的全局缓存回不到调用者、缓存失效；`$()` 只适合测试或一次性 echo 捕获（tests/ 下允许）。Task 6 Step 1b 用生产面 grep 锁住 lib/ob 不出现 `$()` 调用。
- 验证范围: 函数已定义；source 后可调用且 `return 0`；`exit_contract.py` 仍通过；`shellcheck lib/repo.sh` 无新告警。

- [ ] Step 1: 确认当前不存在该函数
- Run: `! grep -q '^detect_runtime_git_host()' lib/repo.sh`
- Expected: 命令成功（退出码 0），证明函数尚未定义。

- [ ] Step 2: 运行并确认当前基线绿
- Run: `python3 tools/exit_contract.py >/dev/null && echo EC_OK`
- Expected: 输出 `EC_OK`（改动前 exit_contract 必须已绿，否则后续无法判断是否本次引入）。

- [ ] Step 3: 写最小实现
- Change: 在 `lib/repo.sh` 的 `is_valid_repo_url()` 之后插入下面的函数。

```bash
# detect_runtime_git_host — 提取 runtime Git mirror host(术语见 CONTEXT.md)。
# vendor 脚本(meta-*/git-mirror-url.sh, legacy github-gitlab-url.sh)的 GIT_MIRROR_HOST/GITLAB_IP 优先;
# fallback 主仓 origin(git remote get-url)。带一次性全局缓存——clone_sub_repos 遍历 ~570 个 dep repo,
# 每个 ${GITLAB_IP} clone_url 都会触发解析,不缓存会重算 N 次。leaf-pure:绝不 exit;
# 拿到/拿不到 host 都 return 0,不报错(配置缺失由调用者决定 remedy)。
# Returns: echo host 或空串,恒 return 0。
detect_runtime_git_host() {
    # 一次性缓存:哨兵变量区分"已求值(值为空)"与"未求值",不用 -n(host 可合法为空)
    if [[ -n "${_RUNTIME_GIT_HOST_RESOLVED+x}" ]]; then
        echo "${_RUNTIME_GIT_HOST:-}"
        return 0
    fi

    # 本地化 OPENBMC_DIR(nounset 自洽):未设/未初始化时 graceful 返回空,不依赖调用者保证
    local openbmc_dir="${OPENBMC_DIR:-}"
    local host=""
    local _rt_script=""
    local _candidate
    if [[ -n "$openbmc_dir" ]]; then
        for _candidate in "$openbmc_dir"/meta-*/git-mirror-url.sh \
                          "$openbmc_dir"/meta-*/github-gitlab-url.sh; do
            [[ -f "$_candidate" ]] && { _rt_script="$_candidate"; break; }
        done
    fi
    if [[ -f "$_rt_script" ]]; then
        host=$(grep -oP '^(GITLAB_IP|GIT_MIRROR_HOST)=["'"'"']?\K[^"'"'"'\s]+' "$_rt_script" 2>/dev/null | head -1 || true)
    fi

    # fallback: 主仓 origin(git 官方 API,比手解 .git/config 文件更稳健)
    if [[ -z "$host" && -n "$openbmc_dir" ]]; then
        local _remote_url=""
        _remote_url=$(git -C "$openbmc_dir" remote get-url origin 2>/dev/null || true)
        if [[ "$_remote_url" == git@* ]]; then
            host=$(printf '%s\n' "$_remote_url" | sed -E 's/^git@([^:]+):.*/\1/')
        elif [[ "$_remote_url" == http://* || "$_remote_url" == https://* ]]; then
            host=$(printf '%s\n' "$_remote_url" | sed -E 's#^https?://([^/:]+).*#\1#')
        fi
    fi

    _RUNTIME_GIT_HOST="$host"
    _RUNTIME_GIT_HOST_RESOLVED=1
    echo "$host"
    return 0
}
```

- [ ] Step 4: 运行并确认通过
- Run: `OB_NO_MAIN=1 source ob 2>/dev/null; declare -F detect_runtime_git_host >/dev/null && echo DEFINED`
- Expected: 输出 `DEFINED`。
- Run: `awk '/^detect_runtime_git_host\(\)/,/^}$/' lib/repo.sh | grep -qw exit && echo HAS_EXIT || echo NO_EXIT`
- Expected: 输出 `NO_EXIT`（函数体无命令词 `exit`——这是「自愿 leaf-pure」的静态锁；`exit_contract.py` 不管 repo.sh 单函数，因为 repo.sh 是 direct-exit basename）。
- Run: `OB_CHECK_SKIP_TESTS=1 OB_CHECK_READONLY=1 tools/ob_check.sh 2>&1 | grep -E 'extract_funcs|shellcheck|exit-contract' | grep -q '✗' && echo HAS_BAD || echo CHECK_OK`
- Expected: 输出 `CHECK_OK`（对齐仓库 flat 合成 + baseline 门禁口径；readonly 不重生成 baseline，只看 extract_funcs/shellcheck/exit-contract 三段无 `✗`）。

- [ ] Step 5: checkpoint commit
- Run: `git add lib/repo.sh && git commit -m "feat(repo): add detect_runtime_git_host leaf-pure primitive"`
- Expected: commit 成功。

### Task 2: repo.sh ensure_bootstrap_local_conf 改用 detect_runtime_git_host

- 目标：把 `ensure_bootstrap_local_conf` 里手写的「glob 发现 vendor 脚本 + grep GITLAB_IP + fallback origin」段替换为一行函数调用。
- Files:
  - Modify: `lib/repo.sh` 的 `ensure_bootstrap_local_conf`（当前 `for _candidate … github-gitlab-url.sh` 段 + `git -C … remote get-url origin` fallback 段）
- 接口契约:
  - Consumes: Task 1 的 `detect_runtime_git_host`
  - Produces: 无（行为不变的内部重构）
- 验证范围: 旧的手写提取段被替换；后续 `git config --global url.git@…:.insteadOf` 段与 `local.conf` include 段保留；相关现有测试（`tests/protocol/bitbake_env_entry_contract.sh` 等）仍绿。

- [ ] Step 1: 确认 ensure_bootstrap_local_conf 仍是手写段（函数体范围，避开 detect_runtime_git_host 的 legacy fallback 干扰）
- Run: `awk '/^ensure_bootstrap_local_conf\(\)/,/^}$/' lib/repo.sh | grep -qE 'local _rt_script|git remote get-url origin' && echo LEGACY_PRESENT`
- Expected: 输出 `LEGACY_PRESENT`（旧 inline glob/origin 段仍在 ensure_bootstrap_local_conf 函数体内）。

- [ ] Step 2: 运行并确认当前基线绿
- Run: `OB_CHECK_SKIP_TESTS=1 OB_CHECK_READONLY=1 tools/ob_check.sh >/dev/null 2>&1 && echo CHECK_OK`
- Expected: 输出 `CHECK_OK`。

- [ ] Step 3: 改调用方
- Change: 把 `ensure_bootstrap_local_conf` 中从 `local _rt_script=""` 起到 origin fallback 结束（含 `gitlab_ip=$(… sed …)` 的两个 `if`）整段替换为：

```bash
    local gitlab_ip=""
    detect_runtime_git_host >/dev/null    # direct call:函数内全局缓存不穿透 $() subshell
    gitlab_ip="${_RUNTIME_GIT_HOST:-}"
```

保留下方 `if [[ -n "$gitlab_ip" ]]; then … git config --global url.git@${gitlab_ip}:.insteadOf …` 整段不变，以及 `local include_line=…` 起的 local.conf include 段不变。

- [ ] Step 4: 运行并确认通过
- Run: `awk '/^ensure_bootstrap_local_conf\(\)/,/^}$/' lib/repo.sh | grep -qE 'local _rt_script|git remote get-url origin' && echo LEGACY_PRESENT || echo LEGACY_GONE`
- Expected: 输出 `LEGACY_GONE`（`ensure_bootstrap_local_conf` 函数体内已无旧 inline glob/origin 段；注意 `github-gitlab-url.sh` 字符串仍存在于 `detect_runtime_git_host` 体内，这是预期，不能用它当判据）。
- Run: `awk '/^ensure_bootstrap_local_conf\(\)/,/^}$/' lib/repo.sh | grep -q 'detect_runtime_git_host >/dev/null' && awk '/^ensure_bootstrap_local_conf\(\)/,/^}$/' lib/repo.sh | grep -q 'gitlab_ip="\${_RUNTIME_GIT_HOST:-}"' && echo WIRED`
- Expected: 输出 `WIRED`。
- Run: `awk '/^ensure_bootstrap_local_conf\(\)/,/^}$/' lib/repo.sh | grep -qF 'git config --global' && echo INSTEADOF_KEPT`
- Expected: 输出 `INSTEADOF_KEPT`（insteadOf 副作用段保留）。注:用 `grep -F` 而非 `grep 'url.git@${gitlab_ip}:.insteadOf'`——后者在 BRE 下因 `$` 锚点歧义假阴(执行时实测发现)。
- Run: `bash tests/protocol/bitbake_env_entry_contract.sh >/dev/null 2>&1; echo "rc=$?"`
- Expected: `rc=0`（该测试 stub 掉 `ensure_bootstrap_local_conf`，但仍 source repo.sh，确保新函数不破坏 source）。

- [ ] Step 5: checkpoint commit
- Run: `git add lib/repo.sh && git commit -m "refactor(repo): ensure_bootstrap_local_conf uses detect_runtime_git_host"`
- Expected: commit 成功。

### Task 3: init_pipeline.sh clone_sub_repos 的 GITLAB_IP 分支改用 detect_runtime_git_host

- 目标：把 `clone_sub_repos` 展开循环里 GITLAB_IP/GIT_MIRROR_HOST 的 script+origin 提取段替换为函数调用；**保留**通用 `${VAR}` 的 local.conf fallback 与 URL rewrite 表。
- Files:
  - Modify: `lib/init_pipeline.sh` 的 `clone_sub_repos`（GITLAB_IP/GIT_MIRROR_HOST 分支段）
- 接口契约:
  - Consumes: Task 1 的 `detect_runtime_git_host`
  - Produces: 无
- 验证范围: GITLAB_IP/GIT_MIRROR_HOST 的内联 script+origin 提取被替换；local.conf fallback（`if [[ -z "$_vv" && -f "$_local_conf" ]]`）保留；URL rewrite 表（`_url_rewrites` 数组）保留；`tests/orchestration/clone_sub_repos.sh` 仍绿。

- [ ] Step 1: 确认当前仍是内联提取
- Run: `grep -q 'GITLAB_IP|GIT_MIRROR_HOST' lib/init_pipeline.sh && echo INLINE_PRESENT`
- Expected: 输出 `INLINE_PRESENT`。

- [ ] Step 2: 运行并确认当前基线绿
- Run: `bash tests/orchestration/clone_sub_repos.sh >/dev/null 2>&1; echo "rc=$?"`
- Expected: `rc=0`。

- [ ] Step 3: 改调用方
- Change: 在 `clone_sub_repos` 的 `for _vk in $_var_names` 循环内，把下面这段（GITLAB_IP/GIT_MIRROR_HOST 的 script + origin 提取）：

```bash
                if [[ "$_vn" == "GITLAB_IP" || "$_vn" == "GIT_MIRROR_HOST" ]] && [[ -f "$_runtime_script" ]]; then
                    _vv=$(grep -oP '^(GITLAB_IP|GIT_MIRROR_HOST)=["'"'"']?\K[^"'"'"'\s]+' "$_runtime_script" 2>/dev/null | head -1 || true)
                fi

                if [[ -z "$_vv" ]] && { [[ "$_vn" == "GITLAB_IP" || "$_vn" == "GIT_MIRROR_HOST" ]] ; } && [[ -f "$_openbmc_git_config" ]]; then
                    local _remote_url=""
                    _remote_url=$(grep -E '^[[:space:]]*url = (git@|https?)' "$_openbmc_git_config" 2>/dev/null | head -1 | awk '{print $3}')
                    if [[ "$_remote_url" == git@* ]]; then
                        _vv=$(echo "$_remote_url" | sed -E 's/^git@([^:]+):.*/\1/')
                    elif [[ "$_remote_url" == http://* || "$_remote_url" == https://* ]]; then
                        _vv=$(echo "$_remote_url" | sed -E 's#^https?://([^/:]+).*#\1#')
                    fi
                fi
```

替换为：

```bash
                if [[ "$_vn" == "GITLAB_IP" || "$_vn" == "GIT_MIRROR_HOST" ]]; then
                    detect_runtime_git_host >/dev/null   # direct call:缓存不穿透 $() subshell
                    _vv="${_RUNTIME_GIT_HOST:-}"
                fi
```

**可顺带清理**：删除上述段后，循环顶部的 `_runtime_script` 与 `_openbmc_git_config` 两个局部变量声明已无人引用，一并删除；`_local_conf` 仍被下方 local.conf fallback 引用，保留。**不要动**：下方的 `if [[ -z "$_vv" && -f "$_local_conf" ]]` local.conf fallback 段原样保留；`_url_rewrites` 数组与 URL rewrite 循环原样保留。

- [ ] Step 4: 运行并确认通过
- Run: `! grep -qE '_runtime_script|_openbmc_git_config' lib/init_pipeline.sh && echo INLINE_GONE`
- Expected: 输出 `INLINE_GONE`。
- Run: `grep -q 'detect_runtime_git_host >/dev/null' lib/init_pipeline.sh && grep -q '_vv="\${_RUNTIME_GIT_HOST:-}"' lib/init_pipeline.sh && echo WIRED`
- Expected: 输出 `WIRED`。
- Run: `grep -q '_local_conf' lib/init_pipeline.sh && grep -q '_url_rewrites' lib/init_pipeline.sh && echo BOUNDARY_KEPT`
- Expected: 输出 `BOUNDARY_KEPT`（local.conf fallback 引用与 URL rewrite 表都保留）。
- Run: `bash tests/orchestration/clone_sub_repos.sh >/dev/null 2>&1; echo "rc=$?"`
- Expected: `rc=0`。

- [ ] Step 4b: 加 GITLAB_IP 展开分支的 orchestration 回归 case
- Change: 现有 fixture（`deps.json.sample`）两条都是普通 GitHub URL，不覆盖本次改的变量展开分支。在 `tests/orchestration/clone_sub_repos.sh` 末尾（`rm -rf "$TMP" "$DB"` 与 `assert_summary` 之间）追加一个 case，构造含 `${GITLAB_IP}` 的临时 deps.json，断言 `git clone --bare` 收到的是展开后的 URL：

```bash
# --- GITLAB_IP 展开分支(Task3 回归锁):clone_url 含 ${GITLAB_IP} → 展开成 vendor script host ---
TMP3="$(mktemp -d)"; OPENBMC3="$TMP3/openbmc"; mkdir -p "$OPENBMC3/meta-x"
printf 'GITLAB_IP=10.0.0.9\n' > "$OPENBMC3/meta-x/git-mirror-url.sh"
BUILD3="$TMP3/build"; mkdir -p "$BUILD3"
cat > "$BUILD3/deps.json" <<'JSON'
[{"name":"priv","clone_url":"https://${GITLAB_IP}/team/priv.git","src_uri":"git://10.0.0.9/team/priv.git;branch=main","srcrev":"abc","recipe":"r1"}]
JSON
DB3="$(mktemp -d)"; mkfake_bin "$DB3" git
stub_script "$DB3" git 'case "$1" in config) exit 0;; clone) mkdir -p "$4"; exit 0;; esac; exit 0'
with_stub "$DB3" -- bash -c 'OB_NO_MAIN=1 source "$1"
WORKSPACE_DIR="'"$TMP3"'"; OPENBMC_DIR="'"$OPENBMC3"'"; BUILD_DIR="'"$BUILD3"'"; MACHINE="romulus"; DRY_RUN=0
STATUS_MIRROR_NEW=(); STATUS_FAILED=()
clone_sub_repos
' _ "$OB" 2>/dev/null
_calls="$(cat "$DB3/.git.calls" 2>/dev/null)"
assert_contains "GITLAB_IP expanded in clone URL" "$_calls" "10.0.0.9"
assert_false "no unresolved \${GITLAB_IP}" grep -qF '${GITLAB_IP}' "$DB3/.git.calls"
rm -rf "$TMP3" "$DB3"
```

  注意：`clone_sub_repos` 在非 DRY_RUN 路径会调 `git config --global http.postBuffer …`，stub git 的 `config` 分支 `exit 0` 拦截，不会真改宿主全局配置；stub 默认把所有调用参数记进 `.git.calls`，故断言针对该文件。
- Run: `bash tests/orchestration/clone_sub_repos.sh 2>&1 | tail -1`
- Expected: 当前基线 `PASS=4`，新增 2 个 assert 后为 `PASS=6 FAIL=0`（若后续测试数变化，以 `FAIL=0` 且两条新增断言均 ok 为准）。

- [ ] Step 5: checkpoint commit
- Run: `git add lib/init_pipeline.sh tests/orchestration/clone_sub_repos.sh && git commit -m "refactor(init_pipeline): clone_sub_repos GITLAB_IP branch uses detect_runtime_git_host"`
- Expected: commit 成功。

### Task 4: 删 is_private_url 死函数 + 清理测试 case + matrix 横切行

- 目标：删除生产零调用的死函数 `lib/util.sh:is_private_url`，连同它在 `tests/unit/url_extra.sh` 的 case 和 `tools/coverage_matrix.md` 横切行的登记。
- Files:
  - Modify: `lib/util.sh`（删 `is_private_url` 整个函数）
  - Modify: `tests/unit/url_extra.sh`（删 is_private_url 的 7 个 assert 行）
  - Modify: `tools/coverage_matrix.md`（横切「conf/url 工具」行涉及函数列删 `is_private_url`）
- 接口契约:
  - Consumes: 无（独立清理）
  - Produces: 无
- 验证范围: 全仓无 `is_private_url` 残留定义/调用；`exit_contract.py` 仍过（util.sh 例外集 `{fn_quit, resolve_npm_registry, require_path}` 不含 is_private_url，删它不破 Y 规则）；`url_extra.sh` 仍可跑（剩 `parse_hostkey_offending`）。

- [ ] Step 1: 确认 is_private_url 当前是死函数（生产零调用）
- Run: `! grep -rn 'is_private_url' lib/ ob 2>/dev/null | grep -v 'is_private_url()' | grep -q . && echo DEAD_CONFIRMED`
- Expected: 输出 `DEAD_CONFIRMED`（lib/ob 里除定义行外无引用）。

- [ ] Step 2: 运行并确认当前 url_extra 绿
- Run: `bash tests/unit/url_extra.sh >/dev/null 2>&1; echo "rc=$?"`
- Expected: `rc=0`。

- [ ] Step 3: 删函数 + 测试 case + matrix 行
- Change:
  1. 删 `lib/util.sh` 的 `is_private_url()` 整个函数（从 `# Check whether a URL points to a private/internal host.` 注释块到函数结束）。
  2. 删 `tests/unit/url_extra.sh` 里 `is_private_url` 的 7 行 assert（`assert_true "private 10/8" is_private_url …` 到 `assert_false "bare ip no proto" is_private_url '10.0.0.1'`）；保留文件头的 `# 覆盖 is_private_url / parse_hostkey_offending。` 注释待 Task 5 更新，以及 `parse_hostkey_offending` 的两行 assert。
  3. `tools/coverage_matrix.md` 横切「conf/url 工具」行的涉及函数列：删 `is_private_url`（保留 `read_local_conf_var;resolve_effective_dl_dir;resolve_effective_sstate_dir;parse_hostkey_offending;machine_conf_chain_contains`）。

- [ ] Step 4: 运行并确认通过
- Run: `! grep -rn 'is_private_url' lib/ tests/ ob tools/*.py tools/*.sh tools/*.md 2>/dev/null | grep -q . && echo NO_RESIDUE || echo RESIDUE_FOUND`
- Expected: 输出 `NO_RESIDUE`（活跃代码/测试/matrix 无残留）。`tools/archive/reorder.py` 是 § 归类的冻结历史快照（记录 ob 拆 lib 前的旧结构），刻意不扫、不改；如需清理归档另立任务。
- Run: `python3 tools/exit_contract.py >/dev/null && echo EC_OK`
- Expected: 输出 `EC_OK`。
- Run: `bash tests/unit/url_extra.sh 2>&1 | tail -1`
- Expected: 形如 `PASS=2 FAIL=0`（只剩 parse_hostkey_offending 的 2 个 assert；FAIL=0）。

- [ ] Step 5: checkpoint commit
- Run: `git add lib/util.sh tests/unit/url_extra.sh tools/coverage_matrix.md && git commit -m "chore(util): remove dead is_private_url + cleanup tests/matrix"`
- Expected: commit 成功。

### Task 5: 给 detect_runtime_git_host 加 unit case + matrix init 行

- 目标：在 `tests/unit/url_extra.sh` 加 `detect_runtime_git_host` 的 6 个 case（fallback 链 4 + 缓存幂等 2，共 8 个 assert）；`tools/coverage_matrix.md` init 行登记覆盖。
- Files:
  - Modify: `tests/unit/url_extra.sh`
  - Modify: `tools/coverage_matrix.md`（init 节「子仓库克隆」行涉及函数加 `detect_runtime_git_host`）
- 接口契约:
  - Consumes: Task 1 的 `detect_runtime_git_host`
  - Produces: 无
- 验证范围: `url_extra.sh` 全绿（6 个新 case = fallback 4 + cache 2，共 8 assert，+ 既有 parse_hostkey_offending）；matrix 登记 detect_runtime_git_host 覆盖。

- [ ] Step 1: 确认当前 url_extra 未测 detect_runtime_git_host
- Run: `! grep -q 'detect_runtime_git_host' tests/unit/url_extra.sh && echo NOT_YET`
- Expected: 输出 `NOT_YET`。

- [ ] Step 2: 运行并确认当前绿
- Run: `bash tests/unit/url_extra.sh >/dev/null 2>&1; echo "rc=$?"`
- Expected: `rc=0`。

- [ ] Step 3: 加测试 case
- Change: 把 `tests/unit/url_extra.sh` 头部注释更新为 `# 覆盖 detect_runtime_git_host / parse_hostkey_offending。`；在 `is_private_url` 旧位置（已 Task 4 删除）补上 6 个 case（fallback 链 4 + 缓存幂等 2）。fallback case 用 `$(detect_runtime_git_host)` 捕获（subshell 首次求值即可，不依赖缓存）；缓存 case 必须 direct call（见下）。测试用 stub `$OPENBMC_DIR` 指向临时目录构造 vendor 脚本 / origin：

```bash
# detect_runtime_git_host: vendor 脚本 GITLAB_IP 优先 → fallback origin(git@/https) → 空
_save_openbmc="${OPENBMC_DIR:-}"
TMP2=$(mktemp -d)
mkdir -p "$TMP2/meta-x"

# case 1: vendor 脚本含 GITLAB_IP
OPENBMC_DIR="$TMP2"
printf 'GITLAB_IP=10.0.0.9\n' > "$TMP2/meta-x/git-mirror-url.sh"
assert_eq "host from GITLAB_IP script" "$(detect_runtime_git_host)" "10.0.0.9"
unset _RUNTIME_GIT_HOST_RESOLVED _RUNTIME_GIT_HOST   # 清缓存,每个 case 独立

# case 2: vendor 脚本含 GIT_MIRROR_HOST
rm -f "$TMP2/meta-x/git-mirror-url.sh"; printf 'GIT_MIRROR_HOST=mirror.local\n' > "$TMP2/meta-x/git-mirror-url.sh"
assert_eq "host from GIT_MIRROR_HOST script" "$(detect_runtime_git_host)" "mirror.local"
unset _RUNTIME_GIT_HOST_RESOLVED _RUNTIME_GIT_HOST

# case 3: 无 vendor 脚本 → fallback .git/config origin(用 git remote get-url,需真 git 仓)
rm -f "$TMP2/meta-x/git-mirror-url.sh"; rmdir "$TMP2/meta-x"
git init -q "$TMP2/openbmc-repo" 2>/dev/null
git -C "$TMP2/openbmc-repo" remote add origin git@gitlab.example.com:team/repo.git 2>/dev/null
OPENBMC_DIR="$TMP2/openbmc-repo"
assert_eq "host from git@ origin" "$(detect_runtime_git_host)" "gitlab.example.com"
git -C "$TMP2/openbmc-repo" remote set-url origin https://gitlab2.example.com/team/repo.git 2>/dev/null
unset _RUNTIME_GIT_HOST_RESOLVED _RUNTIME_GIT_HOST
assert_eq "host from https origin" "$(detect_runtime_git_host)" "gitlab2.example.com"
unset _RUNTIME_GIT_HOST_RESOLVED _RUNTIME_GIT_HOST

# case 4: 都没有 → 空 + return 0
OPENBMC_DIR="$TMP2/no-such"
assert_rc 0 "empty host returns 0" detect_runtime_git_host
assert_eq "empty host echoes nothing" "$(detect_runtime_git_host)" ""
unset _RUNTIME_GIT_HOST_RESOLVED _RUNTIME_GIT_HOST

# case 5: 缓存幂等——首次求值后改 script,第二次仍返回缓存值(钉"不重算")
#   detect 内全局缓存不穿透 $() subshell,故 case5/6 用 direct call + 读 _RUNTIME_GIT_HOST
mkdir -p "$TMP2/meta-x"
printf 'GITLAB_IP=10.0.0.9\n' > "$TMP2/meta-x/git-mirror-url.sh"
OPENBMC_DIR="$TMP2"
detect_runtime_git_host >/dev/null
first="${_RUNTIME_GIT_HOST:-}"
printf 'GITLAB_IP=10.0.0.10\n' > "$TMP2/meta-x/git-mirror-url.sh"   # 改 script,不 unset 缓存
detect_runtime_git_host >/dev/null
second="${_RUNTIME_GIT_HOST:-}"
assert_eq "cache returns first value" "$first" "10.0.0.9"
assert_eq "cache: 2nd call unchanged" "$second" "10.0.0.9"
unset _RUNTIME_GIT_HOST_RESOLVED _RUNTIME_GIT_HOST

# case 6: 哨兵区分"已求值空"vs"未求值"——首次空后补 script,未 unset 仍空(钉哨兵用 ${x+x} 而非 -n)
rm -f "$TMP2/meta-x/git-mirror-url.sh"
OPENBMC_DIR="$TMP2/no-such3"   # 无 vendor script 无 origin
detect_runtime_git_host >/dev/null
empty_first="${_RUNTIME_GIT_HOST:-}"
assert_eq "first call empty" "$empty_first" ""
OPENBMC_DIR="$TMP2"; printf 'GITLAB_IP=10.0.0.9\n' > "$TMP2/meta-x/git-mirror-url.sh"   # 补 script
detect_runtime_git_host >/dev/null   # 未 unset,用缓存(空)
still_empty="${_RUNTIME_GIT_HOST:-}"
assert_eq "cached empty sticks until unset" "$still_empty" ""
unset _RUNTIME_GIT_HOST_RESOLVED _RUNTIME_GIT_HOST

rm -rf "$TMP2"
OPENBMC_DIR="$_save_openbmc"
unset _RUNTIME_GIT_HOST_RESOLVED _RUNTIME_GIT_HOST
```

  并在 `tools/coverage_matrix.md` init 节「子仓库克隆」行的涉及函数列追加 `detect_runtime_git_host`（覆盖 test 列已有 `unit/url_extra.sh` 则补，否则加）。

- [ ] Step 4: 运行并确认通过
- Run: `bash tests/unit/url_extra.sh 2>&1 | tail -1`
- Expected: `PASS=8 FAIL=0`（parse_hostkey_offending 2 + detect fallback 4 + cache 2）。
- Run: `grep -q 'detect_runtime_git_host' tools/coverage_matrix.md && echo MATRIX_UPDATED`
- Expected: 输出 `MATRIX_UPDATED`。

- [ ] Step 5: checkpoint commit
- Run: `git add tests/unit/url_extra.sh tools/coverage_matrix.md && git commit -m "test(repo): unit-cover detect_runtime_git_host + matrix"`
- Expected: commit 成功。

### Task 6: 最终验证 ob_check.sh

- 目标：改完 lib + tests + matrix 后，跑一站式自检确认全绿，并处理 shellcheck baseline 的良性重生成。
- Files: 无（只跑检查）
- 接口契约:
  - Consumes: Task 1–5 全部产出
  - Produces: 可能更新的 `tests/.shellcheck-baseline`（良性重生成）
- 验证范围: `tools/ob_check.sh` 全部 ✓；若有 shellcheck baseline 重生成，`git diff tests/.shellcheck-baseline` 确认是良性（告警减少/行号平移），无新增告警类型。

- [ ] Step 1: 跑一站式自检
- Run: `tools/ob_check.sh; echo "rc=$?"`
- Expected: `rc=0`，输出全 `✓`（含 `extract_funcs`、`machine-state surface`、`shellcheck baseline`、`exit-contract`、`run_all ALL GREEN`）。

- [ ] Step 1b: 生产代码无 `$()` 调 detect（防缓存静默失效的回潮门禁）
- Run: `! grep -RnF '$(detect_runtime_git_host)' lib/ ob 2>/dev/null | grep -q . && echo NO_SUBSHELL_PROD_CALLERS || echo SUBSHELL_CALLER_FOUND`
- Expected: 输出 `NO_SUBSHELL_PROD_CALLERS`。生产调用必须 direct call 才能让全局缓存穿透 subshell；`$()` 只允许出现在 tests/（此 grep 不扫 tests/）。若输出 `SUBSHELL_CALLER_FOUND`，把对应生产调用改为 direct call + 读 `${_RUNTIME_GIT_HOST:-}`。

- [ ] Step 2: 若 shellcheck baseline 被重生成，确认良性
- Run: `git diff --stat tests/.shellcheck-baseline`
- Expected: 若有 diff，内容仅为告警条目减少或行号变化（删 is_private_url 减少了告警是预期良性），**不出现新的告警类型/实例**。若 ob_check.sh 报 `✗ shellcheck 新增告警`，回到对应 Task 修告警，不要直接 regenerate 掩盖。

- [ ] Step 3: 跑一次完整 protocol 层确认 exit-code 契约未破
- Run: `bash tests/run_all.sh 2>&1 | tail -5`
- Expected: 无 `FAIL` 行（`.sh` 快速子集全绿）。

## 评审焦点（给独立评审 agent）

本次计划由 `/grill-with-docs` 敲定，评审 agent 无该上下文。重点 challenge 以下几点：

1. **缓存的正确性**（Task 1）：哨兵用 `${_RUNTIME_GIT_HOST_RESOLVED+x}` 区分「已求值为空」与「未求值」——host 合法可为空，不能用 `[[ -n ]]`。验证：case 4（都没有）能正确 echo 空 且 return 0，且不影响后续 case（每个 case `unset` 哨兵）。
2. **Task 3 的边界保留**：是否真的只替换了 GITLAB_IP/GIT_MIRROR_HOST 的 script+origin 提取段，而通用 `${VAR}` 的 local.conf fallback（`if [[ -z "$_vv" && -f "$_local_conf" ]]`）与 URL rewrite 表（`_url_rewrites`）原样保留。这是硬约束，破了会改变 init 行为。
3. **origin 提取机制统一**（Task 1）：原 init_pipeline/py 用手解 `.git/config` 文件，本计划统一为 `git remote get-url origin`（更稳健）。评审可挑战：是否存在「git 未安装 / .git 存在但 remote 未配」等场景下两种机制行为不同的边缘情况。注意：原 repo.sh 已用 `git remote get-url`，本次是让 init_pipeline 对齐 repo.sh，不是引入全新机制。
4. **is_private_url 是否真死**（Task 4）：Step 1 的 grep 应在合并前重跑确认（生产代码无 `is_private_url` 调用）。若评审发现任何调用点，Task 4 必须暂停。
5. **不跨语言 DRY 的边界**：python `_detect_runtime_git_host` 维持独立是本次明确决策（理由：双栈同概念重复是固有代价，跨语言共享的进程/契约开销不划算；vendor 脚本命名中期稳定）。评审若认为 drift 风险被低估，可就此提出。

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行（Task 1 → 6），不要无声跳步、合并步或改变任务目标；Task 2/3/5 都依赖 Task 1。
- 每完成一个任务，运行该任务 Step 4 的验证，确认 Expected 才进下一个。
- 遇到阻塞、重复失败或计划与仓库现实不符（如 grep 锚点对不上、assert 数量不符），立即停下说明，不要猜。
- 当前在 `main` 分支：开始实现前与用户确认是否新建分支（如 `feature/mirror-host-resolver`）。
- 全部任务完成后，运行 Task 6 最终验证并输出修改摘要。

## 最终验证

- Run: `tools/ob_check.sh && bash tests/run_all.sh`
- Expected: `ob_check.sh` 全 `✓`、`rc=0`；`run_all.sh` 无 `FAIL` 行；`git diff tests/.shellcheck-baseline`（若有）仅良性差异。
- 环境前提：Linux + bash + git + python3 + shellcheck（ob_check.sh 依赖）。

## 审阅 Checkpoint

- 计划正文到此结束。请先审阅这份计划；如无问题，下一步可按计划由普通编码 agent 或人工继续执行。
- 审阅通过前，不进入实现。
