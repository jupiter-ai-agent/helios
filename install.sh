#!/bin/bash
# HELIOS Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/jupiter-ai-agent/helios/main/install.sh | sh
set -e

VERSION="0.1.0"
GITHUB_REPO="jupiter-ai-agent/helios"
HELIOS_HOME="$HOME/.helios"
EXECUTOR_BIN="/usr/local/bin/helios-executor"
SOCKET_PATH="$HOME/.helios/executor.sock"
OPERATOR_IMAGE="jupitertriangles/helios-operator:202602"

# ── 색상 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
ok()    { printf "${GREEN}[OK]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
fail()  { printf "${RED}[FAIL]${NC} %s\n" "$1"; exit 1; }

# ── OS/Arch 감지 ──
detect_platform() {
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) ARCH="amd64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *) fail "지원하지 않는 아키텍처: $ARCH" ;;
    esac
    case "$OS" in
        darwin|linux) ;;
        *) fail "지원하지 않는 OS: $OS" ;;
    esac
    PLATFORM="${OS}-${ARCH}"
}

# ── 업데이트 감지 ──
check_existing() {
    if [ -f "$HELIOS_HOME/executor.yaml" ]; then
        info "기존 HELIOS 설치 감지 — 업데이트 모드"
        UPDATE_MODE=true
    else
        UPDATE_MODE=false
    fi
}

# ── 이메일 인증 ──
verify_email() {
    if [ "$UPDATE_MODE" = true ]; then
        info "업데이트 — 이메일 인증 건너뜀 (인증된 호스트)"
        return 0
    fi

    AUTH_BIN="/tmp/helios-auth-${PLATFORM}"
    info "인증 바이너리 다운로드..."
    curl -fsSL -H "Cache-Control: no-cache" \
        "https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/helios-auth-${PLATFORM}" \
        -o "$AUTH_BIN" 2>/dev/null || fail "helios-auth 다운로드 실패. 릴리스를 확인하세요."
    chmod +x "$AUTH_BIN"

    info "설치 인증 진행..."
    "$AUTH_BIN" verify </dev/tty || fail "인증 실패"
    rm -f "$AUTH_BIN"
    ok "인증 완료"
}

# ── Docker 확인 ──
check_docker() {
    if ! command -v docker &>/dev/null; then
        fail "Docker가 설치되어 있지 않습니다. 먼저 Docker를 설치하세요."
    fi
    if ! docker info &>/dev/null; then
        fail "Docker 데몬이 실행 중이 아닙니다. Docker를 시작하세요."
    fi
    ok "Docker 확인"
}

# ── Executor 설치 ──
install_executor() {
    info "Executor 다운로드..."
    mkdir -p "$HELIOS_HOME"

    TMP_BIN="/tmp/helios-executor-${PLATFORM}"
    curl -fsSL -L "https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/helios-executor-${PLATFORM}" \
        -o "$TMP_BIN" || fail "helios-executor 다운로드 실패"
    
    if [ ! -s "$TMP_BIN" ]; then
        fail "다운로드된 파일이 비어있습니다"
    fi
    chmod +x "$TMP_BIN"

    # /usr/local/bin에 설치 (sudo 필요할 수 있음)
    if [ -w "$(dirname "$EXECUTOR_BIN")" ]; then
        mv "$TMP_BIN" "$EXECUTOR_BIN"
    else
        info "관리자 권한 필요"
        sudo mv "$TMP_BIN" "$EXECUTOR_BIN" </dev/tty
        sudo chmod +x "$EXECUTOR_BIN"
    fi
    ok "Executor 바이너리: $EXECUTOR_BIN"

    # 설정 파일 (신규 설치만)
    if [ ! -f "$HELIOS_HOME/executor.yaml" ]; then
        # 프로젝트 디렉토리 입력
        echo ""
        DEFAULT_DIR="/opt/helios"
        read -p "HELIOS 프로젝트 디렉토리 [${DEFAULT_DIR}]: " PROJECT_DIR </dev/tty
        PROJECT_DIR="${PROJECT_DIR:-${DEFAULT_DIR}}"
        if [ -w "$(dirname "$PROJECT_DIR")" ]; then
            mkdir -p "$PROJECT_DIR"
        else
            sudo mkdir -p "$PROJECT_DIR" </dev/tty
            sudo chown "$(whoami)" "$PROJECT_DIR"
        fi

        cat > "$HELIOS_HOME/executor.yaml" << YAML
socket_path: "${HELIOS_HOME}/executor.sock"
project_dir: "${PROJECT_DIR}"
log_file: "${HELIOS_HOME}/executor.log"
YAML
        ok "설정 파일: $HELIOS_HOME/executor.yaml"
    else
        info "기존 설정 유지: $HELIOS_HOME/executor.yaml"
        PROJECT_DIR=$(grep project_dir "$HELIOS_HOME/executor.yaml" | awk '{print $2}' | tr -d '"')
    fi
}

