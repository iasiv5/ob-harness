# 社区 QEMU Binary 更新检查实施计划

## 目标

为 `ob start-qemu` 的 community 路径新增 Jenkins build number 级别的 QEMU binary 更新检查能力：
1. 每次 `start-qemu` 自动比对本地 manifest 的 `build_number` 与 Jenkins `lastSuccessfulBuild` 的 build number
2. 检测到更新时，交互式引导用户确认更新（三行 warn + Y/N 模式）
3. 更新失败时安全回退到旧 binary，不打断启动流程
4. 不影响 custom 路径、不影响非 TTY / Jenkins 不可达等场景

## 架构快照

**改动前**：`ensure_qemu_binary_community()` 只做存在性检查——binary 存在就 `return 0`，不存在就下载。manifest 记录了 `sha256` 和 `installed_at`，但从未被消费。

**改动后**：
```
ensure_qemu_binary_community()
  ├─ [[ -x $QEMU_BIN_FILE ]] ?
  │    ├─ No  → 现有下载流程 + 追加 build_number 写入
  │    └─ Yes → check_jenkins_update()
  │               ├─ manifest 无 build_number → 静默跳过
  │               ├─ manifest URL 非 Jenkins → 静默跳过
  │               ├─ Jenkins 不可达 → 静默跳过
  │               ├─ build number 相同 → 静默跳过
  │               ├─ 非 TTY → info 通知 + 跳过
  │               └─ TTY → 交互 Y/N
  │                    ├─ N → return 0（用旧 binary 继续）
  │                    └─ Y → download_and_replace_community_qemu()
  │                              ├─ flock 并发保护
  │                              ├─ 下载到临时目录
  │                              ├─ 验证（file type、sha256）
  │                              ├─ 备份旧 binary（.bak-<build_number>）
  │                              ├─ 替换 + 重写 manifest
  │                              ├─ 清理备份
  │                              └─ 失败时 warn + 用旧 binary 继续
```

所有新增逻辑仅在 `ensure_qemu_binary_community()` 内部执行，`ensure_qemu_binary_custom()` 和 `ensure_qemu_binary()` 分派器不受影响。

## 输入工件

- 设计决策：grilling session 中逐条确认的 20 条决策（见对话历史）
- 参考实现：`ob` 脚本中 `cmd_init` 的 confirmation UI 模式（`ob` 函数 `confirm_init_and_proceed`，约 L2580-2613）

## 文件结构与职责

- Modify: `ob`
  - 修改函数：`ensure_qemu_binary_community()`（L550-662）、`write_qemu_binary_manifest()`（L517-534）
  - 新增函数：`query_jenkins_build_number()`、`download_and_replace_community_qemu()`、`check_jenkins_update()`

## 任务清单

### Task 1: 新增 `query_jenkins_build_number()` 辅助函数

- 目标：封装 Jenkins API 调用，返回指定 job 的 `lastSuccessfulBuild` build number
- 涉及文件：`ob`（`write_qemu_pcbios_manifest` 函数之后，约 L549）
- 验证范围：函数存在、语法正确、能正确解析 Jenkins JSON 响应

- [ ] Step 1: 检查插入点上下文

  - Run: `grep -n '^write_qemu_pcbios_manifest\|^ensure_qemu_binary_community' ob`
  - Expected: `write_qemu_pcbios_manifest` 在 L536，`ensure_qemu_binary_community` 在 L550，插入点在 L549（两者之间）

- [ ] Step 2: 在 L549 之后插入 `query_jenkins_build_number()`

  函数逻辑：
  ```bash
  # Query Jenkins lastSuccessfulBuild number for a given job URL.
  # Args: $1 = Jenkins job base URL (e.g. https://jenkins.openbmc.org/job/latest-qemu-x86)
  # Returns: build number via stdout (empty string on failure)
  query_jenkins_build_number() {
      local job_url="$1"
      local api_url="${job_url}/lastSuccessfulBuild/api/json?tree=number"
      local raw
      raw=$(curl -s --max-time 5 "$api_url" 2>/dev/null) || return 0
      echo "$raw" | grep -o '"number":[0-9]*' | head -1 | cut -d: -f2
  }
  ```

