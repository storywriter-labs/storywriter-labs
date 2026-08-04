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
| `nginx-labs.storywriter.net.conf` | `/etc/nginx/sites-available/labs.storywriter.net.conf` | Hand-edited (lazy DNS) — **not yet on the box**, see below |
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

## Pending: the port-80 fix is in this repo but not on the box

⚠️ **`nginx-labs.storywriter.net.conf` here is ahead of the box.** Until it is
applied, the drift check above will report a difference for that one file. That
is expected, and this is the only file it applies to.

The box still runs the stock version, whose ActivityPub blocks use a literal
upstream:

```nginx
proxy_pass https://ap.ghost.org;      # still live on the box
```

nginx parses every enabled site before it serves anything, so a literal hostname
in *any* of them is resolved at startup. A DNS failure there still aborts the
whole process with `[emerg] host not found in upstream "ap.ghost.org"`, exactly
as on 2026-07-29. The fix in the `-ssl` file does not cover this, because the
risk is per-config-file, not per-request. Both files are symlinked into
`sites-enabled/`, so both must be fixed.

The restart drop-in already limits the damage — systemd retries every 5s, so the
box recovers once DNS does instead of staying down for two days. The trigger
itself stays open until this is applied.

To apply, from the repo root:

```bash
scp -i ~/.ssh/storywriter-labs-ec2 box/nginx-labs.storywriter.net.conf \
  ubuntu@labs.storywriter.net:/tmp/labs-port80.conf

ssh -i ~/.ssh/storywriter-labs-ec2 ubuntu@labs.storywriter.net '
  sudo cp -a /etc/nginx/sites-available/labs.storywriter.net.conf \
             /root/labs.storywriter.net.conf.bak-$(date +%F) &&
  sudo install -o root -g root -m 644 /tmp/labs-port80.conf \
    /etc/nginx/sites-available/labs.storywriter.net.conf &&
  sudo nginx -t && sudo systemctl reload nginx'
```

`nginx -t` runs before the reload and `&&` stops the chain if it fails, so a bad
config never reaches a running nginx. The backup in `/root` is the way back.

Then confirm both ports still proxy federation, and delete this section:

```bash
curl -s -o /dev/null -w 'https %{http_code}\n' \
  "https://labs.storywriter.net/.well-known/webfinger?resource=acct:index@labs.storywriter.net"
curl -s -o /dev/null -w 'http  %{http_code}\n' \
  "http://labs.storywriter.net/.well-known/webfinger?resource=acct:index@labs.storywriter.net"
```
