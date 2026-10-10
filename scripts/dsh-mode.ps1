<#
  dsh-mode.ps1 — 纯净 / 完整模式切换（Windows 版，对应 WSL 侧的 dsh-mode.sh）

  原理：web-launch.ps1 检查标记文件 %USERPROFILE%\.dsh\.dsh-web-mode
          存在   → 启动时追加 --patch config\clean.patch.yml（剥离第三方插件）
          不存在 → 完整模式（默认，含第三方插件）

  用法：
    dsh-mode.ps1 clean     切纯净模式（仅官方 base + web-app）
    dsh-mode.ps1 full      切完整模式
    dsh-mode.ps1 status    查看当前模式

  切换后会重启 dsh web 让配置生效（调用 dsh-service.ps1 restart web）。
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][ValidateSet('clean', 'full', 'status')][string]$Mode = 'status'
)

$ErrorActionPreference = 'Stop'

$Root     = Split-Path -Parent $PSScriptRoot
$DshHome  = Join-Path $env:USERPROFILE '.dsh'
$MarkFile = Join-Path $DshHome '.dsh-web-mode'
$Patch    = Join-Path $Root 'config\clean.patch.yml'
$Service  = Join-Path $PSScriptRoot 'dsh-service.ps1'

function Show-Mode {
  if (Test-Path $MarkFile) {
    Write-Host '当前模式: 纯净（剥离第三方插件，仅官方 base + web-app）'
  } else {
    Write-Host '当前模式: 完整（含第三方插件）'
  }
  Write-Host ('标记文件: ' + $MarkFile)
}

switch ($Mode) {
  'status' {
    Show-Mode
  }

  'clean' {
    if (-not (Test-Path $DshHome)) { New-Item -ItemType Directory $DshHome -Force | Out-Null }
    if (-not (Test-Path $Patch)) { Write-Error ('纯净模式 patch 缺失: ' + $Patch); exit 1 }
    New-Item -ItemType File -Path $MarkFile -Force | Out-Null
    Write-Host '[1/2] 已置纯净模式标记'
    Write-Host '[2/2] 重启 dsh web ...'
    & $Service restart web
    Write-Host '完成: 已切到纯净模式（浏览器刷新即生效）'
  }

  'full' {
    if (Test-Path $MarkFile) { Remove-Item $MarkFile -Force }
    Write-Host '[1/2] 已清除纯净模式标记'
    Write-Host '[2/2] 重启 dsh web ...'
    & $Service restart web
    Write-Host '完成: 已切到完整模式（浏览器刷新即生效）'
  }
}
