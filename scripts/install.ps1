<#
  install.ps1 — DSH-Pet-Client-Win 部署脚本

  做六件事：
    1. 检查 Node（内置 zstd 需要 Node >= 22）
    2. 检查全局 dsh，缺失则自动安装（npm i -g @deepseek-ai/dsh）
    3. 安装 terminal-server 的 npm 依赖
    4. 把本项目的插件同步进 web profile（终端面板 / Token HUD / 已归档会话都在这几个插件里）
    5. 部署托盘客户端（复制 exe 并按需注册其开机自启）
    6. 注册服务开机自启（启动文件夹里放一个隐藏窗口的 vbs）

  用法：
    install.ps1                  完整部署
    install.ps1 -NoAutostart     装依赖/插件，但不注册任何开机自启
    install.ps1 -Start           装完立即启动服务（并启动客户端）

  前提：本脚本应位于部署根下的 scripts\ 目录。
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
Write-Host '[1/6] 检查 Node ...'
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

# ---------- 2. dsh（缺失则自动安装） ----------
Write-Host '[2/6] 检查 dsh ...'
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
  Write-Host '  未检测到全局 dsh，正在安装（npm i -g @deepseek-ai/dsh）...'
  & npm install -g @deepseek-ai/dsh --no-audit --no-fund 2>&1 |
    Select-Object -Last 3 | ForEach-Object { Write-Host ('    ' + $_) }
  $dshBin = Find-DshBinJs
  if ($dshBin) {
    Write-Host ('  √ 已安装: ' + $dshBin)
  } else {
    Write-Warning '  安装后仍未找到 dsh —— 请手动执行: npm i -g @deepseek-ai/dsh'
  }
} else {
  Write-Host ('  ' + $dshBin)
}

# ---------- 3. terminal-server 依赖 ----------
Write-Host '[3/6] 安装 terminal-server 依赖 ...'
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
Write-Host '[4/6] 同步本地插件到 web profile ...'
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

# ---------- 5. 客户端 ----------
Write-Host '[5/6] 部署托盘客户端 ...'
$exeSrc = Join-Path $Root 'client\dsh-pet.exe'
if (-not (Test-Path $exeSrc)) {
  Write-Warning '  未找到客户端 exe（源码在 client\）—— 发布包应当自带；自行编译可跑 scripts\build-client.ps1'
} else {
  $desktop = [Environment]::GetFolderPath('Desktop')
  # 客户端 exe 直接放桌面根目录，不建子文件夹（主 2026-10-10 定）。
  # 桌面不可用时回落到项目内 client\。
  $exeDst = if ($desktop) { Join-Path $desktop 'dsh-pet.exe' } else { Join-Path $Root 'client\dsh-pet.exe' }

  # 历史遗留副本：旧位置 桌面\DSH-Pet-Client\ 与旧文件名 dsh_client_full.exe，部署后一并清理
  $legacyExes = @()
  if ($desktop) {
    $legacyExes += (Join-Path $desktop 'DSH-Pet-Client\dsh_client_full.exe')
    $legacyExes += (Join-Path $desktop 'DSH-Pet-Client\dsh-pet.exe')
    $legacyExes += (Join-Path $desktop 'dsh_client_full.exe')
  }

  # 覆盖前先结束正在运行的客户端：exe 被占用时无法替换（升级/重装必踩）。
  # 这里用 Get-Process + Kill()，不用 taskkill —— 后者在进程不存在时会往 stderr 写
  # 「not found」，在 $ErrorActionPreference='Stop' 下会被当成错误而中断整个脚本。
  # 新旧进程名都要处理；记下它本来在运行，替换完再拉起来，用户无感。
  $running = @(Get-Process dsh-pet, dsh_client_full -ErrorAction SilentlyContinue)
  $wasRunning = $running.Count -gt 0
  if ($wasRunning) {
    Write-Host '  客户端正在运行，先结束它以便替换 ...'
    foreach ($proc in $running) {
      try { $proc.Kill(); [void]$proc.WaitForExit(3000) } catch { }
    }
    Start-Sleep -Seconds 2
  }

  try {
    Copy-Item $exeSrc $exeDst -Force -ErrorAction Stop
    Write-Host ('  已部署: ' + $exeDst)
  } catch {
    Write-Warning ('  客户端复制失败（可能仍被占用）：' + $_.Exception.Message)
  }

  foreach ($lg in $legacyExes) {
    if ($lg -and ($lg -ne $exeDst) -and (Test-Path $lg)) {
      Remove-Item $lg -Force -ErrorAction SilentlyContinue
      Write-Host ('  已清理历史副本: ' + $lg)
    }
  }

  if ($wasRunning) {
    Write-Host '  重新启动客户端 ...'
    Start-Process $exeDst
  }

  if ($NoAutostart) {
    Write-Host '  跳过客户端自启（-NoAutostart）'
  } else {
    $runKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $desired = '"' + $exeDst + '"'
    # exe 改名 dsh-pet 后自启值名统一为 DSH-Pet；顺手清掉旧值名 DSH-Nim-Client
    $oldVal = (Get-ItemProperty $runKey -Name 'DSH-Nim-Client' -ErrorAction SilentlyContinue).'DSH-Nim-Client'
    if ($oldVal) {
      Remove-ItemProperty $runKey -Name 'DSH-Nim-Client' -Force -ErrorAction SilentlyContinue
      Write-Host '  已移除旧自启项（DSH-Nim-Client）'
    }
    $current = (Get-ItemProperty $runKey -Name 'DSH-Pet' -ErrorAction SilentlyContinue).'DSH-Pet'
    if ($current -ne $desired) {
      Set-ItemProperty $runKey -Name 'DSH-Pet' -Value $desired -Force
      Write-Host '  已注册客户端开机自启（HKCU Run → DSH-Pet）'
    } else {
      Write-Host '  客户端开机自启已存在'
    }
  }

  if ($Start) { Write-Host '  启动客户端 ...'; Start-Process $exeDst }
}

# ---------- 6. 服务自启 ----------
if ($NoAutostart) {
  Write-Host '[6/6] 跳过服务自启（-NoAutostart）'
} else {
  Write-Host '[6/6] 注册服务开机自启 ...'
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

# ---------- 可选：立即启动服务 ----------
if ($Start) {
  Write-Host ''
  Write-Host '启动服务 ...'
  & (Join-Path $Root 'scripts\dsh-service.ps1') start
  Write-Host ''
  Write-Host '界面地址: http://127.0.0.1:3080'
}

Write-Host ''
Write-Host '完成。常用命令：'
Write-Host ('  status    : ' + (Join-Path $Root 'scripts\dsh-service.ps1') + ' status')
Write-Host ('  restart   : ' + (Join-Path $Root 'scripts\dsh-service.ps1') + ' restart')
Write-Host ('  切模式    : ' + (Join-Path $Root 'scripts\dsh-mode.ps1') + ' clean|full|status')
Write-Host ('  同步插件  : ' + (Join-Path $Root 'scripts\sync-plugins.ps1') + ' [-Check]')
Write-Host ('  编译客户端: ' + (Join-Path $Root 'scripts\build-client.ps1'))
Write-Host ('  打包发布  : ' + (Join-Path $Root 'scripts\pack-share.ps1'))
