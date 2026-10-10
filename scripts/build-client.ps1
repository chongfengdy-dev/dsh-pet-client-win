<#
  build-client.ps1 — 编译托盘客户端 dsh_client_full.exe
  （Nim + winim，MinGW 静态链接 → 单文件、零 DLL 依赖）

  产物：client\dsh_client_full.exe
        exe 外壳图标（icon.res）与托盘四色图标（assets\*.ico 编译期 staticRead）均已内嵌。

  前提：
    - Nim 2.x         （nim.exe 在 PATH，或装在 <用户目录>\nim-*）
    - MinGW-w64       （gcc.exe 在 PATH，或装在 C:\mingw64 / C:\msys64\mingw64 / <用户目录>\mingw64）
    - winim 包        （nimble install winim）

  用法：
    build-client.ps1           编译
    build-client.ps1 -Run      编译完立即启动客户端

  说明：路径全部动态解析，不写死用户名或家目录。
#>
[CmdletBinding()]
param(
  [switch]$Run
)

$ErrorActionPreference = 'Stop'

$Root   = Split-Path -Parent $PSScriptRoot
$Client = Join-Path $Root 'client'
$NimSrc = Join-Path $Client 'dsh_client_full.nim'

if (-not (Test-Path $NimSrc)) { Write-Error ('缺少客户端源码: ' + $NimSrc); exit 1 }

# ---------- 定位 MinGW ----------
$mingw = $null
foreach ($d in @('C:\mingw64', 'C:\msys64\mingw64', (Join-Path $env:USERPROFILE 'mingw64'), (Join-Path $env:ProgramFiles 'mingw64'))) {
  if (Test-Path (Join-Path $d 'bin\gcc.exe')) { $mingw = $d; break }
}
if (-not $mingw) {
  $gcc = Get-Command gcc.exe -ErrorAction SilentlyContinue
  if ($gcc) { $mingw = Split-Path (Split-Path $gcc.Source -Parent) -Parent }
}
if (-not $mingw) { Write-Error '未找到 MinGW-w64（gcc.exe）—— 请安装并加入 PATH'; exit 1 }

# ---------- 定位 Nim ----------
$nimBin = $null
$nim = Get-Command nim.exe -ErrorAction SilentlyContinue
if ($nim) { $nimBin = Split-Path $nim.Source -Parent }
if (-not $nimBin) {
  $cand = Get-ChildItem (Join-Path $env:USERPROFILE 'nim-*') -Directory -ErrorAction SilentlyContinue |
          Where-Object { Test-Path (Join-Path $_.FullName 'bin\nim.exe') } | Select-Object -First 1
  if ($cand) { $nimBin = Join-Path $cand.FullName 'bin' }
}
if (-not $nimBin) { Write-Error '未找到 nim.exe —— 请安装 Nim 2.x 并加入 PATH'; exit 1 }

# ---------- 定位 winim ----------
$winim = Get-ChildItem (Join-Path $env:USERPROFILE '.nimble\pkgs2') -Directory -Filter 'winim-*' -ErrorAction SilentlyContinue |
         Select-Object -First 1
if (-not $winim) { Write-Error '未找到 winim 包 —— 请执行: nimble install winim'; exit 1 }

Write-Host ('MinGW : ' + $mingw)
Write-Host ('Nim   : ' + $nimBin)
Write-Host ('winim : ' + $winim.FullName)
Write-Host ''

$env:PATH = ($mingw + '\bin;' + $nimBin + ';' + $env:PATH)

$nimArgs = @('c', '--app:gui', ('--path:' + $winim.FullName), '-d:release')
$iconRes = Join-Path $Client 'icon.res'
if (Test-Path $iconRes) {
  $nimArgs += ('--passL:' + $iconRes)
} else {
  Write-Warning '缺少 icon.res —— exe 外壳图标会用默认（托盘图标不受影响）'
}
$nimArgs += 'dsh_client_full.nim'

Push-Location $Client
try {
  Write-Host ('nim ' + ($nimArgs -join ' '))
  Write-Host ''
  & (Join-Path $nimBin 'nim.exe') @nimArgs
  if ($LASTEXITCODE -ne 0) { Write-Error ('编译失败（退出码 ' + $LASTEXITCODE + '）'); exit 1 }
} finally {
  Pop-Location
}

$exe = Join-Path $Client 'dsh_client_full.exe'
if (Test-Path $exe) {
  $i = Get-Item $exe
  Write-Host ''
  Write-Host ('√ 编译完成: ' + $exe)
  Write-Host ('  体积: ' + [Math]::Round($i.Length / 1KB, 1) + ' KB（单文件，无 DLL 依赖）')
  if ($Run) {
    Write-Host '启动客户端 ...'
    Start-Process $exe
  }
} else {
  Write-Error '编译流程结束，但没有找到产物 exe'
}
