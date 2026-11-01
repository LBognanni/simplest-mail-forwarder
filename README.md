# simplest-mail-forwarder

A small mail server that forwards all mail sent to your domains on to other addresses. It only forwards:
it doesn't store mail, and you can't log in to it or send mail through it.

## Before you start

You need a server that can send and receive email on port 25, which many cloud providers block by default.
You also need these DNS records:

| Record | Example |
|---|---|
| A | `mail.example.com` → your server's IP |
| MX, for each domain | `example.com` → `10 mail.example.com` |
| TXT | `example.com` → `v=spf1 ip4:<your server's IP> ~all` |
| PTR, set with your hosting provider | your server's IP → `mail.example.com` |

## Running with `docker run`

```sh
docker run -d --name mailserver \
  --hostname mail.example.com \
  --restart unless-stopped \
  -p 25:25 \
  -e MAIL_HOSTNAME=mail.example.com \
  -e 'FORWARD_RULES=@example.com:someone@example.net' \
  -e SRS_DOMAIN=example.com \
  -v postfix-spool:/var/spool/postfix \
  -v mail-tls:/etc/postfix-tls \
  -v srs-secret:/var/lib/postsrsd \
  --tmpfs /run --tmpfs /tmp --tmpfs /etc/postfix --tmpfs /var/lib/postfix \
  --read-only \
  --cap-drop ALL \
  --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add SETGID --cap-add SETUID \
  --security-opt no-new-privileges \
  --pids-limit 200 \
  --memory 256m \
  ghcr.io/lbognanni/simplest-mail-forwarder:latest
```

## Running with Docker Compose

```yaml
services:
  mailserver:
    image: ghcr.io/lbognanni/simplest-mail-forwarder:latest
    hostname: mail.example.com
    restart: unless-stopped
    ports:
      - "25:25"
    environment:
      - MAIL_HOSTNAME=mail.example.com
      - FORWARD_RULES=@example.com:someone@example.net
      - SRS_DOMAIN=example.com
    volumes:
      - postfix-spool:/var/spool/postfix
      - mail-tls:/etc/postfix-tls
      - srs-secret:/var/lib/postsrsd
    tmpfs:
      - /run
      - /tmp
      - /etc/postfix
      - /var/lib/postfix
    read_only: true
    cap_drop: [ALL]
    cap_add: [CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID]
    security_opt:
      - no-new-privileges:true
    pids_limit: 200
    mem_limit: 256m

volumes:
  postfix-spool:
  mail-tls:
  srs-secret:
```

## Configuration

All three settings are required.

| Setting | Example | Notes |
|---|---|---|
| `MAIL_HOSTNAME` | `mail.example.com` | Your server's name, the same as its A and PTR records |
| `FORWARD_RULES` | `@foo.com:alice@bar.net;info@foo.com:bob@bar.net` | Where to forward mail. Separate rules with `;` |
| `SRS_DOMAIN` | `foo.com` | One of your domains, with the MX and TXT records above |

`@foo.com:alice@bar.net` forwards everything sent to `foo.com`. `info@foo.com:bob@bar.net` forwards
only that address, and takes priority over a rule for the whole domain. Each rule has one destination.

Back up the `srs-secret` volume, because losing it can break replies to recently forwarded mail.

## Limitations

- **No "undeliverable" notices.** If your inbox provider refuses a message, the sender isn't told.
- **Some automatic replies are lost.** If you send mail from a forwarded address, you may not receive
  automatic replies to it, such as out-of-office messages, read receipts or "undeliverable" notices.
- **No spam filter.** Your inbox provider's spam filter does that job.

## Updating and troubleshooting

To update, run `docker compose pull`, then `docker compose up -d mailserver`. Your server doesn't update by
itself, so do this now and then to pick up security fixes.

If mail stops arriving, read the logs with `docker compose logs -f mailserver`. See mail waiting to be
delivered with `docker compose exec mailserver postqueue -p`.

## More

- Developer notes: [DEVELOPERS.md](DEVELOPERS.md)
- Licence: [GNU Affero General Public License v3.0](LICENSE)
