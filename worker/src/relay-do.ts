import { badRequest } from "./types";

export class RelayDO implements DurableObject {
  constructor(private readonly state: DurableObjectState) {}

  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("upgrade") !== "websocket") {
      return badRequest("relay_requires_websocket");
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.state.acceptWebSocket(server);
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(sender: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message === "string") {
      return;
    }

    for (const socket of this.state.getWebSockets()) {
      if (socket !== sender) {
        socket.send(message);
      }
    }
  }
}
