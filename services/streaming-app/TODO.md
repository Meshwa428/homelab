# streaming-app roadmap

Base app is [xalonious/streaming-app](https://github.com/xalonious/streaming-app)
(Express + React, MIT), self-hosted here and pointed at
[vidking.net](https://www.vidking.net) as the playback source.

The list below is a feature wishlist pulled from
[Reely](https://github.com/Vette1123/movies-streaming-platform) — a much more
fully-featured TMDB tracker/player we evaluated but didn't self-host directly,
because its search/filtering/season/account backend only exists as a
Cloudflare Worker (`cloudflare/worker.js`), not as portable server code, and
its premium player depends on a private companion repo. Instead we're
cherry-picking the features we actually want and building them into our own
fork over time.

## Confirmed working already (base app)
- [x] TMDB-powered catalog (trending, popular, top-rated, discovery by genre)
- [x] Rich detail pages (synopsis, cast, trailers, recommendations, collections)
- [x] In-page streaming player via vidking (movie + TV episode embeds)
- [x] Season & episode navigator
- [x] Search (debounced, movie/TV/multi)
- [x] Genre browsing

## To build ourselves
- [ ] **Continue watching / watch history** — resume position per title, a
      dedicated history page, remove/clear entries. vidking supports this
      natively: pass `?progress=<seconds>` on the embed URL to resume, and it
      `postMessage`s `PLAYER_EVENT` (play/pause/timeupdate/ended/seeked) and
      `MEDIA_DATA` progress objects to the parent window. Needs a
      `postMessage` listener in `PlayerPage.tsx` + `localStorage`. No account
      needed — everything stays on-device (privacy-first, like Reely's).
- [ ] **Watchlist** — save titles to watch later, on-device only, no account.
- [ ] Animated hero slider with inline trailer preview on the landing page
- [ ] Advanced filters — sort, genre include/exclude, rating, vote count,
      runtime, release year range, language, certification, "where to watch"
- [ ] Infinite scroll on browse/listing pages
- [ ] URL-synced filters (shareable filtered views)
- [ ] Command-palette search (⌘K) with recent searches
- [ ] Collections / franchise pages
- [ ] Real IMDb ratings layered over TMDB (opt-in)
- [ ] Web Share (native share sheet on title pages)
- [ ] Installable PWA (manifest + service worker, offline app shell)
- [ ] SEO/structured data (JSON-LD, OG/Twitter cards, sitemap, robots)
- [ ] Accessibility pass (skip-to-content, aria roles, mobile nav)
- [ ] Optimized imagery (responsive `srcset`, CDN/proxy fallback chain)

## Explicitly not planned
- Accounts, Cloudflare Workers/D1, PostHog analytics, Buy-Me-a-Coffee/"pro"
  tiers, Watch Together — SaaS scaffolding from Reely we don't need for a
  single-household homelab deployment.
