module.exports = {
  // Reachable only from the proxy on the `secure` network.
  // cred-gateway does not whitelist this path, so dev cannot reach it.
  // Returns whichever credential is configured, preferring auth token over API key.
  // type: "auth_token" → inject as Authorization: Bearer <value>
  // type: "api_key"    → inject as x-api-key: <value>
  "/anthropic/cred": async (url, send) => {
    if (process.env.ANTHROPIC_AUTH_TOKEN) {
      console.log("[broker] issued anthropic auth token to proxy");
      send(200, { type: "auth_token", value: process.env.ANTHROPIC_AUTH_TOKEN });
    } else if (process.env.ANTHROPIC_API_KEY) {
      console.log("[broker] issued anthropic api key to proxy");
      send(200, { type: "api_key", value: process.env.ANTHROPIC_API_KEY });
    } else {
      send(500, { error: "no Anthropic credential configured" });
    }
  },
};
