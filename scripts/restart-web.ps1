<#
  restart-web.ps1 — 异步触发 dsh web 重启（供「一键更新 dsh」使用）

  为什么单独一个脚本：
    dsh 更新完成后，terminal-server 通过环境变量 DSH_RESTART_CMD 调用本脚本
    （见 terminal-server/server.js 的 restartDshWeb）。那边 execFile 的超时是 30 秒，
    而 dsh web 首次启动要加载插件、编译前端 bundle，常常超过 30 秒 —— 同步等待的话
    命令会被判超时（web 其实起得来，但接口会回 restarted=false）。
    这里改成「后台拉起真正的 restart 并立刻退出」，调用方秒回。

  为什么要重定向孙进程的输出：
    若后台进程继承本进程的 stdout/stderr 句柄，调用方（node 的 execFile）会一直等
    管道关闭 —— 等于没异步。重定向到日志文件可彻底断开继承。

  用法：
    restart-web.ps1            异步重启 web（一键更新走这条）
    restart-web.ps1 -Wait      同步等待完成（手动排查用）
#>
[CmdletBinding()]
param(
  [switch]$Wait
)

$ErrorActionPreference = 'Stop'

$Root    = Split-Path -Parent $PSScriptRoot
$Service = Join-Path $Root 'scripts\dsh-service.ps1'
$LogDir  = Join-Path $Root 'logs'

if (-not (Test-Path $Service)) { Write-Error ('缺少服务脚本: ' + $Service); exit 1 }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory $LogDir -Force | Out-Null }

if ($Wait) {
  & $Service restart web
  exit $LASTEXITCODE
}

$argStr = '-NoProfile -ExecutionPolicy Bypass -File "{0}" restart web' -f $Service
Start-Process -FilePath 'powershell.exe' -ArgumentList $argStr -WindowStyle Hidden `
  -RedirectStandardOutput (Join-Path $LogDir 'restart-web.out.log') `
  -RedirectStandardError  (Join-Path $LogDir 'restart-web.err.log') | Out-Null

Write-Host '[restart-web] 已触发 dsh web 重启（后台进行，浏览器稍后刷新）'
