<#
  dsh-service.ps1 — DSH-Pet-Client-Win 服务管理（Windows 版，对应 WSL 侧的 systemd）

  管理两个常驻服务：
    web  : dsh web          （默认 3080）—— 对话界面后端
    term : terminal-server  （默认 3081）—— 终端 / Token HUD / 状态灯

  用法：
    dsh-service.ps1 start   [web|term|all]     不填默认 all
    dsh-service.ps1 stop    [web|term|all]
    dsh-service.ps1 restart [web|term|all]
    dsh-service.ps1 status

  实现要点：
    - 隐藏窗口后台运行，PID 写入 run\<name>.pid
    - 停止用 taskkill /T 杀进程树（包装器会 spawn node 子进程）
    - 杀之前校验命令行含部署根路径 —— 防 PID 复用误杀无关进程
    - 端口可用环境变量覆盖：DSH_WEB_PORT / DSH_TERM_PORT
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][ValidateSet('start', 'stop', 'restart', 'status')][string]$Action = 'status',
  [Parameter(Position = 1)][ValidateSet('web', 'term', 'all')][string]$Target = 'all'
)

$ErrorActionPreference = 'Stop'

$Root     = Split-Path -Parent $PSScriptRoot
$RunDir   = Join-Path $Root 'run'
$LogDir   = Join-Path $Root 'logs'
$WebPort  = if ($env:DSH_WEB_PORT)  { [int]$env:DSH_WEB_PORT }  else { 3080 }
$TermPort = if ($env:DSH_TERM_PORT) { [int]$env:DSH_TERM_PORT } else { 3081 }

foreach ($d in @($RunDir, $LogDir)) {
  if (-not (Test-Path $d)) { New-Item -ItemType Directory $d -Force | Out-Null }
}

function Get-Def([string]$name) {
  if ($name -eq 'web') {
    return @{
      Name    = 'web'
      Label   = 'dsh web'
      Port    = $WebPort
      Script  = (Join-Path $Root 'scripts\web-launch.ps1')
      WorkDir = $env:USERPROFILE
    }
  }
  return @{
    Name    = 'term'
    Label   = 'terminal-server'
    Port    = $TermPort
    Node    = (Join-Path $Root 'terminal-server\server.js')
    WorkDir = (Join-Path $Root 'terminal-server')
  }
}

function Get-PidPath([string]$name) { Join-Path $RunDir ($name + '.pid') }

function Get-LivePid([string]$name) {
  <# 返回仍在运行、且确属本部署的 PID；否则 $null #>
  $f = Get-PidPath $name
  if (-not (Test-Path $f)) { return $null }
  $v = (Get-Content $f -ErrorAction SilentlyContinue | Select-Object -First 1)
  if (-not $v) { return $null }
  $pidNum = 0
  if (-not [int]::TryParse(([string]$v).Trim(), [ref]$pidNum)) { return $null }
  $proc = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $pidNum) -ErrorAction SilentlyContinue
  if (-not $proc) { return $null }
  # 防 PID 复用：命令行必须包含本部署根路径
  $cl = [string]$proc.CommandLine
  if ($cl -and $cl.ToLower().Contains($Root.ToLower())) { return $pidNum }
  return $null
}

function Test-PortListen([int]$port) {
  return [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
}

function Wait-PortFree([int]$port, [int]$timeoutSec = 10) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (-not (Test-PortListen $port)) { return $true }
    Start-Sleep -Milliseconds 300
  }
  return $false
}

