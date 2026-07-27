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
