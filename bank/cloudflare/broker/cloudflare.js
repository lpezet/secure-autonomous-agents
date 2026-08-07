const fs = require("fs");
const https = require("https");
const { logEvent } = require("../audit");

const SAFETY_WINDOW_MS = 5 * 60 * 1000;
const cloudflareTokenCache = new Map();

// Which profile this deployment issues. Deployment configuration, same value
// the proxy addon is configured with. The `profile` query param is checked
// against this rather than trusted — see the route handler.
const CONFIGURED_PROFILE = process.env.CLOUDFLARE_PROFILE || "workers-deploy";

async function mintCloudflareToken(profile) {
  const cached = cloudflareTokenCache.get(profile);
  if (cached && new Date(cached.expiresAt) - Date.now() > SAFETY_WINDOW_MS) {
    return cached;
  }

  // Profile definitions. Permission group IDs come from:
  //   GET https://api.cloudflare.com/client/v4/user/tokens/permission_groups
  const profiles = {
    "workers-deploy": {
      permission_groups: [{ id: "e086da7e2179491d91ee5f35b3ca210a" }], // Workers Scripts:Edit
      resources: { "com.cloudflare.api.account.*": "*" },
    },
    // Add more profiles here. Example:
    // 'dns-edit': {
    //   permission_groups: [{ id: '<DNS_WRITE_ID>' }],
    //   resources: { 'com.cloudflare.api.account.zone.<ZONE_ID>': '*' },
    // },
  };

  const profileDef = profiles[profile];
  if (!profileDef) throw new Error(`Unknown Cloudflare profile: ${profile}`);

  // Note: broker makes direct outbound calls to api.cloudflare.com without
  // going through the proxy — routing through it would be circular.
  const minterToken = fs
    .readFileSync(process.env.CLOUDFLARE_MINTER_TOKEN_PATH, "utf8")
    .trim();
  const expiresAt = new Date(Date.now() + 60 * 60 * 1000).toISOString();
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const body = JSON.stringify({
    name: `agent-${profile}-${stamp}`,
    policies: [
      {
        effect: "allow",
        resources: profileDef.resources,
        permission_groups: profileDef.permission_groups,
      },
    ],
    expires_on: expiresAt,
  });

  const result = await new Promise((resolve, reject) => {
    const req = https.request(
      "https://api.cloudflare.com/client/v4/user/tokens",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${minterToken}`,
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(body),
        },
      },
      (res) => {
        let data = "";
        res.on("data", (c) => (data += c));
        res.on("end", () => {
          try {
            resolve(JSON.parse(data));
          } catch (e) {
            reject(e);
          }
        });
      },
    );
    req.on("error", reject);
    req.write(body);
    req.end();
  });

  if (!result.success)
    throw new Error(`Cloudflare API error: ${JSON.stringify(result.errors)}`);

  // Expired tokens accumulate as inactive entries in Cloudflare dashboard.
  // They are inert (no security risk) but can be pruned manually:
  //   dashboard → Profile → API Tokens → delete agent-* entries with past dates
  const entry = { token: result.result.value, expiresAt };
  cloudflareTokenCache.set(profile, entry);
  return entry;
}

module.exports = {
  "/cloudflare/token": async (url, send) => {
    // The param is a cross-check, not an input. Which profile gets minted is
    // CONFIGURED_PROFILE; a caller asking for a different one is either a
    // misconfigured proxy or an addon that went back to reading the profile off
    // a request header, and neither is a reason to mint wider authority. The
    // addon already ignores the header — this is what still holds if it stops.
    const requested = url.searchParams.get("profile");
    if (requested && requested !== CONFIGURED_PROFILE) {
      logEvent("request_rejected", {
        provider: "cloudflare",
        reason: "profile_mismatch",
        requested,
        configured: CONFIGURED_PROFILE,
      });
      return send(403, { error: "profile not permitted" });
    }
    const t = await mintCloudflareToken(CONFIGURED_PROFILE);
    console.log(
      `[broker] issued cloudflare token profile=${CONFIGURED_PROFILE} (expires ${t.expiresAt})`,
    );
    logEvent("token_issued", { provider: "cloudflare", profile: CONFIGURED_PROFILE });
    send(200, t);
  },
};
