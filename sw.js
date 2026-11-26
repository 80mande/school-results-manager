/* EduRecord PWA worker: network-first for pages, never caches API/private data. */
const CACHE_NAME = "edurecord-pwa-shell-v1";
self.addEventListener("install", event => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE_NAME);
    try { await cache.add(new Request("/", { cache: "reload" })); } catch (_) {}
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
self.addEventListener("fetch", event => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin || request.mode !== "navigate") return;
  event.respondWith((async () => {
    const cache = await caches.open(CACHE_NAME);
    try {
      const response = await fetch(request);
      if (response && response.ok) await cache.put("/", response.clone());
      return response;
    } catch (_) {
      return (await cache.match("/")) || new Response("<h1>EduRecord is offline</h1><p>Please reconnect to the internet and try again.</p>", { headers: { "Content-Type": "text/html; charset=utf-8" }, status: 503 });
    }
  })());
});
