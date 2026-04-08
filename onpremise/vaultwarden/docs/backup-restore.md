# 백업 & 복원 가이드

## 백업 전략

- **스케줄**: 매일 KST 03:00 (UTC 18:00)
- **파일 형식**: `db-YYYYMMDD.sqlite3`, `rsa_key-YYYYMMDD.pem`
- **보관 기간**: 30일 (초과 시 자동 삭제)
- **저장소**: `vaultwarden-backup-data` PVC (25Gi, NFS)

<br/>

## 백업 파일

| 파일 | 설명 |
|------|------|
| `db-YYYYMMDD.sqlite3` | SQLite 데이터베이스 (모든 vault 데이터, 사용자, 조직) |
| `rsa_key-YYYYMMDD.pem` | JWT 토큰 서명용 RSA 개인키 |

> **중요**: `rsa_key.pem`은 필수 파일입니다. 분실 시 기존 세션이 모두 무효화되며
> 사용자는 재인증해야 합니다.

<br/>

## 수동 백업

```bash
# 즉시 백업 실행
kubectl create job --from=cronjob/vaultwarden-backup manual-backup -n vaultwarden

# Job 상태 확인
kubectl get jobs -n vaultwarden

# 백업 로그 확인
kubectl logs job/manual-backup -n vaultwarden

# 백업 목록 확인
./scripts/restore.sh
```

<br/>

## 복원

### restore.sh 사용 (권장)

```bash
# 백업 목록 확인
./scripts/restore.sh

# 특정 날짜로 복원
./scripts/restore.sh 20260408

# 가장 최근 백업으로 복원
./scripts/restore.sh latest
```

스크립트가 자동으로 수행하는 작업:
1. Vaultwarden 중지 (replicas=0)
2. 백업 파일을 데이터 PVC로 복사
3. Vaultwarden 재시작 (replicas=1)
4. Pod ready 대기

<br/>

### 수동 복원

```bash
# 1. Vaultwarden 중지
kubectl scale statefulset vaultwarden --replicas=0 -n vaultwarden

# 2. 복원 Pod 실행
kubectl run restore --rm -it --image=busybox -n vaultwarden \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "restore",
        "image": "busybox",
        "command": ["sh", "-c",
          "cp /backup/db-20260408.sqlite3 /data/db.sqlite3 && echo Done"],
        "volumeMounts": [
          {"name": "data", "mountPath": "/data"},
          {"name": "backup", "mountPath": "/backup"}
        ]
      }],
      "volumes": [
        {"name": "data", "persistentVolumeClaim": {"claimName": "vaultwarden-data-vaultwarden-0"}},
        {"name": "backup", "persistentVolumeClaim": {"claimName": "vaultwarden-backup-data"}}
      ]
    }
  }'

# 3. Vaultwarden 재시작
kubectl scale statefulset vaultwarden --replicas=1 -n vaultwarden
```

<br/>

## 보관 기간 변경

`values/mgmt.yaml`의 CronJob args에서 `RETENTION_DAYS`를 수정합니다:

```yaml
# 현재: 30일
RETENTION_DAYS=30

# 예시: 90일로 변경
RETENTION_DAYS=90
```

적용: `helmfile apply`

<br/>

## 모니터링

```bash
# CronJob 스케줄 확인
kubectl get cronjobs -n vaultwarden

# 최근 백업 Job 확인
kubectl get jobs -n vaultwarden --sort-by=.metadata.creationTimestamp

# 백업 PVC 용량 확인
kubectl run check-size --rm -it --restart=Never --image=busybox -n vaultwarden \
  --overrides='{"spec":{"containers":[{"name":"check","image":"busybox","command":["du","-sh","/backup"],"volumeMounts":[{"name":"b","mountPath":"/backup"}]}],"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"vaultwarden-backup-data"}}]}}'
```
