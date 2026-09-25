<#
    Grading for the Direct Lake fallback drill.

    Nothing in here calls Fabric. Everything it needs is passed in, so the
    judgement can be tested without a capacity, a warehouse or a semantic model,
    and so a change to the grading cannot quietly depend on the state of an
    environment somebody else is also using.

    The one rule this module exists to enforce: a DAX query that succeeded is
    not evidence that a table ran in Direct Lake mode. Silent fallback IS a
    successful query returning correct results, so any function that treated
    success as evidence would be structurally incapable of seeing the thing this
    lab is about.
#>

Set-StrictMode -Version Latest

$script:FallbackNone = 'None'

function Get-FallbackMatrix {
    <#
        .SYNOPSIS
        Reads fallback-matrix.json and fails loudly if it is incoherent.

        .DESCRIPTION
        The matrix is the yardstick. An incoherent one would make the drill
        unfalsifiable while its report still looked rigorous, so it is checked
        here rather than trusted: every guard needs an expectation for both
        passes, and at least one guard has to diverge between them. A matrix
        where nothing diverges is not testing the remediation.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Matrix not found at '$Path'."
    }

    $matrix = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json

    $guards = @($matrix.guards)
    if (-not $guards.Count) { throw 'The matrix declares no guards.' }

    $valid = @('DirectLake', 'FellBack', 'Refused')
    foreach ($guard in $guards) {
        foreach ($field in 'id', 'table', 'severity', 'phase', 'model', 'expectAutomatic', 'expectDirectLakeOnly') {
            if (-not $guard.PSObject.Properties.Name.Contains($field)) {
                throw "Guard '$($guard.id)' is missing '$field'."
            }
        }
        foreach ($field in 'expectAutomatic', 'expectDirectLakeOnly') {
            if ($guard.$field -notin $valid) {
                throw "Guard '$($guard.id)' expects '$($guard.$field)' for $field, which is not one of: $($valid -join ', ')."
            }
        }
    }

    $ids = @($guards.id)
    $duplicates = @($ids | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
    if ($duplicates.Count) {
        throw "Duplicate guard id(s): $($duplicates -join ', ')."
    }

    if (-not @($guards | Where-Object { $_.severity -eq 'Baseline' }).Count) {
        throw 'The matrix declares no Baseline guard. Without one, a drill that reports FellBack for everything passes the finding for free.'
    }

    $phases = @('beforeFraming', 'afterFraming')
    foreach ($guard in $guards) {
        if ($guard.phase -notin $phases) {
            throw "Guard '$($guard.id)' names phase '$($guard.phase)', which is not one of: $($phases -join ', ')."
        }
    }

    # The baseline and the unframed guard are the same table on purpose, so the
    # only difference between them is the framing. A matrix where they drifted
    # onto different tables would still look reasonable and would no longer rule
    # out the table itself being the reason.
    $baseline = @($guards | Where-Object { $_.severity -eq 'Baseline' })[0]
    $unframed = @($guards | Where-Object { $_.phase -eq 'beforeFraming' -and $_.model -eq $baseline.model })
    if ($unframed.Count -and $unframed[0].table -ne $baseline.table) {
        throw "The beforeFraming guard is on table '$($unframed[0].table)' and the Baseline guard is on '$($baseline.table)'. They must be the same table, or framing is not the only difference between them."
    }

    $diverging = @($guards | Where-Object { $_.expectAutomatic -ne $_.expectDirectLakeOnly })
    if (-not $diverging.Count) {
        throw 'No guard changes between the two passes, so the matrix does not test the remediation.'
    }

    return $matrix
}

function Get-FallbackReason {
    <#
        .SYNOPSIS
        Normalises whatever TABLETRAITS() put in DirectLakeFallbackInfo.

        .DESCRIPTION
        Returns the reason as a string, 'None' when the table is in Direct Lake
        mode, or $null when the value could not be read at all.

        The column is documented as carrying a fallback reason with 'None'
        meaning Direct Lake, but the wire type is not promised -- DAX columns of
        this kind come back as an integer on some paths and a string on others.
        Both are handled, and anything else is treated as unreadable rather than
        guessed at: a value this function does not recognise must not be allowed
        to become a pass.
    #>
    [CmdletBinding()]
    [OutputType([object], [string])]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][object] $Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [string]) {
        $text = $Value.Trim()
        if ($text -eq '') { return $null }
        return $text
    }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        # 0 is the documented "no fallback" value. Every other number is a real
        # reason whose name this module does not need to know -- it is reported
        # verbatim so the drill output names what Fabric actually said.
        if ([double]$Value -eq 0) { return $script:FallbackNone }
        return "FallbackInfo=$Value"
    }

    return $null
}

