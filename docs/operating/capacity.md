# 용량과 한계

vsftpd 단일 Pod 의 동시 접속 / 처리량 / 자원 한계를 한 페이지에. 변경 시 영향이 큰 상수와 부하 테스트 관측치를 함께 둔다.

## 용량 상수

| 상수 | 값 | 위치 | 변경 영향 |
|---|---|---|---|
| `max_clients` | 600 | `docker/conf/vsftpd.conf` | 전체 동시 세션 상한. 변경 시 이미지 재빌드 |
| `max_per_ip` | 10 | `docker/conf/vsftpd.conf` | 단일 source IP 당 동시 세션 상한. NAT 뒤 사용자 분포 고려 |
| PASV 포트 범위 | 30000–30099 (100) | `docker/conf/vsftpd.conf` + `k8s/05-service.yaml` | 동시 transfer 채널 상한 |
| Pod resources | `k8s/04-deployment.yaml` 의 `resources.requests/limits` | `k8s/04-deployment.yaml` | scheduling / throttling 영향 |
| NAS PVC accessMode | RWX (NAS StorageClass) | `k8s/01-pvc.yaml` | Pod 재배치 시 다른 worker 마운트 가능 |

## 동시 접속 모델

control 세션은 TCP 21 만 점유. PASV 데이터 채널만 30000–30099 풀에서 포트 1 개 점유. transfer 가 끝나면 즉시 반납.

활성 transfer ≤ PASV 포트 풀 (100). 동시 transfer 가 100 을 넘으면 `421 Sorry, no free address` 발생.

| 신호 | 의미 |
|---|---|
| 전체 세션 N | control 세션 카운트 (자식 PID 카운트로 근사). 상한 600 |
| 활성 transfer M | N 중 PASV 데이터 채널 사용 중. 상한 100 |
| `421 Too many connections from this IP` | 동일 source IP 가 10 세션 초과 시도 |
| `421 Sorry, no free address` | PASV 포트 풀 소진 |

대부분 워크로드에서 `M << N` (사용자가 명령 입력 사이의 idle 시간). 부하 테스트에서 500 세션이 LIST 만 반복할 때 `M ≈ 100` 도달 가능 확인.

## 부하 테스트 결과

`tests/load-test.yaml` 의 500 세션 부하 (50 loadgen Pod × 10 세션 / 5 초 간격 LIST):

| 신호 | 관측값 | 임계 |
|---|---|---|
| 활성 세션 (자식 PID 카운트) | ~502 (init / tail-F / vsftpd master 4 개 포함) | 600 |
| Pod restart | 0 | 변화 시 alert |
| `max_per_ip` reject | 0 (50 IP × 10 = 500 이므로 미발생) | 정상 |
| PASV 포트 사용률 | ~100/100 (LIST 빈도에 따라 가변) | 100 |
| 로그 라인 손실 | 0 | named pipe + tail -F 안정 |

부하 모델 / 실행 방법은 [operating/testing.md — load-test.yaml](testing.md#load-testyaml).

## 사용자 N 명 받으려면

| 시나리오 | 권장 조정 |
|---|---|
| 동시 사용자 ≤ 500 / 활성 transfer ≤ 80 | 기본값 유지 |
| 동시 활성 transfer > 80 지속 | [maintenance.md — PASV 포트 범위 확장](maintenance.md#pasv-포트-범위-확장) |
| `max_per_ip=10` 위양성 (NAT 뒤 사용자 많음) | `max_per_ip` 상향 — DoS 보호 약화 트레이드오프 |
| 동시 세션 > 600 | 멀티 Pod 설계 재검토 (1.0 범위 밖) |
| 처리량 (MB/s) 한계 도달 | NAS 운영팀과 PVC throughput SLA 합의 |

## 메모리 / CPU 풋프린트 (관측값)

500 세션 부하 시 (참고치):

- vsftpd 컨테이너: CPU ≈ 0.5 core, RSS ≈ 200 MB
- user-syncer 컨테이너: idle 시 CPU ≈ 0.001 core, RSS ≈ 10 MB

권장 `resources.requests` / `limits` 는 `k8s/04-deployment.yaml` 의 commit history 참고. 큰 부하 변동이 예상되면 부하 테스트 재실행 후 조정.

## 알려진 한계

- **단일 Pod.** 1.0 의 의도적 단순화. 노드 장애 시 재배치 — 수십 초 다운타임.
- **`ss` 직접 관측 불가.** 컨테이너 PID namespace 제약. 자식 PID 카운트로 대체 ([operating/monitoring.md — 동시 세션과 PASV 사용률](monitoring.md#동시-세션과-pasv-사용률)).
- **부하 테스트 환경 의존.** kind / minikube 재현 불가. NAS RWX + MetalLB 필요.
- **활성 transfer 직접 카운트 어려움.** PASV 포트 사용률은 `ss` 가 0 만 반환해 컨테이너 내부 정확 측정 불가. xferlog 의 시간창 기반 추정으로 대체.
- **메모리 / CPU 수치는 1 회 관측값.** 워크로드 / 데이터 크기에 따라 변동. SLO 가 아닌 참고치.
