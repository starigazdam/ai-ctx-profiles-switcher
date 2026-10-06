#Requires -Modules Pester
<#
.SYNOPSIS
    Tests-first suite for the future .NET 10 CLI's read-only `current` command:

        dotnet run --project src/Ctx/Ctx.csproj -- current [--recorded-mode <mode>]

    These pin observable behavior to the current shell implementation:
    ctx.ps1::Show-CtxCurrent / Write-CtxStatus (mirrored by ctx.sh). The
    recorded integration mode is explicit command input and is never inferred
    from the AI_CTX_PROFILES_COPILOT_MODE selector.

.NOTES
    Every invocation runs in an isolated process environment: the child never
    inherits any ambient AI_CTX_*/COPILOT_*/CTX_* state, and DOTNET_CLI_HOME is
    redirected into a temp dir, so no real Copilot state, HOME, or credentials
    are read or written.
#>

BeforeAll {
    $Script:CtxDotnetRepoRoot = Split-Path -Parent $PSScriptRoot
    $Script:CtxDotnetProject = Join-Path $Script:CtxDotnetRepoRoot 'src/Ctx/Ctx.csproj'

    $Script:CtxDotnetManagedEnv = @(
        'AI_CTX_PROFILES', 'AI_CTX_PROFILES_COPILOT_MODE', 'AI_CTX_PROFILES_CONFIG_ROOT',
        'AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT', 'AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT',
        'COPILOT_HOME', 'COPILOT_SKILLS_DIRS', 'COPILOT_CUSTOM_INSTRUCTIONS_DIRS',
        'CTX_COPILOT_DIR', 'CTX_AUTO_LOAD', 'AI_CONTEXT', 'AI_CONFIG_ROOT', 'CTX_HOMES_ROOT'
    )

    function Script:Invoke-CtxDotnetCurrent {
        param(
            [hashtable]$Environment = @{},
            [string[]]$Arguments = @()
        )

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'dotnet'
        foreach ($arg in @('run', '--project', $Script:CtxDotnetProject, '--', 'current') + $Arguments) {
            $psi.ArgumentList.Add($arg)
        }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $Script:CtxDotnetTmp

        foreach ($name in $Script:CtxDotnetManagedEnv) { [void]$psi.Environment.Remove($name) }
        $psi.Environment['DOTNET_CLI_HOME'] = $Script:CtxDotnetTmp
        $psi.Environment['DOTNET_CLI_TELEMETRY_OPTOUT'] = '1'
        $psi.Environment['DOTNET_NOLOGO'] = '1'
        $psi.Environment['DOTNET_SKIP_FIRST_TIME_EXPERIENCE'] = '1'
        foreach ($key in $Environment.Keys) { $psi.Environment[$key] = [string]$Environment[$key] }

        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()

        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($line in ($stdout -split "`r?`n")) { $lines.Add($line) }
        while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }

        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            StdOut   = $stdout
            StdErr   = $stderr
            Output   = @($lines)
        }
    }
}

