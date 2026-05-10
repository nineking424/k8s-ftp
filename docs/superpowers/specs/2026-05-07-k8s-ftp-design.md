# k8s에서 동작하는 Plain FTP 서비스 설계

- 문서 작성일: 2026-05-07
- 상태: 설계 (구현 전)

## 1. 목표와 배경

k8s 클러스터 내부에 Plain FTP 서비스를 구축한다. 사내 사용자가 자신의 격리된 디렉토리에 파일을 송수신할 수 있어야 하며, ACTIVE/PASV 모드를 모두 지원하고, 500명 이상 동시 접속을 수용한다. 사외망 접근은 인프라 레벨에서 차단되어 있다는 전제 위에서 설계한다.

## 2. 요구사항 확정

| 항목 | 결정 | 비고 |
|---|---|---|
| 프로토콜 | Plain FTP | FTPS, SFTP는 도입하지 않는다 |
| 모드 | ACTIVE + PASV | ACTIVE는 best-effort. EgressIP 정책으로 보강 |
| 노출 범위 | 사내망 전용 | 사외망 차단은 인프라 방화벽이 담당 |
| 스토리지 | NAS StorageClass PVC | RWX, 사내 NAS 백엔드 |
| 사용자 인증 | vsftpd 가상 사용자 | pam_userdb 기반. 평문 사용자 목록은 Secret으로 관리 |
| 사용자 격리 | chroot per user | `/srv/ftp/<username>` 단위 |
| 동시 접속 규모 | 500+ | 단일 Pod 수직 스케일로 수용 |
| HA | 단일 Pod (SPOF 수용) | 재시작 다운타임 <30초 허용 |
| MinIO 사용 | 미사용 | FTP 클라이언트가 유일한 데이터 소비자 |

## 3. 아키텍처 개요

```
[FTP 클라이언트들] ──(사내망)──▶ [내부 LoadBalancer 10.0.0.42]
                                           │
                                           ▼
                              ┌────────────────────────┐
                              │   k8s Pod (단일)        │
                              │  ┌─────────────────┐   │
                              │  │ vsftpd          │   │
                              │  │ control: :21    │   │
                              │  │ passive: 30000- │   │
                              │  │          30099  │   │
                              │  └─────────────────┘   │
                              │  ┌─────────────────┐   │
                              │  │ user-syncer     │   │
                              │  │ (사이드카)       │   │
                              │  └─────────────────┘   │
                              │           │            │
                              │           ▼ /srv/ftp   │
                              │   [PVC: NAS StorageClass]│
                              └────────────────────────┘
                                           │
                                           ▼
                                  [사내 NAS (RWX)]

[outgoing ACTIVE 데이터 연결]
  vsftpd Pod ──▶ Calico EgressGateway (SNAT to 10.0.0.42) ──▶ 클라이언트
```

핵심 설계 선택:
- **단일 Pod**: PASV 포트 샤딩, sticky session, 다중 Pod 간 source IP 일관성 문제를 모두 회피한다. 트레이드오프는 Pod 재시작 시 짧은 다운타임이며, 내부 사용 도구로 수용 가능하다.
- **가상 사용자**: 컨테이너 내 OS 사용자를 만들지 않고 vsftpd guest 모드로 모든 인증을 가상 사용자에게 위임한다. 사용자 추가/제거가 가벼워진다.
- **chroot 격리**: 각 사용자는 자기 chroot 루트 밖으로 빠져나가지 못한다.
- **EgressIP = LB IP**: ACTIVE 모드에서 서버가 클라이언트로 거는 outgoing TCP의 source IP를 LoadBalancer IP로 SNAT하여 클라이언트 방화벽이 일관되게 허용하도록 한다.

## 4. 컴포넌트

### 4.1 vsftpd 컨테이너 이미지

Debian 12-slim 기반 자체 빌드. 진입점 스크립트가 ConfigMap/Secret을 읽고 vsftpd를 기동한다. 분기별 보안 패치 재빌드 주기를 가진다.

