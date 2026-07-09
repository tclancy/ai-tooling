# Scenario tests for install.ps1 — mirrors run_sh_tests.sh.
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:Fail = 0

function Setup-Scratch {
  $script:Scratch = Join-Path ([IO.Path]::GetTempPath()) ("aitool-" + [Guid]::NewGuid().ToString('N'))
  $script:Repo = Join-Path $Scratch 'repo'
  $script:H    = Join-Path $Scratch 'home'
  New-Item -ItemType Directory -Path $Scratch | Out-Null
  Copy-Item -LiteralPath $RepoRoot -Destination $Repo -Recurse
  New-Item -ItemType Directory -Path (Join-Path $H '.claude') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $H '.codex')  -Force | Out-Null
  $env:AI_TOOLING_HOME = $H
  $script:Receipt = Join-Path $H '.agents\.ai-tooling-receipt'
}

function Run-Installer {
  param([string[]]$Flags = @())
  # Localized EAP: under 'Stop', native stderr routed through 2>&1 can raise
  # NativeCommandError in WinPS 5.1 and abort the whole suite mid-run.
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $script:Out = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'install.ps1') @Flags 2>&1 | Out-String)
  $script:Rc = $LASTEXITCODE
  $ErrorActionPreference = $prev
}

function Expected-Dests {  # independent re-derivation from TSV + globs
  $rows = Get-Content -LiteralPath (Join-Path $Repo 'harnesses.tsv') |
    Where-Object { $_ -notmatch '^\s*$' -and $_ -notmatch '^#' }
  foreach ($row in $rows) {
    $f = $row -split "`t"
    $detect = $f[1] -replace '^~', $env:AI_TOOLING_HOME -replace '/', '\'
    $dest   = $f[2] -replace '^~', $env:AI_TOOLING_HOME -replace '/', '\'
    if ($f[1] -ne '-' -and -not (Test-Path -LiteralPath $detect)) { continue }
    if ($f[0] -eq 'skills') {
      Get-ChildItem -LiteralPath (Join-Path $Repo 'skills') -Directory |
        ForEach-Object { Join-Path $dest $_.Name }
    } else {
      Get-ChildItem -LiteralPath (Join-Path $Repo $f[0]) -Filter *.md -File |
        ForEach-Object { Join-Path $dest $_.Name }
    }
  }
}

function A-Fail($m)        { Write-Output "ASSERT FAILED: $m"; $script:Fail = 1 }
function Assert-Exists($p)  { if (-not (Test-Path -LiteralPath $p)) { A-Fail "exists: $p" } }
function Assert-Missing($p) { if (Test-Path -LiteralPath $p) { A-Fail "missing: $p" } }
function Assert-Rc($want)   { if ($Rc -ne $want) { A-Fail "rc: want $want got $Rc — output: $Out" } }
function Assert-Contains($needle) { if ($Out -notlike "*$needle*") { A-Fail "contains '$needle' in: $Out" } }
function Test-IsLinkPath($p) {
  try { $a = [IO.File]::GetAttributes($p) } catch { return $false }
  return [bool]($a -band [IO.FileAttributes]::ReparsePoint)
}
function Assert-Symlink($p)    { if (-not (Test-IsLinkPath $p)) { A-Fail "symlink: $p" } }
function Assert-NotSymlink($p) { if (Test-IsLinkPath $p) { A-Fail "not-symlink: $p" } }

function Can-Symlink {
  $probe = Join-Path ([IO.Path]::GetTempPath()) ("lnprobe-" + [Guid]::NewGuid().ToString('N'))
  try {
    New-Item -ItemType SymbolicLink -Path $probe -Value ([IO.Path]::GetTempPath()) -ErrorAction Stop | Out-Null
    [IO.Directory]::Delete($probe, $false)
    return $true
  } catch { return $false }
}

function Scenario-DryRunTouchesNothing {
  Setup-Scratch
  Run-Installer @('-DryRun')
  Assert-Rc 0
  Assert-Missing $Receipt
  Expected-Dests | ForEach-Object { Assert-Missing $_ }
  Assert-Contains 'install (copy)'
}

function Scenario-FreshInstall {
  Setup-Scratch
  Run-Installer
  Assert-Rc 0
  Expected-Dests | ForEach-Object { Assert-Exists $_ }
  Assert-Exists $Receipt
  if ((Get-Content -LiteralPath $Receipt -TotalCount 1) -ne '# ai-tooling-receipt v1') { A-Fail 'receipt header' }
  Assert-Exists (Join-Path $H '.agents\skills\test-docs\SKILL.md')
}

function Scenario-RerunIdempotent {
  Setup-Scratch
  Run-Installer; Assert-Rc 0
  Run-Installer; Assert-Rc 0
  Expected-Dests | ForEach-Object { Assert-Exists $_ }
}

function Scenario-RenameCleansOrphan {
  Setup-Scratch
  Run-Installer; Assert-Rc 0
  Rename-Item -LiteralPath (Join-Path $Repo 'skills\test-docs') 'test-docs-renamed'
  Run-Installer; Assert-Rc 0
  Assert-Missing (Join-Path $H '.agents\skills\test-docs')
  Assert-Exists  (Join-Path $H '.agents\skills\test-docs-renamed')
}

