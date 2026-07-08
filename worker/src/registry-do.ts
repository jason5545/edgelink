import { relayAuthMessage, verifyEd25519, isBase64Bytes } from "./crypto";
import { badRequest, json, type DeviceRecord, type Platform } from "./types";
import { isDeviceId, isNonEmptyString, parseJson } from "./validation";

const PLATFORMS = new Set<Platform>(["macos", "android", "ios", "windows", "linux"]);

export class RegistryDO implements DurableObject {
  constructor(private readonly state: DurableObjectState) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "POST" && url.pathname === "/v1/device/register") {
      return this.register(request);
    }

    if (request.method === "GET" && url.pathname.startsWith("/v1/device/")) {
      const deviceId = url.pathname.split("/").at(-1);
      if (!isDeviceId(deviceId)) {
        return badRequest("invalid_device_id");
      }
      const record = await this.state.storage.get<DeviceRecord>(`device:${deviceId}`);
      if (!record) {
        return json({ error: "device_not_found" }, { status: 404 });
      }
      return json({ device: publicDeviceRecord(record) });
    }

    if (request.method === "POST" && url.pathname === "/internal/device/verify-relay-auth") {
      return this.verifyRelayAuth(request);
    }

    return badRequest("unsupported_registry_route");
  }

  private async register(request: Request): Promise<Response> {
    const body = await parseJson<{
      pubkey?: string;
      name?: string;
      platform?: Platform;
    }>(request);

    if (!body?.pubkey || !isBase64Bytes(body.pubkey, 32) || !isNonEmptyString(body.name) || !body.platform || !PLATFORMS.has(body.platform)) {
      return badRequest("invalid_device_registration");
    }

    const existingDeviceId = await this.state.storage.get<string>(`pubkey:${body.pubkey}`);
    if (existingDeviceId) {
      return json({ deviceId: existingDeviceId });
    }

    const deviceId = await this.allocateDeviceId();
    const record: DeviceRecord = {
      deviceId,
      pubkey: body.pubkey,
      name: body.name,
      platform: body.platform,
      createdAt: new Date().toISOString()
    };

    await this.state.storage.put(`device:${deviceId}`, record);
    await this.state.storage.put(`pubkey:${body.pubkey}`, deviceId);
    return json({ deviceId });
  }

  private async verifyRelayAuth(request: Request): Promise<Response> {
    const body = await parseJson<{
      deviceId?: string;
      ts?: number;
      sig?: string;
    }>(request);

    if (!body || !isDeviceId(body.deviceId) || typeof body.ts !== "number" || !body.sig) {
      return badRequest("invalid_relay_auth");
    }

    if (Math.abs(Math.floor(Date.now() / 1000) - body.ts) > 5 * 60) {
      return json({ ok: false, error: "relay_auth_expired" }, { status: 401 });
    }

    const record = await this.state.storage.get<DeviceRecord>(`device:${body.deviceId}`);
    if (!record) {
      return json({ ok: false, error: "device_not_found" }, { status: 404 });
    }

    const ok = await verifyEd25519(record.pubkey, body.sig, relayAuthMessage(body.deviceId, body.ts));
    return json({ ok, device: ok ? publicDeviceRecord(record) : undefined }, { status: ok ? 200 : 401 });
  }

  private async allocateDeviceId(): Promise<string> {
    for (let attempt = 0; attempt < 32; attempt += 1) {
      const deviceId = String(100_000_000 + randomInt(900_000_000));
      const existing = await this.state.storage.get(`device:${deviceId}`);
      if (!existing) {
        return deviceId;
      }
    }
    throw new Error("unable_to_allocate_device_id");
  }
}

const randomInt = (exclusiveMax: number): number => {
  const bytes = new Uint32Array(1);
  crypto.getRandomValues(bytes);
  return bytes[0] % exclusiveMax;
};

const publicDeviceRecord = (record: DeviceRecord) => ({
  deviceId: record.deviceId,
  pubkey: record.pubkey,
  name: record.name,
  platform: record.platform,
  createdAt: record.createdAt
});
