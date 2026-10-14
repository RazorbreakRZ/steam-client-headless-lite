#!/usr/bin/env bash
# =============================================================================
# clean-local.sh — tidy up local development leftovers for this project.
# -----------------------------------------------------------------------------
# Removes, in increasing order of aggressiveness:
#   - the build/run container from docker-compose.build.yml
#   - the locally built image (steam-client-headless-lite:local)
#   - the BuildKit build cache (apt cache mounts + dangling layers)   [--deep]
#   - the local bind-mount test data in ./.local                      [--data]
#
# SAFE BY DEFAULT: a dry run that only prints what it would do. Nothing is
# removed unless you pass --execute. The two heavy/destructive steps are opt-in
# via --deep and --data even in --execute mode.
#
# Usage:
#   ./scripts/clean-local.sh                      # dry-run, show the plan
#   ./scripts/clean-local.sh --execute            # remove container + :local image
#   ./scripts/clean-local.sh --execute --deep     # also prune BuildKit cache
#   ./scripts/clean-local.sh --execute --data     # also delete ./.local test data
#   ./scripts/clean-local.sh --execute --deep --data   # everything
#
# Options:
#   --execute   Actually perform the actions (default: dry-run).
#   --deep      Also prune the Docker BuildKit build cache (frees the most space,
#               but the next build re-downloads apt packages). System-wide.
#   --data      Also delete ./.local (Steam runtime + session test data). You
#               will have to log in and re-download the client on next start.
#   --sudo      Prefix docker commands with sudo (if your user isn't in the
#               docker group).
#   -h|--help   Show this help.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.build.yml"
IMAGE="steam-client-headless-lite:local"
LOCAL_DATA="${PROJECT_DIR}/.local"

DRY_RUN=true
DEEP=false
DATA=false
DOCKER="docker"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --execute) DRY_RUN=false; shift ;;
        --deep)    DEEP=true; shift ;;
        --data)    DATA=true; shift ;;
        --sudo)    DOCKER="sudo docker"; shift ;;
        -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; echo "Use -h for help." >&2; exit 2 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
run() {
    local cmd="$*"
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${NC} ${cmd}"
    else
        echo -e "${GREEN}[EXEC]${NC} ${cmd}"
        eval "${cmd}"
    fi
}

echo "=============================================="
echo " clean-local — development cleanup"
echo "=============================================="
echo "  Project : ${PROJECT_DIR}"
echo "  Image   : ${IMAGE}"
if $DRY_RUN; then
    echo -e "  Mode    : ${YELLOW}DRY-RUN (nothing is removed)${NC}"
    echo "  Add --execute to apply."
else
    echo -e "  Mode    : ${RED}EXECUTE${NC}"
fi
echo "  Deep    : $($DEEP && echo 'yes (prune build cache)' || echo 'no')"
echo "  Data    : $($DATA && echo 'yes (delete ./.local)' || echo 'no')"
echo ""

# 1) Stop and remove the compose container.
if [[ -f "${COMPOSE_FILE}" ]]; then
    run "${DOCKER} compose -f '${COMPOSE_FILE}' down"
else
    echo "  (no ${COMPOSE_FILE}; skipping compose down)"
fi

# 2) Remove the locally built image.
run "${DOCKER} image rm '${IMAGE}' 2>/dev/null || true"

# 3) Optional: prune the BuildKit build cache (system-wide).
if $DEEP; then
    echo -e "${YELLOW}  --deep: this prunes ALL unused build cache on the host, not just this project.${NC}"
    run "${DOCKER} builder prune -f"
fi

# 4) Optional: delete local test data.
if $DATA; then
    if [[ -d "${LOCAL_DATA}" ]]; then
        echo -e "${RED}  --data: deleting ${LOCAL_DATA} (Steam runtime + session will be lost).${NC}"
        run "rm -rf '${LOCAL_DATA}'"
    else
        echo "  (${LOCAL_DATA} does not exist; nothing to delete)"
    fi
fi

echo ""
if $DRY_RUN; then
    echo -e "${YELLOW}Dry-run complete. Re-run with --execute to apply.${NC}"
else
    echo -e "${GREEN}Done.${NC}"
fi
echo ""
