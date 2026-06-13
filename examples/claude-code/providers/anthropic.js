module.exports = {
  // Reachable only from the proxy on the `secure` network.
  // cred-gateway does not whitelist this path, so dev cannot reach it.
  "/anthropic/key": async (url, send) => {
    console.log("[broker] issued anthropic key to proxy");
    send(200, { key: process.env.ANTHROPIC_API_KEY });
  },
};
