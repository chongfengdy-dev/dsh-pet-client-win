<#
  pack-share.ps1 — 打包发布 zip（Windows 版，对标 WSL 侧的 pack-share.sh）

  设计原则（都是踩过坑的）：
    1. 文件清单以 `git ls-files` 为准 → .gitignore 里的私有/敏感文件天然排除：
       platform-token.json、term-state.json、terminal-server\backgrounds\、*.log、*.pid 等。
       不要用整目录复制 —— 那会把上面这些一起搬进包。
    2. 显式补充「被 gitignore 但发布必需」的文件：客户端 exe（编译产物，不入库但要随包发）。
    3. 打包前做敏感串扫描，命中即中止、不产出 zip。
    4. 客户端 exe 不存在时先自动编译（除非 -SkipBuild）。

  用法：
    pack-share.ps1                          打包 v1.1 到桌面
    pack-share.ps1 -Version v1.1            指定版本号
    pack-share.ps1 -OutDir D:\out           指定输出目录
    pack-share.ps1 -SkipBuild               不自动编译（要求 exe 已存在）
#>
[CmdletBinding()]
param(
  [string]$Version = 'v1.1',
  [string]$OutDir  = '',
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $env:USERPROFILE 'Desktop' }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory $OutDir -Force | Out-Null }

$Base = 'DSH-Pet-Client-Win-' + $Version
$Zip  = Join-Path $OutDir ($Base + '-share.zip')

# ---------- 0. 客户端 exe ----------
$exe = Join-Path $Root 'client\dsh-pet.exe'
if (-not (Test-Path $exe)) {
  if ($SkipBuild) { Write-Error ('缺少客户端 exe: ' + $exe + '（去掉 -SkipBuild 可自动编译）'); exit 1 }
  Write-Host '[0/5] 客户端 exe 不存在，先编译 ...'
  & (Join-Path $PSScriptRoot 'build-client.ps1')
}
if (-not (Test-Path $exe)) { Write-Error '客户端 exe 仍不存在，打包中止'; exit 1 }
Write-Host ('[0/5] 客户端 exe: ' + [Math]::Round((Get-Item $exe).Length / 1KB, 1) + ' KB')

# ---------- 暂存 ----------
$stage = Join-Path $env:TEMP ('dsh-share-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)))
$pkg   = Join-Path $stage $Base
New-Item -ItemType Directory $pkg -Force | Out-Null

try {
  Write-Host '[1/5] 复制 git 跟踪文件（.gitignore 自动生效）...'
  $files = @(& git -C $Root -c core.quotePath=false ls-files)
  foreach ($f in $files) {
    $src = Join-Path $Root ($f -replace '/', '\')
    $dst = Join-Path $pkg  ($f -replace '/', '\')
    $d   = Split-Path $dst -Parent
    if (-not (Test-Path $d)) { New-Item -ItemType Directory $d -Force | Out-Null }
    Copy-Item $src $dst -Force
  }
  Write-Host ('  ' + $files.Count + ' 个文件')

  Write-Host '[2/5] 补充发布必需的未跟踪文件 ...'
  $exeDst = Join-Path $pkg 'client\dsh-pet.exe'
  Copy-Item $exe $exeDst -Force
  Write-Host '  + client\dsh-pet.exe（编译产物，随包分发，用户无需自行编译）'

  Write-Host '[3/5] 敏感内容扫描 ...'
  $patterns = @(
    @{ re = 'userToken"\s*:\s*"[A-Za-z0-9_\-]{20,}'; label = 'userToken 实值' },
    @{ re = '/home/[a-z][a-z0-9_-]*/';                label = '绝对家目录 /home/*' },
    @{ re = 'C:\\Users\\[A-Za-z0-9_.\-]+';            label = 'C:\Users\* 绝对用户目录' },
    @{ re = 'sk-[A-Za-z0-9]{20,}';                    label = 'sk- API key' },
    @{ re = 'ghp_[A-Za-z0-9]{20,}';                   label = 'ghp_ token' },
    @{ re = 'DESKTOP-[A-Z0-9]{7}';                    label = 'DESKTOP 主机名' }
  )
  $exts = @('.ps1', '.js', '.json', '.md', '.yml', '.yaml', '.bat', '.nim', '.txt', '.rc', '.mjs', '.cjs')
  $hits = @()
  foreach ($f in (Get-ChildItem $pkg -Recurse -File -ErrorAction SilentlyContinue |
                  Where-Object { $exts -contains $_.Extension -and $_.FullName -notmatch '\\node_modules\\' })) {
    $text = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $text) { continue }
    foreach ($p in $patterns) {
      if ($text -match $p.re) { $hits += ($p.label + '  ->  ' + $f.FullName.Replace($pkg + '\', '')) }
    }
  }
  if ($hits.Count -gt 0) {
    Write-Host '  × 发现敏感内容，打包中止（不会产出 zip）：'
    $hits | ForEach-Object { Write-Host ('      ' + $_) }
    exit 1
  }
  Write-Host '  √ 未发现敏感内容'

  Write-Host '[4/5] 压缩 ...'
  if (Test-Path $Zip) { Remove-Item $Zip -Force }
  Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $Zip -CompressionLevel Optimal
} finally {
  Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '[5/5] 完成'
$z = Get-Item $Zip
Write-Host ('  ' + $z.FullName)
Write-Host ('  大小: ' + [Math]::Round($z.Length / 1KB, 1) + ' KB')
Write-Host ('  SHA256: ' + (Get-FileHash $Zip -Algorithm SHA256).Hash)
