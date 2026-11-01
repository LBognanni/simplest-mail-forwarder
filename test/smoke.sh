#!/bin/sh
# End-to-end test of the image, under the same hardening as production.
#
#   docker build -t simplest-mail-forwarder:test . && test/smoke.sh
#
# Set IMAGE to test another tag. Exits non-zero if any check fails.
set -u
cd "$(dirname "$0")" || exit 1

passed=0
failed=0

dc() {
    docker compose -f compose.yml "$@"
}

cleanup() {
    dc down -v --remove-orphans >/dev/null 2>&1
}

ok() {
    passed=$((passed + 1))
    echo "ok    - $1"
}

not_ok() {
    failed=$((failed + 1))
    echo "FAIL  - $1"
}

# check "description" command [args...]
check() {
    description=$1
    shift
    if "$@"; then ok "$description"; else not_ok "$description"; fi
}

has() {
    printf '%s\n' "$1" | grep -Eq -- "$2"
}

lacks() {
    ! has "$1" "$2"
}

# Prints each argument as one SMTP line, slowly enough to pass reject_unauth_pipelining.
lines() {
    sleep 0.4
    for line in "$@"; do
        printf '%s\r\n' "$line"
        sleep 0.25
    done
    sleep 0.6
}

smtp() {
    lines "$@" | dc exec -T client timeout 20 nc -w 4 mailserver 25
}

smtp_tls() {
    lines "$@" | dc exec -T client \
        timeout 20 openssl s_client -starttls smtp -connect mailserver:25 -quiet 2>&1
}

# send <sender> <recipient> <subject>
send() {
    smtp "EHLO client.test" "MAIL FROM:<$1>" "RCPT TO:<$2>" DATA \
        "From: <sender@example.com>" "To: <someone@example.com>" "Subject: $3" "" "Test body" . QUIT
}

logs() {
    dc logs --no-log-prefix mailserver
}

# Waits for a line in the Postfix log. Delivery is asynchronous.
in_logs() {
    tries=0
    while [ "$tries" -lt 20 ]; do
        logs | grep -Eq -- "$1" && return 0
        tries=$((tries + 1))
        sleep 0.5
    done
    return 1
}

# Prints the raw message with this subject once it reaches the sink.
sink_message() {
    tries=0
    while [ "$tries" -lt 20 ]; do
        id=$(dc exec -T client wget -qO- "http://mailpit:8025/api/v1/search?query=subject:$1" \
            | grep -Eo '"ID":"[^"]+"' | head -n 1 | cut -d'"' -f4)
        if [ -n "$id" ]; then
            dc exec -T client wget -qO- "http://mailpit:8025/api/v1/message/$id/raw"
            return 0
        fi
        tries=$((tries + 1))
        sleep 0.5
    done
    return 1
}

in_sink() {
    sink_message "$1" >/dev/null
}

use_sink() {
    dc exec -T mailserver postconf -e 'relayhost=[mailpit]:1025'
    dc exec -T mailserver postfix reload >/dev/null 2>&1
}

secret_sum() {
    dc exec -T mailserver sha256sum /var/lib/postsrsd/secret
}

cert_sum() {
    dc exec -T mailserver sha256sum /etc/postfix-tls/cert.pem
}

trap cleanup EXIT
cleanup

echo "# Rejected configuration"
# Each value holds a marker that must never reach the logs.
for rules in \
    'zzprivate' \
    '@a.test:zzprivate' \
    'zzprivate@b.test' \
    '@a.test:zzprivate@b.test;' \
    ';@a.test:zzprivate@b.test' \
    '@a.test:zzprivate@b.test;;@b.test:zzprivate@b.test' \
    '@a.test:zzprivate@b.test extra' \
    '@a.test:zzprivate@b.test$(id)' \
    '*@a.test:zzprivate@b.test' \
    '@a.test:zz,private@b.test' \
    '@a.test:zzprivate@b.test:c@d.test' \
    'x@@a.test:zzprivate@b.test' \
    '@nodot:zzprivate@b.test' \
    '@a.test:zzprivate@b.test
@c.test:zzprivate@b.test'; do
    output=$(dc run --rm --no-deps -T -e "FORWARD_RULES=$rules" mailserver 2>&1)
    status=$?
    label=$(printf '%s' "$rules" | tr '\n' '~')
    if [ "$status" -ne 0 ] && lacks "$output" 'zzprivate'; then
        ok "FORWARD_RULES refused without printing it: $label"
    else
        not_ok "FORWARD_RULES refused without printing it: $label (exit $status)"
    fi
