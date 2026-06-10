# npm 注册表自动检测 + 超时配置 实施计划

## 目标

`ob build` 在编译 webui-vue 等含 `npm install` 的 recipe 时，自动选择最快的 npm 注册表（npmjs.org 或 npmmirror.com），并注入合理的超时参数。用户无需手动配置；可通过 `OB_NPM_REGISTRY` 环境变量覆盖或禁用自动检测。

## 架构快照

npm 配置通过两条路径注入 BitBake 构建环境，缺一不可：

1. **`.inc` 文件（`generate_build_config()` 生成）**：用 `??=` 弱默认设置超时值，用 `export` 标记变量为 task 环境导出。对 `npm_config_registry` 只做 `export`（无值），实际值由路径 2 提供。
2. **进程环境变量（`cmd_build()` 设置）**：在 `bitbake` 调用前 export `npm_config_registry`（来自自动探测）和超时变量，并注册到 `BB_ENV_PASSTHROUGH_ADDITIONS` 让 BitBake 的 `clean_environment()` 保留它们。

BitBake 环境变量传播完整路径（已通过源码验证）：
- Shell export → `BB_ENV_PASSTHROUGH_ADDITIONS` 保留 → `inheritFromOS()` 写入 datastore → `.inc` 中 `export` 标记导出 → task shell 环境 → npm 读取

注册表选择决策：
- 默认选择 npmmirror.com（国内镜像），只有 mirror 慢（≥2s）且 npmjs.org 快（<1s）时才切换
- 并行探测两个源（下载 `uuid-9.0.0.tgz`，~16KB）
- 两个都超时 → 报错退出
- 结果缓存 24h 到 `$CONFIGS_DIR/$MACHINE.npm-registry`

## 输入工件

- 已验证的 BitBake 环境变量传播路径分析（本次会话中完成）
- 已创建的 best practice skill：`rules/skills/bestpractice_05-npm_network_timeout_in_yocto.md`
- 原始错误日志和工程师解决方案文档（用户提供）

## 文件结构与职责

- Modify：`ob`
  - `generate_build_config()` — 添加 npm 超时 export 到 `.inc` 文件
  - 新增 `probe_npm_registry()` — 并行探测两个 npm 源的下载速度
  - 新增 `resolve_npm_registry()` — 完整决策树（env var → cache → probe → error）
  - `cmd_build()` — 在 bitbake 调用前调用 `resolve_npm_registry()` 并 export + `BB_ENV_PASSTHROUGH_ADDITIONS`
  - `usage()` — 添加 `OB_NPM_REGISTRY` 环境变量说明
- Modify：`rules/skills/bestpractice_05-npm_network_timeout_in_yocto.md` — 添加 ob build 自动处理说明

## 任务清单

### Task 1: 在 generate_build_config() 添加 npm 超时配置到 .inc 文件

- 目标：`.inc` 文件包含 npm 超时弱默认值和 export 标记，使所有 npm task 自动获得合理超时
- 涉及文件：`ob` → `generate_build_config()` 函数
- 验证范围：对已初始化的 machine 运行 `ob init` 后，`.inc` 文件包含 npm 相关行

- [ ] Step 1: 确认当前 .inc 文件不包含任何 npm 配置
- Run: `grep -c 'npm' /bmc/iasi/ob-harness/workspace/openbmc/build/*/conf/externalsrc-*.inc 2>/dev/null || echo "0 matches"`
- Expected: 0 matches

- [ ] Step 2: 在 `generate_build_config()` 的 brace block 内，`SSTATE_DIR` 行之后、WSL 条件块之前，添加 npm 配置块
- Change: 在 `echo "SSTATE_DIR ??= \"$WORKSPACE_DIR/sstate-cache\""` 之后插入：
```bash
        echo ""
        echo "# npm network timeout defaults for Node.js recipes (e.g. webui-vue)."
        echo "# Override in local.conf with = if needed. Registry is auto-detected by 'ob build'."
        echo "npm_config_fetch_timeout ??= \"600000\""
        echo "export npm_config_fetch_timeout"
        echo "npm_config_fetch_retry_maxtimeout ??= \"120000\""
        echo "export npm_config_fetch_retry_maxtimeout"
        echo "npm_config_fetch_retry_mintimeout ??= \"30000\""
        echo "export npm_config_fetch_retry_mintimeout"
        echo "npm_config_fetch_retry_factor ??= \"2\""
        echo "export npm_config_fetch_retry_factor"
        echo "# npm_config_registry is NOT set here — it is injected dynamically by 'ob build'"
        echo "# via BB_ENV_PASSTHROUGH_ADDITIONS. Setting it to empty would break direct bitbake."
```

