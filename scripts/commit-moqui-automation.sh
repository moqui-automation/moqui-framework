#!/usr/bin/env bash
# This software is in the public domain under CC0 1.0 Universal plus a
# Grant of Patent License.
#
# To the extent possible under law, the author(s) have dedicated all
# copyright and related and neighboring rights to this software to the
# public domain worldwide. This software is distributed without any
# warranty.
#
# You should have received a copy of the CC0 Public Domain Dedication
# along with this software (see the LICENSE.md file). If not, see
# <http://creativecommons.org/publicdomain/zero/1.0/>.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPORT_DIR="/tmp/moqui-automation-commit-report-$(date +%Y%m%d-%H%M%S)"
DO_COMMIT=0
DO_FETCH=0
UPSTREAM_REF="${UPSTREAM_REF:-origin/master}"

usage() {
    cat <<EOF
Usage:
  $(basename "$0") [--fetch] [--commit]

Default behavior:
  - generates comparison reports for each repository under ${REPORT_DIR}
  - does NOT create commits unless --commit is specified

Options:
  --fetch    run 'git fetch origin' for repositories that already have an origin remote
  --commit   stage and commit each repository separately
  -h, --help show this help

Optional environment variable overrides:
  UPSTREAM_REF=origin/master
  MOQUI_FRAMEWORK_MSG="..."
  EXAMPLE_MSG="..."
  MANTLE_UDM_MSG="..."
  MANTLE_USL_MSG="..."
  MOQUI_CAMEL_MSG="..."
  MOQUI_JEP_MSG="..."
  MOQUI_PLC4J_MSG="..."
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fetch) DO_FETCH=1 ;;
        --commit) DO_COMMIT=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
    shift
done

mkdir -p "${REPORT_DIR}"

declare -A REPO_PATHS=(
    [moqui-framework]="${ROOT_DIR}"
    [example]="${ROOT_DIR}/runtime/component/example"
    [mantle-udm]="${ROOT_DIR}/runtime/component/mantle-udm"
    [mantle-usl]="${ROOT_DIR}/runtime/component/mantle-usl"
    [moqui-camel]="${ROOT_DIR}/runtime/component/moqui-camel"
    [moqui-jep]="${ROOT_DIR}/runtime/component/moqui-jep"
    [moqui-plc4j]="${ROOT_DIR}/runtime/component/moqui-plc4j"
)

declare -A REPO_MESSAGES=(
    [moqui-framework]="${MOQUI_FRAMEWORK_MSG:-Customize framework for virtual threads, Python/JEP, and IIoT features}"
    [example]="${EXAMPLE_MSG:-Update example component customizations and tests}"
    [mantle-udm]="${MANTLE_UDM_MSG:-Add math and device entities plus related data}"
    [mantle-usl]="${MANTLE_USL_MSG:-Add math and device views and related service updates}"
    [moqui-camel]="${MOQUI_CAMEL_MSG:-Add configuration-driven Camel XML routes and tests}"
    [moqui-jep]="${MOQUI_JEP_MSG:-Initial moqui-jep component}"
    [moqui-plc4j]="${MOQUI_PLC4J_MSG:-Initial moqui-plc4j component}"
)

REPO_ORDER=(
    moqui-framework
    example
    mantle-udm
    mantle-usl
    moqui-camel
    moqui-jep
    moqui-plc4j
)

ROOT_EXCLUDES=(
    ":(exclude).claude"
    ":(exclude).codex"
    ":(exclude).gradle"
    ":(exclude).idea"
    ":(exclude).vscode"
    ":(exclude)logs"
    ":(exclude)modbuspal2.log"
    ":(exclude)build"
    ":(exclude)execwartmp"
    ":(exclude)moqui.war"
    ":(exclude)runtime/log"
    ":(exclude)runtime/db"
    ":(exclude)runtime/elasticsearch"
    ":(exclude)runtime/python_venv"
)

ROOT_STAGE_EXCLUDES=(
    ":(exclude).claude"
    ":(exclude).codex"
    ":(exclude)logs"
    ":(exclude)modbuspal2.log"
)

root_git_args() {
    printf '%s\n' . "${ROOT_EXCLUDES[@]}"
}

root_stage_args() {
    printf '%s\n' . "${ROOT_STAGE_EXCLUDES[@]}"
}

has_git_repo() {
    local repo_path="$1"
    local repo_top
    repo_top="$(git -C "${repo_path}" rev-parse --show-toplevel 2>/dev/null || true)"
    [[ -n "${repo_top}" ]] && [[ "${repo_top}" == "$(cd "${repo_path}" && pwd)" ]]
}

has_upstream_ref() {
    local repo_path="$1"
    git -C "${repo_path}" show-ref --verify --quiet "refs/remotes/${UPSTREAM_REF}"
}

fetch_origin_if_requested() {
    local repo_path="$1"
    if [[ "${DO_FETCH}" -eq 1 ]] && has_git_repo "${repo_path}" && git -C "${repo_path}" remote get-url origin >/dev/null 2>&1; then
        echo "Fetching origin for ${repo_path}"
        git -C "${repo_path}" fetch origin
    fi
}

