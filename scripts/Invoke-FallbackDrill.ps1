#Requires -Version 7.0
<#
    .SYNOPSIS
    Creates a Fabric warehouse and four Direct Lake semantic models, measures
    whether each table actually runs in Direct Lake mode, and grades the result
    against fallback-matrix.json.

    .DESCRIPTION
    The whole point is that a successful DAX query proves nothing here. Silent
    fallback is a query that works and returns the right answer, so every
    measurement records three separate things -- whether the query succeeded,
    whether TABLETRAITS returned a DirectLakeFallbackInfo column, and what was
    in it -- and the grading module refuses to conclude anything from the first
    one alone.

    Four models, not two: the clean model holds only the Delta-backed table, and
    the view-backed table lives on its own. That is not tidiness. A
    directLakeOnly model containing a view-backed table fails to refresh
    outright, which would leave the clean table unframed and turn the baseline
    into collateral damage instead of a control.

    .PARAMETER WorkspaceId
    The Fabric workspace to build in. Created by scripts/bootstrap.sh.

    .PARAMETER Keep
    Leave the warehouse and semantic models behind for inspection. The default
    deletes them, because a second run must not inherit the first run's state.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $WorkspaceId,
    [Parameter(Mandatory)][string] $WarehouseId,
    [Parameter(Mandatory)][string] $ConnectionId,
    [Parameter()][string] $MatrixPath = (Join-Path -Path $PSScriptRoot -ChildPath '../fallback-matrix.json'),
    [Parameter()][string] $ReportPath = (Join-Path -Path $PSScriptRoot -ChildPath '../fallback-report.json'),
    [Parameter()][switch] $Keep
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Write-Information is the house style for progress in this series, and it is only
# visible with the preference set.
$InformationPreference = 'Continue'

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../module/DirectLakeMode/DirectLakeMode.psm1') -Force
Import-Module SqlServer -ErrorAction Stop

$matrix = Get-FallbackMatrix -Path $MatrixPath

$suffix = -join ((48..57) + (97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })

$FabricApi = 'https://api.fabric.microsoft.com/v1'
$PowerBiApi = 'https://api.powerbi.com/v1.0/myorg'

# --------------------------------------------------------------------- tokens

function Get-DrillToken {
    <#
        Environment variable first, then the Azure CLI.
        CI supplies these from a federated credential, which is the only way the
        drill runs unattended. Locally the CLI is easier.

        Errors are captured and reported rather than suppressed. An earlier lab
        in this series hid the CLI's own explanation behind 2>$null and reported
        "could not get a token" for a message the CLI had already written.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $EnvironmentVariable,
        [Parameter(Mandatory)][string] $Resource
    )

    $fromEnv = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        Write-Information "  token for $Resource from `$env:$EnvironmentVariable"
        return $fromEnv.Trim()
    }

    $stderr = [IO.Path]::GetTempFileName()
    try {
        $token = (& az account get-access-token --resource $Resource --query accessToken -o tsv 2>$stderr)
        $detail = (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue)
        if ([string]::IsNullOrWhiteSpace($token)) {
            throw "Could not get a token for $Resource. Set `$env:$EnvironmentVariable, or sign in with az login.$(if ($detail) { " The CLI said: $($detail.Trim())" })"
        }
        Write-Information "  token for $Resource from the Azure CLI"
        return $token.Trim()
    }
    finally {
        Remove-Item -LiteralPath $stderr -Force -ErrorAction SilentlyContinue
    }
}

Write-Information '== Acquiring tokens'
$fabricToken = Get-DrillToken -EnvironmentVariable 'FABRIC_TOKEN' -Resource 'https://api.fabric.microsoft.com'
$powerBiToken = Get-DrillToken -EnvironmentVariable 'POWERBI_TOKEN' -Resource 'https://analysis.windows.net/powerbi/api'
$warehouseToken = Get-DrillToken -EnvironmentVariable 'WAREHOUSE_TOKEN' -Resource 'https://database.windows.net/'

# ------------------------------------------------------------------ REST calls

