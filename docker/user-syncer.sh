#!/bin/sh
set -eu

USERS_TXT="${USERS_TXT:-/var/run/users/users.txt}"
SHARED_DIR="${SHARED_DIR:-/shared}"
FTP_ROOT="${FTP_ROOT:-/srv/ftp}"

regenerate() {
    if [ ! -f "$USERS_TXT" ]; then
        echo "WARN: $USERS_TXT 없음, 동기화 스킵" >&2
        return 0
    fi

    # 형식 검증: 줄 수가 짝수여야 함 (user/password 쌍)
    lines=$(wc -l < "$USERS_TXT")
    if [ $((lines % 2)) -ne 0 ]; then
        echo "ERROR: $USERS_TXT 줄 수가 짝수가 아님 (현재 $lines), 기존 DB 유지" >&2
        return 1
    fi

    # 사용자명 유효성 (영문/숫자/언더스코어/하이픈만)
    awk 'NR%2==1' "$USERS_TXT" | while read -r u; do
        case "$u" in
            *[!a-zA-Z0-9_-]*|"")
                echo "ERROR: 잘못된 사용자명 '$u', 기존 DB 유지" >&2
                exit 1
                ;;
        esac
    done || return 1

    db_load -T -t hash -f "$USERS_TXT" "$SHARED_DIR/users.db.new"
    chmod 600 "$SHARED_DIR/users.db.new"
    mv "$SHARED_DIR/users.db.new" "$SHARED_DIR/users.db"

    awk 'NR%2==1' "$USERS_TXT" | while read -r u; do
        if [ ! -d "$FTP_ROOT/$u" ]; then
            mkdir -p "$FTP_ROOT/$u"
            chown ftpvirt:ftpvirt "$FTP_ROOT/$u"
            echo "INFO: 사용자 디렉토리 생성: $u"
        fi
    done

    echo "INFO: users.db 동기화 완료 ($(date -Iseconds))"
}

# 초기 동기화
regenerate || true

# inotify 감시 루프
inotifywait -m -e modify -e create -e delete_self -e moved_to "$(dirname "$USERS_TXT")" |
while read -r _ event _; do
    echo "INFO: 변경 감지 ($event), 동기화 시작"
    sleep 1   # k8s가 마운트를 갱신하는 동안 잠시 대기
    regenerate || echo "ERROR: 동기화 실패, 다음 이벤트 대기"
done
