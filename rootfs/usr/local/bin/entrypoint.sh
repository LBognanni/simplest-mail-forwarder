#!/bin/sh
# Configures Postfix from the environment and runs it in the foreground.
# Never print FORWARD_RULES or any part of it: it holds private addresses.
set -eu

die() {
    echo "entrypoint: $*" >&2
    exit 1
}

# Rejects anything outside this character set first, because grep matches line by line
# and a value containing a newline could otherwise pass on one good line.
only_address_chars() {
    case "$1" in
        *[!A-Za-z0-9.@:_%+-]*) return 1 ;;
    esac
}

DOMAIN_RE='([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}'
LOCAL_RE='[A-Za-z0-9._%+-]+'

: "${MAIL_HOSTNAME:=}"
: "${FORWARD_RULES:=}"
: "${SRS_DOMAIN:=}"
[ -n "$MAIL_HOSTNAME" ] || die "MAIL_HOSTNAME is required"
[ -n "$FORWARD_RULES" ] || die "FORWARD_RULES is required"
[ -n "$SRS_DOMAIN" ] || die "SRS_DOMAIN is required"

if ! only_address_chars "$MAIL_HOSTNAME" \
    || ! printf '%s' "$MAIL_HOSTNAME" | grep -Eq "^$DOMAIN_RE\$"; then
    die "MAIL_HOSTNAME is not a valid hostname"
fi

if ! only_address_chars "$SRS_DOMAIN" \
    || ! printf '%s' "$SRS_DOMAIN" | grep -Eq "^$DOMAIN_RE\$"; then
    die "SRS_DOMAIN is not a valid domain"
fi

case "$FORWARD_RULES" in
    *[!A-Za-z0-9.@:_%+\;-]*) die "FORWARD_RULES contains an invalid character" ;;
    \;* | *\; | *\;\;*) die "FORWARD_RULES contains an empty rule" ;;
esac

template=/usr/local/etc/postfix
cp -R "$template"/. /etc/postfix/
chown -R root:root /etc/postfix
chmod 0755 /etc/postfix
chown postfix:root /var/lib/postfix
chmod 0700 /var/lib/postfix

set -f
old_ifs=$IFS
IFS=';'
# shellcheck disable=SC2086 # Splitting on ; is the point, and globbing is off.
set -- $FORWARD_RULES
IFS=$old_ifs
set +f

: > /etc/postfix/virtual
domains=
number=0
for rule in "$@"; do
    number=$((number + 1))
    printf '%s' "$rule" | grep -Eq "^($LOCAL_RE)?@$DOMAIN_RE:$LOCAL_RE@$DOMAIN_RE\$" \
        || die "FORWARD_RULES rule $number is invalid"
    source=${rule%%:*}
    target=${rule#*:}
    domain=${source#*@}
    printf '%s %s\n' "$source" "$target" >> /etc/postfix/virtual
    case ",$domains," in
        *",$domain,"*) ;;
        *) domains=${domains:+$domains,}$domain ;;
    esac
done

postconf -e "myhostname=$MAIL_HOSTNAME" "virtual_alias_domains=$domains"
postmap lmdb:/etc/postfix/virtual

key=/etc/postfix-tls/key.pem
cert=/etc/postfix-tls/cert.pem
if [ ! -s "$key" ] || [ ! -s "$cert" ]; then
    (
        umask 077
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
            -days 3650 -subj "/CN=$MAIL_HOSTNAME" \
            -addext "subjectAltName=DNS:$MAIL_HOSTNAME" \
            -keyout "$key.new" -out "$cert.new" 2>/dev/null
        mv "$cert.new" "$cert"
        mv "$key.new" "$key"
    )
fi

# Never replace an existing secret: bounces to older SRS addresses need it.
secret=/var/lib/postsrsd/secret
if [ ! -s "$secret" ]; then
    (
        umask 077
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$secret.new"
        mv "$secret.new" "$secret"
    )
fi

srs_config=/run/postsrsd.conf
cat > "$srs_config" <<CONFIG
srs-domain = "$SRS_DOMAIN"
domains = {}
socketmap = "inet:127.0.0.1:10003"
secrets-file = "$secret"
original-envelope = embedded
unprivileged-user = "postsrsd"
chroot-dir = ""
CONFIG

postfix check

# The Postfix master must be PID 1, so nothing can sit above both programs. This loop stays
# behind after the exec and restarts PostSRSd, which reads the secret and then drops to its
# own user. While it's down, Postfix answers 451 and senders retry.
while :; do
    postsrsd -C "$srs_config" || echo "entrypoint: postsrsd exited with status $?" >&2
    sleep 1
done &

exec postfix start-fg