done

output=$(dc run --rm --no-deps -T -e FORWARD_RULES= mailserver 2>&1)
status=$?
check "empty FORWARD_RULES refused" test "$status" -ne 0
output=$(dc run --rm --no-deps -T -e MAIL_HOSTNAME= mailserver 2>&1)
status=$?
check "empty MAIL_HOSTNAME refused" test "$status" -ne 0
output=$(dc run --rm --no-deps -T -e 'MAIL_HOSTNAME=mail.smf.test extra' mailserver 2>&1)
status=$?
check "malformed MAIL_HOSTNAME refused" test "$status" -ne 0
output=$(dc run --rm --no-deps -T -e SRS_DOMAIN= mailserver 2>&1)
status=$?
check "empty SRS_DOMAIN refused" test "$status" -ne 0
output=$(dc run --rm --no-deps -T -e 'SRS_DOMAIN=srs.test"' mailserver 2>&1)
status=$?
check "malformed SRS_DOMAIN refused" test "$status" -ne 0

echo "# Start"
if ! dc up -d --wait --wait-timeout 60 mailserver mailpit client >/dev/null 2>&1; then
    not_ok "stack starts and becomes healthy"
    dc ps -a
    logs
    exit 1
fi
ok "stack starts and becomes healthy"
use_sink

echo "# Forwarding"
reply=$(send alice@b.test catchall@a.test smoke-catchall)
check "catch-all mail is accepted" has "$reply" '250 2\.0\.0 Ok: queued'
check "catch-all mail reaches the sink" in_sink smoke-catchall
check "catch-all mail goes to its rule's target" \
    in_logs 'to=<one@example\.com>, orig_to=<catchall@a\.test>.*status=sent'

send alice@b.test vip@a.test smoke-specific >/dev/null
check "user@domain overrides the catch-all" \
    in_logs 'to=<three@example\.com>, orig_to=<vip@a\.test>.*status=sent'

send alice@b.test other@b.test smoke-second-rule >/dev/null
check "second domain uses its own target" \
    in_logs 'to=<two@example\.com>, orig_to=<other@b\.test>.*status=sent'

echo "# SRS"
raw=$(sink_message smoke-catchall | tr -d '\r')
return_path=$(printf '%s\n' "$raw" | sed -n 's/^Return-Path: <\(.*\)>$/\1/p' | head -n 1)
check "envelope sender is rewritten to SRS0" has "$return_path" '^SRS0=[^=]+=[^=]+=b\.test=alice@srs\.test$'

send carol@a.test "$return_path" smoke-srs-reverse >/dev/null
check "mail to an SRS address is reversed to the original sender" \
    in_logs "to=<two@example\.com>, orig_to=<SRS0=.*alice@srs\.test>.*status=sent"

echo "# Backscatter"
reply=$(send '' empty@a.test smoke-empty-sender)
check "empty-sender mail is accepted" has "$reply" '250 2\.0\.0 Ok: queued'
check "empty-sender mail is discarded" in_logs 'orig_to=<empty@a\.test>.*relay=none.*status=sent \(empty sender\)'
send alice@b.test after-empty@a.test smoke-after-empty >/dev/null
in_sink smoke-after-empty
found=$(dc exec -T client wget -qO- 'http://mailpit:8025/api/v1/search?query=subject:smoke-empty-sender')
check "empty-sender mail doesn't reach the sink" lacks "$found" '"ID":"'

echo "# Refusals"
reply=$(smtp "EHLO client.test" "MAIL FROM:<alice@b.test>" "RCPT TO:<victim@elsewhere.test>" QUIT)
check "mail for another domain is refused" has "$reply" '454 4\.7\.1 .*Relay access denied|554 5\.7\.1 .*Relay access denied'

server_ip=$(dc exec -T mailserver hostname -i | awk '{print $1}')
reply=$(smtp "EHLO client.test" "MAIL FROM:<alice@b.test>" "RCPT TO:<root@localhost>" QUIT)
check "root@localhost is refused" has "$reply" 'Relay access denied'
reply=$(smtp "EHLO client.test" "MAIL FROM:<alice@b.test>" "RCPT TO:<root@[$server_ip]>" QUIT)
check "root@[server address] is refused" has "$reply" '5[0-9][0-9] 5\.[0-9]\.[0-9]'