- [ ] Step 3: 对已初始化的 machine 重新运行 `ob init` 并检查 .inc 文件
- Run: `cd /bmc/iasi/ob-harness && ./ob init romulus -d 2>&1 | grep -A5 npm`（dry-run 预览）
- Expected: 输出中显示 npm 相关 echo 行

- [ ] Step 4: 验证 .inc 文件内容正确
- Run: `cat /bmc/iasi/ob-harness/workspace/openbmc/build/romulus/conf/externalsrc-romulus.inc | grep -A2 npm`
- Expected: 看到超时 `??=` 行和 `export` 行

### Task 2: 新增 probe_npm_registry() 函数

- 目标：实现并行探测两个 npm 源下载速度的函数，返回选择的 registry URL
- 涉及文件：`ob` → 在 `calc_parallelism()`（~1554 行）之后插入新函数
- 验证范围：函数在 `ob` 脚本中可被调用，source 不报语法错误

- [ ] Step 1: 确认 `ob` 脚本当前没有 `probe_npm_registry` 函数
- Run: `grep -c 'probe_npm_registry' /bmc/iasi/ob-harness/ob`
- Expected: 0

- [ ] Step 2: 在 `calc_parallelism()` 函数之后（`}` 结束行后），`list_available_machines()` 之前，插入 `probe_npm_registry()` 函数
- Change: 插入以下函数（核心逻辑）：
```bash
# Probe both npm registries in parallel, return the URL of the faster one.
# Default preference: npmmirror.com (Chinese mirror).
# If npmjs.org is clearly faster (<3s AND <1.5× mirror time), prefer npmjs.org.
# Returns: echoes registry URL, or empty string if both fail.
probe_npm_registry() {
    local npmjs_url="https://registry.npmjs.org/uuid/-/uuid-9.0.0.tgz"
    local mirror_url="https://registry.npmmirror.com/uuid/-/uuid-9.0.0.tgz"
    local tmp_npmjs tmp_mirror

    if ! command -v curl &>/dev/null; then
        verbose "curl not available, defaulting to npmmirror.com"
        echo "https://registry.npmmirror.com/"
        return 0
    fi

    tmp_npmjs=$(mktemp /tmp/ob-npm-probe-npmjs-XXXXXX)
    tmp_mirror=$(mktemp /tmp/ob-npm-probe-mirror-XXXXXX)

    # Parallel probes — each writes download time (seconds) to a temp file
    { curl -s -o /dev/null -w '%{time_total}' --max-time 10 "$npmjs_url" > "$tmp_npmjs" 2>/dev/null; } &
    local pid_npmjs=$!
    { curl -s -o /dev/null -w '%{time_total}' --max-time 10 "$mirror_url" > "$tmp_mirror" 2>/dev/null; } &
    local pid_mirror=$!

    wait "$pid_npmjs" 2>/dev/null || true
    wait "$pid_mirror" 2>/dev/null || true

    local npmjs_time="" mirror_time=""
    npmjs_time=$(cat "$tmp_npmjs" 2>/dev/null | tr -d '[:space:]')
    mirror_time=$(cat "$tmp_mirror" 2>/dev/null | tr -d '[:space:]')
    rm -f "$tmp_npmjs" "$tmp_mirror"

    verbose "  npmjs.org: ${npmjs_time:-timeout}s | npmmirror.com: ${mirror_time:-timeout}s"

    # Both failed
    if [[ -z "$npmjs_time" ]] && [[ -z "$mirror_time" ]]; then
        echo ""
        return 0
    fi

    # Only one succeeded — use it
    if [[ -z "$npmjs_time" ]]; then
        echo "https://registry.npmmirror.com/"
        return 0
    fi
    if [[ -z "$mirror_time" ]]; then
        echo "https://registry.npmjs.org/"
        return 0
    fi

    # Both succeeded — pick the better one.
    # npmmirror.com is the safe default. Only switch to npmjs.org when
    # the mirror is genuinely slow and npmjs.org is clearly fast.
    local mirror_fast=0
    if awk "BEGIN { exit !($mirror_time < 2) }" 2>/dev/null; then
        mirror_fast=1
    fi

    if [[ "$mirror_fast" -eq 1 ]]; then
        echo "https://registry.npmmirror.com/"
    elif awk "BEGIN { exit !($npmjs_time < 1) }" 2>/dev/null; then
        echo "https://registry.npmjs.org/"
    else
        echo "https://registry.npmmirror.com/"
    fi
}
```