**베이스 이미지 결정 (2026-05-11 갱신)**: 본 설계의 핵심인 vsftpd 가상 사용자 인증은 `pam_userdb.so` 모듈에 의존한다. Alpine Linux 3.20의 `linux-pam` 패키지는 이 모듈을 빌드 시 포함하지 않아 사용 불가하다. Debian 12-slim의 `libpam-modules` 패키지는 `pam_userdb.so`를 정상 제공하며 `db-util`로 `db_load`도 함께 사용 가능하다. 트레이드오프: 이미지 크기 증가(~22MB → ~80MB), 패치 빈도 차이는 분기별 재빌드로 흡수한다.

Dockerfile 골자:
```Dockerfile
FROM debian:12-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        vsftpd libpam-modules db-util inotify-tools \
    && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /entrypoint.sh
RUN useradd -r -s /usr/sbin/nologin ftpvirt
EXPOSE 21 30000-30099
ENTRYPOINT ["/entrypoint.sh"]
```

### 4.2 vsftpd 핵심 설정 (`vsftpd.conf`)

```ini
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
guest_enable=YES
guest_username=ftpvirt
user_sub_token=$USER
local_root=/srv/ftp/$USER
chroot_local_user=YES
allow_writeable_chroot=YES
hide_ids=YES

pasv_enable=YES
pasv_address=10.0.0.42
pasv_addr_resolve=NO
pasv_min_port=30000
pasv_max_port=30099

port_enable=YES
connect_from_port_20=YES
ftp_data_port=20

max_clients=600
max_per_ip=10
local_max_rate=0

pam_service_name=vsftpd_virtual

xferlog_enable=YES
xferlog_std_format=NO
log_ftp_protocol=YES
vsftpd_log_file=/dev/stdout
```

### 4.3 PAM 가상 사용자 인증

`/etc/pam.d/vsftpd_virtual`:
```
auth required pam_userdb.so db=/shared/users
account required pam_userdb.so db=/shared/users
```

`pam_userdb`는 인증 시점마다 DB 파일을 새로 연다. DB 파일을 원자적으로 교체하면 vsftpd 재시작 없이 신규 사용자가 즉시 인증 가능하다.

### 4.4 디렉토리 구조

```
/srv/ftp/                  ← PVC 마운트
├── alice/                 ← alice의 chroot 루트
├── bob/
└── ...
```

각 사용자 디렉토리는 user-syncer가 `mkdir -p`로 보장하며 `ftpvirt:ftpvirt` 소유로 설정한다.

### 4.5 user-syncer 사이드카

역할: Secret이 갱신될 때 vsftpd 재시작 없이 사용자 DB와 디렉토리를 동기화한다.

알고리즘 (셸 스크립트, 50줄 미만):
```
1. inotifywait로 /var/run/users/users.txt 변경 감시
2. 변경 감지 시:
   a. 형식 검증 (실패 시 기존 DB 유지하고 경고 로그)
   b. db_load -T -t hash users.txt > /shared/users.db.new
   c. 사용자별 mkdir -p /srv/ftp/<user> + chown
   d. mv /shared/users.db.new /shared/users.db (원자적 rename)
3. 다음 인증 요청부터 새 DB 사용
```

평균 전파 지연: kubelet Secret 갱신 주기 ~60초 + inotify 즉시 반응 + 5초 미만 처리. 최대 90초 내에 신규 사용자 로그인 가능.

### 4.6 k8s 리소스 명세

