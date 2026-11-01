FROM alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

# The queue and SRS secret live on volumes across image rebuilds, so these IDs must never change.
# Alpine's package scripts keep accounts that already exist.
RUN addgroup -S -g 200 postfix \
 && addgroup -S -g 201 postdrop \
 && addgroup -S -g 202 postsrsd \
 && adduser -S -D -H -u 200 -G postfix -h /var/spool/postfix -s /sbin/nologin postfix \
 && adduser -S -D -H -u 202 -G postsrsd -h /var/lib/postsrsd -s /sbin/nologin postsrsd \
 && apk upgrade --no-cache \
 && apk add --no-cache ca-certificates openssl postfix postsrsd

COPY rootfs/ /

# /etc/postfix is tmpfs at runtime, which hides everything in it. Keep what Postfix still needs.
RUN cp -R /etc/postfix/dynamicmaps.cf /etc/postfix/dynamicmaps.cf.d \
          /etc/postfix/postfix-files /etc/postfix/postfix-files.d \
          /usr/local/etc/postfix/ \
 && install -d -o root -g root -m 0700 /var/lib/postsrsd \
 && install -d -o root -g root -m 0755 /etc/postfix-tls

EXPOSE 25

# Checks for the port 25 listener. `postfix status` logs a line on every check, connecting to
# the port logs two, and postqueue reports success as root even when Postfix is down.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --start-interval=1s --retries=3 \
    CMD grep -q ' 00000000:0019 00000000:0000 0A ' /proc/net/tcp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