- [ ] Step 3: 验证脚本语法正确
- Run: `bash -n /bmc/iasi/ob-harness/ob && echo "syntax OK"`
- Expected: `syntax OK`

### Task 3: 新增 resolve_npm_registry() 函数

- 目标：实现完整决策树函数（env var → cache → probe → error），设置 `NPM_REGISTRY_RESOLVED` 全局变量
- 涉及文件：`ob` → 紧接 `probe_npm_registry()` 之后插入
- 验证范围：函数在 `ob` 脚本中可被调用，source 不报语法错误

- [ ] Step 1: 确认 `ob` 脚本当前没有 `resolve_npm_registry` 函数
- Run: `grep -c 'resolve_npm_registry' /bmc/iasi/ob-harness/ob`
- Expected: 0

- [ ] Step 2: 在 `probe_npm_registry()` 之后插入 `resolve_npm_registry()` 函数
- Change: 插入以下函数：
```bash
# Resolve which npm registry to use.
# Decision order: OB_NPM_REGISTRY env > cache (<24h) > probe > error.
# Sets NPM_REGISTRY_RESOLVED: the chosen URL, "" for npm default, or "skip".
resolve_npm_registry() {
    local cache_file="$CONFIGS_DIR/$MACHINE.npm-registry"
    local cache_ttl=86400  # 24 hours
    NPM_REGISTRY_RESOLVED=""

    # 1. Environment variable override
    if [[ -n "${OB_NPM_REGISTRY+x}" ]]; then
        if [[ -z "$OB_NPM_REGISTRY" ]]; then
            info "OB_NPM_REGISTRY is set (empty) — npm registry auto-detection disabled"
            NPM_REGISTRY_RESOLVED="skip"
            return 0
        fi
        info "OB_NPM_REGISTRY override: $OB_NPM_REGISTRY"
        NPM_REGISTRY_RESOLVED="$OB_NPM_REGISTRY"
        return 0
    fi

    # 2. Cache check
    if [[ -f "$cache_file" ]]; then
        local cache_epoch cache_url cache_age
        cache_epoch=$(sed -n '1p' "$cache_file" 2>/dev/null | grep -oP '^\d+$' || echo "")
        cache_url=$(sed -n '2p' "$cache_file" 2>/dev/null || true)
        if [[ -n "$cache_epoch" && -n "$cache_url" ]]; then
            cache_age=$(( $(date +%s) - cache_epoch ))
            if [[ "$cache_age" -lt "$cache_ttl" ]]; then
                local hours_ago=$(( cache_age / 3600 ))
                if [[ -n "$cache_url" ]]; then
                    info "npm registry: $cache_url (cached, probed ${hours_ago}h ago)"
                else
                    info "npm registry: npmjs.org default (cached, probed ${hours_ago}h ago)"
                fi
                NPM_REGISTRY_RESOLVED="$cache_url"
                return 0
            fi
            verbose "npm registry cache stale (${cache_age}s > ${cache_ttl}s), re-probing"
        fi
    fi

    # 3. Live probe
    info "Probing npm registries (npmjs.org vs npmmirror.com, max 10s)..."
    local chosen_url
    chosen_url=$(probe_npm_registry)
    if [[ -z "$chosen_url" ]]; then
        # Both registries timed out — check if this was a real timeout or curl missing
        if ! command -v curl &>/dev/null; then
            warn "curl not available for npm registry probe, using npmjs.org default"
            chosen_url=""
        else
            echo ""
            error "Both npm registries are unreachable (10s timeout):"
            error "  - registry.npmjs.org: timeout"
            error "  - registry.npmmirror.com: timeout"
            echo ""
            echo "  Possible causes:"
            echo "    1. No internet connectivity"
            echo "    2. Firewall blocking HTTPS to registry hosts"
            echo "    3. DNS resolution failure"
            echo ""
            echo "  To override manually:"
            echo "    export OB_NPM_REGISTRY=https://registry.npmmirror.com/"
            echo "    ob build"
            echo ""
            echo "  To skip npm configuration entirely:"
            echo "    export OB_NPM_REGISTRY="
            echo "    ob build"
            echo ""
            exit 1
        fi
    fi

    # Write cache
    {
        date +%s
        echo "$chosen_url"
    } > "$cache_file" 2>/dev/null || warn "Failed to write npm registry cache to $cache_file"

    if [[ -n "$chosen_url" ]]; then
        info "npm registry: $chosen_url (auto-detected)"
    else
        info "npm registry: npmjs.org default (auto-detected, npmjs.org is faster)"
    fi
    NPM_REGISTRY_RESOLVED="$chosen_url"
}
```