reply=$(smtp "EHLO client.test" "MAIL FROM:<nobody@does-not-exist.invalid>" "RCPT TO:<x@a.test>" QUIT)
check "unknown sender domain is refused" has "$reply" 'Sender address rejected'

reply=$(smtp "EHLO client.test" "VRFY catchall@a.test" QUIT)
check "VRFY is refused" has "$reply" '502 5\.5\.1'
check "VRFY isn't advertised" lacks "$reply" '^250[ -]VRFY'

check "AUTH isn't advertised before STARTTLS" lacks "$reply" '^250[ -]AUTH'
check "STARTTLS is advertised" has "$reply" '^250[ -]STARTTLS'

reply=$(smtp_tls "EHLO client.test" QUIT)
check "STARTTLS works" has "$reply" '250[ -]mail\.smf\.test'
check "AUTH isn't advertised after STARTTLS" lacks "$reply" '^250[ -]AUTH'

for port in 465 587; do
    if dc exec -T client nc -z -w 2 mailserver "$port" 2>/dev/null; then
        not_ok "port $port is closed"
    else
        ok "port $port is closed"
    fi
done

echo "# Hardening"
check "postqueue -p works under no-new-privileges" dc exec -T mailserver postqueue -p
check "root filesystem is read-only" test "$(dc exec -T mailserver sh -c 'touch /usr/x 2>&1; echo $?' | tail -n 1)" -ne 0
srs_processes=$(dc exec -T mailserver ps -o user,comm | grep ' postsrsd$')
check "postsrsd is running" has "$srs_processes" 'postsrsd'
check "postsrsd doesn't run as root" lacks "$srs_processes" '^ *(root|0) '
reply=$(dc exec -T client nc -z -w 2 mailserver 10003 2>&1; echo "exit=$?")
check "postsrsd isn't reachable from outside the container" lacks "$reply" 'exit=0'
check "the Docker subnet isn't trusted" test "$(dc exec -T mailserver postconf -h mynetworks)" = '127.0.0.0/8'

echo "# postsrsd outage"
# Pauses the restart loop, so the outage lasts until the check is done.
srs_pid=$(dc exec -T mailserver pgrep -o postsrsd)
loop_pid=$(dc exec -T mailserver cut -d' ' -f4 "/proc/$srs_pid/stat")
dc exec -T mailserver kill -STOP "$loop_pid"
# Root has no CAP_KILL here, so only the postsrsd user can signal it. pkill also catches the
# forked children, which keep serving connections that idle smtpd processes still hold open.
dc exec -T -u postsrsd mailserver pkill postsrsd
# Nothing is queued here: the recipient lookup fails, so the sending server keeps the mail and retries.
reply=$(smtp "EHLO client.test" "MAIL FROM:<alice@b.test>" "RCPT TO:<outage@a.test>" QUIT)
check "the sender is told to retry while postsrsd is down" has "$reply" '^451 4\.3\.0'
dc exec -T mailserver kill -CONT "$loop_pid"
tries=0
until dc exec -T mailserver nc -z 127.0.0.1 10003 2>/dev/null || [ "$tries" -ge 20 ]; do
    tries=$((tries + 1))
    sleep 0.5
done
new_srs_pid=$(dc exec -T mailserver pgrep -o postsrsd)
check "postsrsd restarts by itself" test -n "$new_srs_pid" -a "$new_srs_pid" != "$srs_pid"
send alice@b.test outage@a.test smoke-outage >/dev/null
check "mail flows again when postsrsd returns" in_sink smoke-outage

echo "# Restart"
secret_before=$(secret_sum)
cert_before=$(cert_sum)
dc stop mailpit >/dev/null 2>&1
send alice@b.test queued@a.test smoke-queued >/dev/null
check "mail waits in the queue while the destination is down" \
    in_logs 'orig_to=<queued@a\.test>.*status=deferred'
dc restart mailserver >/dev/null 2>&1
dc up -d --wait --wait-timeout 60 mailserver >/dev/null 2>&1
check "SRS secret survives a restart" test "$(secret_sum)" = "$secret_before"
check "certificate survives a restart" test "$(cert_sum)" = "$cert_before"
queue=$(dc exec -T mailserver postqueue -p)
check "queue survives a restart" has "$queue" 'queued@a\.test|one@example\.com'
dc start mailpit >/dev/null 2>&1
dc up -d --wait --wait-timeout 60 mailpit >/dev/null 2>&1
use_sink
dc exec -T mailserver postqueue -f >/dev/null 2>&1
check "queued mail is delivered after the restart" in_sink smoke-queued

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
