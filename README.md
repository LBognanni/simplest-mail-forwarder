# simplest-mail-forwarder

A small container image that forwards all mail for your domains to other addresses. It runs Postfix and
PostSRSd on Alpine, with no login, no submission port and no DKIM. It only forwards.

Both run in one container, with no process supervisor. The Postfix master is PID 1, and a small loop in
the entrypoint restarts PostSRSd if it exits. PostSRSd listens on localhost only and runs as its own user.

## Usage

Use [`deploy/compose.yml`](deploy/compose.yml) as your starting point. Copy `deploy/.env.example` to
`.env`, fill it in, then run `docker compose up -d`. Pin `IMAGE` by digest.

| Variable | Example | Notes |
|---|---|---|
| `MAIL_HOSTNAME` | `mail.example.com` | Required. Should match the server's reverse DNS |
| `FORWARD_RULES` | `@a.example:x@b.example;info@c.example:y@d.example` | Required. Rules separated by `;` |
| `SRS_DOMAIN` | `a.example` | Required. Must have an MX pointing at this server and an SPF record allowing it |

Each rule is `@domain:address` for a catch-all, or `user@domain:address` for one address. A `user@domain`
rule overrides a catch-all. If a domain only has `user@domain` rules, other addresses there are refused.

Each rule forwards to one address. Any invalid rule stops the container, and the value is never logged.

## What it won't do

**It discards all mail with an empty envelope sender.** A catch-all accepts everything, so when a
destination later rejects spam, a bounce to the forged sender would harm this IP's reputation. The cost
is that genuine senders aren't told if the destination rejects their mail, and auto-replies or receipts
sent with an empty sender are lost. To accept the backscatter instead, remove the
`sender_dependent_default_transport_maps` line from `main.cf`.

**There's no spam filtering or inbound SPF checking**, and the certificate on port 25 is self-signed. TLS
is opportunistic, which suits server-to-server mail unless you use MTA-STS or DANE.

**Mail stops if PostSRSd is down, but isn't lost.** Postfix answers `451`, and senders retry later.

## Operations

- Queue: `docker compose exec mailserver postqueue -p`
- Retry the queue now: `docker compose exec mailserver postqueue -f`
- Logs: `docker compose logs -f mailserver`

To update, change the digest and run `docker compose up -d mailserver`. The queue is on a volume, and
senders retry during the short restart.

Back up the `srs-secret` volume. Losing it breaks replies to in-flight SRS addresses, though new mail
keeps working. The UIDs and GIDs are fixed in the `Dockerfile`, so volumes keep working across rebuilds.
Don't change them.

## Images

CI rebuilds the image weekly and on every push to `main`, then tests and scans it. It publishes
`ghcr.io/lbognanni/simplest-mail-forwarder:<yyyy-mm-dd>` and `:latest` with build provenance:

```
gh attestation verify oci://ghcr.io/lbognanni/simplest-mail-forwarder@sha256:... --owner LBognanni
```

CI doesn't deploy or announce new images. GitHub also disables scheduled workflows after 60 days without
repository activity, so check that the weekly build is still running.

## Development

```
docker build -t simplest-mail-forwarder:test .
test/smoke.sh
```

The smoke test sends real SMTP from a separate container, with the production hardening, into a
[Mailpit](https://mailpit.axllent.org/) sink. It needs outbound DNS for one check.

To scan a local build:

```
docker save -o test/image.tar simplest-mail-forwarder:test
docker compose -f test/compose.yml --profile scan run --rm trivy
```

This repo is public. Use `example.com` and `*.test` addresses in tests, and never commit real forwarding
targets, secrets or personal data.

## Licence

[GNU Affero General Public License v3.0](LICENSE).
