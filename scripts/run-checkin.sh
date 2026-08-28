#!/bin/bash
# iKuuu 每日签到运行器(WSL cron 每天 12:00 调用)
BASE="$HOME/ikuuu"
LOGDIR="$BASE/logs"
DESKTOP="/mnt/c/Users/26912/Desktop"
PWSH='/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
PS1SCRIPT='C:\Users\26912\ikuuu-auto-checkin.ps1'
source "$BASE/config.sh"
mkdir -p "$LOGDIR"
today=$(date +%F)
today_s=$(date +%s)

# ---------- 滚动日志: 每 30 天一个新文件, 删除 30 天前的 ----------
cur=""
for f in $(ls -1 "$LOGDIR"/ikuuu-*.log 2>/dev/null | sort); do
    d=$(basename "$f" .log); d=${d#ikuuu-}
    ds=$(date -d "$d" +%s 2>/dev/null) || continue
    age=$(( (today_s - ds) / 86400 ))
    if [ "$age" -ge 30 ]; then
        rm -f "$f"
    else
        cur="$f"
    fi
done
if [ -z "$cur" ]; then
    cur="$LOGDIR/ikuuu-$(date +%Y%m%d).log"
    touch "$cur"
fi

# ---------- 补记缺失日期(从上一次有记录的下一天到昨天) ----------
state="$BASE/state.txt"
last=$(grep -m1 '^LAST_RUN_DATE=' "$state" 2>/dev/null | cut -d= -f2)
if [ -n "$last" ] && [[ "$last" < "$today" ]]; then
    d=$(date -d "$last +1 day" +%F)
    while [[ "$d" < "$today" ]]; do
        echo "DAY|$d|STATUS=MISSING|TRAFFIC=-" >> "$cur"
        d=$(date -d "$d +1 day" +%F)
    done
fi

# ---------- 执行签到 ----------
{
    echo ""
    echo "===== RUN $(date '+%F %T') ====="
} >> "$cur"
out=$("$PWSH" -NoProfile -ExecutionPolicy Bypass -File "$PS1SCRIPT" \
    -Email "$IKUUU_EMAIL" -Password "$IKUUU_PASSWORD" 2>&1)
rc=$?
echo "$out" >> "$cur"

# ---------- 结果分类 ----------
if [ "$rc" -ne 0 ] || echo "$out" | grep -qaE '登录失败|NO_BUTTON|异常|Exception|FullyQualifiedErrorId'; then
    status="ERROR"
    errfile="$DESKTOP/iKuuu报错-$(date +%Y%m%d-%H%M%S).txt"
    {
        echo "iKuuu 签到报错  $(date '+%F %T')"
        echo "退出码: $rc"
        echo "----------------------------------------"
        echo "$out"
    } > "$errfile" 2>/dev/null
elif echo "$out" | grep -qa '快速签到完成'; then
    status="OK_FAST"
elif echo "$out" | grep -qa '签到结果 : DONE'; then
    status="OK_DONE"
elif echo "$out" | grep -qaE 'ALREADY|今日已签到'; then
    status="OK_ALREADY"
else
    status="UNKNOWN"
fi

traffic=$(echo "$out" | grep -aoE '剩余流量[^0-9]*[0-9.]+ ?[KMGT]?B?' | tail -1 | grep -aoE '[0-9.]+ ?[KMGT]?B' | tail -1)
[ -z "$traffic" ] && traffic=$(echo "$out" | grep -aoE '当前流量 : [0-9.]+ ?[KMGT]?B?' | grep -aoE '[0-9.]+ ?[KMGT]?B' | tail -1)
[ -z "$traffic" ] && traffic="-"

echo "DAY|$today|STATUS=$status|TRAFFIC=$traffic" >> "$cur"
echo "LAST_RUN_DATE=$today" > "$state"
echo "[$(date '+%F %T')] status=$status traffic=$traffic log=$cur"
