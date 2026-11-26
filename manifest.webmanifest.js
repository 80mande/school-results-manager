import { getPwaContext } from "./_lib/pwa.js";

export async function onRequest({ request }) {
  const app = await getPwaContext(request);
  const origin = new URL(request.url).origin;
  const manifest = {
    id: `${origin}/`,
    name: app.name,
    short_name: app.shortName,
    description: app.description,
    start_url: `${origin}/`,
    scope: `${origin}/`,
    display: "standalone",
    orientation: "any",
    background_color: "#ffffff",
    theme_color: app.primary,
    icons: [{ src: "/pwa-icon.svg", sizes: "any", type: "image/svg+xml", purpose: "any maskable" }]
  };
  return new Response(JSON.stringify(manifest), {
    headers: {
      "Content-Type": "application/manifest+json; charset=utf-8",
      "Cache-Control": "no-store, max-age=0",
      "X-Content-Type-Options": "nosniff"
    }
  });
}
