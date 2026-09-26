#!/usr/bin/env bash
#
# One-time setup so the drill can run unattended.
#
# Creates the persistent half of the lab -- a workspace identity, a warehouse and
# a cloud connection -- plus a federated Entra application to run the drill, and
# configures this repository. Re-runnable: everything it creates is looked up
# first.
#
# Why the warehouse lives here and not in the drill
# -------------------------------------------------
# A semantic model created by a service principal cannot frame under the default
# single sign-on configuration. It fails with "We cannot access the source Delta
# table", which reads like a missing table rather than a missing identity, and
# the documentation says as much in passing: default Direct Lake semantic models
# on a lakehouse or warehouse do not support service principals. The fix is to
# bind each model to a cloud connection with a fixed identity.
#
# A connection targets one specific server AND database, so it cannot be created
# ahead of a warehouse that does not exist yet. That makes the warehouse
# persistent setup and the semantic models the only thing the drill creates and
# destroys -- which is the right split anyway, since the models are what is under
# test.
#
# The fixed identity is the WORKSPACE IDENTITY, not a service principal secret.
# That is deliberate: there is no client secret anywhere in this design, so
# nothing to store, rotate or leak.
#
# Needs: az, gh, node. Not jq -- all three tools parse JSON themselves.
set -euo pipefail

WORKSPACE=""
CAPACITY=""
REPO=""
ENVIRONMENT="lab"
APP_NAME="queries-that-quietly-fell-back-orchestrator"
WAREHOUSE_NAME="wh_fallback"
CONNECTION_NAME="queries-that-quietly-fell-back-warehouse"
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

# Evaluates a JS expression against a JSON object on stdin. $1 refers to the
# parsed object as `j`. Prints an empty line rather than throwing, so callers
# test for emptiness.
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

fabric_async() {
  # Posts and, on a 202, polls the operation to completion. Prints the final
  # state. A create that is still Running is not a create that worked.
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -D - -o /dev/null -X "$method" "${FABRIC_API}/${path}"
    -H "Authorization: Bearer ${FABRIC_TOKEN}"
    -H 'Content-Type: application/json')
  if [ -n "$body" ]; then args+=(--data "$body"); else args+=(-H 'Content-Length: 0'); fi

  local headers status location
  headers=$(curl "${args[@]}")
  status=$(printf '%s' "$headers" | head -1 | awk '{print $2}')
  if [ "$status" = "200" ] || [ "$status" = "201" ]; then echo "Succeeded"; return 0; fi
  if [ "$status" != "202" ]; then echo "HTTP ${status}"; return 0; fi

  location=$(printf '%s' "$headers" | grep -i '^location:' | tr -d '\r' | sed 's/^[Ll]ocation: //')
  local state=""
  local elapsed=0
  while [ "$elapsed" -lt 120 ]; do
    sleep 10
    elapsed=$((elapsed + 10))
    state=$(curl -sS -H "Authorization: Bearer ${FABRIC_TOKEN}" "$location" | pick 'j.status')
    case "$state" in
      Succeeded|Failed) echo "$state"; return 0 ;;
    esac
  done
  echo "TimedOut(${state})"
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
# easy to confuse -- and were confused once, costing an afternoon. The title,
# not the identifier, is what the portal shows.
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
  note "created ${WORKSPACE_ID}"
fi

# ---------------------------------------------------- the workspace identity

# This is the fixed identity the connection will use. It exists so that no client
# secret has to: a service principal credential on the connection would mean a
# secret in a repository or a vault, and this needs neither.
say "Provisioning the workspace identity"
EXISTING_IDENTITY=$(fabric GET "workspaces/${WORKSPACE_ID}" | pick 'j.workspaceIdentity && j.workspaceIdentity.servicePrincipalId')
if [ -n "$EXISTING_IDENTITY" ]; then
  note "already has one (${EXISTING_IDENTITY})"
else
  STATE=$(fabric_async POST "workspaces/${WORKSPACE_ID}/provisionIdentity")
  if [ "$STATE" != "Succeeded" ]; then
    echo "   provisioning the workspace identity ended in: ${STATE}" >&2
    echo "   A workspace identity needs a Fabric capacity. A trial capacity works; shared does not." >&2
    exit 1
  fi
  EXISTING_IDENTITY=$(fabric GET "workspaces/${WORKSPACE_ID}" | pick 'j.workspaceIdentity && j.workspaceIdentity.servicePrincipalId')
  note "provisioned (${EXISTING_IDENTITY})"
fi

# --------------------------------------------------------------- the warehouse

say "Creating the warehouse"
WAREHOUSE_ID=$(fabric GET "workspaces/${WORKSPACE_ID}/warehouses" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const v=(JSON.parse(d).value||[]);const m=v.find(w=>w.displayName===process.argv[1]);console.log(m?m.id:'');}catch(e){console.log('');}})" "$WAREHOUSE_NAME")

if [ -n "$WAREHOUSE_ID" ]; then
  note "reusing ${WAREHOUSE_ID}"
else
  STATE=$(fabric_async POST "workspaces/${WORKSPACE_ID}/warehouses" \
    "{\"displayName\":\"${WAREHOUSE_NAME}\",\"description\":\"Source for the Direct Lake fallback drill\"}")
  if [ "$STATE" != "Succeeded" ]; then
    echo "   warehouse creation ended in: ${STATE}" >&2
    exit 1
  fi
  WAREHOUSE_ID=$(fabric GET "workspaces/${WORKSPACE_ID}/warehouses" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const v=(JSON.parse(d).value||[]);const m=v.find(w=>w.displayName===process.argv[1]);console.log(m?m.id:'');}catch(e){console.log('');}})" "$WAREHOUSE_NAME")
  [ -n "$WAREHOUSE_ID" ] || { echo "   warehouse reported success but is not listed." >&2; exit 1; }
  note "created ${WAREHOUSE_ID}"
