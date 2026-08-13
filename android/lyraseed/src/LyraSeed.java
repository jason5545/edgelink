import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.KeyStore;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.zip.CRC32;
import javax.crypto.Cipher;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import org.json.JSONObject;

public final class LyraSeed {
    private static final String STORE =
        "/data/data/com.xiaomi.mi_connect_service/cache/storage.lyra";
    private static final String ALIAS = "lyra_store_manager";
    private static final String TRANSFORMATION = "AES/GCM/NoPadding";
    private static final int GCM_TAG_BITS = 128;

    private LyraSeed() {}

    public static void main(String[] args) {
        try {
            run(args);
        } catch (Throwable error) {
            System.out.println("ERROR " + error.getClass().getSimpleName() + ": " + error.getMessage());
            System.exit(1);
        }
    }

    private static void run(String[] args) throws Exception {
        String mode = args.length > 0 ? args[0] : "list";
        Map<String, byte[]> entries = readEntries();
        switch (mode) {
            case "list":
                System.out.println("entries=" + entries.size());
                for (Map.Entry<String, byte[]> e : entries.entrySet()) {
                    System.out.println("  " + e.getKey() + " (" + e.getValue().length + "B)");
                }
                return;
            case "dump":
                System.out.println("entries=" + entries.size());
                for (Map.Entry<String, byte[]> e : entries.entrySet()) {
                    System.out.println("  " + e.getKey() + " (" + e.getValue().length + "B)");
                    System.out.println("    " + new String(e.getValue(), StandardCharsets.UTF_8));
                }
                return;
            case "check": {
                String deviceId = requireArg(args, 1, "check <deviceId>");
                System.out.println(checkJson(entries, deviceId));
                boolean ok = entries.containsKey(credKey(deviceId)) && entries.containsKey(ticketKey(deviceId));
                System.exit(ok ? 0 : 3);
                return;
            }
            case "seed": {
                String payloadPath = requireArg(args, 1, "seed <payloadFile>");
                JSONObject payload = new JSONObject(
                    new String(Files.readAllBytes(Paths.get(payloadPath)), StandardCharsets.UTF_8));
                String deviceId = payload.getString("deviceId");
                String cred = payload.getString("cred");
                String ticket = payload.getString("ticket");
                entries.put(credKey(deviceId), cred.getBytes(StandardCharsets.UTF_8));
                entries.put(ticketKey(deviceId), ticket.getBytes(StandardCharsets.UTF_8));
                writeEntries(entries);
                Map<String, byte[]> verify = readEntries(STORE + ".seeded");
                System.out.println("seeded " + deviceId + " verify=" + checkJson(verify, deviceId));
                return;
            }
            default:
                throw new IllegalArgumentException("unknown mode: " + mode);
        }
    }

    static String checkJson(Map<String, byte[]> entries, String deviceId) {
        try {
            JSONObject out = new JSONObject();
            out.put("deviceId", deviceId);
            byte[] cred = entries.get(credKey(deviceId));
            out.put("hasCred", cred != null);
            out.put("hasTicket", entries.containsKey(ticketKey(deviceId)));
            if (cred != null) {
                try {
                    JSONObject parsed = new JSONObject(new String(cred, StandardCharsets.UTF_8));
                    JSONObject account = parsed.getJSONObject("account");
                    out.put("credNotBefore", account.optLong("not_before"));
                    out.put("credNotAfter", account.optLong("not_after"));
                    out.put("trustedType", parsed.optInt("trusted_type"));
                } catch (Exception parseError) {
                    out.put("credParseError", parseError.getClass().getSimpleName());
                }
            }
            return out.toString();
        } catch (Exception error) {
            return "{\"deviceId\":\"" + deviceId + "\",\"error\":\"" + error.getClass().getSimpleName() + "\"}";
        }
    }

    private static String credKey(String deviceId) {
        return "identity-cred:" + deviceId;
    }

    private static String ticketKey(String deviceId) {
        return "identity-ticket:" + deviceId;
    }

    private static String requireArg(String[] args, int index, String usage) {
        if (args.length <= index || args[index].isEmpty()) {
            throw new IllegalArgumentException("usage: LyraSeed " + usage);
        }
        return args[index];
    }

    private static Map<String, byte[]> readEntries() throws Exception {
        return readEntries(STORE);
    }

