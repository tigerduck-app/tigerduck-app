# Issues — tigerduck-website

## Known Gotchas

### Three.js / R3F
- NEVER import three or @react-three/fiber in Server Components - will SSR crash
- Must use: const Hero3D = dynamic(() => import('./Hero3D'), { ssr: false })
- Use frameloop="demand" for performance

### Cloudflare Workers
- No Cloudflare Images binding on Free plan
- Use nodejs_compat + global_fetch_strictly_public compat flags
- wrangler.jsonc (not wrangler.toml)

### next-intl
- Need middleware.ts for routing
- Need i18n/routing.ts and i18n/request.ts
- App Router requires [locale] segment in app directory

### GitHub API
- Rate limit: use ISR revalidate=3600 (not per-request fetch)
- Filter bots from contributors list
- Fallback to static data on failure

### Screenshots
- GitHub user-attachments URLs may expire (JWT tokens)
- Download to public/screenshots/ and version them
- If download fails, use placeholder files

## Resolved Issues
(none yet)
