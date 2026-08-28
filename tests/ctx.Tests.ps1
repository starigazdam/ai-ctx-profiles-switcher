#Requires -Modules Pester
<#
.SYNOPSIS
    Pester test suite for ctx.ps1 — mirrors tests/ctx.bats (historical design
    in docs/design-history-copilot-home.md
    section 5.2), including COPILOT_HOME per-folder skill isolation and the
    3.4a self-healing reconciliation hazard fix.

.NOTES
    Every test runs against an isolated $HOME / $env:AI_CONFIG_ROOT /
    COPILOT_HOME root (via CTX_COPILOT_DIR / CTX_HOMES_ROOT overrides)
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
        $profileDir = Join-Path $env:AI_CONFIG_ROOT "profiles\$Name"
        New-Item -ItemType Directory -Path (Join-Path $profileDir '.github\instructions') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $profileDir ".github\instructions\$Name.instructions.md") -Value "# $Name instructions"
        if ($Skill) {
            $skillDir = Join-Path $profileDir ".github\skills\$Skill"
            New-Item -ItemType Directory -Path $skillDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $skillDir 'SKILL.md') -Value "---`nname: $Skill`ndescription: Test skill $Skill`n---`n"
        }
        return $profileDir
    }
}

Describe 'ctx.ps1 COPILOT_HOME isolation' {

    BeforeEach {
        $Script:TestTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ctx-pester-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $Script:TestTmp -Force | Out-Null

        $env:HOME = Join-Path $Script:TestTmp 'home'
        $env:AI_CONFIG_ROOT = Join-Path $Script:TestTmp 'ai-config'
        $env:CTX_COPILOT_DIR = Join-Path $Script:TestTmp 'copilot'
        $env:CTX_HOMES_ROOT = Join-Path $env:HOME '.config\ctx\homes'

        New-Item -ItemType Directory -Path $env:HOME -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $env:AI_CONFIG_ROOT 'profiles') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $env:AI_CONFIG_ROOT 'shared') -Force | Out-Null
        New-Item -ItemType Directory -Path $env:CTX_COPILOT_DIR -Force | Out-Null

        Remove-Item Env:\AI_CONTEXT -ErrorAction SilentlyContinue
        Remove-Item Env:\COPILOT_CUSTOM_INSTRUCTIONS_DIRS -ErrorAction SilentlyContinue
        Remove-Item Env:\COPILOT_HOME -ErrorAction SilentlyContinue
        Remove-Item Env:\CTX_AUTO_LOAD -ErrorAction SilentlyContinue
        $Script:CtxAutoLoadDir = $null
        $Script:CtxAutoLoadHomeOverride = $null

        . $Script:CtxSrc
    }

    AfterEach {
        Remove-Item -LiteralPath $Script:TestTmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    function New-CtxTestProfile {
        param([string]$Name, [string]$Skill)
        $profileDir = Join-Path $env:AI_CONFIG_ROOT "profiles\$Name"
        New-Item -ItemType Directory -Path (Join-Path $profileDir '.github\instructions') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $profileDir ".github\instructions\$Name.instructions.md") -Value "# $Name instructions"
        if ($Skill) {
            $skillDir = Join-Path $profileDir ".github\skills\$Skill"
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
        $link = Join-Path $env:COPILOT_HOME 'skills\review-skill'
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
        Test-Path -LiteralPath (Join-Path $reviewHome 'skills\review-skill') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $reviewHome 'skills\test-skill') | Should -BeFalse

        ctx test
        $testHome = $env:COPILOT_HOME
        $testHome | Should -Not -Be $reviewHome
        Test-Path -LiteralPath (Join-Path $testHome 'skills\test-skill') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $testHome 'skills\review-skill') | Should -BeFalse
    }

    It 'Test 3b: .ctx multi-entry activation puts both skills in one home, no bleed' {
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        $testDir = New-CtxTestProfile -Name 'test' -Skill 'test-skill'

        $proj = Join-Path $Script:TestTmp 'project'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir`ntest:$testDir"

        Import-CtxFile -CtxFile (Join-Path $proj '.ctx')
        $combinedHome = $env:COPILOT_HOME
        Test-Path -LiteralPath (Join-Path $combinedHome 'skills\review-skill') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $combinedHome 'skills\test-skill') | Should -BeTrue
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
        $link = Join-Path $env:COPILOT_HOME 'skills\review-skill'
        Test-Path -LiteralPath $link | Should -BeTrue

        Remove-Item -LiteralPath (Join-Path $reviewDir '.github\skills\review-skill') -Recurse -Force
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
        $proj = Join-Path $repoRoot 'examples\copilot-cli-dotctx-test-review'
        Test-Path -LiteralPath $proj | Should -BeTrue

        Import-CtxFile -CtxFile (Join-Path $proj '.ctx')

        $env:COPILOT_HOME | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $env:COPILOT_HOME 'skills\review-profile-skill') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $env:COPILOT_HOME 'skills\test-profile-skill') | Should -BeTrue
    }

    It 'Test 9: fresh activation does not create settings.local.json' {
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'

        $proj = Join-Path $Script:TestTmp 'project9'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"

        Import-CtxFile -CtxFile (Join-Path $proj '.ctx')

        Test-Path -LiteralPath (Join-Path $proj '.github\copilot\settings.local.json') | Should -BeFalse
    }

    It 'Test 9b: manual ctx activation does not create settings.local.json' {
        $reviewDir = New-CtxTestProfile -Name 'review' -Skill 'review-skill'
        ctx review
        Test-Path -LiteralPath (Join-Path $reviewDir '.github\copilot') | Should -BeFalse
    }

    It 'Test 10: ctx warns and does not crash when link creation fails' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null

        Mock New-CtxLink { return $false } -ModuleName $null

        ctx review -WarningVariable warnings -WarningAction SilentlyContinue

        $env:COPILOT_HOME | Should -BeNullOrEmpty
    }

    It 'Test 11: test-profile-skill SKILL.md has well-formed frontmatter' {
        $repoRoot = Split-Path -Parent $Script:CtxSrc
        $skillMd = Join-Path $repoRoot 'examples\ai-profiles\test\.github\skills\test-profile-skill\SKILL.md'
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
        $reviewDir = Join-Path (Join-Path $env:AI_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "home: .copilot-ctx`nreview:$reviewDir"

        Import-CtxFile -CtxFile (Join-Path $proj '.ctx')

        $expectedHome = Join-Path $proj '.copilot-ctx'
        $env:COPILOT_HOME | Should -Be $expectedHome
        Test-Path -LiteralPath $env:COPILOT_HOME -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path (Join-Path $env:COPILOT_HOME 'skills') 'review-skill') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $env:CTX_HOMES_ROOT 'review') | Should -BeFalse
    }

    It 'Test 16: .ctx without a home: directive still uses the centralized default' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null

        $proj = Join-Path $Script:TestTmp 'project-nohome'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "review:$reviewDir"

        Import-CtxFile -CtxFile (Join-Path $proj '.ctx')

        $env:COPILOT_HOME | Should -Be (Join-Path $env:CTX_HOMES_ROOT 'review')
    }

    It 'Test 17: home: directive with absolute path is used as-is' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null

        $proj = Join-Path $env:HOME 'project-home-abs'
        $customHome = Join-Path $env:HOME 'custom-copilot-home'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "home: $customHome`nreview:$reviewDir"

        Import-CtxFile -CtxFile (Join-Path $proj '.ctx')

        $env:COPILOT_HOME | Should -Be $customHome
        Test-Path -LiteralPath (Join-Path (Join-Path $env:COPILOT_HOME 'skills') 'review-skill') | Should -BeTrue
    }

    It 'Test 18: Clear-CtxContext -All removes the custom home: location, not the centralized one' {
        New-CtxTestProfile -Name 'review' -Skill 'review-skill' | Out-Null

        $proj = Join-Path $env:HOME 'project-home-clear'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "home: .copilot-ctx`nreview:$reviewDir"

        Import-CtxFile -CtxFile (Join-Path $proj '.ctx')
        $customHome = $env:COPILOT_HOME
        Test-Path -LiteralPath $customHome -PathType Container | Should -BeTrue

        $Script:CtxAutoLoadDir = $proj
        Clear-CtxContext -All

        Test-Path -LiteralPath $customHome | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $env:CTX_HOMES_ROOT 'review') | Should -BeFalse
    }

    It 'Test 19: duplicate home: directive in .ctx is rejected' {
        $proj = Join-Path $env:HOME 'project-home-dup'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CONFIG_ROOT 'profiles') 'review'
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
        $custom = Join-Path $env:HOME '.config\ctx\homes\project-valid\nested'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "home:$custom`nreview:$reviewDir"
        Import-CtxFile -CtxFile (Join-Path $proj '.ctx')
        $env:COPILOT_HOME | Should -Be $custom
        Test-Path -LiteralPath $custom -PathType Container | Should -BeTrue
    }

    It 'Test 21: home: rejects traversal outside HOME and preserves active context' {
        $proj = Join-Path $Script:TestTmp 'project-home-traversal'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "home:..\outside`nreview:$reviewDir"
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        try { $result = Import-CtxFile -CtxFile (Join-Path $proj '.ctx') } finally { $ErrorActionPreference = $prevEap }
        $result | Should -Be $false
        ($Error | Select-Object -First 1).ToString() | Should -Match 'unsafe home'
        Test-Path -LiteralPath (Join-Path $Script:TestTmp 'outside') | Should -BeFalse
        $env:AI_CONTEXT | Should -BeNullOrEmpty
    }

    It 'Test 22: home: rejects absolute paths outside allowed roots' {
        $proj = Join-Path $Script:TestTmp 'project-home-absolute'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $reviewDir = Join-Path (Join-Path $env:AI_CONFIG_ROOT 'profiles') 'review'
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
        $reviewDir = Join-Path (Join-Path $env:AI_CONFIG_ROOT 'profiles') 'review'
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
        $reviewDir = Join-Path (Join-Path $env:AI_CONFIG_ROOT 'profiles') 'review'
        Set-Content -LiteralPath (Join-Path $proj '.ctx') -Value "home:$(Join-Path $proj 'link\child')`nreview:$reviewDir"
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        try { $result = Import-CtxFile -CtxFile (Join-Path $proj '.ctx') } finally { $ErrorActionPreference = $prevEap }
        $result | Should -Be $false
        ($Error | Select-Object -First 1).ToString() | Should -Match 'unsafe home'
    }

    It 'Test 25: Clear-CtxContext -All refuses an unsafe selected home' {
        $victim = Join-Path $env:HOME 'victim-home'
        $outside = Join-Path $Script:TestTmp 'victim-outside'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        New-Item -ItemType SymbolicLink -Path $victim -Target $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'data.txt') -Value 'important'
        $env:AI_CONTEXT = 'review'; $env:COPILOT_HOME = $victim; $Script:CtxAutoLoadHomeOverride = $victim
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'; $Error.Clear()
        try { Clear-CtxContext -All } finally { $ErrorActionPreference = $prevEap }
        Test-Path -LiteralPath (Join-Path $victim 'data.txt') | Should -BeTrue
        ($Error | Select-Object -First 1).ToString() | Should -Match 'unsafe home'
    }

    It 'Test 26: home validator rejects HOME itself' {
        { Get-CtxValidatedHomePath -Path $env:HOME } | Should -Throw '*unsafe home*'
    }

    It 'Test 27: home validator rejects CTX_HOMES_ROOT itself' {
        { Get-CtxValidatedHomePath -Path $env:CTX_HOMES_ROOT } | Should -Throw '*unsafe home*'
    }
}
