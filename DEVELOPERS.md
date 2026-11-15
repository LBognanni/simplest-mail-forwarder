# Developer notes

For running the image, see [README.md](README.md).

## How it works

Postfix and PostSRSd run in one container, with no process supervisor. `postfix start-fg` needs the Postfix
master to be PID 1, so no parent process can watch both programs. A small loop in `entrypoint.sh` stays
behind after the `exec` and restarts PostSRSd if it exits. PostSRSd listens on `127.0.0.1:10003`, reads
the root-only secret, then drops to its own user.

`/etc/postfix` is tmpfs at runtime, so the image keeps its templates in `/usr/local/etc/postfix`, and the
entrypoint copies them across on each start.

The UIDs and GIDs are fixed in the `Dockerfile`, so volumes keep working across rebuilds. Don't change them.

The healthcheck looks for the port 25 listener in `/proc/net/tcp`. It's silent, but it stays healthy if
`smtpd` is crash-looping or PostSRSd is down. `postfix status` logs a line per check, and `postqueue` exits
0 as root even with Postfix down.

To accept backscatter instead of discarding mail with an empty sender, remove the
`sender_dependent_default_transport_maps` line from `main.cf` and build your own image.

## Smoke test

```sh
docker build -t simplest-mail-forwarder:test .
test/smoke.sh
```

The smoke test sends real SMTP from a separate container, with the production hardening, into a
[Mailpit](https://mailpit.axllent.org/) sink. It takes about 2 minutes and needs outbound DNS for one check.
Set `IMAGE` to test another tag.

Keep the hardening in `test/compose.yml` and `deploy/compose.yml` in step. The README's examples should
match them too.

## Image scanning

```sh
docker save -o test/image.tar simplest-mail-forwarder:test
docker compose -f test/compose.yml --profile scan run --rm trivy
```

Trivy fails on fixable HIGH or CRITICAL findings.

## CI

CI rebuilds the image weekly and on every push to `main`, then tests and scans it. If those pass, it
publishes `latest` and a versioned tag (`<yyyy-mm-dd>.<run number>.<run attempt>`) with build provenance,
and creates a GitHub release of the same name that records the image digest. Pull requests build and
test, but never publish. Dependabot proposes updates to the base image, Mailpit, Trivy and the pinned actions.

CI doesn't deploy or announce new images. GitHub also disables scheduled workflows after 60 days without
repository activity, so check that the weekly build is still running.

## Public repo

This repo is public. Use `example.com` and `*.test` addresses in tests, and never commit real forwarding
targets, secrets or personal data.