function Resolve-FallbackOutcome {
    <#
        .SYNOPSIS
        Grades one table in one pass.

        .DESCRIPTION
        DirectLake  the table ran in Direct Lake mode
        FellBack    the query succeeded and the table was federated to SQL
        Refused     the query failed because fallback was not permitted
        Unknown     could not be determined. Always a failure, never a pass

        QuerySucceeded is deliberately NOT sufficient to return DirectLake.
        Silent fallback is a successful query returning correct results, so
        success is evidence of nothing here and the reason has to be read.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # [object], not [bool]. A [bool] parameter cannot hold "not measured",
        # and $null coerced to $false would read as a failed query -- inventing
        # a Refused out of a reading that never happened.
        [Parameter(Mandatory)][AllowNull()][object] $QuerySucceeded,

        # [object] rather than [string] on purpose. A [string] parameter coerces
        # $null to the empty string, which silently turned the null checks in a
        # sibling lab into dead code.
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][object] $FallbackInfo,

        # Whether TABLETRAITS returned the DirectLakeFallbackInfo column at all,
        # separately from what was in it. This is not defensive programming, it
        # is the only way to grade the healthy case.
        #
        # The documentation says a value of 'None' means the table is in Direct
        # Lake mode. Measured against a real framed table, the value is $null.
        # So null carries two entirely different meanings -- "no fallback, this
        # table is fine" and "the reading did not happen" -- and a grader given
        # only the value has to either fail every healthy table or pass every
        # failed measurement. Presence separates them.
        [Parameter()][AllowNull()][object] $FallbackInfoPresent,

        [Parameter()][AllowNull()][AllowEmptyString()][object] $ErrorMessage
    )

    if ($null -eq $QuerySucceeded) {
        return [pscustomobject]@{
            Outcome = 'Unknown'
            Reason  = 'Whether the query succeeded was never recorded, so nothing can be concluded about how it ran.'
        }
    }

    if (-not [bool]$QuerySucceeded) {
        $text = if ($null -eq $ErrorMessage) { '' } else { [string]$ErrorMessage }

        if ($text.Trim() -eq '') {
            return [pscustomobject]@{
                Outcome = 'Unknown'
                Reason  = 'The query failed and no error was captured. A failure with no reason could be the refusal this lab expects or an unrelated outage, and those must not be graded the same.'
            }
        }

        # The refusal a DirectLakeOnly model produces names the mode. Anything
        # else that failed is a broken drill, not a finding -- a capacity under
        # pressure and a deliberate refusal are both "the query failed".
        if ($text -match 'DirectLake|Direct Lake|fall ?back') {
            return [pscustomobject]@{
                Outcome = 'Refused'
                Reason  = "The query failed and the error names Direct Lake mode, which is the refusal DirectLakeOnly is supposed to produce: $($text.Trim())"
            }
        }

        return [pscustomobject]@{
            Outcome = 'Unknown'
            Reason  = "The query failed for a reason that says nothing about Direct Lake mode, so it is not evidence either way: $($text.Trim())"
        }
    }

    if ($null -eq $FallbackInfoPresent) {
        return [pscustomobject]@{
            Outcome = 'Unknown'
            Reason  = 'The query succeeded but whether TABLETRAITS returned a DirectLakeFallbackInfo column was never recorded. Because an empty value means the table is healthy, not knowing whether the column was there at all makes the reading useless.'
        }
    }

    if (-not [bool]$FallbackInfoPresent) {
        return [pscustomobject]@{
            Outcome = 'Unknown'
            Reason  = 'The query succeeded but TABLETRAITS returned no DirectLakeFallbackInfo column for this table. A successful query is exactly what silent fallback produces, so without the column this is not evidence of Direct Lake mode.'
        }
    }

    $reason = Get-FallbackReason -Value $FallbackInfo

    # The column was present and carried nothing, which is what a framed table in
    # Direct Lake mode actually reports. Measured, not documented: the docs
    # promise the string 'None' and the API returns null.
    if ($null -eq $reason -or $reason -eq $script:FallbackNone) {
        return [pscustomobject]@{
            Outcome = 'DirectLake'
            Reason  = 'The query succeeded and TABLETRAITS reports no fallback reason for this table.'
        }
    }

    return [pscustomobject]@{
        Outcome = 'FellBack'
        Reason  = "The query succeeded and returned correct results, and TABLETRAITS reports this table was federated instead: $reason"
    }
}

function Test-GuardExpectation {
    <#
        .SYNOPSIS
        Compares one observed outcome against what the matrix declared.

        .DESCRIPTION
        Unknown is never a pass, even when the expectation happens to be
        Unknown -- which is why the matrix does not allow it as an expectation.
        A drill that could not read its own result must not report success.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $Expected,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][object] $Observed
    )

    $seen = if ($null -eq $Observed) { '' } else { ([string]$Observed).Trim() }

    if ($seen -eq '' -or $seen -eq 'Unknown') {
        return [pscustomobject]@{
            Passed       = $false
            Inconclusive = $true
            Detail       = "Expected '$Expected' and the outcome could not be determined."
        }
    }

    if ($seen -eq $Expected) {
        return [pscustomobject]@{
            Passed       = $true
            Inconclusive = $false
            Detail       = "Observed '$seen' as declared."
        }
    }

    return [pscustomobject]@{
        Passed       = $false
        Inconclusive = $false
        Detail       = "Expected '$Expected', observed '$seen'."
    }
}

Export-ModuleMember -Function Get-FallbackMatrix, Get-FallbackReason, Resolve-FallbackOutcome, Test-GuardExpectation
