# Wiki 개선 설계 (SSOT 이전 + 절차 페이지 신설 + 검증 게이트)

> **상태.** Brainstorming 완료, plan 작성 대기. 작성일 2026-05-12. 대상 위키: <https://nineking424.github.io/k8s-ftp/>.

## 목표

배포된 wiki 가 README `운영 SOP` 로 폴스루하지 않고 자급자족하도록 개선한다. SSOT(single source of truth) 를 wiki 로 이전하고, 가장 빈도 높은 운영 작업인 **사용자 추가·제거** 의 정식 절차 페이지를 신설하며, 외부 데이터 부재 상태의 placeholder 를 임의 수치 없이 "출처/언제 정해질지" 만 명시해 의미를 자급자족하게 만든다.

## 비목표

- UX/테마 마이그레이션 (readthedocs → Material 같은 변경 없음).
- installation / FAQ / developer 가이드 신설 (자주 안 보는 페이지는 rot 위험 — 이번 라운드 범위 밖).
- placeholder 의 실수치 채움 (사내 SLO/보안 정책 문서 미확정 — 의미만 보강).
- vsftpd `/metrics` exporter 도입 (1.0 운영 안정화 후로 별도 라운드).
- 브랜치 보호 룰 변경 (CI gate 의 머지 차단 강제는 별도 작업).

## 배경 — 현재 wiki 의 결함 4 가지

1. **사용자 추가·제거 정식 절차 페이지 부재.** `docs/operating/troubleshooting.md` 가 "무중단 사용자 추가가 반영되지 않는다" 의 *실패 케이스* 만 다루고, 정상 흐름·검증 룰·end-to-end 예제는 `README#운영-sop` 의 두 섹션 (`#사용자-추가`, `#사용자-제거`) 으로 폴스루한다. wiki 안에서 자급자족 안 됨.

2. **README 의 운영 SOP 가 wiki 와 중복**. 직전 라운드에서 README 에 7 개 SOP 섹션 (사용자 추가/제거, PASV 사용률, PASV 확장, LB IP 변경, 보안 패치, 백업) 을 추가했다. SSOT 가 둘 — drift 가 시간 문제.

3. **monitoring.md 의 placeholder 4 종이 의미 자급자족 안 됨**. `<N from security policy>`, `<rate from SLO>`, `<vsftpd_sessions_active>` 등 — 어디서 정해질지, 언제 정해질지, 그동안 운영자가 무엇을 해야 하는지가 표 안에 없다.

4. **broken-link CI 부재**. `mkdocs build --strict` 는 내부 anchor 만 검증. README 의 wiki 절대 URL, 페이지 간 cross-anchor 의 drift 가 잡히지 않아 SSOT 이전 후 가장 큰 silent failure 위험.

## 개선의 5 가지 결정

1. **개선 축**: breadth(누락 페이지 추가) + depth(기존 페이지 보강) + quality(일관성·CI). UX/테마는 보류.
2. **1차 독자**: 모든 페르소나 균등 — 우선순위는 시나리오 빈도로 결정.
3. **1순위 시나리오**: 사용자 추가·제거.
4. **SSOT 위치**: wiki 가 정본, README 는 요약 + 링크.
5. **Placeholder 처리**: 실수치 자료 없음 — 구조 유지 + 의미/출처만 보강.

## 파일 구조

```
docs/
  index.md                         (수정: 페르소나 라우팅 표에 user-management / maintenance 추가)
  concepts/
    architecture.md                (변경 없음)
  operating/
    index.md                       (수정: nav 갱신)
    user-management.md             (NEW — P1)
    maintenance.md                 (NEW — P2)
    monitoring.md                  (수정: placeholder 메타 컬럼)
    troubleshooting.md             (수정: README 폴스루 anchor → wiki anchor)
README.md                          (수정: 운영 SOP → 운영 빠른 참조 표)
mkdocs.yml                         (수정: nav 두 줄 추가)
.github/workflows/docs.yml         (수정: PR 트리거, lychee link-check job 추가)
```

