<#
ikuuu-auto-checkin.ps1 - iKuuu VPN 自动签到脚本
用法(WSL 或 CMD 中):
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Users\26912\ikuuu-auto-checkin.ps1 -Email your@email.com -Password "你的密码"
流程: 从发布页(ikuuu.me)动态解析当前可用域名 -> 打开 Chrome 登录页 -> 自动填写账密并触发验证
      -> 等待用户在 Chrome 窗口完成滑块验证(最多 4 分钟) -> 自动登录 -> 每日签到 -> 输出结果
#>
param(
    [Parameter(Mandatory = $true)][string]$Email,
    [Parameter(Mandatory = $true)][string]$Password,
    [string]$Portal = 'https://ikuuu.me/',
    [int]$CDPPort = 9222,
    [string]$ProfileDir = 'C:\temp\ikuuu-chrome-profile'
)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------- 工具函数 ----------
function ConvertTo-JsString([string]$s) {
    return $s.Replace('\', '\\').Replace('"', '\"')
}
function Write-Step([string]$m) { Write-Output ("[" + (Get-Date -Format HH:mm:ss) + "] " + $m) }

# ---------- 0. 快速路径: 用已保存的会话 cookie 免浏览器直接签到 ----------
$cookieFile = 'C:\temp\ikuuu_cookie.txt'
$domainFile = 'C:\temp\ikuuu_domain.txt'
$knownDomains = @('https://ikuuu.foo', 'https://ikuuu.bar')

function Invoke-FastCheckin([string]$d, [string]$cookie) {
    $req = [System.Net.HttpWebRequest]::Create("$d/user/checkin")
    $req.Method = 'POST'
    $req.ContentType = 'application/x-www-form-urlencoded; charset=UTF-8'
    $req.Referer = "$d/user"
    $req.Headers.Add('Cookie', $cookie)
    $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
    $req.Timeout = 15000
    $resp = $req.GetResponse()
    $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
    $txt = $sr.ReadToEnd()
    $resp.Close()
    return $txt
}

if (Test-Path $cookieFile) {
    $savedCookie = ([System.IO.File]::ReadAllText($cookieFile)).Trim()
    if ($savedCookie) {
        Write-Step '步骤0: 检测到已保存会话, 尝试免浏览器快速签到...'
        $tryList = @()
        if (Test-Path $domainFile) {
            $d0 = ([System.IO.File]::ReadAllText($domainFile)).Trim()
            if ($d0) { $tryList += $d0 }
        }
        $tryList += $knownDomains
        $fastDone = $false
        foreach ($d in ($tryList | Select-Object -Unique)) {
            try {
                $txt = Invoke-FastCheckin $d $savedCookie
                $j = $null
                try { $j = $txt | ConvertFrom-Json } catch {}
                if ($j -and (($j.ret -eq 1) -or ($j.msg -match '签到'))) {
                    Write-Output '========================================'
                    Write-Step ("快速签到完成(未打开浏览器): " + $j.msg)
                    if ($j.traffic) { Write-Output ("  本次奖励: " + $j.traffic) }
                    if ($j.trafficInfo -and $j.trafficInfo.unUsedTraffic) { Write-Output ("  剩余流量: " + $j.trafficInfo.unUsedTraffic) }
                    Write-Output '========================================'
                    $fastDone = $true
                    break
                }
            } catch {}
        }
        if ($fastDone) { exit 0 }
        Write-Step '快速路径不可用(会话失效或域名变更), 转入浏览器完整流程...'
    }
}

# ---------- 1. 定位 Chrome 并启动 CDP ----------
$chromeCandidates = @(
    'C:\Program Files\Google\Chrome\Application\chrome.exe',
    'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
)
$chrome = $chromeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { throw '未找到 Chrome/Edge' }
$cdpBase = "http://127.0.0.1:$CDPPort"

function Test-Cdp {
    try { Invoke-WebRequest -UseBasicParsing "$cdpBase/json/version" -TimeoutSec 3 | Out-Null; return $true } catch { return $false }
}

if (-not (Test-Cdp)) {
    # 只清理本脚本专用 profile 的残留 Chrome,不影响用户自己的浏览器
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$ProfileDir*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
    Start-Process -FilePath $chrome -ArgumentList @(
        "--remote-debugging-port=$CDPPort", "--user-data-dir=$ProfileDir",
        '--no-first-run', '--no-default-browser-check', '--window-size=1100,900', 'about:blank'
    )
    $up = $false
    foreach ($i in 1..15) { Start-Sleep -Seconds 1; if (Test-Cdp) { $up = $true; break } }
    if (-not $up) { throw 'Chrome CDP 端口未就绪' }
    Write-Step "Chrome 已启动 (CDP 端口 $CDPPort)"
} else {
    Write-Step "复用已运行的 CDP Chrome (端口 $CDPPort)"
}

# ---------- CDP 连接 ----------
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ct = New-Object System.Threading.CancellationTokenSource
$script:evalId = 100

function Get-PageTab {
    $tabs = (Invoke-WebRequest -UseBasicParsing "$cdpBase/json" -TimeoutSec 10).Content | ConvertFrom-Json
    $p = $tabs | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
    if (-not $p) {
        $p = (Invoke-WebRequest -UseBasicParsing -Method Put "$cdpBase/json/new" -TimeoutSec 10).Content | ConvertFrom-Json
    }
    return $p
}
$page = Get-PageTab
$ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, $ct.Token).Wait(20000) | Out-Null

