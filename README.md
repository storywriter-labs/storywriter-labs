# StoryWriter Labs

The [Ghost CMS](https://ghost.org) site at **labs.storywriter.net** — its theme,
its Ghost settings, and the Terraform for the dedicated `t4g.micro` EC2 instance
it runs on.

Kept in its own repo, with its own Terraform state, so an `apply` here can never
affect the separate Laravel API that powers the StoryWriter app.

**Ghost version on the box: 6.x** (check with `ghost version` in
`/var/www/storywriter-labs`; update this line when you `ghost update`).

## Scope: what is and isn't version-controlled

Four things live here, and nothing else:

| In the repo | Not in the repo |
| --- | --- |
| `theme/` — the Handlebars theme (deployed by CI) | Ghost core — installed and updated by `ghost-cli` |
| `ghost/` — `routes.yaml`, `redirects.yaml`, a code-injection mirror | Content: posts, members, images (MySQL + `content/`) |
| `terraform/` — the AWS bones | `config.production.json` — DB and mail credentials |
| `box/` — mirrors of the hand-edited nginx and systemd files | Everything else on the box — packages, certs, MySQL |

Only `theme/` deploys automatically. `ghost/` and `box/` are mirrors: Ghost and
`ghost-cli` own those paths, so they are uploaded or copied by hand, and kept
here so a change is reviewable and a restore is a copy rather than a retype.

Ghost core is deliberately absent. `ghost-cli` owns `/var/www/storywriter-labs` as
versioned directories behind a `current` symlink and runs MySQL migrations on `ghost update`;
there is no supported "deploy Ghost from git" path for a `ghost-cli` install, so
committing core would mean version-controlling a directory we don't control.
`ghost update` is the upgrade mechanism, `ghost update --rollback` the escape hatch.

Likewise Ghost itself (MySQL, Node, nginx, Let's Encrypt SSL) is installed
manually with `ghost-cli` rather than from `user_data` — the only install path
Ghost supports; wrapping it would mean maintaining an unsupported
reimplementation of their installer for no real gain on a single-instance blog.

The consequence: **re-running Terraform is not the disaster recovery plan.**
Recovery comes from EBS snapshots plus Ghost's own JSON/zip exports. Terraform
rebuilds the box; the snapshot restores the site.

```
labs/
  theme/                     the storywriter-labs theme — see theme/README.md
  ghost/
    routes.yaml              URL structure / collections — upload via admin
    redirects.yaml           301s and 302s — upload via admin
    code-injection.md        mirror of Admin -> Settings -> Code injection
  .github/workflows/
    deploy-theme.yml         build + gscan + push theme on merge to main
  terraform/
    main.tf                  provider + terraform block
    backend.tf               S3 remote state (key: environments/labs/...)
    backend.hcl.example      copy to backend.hcl — account-specific state bucket
    variables.tf
    ghost.tf                 key pair, SG, EIP, EC2 instance, EIP assoc, Route 53 record
    user-data.sh             minimal first-boot: creates swap only
    outputs.tf
    terraform.tfvars.example copy to terraform.tfvars and fill in
```

## Prerequisites

- **Terraform >= 1.10** — the S3 backend uses native `use_lockfile` state
  locking, which doesn't exist in earlier versions.
- **An S3 bucket for remote state, already created.** This repo does not
  bootstrap one; it reuses an existing bucket under its own key.
- **An existing VPC, public subnet, and Route 53 hosted zone.** These are read
  as data sources, never created — so a `destroy` here can't take them out.
- AWS credentials with EC2, Elastic IP, Route 53 and S3 access.

## Provision the AWS bones

```bash
# 1. Generate a dedicated key pair for this box (private key stays local):
ssh-keygen -t ed25519 -f ~/.ssh/storywriter-labs-ec2 -C storywriter-labs

cd terraform

# 2. Point Terraform at your state bucket:
cp backend.hcl.example backend.hcl   # then edit: bucket name, AWS profile

# 3. Fill in the variables:
cp terraform.tfvars.example terraform.tfvars
#    - paste ~/.ssh/storywriter-labs-ec2.pub into ssh_public_key
#    - set vpc_id / subnet_id / route53_zone_id
#    - list your trusted IPs (one /32 each) in allowed_ssh_cidrs

terraform init -backend-config=backend.hcl
terraform plan      # expect ~6 adds (key pair, SG, EIP, instance, EIP assoc, A record)
terraform apply
```

Verify:

```bash
dig +short labs.storywriter.net     # → the new Elastic IP
```

Both `backend.hcl` and `terraform.tfvars` are gitignored — they hold
account-specific identifiers and shouldn't be committed.

## Getting onto the box

```bash
ssh -i ~/.ssh/storywriter-labs-ec2 ubuntu@labs.storywriter.net
```

**The SSH user is `ubuntu`.** Neither `ghost` nor `ghost-mgr` accepts a
connection: `ghost` is a no-login system account that only runs the Node process,
and `ghost-mgr` owns the install but has no key in its `authorized_keys`. Switch
after you connect:

```bash
sudo -u ghost-mgr bash          # to run ghost-cli commands
```

Access is limited to the `/32`s in `allowed_ssh_cidrs` (`terraform.tfvars`), so
add your address there first if the connection times out.

⚠️ **`ghost restart` fails over SSH** with *"Prompts have been disabled, all
options must be provided via command line flags"*, with or without a TTY. Restart
the service directly instead:

```bash
sudo systemctl restart ghost_labs-storywriter-net.service
```

## Install Ghost (manual, once)

SSH in and follow <https://docs.ghost.org/install/ubuntu>:

1. Create a non-root `ghost-mgr` user; install MySQL 8, Node.js 20, nginx.
2. `sudo npm install -g ghost-cli@latest`
3. `sudo mkdir -p /var/www/storywriter-labs && sudo chown ghost-mgr:ghost-mgr /var/www/storywriter-labs && cd /var/www/storywriter-labs`
4. `ghost install` — URL `https://labs.storywriter.net`, DB MySQL; let it set up
   nginx + Let's Encrypt SSL when prompted.

The install directory is `/var/www/storywriter-labs`, **not** `/var/www/ghost` —
the path most Ghost docs use. `/var/www/ghost` does not exist on this box.

The 2 GB swap file is created automatically on first boot (`user-data.sh`);
confirm with `swapon --show` before running `ghost install`. MySQL 8 and Node
will OOM on a 1 GB instance without it.

## Transactional email

Ghost sends transactional mail — member sign-in links, staff invites, password
resets — through the **AWS SES SMTP interface in `us-east-2`**. The box itself is
in `us-east-1`; the cross-region hop is irrelevant at this volume.

The config lives on the box in `/var/www/storywriter-labs/config.production.json`
and is **not** in this repo — it holds the SMTP password:

```json
"mail": {
  "transport": "SMTP",
  "options": {
    "host": "email-smtp.us-east-2.amazonaws.com",
    "port": 587,
    "secure": false,
    "requireTLS": true,
    "auth": { "user": "<access-key-id>", "pass": "<derived-smtp-password>" }
  },
  "from": "'StoryWriter Labs' <no-reply@labs.storywriter.net>"
}
```

⚠️ **Never add `"service": "SES"` to `mail.options`.** Nodemailer treats `service`
as a well-known preset, and the preset **overrides** an explicit `host` and
`port` — silently repointing Ghost at `email-smtp.us-east-1.amazonaws.com:465`.
The result is `535 Invalid login`, which reads like a bad password when in fact
the credentials are fine and the endpoint is wrong. Set `host`, `port` and `auth`
only. This cost real debugging time in August 2026.

### Credentials

The IAM user `storywriter-labs-ses-smtp` exists only to send this mail. Its inline
policy `ses-send-labs-subdomain` allows `ses:SendRawEmail` and `ses:SendEmail` on
the `storywriter.net` identity, but **only** where the From address matches
`*@labs.storywriter.net`. Sending as any other address on the domain fails at SMTP
time with `554 Access denied` — deliberate, so a compromise of this box cannot
send as the main app.

SMTP credentials are not the IAM secret key. The password is derived from it with
the SigV4-based algorithm AWS documents, keyed to the region — a `us-east-1`
password will not authenticate against `us-east-2`. To rotate: create a new access
key, re-derive, update the config, restart, then delete the old key.

### Monitoring

Two CloudWatch alarms in `us-east-2` publish to the SNS topic
`storywriter-ses-alerts`:

| Alarm | Metric | Fires above |
| --- | --- | --- |
| `ses-bounce-rate-high` | `Reputation.BounceRate` | 5% (AWS pauses sending near 10%) |
| `ses-complaint-rate-high` | `Reputation.ComplaintRate` | 0.1% (AWS pauses near 0.5%) |

Both sit at `INSUFFICIENT_DATA` until there is enough volume for SES to publish a
reputation figure; missing data is treated as not-breaching, so they stay quiet.

⚠️ **These are account-wide, not labs-only.** SES reputation is shared by
everything sending as `storywriter.net`, including the main app. A bounce problem
here degrades deliverability there, which is why the alarms are worth having on a
low-traffic blog.

Notes that save time later:

- **No DNS or identity work is needed for this subdomain.** The SES domain
  identity is `storywriter.net`, and a domain identity authorises every
  subdomain. DKIM is signed with the parent key, which satisfies relaxed DMARC
  alignment for a `labs.storywriter.net` From address.
- **The sender address appears in two places.** `mail.from` above covers staff
  mail. Member-facing mail uses Ghost's own *support address*
  (Admin → Settings → Portal), which defaults to the bare string `noreply` and
  expands against the site domain. Set both to the same address or they diverge.
- **Newsletters cannot use SES.** Ghost 6 ships exactly one bulk-email provider,
  `mailgun-email-provider.js`. SES covers transactional mail only; bulk sending
  needs Mailgun credentials.
- **Check sends in CloudWatch, not `sesv2 get-account`.** The `AWS/SES` metrics
  `Send`, `Delivery` and `Bounce` in `us-east-2` are authoritative and appear
  within a few minutes. `SentLast24Hours` is unreliable — it stayed at `0`
  throughout testing.

Verify the transport without sending anything — build the transport, read back the
resolved host, then authenticate:

```js
const t = nodemailer.createTransport(cfg.mail.options);
console.log(t.transporter.options.host, t.transporter.options.port);  // must match the config
await t.verify();                                                     // must not throw
```

## Local nginx change: lazy DNS for `ap.ghost.org`

**This lives only on the box**, and no automation restores it. The file is
mirrored at [`box/nginx-labs.storywriter.net-ssl.conf`](box/) — copy it back
rather than retyping it from the snippets below. This section explains *why* the
file looks the way it does; [`box/README.md`](box/README.md) covers restoring it,
checking it for drift, and one gap that is still open.

Ghost-CLI's stock nginx template proxies two ActivityPub path groups to Ghost's
hosted federation service at `ap.ghost.org`:

```nginx
location ~ /.ghost/activitypub/* { ... proxy_pass https://ap.ghost.org; }
location ~ /.well-known/(webfinger|nodeinfo) { ... proxy_pass https://ap.ghost.org; }
```

A **literal** hostname in `proxy_pass` makes nginx resolve it once, while parsing
the config. That has bitten us:

- **2026-07-29** — `unattended-upgrades` replaced `libc6` and restarted nginx.
  The glibc resolver was mid-upgrade, the lookup failed, and nginx aborted with
  `[emerg] host not found in upstream "ap.ghost.org"`. It never came back. The
  whole site was down for two days, including pages that never touch ActivityPub.
- The record has a **300s TTL**, but nginx pins the first IP until a reload, so
  federation would silently break whenever Ghost moves that endpoint.

The fix, in `/etc/nginx/sites-available/labs.storywriter.net-ssl.conf`, defers
the lookup to request time. In the `server` block:

```nginx
resolver 169.254.169.253 valid=30s ipv6=off;
resolver_timeout 5s;
```

and in **both** ActivityPub `location` blocks:

```nginx
proxy_ssl_server_name on;
proxy_ssl_name ap.ghost.org;
set $ap_upstream "ap.ghost.org";
proxy_pass https://$ap_upstream$request_uri;
```

Details that matter if you retype this:

- `169.254.169.253` is AmazonProvidedDNS. nginx does **not** read
  `/etc/resolv.conf`, so a resolver must be named. Prefer it over the
  systemd-resolved stub (`127.0.0.53`): resolution then does not depend on a
  local daemon that package upgrades restart — the exact 2026-07-29 trigger.
- `ipv6=off` — the instance has no global IPv6 address and `ap.ghost.org`
  publishes no AAAA record, so AAAA lookups can only stall or fail.
- `$request_uri`, **not** `$uri` — it keeps the query string. Webfinger is called
  as `?resource=acct:...`, so `$uri` would silently break federation.

After the change, a DNS failure returns 502 on those two paths only. nginx still
starts, and the rest of the site keeps serving.

The port-80 config, `labs.storywriter.net.conf`, needs the same edit — it is
enabled too, and one literal hostname anywhere in the loaded config is enough to
stop nginx from starting. The fixed file is in `box/`, still waiting to be
applied to the box; [`box/README.md`](box/README.md) has the command.

**When it gets reverted:** `ghost update` does *not* touch this file (the
ghost-cli nginx extension only implements a `setup()` hook). But `ghost setup`,
`ghost setup nginx`, and `ghost setup ssl` regenerate it from the stock template
and will drop these edits. Run `sudo nginx -t` after any of them.

Verify with:

```bash
sudo nginx -t && sudo systemctl reload nginx
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://labs.storywriter.net/.well-known/webfinger?resource=acct:index@labs.storywriter.net"
```

## Local systemd change: nginx restart policy

**Also lives only on the box**, at
`/etc/systemd/system/nginx.service.d/10-restart.conf`, mirrored here as
[`box/systemd-nginx-10-restart.conf`](box/):

```ini
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=on-failure
RestartSec=5s
```

Stock `nginx.service` ships `Restart=no`. That is the second half of the
2026-07-29 outage: nginx failed one start and nothing ever retried, so a
transient DNS error became a two-day outage. Ghost's own unit already has
`Restart=always`, which is exactly why Ghost recovered from the same event and
nginx did not.

Two decisions worth keeping:

- `on-failure`, not `always` — covers crashes and failed starts, but still lets
  `systemctl stop nginx` mean stop.
- `StartLimitIntervalSec=0` disables the start rate limiter, so systemd retries
  indefinitely. The default (5 starts per 10s, then give up permanently) would
  recreate the exact failure this guards against, only later. The trade is that
  a genuinely broken config retries every 5s and fills the journal — if nginx is
  flapping, check `journalctl -u nginx` rather than assuming a transient fault.

This is a drop-in under `/etc/systemd/system/`, so nginx package upgrades do not
touch it. It is independent of the lazy-DNS change above: lazy DNS removes one
cause of a failed start, this makes *any* failed start recoverable. Keep both.

Verify with:

```bash
systemctl show nginx -p Restart -p RestartUSec -p StartLimitIntervalUSec
# expect: Restart=on-failure  RestartUSec=5s  StartLimitIntervalUSec=0
```

## Theme deployment

The theme is the only part of this repo that deploys automatically. Merging to
`main` with changes under `theme/` runs `.github/workflows/deploy-theme.yml`,
which builds the assets, validates with `gscan --fatal`, and uploads the theme
over the Ghost **Admin API** — no SSH, no deploy key on the box.

One-time setup:

1. In Ghost Admin → Settings → **Integrations** → *Add custom integration*, name
   it "GitHub Actions" and copy the **Admin API key** (the `id:secret` pair).
2. Add two GitHub repo secrets:
   - `GHOST_ADMIN_API_URL` → `https://labs.storywriter.net`
   - `GHOST_ADMIN_API_KEY` → the Admin API key from step 1
3. Push. Then activate `storywriter-labs` once in Admin → Design; later deploys
   update the active theme in place.

Rolling back a bad theme deploy is `git revert` + push — Ghost keeps no theme
history of its own.

⚠️ **Don't edit theme code in Ghost Admin.** Ghost 6 lets you edit theme files
in the admin UI; anything changed there is silently overwritten by the next
deploy. Same for `routes.yaml` and code injection: those live in MySQL, so the
files in `ghost/` are only the source of truth if you keep them that way.

## Ghost settings (`ghost/`)

Not deployed by CI — Ghost has no API for these, so they're uploaded by hand and
mirrored here for review and restore:

- `routes.yaml` / `redirects.yaml` — Admin → Settings → Advanced → **Labs**, upload.
  (`routes.yaml` can also be copied to `content/settings/routes.yaml`, followed by
  a `systemctl restart` — see [Getting onto the box](#getting-onto-the-box).)
- `code-injection.md` — paste into Admin → Settings → **Code injection**.

## Backups

- Daily EBS snapshot lifecycle (AWS Backup) on the root volume — pennies/month.
- Optional: weekly `ghost backup` zip pushed to S3.

## Teardown caveat

`terraform destroy` releases the Elastic IP and deletes the A record, so the
site's public IP is **not** recoverable afterwards — anything pointing at that
IP breaks. Snapshot the root volume first if the content matters.

Any Terraform change that replaces the instance also discards everything Ghost
installed by hand, including the box-local files: the lazy-DNS nginx edit and the
nginx systemd restart drop-in. Terraform reports success, the site comes back,
and both fixes are silently gone — so the 2026-07-29 outage becomes possible
again. Restore them from [`box/`](box/README.md) on a rebuilt box.

## Cost

An on-demand `t4g.micro` plus a 20 GB gp3 root volume runs a few dollars a
month. For a box you're keeping, an EC2 Instance Savings Plan (t4g family, same
region) cuts that meaningfully — worth buying after a couple of days of real
usage data, not up front.

Email adds essentially nothing: the SES SMTP interface has no subscription fee and
costs $0.10 per 1,000 messages.

**Don't reach for SES Mail Manager for outbound mail.** Transactional sending was
briefly built on a Mail Manager AUTH ingress endpoint in July 2026. It worked, but
it was the wrong tool twice over:

- `USE2-IngressPoint-Subscription` bills at **$50/month per dedicated endpoint**,
  flat, regardless of volume — roughly ten times the cost of the server it served.
- Rule actions run *after* the endpoint returns `250 OK`, so a failed send could
  never be reported back to Ghost. With `ActionFailurePolicy: DROP` and no
  archiving, a message could vanish silently and no setting could prevent it.

Sending direct fixes both: no fee, and SES rejects a bad send synchronously with
an SMTP error that Ghost logs. Mail Manager earns its price on inbound processing,
rule sets and archiving — none of which a blog sending sign-in links needs.

## License

MIT — see [LICENSE](LICENSE).
