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
