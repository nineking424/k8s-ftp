# 모니터링

xferlog stdout, 컨테이너 자식 PID 수, Pod restartCount — 이 세 가지가 현재 관측 가능한 신호다. 메트릭 exporter 는 아직 없으므로 본 페이지는 로그/명령어 기반 진단을 정리한다.

## Probe — /livez · /readyz

vsftpd 자체는 HTTP healthz 가 없고, Kubernetes probe 는 TCP 21 으로만 헬스를 잡는다.

| Probe | 책임 | 매핑 | 실패가 의미하는 것 |
|---|---|---|---|
| `tcpSocket :21` | TCP 21 listen 여부 | `livenessProbe`, `readinessProbe` | vsftpd master 다운 — kubelet 이 재시작 트리거 |

요점: probe 는 listen 여부만 묻는다. 로그인 / PASV 데이터 채널 성공 여부는 잡히지 않으므로, 신뢰성 SLO 는 외부 FTP synthetic 체크로 보완해야 한다.

## 로그

vsftpd 가 stdout 으로 흘리는 라인은 모두 `xferlog_std_format=NO` 의 vsftpd verbose 포맷이다. RO root 제약상 vsftpd 가 named pipe (`/var/run/vsftpd/vsftpd.log`) 에 쓰고 entrypoint 의 `tail -F` 가 stdout 으로 흘린다.

| 라인 키워드 | 컴포넌트 | 의미 | 후속 |
|---|---|---|---|
| `CONNECT: Client "<ip>"` | vsftpd | 새 control 세션 시작 | 정상 |
| `OK LOGIN: Client "<ip>"` | vsftpd | 인증 성공 | 정상 |
| `FAIL LOGIN: Client "<ip>"` | vsftpd | 인증 실패 — 패스워드 오타 또는 brute force | 의심 |
| `OK UPLOAD: Client "<ip>", "<path>", <N> bytes, <rate>` | vsftpd | 업로드 성공 (xferlog) | 정상 |
| `OK DOWNLOAD: Client "<ip>", "<path>", <N> bytes, <rate>` | vsftpd | 다운로드 성공 (xferlog) | 정상 |
| `421 Too many connections from this IP` | vsftpd | `max_per_ip=10` 도달 | [트러블슈팅 — max_per_ip](troubleshooting.md#max_per_ip-초과로-신규-세션-거부) |
| `INFO: users.db 동기화 완료` | user-syncer | Secret 변경 반영 성공 | 정상 |
| `ERROR: 잘못된 사용자명` | user-syncer | `users.txt` 사용자명 정규식 위반 — 기존 DB 유지 | [트러블슈팅 — 사용자 추가](troubleshooting.md#무중단-사용자-추가가-반영되지-않는다) |
| `ERROR: ... 줄 수가 짝수가 아님` | user-syncer | `users.txt` 줄 수 불일치 — 기존 DB 유지 | 동상 |

**상태 추적은 로그가 아니라 Secret 과 NAS PVC.** xferlog 는 후행 관찰용이고, 사용자 목록 source of truth 는 `kubectl get secret vsftpd-users -o jsonpath='{.data.users\.txt}' | base64 -d`.

## 동시 세션과 PASV 사용률

`ss` 는 컨테이너 PID/namespace 제약으로 0 만 반환한다 (Task 27 부하 테스트에서 확인). 대체 신호는 vsftpd 자식 PID 카운트다 — vsftpd 는 세션당 한 프로세스를 띄운다.

```bash
kubectl exec -n ftp deploy/vsftpd -c vsftpd -- sh -c 'ls /proc | grep -c "^[0-9]"'
```

출력에서 init(`tini`) + entrypoint + master + tail-F 의 4개를 빼면 활성 세션 수 근사치. 500세션 부하 시 ~502 까지 관측됨. **`max_clients=600` 의 80% 인 480을 임계로 사용한다.**

## 메트릭 (exporter 미도입)

`/metrics` endpoint 와 Prometheus exporter 는 1.0 운영 안정화 후 도입으로 결정. 현재는 명령어로 등가 신호를 직접 산출한다. 본 표는 exporter 도입 시 메트릭 이름이 결정되므로 이름을 `<placeholder>` 로 둔다 — needs-verification.

### 메트릭 카탈로그 (placeholder)

표의 `< >` 로 둘러싸인 식별자는 *미정 자리* — exporter 도입이나 사내 자료 확정 후 채운다.

| 메트릭 | 모드 | 현재 산출 | 라벨 (예상 카디널리티) | 이름 확정 조건 |
|---|---|---|---|---|
| `<vsftpd_sessions_active>` | (미도입) | 자식 PID 카운트 (위 절) | exporter 도입 시 `user` (10–수십) | vsftpd exporter 도입 결정 (1.0 운영 안정화 후) |
| `<vsftpd_login_failed_total>` | (미도입) | `kubectl logs ... \| grep "FAIL LOGIN" \| wc -l` | exporter 도입 시 `source_ip` (카디널리티 폭주 위험 — 필터 필요) | 동상 |
| `<vsftpd_max_per_ip_rejects_total>` | (미도입) | `kubectl logs ... \| grep "421 Too many" \| wc -l` | exporter 도입 시 `source_ip` | 동상 |
| `<pod_restart_count>` | scrape (kube-state-metrics) | `kubectl get pod -n ftp -l app=vsftpd -o jsonpath='{.items[0].status.containerStatuses[*].restartCount}'` | `container` (2: vsftpd, user-syncer) | 결정됨 — kube-state-metrics 기본 메트릭 |

### 권장 알람 (임계값 placeholder)

| 신호 | 임계값 | 의미 | 임계 결정 조건 |
|---|---|---|---|
| 자식 PID 카운트 (활성 세션) | ≥ 480 | `max_clients=600` 의 80% — 수용량 검토 | 결정됨 — `vsftpd.conf` 의 `max_clients` 변경 시 재계산 |
| `FAIL LOGIN` 5분 내 N회 같은 source IP | `<N from security policy>` | brute force 의심 → IP 차단 절차 | 사내 보안 정책 확정 후 채움. **임시 운영: 분당 ≥ 5 시 수동 검토** |
| `421 Too many connections` 분당 발생 | `<rate from SLO>` | `max_per_ip` 임계 도달 — 정책 재검토 | 가용성 SLO 확정 후 채움. **임시 운영: 분당 ≥ 3 시 수동 검토** |
| Pod `restartCount` 증가 | 모니터링 인터벌 내 1회 이상 | vsftpd master crash → [트러블슈팅 — Pod CrashLoop](troubleshooting.md#pod-가-crashloop) | 결정됨 — kube-state-metrics 의 변화량 감지 |

`<N from security policy>` 와 `<rate from SLO>` 의 임시 운영 임계 (분당 ≥ 5 / 분당 ≥ 3) 는 *근거 없는 가이드라인* 으로, 실제 정책 확정 시 즉시 교체한다. 그동안 on-call 이 "지금 뭘 해야 하나" 의 답을 받지 못하는 공백을 메우기 위함이지 SLO 가 아니다.

## 알려진 한계

- **PASV 포트 사용률 직접 관측 불가.** 컨테이너 내부 `ss` 가 0 만 반환 — 자식 PID 카운트로 대체.
- **`FAIL LOGIN` / `max_per_ip` 가 source IP 단위.** NAT 뒤 사용자가 같은 외부 IP 로 보이면 위양성이 늘어난다.
- **로그 회전 없음.** named pipe 이므로 의미 없다. 보존은 클러스터 로그 수집기 (Loki/ELK) 정책에 위임.
