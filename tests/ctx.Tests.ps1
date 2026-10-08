#Requires -Modules Pester
<#
.SYNOPSIS
    Pester test suite for ctx.ps1 — mirrors tests/ctx.bats (historical design
    in docs/design-history-copilot-home.md
    section 5.2), including COPILOT_HOME per-folder skill isolation and the
    3.4a self-healing reconciliation hazard fix.

.NOTES
    Every test runs against an isolated $HOME / $env:AI_CTX_PROFILES_CONFIG_ROOT /
    COPILOT_HOME root (via CTX_COPILOT_DIR / AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT overrides)
    inside a temp dir, so nothing touches the real user's ~/.copilot or
    ~/.config/ctx.

    KNOWN LIMITATION: the Windows-only symlink -> junction -> hardlink
    fallback ladder (plan section 3.5) cannot be fully exercised on Linux/
    macOS pwsh, since New-Item -ItemType SymbolicLink succeeds unprivileged
    there and the Junction/HardLink rungs are never reached. Test 10
    (fallback on failure) forces failure generically instead. The ladder's
    Windows-specific behavior is documented as manual-verification-only,
    per section 5.3 of the plan.
#>

BeforeAll {
    $Script:CtxSrc = Join-Path (Split-Path -Parent $PSScriptRoot) 'ctx.ps1'

    function Script:New-CtxTestProfile {
        param([string]$Name, [string]$Skill)
        $profileDir = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT "profiles/$Name"
        New-Item -ItemType Directory -Path (Join-Path $profileDir '.github/instructions') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $profileDir ".github/instructions/$Name.instructions.md") -Value "# $Name instructions"
        if ($Skill) {
            $skillDir = Join-Path $profileDir ".github/skills/$Skill"
            New-Item -ItemType Directory -Path $skillDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $skillDir 'SKILL.md') -Value "---`nname: $Skill`ndescription: Test skill $Skill`n---`n"
        }
        return $profileDir
    }

    function Script:Test-CtxOldUnixDotnet {
        $isWindowsLike = $IsWindows -or ($env:OS -ceq 'Windows_NT')
        return ((-not $isWindowsLike) -and ([System.Environment]::Version.Major -lt 9))
    }

    function Script:New-CtxTestCanonicalProfile {
        param([string]$Name, [byte[]]$AgentsBytes)
        $profileDir = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT "profiles/$Name"
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        if ($null -eq $AgentsBytes) {
            $AgentsBytes = [System.Text.Encoding]::UTF8.GetBytes("# $Name canonical instructions")
        }
        [System.IO.File]::WriteAllBytes((Join-Path $profileDir 'AGENTS.md'), $AgentsBytes)
        return $profileDir
    }

    function Script:New-CtxTestCanonicalSkill {
        param([string]$Profile, [string]$Skill)
        $skillDir = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT "profiles/$Profile/.agents/skills/$Skill"
        New-Item -ItemType Directory -Path $skillDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $skillDir 'SKILL.md'), "---`nname: $Skill`ndescription: test`n---`n")
    }

    function Script:Get-CtxProjectionBytes {
        param([byte[]]$Body)
        $header = [System.Text.Encoding]::UTF8.GetBytes("---`napplyTo: `"**`"`n---`n`n")
        $out = New-Object byte[] ($header.Length + $Body.Length)
        [Array]::Copy($header, 0, $out, 0, $header.Length)
        [Array]::Copy($Body, 0, $out, $header.Length, $Body.Length)
        return ,$out
    }

    function Script:Assert-CtxFileBytes {
        param([string]$Path, [byte[]]$Expected)
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path)) | Should -Be ([Convert]::ToBase64String($Expected))
    }
}

