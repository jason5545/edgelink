export interface Env {
  REGISTRY: DurableObjectNamespace;
  PAIRING: DurableObjectNamespace;
  RELAY: DurableObjectNamespace;
}

export type Platform = "macos" | "android" | "ios" | "windows" | "linux";

export interface DeviceRecord {
  deviceId: string;
  pubkey: string;
  name: string;
  platform: Platform;
  createdAt: string;
}

export const json = (body: unknown, init: ResponseInit = {}) => {
  const headers = new Headers(init.headers);
  headers.set("content-type", "application/json; charset=utf-8");
  return new Response(JSON.stringify(body), { ...init, headers });
};

export const badRequest = (message: string) => json({ error: message }, { status: 400 });

export const notFound = () => json({ error: "not_found" }, { status: 404 });