| 리소스 | 이름 | 역할 |
|---|---|---|
| Namespace | `ftp` | 격리 |
| Deployment | `vsftpd` | replicas: 1 |
| PVC | `ftp-data` | NAS StorageClass, RWX |
| ConfigMap | `vsftpd-config` | `vsftpd.conf`, PAM 설정, entrypoint |
| Secret | `vsftpd-users` | 가상 사용자 평문 목록 (`username\npassword\n` 줄 교차) |
| Service | `vsftpd` | type: LoadBalancer, loadBalancerIP: 10.0.0.42, 21 + 30000-30099 |
| Deployment | `egress-gateway-ftp` | Calico Egress Gateway, replicas: 2 (active/standby) |
| IPPool | `ftp-egress-pool` | EgressIP를 LB IP와 동일하게 발급 |
| EgressGatewayPolicy | `vsftpd-egress` | vsftpd Pod의 outgoing을 Egress Gateway로 라우팅 |

NetworkPolicy는 적용하지 않는다. 사내망 신뢰 경계 내부이며 사외 차단은 인프라가 담당한다.

## 5. 데이터 흐름

### 5.1 PASV 정상 경로

```
Client                LB(10.0.0.42)         vsftpd Pod
  │  TCP :21 ─────▶  │ ─────────────────▶  │
  │  USER alice ───────────────────────▶   │
  │  PASS *** ─────────────────────────▶   │ → pam_userdb
  │  ◀── 230 OK
  │  PASV ─────────────────────────────▶   │
  │  ◀── 227 (10,0,0,42,117,42)            │   ← pasv_address=LB IP
  │  TCP :30000 ─▶  │ ─────────────────▶   │
  │  STOR file ────────────────────────▶   │
  │  ─── data ─────────────────────────▶   │ → /srv/ftp/alice/file
  │  ◀── 226
```

핵심:
- `pasv_address=10.0.0.42`로 LB IP 광고
- LB는 21 + 30000-30099 모든 포트를 동일 Pod로 라우팅
- Service `externalTrafficPolicy: Local`로 source IP 보존

### 5.2 ACTIVE 정상 경로 (EgressIP 적용 후)

```
Client(192.168.1.50)    Egress Gateway          vsftpd Pod
  │                     (SNAT to 10.0.0.42)         │
  │  USER/PASS ──────────────────────────────────▶  │
  │  PORT 192.168.1.50:51201 ────────────────────▶  │
  │  RETR file ──────────────────────────────────▶  │
  │  ◀ TCP SYN to 192.168.1.50:51201
  │     src=10.0.0.42 ◀── SNAT ◀── (originally Pod IP)
  │  Client firewall: 10.0.0.42 허용 → 통과 ✓
```

### 5.3 부팅 시퀀스

```
1. PVC 바인딩 (NAS)
2. initContainer:
   - Secret(/var/run/users/users.txt) 읽기
   - db_load → /shared/users.db (initial)
   - 사용자별 디렉토리 mkdir -p
3. main container vsftpd:
   - ConfigMap의 vsftpd.conf 마운트
   - /shared/users.db 사용
   - /srv/ftp PVC 마운트
   - listen :21, :30000-30099
4. sidecar user-syncer:
   - inotifywait 시작
5. Service Endpoint 등록 → LB 트래픽 수신
```

### 5.4 무중단 사용자 추가 흐름

```
운영자 → kubectl edit secret vsftpd-users
       → kubelet이 Pod 내 마운트 파일 갱신 (~60초)
       → user-syncer가 inotify 이벤트 수신
       → users.db 재생성 + 원자적 교체
       → 신규 사용자 즉시 인증 가능
       → 기존 세션 영향 없음
```

다운타임 0. 사용자 디렉토리 생성도 함께 수행된다. 사용자 *제거* 시 데이터는 남으며, 별도 운영 절차로 정리한다.

### 5.5 장애 시나리오

