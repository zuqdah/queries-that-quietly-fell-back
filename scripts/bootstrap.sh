#!/usr/bin/env bash
#
# One-time setup so the drill can run unattended.
#
# Creates a federated Entra application, gives it Admin on an existing Fabric
# workspace, and configures this repository. Re-runnable: everything it creates
# is looked up first.
#
# The workspace is created here, by a human, and reused. The drill creates and
# destroys only the items inside it -- a warehouse and two semantic models.
# That is a deliberate split: creating a workspace requires the tenant setting
# "Service principals can create workspaces, connections, and deployment
# pipelines", and there is no reason to hand a lab orchestrator that when a
# workspace role is enough. The setting the drill DOES need,
# "Service principals can call Fabric public APIs", is separate and is checked
# below.
#
# Needs: az, gh. Not jq -- both tools parse JSON themselves.
set -euo pipefail

WORKSPACE=""
CAPACITY=""
REPO=""
ENVIRONMENT="lab"
APP_NAME="queries-that-quietly-fell-back-orchestrator"
FABRIC_API="https://api.fabric.microsoft.com/v1"

usage() {
  cat <<'USAGE'
Usage: scripts/bootstrap.sh --workspace <name|guid> [--capacity <name|guid>] [--repo owner/name] [--environment name]

  --workspace    Fabric workspace to run the drill in. Created if a name is given and no
                 such workspace exists, which needs --capacity.
  --capacity     Fabric capacity to bind a newly created workspace to. Only needed when
                 the workspace does not exist yet.
  --repo         GitHub repository as owner/name. Defaults to this checkout's origin.
  --environment  GitHub environment named in the OIDC subject. Default: lab
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) WORKSPACE="${2:-}"; shift 2 ;;
    --capacity) CAPACITY="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --environment) ENVIRONMENT="${2:-}"; shift 2 ;;
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

# Reads a field out of a JSON object on stdin without needing jq.
pick() { node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);const v=$1;console.log(v===undefined||v===null?'':v);}catch(e){console.log('');}})"; }

fabric() {
  # fabric <method> <path> [body]
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -X "$method" "${FABRIC_API}/${path}"
    -H "Authorization: Bearer ${FABRIC_TOKEN}"
    -H 'Content-Type: application/json')
  if [ -n "$body" ]; then args+=(--data "$body"); fi
  curl "${args[@]}"
}

# ------------------------------------------------------------------ preflight

say "Checking prerequisites"
for tool in az gh node; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is not on PATH." >&2; exit 1; }
done
az account show >/dev/null 2>&1 || { echo "Not signed in to az. Run: az login" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not signed in to gh. Run: gh auth login" >&2; exit 1; }

TENANT_ID=$(az account show --query tenantId -o tsv)
FABRIC_TOKEN=$(az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)
note "tenant ${TENANT_ID}"

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  [ -n "$REPO" ] || { echo "Could not work out the repository. Pass --repo owner/name." >&2; exit 1; }
fi

# The one tenant setting the drill cannot work around. Checked rather than
# assumed, because its name and the name of the workspace-creation setting are
# easy to confuse -- the title, not the identifier, is what the portal shows.
say "Checking the tenant allows service principals to call Fabric APIs"
SP_APIS=$(fabric GET admin/tenantsettings | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const s=(JSON.parse(d).tenantSettings||[]).find(x=>x.settingName==='ServicePrincipalAccessPermissionAPIs');console.log(s?String(s.enabled):'unknown');}catch(e){console.log('unreadable');}})")
case "$SP_APIS" in
  true) note "enabled" ;;
  unknown|unreadable)
    note "WARNING: could not read the tenant setting. If the drill gets 401 from Fabric, check"
    note "         Admin portal -> Tenant settings -> Developer settings ->"
    note "         'Service principals can call Fabric public APIs'." ;;
  *)
    echo "   'Service principals can call Fabric public APIs' is off. The drill cannot run without it." >&2
    echo "   Admin portal -> Tenant settings -> Developer settings." >&2
    exit 1 ;;
esac

# --------------------------------------------------------------- the workspace

say "Resolving the workspace"
WORKSPACE_ID=$(fabric GET workspaces | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const v=(JSON.parse(d).value||[]);const q=process.argv[1];const m=v.find(w=>w.id===q||w.displayName===q);console.log(m?m.id:'');}catch(e){console.log('');}})" "$WORKSPACE")

if [ -n "$WORKSPACE_ID" ]; then
  note "reusing ${WORKSPACE_ID}"
else
  [ -n "$CAPACITY" ] || { echo "Workspace '${WORKSPACE}' does not exist and no --capacity was given to create it in." >&2; exit 1; }
  CAPACITY_ID=$(fabric GET capacities | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const v=(JSON.parse(d).value||[]);const q=process.argv[1];const m=v.find(c=>c.id===q||c.displayName===q);console.log(m?m.id:'');}catch(e){console.log('');}})" "$CAPACITY")
  [ -n "$CAPACITY_ID" ] || { echo "No capacity matching '${CAPACITY}'. A Fabric trial capacity is started from the account manager in the Fabric portal." >&2; exit 1; }
  WORKSPACE_ID=$(fabric POST workspaces "{\"displayName\":\"${WORKSPACE}\",\"capacityId\":\"${CAPACITY_ID}\"}" | pick 'j.id')
  [ -n "$WORKSPACE_ID" ] || { echo "Could not create workspace '${WORKSPACE}'." >&2; exit 1; }
  note "created ${WORKSPACE_ID} on capacity ${CAPACITY_ID}"
fi