핵심 결정:

- `maintenance.md` **한 페이지에 통합** — LB IP 변경 / PASV 포트 확장 / 보안 패치 / 백업 을 H2 4 섹션으로. 분리 시 페이지 4 개 → rot 위험.
- `user-management.md` **별도 페이지** — 1 순위 시나리오로 시퀀스 다이어그램 + 검증 룰 + 추가/제거 예제 분량이 두텁다.

## 페이지 1 — `operating/user-management.md`

절차 페이지 패턴 (Symptom→Cause→Diagnose→Act→Verify 4-beat 는 트러블슈팅 전용이므로 미적용).

**구성**:

```
# 사용자 관리

(1줄 오프닝) 가상 사용자 추가/제거 절차. 변경의 source of truth 는 `vsftpd-users` Secret,
user-syncer sidecar 가 atomic rename 으로 `users.db` 를 갱신한다.

## 변경 흐름

(mermaid sequenceDiagram — Secret apply → inotify → db_load → atomic rename → curl 검증)
(반영 타이밍: 1~3 초. 실패 시 user-syncer 가 기존 users.db 유지.)

## 검증 룰

| 항목 | 규칙 | 위반 시 |
|---|---|---|
| 줄 구조 | 홀수=사용자명, 짝수=비밀번호 | ERROR: 줄 수가 짝수가 아님 → 기존 DB 유지 |
| 사용자명 정규식 | ^[a-zA-Z0-9_-]+$ | ERROR: 잘못된 사용자명 → 기존 DB 유지 |
| 인코딩 | UTF-8, BOM 없음 | db_load 실패 → 기존 DB 유지 |
| 최대 사용자 수 | (실측 한계 없음 — 메모리 제약) | — |

## 사용자 추가

(4~6 step end-to-end: Secret 갱신 → apply → user-syncer 로그 확인 → curl 230 검증)

## 사용자 제거

(같은 패턴: Secret 에서 두 줄 제거 → apply → 기존 세션 끊김 확인 → curl 530 검증)

## 변경 후 검증

(필수 3 항목: 신규 로그인 230, 제거된 사용자 530, user-syncer INFO 라인 timestamp 갱신)

## 실패 시

(트러블슈팅 cross-link — troubleshooting.md#무중단-사용자-추가가-반영되지-않는다)

## 알려진 한계

(짝수 라인 + 정규식 제약, 사용자별 quota 없음, 비밀번호 회전 미자동화 — 3~5 개)
```

핵심 결정:

- **시퀀스 다이어그램이 절차 코드보다 먼저**. 추가/제거가 같은 메커니즘이므로 흐름 이해가 먼저.
- **검증 룰 표를 선행 배치**. 트러블슈팅에서 거꾸로 발견하는 패턴을 해소.
- **실패 케이스는 트러블슈팅에 anchor 폴스루**. user-management.md 는 정상 흐름 + 검증 룰 정본, 실패 모드는 troubleshooting.md 가 정본 — 중복 회피.

## 페이지 2 — `operating/maintenance.md`

```
# 운영 절차 (Maintenance)

(1줄 오프닝) 사용자 관리 외 정기·비정기 운영 절차. 각 H2 는 사전 조건 → 단계 → 검증 → 알려진 한계 4 구간.

## PASV 포트 범위 확장
## LB IP 변경
## 이미지 보안 패치 (롤아웃)
## 백업·복구
```

H2 순서는 빈도 ↑ → ↓ (PASV 확장 가장 자주, 백업 가장 드묾).

각 H2 의 4 구간 패턴 (예: PASV 포트 확장):

```
(1~2줄: 언제 필요한가)

**사전 조건.** ...

**단계.**

1. ConfigMap PASV_MIN/MAX 수정
2. Service spec.ports 신규 포트 추가
3. kubectl apply 두 manifest
4. kubectl rollout restart deployment/vsftpd

**검증.**

(curl --ftp-pasv 로 227 응답 튜플 확인, 새 범위 안)

**알려진 한계.** Service 포트 enumerate (k8s range 표기 미지원), manifests 길어짐 — 100 단위 권장.
```

