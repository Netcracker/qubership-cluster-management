#!/bin/bash
# Runs as root on the Nexus VM (local/lab.sh nexus-install pipes it over SSH); the archive is already in /tmp.
# No Internet needed: the Linux archive includes its Java runtime.
set -euo pipefail
archive=/tmp/nexus.tar.gz work=/opt/sonatype-work/nexus3

id nexus >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/nexus --shell /usr/sbin/nologin nexus
if [[ ! -d /opt/nexus ]]; then
    dir=/opt/$(tar -tzf "$archive" | sed -n 1p | cut -d/ -f1)
    tar -xzf "$archive" -C /opt && ln -sfn "$dir" /opt/nexus
fi
rm -f "$archive"

# admin/admin123 until bundle/load.sh replaces it with the SOPS-stored password.
mkdir -p "$work/etc"
grep -q randompassword "$work/etc/nexus.properties" 2>/dev/null ||
    echo 'nexus.security.randompassword=false' >> "$work/etc/nexus.properties"
chown -R nexus:nexus /opt/nexus/ /opt/sonatype-work

cat > /etc/systemd/system/nexus.service <<'UNIT'
[Unit]
Description=Nexus Repository
After=network.target

[Service]
Type=forking
User=nexus
LimitNOFILE=65536
ExecStart=/opt/nexus/bin/nexus start
ExecStop=/opt/nexus/bin/nexus stop
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now nexus
