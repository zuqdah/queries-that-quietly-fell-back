#!/usr/bin/env bash
#
# Creates the one thing the drill does not create for itself: a Fabric workspace
# on a capacity. Everything else -- the warehouse, the fixture, the six semantic
# models -- the drill builds and destroys on every run.
#
# This script used to be much larger. It created a federated Entra application, a
# workspace identity, a persistent warehouse and a fixed-identity cloud
# connection, so that the drill could run unattended in GitHub Actions. All of
# that has been removed, because the drill cannot run unattended: the only API
# that can report whether a table is really in Direct Lake mode is closed to
# service principals for exactly the kind of model this lab measures. See "The
# check that cannot be automated" in the README.
#
# The remains of that attempt are documented rather than kept. Complexity that
# exists because something was tried is worse than no complexity at all.
#
# Needs: az, node.
set -euo pipefail

WORKSPACE=""
CAPACITY=""
FABRIC_API="https://api.fabric.microsoft.com/v1"

usage() {
  cat <<'USAGE'
Usage: scripts/bootstrap.sh --workspace <name|guid> [--capacity <name|guid>]

  --workspace   Fabric workspace to run the drill in. Created if a name is given and no
                such workspace exists, which needs --capacity.
  --capacity    Fabric capacity to bind a newly created workspace to. A trial capacity
                works; it is started from the account manager in the Fabric portal.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) WORKSPACE="${2:-}"; shift 2 ;;
    --capacity) CAPACITY="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$WORKSPACE" ]; then
  echo "--workspace is required." >&2
  usage
  exit 2
fi

say() { printf '\n== %s\n' "$1"; }
note() { printf '   %s\n' "$1"; }

# Evaluates a JS expression against JSON on stdin; $1 refers to the parsed object
# as `j`. Prints an empty line rather than throwing, so callers test for empty.
pick() { node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);const v=$1;console.log(v===undefined||v===null?'':v);}catch(e){console.log('');}})"; }

fabric() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -X "$method" "${FABRIC_API}/${path}"
    -H "Authorization: Bearer ${FABRIC_TOKEN}"
    -H 'Content-Type: application/json')
  if [ -n "$body" ]; then args+=(--data "$body"); fi
  curl "${args[@]}"
}

find_by_name_or_id() {
  # find_by_name_or_id <collection-path> <name-or-guid>
  fabric GET "$1" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const v=(JSON.parse(d).value||[]);const q=process.argv[1];const m=v.find(x=>x.id===q||x.displayName===q);console.log(m?m.id:'');}catch(e){console.log('');}})" "$2"
}

# ------------------------------------------------------------------ preflight

say "Checking prerequisites"
for tool in az node; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is not on PATH." >&2; exit 1; }
done
az account show >/dev/null 2>&1 || { echo "Not signed in to az. Run: az login" >&2; exit 1; }

FABRIC_TOKEN=$(az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)
note "tenant $(az account show --query tenantId -o tsv)"

# A Fabric licence is assigned on first sign-in to the Fabric portal, not by the
# CLI. Without it every call below returns UserNotLicensed, which reads like a
# permissions problem rather than "you have never opened Fabric".
LICENCE_CHECK=$(fabric GET workspaces | pick 'j.errorCode')
if [ "$LICENCE_CHECK" = "UserNotLicensed" ]; then
  echo "   Fabric returns UserNotLicensed. Sign in once at https://app.fabric.microsoft.com" >&2
  echo "   to have the free per-user licence assigned, then run this again." >&2
  exit 1
fi

# --------------------------------------------------------------- the workspace

say "Resolving the workspace"
WORKSPACE_ID=$(find_by_name_or_id workspaces "$WORKSPACE")

if [ -n "$WORKSPACE_ID" ]; then
  note "reusing ${WORKSPACE_ID}"
else
  [ -n "$CAPACITY" ] || { echo "Workspace '${WORKSPACE}' does not exist and no --capacity was given to create it in." >&2; exit 1; }
  CAPACITY_ID=$(find_by_name_or_id capacities "$CAPACITY")
  if [ -z "$CAPACITY_ID" ]; then
    echo "No capacity matching '${CAPACITY}'." >&2
    echo "Fabric has no free tier: you need a trial capacity, started from the account manager" >&2
    echo "in the Fabric portal, or an F SKU. See the Cost section of the README." >&2
    exit 1
  fi
  WORKSPACE_ID=$(fabric POST workspaces "{\"displayName\":\"${WORKSPACE}\",\"capacityId\":\"${CAPACITY_ID}\"}" | pick 'j.id')
  [ -n "$WORKSPACE_ID" ] || { echo "Could not create workspace '${WORKSPACE}'." >&2; exit 1; }
  note "created ${WORKSPACE_ID} on capacity ${CAPACITY_ID}"
fi

# A Direct Lake model cannot be created in a personal workspace, and the error
# arrives several API calls later as something less obvious.
WORKSPACE_TYPE=$(fabric GET "workspaces/${WORKSPACE_ID}" | pick 'j.type')
if [ "$WORKSPACE_TYPE" = "Personal" ]; then
  echo "   '${WORKSPACE}' is a personal workspace (My workspace). Direct Lake models cannot be created there." >&2
  exit 1
fi

CAPACITY_BOUND=$(fabric GET "workspaces/${WORKSPACE_ID}" | pick 'j.capacityId')
if [ -z "$CAPACITY_BOUND" ]; then
  echo "   '${WORKSPACE}' is not on a capacity. Direct Lake requires one; assign a trial or F capacity." >&2
  exit 1
fi

say "Done"
cat <<EOF

  Workspace   ${WORKSPACE_ID}
  Capacity    ${CAPACITY_BOUND}

  Run the drill:

    pwsh ./scripts/Invoke-FallbackDrill.ps1 -WorkspaceId ${WORKSPACE_ID}

  It runs as you. See "The check that cannot be automated" in the README for why
  it cannot run as a service principal in CI.
EOF