핵심 결정:

- **백업·복구 한 H2 안에 통합** — 같은 NAS PVC snapshot 메커니즘이라 분리 불필요.
- **이미지 보안 패치 별도 H2** — 단순 rollout 이 아닌 base 이미지 업데이트 + 재빌드 + 태그 + manifests 갱신까지 — 분량이 크다.
- **각 H2 끝 "알려진 한계"** — 트러블슈팅 / monitoring 과 동일한 톤.

## 페이지 3 — `operating/monitoring.md` placeholder 보강

자료 없음 → 임의 수치 적지 않음. 표에 출처/조건 컬럼 추가.

**메트릭 카탈로그** (4 → 5 컬럼):

| 메트릭 | 모드 | 현재 산출 | 라벨 | **이름 확정 조건** (NEW) |
|---|---|---|---|---|
| `<vsftpd_sessions_active>` | 미도입 | 자식 PID 카운트 | exporter 도입 시 `user` | vsftpd exporter 도입 결정 (1.0 운영 안정화 후) |
| `<vsftpd_login_failed_total>` | 미도입 | grep FAIL LOGIN \| wc -l | exporter 도입 시 `source_ip` | 동상 |
| `<vsftpd_max_per_ip_rejects_total>` | 미도입 | grep 421 \| wc -l | exporter 도입 시 `source_ip` | 동상 |
| `<pod_restart_count>` | scrape (kube-state-metrics) | kubectl get pod jsonpath | `container` | 결정됨 — kube-state-metrics 기본 메트릭 |

**알람 표** (3 → 4 컬럼):