function Send-Cdp([object]$obj) {
    $json = $obj | ConvertTo-Json -Depth 8 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $ws.SendAsync([System.ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct.Token).Wait(20000) | Out-Null
}
function Recv-Cdp {
    $buf = New-Object byte[] 262144
    $ms = New-Object System.IO.MemoryStream
    $res = $null
    do {
        $res = $ws.ReceiveAsync([System.ArraySegment[byte]]::new($buf), $ct.Token).Result
        if ($res.Count -gt 0) { $ms.Write($buf, 0, $res.Count) }
    } while (-not $res.EndOfMessage)
    return [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
}
function Wait-Response([int]$id, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $msg = Recv-Cdp
        try { $o = $msg | ConvertFrom-Json } catch { continue }
        if ($o.id -eq $id) { return $o }
    }
    return $null
}
function Invoke-PageJs([string]$js, [int]$timeoutSec = 30) {
    $id = $script:evalId; $script:evalId++
    Send-Cdp @{ id = $id; method = 'Runtime.evaluate'; params = @{ expression = $js; returnByValue = $true; awaitPromise = $true } }
    $r = Wait-Response $id $timeoutSec
    if ($r -and $r.result.result) { return $r.result.result.value }
    return $null
}
function Navigate-Page([string]$url, [int]$settleSec = 4) {
    Send-Cdp @{ id = 90; method = 'Page.enable' }
    Send-Cdp @{ id = 91; method = 'Page.navigate'; params = @{ url = $url } }
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        $msg = Recv-Cdp
        try { $o = $msg | ConvertFrom-Json } catch { continue }
        if ($o.method -eq 'Page.loadEventFired') { break }
    }
    Start-Sleep -Seconds $settleSec
}
function Send-Mouse([string]$type, [double]$x, [double]$y, [string]$btn = 'none', [int]$clicks = 1) {
    $id = $script:evalId; $script:evalId++
    $p = @{ type = $type; x = $x; y = $y; pointerType = 'mouse' }
    if ($btn -ne 'none') { $p.button = $btn; $p.buttons = 1; $p.clickCount = $clicks }
    Send-Cdp @{ id = $id; method = 'Input.dispatchMouseEvent'; params = $p }
}
function Click-CaptchaWidget {
    $raw = Invoke-PageJs "(function () {
        const el = document.querySelector('.geetest_tip') || document.querySelector('[class*=geetest_radar_tip]');
        if (!el || !el.offsetParent) return JSON.stringify({found:false});
        const r = el.getBoundingClientRect();
        return JSON.stringify({found:true, x:r.x+r.width/2, y:r.y+r.height/2});
    })()" 15
    $w = $null
    try { $w = $raw | ConvertFrom-Json } catch {}
    if (-not $w -or -not $w.found) { return }
    $tx = [double]$w.x; $ty = [double]$w.y
    $sx = $tx - 157.0; $sy = $ty - 83.0
    for ($i = 1; $i -le 12; $i++) {
        $f = $i / 12
        $ease = $f * $f * (3 - 2 * $f)
        Send-Mouse 'mouseMoved' ($sx + ($tx - $sx) * $ease + [Math]::Sin($i * 2.3) * 2.2) ($sy + ($ty - $sy) * $ease + [Math]::Cos($i * 1.6) * 1.8)
        Start-Sleep -Milliseconds (22 + ($i % 4) * 9)
    }
    Start-Sleep -Milliseconds 120
    Send-Mouse 'mousePressed' $tx $ty 'left' 1
    Start-Sleep -Milliseconds 90
    Send-Mouse 'mouseReleased' $tx $ty 'left' 1
}
$dismissOkJs = "(async () => {
    const findOk = () => Array.from(document.querySelectorAll('button')).find(b => b.offsetParent && /^(OK|确定|好的|确认)$/.test(b.textContent.trim()));
    let n = 0;
    for (let i = 0; i < 3; i++) {
        const b = findOk();
        if (!b) break;
        b.click();
        n++;
        await new Promise(r => setTimeout(r, 1500));
    }
    return 'dismissed:' + n;
})()"

