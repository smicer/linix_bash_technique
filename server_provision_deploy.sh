#!/bin/bash
# file: deploy_application.sh

# 🚀 웹 애플리케이션 자동 배포 및 서버 설정 스크립트

# 이 스크립트는 새로운 Ubuntu 서버에 웹 애플리케이션을 배포하고
# 필요한 종속성 설치, Nginx 설정, 서비스 활성화까지 모든 과정을 자동화합니다.
# 멱등성(Idempotency)과 오류 처리를 고려한 프로덕션 레벨 스크립트입니다.

# --- 설정 변수 (환경에 따라 변경) ---
APP_REPO_URL="https://github.com/your-org/your-app.git"
APP_BRANCH="main" # 배포할 브랜치
DEPLOY_DIR="/var/www/your-app"
APP_USER="www-data" # 애플리케이션 실행 사용자
NGINX_CONF_PATH="/etc/nginx/sites-available/your-app.conf"
NGINX_ENABLED_PATH="/etc/nginx/sites-enabled/your-app.conf"
SYSTEMD_SERVICE_NAME="your-app.service" # Systemd 서비스 이름
JAVA_VERSION="17" # 예: Java 애플리케이션

LOG_FILE="/var/log/deploy_app.log"
exec > >(tee -a "$LOG_FILE") 2>&1 # 스크립트 출력과 에러를 로그 파일에 기록

# --- 함수 정의 ---

log_info() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $1"
}

log_error() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] $1" >&2
    exit 1
}

# 함수: 필요 패키지 설치 (멱등성 고려)
install_dependencies() {
    log_info "필요한 시스템 패키지 설치 확인..."
    sudo apt update || log_error "APT 업데이트 실패."
    
    # Java (OpenJDK) 설치
    if ! command -v java &> /dev/null || [[ "$(java -version 2>&1)" != *"$JAVA_VERSION"* ]]; then
        log_info "Java OpenJDK $JAVA_VERSION 설치 중..."
        sudo apt install -y openjdk-$JAVA_VERSION-jdk || log_error "Java $JAVA_VERSION 설치 실패."
    else
        log_info "Java OpenJDK $JAVA_VERSION 이미 설치됨."
    fi

    # Nginx 설치
    if ! command -v nginx &> /dev/null; then
        log_info "Nginx 설치 중..."
        sudo apt install -y nginx || log_error "Nginx 설치 실패."
    else
        log_info "Nginx 이미 설치됨."
    fi
    
    # Git 설치
    if ! command -v git &> /dev/null; then
        log_info "Git 설치 중..."
        sudo apt install -y git || log_error "Git 설치 실패."
    else
        log_info "Git 이미 설치됨."
    fi
    log_info "필요한 시스템 패키지 설치/확인 완료."
}

# 함수: 애플리케이션 코드 클론/업데이트 (멱등성 고려)
deploy_code() {
    log_info "애플리케이션 코드 배포 시작..."
    if [ ! -d "$DEPLOY_DIR" ]; then
        log_info "배포 디렉토리 '$DEPLOY_DIR' 생성 중..."
        sudo mkdir -p "$DEPLOY_DIR" || log_error "배포 디렉토리 생성 실패."
        sudo chown "$APP_USER:$APP_USER" "$DEPLOY_DIR" || log_error "배포 디렉토리 소유권 변경 실패."
    fi

    if [ -d "$DEPLOY_DIR/.git" ]; then
        log_info "기존 저장소 업데이트 중..."
        sudo -u "$APP_USER" git -C "$DEPLOY_DIR" pull origin "$APP_BRANCH" || log_error "Git pull 실패."
    else
        log_info "새로운 저장소 클론 중..."
        sudo -u "$APP_USER" git clone -b "$APP_BRANCH" "$APP_REPO_URL" "$DEPLOY_DIR" || log_error "Git clone 실패."
    fi
    log_info "애플리케이션 코드 배포 완료."
}

