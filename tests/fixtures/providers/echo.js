// Dummy broker provider. Proves server.js auto-discovers *.js in PROVIDERS_DIR
// without an image rebuild.
module.exports = {
  "/echo/ping": async (url, send) => send(200, { pong: true }),
  "/echo/query": async (url, send) => send(200, { got: url.searchParams.get("v") }),
};
