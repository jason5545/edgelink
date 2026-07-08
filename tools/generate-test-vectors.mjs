import { createCipheriv, createHash, createPrivateKey, createPublicKey, diffieHellman, hkdfSync, sign } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const outDir = join(root, "docs", "test-vectors");

const utf8 = (value) => Buffer.from(value, "utf8");
const b64 = (value) => Buffer.from(value).toString("base64");
const hex = (value) => Buffer.from(value).toString("hex");
const sha256 = (value) => createHash("sha256").update(value).digest();

const u16be = (value) => {
  const out = Buffer.alloc(2);
  out.writeUInt16BE(value);
  return out;
};

const u32be = (value) => {
  const out = Buffer.alloc(4);
  out.writeUInt32BE(value);
  return out;
};

const u64be = (value) => {
  const out = Buffer.alloc(8);
  out.writeBigUInt64BE(BigInt(value));
  return out;
};

const lengthPrefix = (chunks) =>
  Buffer.concat(chunks.flatMap((chunk) => {
    const bytes = Buffer.isBuffer(chunk) ? chunk : utf8(String(chunk));
    return [u16be(bytes.length), bytes];
  }));

const peerRecord = (deviceId, ephPk, nonce) => lengthPrefix([deviceId, ephPk, nonce]);

const ed25519Pkcs8Prefix = Buffer.from("302e020100300506032b657004220420", "hex");
const x25519Pkcs8Prefix = Buffer.from("302e020100300506032b656e04220420", "hex");

const ed25519PrivateKey = (seedHex) =>
  createPrivateKey({
    key: Buffer.concat([ed25519Pkcs8Prefix, Buffer.from(seedHex, "hex")]),
    format: "der",
    type: "pkcs8"
  });

const x25519PrivateKey = (seedHex) =>
  createPrivateKey({
    key: Buffer.concat([x25519Pkcs8Prefix, Buffer.from(seedHex, "hex")]),
    format: "der",
    type: "pkcs8"
  });

const rawPublicKey = (privateKey) => {
  const der = createPublicKey(privateKey).export({ format: "der", type: "spki" });
  return Buffer.from(der).subarray(-32);
};

const sasFromDigest = (digest) => {
  let remainder = 0;
  for (const byte of digest) {
    remainder = (remainder * 256 + byte) % 1_000_000;
  }
  const numeric = String(remainder).padStart(6, "0");
  return { numeric, display: `${numeric.slice(0, 3)} ${numeric.slice(3)}` };
};

const hostEdSeed = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
const clientEdSeed = "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f";
const hostEd = ed25519PrivateKey(hostEdSeed);
const clientEd = ed25519PrivateKey(clientEdSeed);
const hostPk = rawPublicKey(hostEd);
const clientPk = rawPublicKey(clientEd);

const hostPairingNonce = Buffer.from("404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f", "hex");
const clientPairingNonce = Buffer.from("606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f", "hex");
const commitment = sha256(Buffer.concat([hostPk, hostPairingNonce]));
const sasDigest = sha256(Buffer.concat([hostPk, clientPk, hostPairingNonce, clientPairingNonce]));

const pairingVector = {
  version: 1,
  algorithm: "SAS = SHA256(hostPk || clientPk || nonceH || nonceC), interpreted as a big-endian integer modulo 1000000",
  host: {
    deviceId: "949758990",
    name: "Jason's Mac",
    publicKeyBase64: b64(hostPk),
    nonceBase64: b64(hostPairingNonce)
  },
  client: {
    deviceId: "137245816",
    name: "Pixel 9",
    publicKeyBase64: b64(clientPk),
    nonceBase64: b64(clientPairingNonce)
  },
  commitment: {
    algorithm: "SHA256(hostPk || nonceH)",
    base64: b64(commitment),
    hex: hex(commitment)
  },
  sasDigestHex: hex(sasDigest),
  sas: sasFromDigest(sasDigest)
};

const hostXSeed = "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f";
const clientXSeed = "a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf";
const hostX = x25519PrivateKey(hostXSeed);
const clientX = x25519PrivateKey(clientXSeed);
const hostEphPk = rawPublicKey(hostX);
const clientEphPk = rawPublicKey(clientX);
const hostHandshakeNonce = Buffer.from("c0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf", "hex");
const clientHandshakeNonce = Buffer.from("e0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff", "hex");

const clientPeerRecord = peerRecord("137245816", clientEphPk, clientHandshakeNonce);
const hostPeerRecord = peerRecord("949758990", hostEphPk, hostHandshakeNonce);
const helloInput = Buffer.concat([utf8("EdgeLink hs.v1 hello\n"), clientPeerRecord]);
const helloSignature = sign(null, helloInput, clientEd);
const ackInput = Buffer.concat([utf8("EdgeLink hs.v1 ack\n"), clientPeerRecord, hostPeerRecord]);
const ackSignature = sign(null, ackInput, hostEd);
const confirmInput = Buffer.concat([utf8("EdgeLink hs.v1 confirm\n"), clientPeerRecord, hostPeerRecord, helloSignature, ackSignature]);
const confirmSignature = sign(null, confirmInput, clientEd);

