
const SUPABASE_URL = "https://dukqweogkftgvbrhzjkk.supabase.co";
const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_7yIKAC07tFFzijxPTtzShg_HB96TFQi";
const ROOT_DOMAIN = "edurecord.com.ng";

function safeColor(value, fallback) {
  return typeof value === "string" && /^#[0-9a-f]{6}$/i.test(value) ? value : fallback;
}

function safeText(value, fallback) {
  return typeof value === "string" && value.trim() ? value.trim().slice(0, 100) : fallback;
}

function initials(name) {
  const words = String(name || "School").trim().split(/\s+/).filter(Boolean);
  return (words.length > 1 ? words.slice(0, 2).map(x => x[0]) : [String(words[0] || "S").slice(0, 2)]).join("").toUpperCase().slice(0, 3);
}

export async function getPwaContext(request) {
  const url = new URL(request.url);
  const host = url.hostname.toLowerCase();

  const platform = host === ROOT_DOMAIN || host === `www.${ROOT_DOMAIN}` ||
    host.endsWith(".pages.dev") || host.endsWith(".github.io") ||
    host === "localhost" || host === "127.0.0.1";

  if (platform) {
    return {
      name: "EduRecord",
      shortName: "EduRecord",
      description: "EduRecord school management and results platform.",
      primary: "#1746a2",
      accent: "#d6ad45",
      initials: "ER"
    };
  }

  let fallback = host.endsWith(`.${ROOT_DOMAIN}`)
    ? host.slice(0, -(ROOT_DOMAIN.length + 1))
    : host.split(".")[0];

  fallback = fallback.replace(/[-_]+/g, " ").replace(/\b\w/g, c => c.toUpperCase());

  let result = null;

  try {
    const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/edurecord_public_school_website`, {
      method: "POST",
      headers: {
        "apikey": SUPABASE_PUBLISHABLE_KEY,
        "Authorization": `Bearer ${SUPABASE_PUBLISHABLE_KEY}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({ p_slug: host })
    });

    if (response.ok) result = await response.json();
  } catch (error) {
    console.warn("PWA school details lookup failed", error);
  }

  const schoolName = safeText(result?.school?.school_name, fallback || "School");
  const branding = result?.website?.site_config?.branding || {};
  const primary = safeColor(branding.primary_color, "#075b46");
  const accent = safeColor(branding.accent_color, "#d6ad45");

  return {
    name: `${schoolName} | Official School Website`,
    shortName: schoolName.slice(0, 24),
    description: `Official website and student portal for ${schoolName}.`,
    primary,
    accent,
    initials: initials(schoolName),
    logoUrl: branding.logo_url || "",
    schoolSlug: host
  };
}

async function fetchSchoolLogoData(ctx) {
  if (!ctx.logoUrl || !ctx.schoolSlug) return "";

  try {
    const signedResponse = await fetch(`${SUPABASE_URL}/functions/v1/public-school-website-images`, {
      method: "POST",
      headers: {
        "apikey": SUPABASE_PUBLISHABLE_KEY,
        "Authorization": `Bearer ${SUPABASE_PUBLISHABLE_KEY}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        slug: ctx.schoolSlug,
        image_urls: [ctx.logoUrl]
      })
    });

    if (!signedResponse.ok) return "";

    const signedData = await signedResponse.json();
    const signedUrl = signedData?.images?.[ctx.logoUrl];

    if (!signedUrl) return "";

    const imageResponse = await fetch(signedUrl);
    if (!imageResponse.ok) return "";

    const mime = (imageResponse.headers.get("content-type") || "").split(";")[0].toLowerCase();

    if (!["image/png", "image/jpeg", "image/webp"].includes(mime)) return "";

    const bytes = new Uint8Array(await imageResponse.arrayBuffer());
    if (!bytes.length || bytes.length > 700000) return "";

    let binary = "";
    const chunk = 0x8000;

    for (let i = 0; i < bytes.length; i += chunk) {
      binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
    }

    return `data:${mime};base64,${btoa(binary)}`;
  } catch (error) {
    console.warn("School PWA logo could not be loaded; using initials instead.", error);
    return "";
  }
}

export async function getPwaIconSvg(request) {
  const ctx = await getPwaContext(request);
  const logoData = await fetchSchoolLogoData(ctx);
  return iconSvg(ctx, logoData);
}

export function iconSvg(ctx, logoData = "") {
  const p = ctx.primary;
  const a = ctx.accent;
  const letters = String(ctx.initials || "S").replace(/[<>&"']/g, "");

  const mark = logoData
    ? `<image href="${logoData}" x="112" y="112" width="288" height="288" preserveAspectRatio="xMidYMid meet"/>`
    : `<circle cx="256" cy="256" r="150" fill="#ffffff" fill-opacity=".12"/><text x="256" y="292" text-anchor="middle" font-family="Arial,Helvetica,sans-serif" font-size="${letters.length > 2 ? 112 : 148}" font-weight="800" fill="#ffffff">${letters}</text>`;

  return `<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512"><rect width="512" height="512" rx="112" fill="${p}"/><path d="M72 72h368v24H72z" fill="${a}"/>${mark}<path d="M160 430h192" stroke="${a}" stroke-width="18" stroke-linecap="round"/></svg>`;
    }
    
