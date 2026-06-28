# Deploying to Cloudflare Pages (read only when asked to deploy)

> This file is intentionally NOT referenced from `AGENTS.md` or any always-loaded
> doc. Don't act on it unless the user explicitly asks to deploy the site.

The site is hosted on **Cloudflare Pages**, served from an **orphan `static`
branch** that contains only the prebuilt web files at its root. Cloudflare is
connected to the GitHub repo and auto-deploys whenever `static` changes — there is
**no build step on Cloudflare's side**. Deploying = build locally, then replace the
`static` branch with the fresh files.

## Deploy (the whole procedure)

1. Build the web output (from the repo root):
   ```sh
   EMSDK_ENV=~/emsdk/emsdk_env.sh ./build_web.sh
   ```
   Confirm it ends with `OK -> build/web/game.html` and that these exist:
   `build/web/game.html`, `build/web/game.js`, `build/web/game.wasm`,
   `build/web/game.data`. (PATH note: strip `/mnt/c` first under WSL — see
   `.agents/knowledge/environment.md`.)

2. Replace the `static` branch with the new files and push. This uses a throwaway
   repo + force-push, so `static` stays a single clean commit (no history bloat)
   and your working tree / `main` are never touched:
   ```sh
   WT=$(mktemp -d)
   cp build/web/game.js build/web/game.wasm build/web/game.data "$WT"/
   cp build/web/game.html "$WT"/index.html       # Pages serves /index.html at /
   cp web/_headers "$WT"/_headers                 # cache headers (optional)
   git -C "$WT" init -q
   git -C "$WT" checkout -q -b static
   git -C "$WT" add -A
   git -C "$WT" -c user.email=deploy@local -c user.name=deploy \
       commit -q -m "Static build $(date -u +%FT%TZ)"
   git -C "$WT" push -f git@github.com:realtradam/raylib-jamstack.git static
   rm -rf "$WT"
   ```

3. Cloudflare Pages picks up the push and deploys in ~1 minute. Done.

The web entry script (which `.rb` demo runs) is set in `web/shell.html`
(`Module.arguments`); change it and rebuild before deploying if needed.

## One-time Cloudflare setup (already connected to GitHub)

In the Cloudflare dashboard → Workers & Pages → your Pages project (or create one
from the connected `raylib-jamstack` repo):

- **Production branch:** `static`
- **Framework preset:** None
- **Build command:** *(leave empty)*
- **Build output directory:** `/` (root — the files live at the branch root)
- (Optional) Disable preview deployments for other branches so pushes to `main`
  don't trigger empty builds: Settings → Builds & deployments → Branch control.

Because the build command is empty, Cloudflare just uploads the branch root as-is.

## Notes
- Single-threaded build (no pthreads/SharedArrayBuffer) → **no COOP/COEP headers
  needed**. `.wasm` is served as `application/wasm` automatically.
- `game.wasm` is ~7 MB (well under Pages' 25 MiB/file limit).
- Force-pushing `static` is expected and safe: it holds only generated artifacts.