| 상황 | 영향 | 복구 |
|---|---|---|
| vsftpd 프로세스 죽음 | 새 연결 거부 | livenessProbe → 컨테이너 재시작 |
| Pod crash | 진행 중 전송 중단, ~30초 다운 | k8s 자동 재기동 |
| Node 장애 | 다른 Node로 재스케줄까지 다운 (수 분) | k8s 자동 재스케줄 |
| NAS 장애 | 모든 IO 실패 | NAS 복구 의존 |
| Egress Gateway 노드 장애 | ACTIVE 모드 일시 실패 | Calico BGP가 standby로 페일오버 (수 초) |
| 사용자 DB 손상 | 인증 실패 | initContainer 재실행 또는 Secret 복구 |
| Secret 형식 오류 | user-syncer 거부, 기존 DB 유지 | Secret 수정 |
| LB IP 변경 | PASV 응답 불일치 | `pasv_address` ConfigMap 갱신 + Pod 재시작 |

## 6. 보안

### 6.1 위협 모델

- 사외망 공격: 인프라 방화벽이 차단한다. 본 설계 범위 밖이다.
- 사내 사용자 간 데이터 누출: chroot로 격리한다.
- 자격증명 평문 노출: 사내망 신뢰 전제. 위험 수용.
- 컨테이너 권한 상승: capabilities 최소화로 완화한다.

### 6.2 컨테이너 보안

```yaml
securityContext:
  runAsUser: 0
  runAsGroup: 0
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: [ALL]
    add: [NET_BIND_SERVICE, SYS_CHROOT]
```

쓰기가 필요한 경로는 emptyDir로 분리한다 (`/var/run`, `/tmp`, `/shared`).

### 6.3 Secret 관리

- `vsftpd-users` Secret 편집 권한은 `ftp` 네임스페이스 RBAC로 운영자 그룹에 한정한다.
- 평문 사용자 목록은 GitOps 저장소에 평문 저장하지 않는다. SealedSecrets, External Secrets, 또는 운영자 수동 적용 중 운영팀 정책에 맞춰 선택한다.

### 6.4 감사

- xferlog가 stdout으로 출력되어 클러스터 로그 수집기로 흘러간다.
- 인증 성공/실패, 파일 전송 명세가 모두 기록된다.

## 7. Calico EgressGateway 설정

> **사전 확인 필수**: Egress Gateway 기능은 Calico Enterprise (Tigera Calico Cloud/Enterprise) 기능이다. OSS Calico에는 동등 기능이 없다. 사내 Calico 라이선스 종류를 먼저 확인할 것. OSS Calico만 사용 가능한 경우 대안 경로(hostNetwork DaemonSet 또는 ACTIVE 모드 포기)로 재설계 필요.
>
> 아래 매니페스트는 Calico Enterprise 기준이며, 정확한 API 버전과 필드는 운영 중인 Calico 버전 문서로 검증한 뒤 적용할 것.

### 7.1 IPPool

```yaml
apiVersion: projectcalico.org/v3
kind: IPPool
metadata:
  name: ftp-egress-pool
spec:
  cidr: 10.0.0.42/32
  blockSize: 32
  natOutgoing: false
  disabled: false
```

### 7.2 Egress Gateway Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: egress-gateway-ftp
  namespace: egress-gateway
spec:
  replicas: 2
  selector:
    matchLabels: { app: egress-gateway-ftp }
  template:
    metadata:
      annotations:
        cni.projectcalico.org/awsSrcDstCheck: Disable
      labels:
        app: egress-gateway-ftp
        egress-code: "ftp"
    spec:
      nodeSelector:
        ftp-egress-gateway: "true"
      containers:
        - name: gateway
          image: quay.io/calico/egress-gateway:v3.27.0
          env:
            - name: EGRESS_POD_IP
              valueFrom:
                fieldRef: { fieldPath: status.podIP }
          securityContext:
            capabilities:
              add: [NET_ADMIN]
```

### 7.3 EgressGatewayPolicy

```yaml
apiVersion: projectcalico.org/v3
kind: EgressGatewayPolicy
metadata:
  name: vsftpd-egress