- Change: 插入新函数

- [ ] Step 3: 验证语法

  - Run: `bash -n ob`
  - Expected: 无输出（语法正确）

### Task 2: 修改 `write_qemu_binary_manifest()` 支持 `build_number` 参数

- 目标：让 manifest 写入时可选地包含 `build_number` 字段，避免后续追加写入
- 涉及文件：`ob`（`write_qemu_binary_manifest` 函数，L517-534）
- 验证范围：新参数可选兼容（不传时行为不变）

- [ ] Step 1: 检查当前函数签名和调用点

  - Run: `grep -n 'write_qemu_binary_manifest' ob`
  - Expected: 函数定义在 L517，调用点在 L658（`ensure_qemu_binary_community` 内）

- [ ] Step 2: 修改函数签名，增加可选的第 6 个参数 `build_number`

  ```bash
  write_qemu_binary_manifest() {
      local install_source="$1"
      local arch="$2"
      local source_key="$3"
      local source_value="$4"
      local sha256="$5"
      local build_number="${6:-}"
      local manifest_path="${QEMU_BIN_FILE}.manifest"

      cat > "$manifest_path" <<MANIFEST_EOF
  asset=binary
  source=${install_source}
  arch=${arch}
  binary_path=${QEMU_BIN_FILE}
  ${source_key}=${source_value}
  installed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  sha256=${sha256}
  MANIFEST_EOF

      if [[ -n "$build_number" ]]; then
          echo "build_number=${build_number}" >> "$manifest_path"
      fi
  }
  ```

- Change: 函数签名增加第 6 个可选参数，函数体末尾条件追加 `build_number` 行

- [ ] Step 3: 验证语法

  - Run: `bash -n ob`
  - Expected: 无输出（语法正确）

### Task 3: 修改 `ensure_qemu_binary_community()` 首次下载后写入 `build_number`

- 目标：首次下载完成后，查询 Jenkins API 获取 build number，传给 `write_qemu_binary_manifest()`
- 涉及文件：`ob`（`ensure_qemu_binary_community` 函数，L655-661 区域）
- 验证范围：首次下载后 manifest 包含 `build_number` 字段

- [ ] Step 1: 定位当前下载完成后的 manifest 写入调用

  - Run: `sed -n '655,662p' ob`
  - Expected: 看到 `sha256=...`、`write_qemu_binary_manifest` 调用和 `info "QEMU binary ready"`

- [ ] Step 2: 在 `write_qemu_binary_manifest` 调用之前，查询 Jenkins build number

  将 L655-661 区域替换为：
  ```bash
      local sha256=""
      sha256=$(sha256sum "$QEMU_BIN_FILE" | awk '{print $1}')

      # Query Jenkins for build number (community source only)
      local build_number=""
      local qemu_url_for_check="$qemu_url"
      if [[ "$qemu_url_for_check" == *"jenkins.openbmc.org"* ]]; then
          # Extract job URL from artifact URL
          local job_url
          job_url=$(echo "$qemu_url_for_check" | sed -E 's|/lastSuccessfulBuild/.*||; s|/artifact/.*||')
          build_number=$(query_jenkins_build_number "$job_url")
      fi

      write_qemu_binary_manifest "$label" "$arch" "url" "$qemu_url" "$sha256" "$build_number"

      info "QEMU binary ready: $QEMU_BIN_FILE"
      verbose "  SHA256: $sha256"
      if [[ -n "$build_number" ]]; then
          verbose "  Build: #$build_number"
      fi
  ```

- Change: 下载完成后增加 Jenkins API 查询，将 build number 传入 manifest 写入

- [ ] Step 3: 验证语法

  - Run: `bash -n ob`
  - Expected: 无输出（语法正确）

### Task 4: 新增 `download_and_replace_community_qemu()` 函数

- 目标：实现带安全备份的 QEMU binary 更新下载流程（flock 并发保护、临时目录解压、显式备份、原子替换、失败回退）
- 涉及文件：`ob`（`query_jenkins_build_number` 函数之后，约 L565）
- 验证范围：函数存在、语法正确、逻辑覆盖所有 corner case

