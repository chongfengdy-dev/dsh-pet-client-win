# DSH-Pet-Client-Win

**Windows 原生版 pet 栈**：把 DeepSeek Harness 的界面后端与终端/HUD 服务完全搬到 Windows
原生运行，**不依赖 WSL**。

> 与 [`dsh-pet-client`](https://github.com/chongfengdy-dev/dsh-pet-client)（WSL/Linux 通用版）
> 结构对称：同一套插件、同一个 3080/3081 端口约定、同一份 `~/.dsh` 会话与记忆，
> 因此两边可随时对调，也能随时回退。

## 姊妹项目

| 项目 | 平台 | 形态 |
|---|---|---|
| [`dsh-pet-client`](https://github.com/chongfengdy-dev/dsh-pet-client) | WSL / Linux 通用 | dsh web + terminal-server + systemd + Nim 托盘壳 |
| [`dsh-pet-client-kde`](https://github.com/chongfengdy-dev/dsh-pet-client-kde) | Linux 原生 | Qt6 托盘状态灯 |
| **`dsh-pet-client-win`** | **Windows 原生** | **本项目** |
| [`dsh-message-outline`](https://github.com/chongfengdy-dev/dsh-message-outline) | 跨平台 | 消息大纲插件（非 pet 系列） |

## 组成

| 组件 | 端口 | 形态 |
|---|---|---|
| dsh web（profile: web） | **3080** | Node，由 `scripts\dsh-service.ps1` 托管（替代 systemd） |
| terminal-server | **3081** | Node（`node-pty` 自带 win32-x64 预编译，无需重编） |
| pet 壳 | — | 复用 `dsh-pet-client` 的 `dsh_client_full.exe`（Nim + winim 托盘状态灯） |
| 对话界面 | — | 默认浏览器的 PWA 独立窗口（地址不变，无需改动） |

```
Windows
├─ dsh_client_full.exe ── 读 %USERPROFILE%\pet-state.json ── 托盘四色状态灯
├─ PWA 窗口 ── http://127.0.0.1:3080
│    └─ dsh-term-panels 插件（终端面板 / Token HUD / 消息大纲 / 已归档会话）
├─ dsh web（3080，node --profile web）
└─ terminal-server（3081，node）
     ├─ WebSocket /ws   → PowerShell 真 PTY 终端
     ├─ /api/today-usage → 聚合 ~/.dsh/sessions（Node 内置 zstd，多帧切分）
     ├─ /api/platform-usage → 平台用量与金额（classic-level 读浏览器 token）
     ├─ /api/balance     → 官方余额接口
     └─ 写 pet-state.json → 宠物状态灯
```

## 与 WSL 版的关键差异

| 主题 | WSL 版 | 本版 |
|---|---|---|
| 服务托管 | systemd（`dsh-web.service` / `dsh-terminal.service`） | `dsh-service.ps1` + 启动文件夹 `dsh-pet-client.vbs` |
| 终端 shell | `$SHELL`（bash） | `powershell.exe`（可用 `DSH_TERM_SHELL` 覆盖） |
| 平台 token 读取 | Python + `plyvel`（LevelDB） | Node + `classic-level`（零编译，读取结果与 plyvel **同指纹**） |
| 词元聚合 | Python（`today-usage.py`） | Node（`lib/today-usage.js`，**零 Python 依赖**） |
| 一键更新后重启 | `sudo systemctl restart dsh-web` | `DSH_RESTART_CMD` → `scripts\restart-web.ps1`（异步，避免 30s 超时） |
| 不迁 | — | 微信通道(3082)、选股脚本 |

## 目录结构

```
dsh-pet-client-win/
├─ scripts/
│  ├─ install.ps1            部署：检查 Node/dsh → 装依赖 → 同步插件 → 注册开机自启
│  ├─ dsh-service.ps1        服务管理：start|stop|restart|status [web|term|all]
│  ├─ sync-plugins.ps1       把 plugins\ 同步进 profile（-Check 只体检，-Restart 同步后重启）
│  ├─ web-launch.ps1         dsh web 启动器（按标记决定是否走纯净模式）
│  ├─ restart-web.ps1        异步重启 web（一键更新调用）
│  ├─ dsh-mode.ps1           纯净/完整模式：clean|full|status
│  ├─ migrate-from-wsl.ps1   从 WSL 搬 profile / 插件 / 记忆（只读 WSL）
│  └─ switch-to-win.ps1      正式切换：停 WSL 服务 → Windows 接管 3080/3081
├─ config/
│  └─ clean.patch.yml        纯净模式 patch（仅官方 base + web-app）
├─ plugins/                  本地插件实体副本（不入库的是各自 node_modules）
│  ├─ dsh-term-panels/       终端面板 / Token HUD / 消息大纲 / 已归档会话
│  ├─ dsh-archive-sync/      归档集合变更即时同步
│  └─ dsh-web-token-sync/    认证链接写入 %USERPROFILE%\.dsh\dsh-web-token.txt
├─ terminal-server/          3081 服务（Node，零 Python）
│  ├─ server.js
│  └─ lib/                   platform-token / today-usage / ask-pending / zstd-frames
├─ logs/ · run/              运行时日志与 PID（不入库）
└─ README.md · 使用说明.md
```

## 快速开始

前提：**Node 22+**（内置 zstd 需要）、全局 `dsh`（`npm i -g @deepseek-ai/dsh`）、Windows 10/11。

```powershell
# 部署（装依赖 + 同步插件 + 注册开机自启 + 立即启动）
powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -Start

# 打开界面
start http://127.0.0.1:3080
```

日常管理：

```powershell
scripts\dsh-service.ps1 status              # 两个服务的运行状态
scripts\dsh-service.ps1 restart term        # 只重启终端服务
scripts\dsh-service.ps1 restart             # web + term 都重启
scripts\dsh-mode.ps1 status                 # 当前模式
scripts\dsh-mode.ps1 clean                  # 切纯净模式（剥离第三方插件，应急用）
scripts\dsh-mode.ps1 full                   # 切回完整模式
scripts\sync-plugins.ps1                    # 把 plugins\ 同步进 profile（改完插件源码后跑）
scripts\sync-plugins.ps1 -Check             # 只体检插件是否滞后，不改动任何文件
```

> 纯净模式下页面里没有终端/HUD/记忆等面板，但官方界面照常可用——用于「某个插件把页面搞坏了」时定位。

## 从 WSL 迁移过来

```powershell
# 1) 先搬数据（只读 WSL，覆盖前自动备份到 .dsh\.migrate-backup-<时间戳>\）
powershell -ExecutionPolicy Bypass -File scripts\migrate-from-wsl.ps1

# 2) 确认 Windows 侧能独立跑起来后，再正式切换端口
powershell -ExecutionPolicy Bypass -File scripts\switch-to-win.ps1 -WaitSeconds 15
```

`switch-to-win.ps1` 会：停 WSL 侧 `dsh-web`(3080)/`terminal-server`(3081) → 停 Windows 测试实例
→ 以默认端口启动 → 注册自启 → 任一步失败自动回滚（重新拉起 WSL 服务）。
`-Rollback` 可手动回滚。

> **注意**：切换会把当前页面（3080）换成 Windows 侧进程，请挑不忙的时候做。
> 另外脚本停 WSL 服务用的是 `pkill`，对 systemd 托管的单元无效（会被 `Restart` 策略拉回），
> 且启动校验只看「端口是否在监听」——详见下方「已知事项」。

## 已知事项

1. **`switch-to-win.ps1` 的两处缺陷（未修）**
   - 用 `pkill -f 'terminal-server/server.js'` 停 WSL 服务：若该服务由 systemd 托管，
     会被 `Restart=` 策略秒速拉回 → Windows 侧启动报 `EADDRINUSE`。应改用
     `systemctl --user stop dsh-terminal`。
   - 启动校验只判断「端口在监听」，没验证「端口持有者是不是自己刚起的进程」，
     于是会把他人的占用误判为启动成功、跳过回滚。应改为比对 `Start-Process` 的 PID。
2. **`platform-token.json` 缺失可自愈**（2026-10-10 已实现）
   该文件由浏览器 LevelDB 读出、且被 `.gitignore` 忽略，新机器上天然不存在。
   现在 `/api/platform-usage` 在读到空 token 时会先自动去浏览器抓一次再重试，
   HUD 的「今日消耗」金额不会因此空掉。
3. **沙箱/受限环境下的诊断**：`Get-NetTCPConnection`、`Get-CimInstance` 可能静默失效，
   查端口请用 `netstat -ano`。

## 状态

- **2026-10-10**：迁移完成并接管标准端口（3080 / 3081 全 Windows 原生，微信通道停用，
  WSL 侧服务已停用并取消自启，WSL 数据保留未删）。
- 已实测：界面后端、终端 PTY、Token HUD（词元 / 金额 / 余额）、消息大纲、已归档会话、
  宠物状态灯、纯净/完整模式切换、一键更新链路。

## License

MIT（与 `dsh-pet-client` 一致）
