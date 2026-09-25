<#
    Unit tests for the grading module. No Fabric, no capacity, no network.

    The cases that matter most are the ones asserting that a SUCCESSFUL query is
    not graded as Direct Lake. That is the whole subject of the lab: silent
    fallback is a query that worked and returned the right answer, so a grader
    that trusted success would be unable to see it.
#>

BeforeAll {
    $script:ModulePath = Join-Path -Path $PSScriptRoot -ChildPath '../module/DirectLakeMode/DirectLakeMode.psm1'
    Import-Module $script:ModulePath -Force
    $script:MatrixPath = Join-Path -Path $PSScriptRoot -ChildPath '../fallback-matrix.json'

    # A scriptblock, not a function: Pester 5 discovers and runs in separate
    # passes and functions defined in BeforeAll do not survive into the run
    # phase, while $script: variables do.
    $script:WriteMatrix = {
        param($Object)
        $path = Join-Path ([IO.Path]::GetTempPath()) ("dlmatrix-" + [guid]::NewGuid().ToString('n') + '.json')
        $Object | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8
        return $path
    }

    $script:GoodMatrix = {
        return [pscustomobject]@{
            guards = @(
                [pscustomobject]@{ id = 'baseline'; table = 'Sales'; severity = 'Baseline'; phase = 'afterFraming'; model = 'clean'; expectAutomatic = 'DirectLake'; expectDirectLakeOnly = 'DirectLake' }
                [pscustomobject]@{ id = 'view'; table = 'SalesView'; severity = 'Critical'; phase = 'afterFraming'; model = 'clean'; expectAutomatic = 'FellBack'; expectDirectLakeOnly = 'Refused' }
            )
        }
    }
}

