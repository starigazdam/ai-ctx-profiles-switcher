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
