# Signing Downstroke

macOS ties the Input Monitoring permission to the app's code signature. An ad-hoc signature changes on every build, so macOS would ask for permission again after each rebuild. A self-signed certificate, created once, keeps the signature stable.

## One-time setup

1. Open **Keychain Access**.
2. From the menu bar, choose **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Fill in:
   - **Name:** `Downstroke Local Signing`
   - **Identity Type:** Self Signed Root
   - **Certificate Type:** Code Signing
4. Click **Create**, then **Done**. It goes into your login keychain.
5. Check it's usable:

   ```bash
   security find-identity -p codesigning
   ```

   You should see a line with `"Downstroke Local Signing"`, probably marked `CSSMERR_TP_NOT_TRUSTED`. That's expected for a self-signed certificate and doesn't stop it signing. Don't use `-v`, which lists only trusted identities.

If Keychain Access saves the certificate to iCloud or Local Items, code signing can't see it. Recreate it with **Let me override defaults** ticked, and choose the **login** keychain.

### Or import a ready-made certificate

If you have a `.p12` file containing the `Downstroke Local Signing` certificate and key, import it into the login keychain and let `codesign` use it:

```bash
security import downstroke-signing.p12 -k ~/Library/Keychains/login.keychain-db -P <p12 password> -T /usr/bin/codesign
```

The first time `scripts/bundle.sh` signs with it, macOS may ask to let `codesign` use the key. Choose **Always Allow**.

## Using a different identity

Set `DOWNSTROKE_SIGN_IDENTITY` to the certificate's name, for example an Apple Developer ID:

```bash
DOWNSTROKE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/bundle.sh
```

Changing the identity later resets the Input Monitoring permission once.