const transcriptHash = sha256(Buffer.concat([
  utf8("EdgeLink hs.v1 transcript\n"),
  clientPeerRecord,
  helloSignature,
  hostPeerRecord,
  ackSignature,
  confirmSignature
]));
const sharedSecret = diffieHellman({ privateKey: clientX, publicKey: createPublicKey(hostX) });
const reverseSharedSecret = diffieHellman({ privateKey: hostX, publicKey: createPublicKey(clientX) });
if (!sharedSecret.equals(reverseSharedSecret)) {
  throw new Error("X25519 shared secret mismatch");
}

const okm = Buffer.from(hkdfSync("sha256", sharedSecret, transcriptHash, utf8("EdgeLink secure channel v1"), 64));
const initiatorToResponderKey = okm.subarray(0, 32);
const responderToInitiatorKey = okm.subarray(32, 64);
const plaintext = utf8(JSON.stringify({ t: "status.ping", b: {} }));
const frameNonce = Buffer.concat([Buffer.alloc(4), u64be(0)]);
const aad = utf8("EdgeLink frame v1 i2r");
const cipher = createCipheriv("chacha20-poly1305", initiatorToResponderKey, frameNonce, { authTagLength: 16 });
cipher.setAAD(aad, { plaintextLength: plaintext.length });
const ciphertextAndTag = Buffer.concat([cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
const frame = Buffer.concat([u32be(ciphertextAndTag.length), ciphertextAndTag]);

const handshakeVector = {
  version: 1,
  encoding: {
    peerRecord: "u16be(len(deviceIdUtf8)) || deviceIdUtf8 || u16be(32) || ephPkRaw || u16be(32) || nonceRaw",
    helloSignatureInput: "utf8(\"EdgeLink hs.v1 hello\\n\") || clientPeerRecord",
    ackSignatureInput: "utf8(\"EdgeLink hs.v1 ack\\n\") || clientPeerRecord || hostPeerRecord",
    confirmSignatureInput: "utf8(\"EdgeLink hs.v1 confirm\\n\") || clientPeerRecord || hostPeerRecord || helloSig || ackSig",
    transcriptHash: "SHA256(utf8(\"EdgeLink hs.v1 transcript\\n\") || clientPeerRecord || helloSig || hostPeerRecord || ackSig || confirmSig)",
    hkdf: "HKDF-SHA256(ikm = X25519 shared secret, salt = transcriptHash, info = utf8(\"EdgeLink secure channel v1\"), length = 64)"
  },
  identityKeys: {
    host: { seedHex: hostEdSeed, publicKeyBase64: b64(hostPk) },
    client: { seedHex: clientEdSeed, publicKeyBase64: b64(clientPk) }
  },
  ephemeralKeys: {
    host: { privateKeyRawHex: hostXSeed, publicKeyBase64: b64(hostEphPk) },
    client: { privateKeyRawHex: clientXSeed, publicKeyBase64: b64(clientEphPk) }
  },
  nonces: {
    hostBase64: b64(hostHandshakeNonce),
    clientBase64: b64(clientHandshakeNonce)
  },
  peerRecordsHex: {
    client: hex(clientPeerRecord),
    host: hex(hostPeerRecord)
  },
  signatures: {
    helloInputHex: hex(helloInput),
    helloSignatureBase64: b64(helloSignature),
    ackInputHex: hex(ackInput),
    ackSignatureBase64: b64(ackSignature),
    confirmInputHex: hex(confirmInput),
    confirmSignatureBase64: b64(confirmSignature)
  },
  keySchedule: {
    sharedSecretHex: hex(sharedSecret),
    transcriptHashHex: hex(transcriptHash),
    hkdfOkmHex: hex(okm),
    initiatorToResponderKeyHex: hex(initiatorToResponderKey),
    responderToInitiatorKeyHex: hex(responderToInitiatorKey)
  },
  encryptedFrame: {
    direction: "initiator_to_responder",
    counter: 0,
    nonceHex: hex(frameNonce),
    aadUtf8: "EdgeLink frame v1 i2r",
    plaintextUtf8: plaintext.toString("utf8"),
    ciphertextAndTagHex: hex(ciphertextAndTag),
    frameHex: hex(frame)
  }
};

mkdirSync(outDir, { recursive: true });
writeFileSync(join(outDir, "pairing-sas-v1.json"), `${JSON.stringify(pairingVector, null, 2)}\n`);
writeFileSync(join(outDir, "handshake-channel-v1.json"), `${JSON.stringify(handshakeVector, null, 2)}\n`);
console.log("Wrote docs/test-vectors/pairing-sas-v1.json");
console.log("Wrote docs/test-vectors/handshake-channel-v1.json");