# ── 데몬 등록 ──
register_daemon() {
    if [ "$OS" = "darwin" ]; then
        register_launchd
    else
        register_systemd
    fi
}

register_launchd() {
    PLIST="$HOME/Library/LaunchAgents/co.triangles.helios-executor.plist"

    # 기존 데몬 중지
    launchctl unload "$PLIST" 2>/dev/null || true

    cat > "$PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>co.triangles.helios-executor</string>
    <key>ProgramArguments</key>
    <array>
        <string>${EXECUTOR_BIN}</string>
        <string>-config</string>
        <string>${HELIOS_HOME}/executor.yaml</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>${HELIOS_HOME}/executor.log</string>
    <key>StandardErrorPath</key>
    <string>${HELIOS_HOME}/executor.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
PLIST

    launchctl load "$PLIST"
    ok "launchd 데몬 등록"
}

register_systemd() {
    SERVICE="/etc/systemd/system/helios-executor.service"

    sudo tee "$SERVICE" > /dev/null << SERVICE
[Unit]
Description=HELIOS Executor
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=${EXECUTOR_BIN} -config ${HELIOS_HOME}/executor.yaml
Restart=always
RestartSec=5
User=$(whoami)

[Install]
WantedBy=multi-user.target
SERVICE

    sudo systemctl daemon-reload
    sudo systemctl enable helios-executor
    sudo systemctl restart helios-executor
    ok "systemd 데몬 등록"
}

# ── Executor 헬스체크 ──
wait_executor() {
    info "Executor 시작 대기..."
    for i in $(seq 1 15); do
        if [ -S "${HELIOS_HOME}/executor.sock" ]; then
            ok "Executor 소켓 연결 확인"
            return 0
        fi
        sleep 1
    done
    fail "Executor 시작 실패. 로그 확인: cat $HELIOS_HOME/executor.log"
}

# ── Operator 컨테이너 ──
start_operator() {
    info "Operator 이미지 pull..."
    docker pull "$OPERATOR_IMAGE" 2>/dev/null || warn "pull 실패 — 로컬 이미지 사용"

    # 기존 컨테이너 제거
    docker rm -f helios-operator 2>/dev/null || true

    info "Operator 컨테이너 기동..."
    docker run -d \
        --name helios-operator \
        --restart unless-stopped \
        -p 1110:1110 \
        -v "${HELIOS_HOME}/executor.sock:/var/run/helios-executor.sock" \
        -v "${PROJECT_DIR}:/helios" \
        -v helios-operator-data:/data \
        "$OPERATOR_IMAGE" >/dev/null

    # 헬스체크
    info "Operator 시작 대기..."
    for i in $(seq 1 20); do
        if curl -s http://localhost:1110/health >/dev/null 2>&1 || curl -sk https://localhost:1110/health >/dev/null 2>&1; then
            ok "Operator 기동 완료"
            return 0
        fi
        sleep 2
    done
    fail "Operator 시작 실패. 로그 확인: docker logs helios-operator"
}

