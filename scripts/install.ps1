<#
  install.ps1 — DSH-Pet-Client-Win 部署脚本

  做五件事：
    1. 检查 Node（内置 zstd 需要 Node >= 22）
    2. 检查全局 dsh（界面后端依赖）
    3. 安装 terminal-server 的 npm 依赖
    4. 把本项目的插件同步进 web profile（终端面板 / Token HUD / 已归档会话都在这几个插件里）
    5. 注册开机自启（启动文件夹里放一个隐藏窗口的 vbs）

  用法：
    install.ps1                  部署 + 装自启
    install.ps1 -NoAutostart     只装依赖，不动自启
    install.ps1 -Start           装完立即启动服务

  前提：本脚本应位于部署根下的 scripts\ 目录（即 %USERPROFILE%\dsh-pet-client-win\scripts\）。
#>
[CmdletBinding()]
param(
  [switch]$NoAutostart,
  [switch]$Start
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

Write-Host '=== DSH-Pet-Client-Win 部署 ==='
Write-Host ('部署根: ' + $Root)
Write-Host ''

# ---------- 1. Node ----------
Write-Host '[1/5] 检查 Node ...'
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
  Write-Error '未找到 node —— 请先安装 Node.js 22+：https://nodejs.org'
  exit 1
}
$nodeVer = (& node --version).Trim()
$major = 0
if ($nodeVer -match '^v(\d+)') { $major = [int]$Matches[1] }
Write-Host ('  node ' + $nodeVer)
if ($major -lt 22) {
  Write-Warning ('  Node ' + $nodeVer + ' 低于 22 —— 内置 zstd 不可用（今日用量统计会失效），建议升级')
}

# ---------- 2. dsh ----------
Write-Host '[2/5] 检查 dsh ...'
function Find-DshBinJs {
  $cands = New-Object System.Collections.Generic.List[string]
  $appdata = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $env:USERPROFILE 'AppData\Roaming' }
  $cands.Add((Join-Path $appdata 'npm\node_modules\@deepseek-ai\dsh\lib\bin.js'))
  $cands.Add((Join-Path $env:USERPROFILE '.npm-global\lib\node_modules\@deepseek-ai\dsh\lib\bin.js'))
  foreach ($c in $cands) { if (Test-Path $c) { return $c } }
  try {
    $r = (& npm root -g 2>$null | Select-Object -First 1)
    if ($r) {
      foreach ($sep in @('\', '/')) {
        $p = Join-Path $r.Trim() ('@deepseek-ai' + $sep + 'dsh' + $sep + 'lib' + $sep + 'bin.js')
        if (Test-Path $p) { return $p }
      }
    }
  } catch { }
  return $null
}
$dshBin = Find-DshBinJs
if (-not $dshBin) {
  Write-Warning '  未检测到全局 dsh —— 界面后端(3080)无法启动。请执行: npm i -g @deepseek-ai/dsh'
} else {
  Write-Host ('  ' + $dshBin)
}

# ---------- 3. 依赖 ----------
Write-Host '[3/5] 安装 terminal-server 依赖 ...'
$termDir = Join-Path $Root 'terminal-server'
if (-not (Test-Path $termDir)) { Write-Error ('缺少目录: ' + $termDir); exit 1 }
if (Test-Path (Join-Path $termDir 'node_modules')) {
  Write-Host '  node_modules 已存在，跳过（要重装请先删除该目录）'
} else {
  Push-Location $termDir
  try { & npm install --no-audit --no-fund --loglevel=error } finally { Pop-Location }
  Write-Host '  完成'
}

# ---------- 4. 插件 ----------
Write-Host '[4/5] 同步本地插件到 web profile ...'
$syncScript = Join-Path $Root 'scripts\sync-plugins.ps1'
$dshHome    = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
$webProfile = Join-Path $dshHome 'profiles\web'
if (-not (Test-Path $webProfile)) {
  Write-Warning '  web profile 尚不存在 —— 先启动一次 dsh web（scripts\dsh-service.ps1 start web），再跑 scripts\sync-plugins.ps1'
} elseif (Test-Path $syncScript) {
  & $syncScript
} else {
  Write-Warning ('  未找到同步脚本: ' + $syncScript)
}

# ---------- 5. 自启 ----------
if ($NoAutostart) {
  Write-Host '[5/5] 跳过自启（-NoAutostart）'
} else {
  Write-Host '[5/5] 注册开机自启 ...'
  $startupDir = [Environment]::GetFolderPath('Startup')
  $vbsPath = Join-Path $startupDir 'dsh-pet-client.vbs'
  $svcPath = Join-Path $Root 'scripts\dsh-service.ps1'
  $vbs = @"
' DSH-Pet-Client-Win 开机自启（由 install.ps1 生成，勿手改路径）
' 隐藏窗口启动服务：dsh web(3080) + terminal-server(3081)
Set ws = CreateObject("WScript.Shell")
ws.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""$svcPath"" start", 0, False
"@
  [IO.File]::WriteAllText($vbsPath, $vbs, (New-Object Text.UTF8Encoding $true))
  Write-Host ('  已写入: ' + $vbsPath)
}

# ---------- 可选：立即启动 ----------
if ($Start) {
  Write-Host ''
  Write-Host '启动服务 ...'
  & (Join-Path $Root 'scripts\dsh-service.ps1') start
}

Write-Host ''
Write-Host '完成。常用命令：'
Write-Host ('  status   : ' + (Join-Path $Root 'scripts\dsh-service.ps1') + ' status')
Write-Host ('  restart  : ' + (Join-Path $Root 'scripts\dsh-service.ps1') + ' restart')
Write-Host ('  切模式   : ' + (Join-Path $Root 'scripts\dsh-mode.ps1') + ' clean|full|status')
Write-Host ('  同步插件 : ' + (Join-Path $Root 'scripts\sync-plugins.ps1') + ' [-Check]（改完 plugins\ 源码后跑）')
