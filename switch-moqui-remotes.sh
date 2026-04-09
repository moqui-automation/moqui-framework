#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

REPOS=(
  .
  runtime
  runtime/component/MarbleERP
  runtime/component/SimpleScreens
  runtime/component/example
  runtime/component/mantle-udm
  runtime/component/mantle-usl
  runtime/component/moqui-camel
  runtime/component/moqui-fop
  runtime/component/moqui-jep
  runtime/component/moqui-plc4j
  runtime/component/moqui-plc
  runtime/moqui-camel-gateway
)

PINNED_AUTOMATION_REPOS=(
  runtime/component/moqui-jep
  runtime/component/moqui-plc4j
  runtime/component/moqui-plc
  runtime/moqui-camel-gateway
)

LEGACY_REMOTES=(
  moqui
  official
)

declare -A REPO_OFFICIAL_NAME=(
  [.]="moqui-framework"
  [runtime]="moqui-framework"
  [runtime/component/MarbleERP]="MarbleERP"
  [runtime/component/SimpleScreens]="SimpleScreens"
  [runtime/component/example]="example"
  [runtime/component/mantle-udm]="mantle-udm"
  [runtime/component/mantle-usl]="mantle-usl"
  [runtime/component/moqui-camel]="moqui-camel"
  [runtime/component/moqui-fop]="moqui-fop"
)

declare -A REPO_AUTOMATION_NAME=(
  [.]="moqui-framework"
  [runtime]="moqui-runtime"
  [runtime/component/MarbleERP]="MarbleERP"
  [runtime/component/SimpleScreens]="SimpleScreens"
  [runtime/component/example]="example"
  [runtime/component/mantle-udm]="mantle-udm"
  [runtime/component/mantle-usl]="mantle-usl"
  [runtime/component/moqui-camel]="moqui-camel"
  [runtime/component/moqui-fop]="moqui-fop"
  [runtime/component/moqui-jep]="moqui-jep"
  [runtime/component/moqui-plc4j]="moqui-plc4j"
  [runtime/component/moqui-plc]="moqui-plc"
  [runtime/moqui-camel-gateway]="moqui-camel-gateway"
)

COMMAND=""
DRY_RUN=false
declare -a SELECTED_REPOS=()
declare -a TARGET_REPOS=()
declare -a SUMMARY=()
HAS_ISSUES=0

usage() {
  cat <<'EOF'
Usage: switch-moqui-remotes.sh <official|automation|show> [options]

Commands:
  official          switch the sync repos to the official Moqui repositories
  automation        switch every repo to the moqui-automation repositories
  show              print the current remote and tracking setup

Options:
  --repo <path>     limit execution to one repository path; repeatable
  --dry-run         print changes without applying them
  -h, --help        show this help

Rules:
  - origin is the active remote used by gitPullAll
  - automation is always configured as the moqui-automation remote
  - upstream is configured only for repos that exist in official Moqui
  - legacy remotes like moqui and official are removed during switching
  - pinned repos always stay on moqui-automation:
      runtime/component/moqui-jep
      runtime/component/moqui-plc4j
      runtime/component/moqui-plc
      runtime/moqui-camel-gateway

Typical flow:
  1. ./switch-moqui-remotes.sh official
  2. ./gradlew gitPullAll
  3. resolve merges and commit where needed
  4. ./switch-moqui-remotes.sh automation
  5. push the updated forks to moqui-automation
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

note() {
  echo "  - $*"
}

warn() {
  echo "  ! $*"
}

append_summary() {
  local state="$1"
  local repo_dir="$2"
  local message="$3"

  SUMMARY+=("[$state] $repo_dir: $message")
  if [[ "$state" != "OK" ]]; then
    HAS_ISSUES=1
  fi
}

run_git() {
  if [[ "$DRY_RUN" == true ]]; then
    printf 'DRY-RUN: git'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  else
    git "$@"
  fi
}

repo_abs_dir() {
  local repo_dir="$1"
  if [[ "$repo_dir" == "." ]]; then
    echo "$ROOT_DIR"
  else
    echo "$ROOT_DIR/$repo_dir"
  fi
}

is_git_repo() {
  local abs_dir="$1"
  git -C "$abs_dir" rev-parse --git-dir >/dev/null 2>&1
}

repo_in_list() {
  local repo_dir="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$repo_dir" ]]; then
      return 0
    fi
  done
  return 1
}

is_pinned_repo() {
  local repo_dir="$1"
  repo_in_list "$repo_dir" "${PINNED_AUTOMATION_REPOS[@]}"
}

has_official_repo() {
  local repo_dir="$1"
  [[ -n "${REPO_OFFICIAL_NAME[$repo_dir]:-}" ]]
}