- [ ] Step 3: 验证脚本语法正确
- Run: `bash -n /bmc/iasi/ob-harness/ob && echo "syntax OK"`
- Expected: `syntax OK`

### Task 4: 在 cmd_build() 中调用 resolve_npm_registry() 并注入环境变量

- 目标：在 bitbake 调用前完成 npm 注册表探测，通过 `BB_ENV_PASSTHROUGH_ADDITIONS` 注入环境变量
- 涉及文件：`ob` → `cmd_build()` 函数，`source setup` 之后、bitbake 调用之前
- 验证范围：`ob build` 运行时日志显示 npm registry 探测结果

- [ ] Step 1: 确认 `cmd_build()` 中 bitbake 调用前没有 npm 相关代码
- Run: `grep -n 'npm\|NPM_REGISTRY' /bmc/iasi/ob-harness/ob | head -5`
- Expected: 仅匹配到新加的 `probe_npm_registry` 和 `resolve_npm_registry` 函数定义，`cmd_build` 内无匹配

- [ ] Step 2: 在 `cmd_build()` 中，`eval "$prev_opts"`（source setup 恢复）之后、`# === Run bitbake ===` 注释之前，插入 npm 配置块
- Change: 在 `eval "$prev_opts"` 行之后插入：
```bash
    # === npm registry auto-detection ===
    resolve_npm_registry
    if [[ "$NPM_REGISTRY_RESOLVED" != "skip" ]]; then
        export npm_config_registry="$NPM_REGISTRY_RESOLVED"
        export npm_config_fetch_timeout=600000
        export npm_config_fetch_retry_maxtimeout=120000
        export npm_config_fetch_retry_mintimeout=30000
        export npm_config_fetch_retry_factor=2
        local _npm_vars="npm_config_registry npm_config_fetch_timeout npm_config_fetch_retry_maxtimeout npm_config_fetch_retry_mintimeout npm_config_fetch_retry_factor"
        local _existing="${BB_ENV_PASSTHROUGH_ADDITIONS:-}"
        BB_ENV_PASSTHROUGH_ADDITIONS="$_npm_vars"
        if [[ -n "$_existing" ]]; then
            BB_ENV_PASSTHROUGH_ADDITIONS="$_existing $BB_ENV_PASSTHROUGH_ADDITIONS"
        fi
        export BB_ENV_PASSTHROUGH_ADDITIONS
        verbose "Exported npm config for bitbake passthrough"
        verbose "  npm_config_registry=$npm_config_registry"
    fi
```

- [ ] Step 3: 验证脚本语法正确
- Run: `bash -n /bmc/iasi/ob-harness/ob && echo "syntax OK"`
- Expected: `syntax OK`

### Task 5: 更新 usage() 添加 OB_NPM_REGISTRY 说明

- 目标：`ob -h` 输出中包含 `OB_NPM_REGISTRY` 环境变量说明
- 涉及文件：`ob` → `usage()` 函数，Environment Variables 段落
- 验证范围：`ob -h` 显示 OB_NPM_REGISTRY 说明

- [ ] Step 1: 确认当前 usage 中没有 OB_NPM_REGISTRY
- Run: `grep 'OB_NPM_REGISTRY' /bmc/iasi/ob-harness/ob`
- Expected: 仅匹配新加的函数代码，usage heredoc 中无匹配

