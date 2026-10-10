# DSH-Pet-Client-Win

**Windows 原生版 DeepSeek Harness pet 客户端** —— 托盘客户端 + 界面后端 + 终端/HUD 服务
完整一套，全部跑在 Windows 原生环境，**不依赖 WSL**。

姊妹项目：[`dsh-pet-client`](https://github.com/chongfengdy-dev/dsh-pet-client)（WSL / Linux 通用版）、
[`dsh-pet-client-kde`](https://github.com/chongfengdy-dev/dsh-pet-client-kde)（Linux 托盘状态灯）。

---

## 一、项目来源

本项目从 [`dsh-pet-client`](https://github.com/chongfengdy-dev/dsh-pet-client) 独立而来：那套实现的后端
（dsh web 与 terminal-server）依赖 WSL 提供 bash、systemd 与 Python，Windows 侧只能算个壳。
2026-10-10 把后端整体原生化到 Windows，并把托盘客户端源码一并纳入本仓库，
形成一个**自包含**的 Windows 原生项目 —— 客户端与后端在这里是一个整体，不再分家。

后端原生化为四处等价替换（改写平台层，功能逻辑不变）：

| 原实现（WSL / Linux） | 本实现（Windows 原生） |
|---|---|
| systemd 托管服务（`dsh-web.service` / `dsh-terminal.service`） | PowerShell 服务层（`scripts\dsh-service.ps1`）+ 启动文件夹自启 |
| 终端跑 `$SHELL`（bash） | 终端跑 `powershell.exe`（真 PTY，可换 shell） |
| Python + `plyvel` 读浏览器 LevelDB 取平台 token | Node + `classic-level`（自带 win32-x64 预编译，读取结果与 plyvel **同指纹**） |
| Python 脚本聚合会话词元 | Node 内置 zstd（按魔数切多帧解压，**零 Python 依赖**） |

## 二、功能说明

| 功能 | 说明 |
|---|---|
| **托盘客户端** | `dsh_client_full.exe`（Nim + winim，单文件、零 DLL）：托盘四色状态灯，左键呼出 / 最小化对话窗口 |
| **四色状态灯** | 蓝 = 窗口可见 ｜ 黑 = 收起 / 最小化 ｜ 橙闪 = 有提问或审批待处理 ｜ 绿闪 = 刚回复完；数据来自 `%USERPROFILE%\pet-state.json` |
| **对话界面** | 浏览器 / PWA 打开 `http://127.0.0.1:3080`（dsh web，profile: web） |
| **内嵌终端** | 页面右侧按钮开合，直连 3081 的 WebSocket；Windows 下开出的是 **PowerShell**（可用 `DSH_TERM_SHELL` 换成 `pwsh.exe` / `cmd.exe` 等） |
| **Token HUD** | 常驻右上角：输入(命中 / 未命中) / 命中率 / 输出 / **今日消耗金额** / 余额；余额与金额走 DeepSeek 官方接口 |
| **消息大纲** | 当前会话「我的消息」侧边导航（左缘横杠），hover 展开、点击跳转 |
| **已归档会话** | 侧栏面板：查看 / 打开 / 恢复 / 删除会话 |
| **纯净 / 完整模式** | `clean` 只留官方界面 + 认证同步（应急排查用），`full` 恢复全部插件 |
| **一键更新** | 页面提示有新版本时点更新：自动 `npm i -g`，并通过 `DSH_RESTART_CMD` 异步重启界面后端 |
| **开机自启** | 启动文件夹里的 `dsh-pet-client.vbs` 隐藏窗口拉起 3080 + 3081；客户端由托盘自启项拉起 |

## 三、架构

```mermaid
graph TD
    subgraph Windows 原生
        A[dsh_client_full.exe<br/>托盘四色状态灯] -->|读 pet-state.json| D[%USERPROFILE%\pet-state.json]
        A -->|呼出 / 最小化| B[PWA / 浏览器窗口<br/>http://127.0.0.1:3080]
        B --> C[dsh-term-panels 插件<br/>终端面板 / Token HUD /<br/>消息大纲 / 已归档会话]
        E[dsh web :3080<br/>dsh --profile web] --> B
        F[terminal-server :3081<br/>server.js + node-pty] --> C
        F -->|写入状态| D
        F -->|fs 监控| S[(~/.dsh/sessions<br/>*.jsonl.zstd)]
        E -->|会话记录| S
    end
    C -->|WebSocket /ws| F
    C -->|HTTP /api/*| F
    F -->|classic-level| L[(浏览器 Local Storage<br/>platform.deepseek.com token)]
    F -->|HTTPS| P[platform.deepseek.com<br/>用量与金额]
    F -->|HTTPS| Q[api.deepseek.com<br/>余额]
```

**数据流**：插件在页面里渲染终端与 HUD → 通过 WebSocket / HTTP 连 3081 → 服务在本机跑
PowerShell PTY、聚合会话记录、代理平台用量接口 → 宠物状态写入文件，托盘客户端读取后变色。

**服务托管**：`scripts\dsh-service.ps1` 以后台隐藏窗口方式拉起两个 Node 进程，PID 记录在
`run\*.pid`，停止时用 `taskkill /T` 杀进程树，并在杀之前校验命令行包含部署根路径（防 PID 复用误杀）。

## 四、目录结构

```
dsh-pet-client-win/
├─ client/                   托盘客户端（Nim + winim → 单文件 exe）
│  ├─ dsh_client_full.nim    源码（仅依赖 winim 与标准库）
│  ├─ assets/                图标资源（编译期 staticRead 内嵌，共 11 个文件）
│  ├─ icon.rc · icon.res     exe 外壳图标资源
│  └─ dsh_client_full.exe    编译产物（不入库）
├─ scripts/
│  ├─ install.ps1            部署：检查 Node/dsh → 装依赖 → 同步插件 → 注册开机自启
│  ├─ dsh-service.ps1        服务管理：start|stop|restart|status [web|term|all]
│  ├─ sync-plugins.ps1       把 plugins\ 同步进 profile（-Check 只体检，-Restart 同步后重启）
│  ├─ build-client.ps1       编译托盘客户端（动态定位 Nim / MinGW / winim）
│  ├─ web-launch.ps1         dsh web 启动器（按标记决定是否走纯净模式）
│  ├─ restart-web.ps1        异步重启 web（一键更新调用，避免 30 秒超时）
│  └─ dsh-mode.ps1           纯净 / 完整模式：clean|full|status
├─ config/
│  └─ clean.patch.yml        纯净模式 patch（仅官方 base + web-app）
├─ plugins/                  本地插件实体副本（profile 内必须是真实目录副本，不能用符号链接）
│  ├─ dsh-term-panels/       终端面板 / Token HUD / 消息大纲 / 已归档会话
│  ├─ dsh-archive-sync/      归档集合变更即时同步
│  └─ dsh-web-token-sync/    把带 token 的认证链接写入 %USERPROFILE%\.dsh\dsh-web-token.txt
├─ terminal-server/          :3081 服务（Node，零 Python 依赖）
│  ├─ server.js
│  └─ lib/
│     ├─ platform-token.js   读浏览器 Local Storage 里的平台 token（classic-level）
│     ├─ today-usage.js      聚合本地会话记录统计当日词元
│     ├─ ask-pending.js      检测提问 / 审批待处理
│     └─ zstd-frames.js      dsh 会话文件的多帧 zstd 切分解压
├─ logs/ · run/              运行时日志与 PID（不入库）
├─ LICENSE                   MIT
├─ README.md                 本文档
└─ 使用说明.md                面向使用者的操作说明
```

## 五、部署

### 前置条件

- **Windows 10 / 11**
- **Node.js 22+**（词元统计用到内置 zstd；`install.ps1` 会检查并提示）
- 全局 dsh：`npm i -g @deepseek-ai/dsh`

### 安装

```powershell
# 解压后在项目目录执行
powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -Start
```

脚本依次做五件事：检查 Node → 检查全局 dsh → 安装 `terminal-server` 依赖 →
把 `plugins\` 同步进 web profile → 注册开机自启；`-Start` 表示装完立即启动。
加 `-NoAutostart` 可只装依赖、不动自启。

安装后打开 <http://127.0.0.1:3080>。

> 建议把 3080 装成 PWA（浏览器地址栏右侧「安装」图标）：独立窗口没有地址栏，
> 托盘状态灯也会优先跟随 PWA 窗口变色。
> dsh web 要求 token 认证时，带 token 的链接会自动写到
> `%USERPROFILE%\.dsh\dsh-web-token.txt`，直接打开文件里的链接即可。

### 客户端（托盘状态灯）

`client\dsh_client_full.exe` 是编译产物，**不入库**。两种取用方式：

```powershell
# A. 从源码编译（需要 Nim / MinGW / winim，见下一节）
powershell -ExecutionPolicy Bypass -File scripts\build-client.ps1

# B. 编译并立刻启动
powershell -ExecutionPolicy Bypass -File scripts\build-client.ps1 -Run
```

客户端只做两件事：读 `%USERPROFILE%\pet-state.json` 显示托盘四色状态灯，
以及左键呼出 / 最小化对话窗口（已装 PWA 则跟随 PWA 窗口，否则回落默认浏览器）。

### 日常管理

```powershell
scripts\dsh-service.ps1 status              # 两个服务的运行状态
scripts\dsh-service.ps1 restart             # web + term 都重启
scripts\dsh-service.ps1 restart term        # 只重启终端服务
scripts\dsh-mode.ps1 status                 # 当前模式
scripts\dsh-mode.ps1 clean                  # 切纯净模式（剥离第三方插件）
scripts\dsh-mode.ps1 full                   # 切回完整模式
scripts\sync-plugins.ps1                    # 改完 plugins\ 源码后同步进 profile
scripts\sync-plugins.ps1 -Check             # 只体检插件是否滞后，不改动文件
scripts\build-client.ps1                    # 重新编译托盘客户端
```

## 六、构建与编译

### 后端：无需编译

服务层是纯 Node / PowerShell，解压即可用：

- `terminal-server` 依赖通过 `npm ci` / `npm install` 安装（实测全新安装 **85 个包、约 17 秒**）；
- 涉及原生模块的两个依赖都**自带 win32-x64 预编译**，**不需要 VS Build Tools**：
  `node-pty`（终端 PTY）与 `classic-level`（读浏览器 LevelDB）；
- 前端部分由 dsh web 在启动时自行编译 bundle（首次启动较慢，属正常现象）。

### 客户端：需要编译

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-client.ps1
```

脚本会自动定位工具链（都支持 PATH 或常见安装位置），不写死任何用户路径：

| 依赖 | 要求 | 查找方式 |
|---|---|---|
| **Nim** | 2.x | `nim.exe` 在 PATH，或 `<用户目录>\nim-*` |
| **MinGW-w64** | 提供 `gcc.exe` | PATH，或 `C:\mingw64` / `C:\msys64\mingw64` / `<用户目录>\mingw64` |
| **winim** | 3.9+ | `nimble install winim`（装到 `<用户目录>\.nimble\pkgs2\winim-*`） |

编译采用 MinGW 静态链接（`--passL:-static`），产物是**单个 exe、零 DLL 依赖**；
托盘图标与 exe 图标都已内嵌（前者由源码 `staticRead` 编译期嵌入，后者来自 `client\icon.res`）。
实测：**176,662 行 / 约 17 秒 / 587.7 KB**。

> 链接阶段可能出现 `ld.exe: .rsrc merge failure: multiple non-default manifests`，
> 这是资源段清单合并的提示，**不影响产物**（exe 正常生成且可运行）。

## 七、注意事项

- **端口**：3080（界面后端）、3081（终端 / HUD / 状态）。两者被占时服务会启动失败，
  日志见 `logs\web.err.log`、`logs\term.err.log`（常见 `EADDRINUSE`）。
- **受限环境下的诊断**：`Get-NetTCPConnection`、`Get-CimInstance` 在沙箱 / 受限令牌下可能
  静默返回空，导致 `dsh-service.ps1 status` 误报 `stopped`。查端口请用 `netstat -ano`。
- **新机器首次启动**：若本地还没有平台 token 缓存，HUD 金额会在启动后 5–8 秒内取不到
  （首次需从浏览器 LevelDB 抓取），随后自动恢复；token 落盘后不再出现。
- **插件必须同步进 profile**：profile 内要的是**真实目录副本**，不能用符号链接
  （ESM 按真实路径解析依赖，链接过去会 `failed to import`）。
  改完 `plugins\` 下的源码后跑 `scripts\sync-plugins.ps1`，必要时再 `restart web`。

## 八、版本历史

| 版本 | 日期 | 说明 |
|---|---|---|
| **v1.0** | 2026-10-10 | 首个 Windows 原生版本。后端（dsh web 3080 + terminal-server 3081）完成原生化并接管标准端口，terminal-server 零 Python 依赖（classic-level 读 token、Node 多帧 zstd 统计词元）；PowerShell 服务层（`dsh-service.ps1`）替代 systemd；**托盘客户端源码与资源并入本仓库**并提供 `build-client.ps1` 一键编译；插件随包发布并提供 `sync-plugins.ps1`；平台 token 缺失自愈（HUD 金额不再空）；一键更新改为异步重启。 |

## 九、许可证

[MIT](LICENSE) —— 与 `dsh-pet-client` 一致。