function Invoke-Api {
    <#
        A non-2xx is data, not an exception. "The request was refused" is
        something this drill records and grades rather than dies on -- the
        DirectLakeOnly pass is supposed to produce refusals.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][string] $Token,
        [Parameter()][string] $Method = 'Get',
        [Parameter()][AllowNull()][object] $Body
    )

    $headers = @{ Authorization = "Bearer $Token" }
    $splat = @{
        Uri                = $Uri
        Method             = $Method
        Headers            = $headers
        ContentType        = 'application/json'
        SkipHttpErrorCheck = $true
        StatusCodeVariable = 'status'
        ErrorAction        = 'Stop'
    }
    if ($null -ne $Body) { $splat.Body = ($Body | ConvertTo-Json -Depth 20 -Compress) }

    $response = Invoke-RestMethod @splat
    $ok = $status -ge 200 -and $status -lt 300

    return [pscustomobject]@{
        Ok             = $ok
        Status         = $status
        Body           = $response
        ResponseHeaders = $null
    }
}

function Wait-FabricOperation {
    <#
        Item creation in Fabric is a long-running operation. The 202 carries a
        Location header, and the operation has to be polled until it stops
        saying Running. A create that is still Running is not a create that
        worked.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Location,
        [Parameter()][int] $TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $result = Invoke-Api -Uri $Location -Token $fabricToken
        $state = if ($result.Ok -and $result.Body.PSObject.Properties.Name -contains 'status') { [string]$result.Body.status } else { 'Unknown' }
        if ($state -ne 'Running' -and $state -ne 'NotStarted') { return $state }
        Start-Sleep -Seconds 10
    }
    return 'TimedOut'
}

