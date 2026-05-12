# 용어집

본 위키에서 자주 쓰는 도메인 용어 + 약어. 사내 표준이 따로 있으면 사내 표준이 우선.

## FTP / 네트워크

| 용어 | 정의 |
|---|---|
| **PASV (passive mode)** | FTP 데이터 채널을 클라이언트→서버 방향으로 여는 모드. 서버가 임의 포트를 알려주면 클라이언트가 그 포트로 접속. NAT / 방화벽 뒤 클라이언트가 사용. |
| **control 채널** | TCP 21 — FTP 명령 / 응답 통로. 세션 시작부터 종료까지 유지. |
| **data 채널** | 실제 파일 전송 통로. PASV 모드에서는 PASV 포트 풀 (30000–30099) 에서 한 포트 사용. |
| **MetalLB** | k8s 의 LoadBalancer Service 를 베어메탈에서 동작시키는 컨트롤러. IP 풀에서 LB IP 할당. |
| **EHOSTUNREACH** | macOS lftp 4.9.3 에서 PASV 응답의 IP 로 직접 접속 시도가 막힐 때 발생. 알려진 결함 — `curl --ftp-pasv` 우회. |

## vsftpd / 가상 사용자

| 용어 | 정의 |
|---|---|
| **가상 사용자 (virtual user)** | OS 의 시스템 계정과 분리된, PAM `pam_pwdfile` 모듈로 인증되는 FTP 전용 사용자. `/etc/passwd` 에 없다. |
| **`ftpvirt`** | Pod 내부의 실제 시스템 계정. 모든 가상 사용자가 이 UID/GID 로 동작 (`guest_username=ftpvirt`). |
| **chroot jail** | 가상 사용자 로그인 시 root 디렉토리를 `/srv/ftp/<user>/` 로 제한. 이 디렉토리 밖에 접근 불가. |
| **`users.txt`** | Secret 에 마운트된 평문 사용자 목록. 사용자명 + 비밀번호 줄 페어. user-syncer 가 inotify 로 감지. |
| **`users.db`** | `db_load` 가 만든 Berkeley DB. PAM `pam_pwdfile` 이 참조. vsftpd 가 매 로그인마다 다시 연다. |
| **atomic rename** | `db_load` 가 `/tmp/users.db.new` 생성 후 `mv` 로 교체. 로그인 중인 세션이 깨지지 않음 (POSIX 보장). |
| **`pam_pwdfile`** | vsftpd 가 사용하는 PAM 인증 모듈. 평문 비밀번호 파일을 받아 인증. |

## Kubernetes / 스토리지

| 용어 | 정의 |
|---|---|
| **RWX (ReadWriteMany)** | PVC accessMode — 여러 Pod 가 동시에 마운트 가능. NAS / NFS / CephFS 등. |
| **RWO (ReadWriteOnce)** | PVC accessMode — 단일 노드에서만 마운트 가능. local PV / EBS 등. |
| **lease** | k8s 의 분산 락 객체 (`coordination.k8s.io/v1`). 본 프로젝트는 사용 안 함 — 단일 Pod 모델. |
| **kube-state-metrics** | Pod / Deployment 등 k8s 객체 상태를 메트릭으로 노출. `restartCount` 등 본 위키의 placeholder 메트릭 출처. |
| **named pipe** | `mkfifo` 로 만든 파일 시스템 객체. 읽기 / 쓰기 양쪽이 열려야 동작. entrypoint 에서 vsftpd 로그를 stdout 으로 흘리기 위해 사용. |

## 정책 / SLO

| 용어 | 정의 |
|---|---|
| **source of truth (SoT)** | 어떤 데이터의 *정본* 위치. 사용자 자격증명의 SoT 는 Secret + password manager, 데이터의 SoT 는 NAS PVC. |
| **RPO (Recovery Point Objective)** | 장애 시 *얼마나 이전 시점까지* 복원 가능한가. 본 프로젝트는 NAS 운영팀 정책에 위임. |
| **RTO (Recovery Time Objective)** | 장애 시 *얼마나 빨리* 복원 가능한가. RPO 와 동일하게 위임. |
| **PIT (point-in-time)** | 특정 시각으로 복원하는 능력. NAS 스냅샷 간격이 PIT 의 하한. |
| **SLO** | Service Level Objective — 가용성 / 지연 등의 목표값. 본 프로젝트는 사내 SLO 미확정. |
