# Warren Onboarding

The public onboarding site for Warren, served from a Cloudflare Worker.

## Stack

- React + Vite for the front-end
- Cloudflare Worker with static assets for hosting
- `ghostty-web` for an interactive terminal demo (Ghostty's VT parser compiled to WebAssembly)
- Built-in English / Simplified Chinese i18n
- Chinese display type: ZCOOL XiaoWei (站酷小薇) + MiSans (小米)

The Download button resolves the latest GitHub release through the Worker's
`/api/latest-release` endpoint and starts the installer download directly.

The standalone `/changelog` page presents the release history in the same
English / Simplified Chinese interface as the landing page. Keep its release
entries in sync with the repository root `CHANGELOG.md` when publishing a
new Warren version.

## Local development

```sh
npm install
npm run dev        # Vite HMR at http://localhost:5173
```

To preview the exact Cloudflare Worker behavior locally:

```sh
npm run build
npm run preview    # wrangler dev at http://localhost:8787
```

## Deploy

```sh
npm run deploy
```

The worker name is `warren-onboarding`. Once `warrenai.xyz` is ready on
Cloudflare, uncomment the `routes` block in `wrangler.toml` and deploy again.

## Notes

- The site lives in `Onboarding/` inside the Warren repository. It is
  self-contained and does not touch other source trees.
- `ghostty-web` inlines its WASM bundle, so no extra static asset is needed.
