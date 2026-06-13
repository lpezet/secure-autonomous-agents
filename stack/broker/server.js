const http = require("http");
const fs = require("fs");
const path = require("path");

const PORT = 8080;
const PROVIDERS_DIR = process.env.PROVIDERS_DIR || path.join(__dirname, "providers");

// Load providers in sorted order (numeric prefix controls load order)
const providerFiles = fs
  .readdirSync(PROVIDERS_DIR)
  .filter((f) => f.endsWith(".js"))
  .sort();

const routes = {};
for (const file of providerFiles) {
  Object.assign(routes, require(path.join(PROVIDERS_DIR, file)));
}

const server = http.createServer(async (req, res) => {
  const send = (status, obj, contentType = "application/json") => {
    res.writeHead(status, { "Content-Type": contentType });
    res.end(typeof obj === "string" ? obj : JSON.stringify(obj));
  };

  try {
    const url = new URL(req.url, `http://localhost:${PORT}`);

    if (url.pathname === "/healthz") return send(200, { ok: true });

    const handler = routes[url.pathname];
    if (!handler) return send(404, { error: "not found" });

    await handler(url, send);
  } catch (err) {
    console.error("[broker] error:", err);
    send(500, { error: String(err.message || err) });
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`[broker] listening on :${PORT}`);
  console.log(`[broker] GITHUB_APP_ID=${process.env.GITHUB_APP_ID || "(not set)"}`);
  console.log(`[broker] GITHUB_APP_INSTALLATION_ID=${process.env.GITHUB_APP_INSTALLATION_ID || "(not set)"}`);
  console.log(`[broker] GITHUB_APP_PRIVATE_KEY_PATH=${process.env.GITHUB_APP_PRIVATE_KEY_PATH || "(not set)"}`);
  console.log(`[broker] providers loaded: ${providerFiles.join(", ")}`);
});