- [ ] Step 1: 在 `query_jenkins_build_number` 之后插入新函数

  函数逻辑：
  ```bash
  # Download a new QEMU binary and safely replace the existing one.
  # Args: $1 = download URL, $2 = remote build number, $3 = arch
  # Returns: 0 on success, 1 on failure (caller should continue with old binary)
  download_and_replace_community_qemu() {
      local qemu_url="$1"
      local remote_build="$2"
      local arch="$3"
      local manifest="${QEMU_BIN_FILE}.manifest"

      # ── flock: prevent concurrent updates ──
      local lock_file="${QEMU_BIN_FILE}.update.lock"
      exec 200>"$lock_file"
      if ! flock -n 200; then
          warn "Another QEMU binary update is in progress. Skipping."
          exec 200>&-
          return 1
      fi

      # ── Download to temp directory ──
      local tmp_dir
      tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/qemu-update-XXXXXX")

      info "Downloading QEMU binary (build #${remote_build})..."
      verbose "  URL: $qemu_url"

      if ! curl -fSL -o "${tmp_dir}/download" "$qemu_url"; then
          warn "Failed to download QEMU binary from: $qemu_url"
          rm -rf "$tmp_dir"
          flock -u 200 2>/dev/null; exec 200>&-
          return 1
      fi

      # ── Extract / locate binary ──
      local new_binary=""
      local file_type
      file_type=$(file -b "${tmp_dir}/download" 2>/dev/null || echo "")

      if echo "$file_type" | grep -qi "gzip\|xz"; then
          verbose "  Detected archive, extracting..."
          tar xf "${tmp_dir}/download" -C "$tmp_dir/" --strip-components=1 2>/dev/null \
              || tar xf "${tmp_dir}/download" -C "$tmp_dir/" 2>/dev/null

          for candidate in "$tmp_dir/$arch" "$tmp_dir/bin/$arch"; do
              if [[ -f "$candidate" ]]; then
                  new_binary="$candidate"
                  break
              fi
          done

          if [[ -z "$new_binary" ]]; then
              warn "Could not find $arch in extracted archive."
              rm -rf "$tmp_dir"
              flock -u 200 2>/dev/null; exec 200>&-
              return 1
          fi
      else
          new_binary="${tmp_dir}/download"
      fi

      # ── Verify new binary ──
      chmod +x "$new_binary"
      if ! [[ -x "$new_binary" ]]; then
          warn "Downloaded file is not executable."
          rm -rf "$tmp_dir"
          flock -u 200 2>/dev/null; exec 200>&-
          return 1
      fi

      local new_sha256
      new_sha256=$(sha256sum "$new_binary" | awk '{print $1}')

      # ── Backup old binary ──
      local old_build
      old_build=$(grep '^build_number=' "$manifest" 2>/dev/null | cut -d= -f2)
      local bak_suffix="${old_build:-unknown}"
      local bak_file="${QEMU_BIN_FILE}-${bak_suffix}.bak"

      info "Backing up current QEMU binary (build #${bak_suffix})..."
      cp "$QEMU_BIN_FILE" "$bak_file"

      # ── Replace ──
      if ! mv "$new_binary" "$QEMU_BIN_FILE"; then
          warn "Failed to replace QEMU binary."
          # Restore from backup (should be identical, but being safe)
          if [[ -f "$bak_file" ]]; then
              mv "$bak_file" "$QEMU_BIN_FILE"
          fi
          rm -rf "$tmp_dir"
          flock -u 200 2>/dev/null; exec 200>&-
          return 1
      fi
      chmod +x "$QEMU_BIN_FILE"

      # ── Update manifest ──
      local label
      label=$(read_source_label)
      write_qemu_binary_manifest "$label" "$arch" "url" "$qemu_url" "$new_sha256" "$remote_build"

      # ── Cleanup ──
      rm -rf "$tmp_dir"
      rm -f "$bak_file"
      flock -u 200 2>/dev/null; exec 200>&-

      info "QEMU binary updated to build #${remote_build}."
      verbose "  SHA256: $new_sha256"
      return 0
  }
  ```

- Change: 插入新函数

- [ ] Step 2: 验证语法

  - Run: `bash -n ob`
  - Expected: 无输出（语法正确）

