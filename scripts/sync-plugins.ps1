<#
  sync-plugins.ps1 — 把本项目的插件同步进 dsh profile
  （Windows 版，对应 WSL 侧的 sync-plugin.sh）

  背景：profile 内必须是**真实目录副本**，不能用符号链接 —— ESM 按真实路径解析依赖，
  链接到项目目录后会找不到宿主 @deepseek-ai 包，插件会 failed to import。
  因此改完 plugins\ 下的源码不会自动生效，需要在项目目录跑本脚本同步
  （install.ps1 首次部署时也会调用它）。

  用法：
    sync-plugins.ps1                          同步全部本地插件 → web profile
    sync-plugins.ps1 -Name dsh-term-panels    只同步指定插件
    sync-plugins.ps1 -Profile desktop         指定 profile（默认 web）
    sync-plugins.ps1 -Check                   只检查是否滞后，不改动任何文件
    sync-plugins.ps1 -Restart                 同步后重启 dsh web 使其生效

  说明：路径全部动态解析（DSH_HOME / 用户目录 / 脚本所在目录），不写死用户名或家目录。
#>
[CmdletBinding()]
param(
  [string]$Name = '',
  [string]$Profile = 'web',
  [switch]$Check,
  [switch]$Restart
)

$ErrorActionPreference = 'Stop'

$Root        = Split-Path -Parent $PSScriptRoot
$PluginsDir  = Join-Path $Root 'plugins'
$DshHome     = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
$ProfileDir  = Join-Path $DshHome ('profiles\' + $Profile)
$NodeModules = Join-Path $ProfileDir 'node_modules'

if (-not (Test-Path $PluginsDir)) { Write-Error ('缺少插件目录: ' + $PluginsDir); exit 1 }
if (-not (Test-Path $ProfileDir)) {
  Write-Error ('profile 不存在: ' + $ProfileDir + "`n  先启动一次 dsh web（scripts\dsh-service.ps1 start web）让它生成 profile，再跑本脚本。")
  exit 1
}
if (-not (Test-Path $NodeModules)) { $null = New-Item -ItemType Directory $NodeModules -Force }

$targets = if ($Name) { @($Name) } else { @(Get-ChildItem $PluginsDir -Directory | Sort-Object Name | Select-Object -ExpandProperty Name) }
if ($targets.Count -eq 0) { Write-Host '没有找到可同步的插件'; exit 0 }

# 参与比较/同步的文件（排除依赖目录与备份）
function Get-PluginFiles([string]$dir) {
  Get-ChildItem $dir -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object {
      $_.FullName -notmatch '\\node_modules\\' -and
      $_.Name -notmatch '\.bak-' -and
      $_.Name -ne 'platform-token.json'
    }
}

function Compare-Plugin([string]$src, [string]$dst) {
  if (-not (Test-Path $dst)) { return @{ status = 'missing'; diff = @() } }
  $item = Get-Item $dst -Force
  if ($item.LinkType) { return @{ status = 'symlink'; diff = @() } }

  $diffs = @()
  foreach ($f in (Get-PluginFiles $src)) {
    $rel = $f.FullName.Substring($src.Length).TrimStart('\')
    $d = Join-Path $dst $rel
    if (-not (Test-Path $d)) { $diffs += ('仅源有  : ' + $rel); continue }
    if ((Get-FileHash $f.FullName -Algorithm SHA256).Hash -ne (Get-FileHash $d -Algorithm SHA256).Hash) {
      $diffs += ('内容不同: ' + $rel)
    }
  }
  foreach ($f in (Get-PluginFiles $dst)) {
    $rel = $f.FullName.Substring($dst.Length).TrimStart('\')
    if (-not (Test-Path (Join-Path $src $rel))) { $diffs += ('仅目标有: ' + $rel) }
  }
  if ($diffs.Count -eq 0) { return @{ status = 'same'; diff = @() } }
  return @{ status = 'differs'; diff = $diffs }
}

Write-Host ('DSH_HOME : ' + $DshHome)
Write-Host ('profile  : ' + $Profile)
Write-Host ('插件来源 : ' + $PluginsDir)
Write-Host ('插件目标 : ' + $NodeModules)
Write-Host ''

$synced = 0
$same   = 0
foreach ($t in $targets) {
  $src = Join-Path $PluginsDir $t
  $dst = Join-Path $NodeModules $t

  Write-Host ('== ' + $t + ' ==')
  if (-not (Test-Path $src)) { Write-Warning '   跳过：源目录不存在'; Write-Host ''; continue }

  $r = Compare-Plugin $src $dst
  # 注意：PowerShell 的 continue/break 在 switch 内只作用于 switch 自身，不是外层 foreach；
  # 若在 switch 里直接 continue，"已一致"的插件照样会被重新同步。故用标志位在 switch 之后再跳。
  $skipSync = $false
  switch ($r.status) {
    'same' {
      Write-Host '   √ 已与项目一致，无需同步'
      $same++
      $skipSync = $true
    }
    'symlink' {
      Write-Warning '   跳过：目标当前是符号链接（会导致 ESM 依赖解析失败），请先改成目录副本'
      $skipSync = $true
    }
    'missing' { Write-Host '   ! 目标未安装 —— 将首次安装' }
    'differs' {
      Write-Host ('   ! 检测到 ' + $r.diff.Count + ' 处差异：')
      $r.diff | Select-Object -First 12 | ForEach-Object { Write-Host ('      ' + $_) }
      if ($r.diff.Count -gt 12) { Write-Host ('      …（其余 ' + ($r.diff.Count - 12) + ' 处略）') }
    }
  }

  if ($skipSync) { Write-Host ''; continue }
  if ($Check) { Write-Host '   （-Check 模式：未做任何改动）'; Write-Host ''; continue }

  # 备份旧版（最多保留最近 3 个）
  if (Test-Path $dst) {
    $bak = $dst + '.bak-' + (Get-Date -Format 'yyyyMMddHHmmss')
    if (Test-Path $bak) { Remove-Item $bak -Recurse -Force }
    Move-Item $dst $bak -Force
    Write-Host ('   旧版备份: ' + (Split-Path $bak -Leaf))
    Get-ChildItem ($dst + '.bak-*') -Directory -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 |
      ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
  }

  # 实体复制（robocopy：目标刚被移走，此处是空目录，用 /E 即可）
  $null = New-Item -ItemType Directory $dst -Force
  $rc = Start-Process -FilePath 'robocopy.exe' -Wait -PassThru -WindowStyle Hidden -ArgumentList @(
    $src, $dst, '/E', '/XD', 'node_modules', '/XF', '*.bak-*', '/NFL', '/NDL', '/NJH', '/NJS', '/NP'
  )
  if ($rc.ExitCode -ge 8) {
    Write-Warning ('   robocopy 失败（退出码 ' + $rc.ExitCode + '）')
  } else {
    Write-Host '   √ 已同步'
    $synced++
  }
  Write-Host ''
}

Write-Host ('完成：同步 ' + $synced + ' 个，已一致 ' + $same + ' 个。')
if ($Check) { Write-Host '（-Check 模式：本次未做任何改动）' }

if ($synced -gt 0) {
  if ($Restart) {
    Write-Host '重启 dsh web 使改动生效 ...'
    & (Join-Path $PSScriptRoot 'restart-web.ps1') -Wait
  } else {
    Write-Host '提示：插件改动需重启 dsh web 才生效 —— 跑 scripts\dsh-service.ps1 restart web，或下次带 -Restart。'
  }
}
