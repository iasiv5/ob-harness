#!/usr/bin/env bash
# update.sh — 更新本仓库 .claude/skills 下定义的 skills
# 用法:
#   ./update.sh                      # 更新 .your-skill-collection.json 中所有未跳过的 skills
#   ./update.sh codebase-design      # 只更新指定的 skill
# 注意: skip 列表中的 skill 不参与更新

set -euo pipefail

SKILLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_DIR="$(command -v cygpath >/dev/null 2>&1 && cygpath -w "$SKILLS_DIR" || echo "$SKILLS_DIR")"
TMP_BASE="$(mktemp -d "$SKILLS_DIR/.update_tmp.XXXXXX")"
trap 'rm -rf "$TMP_BASE"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "错误: 需要 python3"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "错误: 需要 git"; exit 1; }

log()  { printf '\033[34m▶\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✓ 已更新\033[0m\n'; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; }

FILTER="${*:-}"

# 主源（默认 github.com）与镜像兜底源。镜像源可用环境变量覆盖：
#   GITHUB_MIRROR=https://gh-proxy.com/https://github.com ./update.sh
BASE="${GITHUB_BASE_URL:-https://github.com}"
MIRROR="${GITHUB_MIRROR:-https://gh-proxy.com/https://github.com}"
CLONE_ERR="$TMP_BASE/.clone_err"

clone_url() {  # $1=base $2=repo(owner/name) $3=dest
  git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=60 -c http.connectTimeout=60 \
    clone --depth=1 --quiet "$1/$2.git" "$3" 2>"$CLONE_ERR"
}

is_net_failure() {  # $1=本次耗时(s)
  local err
  err=$(cat "$CLONE_ERR" 2>/dev/null || true)
  (( ${1:-0} >= 50 )) && return 0
  [[ "$err" =~ (timed[[:space:]]out|Connection[[:space:]]timed[[:space:]]out|early[[:space:]]EOF|RPC[[:space:]]failed|Could[[:space:]]not[[:space:]]resolve[[:space:]]host|Connection[[:space:]]refused|Connection[[:space:]]reset|Failed[[:space:]]to[[:space:]]connect|unable[[:space:]]to[[:space:]]access|Empty[[:space:]]reply) ]]
}

get_clone() {
  local repo="$1"
  local dest="$TMP_BASE/${repo//\//__}"

  [[ -d "$dest" ]] && { printf '%s' "$dest"; return 0; }

  if [[ -f "$TMP_BASE/.use_mirror" ]]; then
    if clone_url "$MIRROR" "$repo" "$dest"; then
      printf '%s' "$dest"
      return 0
    fi
    rm -rf "$dest"
    fail "镜像克隆失败: $repo"
    return 1
  fi

  local start=$SECONDS
  if clone_url "$BASE" "$repo" "$dest"; then
    printf '%s' "$dest"
    return 0
  fi
  local dur=$((SECONDS - start))
  rm -rf "$dest"

  if is_net_failure "$dur"; then
    printf '\033[33m    ⚠ github.com 无法触达（60s 内无数据），切换镜像源 %s\033[0m\n' "${MIRROR#https://}" >&2
    : > "$TMP_BASE/.use_mirror"
    if clone_url "$MIRROR" "$repo" "$dest"; then
      printf '%s' "$dest"
      return 0
    fi
    rm -rf "$dest"
    fail "镜像克隆失败: $repo"
    return 1
  fi

  fail "克隆失败: $repo（耗时 ${dur}s）"
  return 1
}

# 输出格式: name TAB repo TAB mode TAB payload
#   mode=subdir: payload=子目录路径（或空）
#   mode=files:  payload=JSON 数组字符串
read_skills() {
  python3 -c "
import json, os, sys
data = json.load(open(os.path.join(sys.argv[2], '.your-skill-collection.json')))
skips = set(data.get('skip', []))
filters = set(sys.argv[1].split()) if sys.argv[1].strip() else None
for name, cfg in data['skills'].items():
    if name in skips:
        continue
    if filters and name not in filters:
        continue
    if 'files' in cfg:
        import json as j
        print(name + '\t' + cfg['repo'] + '\tfiles\t' + j.dumps(cfg['files']))
    else:
        print(name + '\t' + cfg['repo'] + '\tsubdir\t' + cfg.get('subdir', ''))
" "$FILTER" "$PYTHON_DIR"
}

