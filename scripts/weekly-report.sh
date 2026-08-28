#!/bin/bash
# iKuuu 周报生成器(WSL cron 每周日 24:00 即周一 00:00 调用)
BASE="$HOME/ikuuu"
LOGDIR="$BASE/logs"
DESKTOP="/mnt/c/Users/26912/Desktop"

sun=$(date -d 'yesterday' +%F)          # 周日
stamp=$(date -d 'yesterday' +%Y%m%d)
wk=$(date -d 'yesterday' +%V)

declare -A daystat daytraffic
# 近 7 天: sun-6 .. sun
weekdays=()
for i in 6 5 4 3 2 1 0; do
    weekdays+=("$(date -d "$sun -${i} day" +%F)")
done

# 汇总所有日志中的 DAY| 记录
declare -A all_last
if ls "$LOGDIR"/ikuuu-*.log >/dev/null 2>&1; then
    while IFS='|' read -r _ d st tr; do
        [ -z "$d" ] && continue
        st="${st#STATUS=}"; tr="${tr#TRAFFIC=}"
        all_last["$d"]="$st|$tr"
    done < <(cat "$LOGDIR"/ikuuu-*.log | grep -a '^DAY|')
fi

declare -A allstat
total=0
for d in "${!all_last[@]}"; do
    st="${all_last[$d]%%|*}"
    total=$((total + 1))
    allstat[$st]=$(( ${allstat[$st]:-0} + 1 ))
done

# 周内统计
ok=0; miss=0; err=0; other=0
declare -a detail_lines
wd_names=(一 二 三 四 五 六 日)
for d in "${weekdays[@]}"; do
    rec="${all_last[$d]:-}"
    if [ -z "$rec" ]; then
        st="MISSING"; tr="-"
    else
        st="${rec%%|*}"; tr="${rec#*|}"
    fi
    case "$st" in
        OK_*) ok=$((ok + 1)); mark="✓ 成功($st)";;
        ERROR) err=$((err + 1)); mark="✗ 报错";;
        MISSING) miss=$((miss + 1)); mark="· 缺失";;
        *) other=$((other + 1)); mark="? $st";;
    esac
    wd=$(date -d "$d" +%u)
    detail_lines+=("$d (${wd_names[$((wd - 1))]})  $mark  剩余: $tr")
done

first_traffic="-"; last_traffic="-"
for d in "${weekdays[@]}"; do
    rec="${all_last[$d]:-}"
    [ -z "$rec" ] && continue
    tr="${rec#*|}"
    [ "$tr" = "-" ] && continue
    [ "$first_traffic" = "-" ] && first_traffic="$tr"
    last_traffic="$tr"
done

session_state="未知"
[ -f /mnt/c/temp/ikuuu_cookie.txt ] && session_state="有效(可免浏览器秒签)"

report="$DESKTOP/iKuuu周报-$stamp-第${wk}周.txt"

# 清理旧周报, 只保留最新一份
rm -f "$DESKTOP"/iKuuu周报-*.txt

{
    echo "=========================================="
    echo "  iKuuu VPN 自动签到周报"
    echo "  周期: ${weekdays[0]} ~ $sun (第 ${wk} 周)"
    echo "  生成: $(date '+%F %T')"
    echo "=========================================="
    echo ""
    echo "── 近 7 天明细 ──"
    for line in "${detail_lines[@]}"; do echo "  $line"; done
    echo ""
    echo "── 本周汇总 ──"
    echo "  成功执行: $ok 天 | 缺失: $miss 天 | 报错: $err 天 | 其他: $other 天"
    echo "  流量变化: $first_traffic → $last_traffic"
    echo ""
    echo "── 全部记录汇总 ──"
    echo "  总记录天数: $total"
    for st in OK_DONE OK_FAST OK_ALREADY ERROR MISSING UNKNOWN; do
        [ -n "${allstat[$st]:-}" ] && echo "  $st: ${allstat[$st]} 天"
    done
    echo "  当前会话: $session_state"
    echo ""
    echo "── 说明 ──"
    echo "  OK_DONE=浏览器流程签到成功  OK_FAST=cookie快速签到"
    echo "  OK_ALREADY=当日已签过  MISSING=当日未执行(已补记)"
} > "$report" 2>/dev/null

echo "[$(date '+%F %T')] weekly report written: $report"