function New-FabricItem {
    # SupportsShouldProcess because this creates billable cloud items. The analyser
    # asks for it and the analyser is right: -WhatIf on a drill that provisions a
    # warehouse is a reasonable thing to want.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $Collection,
        [Parameter(Mandatory)][hashtable] $Body,
        [Parameter(Mandatory)][string] $Description
    )

    if (-not $PSCmdlet.ShouldProcess("$Collection/$($Body.displayName)", 'Create')) {
        return [pscustomobject]@{ Ok = $false; Id = $null; Detail = 'skipped by -WhatIf' }
    }

    $uri = "$FabricApi/workspaces/$WorkspaceId/$Collection"
    $headers = @{ Authorization = "Bearer $fabricToken" }
    $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -ContentType 'application/json' `
        -Body ($Body | ConvertTo-Json -Depth 20 -Compress) -SkipHttpErrorCheck -ErrorAction Stop

    if ($response.StatusCode -eq 201) {
        $created = $response.Content | ConvertFrom-Json
        return [pscustomobject]@{ Ok = $true; Id = $created.id; Detail = 'created' }
    }

    if ($response.StatusCode -eq 202) {
        $location = $response.Headers['Location']
        if ($location -is [array]) { $location = $location[0] }
        $state = Wait-FabricOperation -Location $location
        if ($state -ne 'Succeeded') {
            return [pscustomobject]@{ Ok = $false; Id = $null; Detail = "$Description did not complete: $state" }
        }
        # The operation result does not always carry the id, so the item is
        # looked up by name rather than assumed.
        $listed = Invoke-Api -Uri $uri -Token $fabricToken
        $match = @($listed.Body.value | Where-Object { $_.displayName -eq $Body.displayName })
        if (-not $match.Count) {
            return [pscustomobject]@{ Ok = $false; Id = $null; Detail = "$Description reported success but no item named '$($Body.displayName)' exists" }
        }
        return [pscustomobject]@{ Ok = $true; Id = $match[0].id; Detail = 'created' }
    }

    return [pscustomobject]@{ Ok = $false; Id = $null; Detail = "$Description failed with HTTP $($response.StatusCode): $($response.Content)" }
}

# ------------------------------------------------------------------- warehouse

function Get-WarehouseFixtureSql {
    <#
        Sales is a real table, so it has a Delta table underneath and can be
        framed. SalesView is a view over it, which is one of the two documented
        fallback triggers -- a view has nothing to frame.

        Both return the same numbers on purpose. That is the assertion about
        correctness: the fallen-back table is not wrong, it is just not Direct
        Lake, which is exactly why nobody notices.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return [string[]]@(
        'CREATE TABLE dbo.Sales (OrderId INT NOT NULL, Amount DECIMAL(18,2) NOT NULL, Region VARCHAR(20) NOT NULL)'
        "INSERT INTO dbo.Sales (OrderId, Amount, Region) VALUES (1, 100.00, 'East'), (2, 250.50, 'West'), (3, 75.25, 'East'), (4, 410.00, 'North')"
        'CREATE VIEW dbo.SalesView AS SELECT OrderId, Amount, Region FROM dbo.Sales'
    )
}

function Get-ModelDefinition {
    <#
        TMSL for a Direct Lake on SQL semantic model.

        directLakeBehavior is the single property the two passes differ by, which
        is why the passes are separate models rather than an XMLA write: it makes
        the variable a property of the definition and removes a whole class of
        setup from the drill.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Behavior,
        [Parameter(Mandatory)][string[]] $Tables,
        [Parameter(Mandatory)][string] $Server,
        [Parameter(Mandatory)][string] $DatabaseId
    )

    $columns = @(
        @{ name = 'OrderId'; dataType = 'int64'; sourceColumn = 'OrderId'; sourceLineageTag = 'OrderId' }
        @{ name = 'Amount'; dataType = 'decimal'; sourceColumn = 'Amount'; sourceLineageTag = 'Amount' }
        @{ name = 'Region'; dataType = 'string'; sourceColumn = 'Region'; sourceLineageTag = 'Region' }
    )

    $modelTables = foreach ($table in $Tables) {
        @{
            name             = $table
            sourceLineageTag = "[dbo].[$table]"
            columns          = $columns
            partitions       = @(
                @{
                    name   = "$table-partition"
                    mode   = 'directLake'
                    source = @{
                        type             = 'entity'
                        entityName       = $table
                        schemaName       = 'dbo'
                        expressionSource = 'DatabaseQuery'
                    }
                }
            )
        }
    }

    $bim = @{
        name              = $Name
        compatibilityLevel = 1604
        model             = @{
            culture                         = 'en-US'
            defaultPowerBIDataSourceVersion = 'powerBI_V3'
            sourceQueryCulture              = 'en-US'
            directLakeBehavior              = $Behavior
            expressions                     = @(
                @{
                    name       = 'DatabaseQuery'
                    kind       = 'm'
                    # By GUID, not friendly name: the docs require it for refresh
                    # and Edit tables to work against the model.
                    expression = "let`n    Source = Sql.Database(`"$Server`", `"$DatabaseId`")`nin`n    Source"
                }
            )
            tables                          = @($modelTables)
        }
    }

    $encode = {
        param($Object)
        $json = if ($Object -is [string]) { $Object } else { $Object | ConvertTo-Json -Depth 20 }
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    }

    return @{
        displayName = $Name
        definition  = @{
            parts = @(
                @{ path = 'model.bim'; payload = (& $encode $bim); payloadType = 'InlineBase64' }
                @{ path = 'definition.pbism'; payload = (& $encode (@{ version = '4.0'; settings = @{} })); payloadType = 'InlineBase64' }
            )
        }
    }
}

# ------------------------------------------------------------------ measuring

function Get-TraitSnapshot {
    <#
        Runs EVALUATE TABLETRAITS() and returns, per table, three separate facts:
        the declared storage mode, whether the DirectLakeFallbackInfo column came
        back at all, and what was in it.

        Presence is tracked separately because a framed table in Direct Lake mode
        reports NULL for that column. The documentation says the value is 'None';
        it is null. Null is also what an unread column looks like, so without
        presence there is no way to tell a healthy table from a failed
        measurement.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string] $DatasetId)

    $result = Invoke-Api -Method Post -Token $powerBiToken `
        -Uri "$PowerBiApi/groups/$WorkspaceId/datasets/$DatasetId/executeQueries" `
        -Body @{
            queries            = @(@{ query = 'EVALUATE TABLETRAITS()' })
            serializerSettings = @{ includeNulls = $true }
        }

    if (-not $result.Ok) {
        return [pscustomobject]@{ Ok = $false; ErrorMessage = (Get-ApiErrorText -Response $result); Tables = @{} }
    }

    $tables = @{}
    foreach ($row in $result.Body.results[0].tables[0].rows) {
        $names = $row.PSObject.Properties.Name
        $tableName = [string]$row.'[TableName]'
        $tables[$tableName] = [pscustomobject]@{
            StorageMode         = if ($names -contains '[StorageMode]') { [string]$row.'[StorageMode]' } else { $null }
            FallbackInfoPresent = $names -contains '[DirectLakeFallbackInfo]'
            FallbackInfo        = if ($names -contains '[DirectLakeFallbackInfo]') { $row.'[DirectLakeFallbackInfo]' } else { $null }
        }
    }

    return [pscustomobject]@{ Ok = $true; ErrorMessage = $null; Tables = $tables }
}

function Get-ApiErrorText {
    <#
        Pulls the human-readable part out of a Power BI error. The detail that
        names Direct Lake lives several levels down, and the grading module keys
        a Refused off that text -- so losing it would turn every refusal into an
        Unknown.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()][object] $Response)

    if ($null -eq $Response -or $null -eq $Response.Body) { return "HTTP $($Response.Status) with no body." }

    $body = $Response.Body
    $parts = [Collections.Generic.List[string]]::new()

    if ($body.PSObject.Properties.Name -contains 'error') {
        $err = $body.error
        if ($err.PSObject.Properties.Name -contains 'code') { $parts.Add([string]$err.code) }
        if ($err.PSObject.Properties.Name -contains 'message') { $parts.Add([string]$err.message) }
        if ($err.PSObject.Properties.Name -contains 'pbi.error') {
            $details = $err.'pbi.error'.details
            foreach ($detail in @($details)) {
                if ($null -ne $detail -and $detail.PSObject.Properties.Name -contains 'detail') {
                    $parts.Add([string]$detail.detail.value)
                }
            }
        }
    }

    if (-not $parts.Count) { $parts.Add(($body | ConvertTo-Json -Depth 6 -Compress)) }
    return ($parts -join ' :: ')
}

function Measure-Table {
    <#
        One table, one model, one moment in time. Returns everything the grading
        module needs and nothing it does not.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $DatasetId,
        [Parameter(Mandatory)][string] $Table,
        [Parameter(Mandatory)][AllowNull()][object] $Traits
    )

    $query = "EVALUATE ROW(`"total`", SUM($Table[Amount]))"
    $result = Invoke-Api -Method Post -Token $powerBiToken `
        -Uri "$PowerBiApi/groups/$WorkspaceId/datasets/$DatasetId/executeQueries" `
        -Body @{ queries = @(@{ query = $query }); serializerSettings = @{ includeNulls = $true } }

    $total = $null
    $errorText = $null
    if ($result.Ok) {
        $rows = @($result.Body.results[0].tables[0].rows)
        if ($rows.Count) { $total = $rows[0].'[total]' }
    }
    else {
        $errorText = Get-ApiErrorText -Response $result
    }

    $traitsForTable = if ($null -ne $Traits -and $Traits.Ok -and $Traits.Tables.ContainsKey($Table)) { $Traits.Tables[$Table] } else { $null }

    return [pscustomobject]@{
        Table               = $Table
        QuerySucceeded      = $result.Ok
        Total               = $total
        ErrorMessage        = $errorText
        StorageMode         = if ($traitsForTable) { $traitsForTable.StorageMode } else { $null }
        FallbackInfoPresent = if ($traitsForTable) { $traitsForTable.FallbackInfoPresent } else { $null }
        FallbackInfo        = if ($traitsForTable) { $traitsForTable.FallbackInfo } else { $null }
    }
}

