#!/bin/sh
set -eu

# 무중단 사용자 추가 검증
# alice의 대용량 업로드가 진행 중인 동안 charlie를 Secret 업데이트로 추가하고,
# charlie 로그인 가능 시점, alice 전송 완료, Pod 미재시작을 검증한다.
#
# 사용법:
#   ./tests/zero-downtime-useradd.sh <LB_IP> <alice_pw>

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <LB_IP> <alice_pw>" >&2
    exit 2
fi

LB_IP="$1"
ALICE_PW="$2"

LARGE_FILE=$(mktemp)
CURL_LOG=$(mktemp)
CURL_PID=""
ORIGINAL_USERS=""

cleanup() {
    # 백그라운드 curl 종료
    if [ -n "$CURL_PID" ] && kill -0 "$CURL_PID" 2>/dev/null; then
        kill "$CURL_PID" 2>/dev/null || true
        wait "$CURL_PID" 2>/dev/null || true
    fi

    # 로컬 임시 파일 제거
    rm -f "$LARGE_FILE" "$CURL_LOG"

    # 서버 측 longfile.bin 제거 (best effort)
    kubectl -n ftp exec deploy/vsftpd -c vsftpd -- rm -f /srv/ftp/alice/longfile.bin >/dev/null 2>&1 || true

    # Secret 복원: 원본 4줄 상태로 (alice/bob)
    if [ -n "$ORIGINAL_USERS" ]; then
        RESTORE_FILE=$(mktemp)
        printf '%s' "$ORIGINAL_USERS" > "$RESTORE_FILE"
        kubectl create secret generic vsftpd-users -n ftp \
            --from-file=users.txt="$RESTORE_FILE" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
        rm -f "$RESTORE_FILE"
    fi
}
trap cleanup EXIT INT TERM

# 0. 원본 Secret users.txt 캡처
ORIGINAL_USERS=$(kubectl -n ftp get secret vsftpd-users -o jsonpath='{.data.users\.txt}' | base64 -d)
if [ -z "$ORIGINAL_USERS" ]; then
    echo "FAIL: vsftpd-users Secret을 읽을 수 없음" >&2
    exit 1
fi

# 1. 200MB 랜덤 파일 생성
echo "INFO: 200MB 랜덤 파일 생성 중..."
dd if=/dev/urandom of="$LARGE_FILE" bs=1M count=200 >/dev/null 2>&1

# 2. alice 업로드 백그라운드 시작 (5MB/s 제한 → 약 40초 소요)
echo "INFO: alice 업로드를 백그라운드로 시작 (5MB/s 제한)"
curl -sS --limit-rate 5M --ftp-pasv --disable-epsv \
    --user "alice:${ALICE_PW}" \
    -T "$LARGE_FILE" \
    "ftp://${LB_IP}/longfile.bin" \
    >"$CURL_LOG" 2>&1 &
CURL_PID=$!

# 3. 업로드가 안정적으로 진행되도록 잠시 대기
sleep 10
if ! kill -0 "$CURL_PID" 2>/dev/null; then
    echo "FAIL: alice 업로드가 초기 10초 안에 종료됨 (curl 로그 아래)" >&2
    cat "$CURL_LOG" >&2
    exit 1
fi
echo "INFO: alice 업로드 진행 중 (PID=$CURL_PID)"

# 4. Secret 업데이트 시점 스냅샷
START_TIME=$(date +%s)

# 5. Secret에 charlie 추가 (기존 4줄 보존)
NEW_USERS_FILE=$(mktemp)
printf '%s\ncharlie\ncharliepw\n' "$ORIGINAL_USERS" > "$NEW_USERS_FILE"
kubectl create secret generic vsftpd-users -n ftp \
    --from-file=users.txt="$NEW_USERS_FILE" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
rm -f "$NEW_USERS_FILE"
echo "INFO: Secret에 charlie 추가 완료 (t=${START_TIME})"

# 6. charlie 로그인 폴링 (최대 24회 × 5초 = 120초)
CHARLIE_OK=0
i=0
while [ "$i" -lt 24 ]; do
    i=$((i + 1))
    if curl -sS --max-time 5 --disable-epsv --ftp-pasv \
            --user 'charlie:charliepw' \
            "ftp://${LB_IP}/" >/dev/null 2>&1; then
        NOW=$(date +%s)
        ELAPSED=$((NOW - START_TIME))
        echo "OK: charlie 로그인 성공 (소요 시간: ${ELAPSED}s)"
        CHARLIE_OK=1
        break
    fi
    sleep 5
done

if [ "$CHARLIE_OK" -ne 1 ]; then
    echo "FAIL: 120초 이내 charlie 로그인 실패" >&2
    exit 1
fi

# 7. alice 업로드 완료 대기
echo "INFO: alice 업로드 완료 대기 중..."
ALICE_RC=0
wait "$CURL_PID" || ALICE_RC=$?
CURL_PID=""

if [ "$ALICE_RC" -ne 0 ]; then
    echo "FAIL: alice의 진행 중 전송이 실패함 (rc=${ALICE_RC})" >&2
    echo "----- curl log -----" >&2
    cat "$CURL_LOG" >&2
    exit 1
fi

echo "OK: alice 전송 완료, charlie 무중단 추가 검증 성공"

# 8. Pod 미재시작 검증
RESTARTS=$(kubectl -n ftp get pod -l app=vsftpd \
    -o jsonpath='{.items[0].status.containerStatuses[*].restartCount}')
echo "INFO: restartCount = '${RESTARTS}'"

# 모든 값이 0인지 확인 (공백으로 구분된 정수들)
for n in $RESTARTS; do
    if [ "$n" -ne 0 ]; then
        echo "FAIL: Pod의 컨테이너가 재시작됨 (restartCount=${RESTARTS})" >&2
        exit 1
    fi
done

echo "OK: Pod 재시작 없음 (restartCount=${RESTARTS})"
exit 0