- [ ] Step 2: 在 `usage()` 的 Environment Variables 段落中，`OB_QEMU_BINARY_URL` 行之后添加一行
- Change: 在 `OB_QEMU_BINARY_URL` 行后添加：
```
  OB_NPM_REGISTRY          Override npm registry URL (set empty to disable auto-detection)
```

- [ ] Step 3: 验证 usage 输出
- Run: `./ob -h 2>&1 | grep OB_NPM_REGISTRY`
- Expected: 显示 `OB_NPM_REGISTRY          Override npm registry URL (set empty to disable auto-detection)`

### Task 6: 更新 bestpractice_05 skill 文档

- 目标：在 skill 文档中添加 ob build 自动处理的说明，让用户知道自动机制存在
- 涉及文件：`rules/skills/bestpractice_05-npm_network_timeout_in_yocto.md`
- 验证范围：文档包含自动检测机制的说明

- [ ] Step 1: 确认当前文档不包含自动检测说明
- Run: `grep -c 'ob build.*auto\|自动' /bmc/iasi/ob-harness/rules/skills/bestpractice_05-npm_network_timeout_in_yocto.md`
- Expected: 0

- [ ] Step 2: 在文档"错误特征"段落之前添加 "ob build 自动处理" 小节
- Change: 在 `## 错误特征` 行之前插入：
```markdown
## ob build 自动处理

如果使用 `ob build` 构建固件，npm 注册表和超时参数已内置自动处理：

- **注册表自动探测**：`ob build` 在调用 bitbake 前并行测试 `npmjs.org` 和 `npmmirror.com` 的下载速度，自动选择更快的源。默认倾向 `npmmirror.com`（国内镜像），仅当 `npmjs.org` 明显更快时切回。
- **超时参数自动注入**：通过 BitBake 的 `BB_ENV_PASSTHROUGH_ADDITIONS` 机制向所有 npm task 注入 600 秒超时和合理的重试参数。
- **探测结果缓存 24 小时**，避免每次构建重新探测。
- **环境变量覆盖**：`OB_NPM_REGISTRY` 可强制指定注册表或设为空禁用自动检测。

本节以下的手动策略适用于不使用 `ob build` 的场景（直接运行 bitbake、CI 环境等）。
```

- [ ] Step 3: 验证文档内容
- Run: `grep 'ob build 自动处理' /bmc/iasi/ob-harness/rules/skills/bestpractice_05-npm_network_timeout_in_yocto.md`
- Expected: 匹配到新添加的段落标题

## 执行纪律

- 开始实现前先批判性复查整份计划；如果发现缺项、矛盾、命名不一致或验证命令无效，先修计划
- 按任务顺序执行，不要无声跳步、合并步或改变任务目标
- 每完成一个任务，都运行该任务定义的验证
- 遇到阻塞、重复失败或计划与仓库现实不符，立即停下来说明，不要猜
- 如果当前就在 `main` 或 `master`，且用户没有明确同意，开始实现前先确认
- 全部任务完成后，运行最终验证并输出修改摘要

## 最终验证

在所有任务完成后运行：

1. **语法检查**：`bash -n /bmc/iasi/ob-harness/ob && echo "syntax OK"`
2. **函数存在性**：`grep -c 'probe_npm_registry\|resolve_npm_registry\|NPM_REGISTRY_RESOLVED' /bmc/iasi/ob-harness/ob` — 期望出现多个匹配（函数定义 + 调用点）
3. **usage 输出**：`./ob -h 2>&1 | grep OB_NPM_REGISTRY` — 期望显示说明行
4. **skill 文档**：`grep 'ob build 自动处理' /bmc/iasi/ob-harness/rules/skills/bestpractice_05-npm_network_timeout_in_yocto.md` — 期望匹配

由于完整的端到端验证需要实际网络探测和 bitbake 构建（耗时数小时），以上检查覆盖了"代码正确性"层面。实际 npm 注册表切换效果需在下次 `ob build` 构建时通过日志中 `npm http fetch GET` URL 确认。

## 审阅 Checkpoint

实施计划已写好并保存到 `docs/plans/2026-06-10-npm-registry-auto-detection-implementation-plan.md`。请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行。