repo_official_name() {
  local repo_dir="$1"
  echo "${REPO_OFFICIAL_NAME[$repo_dir]:-}"
}

repo_automation_name() {
  local repo_dir="$1"
  echo "${REPO_AUTOMATION_NAME[$repo_dir]:-}"
}

official_url() {
  local repo_name="$1"
  echo "https://github.com/moqui/${repo_name}.git"
}

automation_url() {
  local repo_name="$1"
  echo "git@github.com:moqui-automation/${repo_name}.git"
}

remote_exists() {
  local abs_dir="$1"
  local remote_name="$2"
  git -C "$abs_dir" remote get-url "$remote_name" >/dev/null 2>&1
}

set_remote_url() {
  local abs_dir="$1"
  local remote_name="$2"
  local url="$3"

  if remote_exists "$abs_dir" "$remote_name"; then
    run_git -C "$abs_dir" remote set-url "$remote_name" "$url"
  else
    run_git -C "$abs_dir" remote add "$remote_name" "$url"
  fi
}

remove_remote_if_exists() {
  local abs_dir="$1"
  local remote_name="$2"

  if remote_exists "$abs_dir" "$remote_name"; then
    run_git -C "$abs_dir" remote remove "$remote_name"
  fi
}

remove_legacy_remotes() {
  local abs_dir="$1"
  local remote_name

  for remote_name in "${LEGACY_REMOTES[@]}"; do
    remove_remote_if_exists "$abs_dir" "$remote_name"
  done
}

current_branch() {
  local abs_dir="$1"
  git -C "$abs_dir" branch --show-current
}

working_tree_dirty() {
  local abs_dir="$1"
  [[ -n "$(git -C "$abs_dir" status --short)" ]]
}

current_origin_url() {
  local abs_dir="$1"
  git -C "$abs_dir" remote get-url origin 2>/dev/null || true
}

current_automation_url() {
  local abs_dir="$1"
  git -C "$abs_dir" remote get-url automation 2>/dev/null || true
}

current_upstream_url() {
  local abs_dir="$1"
  git -C "$abs_dir" remote get-url upstream 2>/dev/null || true
}

tracking_branch() {
  local abs_dir="$1"
  local branch_name="$2"
  git -C "$abs_dir" for-each-ref --format='%(upstream:short)' "refs/heads/$branch_name"
}

determine_origin_mode() {
  local repo_dir="$1"
  local abs_dir="$2"
  local origin_url

  origin_url="$(current_origin_url "$abs_dir")"
  if is_pinned_repo "$repo_dir"; then
    case "$origin_url" in
      *github.com:moqui-automation/*|*github.com/moqui-automation/*)
        echo "automation (pinned)"
        ;;
      *github.com/moqui/*)
        echo "official (pinned mismatch)"
        ;;
      "")
        echo "missing (pinned mismatch)"
        ;;
      *)
        echo "custom (pinned mismatch)"
        ;;
    esac
    return
  fi

  case "$origin_url" in
    *github.com/moqui/*)
      echo "official"
      ;;
    *github.com:moqui-automation/*|*github.com/moqui-automation/*)
      echo "automation"
      ;;
    "")
      echo "missing"
      ;;
    *)
      echo "custom"
      ;;
  esac
}

normalize_branch_tracking() {
  local abs_dir="$1"
  local branch_name upstream_ref merge_branch remote_name

  while IFS='|' read -r branch_name upstream_ref; do
    [[ -n "$branch_name" ]] || continue

    if [[ -z "$upstream_ref" ]]; then
      merge_branch="$branch_name"
    else
      remote_name="${upstream_ref%%/*}"
      merge_branch="${upstream_ref#*/}"
      case "$remote_name" in
        origin|automation|upstream|official|moqui)
          ;;
        *)
          note "leaving tracking unchanged for $branch_name -> $upstream_ref"
          continue
          ;;
      esac
    fi

    run_git -C "$abs_dir" config "branch.$branch_name.remote" origin
    run_git -C "$abs_dir" config "branch.$branch_name.merge" "refs/heads/$merge_branch"
  done < <(git -C "$abs_dir" for-each-ref --format='%(refname:short)|%(upstream:short)' refs/heads)
}

