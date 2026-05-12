# 운영 절차 (Maintenance)

사용자 관리 외 정기·비정기 운영 절차. 각 H2 는 **사전 조건** → **단계** → **검증** → **알려진 한계** 4 구간.

사용자 추가·제거는 [user-management.md](user-management.md) — 빈도가 높아 별도 페이지.

## PASV 포트 범위 확장

`421 Too many connections` 또는 동시 세션 한계 도달이 일상화되면 PASV 포트 범위를 늘려 수용량을 확장한다. 기본은 30000–30099 (100 포트).

**사전 조건.**

- 현재 동시 세션 임계 도달이 일시적 폭주가 아닌 추세 — [monitoring.md — 자식 PID 카운트](monitoring.md#동시-세션과-pasv-사용률) 로 5 분 이상 480 + 지속 확인.
- 신규 NodePort 가 클러스터 다른 Service 와 충돌 없음 — `kubectl get svc -A | grep -E '3009[0-9]|301[0-9][0-9]'` 로 확인.

**단계.**

100 → 200 포트로 확장 (30000–30199) 예시.

1. `docker/conf/vsftpd.conf` 의 `pasv_max_port` 값을 `30199` 로 변경.

```bash
sed -i 's/^pasv_max_port=.*/pasv_max_port=30199/' docker/conf/vsftpd.conf
```

> macOS BSD `sed` 은 `-i ''` 가 필요. 이 페이지의 모든 `sed -i` 명령에 동일.

2. 이미지 재빌드 + 푸시 — 태그는 날짜 기반 (`vYYYYMMDD-1`).

```bash
docker build -t <registry>/vsftpd:v$(date +%Y%m%d)-1 docker/
docker push <registry>/vsftpd:v$(date +%Y%m%d)-1
```

3. `k8s/05-service.yaml` 의 `spec.ports` 에 30100–30199 항목 100 개를 enumerate 로 추가. k8s Service 가 포트 range 표기를 지원하지 않으므로 한 줄씩 명시.

```yaml
# k8s/05-service.yaml 의 spec.ports 끝에 다음 패턴 100개 추가
- { name: pasv-30100, port: 30100, targetPort: 30100, protocol: TCP }
- { name: pasv-30101, port: 30101, targetPort: 30101, protocol: TCP }
# ...
- { name: pasv-30199, port: 30199, targetPort: 30199, protocol: TCP }
```

생성은 셸 한 줄로:

```bash
for p in $(seq 30100 30199); do
  echo "  - { name: pasv-$p, port: $p, targetPort: $p, protocol: TCP }"
done
```

4. Deployment 의 이미지 태그를 새 태그로 갱신 후 두 manifest 같이 apply.

```bash
sed -i "s|image: <registry>/vsftpd:.*|image: <registry>/vsftpd:v$(date +%Y%m%d)-1|" k8s/04-deployment.yaml
kubectl apply -f k8s/04-deployment.yaml -f k8s/05-service.yaml
```

5. 롤아웃 완료 대기.

```bash
kubectl rollout status deployment/vsftpd -n ftp --timeout=120s
```

**검증.** 새 범위 안의 포트가 PASV 응답에 등장.

```bash
curl -v --disable-epsv --ftp-pasv --user '<user>:<pw>' "ftp://192.168.3.42/" 2>&1 | grep "227 Entering Passive Mode"
```

응답 튜플의 `(p1, p2)` 에서 계산한 포트 `p1*256+p2` 가 30000–30199 안 (특히 30100–30199 범위가 한 번이라도 관찰되면 확장 반영 완료).

**알려진 한계.**

- **Service 포트 enumerate** — k8s 가 포트 range 표기를 지원하지 않아 100 단위로 늘릴 때마다 manifest 가 길어진다. 200 포트 이상은 generate-only 헬퍼 스크립트 도입 검토.
- **롤아웃 중 짧은 무중단 끊김** — vsftpd Pod 가 재시작되는 ~10 초 동안 신규 세션 연결 실패 가능. 기존 세션은 RollingUpdate 의 maxUnavailable 설정에 따라 영향.

## LB IP 변경

MetalLB 풀의 외부 IP 가 변경되거나 새 LB 로 마이그레이션할 때. control 채널만 잡히고 PASV 데이터 채널이 끊기는 가장 흔한 원인이 PASV_ADDRESS 와 실제 LB IP 불일치이므로 두 값을 항상 동시에 변경.

**사전 조건.**

- 신규 IP 가 MetalLB AddressPool 안에 있고 다른 Service 가 점유 중이 아님.
- 클라이언트 측 방화벽 규칙이 신규 IP 의 21 + 30000-30099 (또는 확장 범위) 를 허용함을 사전 합의.

**단계.**

기존 `192.168.3.42` → 신규 `192.168.3.43` 예시.

1. `ConfigMap vsftpd-config` 의 `PASV_ADDRESS` 값을 신규 IP 로.

```bash
kubectl get configmap vsftpd-config -n ftp -o yaml > /tmp/cm.yaml
sed -i 's/PASV_ADDRESS: "192.168.3.42"/PASV_ADDRESS: "192.168.3.43"/' /tmp/cm.yaml
kubectl apply -f /tmp/cm.yaml && rm /tmp/cm.yaml
```

2. Service 의 `metallb.io/loadBalancerIPs` annotation 도 동일 IP 로.

```bash
kubectl annotate svc vsftpd -n ftp metallb.io/loadBalancerIPs=192.168.3.43 --overwrite
```

3. ConfigMap 변경은 vsftpd 가 재기동해야 반영되므로 롤아웃.

```bash
kubectl rollout restart deployment/vsftpd -n ftp
kubectl rollout status deployment/vsftpd -n ftp --timeout=120s
```

4. Service 의 EXTERNAL-IP 가 신규 IP 로 갱신됐는지 확인.

```bash
kubectl get svc vsftpd -n ftp -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

기대값: `192.168.3.43`.

5. 클라이언트 공지 — 사내 채널에 신규 IP 와 변경 시각 공지.

**검증.**

```bash
curl --disable-epsv --ftp-pasv --user '<user>:<pw>' "ftp://192.168.3.43/" 2>&1 | grep -E "Connected|227 Entering Passive Mode"
```

`Connected` + `227` 튜플의 앞 네 수가 `192,168,3,43` 이면 통과.

**알려진 한계.**

- **기존 클라이언트 측 DNS/hosts 캐시.** 도메인 기반이 아니라 IP 직접 사용이라면 클라이언트 캐시는 없지만, 사내 DNS 에 별칭이 있다면 TTL 만료 대기 필요.
- **변경 윈도우 동안 신규 세션 끊김.** 롤아웃 ~10 초 + Service EXTERNAL-IP 재할당 ~5 초 — 신규 세션 실패 윈도우 합쳐 15-30 초.

## 이미지 보안 패치

분기별 또는 CVE 공지 후 베이스 이미지 (Debian slim) 와 vsftpd 패키지 업데이트. 단순 `kubectl rollout restart` 가 아니라 이미지 재빌드가 선행.

**사전 조건.**

- 현재 운영 중 이미지 태그 확인 — `kubectl get deploy vsftpd -n ftp -o jsonpath='{.spec.template.spec.containers[*].image}'`.
- Container registry 푸시 권한.
- 롤아웃 전 신규 이미지로 로컬 smoke 테스트 (`docker run` + `curl --user test:test ftp://localhost/`) 권장.

**단계.**

1. `docker/Dockerfile` 의 베이스 이미지 정책 확인.

```bash
grep "^FROM " docker/Dockerfile
```

- 단순 태그 사용 (예: `debian:bookworm-slim`) — `--no-cache` 빌드만으로 apt 가 최신 패키지 인덱스를 받아 패치 흡수. Dockerfile 변경 불필요.
- 다이제스트 고정 사용 (`debian:bookworm-slim@sha256:...`) — `docker pull debian:bookworm-slim && docker inspect ... --format '{{index .RepoDigests 0}}'` 로 새 다이제스트를 얻어 `FROM` 라인 교체.

2. 이미지 재빌드 — 캐시 무시로 apt 패치를 확실히 흡수.

```bash
docker build --no-cache -t <registry>/vsftpd:v$(date +%Y%m%d)-1 docker/
```

3. 로컬 smoke 테스트 (선택).

```bash
docker run --rm -d --name vsftpd-smoke -p 2121:21 <registry>/vsftpd:v$(date +%Y%m%d)-1
sleep 5
curl -v ftp://localhost:2121/ 2>&1 | grep "220"
docker stop vsftpd-smoke
```

4. 푸시.

```bash
docker push <registry>/vsftpd:v$(date +%Y%m%d)-1
```

5. Deployment 의 두 컨테이너 (vsftpd + user-syncer) 이미지 태그 동시 갱신.

```bash
kubectl set image deployment/vsftpd -n ftp \
  vsftpd=<registry>/vsftpd:v$(date +%Y%m%d)-1 \
  user-syncer=<registry>/vsftpd:v$(date +%Y%m%d)-1
kubectl rollout status deployment/vsftpd -n ftp --timeout=120s
```

**검증.**

- Pod 가 새 태그로 떠 있음.

```bash
kubectl get pod -n ftp -l app=vsftpd -o jsonpath='{.items[*].spec.containers[*].image}'
```

- 로그인 + 업로드 round-trip.

```bash
echo test > /tmp/smoke && curl --user '<user>:<pw>' -T /tmp/smoke "ftp://192.168.3.42/"
curl --user '<user>:<pw>' "ftp://192.168.3.42/smoke" -o /tmp/smoke.dl && diff /tmp/smoke /tmp/smoke.dl
```

**알려진 한계.**

- **롤아웃 짧은 끊김.** 위 PASV 확장과 동일 ~10 초. RollingUpdate.maxUnavailable=1 + replicas=1 이라 사실상 전면 끊김 윈도우. 진정한 무중단이 필요하면 replicas=2 + leader-elect 메커니즘 도입 검토 (현재 1.0 범위 밖).
- **롤백 절차 별도** — 본 페이지에 포함하지 않는다. `kubectl rollout undo deployment/vsftpd -n ftp` 가 일반적이지만 user-syncer 의 sidecar 동작이 이전 버전과 호환되는지 변경 관리 절차에서 사전 검증.

## 백업과 복구

세 종류의 상태를 별도로 관리. 동일 메커니즘이 아니므로 각각 정책.

| 대상 | source of truth | 백업 정책 | 복구 |
|---|---|---|---|
| 사용자 데이터 (`/srv/ftp/`) | NAS PVC | NAS 측 스냅샷 — 사내 NAS 운영팀 RPO/RTO 합의 | NAS 스냅샷 복구 후 PVC 재마운트 |
| 사용자 자격증명 (`vsftpd-users` Secret) | etcd | etcd 백업으로 보호 + 평문 `users.txt` 는 별도 password manager (GitOps 평문 저장 금지) | etcd 복원 또는 password manager 에서 재구성 |
| 매니페스트 (`k8s/`, `docker/`) | 본 저장소 | Git 자체가 보관 — 외부 미러 1 개 권장 | `git clone` + `kubectl apply -k .` |

**사전 조건.** NAS 운영팀과 사전 합의된 RPO/RTO 가 있어야 의미 있다. 본 페이지는 *기술적 절차* 만 — 정책은 운영 합의 사항.

**단계 — 임시 데이터 백업 (NAS 스냅샷 외, 마이그레이션·검증용).**

```bash
kubectl exec -n ftp deploy/vsftpd -c vsftpd -- tar -czf - -C /srv/ftp . > /tmp/ftp-backup-$(date +%Y%m%d).tar.gz
```

`>` 리다이렉트는 로컬 셸에서 동작하므로 파일은 **명령을 실행한 머신의** `/tmp/` 에 생성된다. SSH 세션에서 실행하면 SSH 호스트에 저장되니 주의.

진행률 확인:

```bash
ls -lh /tmp/ftp-backup-*.tar.gz
```

**단계 — Secret 백업 (디버깅·이관용).**

```bash
kubectl get secret vsftpd-users -n ftp -o yaml > /tmp/secret-backup-$(date +%Y%m%d).yaml
chmod 600 /tmp/secret-backup-*.yaml
```

*평문 base64 가 들어 있으므로 보관 위치 통제 필수.* 작업 후 즉시 삭제 또는 password manager 에.

**검증.**

```bash
tar -tzf /tmp/ftp-backup-$(date +%Y%m%d).tar.gz | head -5
```

파일 목록이 비어 있지 않으면 백업 본문 정상.

**알려진 한계.**

- **NAS 스냅샷이 정본 백업.** 본 페이지의 `tar` 백업은 *마이그레이션·임시 검증용* 이지 정기 백업 정책의 대체가 아니다. 정기 백업은 NAS 운영팀 정책에 위임.
- **Secret 평문 노출.** `kubectl get secret -o yaml` 산출물엔 base64 만 들어가지만 `base64 -d` 한 줄로 평문이 되므로 보안 등급은 평문과 동일. 안전한 보관 채널 외 저장 금지.
- **PIT (point-in-time) 복원 불가.** NAS 스냅샷의 보존 간격이 RPO 의 하한. 분 단위 복원이 필요하면 별도 스토리지 검토 (현재 1.0 범위 밖).
