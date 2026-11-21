# Research 013: Signing in by itself

Started 2026-11-20. Sources are cited inline; "tested" means run on Toni's Mac.

## Passkeys in an app's own web view (tested 2026-11-20, macOS 27.0.1, set up like Latchkey's own browser)

A probe app built like Latchkey's own browser (a `WKWebView` with a memory-only data store, no
browser entitlement, page loaded as `https://example.com/`) found:

- `PublicKeyCredential` and `navigator.credentials` exist, and the page is a secure context.
- `PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()` answers **false**, so
  sites that check it first hide their passkey button.
- `navigator.credentials.get({publicKey: …})` fails at once with `NotAllowedError: The document
  is not focused.` An off-screen view is never focused, so WebKit's own passkey path can't be
  used there even with the entitlement.
- A `WKUserScript` injected at document start in the page's own world replaced
  `navigator.credentials` (`Object.defineProperty`), and the page's `get` call reached the
  script with its `publicKey` options. So Latchkey can answer a site's passkey request itself;
  the script must also make `isUserVerifyingPlatformAuthenticatorAvailable` (and conditional
  mediation's check) answer true, or sites won't ask.

## Keeping the copies on the Mac (from Latchkey's own code, 2026-11-20)

Latchkey already keeps its pairing record and activity-log key in the Keychain as items
accessible after the first unlock, this device only (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
`macos/App/DeviceIdentity.swift`), and reads them while the Mac is locked with the lid closed
every time it reconnects. Sign-in copies stored the same way are readable whenever Latchkey works
while locked, never sync to iCloud, and stay on this Mac. The rules in `.claude/rules/macos.md`
for Keychain reads (count without data, "couldn't read" is not "isn't there") apply.

## How others answer passkeys in software (2026-11-20)

- Bitwarden's browser extension replaces `navigator.credentials.create`/`get` with a script in
  the page, keeps the originals for fallback, and does the passkey work outside the page
  ([Bitwarden's passkey design](https://contributing.bitwarden.com/architecture/deep-dives/passkeys/implementations/provider/browser-extension);
  source `apps/browser/src/autofill/fido2/content/fido2-page-script.ts`,
  `libs/common/src/platform/services/fido2/fido2-authenticator.service.ts` in
  [bitwarden/clients](https://github.com/bitwarden/clients)). It requires an `https` origin, checks the
  site's passkey name (RP ID) is the page's registrable domain or a parent of it, builds
  `clientDataJSON` (`type`, `challenge`, `origin`, `crossOrigin`), signs ES256 only, and sets the
  backup flags BE=1, BS=1 and counter 0.
- A wrapper in the page's own world can be tampered with by the page's scripts
  ([Scott Helme on 1Password's wrapper](https://scotthelme.co.uk/passkeys-permissions-policy-and-bug-hunting-in-1passwords-webauthn-wrapper/)).
  So the page gets only a thin hook; the key and the signing stay in Latchkey, outside the page.
- No open-source Swift authenticator exists; CryptoKit's P-256 signing is all the signing needs.
  Chrome's DevTools virtual authenticator is for tests only.

## Do moved passkeys keep working? (2026-11-20)

- The export keeps what a site checks: the credential id equals the original, the RP ID and user
  handle match, and the key is the same private key in PKCS#8
  ([CXF 1.0](https://fidoalliance.org/specs/cx/cxf-v1.0-ps-20250814.html)). A passkey with a
  counter above 0 is left out of an export; importers store 0 and never raise it.
- Backup eligibility (BE) is permanent per credential, and a site may refuse an answer whose BE
  differs from registration ([WebAuthn L3](https://w3c.github.io/webauthn/)). Apple's passkeys
  report BE=1, BS=1 ([Apple forum](https://developer.apple.com/forums/thread/813844)), so Latchkey
  answers with BE=1, BS=1, counter 0, ES256. Not confirmed from Apple: that every iCloud Keychain
  passkey was registered with BE=1 (very likely; a live test settles it).

## How other agent tools keep secrets from the model (2026-11-20)

- 1Password's agentic autofill (with Browserbase) injects the credential into the browser "just
  in time", never into the model, logs each use, and matches the site
  ([1Password](https://1password.com/blog/closing-the-credential-risk-gap-for-browser-use-ai-agents),
  [Browserbase](https://browserbase.com/blog/1password-agentic-autofill)). 1Password for Claude
  in Chrome asks for Touch ID per login and has no passkeys
  ([Claude help](https://support.claude.com/en/articles/15936181-get-started-with-1password-for-claude)).
- browser-use shows the model placeholders, fills real values after the model call, ties each
  secret to domain patterns, and skips cross-site frames
  ([browser-use](https://docs.browser-use.com/customize/sensitive-data)).
- Bitwarden's MCP server returns secrets to the model ([Bitwarden](https://bitwarden.com/blog/bitwarden-mcp-server/)):
  the pattern Latchkey avoids.

## Risks (2026-11-20)

- **Which site.** Apple's shared-credentials list must not be used to release a credential
  without the user's review ([apple/password-manager-resources](https://github.com/apple/password-manager-resources)),
  so a fill with nobody watching stays within the site the item was saved for. Filling every
  subdomain let clickjacking steal passwords, codes, and passkeys from 10 of 11 managers
  ([DEF CON 33, The Hacker News](https://thehackernews.com/2025/08/dom-based-extension-clickjacking.html)).
- **Frames.** Filling into another site's frame got Bitwarden criticised
  ([Flashpoint](https://flashpoint.io/blog/bitwarden-password-pilfering/)); passkeys in frames
  need the parent's permission and the site sees `crossOrigin`
  ([web.dev](https://web.dev/articles/webauthn-within-iframe)).
- **New device and automation.** Google blocks embedded and automated sign-ins and challenges
  unknown devices ([Google](https://developers.googleblog.com/2020/08/guidance-for-our-effort-to-block-less-secure-browser-and-apps.html)).
  Hand back, don't retry.
- **Lockouts.** Sites lock after 5 to 10 failures
  ([OWASP](https://owasp.org/www-project-web-security-testing-guide/latest/4-Web_Application_Security_Testing/04-Authentication_Testing/03-Testing_for_Weak_Lock_Out_Mechanism)):
  one try per sign-in, stop at the first failure.

## Verification codes (2026-11-20)

- The export carries them: CXF's TOTP record has a Base32 secret, period (30), digits (6), and
  algorithm (SHA-1/256/512), with issuer and user name; Apple's import API has a matching type
  ([CXF 1.0](https://fidoalliance.org/specs/cx/cxf-v1.0-ps-20250814.html),
  [ASCredentialImportManager](https://developer.apple.com/documentation/authenticationservices/ascredentialimportmanager.md)).
- Codes follow RFC 6238; a site must refuse the same code twice, so a retry waits for the next
  30-second step ([RFC 6238](https://www.rfc-editor.org/rfc/rfc6238)).
- `websites-that-append-2fa-to-password.json` in apple/password-manager-resources names sites
  where the code goes after the password in the same field.
