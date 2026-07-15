export interface Env {
  REGISTRY: DurableObjectNamespace;
  PAIRING: DurableObjectNamespace;
  RELAY: DurableObjectNamespace;
  TURN_REALM?: string;
  TURN_URLS?: string;
  TURN_TTL_SECONDS?: string;
  TURN_STATIC_AUTH_SECRET?: string;
}

export type Platform = "macos" | "android" | "ios" | "windows" | "linux";

export interface DeviceRecord {
  deviceId: string;
  pubkey: string;
  name: string;
  platform: Platform;
  createdAt: string;
}

export interface PairingRecord {
  hostId: string;
  clientId: string;
  hostPk: string;
  clientPk: string;
  hostName: string;
  clientName: string;
  pairedAt: string;
}

export interface PairConfirmation {
  role: "host" | "client";
  hostId: string;
  clientId: string;
  hostPk: string;
  clientPk: string;
  hostName: string;
  clientName: string;
  confirmedAt: number;
}

export interface RelaySocketAttachment {
  authenticated: boolean;
  deviceId?: string;
  role?: "host" | "client";
}

export const json = (body: unknown, init: ResponseInit = {}) => {
  const headers = new Headers(init.headers);
  headers.set("content-type", "application/json; charset=utf-8");
  return new Response(JSON.stringify(body), { ...init, headers });
};

export const badRequest = (message: string) => json({ error: message }, { status: 400 });

export const notFound = () => json({ error: "not_found" }, { status: 404 });
