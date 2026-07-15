const textEncoder = new TextEncoder();

export const relayAuthMessage = (deviceId: string, ts: number): Uint8Array =>
  textEncoder.encode(`EdgeLink relay auth v1\n${deviceId}\n${ts}`);

export const sha256Hex = async (bytes: Uint8Array): Promise<string> => {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
};

export const base64ToBytes = (value: string): Uint8Array | null => {
  try {
    const binary = atob(value);
    const out = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      out[index] = binary.charCodeAt(index);
    }
    return out;
  } catch {
    return null;
  }
};

export const bytesToBase64 = (bytes: Uint8Array): string => {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary);
};

export const isBase64Bytes = (value: string, expectedLength: number): boolean =>
  base64ToBytes(value)?.byteLength === expectedLength;

export const hmacSha1Base64 = async (secret: string, message: string): Promise<string> => {
  const key = await crypto.subtle.importKey(
    "raw",
    textEncoder.encode(secret),
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("HMAC", key, textEncoder.encode(message));
  return bytesToBase64(new Uint8Array(signature));
};

export const verifyEd25519 = async (publicKeyBase64: string, signatureBase64: string, message: Uint8Array): Promise<boolean> => {
  const publicKey = base64ToBytes(publicKeyBase64);
  const signature = base64ToBytes(signatureBase64);
  if (!publicKey || !signature) {
    return false;
  }

  const key = await crypto.subtle.importKey(
    "raw",
    publicKey,
    { name: "Ed25519" },
    false,
    ["verify"]
  );

  return crypto.subtle.verify("Ed25519", key, signature, message);
};
