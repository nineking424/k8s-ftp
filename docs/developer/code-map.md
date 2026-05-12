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

## 컴포넌트별 상세

### Dockerfile

- Base: `debian:12-slim` — 가상 사용자 + PAM 모듈 필요해서 alpine 안 씀.
- Packages: `vsftpd`, `libpam-pwdfile`, `db-util` (Berkeley DB CLI for `db_load`), `tini`, `inotify-tools`.
- COPY 4 종: `vsftpd.conf`, `pam_vsftpd_virtual`, `entrypoint.sh`, `user-syncer.sh`.
- 영구 디렉토리: `/var/run/vsftpd/` (named pipe), `/srv/ftp/` (사용자 데이터), `secure_chroot_dir`.
- ENTRYPOINT: `tini -- /entrypoint.sh` — PID 1 / zombie reaping.
- EXPOSE: `21 30000-30099`.

### conf/vsftpd.conf

- 가상 사용자: `guest_enable=YES` + `guest_username=ftpvirt` (Pod 내 실제 시스템 사용자) + `virtual_use_local_privs=YES`.
- chroot: `chroot_local_user=YES` + `allow_writeable_chroot=YES` (`/srv/ftp/<user>` 가 사용자별 root).
- PASV: `pasv_enable=YES` + `pasv_min_port=30000` + `pasv_max_port=30099` + `pasv_address=$PASV_ADDRESS`.
- 로그: `xferlog_enable=YES` + `xferlog_std_format=NO` + `xferlog_file=/var/run/vsftpd/vsftpd.log` (named pipe).
- 동시성: `max_clients=600` + `max_per_ip=10`.

### conf/pam_vsftpd_virtual

2 줄. `auth required pam_pwdfile.so pwdfile=/etc/vsftpd_user_passwd` + `account required pam_permit.so`. `pam_pwdfile` 모듈이 user-syncer 가 만든 Berkeley DB 를 평문 비교 인증으로 참조.

### entrypoint.sh

순서:
1. `mkfifo /var/run/vsftpd/vsftpd.log` — vsftpd 가 RO root 에서도 로그 출력 가능하게.
2. `tail -F /var/run/vsftpd/vsftpd.log &` — named pipe 를 stdout 으로 흘려 `kubectl logs` 에 노출.
3. `/user-syncer.sh &` — 백그라운드 sync 데몬.
4. `exec /usr/sbin/vsftpd /etc/vsftpd/vsftpd.conf` — foreground (tini 아래 PID 2).

### user-syncer.sh

입력: `/etc/vsftpd/users.txt` (Secret 마운트).
출력: `/etc/vsftpd_user_passwd` (`db_load` 결과 Berkeley DB).

동작:
1. `inotifywait -m -e modify,create,move /etc/vsftpd/users.txt` 루프.
2. 줄 수 짝수 검증 (사용자명 + 비밀번호 페어).
3. 사용자명 정규식 검증 (`^[a-z][a-z0-9_-]{0,31}$`).
4. `db_load -T -t hash /tmp/users.db.new` — 표준 입력으로 페어를 받아 DB 생성.
5. `mv /tmp/users.db.new /etc/vsftpd_user_passwd` — atomic rename (POSIX 보장).
6. 신규 사용자별 `mkdir -p /srv/ftp/<user>/` + owner/perms 일관.

vsftpd 는 매 로그인마다 DB 를 다시 열기 때문에 재기동 불필요. 반영 지연은 inotify → db_load → mv 합계 약 18 초 (관측치).
