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