stage_subdir_contents() {  # $1=src_dir $2=stage_dir
  cp -a "$1/." "$2/"
}

replace_skill_dir() {  # $1=stage_dir $2=dest_dir $3=skill_name
  local stage_dir="$1"
  local dest_dir="$2"
  local skill_name="$3"
  local old_dir="$TMP_BASE/.rollback_${skill_name}"

  rm -rf "$old_dir"
  if [[ -e "$dest_dir" ]]; then
    mv "$dest_dir" "$old_dir"
  fi

  if mv "$stage_dir" "$dest_dir"; then
    rm -rf "$old_dir"
    return 0
  fi

  fail "替换失败: $skill_name"
  rm -rf "$dest_dir"
  if [[ -e "$old_dir" ]]; then
    mv "$old_dir" "$dest_dir"
  fi
  return 1
}

[[ -n "$FILTER" ]] && log "更新 skills: $FILTER" || log "更新所有 skills"
echo

while IFS=$'\t' read -r name repo mode payload; do
  printf '  %s\n' "$name"
  dest="$SKILLS_DIR/$name"
  stage="$TMP_BASE/.stage_${name}"

  rm -rf "$stage"
  mkdir -p "$stage"

  printf '    克隆 https://github.com/%s ... ' "$repo"
  repo_dir=$(get_clone "$repo") || {
    rm -rf "$stage"
    continue
  }

  if [[ "$mode" == "files" ]]; then
    local_err=0
    while IFS=$'\t' read -r src_path dest_name; do
      full_src="$repo_dir/$src_path"
      full_dest="$stage/$dest_name"
      mkdir -p "$(dirname "$full_dest")"
      if [[ -f "$full_src" ]]; then
        cp "$full_src" "$full_dest" || { local_err=1; break; }
      elif [[ -d "$full_src" ]]; then
        mkdir -p "$full_dest"
        stage_subdir_contents "$full_src" "$full_dest" || { local_err=1; break; }
      else
        printf '\n'
        fail "路径不存在: $src_path"
        local_err=1
        break
      fi
    done < <(python3 -c "
import json, sys
for item in json.loads(sys.argv[1]):
    print(item['src'] + '\t' + item['dest'])
" "$payload")

    if [[ $local_err -ne 0 ]]; then
      rm -rf "$stage"
      continue
    fi
  elif [[ -n "$payload" ]]; then
    src="$repo_dir/$payload"
    if [[ ! -d "$src" ]]; then
      fail "子目录不存在: $payload"
      rm -rf "$stage"
      continue
    fi
    if ! stage_subdir_contents "$src" "$stage"; then
      fail "复制失败: $name"
      rm -rf "$stage"
      continue
    fi
  else
    if ! stage_subdir_contents "$repo_dir" "$stage"; then
      fail "复制失败: $name"
      rm -rf "$stage"
      continue
    fi
    rm -rf "$stage/.git"
  fi

  if replace_skill_dir "$stage" "$dest" "$name"; then
    ok
  else
    rm -rf "$stage"
  fi
done < <(read_skills)

rm -rf "$TMP_BASE"
trap - EXIT

echo
log "完成！"
echo

if git -C "$SKILLS_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  changed=$(git -C "$SKILLS_DIR" status --short --untracked-files=all || true)
  if [[ -n "$changed" ]]; then
    printf '\033[33m─────────────────────────────────────────\033[0m\n'
    printf '\033[33m  有变更尚未提交：\033[0m\n'
    printf '%s\n' "$changed" | sed 's/^/    /'
    printf '\033[33m─────────────────────────────────────────\033[0m\n'
    printf '  git add -A && git commit -m "update skills"\n'
  else
    printf '  已是最新，无需提交。\n'
  fi
fi