function Invoke-Framing {
    <#
        A Direct Lake refresh is framing: it copies metadata, not data.

        The outcome is returned rather than thrown on, because a failed refresh
        is one of this lab's findings -- under directLakeOnly a model holding a
        view-backed table cannot be refreshed at all.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string] $DatasetId, [Parameter()][int] $TimeoutSeconds = 300)

    $start = Invoke-Api -Method Post -Token $powerBiToken `
        -Uri "$PowerBiApi/groups/$WorkspaceId/datasets/$DatasetId/refreshes" -Body @{ type = 'full' }

    if (-not $start.Ok) {
        return [pscustomobject]@{ Status = 'NotStarted'; ErrorMessage = (Get-ApiErrorText -Response $start) }
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10
        $history = Invoke-Api -Token $powerBiToken `
            -Uri "$PowerBiApi/groups/$WorkspaceId/datasets/$DatasetId/refreshes?`$top=1"
        if (-not $history.Ok) { continue }
        $latest = @($history.Body.value)
        if (-not $latest.Count) { continue }

        $status = [string]$latest[0].status
        if ($status -eq 'Completed' -or $status -eq 'Failed' -or $status -eq 'Disabled') {
            $detail = $null
            if ($latest[0].PSObject.Properties.Name -contains 'serviceExceptionJson' -and $latest[0].serviceExceptionJson) {
                $detail = [string]$latest[0].serviceExceptionJson
            }
            return [pscustomobject]@{ Status = $status; ErrorMessage = $detail }
        }
    }

    return [pscustomobject]@{ Status = 'TimedOut'; ErrorMessage = "Refresh did not finish within $TimeoutSeconds seconds." }
}