spec:
  rules:
    - destination:
        cidr: 0.0.0.0/0
      gateway:
        namespaceSelector: "projectcalico.org/name == 'egress-gateway'"
        selector: "egress-code == 'ftp'"
        maxNextHops: 1
```

### 7.4 BGP 광고 충돌 방지

LB IP `10.0.0.42`를 LoadBalancer 시스템(MetalLB 또는 사내 LB)이 광고하는 동안, IPPool은 광고하지 않도록 설정한다 (`disableBGPExport: true` 또는 별도 BGPConfiguration). 두 시스템이 동일 IP를 동시에 광고하면 라우팅 혼란이 발생한다.

### 7.5 Egress Gateway 노드 라벨

```bash
kubectl label node <gw-node-1> ftp-egress-gateway=true
kubectl label node <gw-node-2> ftp-egress-gateway=true
```

active/standby로 동작하므로 두 노드 중 한 곳이 다운되면 BGP가 자동 페일오버한다.

## 8. 모니터링과 운영

### 8.1 헬스체크

```yaml
livenessProbe:
  tcpSocket: { port: 21 }
  initialDelaySeconds: 10
  periodSeconds: 30
  failureThreshold: 3
readinessProbe:
  tcpSocket: { port: 21 }
  initialDelaySeconds: 5
  periodSeconds: 10
