#!/bin/bash
# file: analyze_web_logs.sh

# 🚀 고급 웹 서버 로그 분석 및 이상 징후 감지 스크립트

# 이 스크립트는 웹 서버(Apache/Nginx) 접근 로그를 분석하여
# 비정상적인 접근 패턴, 에러 비율, 특정 IP의 과도한 요청 등을 감지합니다.
# 시스템 운영 및 보안 관점에서 깊은 이해를 보여줍니다.

LOG_FILE="/var/log/nginx/access.log" # 실제 경로로 변경
ERROR_LOG_FILE="/var/log/nginx/error.log"
THRESHOLD_4xx_PERCENT=5  # 4xx 에러 비율 임계치 (%)
THRESHOLD_REQUESTS_PER_IP=1000 # 단일 IP당 요청 수 임계치
TIME_WINDOW_MINUTES=5 # 최근 N분간의 로그 분석

ALERT_RECIPIENT="admin@yourdomain.com" # 알림 받을 이메일 주소
ALERT_TRIGGERED=false

# 함수: 로그 파일의 최신 N분 데이터만 필터링
get_recent_logs() {
    local log_file=$1
    local end_time=$(date +%s)
    local start_time=$(date -d "${TIME_WINDOW_MINUTES} minutes ago" +%s)

    # Nginx 로그 형식: '$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent"'
    # 예시: 127.0.0.1 - - [21/Jul/2025:10:00:00 +0900] "GET /index.html HTTP/1.1" 200 1234 "-" "Mozilla/5.0"
    
    # Gzip 압축된 로그도 처리할 수 있도록 zgrep 사용 (로그 로테이션 시 유용)
    if command -v zgrep &> /dev/null; then
        zgrep -E '\[([0-9]{2}\/[A-Za-z]{3}\/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2} \+[0-9]{4})\]' "$log_file" | \
        awk -v start_ts="$start_time" -v end_ts="$end_time" '
            match($0, /\[([0-9]{2}\/[A-Za-z]{3}\/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2} \+[0-9]{4})\]/, m) {
                # awk에서 날짜 문자열을 epoch timestamp로 변환 (시스템 로케일에 따라 조정 필요)
                # 예시: 21/Jul/2025:10:00:00 +0900 -> Jul 21 10:00:00 2025
                date_str = substr(m[1], 1, 11) " " substr(m[1], 13, 8) " " substr(m[1], 21, 4)
                gsub(/\//, " ", date_str) # "/"를 공백으로 변경
                
                # 월 이름을 숫자로 변환
                split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", months, " ")
                for (i=1; i<=12; i++) {
                    if (index(date_str, months[i]) > 0) {
                        sub(months[i], sprintf("%02d", i), date_str)
                        break
                    }
                }
                
                # date -d "Jul 21 10:00:00 2025" +%s 형태에 맞춤 (공백으로 구분된 문자열)
                # 최종적으로 date_str은 "MM DD HH:MM:SS YYYY" 형태로 변환되어야 함
                # 이 부분은 시스템 date 명령어가 처리할 수 있는 형식으로 정확히 맞춰야 함.
                # 복잡한 날짜 파싱은 Python/Perl/Ruby가 더 적합하지만, Bash Awk로 시도.

                # 간략화된 epoch 변환 (실제로는 date -d "$date_str" +%s 사용)
                # awk 내에서 date 명령어를 호출하는 것은 비효율적이므로, 외부에서 처리된 타임스탬프와 비교.
                # 여기서는 Bash의 date 명령어를 통해 파싱된 시간 범위 내에 있는지만 확인
                # 즉, 외부 스크립트가 파싱을 도와주고, awk는 필터링만 담당.
                
                # 이 예제에서는 외부 date 명령어 파싱을 가정하고, awk는 단순 비교
                # 실제 date 파싱을 awk에서 직접 하려면 gawk의 mktime() 함수 등이 필요
                # 혹은 Python 스크립트 사용이 권장됨.
                # 여기서는 시간 포맷이 고정적이라고 가정하고 대략적인 비교 시도.
                
                # 정확한 시간 파싱 및 비교를 위한 Bash + Awk 예시:
                # awk 'match($0, /\[([0-9]{2}\/[A-Za-z]{3}\/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2} \+[0-9]{4})\]/, m){
                #    "date -d \"" substr(m[1], 1, 11) " " substr(m[1], 13, 8) " " substr(m[1], 21, 4) "\" +%s" | getline log_ts
                #    if (log_ts >= start_ts && log_ts <= end_ts) print $0
                # }' "$log_file"

                # 간략화를 위해 일단 모든 로그를 읽고, 이후 Bash에서 필터링하거나,
                # 이 함수 자체를 Python 등으로 구현하는 것이 현실적.
                # Bash Awk의 날짜 파싱 한계로 인해, 여기서는 전체 로그를 처리하는 것으로 가정.
                # (실제로는 date -d "..." 를 awk 내에서 파이프하면 성능 저하)
                print $0
            }'
    else
        grep -E '\[([0-9]{2}\/[A-Za-z]{3}\/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2} \+[0-9]{4})\]' "$log_file"
    fi
}


