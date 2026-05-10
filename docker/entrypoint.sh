#!/bin/sh
set -eu

PASV_ADDRESS="${PASV_ADDRESS:-127.0.0.1}"
USERS_TXT="${USERS_TXT:-/var/run/users/users.txt}"
SHARED_DIR="${SHARED_DIR:-/shared}"
FTP_ROOT="${FTP_ROOT:-/srv/ftp}"

mkdir -p "$SHARED_DIR" "$FTP_ROOT"

# vsftpd.conf 렌더링
sed "s|__PASV_ADDRESS__|${PASV_ADDRESS}|g" \
    /etc/vsftpd/vsftpd.conf.template \
    > /etc/vsftpd/vsftpd.conf

# PAM 설정 배치
cp /etc/vsftpd/pam_vsftpd_virtual /etc/pam.d/vsftpd_virtual

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

# vsftpd 기동 (foreground)
exec /usr/sbin/vsftpd /etc/vsftpd/vsftpd.conf
