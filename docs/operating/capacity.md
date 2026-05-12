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
