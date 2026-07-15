import { PairingDO } from "./pairing-do";
import { RegistryDO } from "./registry-do";
import { RelayDO } from "./relay-do";
import { badRequest, json, notFound, type Env } from "./types";

export { PairingDO, RegistryDO, RelayDO };

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/v1/hello")) {
      return json({
        name: "edgelink-worker",
        status: "ok",
        protocol: "edgelink-v1"
      });
    }

    if (url.pathname === "/v1/device/register" || url.pathname.startsWith("/v1/device/")) {
      const id = env.REGISTRY.idFromName("global");
      return env.REGISTRY.get(id).fetch(request);
    }

    if (url.pathname === "/v1/pair/start" || url.pathname === "/v1/pair/claim" || url.pathname === "/v1/pair/confirm" || url.pathname === "/v1/pair/ws") {
      const body = request.headers.get("upgrade") === "websocket"
        ? null
        : await request.clone().json().catch(() => null) as { hostId?: string } | null;
      const hostId = url.searchParams.get("hostId") ?? body?.hostId;
      if (!hostId) {
        return badRequest("missing_host_id");
      }
      const id = env.PAIRING.idFromName(hostId);
      return env.PAIRING.get(id).fetch(request);
    }

    if (url.pathname === "/v1/connect") {
      const hostId = url.searchParams.get("hostId");
      if (!hostId) {
        return badRequest("missing_host_id");
      }
      const id = env.RELAY.idFromName(hostId);
      return env.RELAY.get(id).fetch(request);
    }

    if (url.pathname === "/v1/turn/credentials") {
      const body = request.method === "POST"
        ? await request.clone().json().catch(() => null) as { hostId?: string } | null
        : null;
      const hostId = url.searchParams.get("hostId") ?? body?.hostId;
      if (!hostId) {
        return badRequest("missing_host_id");
      }
      const id = env.RELAY.idFromName(hostId);
      return env.RELAY.get(id).fetch(request);
    }

    return notFound();
  }
};
