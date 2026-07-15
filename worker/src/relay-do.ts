import { badRequest, json, type Env, type PairingRecord, type RelaySocketAttachment } from "./types";
import { hmacSha1Base64 } from "./crypto";
import { isDeviceId, parseJson } from "./validation";

const DEFAULT_TURN_TTL_SECONDS = 10 * 60;
const MAX_TURN_TTL_SECONDS = 60 * 60;

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

    if (role === "host") {
      this.closeReplacedHostSockets(sender, body.b.deviceId);
    }

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

    const issuedAt = Math.floor(Date.now() / 1000);
    const expiresAt = issuedAt + config.ttlSeconds;
    const username = `${expiresAt}:${body.deviceId}:${body.hostId}`;
    const credential = await hmacSha1Base64(config.staticAuthSecret, username);
    const iceServers = [{
      urls: config.urls,
      username,
      credential,
      credentialType: "password" as const
    }];

    return json({
      urls: config.urls,
      username,
      credential,
      credentialType: "password",
      ttlSeconds: config.ttlSeconds,
      issuedAt,
      expiresAt,
      realm: config.realm,
      role,
      iceServers
    });
  }

  private closeReplacedHostSockets(sender: WebSocket, deviceId: string): void {
    for (const socket of this.state.getWebSockets()) {
      if (socket === sender) {
        continue;
      }

      const attachment = readAttachment(socket);
      if (attachment.authenticated && attachment.role === "host" && attachment.deviceId === deviceId) {
        socket.close(1000, "replaced_by_new_host");
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

const readTurnConfig = (env: Env): {
  urls: string[];
  realm: string;
  ttlSeconds: number;
  staticAuthSecret: string;
} | null => {
  const staticAuthSecret = env.TURN_STATIC_AUTH_SECRET?.trim();
  const urls = env.TURN_URLS?.split(",")
    .map((url) => url.trim())
    .filter((url) => url.length > 0) ?? [];
  const realm = env.TURN_REALM?.trim() || "edgelink-turn-tokyo";
  const requestedTtl = Number(env.TURN_TTL_SECONDS ?? DEFAULT_TURN_TTL_SECONDS);
  const ttlSeconds = Number.isFinite(requestedTtl)
    ? Math.min(Math.max(Math.floor(requestedTtl), 60), MAX_TURN_TTL_SECONDS)
    : DEFAULT_TURN_TTL_SECONDS;

  if (!staticAuthSecret || urls.length === 0) {
    return null;
  }

  return {
    urls,
    realm,
    ttlSeconds,
    staticAuthSecret
  };
};

const isPairingRecord = (value: PairingRecord | null): value is PairingRecord =>
  !!value &&
  isDeviceId(value.hostId) &&
  isDeviceId(value.clientId) &&
  typeof value.hostPk === "string" &&
  typeof value.clientPk === "string" &&
  typeof value.hostName === "string" &&
  typeof value.clientName === "string" &&
  typeof value.pairedAt === "string";