function Scenario-ForeignDestSkippedThenForced {
  Setup-Scratch
  $foreign = Join-Path $H '.agents\skills\test-docs'
  New-Item -ItemType Directory -Path $foreign -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $foreign 'mine.txt') -Value 'precious'
  Run-Installer
  Assert-Rc 2
  Assert-Exists (Join-Path $foreign 'mine.txt')
  Assert-Exists (Join-Path $H '.claude\skills\test-docs\SKILL.md')
  Assert-Contains 'skip (exists, not ours'
  Run-Installer @('-Force')
  Assert-Rc 0
  Assert-Missing (Join-Path $foreign 'mine.txt')
  Assert-Exists  (Join-Path $foreign 'SKILL.md')
}

function Scenario-LinkInstall {
  Setup-Scratch
  Run-Installer @('-Link')
  Assert-Rc 0
  Assert-Symlink (Join-Path $H '.agents\skills\test-docs')
  Assert-Symlink (Join-Path $H '.claude\agents\doc-follower.md')
}

function Scenario-LinkThenCopyCloneIntact {
  Setup-Scratch
  Run-Installer @('-Link'); Assert-Rc 0
  Run-Installer;            Assert-Rc 0
  Assert-NotSymlink (Join-Path $H '.agents\skills\test-docs')
  Assert-Exists (Join-Path $H '.agents\skills\test-docs\SKILL.md')
  Assert-Exists (Join-Path $Repo 'skills\test-docs\SKILL.md')   # clone intact
  Assert-Exists (Join-Path $Repo 'agents\doc-follower.md')
}

function Scenario-CopyThenLink {
  Setup-Scratch
  Run-Installer;            Assert-Rc 0
  Run-Installer @('-Link'); Assert-Rc 0
  Assert-Symlink (Join-Path $H '.agents\skills\test-docs')
}

function Scenario-LinkUninstallClean {
  Setup-Scratch
  Run-Installer @('-Link');      Assert-Rc 0
  Run-Installer @('-Uninstall'); Assert-Rc 0
  Expected-Dests | ForEach-Object { Assert-Missing $_ }
  Assert-Missing $Receipt
  Assert-Missing (Join-Path $H '.agents')
}

function Scenario-UninstallSkipsForeignLink {
  Setup-Scratch
  Run-Installer @('-Link'); Assert-Rc 0
  $d = Join-Path $H '.agents\skills\test-docs'
  [IO.Directory]::Delete($d, $false)              # remove our link object
  New-Item -ItemType SymbolicLink -Path $d -Value $Scratch | Out-Null
  Run-Installer @('-Uninstall')
  Assert-Rc 2
  Assert-Symlink $d
  Assert-Contains 'leaving it'
}

function Scenario-UninstallLeavesReplacedLinkDest {
  Setup-Scratch
  Run-Installer @('-Link'); Assert-Rc 0
  $d = Join-Path $H '.agents\skills\test-docs'
  [IO.Directory]::Delete($d, $false)              # remove our link object
  New-Item -ItemType Directory -Path $d | Out-Null
  Set-Content -LiteralPath (Join-Path $d 'user-data.txt') -Value 'precious'
  Run-Installer @('-Uninstall')
  Assert-Rc 2
  Assert-Exists (Join-Path $d 'user-data.txt')    # never rm -rf'd
  Assert-Contains 'no longer our symlink'
}

function Scenario-UninstallLeavesNothing {
  Setup-Scratch
  Run-Installer; Assert-Rc 0
  Run-Installer @('-Uninstall'); Assert-Rc 0
  Expected-Dests | ForEach-Object { Assert-Missing $_ }
  Assert-Missing $Receipt
  Assert-Missing (Join-Path $H '.agents')
  Assert-Exists  (Join-Path $H '.claude')
}

function Scenario-UninstallDryRun {
  Setup-Scratch
  Run-Installer; Assert-Rc 0
  Run-Installer @('-Uninstall', '-DryRun'); Assert-Rc 0
  Assert-Exists $Receipt
  Expected-Dests | ForEach-Object { Assert-Exists $_ }
}

$scenarios = @(
  'Scenario-DryRunTouchesNothing', 'Scenario-FreshInstall',
  'Scenario-RerunIdempotent', 'Scenario-RenameCleansOrphan',
  'Scenario-ForeignDestSkippedThenForced',
  'Scenario-UninstallLeavesNothing', 'Scenario-UninstallDryRun'
)
if (Can-Symlink) {
  $scenarios += @(
    'Scenario-LinkInstall', 'Scenario-LinkThenCopyCloneIntact',
    'Scenario-CopyThenLink', 'Scenario-LinkUninstallClean',
    'Scenario-UninstallSkipsForeignLink', 'Scenario-UninstallLeavesReplacedLinkDest'
  )
} else {
  Write-Output 'NOTICE: symlinks unavailable on this runner — link scenarios skipped'
}
foreach ($s in $scenarios) { Write-Output "== $s"; & $s }
if ($script:Fail -ne 0) { Write-Output 'RESULT: FAIL'; exit 1 }
Write-Output 'RESULT: ALL PASS'