# 함수: 애플리케이션 빌드 (Maven/Gradle 등 Java 빌드 툴 가정)
build_application() {
    log_info "애플리케이션 빌드 시작..."
    # 이 부분은 실제 애플리케이션의 빌드 과정에 따라 변경해야 합니다.
    # 예: Maven 프로젝트의 경우
    if command -v mvn &> /dev/null; then
        sudo -u "$APP_USER" mvn -f "$DEPLOY_DIR/pom.xml" clean install -DskipTests || log_error "Maven 빌드 실패."
    elif command -v gradle &> /dev/null; then
        sudo -u "$APP_USER" gradle -p "$DEPLOY_DIR" clean build -x test || log_error "Gradle 빌드 실패."
    else
        log_error "Maven 또는 Gradle을 찾을 수 없습니다. 빌드 도구를 설치하거나 이 부분을 조정하세요."
    fi
    log_info "애플리케이션 빌드 완료."
}

# 함수: Nginx 설정 (템플릿 사용 가능)
configure_nginx() {
    log_info "Nginx 설정 적용 시작..."
    # Nginx 설정 파일 내용 (여기서는 간단한 예시, 실제는 더 복잡)
    local nginx_conf="
server {
    listen 80;
    server_name your-domain.com; # 실제 도메인으로 변경

    location / {
        proxy_pass http://127.0.0.1:8080; # 애플리케이션이 실행되는 포트
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
"
    echo "$nginx_conf" | sudo tee "$NGINX_CONF_PATH" || log_error "Nginx 설정 파일 작성 실패."

    # 기존 심볼릭 링크 제거 (멱등성)
    if [ -L "$NGINX_ENABLED_PATH" ]; then
        sudo rm "$NGINX_ENABLED_PATH" || log_error "기존 Nginx 심볼릭 링크 삭제 실패."
    fi

    # 심볼릭 링크 생성
    sudo ln -s "$NGINX_CONF_PATH" "$NGINX_ENABLED_PATH" || log_error "Nginx 심볼릭 링크 생성 실패."

    # Nginx 설정 테스트 및 재시작
    sudo nginx -t && sudo systemctl reload nginx || log_error "Nginx 설정 테스트 또는 재로드 실패."
    log_info "Nginx 설정 적용 완료."
}

# 함수: Systemd 서비스 설정 및 활성화
configure_systemd_service() {
    log_info "Systemd 서비스 설정 시작..."
    # Systemd 서비스 파일 내용 (Java Jar 실행 예시)
    local service_file="
[Unit]
Description=Your Application Service
After=network.target

[Service]
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$DEPLOY_DIR
ExecStart=/usr/bin/java -jar $DEPLOY_DIR/target/your-app.jar # 실제 Jar 파일 경로로 변경
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
"
    echo "$service_file" | sudo tee "/etc/systemd/system/$SYSTEMD_SERVICE_NAME" || log_error "Systemd 서비스 파일 작성 실패."

    sudo systemctl daemon-reload || log_error "Systemd 데몬 리로드 실패."
    sudo systemctl enable "$SYSTEMD_SERVICE_NAME" || log_error "Systemd 서비스 활성화 실패."
    sudo systemctl start "$SYSTEMD_SERVICE_NAME" || log_error "Systemd 서비스 시작 실패."
    sudo systemctl status "$SYSTEMD_SERVICE_NAME" --no-pager || log_error "Systemd 서비스 상태 확인 실패."

    log_info "Systemd 서비스 설정 및 활성화 완료."
}

# --- 메인 배포 흐름 ---
log_info "애플리케이션 배포 스크립트 시작."

# 모든 함수는 내부적으로 오류 발생 시 스크립트를 종료하도록 설계되어 있습니다.
install_dependencies
deploy_code
build_application # Java 애플리케이션의 경우
configure_nginx
configure_systemd_service

log_info "애플리케이션 배포 및 설정 완료! 🎉"
