#!/bin/sh
set -eu

CONTAINER_NAME="k8s-ftp-chroot"
USERS_FILE=$(mktemp)

cat > "$USERS_FILE" <<'EOF'
alice
alicepw
bob
bobpw
EOF

cleanup() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    rm -f "$USERS_FILE"
}
trap cleanup EXIT

docker run -d --name "$CONTAINER_NAME" \
    -p 2121:21 \
    -p 30000-30099:30000-30099 \
    -e PASV_ADDRESS=127.0.0.1 \
    -v "$USERS_FILE:/var/run/users/users.txt:ro" \
    --cap-add NET_BIND_SERVICE \
    --cap-add SYS_CHROOT \
    k8s-ftp:dev

sleep 3

# bob 디렉토리에 미리 secret 파일 심기 (alice가 접근하면 안 되는 데이터)
docker exec "$CONTAINER_NAME" sh -c "echo 'bob-secret' > /srv/ftp/bob/secret.txt && chown ftpvirt:ftpvirt /srv/ftp/bob/secret.txt"

# alice로 로그인 후 다양한 경로로 bob 디렉토리/파일 접근 시도
OUTPUT=$(lftp -u alice,alicepw -p 2121 127.0.0.1 <<'LFTP' 2>&1 || true
set ftp:passive-mode true
cd /bob
cd ../bob
cd ../../bob
cd ../../../bob
pwd
ls /bob
cat /bob/secret.txt
bye
LFTP
)

# alice가 bob 데이터 내용을 보면 실패
if echo "$OUTPUT" | grep -q "bob-secret"; then
    echo "FAIL: alice가 bob 데이터에 접근함" >&2
    echo "$OUTPUT" >&2
    exit 1
fi

# 현재 디렉토리가 /bob이 되면 실패 (chroot 탈출)
if echo "$OUTPUT" | grep -qE '^/bob\b'; then
    echo "FAIL: alice가 bob 디렉토리로 이동함" >&2
    echo "$OUTPUT" >&2
    exit 1
fi

echo "OK: chroot 격리 확인"