# ── 삭제 ──
uninstall() {
    echo ""
    echo "  ╦ ╦╔═╗╦  ╦╔═╗╔═╗"
    echo "  ╠═╣║╣ ║  ║║ ║╚═╗"
    echo "  ╩ ╩╚═╝╩═╝╩╚═╝╚═╝"
    echo "  Uninstaller v${VERSION}"
    echo ""

    detect_platform

    printf "${RED}HELIOS를 완전히 삭제합니다. 모든 데이터가 삭제됩니다.${NC}\n"
    printf "계속하시겠습니까? (yes/no): "
    read CONFIRM </dev/tty
    if [ "$CONFIRM" != "yes" ]; then
        info "삭제 취소"
        exit 0
    fi

    # 1. Operator 컨테이너 + 볼륨
    info "Operator 컨테이너 삭제..."
    docker rm -f helios-operator 2>/dev/null || true
    docker volume rm helios-operator-data 2>/dev/null || true

    # 2. 설치된 모든 HELIOS 서비스 컨테이너
    info "HELIOS 서비스 컨테이너 삭제..."
    HELIOS_CONTAINERS=$(docker ps -a --format "{{.Names}}" 2>/dev/null | grep "^helios-" || true)
    if [ -n "$HELIOS_CONTAINERS" ]; then
        echo "$HELIOS_CONTAINERS" | xargs docker rm -f 2>/dev/null || true
    fi

    # 3. HELIOS 볼륨
    info "HELIOS 볼륨 삭제..."
    HELIOS_VOLUMES=$(docker volume ls --format "{{.Name}}" 2>/dev/null | grep "^helios" || true)
    if [ -n "$HELIOS_VOLUMES" ]; then
        echo "$HELIOS_VOLUMES" | xargs docker volume rm 2>/dev/null || true
    fi

    # 4. HELIOS 네트워크
    docker network rm helios_helios-net 2>/dev/null || true

    # 5. Executor 데몬 중지 + 제거
    info "Executor 데몬 제거..."
    if [ "$(uname -s)" = "Darwin" ]; then
        launchctl unload "$HOME/Library/LaunchAgents/co.triangles.helios-executor.plist" 2>/dev/null || true
        rm -f "$HOME/Library/LaunchAgents/co.triangles.helios-executor.plist"
    else
        sudo systemctl stop helios-executor 2>/dev/null || true
        sudo systemctl disable helios-executor 2>/dev/null || true
        sudo rm -f /etc/systemd/system/helios-executor.service
        sudo systemctl daemon-reload 2>/dev/null || true
    fi

    # 6. Executor 바이너리
    info "Executor 바이너리 삭제..."
    sudo rm -f "$EXECUTOR_BIN" </dev/tty 2>/dev/null || rm -f "$EXECUTOR_BIN" 2>/dev/null || true

    # 7. 프로젝트 디렉토리 (설정 삭제 전에 경로 읽기)
    PROJECT_DIR=""
    if [ -f "$HELIOS_HOME/executor.yaml" ]; then
        PROJECT_DIR=$(grep project_dir "$HELIOS_HOME/executor.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"')
    fi

    # 8. 설정 디렉토리
    info "설정 삭제..."
    rm -rf "$HELIOS_HOME"
    if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
        printf "프로젝트 디렉토리도 삭제하시겠습니까? (${PROJECT_DIR}) (yes/no): "
        read DEL_PROJECT </dev/tty
        if [ "$DEL_PROJECT" = "yes" ]; then
            sudo rm -rf "$PROJECT_DIR" </dev/tty 2>/dev/null || rm -rf "$PROJECT_DIR" 2>/dev/null || true
            ok "프로젝트 디렉토리 삭제 완료"
        fi
    fi

    echo ""
    ok "HELIOS 완전 삭제 완료"
    echo ""
}

# ── 메인 ──
main() {
    echo ""
    echo "  ╦ ╦╔═╗╦  ╦╔═╗╔═╗"
    echo "  ╠═╣║╣ ║  ║║ ║╚═╗"
    echo "  ╩ ╩╚═╝╩═╝╩╚═╝╚═╝"
    echo "  Installer v${VERSION}"
    echo ""

    detect_platform
    info "플랫폼: ${PLATFORM}"

    check_existing
    check_docker
    verify_email
    install_executor
    register_daemon
    wait_executor
    start_operator

    # 호스트 IP 감지
    if [ "$OS" = "darwin" ]; then
        HOST_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "localhost")
    else
        HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
    fi

    echo ""
    echo "  ┌──────────────────────────────────────┐"
    echo "  │                                      │"
    echo "  │   HELIOS 설치 완료!                  │"
    echo "  │                                      │"
    echo "  │   접속: http://${HOST_IP}:1110        │"
    echo "  │                                      │"
    echo "  └──────────────────────────────────────┘"
    echo ""
}

# ── 진입점 ──
case "${1:-}" in
    uninstall|remove|delete)
        uninstall
        ;;
    *)
        main
        ;;
esac
