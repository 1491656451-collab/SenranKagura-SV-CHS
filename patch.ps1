<#
  闪乱神乐 少女们的证明（SHINOVI VERSUS）汉化补丁 应用器
  用法： pwsh -File patch.ps1 install|uninstall|status [-Parts text,font,story,tex] [-GameDir <游戏目录>]
#>
param(
  [Parameter(Position=0)][ValidateSet('install','uninstall','status')][string]$Action = 'status',
  [string]$GameDir,
  [ValidateSet('text','font','story','tex')][string[]]$Parts
)
$ErrorActionPreference = 'Stop'
$SEP = [IO.Path]::DirectorySeparatorChar
function NP([string]$r) { $r.Replace('\', $SEP).Replace('/', $SEP) }
$Here = $PSScriptRoot
if ($IsWindows) { Get-ChildItem -LiteralPath $Here -Recurse -File | Unblock-File -ErrorAction SilentlyContinue }

function Find-GameDir {
  $cands = @()
  $d = Get-Item -LiteralPath $Here
  while ($d) { $cands += $d.FullName; $d = $d.Parent }
  foreach ($c in $cands) { if (Test-Path -LiteralPath (Join-Path $c 'SKShinoviVersus.exe')) { return $c } }
  return $null
}
if (-not $GameDir) { $GameDir = Find-GameDir }
if (-not $GameDir -or -not (Test-Path -LiteralPath (Join-Path $GameDir 'SKShinoviVersus.exe'))) {
  Write-Host '找不到游戏目录（目录里应有 SKShinoviVersus.exe）。请把补丁文件夹放进游戏目录，或用 -GameDir 指定。' -ForegroundColor Red; exit 2
}
$Man = Get-Content -LiteralPath (Join-Path $Here 'manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json
$BackupDir = Join-Path $GameDir ('_汉化补丁备份' + $SEP + $Man.version)

function MD5([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  (Get-FileHash -LiteralPath $p -Algorithm MD5).Hash.ToLowerInvariant()
}
function State($f) {
  $h = MD5 (Join-Path $GameDir (NP $f.rel))
  if ($null -eq $h) { 'missing' } elseif ($h -eq $f.orig_md5) { 'original' } elseif ($h -eq $f.new_md5) { 'patched' } else { 'unknown' }
}
function Apply-Delta([string]$src, [string]$delta, [string]$dst) {
  Copy-Item -LiteralPath $src -Destination $dst -Force
  $d = [IO.File]::ReadAllBytes($delta)
  if ([Text.Encoding]::ASCII.GetString($d, 0, 4) -ne 'SVD1') { throw "差分文件格式不对：$delta" }
  $n = [BitConverter]::ToUInt32($d, 4); $p = 8
  $fs = [IO.File]::Open($dst, 'Open', 'ReadWrite')
  try {
    for ($i = 0; $i -lt $n; $i++) {
      $off = [BitConverter]::ToUInt64($d, $p); $len = [BitConverter]::ToUInt32($d, $p + 8); $p += 12
      [void]$fs.Seek([int64]$off, 'Begin'); $fs.Write($d, $p, [int]$len); $p += $len
    }
  } finally { $fs.Close() }
}

Write-Host "游戏目录：$GameDir"
Write-Host "补丁：$($Man.name) v$($Man.version)　文件数：$($Man.files.Count)"

switch ($Action) {
'status' {
  foreach ($f in $Man.files) { '{0,-9} {1,-6} {2}' -f (State $f), $f.part, $f.rel | Write-Host }
}
'install' {
  $sel = if ($Parts) { @($Man.files | Where-Object { $Parts -contains $_.part }) } else { @($Man.files) }
  if ($Parts) { Write-Host ('本次只安装：' + ($Parts -join ', ')) -ForegroundColor Yellow }
  $todo = @(); $bad = @()
  foreach ($f in $sel) {
    $s = State $f
    if ($s -eq 'original') { $todo += $f } elseif ($s -ne 'patched') { $bad += "$($f.rel)  [$s]" }
  }
  if ($bad.Count) {
    Write-Host '以下文件不是原版（可能装过其他补丁或已损坏），已中止，没有写入任何文件：' -ForegroundColor Red
    $bad | ForEach-Object { Write-Host "  $_" }
    Write-Host '请先卸载其他汉化补丁，或在 Steam 中「验证游戏文件完整性」后重试。'; exit 3
  }
  if (-not $todo.Count) { Write-Host '已经安装过本补丁，无需重复安装。' -ForegroundColor Green; exit 0 }
  foreach ($f in $todo) {
    $data = Join-Path $Here (NP $f.data)
    if ((MD5 $data) -ne $f.data_md5) { Write-Host "补丁包文件不完整：$($f.data)，已中止，没有写入任何文件。请重新解压补丁。" -ForegroundColor Red; exit 4 }
  }
  foreach ($f in $todo) {
    $src = Join-Path $GameDir (NP $f.rel); $bak = Join-Path $BackupDir (NP $f.rel)
    New-Item -ItemType Directory -Force -Path (Split-Path $bak) | Out-Null
    if ((MD5 $bak) -ne $f.orig_md5) { Copy-Item -LiteralPath $src -Destination $bak -Force }
    if ((MD5 $bak) -ne $f.orig_md5) { Write-Host "备份失败：$($f.rel)，已中止，没有写入任何文件。" -ForegroundColor Red; exit 4 }
  }
  $written = @()
  try {
    foreach ($f in $todo) {
      $dst = Join-Path $GameDir (NP $f.rel); $tmp = "$dst.chs_tmp"; $data = Join-Path $Here (NP $f.data)
      if ($f.mode -eq 'delta') { Apply-Delta (Join-Path $BackupDir (NP $f.rel)) $data $tmp } else { Copy-Item -LiteralPath $data -Destination $tmp -Force }
      if ((MD5 $tmp) -ne $f.new_md5) { throw "生成结果校验失败：$($f.rel)" }
      Move-Item -LiteralPath $tmp -Destination $dst -Force
      $written += $f
      if ((MD5 $dst) -ne $f.new_md5) { throw "写入后回读校验失败：$($f.rel)" }
      Write-Host "  已写入 $($f.rel)"
    }
  } catch {
    Write-Host "出错：$_" -ForegroundColor Red; Write-Host '正在回滚……'
    foreach ($f in $written) { Copy-Item -LiteralPath (Join-Path $BackupDir (NP $f.rel)) -Destination (Join-Path $GameDir (NP $f.rel)) -Force }
    Get-ChildItem -LiteralPath $GameDir -Recurse -Filter '*.chs_tmp' -File | Remove-Item -Force -ErrorAction SilentlyContinue
    $left = @($todo | Where-Object { (State $_) -ne 'original' })
    if ($left.Count) { Write-Host '回滚不完整，请用 Steam 验证游戏文件完整性。' -ForegroundColor Red } else { Write-Host '已回滚，游戏文件保持原样。' }
    exit 5
  }
  Write-Host "安装完成。原版文件备份在：$BackupDir" -ForegroundColor Green
}
'uninstall' {
  $fail = 0
  foreach ($f in $Man.files) {
    if ((State $f) -eq 'original') { Write-Host "  已是原版 $($f.rel)"; continue }
    $bak = Join-Path $BackupDir (NP $f.rel)
    if ((MD5 $bak) -ne $f.orig_md5) { Write-Host "  缺少有效备份：$($f.rel)" -ForegroundColor Red; $fail++; continue }
    Copy-Item -LiteralPath $bak -Destination (Join-Path $GameDir (NP $f.rel)) -Force
    if ((State $f) -eq 'original') { Write-Host "  已还原 $($f.rel)" } else { Write-Host "  还原后校验失败：$($f.rel)" -ForegroundColor Red; $fail++ }
  }
  if ($fail) { Write-Host '部分文件未能还原，请用 Steam 验证游戏文件完整性。' -ForegroundColor Red; exit 6 }
  Write-Host '卸载完成，游戏文件已与原版逐字节一致。' -ForegroundColor Green
}
}
