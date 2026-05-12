# FAQ

운영자 / 컨트리뷰터가 자주 묻는 디자인 결정 + 향후 계획. 절차는 wiki 의 해당 페이지로 폴스루.

## 왜 plain FTP 인가 (SFTP / FTPS 가 아니라)

사내 LAN 전용 + 기존 클라이언트 다수가 plain FTP 만 지원이라는 운영 제약. TLS / SSH 도입 시 인증서 / 키 관리 + PASV 데이터 채널 암호화 등 추가 비용이 1.0 범위 밖.

향후 TLS 도입은 결정 보류 — 사내 보안 정책 변경 시 재검토.

## 왜 MinIO native FTP 안 썼나

MinIO 의 native FTP/SFTP 가 옵션에 있지만 1.0 요구사항은 **vsftpd 가상 사용자 + chroot per user + NAS PVC** 의 단순 모델. MinIO 는 S3 API 가 정본이라 FTP 는 부수적 인터페이스 — 가상 사용자 관리 / chroot 정책 / 파일 권한 모델이 vsftpd 만큼 직접적이지 않다.

## 왜 단일 Pod 인가

`max_clients=600` 으로 검증된 한 Pod 의 처리량이 사내 예상 부하를 충분히 흡수. 멀티 Pod 는 PASV 포트 풀 분할 / 세션 친화성 / NAS 동시 쓰기 정책 등 추가 설계 비용 — 1.0 범위 밖.

500 세션 부하 테스트에서 `ss` 미관측 결함 외 안정. 자세한 한계는 [operating/capacity.md](operating/capacity.md).

## TLS / FTPS 는 언제

미정. 도입하려면:

- vsftpd `ssl_enable=YES` + 인증서 마운트 정책.
- PASV 데이터 채널 암호화 — 포트 범위 충분한지 재검토.
- 사내 인증서 회전 절차 합의.

위 3 가지가 합의되면 작업 가능. 그동안 사내 LAN + IP 화이트리스트로 보호.

## 사용자 추가가 즉시 반영되나

`users.txt` 변경 후 약 18 초 (관측치). user-syncer 가 inotify 감지 → `db_load` → `mv` atomic rename. vsftpd 는 매 로그인마다 DB 를 다시 열기 때문에 재기동 없음.

상세: [operating/user-management.md](operating/user-management.md).

## 동시 접속 한계는 얼마나

설계값: `max_clients=600`, `max_per_ip=10`. 검증값: 500 세션 부하 테스트 통과. 자세히: [operating/capacity.md](operating/capacity.md).

`max_per_ip=10` 은 단일 IP 의 DoS 보호. NAT 뒤 사용자가 많으면 위양성 발생 가능.

## PASV 포트 범위 100 으로 충분한가

활성 transfer 세션 ≤ 100 개라는 가정. control 세션은 PASV 채널을 쓰지 않는 동안 포트를 차지하지 않는다. 100 개 동시 transfer 가 부족하다는 신호 (`421 ...` 가 PASV 부족으로 발생) 가 보이면 [maintenance.md — PASV 포트 범위 확장](operating/maintenance.md#pasv-포트-범위-확장).

## 메트릭 exporter 는 언제

1.0 운영 안정화 후 도입 결정. 현재는 명령어 + xferlog 로 등가 신호 산출. [operating/monitoring.md](operating/monitoring.md) 의 placeholder 컨벤션 참고.

## 백업 정책은 어떻게 정해지나

세 종류 상태 (NAS PVC / Secret / 매니페스트) 각각 정책 분리. 데이터 백업은 사내 NAS 운영팀의 스냅샷 정책이 정본 — 본 프로젝트는 *기술적 절차* 만 제공. [operating/maintenance.md — 백업과 복구](operating/maintenance.md#백업과-복구).
