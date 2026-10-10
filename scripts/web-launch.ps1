<#
  web-launch.ps1 — dsh web 启动器（Windows 版，对应 WSL 侧的 web-launch.sh）

  职责：
    1. 动态定位 dsh 入口（lib/bin.js），不写死安装路径
    2. 读纯净模式标记 %USERPROFILE%\.dsh\.dsh-web-mode —— 存在则追加 --patch
    3. 前台运行 dsh web（由 dsh-service.ps1 以后台隐藏窗口方式包装）

  为什么不直接用 dsh.cmd：需要精确控制 node 与参数次序，.cmd 多一层拼装且
  不利于传递 --patch 路径。
#>
[CmdletBinding()]
param(
  [int]$Port = 0
)

$ErrorActionPreference = 'Stop'

# 部署根 = scripts 的上一级
$Root = Split-Path -Parent $PSScriptRoot

if ($Port -le 0) {
  $Port = if ($env:DSH_WEB_PORT) { [int]$env:DSH_WEB_PORT } else { 3080 }
}

$DshHome   = Join-Path $env:USERPROFILE '.dsh'
$MarkFile  = Join-Path $DshHome '.dsh-web-mode'
$PatchFile = Join-Path $Root 'config\clean.patch.yml'

function Find-DshBinJs {
  <# 动态定位 @deepseek-ai/dsh 的 lib/bin.js（不写死安装位置） #>
  $cands = New-Object System.Collections.Generic.List[string]
  $appdata = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $env:USERPROFILE 'AppData\Roaming' }
  $cands.Add((Join-Path $appdata 'npm\node_modules\@deepseek-ai\dsh\lib\bin.js'))
  $cands.Add((Join-Path $env:USERPROFILE '.npm-global\lib\node_modules\@deepseek-ai\dsh\lib\bin.js'))
  $cands.Add('/usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js')
  $cands.Add('/usr/lib/node_modules/@deepseek-ai/dsh/lib/bin.js')
  foreach ($c in $cands) { if (Test-Path $c) { return $c } }

  # 兜底：问 npm 自己（较慢，仅在前述候选都落空时）
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

$bin = Find-DshBinJs
if (-not $bin) {
  Write-Error '未找到 dsh 入口 —— 请先执行: npm i -g @deepseek-ai/dsh'
  exit 1
}

$dshArgs = @($bin, '--profile', 'web')

if (Test-Path $MarkFile) {
  if (Test-Path $PatchFile) {
    $dshArgs += @('--patch', $PatchFile)
    Write-Host '[web-launch] 模式: 纯净（--patch clean.patch.yml）'
  } else {
    Write-Warning "[web-launch] 纯净模式标记存在但 patch 文件缺失: $PatchFile（按完整模式启动）"
  }
} else {
  Write-Host '[web-launch] 模式: 完整'
}

$dshArgs += @('--', '--port', "$Port", '--no-open')

Write-Host "[web-launch] 启动 dsh web，端口 $Port"
Write-Host "[web-launch] node $bin --profile web ..."

& node @dshArgs
exit $LASTEXITCODE
