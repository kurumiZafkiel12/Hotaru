import java.io.ByteArrayInputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.util.Base64;
import java.util.HexFormat;
import java.util.Properties;

class FormalSigningPreflight {
    static final String EXPECTED = "7963ba5a3728d320e82cdfb43d58f7d32bdffd419113e2850de7ea2f2b987faa";
    static String required(String name) {
        String value = System.getenv(name);
        if (value == null || value.isEmpty()) throw new IllegalStateException("Missing signing binding: " + name);
        return value;
    }
    static boolean unlocks(KeyStore store, String alias, char[] password) {
        try { return store.getKey(alias, password) != null; }
        catch (Exception error) { return false; }
    }
    public static void main(String[] args) throws Exception {
        byte[] encoded = Base64.getMimeDecoder().decode(required("KEYSTORE"));
        String alias = required("KEY_ALIAS");
        char[] storePassword = required("STORE_PASSWORD").toCharArray();
        char[] keyPassword = required("KEY_PASSWORD").toCharArray();
        KeyStore store = KeyStore.getInstance("PKCS12");
        try { store.load(new ByteArrayInputStream(encoded), storePassword); }
        catch (Exception error) { throw new IllegalStateException("Cannot open PKCS12 with STORE_PASSWORD"); }
        if (!store.isKeyEntry(alias)) throw new IllegalStateException("KEY_ALIAS does not identify a private key");
        String fingerprint = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(store.getCertificate(alias).getEncoded()));
        if (!EXPECTED.equals(fingerprint)) throw new IllegalStateException("Certificate differs from user-confirmed SHA256: " + fingerprint);
        boolean configuredPasswordWorks = unlocks(store, alias, keyPassword);
        boolean storePasswordWorks = unlocks(store, alias, storePassword);
        if (!configuredPasswordWorks && !storePasswordWorks) throw new IllegalStateException("Neither configured KEY_PASSWORD nor STORE_PASSWORD unlocks the private key");
        char[] effectivePassword = configuredPasswordWorks ? keyPassword : storePassword;
        System.out.println("{\"certificate_sha256\":\"" + fingerprint + "\",\"configured_key_password_valid\":" + configuredPasswordWorks + ",\"store_password_unlocks_key\":" + storePasswordWorks + "}");
        String configPath = System.getenv("SIGNING_CONFIG_PATH");
        if (configPath != null) {
            Path keyPath = Path.of(required("SIGNING_KEYSTORE_PATH"));
            Files.write(keyPath, encoded);
            Files.setPosixFilePermissions(keyPath, PosixFilePermissions.fromString("rw-------"));
            Path config = Path.of(configPath);
            Properties properties = new Properties();
            if (Files.exists(config)) try (var input = Files.newInputStream(config)) { properties.load(input); }
            properties.setProperty("keyAlias", alias);
            properties.setProperty("storePassword", new String(storePassword));
            properties.setProperty("keyPassword", new String(effectivePassword));
            try (OutputStream output = Files.newOutputStream(config)) { properties.store(output, "Android signing configuration"); }
            Files.setPosixFilePermissions(config, PosixFilePermissions.fromString("rw-------"));
        }
    }
}
