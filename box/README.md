# Box-local config (`box/`)

Mirrors of files that live **only** on the EC2 instance. Nothing here deploys.
No CI job reads this directory, and no Terraform resource writes these files.

They are kept for the same reason as `ghost/` — Ghost and `ghost-cli` own these
paths, so there is no supported deploy path. Mirroring them means a restore is a
copy rather than a retype, a change shows up in a diff, and drift can be
detected. The reasoning behind each change is in the repo `README.md`; this
directory holds the bytes.

| File here | Goes to | Ours? |
| --- | --- | --- |
| `nginx-labs.storywriter.net-ssl.conf` | `/etc/nginx/sites-available/labs.storywriter.net-ssl.conf` | Hand-edited (lazy DNS) |
| `nginx-labs.storywriter.net.conf` | `/etc/nginx/sites-available/labs.storywriter.net.conf` | Hand-edited (lazy DNS) |
| `systemd-nginx-10-restart.conf` | `/etc/systemd/system/nginx.service.d/10-restart.conf` | Ours, created by hand |

Both nginx files are symlinked into `sites-enabled/`. `ghost setup`,
`ghost setup nginx` and `ghost setup ssl` regenerate them from the stock
template and drop the edits. `ghost update` does not.

## Check for drift

```bash
ssh -i ~/.ssh/storywriter-labs-ec2 ubuntu@labs.storywriter.net \
  'sudo md5sum /etc/nginx/sites-available/labs.storywriter.net-ssl.conf \
               /etc/nginx/sites-available/labs.storywriter.net.conf \
               /etc/systemd/system/nginx.service.d/10-restart.conf'
md5sum box/*.conf
```

Same hashes, in the same file order, means the box matches this directory. If
they differ, work out which side is right before you copy either way — the box
may hold a fix nobody mirrored yet.

## Restore

nginx:

```bash
scp -i ~/.ssh/storywriter-labs-ec2 box/nginx-labs.storywriter.net-ssl.conf \
  ubuntu@labs.storywriter.net:/tmp/
ssh -i ~/.ssh/storywriter-labs-ec2 ubuntu@labs.storywriter.net '
  sudo install -o root -g root -m 644 /tmp/nginx-labs.storywriter.net-ssl.conf \
    /etc/nginx/sites-available/labs.storywriter.net-ssl.conf &&
  sudo nginx -t && sudo systemctl reload nginx'
```

systemd (note the `daemon-reload` — without it the drop-in is ignored):

```bash
scp -i ~/.ssh/storywriter-labs-ec2 box/systemd-nginx-10-restart.conf \
  ubuntu@labs.storywriter.net:/tmp/
ssh -i ~/.ssh/storywriter-labs-ec2 ubuntu@labs.storywriter.net '
  sudo mkdir -p /etc/systemd/system/nginx.service.d &&
  sudo install -o root -g root -m 644 /tmp/systemd-nginx-10-restart.conf \
    /etc/systemd/system/nginx.service.d/10-restart.conf &&
  sudo systemctl daemon-reload'
```

## Verify

```bash
# nginx starts, and webfinger keeps its query string
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://labs.storywriter.net/.well-known/webfinger?resource=acct:index@labs.storywriter.net"

# restart policy is live
systemctl show nginx -p Restart -p RestartUSec -p StartLimitIntervalUSec
# expect: Restart=on-failure  RestartUSec=5s  StartLimitIntervalUSec=0
```

## Both nginx files need the fix, not just the `-ssl` one

Easy to get wrong, and it was wrong on the box until 2026-08-05: the lazy-DNS
edit went into `labs.storywriter.net-ssl.conf` only, and the port-80 file kept a
literal upstream:

```nginx
proxy_pass https://ap.ghost.org;
```

That is enough to keep the whole 2026-07-29 failure alive. nginx parses every
enabled site before it serves anything, so a literal hostname in *any* of them
is resolved at startup, and one failed lookup aborts the process with
`[emerg] host not found in upstream "ap.ghost.org"`. The risk is
per-config-file, not per-request. Both files are symlinked into
`sites-enabled/`, so both carry the fix now — keep it that way.

`ghost setup ssl` regenerates them from the stock template, so this is exactly
the pair to re-check afterwards.

Old `.bak` copies in `sites-available/` are harmless: `nginx.conf` includes
`sites-enabled/*` only, and nothing symlinks them.