function Start-Svc([string]$name) {
  $def = Get-Def $name
  $live = Get-LivePid $name
  if ($live) { Write-Host ('[skip ] ' + $def.Label + ' 已在运行 (PID ' + $live + ')'); return }

  $outLog = Join-Path $LogDir ($name + '.out.log')
  $errLog = Join-Path $LogDir ($name + '.err.log')

  if ($name -eq 'web') {
    # 路径可能含空格，自己带引号（Start-Process 的数组拼接对空格不可靠）
    $argStr = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Port {1}' -f $def.Script, $def.Port
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argStr `
         -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru
  } else {
    $env:DSH_TERM_PORT = "$($def.Port)"
    # 一键更新 dsh 后的自动重启：Windows 没有 systemd，terminal-server 侧靠 DSH_RESTART_CMD 触发。
    # 走 restart-web.ps1（后台异步触发并立即返回）——直接调 restart 会因 web 首启耗时而
    # 撞上 execFile 的 30s 超时（见 server.js 的 restartDshWeb）。
    $env:DSH_RESTART_CMD = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' +
                           (Join-Path $Root 'scripts\restart-web.ps1') + '"'
    $argStr = '"{0}"' -f $def.Node
    $p = Start-Process -FilePath 'node' -ArgumentList $argStr -WorkingDirectory $def.WorkDir `
         -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru
  }
  $p.Id | Out-File -FilePath (Get-PidPath $name) -Encoding ascii -Force

  # 启动校验：等端口真正进入监听。
  # 不校验的话，端口被占/依赖缺失导致进程秒退时，脚本会谎报"启动成功"。
  $ok = $false
  $deadline = (Get-Date).AddSeconds(90)   # dsh web 首次启动要加载插件/编译前端，可能超过 60s
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if (-not (Get-Process -Id $p.Id -ErrorAction SilentlyContinue)) { break }
    if (Test-PortListen $def.Port) { $ok = $true; break }
  }
  if ($ok) {
    Write-Host ('[start] ' + $def.Label + ' -> PID ' + $p.Id + '  (端口 ' + $def.Port + ' 已监听)')
  } else {
    $tail = ''
    foreach ($lf in @($errLog, $outLog)) {
      if (Test-Path $lf) {
        $t = (Get-Content $lf -Tail 3 -ErrorAction SilentlyContinue) -join ' | '
        if ($t) { $tail = $t; break }
      }
    }
    Write-Warning ('[start] ' + $def.Label + ' 启动失败：端口 ' + $def.Port + ' 未监听（进程已退出或端口被占用）')
    if ($tail) { Write-Warning ('   日志尾部: ' + $tail) }
  }
}

function Stop-Svc([string]$name) {
  $def = Get-Def $name
  $live = Get-LivePid $name
  if ($live) {
    & taskkill.exe /PID $live /T /F 2>&1 | Out-Null
    Remove-Item (Get-PidPath $name) -Force -ErrorAction SilentlyContinue
    Write-Host ('[stop ] ' + $def.Label + ' (PID ' + $live + ')')
  } else {
    Remove-Item (Get-PidPath $name) -Force -ErrorAction SilentlyContinue
    Write-Host ('[skip ] ' + $def.Label + ' 未按 PID 记录运行')
  }

  # 兜底：按端口把仍在监听的 node 进程一并结束。
  # 场景：进程不是本脚本启动的（手工跑的 dsh web、或 wrapper 退出后的孤儿进程），
  # PID 记录里没有它，但端口确实占着 —— 主 2026-10-10 明确要求「关闭服务要关干净」。
  # 用 netstat 解析而非 Get-NetTCPConnection：后者在受限环境下会静默失效。
  $deadline = (Get-Date).AddSeconds(8)
  while ((Get-Date) -lt $deadline) {
    $listening = netstat -ano | Select-String ('127.0.0.1:' + $def.Port + '\s+0.0.0.0:0\s+LISTENING')
    if (-not $listening) { break }
    foreach ($l in $listening) {
      $parts = @(($l.Line -split '\s+') | Where-Object { $_ -ne '' })
      if ($parts.Count -lt 5) { continue }
      $procId = 0
      if (-not [int]::TryParse($parts[-1], [ref]$procId)) { continue }
      $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
      if ($p -and $p.ProcessName -eq 'node') {
        try {
          Stop-Process -Id $procId -Force
          Write-Host ('  [stop ] ' + $def.Label + ' 端口 ' + $def.Port + ' 的监听进程 PID ' + $procId + '（非本脚本启动，按端口清理）')
        } catch { }
      }
    }
    Start-Sleep -Milliseconds 500
  }
  if (netstat -ano | Select-String ('127.0.0.1:' + $def.Port + '\s+0.0.0.0:0\s+LISTENING')) {
    Write-Warning ('  端口 ' + $def.Port + ' 仍被占用（占用者不是 node？）')
  }
}

function Show-Status {
  Write-Host ('部署根: ' + $Root)
  foreach ($n in @('web', 'term')) {
    $def = Get-Def $n
    $live = Get-LivePid $n
    $listen = Test-PortListen $def.Port
    $state = if ($live -and $listen) { 'running' } elseif ($live) { 'starting' } else { 'stopped' }
    $pidText = if ($live) { "$live" } else { '-' }
    Write-Host ('  ' + $def.Label.PadRight(16) + ' [' + $state.PadRight(8) + ']  PID=' + $pidText.PadRight(8) +
                ' 端口 ' + $def.Port + ' 监听=' + $listen)
  }
}

$targets = if ($Target -eq 'all') { @('web', 'term') } else { @($Target) }

switch ($Action) {
  'start' { foreach ($t in $targets) { Start-Svc $t } }
  'stop'  { foreach ($t in $targets) { Stop-Svc $t } }
  'restart' {
    foreach ($t in $targets) {
      $def = Get-Def $t
      Stop-Svc $t
      [void](Wait-PortFree $def.Port)
      Start-Svc $t
    }
  }
  'status' { Show-Status }
}
