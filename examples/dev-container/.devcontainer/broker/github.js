const fs = require("fs");
const https = require("https");
const { createAppAuth } = require("@octokit/auth-app");

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
  githubTokenCache = { token: t.token, expiresAt: t.expiresAt };
  return githubTokenCache;
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
  "/github/token": async (url, send) => {
    const t = await mintGitHubToken();
    console.log(`[broker] issued github token (expires ${t.expiresAt})`);
    send(200, t);
  },

  "/github/credential": async (url, send) => {
    const t = await mintGitHubToken();
    console.log(`[broker] issued github credential (expires ${t.expiresAt})`);
    send(200, `username=x-access-token\npassword=${t.token}\n`, "text/plain");
  },

  "/github/identity": async (url, send) => {
    const id = await getGitHubIdentity();
    console.log(`[broker] issued github identity ${id.name}`);
    send(200, id);
  },
};
