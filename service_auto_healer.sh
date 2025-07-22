#!/bin/bash
# file: service_health_monitor.sh

# 🚀 Docker/Kubernetes 서비스 헬스 체크 및 자가 복구 스크립트

# 이 스크립트는 특정 Docker 컨테이너 또는 Kubernetes Pod의 헬스 체크 엔드포포인트를 주기적으로 확인하고,
# 문제가 감지되면 자동으로 재시작을 시도하거나 관리자에게 알림을 보냅니다.
# 프로덕션 환경에서 서비스의 안정성을 보장하는 데 필수적인 스크립트입니다.

SERVICE_NAME="my-web-app" # 모니터링할 서비스 이름 (Docker Compose 서비스 이름 또는 K8s Deployment 이름)
HEALTH_CHECK_URL="http://localhost:8080/health" # 서비스의 헬스 체크 엔드포인트
CHECK_INTERVAL_SEC=10 # 헬스 체크 주기 (초)
FAILURE_THRESHOLD=3 # 연속 실패 횟수 임계치
CONTAINER_ENGINE="docker" # 또는 "kubectl"

ALERT_RECIPIENT="devops@yourdomain.com"
FAILURE_COUNT=0

# 함수: 알림 전송 (Slack, Email 등)
send_alert() {
    local subject="[긴급] $SERVICE_NAME 서비스 이상 감지"
    local message="$1"
    echo -e "$message" | mail -s "$subject" "$ALERT_RECIPIENT"
    echo "$(date) [ALERT] $subject: $message" >> /var/log/service_monitor.log
}

# 함수: 서비스 재시작
restart_service() {
    echo "$(date) [ACTION] '$SERVICE_NAME' 서비스 재시작 시도..." >> /var/log/service_monitor.log
    if [[ "$CONTAINER_ENGINE" == "docker" ]]; then
        # Docker Compose 사용 시
        if command -v docker-compose &> /dev/null; then
            docker-compose restart "$SERVICE_NAME"
            if [ $? -eq 0 ]; then
                echo "$(date) [SUCCESS] Docker Compose '$SERVICE_NAME' 재시작 성공." >> /var/log/service_monitor.log
                send_alert "$SERVICE_NAME 서비스가 재시작되었습니다."
                return 0
            else
                echo "$(date) [ERROR] Docker Compose '$SERVICE_NAME' 재시작 실패." >> /var/log/service_monitor.log
                send_alert "$SERVICE_NAME 서비스 재시작 시도 실패."
                return 1
            fi
        # 단일 Docker 컨테이너 사용 시
        elif command -v docker &> /dev/null; then
            docker restart $(docker ps -q --filter "name=$SERVICE_NAME")
            if [ $? -eq 0 ]; then
                echo "$(date) [SUCCESS] Docker 컨테이너 '$SERVICE_NAME' 재시작 성공." >> /var/log/service_monitor.log
                send_alert "$SERVICE_NAME 서비스가 재시작되었습니다."
                return 0
            else
                echo "$(date) [ERROR] Docker 컨테이너 '$SERVICE_NAME' 재시작 실패." >> /var/log/service_monitor.log
                send_alert "$SERVICE_NAME 서비스 재시작 시도 실패."
                return 1
            fi
        fi
    elif [[ "$CONTAINER_ENGINE" == "kubectl" ]]; then
        # Kubernetes Deployment 재시작 (롤링 업데이트 트리거)
        if command -v kubectl &> /dev/null; then
            kubectl rollout restart deployment "$SERVICE_NAME"
            if [ $? -eq 0 ]; then
                echo "$(date) [SUCCESS] Kubernetes Deployment '$SERVICE_NAME' 롤아웃 재시작 성공." >> /var/log/service_monitor.log
                send_alert "$SERVICE_NAME 서비스 Deployment 롤아웃이 재시작되었습니다."
                return 0
            else
                echo "$(date) [ERROR] Kubernetes Deployment '$SERVICE_NAME' 롤아웃 재시작 실패." >> /var/log/service_monitor.log
                send_alert "$SERVICE_NAME 서비스 Deployment 롤아웃 재시작 시도 실패."
                return 1
            fi
        fi
    fi
    echo "$(date) [ERROR] 서비스 재시작을 위한 컨테이너 엔진 ($CONTAINER_ENGINE)을 찾을 수 없거나 지원되지 않습니다." >> /var/log/service_monitor.log
    send_alert "$SERVICE_NAME 서비스 재시작 실패: 컨테이너 엔진 문제."
    return 1
}

echo "$(date) [INFO] '$SERVICE_NAME' 서비스 헬스 체크 시작..." >> /var/log/service_monitor.log

while true; do
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -m 5 -L "$HEALTH_CHECK_URL")
    
    if [ "$HTTP_STATUS" -eq 200 ]; then
        if [ "$FAILURE_COUNT" -gt 0 ]; then
            echo "$(date) [INFO] '$SERVICE_NAME' 서비스 정상 복구됨." >> /var/log/service_monitor.log
            send_alert "'$SERVICE_NAME' 서비스가 정상적으로 복구되었습니다."
        fi
        FAILURE_COUNT=0
    else
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
        echo "$(date) [WARN] '$SERVICE_NAME' 서비스 헬스 체크 실패 (HTTP Status: $HTTP_STATUS). 연속 실패 횟수: $FAILURE_COUNT" >> /var/log/service_monitor.log
        
        if [ "$FAILURE_COUNT" -ge "$FAILURE_THRESHOLD" ]; then
            echo "$(date) [CRITICAL] '$SERVICE_NAME' 서비스 연속 실패 임계치 도달. 재시작 시도." >> /var/log/service_monitor.log
            send_alert "'$SERVICE_NAME' 서비스가 $FAILURE_THRESHOLD회 연속으로 응답하지 않습니다. 재시작을 시도합니다."
            if restart_service; then
                FAILURE_COUNT=0 # 재시작 성공 시 카운트 리셋
            else
                # 재시작 실패 시, 추가적인 조치 또는 지속적인 알림
                echo "$(date) [ERROR] '$SERVICE_NAME' 서비스 재시작 실패, 지속적인 모니터링 필요." >> /var/log/service_monitor.log
                sleep 60 # 실패 시 더 긴 대기 후 다음 주기 확인
            fi
        fi
    fi
    sleep "$CHECK_INTERVAL_SEC"
done
