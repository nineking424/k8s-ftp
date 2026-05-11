#!/bin/sh
set -eu

PASV_ADDRESS="${PASV_ADDRESS:-127.0.0.1}"
USERS_TXT="${USERS_TXT:-/var/run/users/users.txt}"
SHARED_DIR="${SHARED_DIR:-/shared}"
FTP_ROOT="${FTP_ROOT:-/srv/ftp}"

mkdir -p "$SHARED_DIR" "$FTP_ROOT" /var/run/vsftpd/empty

# 초기 users.db 생성
if [ -f "$USERS_TXT" ]; then
    db_load -T -t hash -f "$USERS_TXT" "$SHARED_DIR/users.db"
    chmod 600 "$SHARED_DIR/users.db"

    # 사용자 디렉토리 보장
    awk 'NR%2==1' "$USERS_TXT" | while read -r u; do
        mkdir -p "$FTP_ROOT/$u"
        chown ftpvirt:ftpvirt "$FTP_ROOT/$u"
    done
else
    echo "WARN: $USERS_TXT not found, vsftpd will start but no users can log in" >&2
fi

# vsftpd 로그를 stdout으로 노출: named pipe + tail -F
# (vsftpd는 privsep 후 비특권 child에서 log_file을 open하므로 /dev/stdout 직접 사용 불가)
LOG_PIPE=/var/run/vsftpd/vsftpd.log
if [ ! -p "$LOG_PIPE" ]; then
    rm -f "$LOG_PIPE"
    mkfifo "$LOG_PIPE"
    chmod 666 "$LOG_PIPE"
fi
tail -F "$LOG_PIPE" &

# vsftpd 기동 (foreground). pasv_address는 argv로 주입해 RO root에서도 동작
exec /usr/sbin/vsftpd /etc/vsftpd/vsftpd.conf "-opasv_address=${PASV_ADDRESS}"
