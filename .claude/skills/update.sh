#!/usr/bin/env bash
# update.sh — 将 iasiv5/m 的 iasi 插件 skills 全量同步到本目录（受控镜像）
#
# 本目录（ob-harness/.claude/skills）是 iasiv5/m/plugins/iasi/skills 的本地镜像：
#   - 自研 skills 的维护源是 iasiv5/skills；本脚本同步进入 iasi 插件后的完整集合，不直接读取维护源。
#   - 修改自研 skill 时，先更新维护源并确认更新已进入 iasi 插件，再运行本脚本更新本地镜像。
#   - 同步策略为 1:1 全量：源端已有的 skill 原子替换本地同名目录，源端没有的本地 skill 删除。
#   - 同步 skill 目录和插件级 ATTRIBUTIONS.md；update.sh 本身不参与同步。
#
# 用法:
#   ./update.sh                                  # 克隆 iasiv5/m 并同步其 iasi 插件
#
# 环境变量:
#   GITHUB_BASE_URL      GitHub 基址，默认 https://github.com
#   GITHUB_MIRROR        GitHub 镜像基址，默认 https://gh-proxy.com/https://github.com

set -euo pipefail

SKILLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_BASE="$(mktemp -d "$SKILLS_DIR/.sync_tmp.XXXXXX")"
trap 'rm -rf "$TMP_BASE"' EXIT

command -v git >/dev/null 2>&1 || { echo "错误: 需要 git"; exit 1; }

log()  { printf '\033[34m▶\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m\n'; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; }

# 克隆 iasiv5/m，并返回 iasi 插件的 skills 目录路径。
clone_remote() {
  local repo="iasiv5/m" dest="$TMP_BASE/remote_src"
  local base="${GITHUB_BASE_URL:-https://github.com}"
  local mirror="${GITHUB_MIRROR:-https://gh-proxy.com/https://github.com}"
  local err="$TMP_BASE/.clone_err"
  if git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=60 clone --depth=1 --quiet "$base/$repo.git" "$dest" 2>"$err"; then
    printf '%s' "$dest/plugins/iasi/skills"; return 0
  fi
  log "github.com 克隆失败，尝试镜像 ${mirror#https://}"
  if git clone --depth=1 --quiet "$mirror/$repo.git" "$dest" 2>>"$err"; then
    printf '%s' "$dest/plugins/iasi/skills"; return 0
  fi
  fail "克隆失败: $repo"; sed 's/^/    /' "$err" >&2; return 1
}

# 列出目录下的非隐藏一级子目录名，每行一个。
list_skills() {  # $1=dir
  local d
  for d in "$1"/*/; do
    [[ -d "$d" ]] || continue
    basename "$d"
  done
}

# 先将 skill 复制到临时暂存目录，再替换目标；失败时恢复旧目录。
replace_skill_dir() {  # $1=src_dir $2=dest_dir $3=skill_name
  local src_dir="$1" dest_dir="$2" skill_name="$3"
  local stage="$TMP_BASE/.stage_${skill_name}" old="$TMP_BASE/.rollback_${skill_name}"
  rm -rf "$stage" "$old"; mkdir -p "$stage"
  cp -a "$src_dir/." "$stage/" || { fail "复制失败: $skill_name"; return 1; }
  [[ -e "$dest_dir" ]] && mv "$dest_dir" "$old"
  if mv "$stage" "$dest_dir"; then rm -rf "$old"; return 0; fi
  fail "替换失败: $skill_name"; rm -rf "$dest_dir"
  [[ -e "$old" ]] && mv "$old" "$dest_dir"; return 1
}

SRC="$(clone_remote)" || exit 1
[[ -d "$SRC" ]] || { fail "同步源不是目录: $SRC"; exit 1; }

log "同步源: github.com/iasiv5/m (plugins/iasi/skills)"
log "目标:   $SKILLS_DIR"
echo

# 获取插件提供的 skill 目录列表；空列表时中止，避免误删本地内容。
src_names=()
while IFS= read -r name; do
  [[ -n "$name" ]] && src_names+=("$name")
done < <(list_skills "$SRC")

if (( ${#src_names[@]} == 0 )); then
  fail "同步源没有任何 skill 目录: $SRC"
  fail "为防止误删本地 skill，中止同步。请检查同步源。"
  exit 1
fi

# 保存源端 skill 名称，供后续判断本地目录是否仍存在于源端。
declare -A src_set=()
for name in "${src_names[@]}"; do src_set["$name"]=1; done

# 将源端存在的 skill 原子替换到本地。
log "同步 skill（源共 ${#src_names[@]} 个）"
for name in "${src_names[@]}"; do
  printf '  %s ... ' "$name"
  if replace_skill_dir "$SRC/$name" "$SKILLS_DIR/$name" "$name"; then
    ok
  fi
done

# 同步 iasi 插件目录中的 ATTRIBUTIONS.md。
if [[ -f "$SRC/../ATTRIBUTIONS.md" ]]; then
  printf '  ATTRIBUTIONS.md ... '
  cp "$SRC/../ATTRIBUTIONS.md" "$SKILLS_DIR/ATTRIBUTIONS.md" && ok
else
  fail "m 的 ATTRIBUTIONS.md 未找到: $SRC/../ATTRIBUTIONS.md"
fi

# 仅删除本地存在、但源端已不存在的 skill。
removed=()
while IFS= read -r name; do
  [[ -n "$name" ]] && [[ -z "${src_set[$name]:-}" ]] && removed+=("$name")
done < <(list_skills "$SKILLS_DIR")

if (( ${#removed[@]} > 0 )); then
  echo
  log "删除本地多余 skill（源已移除，共 ${#removed[@]} 个）"
  for name in "${removed[@]}"; do
    printf '  %s ... ' "$name"
    if rm -rf "$SKILLS_DIR/$name"; then ok; fi
  done
fi

rm -rf "$TMP_BASE"; trap - EXIT

echo
log "完成！"
echo

if git -C "$SKILLS_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  changed=$(git -C "$SKILLS_DIR" status --short --untracked-files=all -- . || true)
  if [[ -n "$changed" ]]; then
    printf '\033[33m─────────────────────────────────────────\033[0m\n'
    printf '\033[33m  ob-harness 有变更尚未提交：\033[0m\n'
    printf '%s\n' "$changed" | sed 's/^/    /'
    printf '\033[33m─────────────────────────────────────────\033[0m\n'
    printf '  git add -A && git commit -m "sync skills from iasiv5/m marketplace"\n'
  else
    printf '  已是最新，无需提交。\n'
  fi
fi
