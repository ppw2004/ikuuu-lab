# 可行执行方案(带时间估算)

> 适用于复现本仓库实践,或迁移到其他 SSPanel 系机场
> 总工时约 **2 小时**(含调试余量);纯部署已有脚本约 **15 分钟**

## T+0:00 ~ T+0:10 环境与资产盘点

| 检查项 | 命令/方法 | 通过标准 |
|---|---|---|
| Windows Chrome | `Test-Path 'C:\Program Files\Google\Chrome\Application\chrome.exe'` | 存在 |
| PowerShell 5.1+ | `$PSVersionTable.PSVersion` | ≥5.1 |
| WSL cron | `pgrep -x cron` | 进程存在 |
| 站点可达 | 打开发布页 | 页面加载 |

**产出**: 确认技术底座为「Windows Chrome + CDP + WSL bash」。

## T+0:10 ~ T+0:25 域名发现模块

1. 以独立 user-data-dir 启动 Chrome,开 `--remote-debugging-port=9222`
2. CDP `Page.navigate` 到发布页,等待 `loadEventFired` + 6s(动态状态探测)
3. `Runtime.evaluate` 执行 `Array.from(document.querySelectorAll('a[href]')).map(a => new URL(a.href).origin)` 去重过滤
4. 对候选域名逐个 `Invoke-WebRequest` 测活,取首个可达者

**验收**: 拿到 ≥1 个可用域名,与发布页展示一致。

## T+0:25 ~ T+0:55 CDP 客户端(核心基建)

PowerShell 零依赖实现:

```
ClientWebSocket → /json 列 tab → 连 page 级 ws
Send: {id, method, params} JSON
Recv: 缓冲循环直到 EndOfMessage
封装: Navigate-Page / Invoke-PageJs / Send-Mouse
```

**坑位预警**:
- 中文脚本必须存 UTF-8 **带 BOM**
- 数字开头 id 不能用 CSS 选择器
- 页面跳转会使 evaluate 报 "Inspected target navigated"(即成功信号)

**验收**: 能在目标页执行任意 JS 并取回返回值。

## T+0:55 ~ T+1:15 登录 + 验证码自动化

1. 表单探测:`#email` / `#password` / `#remember-me` / `button.login`
2. `setVal`(input+change 事件)注入凭据 → 点击登录
3. **极验拟人点击**:
   - 定位 `.geetest_tip` 叶子节点中心坐标
   - `Input.dispatchMouseEvent`:12 步 smoothstep 缓动 + 微抖动 → pressed → released
   - 失败重试 ≤5 次(通常第 2 次通过)
4. 监测 `验证通过` 文本 → 补点登录(≤3 次)→ 自动点掉 OK/确定弹窗
5. 轮询 `location.href` 含 `/user` 即登录成功

**验收**: 零登录态冷启动到面板,**全程无人工**。

## T+1:15 ~ T+1:25 签到与结果解析

- 点击 `[onclick^=checkin]` 或含"每日签到"的元素
- 解析弹窗:奖励 MB / "您似乎已经签到过了"
- 兜底:页面含"明日再来" → 今日已签

**验收**: 三种状态(成功/已签/异常)均正确分类。

## T+1:25 ~ T+1:40 cookie 快速路径

1. 登录成功后 `Network.getCookies` 提取会话落盘
2. 快速路径:纯 HTTP `POST /user/checkin`(带 Cookie 头)
3. 响应含"签到"字样即会话有效;否则转浏览器流程

**验收**: 会话有效时 **<1 秒**完成签到,不启动浏览器。

## T+1:40 ~ T+2:00 无人值守化

```
cron:
  0 12 * * *  run-checkin.sh      # 每日签到
  0 0  * * 1  weekly-report.sh    # 周日 24:00 周报
```

配套机制:
- 30 天滚动日志,超期删除
- `state.txt` 记录末次执行日,缺失日期自动补 `MISSING`
- 任何 ERROR → 桌面立即生成 `iKuuu报错-时间戳.txt`
- 周报含近 7 天明细/本周汇总/全部汇总,旧报自动清理

**验收**: 手动触发日跑器与周报器,桌面产物格式正确;模拟断跑一天后下次执行出现补记。

## 已知限制与降级路径

| 场景 | 表现 | 降级方案 |
|---|---|---|
| 极验升级为识别挑战 | 5 连点击失败 | 人工兜底窗口(4 分钟) |
| 中午 12 点 WSL 未运行 | 当日 MISSING | 次日自动补记(签到本身不可回溯) |
| 站点更换域名 | 旧域名全失效 | 发布页重解析自动跟随 |
| 会话被服务端吊销 | 快速路径失效 | 自动转浏览器全自动流程 |
