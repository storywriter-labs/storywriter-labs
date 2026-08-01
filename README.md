# StoryWriter Labs

The [Ghost CMS](https://ghost.org) site at **labs.storywriter.net** — its theme,
its Ghost settings, and the Terraform for the dedicated `t4g.micro` EC2 instance
it runs on.

Kept in its own repo, with its own Terraform state, so an `apply` here can never
affect the separate Laravel API that powers the StoryWriter app.

**Ghost version on the box: 6.x** (check with `ghost version` in `/var/www/ghost`;
update this line when you `ghost update`).

## Scope: what is and isn't version-controlled

Three things live here, and nothing else:

| In the repo | Not in the repo |
| --- | --- |
| `theme/` — the Handlebars theme (deployed by CI) | Ghost core — installed and updated by `ghost-cli` |
| `ghost/` — `routes.yaml`, `redirects.yaml`, a code-injection mirror | Content: posts, members, images (MySQL + `content/`) |
| `terraform/` — the AWS bones | `config.production.json` — DB and mail credentials |

Ghost core is deliberately absent. `ghost-cli` owns `/var/www/ghost` as versioned
directories behind a `current` symlink and runs MySQL migrations on `ghost update`;
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

## Install Ghost (manual, once)

SSH in and follow <https://docs.ghost.org/install/ubuntu>:

1. Create a non-root `ghost-mgr` user; install MySQL 8, Node.js 20, nginx.
2. `sudo npm install -g ghost-cli@latest`
3. `sudo mkdir -p /var/www/ghost && sudo chown ghost-mgr:ghost-mgr /var/www/ghost && cd /var/www/ghost`
4. `ghost install` — URL `https://labs.storywriter.net`, DB MySQL; let it set up
   nginx + Let's Encrypt SSL when prompted.

The 2 GB swap file is created automatically on first boot (`user-data.sh`);
confirm with `swapon --show` before running `ghost install`. MySQL 8 and Node
will OOM on a 1 GB instance without it.

## Local nginx change: lazy DNS for `ap.ghost.org`

**This lives only on the box.** It is not in this repo and no automation restores
it. Re-apply it by hand if it is ever lost — see "when it gets reverted" below.

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
`/etc/systemd/system/nginx.service.d/10-restart.conf`:

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
  (`routes.yaml` can also be copied to `content/settings/routes.yaml` + `ghost restart`.)
- `code-injection.md` — paste into Admin → Settings → **Code injection**.

## Backups

- Daily EBS snapshot lifecycle (AWS Backup) on the root volume — pennies/month.
- Optional: weekly `ghost backup` zip pushed to S3.

## Teardown caveat

`terraform destroy` releases the Elastic IP and deletes the A record, so the
site's public IP is **not** recoverable afterwards — anything pointing at that
IP breaks. Snapshot the root volume first if the content matters.

## Cost

An on-demand `t4g.micro` plus a 20 GB gp3 root volume runs a few dollars a
month. For a box you're keeping, an EC2 Instance Savings Plan (t4g family, same
region) cuts that meaningfully — worth buying after a couple of days of real
usage data, not up front.

## License

MIT — see [LICENSE](LICENSE).