Describe 'ctx.ps1 COPILOT_HOME isolation' {

    BeforeEach {
        $Script:TestTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ctx-pester-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $Script:TestTmp -Force | Out-Null

        $env:HOME = Join-Path $Script:TestTmp 'home'
        $env:AI_CTX_PROFILES_CONFIG_ROOT = Join-Path $Script:TestTmp 'ai-config'
        $env:CTX_COPILOT_DIR = Join-Path $Script:TestTmp 'copilot'
        $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT = Join-Path $env:HOME '.config/ctx/homes'

        New-Item -ItemType Directory -Path $env:HOME -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') -Force | Out-Null
        New-Item -ItemType Directory -Path $env:CTX_COPILOT_DIR -Force | Out-Null

        Remove-Item Env:\AI_CTX_PROFILES -ErrorAction SilentlyContinue
        Remove-Item Env:\COPILOT_CUSTOM_INSTRUCTIONS_DIRS -ErrorAction SilentlyContinue
        Remove-Item Env:\COPILOT_HOME -ErrorAction SilentlyContinue
        Remove-Item Env:\COPILOT_SKILLS_DIRS -ErrorAction SilentlyContinue
        Remove-Item Env:\CTX_AUTO_LOAD -ErrorAction SilentlyContinue
        Remove-Item Env:\AI_CTX_PROFILES_COPILOT_MODE -ErrorAction SilentlyContinue
        Remove-Item Env:\AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT -ErrorAction SilentlyContinue
        $Script:CtxAutoLoadDir = $null
        $Script:CtxAutoLoadHomeOverride = $null
        $Script:CtxSkillsDirsOwned = $false
        $Script:CtxSkillsDirsWasSet = $false
        $Script:CtxSkillsDirsValue = $null
        $Script:CtxActiveMode = $null
        $Script:CtxActiveContext = $null
        $Script:CtxActiveCustomDirs = $null
        $Script:CtxActiveHomeWasSet = $false
        $Script:CtxActiveHomeValue = $null

        Set-Location $env:HOME
        . $Script:CtxSrc
    }

    AfterEach {
        Remove-Item -LiteralPath $Script:TestTmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    function New-CtxTestProfile {
        param([string]$Name, [string]$Skill)
        $profileDir = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT "profiles/$Name"
        New-Item -ItemType Directory -Path (Join-Path $profileDir '.github/instructions') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $profileDir ".github/instructions/$Name.instructions.md") -Value "# $Name instructions"
        if ($Skill) {
            $skillDir = Join-Path $profileDir ".github/skills/$Skill"
            New-Item -ItemType Directory -Path $skillDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $skillDir 'SKILL.md') -Value "---`nname: $Skill`ndescription: Test skill $Skill`n---`n"
        }
        return $profileDir
    }

    It 'Test 1: manual activation creates isolated COPILOT_HOME with skill symlink' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        ctx review

        $env:COPILOT_HOME | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $env:COPILOT_HOME | Should -BeTrue
        $link = Join-Path $env:COPILOT_HOME 'skills/review-skill'
        Test-CtxIsLink -Path $link | Should -BeTrue
    }

    It 'Test 2: shared files link back to the real copilot dir' {
        New-CtxTestProfile -Name 'review' | Out-Null
        ctx review

        foreach ($f in (Get-CtxCopilotHomeSharedFiles)) {
            $link = Join-Path $env:COPILOT_HOME $f
            Test-CtxIsLink -Path $link | Should -BeTrue
        }
        foreach ($d in (Get-CtxCopilotHomeSharedDirs)) {
            $link = Join-Path $env:COPILOT_HOME $d
            Test-CtxIsLink -Path $link | Should -BeTrue
        }
    }

    It 'Test 3: multi-profile context has both skills, single-profile context is isolated' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        New-CtxTestProfile -Name 'test' -Skill 'test-skill' | Out-Null

        ctx review
        $reviewHome = $env:COPILOT_HOME
        Test-Path -LiteralPath (Join-Path $reviewHome 'skills/review-skill') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $reviewHome 'skills/test-skill') | Should -BeFalse

        ctx test
        $testHome = $env:COPILOT_HOME
        $testHome | Should -Not -Be $reviewHome
        Test-Path -LiteralPath (Join-Path $testHome 'skills/test-skill') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $testHome 'skills/review-skill') | Should -BeFalse
    }

    It 'Test 3b: .ctx multi-entry activation puts both skills in one home, no bleed' {
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        $testDir = New-CtxTestProfile -Name 'test' -Skill 'test-skill'

        $proj = Join-Path $Script:TestTmp 'project'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir`ntest:$testDir"

        Import-CtxFile -CtxFile (Join-Path $proj '.ctx')
        $combinedHome = $env:COPILOT_HOME
        Test-Path -LiteralPath (Join-Path $combinedHome 'skills/review-skill') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $combinedHome 'skills/test-skill') | Should -BeTrue
    }

    It 'Test 4: re-activating the same profile does not recreate unchanged links' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        ctx review
        $settingsPath = Join-Path $env:COPILOT_HOME 'settings.json'
        $before = (Get-Item -LiteralPath $settingsPath -Force).LastWriteTimeUtc

        Start-Sleep -Seconds 1
        ctx review
        $after = (Get-Item -LiteralPath $settingsPath -Force).LastWriteTimeUtc

        $before | Should -Be $after
    }

    It 'Test 5: reactivation removes a skill symlink that no longer exists in the profile' {
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        ctx review
        $link = Join-Path $env:COPILOT_HOME 'skills/review-skill'
        Test-Path -LiteralPath $link | Should -BeTrue

        Remove-Item -LiteralPath (Join-Path $reviewDir '.github/skills/review-skill') -Recurse -Force
        ctx review

        Test-Path -LiteralPath $link | Should -BeFalse
    }

    It 'Test 6: ctx clear unsets COPILOT_HOME but preserves the home dir on disk' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        ctx review
        $homeDir = $env:COPILOT_HOME
        Test-Path -LiteralPath $homeDir | Should -BeTrue

        Clear-CtxContext

        $env:COPILOT_HOME | Should -BeNullOrEmpty
        Test-Path -LiteralPath $homeDir | Should -BeTrue
    }

    It 'Test 7: ctx clear --all removes only the current context home dir' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        New-CtxTestProfile -Name 'test' -Skill 'test-skill' | Out-Null

        ctx review
        $reviewHome = $env:COPILOT_HOME
        ctx test
        $testHome = $env:COPILOT_HOME

        Test-Path -LiteralPath $reviewHome | Should -BeTrue
        Test-Path -LiteralPath $testHome | Should -BeTrue

        Clear-CtxContext -All

        Test-Path -LiteralPath $testHome | Should -BeFalse
        Test-Path -LiteralPath $reviewHome | Should -BeTrue
    }

    It 'Test 8: .ctx auto-load creates COPILOT_HOME isolation identical to manual ctx' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        New-CtxTestProfile -Name 'test' -Skill 'test-skill' | Out-Null

        $repoRoot = Split-Path -Parent $Script:CtxSrc
        $proj = Join-Path $repoRoot 'examples/copilot-cli-dotctx-test-review'
        Test-Path -LiteralPath $proj | Should -BeTrue

        Import-CtxFile -CtxFile (Join-Path $proj '.ctx')

        $env:COPILOT_HOME | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $env:COPILOT_HOME 'skills/review-profile-skill') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $env:COPILOT_HOME 'skills/test-profile-skill') | Should -BeTrue
    }

    It 'Test 9: fresh activation does not create settings.local.json' {
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'

        $proj = Join-Path $Script:TestTmp 'project9'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"

        Import-CtxFile -CtxFile (Join-Path $proj '.ctx')

        Test-Path -LiteralPath (Join-Path $proj '.github/copilot/settings.local.json') | Should -BeFalse
    }

    It 'Test 9b: manual ctx activation does not create settings.local.json' {
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        ctx review
        Test-Path -LiteralPath (Join-Path $reviewDir '.github/copilot') | Should -BeFalse
    }

    It 'Test 10: ctx warns and does not crash when link creation fails' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null

        Mock New-CtxLink { return $false } -ModuleName $null

        ctx review -WarningVariable warnings -WarningAction SilentlyContinue

        $env:COPILOT_HOME | Should -BeNullOrEmpty
    }

    It 'manual ctx activation leaves state untouched when link reconciliation fails' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        New-CtxTestProfile -Name 'test' -Skill 'test-skill' | Out-Null
        ctx review | Out-Null

        $prevProfiles = $env:AI_CTX_PROFILES
        $prevDirs = $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS
        $prevHome = $env:COPILOT_HOME
        $prevMode = $Script:CtxActiveMode
        $prevContext = $Script:CtxActiveContext
        $prevCustomDirs = $Script:CtxActiveCustomDirs
        $prevHomeWasSet = $Script:CtxActiveHomeWasSet
        $prevHomeValue = $Script:CtxActiveHomeValue

        Mock Resolve-CtxLink { return $false }

        $result = ctx test -WarningVariable warnings -WarningAction SilentlyContinue

        # The manual ctx function reports the failure as exactly $false and
        # returns before completing the activation, so the existing
        # activation's env vars and session record are left exactly as they
        # were.
        $result | Should -BeExactly $false
        $warnings -join "`n" | Should -Match 'warning'
        $env:AI_CTX_PROFILES | Should -Be $prevProfiles
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be $prevDirs
        $env:COPILOT_HOME | Should -Be $prevHome
        $Script:CtxActiveMode | Should -Be $prevMode
        $Script:CtxActiveContext | Should -Be $prevContext
        $Script:CtxActiveCustomDirs | Should -Be $prevCustomDirs
        $Script:CtxActiveHomeWasSet | Should -Be $prevHomeWasSet
        $Script:CtxActiveHomeValue | Should -Be $prevHomeValue
    }

    It '.ctx auto-load leaves state and workspace untouched when link reconciliation fails' {
        $proj = Join-Path $env:HOME 'project-link-fail'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        $testDir = New-CtxTestProfile -Name 'test' -Skill 'test-skill'
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "review:$reviewDir"
        Import-CtxFile -CtxFile $ctxFile | Out-Null

        $workspace = Join-Path $proj 'project-link-fail.code-workspace'
        $wsBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($workspace))

        $prevProfiles = $env:AI_CTX_PROFILES
        $prevDirs = $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS
        $prevHome = $env:COPILOT_HOME
        $prevMode = $Script:CtxActiveMode
        $prevContext = $Script:CtxActiveContext
        $prevCustomDirs = $Script:CtxActiveCustomDirs
        $prevHomeWasSet = $Script:CtxActiveHomeWasSet
        $prevHomeValue = $Script:CtxActiveHomeValue

        Set-Content -LiteralPath $ctxFile -Value "test:$testDir"
        $script:linkWarnings = @()
        Mock Resolve-CtxLink { return $false }
        Mock Write-Warning { $script:linkWarnings += $Message }

        $result = Import-CtxFile -CtxFile $ctxFile

        $result | Should -BeFalse
        $script:linkWarnings -join "`n" | Should -Match 'warning'
        $env:AI_CTX_PROFILES | Should -Be $prevProfiles
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be $prevDirs
        $env:COPILOT_HOME | Should -Be $prevHome
        $Script:CtxActiveMode | Should -Be $prevMode
        $Script:CtxActiveContext | Should -Be $prevContext
        $Script:CtxActiveCustomDirs | Should -Be $prevCustomDirs
        $Script:CtxActiveHomeWasSet | Should -Be $prevHomeWasSet
        $Script:CtxActiveHomeValue | Should -Be $prevHomeValue
        $wsAfter = [Convert]::ToBase64String([IO.File]::ReadAllBytes($workspace))
        $wsAfter | Should -Be $wsBefore
    }

    It 'manual ctx activation leaves state untouched when COPILOT_HOME creation fails' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        New-CtxTestProfile -Name 'test' -Skill 'test-skill' | Out-Null
        ctx review | Out-Null

        $prevProfiles = $env:AI_CTX_PROFILES
        $prevDirs = $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS
        $prevHome = $env:COPILOT_HOME
        $prevMode = $Script:CtxActiveMode
        $prevContext = $Script:CtxActiveContext
        $prevCustomDirs = $Script:CtxActiveCustomDirs
        $prevHomeWasSet = $Script:CtxActiveHomeWasSet
        $prevHomeValue = $Script:CtxActiveHomeValue

        $skillsPath = Join-Path (Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'test') 'skills'
        Mock New-Item { throw 'boom' } -ParameterFilter { $ItemType -eq 'Directory' -and $Path -eq $skillsPath }

        $result = ctx test -WarningVariable warnings -WarningAction SilentlyContinue

        $result | Should -BeExactly $false
        $warnings -join "`n" | Should -Match 'warning'
        $env:AI_CTX_PROFILES | Should -Be $prevProfiles
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be $prevDirs
        $env:COPILOT_HOME | Should -Be $prevHome
        $Script:CtxActiveMode | Should -Be $prevMode
        $Script:CtxActiveContext | Should -Be $prevContext
        $Script:CtxActiveCustomDirs | Should -Be $prevCustomDirs
        $Script:CtxActiveHomeWasSet | Should -Be $prevHomeWasSet
        $Script:CtxActiveHomeValue | Should -Be $prevHomeValue
    }

    It '.ctx auto-load leaves state and workspace untouched when COPILOT_HOME creation fails' {
        $proj = Join-Path $env:HOME 'project-mkdir-fail'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        $testDir = New-CtxTestProfile -Name 'test' -Skill 'test-skill'
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "review:$reviewDir"
        Import-CtxFile -CtxFile $ctxFile | Out-Null

        $workspace = Join-Path $proj 'project-mkdir-fail.code-workspace'
        $wsBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($workspace))

        $prevProfiles = $env:AI_CTX_PROFILES
        $prevDirs = $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS
        $prevHome = $env:COPILOT_HOME
        $prevMode = $Script:CtxActiveMode
        $prevContext = $Script:CtxActiveContext
        $prevCustomDirs = $Script:CtxActiveCustomDirs
        $prevHomeWasSet = $Script:CtxActiveHomeWasSet
        $prevHomeValue = $Script:CtxActiveHomeValue

        Set-Content -LiteralPath $ctxFile -Value "test:$testDir"
        $skillsPath = Join-Path (Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'test') 'skills'
        $script:mkdirWarnings = @()
        Mock New-Item { throw 'boom' } -ParameterFilter { $ItemType -eq 'Directory' -and $Path -eq $skillsPath }
        Mock Write-Warning { $script:mkdirWarnings += $Message }

        $result = Import-CtxFile -CtxFile $ctxFile

        $result | Should -BeFalse
        $script:mkdirWarnings -join "`n" | Should -Match 'warning'
        $env:AI_CTX_PROFILES | Should -Be $prevProfiles
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be $prevDirs
        $env:COPILOT_HOME | Should -Be $prevHome
        $Script:CtxActiveMode | Should -Be $prevMode
        $Script:CtxActiveContext | Should -Be $prevContext
        $Script:CtxActiveCustomDirs | Should -Be $prevCustomDirs
        $Script:CtxActiveHomeWasSet | Should -Be $prevHomeWasSet
        $Script:CtxActiveHomeValue | Should -Be $prevHomeValue
        $wsAfter = [Convert]::ToBase64String([IO.File]::ReadAllBytes($workspace))
        $wsAfter | Should -Be $wsBefore
    }

    It 'Invoke-CtxAutoLoad propagates $false and preserves state when link reconciliation fails' {
        $projA = Join-Path $env:HOME 'project-hook-fail-a'
        New-Item -ItemType Directory -Path $projA -Force | Out-Null
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        $testDir = New-CtxTestProfile -Name 'test' -Skill 'test-skill'
        Set-Content -LiteralPath (Join-Path $projA '.ctx') -Value "review:$reviewDir"

        Set-Location $projA
        Invoke-CtxAutoLoad
        $env:AI_CTX_PROFILES | Should -Be 'review'
        $Script:CtxAutoLoadDir | Should -Be $projA

        # Auto-load never writes a workspace file (issue #30); seed one the
        # way an explicit Import-CtxFile/activation would, to test that the
        # hook's later failure elsewhere still leaves a pre-existing one intact.
        Update-CtxWorkspaceFile -BaseDir $projA -Names @('review') -Dirs @($reviewDir)
        $workspaceA = Join-Path $projA 'project-hook-fail-a.code-workspace'
        $wsBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($workspaceA))

        $prevProfiles = $env:AI_CTX_PROFILES
        $prevDirs = $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS
        $prevHome = $env:COPILOT_HOME
        $prevMode = $Script:CtxActiveMode
        $prevContext = $Script:CtxActiveContext
        $prevCustomDirs = $Script:CtxActiveCustomDirs
        $prevHomeWasSet = $Script:CtxActiveHomeWasSet
        $prevHomeValue = $Script:CtxActiveHomeValue

        # A different directory's .ctx load fails; the hook must surface it as
        # exactly $false while leaving the prior activation untouched.
        $projB = Join-Path $env:HOME 'project-hook-fail-b'
        New-Item -ItemType Directory -Path $projB -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $projB '.ctx') -Value "test:$testDir"
        Set-Location $projB

        $script:linkWarnings = @()
        Mock Resolve-CtxLink { return $false }
        Mock Write-Warning { $script:linkWarnings += $Message }

        $result = Invoke-CtxAutoLoad

        $result | Should -BeExactly $false
        $script:linkWarnings -join "`n" | Should -Match 'warning'
        $Script:CtxAutoLoadDir | Should -Be $projA
        $env:AI_CTX_PROFILES | Should -Be $prevProfiles
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be $prevDirs
        $env:COPILOT_HOME | Should -Be $prevHome
        $Script:CtxActiveMode | Should -Be $prevMode
        $Script:CtxActiveContext | Should -Be $prevContext
        $Script:CtxActiveCustomDirs | Should -Be $prevCustomDirs
        $Script:CtxActiveHomeWasSet | Should -Be $prevHomeWasSet
        $Script:CtxActiveHomeValue | Should -Be $prevHomeValue
        $wsAfter = [Convert]::ToBase64String([IO.File]::ReadAllBytes($workspaceA))
        $wsAfter | Should -Be $wsBefore
        Test-Path -LiteralPath (Join-Path $projB 'project-hook-fail-b.code-workspace') | Should -BeFalse
    }

    It 'ctx load propagates $false and preserves state when import fails' {
        $proj = Join-Path $env:HOME 'project-ctx-load-fail'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        $testDir = New-CtxTestProfile -Name 'test' -Skill 'test-skill'
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "review:$reviewDir"
        Import-CtxFile -CtxFile $ctxFile | Out-Null

        $workspace = Join-Path $proj 'project-ctx-load-fail.code-workspace'
        $wsBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($workspace))

        $prevProfiles = $env:AI_CTX_PROFILES
        $prevDirs = $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS
        $prevHome = $env:COPILOT_HOME
        $prevMode = $Script:CtxActiveMode
        $prevContext = $Script:CtxActiveContext
        $prevCustomDirs = $Script:CtxActiveCustomDirs
        $prevHomeWasSet = $Script:CtxActiveHomeWasSet
        $prevHomeValue = $Script:CtxActiveHomeValue

        Set-Content -LiteralPath $ctxFile -Value "test:$testDir"
        $script:linkWarnings = @()
        Mock Resolve-CtxLink { return $false }
        Mock Write-Warning { $script:linkWarnings += $Message }

        $result = ctx load $ctxFile

        $result | Should -BeExactly $false
        $script:linkWarnings -join "`n" | Should -Match 'warning'
        $env:AI_CTX_PROFILES | Should -Be $prevProfiles
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be $prevDirs
        $env:COPILOT_HOME | Should -Be $prevHome
        $Script:CtxActiveMode | Should -Be $prevMode
        $Script:CtxActiveContext | Should -Be $prevContext
        $Script:CtxActiveCustomDirs | Should -Be $prevCustomDirs
        $Script:CtxActiveHomeWasSet | Should -Be $prevHomeWasSet
        $Script:CtxActiveHomeValue | Should -Be $prevHomeValue
        $wsAfter = [Convert]::ToBase64String([IO.File]::ReadAllBytes($workspace))
        $wsAfter | Should -Be $wsBefore
    }

    It 'Test 11: test-profile-skill SKILL.md has well-formed frontmatter' {
        $repoRoot = Split-Path -Parent $Script:CtxSrc
        $skillMd = Join-Path $repoRoot 'examples/ai-profiles/test/.github/skills/test-profile-skill/SKILL.md'
        Test-Path -LiteralPath $skillMd | Should -BeTrue

        $lines = Get-Content -LiteralPath $skillMd
        $lines[0] | Should -Be '---'
        ($lines | Where-Object { $_ -eq '---' } | Measure-Object).Count | Should -BeGreaterOrEqual 2
        ($lines | Where-Object { $_ -match '^name:' } | Measure-Object).Count | Should -BeGreaterThan 0
        ($lines | Where-Object { $_ -match '^description:' } | Measure-Object).Count | Should -BeGreaterThan 0
    }

    It 'Test 12: symlink replaced by a plain-file write is detected and reconciled (settings.json)' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        ctx review
        $ctxHome = $env:COPILOT_HOME
        $settingsPath = Join-Path $ctxHome 'settings.json'

        Test-CtxIsLink -Path $settingsPath | Should -BeTrue

        # Simulate Copilot CLI's write-tmp + rename(tmp, path), which
        # replaces the link itself with a plain regular file.
        Remove-Item -LiteralPath $settingsPath -Force
        Set-Content -LiteralPath $settingsPath -Value '{"bashEnv": true}'
        Test-CtxIsLink -Path $settingsPath | Should -BeFalse

        ctx review

        Test-CtxIsLink -Path $settingsPath | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $env:CTX_COPILOT_DIR 'settings.json') -Raw) | Should -Match 'bashEnv'
        (Get-Content -LiteralPath $settingsPath -Raw) | Should -Match 'bashEnv'
    }

    It 'Test 13: reconciliation runs for every shared file, not just settings.json' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        ctx review
        $ctxHome = $env:COPILOT_HOME

        foreach ($f in @('config.json', 'mcp-config.json', 'session-store.db')) {
            $p = Join-Path $ctxHome $f
            Remove-Item -LiteralPath $p -Force
            Set-Content -LiteralPath $p -Value "content-for-$f"
        }

        ctx review

        foreach ($f in @('config.json', 'mcp-config.json', 'session-store.db')) {
            $p = Join-Path $ctxHome $f
            Test-CtxIsLink -Path $p | Should -BeTrue
            (Get-Content -LiteralPath (Join-Path $env:CTX_COPILOT_DIR $f) -Raw).Trim() | Should -Be "content-for-$f"
        }
    }

    It 'Test 14: reconciliation is a no-op when nothing changed' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        ctx review
        $ctxHome = $env:COPILOT_HOME
        $settingsPath = Join-Path $ctxHome 'settings.json'
        $realPath = Join-Path $env:CTX_COPILOT_DIR 'settings.json'

        $beforeHome = (Get-Item -LiteralPath $settingsPath -Force).LastWriteTimeUtc
        $beforeReal = (Get-Item -LiteralPath $realPath -Force).LastWriteTimeUtc

        Start-Sleep -Seconds 1
        ctx review

        $afterHome = (Get-Item -LiteralPath $settingsPath -Force).LastWriteTimeUtc
        $afterReal = (Get-Item -LiteralPath $realPath -Force).LastWriteTimeUtc

        $beforeHome | Should -Be $afterHome
        $beforeReal | Should -Be $afterReal
    }

    It 'Test 15: home: directive in .ctx puts COPILOT_HOME at the custom location' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null

        $proj = Join-Path $env:HOME 'project-home'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "home: .copilot-ctx`nreview:$reviewDir"

        Import-CtxFile -CtxFile (Join-Path $proj '.ctx')

        $expectedHome = Join-Path $proj '.copilot-ctx'
        $env:COPILOT_HOME | Should -Be $expectedHome
        Test-Path -LiteralPath $env:COPILOT_HOME -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path (Join-Path $env:COPILOT_HOME 'skills') 'review-skill') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'review') | Should -BeFalse
    }

    It 'Test 16: .ctx without a home: directive still uses the centralized default' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null

        $proj = Join-Path $Script:TestTmp 'project-nohome'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"

        Import-CtxFile -CtxFile (Join-Path $proj '.ctx')

        $env:COPILOT_HOME | Should -Be (Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'review')
    }

    It 'Test 17: home: directive with absolute path is used as-is' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null

        $proj = Join-Path $env:HOME 'project-home-abs'
        $customHome = Join-Path $env:HOME 'custom-copilot-home'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "home: $customHome`nreview:$reviewDir"

        Import-CtxFile -CtxFile (Join-Path $proj '.ctx')

        $env:COPILOT_HOME | Should -Be $customHome
        Test-Path -LiteralPath (Join-Path (Join-Path $env:COPILOT_HOME 'skills') 'review-skill') | Should -BeTrue
    }

    It 'Test 18: Clear-CtxContext -All removes the custom home: location, not the centralized one' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null

        $proj = Join-Path $env:HOME 'project-home-clear'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "home: .copilot-ctx`nreview:$reviewDir"

        Import-CtxFile -CtxFile (Join-Path $proj '.ctx')
        $customHome = $env:COPILOT_HOME
        Test-Path -LiteralPath $customHome -PathType Container | Should -BeTrue

        $Script:CtxAutoLoadDir = $proj
        Clear-CtxContext -All

        Test-Path -LiteralPath $customHome | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'review') | Should -BeFalse
    }

    It 'Test 19: duplicate home: directive in .ctx is rejected' {
        $proj = Join-Path $env:HOME 'project-home-dup'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "home: .copilot-ctx-a`nhome: .copilot-ctx-b`nreview:$reviewDir"

        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $Error.Clear()
        $result = $null
        try {
            $result = Import-CtxFile -CtxFile (Join-Path $proj '.ctx')
        } finally {
            $ErrorActionPreference = $prevEap
        }

        $result | Should -Be $false
        ($Error | Select-Object -First 1).ToString() | Should -Match 'duplicate'
    }

    It 'Test 20: home: accepts a canonical nested path under HOME' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $proj = Join-Path $env:HOME 'project-home-valid'
        $custom = Join-Path $env:HOME '.config/ctx/homes/project-valid/nested'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "home:$custom`nreview:$reviewDir"
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx')
        $env:COPILOT_HOME | Should -Be $custom
        Test-Path -LiteralPath $custom -PathType Container | Should -BeTrue
    }

    It 'Test 21: home: rejects traversal outside HOME and preserves active context' {
        $proj = Join-Path $Script:TestTmp 'project-home-traversal'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "home:..\outside`nreview:$reviewDir"
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        try { $result = Import-CtxFile -CtxFile (Join-Path $proj '.ctx') } finally { $ErrorActionPreference = $prevEap }
        $result | Should -Be $false
        ($Error | Select-Object -First 1).ToString() | Should -Match 'unsafe home'
        Test-Path -LiteralPath (Join-Path $Script:TestTmp 'outside') | Should -BeFalse
        $env:AI_CTX_PROFILES | Should -BeNullOrEmpty
    }

    It 'Test 22: home: rejects absolute paths outside allowed roots' {
        $proj = Join-Path $Script:TestTmp 'project-home-absolute'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        $unrelated = Join-Path $Script:TestTmp 'unrelated'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "home:$unrelated`nreview:$reviewDir"
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        try { $result = Import-CtxFile -CtxFile (Join-Path $proj '.ctx') } finally { $ErrorActionPreference = $prevEap }
        $result | Should -Be $false
        ($Error | Select-Object -First 1).ToString() | Should -Match 'unsafe home'
        Test-Path -LiteralPath $unrelated | Should -BeFalse
    }

    It 'Test 23: home: rejects root and empty paths' {
        $proj = Join-Path $Script:TestTmp 'project-home-boundaries'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        foreach ($value in @([System.IO.Path]::GetPathRoot($HOME), '')) {
            Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "home:$value`nreview:$reviewDir"
            $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
            try { $result = Import-CtxFile -CtxFile (Join-Path $proj '.ctx') } finally { $ErrorActionPreference = $prevEap }
            $result | Should -Be $false
        }
    }

    It 'Test 24: home: rejects a symlink escape outside allowed roots' {
        $proj = Join-Path $env:HOME 'project-home-link'
        $outside = Join-Path $Script:TestTmp 'outside-link'
        New-Item -ItemType Directory -Path $proj,$outside -Force | Out-Null
        New-Item -ItemType SymbolicLink -Path (Join-Path $proj 'link') -Target $outside -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "home:$(Join-Path $proj 'link\child')`nreview:$reviewDir"
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        try { $result = Import-CtxFile -CtxFile (Join-Path $proj '.ctx') } finally { $ErrorActionPreference = $prevEap }
        $result | Should -Be $false
        ($Error | Select-Object -First 1).ToString() | Should -Match 'unsafe home'
    }

    It 'Test 25: Clear-CtxContext -All refuses an unsafe selected home' {
        New-CtxTestProfile -Name 'review' | Out-Null
        $victim = Join-Path $env:HOME 'victim-home'
        $outside = Join-Path $Script:TestTmp 'victim-outside'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        New-Item -ItemType SymbolicLink -Path $victim -Target $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'data.txt') -Value 'important'
        # Establish a real Mode A activation record, then point COPILOT_HOME
        # and the override at the unsafe link so clear --all still refuses.
        ctx review | Out-Null
        $env:COPILOT_HOME = $victim; $Script:CtxAutoLoadHomeOverride = $victim
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        try { Clear-CtxContext -All } finally { $ErrorActionPreference = $prevEap }
        Test-Path -LiteralPath (Join-Path $victim 'data.txt') | Should -BeTrue
        ($Error | Select-Object -First 1).ToString() | Should -Match 'unsafe home'
    }

    It 'Test 26: Clear-CtxContext -All propagates a valid-home deletion failure' {
        New-CtxTestProfile -Name 'review' | Out-Null
        # Establish a real Mode A activation record; the synthetic home is the
        # deletion target.
        ctx review | Out-Null
        $victim = $env:COPILOT_HOME
        Test-Path -LiteralPath $victim -PathType Container | Should -BeTrue
        Mock Remove-Item { }
        Mock Remove-Item { throw 'simulated deletion failure' } -ParameterFilter { $LiteralPath -eq $victim }

        $result = Clear-CtxContext -All 2>$null

        $result | Should -BeFalse
        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq $victim }
    }

    It 'Test 27: Clear-CtxContext -All propagates an artifact deletion failure' {
        $dir = Join-Path $TestDrive 'artifact-failure'
        $settingsDir = Join-Path $dir '.github/copilot'
        New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
        $settingsFile = Join-Path $settingsDir 'settings.local.json'
        Set-Content -Path $settingsFile -Value '{}'
        $Script:CtxAutoLoadDir = $dir
        Remove-Item Env:\AI_CTX_PROFILES -ErrorAction SilentlyContinue
        Remove-Item Env:\COPILOT_HOME -ErrorAction SilentlyContinue
        Mock Remove-Item { }
        Mock Remove-Item { throw 'simulated artifact deletion failure' } -ParameterFilter { $LiteralPath -eq $settingsFile }

        $result = Clear-CtxContext -All 2>$null

        $result | Should -BeFalse
        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq $settingsFile }
    }

    It 'Test 28: home validator rejects HOME itself' {
        { Get-CtxValidatedHomePath -Path $env:HOME } | Should -Throw '*unsafe home*'
    }

    It 'Test 29: home validator rejects AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT itself' {
        { Get-CtxValidatedHomePath -Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT } | Should -Throw '*unsafe home*'
    }

    It 'home: directive conflicts with a non-synthetic-home mode and leaves state untouched' {
        $proj = Join-Path $env:HOME 'project-home-mode-conflict'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = New-CtxTestProfile -Name 'review'
        $custom = Join-Path $env:HOME '.config/ctx/homes/mode-conflict'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "home:$custom`nreview:$reviewDir"
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'global-user'
        $env:AI_CTX_PROFILES = 'previous'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS = 'previous-dirs'
        $env:COPILOT_HOME = 'previous-home'
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        try { $result = Import-CtxFile -CtxFile (Join-Path $proj '.ctx') } finally { $ErrorActionPreference = $prevEap }
        $result | Should -BeFalse
        ($Error | Select-Object -First 1).ToString() | Should -Match 'ctx: error:'
        ($Error | Select-Object -First 1).ToString() | Should -Match 'home'
        ($Error | Select-Object -First 1).ToString() | Should -Match 'global-user'
        $env:AI_CTX_PROFILES | Should -Be 'previous'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be 'previous-dirs'
        $env:COPILOT_HOME | Should -Be 'previous-home'
        Test-Path -LiteralPath $custom | Should -BeFalse
    }

    It 'an invalid copilot mode is rejected before any state change' {
        $proj = Join-Path $env:HOME 'project-invalid-mode'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = New-CtxTestProfile -Name 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'bogus'
        $env:AI_CTX_PROFILES = 'previous'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS = 'previous-dirs'
        $env:COPILOT_HOME = 'previous-home'
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        try { ctx review } finally { $ErrorActionPreference = $prevEap }
        ($Error | Select-Object -First 1).ToString() | Should -Match 'ctx: error:'
        ($Error | Select-Object -First 1).ToString() | Should -Match 'synthetic-home'
        ($Error | Select-Object -First 1).ToString() | Should -Match 'global-user'
        ($Error | Select-Object -First 1).ToString() | Should -Match 'ephemeral-clean'
        $env:AI_CTX_PROFILES | Should -Be 'previous'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be 'previous-dirs'
        $env:COPILOT_HOME | Should -Be 'previous-home'

        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        try { $result = Import-CtxFile -CtxFile (Join-Path $proj '.ctx') } finally { $ErrorActionPreference = $prevEap }
        $result | Should -BeFalse
        $env:AI_CTX_PROFILES | Should -Be 'previous'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be 'previous-dirs'
        $env:COPILOT_HOME | Should -Be 'previous-home'
        Test-Path -LiteralPath (Join-Path $proj 'project-invalid-mode.code-workspace') | Should -BeFalse
    }

    It 'workspace created by ctx is marked and removed by clear --all' {
        $proj = Join-Path $Script:TestTmp 'project-workspace'
        $profile = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/review'
        New-Item -ItemType Directory -Path $proj, $profile -Force | Out-Null
        Update-CtxWorkspaceFile -BaseDir $proj -Names @('review') -Dirs @($profile)

        $workspace = Join-Path $proj 'project-workspace.code-workspace'
        ((Get-Content -LiteralPath $workspace -Raw) | ConvertFrom-Json).generatedBy | Should -Be 'ctx'
        $Script:CtxAutoLoadDir = $proj
        Clear-CtxContext -All | Should -BeTrue
        Test-Path -LiteralPath $workspace | Should -BeFalse
    }

    It 'pre-existing unmarked workspace is preserved by clear --all' {
        $proj = Join-Path $Script:TestTmp 'project-workspace-existing'
        $workspace = Join-Path $proj 'project-workspace-existing.code-workspace'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath $workspace -Value '{"folders":[{"path":"."}],"settings":{}}'
        $Script:CtxAutoLoadDir = $proj
        Clear-CtxContext -All | Should -BeTrue
        Test-Path -LiteralPath $workspace | Should -BeTrue
    }

    It 'symlink to a marked workspace is preserved by clear --all' {
        $proj = Join-Path $Script:TestTmp 'project-workspace-symlink'
        $target = Join-Path $Script:TestTmp 'marked.code-workspace'
        $workspace = Join-Path $proj 'project-workspace-symlink.code-workspace'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath $target -Value '{"generatedBy":"ctx"}'
        New-Item -ItemType SymbolicLink -Path $workspace -Target $target -ErrorAction Stop | Out-Null
        $Script:CtxAutoLoadDir = $proj
        Clear-CtxContext -All | Should -BeTrue
        (Get-Item -LiteralPath $workspace -Force).LinkType | Should -Not -BeNullOrEmpty
    }

    It 'wrong-case workspace marker is preserved by clear --all' {
        $proj = Join-Path $Script:TestTmp 'project-workspace-case'
        $workspace = Join-Path $proj 'project-workspace-case.code-workspace'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath $workspace -Value '{"generatedBy":"CTX"}'
        $Script:CtxAutoLoadDir = $proj
        Clear-CtxContext -All | Should -BeTrue
        Test-Path -LiteralPath $workspace | Should -BeTrue
    }

    It 'invalid workspace markers are preserved with warnings' {
        foreach ($case in @(
            @{ Name = 'malformed'; Content = '{not-json}' },
            @{ Name = 'false'; Content = '{"generatedBy":false}' },
            @{ Name = '123'; Content = '{"generatedBy":123}' },
            @{ Name = 'null'; Content = '{"generatedBy":null}' }
        )) {
            $proj = Join-Path $Script:TestTmp "project-workspace-marker-$($case.Name)"
            $workspace = Join-Path $proj "project-workspace-marker-$($case.Name).code-workspace"
            New-Item -ItemType Directory -Path $proj -Force | Out-Null
            Set-Content -LiteralPath $workspace -Value $case.Content
            $Script:CtxAutoLoadDir = $proj
            Clear-CtxContext -All | Should -BeTrue
            Test-Path -LiteralPath $workspace | Should -BeTrue
        }
    }

    It 'help documents conditional workspace cleanup' {
        $script:helpOutput = $null
        Mock Write-Host {
            param($Object)
            $script:helpOutput = $Object
        }
        Show-CtxUsage
        $script:helpOutput | Should -Match 'generatedBy'
        $script:helpOutput | Should -Match 'unmarked, invalid'
        $script:helpOutput | Should -Match 'linked workspaces are preserved'
    }

    It 'ctx check reports no .ctx as a successful read-only no-op' {
        $outside = Join-Path $Script:TestTmp 'outside'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Set-Location $outside
        $env:AI_CTX_PROFILES = 'manual'
        $result = @(Test-CtxActivation)
        $result[-1] | Should -BeTrue
        $env:AI_CTX_PROFILES | Should -Be 'manual'
    }

    It 'ctx check detects environment and link drift without repairing it' {
        $proj = Join-Path $Script:TestTmp 'project-check'
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null
        Set-Location $proj
        $env:AI_CTX_PROFILES = 'wrong'
        $settings = Join-Path $env:COPILOT_HOME 'settings.json'
        Remove-Item -LiteralPath $settings -Force
        Set-Content -LiteralPath $settings -Value 'drift'
        $result = @(Test-CtxActivation)
        $result[-1] | Should -BeFalse
        Test-CtxIsLink -Path $settings | Should -BeFalse
        $env:AI_CTX_PROFILES | Should -Be 'wrong'
    }

    It 'Mode A default-equivalence: unset and explicit synthetic-home are byte-identical for current and check' {
        $proj = Join-Path $env:HOME 'project-mode-default-equivalence'
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "review:$reviewDir"

        Remove-Item Env:\AI_CTX_PROFILES_COPILOT_MODE -ErrorAction SilentlyContinue
        Import-CtxFile -CtxFile $ctxFile | Out-Null
        $currentUnset = @(& { Show-CtxCurrent } 6>&1)
        ($currentUnset -join "`n") | Should -Match 'Mode: A — synthetic-home'

        Clear-CtxContext | Out-Null
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'synthetic-home'
        Import-CtxFile -CtxFile $ctxFile | Out-Null
        $currentExplicit = @(& { Show-CtxCurrent } 6>&1)
        ($currentExplicit -join "`n") | Should -Match 'Mode: A — synthetic-home'
        ($currentExplicit -join "`n") | Should -Be ($currentUnset -join "`n")

        Remove-Item Env:\AI_CTX_PROFILES_COPILOT_MODE -ErrorAction SilentlyContinue
        Set-Location $proj
        $checkUnset = @(& { Test-CtxActivation } 6>&1)
        ($checkUnset -join "`n") | Should -Match 'CHECK PASS COPILOT_MODE'

        $env:AI_CTX_PROFILES_COPILOT_MODE = 'synthetic-home'
        $checkExplicit = @(& { Test-CtxActivation } 6>&1)
        ($checkExplicit -join "`n") | Should -Match 'CHECK PASS COPILOT_MODE'
        ($checkExplicit -join "`n") | Should -Be ($checkUnset -join "`n")
    }

    It 'direct ctx check returns a scalar Boolean status while preserving diagnostics' {
        $proj = Join-Path $Script:TestTmp 'project-check-direct'
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null
        Set-Location $proj
        $result = ctx check
        $result.GetType().Name | Should -Be 'Boolean'
        $result | Should -BeTrue
        $env:AI_CTX_PROFILES = 'wrong'
        $result = ctx check
        $result.GetType().Name | Should -Be 'Boolean'
        $result | Should -BeFalse
    }

    It 'ctx check accepts a hardlink fallback for shared files' {
        $proj = Join-Path $Script:TestTmp 'project-check-hardlink'
        $reviewDir = New-CtxTestProfile -Name 'review'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null
        $link = Join-Path $env:COPILOT_HOME 'settings.json'
        Remove-Item -LiteralPath $link -Force
        New-Item -ItemType HardLink -Path $link -Target (Join-Path $env:CTX_COPILOT_DIR 'settings.json') | Out-Null
        (Get-CtxFileIdentity -Path $link) | Should -Be (Get-CtxFileIdentity -Path (Join-Path $env:CTX_COPILOT_DIR 'settings.json'))
        Set-Location $proj
        (ctx check) | Should -BeTrue
    }

    It 'ctx check detects an unexpected stale skill deterministically' {
        $proj = Join-Path $Script:TestTmp 'project-check-stale'
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null
        $stale = Join-Path $env:COPILOT_HOME 'skills/stale-skill'
        New-Item -ItemType Directory -Path $stale -Force | Out-Null
        Set-Location $proj
        $result = Test-CtxActivation
        $result.GetType().Name | Should -Be 'Boolean'
        $result | Should -BeFalse
        $diagnostics = @(& { Test-CtxActivation } 6>&1)
        ($diagnostics -join "`n") | Should -Match 'CHECK FAIL skill:stale-skill: unexpected skill'
    }

    It 'ctx check normalizes wrapped Copilot skill JSON and preserves sorted diagnostics' {
        $proj = Join-Path $Script:TestTmp 'project-check-copilot-wrapped'
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'zeta-skill'
        $alphaDir = Join-Path $reviewDir '.github/skills/alpha-skill'
        New-Item -ItemType Directory -Path $alphaDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $alphaDir 'SKILL.md') -Value '---`nname: alpha-skill`ndescription: alpha`n---`n'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null
        $script:copilotProbeCalls = 0
        function copilot {
            $script:copilotProbeCalls++
            return '{"skills":[{"name":"zeta-skill"},{"name":"alpha-skill"}]}'
        }
        Set-Location $proj
        $first = @(& { Test-CtxActivation } 6>&1)
        $second = @(& { Test-CtxActivation } 6>&1)
        ($first -join "`n") | Should -Be ($second -join "`n")
        ($first -join "`n") | Should -Match 'CHECK SKIP skills: copilot probe disabled in read-only check'
        $script:copilotProbeCalls | Should -Be 0
    }

    It 'ctx check treats mixed-case HOME like Import-CtxFile' {
        $proj = Join-Path $env:HOME 'project-check-home-case'
        $override = Join-Path $env:HOME 'custom-copilot-home'
        $reviewDir = New-CtxTestProfile -Name 'review'
        New-Item -ItemType Directory -Path $proj, $override -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "HOME:$override`nreview:$reviewDir"
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null
        Set-Location $proj
        (Test-CtxActivation) | Should -BeTrue
    }

    It 'activation treats mixed-case HOME as a directive and excludes it from AI_CTX_PROFILES' {
        $proj = Join-Path $env:HOME 'project-activation-home-case'
        $override = Join-Path $env:HOME 'custom-copilot-home'
        $reviewDir = New-CtxTestProfile -Name 'review'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "HoMe:$override`nreview:$reviewDir"
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Should -BeTrue
        $env:COPILOT_HOME | Should -Be $override
        $env:AI_CTX_PROFILES | Should -Be 'review'
        $env:AI_CTX_PROFILES | Should -Not -Match 'HoMe'
    }

    It 'reactivation removes a dangling stale skill link' {
        $proj = Join-Path $env:HOME 'project-dangling-skill'
        $reviewDir = New-CtxTestProfile -Name 'review'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null
        $stale = Join-Path $env:COPILOT_HOME 'skills/stale-skill'
        New-Item -ItemType SymbolicLink -Path $stale -Target (Join-Path $env:HOME 'missing-skill') | Out-Null
        (Get-Item -LiteralPath $stale -Force).LinkType | Should -Not -BeNullOrEmpty
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null
        Test-Path -LiteralPath $stale | Should -BeFalse
        Get-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }


    It 'Issue 4: ctx check shares parser semantics for profiles, direct paths, and home directives without writes' {
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        $direct = Join-Path $Script:TestTmp 'direct-check'
        $proj = Join-Path $env:HOME 'project-check-parser-parity'
        $override = Join-Path $env:HOME 'check-parser-home'
        New-Item -ItemType Directory -Path $direct, $proj, $override -Force | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "HoMe:$override`nreview:@profile`nlocal:$direct"
        Import-CtxFile -CtxFile $ctxFile | Should -BeTrue
        $beforeContext = $env:AI_CTX_PROFILES; $beforeDirs = $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS; $beforeHome = $env:COPILOT_HOME
        $beforeWrite = (Get-Item -LiteralPath $ctxFile -Force).LastWriteTimeUtc
        Set-Location $proj

        (Test-CtxActivation) | Should -BeTrue
        $env:AI_CTX_PROFILES | Should -Be $beforeContext
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be $beforeDirs
        $env:COPILOT_HOME | Should -Be $beforeHome
        (Get-Item -LiteralPath $ctxFile -Force).LastWriteTimeUtc | Should -Be $beforeWrite
    }

    It 'Issue 4: ctx check rejects duplicate labels, targets, and reserved home labels read-only' {
        New-CtxTestProfile -Name 'review' | Out-Null
        $proj = Join-Path $env:HOME 'project-check-parser-invalid'
        $duplicate = Join-Path $Script:TestTmp 'duplicate-target'
        New-Item -ItemType Directory -Path $proj, $duplicate -Force | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "review:$duplicate`nReview:$duplicate`nhome:$(Join-Path $env:HOME 'check-a')`nHOME:$(Join-Path $env:HOME 'check-b')"
        $env:AI_CTX_PROFILES = 'previous'; $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS = 'previous-dirs'
        $beforeWrite = (Get-Item -LiteralPath $ctxFile -Force).LastWriteTimeUtc
        Set-Location $proj

        (Test-CtxActivation) | Should -BeFalse
        $env:AI_CTX_PROFILES | Should -Be 'previous'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be 'previous-dirs'
        (Get-Item -LiteralPath $ctxFile -Force).LastWriteTimeUtc | Should -Be $beforeWrite
    }

    It 'Issue 4: manual and @profile traversal cannot escape profiles before state changes' {
        New-CtxTestProfile -Name 'review' | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'escaped') -Force | Out-Null
        $env:AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT = Join-Path $Script:TestTmp 'trusted-external-profiles'
        New-Item -ItemType Directory -Path $env:AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT -Force | Out-Null
        $env:AI_CTX_PROFILES = 'previous'; $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS = 'previous-dirs'

        $previous = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        try { ctx ../escaped } finally { $ErrorActionPreference = $previous }
        ($Error | Select-Object -First 1).ToString() | Should -Match 'invalid profile identifier'
        $env:AI_CTX_PROFILES | Should -Be 'previous'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be 'previous-dirs'

        $proj = Join-Path $env:HOME 'project-profile-traversal'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "../escaped:@profile`nreview:@profile"
        $previous = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        try { $result = Import-CtxFile -CtxFile $ctxFile } finally { $ErrorActionPreference = $previous }
        $result | Should -BeFalse
        ($Error | Select-Object -First 1).ToString() | Should -Match 'invalid profile identifier'
        $env:AI_CTX_PROFILES | Should -Be 'previous'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be 'previous-dirs'
    }



    It 'Issue 4: ctx check rejects canonical duplicate targets read-only' {
        $proj = Join-Path $env:HOME 'project-check-canonical-target'
        $target = Join-Path $Script:TestTmp 'canonical-target'
        New-Item -ItemType Directory -Path $proj, $target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "one:$target`ntwo:$(Join-Path $target '.')"
        $env:AI_CTX_PROFILES = 'previous'; $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS = 'previous-dirs'
        Set-Location $proj

        (Test-CtxActivation) | Should -BeFalse
        $env:AI_CTX_PROFILES | Should -Be 'previous'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be 'previous-dirs'
    }

    It "noautoload flag: Import-CtxFile still loads a noautoload .ctx file" {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $proj = Join-Path $env:HOME 'project-noautoload'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "noautoload`nreview:$reviewDir"

        Import-CtxFile -CtxFile (Join-Path $proj '.ctx')

        $env:AI_CTX_PROFILES | Should -Be 'review'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Match 'profiles.review'
    }

    It "noautoload flag: Invoke-CtxAutoLoad skips a .ctx file with noautoload" {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $proj = Join-Path $env:HOME 'project-noautoload-hook'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "noautoload`nreview:$reviewDir"

        Set-Location $proj
        Invoke-CtxAutoLoad

        $env:AI_CTX_PROFILES | Should -BeNullOrEmpty
        $Script:CtxAutoLoadDir | Should -BeNullOrEmpty
    }

    It "issue30: Invoke-CtxAutoLoad does not create a .code-workspace file" {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $proj = Join-Path $env:HOME 'project-issue30-autoload'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"

        Set-Location $proj
        Invoke-CtxAutoLoad

        $env:AI_CTX_PROFILES | Should -Be 'review'
        Join-Path $proj 'project-issue30-autoload.code-workspace' | Should -Not -Exist
    }

    It "issue30: explicit Import-CtxFile still creates a .code-workspace file" {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $proj = Join-Path $env:HOME 'project-issue30-explicit'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"

        Import-CtxFile -CtxFile (Join-Path $proj '.ctx')

        $env:AI_CTX_PROFILES | Should -Be 'review'
        Join-Path $proj 'project-issue30-explicit.code-workspace' | Should -Exist
    }

    It "noautoload flag: case-insensitive (NOAUTOLOAD is accepted)" {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $proj = Join-Path $env:HOME 'project-noautoload-upper'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "NOAUTOLOAD`nreview:$reviewDir"

        Import-CtxFile -CtxFile (Join-Path $proj '.ctx')
        $env:AI_CTX_PROFILES | Should -Be 'review'

        Set-Location $proj
        Remove-Item Env:\AI_CTX_PROFILES -ErrorAction SilentlyContinue
        Remove-Item Env:\COPILOT_CUSTOM_INSTRUCTIONS_DIRS -ErrorAction SilentlyContinue
        Remove-Item Env:\COPILOT_HOME -ErrorAction SilentlyContinue
        $Script:CtxAutoLoadDir = $null
        Invoke-CtxAutoLoad

        $env:AI_CTX_PROFILES | Should -BeNullOrEmpty
    }

    It "noautoload flag: hook clears context when flag added after auto-load" {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $proj = Join-Path $env:HOME 'project-noautoload-added-later'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"

        Set-Location $proj
        Invoke-CtxAutoLoad
        $env:AI_CTX_PROFILES | Should -Be 'review'
        $Script:CtxAutoLoadDir | Should -Be $proj

        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "noautoload`nreview:$reviewDir"
        Invoke-CtxAutoLoad

        $env:AI_CTX_PROFILES | Should -BeNullOrEmpty
        $Script:CtxAutoLoadDir | Should -BeNullOrEmpty
    }

    It "ctx load: loads a .ctx file via explicit path" {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $proj = Join-Path $env:HOME 'project-ctx-load'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"

        ctx load (Join-Path $proj '.ctx')

        $env:AI_CTX_PROFILES | Should -Be 'review'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Match 'profiles.review'
        $Script:CtxAutoLoadDir | Should -Be $proj
    }

    It "ctx load in Mode B returns no Boolean pipeline value on success" {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'global-user'
        $proj = Join-Path $env:HOME 'project-ctx-load-mode-b'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"

        $result = @(ctx load (Join-Path $proj '.ctx'))

        @($result | Where-Object { $_ -is [bool] }).Count | Should -Be 0
        $env:AI_CTX_PROFILES | Should -Be 'review'
        $env:COPILOT_HOME | Should -BeNullOrEmpty
        $Script:CtxAutoLoadDir | Should -Be $proj
    }

    It "ctx load in Mode C returns no Boolean pipeline value on success" {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'ephemeral-clean'
        $proj = Join-Path $env:HOME 'project-ctx-load-mode-c'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"

        $result = @(ctx load (Join-Path $proj '.ctx'))

        @($result | Where-Object { $_ -is [bool] }).Count | Should -Be 0
        $env:AI_CTX_PROFILES | Should -Be 'review'
        $Script:CtxAutoLoadDir | Should -Be $proj
    }

    It "ctx load in Mode A returns the documented $true on success" {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'synthetic-home'
        $proj = Join-Path $env:HOME 'project-ctx-load-mode-a'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"

        $result = ctx load (Join-Path $proj '.ctx')

        $result | Should -BeExactly $true
        $env:AI_CTX_PROFILES | Should -Be 'review'
        $Script:CtxAutoLoadDir | Should -Be $proj
    }

    It "ctx load: loads a noautoload .ctx file that the hook would skip" {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $proj = Join-Path $env:HOME 'project-ctx-load-noautoload'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "noautoload`nreview:$reviewDir"

        ctx load (Join-Path $proj '.ctx')

        $env:AI_CTX_PROFILES | Should -Be 'review'
        $Script:CtxAutoLoadDir | Should -Be $proj
    }

    It "ctx load: relative path resolves against current location" {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $proj = Join-Path $env:HOME 'project-ctx-load-relative'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"

        Set-Location $proj
        ctx load .ctx

        $env:AI_CTX_PROFILES | Should -Be 'review'
        $Script:CtxAutoLoadDir | Should -Be $proj
    }

    It "ctx load: sets state so Clear-CtxContext -All cleans up artifacts" {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $proj = Join-Path $env:HOME 'project-ctx-load-clear-all'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"

        ctx load (Join-Path $proj '.ctx')
        $homeDir = $env:COPILOT_HOME
        Test-Path -LiteralPath $homeDir -PathType Container | Should -BeTrue

        Clear-CtxContext -All

        Test-Path -LiteralPath $homeDir | Should -BeFalse
    }

    It "ctx load: errors when file not found" {
        $previous = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        ctx load (Join-Path $Script:TestTmp 'nonexistent/.ctx')
        $ErrorActionPreference = $previous
        ($Error | Select-Object -First 1).ToString() | Should -Match 'not found'
    }

    It "ctx load: errors when no path given" {
        $previous = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        ctx load
        $ErrorActionPreference = $previous
        ($Error | Select-Object -First 1).ToString() | Should -Match 'requires a path argument'
    }

    It "ctx load: bypasses noautoload but still validates the .ctx file" {
        $proj = Join-Path $env:HOME 'project-ctx-load-invalid'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "noautoload`nbadline-no-colon"

        $previous = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        ctx load (Join-Path $proj '.ctx')
        $ErrorActionPreference = $previous
        ($Error | Select-Object -First 1).ToString() | Should -Match 'invalid .ctx line'
    }

    It 'Mode B: COPILOT_HOME is left exactly as-is across activation and clear' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        New-CtxTestProfile -Name 'test' -Skill 'test-skill' | Out-Null
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'global-user'

        # (a) unset before activation -> still unset after
        Remove-Item Env:\COPILOT_HOME -ErrorAction SilentlyContinue
        ctx review
        $env:COPILOT_HOME | Should -BeNullOrEmpty
        Clear-CtxContext
        $env:COPILOT_HOME | Should -BeNullOrEmpty

        # (b) custom user value byte-identical after activation
        $custom = Join-Path $Script:TestTmp 'custom-home'
        $env:COPILOT_HOME = $custom
        ctx review
        $env:COPILOT_HOME | Should -Be $custom
        Clear-CtxContext
        $env:COPILOT_HOME | Should -Be $custom

        # (c) leftover synthetic home from a prior Mode A activation is untouched
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'synthetic-home'
        ctx review
        $leftover = $env:COPILOT_HOME
        $leftover | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $leftover -PathType Container | Should -BeTrue
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'global-user'
        ctx test
        $env:COPILOT_HOME | Should -Be $leftover

        # clear --all under Mode B: returns $true, COPILOT_HOME unchanged,
        # workspace artifact still cleaned up
        $proj = Join-Path $Script:TestTmp 'project-b-clear-all'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = New-CtxTestProfile -Name 'review2' -Skill 'review-skill'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review2:$reviewDir"
        Set-Location $proj
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Should -BeTrue
        $beforeHome = $env:COPILOT_HOME
        $workspace = Join-Path $proj 'project-b-clear-all.code-workspace'
        Test-Path -LiteralPath $workspace | Should -BeTrue
        Clear-CtxContext -All | Should -BeTrue
        $env:COPILOT_HOME | Should -Be $beforeHome
        Test-Path -LiteralPath $workspace | Should -BeFalse
    }

    It 'Mode B: preserved-COPILOT_HOME warning goes to stderr on success, never otherwise' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'global-user'

        function Invoke-CtxCapturedStderr {
            param([scriptblock]$Action)
            $origError = [Console]::Error
            $writer = [System.IO.StringWriter]::new()
            try {
                [Console]::SetError($writer)
                & $Action
                return $writer.ToString()
            } finally {
                [Console]::SetError($origError)
                $writer.Dispose()
            }
        }

        $warning = 'ctx: warning: global-user mode preserves the existing COPILOT_HOME'

        # (a) COPILOT_HOME unset -> no warning on stderr
        Remove-Item Env:\COPILOT_HOME -ErrorAction SilentlyContinue
        $stderr = Invoke-CtxCapturedStderr { ctx review | Out-Null }
        $stderr | Should -Not -Match $warning

        # (b) COPILOT_HOME present -> exact template on stderr, value untouched
        $customHome = Join-Path $Script:TestTmp 'custom-home'
        $env:COPILOT_HOME = $customHome
        $stderr = Invoke-CtxCapturedStderr { ctx review | Out-Null }
        $env:COPILOT_HOME | Should -Be $customHome
        $stderr | Should -BeExactly ("ctx: warning: global-user mode preserves the existing COPILOT_HOME: `"$customHome`". This may point to a synthetic home from a previous ctx activation." + [Environment]::NewLine)

        # (b2) COPILOT_HOME present-but-empty: where an empty env var is
        # representable (Windows) the exact template fires with empty quotes.
        # On Unix pwsh, assigning '' removes the variable, collapsing to the
        # absent case (bats covers the empty-present template for bash).
        $env:COPILOT_HOME = ''
        $stderr = Invoke-CtxCapturedStderr { ctx review | Out-Null }
        if (Test-Path Env:\COPILOT_HOME) {
            $stderr | Should -BeExactly ("ctx: warning: global-user mode preserves the existing COPILOT_HOME: `"`". This may point to a synthetic home from a previous ctx activation." + [Environment]::NewLine)
        } else {
            $stderr | Should -Not -Match $warning
        }

        # (c) Modes A and C -> no warning on stderr
        $env:COPILOT_HOME = $customHome
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'synthetic-home'
        $stderr = Invoke-CtxCapturedStderr { ctx review | Out-Null }
        $stderr | Should -Not -Match $warning
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'ephemeral-clean'
        $stderr = Invoke-CtxCapturedStderr { ctx review | Out-Null }
        $stderr | Should -Not -Match $warning

        # (d) failed activation -> no warning on stderr
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'bogus'
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        try { $stderr = Invoke-CtxCapturedStderr { ctx review | Out-Null } } finally { $ErrorActionPreference = $prevEap }
        $stderr | Should -Not -Match $warning

        # (e) explicit ctx load under Mode B with COPILOT_HOME present -> warning
        $proj = Join-Path $Script:TestTmp 'project-b-warn'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "review:$reviewDir"
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'global-user'
        $loadHome = Join-Path $Script:TestTmp 'load-home'
        $env:COPILOT_HOME = $loadHome
        $stderr = Invoke-CtxCapturedStderr { ctx load $ctxFile | Out-Null }
        $env:COPILOT_HOME | Should -Be $loadHome
        $stderr | Should -BeExactly ("ctx: warning: global-user mode preserves the existing COPILOT_HOME: `"$loadHome`". This may point to a synthetic home from a previous ctx activation." + [Environment]::NewLine)

        # (f) read-only commands never warn: current and check emit nothing on stderr
        $stderr = Invoke-CtxCapturedStderr { Show-CtxCurrent | Out-Null }
        $stderr | Should -Not -Match $warning
        Set-Location $proj
        $stderr = Invoke-CtxCapturedStderr { Test-CtxActivation | Out-Null }
        $stderr | Should -Not -Match $warning

        # (g) .ctx auto-load under Mode B with COPILOT_HOME present -> warning
        $projAuto = Join-Path $Script:TestTmp 'project-b-warn-auto'
        New-Item -ItemType Directory -Path $projAuto -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $projAuto '.ctx') -Value "review:$reviewDir"
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'global-user'
        $autoHome = Join-Path $Script:TestTmp 'auto-home'
        $env:COPILOT_HOME = $autoHome
        $Script:CtxAutoLoadDir = $null
        Set-Location $projAuto
        $stderr = Invoke-CtxCapturedStderr { Invoke-CtxAutoLoad | Out-Null }
        $env:COPILOT_HOME | Should -Be $autoHome
        $stderr | Should -BeExactly ("ctx: warning: global-user mode preserves the existing COPILOT_HOME: `"$autoHome`". This may point to a synthetic home from a previous ctx activation." + [Environment]::NewLine)
    }

    It 'Mode B: COPILOT_SKILLS_DIRS is unset (not empty) when no skills dirs exist' {
        New-CtxTestProfile -Name 'review' | Out-Null
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'global-user'
        ctx review
        Test-Path Env:\COPILOT_SKILLS_DIRS | Should -BeFalse

        Clear-CtxContext | Out-Null
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'ephemeral-clean'
        ctx review
        Test-Path Env:\COPILOT_SKILLS_DIRS | Should -BeFalse
    }

    It 'Mode B: COPILOT_SKILLS_DIRS keeps stable order and rejects comma paths' {
        $alphaDir = New-CtxTestProfile -Name 'alpha' -Skill 'alpha-skill'
        $betaDir = New-CtxTestProfile -Name 'beta' -Skill 'beta-skill'
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'global-user'

        # (a) existing skills dirs listed in the same stable order as the entries
        ctx alpha beta
        $expected = (Join-Path $alphaDir '.github\skills') + ',' + (Join-Path $betaDir '.github\skills')
        $env:COPILOT_SKILLS_DIRS | Should -Be $expected

        # fully replaced (not appended) on the next activation
        ctx beta
        $env:COPILOT_SKILLS_DIRS | Should -Be (Join-Path $betaDir '.github\skills')

        # (b) a resolved path with a literal comma is rejected before any state change
        $commaDir = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/a,b'
        New-Item -ItemType Directory -Path (Join-Path $commaDir '.github\skills') -Force | Out-Null
        $env:AI_CTX_PROFILES = 'previous'
        $env:COPILOT_HOME = 'previous-home'
        $env:COPILOT_SKILLS_DIRS = 'previous-skills'
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        try { ctx 'a,b' } finally { $ErrorActionPreference = $prevEap }
        ($Error | Select-Object -First 1).ToString() | Should -Match 'comma'
        $env:AI_CTX_PROFILES | Should -Be 'previous'
        $env:COPILOT_HOME | Should -Be 'previous-home'
        $env:COPILOT_SKILLS_DIRS | Should -Be 'previous-skills'
    }

    It 'Mode B/C manual activation keeps its old no-Boolean-pipeline-output behavior; Mode A returns $true' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        New-CtxTestProfile -Name 'test' -Skill 'test-skill' | Out-Null

        # Mode B (global-user): a successful manual activation must not emit
        # any Boolean pipeline value (old behavior retained).
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'global-user'
        $resultB = @(ctx review)
        @($resultB | Where-Object { $_ -is [bool] }).Count | Should -Be 0

        # Mode C (ephemeral-clean): same no-Boolean-pipeline-output guarantee.
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'ephemeral-clean'
        $resultC = @(ctx test)
        @($resultC | Where-Object { $_ -is [bool] }).Count | Should -Be 0

        # Mode A (synthetic-home): the documented $true success value is
        # retained for a successful manual activation.
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'synthetic-home'
        $resultA = ctx review
        $resultA | Should -BeExactly $true
    }

    It 'Mode B/C -> Mode A unsets a session-set COPILOT_SKILLS_DIRS but never a user value' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        New-CtxTestProfile -Name 'test' -Skill 'test-skill' | Out-Null
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'global-user'

        # B activation sets COPILOT_SKILLS_DIRS (ctx-owned this session)
        ctx review
        $env:COPILOT_SKILLS_DIRS | Should -Not -BeNullOrEmpty

        # switch into Mode A -> unset
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'synthetic-home'
        ctx test
        Test-Path Env:\COPILOT_SKILLS_DIRS | Should -BeFalse

        # fresh session state: a user-set value is never touched by Mode A
        $Script:CtxSkillsDirsOwned = $false
        $env:COPILOT_SKILLS_DIRS = 'my-own-value'
        ctx review
        $env:COPILOT_SKILLS_DIRS | Should -Be 'my-own-value'
    }

    It 'Mode C: every activation gets a fresh unique ephemeral home; clear never deletes' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'ephemeral-clean'

        # (a) reactivating the same profile (no clear between) yields a
        # different path, and BOTH ephemeral dirs stay on disk - Mode C never
        # deletes
        ctx review
        $home1 = $env:COPILOT_HOME
        ctx review
        $home2 = $env:COPILOT_HOME
        $home1 | Should -Not -BeNullOrEmpty
        $home2 | Should -Not -BeNullOrEmpty
        $home1 | Should -Not -Be $home2
        Test-Path -LiteralPath $home1 -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $home2 -PathType Container | Should -BeTrue

        # (b) plain ctx clear unsets COPILOT_HOME but leaves home2 + marker on disk
        New-Item -Path (Join-Path $home2 'marker') -ItemType File -Force | Out-Null
        ctx clear | Out-Null
        Test-Path Env:\COPILOT_HOME | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $home2 'marker') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $home2 -PathType Container | Should -BeTrue

        # (c) ctx clear --all reports the retained path, still never deletes,
        # and the common workspace/settings cleanup still runs
        $proj = Join-Path $Script:TestTmp 'project-c-clear-all'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"
        Set-Location $proj
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Should -BeTrue
        $home3 = $env:COPILOT_HOME
        New-Item -Path (Join-Path $home3 'marker') -ItemType File -Force | Out-Null
        $workspace = Join-Path $proj 'project-c-clear-all.code-workspace'
        Test-Path -LiteralPath $workspace -PathType Leaf | Should -BeTrue
        $clearAllOutput = (Clear-CtxContext -All 6>&1 | Out-String)
        Test-Path Env:\COPILOT_HOME | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $home3 'marker') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $home3 -PathType Container | Should -BeTrue
        $clearAllOutput | Should -Match 'retained'
        $clearAllOutput | Should -Match 'not deleted'
        $clearAllOutput | Should -Match ([regex]::Escape($home3))
        $clearAllOutput | Should -Match 'consumes disk'
        $clearAllOutput | Should -Match 'manually removed'
        $clearAllOutput | Should -Match 'responsibility'
        Test-Path -LiteralPath $workspace -PathType Leaf | Should -BeFalse
    }

    # --- Group 5: mode-aware clear/current/check --------------------------

    It 'Group5 5.3: clear per mode - B leaves COPILOT_HOME, C unsets/retains, A deletes, common cleanup runs' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        New-CtxTestProfile -Name 'test' -Skill 'test-skill' | Out-Null

        # Mode A: existing delete behavior remains (--all removes the synthetic home)
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'synthetic-home'
        ctx review | Out-Null
        $aHome = $env:COPILOT_HOME
        Test-Path -LiteralPath $aHome -PathType Container | Should -BeTrue
        ctx clear --all | Out-Null
        Test-Path -LiteralPath $aHome | Should -BeFalse
        Test-Path Env:\COPILOT_HOME | Should -BeFalse

        # Mode B: plain clear and clear --all leave COPILOT_HOME byte-identical
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'global-user'
        $customHome = Join-Path $Script:TestTmp 'b-custom-home'
        $env:COPILOT_HOME = $customHome
        $projB = Join-Path $Script:TestTmp 'project-b-clear'
        New-Item -ItemType Directory -Path $projB -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $projB '.ctx') -Value "review:$reviewDir"
        Set-Location $projB
        ctx load (Join-Path $projB '.ctx') | Out-Null
        $env:COPILOT_HOME | Should -Be $customHome
        ctx clear | Out-Null
        $env:COPILOT_HOME | Should -Be $customHome
        ctx load (Join-Path $projB '.ctx') | Out-Null
        $wsB = Join-Path $projB 'project-b-clear.code-workspace'
        Test-Path -LiteralPath $wsB -PathType Leaf | Should -BeTrue
        ctx clear --all | Out-Null
        $env:COPILOT_HOME | Should -Be $customHome
        Test-Path -LiteralPath $wsB | Should -BeFalse
        Remove-Item Env:\COPILOT_HOME -ErrorAction SilentlyContinue

        # Mode C: plain clear and clear --all unset COPILOT_HOME, retain path +
        # marker, print the retained notice (incl. plain clear), clean common artifacts
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'ephemeral-clean'
        $projC = Join-Path $Script:TestTmp 'project-c-clear'
        New-Item -ItemType Directory -Path $projC -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $projC '.ctx') -Value "review:$reviewDir"
        Set-Location $projC
        ctx load (Join-Path $projC '.ctx') | Out-Null
        $cHome = $env:COPILOT_HOME
        New-Item -Path (Join-Path $cHome 'marker') -ItemType File -Force | Out-Null
        $clearOut = @(& { ctx clear } 6>&1)
        ($clearOut -join "`n") | Should -Match 'retained'
        ($clearOut -join "`n") | Should -Match 'not deleted'
        ($clearOut -join "`n") | Should -Match ([regex]::Escape($cHome))
        ($clearOut -join "`n") | Should -Match 'consumes disk'
        ($clearOut -join "`n") | Should -Match 'manually removed'
        ($clearOut -join "`n") | Should -Match 'responsibility'
        Test-Path Env:\COPILOT_HOME | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $cHome 'marker') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $cHome -PathType Container | Should -BeTrue

        ctx load (Join-Path $projC '.ctx') | Out-Null
        $cHome2 = $env:COPILOT_HOME
        New-Item -Path (Join-Path $cHome2 'marker') -ItemType File -Force | Out-Null
        $wsC = Join-Path $projC 'project-c-clear.code-workspace'
        Test-Path -LiteralPath $wsC -PathType Leaf | Should -BeTrue
        $clearAllOut = @(& { ctx clear --all } 6>&1)
        ($clearAllOut -join "`n") | Should -Match 'retained'
        ($clearAllOut -join "`n") | Should -Match 'consumes disk'
        ($clearAllOut -join "`n") | Should -Match 'manually removed'
        ($clearAllOut -join "`n") | Should -Match 'responsibility'
        Test-Path Env:\COPILOT_HOME | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $cHome2 'marker') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $cHome2 -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $wsC | Should -BeFalse
    }

    It 'Group5 5.4: current/check/clear use the recorded active mode, not a stale selector' {
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        $proj = Join-Path $Script:TestTmp 'project-stale-selector'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "review:$reviewDir"
        Set-Location $proj

        # Mode C activation, then change the selector to Mode B
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'ephemeral-clean'
        ctx load $ctxFile | Out-Null
        $cHome = $env:COPILOT_HOME
        $cHome | Should -Not -BeNullOrEmpty
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'global-user'

        $current = @(& { Show-CtxCurrent } 6>&1)
        ($current -join "`n") | Should -Match 'Mode: C — ephemeral-clean'
        ($current -join "`n") | Should -Not -Match 'Mode: B — global-user'

        $check = @(& { Test-CtxActivation } 6>&1)
        ($check -join "`n") | Should -Match 'CHECK FAIL COPILOT_MODE'
        ($check -join "`n") | Should -Match 'does not match recorded active mode C — ephemeral-clean'

        # clear uses the recorded Mode C: unsets COPILOT_HOME, retains the path
        ctx clear | Out-Null
        Test-Path Env:\COPILOT_HOME | Should -BeFalse
        Test-Path -LiteralPath $cHome -PathType Container | Should -BeTrue

        # Mode B activation, then change the selector to Mode C
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'global-user'
        $bHome = Join-Path $Script:TestTmp 'b-stale-home'
        $env:COPILOT_HOME = $bHome
        ctx load $ctxFile | Out-Null
        $env:COPILOT_HOME | Should -Be $bHome
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'ephemeral-clean'

        $current = @(& { Show-CtxCurrent } 6>&1)
        ($current -join "`n") | Should -Match 'Mode: B — global-user'
        ($current -join "`n") | Should -Not -Match 'Mode: C — ephemeral-clean'

        $check = @(& { Test-CtxActivation } 6>&1)
        ($check -join "`n") | Should -Match 'CHECK FAIL COPILOT_MODE'

        # clear uses the recorded Mode B: COPILOT_HOME is left exactly as-is
        ctx clear | Out-Null
        $env:COPILOT_HOME | Should -Be $bHome
    }

    It 'Group5 5.5: check per mode - B recorded-home, C path-exists, SKIPs, unknown foreign state' {
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        $proj = Join-Path $Script:TestTmp 'project-check-modes'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "review:$reviewDir"

        # (a) no .ctx remains a successful no-op
        $noctx = Join-Path $Script:TestTmp 'noctx'
        New-Item -ItemType Directory -Path $noctx -Force | Out-Null
        Set-Location $noctx
        $noop = @(& { Test-CtxActivation } 6>&1)
        ($noop -join "`n") | Should -Match 'no .ctx file found'
        ($noop -join "`n") | Should -Match 'True'

        Set-Location $proj
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'global-user'

        # (b) Mode B originally-unset: PASS; drift -> FAIL; link/skill checks SKIP
        Remove-Item Env:\COPILOT_HOME -ErrorAction SilentlyContinue
        Import-CtxFile -CtxFile $ctxFile | Out-Null
        $ok = @(& { Test-CtxActivation } 6>&1)
        ($ok -join "`n") | Should -Match 'CHECK PASS COPILOT_HOME'
        ($ok -join "`n") | Should -Match 'CHECK SKIP link:settings.json'
        ($ok -join "`n") | Should -Match 'CHECK SKIP skill:review-skill'
        ($ok -join "`n") | Should -Match 'ctx check: PASS'

        $env:COPILOT_HOME = Join-Path $Script:TestTmp 'drift-home'
        $fail = @(& { Test-CtxActivation } 6>&1)
        ($fail -join "`n") | Should -Match 'CHECK FAIL COPILOT_HOME'
        Remove-Item Env:\COPILOT_HOME -ErrorAction SilentlyContinue

        # (c) Mode B originally-set: PASS when exact, FAIL on change
        $env:COPILOT_HOME = Join-Path $Script:TestTmp 'b-home'
        Import-CtxFile -CtxFile $ctxFile | Out-Null
        $ok = @(& { Test-CtxActivation } 6>&1)
        ($ok -join "`n") | Should -Match 'CHECK PASS COPILOT_HOME'
        $env:COPILOT_HOME = Join-Path $Script:TestTmp 'b-home-changed'
        $fail = @(& { Test-CtxActivation } 6>&1)
        ($fail -join "`n") | Should -Match 'CHECK FAIL COPILOT_HOME'
        Remove-Item Env:\COPILOT_HOME -ErrorAction SilentlyContinue

        # (d) Mode C: real dir PASS; removed FAIL; symlink FAIL; never inspects contents
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'ephemeral-clean'
        Import-CtxFile -CtxFile $ctxFile | Out-Null
        $cHome = $env:COPILOT_HOME
        Set-Content -LiteralPath (Join-Path $cHome 'content-file') -Value 'x'
        $ok = @(& { Test-CtxActivation } 6>&1)
        ($ok -join "`n") | Should -Match 'CHECK PASS COPILOT_HOME'
        ($ok -join "`n") | Should -Match 'CHECK SKIP link:settings.json'
        ($ok -join "`n") | Should -Match 'CHECK SKIP skill:review-skill'
        Test-Path -LiteralPath (Join-Path $cHome 'content-file') -PathType Leaf | Should -BeTrue

        Remove-Item -LiteralPath $cHome -Recurse -Force
        $fail = @(& { Test-CtxActivation } 6>&1)
        ($fail -join "`n") | Should -Match 'CHECK FAIL COPILOT_HOME'

        Import-CtxFile -CtxFile $ctxFile | Out-Null
        $cHome2 = $env:COPILOT_HOME
        Remove-Item -LiteralPath $cHome2 -Recurse -Force
        $target = Join-Path $Script:TestTmp 'c-target'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        New-Item -ItemType SymbolicLink -Path $cHome2 -Target $target -Force | Out-Null
        $fail = @(& { Test-CtxActivation } 6>&1)
        ($fail -join "`n") | Should -Match 'CHECK FAIL COPILOT_HOME'

        # (e) foreign env state with no matching activation record -> CHECK UNKNOWN,
        # never deleted, unknown alone does not become a false FAIL
        $foreignHome = Join-Path $Script:TestTmp 'foreign-home'
        $foreignSkills = Join-Path $Script:TestTmp 'foreign-skills'
        New-Item -ItemType Directory -Path $foreignHome, $foreignSkills -Force | Out-Null
        Import-CtxFile -CtxFile $ctxFile | Out-Null
        Reset-CtxActiveRecord
        $env:COPILOT_HOME = $foreignHome
        $env:COPILOT_SKILLS_DIRS = $foreignSkills
        $current = @(& { Show-CtxCurrent } 6>&1)
        ($current -join "`n") | Should -Match 'Mode: <unknown>'
        ($current -join "`n") | Should -Match ([regex]::Escape("COPILOT_HOME=$foreignHome (unknown)"))
        $check = @(& { Test-CtxActivation } 6>&1)
        ($check -join "`n") | Should -Match 'CHECK UNKNOWN COPILOT_MODE'
        ($check -join "`n") | Should -Match 'CHECK UNKNOWN COPILOT_HOME'
        ($check -join "`n") | Should -Match 'CHECK UNKNOWN COPILOT_SKILLS_DIRS'
        Test-Path -LiteralPath $foreignHome -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $foreignSkills -PathType Container | Should -BeTrue
    }

    It 'Group5 5.6: Mode C replacement reports retained path only on success; old path remains' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        New-CtxTestProfile -Name 'test' -Skill 'test-skill' | Out-Null
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'ephemeral-clean'

        # C -> C (same profile reactivated): notice for the old path, old dir kept
        ctx review | Out-Null
        $oldHome = $env:COPILOT_HOME
        New-Item -Path (Join-Path $oldHome 'marker') -ItemType File -Force | Out-Null
        $replCc = @(& { ctx review } 6>&1)
        ($replCc -join "`n") | Should -Match 'retained'
        ($replCc -join "`n") | Should -Match ([regex]::Escape($oldHome))
        ($replCc -join "`n") | Should -Match 'consumes disk'
        ($replCc -join "`n") | Should -Match 'manually removed'
        ($replCc -join "`n") | Should -Match 'responsibility'
        Test-Path -LiteralPath (Join-Path $oldHome 'marker') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $oldHome -PathType Container | Should -BeTrue
        $newHome = $env:COPILOT_HOME
        $newHome | Should -Not -Be $oldHome

        # C -> B (switch selector): notice for the old path, COPILOT_HOME kept as-is
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'global-user'
        $replCb = @(& { ctx test } 6>&1)
        ($replCb -join "`n") | Should -Match 'retained'
        ($replCb -join "`n") | Should -Match ([regex]::Escape($newHome))
        ($replCb -join "`n") | Should -Match 'consumes disk'
        ($replCb -join "`n") | Should -Match 'manually removed'
        ($replCb -join "`n") | Should -Match 'responsibility'
        $env:COPILOT_HOME | Should -Be $newHome
        Test-Path -LiteralPath $newHome -PathType Container | Should -BeTrue

        # Failed replacement: temp-home creation fails, no notice, state + record intact
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'ephemeral-clean'
        Mock New-CtxEphemeralCopilotHome { throw 'simulated temp-home failure' }
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        $failed = @(& { ctx test } 6>&1)
        $ErrorActionPreference = $prevEap
        ($failed -join "`n") | Should -Not -Match 'retained'
        ($Error | Select-Object -First 1).ToString() | Should -Match 'temp-home failure'
        $env:AI_CTX_PROFILES | Should -Be 'test'
        $env:COPILOT_HOME | Should -Be $newHome
        $Script:CtxActiveMode | Should -Be 'global-user'
        $Script:CtxActiveContext | Should -Be 'test'
    }

    It 'Group5 5.7a: Mode C temp-home failure (manual entry) leaves env and session record untouched' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        New-CtxTestProfile -Name 'test' -Skill 'test-skill' | Out-Null
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'ephemeral-clean'

        ctx review | Out-Null
        $oldProfiles = $env:AI_CTX_PROFILES
        $oldDirs = $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS
        $oldHome = $env:COPILOT_HOME
        Mock New-CtxEphemeralCopilotHome { throw 'simulated temp-home failure' }
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        try { ctx test } finally { $ErrorActionPreference = $prevEap }
        ($Error | Select-Object -First 1).ToString() | Should -Match 'temp-home failure'
        $env:AI_CTX_PROFILES | Should -Be $oldProfiles
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be $oldDirs
        $env:COPILOT_HOME | Should -Be $oldHome
        $Script:CtxActiveMode | Should -Be 'ephemeral-clean'
        $Script:CtxActiveHomeValue | Should -Be $oldHome
    }

    It 'Group5 5.7b: Mode C temp-home failure (load entry) leaves env, record, and workspace files untouched' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $proj = Join-Path $Script:TestTmp 'project-c-preflight'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'ephemeral-clean'
        Set-Location $proj

        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Should -BeTrue
        $lProfiles = $env:AI_CTX_PROFILES
        $lDirs = $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS
        $lHome = $env:COPILOT_HOME
        $ws = Join-Path $proj 'project-c-preflight.code-workspace'
        Test-Path -LiteralPath $ws -PathType Leaf | Should -BeTrue
        $wsBefore = (Get-Item -LiteralPath $ws -Force).LastWriteTimeUtc

        Mock New-CtxEphemeralCopilotHome { throw 'simulated temp-home failure' }
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        $result = $null
        try { $result = Import-CtxFile -CtxFile (Join-Path $proj '.ctx') } finally { $ErrorActionPreference = $prevEap }
        $result | Should -BeFalse
        $env:AI_CTX_PROFILES | Should -Be $lProfiles
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be $lDirs
        $env:COPILOT_HOME | Should -Be $lHome
        $Script:CtxActiveMode | Should -Be 'ephemeral-clean'
        $Script:CtxActiveHomeValue | Should -Be $lHome
        (Get-Item -LiteralPath $ws -Force).LastWriteTimeUtc | Should -Be $wsBefore
    }

    It 'Group5 5.8: Clear-CtxContext -All with no activation record treats home as unknown and never deletes' {
        New-CtxTestProfile -Name 'review' | Out-Null
        $proj = Join-Path $Script:TestTmp 'project-clear-unknown'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"
        # Foreign context whose COPILOT_HOME happens to equal the otherwise-computed
        # synthetic-home path, but with NO ctx activation record: clear must not
        # guess Mode A or delete it.
        $foreignHome = Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'review'
        New-Item -ItemType Directory -Path $foreignHome -Force | Out-Null
        New-Item -Path (Join-Path $foreignHome 'marker') -ItemType File -Force | Out-Null
        $workspace = Join-Path $proj 'project-clear-unknown.code-workspace'
        Set-Content -LiteralPath $workspace -Value '{"generatedBy":"ctx"}'
        $env:AI_CTX_PROFILES = 'review'
        $env:COPILOT_HOME = $foreignHome
        $Script:CtxAutoLoadDir = $proj

        $clearOutput = @(& { Clear-CtxContext -All } 3>&1 6>&1)
        ($clearOutput -join "`n") | Should -Match 'unknown'
        ($clearOutput -join "`n") | Should -Match 'no matching activation record'
        ($clearOutput -join "`n") | Should -Not -Match 'synthetic-home'
        Test-Path -LiteralPath $foreignHome -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $foreignHome 'marker') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $workspace | Should -BeFalse
    }

    It 'Group5 5.9: Mode C owns COPILOT_SKILLS_DIRS across clear and Mode A switch' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        New-CtxTestProfile -Name 'test' | Out-Null
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'ephemeral-clean'

        # C activation with actual skills: the var is set and ctx-owned
        ctx review | Out-Null
        $env:COPILOT_SKILLS_DIRS | Should -Not -BeNullOrEmpty
        $Script:CtxSkillsDirsOwned | Should -BeTrue

        # ctx clear unsets the owned var and resets the flag
        ctx clear | Out-Null
        Test-Path Env:\COPILOT_SKILLS_DIRS | Should -BeFalse
        $Script:CtxSkillsDirsOwned | Should -BeFalse

        # re-activate C, then switch into Mode A: the owned var is unset
        ctx review | Out-Null
        $env:COPILOT_SKILLS_DIRS | Should -Not -BeNullOrEmpty
        $Script:CtxSkillsDirsOwned | Should -BeTrue
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'synthetic-home'
        ctx test | Out-Null
        Test-Path Env:\COPILOT_SKILLS_DIRS | Should -BeFalse
        $Script:CtxSkillsDirsOwned | Should -BeFalse

        # B/C ownership is flag-true even when no skills dirs exist (var unset)
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'ephemeral-clean'
        Clear-CtxContext | Out-Null
        ctx test | Out-Null
        Test-Path Env:\COPILOT_SKILLS_DIRS | Should -BeFalse
        $Script:CtxSkillsDirsOwned | Should -BeTrue

        $env:AI_CTX_PROFILES_COPILOT_MODE = 'global-user'
        Clear-CtxContext | Out-Null
        ctx test | Out-Null
        Test-Path Env:\COPILOT_SKILLS_DIRS | Should -BeFalse
        $Script:CtxSkillsDirsOwned | Should -BeTrue
    }

    # --- Group 5 remediation (PR #45 review): findings 1-5 ------------------

    It 'Group5 6.1: Mode C changed/unset/foreign COPILOT_HOME is not misattributed' {
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        $proj = Join-Path $Script:TestTmp 'project-c-home-drift'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "review:$reviewDir"
        Set-Location $proj
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'ephemeral-clean'
        Import-CtxFile -CtxFile $ctxFile | Out-Null
        $recHome = $env:COPILOT_HOME
        New-Item -Path (Join-Path $recHome 'marker') -ItemType File -Force | Out-Null

        # (a) changed value: current reports unknown, check FAILs, clear
        # preserves the user's value while still reporting the recorded path
        $userReplacement = Join-Path $Script:TestTmp 'user-replacement'
        $env:COPILOT_HOME = $userReplacement
        $current = @(& { Show-CtxCurrent } 6>&1)
        ($current -join "`n") | Should -Match 'Mode: <unknown>'
        $check = @(& { Test-CtxActivation } 6>&1)
        ($check -join "`n") | Should -Match 'CHECK FAIL COPILOT_HOME'
        $clearOut = @(& { Clear-CtxContext } 3>&1 6>&1)
        ($clearOut -join "`n") | Should -Match 'retained'
        ($clearOut -join "`n") | Should -Match 'changed'
        $env:COPILOT_HOME | Should -Be $userReplacement
        Test-Path -LiteralPath (Join-Path $recHome 'marker') -PathType Leaf | Should -BeTrue

        # (b) unset value: check FAILs, clear leaves it unset but reports retained
        Import-CtxFile -CtxFile $ctxFile | Out-Null
        $recHome2 = $env:COPILOT_HOME
        Remove-Item Env:\COPILOT_HOME -ErrorAction SilentlyContinue
        $check = @(& { Test-CtxActivation } 6>&1)
        ($check -join "`n") | Should -Match 'CHECK FAIL COPILOT_HOME'
        $clearOut = @(& { Clear-CtxContext } 3>&1 6>&1)
        ($clearOut -join "`n") | Should -Match 'retained'
        Test-Path Env:\COPILOT_HOME | Should -BeFalse
        Test-Path -LiteralPath $recHome2 -PathType Container | Should -BeTrue

        # (c) foreign replacement: check FAILs, clear preserves the foreign dir,
        # and neither the recorded path nor the foreign path is deleted
        Import-CtxFile -CtxFile $ctxFile | Out-Null
        $recHome3 = $env:COPILOT_HOME
        $foreign = Join-Path $Script:TestTmp 'foreign-replacement'
        New-Item -ItemType Directory -Path $foreign -Force | Out-Null
        $env:COPILOT_HOME = $foreign
        $check = @(& { Test-CtxActivation } 6>&1)
        ($check -join "`n") | Should -Match 'CHECK FAIL COPILOT_HOME'
        $clearOut = @(& { Clear-CtxContext } 3>&1 6>&1)
        ($clearOut -join "`n") | Should -Match 'retained'
        $env:COPILOT_HOME | Should -Be $foreign
        Test-Path -LiteralPath $foreign -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $recHome3 -PathType Container | Should -BeTrue
    }

    It 'Group5 6.2: Mode C ephemeral COPILOT_HOME is owner-only on non-Windows' {
        if ($IsWindows -or $env:OS -ceq 'Windows_NT') {
            Set-ItResult -Skipped -Because 'Windows relies on the per-user temp parent ACL'
            return
        }
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'ephemeral-clean'
        ctx review | Out-Null
        $effective = [System.IO.File]::GetUnixFileMode($env:COPILOT_HOME)
        $expected = [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor [System.IO.UnixFileMode]::UserExecute
        $effective | Should -Be $expected
    }

    It 'Group5 6.3: Mode A comma-containing skills paths still activate' {
        $commaDir = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/a,b'
        New-Item -ItemType Directory -Path (Join-Path $commaDir '.github\skills') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $commaDir '.github\instructions') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $commaDir '.github/instructions/a,b.instructions.md') -Value '# a,b'
        Remove-Item Env:\AI_CTX_PROFILES_COPILOT_MODE -ErrorAction SilentlyContinue
        ctx 'a,b' | Out-Null
        $env:AI_CTX_PROFILES | Should -Be 'a,b'
        Test-Path Env:\COPILOT_SKILLS_DIRS | Should -BeFalse
        Clear-CtxContext | Out-Null
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'synthetic-home'
        ctx 'a,b' | Out-Null
        $env:AI_CTX_PROFILES | Should -Be 'a,b'
        Test-Path Env:\COPILOT_SKILLS_DIRS | Should -BeFalse

        # .ctx direct-path entry whose resolved path contains a literal comma
        # (non-comma label): Mode A must load it and leave COPILOT_SKILLS_DIRS
        # untouched/unset under both unset selector and explicit synthetic-home.
        $dotctxDir = Join-Path $Script:TestTmp 'comma,dir'
        New-Item -ItemType Directory -Path (Join-Path $dotctxDir '.github\skills') -Force | Out-Null
        $proj = Join-Path $Script:TestTmp 'project-comma-ctx'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "review:$dotctxDir"
        $expectedHome = Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'review'

        Clear-CtxContext | Out-Null
        Remove-Item Env:\AI_CTX_PROFILES_COPILOT_MODE -ErrorAction SilentlyContinue
        Import-CtxFile -CtxFile $ctxFile | Should -BeTrue
        $env:AI_CTX_PROFILES | Should -Be 'review'
        $env:COPILOT_HOME | Should -Be $expectedHome
        Test-Path Env:\COPILOT_SKILLS_DIRS | Should -BeFalse

        Clear-CtxContext | Out-Null
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'synthetic-home'
        Import-CtxFile -CtxFile $ctxFile | Should -BeTrue
        $env:AI_CTX_PROFILES | Should -Be 'review'
        $env:COPILOT_HOME | Should -Be $expectedHome
        Test-Path Env:\COPILOT_SKILLS_DIRS | Should -BeFalse
    }

    It 'Group5 6.4: B/C skills ownership preserves a later user value on clear and Mode A switch' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        New-CtxTestProfile -Name 'test' | Out-Null

        # (a) ctx set the var (B); user replaces it; clear preserves the user value
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'global-user'
        ctx review | Out-Null
        $env:COPILOT_SKILLS_DIRS | Should -Not -BeNullOrEmpty
        $env:COPILOT_SKILLS_DIRS = 'user-own-value'
        ctx clear | Out-Null
        $env:COPILOT_SKILLS_DIRS | Should -Be 'user-own-value'

        # (b) ctx left it unset (C, no skills); user later sets a value; clear preserves it
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'ephemeral-clean'
        ctx test | Out-Null
        Test-Path Env:\COPILOT_SKILLS_DIRS | Should -BeFalse
        $env:COPILOT_SKILLS_DIRS = 'user-own-value'
        ctx clear | Out-Null
        $env:COPILOT_SKILLS_DIRS | Should -Be 'user-own-value'

        # (c) ctx set the var (C); Mode A switch unsets it since still matching
        Clear-CtxContext | Out-Null
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'ephemeral-clean'
        ctx review | Out-Null
        $env:COPILOT_SKILLS_DIRS | Should -Not -BeNullOrEmpty
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'synthetic-home'
        ctx test | Out-Null
        Test-Path Env:\COPILOT_SKILLS_DIRS | Should -BeFalse

        # (d) ctx set the var (C); user replaces it; Mode A switch preserves it
        Clear-CtxContext | Out-Null
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'ephemeral-clean'
        ctx review | Out-Null
        $env:COPILOT_SKILLS_DIRS = 'user-own-value'
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'synthetic-home'
        ctx test | Out-Null
        $env:COPILOT_SKILLS_DIRS | Should -Be 'user-own-value'
    }

    It 'Group5 6.5: check audits COPILOT_SKILLS_DIRS in Mode B/C' {
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        New-CtxTestProfile -Name 'test' | Out-Null
        $proj = Join-Path $Script:TestTmp 'project-check-skills'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "review:$reviewDir"
        Set-Location $proj
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'global-user'

        # (a) expected value -> PASS
        Import-CtxFile -CtxFile $ctxFile | Out-Null
        $ok = @(& { Test-CtxActivation } 6>&1)
        ($ok -join "`n") | Should -Match 'CHECK PASS COPILOT_SKILLS_DIRS'
        ($ok -join "`n") | Should -Match 'ctx check: PASS'

        # (b) missing value -> FAIL
        Remove-Item Env:\COPILOT_SKILLS_DIRS -ErrorAction SilentlyContinue
        $fail = @(& { Test-CtxActivation } 6>&1)
        ($fail -join "`n") | Should -Match 'CHECK FAIL COPILOT_SKILLS_DIRS'

        # (c) wrong value -> FAIL
        $env:COPILOT_SKILLS_DIRS = 'wrong-value'
        $fail = @(& { Test-CtxActivation } 6>&1)
        ($fail -join "`n") | Should -Match 'CHECK FAIL COPILOT_SKILLS_DIRS'
        Remove-Item Env:\COPILOT_SKILLS_DIRS -ErrorAction SilentlyContinue

        # (d) unexpected value when no skills dirs exist (Mode C) -> FAIL
        $testDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'test'
        Set-Content -LiteralPath $ctxFile -Value "test:$testDir"
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'ephemeral-clean'
        Import-CtxFile -CtxFile $ctxFile | Out-Null
        Test-Path Env:\COPILOT_SKILLS_DIRS | Should -BeFalse
        $env:COPILOT_SKILLS_DIRS = 'unexpected-value'
        $fail = @(& { Test-CtxActivation } 6>&1)
        ($fail -join "`n") | Should -Match 'CHECK FAIL COPILOT_SKILLS_DIRS'
    }

    # --- Group 7: ctx skills (read-only potential-skill-discovery inventory) --
    # `ctx skills` inventories candidate skill directories from the filesystem
    # and configuration. It never claims skills are loaded/invoked, never
    # invokes the Copilot CLI, and never modifies settings, files, or the
    # environment. Each candidate carries one classification (precedence:
    # ctx-profile > expected-home > external) while all origins are retained.

    It 'ctx skills: read-only inventory of candidate skill dirs with origins, dedup, and missing paths' {
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        $proj = Join-Path $Script:TestTmp 'project-skills-inventory'
        New-Item -ItemType Directory -Path (Join-Path $proj '.github\copilot'), (Join-Path $proj '.agents\skills\custom'), (Join-Path $proj '.github\skills\repo-skill'), (Join-Path $proj '.claude\skills\claude-skill') -Force | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "review:$reviewDir"
        Set-Location $proj

        # Active Mode A context so ctx-owned provenance is attributable.
        Import-CtxFile -CtxFile $ctxFile | Out-Null
        $homeSkills = Join-Path $env:COPILOT_HOME 'skills'
        Test-Path -LiteralPath $homeSkills -PathType Container | Should -BeTrue

        # Configured entries: COPILOT_SKILLS_DIRS (an existing dot-segment alias of
        # the active profile skills dir, the repo .github/skills dir itself,
        # and a missing dir) and skillDirectories in a repo settings file (one
        # existing skill dir, one missing), plus an observable installed-plugin
        # skills subdir. One row must retain multiple distinct source origins,
        # including two external-class origins.
        $profileSkills = Join-Path $reviewDir '.github\skills'
        $profileSkillsAlias = Join-Path $reviewDir '.github\.\skills'
        $repoGithubSkills = Join-Path $proj '.github\skills'
        $env:COPILOT_SKILLS_DIRS = "$profileSkillsAlias,$repoGithubSkills,$(Join-Path $Script:TestTmp 'missing-skills-dir')"
        # Serialize via ConvertTo-Json so backslashes in Windows paths are
        # escaped correctly; hand-interpolated JSON would be invalid there and
        # silently drop skillDirectories.
        $settings = @{ skillDirectories = @((Join-Path $profileSkills 'review-skill'), (Join-Path $Script:TestTmp 'missing-from-settings')) }
        Set-Content -LiteralPath (Join-Path $proj '.github\copilot\settings.json') -Value ($settings | ConvertTo-Json -Compress)
        New-Item -ItemType Directory -Path (Join-Path $env:CTX_COPILOT_DIR 'installed-plugins\my-plugin\skills\pskill'), (Join-Path $env:CTX_COPILOT_DIR 'installed-plugins\no-skill') -Force | Out-Null

        $beforeEnv = @($env:AI_CTX_PROFILES, $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS, $env:COPILOT_HOME, $env:COPILOT_SKILLS_DIRS)

        $out = @(& { ctx skills } 6>&1)
        ($out -join "`n") | Should -Match ([regex]::Escape('[ctx skills] potential Copilot skill discovery'))
        ($out -join "`n") | Should -Match 'ctx does not claim these skills are loaded or invoked'

        # ctx-profile candidate from the active profile is reported exactly
        # once, retaining the distinct external-class origin from
        # COPILOT_SKILLS_DIRS (dedup via normalization of the dot-segment
        # alias), and ctx-profile wins as the classification. Proven by
        # case-sensitive ordinal counting, not -Match (which is
        # case-insensitive and would not prove "exactly one row").
        $text = $out -join "`n"
        $profileSkillsRow = "candidate: $profileSkills (classification: ctx-profile, origins: copilot-skill-dirs,ctx-profile)"
        $text.IndexOf($profileSkillsRow, [System.StringComparison]::Ordinal) | Should -Not -Be -1
        $needle = "candidate: $profileSkills ("
        $count = 0
        $idx = 0
        while (($idx = $text.IndexOf($needle, $idx, [System.StringComparison]::Ordinal)) -ge 0) {
            $count++
            $idx += $needle.Length
        }
        $count | Should -Be 1

        # expected-home candidate (the active Mode A COPILOT_HOME/skills).
        ($out -join "`n") | Should -Match ([regex]::Escape("candidate: $homeSkills (classification: expected-home, origins: expected-home)"))

        # external candidates: repo .github/skills (found by repository
        # discovery AND COPILOT_SKILLS_DIRS -> two external-class origins),
        # .agents/skills, and .claude/skills, plugin skill dir, configured
        # skillDirectories entry that exists.
        ($out -join "`n") | Should -Match ([regex]::Escape("candidate: $repoGithubSkills (classification: external, origins: copilot-skill-dirs,repo-github-skills)"))
        ($out -join "`n") | Should -Match ([regex]::Escape("candidate: $(Join-Path $proj '.agents\skills') (classification: external, origins: repo-agents-skills)"))
        ($out -join "`n") | Should -Match ([regex]::Escape("candidate: $(Join-Path $proj '.claude\skills') (classification: external, origins: repo-claude-skills)"))
        ($out -join "`n") | Should -Match ([regex]::Escape("candidate: $(Join-Path $env:CTX_COPILOT_DIR 'installed-plugins\my-plugin\skills') (classification: external, origins: plugin-skills)"))
        ($out -join "`n") | Should -Match ([regex]::Escape("candidate: $(Join-Path $profileSkills 'review-skill') (classification: external, origins: settings-skill-dirs)"))

        # Configured-but-missing paths are reported, not failed, and the
        # plugins root itself is never a candidate.
        ($out -join "`n") | Should -Match ([regex]::Escape("missing: $(Join-Path $Script:TestTmp 'missing-skills-dir') (classification: external, origins: copilot-skill-dirs)"))
        ($out -join "`n") | Should -Match ([regex]::Escape("missing: $(Join-Path $Script:TestTmp 'missing-from-settings') (classification: external, origins: settings-skill-dirs)"))
        ($out -join "`n") | Should -Not -Match ([regex]::Escape("candidate: $(Join-Path $env:CTX_COPILOT_DIR 'installed-plugins') ("))
        ($out -join "`n") | Should -Not -Match ([regex]::Escape("candidate: $(Join-Path $env:CTX_COPILOT_DIR 'installed-plugins\no-skill') ("))

        # Boundary disclosures.
        ($out -join "`n") | Should -Match 'not observable: command-line arguments of another Copilot process'
        ($out -join "`n") | Should -Match 'not observable: skill locations inside installed Copilot plugins'
        ($out -join "`n") | Should -Match 'no Copilot CLI probe performed'

        # Strictly read-only: environment and files are untouched.
        $afterEnv = @($env:AI_CTX_PROFILES, $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS, $env:COPILOT_HOME, $env:COPILOT_SKILLS_DIRS)
        $afterEnv | Should -Be $beforeEnv
        Test-Path -LiteralPath $homeSkills -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $proj '.github\skills') -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $proj '.agents\skills\custom') -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $proj '.claude\skills') -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $proj '.github\copilot\settings.json') -PathType Leaf | Should -BeTrue
    }

    It 'ctx skills: case-only path variants stay distinct on case-sensitive platforms, dedup on Windows' {
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        $proj = Join-Path $Script:TestTmp 'project-skills-case'
        New-Item -ItemType Directory -Path (Join-Path $proj '.github\skills'), (Join-Path $proj '.github\Skills') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"
        Set-Location $proj
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null

        # COPILOT_SKILLS_DIRS names the same repo .github/skills location under
        # a case-only variant, so the inventory's path-key comparison decides
        # whether they collapse (Windows) or stay two rows (Linux/macOS).
        $lower = Join-Path $proj '.github\skills'
        $upper = Join-Path $proj '.github\Skills'
        $env:COPILOT_SKILLS_DIRS = "$lower,$upper"

        $out = @(& { ctx skills } 6>&1)
        $text = $out -join "`n"

        # Both variants exist as directories on this platform (on a
        # case-insensitive filesystem the upper variant resolves to the same
        # directory, which is exactly the collision under test).
        Test-Path -LiteralPath $lower -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $upper -PathType Container | Should -BeTrue

        $lowerRow = "candidate: $lower (classification: external, origins: copilot-skill-dirs,repo-github-skills)"
        $upperRow = "candidate: $upper (classification: external, origins: copilot-skill-dirs)"

        # -Match/-Not -Match are case-insensitive even on Windows, so they would
        # let the upper-case variant match a lower-case row. Use Ordinal
        # case-sensitive substring checks instead.
        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            # Windows: case-insensitive path keys collapse to exactly one
            # deduped row (the first-added lower-case key), classification/
            # origins retained; the upper-case variant is not a distinct row.
            $text.IndexOf($lowerRow, [System.StringComparison]::Ordinal) | Should -Not -Be -1
            $text.IndexOf($upperRow, [System.StringComparison]::Ordinal) | Should -Be -1
            $needle = "candidate: $lower ("
            $count = 0
            $idx = 0
            while (($idx = $text.IndexOf($needle, $idx, [System.StringComparison]::Ordinal)) -ge 0) {
                $count++
                $idx += $needle.Length
            }
            $count | Should -Be 1
        } else {
            # Linux/macOS: case-sensitive path keys keep two distinct rows,
            # each with its own classification/origins.
            $text.IndexOf($lowerRow, [System.StringComparison]::Ordinal) | Should -Not -Be -1
            $text.IndexOf($upperRow, [System.StringComparison]::Ordinal) | Should -Not -Be -1
        }
    }

    It 'ctx skills: path normalization strips trailing separators but preserves roots' {
        # Filesystem roots (drive root, UNC share root, /) are never stripped
        # down to a bare drive/empty string.
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetTempPath())
        Get-CtxSkillPathNormalized -Path $root | Should -BeExactly $root

        # Windows drive root explicitly: C:\ must stay C:\ (never C:) whether
        # spelled with a forward or backward slash.
        if ($IsWindows -or $env:OS -ceq 'Windows_NT') {
            Get-CtxSkillPathNormalized -Path 'C:\' | Should -BeExactly 'C:\'
            Get-CtxSkillPathNormalized -Path 'C:/' | Should -BeExactly 'C:\'
        }

        # A non-root directory normalizes to itself whether or not it is
        # spelled with a trailing separator.
        $base = Join-Path $Script:TestTmp 'norm-trailing'
        New-Item -ItemType Directory -Path $base -Force | Out-Null
        Get-CtxSkillPathNormalized -Path $base | Should -BeExactly $base
        Get-CtxSkillPathNormalized -Path ($base + [System.IO.Path]::DirectorySeparatorChar) | Should -BeExactly $base
    }

    It 'ctx skills: duplicate configured paths differing only by a trailing separator dedup to one row' {
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        $proj = Join-Path $Script:TestTmp 'project-skills-trailing-sep'
        New-Item -ItemType Directory -Path (Join-Path $proj '.github\skills') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"
        Set-Location $proj
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null

        # Same directory listed with and without a trailing separator.
        $skillsDir = Join-Path $proj '.github\skills'
        $env:COPILOT_SKILLS_DIRS = "$skillsDir,$skillsDir$([System.IO.Path]::DirectorySeparatorChar)"
        $beforeEnv = @($env:AI_CTX_PROFILES, $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS, $env:COPILOT_HOME, $env:COPILOT_SKILLS_DIRS)

        $out = @(& { ctx skills } 6>&1)
        $text = $out -join "`n"

        # Exactly one row, proven by case-sensitive ordinal counting; both
        # external-class origins (repository discovery + COPILOT_SKILLS_DIRS)
        # are retained.
        $row = "candidate: $skillsDir (classification: external, origins: copilot-skill-dirs,repo-github-skills)"
        $text.IndexOf($row, [System.StringComparison]::Ordinal) | Should -Not -Be -1
        $needle = "candidate: $skillsDir ("
        $count = 0
        $idx = 0
        while (($idx = $text.IndexOf($needle, $idx, [System.StringComparison]::Ordinal)) -ge 0) {
            $count++
            $idx += $needle.Length
        }
        $count | Should -Be 1

        # Strictly read-only: environment is untouched.
        $afterEnv = @($env:AI_CTX_PROFILES, $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS, $env:COPILOT_HOME, $env:COPILOT_SKILLS_DIRS)
        $afterEnv | Should -Be $beforeEnv
    }

    It 'ctx skills: unknown provenance does not guess ctx-owned paths' {
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        $proj = Join-Path $Script:TestTmp 'project-skills-unknown'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"
        Set-Location $proj

        # A context that is set in the environment but has NO matching session
        # activation record: ctx-owned paths must not be guessed.
        $env:AI_CTX_PROFILES = 'review'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS = $reviewDir
        Reset-CtxActiveRecord

        $out = @(& { ctx skills } 6>&1)
        ($out -join "`n") | Should -Match 'unknown: no matching ctx session activation record; ctx-owned paths are not guessed'
        ($out -join "`n") | Should -Not -Match ([regex]::Escape("candidate: $(Join-Path $reviewDir '.github\skills')"))
        ($out -join "`n") | Should -Not -Match 'classification: ctx-profile'
    }

    # --- Issue #40: Mode A skill-name collision reconciliation ---------------
    # Skill names are compared case-insensitively (COPILOT_HOME targets are
    # case-insensitive on Windows), so two source dirs contributing "foo" and
    # "Foo" collide; the whole colliding group is skipped and the collision is
    # diagnosed on activation and reported as CHECK FAIL by ctx check.

    It 'Issue40: exact-name skill collision is diagnosed, skipped, and check fails' {
        $proj = Join-Path $Script:TestTmp 'project-issue40-exact'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'shared-skill'
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $securityDir = New-CtxTestProfile -Name 'security' -Skill 'shared-skill'
        New-CtxTestProfile -Name 'security' -Skill 'security-skill' | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "review:$reviewDir`nsecurity:$securityDir"
        Set-Location $proj

        $activation = @(& { Import-CtxFile -CtxFile $ctxFile } 3>&1 6>&1)
        ($activation -join "`n") | Should -Match 'collision'
        ($activation -join "`n") | Should -Match 'shared-skill'
        ($activation -join "`n") | Should -Match ([regex]::Escape($reviewDir))
        ($activation -join "`n") | Should -Match ([regex]::Escape($securityDir))
        Test-Path -LiteralPath (Join-Path $env:COPILOT_HOME 'skills/shared-skill') | Should -BeFalse
        Test-CtxIsLink -Path (Join-Path $env:COPILOT_HOME 'skills/review-skill') | Should -BeTrue
        Test-CtxIsLink -Path (Join-Path $env:COPILOT_HOME 'skills/security-skill') | Should -BeTrue

        $check = @(& { ctx check } 3>&1 6>&1)
        ($check -join "`n") | Should -Match 'CHECK FAIL skill:shared-skill'
        ($check -join "`n") | Should -Match ([regex]::Escape($reviewDir))
        ($check -join "`n") | Should -Match ([regex]::Escape($securityDir))
        (ctx check) | Should -BeFalse
    }

    It 'Issue40: case-only skill collision is diagnosed, skipped, and check fails' {
        $proj = Join-Path $Script:TestTmp 'project-issue40-case'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'shared-skill'
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $securityDir = New-CtxTestProfile -Name 'security' -Skill 'Shared-Skill'
        New-CtxTestProfile -Name 'security' -Skill 'security-skill' | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "review:$reviewDir`nsecurity:$securityDir"
        Set-Location $proj

        $activation = @(& { Import-CtxFile -CtxFile $ctxFile } 3>&1 6>&1)
        ($activation -join "`n") | Should -Match 'collision'
        ($activation -join "`n") | Should -Match 'shared-skill'
        ($activation -join "`n") | Should -Match ([regex]::Escape($reviewDir))
        ($activation -join "`n") | Should -Match ([regex]::Escape($securityDir))
        Test-Path -LiteralPath (Join-Path $env:COPILOT_HOME 'skills/shared-skill') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $env:COPILOT_HOME 'skills/Shared-Skill') | Should -BeFalse
        Test-CtxIsLink -Path (Join-Path $env:COPILOT_HOME 'skills/review-skill') | Should -BeTrue
        Test-CtxIsLink -Path (Join-Path $env:COPILOT_HOME 'skills/security-skill') | Should -BeTrue

        $check = @(& { ctx check } 3>&1 6>&1)
        ($check -join "`n") | Should -Match 'CHECK FAIL skill:shared-skill'
        ($check -join "`n") | Should -Match ([regex]::Escape($reviewDir))
        ($check -join "`n") | Should -Match ([regex]::Escape($securityDir))
        (ctx check) | Should -BeFalse
    }

    It 'Issue40: non-ASCII case-fold collision (ZÄHLER vs zähler) is diagnosed, skipped, and check fails' {
        $proj = Join-Path $Script:TestTmp 'project-issue40-unicode'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'ZÄHLER'
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $securityDir = New-CtxTestProfile -Name 'security' -Skill 'zähler'
        New-CtxTestProfile -Name 'security' -Skill 'security-skill' | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "review:$reviewDir`nsecurity:$securityDir"
        Set-Location $proj

        $activation = @(& { Import-CtxFile -CtxFile $ctxFile } 3>&1 6>&1)
        ($activation -join "`n") | Should -Match 'collision'
        ($activation -join "`n") | Should -Match 'zähler'
        ($activation -join "`n") | Should -Match ([regex]::Escape($reviewDir))
        ($activation -join "`n") | Should -Match ([regex]::Escape($securityDir))
        Test-Path -LiteralPath (Join-Path $env:COPILOT_HOME 'skills/ZÄHLER') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $env:COPILOT_HOME 'skills/zähler') | Should -BeFalse
        Test-CtxIsLink -Path (Join-Path $env:COPILOT_HOME 'skills/review-skill') | Should -BeTrue
        Test-CtxIsLink -Path (Join-Path $env:COPILOT_HOME 'skills/security-skill') | Should -BeTrue

        $check = @(& { ctx check } 3>&1 6>&1)
        ($check -join "`n") | Should -Match 'CHECK FAIL skill:zähler'
        ($check -join "`n") | Should -Match 'collision'
        ($check -join "`n") | Should -Match ([regex]::Escape($reviewDir))
        ($check -join "`n") | Should -Match ([regex]::Escape($securityDir))
        (ctx check) | Should -BeFalse
    }

    It 'Issue40: stale case-only sibling is detected by check and removed on reactivation' {
        # Only meaningful on a case-sensitive filesystem, where two spellings
        # of the same canonical name can coexist.
        $probe = Join-Path $Script:TestTmp 'caseprobe'
        Set-Content -LiteralPath $probe -Value 'x'
        if (Test-Path -LiteralPath (Join-Path $Script:TestTmp 'CASEPROBE')) {
            Set-ItResult -Skipped -Because 'filesystem is case-insensitive'
            return
        }

        $proj = Join-Path $Script:TestTmp 'project-issue40-stale-case'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'foo-skill'
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "review:$reviewDir"
        Set-Location $proj

        Import-CtxFile -CtxFile $ctxFile | Out-Null
        $fooLink = Join-Path $env:COPILOT_HOME 'skills/foo-skill'
        $fooLinkAlt = Join-Path $env:COPILOT_HOME 'skills/Foo-Skill'
        Test-CtxIsLink -Path $fooLink | Should -BeTrue

        # Simulate a stale same-case sibling on a case-sensitive filesystem.
        New-Item -ItemType SymbolicLink -Path $fooLinkAlt -Target (Join-Path $reviewDir '.github/skills/foo-skill') | Out-Null
        Test-CtxIsLink -Path $fooLinkAlt | Should -BeTrue

        # Read-only check must detect the duplicate canonical name and fail.
        $checkFail = @(& { ctx check } 3>&1 6>&1)
        ($checkFail -join "`n") | Should -Match 'CHECK FAIL skill:foo-skill'
        ($checkFail -join "`n") | Should -Match 'duplicate'
        (ctx check) | Should -BeFalse

        # Reactivation reconciles to exactly one on-disk spelling.
        Import-CtxFile -CtxFile $ctxFile | Out-Null
        Test-CtxIsLink -Path $fooLink | Should -BeTrue
        Test-Path -LiteralPath $fooLinkAlt | Should -BeFalse

        (ctx check) | Should -BeTrue
    }

    It 'Issue40: Greek final-sigma invariant lowercase collision (ΟΣ vs οσ) is diagnosed, skipped, and check fails' {
        $proj = Join-Path $Script:TestTmp 'project-issue40-greek'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'ΟΣ'
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $securityDir = New-CtxTestProfile -Name 'security' -Skill 'οσ'
        New-CtxTestProfile -Name 'security' -Skill 'security-skill' | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "review:$reviewDir`nsecurity:$securityDir"
        Set-Location $proj

        $activation = @(& { Import-CtxFile -CtxFile $ctxFile } 3>&1 6>&1)
        ($activation -join "`n") | Should -Match 'collision'
        ($activation -join "`n") | Should -Match 'οσ'
        ($activation -join "`n") | Should -Match ([regex]::Escape($reviewDir))
        ($activation -join "`n") | Should -Match ([regex]::Escape($securityDir))
        Test-Path -LiteralPath (Join-Path $env:COPILOT_HOME 'skills/ΟΣ') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $env:COPILOT_HOME 'skills/οσ') | Should -BeFalse
        Test-CtxIsLink -Path (Join-Path $env:COPILOT_HOME 'skills/review-skill') | Should -BeTrue
        Test-CtxIsLink -Path (Join-Path $env:COPILOT_HOME 'skills/security-skill') | Should -BeTrue

        $check = @(& { ctx check } 3>&1 6>&1)
        ($check -join "`n") | Should -Match 'CHECK FAIL skill:οσ'
        ($check -join "`n") | Should -Match 'collision'
        ($check -join "`n") | Should -Match ([regex]::Escape($reviewDir))
        ($check -join "`n") | Should -Match ([regex]::Escape($securityDir))
        (ctx check) | Should -BeFalse
    }

    It 'Issue40: Turkish dotted İ and i are distinct under invariant lowercase (no collision)' {
        # Only meaningful on a case-sensitive filesystem, where two spellings
        # of the same canonical name can coexist; on case-insensitive
        # filesystems the on-disk links themselves would alias.
        $probe = Join-Path $Script:TestTmp 'caseprobe'
        Set-Content -LiteralPath $probe -Value 'x'
        if (Test-Path -LiteralPath (Join-Path $Script:TestTmp 'CASEPROBE')) {
            Set-ItResult -Skipped -Because 'filesystem is case-insensitive'
            return
        }

        $proj = Join-Path $Script:TestTmp 'project-issue40-turkish'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'İstanbul'
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $securityDir = New-CtxTestProfile -Name 'security' -Skill 'istanbul'
        New-CtxTestProfile -Name 'security' -Skill 'security-skill' | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "review:$reviewDir`nsecurity:$securityDir"
        Set-Location $proj

        $activation = @(& { Import-CtxFile -CtxFile $ctxFile } 3>&1 6>&1)
        ($activation -join "`n") | Should -Not -Match 'collision'
        Test-CtxIsLink -Path (Join-Path $env:COPILOT_HOME 'skills/İstanbul') | Should -BeTrue
        Test-CtxIsLink -Path (Join-Path $env:COPILOT_HOME 'skills/istanbul') | Should -BeTrue

        (ctx check) | Should -BeTrue
    }

    It 'Issue40: desired spelling is recreated when only a differently-cased link exists' {
        # Runs on every platform, including Windows: a correctly-targeted link
        # seeded under the OLD casing must not satisfy the exact-case link
        # check through case-insensitive path aliasing, so activation leaves
        # the desired on-disk spelling behind as a correct link.
        $proj = Join-Path $Script:TestTmp 'project-issue40-spelling'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'foo-skill'
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "review:$reviewDir"
        Set-Location $proj

        Import-CtxFile -CtxFile $ctxFile | Out-Null
        $fooLink = Join-Path $env:COPILOT_HOME 'skills/foo-skill'
        $fooLinkOld = Join-Path $env:COPILOT_HOME 'skills/Foo-Skill'
        Test-CtxIsLink -Path $fooLink | Should -BeTrue

        # Seed a correctly-targeted link under the OLD casing, removing the
        # desired-casing entry so activation must recreate the desired
        # spelling.
        Remove-Item -LiteralPath $fooLink -Force
        New-CtxLink -LinkPath $fooLinkOld -RealTarget (Join-Path $reviewDir '.github/skills/foo-skill') -Kind 'dir' | Out-Null
        Test-CtxIsLink -Path $fooLinkOld | Should -BeTrue

        # Activate with the desired spelling; the exact on-disk spelling must
        # exist as a correct link afterwards.
        Import-CtxFile -CtxFile $ctxFile | Out-Null
        Test-CtxIsLink -Path $fooLink | Should -BeTrue
        (Get-CtxLinkTarget -Path $fooLink).TrimEnd('\','/') | Should -Be (Join-Path $reviewDir '.github/skills/foo-skill').TrimEnd('\','/')

        # Because Test-Path aliases Foo-Skill and foo-skill on Windows, check
        # the on-disk spelling by enumeration: exactly one entry named
        # foo-skill and no entry named Foo-Skill after activation.
        $skillNames = @(Get-ChildItem -LiteralPath (Join-Path $env:COPILOT_HOME 'skills') -Force | Select-Object -ExpandProperty Name)
        @($skillNames | Where-Object { $_ -ceq 'foo-skill' }).Count | Should -Be 1
        @($skillNames | Where-Object { $_ -ceq 'Foo-Skill' }).Count | Should -Be 0

        (ctx check) | Should -BeTrue
    }

    # --- Issue #48: canonical AGENTS.md profiles ---------------------------

    It 'Issue48: canonical detection projects AGENTS.md bytes and sets custom dirs present-empty' {
        if (Test-CtxOldUnixDotnet) {
            Set-ItResult -Skipped -Because 'all-canonical Mode A requires pwsh/.NET 9+ on Unix'
            return
        }
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# hello`n")) | Out-Null
        ctx review | Out-Null

        $proj = Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/0001-review.instructions.md'
        Test-Path -LiteralPath $proj -PathType Leaf | Should -BeTrue
        Test-CtxIsLink -Path $proj | Should -BeFalse
        Assert-CtxFileBytes -Path $proj -Expected (Get-CtxProjectionBytes ([System.Text.Encoding]::UTF8.GetBytes("# hello`n")))
        $env:AI_CTX_PROFILES | Should -Be 'review'
        Test-Path Env:\COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -BeTrue
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be ''
        $manifest = Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/.ctx-managed'
        (Get-Content -LiteralPath $manifest -Raw).Trim() | Should -Be '0001-review.instructions.md'
    }

    It 'Issue48: canonical .ctx activation projects and ctx check passes' {
        if (Test-CtxOldUnixDotnet) {
            Set-ItResult -Skipped -Because 'all-canonical Mode A requires pwsh/.NET 9+ on Unix'
            return
        }
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# hello`n")) | Out-Null
        $proj = Join-Path $Script:TestTmp 'project-canonical-check'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value 'review:@profile'
        Set-Location $proj

        ctx load $ctxFile | Out-Null

        $projection = Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/0001-review.instructions.md'
        Test-Path -LiteralPath $projection -PathType Leaf | Should -BeTrue
        Assert-CtxFileBytes -Path $projection -Expected (Get-CtxProjectionBytes ([System.Text.Encoding]::UTF8.GetBytes("# hello`n")))
        $manifest = Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/.ctx-managed'
        (Get-Content -LiteralPath $manifest -Raw).Trim() | Should -Be '0001-review.instructions.md'
        $env:AI_CTX_PROFILES | Should -Be 'review'
        Test-Path Env:\COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -BeTrue
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be ''

        $check = @(& { ctx check } *>&1)
        ($check -join "`n") | Should -Match 'CHECK PASS instruction:0001-review\.instructions\.md'
        (ctx check) | Should -BeTrue
    }

    It 'Issue48: old Unix pwsh/.NET <=8 rejects all-canonical Mode A before mutation' {
        if (-not (Test-CtxOldUnixDotnet)) {
            Set-ItResult -Skipped -Because 'requires Unix pwsh/.NET 8 or earlier'
            return
        }
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# hello`n")) | Out-Null
        $env:AI_CTX_PROFILES = 'previous'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS = 'previous-dirs'
        $env:COPILOT_HOME = 'previous-home'

        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $out = @(& { ctx review } *>&1) } finally { $ErrorActionPreference = $prevEap }

        ($out -join "`n") | Should -Match 'all-canonical Mode A requires pwsh/\.NET 9\+ on Unix'
        # A failed Mode A manual activation returns $false (README contract).
        $out[-1] | Should -BeFalse
        $env:AI_CTX_PROFILES | Should -Be 'previous'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be 'previous-dirs'
        $env:COPILOT_HOME | Should -Be 'previous-home'
        Test-Path -LiteralPath (Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'review') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'review/instructions') | Should -BeFalse
        $Script:CtxActiveMode | Should -BeNullOrEmpty
    }

    It 'Issue48: mixed canonical+legacy Mode A keeps legacy dirs in order and projects at selection order' {
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        New-CtxTestCanonicalProfile -Name 'arch' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# arch`n")) | Out-Null
        $securityDir = New-CtxTestProfile -Name 'security' -Skill 'security-skill'

        ctx review arch security | Out-Null

        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be ($reviewDir + ',' + $securityDir)
        Test-Path -LiteralPath (Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/0002-arch.instructions.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/0001-review.instructions.md') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/0003-security.instructions.md') | Should -BeFalse
    }

    It 'Issue48: projection filename sanitizes labels and stays filesystem-safe' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'my profile' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# spaced`n")) | Out-Null

        ctx base 'my profile' | Out-Null

        Test-Path -LiteralPath (Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/0002-my_profile.instructions.md') | Should -BeTrue
    }

    It 'Issue48: non-ASCII label yields a safe filename matching the grammar' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'café' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# accented`n")) | Out-Null

        ctx base 'café' | Out-Null

        $files = @(Get-ChildItem -LiteralPath (Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles') -File -Filter '*.instructions.md')
        $files.Count | Should -Be 1
        $files[0].Name | Should -Be '0002-caf_.instructions.md'
        $files[0].Name | Should -Match '^[0-9]{4,}-[A-Za-z0-9+._-]+\.instructions\.md$'
    }

    It 'Issue48: CRLF, BOM, and missing final newline are preserved byte-for-byte' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# a`r`n# b")) | Out-Null
        ctx base review | Out-Null
        $proj = Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/0002-review.instructions.md'
        Test-Path -LiteralPath $proj -PathType Leaf | Should -BeTrue
        Assert-CtxFileBytes -Path $proj -Expected (Get-CtxProjectionBytes ([System.Text.Encoding]::UTF8.GetBytes("# a`r`n# b")))

        Clear-CtxContext | Out-Null
        $bomBytes = [byte[]](@([byte]0xEF, [byte]0xBB, [byte]0xBF) + [System.Text.Encoding]::UTF8.GetBytes("# bom`n"))
        New-CtxTestCanonicalProfile -Name 'bom' -AgentsBytes $bomBytes | Out-Null
        ctx base bom | Out-Null
        $proj2 = Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/0002-bom.instructions.md'
        Test-Path -LiteralPath $proj2 -PathType Leaf | Should -BeTrue
        Assert-CtxFileBytes -Path $proj2 -Expected (Get-CtxProjectionBytes $bomBytes)
    }

    It 'Issue48: canonical profiles use .agents/skills and ignore co-located .github/skills' {
        New-CtxTestProfile -Name 'base' | Out-Null
        $reviewDir = New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n"))
        New-CtxTestCanonicalSkill -Profile 'review' -Skill 'good-skill'
        New-Item -ItemType Directory -Path (Join-Path $reviewDir '.agents/skills/no-skill') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $reviewDir '.github/skills/legacy-skill') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $reviewDir '.github/skills/legacy-skill/SKILL.md') -Value "---`nname: legacy`n---`n"
        $proj = Join-Path $Script:TestTmp 'project-canonical-skills'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "base:@profile`nreview:@profile"
        Set-Location $proj

        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null

        Test-CtxIsLink -Path (Join-Path $env:COPILOT_HOME 'skills/good-skill') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $env:COPILOT_HOME 'skills/no-skill') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $env:COPILOT_HOME 'skills/legacy-skill') | Should -BeFalse

        $check = @(& { ctx check } 3>&1 6>&1)
        ($check -join "`n") | Should -Match 'CHECK PASS skill:good-skill'
        (ctx check) | Should -BeTrue
    }

    It 'Issue48: canonical skill detection accepts hard-linked SKILL.md like Bash while rejecting symlinks (where supported)' {
        $reviewDir = New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n"))
        New-Item -ItemType Directory -Path (Join-Path $reviewDir '.agents/skills/hard-skill') -Force | Out-Null
        $skillMd = Join-Path $reviewDir '.agents/skills/hard-skill/SKILL.md'
        Set-Content -LiteralPath $skillMd -Value "---`nname: hard`n---`n"
        try {
            # A second hard link raises the link count above 1.
            New-Item -ItemType HardLink -Path (Join-Path $reviewDir '.agents/skills/hard-skill/SKILL.hard') -Target $skillMd -ErrorAction Stop | Out-Null
        } catch {
            Set-ItResult -Skipped -Because 'hard links not supported on this platform'
            return
        }
        # Shared-file semantics preserved: Test-CtxIsLink still treats a
        # multi-link file as a link.
        Test-CtxIsLink -Path $skillMd | Should -BeTrue
        Test-CtxRegularFile -Path $skillMd | Should -BeFalse
        # But canonical skill validation matches Bash `[ -f ] && [ ! -L ]`.
        Test-CtxRegularFile -Path $skillMd -AllowHardLinks | Should -BeTrue
        @(Get-CtxSkillSourceDirs -ResolvedDir $reviewDir | ForEach-Object { $_.Name }) | Should -Contain 'hard-skill'

        # A symlinked SKILL.md is still rejected.
        $symDir = Join-Path $reviewDir '.agents/skills/sym-skill'
        New-Item -ItemType Directory -Path $symDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $symDir 'SKILL.real') -Value "---`nname: sym`n---`n"
        New-Item -ItemType SymbolicLink -Path (Join-Path $symDir 'SKILL.md') -Target (Join-Path $symDir 'SKILL.real') | Out-Null
        @(Get-CtxSkillSourceDirs -ResolvedDir $reviewDir | ForEach-Object { $_.Name }) | Should -Not -Contain 'sym-skill'
    }

    It 'Issue48: canonical/legacy skill collisions reuse warn-and-skip and check FAIL' {
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        New-CtxTestCanonicalSkill -Profile 'review' -Skill 'dup-skill'
        $securityDir = New-CtxTestProfile -Name 'security' -Skill 'Dup-Skill'
        $proj = Join-Path $Script:TestTmp 'project-canonical-collision'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles') 'review'
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "review:$reviewDir`nsecurity:$securityDir"
        Set-Location $proj

        $activation = @(& { Import-CtxFile -CtxFile $ctxFile } 3>&1 6>&1)
        ($activation -join "`n") | Should -Match 'collision'
        Test-Path -LiteralPath (Join-Path $env:COPILOT_HOME 'skills/dup-skill') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $env:COPILOT_HOME 'skills/Dup-Skill') | Should -BeFalse

        $check = @(& { ctx check } 3>&1 6>&1)
        ($check -join "`n") | Should -Match 'CHECK FAIL skill:dup-skill'
        ($check -join "`n") | Should -Match 'collision'
        (ctx check) | Should -BeFalse
    }

    It 'Issue48: Mode B and C manual activation rejects canonical selections before any mutation' {
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        foreach ($mode in @('global-user', 'ephemeral-clean')) {
            $env:AI_CTX_PROFILES_COPILOT_MODE = $mode
            $env:AI_CTX_PROFILES = 'previous'
            $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS = 'previous-dirs'
            $env:COPILOT_HOME = 'previous-home'
            $env:COPILOT_SKILLS_DIRS = 'previous-skills'

            $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            try { $out = @(& { ctx review } *>&1) } finally { $ErrorActionPreference = $prevEap }

            ($out -join "`n") | Should -Match 'canonical'
            ($out -join "`n") | Should -Match 'synthetic-home'
            $env:AI_CTX_PROFILES | Should -Be 'previous'
            $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be 'previous-dirs'
            $env:COPILOT_HOME | Should -Be 'previous-home'
            $env:COPILOT_SKILLS_DIRS | Should -Be 'previous-skills'
            Test-Path -LiteralPath (Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'review') | Should -BeFalse
            $Script:CtxActiveMode | Should -BeNullOrEmpty
        }
    }

    It 'Issue48: explicit .ctx load rejects canonical entries under Mode B and C before mutation' {
        $reviewDir = New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n"))
        $proj = Join-Path $Script:TestTmp 'project-canon-load-bc'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"

        foreach ($mode in @('global-user', 'ephemeral-clean')) {
            $env:AI_CTX_PROFILES_COPILOT_MODE = $mode
            $env:AI_CTX_PROFILES = 'previous'
            $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS = 'previous-dirs'
            $env:COPILOT_HOME = 'previous-home'
            $env:COPILOT_SKILLS_DIRS = 'previous-skills'

            $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            try { $out = @(& { Import-CtxFile -CtxFile (Join-Path $proj '.ctx') } *>&1) } finally { $ErrorActionPreference = $prevEap }

            ($out -join "`n") | Should -Match 'canonical'
            $env:AI_CTX_PROFILES | Should -Be 'previous'
            $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be 'previous-dirs'
            $env:COPILOT_HOME | Should -Be 'previous-home'
            $env:COPILOT_SKILLS_DIRS | Should -Be 'previous-skills'
            Test-Path -LiteralPath (Join-Path $proj 'project-canon-load-bc.code-workspace') | Should -BeFalse
            $Script:CtxActiveMode | Should -BeNullOrEmpty
        }
    }

    It 'Issue48: actual auto-load rejects canonical entries under Mode B and C, and repeats' {
        $reviewDir = New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n"))
        $proj = Join-Path $Script:TestTmp 'project-canon-autoload-bc'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"

        foreach ($mode in @('global-user', 'ephemeral-clean')) {
            $env:AI_CTX_PROFILES_COPILOT_MODE = $mode
            $env:AI_CTX_PROFILES = 'previous'
            $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS = 'previous-dirs'
            $env:COPILOT_HOME = 'previous-home'
            $env:COPILOT_SKILLS_DIRS = 'previous-skills'
            $Script:CtxAutoLoadDir = $null
            Set-Location $proj

            foreach ($attempt in @(1, 2)) {
                $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                try { $out = @(& { Invoke-CtxAutoLoad } *>&1) } finally { $ErrorActionPreference = $prevEap }

                ($out -join "`n") | Should -Match 'canonical'
                $env:AI_CTX_PROFILES | Should -Be 'previous'
                $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be 'previous-dirs'
                $env:COPILOT_HOME | Should -Be 'previous-home'
                $env:COPILOT_SKILLS_DIRS | Should -Be 'previous-skills'
                Test-Path -LiteralPath (Join-Path $proj 'project-canon-autoload-bc.code-workspace') | Should -BeFalse
                $Script:CtxActiveMode | Should -BeNullOrEmpty
            }
        }
    }

    It 'Issue48: unmanifested desired projection is not overwritten' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        $syntheticHome = Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'base+review'
        New-Item -ItemType Directory -Path (Join-Path $syntheticHome 'instructions/ctx-profiles') -Force | Out-Null
        $proj = Join-Path $syntheticHome 'instructions/ctx-profiles/0002-review.instructions.md'
        Set-Content -LiteralPath $proj -Value 'user data' -NoNewline
        $env:AI_CTX_PROFILES = 'previous'

        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $out = @(& { ctx base review } *>&1) } finally { $ErrorActionPreference = $prevEap }

        ($out -join "`n") | Should -Match 'unmanaged projection'
        (Get-Content -LiteralPath $proj -Raw) | Should -Be 'user data'
        $env:AI_CTX_PROFILES | Should -Be 'previous'
    }

    It 'Issue48: manifest-listed desired projection as symlink to outside sentinel fails closed' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        $syntheticHome = Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'base+review'
        $outside = Join-Path $Script:TestTmp 'outside-sentinel'
        Set-Content -LiteralPath $outside -Value 'outside data' -NoNewline
        New-Item -ItemType Directory -Path (Join-Path $syntheticHome 'instructions/ctx-profiles') -Force | Out-Null
        $proj = Join-Path $syntheticHome 'instructions/ctx-profiles/0002-review.instructions.md'
        New-Item -ItemType SymbolicLink -Path $proj -Target $outside | Out-Null
        Set-Content -LiteralPath (Join-Path $syntheticHome 'instructions/ctx-profiles/.ctx-managed') -Value '0002-review.instructions.md'
        $env:AI_CTX_PROFILES = 'previous'

        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $out = @(& { ctx base review } *>&1) } finally { $ErrorActionPreference = $prevEap }

        ($out -join "`n") | Should -Match 'unsafe managed projection target'
        (Get-Content -LiteralPath $outside -Raw) | Should -Be 'outside data'
        (Get-Item -LiteralPath $proj -Force).LinkType | Should -Not -BeNullOrEmpty
        $env:COPILOT_HOME | Should -BeNullOrEmpty
        $env:AI_CTX_PROFILES | Should -Be 'previous'
    }

    It 'Issue48: directory at manifest-listed desired projection name fails closed' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        $syntheticHome = Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'base+review'
        $projDir = Join-Path $syntheticHome 'instructions/ctx-profiles/0002-review.instructions.md'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $syntheticHome 'instructions/ctx-profiles/.ctx-managed') -Value '0002-review.instructions.md'
        $env:AI_CTX_PROFILES = 'previous'

        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $out = @(& { ctx base review } *>&1) } finally { $ErrorActionPreference = $prevEap }

        ($out -join "`n") | Should -Match 'unsafe managed projection target'
        $env:COPILOT_HOME | Should -BeNullOrEmpty
        $env:AI_CTX_PROFILES | Should -Be 'previous'
        Test-Path -LiteralPath $projDir -PathType Container | Should -BeTrue
    }

    It 'Issue48: linked projection directory fails without writing outside the home' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        $syntheticHome = Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'base+review'
        $outside = Join-Path $Script:TestTmp 'outside-instructions'
        New-Item -ItemType Directory -Path $syntheticHome, $outside -Force | Out-Null
        New-CtxLink -LinkPath (Join-Path $syntheticHome 'instructions') -RealTarget $outside -Kind 'dir' | Out-Null

        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $out = @(& { ctx base review } *>&1) } finally { $ErrorActionPreference = $prevEap }

        ($out -join "`n") | Should -Match 'unsafe projection directory'
        Test-Path -LiteralPath (Join-Path $outside 'ctx-profiles') | Should -BeFalse
    }

    It 'Issue48: malformed manifest fails closed without changing projections' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        $syntheticHome = Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'base+review'
        New-Item -ItemType Directory -Path (Join-Path $syntheticHome 'instructions/ctx-profiles') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $syntheticHome 'instructions/ctx-profiles/.ctx-managed') -Value '../escape.instructions.md'

        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $out = @(& { ctx base review } *>&1) } finally { $ErrorActionPreference = $prevEap }

        ($out -join "`n") | Should -Match 'malformed projection manifest'
        Test-Path -LiteralPath (Join-Path $Script:TestTmp 'escape.instructions.md') | Should -BeFalse
    }

    It 'Issue48: stale managed projection is removed on switch to legacy' {
        New-CtxTestProfile -Name 'base' | Out-Null
        $reviewDir = New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n"))
        ctx base review | Out-Null
        $proj = Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/0002-review.instructions.md'
        Test-Path -LiteralPath $proj | Should -BeTrue

        # The profile becomes legacy while the same context (and home) stays
        # selected, so the now-unwanted managed projection must be removed.
        Remove-Item -LiteralPath (Join-Path $reviewDir 'AGENTS.md') -Force
        ctx base review | Out-Null
        Test-Path -LiteralPath $proj | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/.ctx-managed') | Should -BeFalse
    }

    It 'Issue48: ctx clear preserves the cached projection and clear --all removes the home' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        ctx base review | Out-Null
        $syntheticHome = $env:COPILOT_HOME
        $proj = Join-Path $syntheticHome 'instructions/ctx-profiles/0002-review.instructions.md'
        Test-Path -LiteralPath $proj | Should -BeTrue

        Clear-CtxContext | Out-Null
        Test-Path -LiteralPath $proj | Should -BeTrue

        ctx base review | Out-Null
        Clear-CtxContext -All | Out-Null
        Test-Path -LiteralPath $syntheticHome | Should -BeFalse
    }

    It 'Issue48: check uses the recorded Mode A despite a selector mismatch' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        $proj = Join-Path $Script:TestTmp 'project-canonical-mismatch'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:@profile`nbase:@profile"
        Set-Location $proj
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'global-user'

        $check = @(& { ctx check } 3>&1 6>&1)
        ($check -join "`n") | Should -Match 'CHECK PASS instruction:0001-review.instructions.md'
        ($check -join "`n") | Should -Match 'does not match recorded active mode'
        (ctx check) | Should -BeFalse
    }

    It 'Issue48: no activation record skips canonical instruction checks' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        $proj = Join-Path $Script:TestTmp 'project-canonical-norecord'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:@profile`nbase:@profile"
        Set-Location $proj
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null
        Reset-CtxActiveRecord

        $check = @(& { ctx check } 3>&1 6>&1)
        ($check -join "`n") | Should -Match 'CHECK SKIP instruction:0001-review.instructions.md'
    }

    It 'Issue48: all-canonical Mode A check requires present-empty custom dirs' {
        if (Test-CtxOldUnixDotnet) {
            Set-ItResult -Skipped -Because 'all-canonical Mode A requires pwsh/.NET 9+ on Unix'
            return
        }
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        $proj = Join-Path $Script:TestTmp 'project-canonical-empty'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value 'review:@profile'
        Set-Location $proj
        (Import-CtxFile -CtxFile (Join-Path $proj '.ctx')) | Should -BeTrue

        Test-Path Env:\COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -BeTrue
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be ''
        (ctx check) | Should -BeTrue
        Remove-Item Env:\COPILOT_CUSTOM_INSTRUCTIONS_DIRS -ErrorAction SilentlyContinue
        $check = @(& { ctx check } *>&1)
        ($check -join "`n") | Should -Match 'CHECK FAIL COPILOT_CUSTOM_INSTRUCTIONS_DIRS'
    }

    It 'Issue48: ctx current does not add projection listings' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        ctx base review | Out-Null

        $out = @(& { Show-CtxCurrent } 3>&1 6>&1)
        ($out -join "`n") | Should -Not -Match 'instructions\.md'
    }

    It 'Issue48: ctx current distinguishes present-empty from unset COPILOT_CUSTOM_INSTRUCTIONS_DIRS' {
        if (Test-CtxOldUnixDotnet) {
            Set-ItResult -Skipped -Because 'all-canonical Mode A requires pwsh/.NET 9+ on Unix'
            return
        }
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        ctx review | Out-Null

        $out = @(& { Show-CtxCurrent } 6>&1)
        ($out -join "`n") | Should -Match 'COPILOT_CUSTOM_INSTRUCTIONS_DIRS='
        ($out -join "`n") | Should -Match '<present-empty>'

        Remove-Item Env:\COPILOT_CUSTOM_INSTRUCTIONS_DIRS -ErrorAction SilentlyContinue
        $out = @(& { Show-CtxCurrent } 6>&1)
        ($out -join "`n") | Should -Match '<unset>'
    }

    It 'Issue48: legacy-only activation preserves an empty user instructions directory' {
        New-CtxTestProfile -Name 'security' -Skill 'security-skill' | Out-Null
        $syntheticHome = Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'security'
        New-Item -ItemType Directory -Path (Join-Path $syntheticHome 'instructions') -Force | Out-Null

        ctx security | Out-Null
        Test-Path -LiteralPath (Join-Path $syntheticHome 'instructions') -PathType Container | Should -BeTrue
    }

    It 'Issue48: legacy-only activation does not reject an unrelated linked instructions path without a manifest' {
        New-CtxTestProfile -Name 'security' -Skill 'security-skill' | Out-Null
        $syntheticHome = Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'security'
        $outside = Join-Path $Script:TestTmp 'outside-instructions'
        New-Item -ItemType Directory -Path $syntheticHome, $outside -Force | Out-Null
        New-CtxLink -LinkPath (Join-Path $syntheticHome 'instructions') -RealTarget $outside -Kind 'dir' | Out-Null

        ctx security | Out-Null
        Test-CtxIsLink -Path (Join-Path $syntheticHome 'instructions') | Should -BeTrue
    }

    It 'Issue48: legacy-only activation with an existing ctx manifest removes only stale managed projections' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        ctx base review | Out-Null
        $syntheticHome = $env:COPILOT_HOME
        $proj = Join-Path $syntheticHome 'instructions/ctx-profiles/0002-review.instructions.md'
        Test-Path -LiteralPath $proj | Should -BeTrue

        New-CtxTestProfile -Name 'security' -Skill 'security-skill' | Out-Null
        $pdir = Join-Path $Script:TestTmp 'project-legacy-reuse'
        New-Item -ItemType Directory -Path $pdir -Force | Out-Null
        $securityDir = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/security'
        Set-Content -LiteralPath (Join-Path $pdir '.ctx') -Value "security:$securityDir`nhome:$syntheticHome"
        Import-CtxFile -CtxFile (Join-Path $pdir '.ctx') | Out-Null

        Test-Path -LiteralPath $proj | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $syntheticHome 'instructions/ctx-profiles/.ctx-managed') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $syntheticHome 'skills') -PathType Container | Should -BeTrue
    }

    It 'Issue48: ctx check skips projections when no canonical entries and no manifest exist' {
        New-CtxTestProfile -Name 'security' -Skill 'security-skill' | Out-Null
        $proj = Join-Path $Script:TestTmp 'project-legacy-check'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $securityDir = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/security'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "security:$securityDir"
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null
        Set-Location $proj

        $out = @(& { Test-CtxActivation } 6>&1)
        $out[-1] | Should -BeTrue
    }

    It 'Issue48: ctx check fails on a malformed ctx-managed manifest with zero canonical entries' {
        New-CtxTestProfile -Name 'security' -Skill 'security-skill' | Out-Null
        $proj = Join-Path $Script:TestTmp 'project-legacy-check-malformed'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $securityDir = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/security'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "security:$securityDir"
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/.ctx-managed') -Value 'bad name'
        Set-Location $proj

        $out = @(& { Test-CtxActivation } 6>&1)
        $out[-1] | Should -BeFalse
        ($out -join "`n") | Should -Match 'CHECK FAIL instruction:manifest'
    }

    It 'Issue48: ctx check fails on a stale ctx-managed manifest with zero canonical entries' {
        New-CtxTestProfile -Name 'security' -Skill 'security-skill' | Out-Null
        $proj = Join-Path $Script:TestTmp 'project-legacy-check-stale'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $securityDir = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/security'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "security:$securityDir"
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/.ctx-managed') -Value '0001-review.instructions.md'
        Set-Location $proj

        $out = @(& { Test-CtxActivation } 6>&1)
        $out[-1] | Should -BeFalse
        ($out -join "`n") | Should -Match 'stale projection'
    }

    It 'Issue48: projection transaction fails closed when a later source is missing' {
        $reviewDir = New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n"))
        $missing = Join-Path $Script:TestTmp 'missing-source'
        New-Item -ItemType Directory -Path $missing -Force | Out-Null
        $syntheticHome = Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'review+arch'
        $entries = @(
            [PSCustomObject]@{ Order = 1; Label = 'review'; Path = $reviewDir },
            [PSCustomObject]@{ Order = 2; Label = 'arch'; Path = $missing }
        )

        $caught = $null
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            $null = @(& { Set-CtxCanonicalInstructions -HomeDir $syntheticHome -Entries $entries } *>&1)
        } catch {
            $caught = $_
        } finally {
            $ErrorActionPreference = $prevEap
        }

        $caught.Exception.Message | Should -Match 'could not read projection source'
        Test-Path -LiteralPath (Join-Path $syntheticHome 'instructions/ctx-profiles/0001-review.instructions.md') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $syntheticHome 'instructions/ctx-profiles/0002-arch.instructions.md') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $syntheticHome 'instructions/ctx-profiles/.ctx-managed') | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path $syntheticHome 'instructions/ctx-profiles') -Force -Filter '.ctx-txn.*' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'Issue48: projection transaction retry succeeds after the source is fixed' {
        $reviewDir = New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n"))
        $missing = Join-Path $Script:TestTmp 'missing-source'
        New-Item -ItemType Directory -Path $missing -Force | Out-Null
        $syntheticHome = Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'review+arch'
        $entries = @(
            [PSCustomObject]@{ Order = 1; Label = 'review'; Path = $reviewDir },
            [PSCustomObject]@{ Order = 2; Label = 'arch'; Path = $missing }
        )

        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            $null = @(& { Set-CtxCanonicalInstructions -HomeDir $syntheticHome -Entries $entries } *>&1)
        } catch {
            # Expected: the second source is still missing.
        } finally {
            $ErrorActionPreference = $prevEap
        }

        Set-Content -LiteralPath (Join-Path $missing 'AGENTS.md') -Value '# arch'
        Set-CtxCanonicalInstructions -HomeDir $syntheticHome -Entries $entries
        Test-Path -LiteralPath (Join-Path $syntheticHome 'instructions/ctx-profiles/0001-review.instructions.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $syntheticHome 'instructions/ctx-profiles/0002-arch.instructions.md') | Should -BeTrue
        ((Get-Content -LiteralPath (Join-Path $syntheticHome 'instructions/ctx-profiles/.ctx-managed') -Raw).Trim() -replace "`r`n", "`n") | Should -Be "0001-review.instructions.md`n0002-arch.instructions.md"
        @(Get-ChildItem -LiteralPath (Join-Path $syntheticHome 'instructions/ctx-profiles') -Force -Filter '.ctx-txn.*' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'Issue48: an interrupted projection transaction is recoverable on retry' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        New-CtxTestCanonicalProfile -Name 'arch' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# arch`n")) | Out-Null
        $syntheticHome = Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'base+review+arch'
        $projDir = Join-Path $syntheticHome 'instructions/ctx-profiles'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null

        # Simulate a crash after the union manifest was written and one target
        # replaced: the manifest still covers the old stale name plus both
        # desired names, and a leftover per-transaction staging directory
        # remains.
        Set-Content -LiteralPath (Join-Path $projDir '.ctx-managed') -Value "0002-review.instructions.md`n0001-old.instructions.md`n0003-arch.instructions.md"
        Set-Content -LiteralPath (Join-Path $projDir '0002-review.instructions.md') -Value 'old review'
        Set-Content -LiteralPath (Join-Path $projDir '0001-old.instructions.md') -Value 'old stale'
        Set-Content -LiteralPath (Join-Path $projDir '0003-arch.instructions.md') -Value 'old arch'
        New-Item -ItemType Directory -Path (Join-Path $projDir '.ctx-txn.crashed') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $projDir '.ctx-txn.crashed/0002-review.instructions.md') -Value 'partial'

        ctx base review arch | Out-Null
        Assert-CtxFileBytes -Path (Join-Path $projDir '0002-review.instructions.md') -Expected (Get-CtxProjectionBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")))
        Assert-CtxFileBytes -Path (Join-Path $projDir '0003-arch.instructions.md') -Expected (Get-CtxProjectionBytes ([System.Text.Encoding]::UTF8.GetBytes("# arch`n")))
        Test-Path -LiteralPath (Join-Path $projDir '0001-old.instructions.md') | Should -BeFalse
        ((Get-Content -LiteralPath (Join-Path $projDir '.ctx-managed') -Raw).Trim() -replace "`r`n", "`n") | Should -Be "0002-review.instructions.md`n0003-arch.instructions.md"
        # A crashed transaction directory is never swept; it is ignored safely.
        Test-Path -LiteralPath (Join-Path $projDir '.ctx-txn.crashed') -PathType Container | Should -BeTrue
    }

    It 'Issue48: ordinary managed projection files update on reactivation' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        ctx base review | Out-Null
        $proj = Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/0002-review.instructions.md'
        Assert-CtxFileBytes -Path $proj -Expected (Get-CtxProjectionBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")))

        $reviewDir = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/review'
        Set-Content -LiteralPath (Join-Path $reviewDir 'AGENTS.md') -Value '# review v2' -NoNewline
        ctx base review | Out-Null
        Assert-CtxFileBytes -Path $proj -Expected (Get-CtxProjectionBytes ([System.Text.Encoding]::UTF8.GetBytes("# review v2")))
        Test-CtxIsLink -Path $proj | Should -BeFalse
    }

    It 'Issue48: an unrelated .ctx.tmp.keep file survives activation and retry' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        $syntheticHome = Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'base+review'
        $projDir = Join-Path $syntheticHome 'instructions/ctx-profiles'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $projDir '.ctx.tmp.keep') -Value 'keep me' -NoNewline

        ctx base review | Out-Null
        (Get-Content -LiteralPath (Join-Path $projDir '.ctx.tmp.keep') -Raw) | Should -Be 'keep me'

        $reviewDir = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/review'
        Set-Content -LiteralPath (Join-Path $reviewDir 'AGENTS.md') -Value '# review v2' -NoNewline
        ctx base review | Out-Null
        (Get-Content -LiteralPath (Join-Path $projDir '.ctx.tmp.keep') -Raw) | Should -Be 'keep me'
        @(Get-ChildItem -LiteralPath $projDir -Force -Filter '.ctx-txn.*' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'Issue48: stale prune failure retains the expanded manifest and never deletes directory contents' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        $syntheticHome = Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'base+review'
        $projDir = Join-Path $syntheticHome 'instructions/ctx-profiles'
        New-Item -ItemType Directory -Path (Join-Path $projDir '0001-old.instructions.md') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $projDir '0001-old.instructions.md/inner.txt') -Value 'precious' -NoNewline
        Set-Content -LiteralPath (Join-Path $projDir '.ctx-managed') -Value "0001-old.instructions.md`n0002-review.instructions.md"
        Set-Content -LiteralPath (Join-Path $projDir '0002-review.instructions.md') -Value 'old review'

        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $out = @(& { ctx base review } *>&1) } finally { $ErrorActionPreference = $prevEap }

        ($out -join "`n") | Should -Match 'refusing to remove non-regular stale projection'
        # The expanded union manifest is retained so a retry remains possible.
        ((Get-Content -LiteralPath (Join-Path $projDir '.ctx-managed') -Raw).Trim() -replace "`r`n", "`n") | Should -Be "0001-old.instructions.md`n0002-review.instructions.md"
        # Directory contents were never recursively deleted.
        (Get-Content -LiteralPath (Join-Path $projDir '0001-old.instructions.md/inner.txt') -Raw) | Should -Be 'precious'
        # No transaction staging directory is left behind.
        @(Get-ChildItem -LiteralPath $projDir -Force -Filter '.ctx-txn.*' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'Issue48: case-only projection label transition under a shared home removes the stale old-case projection' {
        if ($IsWindows -or $env:OS -ceq 'Windows_NT') {
            Set-ItResult -Skipped -Because 'case-insensitive filesystem: covered by the dedicated Windows alias test'
            return
        }
        New-CtxTestProfile -Name 'base' | Out-Null
        $reviewDir = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/Review'
        New-Item -ItemType Directory -Path $reviewDir -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $reviewDir 'AGENTS.md'), [System.Text.Encoding]::UTF8.GetBytes("# review`n"))
        $syntheticHome = Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'case-home'
        New-Item -ItemType Directory -Path $syntheticHome -Force | Out-Null
        $pdir = Join-Path $Script:TestTmp 'project-case-home'
        New-Item -ItemType Directory -Path $pdir -Force | Out-Null

        Set-Content -LiteralPath (Join-Path $pdir '.ctx') -Value "base:@profile`nReview:@profile`nhome:$syntheticHome"
        Import-CtxFile -CtxFile (Join-Path $pdir '.ctx') | Out-Null
        Test-Path -LiteralPath (Join-Path $syntheticHome 'instructions/ctx-profiles/0002-Review.instructions.md') | Should -BeTrue

        # On a case-sensitive filesystem the old-case projection is a distinct
        # stale file that must be removed, not orphaned, when the label case flips.
        Rename-Item -LiteralPath $reviewDir -NewName 'review'
        Set-Content -LiteralPath (Join-Path $pdir '.ctx') -Value "base:@profile`nreview:@profile`nhome:$syntheticHome"
        Import-CtxFile -CtxFile (Join-Path $pdir '.ctx') | Out-Null
        Test-Path -LiteralPath (Join-Path $syntheticHome 'instructions/ctx-profiles/0002-review.instructions.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $syntheticHome 'instructions/ctx-profiles/0002-Review.instructions.md') | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $syntheticHome 'instructions/ctx-profiles/.ctx-managed') -Raw).Trim() | Should -Be '0002-review.instructions.md'
        $env:AI_CTX_PROFILES | Should -Be 'base+review'
    }

    It 'Issue48: case-only projection label alias on a case-insensitive filesystem stays managed (Windows)' {
        if (-not $IsWindows) {
            Set-ItResult -Skipped -Because 'requires a case-insensitive filesystem (Windows CI)'
            return
        }
        New-CtxTestProfile -Name 'base' | Out-Null
        $reviewDir = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/Review'
        New-Item -ItemType Directory -Path $reviewDir -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $reviewDir 'AGENTS.md'), [System.Text.Encoding]::UTF8.GetBytes("# review`n"))
        $syntheticHome = Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'case-home-win'
        New-Item -ItemType Directory -Path $syntheticHome -Force | Out-Null
        $pdir = Join-Path $Script:TestTmp 'project-case-home-win'
        New-Item -ItemType Directory -Path $pdir -Force | Out-Null

        Set-Content -LiteralPath (Join-Path $pdir '.ctx') -Value "base:@profile`nReview:@profile`nhome:$syntheticHome"
        Import-CtxFile -CtxFile (Join-Path $pdir '.ctx') | Out-Null

        Rename-Item -LiteralPath $reviewDir -NewName 'review'
        Set-Content -LiteralPath (Join-Path $pdir '.ctx') -Value "base:@profile`nreview:@profile`nhome:$syntheticHome"
        Import-CtxFile -CtxFile (Join-Path $pdir '.ctx') | Out-Null

        # On a case-insensitive filesystem the desired name is a case-alias of
        # the existing managed file: it must remain managed (never rejected as
        # unmanaged) and the stale spelling must not delete the projection.
        Test-Path -LiteralPath (Join-Path $syntheticHome 'instructions/ctx-profiles/0002-review.instructions.md') | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $syntheticHome 'instructions/ctx-profiles/.ctx-managed') -Raw).Trim() | Should -Be '0002-review.instructions.md'
        $env:AI_CTX_PROFILES | Should -Be 'base+review'
    }

    It 'Issue48: sanitizer replaces each disallowed Unicode character once (café, supplementary)' {
        Get-CtxSanitizedContextName -Name 'café' | Should -Be 'caf_'
        Get-CtxSanitizedContextName -Name 'caféñ' | Should -Be 'caf__'
        Get-CtxSanitizedContextName -Name 'a𝄞b' | Should -Be 'a_b'
        Get-CtxSanitizedContextName -Name 'my profile' | Should -Be 'my_profile'
        Get-CtxSanitizedContextName -Name 'hello/world' | Should -Be 'hello_world'
    }

    It 'Issue48: sanitizer replaces culture-case-folded Unicode letters with _ (Kelvin, dotted I)' {
        $savedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
        $savedUiCulture = [System.Threading.Thread]::CurrentThread.CurrentUICulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            # Case-sensitive replacement must not let case-folding (Kelvin sign
            # -> k, dotted capital I -> i) smuggle characters through [A-Za-z].
            Get-CtxSanitizedContextName -Name "Kſİ" | Should -Be '___'
            Get-CtxSanitizedContextName -Name "K" | Should -Be '_'
            Get-CtxSanitizedContextName -Name "İ" | Should -Be '_'
            Get-CtxSanitizedContextName -Name 'review' | Should -Be 'review'
        } finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $savedCulture
            [System.Threading.Thread]::CurrentThread.CurrentUICulture = $savedUiCulture
        }
    }

    It 'Issue48: canonical detection rejects a FIFO AGENTS.md without blocking (Unix)' {
        if ($IsWindows -or $env:OS -ceq 'Windows_NT') {
            Set-ItResult -Skipped -Because 'requires mkfifo (Unix)'
            return
        }
        $profileDir = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/fifo-profile'
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        $fifo = Join-Path $profileDir 'AGENTS.md'
        & mkfifo $fifo

        # A FIFO AGENTS.md must not make a profile canonical (Bash `[ -f ]` is
        # false for a FIFO) and must never be opened (reading it would block).
        Test-CtxProfileCanonical -ProfileDir $profileDir | Should -BeFalse
        Test-CtxFollowedRegularFile -Path $fifo | Should -BeFalse

        # A symlink to a regular AGENTS.md is still canonical (Bash follows
        # links); a symlink to a FIFO is not.
        $symProfile = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/symlink-profile'
        New-Item -ItemType Directory -Path $symProfile -Force | Out-Null
        $real = Join-Path $Script:TestTmp 'real-agents.md'
        Set-Content -LiteralPath $real -Value '# x' -NoNewline
        New-Item -ItemType SymbolicLink -Path (Join-Path $symProfile 'AGENTS.md') -Target $real | Out-Null
        Test-CtxProfileCanonical -ProfileDir $symProfile | Should -BeTrue

        $symFifoProfile = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/symfifo-profile'
        New-Item -ItemType Directory -Path $symFifoProfile -Force | Out-Null
        $realFifo = Join-Path $Script:TestTmp 'real-fifo'
        & mkfifo $realFifo
        New-Item -ItemType SymbolicLink -Path (Join-Path $symFifoProfile 'AGENTS.md') -Target $realFifo | Out-Null
        Test-CtxProfileCanonical -ProfileDir $symFifoProfile | Should -BeFalse

        # A regular AGENTS.md is canonical.
        $regProfile = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/reg-profile'
        New-Item -ItemType Directory -Path $regProfile -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $regProfile 'AGENTS.md') -Value '# x' -NoNewline
        Test-CtxProfileCanonical -ProfileDir $regProfile | Should -BeTrue
    }

    It 'Issue48: a FIFO manifest is rejected without blocking (Unix regular-file predicate)' {
        if ($IsWindows -or $env:OS -ceq 'Windows_NT') {
            Set-ItResult -Skipped -Because 'requires mkfifo (Unix)'
            return
        }
        New-CtxTestProfile -Name 'base' | Out-Null
        $reviewDir = New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n"))
        $syntheticHome = Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'base+review'
        $projDir = Join-Path $syntheticHome 'instructions/ctx-profiles'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $fifo = Join-Path $projDir '.ctx-managed'
        & mkfifo $fifo

        # The predicate must reject a FIFO (Get-Item reports FileInfo/Normal,
        # which alone would be indistinguishable from a regular file), and the
        # manifest must never be opened (reading a FIFO would block).
        Test-CtxRegularFile -Path $fifo | Should -BeFalse
        Test-CtxRegularFile -Path $projDir | Should -BeFalse
        Test-CtxRegularFile -Path (Join-Path $reviewDir 'AGENTS.md') | Should -BeTrue

        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $out = @(& { ctx base review } *>&1) } finally { $ErrorActionPreference = $prevEap }
        ($out -join "`n") | Should -Match 'malformed projection manifest'

        # ctx check also fails closed on the FIFO manifest without blocking.
        $checkOut = @(& { Write-CtxCheckInstructions -ExpectedHome $syntheticHome -RecordedMode 'synthetic-home' -Entries @([PSCustomObject]@{ Name = '0002-review.instructions.md'; Source = $reviewDir }) } 6>&1)
        ($checkOut -join "`n") | Should -Match 'CHECK FAIL instruction:manifest'
    }

    It 'Issue48: old Unix rejects all-canonical Mode A load and repeated auto-load before mutation' {
        if (-not (Test-CtxOldUnixDotnet)) {
            Set-ItResult -Skipped -Because 'requires Unix pwsh/.NET 8 or earlier'
            return
        }
        $reviewDir = New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n"))
        $proj = Join-Path $Script:TestTmp 'project-canon-old-unix'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "review:$reviewDir"
        $env:AI_CTX_PROFILES_COPILOT_MODE = 'synthetic-home'
        $env:AI_CTX_PROFILES = 'previous'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS = 'previous-dirs'
        $env:COPILOT_HOME = 'previous-home'

        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $out = @(& { Import-CtxFile -CtxFile $ctxFile } *>&1) } finally { $ErrorActionPreference = $prevEap }
        ($out -join "`n") | Should -Match 'pwsh/\.NET 9\+ on Unix'
        $env:AI_CTX_PROFILES | Should -Be 'previous'
        $env:COPILOT_HOME | Should -Be 'previous-home'
        Test-Path -LiteralPath (Join-Path $proj 'project-canon-old-unix.code-workspace') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'review/instructions') | Should -BeFalse

        $Script:CtxAutoLoadDir = $null
        Set-Location $proj
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $first = @(& { Invoke-CtxAutoLoad } *>&1) } finally { $ErrorActionPreference = $prevEap }
        ($first -join "`n") | Should -Match 'pwsh/\.NET 9\+ on Unix'
        $env:AI_CTX_PROFILES | Should -Be 'previous'
        $Script:CtxActiveMode | Should -BeNullOrEmpty

        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $second = @(& { Invoke-CtxAutoLoad } *>&1) } finally { $ErrorActionPreference = $prevEap }
        ($second -join "`n") | Should -Match 'pwsh/\.NET 9\+ on Unix'
        $env:AI_CTX_PROFILES | Should -Be 'previous'
        Test-Path -LiteralPath (Join-Path $proj 'project-canon-old-unix.code-workspace') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'review/instructions') | Should -BeFalse
    }

    It 'Issue48: direct .ctx canonical profile outside the configured profiles root fails atomically' {
        $outside = Join-Path $Script:TestTmp 'outside-canonical'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        $sentinel = Join-Path $outside 'AGENTS.md'
        [System.IO.File]::WriteAllText($sentinel, "# outside canonical`n")
        $before = [System.IO.File]::ReadAllBytes($sentinel)

        $proj = Join-Path $Script:TestTmp 'project-canon-outside'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "outside:$outside"
        $env:AI_CTX_PROFILES = 'previous'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS = 'previous-dirs'
        $env:COPILOT_HOME = 'previous-home'
        $env:COPILOT_SKILLS_DIRS = 'previous-skills'

        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        try { $result = Import-CtxFile -CtxFile $ctxFile } finally { $ErrorActionPreference = $prevEap }

        $result | Should -BeFalse
        ($Error | Select-Object -First 1).ToString() | Should -Match 'outside the configured profiles root'
        $env:AI_CTX_PROFILES | Should -Be 'previous'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be 'previous-dirs'
        $env:COPILOT_HOME | Should -Be 'previous-home'
        $env:COPILOT_SKILLS_DIRS | Should -Be 'previous-skills'
        Test-Path -LiteralPath (Join-Path $proj 'project-canon-outside.code-workspace') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'outside') | Should -BeFalse
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($sentinel)) | Should -Be ([Convert]::ToBase64String($before))
    }

    It 'Issue48: in-root canonical profile symlink whose target escapes the profiles root fails atomically' {
        $outside = Join-Path $Script:TestTmp 'outside-symlink-target'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        $sentinel = Join-Path $outside 'AGENTS.md'
        [System.IO.File]::WriteAllText($sentinel, "# outside symlink target`n")
        $before = [System.IO.File]::ReadAllBytes($sentinel)
        $link = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/evil'
        New-Item -ItemType SymbolicLink -Path $link -Target $outside | Out-Null

        $proj = Join-Path $Script:TestTmp 'project-canon-symlink-escape'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "evil:$link"
        $env:AI_CTX_PROFILES = 'previous'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS = 'previous-dirs'
        $env:COPILOT_HOME = 'previous-home'

        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        try { $result = Import-CtxFile -CtxFile $ctxFile } finally { $ErrorActionPreference = $prevEap }

        $result | Should -BeFalse
        ($Error | Select-Object -First 1).ToString() | Should -Match 'outside the configured profiles root'
        $env:AI_CTX_PROFILES | Should -Be 'previous'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be 'previous-dirs'
        $env:COPILOT_HOME | Should -Be 'previous-home'
        Test-Path -LiteralPath (Join-Path $proj 'project-canon-symlink-escape.code-workspace') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'evil') | Should -BeFalse
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($sentinel)) | Should -Be ([Convert]::ToBase64String($before))
    }

    It 'Issue48: direct .ctx canonical profile inside the configured root still activates and identifier activation remains compatible' {
        $baseDir = New-CtxTestProfile -Name 'base'
        $reviewDir = New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n"))
        $archDir = New-CtxTestCanonicalProfile -Name 'arch' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# arch`n"))
        $ghostDir = New-CtxTestCanonicalProfile -Name 'ghost' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# ghost unselected`n"))
        New-CtxTestCanonicalSkill -Profile 'review' -Skill 'review-skill'
        New-CtxTestCanonicalSkill -Profile 'arch' -Skill 'arch-skill'
        New-CtxTestCanonicalSkill -Profile 'ghost' -Skill 'ghost-skill'

        # Capture every source so activation can be proven read-only.
        $sources = @(
            (Join-Path $reviewDir 'AGENTS.md'),
            (Join-Path $archDir 'AGENTS.md'),
            (Join-Path $ghostDir 'AGENTS.md'),
            (Join-Path $reviewDir '.agents/skills/review-skill/SKILL.md'),
            (Join-Path $archDir '.agents/skills/arch-skill/SKILL.md'),
            (Join-Path $ghostDir '.agents/skills/ghost-skill/SKILL.md')
        )
        $before = @{}
        foreach ($s in $sources) { $before[$s] = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($s)) }

        $proj = Join-Path $Script:TestTmp 'project-canon-inroot'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "base:@profile`nreview:$reviewDir`narch:@profile"

        ctx load $ctxFile | Out-Null

        # Mixed legacy/identifier compatibility is preserved.
        $env:AI_CTX_PROFILES | Should -Be 'base+review+arch'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be $baseDir

        # Projections are deterministic and keyed to selected entry order (base
        # is legacy, so the canonical entries keep indexes 2 and 3); only the
        # selected canonical entries appear, never the unselected ghost profile.
        $projDir = Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles'
        ((@(Get-ChildItem -LiteralPath $projDir -File -Filter '*.instructions.md').Name | Sort-Object) -join "`n") | Should -Be "0002-review.instructions.md`n0003-arch.instructions.md"
        ((Get-Content -LiteralPath (Join-Path $projDir '.ctx-managed')) -join "`n") | Should -Be "0002-review.instructions.md`n0003-arch.instructions.md"
        Test-Path -LiteralPath (Join-Path $projDir '0004-ghost.instructions.md') | Should -BeFalse

        # Only the selected profiles' distinct skills are linked; ghost is absent.
        $skillsHome = Join-Path $env:COPILOT_HOME 'skills'
        ((@(Get-ChildItem -LiteralPath $skillsHome).Name | Sort-Object) -join "`n") | Should -Be "arch-skill`nreview-skill"
        (Get-CtxLinkTarget -Path (Join-Path $skillsHome 'review-skill') -Target $null) | Should -Be (Join-Path $reviewDir '.agents/skills/review-skill')
        (Get-CtxLinkTarget -Path (Join-Path $skillsHome 'arch-skill') -Target $null) | Should -Be (Join-Path $archDir '.agents/skills/arch-skill')
        Test-Path -LiteralPath (Join-Path $skillsHome 'ghost-skill') | Should -BeFalse

        # Sources are byte-identical after activation.
        foreach ($s in $sources) {
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($s)) | Should -Be $before[$s]
        }
    }

    It 'Issue48: an intermediate in-root symlink followed by .. is not approved as in-root (filesystem order)' {
        $outsideDir = Join-Path $Script:TestTmp 'outside-escape/dir'
        $outsideProfile = Join-Path $Script:TestTmp 'outside-escape/outside-profile'
        New-Item -ItemType Directory -Path $outsideDir, $outsideProfile -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $outsideProfile 'AGENTS.md'), "# outside`n")
        $link = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/escape-link'
        New-Item -ItemType SymbolicLink -Path $link -Target $outsideDir | Out-Null

        # Filesystem order resolves escape-link -> outside/dir, then .. -> the
        # outside parent; the lexical collapse would wrongly land back in root.
        $crafted = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/escape-link/../outside-profile'
        Test-CtxCanonicalProfileWithinRoot -ProfileDir $crafted | Should -BeFalse
        (Get-CtxPhysicalPath -Path $crafted) | Should -Be $outsideProfile

        # Control: a legitimate in-root canonical profile is still approved.
        $reviewDir = New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n"))
        Test-CtxCanonicalProfileWithinRoot -ProfileDir $reviewDir | Should -BeTrue
    }

    It 'Issue48: a symlink loop in the profile path fails closed without recursing indefinitely' {
        $linkA = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/loop-a'
        $linkB = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/loop-b'
        New-Item -ItemType SymbolicLink -Path $linkA -Target $linkB | Out-Null
        New-Item -ItemType SymbolicLink -Path $linkB -Target $linkA | Out-Null

        (Get-CtxPhysicalPath -Path $linkA) | Should -BeNullOrEmpty
        Test-CtxCanonicalProfileWithinRoot -ProfileDir $linkA | Should -BeFalse
    }

    It 'opt-in external profile root accepts canonical aliases and direct paths' {
        $teamDir = New-CtxTestProfile -Name 'team' -Skill $null
        $externalRoot = Join-Path $Script:TestTmp 'external-profiles'
        $externalProfile = Join-Path $externalRoot 'task-scaffold'
        New-Item -ItemType Directory -Path $externalProfile -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $externalProfile 'AGENTS.md'), "# task scaffold instructions`n")
        $profileLink = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/task-scaffold'
        New-Item -ItemType SymbolicLink -Path $profileLink -Target $externalProfile | Out-Null
        $env:AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT = $externalRoot

        $proj = Join-Path $Script:TestTmp 'project-external-profile'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $ctxFile = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $ctxFile -Value "team:@profile`ntask-scaffold:@profile"
        Import-CtxFile -CtxFile $ctxFile | Should -BeTrue
        $env:AI_CTX_PROFILES | Should -Be 'team+task-scaffold'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be $teamDir
        Test-Path -LiteralPath (Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/0002-task-scaffold.instructions.md') | Should -BeTrue

        Set-Location $proj
        Test-CtxActivation | Should -BeTrue

        $directProj = Join-Path $Script:TestTmp 'project-external-direct-path'
        New-Item -ItemType Directory -Path $directProj -Force | Out-Null
        $directCtx = Join-Path $directProj '.ctx'
        Set-Content -LiteralPath $directCtx -Value "team:$teamDir`ntask-scaffold:$externalProfile"
        Import-CtxFile -CtxFile $directCtx | Should -BeTrue
        $env:AI_CTX_PROFILES | Should -Be 'team+task-scaffold'
        Test-CtxCanonicalProfileWithinRoot -ProfileDir $externalProfile | Should -BeTrue
    }

    It 'external profile allowlist rejects untrusted links and invalid roots without mutation' {
        $null = New-CtxTestProfile -Name 'team' -Skill $null
        $null = New-CtxTestProfile -Name 'review' -Skill $null
        $trustedRoot = Join-Path $Script:TestTmp 'trusted-profiles'
        $untrustedProfile = Join-Path $Script:TestTmp 'untrusted/task-scaffold'
        New-Item -ItemType Directory -Path $trustedRoot, $untrustedProfile -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $untrustedProfile 'AGENTS.md'), "# untrusted`n")
        $profileLink = Join-Path $env:AI_CTX_PROFILES_CONFIG_ROOT 'profiles/evil'
        New-Item -ItemType SymbolicLink -Path $profileLink -Target $untrustedProfile | Out-Null
        $env:AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT = $trustedRoot
        $env:AI_CTX_PROFILES = 'previous'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS = 'previous-dirs'
        $env:COPILOT_HOME = 'previous-home'

        $previous = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        try { ctx team evil } finally { $ErrorActionPreference = $previous }
        ($Error | Select-Object -First 1).ToString() | Should -Match 'invalid profile identifier'
        $env:AI_CTX_PROFILES | Should -Be 'previous'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be 'previous-dirs'
        $env:COPILOT_HOME | Should -Be 'previous-home'

        $proj = Join-Path $Script:TestTmp 'project-untrusted-direct-canonical'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $directCtx = Join-Path $proj '.ctx'
        Set-Content -LiteralPath $directCtx -Value "evil:$untrustedProfile"
        $previous = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        try { $result = Import-CtxFile -CtxFile $directCtx } finally { $ErrorActionPreference = $previous }
        $result | Should -BeFalse
        ($Error | Select-Object -First 1).ToString() | Should -Match 'outside the configured profiles root'
        $env:AI_CTX_PROFILES | Should -Be 'previous'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be 'previous-dirs'
        $env:COPILOT_HOME | Should -Be 'previous-home'

        $env:AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT = Join-Path $Script:TestTmp 'missing-profiles-root'
        $previous = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        try { ctx review } finally { $ErrorActionPreference = $previous }
        ($Error | Select-Object -First 1).ToString() | Should -Match 'external profiles root'
        $env:AI_CTX_PROFILES | Should -Be 'previous'
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be 'previous-dirs'
        $env:COPILOT_HOME | Should -Be 'previous-home'

        $env:AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT = 'relative/profiles'
        $previous = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        try { ctx review } finally { $ErrorActionPreference = $previous }
        ($Error | Select-Object -First 1).ToString() | Should -Match 'must be an absolute path'
        $env:AI_CTX_PROFILES | Should -Be 'previous'
    }

    # --- Issue #48 evidence-map gap coverage -------------------------------

    It 'Issue48: source YAML-like frontmatter is copied as body bytes after the fixed header' {
        New-CtxTestProfile -Name 'base' | Out-Null
        $body = [System.Text.Encoding]::UTF8.GetBytes("---`nname: review`n---`n# body`n")
        $reviewDir = New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes $body
        $before = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $reviewDir 'AGENTS.md')))

        ctx base review | Out-Null
        $proj = Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/0002-review.instructions.md'
        Assert-CtxFileBytes -Path $proj -Expected (Get-CtxProjectionBytes $body)
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $reviewDir 'AGENTS.md'))) | Should -Be $before
    }

    It 'Issue48: a linked ctx-managed manifest fails activation without touching the sentinel' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        $syntheticHome = Join-Path $env:AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT 'base+review'
        $outside = Join-Path $Script:TestTmp 'outside-manifest'
        Set-Content -LiteralPath $outside -Value '0002-review.instructions.md'
        $before = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($outside))
        $projDir = Join-Path $syntheticHome 'instructions/ctx-profiles'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        New-CtxLink -LinkPath (Join-Path $projDir '.ctx-managed') -RealTarget $outside -Kind 'file' | Out-Null
        $env:AI_CTX_PROFILES = 'previous'

        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $out = @(& { ctx base review } *>&1) } finally { $ErrorActionPreference = $prevEap }

        ($out -join "`n") | Should -Match 'malformed projection manifest'
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($outside)) | Should -Be $before
        Test-CtxIsLink -Path (Join-Path $projDir '.ctx-managed') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $projDir '0002-review.instructions.md') | Should -BeFalse
        $env:AI_CTX_PROFILES | Should -Be 'previous'
    }

    It 'Issue48: ctx check fails on altered canonical instruction bytes without changing them' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        $proj = Join-Path $Script:TestTmp 'project-canon-altered'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "base:@profile`nreview:@profile"
        Set-Location $proj
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null
        $target = Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/0002-review.instructions.md'
        Set-Content -LiteralPath $target -Value 'tampered bytes' -NoNewline
        $before = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($target))

        $check = @(& { ctx check } *>&1)
        ($check -join "`n") | Should -Match 'CHECK FAIL instruction:0002-review\.instructions\.md'
        (ctx check) | Should -BeFalse
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($target)) | Should -Be $before
    }

    It 'Issue48: ctx check fails on an unmanifested desired projection without changing the manifest' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        $proj = Join-Path $Script:TestTmp 'project-canon-unmanifested'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "base:@profile`nreview:@profile"
        Set-Location $proj
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null
        $manifest = Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/.ctx-managed'
        $projection = Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/0002-review.instructions.md'
        [System.IO.File]::WriteAllText($manifest, '')
        $manifestBefore = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($manifest))
        $projectionBefore = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($projection))

        $check = @(& { ctx check } *>&1)
        ($check -join "`n") | Should -Match 'CHECK FAIL instruction:0002-review\.instructions\.md'
        (ctx check) | Should -BeFalse
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($manifest)) | Should -Be $manifestBefore
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($projection)) | Should -Be $projectionBefore
    }

    It 'Issue48: ctx check fails read-only on an unsafe instructions directory with canonical entries' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        $proj = Join-Path $Script:TestTmp 'project-canon-unsafe-parent'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "base:@profile`nreview:@profile"
        Set-Location $proj
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null
        $synHome = $env:COPILOT_HOME
        $outside = Join-Path $Script:TestTmp 'outside-check-parent'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Remove-Item -LiteralPath (Join-Path $synHome 'instructions') -Recurse -Force
        New-CtxLink -LinkPath (Join-Path $synHome 'instructions') -RealTarget $outside -Kind 'dir' | Out-Null

        $check = @(& { ctx check } *>&1)
        ($check -join "`n") | Should -Match 'CHECK FAIL instruction:0002-review\.instructions\.md'
        (ctx check) | Should -BeFalse
        Test-CtxIsLink -Path (Join-Path $synHome 'instructions') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $outside 'ctx-profiles') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $outside -Force).Count | Should -Be 0
    }

    It 'Issue48: ctx check fails read-only on a linked ctx-profiles directory with canonical entries' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        $proj = Join-Path $Script:TestTmp 'project-canon-unsafe-profiles'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "base:@profile`nreview:@profile"
        Set-Location $proj
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null
        $synHome = $env:COPILOT_HOME
        $outside = Join-Path $Script:TestTmp 'outside-check-profiles'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Remove-Item -LiteralPath (Join-Path $synHome 'instructions/ctx-profiles') -Recurse -Force
        New-CtxLink -LinkPath (Join-Path $synHome 'instructions/ctx-profiles') -RealTarget $outside -Kind 'dir' | Out-Null

        $check = @(& { ctx check } *>&1)
        ($check -join "`n") | Should -Match 'CHECK FAIL instruction:0002-review\.instructions\.md'
        (ctx check) | Should -BeFalse
        Test-CtxIsLink -Path (Join-Path $synHome 'instructions/ctx-profiles') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $outside -Force).Count | Should -Be 0
    }

    It 'Issue48: ctx check fails read-only on a missing ctx-managed manifest with canonical entries' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        $proj = Join-Path $Script:TestTmp 'project-canon-missing-manifest'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "base:@profile`nreview:@profile"
        Set-Location $proj
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null
        $manifest = Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/.ctx-managed'
        Remove-Item -LiteralPath $manifest -Force

        $check = @(& { ctx check } *>&1)
        ($check -join "`n") | Should -Match 'CHECK FAIL instruction:manifest'
        (ctx check) | Should -BeFalse
        Test-Path -LiteralPath $manifest | Should -BeFalse
    }

    It 'Issue48: ctx check fails read-only on a linked ctx-managed manifest without touching the sentinel' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        $proj = Join-Path $Script:TestTmp 'project-canon-linked-manifest'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "base:@profile`nreview:@profile"
        Set-Location $proj
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null
        $manifest = Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/.ctx-managed'
        $outside = Join-Path $Script:TestTmp 'outside-check-manifest'
        Set-Content -LiteralPath $outside -Value '0002-review.instructions.md'
        $before = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($outside))
        Remove-Item -LiteralPath $manifest -Force
        New-CtxLink -LinkPath $manifest -RealTarget $outside -Kind 'file' | Out-Null

        $check = @(& { ctx check } *>&1)
        ($check -join "`n") | Should -Match 'CHECK FAIL instruction:manifest'
        (ctx check) | Should -BeFalse
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($outside)) | Should -Be $before
        Test-CtxIsLink -Path $manifest | Should -BeTrue
    }

    It 'Issue48: ctx check fails on a malformed regular ctx-managed manifest with canonical entries without mutation' {
        New-CtxTestProfile -Name 'base' | Out-Null
        New-CtxTestCanonicalProfile -Name 'review' -AgentsBytes ([System.Text.Encoding]::UTF8.GetBytes("# review`n")) | Out-Null
        $proj = Join-Path $Script:TestTmp 'project-canon-malformed-manifest'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "base:@profile`nreview:@profile"
        Set-Location $proj
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx') | Out-Null
        $manifest = Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/.ctx-managed'
        $projection = Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles/0002-review.instructions.md'
        Set-Content -LiteralPath $manifest -Value 'bad name'
        $manifestBefore = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($manifest))
        $projectionBefore = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($projection))
        $homeBefore = $env:COPILOT_HOME
        $profilesBefore = $env:AI_CTX_PROFILES
        $dirsBefore = $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS

        $check = @(& { ctx check } *>&1)
        ($check -join "`n") | Should -Match 'CHECK FAIL instruction:manifest'
        (ctx check) | Should -BeFalse
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($manifest)) | Should -Be $manifestBefore
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($projection)) | Should -Be $projectionBefore
        $env:COPILOT_HOME | Should -Be $homeBefore
        $env:AI_CTX_PROFILES | Should -Be $profilesBefore
        $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be $dirsBefore
    }

    It 'PR65: external root backslash on Unix fails closed instead of following the slash-sibling symlink' -Skip:($IsWindows -or ($env:OS -ceq 'Windows_NT')) {
        # On Unix a backslash is a literal filename character, not a separator.
        # The configured root here is a real directory named "trusted\root".
        $literalRoot = [System.IO.Path]::Combine($Script:TestTmp, ('trusted' + [char]0x5C + 'root'))
        [System.IO.Directory]::CreateDirectory($literalRoot) | Out-Null

        # A normalized slash sibling "trusted/root" is a symlink to an
        # attacker-controlled directory that contains a rogue profile.
        $attacker = [System.IO.Path]::Combine($Script:TestTmp, 'attacker')
        [System.IO.Directory]::CreateDirectory($attacker) | Out-Null
        [System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($attacker, 'rogue')) | Out-Null
        [System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($Script:TestTmp, 'trusted')) | Out-Null
        $slashSibling = [System.IO.Path]::Combine($Script:TestTmp, 'trusted', 'root')
        [System.IO.Directory]::CreateSymbolicLink($slashSibling, $attacker) | Out-Null

        $env:AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT = $literalRoot

        # Fail closed: reject a backslash-containing external root on Unix with
        # an error that tells the user to use '/' separators.
        $err = $null
        try { Get-CtxExternalProfilesRoot | Out-Null } catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -Match 'backslash'
        $err.Exception.Message | Should -Match 'separator'
        $err.Exception.Message | Should -Match '/'

        # The outside profile must not be resolvable through the slash sibling.
        { Resolve-CtxProfileIdentifier -Name 'rogue' } | Should -Throw
    }

    It 'PR65: invalid external profiles root does not suppress primary-root suggestions in Get-CtxProfileName' {
        New-CtxTestProfile -Name 'review' | Out-Null
        $env:AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT = 'relative/profiles'

        @(Get-CtxProfileName) | Should -Contain 'review'
    }

    It 'Issue67: ctx current fails when the missing .NET engine DLL path does not exist' {
        # The shell adapter must delegate `current` to the .NET 10 engine named
        # by CTX_ENGINE_DLL. A missing DLL is a hard failure with no old-shell
        # fallback, even when no profile is active.
        $priorSet = Test-Path Env:\CTX_ENGINE_DLL
        $priorValue = $env:CTX_ENGINE_DLL
        $missingDll = Join-Path $Script:TestTmp 'missing-engine/no-such-ctx-engine.dll'
        Test-Path -LiteralPath $missingDll | Should -BeFalse

        try {
            $env:CTX_ENGINE_DLL = $missingDll

            $previous = $ErrorActionPreference
            $ErrorActionPreference = 'SilentlyContinue'
            $errorCountBefore = $Error.Count
            $caught = $null
            $out = @()
            try {
                $out = @(& { ctx current } *>&1)
            } catch {
                $caught = $_
            } finally {
                $ErrorActionPreference = $previous
            }

            $newErrors = @($Error | Select-Object -First ($Error.Count - $errorCountBefore))
            $err = @($newErrors + @($caught) | Where-Object { $_ })
            $err | Should -Not -BeNullOrEmpty

            $text = ($out | ForEach-Object { $_.ToString() }) -join "`n"
            $text | Should -Not -Match 'No active AI context'
            $combined = $text + "`n" + (($err | ForEach-Object { $_.ToString() }) -join "`n")
            $combined | Should -Match ([regex]::Escape($missingDll))
            $combined | Should -Match '(?i)engine'
        } finally {
            if ($priorSet) {
                $env:CTX_ENGINE_DLL = $priorValue
            } else {
                Remove-Item Env:\CTX_ENGINE_DLL -ErrorAction SilentlyContinue
            }
        }
    }


    Context 'CtxLocalRoots: config-root and external-profiles-root directives' {

        BeforeAll {
            function Script:New-CtxLocalRootsLegacy {
                param([string]$Root, [string]$Name)
                $dir = Join-Path $Root "profiles/$Name"
                New-Item -ItemType Directory -Path (Join-Path $dir '.github/instructions') -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $dir ".github/instructions/$Name.instructions.md") -Value "# $Name instructions"
                return $dir
            }

            function Script:New-CtxLocalRootsCanonical {
                param([string]$Root, [string]$Name, [string]$Skill)
                $dir = Join-Path $Root $Name
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $dir 'AGENTS.md'), "# $Name canonical instructions`n")
                if ($Skill) {
                    $skillDir = Join-Path $dir ".agents/skills/$Skill"
                    New-Item -ItemType Directory -Path $skillDir -Force | Out-Null
                    [System.IO.File]::WriteAllText((Join-Path $skillDir 'SKILL.md'), "---`nname: $Skill`ndescription: test`n---`n")
                }
                return $dir
            }

            function Script:New-CtxLocalRootsDirLink {
                # Creates a directory link at $Path to $Target, preferring a
                # symbolic link and falling back to a Windows junction when
                # symlink privilege is unavailable. Returns $null when neither
                # can be created.
                param([string]$Path, [string]$Target)
                try {
                    New-Item -ItemType SymbolicLink -Path $Path -Target $Target -ErrorAction Stop | Out-Null
                    return 'symlink'
                } catch {
                    if (-not ($IsWindows -or ($env:OS -ceq 'Windows_NT'))) { return $null }
                    try {
                        New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop | Out-Null
                        return 'junction'
                    } catch {
                        return $null
                    }
                }
            }

            function Script:New-CtxLocalRootsFixture {
                # Builds a project whose .ctx uses @profile entries for two legacy
                # primary profiles plus one canonical external profile, with the
                # two root directives placed after every entry. $TaskIdentifier
                # overrides the task-scaffold entry value (default: its direct
                # relative path) so callers can exercise @profile lookup.
                param([switch]$Absolute, [string]$TaskIdentifier)
                $base = Join-Path $Script:TestTmp ("local-roots-" + [guid]::NewGuid().ToString('N'))
                $proj = Join-Path $base 'project'
                New-Item -ItemType Directory -Path $proj -Force | Out-Null
                $configRoot = Join-Path $proj 'ai-config'
                $externalRoot = Join-Path $proj 'external-profiles'
                New-Item -ItemType Directory -Path (Join-Path $configRoot 'profiles'), $externalRoot -Force | Out-Null
                $teamDir = New-CtxLocalRootsLegacy -Root $configRoot -Name 'team'
                $dotnetDir = New-CtxLocalRootsLegacy -Root $configRoot -Name 'dotnet'
                $taskDir = New-CtxLocalRootsCanonical -Root $externalRoot -Name 'task-scaffold' -Skill 'task-skill'
                $configPath = if ($Absolute) { $configRoot } else { './ai-config' }
                $externalPath = if ($Absolute) { $externalRoot } else { './external-profiles' }
                $taskPath = if ($TaskIdentifier) { $TaskIdentifier } elseif ($Absolute) { $taskDir } else { './external-profiles/task-scaffold' }
                $ctxFile = Join-Path $proj '.ctx'
                Set-Content -LiteralPath $ctxFile -Value @(
                    'team:@profile'
                    'dotnet:@profile'
                    "task-scaffold:$taskPath"
                    "config-root:$configPath"
                    "external-profiles-root:$externalPath"
                )
                return [pscustomobject]@{
                    Base = $base; Project = $proj; CtxFile = $ctxFile
                    ConfigRoot = $configRoot; ExternalRoot = $externalRoot
                    TeamDir = $teamDir; DotnetDir = $dotnetDir; TaskDir = $taskDir
                    Workspace = Join-Path $proj "$(Split-Path -Leaf $proj).code-workspace"
                }
            }
        }

        It 'loads a real mixed fixture using relative root directives placed after the entries' {
            Remove-Item Env:\AI_CTX_PROFILES_CONFIG_ROOT -ErrorAction SilentlyContinue
            Remove-Item Env:\AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT -ErrorAction SilentlyContinue
            $f = New-CtxLocalRootsFixture

            ctx load $f.CtxFile | Should -BeTrue

            $env:AI_CTX_PROFILES | Should -Be 'team+dotnet+task-scaffold'
            $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be (($f.TeamDir, $f.DotnetDir) -join ',')
            (Test-Path Env:\AI_CTX_PROFILES_CONFIG_ROOT) | Should -BeFalse
            (Test-Path Env:\AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT) | Should -BeFalse

            $projDir = Join-Path $env:COPILOT_HOME 'instructions/ctx-profiles'
            Test-Path -LiteralPath (Join-Path $projDir '0003-task-scaffold.instructions.md') | Should -BeTrue
            ((@(Get-ChildItem -LiteralPath $projDir -File -Filter '*.instructions.md').Name | Sort-Object) -join "`n") | Should -Be '0003-task-scaffold.instructions.md'
            (Get-CtxLinkTarget -Path (Join-Path $env:COPILOT_HOME 'skills/task-skill') -Target $null) | Should -Be (Join-Path $f.TaskDir '.agents/skills/task-skill')

            $ws = Get-Content -LiteralPath $f.Workspace -Raw | ConvertFrom-Json
            $folderNames = @($ws.folders | ForEach-Object { $_.name })
            $folderNames | Should -Contain 'ctx: team'
            $folderNames | Should -Contain 'ctx: dotnet'
            $folderNames | Should -Contain 'ctx: task-scaffold'
            $folderNames | Should -Not -Contain 'ctx: config-root'
            $folderNames | Should -Not -Contain 'ctx: external-profiles-root'

            Set-Location $f.Project
            (ctx check) | Should -BeTrue
        }

        It 'ctx check passes after ctx load of a nested relative .ctx through a non-normalized path (#75)' {
            Remove-Item Env:\AI_CTX_PROFILES_CONFIG_ROOT -ErrorAction SilentlyContinue
            Remove-Item Env:\AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT -ErrorAction SilentlyContinue
            $base = Join-Path $Script:TestTmp ("local-roots-nested-" + [guid]::NewGuid().ToString('N'))
            $configRoot = Join-Path $base 'copilot-ai-tools'
            $externalRoot = Join-Path $base 'external-profiles'
            New-Item -ItemType Directory -Path (Join-Path $configRoot 'profiles'), $externalRoot -Force | Out-Null
            $teamDir = New-CtxLocalRootsLegacy -Root $configRoot -Name 'team'
            $null = New-CtxLocalRootsCanonical -Root $externalRoot -Name 'task-scaffold' -Skill 'task-skill'
            $task = Join-Path $base 'x/y/task'
            New-Item -ItemType Directory -Path $task -Force | Out-Null
            # ai-task-scaffold root mode: every path relative to the task folder.
            Set-Content -LiteralPath (Join-Path $task '.ctx') -Value @(
                'config-root:../../../copilot-ai-tools'
                'external-profiles-root:../../../external-profiles'
                'team:../../../copilot-ai-tools/profiles/team'
                'task-scaffold:../../../external-profiles/task-scaffold'
            )

            Set-Location (Split-Path -Parent $task)
            ctx load './task/.ctx' | Should -BeTrue
            Join-Path $task 'task.code-workspace' | Should -Exist
            # Relative entries are stored without "." / ".." segments.
            $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be ([System.IO.Path]::GetFullPath($teamDir))
            Set-Location $task
            # The prompt hook must not re-activate the folder ctx load just activated.
            @(& { Invoke-CtxAutoLoad } 6>&1).Count | Should -Be 0

            (ctx check) | Should -BeTrue
        }

        It 'ctx clear --all removes the workspace generated at a custom filesystem PSDrive root (#75)' {
            $root = Join-Path $Script:TestTmp ("psdrive-root-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $teamDir = New-CtxLocalRootsLegacy -Root (Join-Path $Script:TestTmp 'psdrive-config') -Name 'team'
            Set-Content -LiteralPath (Join-Path $root '.ctx') -Value "team:$teamDir"
            $workspace = Join-Path $root "$(Split-Path -Leaf $root).code-workspace"
            New-PSDrive -Name CtxT75 -PSProvider FileSystem -Root $root | Out-Null
            try {
                Set-Location CtxT75:\
                ctx load '.ctx' | Should -BeTrue
                $workspace | Should -Exist
                (ctx check) | Should -BeTrue
                ctx clear --all | Out-Null
                $workspace | Should -Not -Exist
            } finally {
                Set-Location $env:HOME
                Remove-PSDrive -Name CtxT75 -ErrorAction SilentlyContinue
            }
        }

        It 'supports absolute root directives and leaves both root env vars untouched' {
            Remove-Item Env:\AI_CTX_PROFILES_CONFIG_ROOT -ErrorAction SilentlyContinue
            Remove-Item Env:\AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT -ErrorAction SilentlyContinue
            $f = New-CtxLocalRootsFixture -Absolute

            ctx load $f.CtxFile | Should -BeTrue
            $env:AI_CTX_PROFILES | Should -Be 'team+dotnet+task-scaffold'
            (Test-Path Env:\AI_CTX_PROFILES_CONFIG_ROOT) | Should -BeFalse
            (Test-Path Env:\AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT) | Should -BeFalse

            Set-Location $f.Project
            (ctx check) | Should -BeTrue
        }

        It 'local directives override the matching env roots without leaking to manual ctx or later contexts' {
            $envConfig = Join-Path $Script:TestTmp 'env-ai-config'
            $envTeamDir = New-CtxLocalRootsLegacy -Root $envConfig -Name 'envteam'
            $envExternal = Join-Path $Script:TestTmp 'env-external-profiles'
            $null = New-CtxLocalRootsCanonical -Root $envExternal -Name 'envcanon'
            $env:AI_CTX_PROFILES_CONFIG_ROOT = $envConfig
            $env:AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT = $envExternal

            $f = New-CtxLocalRootsFixture
            ctx load $f.CtxFile | Should -BeTrue
            $env:AI_CTX_PROFILES | Should -Be 'team+dotnet+task-scaffold'
            $env:AI_CTX_PROFILES_CONFIG_ROOT | Should -Be $envConfig
            $env:AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT | Should -Be $envExternal

            Set-Location $env:HOME
            ctx envteam | Out-Null
            $env:AI_CTX_PROFILES | Should -Be 'envteam'
            $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be $envTeamDir

            $proj2 = Join-Path $Script:TestTmp 'project-env-root-only'
            New-Item -ItemType Directory -Path $proj2 -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $proj2 '.ctx') -Value 'envteam:@profile'
            ctx load (Join-Path $proj2 '.ctx') | Should -BeTrue
            $env:AI_CTX_PROFILES | Should -Be 'envteam'
        }

        It 'a legacy .ctx without root directives still resolves through the env roots' {
            $teamDir = New-CtxTestProfile -Name 'plainteam'
            $proj = Join-Path $Script:TestTmp 'project-legacy-no-directive'
            New-Item -ItemType Directory -Path $proj -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value 'plainteam:@profile'
            ctx load (Join-Path $proj '.ctx') | Should -BeTrue
            $env:AI_CTX_PROFILES | Should -Be 'plainteam'
            $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be $teamDir
            Set-Location $proj
            (ctx check) | Should -BeTrue
        }

        It 'auto-load applies the root directives but never writes a workspace file' {
            Remove-Item Env:\AI_CTX_PROFILES_CONFIG_ROOT -ErrorAction SilentlyContinue
            Remove-Item Env:\AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT -ErrorAction SilentlyContinue
            $f = New-CtxLocalRootsFixture
            Set-Location $f.Project
            Invoke-CtxAutoLoad | Out-Null
            $env:AI_CTX_PROFILES | Should -Be 'team+dotnet+task-scaffold'
            Test-Path -LiteralPath $f.Workspace | Should -BeFalse
        }

        It 'loads valid local roots even when both env root variables are invalid' {
            $badConfig = Join-Path $Script:TestTmp 'invalid-env-ai-config'
            $badExternal = Join-Path $Script:TestTmp 'invalid-env-external-profiles'
            $env:AI_CTX_PROFILES_CONFIG_ROOT = $badConfig
            $env:AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT = $badExternal

            $f = New-CtxLocalRootsFixture -TaskIdentifier '@profile'
            ctx load $f.CtxFile | Should -BeTrue

            $env:AI_CTX_PROFILES | Should -Be 'team+dotnet+task-scaffold'
            $env:AI_CTX_PROFILES_CONFIG_ROOT | Should -Be $badConfig
            $env:AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT | Should -Be $badExternal
            (Get-CtxLinkTarget -Path (Join-Path $env:COPILOT_HOME 'skills/task-skill') -Target $null) | Should -Be (Join-Path $f.TaskDir '.agents/skills/task-skill')

            Set-Location $f.Project
            (ctx check) | Should -BeTrue
        }

        It 'rejects partially qualified Windows root directives before normalization' {
            if (-not ($IsWindows -or ($env:OS -ceq 'Windows_NT'))) {
                Set-ItResult -Skipped -Because 'drive-relative and root-relative ambiguity is Windows-only'
                return
            }
            $cases = @(
                @{ Label = 'drive-relative config-root'; Line = 'config-root:C:relative' },
                @{ Label = 'root-relative external-profiles-root'; Line = 'external-profiles-root:\root-relative' }
            )
            foreach ($case in $cases) {
                $proj = Join-Path $Script:TestTmp ("partial-root-" + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $proj -Force | Out-Null
                $ctxFile = Join-Path $proj '.ctx'
                Set-Content -LiteralPath $ctxFile -Value @('team:@profile', $case.Line)
                { Parse-CtxFile -CtxFile $ctxFile } | Should -Throw '*fully qualified*' -Because $case.Label
            }
        }

        It 'rejects invalid or duplicate root directives while preserving the active context' {
            $null = New-CtxTestProfile -Name 'prevteam'
            ctx prevteam | Out-Null
            $prevContext = $env:AI_CTX_PROFILES
            $prevDirs = $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS
            $prevHome = $env:COPILOT_HOME
            $prevContext | Should -Be 'prevteam'

            $f = New-CtxLocalRootsFixture
            $notDir = Join-Path $f.Project 'not-a-directory'
            Set-Content -LiteralPath $notDir -Value 'file'
            $fsRoot = [System.IO.Path]::GetPathRoot($f.Project)

            $cases = @(
                @{ Label = 'duplicate config-root'; Lines = @('team:@profile', "config-root:$($f.ConfigRoot)", "Config-Root:$($f.ConfigRoot)") },
                @{ Label = 'duplicate external-profiles-root'; Lines = @("task-scaffold:$($f.TaskDir)", "external-profiles-root:$($f.ExternalRoot)", "external-profiles-root:$($f.ExternalRoot)") },
                @{ Label = 'empty config-root'; Lines = @('team:@profile', 'config-root:') },
                @{ Label = 'missing config-root'; Lines = @('team:@profile', 'config-root:./no-such-root') },
                @{ Label = 'non-directory config-root'; Lines = @('team:@profile', "config-root:$notDir") },
                @{ Label = 'filesystem-root external-profiles-root'; Lines = @('task-scaffold:@profile', "external-profiles-root:$fsRoot") }
            )
            if (-not ($IsWindows -or ($env:OS -ceq 'Windows_NT'))) {
                $cases += @{ Label = 'backslash external-profiles-root on Unix'; Lines = @('task-scaffold:@profile', 'external-profiles-root:.\evil') }
            }

            foreach ($case in $cases) {
                $badProj = Join-Path $Script:TestTmp ("bad-roots-" + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $badProj -Force | Out-Null
                $badCtx = Join-Path $badProj '.ctx'
                Set-Content -LiteralPath $badCtx -Value $case.Lines
                $previous = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
                try { $result = Import-CtxFile -CtxFile $badCtx } finally { $ErrorActionPreference = $previous }
                $result | Should -BeFalse -Because $case.Label
                $env:AI_CTX_PROFILES | Should -Be $prevContext -Because $case.Label
                $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be $prevDirs -Because $case.Label
                $env:COPILOT_HOME | Should -Be $prevHome -Because $case.Label
            }
        }

        It 'rejects canonical profiles that escape through a sibling path prefix' {
            $f = New-CtxLocalRootsFixture

            $null = New-CtxTestProfile -Name 'escapeprev'
            ctx escapeprev | Out-Null
            $prevContext = $env:AI_CTX_PROFILES
            $prevDirs = $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS
            $prevHome = $env:COPILOT_HOME
            $prevContext | Should -Be 'escapeprev'

            $siblingProfile = Join-Path ($f.ExternalRoot + '-evil') 'task-scaffold'
            New-Item -ItemType Directory -Path $siblingProfile -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $siblingProfile 'AGENTS.md'), "# sibling canonical`n")
            $siblingProj = Join-Path $Script:TestTmp 'project-sibling-escape'
            New-Item -ItemType Directory -Path $siblingProj -Force | Out-Null
            $siblingCtx = Join-Path $siblingProj '.ctx'
            Set-Content -LiteralPath $siblingCtx -Value @("escape:$siblingProfile", "external-profiles-root:$($f.ExternalRoot)")
            $previous = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
            try { $result = Import-CtxFile -CtxFile $siblingCtx } finally { $ErrorActionPreference = $previous }
            $result | Should -BeFalse
            $env:AI_CTX_PROFILES | Should -Be $prevContext
            $env:COPILOT_HOME | Should -Be $prevHome
            $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be $prevDirs
        }

        It 'rejects canonical profiles that physically escape through a directory link' {
            $f = New-CtxLocalRootsFixture
            $outside = Join-Path $Script:TestTmp 'outside-canonical'
            New-Item -ItemType Directory -Path $outside -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $outside 'AGENTS.md'), "# outside canonical`n")
            $link = Join-Path $f.ExternalRoot 'linked-canonical'
            if (-not (New-CtxLocalRootsDirLink -Path $link -Target $outside)) {
                Set-ItResult -Skipped -Because 'symlink/junction creation unavailable'
                return
            }

            $null = New-CtxTestProfile -Name 'escapeprev'
            ctx escapeprev | Out-Null
            $prevContext = $env:AI_CTX_PROFILES
            $prevDirs = $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS
            $prevHome = $env:COPILOT_HOME
            $prevContext | Should -Be 'escapeprev'

            $linkProj = Join-Path $Script:TestTmp 'project-symlink-escape'
            New-Item -ItemType Directory -Path $linkProj -Force | Out-Null
            $linkCtx = Join-Path $linkProj '.ctx'
            Set-Content -LiteralPath $linkCtx -Value @("escape:$link", "external-profiles-root:$($f.ExternalRoot)")
            $previous = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
            try { $result = Import-CtxFile -CtxFile $linkCtx } finally { $ErrorActionPreference = $previous }
            $result | Should -BeFalse
            $env:AI_CTX_PROFILES | Should -Be $prevContext
            $env:COPILOT_HOME | Should -Be $prevHome
            $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be $prevDirs

            # A symlinked child of the trusted external root whose physical
            # target is outside the root must not resolve through @profile.
            $profileLink = Join-Path $f.ExternalRoot 'escape'
            New-CtxLocalRootsDirLink -Path $profileLink -Target $outside | Should -Not -BeNullOrEmpty
            $profileProj = Join-Path $Script:TestTmp 'project-profile-symlink-escape'
            New-Item -ItemType Directory -Path $profileProj -Force | Out-Null
            $profileCtx = Join-Path $profileProj '.ctx'
            Set-Content -LiteralPath $profileCtx -Value @('escape:@profile', "external-profiles-root:$($f.ExternalRoot)")
            $previous = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
            try { $result = Import-CtxFile -CtxFile $profileCtx } finally { $ErrorActionPreference = $previous }
            $result | Should -BeFalse
            $env:AI_CTX_PROFILES | Should -Be $prevContext
            $env:COPILOT_HOME | Should -Be $prevHome
            $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be $prevDirs
        }

        It 'PR73: resolves a relative external-profiles-root through a physical link component' {
            Remove-Item Env:\AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT -ErrorAction SilentlyContinue
            $configRoot = $env:AI_CTX_PROFILES_CONFIG_ROOT
            $teamDir = New-CtxTestProfile -Name 'team'

            $base = Join-Path $Script:TestTmp ("physical-root-" + [guid]::NewGuid().ToString('N'))
            $proj = Join-Path $base 'project'
            $lexicalTrusted = Join-Path $proj 'trusted'
            $outsideTrusted = Join-Path $base 'outside/trusted'
            $linkTarget = Join-Path $base 'outside/nested'
            New-Item -ItemType Directory -Path $proj, $lexicalTrusted, $outsideTrusted, $linkTarget -Force | Out-Null

            $null = New-CtxLocalRootsCanonical -Root $lexicalTrusted -Name 'task-scaffold' -Skill 'task-skill'
            $physicalProfile = New-CtxLocalRootsCanonical -Root $outsideTrusted -Name 'task-scaffold' -Skill 'task-skill'

            $link = Join-Path $proj 'link'
            if (-not (New-CtxLocalRootsDirLink -Path $link -Target $linkTarget)) {
                Set-ItResult -Skipped -Because 'symlink/junction creation unavailable'
                return
            }

            $ctxFile = Join-Path $proj '.ctx'
            Set-Content -LiteralPath $ctxFile -Value @(
                'team:@profile'
                'task-scaffold:@profile'
                'external-profiles-root:./link/../trusted'
            )

            ctx load $ctxFile | Should -BeTrue
            $env:AI_CTX_PROFILES | Should -Be 'team+task-scaffold'
            $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS | Should -Be $teamDir
            $env:AI_CTX_PROFILES_CONFIG_ROOT | Should -Be $configRoot
            (Test-Path Env:\AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT) | Should -BeFalse
            (Get-CtxLinkTarget -Path (Join-Path $env:COPILOT_HOME 'skills/task-skill') -Target $null) | Should -Be (Join-Path $physicalProfile '.agents/skills/task-skill')

            Set-Location $proj
            (ctx check) | Should -BeTrue
        }
    }
}