```

### 8.2 로그

- vsftpd xferlog → stdout → 클러스터 로그 수집기
- 추적할 핵심 신호: 인증 실패율, 동시 연결 수, PASV 포트 사용률, 데이터 전송 throughput

### 8.3 알람 (운영 안정화 후 도입)

- Pod 재시작 → 즉시 알림
- 인증 실패 급증 → 보안 이벤트
- PASV 포트 사용률 80% 초과 → capacity 알림
- Egress Gateway 페일오버 → 운영 주의

### 8.4 메트릭 exporter

vsftpd가 자체 메트릭을 노출하지 않으므로 운영 안정화 후 별도 sidecar exporter (예: mtail로 로그 파싱) 도입을 검토한다. 초기에는 로그 기반으로만 운영한다.

### 8.5 백업

- 데이터: NAS 측 스냅샷에 위임. RPO/RTO는 NAS 운영팀과 합의한다.
- 사용자 DB: Secret이 source of truth. etcd 백업으로 보호된다. 평문 보관 금지.
- 매니페스트: GitOps 저장소(Helm 또는 Kustomize)로 관리한다.

### 8.6 운영 SOP

- 사용자 추가/제거: Secret 편집 → 60초 대기 → FTP 클라이언트로 검증
- 사용자 디렉토리 청소: 분기별 미사용 디렉토리 점검
- PASV 포트 모니터링: 사용률 80% 도달 시 범위 확장 작업 (Service/ConfigMap 동기 변경)
- LB IP 변경 절차: 변경 윈도우 공지 → ConfigMap 갱신 → Pod 재시작 → 검증
- 보안 패치: 분기별 vsftpd 이미지 재빌드

## 9. 테스트 전략

### 9.1 테스트 환경

- **로컬**: docker-compose로 vsftpd 컨테이너 + Docker volume. 이미지 빌드 단계 검증.
- **통합**: kubectl로 접속 가능한 클러스터에 매니페스트 배포. 운영과 동일한 Calico/EgressGateway 구성 사용.
- **부하**: 별도 부하 발생 Pod에서 동시 다중 클라이언트 시뮬레이션.

### 9.2 검증 항목

| 영역 | 항목 | 도구 |
|---|---|---|
| 이미지 빌드 | vsftpd 정상 기동, 최소 capabilities로 :21 바인드 | docker run |
| 인증 | 로그인 성공/실패, 잘못된 패스워드 거부, 미존재 사용자 거부 | lftp, curl |
| chroot 격리 | 사용자 A가 사용자 B 디렉토리 접근 불가, `cd ../`로 escape 불가 | 수동 케이스 |
| PASV 전송 | 100MB/1GB/10GB 송수신, 동시 100 세션, 포트 풀 고갈 동작 | pyftpdlib client, lftp mirror |
| ACTIVE 전송 | EgressIP 적용 후 source IP 검증, ACTIVE 데이터 연결 성공 | tcpdump on egress gateway |
| 무중단 사용자 추가 | Secret 편집 → ~60초 후 신규 사용자 로그인, 기존 세션 영향 없음 | 백그라운드 long transfer + 시간 측정 |
| 장애 | Pod kill, 노드 drain, Egress Gateway 페일오버 | kubectl |
| 부하 | 500 동시 control + 100 동시 data transfer | ftpbench |

### 9.3 수용 기준

- 500 동시 control connection 시 메모리 < 4GB, CPU < 2 cores
- 1GB 파일 PASV 전송이 NAS 처리량의 80% 이상
- Pod 재시작 시 다운타임 < 30초
- Secret 변경 후 신규 사용자 로그인까지 < 90초
- chroot escape 시도 100% 차단

## 10. 단계적 구축 로드맵

| Phase | 기간 | 산출물 | 완료 기준 |
|---|---|---|---|
| 1. MVP | 1주 | Dockerfile, vsftpd.conf, PAM 설정, docker-compose | 로컬에서 PASV/ACTIVE 모두 동작, chroot 격리 동작 |
| 2. k8s 배포 | 1주 | Deployment, PVC, ConfigMap, Secret, Service 매니페스트 | 사내 LB IP로 외부 클라이언트 PASV 송수신 성공 |
| 3. 무중단 사용자 관리 | 3-5일 | user-syncer 사이드카, projected Secret 와이어링 | long-running transfer 중 사용자 추가, 기존 세션 영향 없음 |
| 4. Calico EgressGateway | 3-5일 | Egress Gateway Deployment, IPPool, EgressGatewayPolicy | ACTIVE 클라이언트가 LB IP source 데이터 연결 수신 확인. 시작 전 Calico Enterprise 라이선스 확인이 선결 조건 |
| 5. 운영 안정화 | 1-2주 | 부하 테스트, 장애 시나리오, 로그 파이프라인, 운영 SOP | 부하 수용 기준 달성, 모든 장애 시나리오 자동 복구, 운영팀 인수인계 |
| 6. 운영 이관 | 지속 | 메트릭 exporter (필요시), 패치 주기, 백업 검증 | — |

총 예상 기간 5-7주 (단일 엔지니어 기준, 사내 인프라 협조 포함).

## 11. 외부 의존성

- 사내 LB IP `10.0.0.42` 할당 (네트워크팀)
- NAS StorageClass 사용 가능 확인 (스토리지팀)
- **Calico Enterprise 라이선스 보유 여부 확인** (k8s 운영팀) — Egress Gateway는 Enterprise 기능. 미보유 시 Phase 4 재설계 필요.
- Calico EgressGateway 노드 2개 라벨링 (k8s 운영팀)
- 사외망 차단 정책 확인 (보안팀)

## 12. 의도적으로 포함하지 않은 것

- FTPS / SFTP 지원 — 도입 계획 없음. ConfigMap에 TLS 옵션 자리도 두지 않는다.
- NetworkPolicy 화이트리스트 — 사내망 신뢰 전제, 사외 차단은 인프라가 담당.
- 다중 Pod 수평 확장 — 단일 Pod 수직 스케일로 500+ 충분히 수용. 진짜 필요해지면 별도 설계.
- MinIO 또는 S3 백엔드 — FTP가 유일한 데이터 소비자.
- LDAP/AD 연동 — 가상 사용자로 충분. 외부 IdP 연동은 향후 요구 발생 시.
- 세션 종료 시간 제한, 대역폭 제한 — 운영 데이터 누적 후 필요 시 도입.
- 메트릭 exporter — 초기에는 로그 기반. 운영 안정화 후 검토.
