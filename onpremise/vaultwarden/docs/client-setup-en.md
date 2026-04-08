# Client Setup Guide

Vaultwarden is compatible with all official Bitwarden clients.
Simply configure the Self-hosted server URL.

<br/>

## Chrome Extension

1. Install [Bitwarden Chrome Extension](https://chromewebstore.google.com/detail/bitwarden-password-manage/nngceckbapebfimnlniiiahkandclblb)
2. Click Extension icon → Login screen
3. Click **"Logging in on: bitwarden.com"** at the bottom
4. Select **"Self-hosted"** from the dropdown
5. **Server URL**: `https://vault.example.com` → **Save**
6. Log in with email + master password or click **"Enterprise single sign-on (SSO)"**

<br/>

### SSO Login (GitLab)

1. Click **"Enterprise single sign-on"** on login screen
2. **SSO Identifier**: `gitlab` (any string works)
3. Redirected to GitLab login page
4. After GitLab auth → set master password (first time only, min 12 chars)

<br/>

## Other Clients

All clients require the same **Self-hosted URL** configuration.

| Client | Download |
|--------|----------|
| Desktop (Windows/Mac/Linux) | https://bitwarden.com/download/#downloads-desktop |
| Mobile (iOS/Android) | Search "Bitwarden" on App Store / Google Play |
| Firefox Extension | https://addons.mozilla.org/firefox/addon/bitwarden-password-manager/ |
| CLI | https://bitwarden.com/download/#downloads-command-line-interface |

Setup:
1. Open app → Login screen
2. Select Self-hosted
3. Server URL: `https://vault.example.com`
4. Save and log in

<br/>

## Network Requirements

- `vault.example.com` resolves to `10.0.0.55` via internal DNS
- **Same network**: Direct access
- **External**: VPN required
