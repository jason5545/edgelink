import { badRequest, json, type Env, type PairingRecord, type RelaySocketAttachment } from "./types";
import { isDeviceId, parseJson } from "./validation";

const DEFAULT_TURN_TTL_SECONDS = 24 * 60 * 60;
const MAX_TURN_TTL_SECONDS = 48 * 60 * 60;
const CLOUDFLARE_TURN_REALM = "turn.cloudflare.com";

export class RelayDO implements DurableObject {
  constructor(
    private readonly state: DurableObjectState,
    private readonly env: Env
  ) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/internal/relay/pair" && request.method === "POST") {
      const body = await parseJson<PairingRecord>(request);
      if (!isPairingRecord(body)) {
        return badRequest("invalid_pair_record");
      }
      await this.state.storage.put(`pair:${body.clientId}`, body);
      return json({ ok: true });
    }

    if (url.pathname === "/v1/turn/credentials" && request.method === "POST") {
      return this.issueTurnCredentials(request);
    }

    if (request.headers.get("upgrade") !== "websocket") {
      return badRequest("relay_requires_websocket");
    }

    const hostId = url.searchParams.get("hostId");
    if (!isDeviceId(hostId)) {
      return badRequest("invalid_host_id");
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    server.serializeAttachment({ authenticated: false } satisfies RelaySocketAttachment);
    this.state.acceptWebSocket(server);
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(sender: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message === "string") {
      await this.handleText(sender, message);
      return;
    }

    const senderAttachment = readAttachment(sender);
    if (!senderAttachment.authenticated || !senderAttachment.deviceId) {
      sender.close(1008, "relay_auth_required");
      return;
    }

    for (const socket of this.state.getWebSockets()) {
      const targetAttachment = readAttachment(socket);
      if (socket !== sender && targetAttachment.authenticated && shouldForward(senderAttachment, targetAttachment)) {
        socket.send(message);
      }
    }
  }

  private async handleText(sender: WebSocket, message: string): Promise<void> {
    const body = parseMessage<{
      t?: string;
      b?: {
        hostId?: string;
        deviceId?: string;
        ts?: number;
        sig?: string;
      };
    }>(message);

    if (body?.t !== "relay.auth" || !body.b || !isDeviceId(body.b.hostId) || !isDeviceId(body.b.deviceId) || typeof body.b.ts !== "number" || !body.b.sig) {
      sender.close(1008, "invalid_relay_auth");
      return;
    }

    const role = await this.authorize(body.b.hostId, body.b.deviceId, body.b.ts, body.b.sig);
    if (!role) {
      sender.close(1008, "relay_auth_failed");
      return;
    }

    sender.serializeAttachment({
      authenticated: true,
      deviceId: body.b.deviceId,
      role
    } satisfies RelaySocketAttachment);

    this.closeReplacedRoleSockets(sender, body.b.deviceId, role);

    sender.send(JSON.stringify({ t: "relay.ready", b: { role } }));
  }

  private async issueTurnCredentials(request: Request): Promise<Response> {
    const body = await parseJson<{
      hostId?: string;
      deviceId?: string;
      ts?: number;
      sig?: string;
    }>(request);

    if (!body || !isDeviceId(body.hostId) || !isDeviceId(body.deviceId) || typeof body.ts !== "number" || !body.sig) {
      return badRequest("invalid_turn_auth");
    }

    const role = await this.authorize(body.hostId, body.deviceId, body.ts, body.sig);
    if (!role) {
      return json({ error: "turn_auth_failed" }, { status: 401 });
    }

    const config = readTurnConfig(this.env);
    if (!config) {
      return json({ error: "turn_not_configured" }, { status: 503 });
    }

    return this.issueCloudflareTurnCredentials(config, role);
  }

  private async issueCloudflareTurnCredentials(
    config: CloudflareTurnConfig,
    role: "host" | "client"
  ): Promise<Response> {
    let response: Response;
    try {
      response = await fetch(
        `https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(config.keyId)}/credentials/generate-ice-servers`,
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${config.apiToken}`,
            "content-type": "application/json"
          },
          body: JSON.stringify({ ttl: config.ttlSeconds })
        }
      );
    } catch (error) {
      console.error("Cloudflare TURN credential request failed", error);
      return json({ error: "turn_upstream_unavailable" }, { status: 502 });
    }

    if (!response.ok) {
      console.error("Cloudflare TURN credential request rejected", { status: response.status });
      return json({ error: "turn_upstream_rejected" }, { status: 502 });
    }

    const payload = await parseCloudflareTurnResponse(response);
    if (!payload) {
      console.error("Cloudflare TURN credential response was invalid");
      return json({ error: "turn_upstream_invalid_response" }, { status: 502 });
    }

    const turnServer = payload.iceServers.find((server) =>
      server.username &&
      server.credential &&
      server.urls.some((url) => url.startsWith("turn:") || url.startsWith("turns:"))
    );
    if (!turnServer?.username || !turnServer.credential) {
      console.error("Cloudflare TURN credential response did not contain a TURN server");
      return json({ error: "turn_upstream_invalid_response" }, { status: 502 });
    }

    const issuedAt = Math.floor(Date.now() / 1000);
    const expiresAt = issuedAt + config.ttlSeconds;
    const turnUrls = turnServer.urls.filter((url) => url.startsWith("turn:") || url.startsWith("turns:"));
    return json({
      urls: turnUrls,
      username: turnServer.username,
      credential: turnServer.credential,
      credentialType: "password",
      ttlSeconds: config.ttlSeconds,
      issuedAt,
      expiresAt,
      realm: CLOUDFLARE_TURN_REALM,
      role,
      iceServers: payload.iceServers
    });
  }

  private closeReplacedRoleSockets(
    sender: WebSocket,
    deviceId: string,
    role: "host" | "client"
  ): void {
    for (const socket of this.state.getWebSockets()) {
      if (socket === sender) {
        continue;
      }

      const attachment = readAttachment(socket);
      if (attachment.authenticated && attachment.role === role && attachment.deviceId === deviceId) {
        // close() starts the WebSocket closing handshake, but the old socket can
        // still deliver frames that were already queued. Revoke its attachment
        // first so those stale secure-channel frames cannot reach the peer and
        // advance its receive counter out of sync.
        socket.serializeAttachment({ authenticated: false } satisfies RelaySocketAttachment);
        socket.close(1000, `replaced_by_new_${role}`);
      }
    }
  }

  private async authorize(hostId: string, deviceId: string, ts: number, sig: string): Promise<"host" | "client" | null> {
    const registryId = this.env.REGISTRY.idFromName("global");
    const registry = this.env.REGISTRY.get(registryId);
    const verification = await registry.fetch("https://internal.edgelink/internal/device/verify-relay-auth", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ deviceId, ts, sig })
    });
    if (!verification.ok) {
      return null;
    }

    if (deviceId === hostId) {
      return "host";
    }

    const pair = await this.state.storage.get<PairingRecord>(`pair:${deviceId}`);
    return pair?.hostId === hostId ? "client" : null;
  }
}

const parseMessage = <T>(message: string): T | null => {
  try {
    return JSON.parse(message) as T;
  } catch {
    return null;
  }
};

const readAttachment = (socket: WebSocket): RelaySocketAttachment =>
  socket.deserializeAttachment() as RelaySocketAttachment | null ?? { authenticated: false };

const shouldForward = (sender: RelaySocketAttachment, target: RelaySocketAttachment): boolean => {
  if (sender.role === "host") {
    return target.role === "client";
  }
  return target.role === "host";
};

interface CloudflareTurnConfig {
  keyId: string;
  apiToken: string;
  ttlSeconds: number;
}

interface TurnIceServer {
  urls: string[];
  username?: string;
  credential?: string;
  credentialType?: "password";
}

const readTurnConfig = (env: Env): CloudflareTurnConfig | null => {
  const cloudflareKeyId = env.CLOUDFLARE_TURN_KEY_ID?.trim();
  const cloudflareApiToken = env.CLOUDFLARE_TURN_KEY_API_TOKEN?.trim();
  const requestedTtl = Number(env.TURN_TTL_SECONDS ?? DEFAULT_TURN_TTL_SECONDS);
  const ttlSeconds = Number.isFinite(requestedTtl)
    ? Math.min(Math.max(Math.floor(requestedTtl), 60), MAX_TURN_TTL_SECONDS)
    : DEFAULT_TURN_TTL_SECONDS;

  if (!cloudflareKeyId || !cloudflareApiToken) {
    return null;
  }

  return {
    keyId: cloudflareKeyId,
    apiToken: cloudflareApiToken,
    ttlSeconds,
  };
};

const parseCloudflareTurnResponse = async (response: Response): Promise<{ iceServers: TurnIceServer[] } | null> => {
  let value: unknown;
  try {
    value = await response.json();
  } catch {
    return null;
  }

  if (!value || typeof value !== "object" || !("iceServers" in value) || !Array.isArray(value.iceServers)) {
    return null;
  }

  const iceServers = value.iceServers
    .map(normalizeTurnIceServer)
    .filter((server): server is TurnIceServer => server !== null);
  return iceServers.length > 0 ? { iceServers } : null;
};

const normalizeTurnIceServer = (value: unknown): TurnIceServer | null => {
  if (!value || typeof value !== "object" || !("urls" in value)) {
    return null;
  }

  const rawUrls = typeof value.urls === "string"
    ? [value.urls]
    : Array.isArray(value.urls)
      ? value.urls
      : [];
  const urls = rawUrls
    .filter((url): url is string => typeof url === "string")
    .map((url) => url.trim())
    .filter((url) => /^(?:stun|turn|turns):/i.test(url) && !isPort53Url(url));
  if (urls.length === 0) {
    return null;
  }

  const username = "username" in value && typeof value.username === "string" ? value.username : undefined;
  const credential = "credential" in value && typeof value.credential === "string" ? value.credential : undefined;
  return {
    urls,
    ...(username ? { username } : {}),
    ...(credential ? { credential, credentialType: "password" as const } : {})
  };
};

// Port 53 is often intercepted or blocked. EdgeLink keeps Cloudflare's UDP 3478
// path first, then TCP/TLS fallbacks, without waiting on a misleading DNS port.
const isPort53Url = (url: string): boolean => /^(?:stun|turn|turns):[^?]+:53(?:\?|$)/i.test(url);

const isPairingRecord = (value: PairingRecord | null): value is PairingRecord =>
  !!value &&
  isDeviceId(value.hostId) &&
  isDeviceId(value.clientId) &&
  typeof value.hostPk === "string" &&
  typeof value.clientPk === "string" &&
  typeof value.hostName === "string" &&
  typeof value.clientName === "string" &&
  typeof value.pairedAt === "string";
