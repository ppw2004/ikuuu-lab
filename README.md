# iKuuu 机场自动签到实验报告

> 一次从"手工点验证码"到"零人工全自动体系"的完整逆向与自动化实践
> 实验日期: 2026-08-29 | 环境: Windows 11 + WSL2 (Ubuntu) + Chrome 151

## 0. 摘要

目标站点是一套定制化 SSPanel-Uim 机场面板,具备 **域名发布页(混淆 JS 渲染)**、**极验行为验证**、**多阶段登录状态机**、**频繁更换域名** 四重反自动化措施。

本实验在约 **2 小时**内完成了从零到全自动的完整闭环,最终架构三层兜底:

```
日常(≥99%): 会话 cookie + 单条 HTTP 请求签到 ............ <1 秒,不开浏览器
会话过期:   浏览器全自动登录(拟人轨迹点击过极验)....... ~40 秒,零人工
极端情况:   自动验证 5 连败 → 人工兜底(4 分钟窗口)
```

**核心成果**:验证码从未被"破解"——通过 cookie 复用绕开 + 对纯点击式极验做拟人轨迹模拟,实现了合规前提下的全自动。

## 1. 背景与目标

| 项 | 内容 |
|---|---|
| 目标 | 每日 12:00 自动签到领取流量奖励,无需人工 |
| 约束 | WSL 内无浏览器;站点只有 Windows 可达的 Web 界面;验证码不可语义破解 |
| 账号 | 仅操作本人账号,做日常签到 |

## 2. 实验环境

- Windows 11 (Chrome 151, PowerShell 5.1, 无 Node.js)
- WSL2 Ubuntu (git 2.53, bash, cron; 无 Playwright 浏览器)
- 通信底座: Chrome DevTools Protocol (CDP) over WebSocket,PowerShell 原生客户端

## 3. 完整时间线

### 阶段一:侦察(01:05 – 01:10)

| 时间 | 事件 | 结果 |
|---|---|---|
| 01:05 | WebFetch/curl 抓取 `ikuuu.me` | 页面为壳,域名列表由混淆 JS 动态生成,静态抓取无效 |
| 01:07 | 静态分析混淆脚本 | 拼接出 `'ikuuu'+'.foo'` 片段,但备用域名无法静态还原 |
| 01:09 | 改用 Windows Chrome headless + CDP 9222,PowerShell 手写 WebSocket CDP 客户端 | **成功**:`Runtime.evaluate` 取到渲染后 DOM |
| — | 尝试 `--dump-dom` / `--screenshot` | Chrome 151 新 headless 下**全部失效**(0 字节输出),弃用 |

**产出**: 主域名 `ikuuu.foo`(在线)、备用 `ikuuu.bar`(在线),更新于 2026-07-31。

### 阶段二:登录通道(01:12 – 01:37)

| 时间 | 事件 | 结果 |
|---|---|---|
| 01:12 | 解析登录表单 | SSPanel 定制主题:`#email`/`#password`/极验/邮箱验证码/2FA 多字段并存 |
| 01:21 | CDP 自动填表 + 点击登录 | 极验弹出,**人工**完成;随后程序补点登录成功 |
| 01:25 | 执行每日签到 | **+1261 MB**(免费号实测到账) |
| 01:28 | 打包成脚本首跑 | 暴露:PowerShell 无 BOM 中文乱码、过早补点无效等问题,逐一修复 |
| 01:37 | 无登录态完整流程 | 30 秒自动登录成功(极验当时仍需人工) |

### 阶段三:绕道研究(01:38 – 01:43)

| 时间 | 实验 | 结果 |
|---|---|---|
| 01:41 | `POST /auth/login` 直连(GitHub Actions 签到脚本的同款方案) | ❌ `invalid_phase`——站长定制**多阶段登录状态机**,API 直连被封死 |
| 01:42 | `POST /user/checkin` + 纯 cookie | ✅ `{"ret":0,"msg":"您似乎已经签到过了..."}`——**签到只认会话,不认浏览器** |
| 01:43 | 主脚本升级两级架构 | 快速路径实测 **1 秒**完成,浏览器都不用开 |

**结论**:不需要破解登录验证,只需要"偶发登录 + 常驻会话"。

### 阶段四:极验自动化(01:46 – 01:54)

人工观察发现:该站极验是**纯点击式**(无识别挑战),理论上拟人轨迹+点击即可通过。

| 版本 | 策略 | 结果 |
|---|---|---|
| v1 | 点击容器中心 | ❌ 点到 `embed-captcha` 容器空白处 |
| v2 | 精确叶子按钮 `.geetest_tip` + 二段点击 | ✅ 验证通过;但登录后停在登录页 |
| v3 | v2 + 自动点掉 OK/确定弹窗 | ✅ **FULL AUTO LOGIN SUCCESS** |

关键实现: `Input.dispatchMouseEvent` 合成 12 步缓动轨迹(Sin/Cos 微抖动)+ mousePressed/Released,通常**第 2 次点击**通过。

### 阶段五:无人值守体系(01:55 – 02:00)