Describe 'ctx .NET current command' {

    BeforeEach {
        $Script:CtxDotnetTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ctx-dotnet-pester-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $Script:CtxDotnetTmp -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $Script:CtxDotnetTmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'no active context prints the exact two lines and exits 0' {
        $result = Invoke-CtxDotnetCurrent

        $result.ExitCode | Should -Be 0
        ($result.Output -join "`n") | Should -Be "No active AI context.`nRun `"ctx <profile> [profile...]`" to activate one."
        ($result.Output -join "`n") | Should -Not -Match ([regex]::Escape('[AI Context]'))
    }

    It 'an empty AI_CTX_PROFILES behaves like no active context' {
        $result = Invoke-CtxDotnetCurrent -Environment @{ AI_CTX_PROFILES = '' }

        $result.ExitCode | Should -Be 0
        ($result.Output -join "`n") | Should -Be "No active AI context.`nRun `"ctx <profile> [profile...]`" to activate one."
        ($result.Output -join "`n") | Should -Not -Match ([regex]::Escape('[AI Context]'))
    }

    It 'absent recorded mode reports an unknown mode even when the selector is set' {
        $result = Invoke-CtxDotnetCurrent -Environment @{
            AI_CTX_PROFILES              = 'review'
            AI_CTX_PROFILES_COPILOT_MODE = 'global-user'
        }
        $text = $result.Output -join "`n"

        $result.ExitCode | Should -Be 0
        $text | Should -Match ([regex]::Escape('[AI Context]'))
        $text | Should -Match ([regex]::Escape('Profile : review'))
        $text | Should -Match ([regex]::Escape('Profiles: <none>'))
        $text | Should -Match ([regex]::Escape('AI_CTX_PROFILES=review'))
        $text | Should -Match 'Mode: <unknown>'
        $text | Should -Not -Match 'Mode: A —'
        $text | Should -Not -Match 'Mode: B — global-user'
        $text | Should -Not -Match 'Mode: C —'
    }

    It 'recorded synthetic-home reports mode A, ignores the selector, and omits COPILOT_SKILLS_DIRS' {
        $result = Invoke-CtxDotnetCurrent -Environment @{
            AI_CTX_PROFILES              = 'review'
            AI_CTX_PROFILES_COPILOT_MODE = 'global-user'
            COPILOT_HOME                 = '/fabricated/home'
            COPILOT_SKILLS_DIRS          = '/fabricated/skills'
        } -Arguments @('--recorded-mode', 'synthetic-home')
        $text = $result.Output -join "`n"

        $result.ExitCode | Should -Be 0
        $text | Should -Match 'Mode: A — synthetic-home'
        $text | Should -Match ([regex]::Escape('COPILOT_HOME=/fabricated/home'))
        $text | Should -Not -Match 'COPILOT_SKILLS_DIRS='
    }

    It 'recorded global-user reports mode B with COPILOT_SKILLS_DIRS and COPILOT_HOME' {
        $result = Invoke-CtxDotnetCurrent -Environment @{
            AI_CTX_PROFILES     = 'review'
            COPILOT_HOME        = '/fabricated/home'
            COPILOT_SKILLS_DIRS = '/fabricated/skills'
        } -Arguments @('--recorded-mode', 'global-user')
        $text = $result.Output -join "`n"

        $result.ExitCode | Should -Be 0
        $text | Should -Match 'Mode: B — global-user'
        $text | Should -Match ([regex]::Escape('COPILOT_SKILLS_DIRS=/fabricated/skills'))
        $text | Should -Match ([regex]::Escape('COPILOT_HOME=/fabricated/home'))
    }

    It 'recorded ephemeral-clean reports mode C' {
        $result = Invoke-CtxDotnetCurrent -Environment @{
            AI_CTX_PROFILES = 'review'
            COPILOT_HOME    = '/fabricated/home'
        } -Arguments @('--recorded-mode', 'ephemeral-clean')
        $text = $result.Output -join "`n"

        $result.ExitCode | Should -Be 0
        $text | Should -Match 'Mode: C — ephemeral-clean'
        $text | Should -Match ([regex]::Escape('COPILOT_HOME=/fabricated/home'))
    }

    It 'absent recorded mode labels foreign COPILOT_HOME and COPILOT_SKILLS_DIRS unknown' {
        $result = Invoke-CtxDotnetCurrent -Environment @{
            AI_CTX_PROFILES     = 'review'
            COPILOT_HOME        = '/foreign/home'
            COPILOT_SKILLS_DIRS = '/foreign/skills'
        }
        $text = $result.Output -join "`n"

        $result.ExitCode | Should -Be 0
        $text | Should -Match 'Mode: <unknown>'
        $text | Should -Match ([regex]::Escape('COPILOT_SKILLS_DIRS=/foreign/skills (unknown)'))
        $text | Should -Match ([regex]::Escape('COPILOT_HOME=/foreign/home (unknown)'))
    }

    It 'absent recorded mode with no COPILOT_HOME reports it unset' {
        $result = Invoke-CtxDotnetCurrent -Environment @{ AI_CTX_PROFILES = 'review' }
        $text = $result.Output -join "`n"

        $result.ExitCode | Should -Be 0
        $text | Should -Match 'Mode: <unknown>'
        $text | Should -Match ([regex]::Escape('COPILOT_HOME=<unset>'))
    }

    It 'shows the first profile and the remaining profiles in order' {
        $result = Invoke-CtxDotnetCurrent -Environment @{
            AI_CTX_PROFILES = 'review+azure+security'
        } -Arguments @('--recorded-mode', 'global-user')
        $text = $result.Output -join "`n"

        $result.ExitCode | Should -Be 0
        $text | Should -Match ([regex]::Escape('Profile : review'))
        $text | Should -Match ([regex]::Escape('Profiles: azure, security'))
        $text | Should -Match ([regex]::Escape('AI_CTX_PROFILES=review+azure+security'))
    }

    It 'distinguishes unset from present-empty COPILOT_CUSTOM_INSTRUCTIONS_DIRS' {
        $unset = Invoke-CtxDotnetCurrent -Environment @{ AI_CTX_PROFILES = 'review' } -Arguments @('--recorded-mode', 'global-user')
        $unsetText = $unset.Output -join "`n"
        $unset.ExitCode | Should -Be 0
        $unsetText | Should -Match ([regex]::Escape('COPILOT_CUSTOM_INSTRUCTIONS_DIRS='))
        $unsetText | Should -Match ([regex]::Escape('<unset>'))
        $unsetText | Should -Not -Match '<present-empty>'

        $empty = Invoke-CtxDotnetCurrent -Environment @{
            AI_CTX_PROFILES                  = 'review'
            COPILOT_HOME                     = '/fabricated/home'
            COPILOT_SKILLS_DIRS              = '/fabricated/skills'
            COPILOT_CUSTOM_INSTRUCTIONS_DIRS = ''
        } -Arguments @('--recorded-mode', 'global-user')
        $emptyText = $empty.Output -join "`n"
        $empty.ExitCode | Should -Be 0
        $emptyText | Should -Match ([regex]::Escape('COPILOT_CUSTOM_INSTRUCTIONS_DIRS='))
        $emptyText | Should -Match '<present-empty>'
        $emptyText | Should -Not -Match '<unset>'
    }

    It 'recorded global-user falls back to unset for absent COPILOT_HOME and COPILOT_SKILLS_DIRS' {
        $result = Invoke-CtxDotnetCurrent -Environment @{ AI_CTX_PROFILES = 'review' } -Arguments @('--recorded-mode', 'global-user')
        $text = $result.Output -join "`n"

        $result.ExitCode | Should -Be 0
        $text | Should -Match ([regex]::Escape('Mode: B — global-user'))
        $text | Should -Match ([regex]::Escape('COPILOT_SKILLS_DIRS=<unset>'))
        $text | Should -Match ([regex]::Escape('COPILOT_HOME=<unset>'))
    }

    It 'splits non-empty COPILOT_CUSTOM_INSTRUCTIONS_DIRS on commas in order' {
        $result = Invoke-CtxDotnetCurrent -Environment @{
            AI_CTX_PROFILES                  = 'review'
            COPILOT_CUSTOM_INSTRUCTIONS_DIRS = '/alpha,/beta,/gamma'
        } -Arguments @('--recorded-mode', 'global-user')

        $result.ExitCode | Should -Be 0
        ($result.Output -join "`n") | Should -Match "COPILOT_CUSTOM_INSTRUCTIONS_DIRS=`n/alpha`n/beta`n/gamma"
    }

    It 'does not print canonical projection listings' {
        $result = Invoke-CtxDotnetCurrent -Environment @{ AI_CTX_PROFILES = 'review' } -Arguments @('--recorded-mode', 'synthetic-home')

        $result.ExitCode | Should -Be 0
        ($result.Output -join "`n") | Should -Not -Match 'instructions\.md'
    }
}

<#
    Issue #67 packet 2: the PowerShell side of the shell<->engine protocol
    codec. Apply-CtxProtocolResponse is the adapter function (Verb-CtxNoun, as
    in the rest of ctx.ps1); these cases pin its byte-grammar rejection of a
    UTF-8 BOM and of CRLF line endings, and that rejection applies nothing.
#>
Describe 'ctx .NET protocol adapter' {

    BeforeAll {
        $Script:CtxProtocolSrc = Join-Path $Script:CtxDotnetRepoRoot 'ctx.ps1'
    }

    BeforeEach {
        $Script:CtxDotnetTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ctx-dotnet-pester-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $Script:CtxDotnetTmp -Force | Out-Null

        $Script:CtxProtocolPriorProfiles = $env:AI_CTX_PROFILES

        . $Script:CtxProtocolSrc
    }

    AfterEach {
        if ($null -ne $Script:CtxProtocolPriorProfiles) {
            $env:AI_CTX_PROFILES = $Script:CtxProtocolPriorProfiles
        } else {
            Remove-Item Env:\AI_CTX_PROFILES -ErrorAction SilentlyContinue
        }

        Remove-Item -LiteralPath $Script:CtxDotnetTmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'rejects a response with a UTF-8 BOM and applies nothing' {
        $response = Join-Path $Script:CtxDotnetTmp 'bom-response'
        $body = [System.Text.Encoding]::UTF8.GetBytes("CTX-RES 1`nSET AI_CTX_PROFILES changed`nEXIT 0`nEND`n")
        $bytes = [byte[]]::new($body.Length + 3)
        $bytes[0] = 0xEF; $bytes[1] = 0xBB; $bytes[2] = 0xBF
        [System.Array]::Copy($body, 0, $bytes, 3, $body.Length)
        [System.IO.File]::WriteAllBytes($response, $bytes)

        $env:AI_CTX_PROFILES = 'keep'
        $threw = $null
        try { Apply-CtxProtocolResponse -Path $response } catch { $threw = $_ }

        $threw | Should -Not -BeNullOrEmpty
        $threw.Exception.Message | Should -Match '(?i)bom'
        $env:AI_CTX_PROFILES | Should -Be 'keep'
    }

    It 'rejects a response with CRLF line endings and applies nothing' {
        $response = Join-Path $Script:CtxDotnetTmp 'crlf-response'
        [System.IO.File]::WriteAllText(
            $response,
            "CTX-RES 1`r`nSET AI_CTX_PROFILES changed`r`nEXIT 0`r`nEND`r`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        $env:AI_CTX_PROFILES = 'keep'
        $threw = $null
        try { Apply-CtxProtocolResponse -Path $response } catch { $threw = $_ }

        $threw | Should -Not -BeNullOrEmpty
        $threw.Exception.Message | Should -Match '(?i)(crlf|line ending)'
        $env:AI_CTX_PROFILES | Should -Be 'keep'
    }

    It 'surfaces outcome.* values including a present-empty value' {
        $response = Join-Path $Script:CtxDotnetTmp 'outcome-response'
        [System.IO.File]::WriteAllText(
            $response,
            "CTX-RES 1`nUNSET COPILOT_HOME`nREC outcome.warn_unowned_home `nREC outcome.warn_home_changed /tmp/other`nREC outcome.retained_ephemeral_home /tmp/eph`nEXIT 0`nEND`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        $exit = Apply-CtxProtocolResponse -Path $response

        $exit | Should -Be 0
        $Script:CtxProtocolOutcomeWarnUnownedHome | Should -Be ''
        $Script:CtxProtocolOutcomeWarnHomeChanged | Should -Be '/tmp/other'
        $Script:CtxProtocolOutcomeRetainedEphemeralHome | Should -Be '/tmp/eph'
    }

    It 'returns the response EXIT value after applying its actions' {
        $response = Join-Path $Script:CtxDotnetTmp 'exit-response'
        [System.IO.File]::WriteAllText(
            $response,
            "CTX-RES 1`nSET AI_CTX_PROFILES changed`nEXIT 7`nEND`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        $exit = Apply-CtxProtocolResponse -Path $response

        $exit | Should -Be 7
        $env:AI_CTX_PROFILES | Should -Be 'changed'
    }
}

<#
    Issue #67 packet 3: the `protocol clear` decision table, pinned at the CLI
    level by asserting the exact response file bytes independently of the shell.
#>
Describe 'ctx .NET protocol clear command' {

    BeforeAll {
        function Script:Invoke-CtxProtocolClear {
            param([string]$ProtocolDir)

            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = 'dotnet'
            $engine = $env:CTX_ENGINE_DLL
            if ($engine -and (Test-Path -LiteralPath $engine -PathType Leaf)) {
                foreach ($arg in @($engine, 'protocol', 'clear', '--protocol-dir', $ProtocolDir)) { [void]$psi.ArgumentList.Add($arg) }
            } else {
                foreach ($arg in @('run', '--project', $Script:CtxDotnetProject, '--', 'protocol', 'clear', '--protocol-dir', $ProtocolDir)) { [void]$psi.ArgumentList.Add($arg) }
            }
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.WorkingDirectory = $Script:CtxDotnetTmp
            $psi.Environment['DOTNET_CLI_HOME'] = $Script:CtxDotnetTmp
            $psi.Environment['DOTNET_CLI_TELEMETRY_OPTOUT'] = '1'
            $psi.Environment['DOTNET_NOLOGO'] = '1'

            $proc = [System.Diagnostics.Process]::Start($psi)
            $stdout = $proc.StandardOutput.ReadToEnd()
            $stderr = $proc.StandardError.ReadToEnd()
            $proc.WaitForExit()
            return [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $stderr }
        }

        function Script:New-CtxProtocolDir {
            param([string]$Name)
            $dir = Join-Path $Script:CtxDotnetTmp $Name
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            return $dir
        }

        function Script:Write-CtxClearRequest {
            param([string]$Dir, [string[]]$Lines)
            $body = "CTX-REQ 1`n" + (($Lines -join "`n") + "`n") + "END`n"
            [System.IO.File]::WriteAllBytes((Join-Path $Dir 'request'), [System.Text.UTF8Encoding]::new($false).GetBytes($body))
        }

        function Script:Get-ClearExpected {
            param([string[]]$Lines)
            return "CTX-RES 1`n" + (($Lines -join "`n") + "`n") + "EXIT 0`nEND`n"
        }

        function Script:Assert-ClearResponse {
            param([string]$Dir, [string[]]$Lines)
            $responsePath = Join-Path $Dir 'response'
            Test-Path -LiteralPath $responsePath -PathType Leaf | Should -BeTrue
            $actual = [System.Text.UTF8Encoding]::new($false).GetString([System.IO.File]::ReadAllBytes($responsePath))
            $actual | Should -BeExactly (Get-ClearExpected -Lines $Lines)
        }
    }

    BeforeEach {
        $Script:CtxDotnetTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ctx-dotnet-pester-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $Script:CtxDotnetTmp -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $Script:CtxDotnetTmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'synthetic-home unsets COPILOT_HOME unconditionally' {
        $dir = New-CtxProtocolDir 'synthetic'
        Write-CtxClearRequest -Dir $dir -Lines @('active.mode synthetic-home', 'live.home_was_set 1', 'live.home_value /tmp/x')
        $result = Invoke-CtxProtocolClear -ProtocolDir $dir

        $result.ExitCode | Should -Be 0
        Assert-ClearResponse -Dir $dir -Lines @(
            'UNSET AI_CTX_PROFILES',
            'UNSET COPILOT_CUSTOM_INSTRUCTIONS_DIRS',
            'UNSET COPILOT_HOME'
        )
    }

    It 'ephemeral-clean matching home unsets and retains the recorded path' {
        $dir = New-CtxProtocolDir 'eph-match'
        Write-CtxClearRequest -Dir $dir -Lines @('active.mode ephemeral-clean', 'active.home_value /tmp/eph', 'live.home_was_set 1', 'live.home_value /tmp/eph')
        $result = Invoke-CtxProtocolClear -ProtocolDir $dir

        $result.ExitCode | Should -Be 0
        Assert-ClearResponse -Dir $dir -Lines @(
            'UNSET AI_CTX_PROFILES',
            'UNSET COPILOT_CUSTOM_INSTRUCTIONS_DIRS',
            'UNSET COPILOT_HOME',
            'REC outcome.retained_ephemeral_home /tmp/eph'
        )
    }

    It 'ephemeral-clean changed home is preserved, retained and warned' {
        $dir = New-CtxProtocolDir 'eph-changed'
        Write-CtxClearRequest -Dir $dir -Lines @('active.mode ephemeral-clean', 'active.home_value /tmp/eph', 'live.home_was_set 1', 'live.home_value /tmp/user-home')
        $result = Invoke-CtxProtocolClear -ProtocolDir $dir

        $result.ExitCode | Should -Be 0
        Assert-ClearResponse -Dir $dir -Lines @(
            'UNSET AI_CTX_PROFILES',
            'UNSET COPILOT_CUSTOM_INSTRUCTIONS_DIRS',
            'REC outcome.retained_ephemeral_home /tmp/eph',
            'REC outcome.warn_home_changed /tmp/user-home'
        )
    }

    It 'ephemeral-clean with no recorded home emits no home records' {
        $dir = New-CtxProtocolDir 'eph-nohome'
        Write-CtxClearRequest -Dir $dir -Lines @('active.mode ephemeral-clean', 'active.home_value ', 'live.home_was_set 0', 'live.home_value ')
        $result = Invoke-CtxProtocolClear -ProtocolDir $dir

        $result.ExitCode | Should -Be 0
        Assert-ClearResponse -Dir $dir -Lines @(
            'UNSET AI_CTX_PROFILES',
            'UNSET COPILOT_CUSTOM_INSTRUCTIONS_DIRS'
        )
    }

    It 'global-user never touches COPILOT_HOME' {
        $dir = New-CtxProtocolDir 'global'
        Write-CtxClearRequest -Dir $dir -Lines @('active.mode global-user', 'live.home_was_set 1', 'live.home_value /tmp/user-home')
        $result = Invoke-CtxProtocolClear -ProtocolDir $dir

        $result.ExitCode | Should -Be 0
        Assert-ClearResponse -Dir $dir -Lines @(
            'UNSET AI_CTX_PROFILES',
            'UNSET COPILOT_CUSTOM_INSTRUCTIONS_DIRS'
        )
    }

    It 'no matching record warns an unowned present COPILOT_HOME' {
        $dir = New-CtxProtocolDir 'unowned'
        Write-CtxClearRequest -Dir $dir -Lines @('live.home_was_set 1', 'live.home_value /tmp/foreign')
        $result = Invoke-CtxProtocolClear -ProtocolDir $dir

        $result.ExitCode | Should -Be 0
        Assert-ClearResponse -Dir $dir -Lines @(
            'UNSET AI_CTX_PROFILES',
            'UNSET COPILOT_CUSTOM_INSTRUCTIONS_DIRS',
            'REC outcome.warn_unowned_home /tmp/foreign'
        )
    }

    It 'owned matching skills are unset' {
        $dir = New-CtxProtocolDir 'skills-match'
        Write-CtxClearRequest -Dir $dir -Lines @('active.mode global-user', 'skills.owned 1', 'skills.was_set 1', 'skills.value /skills', 'live.skills_was_set 1', 'live.skills_value /skills')
        $result = Invoke-CtxProtocolClear -ProtocolDir $dir

        $result.ExitCode | Should -Be 0
        Assert-ClearResponse -Dir $dir -Lines @(
            'UNSET AI_CTX_PROFILES',
            'UNSET COPILOT_CUSTOM_INSTRUCTIONS_DIRS',
            'UNSET COPILOT_SKILLS_DIRS'
        )
    }

    It 'owned mismatched skills are preserved' {
        $dir = New-CtxProtocolDir 'skills-mismatch'
        Write-CtxClearRequest -Dir $dir -Lines @('active.mode global-user', 'skills.owned 1', 'skills.was_set 1', 'skills.value /skills', 'live.skills_was_set 1', 'live.skills_value /user-skills')
        $result = Invoke-CtxProtocolClear -ProtocolDir $dir

        $result.ExitCode | Should -Be 0
        Assert-ClearResponse -Dir $dir -Lines @(
            'UNSET AI_CTX_PROFILES',
            'UNSET COPILOT_CUSTOM_INSTRUCTIONS_DIRS'
        )
    }

    It 'unowned skills are preserved' {
        $dir = New-CtxProtocolDir 'skills-unowned'
        Write-CtxClearRequest -Dir $dir -Lines @('active.mode global-user', 'skills.owned 0', 'skills.was_set 0', 'skills.value ', 'live.skills_was_set 1', 'live.skills_value /foreign-skills')
        $result = Invoke-CtxProtocolClear -ProtocolDir $dir

        $result.ExitCode | Should -Be 0
        Assert-ClearResponse -Dir $dir -Lines @(
            'UNSET AI_CTX_PROFILES',
            'UNSET COPILOT_CUSTOM_INSTRUCTIONS_DIRS'
        )
    }

    It 'rejects an unknown request field and writes no response' {
        $dir = New-CtxProtocolDir 'bogus'
        Write-CtxClearRequest -Dir $dir -Lines @('bogus.field x')
        $result = Invoke-CtxProtocolClear -ProtocolDir $dir

        $result.ExitCode | Should -Not -Be 0
        Test-Path -LiteralPath (Join-Path $dir 'response') | Should -BeFalse
    }
}

<#
    Issue #67 packet 3: fail-closed behavior. A missing engine must leave the
    environment untouched and report failure; it must never partially unset.
#>
Describe 'ctx clear fail-closed engine handling' {

    BeforeAll {
        $Script:CtxFailClosedSrc = Join-Path $Script:CtxDotnetRepoRoot 'ctx.ps1'
    }

    BeforeEach {
        $Script:CtxFailClosedPriorEngineSet = Test-Path Env:\CTX_ENGINE_DLL
        $Script:CtxFailClosedPriorEngine = $env:CTX_ENGINE_DLL

        Remove-Item Env:\AI_CTX_PROFILES -ErrorAction SilentlyContinue
        Remove-Item Env:\COPILOT_CUSTOM_INSTRUCTIONS_DIRS -ErrorAction SilentlyContinue
        Remove-Item Env:\COPILOT_HOME -ErrorAction SilentlyContinue
        Remove-Item Env:\COPILOT_SKILLS_DIRS -ErrorAction SilentlyContinue

        . $Script:CtxFailClosedSrc
    }

    AfterEach {
        if ($Script:CtxFailClosedPriorEngineSet) {
            $env:CTX_ENGINE_DLL = $Script:CtxFailClosedPriorEngine
        } else {
            Remove-Item Env:\CTX_ENGINE_DLL -ErrorAction SilentlyContinue
        }
        Remove-Item Env:\AI_CTX_PROFILES -ErrorAction SilentlyContinue
        Remove-Item Env:\COPILOT_CUSTOM_INSTRUCTIONS_DIRS -ErrorAction SilentlyContinue
        Remove-Item Env:\COPILOT_HOME -ErrorAction SilentlyContinue
        Remove-Item Env:\COPILOT_SKILLS_DIRS -ErrorAction SilentlyContinue
    }

    It 'returns $false and leaves the environment untouched when the engine is missing' {
        $env:AI_CTX_PROFILES = 'review'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS = '/dirs'
        $env:COPILOT_HOME = '/tmp/ctx-synthetic'
        Set-CtxActiveRecord -Mode 'synthetic-home'
        $env:CTX_ENGINE_DLL = '/nonexistent/missing-ctx-engine.dll'

        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $result = $null
        try { $result = Clear-CtxContext 2>$null } finally { $ErrorActionPreference = $previous }

        $result | Should -BeFalse
        $env:AI_CTX_PROFILES | Should -Be 'review'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be '/dirs'
        $env:COPILOT_HOME | Should -Be '/tmp/ctx-synthetic'
    }

    It 'returns $false and leaves the environment untouched when the engine is unset' {
        $env:AI_CTX_PROFILES = 'review'
        $env:COPILOT_HOME = '/tmp/ctx-synthetic'
        Set-CtxActiveRecord -Mode 'synthetic-home'
        Remove-Item Env:\CTX_ENGINE_DLL -ErrorAction SilentlyContinue

        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $result = $null
        try { $result = Clear-CtxContext 2>$null } finally { $ErrorActionPreference = $previous }

        $result | Should -BeFalse
        $env:AI_CTX_PROFILES | Should -Be 'review'
        $env:COPILOT_HOME | Should -Be '/tmp/ctx-synthetic'
    }
}
