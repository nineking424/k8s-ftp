# k8s-ftp

사내망 전용 Plain FTP 서비스. vsftpd 단일 Pod + NAS PVC + 가상 사용자 격리.

설계 문서: `docs/superpowers/specs/2026-05-07-k8s-ftp-design.md`
구현 계획: `docs/superpowers/plans/2026-05-11-k8s-ftp.md`

## 빌드
```bash
docker build -t k8s-ftp:dev ./docker
```

## 로컬 실행
```bash
docker-compose up
```

## k8s 배포
```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/
```

## 운영 SOP

### 사용자 추가
1. `kubectl get secret -n ftp vsftpd-users -o yaml > /tmp/secret.yaml`
2. `/tmp/secret.yaml`의 `stringData.users.txt`에 사용자명+패스워드 두 줄 추가
3. `kubectl apply -f /tmp/secret.yaml && rm /tmp/secret.yaml`
4. 약 60-90초 후 신규 사용자 로그인 검증 (관측 사례 ~18초)

### 사용자 제거
1. 동일 절차로 Secret에서 해당 사용자 두 줄 제거
2. 데이터 정리는 별도 절차 (사용자 디렉토리 `/srv/ftp/<user>/` 백업 후 삭제)

### PASV 포트 사용률 확인
```bash
kubectl exec -n ftp deploy/vsftpd -c vsftpd -- sh -c "ss -tn '( sport >= :30000 and sport <= :30099 )' | wc -l"
```
사용률 80개 이상 지속 시 PASV 포트 범위 확장 작업 필요.

> 컨테이너 PID/namespace 제약으로 위 명령이 0을 반환할 수 있음. 그 경우 vsftpd 자식 PID 수로 대체: `kubectl exec -n ftp deploy/vsftpd -c vsftpd -- sh -c 'ls /proc | grep -c "^[0-9]"'`

### PASV 포트 범위 확장
1. `docker/conf/vsftpd.conf`의 `pasv_max_port` 값 변경
2. 이미지 재빌드 + 푸시
3. `k8s/05-service.yaml`에 신규 포트 항목 추가
4. `kubectl apply -f k8s/05-service.yaml -f k8s/04-deployment.yaml`

### LB IP 변경
1. ConfigMap `vsftpd-config`의 `PASV_ADDRESS` 값 변경
2. Service `k8s/05-service.yaml`의 `metallb.io/loadBalancerIPs` annotation 변경
3. `kubectl rollout restart deployment/vsftpd -n ftp`
4. 클라이언트 공지

### 보안 패치 (분기별)
1. Debian slim 베이스 이미지 최신 태그로 `docker/Dockerfile` 갱신
2. `docker build` + 푸시
3. `kubectl set image deployment/vsftpd -n ftp vsftpd=<new-tag> user-syncer=<new-tag>`

### 백업
- 데이터: NAS 스냅샷 정책에 위임 (사내 NAS 운영팀 RPO/RTO 합의)
- Secret: etcd 백업으로 보호. 평문 사용자 목록은 GitOps에 평문 저장 금지.
- 매니페스트: 본 저장소가 source of truth.
