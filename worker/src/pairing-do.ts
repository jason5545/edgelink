import { badRequest, json } from "./types";

const PAIRING_TTL_MS = 5 * 60 * 1000;

export class PairingDO implements DurableObject {
  constructor(private readonly state: DurableObjectState) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/v1/pair/start" && request.method === "POST") {
      const expiresAt = Date.now() + PAIRING_TTL_MS;
      await this.state.storage.put("pairingWindowExpiresAt", expiresAt);
      return json({ ok: true, expiresAt });
    }

    if (url.pathname === "/v1/pair/claim" && request.method === "POST") {
      const expiresAt = await this.state.storage.get<number>("pairingWindowExpiresAt");
      if (!expiresAt || expiresAt < Date.now()) {
        return json({ error: "pairing_window_closed" }, { status: 403 });
      }
      return json({ ok: true, expiresAt });
    }

    if (request.headers.get("upgrade") === "websocket") {
      const expiresAt = await this.state.storage.get<number>("pairingWindowExpiresAt");
      if (!expiresAt || expiresAt < Date.now()) {
        return json({ error: "pairing_window_closed" }, { status: 403 });
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
}
