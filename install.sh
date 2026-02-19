#!/bin/bash
# HELIOS Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/jupiter-ai-agent/helios/main/install.sh | sh
set -e

VERSION="0.1.0"
GITHUB_REPO="jupiter-ai-agent/helios"
HELIOS_HOME="$HOME/.helios"
EXECUTOR_BIN="/usr/local/bin/helios-executor"
SOCKET_PATH="/var/run/helios-executor.sock"
OPERATOR_IMAGE="jupitertriangles/helios-operator:202602"

# ── 색상 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()  { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

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
    DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/helios-executor-${PLATFORM}"
    info "URL: ${DOWNLOAD_URL}"
    curl -fSL "${DOWNLOAD_URL}" -o "$TMP_BIN" 2>&1 || fail "helios-executor 다운로드 실패"
    info "다운로드 크기: $(wc -c < "$TMP_BIN") bytes"
    
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
        read -p "HELIOS 프로젝트 디렉토리 [$(pwd)/helios]: " PROJECT_DIR </dev/tty
        PROJECT_DIR="${PROJECT_DIR:-$(pwd)/helios}"
        mkdir -p "$PROJECT_DIR"

        cat > "$HELIOS_HOME/executor.yaml" << YAML
listen: "unix:///var/run/helios-executor.sock"
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
        if [ -S "$SOCKET_PATH" ]; then
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
        -v "$SOCKET_PATH:/var/run/helios-executor.sock" \
        -v "${PROJECT_DIR}:/helios" \
        -v helios-operator-data:/data \
        "$OPERATOR_IMAGE" >/dev/null

    # 헬스체크
    info "Operator 시작 대기..."
    for i in $(seq 1 20); do
        if curl -sk https://localhost:1110/health >/dev/null 2>&1; then
            ok "Operator 기동 완료"
            return 0
        fi
        sleep 2
    done
    fail "Operator 시작 실패. 로그 확인: docker logs helios-operator"
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
    echo "  │   접속: https://${HOST_IP}:1110       │"
    echo "  │                                      │"
    echo "  └──────────────────────────────────────┘"
    echo ""
}

main
