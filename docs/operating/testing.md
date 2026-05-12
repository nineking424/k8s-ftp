# 테스트와 검증

이미지 / 매니페스트 / vsftpd.conf 변경 후 또는 배포 후 동작 보증 목적의 스크립트 모음. 각 테스트는 단일 책임 — 한 가지 결함을 잡는다.

## 테스트 카탈로그

| 스크립트 | 검증 대상 | 실행 환경 | 통과 기준 |
|---|---|---|---|
| `tests/local-smoke.sh` | docker run 단일 컨테이너 + lftp 업로드/다운로드 1 회 | 로컬 docker | 업로드 파일 존재 + 다운로드 내용 일치 |
| `tests/multi-user.sh` | 10 명 동시 업로드 + 사용자별 chroot 격리 | 로컬 docker | 각 사용자 디렉토리에 자기 파일만 |
| `tests/chroot-escape.sh` | alice 가 bob 의 디렉토리 / 파일 접근 시도 → 실패해야 함 | 로컬 docker | 모든 접근 시도 실패 + bob 데이터 보호 |
| `tests/zero-downtime-useradd.sh` | alice 대용량 업로드 중 charlie 추가 → Pod 재기동 없이 charlie 로그인 가능 | k8s 클러스터 | alice 전송 완료 + charlie 로그인 OK + Pod 미재시작 |
| `tests/load-test.yaml` | 500 동시 control 세션 부하 (50 loadgen Pod × 10 세션) | k8s 클러스터 | 부하 동안 `max_clients` 초과 없음 + Pod 안정 |

## 사전 조건

| 환경 | 도구 | 비고 |
|---|---|---|
| 로컬 | `docker` (또는 `podman`), `lftp` | macOS lftp 4.9.3 에서 `EHOSTUNREACH` 알려진 결함 — 외부 PASV 검증은 `curl --ftp-pasv` 우회 |
| k8s | `kubectl` (정상 `KUBECONFIG`), 배포된 vsftpd Pod | `zero-downtime-useradd.sh` 는 LB IP + alice 자격증명 필요 |

## 실행 절차

### local-smoke.sh

```bash
./tests/local-smoke.sh
```

Expected: 마지막 줄에 `OK`. 컨테이너 이름 `k8s-ftp-smoke` 으로 임시 run / cleanup.

### multi-user.sh

```bash
./tests/multi-user.sh
```

Expected: 10 사용자 각각 자기 디렉토리 + 자기 파일 1 개만 — 격리 검증.

### chroot-escape.sh

```bash
./tests/chroot-escape.sh
```

Expected: alice 가 bob 디렉토리 / 파일에 도달 못함 (`550 Failed to ...` 등). 실패 = chroot 깨진 것이므로 즉시 [troubleshooting.md](troubleshooting.md) 진입.

### zero-downtime-useradd.sh

```bash
./tests/zero-downtime-useradd.sh <LB_IP> <alice_pw>
```

Expected: alice 200 MB 업로드 진행 중 charlie 가 ~18 초 내 로그인. Pod `restartCount` 변화 없음.

> 비밀번호가 셸 history 에 남는다. 검증 후 `history -d <line>` 또는 셸 종료.

### load-test.yaml

```bash
kubectl apply -f tests/load-test.yaml
kubectl -n ftp-loadgen wait --for=condition=complete --timeout=10m job/ftp-loadgen
```

부하 종료 후 정리:

```bash
kubectl delete -f tests/load-test.yaml
```

상세 부하 모델은 capacity.md — 부하 테스트 결과.

## 배포 검증

변경 푸시 후 매번 실행:

| 항목 | 명령 | 통과 기준 |
|---|---|---|
| 컨테이너 살아 있음 | `kubectl get pod -n ftp -l app=vsftpd` | `Running` + `2/2 Ready` |
| 로그 정상 | `kubectl logs -n ftp deploy/vsftpd -c vsftpd --tail=20` | `CONNECT` / `OK LOGIN` 라인만 (`ERROR` 없음) |
| user-syncer 동기화 완료 | `kubectl logs -n ftp deploy/vsftpd -c user-syncer --tail=5` | `INFO: users.db 동기화 완료` |
| FTP 로그인 | `curl --ftp-pasv -u <user>:<pw> ftp://<LB_IP>/` | 디렉토리 리스트 출력 |
