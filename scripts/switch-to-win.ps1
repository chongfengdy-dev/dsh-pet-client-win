<#
  switch-to-win.ps1 — 把服务从 WSL 切换到 Windows（正式搬家）

  做什么：
    1. 停 WSL 侧 dsh-web(3080) + terminal-server(3081)，释放标准端口
    2. 停 Windows 侧的测试实例（3090/3091）
    3. Windows 侧以**默认端口** 3080/3081 启动
    4. 注册开机自启
    5. 验证；任一步失败则回滚（把 WSL 服务重新拉起来），保证主始终有界面可用

  为什么必须先停 WSL：两边都监听 127.0.0.1:3080 会冲突 ——
  Windows 本地监听会顶掉 WSL2 的 localhost 转发。

  注意：本脚本必须由 **Windows 侧**独立进程运行（不要从 WSL 里调），
  否则停掉 WSL 的 dsh-web 时会把自己一起带走。

  用法：
    switch-to-win.ps1                 默认延迟 15 秒后执行
    switch-to-win.ps1 -WaitSeconds 0  立即执行
    switch-to-win.ps1 -NoAutostart    不注册自启
    switch-to-win.ps1 -Rollback       手动回滚（只把 WSL 服务拉起来）
#>
[CmdletBinding()]
param(
  [string]$WslDistro = '',
  [int]$WaitSeconds = 15,
  [switch]$NoAutostart,
  [switch]$Rollback
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$LogDir = Join-Path $Root 'logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir 'switch.log'

function Log([string]$msg) {
  $line = (Get-Date -Format 'HH:mm:ss') + '  ' + $msg
  Write-Host $line
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Get-WslDistro {
  if ($WslDistro) { return $WslDistro }
  try {
    $raw = & wsl.exe -l -q 2>$null
    foreach ($l in @($raw)) {
      $n = ([string]$l -replace "`0", '').Trim()
      if ($n) { return $n }
    }
  } catch { }
  return ''
}

function WslRun([string]$distro, [string]$cmd) {
  <# 在 WSL 里以 root 执行（WSL 的 root 无需密码） #>
  & wsl.exe -d $distro -u root -e bash -lc $cmd 2>&1 | Out-Null
}

function PortListening([int]$port) {
  return [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
}

function WaitPort([int]$port, [bool]$want, [int]$timeoutSec = 40) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    if ((PortListening $port) -eq $want) { return $true }
    Start-Sleep -Milliseconds 500
  }
  return $false
}

Log '=========================================='
Log 'DSH 切换到 Windows'
Log '=========================================='

$distro = Get-WslDistro
Log ('WSL 发行版: ' + $(if ($distro) { $distro } else { '（未探测到）' }))

# ---------- 回滚模式 ----------
if ($Rollback) {
  if ($distro) {
    Log '回滚：重新拉起 WSL 服务 ...'
    WslRun $distro 'systemctl start dsh-web'
    Start-Sleep -Seconds 3
    Log ('  3080 监听 = ' + (PortListening 3080))
  }
  Log '回滚完成'
  exit 0
}

if ($WaitSeconds -gt 0) {
  Log ('等待 ' + $WaitSeconds + ' 秒（给对方进程留出收尾时间）...')
  Start-Sleep -Seconds $WaitSeconds
}

# ---------- 1. 停 WSL ----------
if ($distro) {
  Log '[1/5] 停止 WSL 侧服务 ...'
  WslRun $distro "systemctl stop dsh-web; pkill -f 'terminal-server/server.js' || true"
  $freed = WaitPort 3080 $false 40
  Log ('  3080 已释放 = ' + $freed)
  Log ('  3081 已释放 = ' + (-not (PortListening 3081)))
} else {
  Log '[1/5] 跳过（未探测到 WSL 发行版）'
}

# ---------- 2. 停 Windows 测试实例 ----------
Log '[2/5] 停止 Windows 侧现有实例 ...'
Remove-Item Env:DSH_WEB_PORT  -ErrorAction SilentlyContinue
Remove-Item Env:DSH_TERM_PORT -ErrorAction SilentlyContinue
& (Join-Path $Root 'scripts\dsh-service.ps1') stop
Start-Sleep -Seconds 2

# ---------- 3. 以默认端口启动 ----------
Log '[3/5] 以默认端口启动 Windows 侧服务（3080 / 3081）...'
& (Join-Path $Root 'scripts\dsh-service.ps1') start
$okWeb  = WaitPort 3080 $true 90
$okTerm = WaitPort 3081 $true 40
Log ('  3080 监听 = ' + $okWeb)
Log ('  3081 监听 = ' + $okTerm)

# ---------- 4. 失败回滚 ----------
if (-not ($okWeb -and $okTerm)) {
  Log '!! 启动未完全成功，回滚到 WSL !!!'
  & (Join-Path $Root 'scripts\dsh-service.ps1') stop
  if ($distro) {
    WslRun $distro 'systemctl start dsh-web'
    Start-Sleep -Seconds 5
    Log ('  已回滚，3080 监听 = ' + (PortListening 3080))
  }
  Log '回滚结束，请查看 logs\web.err.log / term.err.log'
  exit 1
}

# ---------- 5. 自启 ----------
if ($NoAutostart) {
  Log '[4/5] 跳过自启（-NoAutostart）'
} else {
  Log '[4/5] 注册开机自启 ...'
  $startupDir = [Environment]::GetFolderPath('Startup')
  $vbsPath = Join-Path $startupDir 'dsh-pet-client.vbs'
  $svcPath = Join-Path $Root 'scripts\dsh-service.ps1'
  $vbs = @"
' DSH-Pet-Client-Win 开机自启（由 switch-to-win.ps1 / install.ps1 生成）
' 隐藏窗口启动服务：dsh web(3080) + terminal-server(3081)
Set ws = CreateObject("WScript.Shell")
ws.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""$svcPath"" start", 0, False
"@
  [IO.File]::WriteAllText($vbsPath, $vbs, (New-Object Text.UTF8Encoding $true))
  Log ('  已写入 ' + $vbsPath)
}

Log '[5/5] 完成 —— 请打开 http://127.0.0.1:3080'
Log '=========================================='
