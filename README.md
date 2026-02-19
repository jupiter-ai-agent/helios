# HELIOS

HELIOS 통합 인프라 플랫폼 설치

## 설치

```bash
curl -fsSL https://raw.githubusercontent.com/jupiter-ai-agent/helios/main/install.sh | sh
```

### 개발 모드 (이메일 인증 건너뜀)

```bash
curl -fsSL https://raw.githubusercontent.com/jupiter-ai-agent/helios/main/install.sh | sh -s -- --dev
```

## 요구사항

- Docker
- macOS (arm64/amd64) 또는 Linux (arm64/amd64)

## 포트

| 포트 | 서비스 |
|------|--------|
| 1110 | HELIOS Operator |
| 1111 | Keycloak Admin |
| 1113~1119 | 관리 서비스 |
