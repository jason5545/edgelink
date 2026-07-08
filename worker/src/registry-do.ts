import { badRequest, json, type DeviceRecord, type Platform } from "./types";

const PLATFORMS = new Set<Platform>(["macos", "android", "ios", "windows", "linux"]);

export class RegistryDO implements DurableObject {
  constructor(private readonly state: DurableObjectState) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method !== "POST" || url.pathname !== "/v1/device/register") {
      return badRequest("unsupported_registry_route");
    }

    const body = await request.json().catch(() => null) as {
      pubkey?: string;
      name?: string;
      platform?: Platform;
    } | null;

    if (!body?.pubkey || !body.name || !body.platform || !PLATFORMS.has(body.platform)) {
      return badRequest("invalid_device_registration");
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
    return json({ deviceId });
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
