# Code injection

Ghost stores site-wide code injection **in MySQL**, not in a file, and nothing
in this repo deploys it. This file is a hand-maintained mirror so the snippets
are reviewable and restorable. When you change either side, change both.

Location in Ghost: **Admin → Settings → Code injection**.
Per-post injection lives in each post's settings panel and is *not* mirrored here.

## Site header

```html
<!-- (nothing yet) -->
```

## Site footer

```html
<!-- (nothing yet) -->
```

## Notes

- Prefer the theme for anything structural or styled — code injection is for
  third-party scripts (analytics, chat widgets, embeds) that don't belong in
  version-controlled templates.
- Ghost 6 ships native analytics, so a third-party analytics snippet may be
  redundant; check Admin → Analytics before adding one.
- Anything added here also needs to survive a restore from EBS snapshot. The
  snapshot includes MySQL, so it does — but a Ghost JSON export does **not**
  include code injection in all cases, which is the reason this mirror exists.
