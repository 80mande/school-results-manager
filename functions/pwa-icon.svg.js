
import { getPwaIconSvg } from "./_lib/pwa.js";

export async function onRequest({ request }) {
  const svg = await getPwaIconSvg(request);

  return new Response(svg, {
    headers: {
      "Content-Type": "image/svg+xml; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff"
    }
  });
}