# --------------------------------------------------------------------- the run

$createdModels = [Collections.Generic.List[string]]::new()
$observations = @{}
$refreshOutcomes = @{}

try {
    Write-Information '== Resolving the warehouse'
    $listed = Invoke-Api -Uri "$FabricApi/workspaces/$WorkspaceId/warehouses/$WarehouseId" -Token $fabricToken
    if (-not $listed.Ok) { throw "Could not read warehouse $WarehouseId. scripts/bootstrap.sh creates it." }
    $warehouseName = [string]$listed.Body.displayName
    $server = [string]$listed.Body.properties.connectionString
    if ([string]::IsNullOrWhiteSpace($server)) { throw 'The warehouse reported no connection string.' }
    Write-Information "   $warehouseName ($WarehouseId)"
    Write-Information "   endpoint $server"

    # The warehouse is persistent, created by bootstrap, because a cloud
    # connection is bound to one specific server and database and so cannot be
    # created ahead of a warehouse that does not exist yet. That makes the fixture
    # state this drill does not own, which is a new risk for this series: every
    # other lab builds and destroys everything it measures.
    #
    # So the fixture is created if absent and then VERIFIED, every run. A
    # warehouse somebody edited between runs would otherwise change the numbers
    # silently, and a drill that trusts state it did not create is exactly the
    # kind of thing this lab is about.
    Write-Information '== Ensuring the fixture'
    $tables = Invoke-Sqlcmd -ServerInstance $server -Database $warehouseName -AccessToken $warehouseToken `
        -Query "SELECT name FROM sys.objects WHERE name IN ('Sales', 'SalesView') AND type IN ('U', 'V')" -ErrorAction Stop
    $present = @(@($tables) | ForEach-Object { [string]$_.name })

    if ($present.Count -lt 2) {
        foreach ($statement in Get-WarehouseFixtureSql) {
            $first = ($statement -split '\s+')[2]
            if ($present -contains ($first -replace '^dbo\.', '')) { continue }
            Invoke-Sqlcmd -ServerInstance $server -Database $warehouseName -AccessToken $warehouseToken `
                -Query $statement -ErrorAction Stop | Out-Null
            Write-Information "   created $(($statement -replace '\s+', ' ').Substring(0, [Math]::Min(58, ($statement -replace '\s+', ' ').Length)))"
        }
    }
    else {
        Write-Information '   Sales and SalesView already exist'
    }

    # Both objects must agree, to the penny, before anything is measured. The
    # assertion about a fallen-back table returning correct results is only
    # meaningful if the two really do hold the same data to begin with.
    $integrity = Invoke-Sqlcmd -ServerInstance $server -Database $warehouseName -AccessToken $warehouseToken -ErrorAction Stop `
        -Query @'
SELECT
    (SELECT COUNT(*) FROM dbo.Sales)          AS SalesRows,
    (SELECT SUM(Amount) FROM dbo.Sales)       AS SalesTotal,
    (SELECT COUNT(*) FROM dbo.SalesView)      AS ViewRows,
    (SELECT SUM(Amount) FROM dbo.SalesView)   AS ViewTotal
'@

    $expectedRows = 4
    $expectedTotal = [decimal]835.75
    if ([int]$integrity.SalesRows -ne $expectedRows -or [decimal]$integrity.SalesTotal -ne $expectedTotal) {
        throw "The fixture is not what this drill expects: Sales has $($integrity.SalesRows) rows totalling $($integrity.SalesTotal), expected $expectedRows totalling $expectedTotal. The warehouse is persistent and something has changed it; recreate it rather than grading against an unknown fixture."
    }
    if ([int]$integrity.ViewRows -ne [int]$integrity.SalesRows -or [decimal]$integrity.ViewTotal -ne [decimal]$integrity.SalesTotal) {
        throw "Sales and SalesView disagree ($($integrity.SalesTotal) vs $($integrity.ViewTotal)). The correctness assertion would be meaningless."
    }
    Write-Information "   verified: $($integrity.SalesRows) rows totalling $($integrity.SalesTotal), and the view agrees"

    foreach ($pass in $matrix.passes) {
        foreach ($model in $matrix.models) {
            $modelName = "sm_$($pass.id)_$($model.id)_$suffix"
            Write-Information ""
            Write-Information "== $($pass.id) / $($model.id): $modelName"

            $definition = Get-ModelDefinition -Name $modelName -Behavior $pass.directLakeBehavior `
                -Tables @($model.tables) -Server $server -DatabaseId $WarehouseId
            $created = New-FabricItem -Collection 'semanticModels' -Body $definition -Description 'Semantic model creation'
            if (-not $created.Ok) { throw $created.Detail }
            $createdModels.Add($created.Id)
            $datasetId = $created.Id

            # Without this the model cannot frame at all when the drill runs as a
            # service principal: it fails with "We cannot access the source Delta
            # table", which reads like a missing table rather than a missing
            # identity. Default single sign-on has no interactive user to borrow,
            # so the model is bound to a connection whose fixed identity is the
            # workspace identity.
            #
            # gatewayObjectId takes the CONNECTION id. Fabric models a cloud
            # connection as a virtual gateway cluster, which is not written down
            # anywhere obvious -- Default.DiscoverGateways returns an empty list
            # for this dataset and the datasource carries no gateway id, so the
            # documented route looks inapplicable.
            $bindSplat = @{
                Method = "Post"
                Token  = $powerBiToken
                Uri    = "$PowerBiApi/groups/$WorkspaceId/datasets/$datasetId/Default.BindToGateway"
                Body   = @{ gatewayObjectId = $ConnectionId }
            }
            $bind = Invoke-Api @bindSplat
            if (-not $bind.Ok) {
                throw "Could not bind $modelName to connection $ConnectionId (HTTP $($bind.Status)). Every measurement after this would be Unknown, so the drill stops here rather than reporting eleven inconclusive results."
            }
            Write-Information "   bound to the fixed-identity connection"

            # beforeFraming: the state the API leaves a new model in. No extra
            # setup stages this -- creating the model is what produces it.
            $traits = Get-TraitSnapshot -DatasetId $datasetId
            foreach ($table in @($model.tables)) {
                $key = "$($pass.id)|$($model.id)|beforeFraming|$table"
                $observations[$key] = Measure-Table -DatasetId $datasetId -Table $table -Traits $traits
                $o = $observations[$key]
                Write-Information ("   beforeFraming {0,-10} query={1} fallbackInfo={2} storageMode={3}" -f $table, $o.QuerySucceeded, ($o.FallbackInfo | ConvertTo-Json -Compress), $o.StorageMode)
            }

            $refresh = Invoke-Framing -DatasetId $datasetId
            $refreshOutcomes["$($pass.id)|$($model.id)"] = $refresh
            Write-Information "   framing: $($refresh.Status)"
            if ($refresh.ErrorMessage) {
                Write-Information "     $((($refresh.ErrorMessage) -replace '\s+', ' ').Substring(0, [Math]::Min(150, (($refresh.ErrorMessage) -replace '\s+', ' ').Length)))"
            }

            $traits = Get-TraitSnapshot -DatasetId $datasetId
            foreach ($table in @($model.tables)) {
                $key = "$($pass.id)|$($model.id)|afterFraming|$table"
                $observations[$key] = Measure-Table -DatasetId $datasetId -Table $table -Traits $traits
                $o = $observations[$key]
                Write-Information ("   afterFraming  {0,-10} query={1} fallbackInfo={2} storageMode={3}" -f $table, $o.QuerySucceeded, ($o.FallbackInfo | ConvertTo-Json -Compress), $o.StorageMode)
            }
        }
    }
}
finally {
    if (-not $Keep) {
        Write-Information ''
        Write-Information '== Cleaning up'
        foreach ($id in $createdModels) {
            $null = Invoke-Api -Method Delete -Token $fabricToken -Uri "$FabricApi/workspaces/$WorkspaceId/semanticModels/$id"
        }
        # The warehouse is deliberately left alone: bootstrap owns it, and the
        # cloud connection is bound to it by id, so deleting it here would break
        # the connection and every run after this one.
        Write-Information "   removed $($createdModels.Count) semantic model(s); the warehouse belongs to bootstrap and stays"
    }
    else {
        Write-Information ''
        Write-Information "== Left behind for inspection: $($createdModels.Count) semantic model(s)"
    }
}

