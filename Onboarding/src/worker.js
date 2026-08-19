const securityHeaders = {
  "Content-Security-Policy":
    "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self' data: ws: wss:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
};

const RELEASE_API = "https://api.github.com/repos/abcdlsj/warren/releases/latest";

function releaseAssetFromHtml(html) {
  const matches = html.matchAll(
    /href="(\/abcdlsj\/warren\/releases\/download\/[^"]+?)"/g,
  );
  for (const match of matches) {
    const name = decodeURIComponent(match[1].split("/").pop() ?? "");
    if (/^Warren-.*\.(dmg|pkg|zip)$/i.test(name)) {
      return { name, path: match[1] };
    }
  }
  return null;
}

async function latestReleaseFromHtml() {
  const latest = await fetch("https://github.com/abcdlsj/warren/releases/latest", {
    redirect: "follow",
    headers: { "User-Agent": "warren-onboarding" },
  });
  if (!latest.ok) {
    throw new Error(`GitHub releases page responded with ${latest.status}`);
  }
  const tag = latest.url.split("/").pop();
  if (!tag) {
    throw new Error("Could not resolve the latest release tag");
  }
  const assets = await fetch(
    `https://github.com/abcdlsj/warren/releases/expanded_assets/${tag}`,
    { headers: { "User-Agent": "warren-onboarding" } },
  );
  if (!assets.ok) {
    throw new Error(`GitHub assets page responded with ${assets.status}`);
  }
  const asset = releaseAssetFromHtml(await assets.text());
  if (!asset) {
    throw new Error("Latest release has no downloadable asset");
  }
  return {
    tag,
    name: asset.name,
    size: null,
    url: `https://github.com${asset.path}`,
  };
}

async function latestRelease() {
  try {
    const response = await fetch(RELEASE_API, {
      headers: {
        Accept: "application/vnd.github+json",
        "User-Agent": "warren-onboarding",
        "X-GitHub-Api-Version": "2022-11-28",
      },
    });
    if (!response.ok) {
      throw new Error(`GitHub API responded with ${response.status}`);
    }
    const release = await response.json();
    const asset =
      release.assets.find((item) => /^Warren-.*\.(dmg|pkg|zip)$/i.test(item.name)) ??
      release.assets[0];
    if (!asset) {
      throw new Error("Latest release has no downloadable asset");
    }
    return {
      tag: release.tag_name,
      name: asset.name,
      size: asset.size,
      url: asset.browser_download_url,
    };
  } catch {
    return latestReleaseFromHtml();
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return Response.json({ ok: true, service: "warren-onboarding" });
    }

    if (url.pathname === "/api/latest-release") {
      try {
        const release = await latestRelease();
        return Response.json(release);
      } catch (error) {
        return Response.json(
          { error: "Could not resolve the latest release." },
          { status: 502 },
        );
      }
    }

    // The ASSETS binding rewrites unknown paths to "/" with a redirect, so
    // pretty routes like /zh and /en fetch the root document instead.
    const isFileRequest = url.pathname !== "/" && url.pathname.match(/\.[a-zA-Z0-9]+$/);
    const target = isFileRequest
      ? request
      : (() => {
          // Keep the document fresh after an asset deployment; hashed files remain cacheable.
          const assetUrl = new URL("/" + url.search, url);
          assetUrl.searchParams.set("__warren_document_nonce", Date.now().toString(36));
          return new Request(assetUrl, request);
        })();
    const response = await env.ASSETS.fetch(target);

    const headers = new Headers(response.headers);
    for (const [key, value] of Object.entries(securityHeaders)) {
      headers.set(key, value);
    }
    if (!isFileRequest) {
      headers.set("Cache-Control", "no-store");
    }

    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  },
};
