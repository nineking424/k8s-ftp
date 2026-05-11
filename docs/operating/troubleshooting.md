# 트러블슈팅

증상 → 원인 → 진단 → 조치 → 확인 매트릭스. 깊은 절차는 [README#운영-sop](https://github.com/nineking424/k8s-ftp#운영-sop) 로 점프한다.

## PASV 가 닿지 않는다 (업로드/다운로드 시작 안됨)

**원인.** Control 채널은 잡혔지만 클라이언트가 `PASV` 응답에 받은 IP:포트로 직접 연결을 못한다. `pasv_address` 가 잘못된 LB IP 거나, Service 의 30000–30099 포트 매핑이 누락된 경우.

**진단.**

```bash
curl -v --disable-epsv --ftp-pasv --user '<user>:<pw>' "ftp://<LB IP>/" 2>&1 | grep "227 Entering Passive Mode"
```

응답 튜플의 앞 네 수가 LB IP 와 일치하고 마지막 두 수 `(p1, p2)` 로 계산한 포트 `p1*256+p2` 가 `[30000, 30099]` 안이면 vsftpd 측은 정상. 데이터 채널이 이후에 안 열리면 LB/Service 포트 매핑 또는 클라이언트 측 방화벽 문제다.

**조치.** ConfigMap `vsftpd-config` 의 `PASV_ADDRESS` 와 Service `metallb.io/loadBalancerIPs` annotation 이 일치하는지 확인. 일치하지 않으면 두 값을 정렬 후 `kubectl rollout restart deployment/vsftpd -n ftp`. 일치한다면 클라이언트 → LB 사이의 30000–30099 방화벽을 확인.

**확인.** `curl --disable-epsv --ftp-pasv -T /tmp/file ftp://<LB IP>/` 가 데이터 채널까지 완료해 `226 Transfer complete` 반환.

## max_per_ip 초과로 신규 세션 거부

**원인.** `vsftpd.conf` 의 `max_per_ip=10` 한계. 같은 source IP 의 11번째 동시 세션을 vsftpd 가 `421 Too many connections from this IP` 로 끊는다. NAT 뒤 다중 클라이언트가 같은 외부 IP 로 보이면 빠르게 도달한다.

**진단.**

```bash
kubectl logs -n ftp -l app=vsftpd -c vsftpd --tail=200 | grep "421 Too many"
```

분당 발생 빈도와 source IP 의 다양성으로 NAT 인지 단일 호스트인지 판단한다.

**조치.** 일회성 폭주면 클라이언트 측이 세션을 끄고 재시도. 만성이면 `docker/conf/vsftpd.conf` 의 `max_per_ip` 를 늘리고 이미지 재빌드 → 롤아웃. 무리한 상향(예: 50+) 은 `max_clients=600` 과 자원 한계 같이 검토.

**확인.** `kubectl logs ... | grep "421 Too many"` 가 새로 안 찍힘. 클라이언트 재시도 성공.

## 무중단 사용자 추가가 반영되지 않는다

**원인.** Secret 갱신은 됐지만 user-syncer 가 `users.txt` 검증 실패로 기존 `users.db` 를 유지하고 있다. 가장 흔한 두 케이스: (a) 줄 수가 짝수가 아님, (b) 사용자명에 `[a-zA-Z0-9_-]` 외의 문자(공백, 한글, `@`, `.` 등) 가 섞임.

**진단.**

```bash
kubectl logs -n ftp -l app=vsftpd -c user-syncer --tail=20 | grep -E "ERROR|INFO: users.db"
```

`INFO: users.db 동기화 완료` 가 Secret apply 이후 timestamp 면 동기화 성공 — 다른 원인. `ERROR: 잘못된 사용자명` 또는 `ERROR: ... 줄 수가 짝수가 아님` 이 보이면 검증 실패다.

**조치.** Secret 의 `users.txt` 를 다시 받아서 형식 확인 — 사용자명 라인과 패스워드 라인이 짝을 이루는지, 사용자명에 허용 문자만 들어 있는지. 수정 후 `kubectl apply -f secret.yaml`. 깊은 절차는 [README — 사용자 추가](https://github.com/nineking424/k8s-ftp#사용자-추가).

**확인.** user-syncer 로그에 `INFO: users.db 동기화 완료` 가 새 timestamp 로 찍히고, `curl --user '<newuser>:<pw>' ftp://<LB IP>/` 가 `230 Login successful`.

## Pod 가 CrashLoop

**원인.** vsftpd 컨테이너가 시작 후 즉시 종료. 가장 흔한 두 원인: (a) Secret `users.txt` 가 비어 있거나 형식이 깨져 `db_load` 가 fail, (b) PVC `ftp-data` 가 마운트 안 됐거나 `ftpvirt` 가 write 권한 없음.

**진단.**

```bash
kubectl logs -n ftp -l app=vsftpd -c vsftpd --previous --tail=50
```

마지막 라인이 `db_load: ...` 면 (a), `mkdir: cannot create directory '/srv/ftp/...'` 면 (b).

**조치.** (a): Secret 의 `users.txt` 가 비어 있지 않은지, base64 디코드 후 짝수 라인인지 확인 후 `kubectl rollout restart deployment/vsftpd`. (b): `kubectl describe pvc ftp-data -n ftp` 로 `Bound` 확인 + StorageClass NAS 응답 확인.

**확인.** `kubectl get pods -n ftp` 가 `2/2 Running`, `restartCount 0`. `curl --user 'alice:<pw>' ftp://<LB IP>/` 가 `230 OK`.

## 클라이언트(macOS lftp)에서 EHOSTUNREACH

**원인.** lftp 4.9.x macOS Homebrew arm64 의 알려진 결함. LB IP `192.168.3.42:21` 로의 TCP 연결만 `connect(control_sock): No route to host` 로 실패한다. 같은 셸에서 `nc -zv`, `curl ftp://...`, Python `socket.connect()` 는 모두 성공.

**진단.**

```bash
curl -v --disable-epsv --ftp-pasv --user '<user>:<pw>' "ftp://<LB IP>/" 2>&1 | grep -E "Connected|227 Entering"
```

curl 이 `Connected` + `227 Entering Passive Mode` 를 모두 출력하면 서버 측은 정상 — lftp 측 결함이다.

**조치.** lftp 대신 curl, FileZilla, WinSCP 사용. 배치 스크립트는 `curl --ftp-pasv --disable-epsv -T <file> ftp://<LB IP>/` 패턴으로 전환.

**확인.** curl 업로드 → 다운로드 → 내용 일치 (`diff`).

## 알려진 한계

- **PASV 포트 사용률 직접 관측 불가** — 컨테이너 내부 `ss` 가 0 만 돌려준다. 대체 신호는 [모니터링 — 동시 세션](monitoring.md#동시-세션-pasv-사용률) 의 자식 PID 카운트.
- **`421 Too many connections` 는 source IP 기준이라 NAT 뒤 사용자는 같은 IP 로 한계 도달이 빠르다.** 사용자별 격리가 필요하면 NAT 분리 또는 `max_per_ip` 조정 후 부하 검증.
- **이미지 롤백은 본 페이지의 조치에 포함하지 않는다** — 위 케이스 모두 root cause 가 명확하므로 우선 root cause 조치, 안 잡히면 `kubectl rollout restart` 까지. 이미지 롤백은 별도 변경관리 절차.