# ----------------------------------------------------------------- the identity

say "Creating the orchestrator application"
APP_ID=$(az ad app list --filter "displayName eq '${APP_NAME}'" --query '[0].appId' -o tsv 2>/dev/null || true)
if [ -n "$APP_ID" ] && [ "$APP_ID" != "None" ]; then
  note "reusing ${APP_ID}"
else
  APP_ID=$(az ad app create --display-name "$APP_NAME" --sign-in-audience AzureADMyOrg --query appId -o tsv)
  note "created ${APP_ID}"
fi

SP_OBJECT_ID=$(az ad sp list --filter "appId eq '${APP_ID}'" --query '[0].id' -o tsv 2>/dev/null || true)
if [ -z "$SP_OBJECT_ID" ] || [ "$SP_OBJECT_ID" = "None" ]; then
  SP_OBJECT_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
  note "created service principal ${SP_OBJECT_ID}"
  # Entra needs a moment before a brand new principal can be referenced by a
  # Fabric role assignment; the failure otherwise names the principal as though
  # it did not exist.
  sleep 30
fi

# The IMMUTABLE subject form, built from GitHub's numeric ids. The portable
# repo:OWNER/REPO form is what the documentation shows and it does not work:
# GitHub presents repo:OWNER@OWNERID/REPO@REPOID and Entra matches the subject
# as an exact string. A sibling lab died on AADSTS700213 proving it.
OWNER_ID=$(gh api "repos/${REPO}" -q .owner.id)
REPO_ID=$(gh api "repos/${REPO}" -q .id)
SUBJECT="repo:${REPO%%/*}@${OWNER_ID}/${REPO#*/}@${REPO_ID}:environment:${ENVIRONMENT}"

say "Adding the federated credential"
note "subject ${SUBJECT}"
EXISTING=$(az ad app federated-credential list --id "$APP_ID" \
  --query "[?name=='github-actions'].subject | [0]" -o tsv 2>/dev/null || true)
if [ "$EXISTING" = "$SUBJECT" ]; then
  note "already trusts the right subject"
else
  if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
    note "replacing a credential that trusted '${EXISTING}'"
    az ad app federated-credential delete --id "$APP_ID" --federated-credential-id github-actions
  fi
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"github-actions\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"${SUBJECT}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" >/dev/null
  note "credential set"
fi

# --------------------------------------------------- the workspace role

# Admin, not Member. The drill creates a warehouse and semantic models and
# deletes them again at the end of a run, and Member cannot delete items it did
# not create. Without the delete, a second run inherits the first run's state
# and a guard passes for the wrong reason.
say "Granting the application Admin on the workspace"
ASSIGNED=$(fabric GET "workspaces/${WORKSPACE_ID}/roleAssignments" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const v=(JSON.parse(d).value||[]);const id=process.argv[1];const m=v.find(r=>r.principal&&r.principal.id===id);console.log(m?m.role:'');}catch(e){console.log('');}})" "$SP_OBJECT_ID")

if [ "$ASSIGNED" = "Admin" ]; then
  note "already Admin"
else
  RESULT=$(fabric POST "workspaces/${WORKSPACE_ID}/roleAssignments" \
    "{\"principal\":{\"id\":\"${SP_OBJECT_ID}\",\"type\":\"ServicePrincipal\"},\"role\":\"Admin\"}")
  CODE=$(echo "$RESULT" | pick 'j.errorCode')
  if [ -n "$CODE" ]; then
    echo "   could not assign the role: ${CODE} $(echo "$RESULT" | pick 'j.message')" >&2
    exit 1
  fi
  note "Admin assigned"
fi

# ----------------------------------------------------- github configuration

say "Configuring the repository"

# A newly created repository refuses its first Actions writes with 403, and
# secrets settle later than variables. Retried generously rather than treated as
# a permission problem, which is what the message claims.
gh_write() {
  local what="$1"; shift
  local delay
  for delay in 5 10 20 30 0; do
    if "$@" >/dev/null 2>&1; then note "set ${what}"; return 0; fi
    [ "$delay" -gt 0 ] && { note "setting ${what} was refused, retrying in ${delay}s"; sleep "$delay"; }
  done
  echo "   could not set ${what}; the error follows:" >&2
  "$@" >&2 2>&1 || true
  return 1
}

gh_write "variable FABRIC_WORKSPACE_ID" gh variable set FABRIC_WORKSPACE_ID --repo "$REPO" --body "$WORKSPACE_ID"
# Secrets rather than variables: neither is a credential on its own, but GitHub
# masks secrets in workflow logs and does not mask variables, and the tenant id
# identifies the directory these labs run in.
gh_write "secret AZURE_CLIENT_ID" gh secret set AZURE_CLIENT_ID --repo "$REPO" --body "$APP_ID"
gh_write "secret AZURE_TENANT_ID" gh secret set AZURE_TENANT_ID --repo "$REPO" --body "$TENANT_ID"

if gh api "repos/${REPO}/environments/${ENVIRONMENT}" >/dev/null 2>&1; then
  note "environment '${ENVIRONMENT}' already exists"
else
  gh_write "environment ${ENVIRONMENT}" gh api --method PUT "repos/${REPO}/environments/${ENVIRONMENT}"
fi

say "Done"
cat <<EOF

  Application   ${APP_NAME}
  Client id     ${APP_ID}
  Tenant id     ${TENANT_ID}
  Subject       ${SUBJECT}
  Workspace     ${WORKSPACE_ID}

  Entra federated credentials take about three minutes to propagate. Then:

    gh workflow run drill.yml --repo ${REPO}
EOF
