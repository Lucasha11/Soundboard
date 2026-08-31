# AGENTS.md

## Pushing to GitHub

This repo is gated by `no-mistakes`. Never push directly to `origin`. Push to the `no-mistakes` remote instead, which runs the review/lint/test/docs pipeline before forwarding to `origin`:

```bash
git push no-mistakes <branch>
```

`no-mistakes status` shows the current gate state; `no-mistakes runs` lists pipeline run history.
