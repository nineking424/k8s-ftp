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

## 운영 빠른 참조

자세한 절차는 wiki 가 정본이다. 본 표는 자주 쓰는 명령의 요약.

| 작업 | 한 줄 명령 (요약) | 자세한 절차 |
|---|---|---|
| 사용자 추가/제거 | `kubectl create secret generic vsftpd-users --from-file=users.txt=/tmp/users.txt -n ftp --dry-run=client -o yaml \| kubectl apply -f -` | [user-management.md](https://nineking424.github.io/k8s-ftp/operating/user-management/) |
| 활성 세션 확인 | `kubectl exec -n ftp deploy/vsftpd -c vsftpd -- sh -c 'ls /proc \| grep -c "^[0-9]"'` | [monitoring.md — 동시 세션과 PASV 사용률](https://nineking424.github.io/k8s-ftp/operating/monitoring/#동시-세션과-pasv-사용률) |
| PASV 포트 범위 확장 | (manifests 변경 필요) | [maintenance.md — PASV 포트 범위 확장](https://nineking424.github.io/k8s-ftp/operating/maintenance/#pasv-포트-범위-확장) |
| LB IP 변경 | (annotation + ConfigMap 변경) | [maintenance.md — LB IP 변경](https://nineking424.github.io/k8s-ftp/operating/maintenance/#lb-ip-변경) |
| 이미지 보안 패치 | `docker build --no-cache && docker push && kubectl set image deployment/vsftpd ...` | [maintenance.md — 이미지 보안 패치](https://nineking424.github.io/k8s-ftp/operating/maintenance/#이미지-보안-패치) |
| 백업 | `kubectl exec -n ftp deploy/vsftpd -c vsftpd -- tar -czf - -C /srv/ftp .` (NAS 스냅샷이 정본) | [maintenance.md — 백업과 복구](https://nineking424.github.io/k8s-ftp/operating/maintenance/#백업과-복구) |
| 트러블슈팅 | — | [troubleshooting.md](https://nineking424.github.io/k8s-ftp/operating/troubleshooting/) |