### Task 5: 新增 `check_jenkins_update()` 函数

- 目标：实现完整的更新检查流程——门卫条件判断、Jenkins API 比对、交互式确认 UI、调用下载替换
- 涉及文件：`ob`（`download_and_replace_community_qemu` 函数之后）
- 验证范围：函数存在、语法正确、覆盖所有门卫分支

- [ ] Step 1: 在 `download_and_replace_community_qemu` 之后插入新函数

  函数逻辑：
  ```bash
  # Check if a newer QEMU binary is available on Jenkins.
  # If update available and interactive, prompt user to update.
  # Non-interactive: notify only.
  # On any failure: silently continue with existing binary.
  check_jenkins_update() {
      local manifest="${QEMU_BIN_FILE}.manifest"

      # ── Guard: manifest must exist ──
      [[ -f "$manifest" ]] || return 0

      # ── Guard: build_number must be present ──
      local local_build
      local_build=$(grep '^build_number=' "$manifest" 2>/dev/null | cut -d= -f2)
      [[ -z "$local_build" ]] && return 0

      # ── Guard: URL must be Jenkins ──
      local manifest_url
      manifest_url=$(grep '^url=' "$manifest" 2>/dev/null | cut -d= -f2-)
      [[ "$manifest_url" != *"jenkins.openbmc.org"* ]] && return 0

      # ── Guard: extract job URL ──
      local job_url
      job_url=$(echo "$manifest_url" | sed -E 's|/lastSuccessfulBuild/.*||; s|/artifact/.*||')

      # ── Query Jenkins ──
      local remote_build
      remote_build=$(query_jenkins_build_number "$job_url")
      [[ -z "$remote_build" ]] && return 0  # Jenkins unreachable

      # ── Same version? ──
      if [[ "$remote_build" == "$local_build" ]]; then
          verbose "QEMU binary is up to date (build #${local_build})."
          return 0
      fi

      # ── Update available ──
      info "QEMU binary update available: build #${local_build} → #${remote_build}"

      # ── Non-interactive: notify and skip ──
      if [[ ! -t 0 ]]; then
          info "Update skipped: non-interactive mode. Re-run in a terminal to update."
          return 0
      fi

      # ── Interactive confirmation ──
      local arch="${QB_SYSTEM_NAME:-qemu-system-arm}"
      echo ""
      echo "============================================================"
      echo ""
      warn "  You are about to update community QEMU binary:  >>> build #${local_build} → #${remote_build} <<<"
      warn "  You are about to update community QEMU binary:  >>> build #${local_build} → #${remote_build} <<<"
      warn "  You are about to update community QEMU binary:  >>> build #${local_build} → #${remote_build} <<<"
      echo ""
      echo "============================================================"
      echo ""
      while true; do
          local confirm
          if ! read -r -p "$(echo -e "${PROMPT_PREFIX} Type (Y/y) to confirm update, (N/n) to cancel: ")" confirm; then
              error "Unable to read confirmation from stdin."
              return 0
          fi
          case "$confirm" in
              [yY])
                  echo ""
                  if download_and_replace_community_qemu "$manifest_url" "$remote_build" "$arch"; then
                      return 0
                  else
                      warn "QEMU binary update failed. Continuing with existing binary."
                      return 0
                  fi
                  ;;
              [nN])
                  warn "Update cancelled by user."
                  return 0
                  ;;
              *)
                  warn "Invalid input. Please type Y or N."
                  ;;
          esac
      done
  }
  ```

- Change: 插入新函数

- [ ] Step 2: 验证语法

  - Run: `bash -n ob`
  - Expected: 无输出（语法正确）

### Task 6: 修改 `ensure_qemu_binary_community()` 插入 update 检查调用

- 目标：在 binary 已存在的分支中，调用 `check_jenkins_update()`
- 涉及文件：`ob`（`ensure_qemu_binary_community` 函数，L550-557 区域）
- 验证范围：binary 存在时触发 update 检查，binary 不存在时走原有下载流程

- [ ] Step 1: 定位当前 binary 存在性检查

  - Run: `sed -n '550,557p' ob`
  - Expected: 看到 `[[ -x "$QEMU_BIN_FILE" ]]` 和 `return 0`

