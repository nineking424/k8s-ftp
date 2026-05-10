#!/bin/sh
set -eu

CONTAINER_NAME="k8s-ftp-smoke"
USERS_FILE=$(mktemp)
TESTFILE=$(mktemp)
DOWNLOADED=$(mktemp)

cat > "$USERS_FILE" <<'EOF'
alice
alicepw
bob
bobpw
EOF

echo "hello from alice" > "$TESTFILE"

cleanup() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    rm -f "$USERS_FILE" "$TESTFILE" "$DOWNLOADED"
}
trap cleanup EXIT

# 컨테이너 기동
docker run -d --name "$CONTAINER_NAME" \
    -p 2121:21 \
    -p 30000-30099:30000-30099 \
    -e PASV_ADDRESS=127.0.0.1 \
    -v "$USERS_FILE:/var/run/users/users.txt:ro" \
    --cap-add NET_BIND_SERVICE \
    --cap-add SYS_CHROOT \
    k8s-ftp:dev

# 기동 대기
sleep 3

# lftp PASV 업로드 + 다운로드 (stdin 배치)
lftp -u alice,alicepw -p 2121 127.0.0.1 <<LFTP
set ftp:passive-mode true
set xfer:clobber on
put $TESTFILE -o test.txt
get test.txt -o $DOWNLOADED
bye
LFTP

# 업로드 검증: 컨테이너 내부에 파일이 실제로 존재
docker exec "$CONTAINER_NAME" test -f /srv/ftp/alice/test.txt
echo PASS_UPLOAD

# 다운로드 검증: 내용이 원본과 일치
if diff -q "$TESTFILE" "$DOWNLOADED" >/dev/null 2>&1; then
    echo PASS_DOWNLOAD
else
    echo FAIL_DOWNLOAD >&2
    exit 1
fi

echo "OK: PASV 스모크 테스트 통과"
