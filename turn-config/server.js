import crypto from "crypto";
import http from "http";

const PORT = process.env.PORT || 3000;

const BASE_URL = process.env.BASE_URL || "https://azxc.site";
const HOMESERVER = process.env.HOMESERVER || "azxc.site";
const JWT_SERVICE_URL = process.env.JWT_SERVICE_URL || "https://sfu.azxc.site/sfu/get";
const LIVEKIT_SERVICE_URL = process.env.LIVEKIT_SERVICE_URL || "wss://sfu.azxc.site";

const TURN_HOST = process.env.TURN_HOST || "turn.azxc.site";
const TURN_REALM = process.env.TURN_REALM || "azxc.site";
const TURN_SECRET = process.env.TURN_SECRET; // static-auth-secret
const TURN_TTL = parseInt(process.env.TURN_TTL || "3600", 10); // seconds
const TURN_NAME = process.env.TURN_NAME || "elementcall";

if (!TURN_SECRET) {
  console.error("TURN_SECRET is required (must match coturn static-auth-secret)");
  process.exit(1);
}

// TURN REST creds: username = "<expiry_unix_timestamp>:<name>"
// credential = base64(HMAC-SHA1(secret, username))
function makeTurnCreds() {
  const expiry = Math.floor(Date.now() / 1000) + TURN_TTL;
  const username = `${expiry}:${TURN_NAME}`;

  const hmac = crypto.createHmac("sha1", TURN_SECRET);
  hmac.update(username);
  const credential = hmac.digest("base64");

  return { username, credential };
}

const server = http.createServer((req, res) => {
  if (req.url !== "/config.json") {
    res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    res.end("not found");
    return;
  }

  const { username, credential } = makeTurnCreds();

  const body = JSON.stringify(
    {
      base_url: BASE_URL,
      homeserver: HOMESERVER,
      jwt_service_url: JWT_SERVICE_URL,
      livekit_service_url: LIVEKIT_SERVICE_URL,
      turnServers: [
        {
          // и UDP, и TCP — так надёжнее для WebRTC
          urls: [
            `turn:${TURN_HOST}:3478?transport=udp`,
            `turn:${TURN_HOST}:3478?transport=tcp`,
            `turns:${TURN_HOST}:5349?transport=tcp`,
          ],
          username,
          credential,
          // важно: credential — пароль (long-term) в терминологии WebRTC
          credentialType: "password",
        },
      ],
    },
    null,
    2
  );

  res.writeHead(200, {
    "content-type": "application/json; charset=utf-8",
    "access-control-allow-origin": "*",
    "cache-control": "no-store",
  });
  res.end(body);
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`turn-config listening on :${PORT}`);
});
