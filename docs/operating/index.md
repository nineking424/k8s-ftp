# 운영

vsftpd 단일 Pod 를 사내망에 돌리는 데 필요한 운영자용 페이지 모음. 일상 운영 절차는 [사용자 관리](user-management.md) / [운영 절차](maintenance.md), 사고 대응은 트러블슈팅에서 진입한다.

- [사용자 관리](user-management.md) — 가상 사용자 추가·제거 정식 절차.
- [운영 절차](maintenance.md) — PASV 포트 확장, LB IP 변경, 이미지 보안 패치, 백업
- [테스트와 검증](testing.md) — 로컬 / k8s 검증 스크립트 카탈로그 + 배포 검증 SOP.
- [용량과 한계](capacity.md) — 동시 접속 / PASV / 부하 테스트 결과 + 사이징.
- [모니터링](monitoring.md) — xferlog 라인 카탈로그, 동시 세션 / PASV 사용률 관찰 방법, 권장 알람.
- [트러블슈팅](troubleshooting.md) — 증상 → 원인 → 진단 → 조치 매트릭스.
