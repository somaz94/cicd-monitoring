# 클라이언트 설정 가이드

Vaultwarden은 모든 Bitwarden 공식 클라이언트와 호환됩니다.
Self-hosted 서버 URL만 설정하면 됩니다.

<br/>

## Chrome Extension

1. [Bitwarden Chrome Extension](https://chromewebstore.google.com/detail/bitwarden-password-manage/nngceckbapebfimnlniiiahkandclblb) 설치
2. Extension 아이콘 클릭 → 로그인 화면
3. 하단의 **"접근 중: bitwarden.com"** 클릭
4. 드롭다운에서 **"자체 호스팅"** 선택
5. **Server URL**: `https://vault.example.com` 입력 → **저장**
6. 이메일 + 마스터 비밀번호로 로그인 또는 **"통합인증(SSO) 사용하기"** 클릭

<br/>

### SSO 로그인 (GitLab)

1. 로그인 화면에서 **"Enterprise single sign-on"** 클릭
2. **SSO Identifier**: `gitlab` (아무 문자열 가능)
3. GitLab 로그인 페이지로 리다이렉트
4. GitLab 인증 완료 → 마스터 비밀번호 설정 (최초 1회, 12자 이상)

<br/>

## 기타 클라이언트

모든 클라이언트에서 동일하게 **Self-hosted URL**만 설정하면 됩니다.

| 클라이언트 | 다운로드 |
|-----------|---------|
| Desktop (Windows/Mac/Linux) | https://bitwarden.com/download/#downloads-desktop |
| Mobile (iOS/Android) | App Store / Google Play에서 "Bitwarden" 검색 |
| Firefox Extension | https://addons.mozilla.org/firefox/addon/bitwarden-password-manager/ |
| CLI | https://bitwarden.com/download/#downloads-command-line-interface |

설정 방법:
1. 앱 실행 → 로그인 화면
2. Self-hosted 선택
3. Server URL: `https://vault.example.com`
4. 저장 후 로그인

<br/>

## 네트워크 요구사항

- `vault.example.com`는 내부 DNS로 `10.0.0.55`에 매핑
- **같은 네트워크**: 직접 접속 가능
- **외부**: VPN 연결 필요
