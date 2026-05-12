# 코드 맵

이미지를 구성하는 4 개 파일 + Kubernetes 매니페스트 5 개의 책임 분담. 변경할 파일을 정하고 영향 범위를 가늠하는 인덱스.

## docker/

| 파일 | 책임 | 변경 빈도 | 변경 후 점검 |
|---|---|---|---|
| `Dockerfile` | Debian slim 12 베이스 + vsftpd + libpam-pwdfile + tini + 가상 사용자 PAM 설정 | 보안 패치 분기별 | [maintenance.md — 이미지 보안 패치](../operating/maintenance.md#이미지-보안-패치) |
| `conf/vsftpd.conf` | vsftpd 가상 사용자 / PASV / 로그 / 최대 클라이언트 설정 | 정책 변경 시 | 컨테이너 재기동 후 operating/testing.md — local-smoke.sh |
| `conf/pam_vsftpd_virtual` | PAM 구성 — `pam_pwdfile` 모듈로 `/etc/vsftpd_user_passwd` 참조 | 거의 없음 | 변경 시 PAM 동작 직접 테스트 (가짜 사용자 1 명 추가 후 로그인) |
| `entrypoint.sh` | tini 아래에서 user-syncer 백그라운드 시작 + named pipe 로그 + vsftpd foreground | 거의 없음 | operating/testing.md — local-smoke.sh |
| `user-syncer.sh` | `users.txt` inotify 감지 → `db_load` 로 `users.db` atomic rename | 사용자 sync 로직 변경 시 | operating/testing.md — zero-downtime-useradd.sh |

## k8s/

| 파일 | 책임 | 변경 빈도 |
|---|---|---|
| `00-namespace.yaml` | `ftp` namespace | 1 회 |
| `01-pvc.yaml` | `ftp-data` RWX PVC (NAS StorageClass) | 1 회 |
| `02-configmap.yaml` | `PASV_ADDRESS` (LB IP) | LB IP 변경 시 |
| `03-secret.yaml.example` | 가상 사용자 자격증명 템플릿. 실제 Secret 은 `kubectl create secret` 으로 생성 (Git 커밋 금지) | 사용자 추가/제거 (별도 운영 절차) |
| `04-deployment.yaml` | vsftpd Pod (vsftpd + user-syncer 사이드카) | 리소스 / 이미지 태그 변경 시 |
| `05-service.yaml` | LoadBalancer Service — 21 + 30000–30099 PASV 포트 노출, MetalLB annotation | 포트 범위 / LB IP 변경 시 |
