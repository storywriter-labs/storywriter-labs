# storywriter-labs theme

The Ghost theme for **labs.storywriter.net**. A fork of [Casper](https://github.com/TryGhost/Casper)
(Ghost Foundation, MIT — see [LICENSE](LICENSE)), taken from Casper 5.12.1.

Deployed automatically by `.github/workflows/deploy-theme.yml` on every push to
`main` that touches this directory. Do not edit theme code in Ghost Admin — the
next deploy overwrites it, and the repo stops describing the live site.

## Local development

You need a local Ghost to render against; this directory is templates, not a server.

```bash
pnpm install
pnpm build          # compile assets/css + assets/js -> assets/built (gitignored)
pnpm dev            # watch + livereload
pnpm test           # gscan validation — run before pushing
```

Point a local Ghost at it once:

```bash
mkdir -p ~/ghost-local && cd ~/ghost-local
ghost install local                                  # http://localhost:2368
ln -s /home/russell/storywriter/labs/theme \
      ~/ghost-local/content/themes/storywriter-labs
ghost restart                                        # then activate it in Admin -> Design
```

## Layout

```
default.hbs        base layout wrapping every page
index.hbs          post list (home)
post.hbs           single post
page.hbs           single page
tag.hbs            tag archive
author.hbs         author archive
error.hbs          500 etc.
error-404.hbs      404
partials/          {{> reusable-bits}}
assets/css/        source CSS (postcss, @import via postcss-easy-import)
assets/js/         source JS (concatenated, lib/ first)
assets/built/      compiled output — gitignored, built by CI
locales/           translation strings
package.json       theme name/version + `config.custom` admin settings
```

`config.custom` in `package.json` is what renders the settings form in
Ghost Admin → Design; read those values in templates as `{{@custom.setting_name}}`.

## Adding a custom post template

Create `custom-<name>.hbs` and it appears in the post settings template dropdown:

```hbs
{{!< default}}
{{!-- Template: Wide --}}
```

## What is NOT here

`routes.yaml`, `redirects.yaml` and code injection are Ghost *settings*, not theme
files — they live in `../ghost/` and are uploaded separately. See `../README.md`.