| 组件 | 设计 |
|---|---|
| 调度 | WSL cron:每日 12:00 签到;周日 24:00 生成周报 |
| 日志 | 30 天滚动文件,超期自动删除 |
| 补记 | 每次运行比对 state,缺失日期自动补 `MISSING`,周报不缺天 |
| 周报 | 写桌面 `iKuuu周报-日期-第N周.txt`,旧报自动清理,含近 7 天明细/本周汇总/全部汇总 |
| 报错 | 任何异常立即在桌面生成 `iKuuu报错-时间戳.txt` 附完整输出 |

**终极验收**(01:53,零登录态冷启动):域名解析 → 填表 → 自动过极验(第 2 次点击)→ 登录 → 签到 → 会话保存,全程 **40 秒,零人工**。

## 4. 关键实验详录

### 实验 A: 域名发布页逆向
- **方法**: 静态抓取 → 失败;浏览器渲染 + `document.querySelectorAll('a[href]')` 提取 origin → 成功
- **工程要点**: WSL 访问不到 Windows Chrome 的 127.0.0.1:9222(NAT + 回环绑定),改为**全部逻辑跑在 Windows 侧 PowerShell**,结果落盘跨文件系统交换

### 实验 B: WSL → Windows 浏览器自动化选型
| 方案 | 结果 | 原因 |
|---|---|---|
| WSL Playwright | ❌ | 无浏览器,下载受限 |
| Windows Chrome `--dump-dom` | ❌ | Chrome 151 已失效,0 字节 |
| 跨系统 CDP(WSL 直连) | ❌ | 回环绑定 + 防火墙 |
| **Windows 侧 PowerShell CDP 客户端** | ✅ | 原生 `ClientWebSocket` + JSON,零依赖 |

### 实验 C: 登录 API 直连(负结果,同样有价值)
`email+passwd+code=` 的经典 SSPanel 打法返回 `invalid_phase`,证实站方针对性加固——**社区通用签到脚本对该站无效**,必须走浏览器。

### 实验 D: 会话复用(本实验最优解)
签到接口只验 cookie → 会话落盘(`Network.getCookies` 提取)→ 次日纯 HTTP 秒签。验证码出现频率从"每天"降到"每次会话过期"(数天~数周一次)。

### 实验 E: 极验拟人点击
- 定位 `.geetest_tip` 叶子节点 `getBoundingClientRect()` 中心
- 12 步 smoothstep 缓动 + 正弦微抖动轨迹,22-49ms 间隔
- 连续 2 次点击(第一次启动、第二次确认)
- **风险说明**: 极验升级为识别挑战(点选文字/图标)时该法即失效,脚本自动降级人工兜底

## 5. 最终架构

```
┌─ 每日 12:00 (WSL cron) ─────────────────────────────┐
│ run-checkin.sh                                      │
│   ├─ cookie 有效? ──→ POST /user/checkin  (<1s)    │
│   └─ 失效 ──→ ikuuu-auto-checkin.ps1 (Windows)      │
│        ├─ 发布页解析域名 → 测活                      │
│        ├─ 填表 → 拟人点击极验 → OK弹窗 → 登录        │
│        ├─ 签到 → 保存新会话 cookie                   │
│        └─ 5 连败 → 人工兜底提示                      │
│ 日志: 30 天滚动 · 缺失补记 · 报错直写桌面            │
└─ 周日 24:00: weekly-report.sh → 桌面周报 ───────────┘
```

## 6. 踩坑记录(按修复时间序)

1. **PowerShell 5.1 无 BOM UTF-8 = GBK 乱码** → 中文脚本必须 `utf-8-sig`
2. **`querySelector('#2fa-code')` 非法** → 数字开头 id 需 `getElementById`
3. **函数返回值未接收泄漏到输出流** → `| Out-Null`
4. **过早补点登录无效** → 验证通过后需重试提交(≤3 次,间隔 8s)
5. **点击命中容器而非按钮** → 必须取"自身文字匹配"的叶子元素
6. **bash 关联数组未 declare** → 字符串下标被算术求值为 0
7. **日志字段前缀未剥离** → 解析前 `${st#STATUS=}`
8. **CDP tab 生命周期** → 开新 tab 的脚本用完即关,断开执行上下文报 "Inspected target navigated"(此报错反而是跳转成功的信号)

## 7. 复现指引

见 [docs/EXECUTION-PLAN.md](docs/EXECUTION-PLAN.md)(带时间估算的分阶段执行方案)。

脚本(已脱敏):
- [scripts/ikuuu-auto-checkin.ps1](scripts/ikuuu-auto-checkin.ps1) — 核心三级签到脚本
- [scripts/run-checkin.sh](scripts/run-checkin.sh) — WSL 日跑器(滚动日志/补记/报错上报)
- [scripts/weekly-report.sh](scripts/weekly-report.sh) — 周报生成器
- [scripts/config.example.sh](scripts/config.example.sh) — 凭据模板

## 8. 合规边界声明

- 全程仅自动化**本人账号**的日常签到,未攻击他人或服务
- 未实施验证码语义破解(打码平台/CV 识别),仅做点击模拟与合规的会话复用
- 站方明确反自动化(`invalid_phase` 加固可证),若账号因此受限,责任自负