configure_repo() {
  local repo_dir="$1"
  local abs_dir="$2"
  local automation_name official_name target_origin_url automation_remote_url upstream_remote_url mode_label

  automation_name="$(repo_automation_name "$repo_dir")"
  if [[ -z "$automation_name" ]]; then
    append_summary "FAILED" "$repo_dir" "missing automation repository mapping"
    return
  fi

  automation_remote_url="$(automation_url "$automation_name")"

  if is_pinned_repo "$repo_dir"; then
    target_origin_url="$automation_remote_url"
    mode_label="automation (pinned)"
  else
    official_name="$(repo_official_name "$repo_dir")"
    if [[ -z "$official_name" ]]; then
      append_summary "FAILED" "$repo_dir" "missing official repository mapping"
      return
    fi

    if [[ "$COMMAND" == "official" ]]; then
      target_origin_url="$(official_url "$official_name")"
      mode_label="official"
    else
      target_origin_url="$automation_remote_url"
      mode_label="automation"
    fi

    upstream_remote_url="$(official_url "$official_name")"
    set_remote_url "$abs_dir" upstream "$upstream_remote_url"
  fi

  set_remote_url "$abs_dir" automation "$automation_remote_url"
  set_remote_url "$abs_dir" origin "$target_origin_url"
  run_git -C "$abs_dir" config remote.pushDefault origin

  if is_pinned_repo "$repo_dir"; then
    remove_remote_if_exists "$abs_dir" upstream
  fi

  remove_legacy_remotes "$abs_dir"
  normalize_branch_tracking "$abs_dir"
  append_summary "OK" "$repo_dir" "origin -> $mode_label"
}

show_repo() {
  local repo_dir="$1"
  local abs_dir="$2"
  local branch_name tracking origin_url automation_remote_url upstream_remote_url mode

  branch_name="$(current_branch "$abs_dir")"
  tracking=""
  if [[ -n "$branch_name" ]]; then
    tracking="$(tracking_branch "$abs_dir" "$branch_name")"
  fi

  origin_url="$(current_origin_url "$abs_dir")"
  automation_remote_url="$(current_automation_url "$abs_dir")"
  upstream_remote_url="$(current_upstream_url "$abs_dir")"
  mode="$(determine_origin_mode "$repo_dir" "$abs_dir")"

  note "mode: $mode"
  note "branch: ${branch_name:-DETACHED}"
  note "tracking: ${tracking:-<none>}"
  if working_tree_dirty "$abs_dir"; then
    warn "working tree: dirty"
  else
    note "working tree: clean"
  fi
  note "origin: ${origin_url:-<missing>}"
  note "automation: ${automation_remote_url:-<missing>}"
  if [[ -n "$upstream_remote_url" ]]; then
    note "upstream: $upstream_remote_url"
  else
    note "upstream: <not configured>"
  fi

  append_summary "OK" "$repo_dir" "displayed status"
}

parse_args() {
  [[ $# -ge 1 ]] || {
    usage
    exit 1
  }

  COMMAND="$1"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        [[ $# -ge 2 ]] || die "missing value for --repo"
        SELECTED_REPOS+=("$2")
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done

  case "$COMMAND" in
    official|automation|show)
      ;;
    *)
      die "unknown command: $COMMAND"
      ;;
  esac
}

resolve_target_repos() {
  local selected repo_dir found

  if (( ${#SELECTED_REPOS[@]} > 0 )); then
    TARGET_REPOS=("${SELECTED_REPOS[@]}")
  else
    TARGET_REPOS=("${REPOS[@]}")
  fi

  for selected in "${TARGET_REPOS[@]}"; do
    found=false
    for repo_dir in "${REPOS[@]}"; do
      if [[ "$repo_dir" == "$selected" ]]; then
        found=true
        break
      fi
    done
    if [[ "$found" != true ]]; then
      die "unknown repository path: $selected"
    fi
  done
}

process_repo() {
  local repo_dir="$1"
  local abs_dir

  abs_dir="$(repo_abs_dir "$repo_dir")"
  echo
  echo "==> $repo_dir"

  if [[ ! -d "$abs_dir" ]]; then
    warn "directory not found"
    append_summary "SKIPPED" "$repo_dir" "directory not found"
    return
  fi

  if ! is_git_repo "$abs_dir"; then
    warn "not a Git repository"
    append_summary "SKIPPED" "$repo_dir" "not a Git repository"
    return
  fi

  case "$COMMAND" in
    show)
      show_repo "$repo_dir" "$abs_dir"
      ;;
    official|automation)
      configure_repo "$repo_dir" "$abs_dir"
      ;;
  esac
}

main() {
  parse_args "$@"
  resolve_target_repos

  for repo_dir in "${TARGET_REPOS[@]}"; do
    process_repo "$repo_dir"
  done

  echo
  echo "Summary"
  for line in "${SUMMARY[@]}"; do
    echo "  $line"
  done

  if [[ "$HAS_ISSUES" == "1" ]]; then
    exit 2
  fi
}

main "$@"
