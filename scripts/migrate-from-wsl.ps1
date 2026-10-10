<#
  migrate-from-wsl.ps1 — 从 WSL 侧迁移 web profile / 记忆 / 人设到 Windows

  原则：**只读 WSL，只写 Windows 侧**，不修改 WSL 任何文件。
  覆盖旧目标前会先备份到 .dsh\.migrate-backup-<时间戳>\。

  迁移内容：
    <WSL>/.dsh/profiles/web     → %USERPROFILE%\.dsh\profiles\web      配置 + node_modules
    <WSL>/.dsh/AGENTS.md        → %USERPROFILE%\.dsh\AGENTS.md          人设
    <WSL>/.dsh/skills           → %USERPROFILE%\.dsh\skills              技能
    <WSL>/.mnemon               → %USERPROFILE%\.mnemon                  记忆
    <WSL>/.dsh/sessions         → %USERPROFILE%\.dsh\sessions            仅 -IncludeSessions

  实现注意（都是实测踩出来的）：
    - \\wsl.localhost 根目录列不出来，发行版名靠 wsl.exe -l -q 取
    - 9p 首次访问偶发 UnauthorizedAccessException（冷启动）→ 探测重试 3 轮
    - WSL 侧 node_modules 里的本地插件是**符号链接**，9p 上 Windows 复制不了
      （错误 1921）→ robocopy 用 /XJ 跳过，之后从本项目的 plugins\ 补实体
    - robocopy 退出码 0~7 算成功；8 只表示"有文件未复制"（这里就是软链），
      故只警告不中断

  用法：
    migrate-from-wsl.ps1                     自动探测 WSL 源
    migrate-from-wsl.ps1 -DryRun             只看计划不写盘
    migrate-from-wsl.ps1 -IncludeSessions    连会话历史一起迁
    migrate-from-wsl.ps1 -WslDsh '\\wsl.localhost\deepin25\home\dream\.dsh'
#>
[CmdletBinding()]
param(
  [string]$WslDsh = '',
  [switch]$IncludeSessions,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot     # 部署根

function Get-WslDistros {
  <# 取已安装的 WSL 发行版名：优先 wsl.exe，兜底查注册表 #>
  $out = @()
  try {
    $raw = & wsl.exe -l -q 2>$null
    foreach ($line in @($raw)) {
      $n = ([string]$line -replace "`0", '').Trim()
      if ($n) { $out += $n }
    }
  } catch { }
  if ($out.Count -eq 0) {
    try {
      $out = @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction Stop |
               ForEach-Object { (Get-ItemProperty $_.PSPath).DistributionName })
    } catch { }
  }
  return $out
}

function Find-WslDsh {
  <# 自动定位 WSL 侧的 .dsh：遍历 发行版 × 用户，取含 profiles\web 的那个 #>
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    foreach ($d in (Get-WslDistros)) {
      foreach ($base in @('\\wsl.localhost', '\\wsl$')) {
        $homeRoot = Join-Path $base (Join-Path $d 'home')
        $users = @()
        try { $users = @(Get-ChildItem $homeRoot -ErrorAction Stop | ForEach-Object { $_.Name }) } catch { continue }
        foreach ($u in $users) {
          $cand = Join-Path $homeRoot (Join-Path $u '.dsh')
          try {
            if (Test-Path (Join-Path $cand 'profiles\web') -ErrorAction Stop) { return $cand }
          } catch { }
        }
      }
    }
    Start-Sleep -Milliseconds 500
  }
  return $null
}

function Copy-Tree([string]$From, [string]$To) {
  <# robocopy 复制目录。
     /E 含子目录；/XJ 跳过符号链接（9p 上的软链复制必失败且无意义）；
     /R:2 失败重试 2 次。退出码 0~7 视为成功，>=8 只警告不中断。 #>
  $null = robocopy $From $To /E /XJ /R:2 /W:1 /NFL /NDL /NJH /NJS /NP
  $code = $LASTEXITCODE
  if ($code -ge 8) {
    Write-Warning ('   robocopy 退出码 ' + $code + '（部分文件未复制，通常是被跳过的符号链接）')
  }
}

if (-not $WslDsh) { $WslDsh = Find-WslDsh }
if (-not $WslDsh -or -not (Test-Path $WslDsh)) {
  Write-Error '未找到 WSL 侧的 .dsh 目录 —— 请用 -WslDsh 显式指定（形如 \\wsl.localhost\<发行版>\home\<用户>\.dsh）'
  exit 1
}
$WslHome = Split-Path -Parent $WslDsh