write_report_for_existing_repo() {
    local repo_name="$1"
    local repo_path="$2"
    local repo_report_dir="${REPORT_DIR}/${repo_name}"
    mkdir -p "${repo_report_dir}"

    if [[ "${repo_name}" == "moqui-framework" ]]; then
        mapfile -t root_args < <(root_git_args)
        git -C "${repo_path}" status --short -- "${root_args[@]}" > "${repo_report_dir}/status-short.txt" || true
    else
        git -C "${repo_path}" status --short > "${repo_report_dir}/status-short.txt" || true
    fi

    if has_upstream_ref "${repo_path}"; then
        if [[ "${repo_name}" == "moqui-framework" ]]; then
            mapfile -t root_args < <(root_git_args)
            git -C "${repo_path}" diff --name-status "${UPSTREAM_REF}" -- "${root_args[@]}" > "${repo_report_dir}/diff-name-status.txt" || true
            git -C "${repo_path}" diff --stat "${UPSTREAM_REF}" -- "${root_args[@]}" > "${repo_report_dir}/diff-stat.txt" || true
        else
            git -C "${repo_path}" diff --name-status "${UPSTREAM_REF}" > "${repo_report_dir}/diff-name-status.txt" || true
            git -C "${repo_path}" diff --stat "${UPSTREAM_REF}" > "${repo_report_dir}/diff-stat.txt" || true
        fi
    else
        printf "Missing upstream ref %s\n" "${UPSTREAM_REF}" > "${repo_report_dir}/diff-name-status.txt"
        printf "Missing upstream ref %s\n" "${UPSTREAM_REF}" > "${repo_report_dir}/diff-stat.txt"
    fi
}

write_report_for_new_repo() {
    local repo_name="$1"
    local repo_path="$2"
    local repo_report_dir="${REPORT_DIR}/${repo_name}"
    mkdir -p "${repo_report_dir}"

    printf "NEW REPOSITORY (not initialized yet)\n" > "${repo_report_dir}/status-short.txt"
    (cd "${repo_path}" && find . -type f ! -path './.git/*' | sort) > "${repo_report_dir}/diff-name-status.txt"
    printf "No upstream diff available for a new repository.\n" > "${repo_report_dir}/diff-stat.txt"
}

stage_repo() {
    local repo_name="$1"
    local repo_path="$2"

    if [[ "${repo_name}" == "moqui-framework" ]]; then
        mapfile -t root_args < <(root_stage_args)
        git -C "${repo_path}" add -A -- "${root_args[@]}"
    else
        git -C "${repo_path}" add -A
    fi
}

init_new_repo_if_needed() {
    local repo_path="$1"
    if ! has_git_repo "${repo_path}"; then
        git -C "${repo_path}" init -b master
    fi
}

commit_repo_if_needed() {
    local repo_name="$1"
    local repo_path="$2"
    local message="$3"

    if ! git -C "${repo_path}" diff --cached --quiet; then
        echo "Committing ${repo_name}"
        git -C "${repo_path}" commit -m "${message}"
    else
        echo "No staged changes for ${repo_name}, skipping commit"
    fi
}

echo "Reports will be written to: ${REPORT_DIR}"
echo

for repo_name in "${REPO_ORDER[@]}"; do
    repo_path="${REPO_PATHS[${repo_name}]}"
    echo "== ${repo_name} =="
    echo "Path: ${repo_path}"

    if has_git_repo "${repo_path}"; then
        fetch_origin_if_requested "${repo_path}"
        write_report_for_existing_repo "${repo_name}" "${repo_path}"
        if [[ "${repo_name}" == "moqui-framework" ]]; then
            mapfile -t root_args < <(root_git_args)
            git -C "${repo_path}" status --short -- "${root_args[@]}" || true
        else
            git -C "${repo_path}" status --short || true
        fi
    else
        write_report_for_new_repo "${repo_name}" "${repo_path}"
        echo "Not a Git repository yet"
    fi

    echo
done

if [[ "${DO_COMMIT}" -ne 1 ]]; then
    echo "Preview completed. Review the reports under:"
    echo "  ${REPORT_DIR}"
    echo
    echo "When you are ready to commit, run:"
    echo "  $(basename "$0") --commit"
    echo
    echo "If you also want refreshed upstream comparisons first, run:"
    echo "  $(basename "$0") --fetch --commit"
    exit 0
fi

echo "Starting commit phase..."
echo

for repo_name in "${REPO_ORDER[@]}"; do
    repo_path="${REPO_PATHS[${repo_name}]}"
    repo_message="${REPO_MESSAGES[${repo_name}]}"

    echo "== commit ${repo_name} =="
    if ! has_git_repo "${repo_path}"; then
        echo "Initializing new repository in ${repo_path}"
        init_new_repo_if_needed "${repo_path}"
    fi

    stage_repo "${repo_name}" "${repo_path}"
    commit_repo_if_needed "${repo_name}" "${repo_path}" "${repo_message}"
    echo
done

echo "All repository commit steps completed."
echo "Comparison reports remain available under:"
echo "  ${REPORT_DIR}"
