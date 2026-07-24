# devtool_search_refresh 原子发布协议深化实施计划

## 目标

把 [lib/devtool_search.sh](../../lib/devtool_search.sh) `devtool_search_refresh`（[L326-L472](../../lib/devtool_search.sh#L326-L472)）内联的 staged-atomic publish 编排（[L386-L460](../../lib/devtool_search.sh#L386-L460) 块体，~75 行、最深 9 层嵌套；实现时以 `else`/`fi` 语义锚点定位，行号会因插入漂移）抽取为文件内私有 leaf-pure helper `_devtool_recipes_publish_pair`，让 refresh 的 else 块塌成一行调用。语义逐字搬移、行为不变，端到端金标 [tests/unit/devtool_search.sh](../../tests/unit/devtool_search.sh) 作回归锁。

## 架构快照

- 抽出私有 helper `_devtool_recipes_publish_pair <stdout_file> <machine> <post_hash> <post_mtime> <post_commit> <stderr_file>` → return rc（0 成功 / 非0 失败），封装整条 staged-atomic publish 全链（stage tmp cache/meta → collect integrity → render meta → backup 旧 pair → publish meta → publish cache → restore-on-fail → discard/cleanup）。
- 与现有结构衔接：消费现有 leaf-pure helper——`devtool_recipes_cache_path`/`devtool_recipes_meta_path`（算路径，[L199-L200](../../lib/devtool_search.sh#L199-L200)）、`_devtool_recipes_collect_cache_integrity`（[L148](../../lib/devtool_search.sh#L148)）、`_devtool_recipes_backup_file`（[L10](../../lib/devtool_search.sh#L10)）、`_devtool_recipes_restore_file`（[L33](../../lib/devtool_search.sh#L33)）、`_devtool_recipes_discard_backup`（[L52](../../lib/devtool_search.sh#L52)）、`_devtool_recipes_schema_version`（[L6](../../lib/devtool_search.sh#L6)）。这些零件早已 leaf-pure，本抽取只收口它们的调用编排。
- 形态对照：与 `bare_mirror.sh`/`image_build.sh` 等 bestpractice_10 抽取族同构（leaf-pure 深 module + 行为金标回归锁），但因 publish_pair 仅 refresh 一个 caller，落点为**文件内私有 helper**（下划线前缀，与 `_devtool_recipes_*` 族一致），不独立成 lib 文件、不登记 exit_contract Y（`devtool_search.sh` 已登记 `set()`）、不加 surface gate。
- 落点（私有 helper）+ 测试（只保留端到端、不加直测）+ 范围（不碰 mktemp 样板）三项均经 grilling 共识确认，见输入工件。

## 全局约束

- **leaf-pure**：`_devtool_recipes_publish_pair` 绝不 exit，return rc；`exit_contract.py` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 已登记 `'devtool_search.sh': set()`（[exit_contract.py:68](../../tools/exit_contract.py#L68)），新私有 helper 自动被 Y 规则覆盖，**不动 exit_contract.py**。若 helper 内意外混入 `exit` 会立即 FAIL（真实 exit 不在例外集）——**FAIL 时删 module 内 exit，不要改例外集去消告警**。
- **行为不变（逐字搬移）**：publish 的 fail-safe 部分失败语义——meta-先-cache-后（有意的更便宜失败路径）、`meta_published` 标志、cache-mv-fail 时 restore 旧 pair（`_devtool_recipes_restore_file` 尽力、失败 backup retained）、meta-mv-fail 时 `meta_published=0` 走 discard 不碰 cache、诊断文案（`ob dev refresh: ...`）——全部逐字搬移，不改顺序、不改消息、不改变量名。`tests/unit/devtool_search.sh` 的 PATH fake（`FAKE_MV_FAIL_CACHE_PUBLISH`/`FAKE_CP_FAIL_BACKUP`/`FAKE_MV_FAIL_META_RESTORE`/`FAKE_MKTEMP_FAIL_AT`）按参数模式匹配，抽取行为不变 → 参数模式仍命中 → 金标自动锁。**排他锁不变量**：helper 在 refresh 已持有的排他 `flock 9` 临界区内被调（refresh [L362-L467](../../lib/devtool_search.sh#L362-L467) 的 `flock 9 ... } 9>"$lock"` 块内），**不自加锁**——钉死此不变量，防后续误"优化"成 helper 自加锁致双锁/死锁。
- **coverage 基线不涨**：当前 CI `--fail-if-uncovered 7`（[ob-tests.yml:28](../../.github/workflows/ob-tests.yml#L28)）；`_devtool_recipes_publish_pair` 被 refresh 端到端测试间接覆盖（xtrace 函数级命中），uncovered 保持 ≤7。
- **不加 surface gate**：私有 helper 单 caller，无跨文件「必经 X」约束要锁，**不动 ob_check.sh**。
- **不动 CONTEXT/WORKSPACE**：`_devtool_recipes_publish_pair` 是私有实现 seam，非领域概念；领域概念 `recipe metadata cache` 已在 CONTEXT.md，publish 是其 implementation。
- **不碰 mktemp 样板**：refresh 入口 [L329-L354](../../lib/devtool_search.sh#L329-L354) 的 4 个失败处理块保持 inline（grilling 判定：4 块差异是「按依赖顺序清理」的正确性核心，抽 helper 行数不减、deletion test 不过、one-adapter）。
- 无版本/平台额外约束。

## 输入工件

- grilling 共识（5 决策点，2026-07-24 本会话，`/grill-with-docs`）：① seam 边界=全吃 staged publish 全链；② 落点=文件内私有 helper；③ 行为契约=照搬 fail-safe 语义；④ 测试=只保留端到端不加直测；⑤ mktemp 样板=不抽。
- 同构先例：[docs/plans/2026-07-24-image-build-extraction-implementation-plan.md](./2026-07-24-image-build-extraction-implementation-plan.md)（leaf-pure 深 module 抽取 + 行为金标回归锁；区别：image_build 是 public lib module 要登记 exit_contract Y，publish_pair 是私有 helper 不登记）。
- 领域术语：[CONTEXT.md](../../CONTEXT.md) `recipe metadata cache`。

## 文件结构与职责

- Modify: `lib/devtool_search.sh` — 新增 `_devtool_recipes_publish_pair` 私有 helper（插入位置：`devtool_search_read` 函数 [L321](../../lib/devtool_search.sh#L321) 结尾之后、`# devtool_search_refresh` 注释 [L323](../../lib/devtool_search.sh#L323) 之前——紧贴唯一 caller refresh，locality 最好）；`devtool_search_refresh` 的 else 块（[L385-L461](../../lib/devtool_search.sh#L385-L461)）塌成一行调用。
- 不动：`tools/exit_contract.py`、`tools/ob_check.sh`、`CONTEXT.md`、`rules/03_WORKSPACE.md`、`tests/unit/devtool_search.sh`。

接口契约：Task 1 产出 `_devtool_recipes_publish_pair`（Consumes 现有 `_devtool_recipes_*` helper + `devtool_recipes_cache_path`/`meta_path`；Produces 私有 helper `_devtool_recipes_publish_pair`），并把 refresh else 块接线到它；Task 2 消费 Task 1 成果做收口验证。

---

## 任务清单

### Task 1: 抽 _devtool_recipes_publish_pair + refresh 接线

- 目标：新增 `_devtool_recipes_publish_pair` 私有 helper（逐字搬移 L386-L461 的 staged-atomic publish 语义），把 refresh else 块塌成一行调用；行为不变。
- 涉及文件：Modify `lib/devtool_search.sh`。
- 接口契约：
  - Consumes: `devtool_recipes_cache_path`/`devtool_recipes_meta_path`（L199-L200）、`_devtool_recipes_collect_cache_integrity`（L148）、`_devtool_recipes_backup_file`（L10）、`_devtool_recipes_restore_file`（L33）、`_devtool_recipes_discard_backup`（L52）、`_devtool_recipes_schema_version`（L6）、全局 `$CONFIGS_DIR`。
  - Produces: 私有 helper `_devtool_recipes_publish_pair <stdout_file> <machine> <post_hash> <post_mtime> <post_commit> <stderr_file>` → return rc（0/非0）；refresh else 块经它发布。
- 验证范围：端到端金标 `tests/unit/devtool_search.sh` 全绿（行为不变回归锁）；`_devtool_recipes_publish_pair` 已定义且被 refresh 调用；refresh 内无 publish 内联残留。

- [ ] Step 1: 写当前状态检查
  - 当前 refresh 仍内联 publish block（L386-L461），`_devtool_recipes_publish_pair` 未定义。
  - Run: `! grep -q '_devtool_recipes_publish_pair' lib/devtool_search.sh`
  - Expected: rc 0（函数未定义）
  - Run: `sed -n '/^devtool_search_refresh()/,/^}/p' lib/devtool_search.sh | grep -q 'meta_published=0'`
  - Expected: rc 0（publish block 仍内联在 refresh 内）

- [ ] Step 2: 运行并确认当前基线
  - Run: `bash tests/unit/devtool_search.sh >/dev/null 2>&1`
  - Expected: rc 0（端到端金标当前绿——行为基线，抽取前必须绿、抽取后仍须绿）

- [ ] Step 3: 写最小实现
  - Modify `lib/devtool_search.sh`，在 `devtool_search_read` 函数（L321 结尾 `}`）之后、`# devtool_search_refresh` 注释（L323）之前，插入：
    ```bash

    # _devtool_recipes_publish_pair <stdout_file> <machine> <post_hash> <post_mtime> <post_commit> <stderr_file>
    # 把生成的 recipe 索引以 staged-atomic 方式发布到 cache+meta pair(stage→integrity→render meta→
    #   backup→publish meta→publish cache→restore-on-fail→discard/cleanup)。逐字搬移自 devtool_search_refresh
    #   原 else 块, fail-safe 语义不变: meta-先-cache-后(更便宜失败路径); meta_published 标志; cache-mv-fail
    #   时 restore 旧 pair(尽力, 失败 backup retained); meta-mv-fail 时 meta_published=0 走 discard 不碰 cache。
    #   消费 devtool_recipes_cache_path/meta_path + _devtool_recipes_collect_cache_integrity/backup_file/
    #   restore_file/discard_backup/schema_version(现有 leaf-pure helper)。leaf-pure: return rc(0/非0), 不 exit。
    #   在 refresh 持有的排他 flock 9 临界区内调用, 不自加锁(refresh L362-L467 的 flock 块)。
    _devtool_recipes_publish_pair() {
        local stdout_file="$1" machine="$2" post_hash="$3" post_mtime="$4" post_commit="$5" stderr_file="$6"
        local cache meta tmp_cache="" tmp_meta="" staged_cache_sha="" staged_record_count=""
        local old_cache_bak="" old_meta_bak="" had_cache=0 had_meta=0 meta_published=0 rc=0
        cache="$(devtool_recipes_cache_path "$machine")"
        meta="$(devtool_recipes_meta_path "$machine")"
        if ! tmp_cache="$(mktemp "${cache}.XXXXXX" 2>/dev/null)"; then
            printf 'ob dev refresh: failed to stage cache at %s\n' "$cache" >>"$stderr_file"
            rc=1
        elif ! cp "$stdout_file" "$tmp_cache" 2>/dev/null; then
            printf 'ob dev refresh: failed to write staged cache %s\n' "$tmp_cache" >>"$stderr_file"
            rc=1
        fi
        if [[ "$rc" -eq 0 ]]; then
            if ! _devtool_recipes_collect_cache_integrity "$tmp_cache" staged_cache_sha staged_record_count; then
                printf 'ob dev refresh: failed to collect staged cache integrity data\n' >>"$stderr_file"
                rc=1
            elif ! tmp_meta="$(mktemp "${meta}.XXXXXX" 2>/dev/null)"; then
                printf 'ob dev refresh: failed to stage metadata at %s\n' "$meta" >>"$stderr_file"
                rc=1
            elif ! printf '{"schema_version":"%s","bblayers_hash":"%s","bblayers_mtime":%s,"openbmc_commit":"%s","cache_sha256":"%s","count":%s,"generated_at":"%s"}\n' \
                    "$(_devtool_recipes_schema_version)" "$post_hash" "$post_mtime" "$post_commit" "$staged_cache_sha" "$staged_record_count" \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" > "$tmp_meta" 2>/dev/null; then
                printf 'ob dev refresh: failed to write staged metadata %s\n' "$tmp_meta" >>"$stderr_file"
                rc=1
            fi
        fi
        if [[ "$rc" -eq 0 ]]; then
            [[ -f "$cache" ]] && had_cache=1
            [[ -f "$meta" ]] && had_meta=1
            _devtool_recipes_backup_file "$cache" \
                "${CONFIGS_DIR}/.${machine}.recipes.cache.backup.XXXXXX" \
                old_cache_bak "$stderr_file" || rc=1
            if [[ "$rc" -eq 0 ]]; then
                _devtool_recipes_backup_file "$meta" \
                    "${CONFIGS_DIR}/.${machine}.recipes.meta.backup.XXXXXX" \
                    old_meta_bak "$stderr_file" || rc=1
            fi
        fi
        if [[ "$rc" -eq 0 ]]; then
            if mv "$tmp_meta" "$meta" 2>/dev/null; then
                tmp_meta=""
                meta_published=1
                if mv "$tmp_cache" "$cache" 2>/dev/null; then
                    tmp_cache=""
                    _devtool_recipes_discard_backup "$old_cache_bak" "$stderr_file" "cache"
                    _devtool_recipes_discard_backup "$old_meta_bak" "$stderr_file" "metadata"
                    old_cache_bak=""
                    old_meta_bak=""
                else
                    printf 'ob dev refresh: failed to publish cache %s; restoring previous pair\n' \
                        "$cache" >>"$stderr_file"
                    rc=1
                    if _devtool_recipes_restore_file "$old_cache_bak" "$cache" "$had_cache" \
                        "$stderr_file" "cache"; then
                        old_cache_bak=""
                    fi
                    if _devtool_recipes_restore_file "$old_meta_bak" "$meta" "$had_meta" \
                        "$stderr_file" "metadata"; then
                        old_meta_bak=""
                    fi
                fi
            else
                printf 'ob dev refresh: failed to publish metadata %s\n' "$meta" >>"$stderr_file"
                rc=1
            fi
        fi
        if [[ "$meta_published" -eq 0 ]]; then
            _devtool_recipes_discard_backup "$old_cache_bak" "$stderr_file" "cache"
            _devtool_recipes_discard_backup "$old_meta_bak" "$stderr_file" "metadata"
        fi
        if [[ -n "$tmp_cache" ]] && ! rm -f "$tmp_cache" 2>/dev/null; then
            printf 'ob dev refresh: staged cache retained at %s\n' "$tmp_cache" >>"$stderr_file"
        fi
        if [[ -n "$tmp_meta" ]] && ! rm -f "$tmp_meta" 2>/dev/null; then
            printf 'ob dev refresh: staged metadata retained at %s\n' "$tmp_meta" >>"$stderr_file"
        fi
        return "$rc"
    }
    ```
  - 接线：把 `devtool_search_refresh` 的 else 块**体**（当前 [L386-L460](../../lib/devtool_search.sh#L386-L460)，即 [L385](../../lib/devtool_search.sh#L385) `else` 与 [L461](../../lib/devtool_search.sh#L461) 外层 `fi` 之间的全部 staged-atomic publish 编排——含 `local cache meta tmp_cache=...`/`meta_published` 状态机/`_devtool_recipes_backup_file`×2/publish `mv`+restore/discard/cleanup tmps）整段删除，替换为单行调用。**保留** L385 `else` 与 L461 `fi`，替换后 else 块形态为（缩进与原块体一致，20 空格）：
    ```bash
                    else
                        _devtool_recipes_publish_pair "$stdout_file" "$machine" "$post_hash" "$post_mtime" "$post_commit" "$stderr_file" || rc=1
                    fi
    ```
  - Change: 新增 `_devtool_recipes_publish_pair`（逐字搬移 L386-L461，仅把 block 局部变量改为函数 local、入参从 `$1`-`$6` 取、末尾 `return "$rc"`）；refresh else 块塌成一行调用，`|| rc=1` 把 helper 非0 return 映射回 refresh 的 `rc=1`（与原 block 内 `rc=1` 语义一致）。

- [ ] Step 4: 运行并确认通过（主锁=端到端金标第 1 条 + grep 接线第 3/4 条；`declare -F` 第 2 条为辅助，ob_loader.sh 加载链已由 image_build 同构命令验证可工作——若 rc 非 0 先排查加载链，不影响主锁判定）
  - Run: `bash tests/unit/devtool_search.sh >/dev/null 2>&1`
  - Expected: rc 0（端到端金标仍绿，行为不变）
  - Run: `bash -c 'source tests/lib/ob_loader.sh; declare -F _devtool_recipes_publish_pair' >/dev/null 2>&1`
  - Expected: rc 0（函数已定义）
  - Run: `sed -n '/^devtool_search_refresh()/,/^}/p' lib/devtool_search.sh | grep -q '_devtool_recipes_publish_pair'`
  - Expected: rc 0（refresh 已接线调用 publish_pair）
  - Run: `! sed -n '/^devtool_search_refresh()/,/^}/p' lib/devtool_search.sh | grep -q 'meta_published'`
  - Expected: rc 0（refresh 内无 publish 内联残留，meta_published 已随 block 搬入 helper）

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add lib/devtool_search.sh && git commit -m "refactor(devtool_search): extract _devtool_recipes_publish_pair leaf-pure helper from refresh"`
  - Expected: commit 成功

### Task 2: 最终配套验证

- 目标：全仓库配套自检 + coverage 基线 + 全测试通过，确认行为不变抽取未破坏任何约束。
- 涉及文件：无（仅运行验证命令）。
- 接口契约：
  - Consumes: Task 1 的 `_devtool_recipes_publish_pair` + refresh 接线成果。
  - Produces: 无。
- 验证范围：ob_check ALL GREEN；coverage uncovered ≤7；run_all 全绿。

- [ ] Step 1: 写当前状态检查
  - Task 1 已完成，`_devtool_recipes_publish_pair` 已定义并接线，进入收口验证。

- [ ] Step 2: 运行并确认前置就绪
  - Run: `grep -q '_devtool_recipes_publish_pair' lib/devtool_search.sh`
  - Expected: rc 0（helper 存在）

- [ ] Step 3: 写最小实现
  - 无代码改动（纯验证任务）。如某项失败，回到 Task 1 修复。

- [ ] Step 4: 运行并确认通过
  - Run: `bash tools/ob_check.sh >/dev/null 2>&1`
  - Expected: rc 0（ALL GREEN，含 exit_contract Y 仍绿 `devtool_search.sh: set()` + shellcheck baseline + extract_funcs + run_all）
  - Run: `tools/trace_collect.sh | python3 tools/coverage_radar.py - --fail-if-uncovered 7 >/dev/null 2>&1`
  - Expected: rc 0（uncovered ≤7，`_devtool_recipes_publish_pair` 被 refresh 测试间接覆盖，不涨）
  - Run: `bash tests/run_all.sh >/dev/null 2>&1`
  - Expected: rc 0（protocol/unit/orchestration 全绿）

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行（Task 1→2），不要无声跳步、合并步或改变任务目标。
- 每完成一个任务，都运行该任务 Step 4 定义的验证。
- 遇到阻塞、重复失败或计划与仓库现实不符，立即停下来说明，不要猜。
- 当前在 `main` 分支（HEAD `5f9756c` == `origin/main`，干净；已核实）。本任务是独立 refactor，建议开始实现前切 feature 分支（如 `feature/devtool-search-publish-deepen`）再落 commit，避免把 refactor 直接落到 main；开始实现前先与用户确认分支策略。
- 全部任务完成后，运行 Task 2 最终验证并输出修改摘要。

## 最终验证

- `bash tests/unit/devtool_search.sh` → exit 0（端到端金标全绿，行为不变）。
- `bash tools/ob_check.sh` → exit 0（ALL GREEN，exit_contract Y 含 `devtool_search.sh: set()` 不变）。
- `tools/trace_collect.sh | python3 tools/coverage_radar.py - --fail-if-uncovered 7` → exit 0（uncovered ≤7）。
- `bash tests/run_all.sh` → exit 0（protocol/unit/orchestration 全绿）。
- 沿用当前 shell（bash）与仓库惯例（`tools/` + `tests/` 脚本均可直接 `bash` 执行）。

## 审阅 Checkpoint

- 计划正文结束。请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行。
- 审阅通过前，不进入实现。