| 신호 | 임계값 | 의미 | **임계 결정 조건** (NEW) |
|---|---|---|---|
| 자식 PID 카운트 | ≥ 480 | max_clients=600 의 80% | 결정됨 — vsftpd.conf 의 max_clients 변경 시 재계산 |
| FAIL LOGIN 분당 N회/IP | `<N from security policy>` | brute force 의심 | 사내 보안 정책 (`<doc>`) 확정 후 채움. 임시 운영: 분당 ≥ 5 시 수동 검토 |
| 421 Too many 분당 발생 | `<rate from SLO>` | max_per_ip 임계 | 가용성 SLO (`<doc>`) 확정 후 채움. 임시 운영: 분당 ≥ 3 시 수동 검토 |
| Pod restartCount 증가 | 모니터링 인터벌 내 1회 이상 | vsftpd master crash | 결정됨 — [트러블슈팅 — Pod CrashLoop](troubleshooting.md#pod-가-crashloop) |

핵심 결정:

- **컬럼 추가** — footnote 보다 구조화, "tables for everything comparable" 룰에 부합.
- **"임시 운영" 한 줄** — 자료 미확정이지만 on-call 이 "지금 뭘 해야 하나" 답을 받지 못하면 페이지 가치 ↓. 임시임을 명시.
- **placeholder 네이밍 컨벤션 한 줄 명시** — 페이지 상단에 `< >` 로 둘러싸인 식별자 = 미정 자리.

## README 축약

`## 운영 SOP` → `## 운영 빠른 참조` (SSOT 관계 명시).

```markdown
## 운영 빠른 참조

자세한 절차는 wiki 가 정본이다. 본 표는 자주 쓰는 명령의 요약.

| 작업 | 한 줄 명령 (요약) | 자세한 절차 |
|---|---|---|
| 사용자 추가/제거 | `kubectl edit secret vsftpd-users -n ftp` | [user-management.md](https://nineking424.github.io/k8s-ftp/operating/user-management/) |
| 활성 세션 확인 | `kubectl exec -n ftp deploy/vsftpd -c vsftpd -- sh -c 'ls /proc \| grep -c "^[0-9]"'` | [monitoring.md#동시-세션과-pasv-사용률](...) |
| PASV 포트 범위 확장 | (manifests 변경 필요) | [maintenance.md#pasv-포트-범위-확장](...) |
| LB IP 변경 | (annotation + ConfigMap 변경) | [maintenance.md#lb-ip-변경](...) |
| 이미지 보안 패치 | `docker build && docker push && kubectl rollout restart deployment/vsftpd -n ftp` | [maintenance.md#이미지-보안-패치-롤아웃](...) |
| 백업 | `kubectl exec ... tar -czf` | [maintenance.md#백업복구](...) |
| 트러블슈팅 | — | [troubleshooting.md](...) |
```

핵심 결정:

- **단일 한 줄 명령 불가 절차는 솔직히 "(manifests 변경 필요)"** — 가짜 한 줄 명령 금지.
- **wiki 절대 URL** — README 는 GitHub 에서도 렌더되므로 상대 경로면 anchor slug 가 다르게 매핑된다. 절대 URL 통일.
- **`docs/operating/troubleshooting.md` 의 `README#운영-sop` / `README#사용자-추가` anchor 모두 wiki anchor 로 일괄 변경.**

## broken-link CI

도구: `lychee` (lycheeverse/lychee-action@v2).

핵심 트릭: PR 단계엔 새 anchor 가 아직 배포 안 됨 → `lychee --remap` 으로 wiki 절대 URL 을 빌드된 `site/` 로 치환해 PR 안에서 검증.

```yaml
name: Docs CI + Deploy

on:
  push:
    branches: [main]
    paths: ['docs/**', 'mkdocs.yml', 'requirements-docs.txt', '.github/workflows/docs.yml', 'README.md']
  pull_request:
    paths: ['docs/**', 'mkdocs.yml', 'requirements-docs.txt', '.github/workflows/docs.yml', 'README.md']
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: '3.12', cache: pip, cache-dependency-path: requirements-docs.txt }
      - run: pip install -r requirements-docs.txt
      - run: mkdocs build --strict
      - uses: actions/upload-pages-artifact@v3
        with: { path: site }
      - uses: actions/upload-artifact@v4
        with: { name: site-dir, path: site/ }

  link-check:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with: { name: site-dir, path: site/ }
      - uses: lycheeverse/lychee-action@v2
        with:
          args: >-
            --no-progress
            --remap 'https://nineking424.github.io/k8s-ftp/(.*) file://${{ github.workspace }}/site/$1'
            README.md docs/**/*.md

  deploy:
    needs: [build, link-check]
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    environment: { name: github-pages, url: ${{ steps.deployment.outputs.page_url }} }
    steps:
      - id: deployment
        uses: actions/deploy-pages@v4
```

핵심 결정:

- **`lychee --remap`** — 같은 PR 안에서 새로 생기는 anchor (예: `maintenance.md#pasv-포트-범위-확장`) 를 머지 전에 검증.
- **build 의 site/ 를 artifact 로 올려 link-check 가 받기** — `actions/deploy-pages` 와의 충돌 회피.
- **PR 트리거 + deploy 조건부** — 머지 전 보호. 브랜치 보호 룰로 머지 차단까지 강제하는 것은 별도 작업 (이번 범위 밖).

## 검증 게이트

| 항목 | 검증 방법 | 통과 기준 |
|---|---|---|
| 내부 anchor drift | `mkdocs build --strict` | 0 broken |
| 외부 + README → wiki 링크 | `lychee` (remap 적용) | 0 broken |
| 새 페이지 자급자족 | 페이지 self-review — 각 H2 절차에 "검증" 단계 포함 | 100% |
| README 폴스루 제거 | `grep -E 'README#운영-sop\|README#사용자' docs/operating/troubleshooting.md` | 0 hit |
| monitoring placeholder 보강 | 양쪽 표 모두 새 컬럼 헤더 존재 | "이름 확정 조건" / "임계 결정 조건" |
| 배포된 wiki URL | 머지 후 새 페이지 URL HTTP 200 | user-management, maintenance |

## PR 분할 — 2 PR

### PR 1 (P0 + P1) — CI 보강 + 사용자 관리 페이지

- `.github/workflows/docs.yml` → PR 트리거 + lychee link-check job + deploy 조건부
- `docs/operating/user-management.md` 신설
- `docs/operating/index.md` nav cross-link 갱신
- `mkdocs.yml` nav 한 줄 추가
- `docs/index.md` 페르소나 라우팅 표 갱신
- `README.md` 의 `사용자 추가` / `사용자 제거` 두 섹션 본문을 각 1~2 줄로 축약 — "자세한 절차: [user-management.md](https://nineking424.github.io/k8s-ftp/operating/user-management/)" + 자주 쓰는 한 줄 명령. 섹션 헤더는 유지 (전체 표 변환은 PR 2 에서). 다른 SOP 섹션은 그대로
- `docs/operating/troubleshooting.md` 의 `README#사용자-추가` anchor 만 wiki anchor 로 변경

**머지 후 검증**: 배포된 사이트에서 `/operating/user-management/` HTTP 200, README 표의 wiki URL 정상 도착.

### PR 2 (P2 + P3) — maintenance + 나머지 축약 + placeholder 보강

- `docs/operating/maintenance.md` 신설
- `mkdocs.yml` nav 한 줄 추가
- `README.md` 나머지 SOP 섹션 (PASV/LB IP/보안 패치/백업) → 표 행으로 통합, `## 운영 SOP` 제목을 `## 운영 빠른 참조` 로 변경
- `docs/operating/monitoring.md` 메트릭/알람 표에 컬럼 추가, placeholder 컨벤션 한 줄 명시
- `docs/operating/troubleshooting.md` 의 `README#운영-sop` anchor 잔여를 wiki anchor 로 변경

핵심 결정:

- **PR 1 에 CI 보강 동봉** — 첫 PR 부터 새 lychee gate 가 작동. 분리하면 P1 머지 후 검증 없는 윈도우 발생.
- **README 축약을 두 PR 에 나눠 적용** — 중간 상태가 짧다 (P1 머지 후 즉시 P2 가 따라붙음). 한 PR 에 통합하면 diff 가 커져 리뷰성 ↓.
- **트러블슈팅 anchor 갱신 분할** — 각 PR 안에서 `grep` 으로 검증 게이트 항목으로 확인.

## 위험과 완화

| 위험 | 완화 |
|---|---|
| lychee 의 `--remap` 매핑이 실패해 false negative | PR 1 머지 전 의도적으로 깨진 링크를 한 번 넣어 lychee 가 실제로 잡는지 1 회 실측 후 되돌리기. |
| 새 wiki anchor slug 가 unicode-aware slugify 와 불일치 | mkdocs `--strict` 가 anchor 누락을 잡음 — 새 페이지 작성 후 즉시 `mkdocs build --strict` 로 로컬 검증. |
| README 의 GitHub 렌더와 wiki 렌더 간 anchor 차이 | README 의 모든 wiki 링크를 절대 URL 로 통일 — 상대 경로 사용 금지. |
| PR 1 머지 후 PR 2 가 지연되어 README 가 일관되지 않은 상태로 노출 | PR 1 / PR 2 를 같은 작업 세션에 연달아 작성 — 1 일 이내 두 PR 머지 완료 목표. |

## 알려진 한계

- placeholder 의 임시 운영 임계값 (`분당 ≥ 5`, `분당 ≥ 3`) 은 사내 자료 부재 상태의 *근거 없는 운영 가이드라인* — 실제 SLO/보안 정책 확정 후 즉시 수치 교체. 이번 라운드에선 임시임을 본문에 명시.
- lychee 가 GitHub anchors 의 rate limit 으로 간헐적 false positive 를 낼 수 있음 — 초기 운영 중 발생 시 `--exclude` 패턴 추가.
- 브랜치 보호 룰 (PR 머지 차단 강제) 은 GitHub 저장소 설정 변경이 필요하며 이번 spec 범위 밖. CI 가 fail 하면 머지 가능 상태 유지 — 머지 전 수동 확인 책임.
