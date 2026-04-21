# Decisions — tigerduck-website

## Architectural Decisions

### Deployment
- Cloudflare Workers (NOT Pages) via @opennextjs/cloudflare
- wrangler.jsonc with nodejs_compat + global_fetch_strictly_public flags
- Custom domain: tigerduck.app

### i18n
- next-intl with App Router
- Route structure: / (zh-TW default), /en (English)
- localePrefix: "as-needed" (zh-TW has no prefix)

### Styling
- Tailwind v4 CSS-first config in globals.css
- No CSS-in-JS
- Dark mode: auto (prefers-color-scheme) + manual toggle via data-theme attribute

### 3D
- @react-three/fiber v10 + @react-three/drei
- Must use dynamic(ssr: false) - never import in Server Components
- WebGL fallback required

### Analytics
- Cloudflare Web Analytics only (no GA4)
- Token via NEXT_PUBLIC_CF_ANALYTICS_TOKEN env var

### CTAs
- iOS beta: TestFlight link (visible)
- Android beta: Discord redirect (visible)
- Store badges: commented out with {/* FUTURE: ... */} (hidden until launch)

### Team Data
- Build-time fetch from GitHub API (ISR 3600s)
- Filter bots ([bot] suffix, claude bot, dependabot)
- Fallback to static data on API failure

## Task 16-17 Decisions
- Kept privacy/delete-account copy inside `app/[locale]` route components instead of adding a separate content layer, because the pages are static and locale branching is tiny.
- Reused the existing `policy` and `deleteAccount` translation keys only for the page chrome (`title`, `lastUpdated`), while the legal body copy stays locale-local in the page file.
- Included the NTUST disclaimer prominently in delete-account pages so the non-affiliation warning is visible before the actionable instructions.