    private static Map<String, byte[]> readEntries(String path) throws Exception {
        SecretKey key = loadKey();
        byte[] file = Files.readAllBytes(Paths.get(path));
        if (file.length < 21 || file[0] != 'L' || file[1] != 'Y' || file[2] != 'R' || file[3] != 'A') {
            throw new IllegalStateException("bad magic");
        }
        byte version = file[4];
        ByteBuffer head = ByteBuffer.wrap(file).order(ByteOrder.BIG_ENDIAN);
        int crc = head.getInt(9);
        int encLen = head.getInt(13);
        if (encLen < 0 || 17 + encLen > file.length) {
            throw new IllegalStateException("bad encLen=" + encLen);
        }
        byte[] enc = new byte[encLen];
        System.arraycopy(file, 17, enc, 0, encLen);
        CRC32 crc32 = new CRC32();
        crc32.update(enc);
        if ((int) crc32.getValue() != crc) {
            throw new IllegalStateException("crc mismatch");
        }
        byte[] plain = decrypt(key, enc);
        if (plain == null) {
            throw new IllegalStateException("decrypt failed");
        }
        ByteBuffer in = ByteBuffer.wrap(plain).order(ByteOrder.BIG_ENDIAN);
        int count = in.getInt();
        Map<String, byte[]> entries = new LinkedHashMap<>();
        for (int i = 0; i < count; i++) {
            int klen = in.getInt();
            byte[] k = new byte[klen];
            in.get(k);
            int vlen = in.getInt();
            byte[] v = new byte[vlen];
            in.get(v);
            entries.put(new String(k, StandardCharsets.UTF_8), v);
        }
        return entries;
    }

    private static void writeEntries(Map<String, byte[]> entries) throws Exception {
        SecretKey key = loadKey();
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        bos.write(ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(entries.size()).array());
        for (Map.Entry<String, byte[]> e : entries.entrySet()) {
            byte[] k = e.getKey().getBytes(StandardCharsets.UTF_8);
            bos.write(ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(k.length).array());
            bos.write(k);
            bos.write(ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(e.getValue().length).array());
            bos.write(e.getValue());
        }
        byte[] enc = encrypt(key, bos.toByteArray());
        CRC32 crc = new CRC32();
        crc.update(enc);
        ByteArrayOutputStream fb = new ByteArrayOutputStream();
        fb.write(new byte[] {'L', 'Y', 'R', 'A', readVersion(STORE)});
        fb.write(ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(12).array());
        fb.write(ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt((int) crc.getValue()).array());
        fb.write(ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(enc.length).array());
        fb.write(enc);
        Path tmp = Paths.get(STORE + ".seeded");
        Files.write(tmp, fb.toByteArray());
        System.out.println("wrote " + tmp + " (" + fb.size() + " bytes)");
    }

    private static byte readVersion(String path) throws Exception {
        byte[] file = Files.readAllBytes(Paths.get(path));
        if (file.length < 21) {
            throw new IllegalStateException("store too small");
        }
        return file[4];
    }

    private static SecretKey loadKey() throws Exception {
        Class.forName("android.security.keystore2.AndroidKeyStoreProvider")
            .getMethod("install")
            .invoke(null);
        KeyStore keyStore = KeyStore.getInstance("AndroidKeyStore");
        keyStore.load(null);
        if (!keyStore.containsAlias(ALIAS)) {
            throw new IllegalStateException("keystore alias missing: " + ALIAS);
        }
        return ((KeyStore.SecretKeyEntry) keyStore.getEntry(ALIAS, null)).getSecretKey();
    }

    private static byte[] decrypt(SecretKey key, byte[] packed) throws Exception {
        ByteBuffer in = ByteBuffer.wrap(packed).order(ByteOrder.BIG_ENDIAN);
        int ctLen = in.getInt();
        byte[] ct = new byte[ctLen];
        in.get(ct);
        int ivLen = in.getInt();
        byte[] iv = new byte[ivLen];
        in.get(iv);
        Cipher cipher = Cipher.getInstance(TRANSFORMATION);
        cipher.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(GCM_TAG_BITS, iv));
        return cipher.doFinal(ct);
    }

    private static byte[] encrypt(SecretKey key, byte[] plain) throws Exception {
        Cipher cipher = Cipher.getInstance(TRANSFORMATION);
        cipher.init(Cipher.ENCRYPT_MODE, key);
        byte[] ct = cipher.doFinal(plain);
        byte[] iv = cipher.getIV();
        ByteBuffer out = ByteBuffer.allocate(8 + ct.length + iv.length).order(ByteOrder.BIG_ENDIAN);
        out.putInt(ct.length);
        out.put(ct);
        out.putInt(iv.length);
        out.put(iv);
        return out.array();
    }
}
