# ai-tooling installer — native Windows (Windows PowerShell 5.1+).
# Function-for-function port of install.sh; harnesses.tsv is shared.
# Spec: docs/superpowers/specs/2026-07-08-installer-design.md
[CmdletBinding()]
param(
  [switch]$Link,
  [switch]$Uninstall,
  [switch]$DryRun,
  [switch]$Force
)
$ErrorActionPreference = 'Stop'

$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HomeDir = if ($env:AI_TOOLING_HOME) { $env:AI_TOOLING_HOME } else { $env:USERPROFILE }
$Tsv = Join-Path $RepoDir 'harnesses.tsv'
$ReceiptDir = Join-Path $HomeDir '.agents'
$Receipt = Join-Path $ReceiptDir '.ai-tooling-receipt'
$ReceiptHeader = '# ai-tooling-receipt v1'
$Mode = if ($Link) { 'link' } else { 'copy' }
$script:Status = 0

function Note($m) { Write-Output $m }
function Fail-Hard($m) { Write-Output "error: $m"; exit 1 }
function Fold($s) { "$s".ToLowerInvariant() }   # Windows: always case-insensitive

function Expand-Dest($p) {
  $p = $p -replace '/', '\'
  if ($p -eq '~') { return $HomeDir }
  if ($p.StartsWith('~\')) { return (Join-Path $HomeDir $p.Substring(2)) }
  return $p
}

function Get-Rows {
  Get-Content -LiteralPath $Tsv | ForEach-Object {
    if ($_ -match '^\s*$' -or $_ -match '^#') { return }
    $f = $_ -split "`t"
    if ($f.Count -lt 3 -or -not $f[1] -or -not $f[2]) { Fail-Hard "harnesses.tsv: malformed row: $_" }
    [pscustomobject]@{ Content = $f[0]; Detect = $f[1]; Dest = (Expand-Dest $f[2]) }
  }
}

function Check-Disjoint {
  $dests = @(Get-Rows | ForEach-Object { $_.Dest })
  $dups = $dests | Group-Object { Fold $_ } | Where-Object { $_.Count -gt 1 }
  if ($dups) { Fail-Hard ("harnesses.tsv: duplicate dest: " + $dups[0].Name) }
  foreach ($a in $dests) { foreach ($b in $dests) {
    if ($a -ne $b -and (Fold "$a\").StartsWith((Fold "$b\"))) {
      Fail-Hard "harnesses.tsv: dest '$a' lies inside dest '$b'"
    }
  } }
}

function Report-Skips {  # harness-detection report: names every found AND skipped detect dir
  Get-Rows | ForEach-Object {
    if ($_.Detect -eq '-') { return }
    $d = Expand-Dest $_.Detect
    if (Test-Path -LiteralPath $d -PathType Container) {
      Note ("found: $d (" + $_.Content + " will be installed)")
    } else {
      Note ("skipped: $d not found (no " + $_.Content + " for that harness)")
    }
  }
}

function Get-ActiveRows {
  Get-Rows | Where-Object {
    $_.Detect -eq '-' -or (Test-Path -LiteralPath (Expand-Dest $_.Detect) -PathType Container)
  }
}

function Get-Units($content) {
  switch ($content) {
    'skills' {
      Get-ChildItem -LiteralPath (Join-Path $RepoDir 'skills') -Directory -ErrorAction SilentlyContinue
    }
    { $_ -in 'agents', 'commands' } {
      Get-ChildItem -LiteralPath (Join-Path $RepoDir $content) -Filter *.md -File -ErrorAction SilentlyContinue
    }
    default { Fail-Hard "harnesses.tsv: unknown content type '$content'" }
  }
}

function Get-Planned {
  foreach ($row in Get-ActiveRows) {
    foreach ($u in @(Get-Units $row.Content)) {
      [pscustomobject]@{ Src = $u.FullName; Dest = (Join-Path $row.Dest $u.Name) }
    }
  }
}

function Test-IsLinkPath($p) {
  try { $a = [IO.File]::GetAttributes($p) } catch { return $false }
  return [bool]($a -band [IO.FileAttributes]::ReparsePoint)
}

function Test-PathAny($p) {  # true for files, dirs, AND dangling links
  if (Test-Path -LiteralPath $p) { return $true }
  return (Test-IsLinkPath $p)
}

function Remove-PathSafe($p) {  # link-aware: a link is removed as an object, never traversed
  try { $a = [IO.File]::GetAttributes($p) } catch { return }
  $isLink = [bool]($a -band [IO.FileAttributes]::ReparsePoint)
  $isDir  = [bool]($a -band [IO.FileAttributes]::Directory)
  if ($isLink) {
    if ($isDir) { [IO.Directory]::Delete($p, $false) } else { [IO.File]::Delete($p) }
  } elseif ($isDir) {
    Remove-Item -LiteralPath $p -Recurse -Force
  } else {
    Remove-Item -LiteralPath $p -Force
  }
}

function Get-LinkTarget($p) {
  try { return (Get-Item -LiteralPath $p -Force).Target | Select-Object -First 1 } catch { return $null }
}

function Ensure-Dir($d) {
  if (Test-Path -LiteralPath $d -PathType Container) { return }
  Ensure-Dir (Split-Path -Parent $d)
  Note "mkdir: $d"
  if (-not $DryRun) {
    Receipt-Append 'dir' '-' $d   # append-before-act
    if (-not (Test-Path -LiteralPath $d -PathType Container)) {
      New-Item -ItemType Directory -Path $d | Out-Null
    }
  }
}

function Receipt-Append($mode, $src, $dest) {
  if ($DryRun) { return }
  if (-not (Test-Path -LiteralPath $Receipt)) {
    New-Item -ItemType Directory -Path $ReceiptDir -Force | Out-Null  # unrecorded by design
    Set-Content -LiteralPath $Receipt -Value $ReceiptHeader -Encoding UTF8
  }
  Add-Content -LiteralPath $Receipt -Value ("{0}`t{1}`t{2}" -f $mode, $src, $dest) -Encoding UTF8
}

function Receipt-Current {  # deduped: last line per folded dest wins; order preserved
  if (-not (Test-Path -LiteralPath $Receipt)) { return @() }
  $map = @{}; $order = New-Object System.Collections.ArrayList
  foreach ($line in Get-Content -LiteralPath $Receipt) {
    if ($line -match '^#') { continue }
    $f = $line -split "`t"
    if ($f.Count -lt 3) { continue }
    $key = Fold $f[2]
    if (-not $map.ContainsKey($key)) { [void]$order.Add($key) }
    $map[$key] = [pscustomobject]@{ Mode = $f[0]; Src = $f[1]; Dest = $f[2] }
  }
  foreach ($k in $order) { $map[$k] }
}

function Remove-Owned($mode, $src, $dest) {
  if ($mode -eq 'link') {
    # A link entry may only ever delete a symlink still pointing at our
    # source. A real file/dir at that path is the user's now.
    if (-not (Test-IsLinkPath $dest)) {
      if (Test-Path -LiteralPath $dest) {
        Note "warning: $dest is no longer our symlink — leaving it"
        $script:Status = 2
      }
      return
    }
    $target = Get-LinkTarget $dest
    if (-not $target -or (Fold $target) -ne (Fold $src)) {
      Note "warning: $dest points at '$target', not our '$src' — leaving it"
      $script:Status = 2
      return
    }
  }
  Remove-PathSafe $dest
}

function Is-Ours($dest) {
  foreach ($e in @(Receipt-Current)) {
    if ((Fold $e.Dest) -eq (Fold $dest)) { return $true }
  }
  return $false
}

function Compact-ReceiptAndPrune {
  if (-not (Test-Path -LiteralPath $Receipt)) { return }
  $plannedDests = @{}
  foreach ($p in @(Get-Planned)) { $plannedDests[(Fold $p.Dest)] = $true }
  $keep = New-Object System.Collections.ArrayList
  foreach ($e in @(Receipt-Current)) {
    if ($e.Mode -eq 'dir' -or $plannedDests.ContainsKey((Fold $e.Dest))) {
      [void]$keep.Add($e)
    } else {
      Note ("remove stale: " + $e.Dest)
      if ($DryRun) { [void]$keep.Add($e) } else { Remove-Owned $e.Mode $e.Src $e.Dest }
    }
  }
  if ($DryRun) { return }
  $tmp = "$Receipt.tmp.$PID"
  Set-Content -LiteralPath $tmp -Value $ReceiptHeader -Encoding UTF8
  foreach ($e in $keep) {
    Add-Content -LiteralPath $tmp -Value ("{0}`t{1}`t{2}" -f $e.Mode, $e.Src, $e.Dest) -Encoding UTF8
  }
  Move-Item -LiteralPath $tmp -Destination $Receipt -Force
}

function New-Link($src, $dest) {
  try {
    New-Item -ItemType SymbolicLink -Path $dest -Value $src -ErrorAction Stop | Out-Null
  } catch {
    # PS 5.1 ignores Developer Mode; cmd's mklink honors it.
    if (Test-Path -LiteralPath $src -PathType Container) {
      cmd /c mklink /D "`"$dest`"" "`"$src`"" 2>&1 | Out-Null
    } else {
      cmd /c mklink "`"$dest`"" "`"$src`"" 2>&1 | Out-Null
    }
  }
  if (-not (Test-IsLinkPath $dest)) {
    Fail-Hard "could not create symlink at $dest — enable Developer Mode, run elevated, or use copy mode"
  }
}

function Install-Unit($src, $dest) {
  Ensure-Dir (Split-Path -Parent $dest)
  Note "install ($Mode): $src -> $dest"
  if ($DryRun) { return }
  Receipt-Append $Mode $src $dest   # before install: crash never strands an owned dest
  Remove-PathSafe $dest
  if ($Mode -eq 'link') {
    New-Link $src $dest
  } else {
    Copy-Item -LiteralPath $src -Destination $dest -Recurse
  }
}

function Do-Install {
  Compact-ReceiptAndPrune
  foreach ($p in @(Get-Planned)) {
    if ((Test-PathAny $p.Dest) -and -not $Force -and -not (Is-Ours $p.Dest)) {
      Note ("skip (exists, not ours — rerun with -Force to claim): " + $p.Dest)
      $script:Status = 2
      continue
    }
    Install-Unit $p.Src $p.Dest
  }
}

function Do-Uninstall {
  if (-not (Test-Path -LiteralPath $Receipt)) {
    Note "nothing to uninstall (no receipt at $Receipt)"
    return
  }
  $entries = @(Receipt-Current)   # capture BEFORE deleting the receipt
  foreach ($e in $entries) {
    if ($e.Mode -eq 'dir') { continue }
    Note ("remove: " + $e.Dest)
    if (-not $DryRun) {
      if ($Force) { Remove-PathSafe $e.Dest } else { Remove-Owned $e.Mode $e.Src $e.Dest }
    }
  }
  Note "remove: $Receipt"
  if (-not $DryRun) { Remove-Item -LiteralPath $Receipt -Force }
  $dirs = $entries | Where-Object { $_.Mode -eq 'dir' } |
    Sort-Object { $_.Dest.Length } -Descending
  foreach ($e in $dirs) {
    Note ("rmdir (if empty): " + $e.Dest)
    if (-not $DryRun) {
      try { [IO.Directory]::Delete($e.Dest, $false) } catch { }
    }
  }
  if (-not $DryRun) {
    try { [IO.Directory]::Delete($ReceiptDir, $false) } catch { }
  }
}

if (-not (Test-Path -LiteralPath $Tsv)) { Fail-Hard "missing $Tsv" }
Check-Disjoint
if ($Uninstall) {
  Do-Uninstall
} else {
  Report-Skips
  Do-Install
}
if ($script:Status -eq 2) { Note 'completed with skips (rerun with -Force to claim them)' }
exit $script:Status