# ---------- 2. 从发布页解析当前可用域名 ----------
Write-Step "步骤1/4: 访问发布页 $Portal 解析最新域名..."
Send-Cdp @{ id = 1; method = 'Page.bringToFront' }
Navigate-Page $Portal 6
$domainsRaw = Invoke-PageJs "JSON.stringify(Array.from(new Set(Array.from(document.querySelectorAll('a[href]')).map(a => new URL(a.href, location.href).origin).filter(h => /ikuuu\.[a-z]+/.test(h)))))" 20
$domains = @()
try { $domains = ($domainsRaw | ConvertFrom-Json) | ForEach-Object { [string]$_ } } catch {}
if ($domains.Count -eq 0) { $domains = @('https://ikuuu.foo', 'https://ikuuu.bar') }
Write-Step ("发布页域名: " + ($domains -join ', '))

$domain = $null
foreach ($d in $domains) {
    try {
        Invoke-WebRequest -UseBasicParsing $d -TimeoutSec 12 | Out-Null
        $domain = $d; break
    } catch {
        $sc = $null
        try { $sc = [int]$_.Exception.Response.StatusCode } catch {}
        if ($sc -and $sc -ge 300 -and $sc -lt 500) { $domain = $d; break }
    }
}
if (-not $domain) { $domain = $domains[0] }
Write-Step "选定入口: $domain"

# ---------- 3. 登录 ----------
Write-Step "步骤2/4: 打开登录页并填写账号..."
Navigate-Page "$domain/auth/login" 4

