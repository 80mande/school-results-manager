/* EduRecord PWA worker
   - Pages: network-first, falling back to the last good copy of the app shell.
   - Libraries and fonts: cached so the app can start without a signal.
   - Never caches API calls, signed image links, or any other private data.
     Only the explicit allow-lists below are ever stored. */
const CACHE_NAME = "edurecord-pwa-shell-v2";

const LIBRARIES = [
  "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2",
  "https://cdn.jsdelivr.net/npm/xlsx@0.18.5/dist/xlsx.full.min.js"
];

function isLibrary(url) {
  return url.hostname === "cdn.jsdelivr.net" &&
    (url.pathname.startsWith("/npm/@supabase/supabase-js@") || url.pathname.startsWith("/npm/xlsx@"));
}
function isFont(url) {
  return url.hostname === "fonts.googleapis.com" || url.hostname === "fonts.gstatic.com";
}

const OFFLINE_PAGE = "<!doctype html><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>EduRecord is offline</title>" +
  "<body style=\"margin:0;min-height:100vh;display:grid;place-items:center;background:#0a1830;color:#fff;font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif;text-align:center;padding:24px\">" +
  "<main style=\"max-width:420px\"><h1 style=\"margin:0 0 10px;font-size:28px;font-weight:600\">You're offline</h1>" +
  "<p style=\"margin:0 0 22px;color:#b4c3df;line-height:1.6\">EduRecord needs a connection the first time it opens. Reconnect and try again.</p>" +
  "<button onclick=\"location.reload()\" style=\"font:inherit;font-weight:700;padding:13px 26px;border:0;border-radius:10px;background:#d4b46a;color:#0a1830;cursor:pointer\">Try again</button></main></body>";

self.addEventListener("install", event => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE_NAME);
    try { await cache.add(new Request("/", { cache: "reload" })); } catch (_) {}
    await Promise.all(LIBRARIES.map(async href => {
      try {
        const response = await fetch(href, { mode: "cors", credentials: "omit" });
        if (response && response.ok) await cache.put(href, response);
      } catch (_) {}
    }));
    await self.skipWaiting();
  })());
});

self.addEventListener("activate", event => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(key => key.startsWith("edurecord-pwa-shell-") && key !== CACHE_NAME).map(key => caches.delete(key)));
    await self.clients.claim();
  })());
});

function handleNavigation(request) {
  return (async () => {
    const cache = await caches.open(CACHE_NAME);
    try {
      const response = await fetch(request);
      if (response && response.ok) await cache.put("/", response.clone());
      return response;
    } catch (_) {
      return (await cache.match("/")) ||
        new Response(OFFLINE_PAGE, { headers: { "Content-Type": "text/html; charset=utf-8" }, status: 503 });
    }
  })();
}

function staleWhileRevalidate(event) {
  const request = event.request;
  event.respondWith((async () => {
    const cache = await caches.open(CACHE_NAME);
    const cached = await cache.match(request, { ignoreVary: true });
    const refresh = fetch(request.url, { mode: "cors", credentials: "omit" })
      .then(async response => {
        if (response && response.ok) await cache.put(request, response.clone());
        return response;
      })
      .catch(() => null);
    if (cached) {
      event.waitUntil(refresh);
      return cached;
    }
    return (await refresh) || Response.error();
  })());
}

self.addEventListener("fetch", event => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);

  if (request.mode === "navigate" && url.origin === self.location.origin) {
    event.respondWith(handleNavigation(request));
    return;
  }
  if (isLibrary(url) || isFont(url)) {
    staleWhileRevalidate(event);
  }
  /* Everything else (Supabase API, storage, signed images, other sites) passes
     straight through to the network and is never stored by this worker. */
});
