#!/usr/bin/env bash
# update.sh — 从 m marketplace 的 iasi 插件全量原子同步 skills 到本目录
#
# 本目录（ob-harness/.claude/skills）是 m/plugins/iasi/skills 的受控镜像：
#   - 不就地编辑；要改 skill 去 m 仓库的 plugins/iasi/skills，再跑本脚本同步。
#   - 同步语义 1:1 全量：源有的 skill 原子替换进来，源没有的 skill 删除。
#   - 同步 skill 目录和 ATTRIBUTIONS.md（都从 m 镜像）；不碰 update.sh 脚本本身。
#
# 用法:
#   ./update.sh                                  # 从 github iasiv5/m clone 同步
#
# 环境变量:
#   GITHUB_BASE_URL      github 基址，默认 https://github.com
#   GITHUB_MIRROR        github 镜像，默认 https://gh-proxy.com/https://github.com

set -euo pipefail

SKILLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_BASE="$(mktemp -d "$SKILLS_DIR/.sync_tmp.XXXXXX")"
trap 'rm -rf "$TMP_BASE"' EXIT

command -v git >/dev/null 2>&1 || { echo "错误: 需要 git"; exit 1; }

log()  { printf '\033[34m▶\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m\n'; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; }

# 克隆 github iasiv5/m，输出其 plugins/iasi/skills 路径
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

# 列出某目录下的 skill 子目录名（非隐藏目录），每行一个
list_skills() {  # $1=dir
  local d
  for d in "$1"/*/; do
    [[ -d "$d" ]] || continue
    basename "$d"
  done
}

# 原子替换：src 内容 stage 后 mv 覆盖 dest，失败回滚
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

# 源 skill 集合
src_names=()
while IFS= read -r name; do
  [[ -n "$name" ]] && src_names+=("$name")
done < <(list_skills "$SRC")

if (( ${#src_names[@]} == 0 )); then
  fail "同步源没有任何 skill 目录: $SRC"
  fail "为防止误删本地 skill，中止同步。请检查同步源。"
  exit 1
fi

# 关联数组做 O(1) 查询
declare -A src_set=()
for name in "${src_names[@]}"; do src_set["$name"]=1; done

# 同步：源有则原子替换
log "同步 skill（源共 ${#src_names[@]} 个）"
for name in "${src_names[@]}"; do
  printf '  %s ... ' "$name"
  if replace_skill_dir "$SRC/$name" "$SKILLS_DIR/$name" "$name"; then
    ok
  fi
done

# 同步 ATTRIBUTIONS.md（从 m 的 iasi 目录镜像到本目录）
if [[ -f "$SRC/../ATTRIBUTIONS.md" ]]; then
  printf '  ATTRIBUTIONS.md ... '
  cp "$SRC/../ATTRIBUTIONS.md" "$SKILLS_DIR/ATTRIBUTIONS.md" && ok
else
  fail "m 的 ATTRIBUTIONS.md 未找到: $SRC/../ATTRIBUTIONS.md"
fi

# 删除：本地有但源没有的 skill
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
    printf '  git add -A && git commit -m "sync skills from m marketplace"\n'
  else
    printf '  已是最新，无需提交。\n'
  fi
fi
