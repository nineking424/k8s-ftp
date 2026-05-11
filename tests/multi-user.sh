#!/bin/sh
set -eu

CONTAINER_NAME="k8s-ftp-multi"
USERS_FILE=$(mktemp)

# 10명 사용자 생성
> "$USERS_FILE"
for i in $(seq 1 10); do
    printf "user%d\npass%d\n" "$i" "$i" >> "$USERS_FILE"
done

cleanup() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    rm -f "$USERS_FILE" /tmp/multiuser-*.txt
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

# 10명 동시 업로드 (lftp stdin heredoc 배치 모드)
pids=""
for i in $(seq 1 10); do
    TESTFILE="/tmp/multiuser-$i.txt"
    echo "data from user$i" > "$TESTFILE"
    lftp -u "user$i,pass$i" -p 2121 127.0.0.1 <<LFTP >/dev/null 2>&1 &
set ftp:passive-mode true
set xfer:clobber on
put $TESTFILE -o file.txt
bye
LFTP
    pids="$pids $!"
done

# 모두 완료 대기
for pid in $pids; do
    wait "$pid"
done

# 각 사용자가 자기 디렉토리에 자기 파일만 있는지 확인
for i in $(seq 1 10); do
    EXPECTED="data from user$i"
    ACTUAL=$(docker exec "$CONTAINER_NAME" cat "/srv/ftp/user$i/file.txt")
    if [ "$ACTUAL" != "$EXPECTED" ]; then
        echo "FAIL: user$i 파일 불일치 (expected=$EXPECTED, actual=$ACTUAL)" >&2
        exit 1
    fi
done

echo "OK: 10명 동시 업로드 격리 확인"