- [ ] Step 2: 在 binary 存在分支中插入 update 检查

  将 L553-557 区域替换为：
  ```bash
      # Already downloaded and executable?
      if [[ -x "$QEMU_BIN_FILE" ]]; then
          verbose "QEMU binary already exists: $QEMU_BIN_FILE"
          check_jenkins_update
          return 0
      fi
  ```

- Change: 在 `return 0` 之前插入 `check_jenkins_update` 调用

- [ ] Step 3: 验证语法和调用链

  - Run: `bash -n ob`
  - Expected: 无输出（语法正确）
  - Run: `grep -n 'check_jenkins_update' ob`
  - Expected: 函数定义 1 处 + 调用点 1 处（在 `ensure_qemu_binary_community` 内）

### Task 7: 全流程集成验证

- 目标：验证新增功能不影响现有流程，语法正确，新函数存在
- 涉及文件：`ob`
- 验证范围：语法、函数存在性、调用链完整性、帮助信息

- [ ] Step 1: 语法检查

  - Run: `bash -n ob && echo "PASS: syntax" || echo "FAIL: syntax"`
  - Expected: `PASS: syntax`

- [ ] Step 2: 新增函数存在性检查

  ```bash
  for fn in query_jenkins_build_number download_and_replace_community_qemu check_jenkins_update; do
      grep -q "^${fn}()" ob && echo "PASS: $fn exists" || echo "FAIL: $fn missing"
  done
  ```
  - Expected: 全部 PASS

- [ ] Step 3: 调用链完整性检查

  ```bash
  # ensure_qemu_binary_community 应包含 check_jenkins_update 调用
  grep -A5 'QEMU binary already exists' ob | grep -q 'check_jenkins_update' \
      && echo "PASS: update check inserted" || echo "FAIL: update check missing"

  # write_qemu_binary_manifest 应接受 build_number 参数
  grep -A2 'write_qemu_binary_manifest' ob | grep -q 'build_number' \
      && echo "PASS: build_number in manifest call" || echo "FAIL: build_number not passed"
  ```
  - Expected: 全部 PASS

- [ ] Step 4: 帮助信息不受影响

  - Run: `./ob start-qemu --help 2>&1 | head -5`
  - Expected: 正常输出 usage 信息，无报错

- [ ] Step 5: Checkpoint commit

  ```bash
  git add ob && git commit -m "feat(ob): 社区 QEMU binary 更新检查 — Jenkins build number 比对与交互式更新"
  ```

## 执行纪律

- 开始实现前，先批判性复查整份计划；如果发现缺项、矛盾、命名不一致或验证命令无效，先修计划
- 按任务顺序执行（Task 1 → Task 7），不要无声跳步、合并步或改变任务目标
- 每完成一个任务，都运行该任务定义的验证（`bash -n ob` + 该任务的特定检查）
- 遇到阻塞、重复失败或计划与仓库现实不符，立即停下来说明，不要猜
- 当前分支 `feat/start-qemu`，非 main 分支，无需额外确认
- 全部任务完成后，运行 Task 7 的最终验证并输出修改摘要

## 最终验证

```bash
# 1. 语法
bash -n ob && echo "PASS: syntax" || echo "FAIL: syntax"

# 2. 新增函数
for fn in query_jenkins_build_number download_and_replace_community_qemu check_jenkins_update; do
    grep -q "^${fn}()" ob && echo "PASS: $fn exists" || echo "FAIL: $fn missing"
done

# 3. 调用链
grep -A5 'QEMU binary already exists' ob | grep -q 'check_jenkins_update' \
    && echo "PASS: update check inserted" || echo "FAIL: update check missing"

grep -A2 'write_qemu_binary_manifest' ob | grep -q 'build_number' \
    && echo "PASS: build_number passed" || echo "FAIL: build_number not passed"

# 4. 帮助
./ob start-qemu --help 2>&1 | head -3
```

预期结果：全部 PASS，帮助信息正常输出。

## 审阅 Checkpoint

计划已写好并保存到 `docs/plans/2026-06-12-qemu-community-update-check-implementation-plan.md`。请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行。