$alreadyUrl = Invoke-PageJs 'location.href' 10
if ($alreadyUrl -match '/user') {
    Write-Step '已有登录态, 跳过登录'
} else {
    $jsEmail = ConvertTo-JsString $Email
    $jsPass = ConvertTo-JsString $Password
    $fillJs = "(async () => {
        const setVal = (el, v) => {
            el.focus(); el.value = v;
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            el.blur();
        };
        const em = document.querySelector('#email') || document.querySelector('input[name=email]');
        const pw = document.querySelector('#password') || document.querySelector('input[name=passwd], input[name=password]');
        if (!em || !pw) return 'NO_FIELDS';
        setVal(em, '$jsEmail');
        setVal(pw, '$jsPass');
        const rm = document.querySelector('#remember-me, input[name=remember]');
        if (rm && !rm.checked) rm.click();
        await new Promise(r => setTimeout(r, 800));
        const btn = document.querySelector('button.login, button[type=submit]');
        if (btn) btn.click();
        await new Promise(r => setTimeout(r, 1500));
        return 'FILLED';
    })()"
    $fillRes = Invoke-PageJs $fillJs 30
    if ($fillRes -ne 'FILLED') { throw "登录表单填写失败: $fillRes" }
    Write-Step '账密已填写, 已点击登录'

    $stateJs = "(function () {
        const vis = s => { const e = document.querySelector(s); return !!(e && e.offsetParent); };
        return JSON.stringify({
            url: location.href,
            geetest: vis('.geetest_holder, [class*=geetest_box]'),
            passed: document.body.innerText.indexOf('验证通过') >= 0,
            emailCode: vis('input[name=login-email-code]'),
            err: (document.querySelector('.alert, [class*=toast]') || {textContent: ''}).textContent.trim().slice(0, 120)
        });
    })()"
    $clickLoginJs = "(function () {
        const b = document.querySelector('button.login, button[type=submit]');
        if (b) b.click();
        return 'clicked';
    })()"

    Write-Step '正在自动完成极验点击验证...'
    Send-Cdp @{ id = 2; method = 'Page.bringToFront' }
    $deadline = (Get-Date).AddSeconds(240)
    $widgetTries = 0
    $submitCount = 0
    $announcedCode = $false
    $humanFallback = $false
    $loginOk = $false
    $lastState = ''
    while ((Get-Date) -lt $deadline) {
        $raw = Invoke-PageJs $stateJs 15
        try { $st = $raw | ConvertFrom-Json } catch { $st = $null }
        if ($st) {
            $lastState = $st.url
            if ($st.url -match '/user') { $loginOk = $true; break }
            if ($st.emailCode -and -not $announcedCode) {
                Write-Step '*** 需要邮箱验证码: 请到邮箱查收 8 位验证码并填入 Chrome 窗口 ***'
                $announcedCode = $true
            }
            if ($st.passed -and $submitCount -lt 3) {
                $submitCount++
                Invoke-PageJs $dismissOkJs 20 | Out-Null
                Invoke-PageJs $clickLoginJs 15 | Out-Null
                Write-Step "验证已通过, 第 $submitCount 次提交登录..."
                Start-Sleep -Seconds 8
                continue
            }
            if (-not $st.passed -and $st.geetest -and $widgetTries -lt 5) {
                $widgetTries++
                Write-Step "自动点击验证块 (第 $widgetTries 次)..."
                Click-CaptchaWidget
                Start-Sleep -Seconds 6
                continue
            }
            if (-not $humanFallback -and $widgetTries -ge 5) {
                $humanFallback = $true
                Write-Step '*** 自动验证未通过, 请在 Chrome 窗口手动完成验证 (最多等待 4 分钟) ***'
            }
        }
        Start-Sleep -Seconds 4
    }
    if (-not $loginOk) {
        $shot = "$env:TEMP\ikuuu_login_fail.png"
        try {
            Send-Cdp @{ id = 3; method = 'Page.captureScreenshot'; params = @{ format = 'png' } }
            $r = Wait-Response 3 20
            if ($r) { [System.IO.File]::WriteAllBytes($shot, [Convert]::FromBase64String($r.result.data)); Write-Step "登录未成功, 截图: $shot" }
        } catch {}
        throw "登录失败, 停留在: $lastState"
    }
    Invoke-PageJs $dismissOkJs 20 | Out-Null
    Write-Step '登录成功!'
}
Start-Sleep -Seconds 3

# ---------- 4. 每日签到 ----------
Write-Step '步骤3/4: 执行每日签到...'
$trafficJs = "(function () {
    const m = document.body.innerText.match(/剩余流量\s*([\d.]+\s*[KMGT]?B?)/);
    return m ? m[1] : '';
})()"
$beforeTraffic = Invoke-PageJs $trafficJs 15