$WinDsh = Join-Path $env:USERPROFILE '.dsh'
$stamp  = Get-Date -Format 'yyyyMMddHHmmss'
$backup = Join-Path $WinDsh ('.migrate-backup-' + $stamp)

Write-Host '=== 迁移 ==='
Write-Host ('  源 (WSL)   : ' + $WslDsh)
Write-Host ('  目标 (Win) : ' + $WinDsh)
Write-Host ('  旧内容备份 : ' + $backup)
Write-Host ''

$items = @(
  @{ Name = 'web profile（配置 + node_modules）'; From = (Join-Path $WslDsh 'profiles\web'); To = (Join-Path $WinDsh 'profiles\web') },
  @{ Name = '人设 AGENTS.md';                     From = (Join-Path $WslDsh 'AGENTS.md');    To = (Join-Path $WinDsh 'AGENTS.md') },
  @{ Name = '技能 skills';                         From = (Join-Path $WslDsh 'skills');       To = (Join-Path $WinDsh 'skills') },
  @{ Name = '记忆 .mnemon';                        From = (Join-Path $WslHome '.mnemon');     To = (Join-Path $env:USERPROFILE '.mnemon') }
)
if ($IncludeSessions) {
  $items += @{ Name = '会话历史 sessions'; From = (Join-Path $WslDsh 'sessions'); To = (Join-Path $WinDsh 'sessions') }
}

$fail = 0
foreach ($it in $items) {
  $exists = $false
  try { $exists = Test-Path $it.From -ErrorAction Stop } catch { $exists = $false }
  if (-not $exists) {
    Write-Host ('[skip] ' + $it.Name + '（源不可达或不存在）')
    continue
  }
  if ($DryRun) {
    Write-Host ('[plan] ' + $it.Name)
    Write-Host ('        ' + $it.From + '   ->   ' + $it.To)
    continue
  }
  try {
    # 覆盖前把旧目标挪进备份
    if (Test-Path $it.To) {
      $safe = ($it.To -replace '[:\\/]', '_')
      $bk = Join-Path $backup $safe
      New-Item -ItemType Directory (Split-Path -Parent $bk) -Force | Out-Null
      Move-Item $it.To $bk -Force
    }
    New-Item -ItemType Directory (Split-Path -Parent $it.To) -Force | Out-Null

    $srcIsDir = (Get-Item $it.From -ErrorAction Stop).PSIsContainer
    if ($srcIsDir) {
      New-Item -ItemType Directory $it.To -Force | Out-Null
      Copy-Tree $it.From $it.To
    } else {
      Copy-Item $it.From $it.To -Force
    }
    $mb = [math]::Round(((Get-ChildItem $it.To -Recurse -File -ErrorAction SilentlyContinue |
           Measure-Object Length -Sum).Sum / 1MB), 1)
    Write-Host ('[ ok ] ' + $it.Name + '  (' + $mb + ' MB)')
  } catch {
    $fail++
    Write-Warning ('[fail] ' + $it.Name + ' -> ' + $_.Exception.Message)
  }
}

# ---------- 补本地插件实体 ----------
# WSL 侧 node_modules 里这 3 个是本仓库的符号链接（9p 上复制不了），
# 从本项目 plugins\ 补成实体目录，保证 dsh 能正常加载。
if (-not $DryRun) {
  $pluginSrc = Join-Path $Root 'plugins'
  $nmDst = Join-Path $WinDsh 'profiles\web\node_modules'
  if ((Test-Path $pluginSrc) -and (Test-Path $nmDst)) {
    Write-Host ''
    Write-Host '补齐本地插件（WSL 侧是符号链接）：'
    foreach ($p in (Get-ChildItem $pluginSrc -Directory -ErrorAction SilentlyContinue)) {
      $target = Join-Path $nmDst $p.Name
      try {
        if (Test-Path $target) { Remove-Item $target -Recurse -Force -ErrorAction SilentlyContinue }
        Copy-Item $p.FullName $target -Recurse -Force
        Write-Host ('  [ ok ] ' + $p.Name)
      } catch {
        $fail++
        Write-Warning ('  [fail] ' + $p.Name + ' -> ' + $_.Exception.Message)
      }
    }
  } else {
    Write-Warning '未找到 plugins\ 目录，跳过本地插件补齐'
  }
}

Write-Host ''
if ($DryRun) {
  Write-Host '（-DryRun：未写任何文件）'
} elseif ($fail -eq 0) {
  Write-Host '迁移完成。下一步：dsh-service.ps1 start，浏览器访问 http://127.0.0.1:3080'
} else {
  Write-Warning ("$fail 项失败，详见上面的 [fail] 行")
}
