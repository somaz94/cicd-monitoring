# Jenkins Pipeline Examples

Jenkins pipeline examples for game resource management and mobile app builds.

> **Note:** For the Jenkins server Helm deployment, see [onpremise/jenkins/](../onpremise/jenkins/).

<br/>

## Overview

This directory contains Jenkinsfile examples for on-premise game build pipelines. Each pipeline manages a specific resource type and integrates with NAS storage, S3/CDN, and internal notification APIs.

<br/>

## Prerequisites

- Jenkins server with Kubernetes agent support
- SSH key configured for NAS access
- AWS CLI configured (for S3 upload pipelines)
- Unity Hub installed on the build node (for client pipelines)
- Xcode installed (for iOS pipeline)
- Internal admin API endpoint accessible from Jenkins

<br/>

## Pipelines

### `init-jenkinsfile` — Version Reset Pipeline

Resets version files for game resources on Dev or Staging environments.

**Parameters:**

| Parameter | Options | Description |
|-----------|---------|-------------|
| `GAME_SERVER` | `Dev`, `Staging` | Target environment |
| `RESOURCE_TYPE` | `Lua`, `Res` | Resource type to reset |

**Stages:**

1. **Reset Version** — Creates an empty version JSON file and uploads it to the NAS via SCP
2. **API Notification** — Sends an HTTP POST to the internal admin API to notify of the version reset
3. **Notification** — Final success/failure notification

**Key Configuration:**

```groovy
// SSH key for NAS access
sshagent(credentials: ['nas-ssh-key']) {
    sh "scp version.json user@nas.example.com:/mnt/nfs/your-app/${env}/server/version/${type}Version.json"
}

// Admin API notification
sh "curl -X POST http://api.example.com/admin/version/reset ..."
```

<br/>

### `ios-jenkinsfile` — iOS Build Pipeline

Builds an iOS app using Unity, creates an IPA, and uploads to TestFlight.

**Parameters:**

| Parameter | Options | Description |
|-----------|---------|-------------|
| `GAME_SERVER` | `Dev`, `Staging`, `Live` | Target environment |

**Stages:**

1. **Git Checkout** — Clones the client repository
2. **Unity Build** — Runs `BuilderJenkins.Build` to generate Xcode project
3. **Backup Bundle Version** — Saves the current version from `Info.plist`
4. **Increment Bundle Version** — Bumps version number for new build
5. **XCode Build** — Creates `.xcarchive` and exports `.ipa`
6. **TestFlight Upload** — Uploads via `xcrun altool`
7. **Post Actions** — Rolls back bundle version on failure

**Key Configuration:**

```groovy
// Unity executable path
def UNITY_PATH = "/Applications/Unity/Hub/Editor/2022.x.x/Unity.app/Contents/MacOS/Unity"

// Workspace directory
def WORKSPACE_DIR = "/path/to/jenkins/workspace/YourApp_iOS"
```

<br/>

### `lua-jenkinsfile` — Lua Resource Build Pipeline

Builds Lua resources using Unity and deploys to NAS and S3.

**Parameters:**

| Parameter | Options | Description |
|-----------|---------|-------------|
| `GAME_SERVER` | `Dev`, `Staging`, `Live` | Target environment |

**Stages:**

1. **Git Checkout** — Clones the client repository (300s timeout)
2. **Unity Build** — Runs `BuilderJenkins.HotfixLua` method
3. **Upload**
   - Loads version info from `DataVersion.json`
   - Uploads to NAS via `rsync` (excludes `.meta` files)
   - Updates server version file via `jq`
   - Notifies admin API
   - Uploads to S3 CDN bucket

**Key Configuration:**

```groovy
// NAS destination
def NAS_PATH = "/mnt/nfs/your-app/${env}/client/lua"

// S3 destination
def S3_PATH = "s3://your-cdn-bucket/your-app/Lua/${APP_VERSION}"
```

<br/>

### `res-jenkinsfile` — Resource Build Pipeline

Builds addressable resources for both iOS and Android platforms.

**Parameters:**

| Parameter | Options | Description |
|-----------|---------|-------------|
| `GAME_SERVER` | `Dev`, `Staging`, `Live` | Target environment |

**Stages:**

1. **Git** — Clones to separate `Android/` and `iOS/` workspace directories
2. **Unity Build**
   - iOS: runs `BuilderJenkins.HotfixResiOS`
   - Android: runs `BuilderJenkins.HotfixResAndroid`
3. **Upload**
   - Deploys iOS/Android assets to separate NAS paths
   - Updates version files via `jq`
   - Notifies admin API

**Key Configuration:**

```groovy
// iOS asset path
def IOS_ASSET_PATH = "${WORKSPACE}/iOS/AddressableData/iOS"

// Android asset path
def ANDROID_ASSET_PATH = "${WORKSPACE}/Android/AddressableData/Android"
```

<br/>

## Common Patterns

All pipelines share these patterns:

```groovy
// NAS SSH authentication
sshagent(credentials: ['nas-ssh-key']) {
    sh "rsync -avz --exclude='*.meta' ${LOCAL_PATH}/ user@nas.example.com:${NAS_PATH}/"
}

// Version file update
sh """
jq '.version = "${NEW_VERSION}"' version.json > version.json.tmp
mv version.json.tmp version.json
"""

// Admin API notification
def response = sh(
    script: "curl -s -o /dev/null -w '%{http_code}' -X POST ${API_URL}",
    returnStdout: true
).trim()
```

<br/>

## Environment Variables

| Variable | Description |
|----------|-------------|
| `GAME_SERVER` | Target environment (Dev/Staging/Live) |
| `APP_VERSION` | Application version string |
| `NAS_HOST` | NAS server hostname or IP |
| `ADMIN_API_URL` | Internal admin API base URL |
| `AWS_CREDENTIALS_ID` | Jenkins credential ID for AWS access |
| `NAS_SSH_KEY_ID` | Jenkins credential ID for NAS SSH key |

<br/>

## Related

- [onpremise/jenkins/](../onpremise/jenkins/) — Jenkins server Helm deployment
- [gitlab-cicd/](../gitlab-cicd/) — GitLab CI/CD pipeline templates
- [github-cicd/](../github-cicd/) — GitHub Actions workflows