Describe 'Resolve-FallbackOutcome' {

    Context 'a successful query is not evidence of Direct Lake mode' {

        It 'grades a successful query whose column was absent as Unknown, not DirectLake' {
            # The case the whole module exists for. The query worked; that says
            # nothing, and guessing DirectLake here would hide every finding.
            $result = Resolve-FallbackOutcome -QuerySucceeded $true -FallbackInfo $null -FallbackInfoPresent $false
            $result.Outcome | Should -Be 'Unknown'
            $result.Reason | Should -Match 'exactly what silent fallback produces'
        }

        It 'grades a successful query with unrecorded column presence as Unknown' {
            # Presence not passed at all. Because an empty value is the HEALTHY
            # reading, not knowing whether the column was there makes the whole
            # measurement useless -- it cannot be defaulted either way.
            $result = Resolve-FallbackOutcome -QuerySucceeded $true -FallbackInfo $null
            $result.Outcome | Should -Be 'Unknown'
            $result.Reason | Should -Match 'never recorded'
        }

        It 'grades a successful query reporting a fallback reason as FellBack' {
            $result = Resolve-FallbackOutcome -QuerySucceeded $true -FallbackInfo 'ViewNotMaterialized' -FallbackInfoPresent $true
            $result.Outcome | Should -Be 'FellBack'
            $result.Reason | Should -Match 'ViewNotMaterialized'
        }
    }

    Context 'the values Fabric actually returns' {

        # Measured against a real Direct Lake on SQL model over a Fabric
        # warehouse, not taken from the documentation. The docs say the value is
        # 'None' when a table is in Direct Lake mode; it is null.
        It 'grades a present-but-null reason as DirectLake, which is what a framed table reports' {
            $result = Resolve-FallbackOutcome -QuerySucceeded $true -FallbackInfo $null -FallbackInfoPresent $true
            $result.Outcome | Should -Be 'DirectLake'
        }

        It 'grades "Not Framed" as FellBack, which is what an unrefreshed model reports' {
            $result = Resolve-FallbackOutcome -QuerySucceeded $true -FallbackInfo 'Not Framed' -FallbackInfoPresent $true
            $result.Outcome | Should -Be 'FellBack'
            $result.Reason | Should -Match 'Not Framed'
        }

        It 'grades "View" as FellBack, which is what a view-backed table reports' {
            $result = Resolve-FallbackOutcome -QuerySucceeded $true -FallbackInfo 'View' -FallbackInfoPresent $true
            $result.Outcome | Should -Be 'FellBack'
            $result.Reason | Should -Match 'View'
        }

        It 'still accepts the documented None, in case the wire value ever matches the docs' {
            (Resolve-FallbackOutcome -QuerySucceeded $true -FallbackInfo 'None' -FallbackInfoPresent $true).Outcome |
                Should -Be 'DirectLake'
        }

        It 'grades a numeric 0 as DirectLake' {
            (Resolve-FallbackOutcome -QuerySucceeded $true -FallbackInfo 0 -FallbackInfoPresent $true).Outcome | Should -Be 'DirectLake'
        }

        It 'tolerates surrounding whitespace' {
            (Resolve-FallbackOutcome -QuerySucceeded $true -FallbackInfo '  None  ' -FallbackInfoPresent $true).Outcome | Should -Be 'DirectLake'
        }

        It 'grades a nonzero number as FellBack' {
            (Resolve-FallbackOutcome -QuerySucceeded $true -FallbackInfo 3 -FallbackInfoPresent $true).Outcome | Should -Be 'FellBack'
        }

        It 'grades an empty string as DirectLake when the column was present' {
            # An empty string and a null are the same statement from this column:
            # there is no fallback reason.
            (Resolve-FallbackOutcome -QuerySucceeded $true -FallbackInfo '' -FallbackInfoPresent $true).Outcome | Should -Be 'DirectLake'
        }
    }

    Context 'a failed query' {

        It 'grades a Direct Lake error as Refused' {
            $result = Resolve-FallbackOutcome -QuerySucceeded $false -FallbackInfo $null `
                -ErrorMessage 'The query cannot be evaluated because DirectLake mode is required.'
            $result.Outcome | Should -Be 'Refused'
        }

        It 'matches a fallback error with a space in it' {
            (Resolve-FallbackOutcome -QuerySucceeded $false -FallbackInfo $null `
                -ErrorMessage 'fall back to DirectQuery is disabled').Outcome | Should -Be 'Refused'
        }

        It 'grades an unrelated failure as Unknown, not Refused' {
            # A capacity under memory pressure and a deliberate refusal are both
            # "the query failed". Grading them the same would let an outage pass
            # as the remediation working.
            $result = Resolve-FallbackOutcome -QuerySucceeded $false -FallbackInfo $null `
                -ErrorMessage 'Capacity limit exceeded. Please try again later.'
            $result.Outcome | Should -Be 'Unknown'
            $result.Reason | Should -Match 'says nothing about Direct Lake mode'
        }

        It 'grades a failure with no captured error as Unknown' {
            (Resolve-FallbackOutcome -QuerySucceeded $false -FallbackInfo $null).Outcome | Should -Be 'Unknown'
        }

        It 'grades a failure with a whitespace-only error as Unknown' {
            (Resolve-FallbackOutcome -QuerySucceeded $false -FallbackInfo $null -ErrorMessage '   ').Outcome | Should -Be 'Unknown'
        }
    }

    Context 'an unmeasured query' {

        It 'grades a null QuerySucceeded as Unknown' {
            # [object] rather than [bool] is load-bearing: a [bool] parameter
            # would coerce $null to $false and invent a failed query out of a
            # reading that never happened.
            $result = Resolve-FallbackOutcome -QuerySucceeded $null -FallbackInfo 'None'
            $result.Outcome | Should -Be 'Unknown'
            $result.Reason | Should -Match 'never recorded'
        }

        It 'does not let a healthy-looking reason rescue an unmeasured query' {
            (Resolve-FallbackOutcome -QuerySucceeded $null -FallbackInfo $null -FallbackInfoPresent $true).Outcome |
                Should -Not -Be 'DirectLake'
        }
    }
}

Describe 'Get-FallbackReason' {

    It 'returns null for null' { Get-FallbackReason -Value $null | Should -BeNullOrEmpty }
    It 'returns null for an empty string' { Get-FallbackReason -Value '' | Should -BeNullOrEmpty }
    It 'returns null for whitespace' { Get-FallbackReason -Value '   ' | Should -BeNullOrEmpty }
    It 'returns None for 0' { Get-FallbackReason -Value 0 | Should -Be 'None' }
    It 'returns None for 0.0' { Get-FallbackReason -Value 0.0 | Should -Be 'None' }
    It 'names the number for a nonzero value' { Get-FallbackReason -Value 7 | Should -Be 'FallbackInfo=7' }
    It 'passes a string reason through' { Get-FallbackReason -Value 'NoFrame' | Should -Be 'NoFrame' }

    It 'returns null for a type it does not recognise rather than guessing' {
        # An unrecognised shape must not become a pass. Returning something
        # truthy here would grade an unreadable value as a real reason.
        Get-FallbackReason -Value @{ unexpected = 'shape' } | Should -BeNullOrEmpty
    }
}

Describe 'Test-GuardExpectation' {

    It 'passes when the outcome matches' {
        (Test-GuardExpectation -Expected 'FellBack' -Observed 'FellBack').Passed | Should -BeTrue
    }

    It 'fails when the outcome differs' {
        $result = Test-GuardExpectation -Expected 'FellBack' -Observed 'DirectLake'
        $result.Passed | Should -BeFalse
        $result.Inconclusive | Should -BeFalse
    }

    It 'treats Unknown as inconclusive and not a pass' {
        $result = Test-GuardExpectation -Expected 'FellBack' -Observed 'Unknown'
        $result.Passed | Should -BeFalse
        $result.Inconclusive | Should -BeTrue
    }

    It 'treats a null outcome as inconclusive' {
        (Test-GuardExpectation -Expected 'DirectLake' -Observed $null).Inconclusive | Should -BeTrue
    }

    It 'never passes an Unknown even when Unknown was somehow expected' {
        (Test-GuardExpectation -Expected 'Unknown' -Observed 'Unknown').Passed | Should -BeFalse
    }
}

Describe 'Get-FallbackMatrix' {

    It 'reads the real matrix that ships with the lab' {
        $matrix = Get-FallbackMatrix -Path $script:MatrixPath
        @($matrix.guards).Count | Should -BeGreaterThan 0
        @($matrix.passes).Count | Should -Be 2
    }

    It 'requires a guard that diverges between the passes' {
        $bad = & $script:GoodMatrix
        $bad.guards[1].expectDirectLakeOnly = 'FellBack'   # now nothing diverges
        $path = & $script:WriteMatrix $bad
        { Get-FallbackMatrix -Path $path } | Should -Throw '*does not test the remediation*'
    }

    It 'requires a Baseline guard' {
        $bad = & $script:GoodMatrix
        $bad.guards[0].severity = 'Critical'
        $path = & $script:WriteMatrix $bad
        { Get-FallbackMatrix -Path $path } | Should -Throw '*no Baseline guard*'
    }

    It 'rejects an expectation that is not a real outcome' {
        $bad = & $script:GoodMatrix
        $bad.guards[1].expectAutomatic = 'ProbablyFine'
        $path = & $script:WriteMatrix $bad
        { Get-FallbackMatrix -Path $path } | Should -Throw '*not one of*'
    }

    It 'rejects Unknown as an expectation' {
        # Unknown is never a pass, so declaring it would be declaring a guard
        # that can never be satisfied.
        $bad = & $script:GoodMatrix
        $bad.guards[1].expectAutomatic = 'Unknown'
        $path = & $script:WriteMatrix $bad
        { Get-FallbackMatrix -Path $path } | Should -Throw '*not one of*'
    }

    It 'rejects duplicate guard ids' {
        $bad = & $script:GoodMatrix
        $bad.guards[1].id = 'baseline'
        $path = & $script:WriteMatrix $bad
        { Get-FallbackMatrix -Path $path } | Should -Throw '*Duplicate guard id*'
    }

    It 'rejects a guard naming a phase that does not exist' {
        $bad = & $script:GoodMatrix
        $bad.guards[1].phase = 'sometimeLater'
        $path = & $script:WriteMatrix $bad
        { Get-FallbackMatrix -Path $path } | Should -Throw '*not one of*'
    }

    It 'rejects a beforeFraming guard on a different table from the Baseline' {
        # The two are the same table on purpose, so framing is the only
        # difference. Drifting them apart would still look reasonable and would
        # stop ruling out the table itself as the cause.
        $bad = & $script:GoodMatrix
        $bad.guards[1].phase = 'beforeFraming'
        $path = & $script:WriteMatrix $bad
        { Get-FallbackMatrix -Path $path } | Should -Throw '*must be the same table*'
    }

    It 'rejects a guard missing an expectation' {
        $bad = [pscustomobject]@{
            guards = @([pscustomobject]@{ id = 'x'; table = 'Sales'; severity = 'Baseline'; phase = 'afterFraming'; model = 'clean'; expectAutomatic = 'DirectLake' })
        }
        $path = & $script:WriteMatrix $bad
        { Get-FallbackMatrix -Path $path } | Should -Throw '*missing*'
    }

    It 'rejects a matrix with no guards' {
        $path = & $script:WriteMatrix ([pscustomobject]@{ guards = @() })
        { Get-FallbackMatrix -Path $path } | Should -Throw '*no guards*'
    }

    It 'fails loudly when the file is missing' {
        { Get-FallbackMatrix -Path (Join-Path ([IO.Path]::GetTempPath()) 'definitely-not-here.json') } |
            Should -Throw '*not found*'
    }
}
