FROM debian:12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        vsftpd \
        libpam-modules \
        db-util \
        inotify-tools \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -r -s /usr/sbin/nologin -d /srv/ftp ftpvirt \
    && mkdir -p /etc/vsftpd /shared /srv/ftp /var/run/users /var/run/vsftpd/empty \
    && chown ftpvirt:ftpvirt /srv/ftp

COPY conf/vsftpd.conf.template /etc/vsftpd/vsftpd.conf.template
COPY conf/pam_vsftpd_virtual /etc/vsftpd/pam_vsftpd_virtual
COPY entrypoint.sh /entrypoint.sh
COPY user-syncer.sh /user-syncer.sh

EXPOSE 21 30000-30099

ENTRYPOINT ["/entrypoint.sh"]