$checkinJs = "(async () => {
    const btn = document.querySelector('[onclick^=checkin]') ||
        Array.from(document.querySelectorAll('a,button')).find(e => /每日签到/.test(e.textContent) && e.offsetParent);
    if (!btn) {
        const done = document.body.innerText.indexOf('明日再来') >= 0;
        return JSON.stringify({result: done ? 'ALREADY' : 'NO_BUTTON', msg: done ? '今日已签到' : '未找到签到按钮'});
    }
    btn.click();
    await new Promise(r => setTimeout(r, 8000));
    const msgs = Array.from(document.querySelectorAll('.alert, .toast, [class*=toast], .sweet-alert, .swal2-container'))
        .map(e => e.textContent.trim().replace(/\s+/g, ' ')).filter(t => t && t.length < 300);
    const m = msgs.join(' ').match(/签到成功[^0-9]*(\d+)\s*MB/) || msgs.join(' ').match(/签到[^\s]{0,20}/);
    const btnAfter = document.querySelector('[onclick^=checkin]');
    return JSON.stringify({
        result: 'DONE',
        reward: m ? m[0] : '',
        buttonNow: btnAfter ? 'still there' : 'gone(明日再来)',
        traffic: (document.body.innerText.match(/剩余流量\s*([\d.]+\s*[KMGT]?B?)/) || [])[1] || ''
    });
})()"
$raw = Invoke-PageJs $checkinJs 40
Invoke-PageJs $dismissOkJs 20 | Out-Null
try { $ci = $raw | ConvertFrom-Json } catch { $ci = $null }

# ---------- 5. 汇总 ----------
Write-Step '步骤4/4: 结果汇总'
$afterTraffic = Invoke-PageJs $trafficJs 15
Write-Output ('========================================')
Write-Output ("入口域名 : $domain")
Write-Output ("签到前流量 : $beforeTraffic")
if ($ci) {
    Write-Output ("签到结果 : " + $ci.result)
    if ($ci.msg) { Write-Output ("说明     : " + $ci.msg) }
    if ($ci.reward) { Write-Output ("奖励     : " + $ci.reward) }
    if ($ci.buttonNow) { Write-Output ("按钮状态 : " + $ci.buttonNow) }
}
Write-Output ("当前流量 : $afterTraffic")

# 保存会话 cookie, 供下次免浏览器快速签到
try {
    Send-Cdp @{ id = 80; method = 'Network.enable' }
    Send-Cdp @{ id = 81; method = 'Network.getCookies'; params = @{ urls = @($domain) } }
    $rc = Wait-Response 81 15
    if ($rc -and $rc.result.cookies) {
        $ch = ($rc.result.cookies | ForEach-Object { $_.name + '=' + $_.value }) -join '; '
        if (-not (Test-Path 'C:\temp')) { New-Item -ItemType Directory -Path 'C:\temp' | Out-Null }
        [System.IO.File]::WriteAllText($cookieFile, $ch, [System.Text.Encoding]::ASCII)
        [System.IO.File]::WriteAllText($domainFile, $domain, [System.Text.Encoding]::ASCII)
        Write-Step '会话已保存, 下次将免浏览器快速签到'
    }
} catch {}

try {
    if (-not (Test-Path 'C:\temp')) { New-Item -ItemType Directory -Path 'C:\temp' | Out-Null }
    Send-Cdp @{ id = 4; method = 'Page.captureScreenshot'; params = @{ format = 'png' } }
    $r = Wait-Response 4 20
    if ($r) {
        [System.IO.File]::WriteAllBytes('C:\temp\ikuuu_checkin_result.png', [Convert]::FromBase64String($r.result.data))
        Write-Output '截图     : C:\temp\ikuuu_checkin_result.png'
    }
} catch {}
Write-Output '========================================'
Write-Step '完成. Chrome 窗口保持打开, 可手动查看; 关闭窗口即退出登录态缓存'

$ws.Dispose()