# --------------------------------------------------------------------- grading

Write-Information ''
Write-Information '== Grading against the matrix'

$results = [Collections.Generic.List[pscustomobject]]::new()

foreach ($pass in $matrix.passes) {
    foreach ($guard in $matrix.guards) {
        $key = "$($pass.id)|$($guard.model)|$($guard.phase)|$($guard.table)"
        $observed = if ($observations.ContainsKey($key)) { $observations[$key] } else { $null }

        if ($null -eq $observed) {
            $outcome = [pscustomobject]@{ Outcome = 'Unknown'; Reason = "No measurement was recorded for $key." }
        }
        else {
            $outcome = Resolve-FallbackOutcome -QuerySucceeded $observed.QuerySucceeded `
                -FallbackInfo $observed.FallbackInfo -FallbackInfoPresent $observed.FallbackInfoPresent `
                -ErrorMessage $observed.ErrorMessage
        }

        $expected = if ($pass.id -eq 'automatic') { $guard.expectAutomatic } else { $guard.expectDirectLakeOnly }
        $verdict = Test-GuardExpectation -Expected $expected -Observed $outcome.Outcome

        $results.Add([pscustomobject]@{
            Kind         = 'Guard'
            Id           = $guard.id
            Pass         = $pass.id
            Severity     = $guard.severity
            Title        = $guard.title
            Expected     = $expected
            Observed     = $outcome.Outcome
            Passed       = $verdict.Passed
            Inconclusive = $verdict.Inconclusive
            Reason       = $outcome.Reason
            Why          = $guard.why
        })

        $label = if ($verdict.Passed) { 'as declared' } elseif ($verdict.Inconclusive) { 'INCONCLUSIVE' } else { 'FAILED' }
        Write-Information ("   {0,-16} {1,-32} {2,-11} {3}" -f $pass.id, $guard.id, $outcome.Outcome, $label)
    }
}

