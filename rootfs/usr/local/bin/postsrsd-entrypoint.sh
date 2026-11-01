#!/bin/sh
# Runs PostSRSd in the foreground as an unprivileged user.
set -eu

die() {
    echo "postsrsd-entrypoint: $*" >&2
    exit 1
}

: "${SRS_DOMAIN:=}"
[ -n "$SRS_DOMAIN" ] || die "SRS_DOMAIN is required"
[ "$(id -u)" -ne 0 ] || die "run this container with user: postsrsd"

case "$SRS_DOMAIN" in
    *[!A-Za-z0-9.-]*) die "SRS_DOMAIN is not a valid domain" ;;
esac
printf '%s' "$SRS_DOMAIN" | grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$' \
    || die "SRS_DOMAIN is not a valid domain"

# Never replace an existing secret: bounces to older SRS addresses need it.
secret=/var/lib/postsrsd/secret
if [ ! -s "$secret" ]; then
    (
        umask 077
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$secret.new"
        mv "$secret.new" "$secret"
    )
fi

config=/tmp/postsrsd.conf
cat > "$config" <<CONFIG
srs-domain = "$SRS_DOMAIN"
domains = {}
socketmap = "inet:*:10003"
secrets-file = "$secret"
original-envelope = embedded
unprivileged-user = ""
chroot-dir = ""
CONFIG

exec postsrsd -C "$config"
