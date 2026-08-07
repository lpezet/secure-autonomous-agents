const fs = require("fs");
const https = require("https");
const { createAppAuth } = require("@octokit/auth-app");
const { logEvent } = require("../audit");

const SAFETY_WINDOW_MS = 5 * 60 * 1000;

let githubAuth = null;
function getGitHubAuth() {
  if (!githubAuth) {
    const privateKey = fs.readFileSync(
      process.env.GITHUB_APP_PRIVATE_KEY_PATH,
      "utf8",
    );
    githubAuth = createAppAuth({
      appId: process.env.GITHUB_APP_ID,
      privateKey,
      installationId: parseInt(process.env.GITHUB_APP_INSTALLATION_ID, 10),
    });
  }
  return githubAuth;
}

let githubTokenCache = null;
async function mintGitHubToken() {
  if (
    githubTokenCache &&
    new Date(githubTokenCache.expiresAt) - Date.now() > SAFETY_WINDOW_MS
  ) {
    return githubTokenCache;
  }
  const auth = getGitHubAuth();
  const t = await auth({ type: "installation" });
  githubTokenCache = {
    token: t.token,
    expiresAt: t.expiresAt,
    // What this token can do. Free — octokit returns it on the installation
    // auth object, no extra call. Taken from the token rather than from the
    // installation so it stays truthful if a future change ever narrows what
    // is minted; today they are the same thing.
    permissions: t.permissions,
  };
  return githubTokenCache;
}

// Lifetime-cached like identityCache, and for the same reason: an installation's
// repository selection changes only when a human changes it in GitHub's UI.
// Restart the broker to pick that up.
//
// This needs its own call. `repositoryIds`/`repositoryNames` appear on the
// installation auth object only when passed IN as narrowing options, and we
// pass neither — so the token itself cannot say whether the installation is
// org-wide. The App JWT can.
let installationScopeCache = null;
async function getInstallationScope() {
  if (installationScopeCache) return installationScopeCache;
  const auth = getGitHubAuth();
  const { token: appJwt } = await auth({ type: "app" });
  const inst = await ghGet(
    `/app/installations/${process.env.GITHUB_APP_INSTALLATION_ID}`,
    `Bearer ${appJwt}`,
  );
  installationScopeCache = { repository_selection: inst.repository_selection };
  return installationScopeCache;
}

// The scope an issued token carries, shaped for the audit trail.
//
// Not a credential and not derived from one: `permissions` maps permission name
// to "read"/"write", `repository_selection` is the enum "all" | "selected".
// Repository *names* are deliberately absent — observer serves this trail over
// HTTP, and private repo names would be signal for no benefit. The enum answers
// the question the ceiling is actually about: is this installation org-wide?
async function tokenScope(t) {
  let repository_selection = "unknown";
  try {
    ({ repository_selection } = await getInstallationScope());
  } catch (e) {
    // Describing a token must never be what stops it being issued. A failed
    // lookup degrades the trail; it does not break the credential path.
    console.log(
      `[broker] github installation scope unavailable (${e.code || e.name})`,
    );
  }
  return { permissions: t.permissions, repository_selection };
}

// Cached for the broker's lifetime. If you rename the GitHub App,
// restart the broker to refresh.
let identityCache = null;
async function getGitHubIdentity() {
  if (identityCache) return identityCache;
  const auth = getGitHubAuth();
  const { token: appJwt } = await auth({ type: "app" });
  const appInfo = await ghGet("/app", `Bearer ${appJwt}`);
  const slug = appInfo.slug;
  const botUser = await ghGet(`/users/${slug}%5Bbot%5D`, null);
  identityCache = {
    name: `${slug}[bot]`,
    email: `${botUser.id}+${slug}[bot]@users.noreply.github.com`,
  };
  return identityCache;
}

// Note: broker makes direct outbound calls to api.github.com without going
// through the proxy — routing through it would be circular.
function ghGet(path, authHeader) {
  return new Promise((resolve, reject) => {
    const headers = {
      "User-Agent": "agent-broker",
      Accept: "application/vnd.github+json",
    };
    if (authHeader) headers.Authorization = authHeader;
    https
      .get({ host: "api.github.com", path, headers }, (res) => {
        let data = "";
        res.on("data", (c) => (data += c));
        res.on("end", () => {
          try {
            const parsed = JSON.parse(data);
            if (res.statusCode >= 400)
              reject(new Error(`GitHub ${res.statusCode}: ${data}`));
            else resolve(parsed);
          } catch (e) {
            reject(e);
          }
        });
      })
      .on("error", reject);
  });
}

module.exports = {
  // Both routes hand over the same token, so both report the same scope. The
  // credential route is the one git push travels, and leaving it out would make
  // the most-used path the least visible one.
  "/github/token": async (url, send) => {
    const t = await mintGitHubToken();
    const scope = await tokenScope(t);
    console.log(`[broker] issued github token (expires ${t.expiresAt})`);
    logEvent("token_issued", { provider: "github", ...scope });
    // Explicit rather than sending the cache entry: the wire format is a
    // contract with 010_github.py, the cache is ours to change.
    send(200, { token: t.token, expiresAt: t.expiresAt });
  },

  "/github/credential": async (url, send) => {
    const t = await mintGitHubToken();
    const scope = await tokenScope(t);
    console.log(`[broker] issued github credential (expires ${t.expiresAt})`);
    logEvent("credential_issued", { provider: "github", ...scope });
    send(200, `username=x-access-token\npassword=${t.token}\n`, "text/plain");
  },

  "/github/identity": async (url, send) => {
    const id = await getGitHubIdentity();
    console.log(`[broker] issued github identity ${id.name}`);
    logEvent("identity_issued", { provider: "github", name: id.name });
    send(200, id);
  },
};