# Assertions are not outcomes of a table, they are the things somebody would
# check instead of checking the table.
function Add-Assertion {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][AllowNull()][object] $Observed,
        [Parameter(Mandatory)][string] $Detail
    )

    $declared = @($matrix.assertions | Where-Object { $_.id -eq $Id })
    if (-not $declared.Count) { throw "Assertion '$Id' is not declared in the matrix." }
    $expected = $declared[0].expected

    $inconclusive = $null -eq $Observed
    $passed = (-not $inconclusive) -and ([bool]$Observed -eq [bool]$expected)

    $results.Add([pscustomobject]@{
        Kind         = 'Assertion'
        Id           = $Id
        Pass         = 'both'
        Severity     = $declared[0].severity
        Title        = $declared[0].id
        Expected     = $expected
        Observed     = $Observed
        Passed       = $passed
        Inconclusive = $inconclusive
        Reason       = $Detail
        Why          = $declared[0].why
    })

    $label = if ($passed) { 'as declared' } elseif ($inconclusive) { 'INCONCLUSIVE' } else { 'FAILED' }
    Write-Information ("   {0,-16} {1,-32} {2,-11} {3}" -f 'assertion', $Id, $Observed, $label)
}

$framedSales = $observations['automatic|clean|afterFraming|Sales']
$fellBackView = $observations['automatic|view|afterFraming|SalesView']

# Correctness: the fallen-back table agrees with the framed one to the penny.
$correct = $null
$detail = 'Not measured.'
if ($null -ne $framedSales -and $null -ne $fellBackView -and $null -ne $framedSales.Total -and $null -ne $fellBackView.Total) {
    $correct = ([decimal]$framedSales.Total -eq [decimal]$fellBackView.Total)
    $detail = "Framed table returned $($framedSales.Total); the fallen-back table returned $($fellBackView.Total)."
}
Add-Assertion -Id 'fallback-query-returns-correct-results' -Observed $correct -Detail $detail

# No error: in the Automatic pass every query succeeded.
$automaticKeys = @($observations.Keys | Where-Object { $_ -like 'automatic|*' })
$noErrors = $null
if ($automaticKeys.Count) {
    $failed = @($automaticKeys | Where-Object { -not $observations[$_].QuerySucceeded })
    $noErrors = ($failed.Count -eq 0)
    $detail = if ($noErrors) { "All $($automaticKeys.Count) queries in the automatic pass succeeded." } else { "$($failed.Count) of $($automaticKeys.Count) queries failed: $($failed -join ', ')" }
}
Add-Assertion -Id 'no-error-or-warning-surfaced' -Observed $noErrors -Detail $detail

