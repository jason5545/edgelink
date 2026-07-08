import { badRequest, json, type Env, type PairConfirmation, type PairingRecord } from "./types";
import { isBase64Bytes } from "./crypto";
import { isDeviceId, isNonEmptyString, now, parseJson } from "./validation";

const PAIRING_TTL_MS = 5 * 60 * 1000;

export class PairingDO implements DurableObject {
  constructor(
    private readonly state: DurableObjectState,
    private readonly env: Env
  ) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/v1/pair/start" && request.method === "POST") {
      const body = await parseJson<{ hostId?: string; hostPk?: string; name?: string }>(request);
      if (!body || !isDeviceId(body.hostId) || !isBase64Bytes(body.hostPk ?? "", 32) || !isNonEmptyString(body.name)) {
        return badRequest("invalid_pair_start");
      }

      const expiresAt = now() + PAIRING_TTL_MS;
      await this.state.storage.delete(["clientClaim", "confirm:host", "confirm:client"]);
      await this.state.storage.put("host", {
        hostId: body.hostId,
        hostPk: body.hostPk,
        hostName: body.name
      });
      await this.state.storage.put("pairingWindowExpiresAt", expiresAt);
      return json({ ok: true, expiresAt });
    }

    if (url.pathname === "/v1/pair/claim" && request.method === "POST") {
      const window = await this.requireOpenWindow();
      if (!window.ok) {
        return window.response;
      }

      const body = await parseJson<{ hostId?: string; clientId?: string; clientPk?: string; name?: string }>(request);
      if (!body || !isDeviceId(body.hostId) || !isDeviceId(body.clientId) || !isBase64Bytes(body.clientPk ?? "", 32) || !isNonEmptyString(body.name)) {
        return badRequest("invalid_pair_claim");
      }

      const host = await this.state.storage.get<{ hostId: string }>("host");
      if (!host || host.hostId !== body.hostId) {
        return badRequest("host_id_mismatch");
      }

      await this.state.storage.put("clientClaim", {
        clientId: body.clientId,
        clientPk: body.clientPk,
        clientName: body.name,
        claimedAt: now()
      });
      return json({ ok: true, expiresAt: window.expiresAt });
    }

    if (url.pathname === "/v1/pair/confirm" && request.method === "POST") {
      const window = await this.requireOpenWindow();
      if (!window.ok) {
        return window.response;
      }
      return this.confirm(request);
    }

    if (request.headers.get("upgrade") === "websocket") {
      const window = await this.requireOpenWindow();
      if (!window.ok) {
        return window.response;
      }

      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);
      this.state.acceptWebSocket(server);
      return new Response(null, { status: 101, webSocket: client });
    }

    return badRequest("unsupported_pairing_route");
  }

  async webSocketMessage(sender: WebSocket, message: string | ArrayBuffer): Promise<void> {
    for (const socket of this.state.getWebSockets()) {
      if (socket !== sender) {
        socket.send(message);
      }
    }
  }

  private async requireOpenWindow(): Promise<
    | { ok: true; expiresAt: number }
    | { ok: false; response: Response }
  > {
    const expiresAt = await this.state.storage.get<number>("pairingWindowExpiresAt");
    if (!expiresAt || expiresAt < now()) {
      return { ok: false, response: json({ error: "pairing_window_closed" }, { status: 403 }) };
    }
    return { ok: true, expiresAt };
  }

  private async confirm(request: Request): Promise<Response> {
    const body = await parseJson<Partial<PairConfirmation>>(request);
    const confirmation = normalizeConfirmation(body);
    if (!confirmation) {
      return badRequest("invalid_pair_confirmation");
    }

    const host = await this.state.storage.get<{ hostId: string; hostPk: string; hostName: string }>("host");
    const claim = await this.state.storage.get<{ clientId: string; clientPk: string; clientName: string }>("clientClaim");
    if (!host || !claim) {
      return json({ error: "pairing_not_ready" }, { status: 409 });
    }

    if (
      confirmation.hostId !== host.hostId ||
      confirmation.hostPk !== host.hostPk ||
      confirmation.clientId !== claim.clientId ||
      confirmation.clientPk !== claim.clientPk
    ) {
      return badRequest("pair_confirmation_mismatch");
    }

    await this.state.storage.put(`confirm:${confirmation.role}`, confirmation);
    const hostConfirmation = await this.state.storage.get<PairConfirmation>("confirm:host");
    const clientConfirmation = await this.state.storage.get<PairConfirmation>("confirm:client");
    if (!hostConfirmation || !clientConfirmation || !samePair(hostConfirmation, clientConfirmation)) {
      return json({ ok: true, paired: false });
    }

    const record: PairingRecord = {
      hostId: confirmation.hostId,
      clientId: confirmation.clientId,
      hostPk: confirmation.hostPk,
      clientPk: confirmation.clientPk,
      hostName: confirmation.hostName,
      clientName: confirmation.clientName,
      pairedAt: new Date().toISOString()
    };
    await this.storeRelayPair(record);
    await this.state.storage.put(`pair:${record.clientId}`, record);
    this.broadcast({ t: "pair.complete", b: { hostId: record.hostId, clientId: record.clientId } });
    return json({ ok: true, paired: true });
  }

  private async storeRelayPair(record: PairingRecord): Promise<void> {
    const id = this.env.RELAY.idFromName(record.hostId);
    const relay = this.env.RELAY.get(id);
    await relay.fetch("https://internal.edgelink/internal/relay/pair", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(record)
    });
  }

  private broadcast(message: unknown): void {
    const encoded = JSON.stringify(message);
    for (const socket of this.state.getWebSockets()) {
      socket.send(encoded);
    }
  }
}

const normalizeConfirmation = (body: Partial<PairConfirmation> | null): PairConfirmation | null => {
  const hostPk = body?.hostPk;
  const clientPk = body?.clientPk;
  if (
    !body ||
    (body.role !== "host" && body.role !== "client") ||
    !isDeviceId(body.hostId) ||
    !isDeviceId(body.clientId) ||
    typeof hostPk !== "string" ||
    typeof clientPk !== "string" ||
    !isBase64Bytes(hostPk, 32) ||
    !isBase64Bytes(clientPk, 32) ||
    !isNonEmptyString(body.hostName) ||
    !isNonEmptyString(body.clientName)
  ) {
    return null;
  }

  return {
    role: body.role,
    hostId: body.hostId,
    clientId: body.clientId,
    hostPk,
    clientPk,
    hostName: body.hostName,
    clientName: body.clientName,
    confirmedAt: now()
  };
};

const samePair = (left: PairConfirmation, right: PairConfirmation): boolean =>
  left.hostId === right.hostId &&
  left.clientId === right.clientId &&
  left.hostPk === right.hostPk &&
  left.clientPk === right.clientPk;