fi

SQL_ENDPOINT=$(fabric GET "workspaces/${WORKSPACE_ID}/warehouses/${WAREHOUSE_ID}" | pick 'j.properties && j.properties.connectionString')
[ -n "$SQL_ENDPOINT" ] || { echo "   the warehouse reported no connection string." >&2; exit 1; }
note "endpoint ${SQL_ENDPOINT}"

# --------------------------------------------------------------- the connection

# Bound to the warehouse by server AND database, which is why it cannot be
# created before the warehouse exists. singleSignOnType None keeps the fixed
# identity in use for framing and for queries; with SSO on, framing would fall
# back to the caller's identity and the drill would break again under CI.
say "Creating the cloud connection"
CONNECTION_ID=$(fabric GET connections | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const v=(JSON.parse(d).value||[]);const m=v.find(c=>c.displayName===process.argv[1]);console.log(m?m.id:'');}catch(e){console.log('');}})" "$CONNECTION_NAME")

if [ -n "$CONNECTION_ID" ]; then
  note "reusing ${CONNECTION_ID}"
else
  CONNECTION_ID=$(fabric POST connections "{
    \"connectivityType\": \"ShareableCloud\",
    \"displayName\": \"${CONNECTION_NAME}\",
    \"connectionDetails\": {
      \"type\": \"SQL\",
      \"creationMethod\": \"SQL\",
      \"parameters\": [
        {\"dataType\": \"Text\", \"name\": \"server\", \"value\": \"${SQL_ENDPOINT}\"},
        {\"dataType\": \"Text\", \"name\": \"database\", \"value\": \"${WAREHOUSE_ID}\"}
      ]
    },
    \"privacyLevel\": \"Organizational\",
    \"credentialDetails\": {
      \"singleSignOnType\": \"None\",
      \"connectionEncryption\": \"NotEncrypted\",
      \"skipTestConnection\": false,
      \"credentials\": { \"credentialType\": \"WorkspaceIdentity\" }
    }
  }" | pick 'j.id')
  [ -n "$CONNECTION_ID" ] || { echo "   could not create the connection." >&2; exit 1; }
  # skipTestConnection was false, so reaching this line means Fabric tested the
  # connection and the workspace identity really can read the warehouse.
  note "created ${CONNECTION_ID} (test connection passed)"
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

# --------------------------------------------------- roles for the orchestrator

# Admin, not Member. The drill creates six semantic models and deletes them
# again, and Member cannot delete items it did not create. Without the delete, a
# second run inherits the first run's state and a guard passes for the wrong
# reason.
say "Granting the application Admin on the workspace"
ASSIGNED=$(fabric GET "workspaces/${WORKSPACE_ID}/roleAssignments" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const v=(JSON.parse(d).value||[]);const id=process.argv[1];const m=v.find(r=>r.principal&&r.principal.id===id);console.log(m?m.role:'');}catch(e){console.log('');}})" "$SP_OBJECT_ID")

if [ "$ASSIGNED" = "Admin" ]; then
  note "already Admin"
else
  RESULT=$(fabric POST "workspaces/${WORKSPACE_ID}/roleAssignments" \
    "{\"principal\":{\"id\":\"${SP_OBJECT_ID}\",\"type\":\"ServicePrincipal\"},\"role\":\"Admin\"}")
  CODE=$(echo "$RESULT" | pick 'j.errorCode')
  if [ -n "$CODE" ]; then
    echo "   could not assign the workspace role: ${CODE} $(echo "$RESULT" | pick 'j.message')" >&2
    exit 1
  fi
  note "Admin assigned"
fi

# Workspace Admin is not enough to USE a connection -- connections carry their
# own role assignments, and binding a model to one the orchestrator cannot use
# fails at framing rather than at bind time.
say "Granting the application use of the connection"
CONN_ROLE=$(fabric GET "connections/${CONNECTION_ID}/roleAssignments" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const v=(JSON.parse(d).value||[]);const id=process.argv[1];const m=v.find(r=>r.principal&&r.principal.id===id);console.log(m?m.role:'');}catch(e){console.log('');}})" "$SP_OBJECT_ID")

if [ -n "$CONN_ROLE" ]; then
  note "already has ${CONN_ROLE}"
else
  RESULT=$(fabric POST "connections/${CONNECTION_ID}/roleAssignments" \
    "{\"principal\":{\"id\":\"${SP_OBJECT_ID}\",\"type\":\"ServicePrincipal\"},\"role\":\"User\"}")
  CODE=$(echo "$RESULT" | pick 'j.errorCode')
  if [ -n "$CODE" ]; then
    echo "   could not grant use of the connection: ${CODE} $(echo "$RESULT" | pick 'j.message')" >&2
    exit 1
  fi
  note "User assigned"
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
gh_write "variable FABRIC_WAREHOUSE_ID" gh variable set FABRIC_WAREHOUSE_ID --repo "$REPO" --body "$WAREHOUSE_ID"
gh_write "variable FABRIC_CONNECTION_ID" gh variable set FABRIC_CONNECTION_ID --repo "$REPO" --body "$CONNECTION_ID"
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
  Warehouse     ${WAREHOUSE_ID}
  Connection    ${CONNECTION_ID}  (fixed identity: workspace identity)

  Entra federated credentials take about three minutes to propagate. Then:

    gh workflow run drill.yml --repo ${REPO}
EOF
