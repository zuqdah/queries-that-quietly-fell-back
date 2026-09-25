# A controller for running the drill from a machine without PowerShell 7.
#
# The machine this lab was written on has PowerShell 5.1 only, and the drill
# needs 7. It also needs to run T-SQL against a Fabric warehouse, and that is the
# interesting part: System.Data.SqlClient is a .NET Framework assembly and does
# not exist on PowerShell 7 on Linux, so the Windows trick of
# `New-Object System.Data.SqlClient.SqlConnection` with an AccessToken property
# does not transfer. The SqlServer module's Invoke-Sqlcmd does, and its
# -AccessToken parameter is the only cross-platform way in that takes an Entra
# token rather than a password. Verified on this image before the drill depended
# on it.
#
#   docker build -f dev/controller.Dockerfile -t fallback-controller dev
#
# Then, from the repository root, passing tokens in from the host:
#
#   docker run --rm -v "$PWD:/lab" -w /lab \
#     -e FABRIC_TOKEN="$(az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)" \
#     -e POWERBI_TOKEN="$(az account get-access-token --resource https://analysis.windows.net/powerbi/api --query accessToken -o tsv)" \
#     -e WAREHOUSE_TOKEN="$(az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)" \
#     fallback-controller pwsh -File scripts/Invoke-FallbackDrill.ps1 -WorkspaceId <guid>
#
# Tokens are passed in rather than fetched inside the container, and that is not
# a style choice. On Windows the Azure CLI's MSAL token cache is encrypted with
# DPAPI against the Windows user, so a container with ~/.azure mounted can read
# azureProfile.json and cannot decrypt a token: `az account show` SUCCEEDS and
# `az account get-access-token` fails with "does not exist in MSAL token cache".
# Those two disagreeing is a confusing half hour. A sibling lab lost it.
FROM mcr.microsoft.com/powershell:7.5-ubuntu-24.04

# The Azure CLI is here for the fallback path when the drill is run
# interactively on Linux, where the token cache is readable.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates python3-venv \
 && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/azcli \
 && /opt/azcli/bin/pip install --no-cache-dir --upgrade pip \
 && /opt/azcli/bin/pip install --no-cache-dir azure-cli
ENV PATH="/opt/azcli/bin:${PATH}"

RUN pwsh -NoProfile -Command \
    "Set-PSRepository PSGallery -InstallationPolicy Trusted; \
     Install-Module SqlServer -Force -AllowClobber; \
     Install-Module Pester -MinimumVersion 5.5.0 -Force -SkipPublisherCheck; \
     Install-Module PSScriptAnalyzer -MinimumVersion 1.22.0 -Force"

# Proves the three things the drill cannot work without, at build time rather
# than ten minutes into a run.
RUN pwsh -NoProfile -Command \
    "Import-Module SqlServer; \
     if (-not (Get-Command Invoke-Sqlcmd).Parameters.ContainsKey('AccessToken')) { throw 'Invoke-Sqlcmd has no -AccessToken parameter; the drill cannot reach the warehouse.' }; \
     Import-Module Pester; Import-Module PSScriptAnalyzer; \
     Write-Output ('SqlServer ' + (Get-Module SqlServer).Version + ' with -AccessToken, on PowerShell ' + \$PSVersionTable.PSVersion)"

WORKDIR /lab
