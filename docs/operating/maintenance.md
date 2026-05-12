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