# Storage mode: still says DirectLake for a table that is being federated.
$storageMode = $null
$detail = 'Not measured.'
if ($null -ne $fellBackView -and $null -ne $fellBackView.StorageMode) {
    $storageMode = ($fellBackView.StorageMode -eq 'DirectLake')
    $detail = "The fallen-back table reports StorageMode=$($fellBackView.StorageMode) while its queries are federated."
}
Add-Assertion -Id 'storage-mode-still-reports-direct-lake' -Observed $storageMode -Detail $detail

# The worst signal of the three. A model holding one framable table and one
# view-backed table reports its refresh as Completed, because something in it
# framed -- while the view-backed table did not and still reports a fallback
# reason afterwards.
$mixedRefresh = $refreshOutcomes['automatic|mixed']
$mixedView = $observations['automatic|mixed|afterFraming|SalesView']
$hidden = $null
$detail = 'Not measured.'
if ($null -ne $mixedRefresh -and $null -ne $mixedView) {
    $viewOutcome = Resolve-FallbackOutcome -QuerySucceeded $mixedView.QuerySucceeded `
        -FallbackInfo $mixedView.FallbackInfo -FallbackInfoPresent $mixedView.FallbackInfoPresent `
        -ErrorMessage $mixedView.ErrorMessage
    $hidden = ($mixedRefresh.Status -eq 'Completed' -and $viewOutcome.Outcome -eq 'FellBack')
    $detail = "The mixed model reported its refresh as $($mixedRefresh.Status) while SalesView graded $($viewOutcome.Outcome) with reason $($mixedView.FallbackInfo | ConvertTo-Json -Compress)."
}
Add-Assertion -Id 'refresh-status-hides-a-table-that-never-framed' -Observed $hidden -Detail $detail

# The one refresh behaviour that has been stable across runs, and the only signal
# in this lab that names the problem out loud. What is NOT asserted is the same
# refresh under the default: that reported Failed on one run and Completed on the
# next from identical code, so it is recorded in the matrix under
# knownNonDeterminism rather than declared as an expectation.
$onlyRefresh = $refreshOutcomes['directLakeOnly|view']
$refuses = $null
$detail = 'Not measured.'
if ($null -ne $onlyRefresh) {
    $refuses = ($onlyRefresh.Status -eq 'Failed')
    $detail = "Framing the view-only model with fallback disabled: $($onlyRefresh.Status)."
    $autoRefresh = $refreshOutcomes['automatic|view']
    if ($null -ne $autoRefresh) {
        $detail += " For the record and not asserted, the same model under the default reported $($autoRefresh.Status)."
    }
}
Add-Assertion -Id 'directlakeonly-refuses-to-frame-a-view-backed-model' -Observed $refuses -Detail $detail

# ---------------------------------------------------------------------- report

$total = $results.Count
$passed = @($results | Where-Object Passed).Count
$inconclusive = @($results | Where-Object Inconclusive).Count
$failed = $total - $passed - $inconclusive

$report = [pscustomobject]@{
    generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    workspaceId  = $WorkspaceId
    total        = $total
    passed       = $passed
    failed       = $failed
    inconclusive = $inconclusive
    ok           = ($failed -eq 0 -and $inconclusive -eq 0)
    refreshes    = $refreshOutcomes
    observations = $observations
    results      = $results
}
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReportPath -Encoding utf8

Write-Information ''
Write-Information "$passed/$total as declared; $failed failed; $inconclusive inconclusive."
if ($report.ok) { Write-Information 'Everything behaved as declared.' }
Write-Information "Report written to $ReportPath"

if ($env:GITHUB_STEP_SUMMARY) {
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('### Direct Lake fallback drill')
    $lines.Add('')
    $lines.Add("**$passed/$total** as declared; $failed failed; $inconclusive inconclusive.")
    $lines.Add('')
    $lines.Add('| pass | check | expected | observed | |')
    $lines.Add('|---|---|---|---|---|')
    foreach ($r in $results) {
        $mark = if ($r.Passed) { 'ok' } elseif ($r.Inconclusive) { 'inconclusive' } else { 'FAILED' }
        $lines.Add("| $($r.Pass) | $($r.Id) | $($r.Expected) | $($r.Observed) | $mark |")
    }
    $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

# Inconclusive is not a pass. A drill that could not read its own result must not
# exit green, or the next change gets made against a number nobody earned.
if (-not $report.ok) { exit 1 }