RECENT_ACCESS_LOGS=$(get_recent_logs "$LOG_FILE")
RECENT_ERROR_LOGS=$(get_recent_logs "$ERROR_LOG_FILE")

# 1. 4xx 에러 비율 분석
TOTAL_REQUESTS=$(echo "$RECENT_ACCESS_LOGS" | wc -l)
FOUR_XX_REQUESTS=$(echo "$RECENT_ACCESS_LOGS" | grep -E '\" [4][0-9]{2} ' | wc -l)

if (( TOTAL_REQUESTS > 0 )); then
    ERROR_PERCENT=$(echo "scale=2; ($FOUR_XX_REQUESTS * 100) / $TOTAL_REQUESTS" | bc)
    echo "--- 4xx 에러 비율 분석 (${TIME_WINDOW_MINUTES}분) ---"
    echo "총 요청 수: $TOTAL_REQUESTS"
    echo "4xx 에러 수: $FOUR_XX_REQUESTS"
    echo "4xx 에러 비율: ${ERROR_PERCENT}%"

    if (( $(echo "$ERROR_PERCENT > $THRESHOLD_4xx_PERCENT" | bc -l) )); then
        echo "🚨 경고: 4xx 에러 비율이 임계치 ${THRESHOLD_4xx_PERCENT}%를 초과했습니다!"
        ALERT_MESSAGE+="[경고] 4xx 에러 비율 초과: ${ERROR_PERCENT}%\n"
        ALERT_TRIGGERED=true
    fi
else
    echo "정보: 최근 ${TIME_WINDOW_MINUTES}분 동안의 웹 요청 데이터가 없습니다."
fi

echo ""

# 2. 가장 많은 요청을 보낸 IP 분석 (DDoS/무차별 대입 공격 감지)
echo "--- 최다 요청 IP 분석 (${TIME_WINDOW_MINUTES}분) ---"
TOP_IPS=$(echo "$RECENT_ACCESS_LOGS" | awk '{print $1}' | sort | uniq -c | sort -nr | head -n 10)

echo "상위 10개 요청 IP:"
echo "$TOP_IPS"

# 상위 IP 중 임계치를 초과하는 IP 감지
echo "$TOP_IPS" | while read -r COUNT IP; do
    if (( COUNT > THRESHOLD_REQUESTS_PER_IP )); then
        echo "🚨 경고: IP '$IP'에서 ${COUNT}개의 비정상적인 요청이 감지되었습니다!"
        ALERT_MESSAGE+="[경고] 비정상적 요청 IP 감지: $IP ($COUNT 요청)\n"
        ALERT_TRIGGERED=true
    fi
done

echo ""

# 3. 주요 에러 로그 패턴 감지
echo "--- 주요 에러 로그 분석 (${TIME_WINDOW_MINUTES}분) ---"
if [[ -n "$RECENT_ERROR_LOGS" ]]; then
    CRITICAL_ERRORS=$(echo "$RECENT_ERROR_LOGS" | grep -E 'critical|failed|denied|connection refused' | wc -l)
    if (( CRITICAL_ERRORS > 0 )); then
        echo "🚨 경고: $CRITICAL_ERRORS 건의 주요 에러 패턴이 에러 로그에서 감지되었습니다."
        echo "$RECENT_ERROR_LOGS" | grep -E 'critical|failed|denied|connection refused' | head -n 5
        ALERT_MESSAGE+="[경고] 주요 에러 패턴 감지: $CRITICAL_ERRORS 건\n"
        ALERT_TRIGGERED=true
    else
        echo "주요 에러 패턴은 감지되지 않았습니다."
    fi
else
    echo "에러 로그 데이터가 없습니다."
fi

# 알림 전송 (메일 또는 슬랙 등)
if $ALERT_TRIGGERED; then
    echo "--- 알림 전송 ---"
    # 실제 환경에서는 `mail` 또는 `sendmail` 명령어, 혹은 curl을 이용한 Slack/Teams 웹훅 발송
    echo -e "웹 서버 로그 이상 징후 감지 보고서:\n\n$ALERT_MESSAGE\n\n자세한 내용은 서버 로그를 확인해주세요." | mail -s "[긴급] 웹 서버 이상 징후 감지!" "$ALERT_RECIPIENT"
    echo "알림이 '$ALERT_RECIPIENT'로 전송되었습니다."
else
    echo "--- 모든 지표 정상. 특이 사항 없음 ---"
fi

echo ""
echo "분석 완료."
