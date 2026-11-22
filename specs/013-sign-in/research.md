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

## Receiving Apple's export (2026-11-20)

- **What the app ships.** An AutoFill credential provider extension
  (`ASCredentialProviderViewController`, extension point
  `com.apple.authentication-services-credential-provider-ui`), with the entitlement
  `com.apple.developer.authentication-services.autofill-credential-provider` on the app and the
  extension ([Apple](https://developer.apple.com/documentation/authenticationservices/ascredentialproviderviewcontroller.md)).
  The extension's `ASCredentialProviderExtensionCapabilities` set `SupportsCredentialExchange`
  and `SupportedCredentialExchangeVersions = ["1.0"]`; the app lists
  `ASCredentialExchangeActivityType` in `NSUserActivityTypes`
  ([ASCredentialImportManager](https://developer.apple.com/documentation/authenticationservices/ascredentialimportmanager.md)).
  Extensions are sandboxed; the app needn't be (not stated by Apple outright:
  [forum](https://developer.apple.com/forums/thread/718589)).
- **The import runs in the app.** macOS opens the app with a user activity holding a one-time
  token; `importCredentials(token:)` returns the data. No file is written
  ([importCredentials](https://developer.apple.com/documentation/authenticationservices/ascredentialimportmanager/importcredentials(token:).md)).
- **Needs the paid Apple Developer Program.** "AutoFill credential provider" is available to
  paid members and Developer ID, not to free (Personal Team) accounts
  ([Apple, supported capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-macos)).
  Latchkey is signed today with Toni's free Apple Development certificate (STATUS: the $99
  program is "later, Toni's call").
- **What comes.** Per item: title, site addresses (`scope.urls`), dates; credentials of kind
  password (user name, password), passkey (credential id, RP ID, user name and display name,
  user handle, private key in PKCS#8), TOTP, notes, cards
  ([ASImportableCredential](https://developer.apple.com/documentation/authenticationservices/asimportablecredential.md),
  [Passkey](https://developer.apple.com/documentation/authenticationservices/asimportablecredential/passkey.md)).
  Apple's Passwords sends logins, passkeys, and verification codes; the Apple Account's own
  passkey isn't exportable ([Bitwarden](https://bitwarden.com/en-gb/help/import-from-safari.md),
  [Six Colors](https://sixcolors.com/post/2025/09/export-keys-securely-from-passwords-to-third-party-managers/)).
  Selected items can be sent, on Mac and iPhone.
- **A snapshot, never a sync.** Nothing pushes later changes in Passwords to the importer; the
  provider's "report" callbacks are signals from sites, and save requests exist on iOS only
  ([WWDC25 279](https://developer.apple.com/videos/play/wwdc2025/279/)). Keeping the copies
  current means exporting again.
- **No AutoFill offers elsewhere.** Registering identities in `ASCredentialIdentityStore` is
  optional; without it macOS shows no suggestions from Latchkey (whether an enabled provider
  still shows a generic entry is to be tested).
- **Early trouble.** Apps missing from the export list were reported and fixed by Apple in
  26.4 ([forum](https://developer.apple.com/forums/thread/819382)); whether Latchkey must be
  switched on under AutoFill & Passwords first is to be tested.
- **The fallback without the program: the CSV file.** Passwords' File → Export All Passwords to
  File writes passwords, user names, sites, notes, and verification codes (an `OTPAuth` column),
  never passkeys, unencrypted ([Apple](https://support.apple.com/guide/passwords/mchl35b12625/mac)).

## Passkeys elsewhere (2026-11-20)

- WebKit's own passkeys need the `com.apple.developer.web-browser.public-key-credential`
  entitlement, for apps that can be the default browser, by request and review
  ([Apple](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential.md),
  [WebKit bug 237380](https://bugs.webkit.org/show_bug.cgi?id=237380)); and off screen the page
  is never focused (tested above). So Latchkey answers passkeys itself in its own browser.
- The hook's messages must take the page's origin from `WKScriptMessage.frameInfo.securityOrigin`,
  never from the page's script ([Apple](https://developer.apple.com/documentation/webkit/wkscriptmessage/frameinfo.md)).
- What the hook must imitate: `PublicKeyCredential` objects (`instanceof`), the availability
  checks, `getClientCapabilities()`, `getClientExtensionResults()`, `toJSON()`, conditional
  requests that wait until aborted. Sites wanting attestation or the PRF extension won't work.
- **Claude's Safari tabs.** Latchkey can't add a script to a Safari page before the page's own
  scripts run, and Safari's own passkeys ask for Touch ID on the screen. A hook added after the
  page loads catches a passkey request started by a button Claude clicks, not one the page starts
  as it opens (to be tested). Passwords and codes fill there like any field.
- **No live access exists.** `SecRequestSharedWebCredential` and `ASAuthorizationPasswordProvider`
  reach only an app's own associated domains, with a sheet on screen
  ([Apple](https://developer.apple.com/documentation/authenticationservices/asauthorizationpasswordprovider.md)).

## Keychain while locked (2026-11-20)

The data protection keychain forgets `WhenUnlocked` secrets some time after the lock (Apple DTS,
[forum](https://developer.apple.com/forums/thread/729835)); `AfterFirstUnlockThisDeviceOnly`
stays readable, as Latchkey's own items already are. The login keychain Latchkey uses today is
"on the road to deprecation" ([TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains.md));
the plan picks one.

## Only a real test settles

1. Latchkey appearing in Passwords' export list (Developer ID, sandboxed stub extension,
   menu-bar app); whether it must be enabled in AutoFill & Passwords first.
2. A menu-bar app receiving the import's user activity.
3. The export's exact content, and Apple's passkey keys loading into CryptoKit as they come.
4. The hook accepted by real sites (BE/BS, frames, conditional requests).
5. Keychain reads hours into a lock, lid closed.

## Can Latchkey export by itself? (2026-11-20)

- Passwords has no scripting dictionary (`sdef /System/Applications/Passwords.app`: error -192,
  no `NSAppleScriptEnabled`; checked on Toni's Mac), so the export can only be run through its
  window, with Accessibility, while the Mac is unlocked.
- Passwords stays locked until the Owner approves with Touch ID or the Mac password, and the
  export asks again ([Apple](https://support.apple.com/guide/passwords/mchl35b12625/mac); community
  posts). macOS's password prompts are believed to ignore typed input from other programs (not
  tested: the test would take over Toni's screen). Apple's export to another app (later, with the
  paid program) asks for Touch ID too. So every export needs the Owner; Latchkey runs every other
  step (Toni chose "One touch, when you click").
- To test in the plan: the menu path and dialogs of Passwords on macOS 27 through Accessibility,
  and choosing the save folder in its save panel.

## Building it (2026-11-21)

- **Tool shape.** MCP research: Anthropic's connector rules reject a tool that both reads and
  writes, and Claude's apps approve read-only tools without asking
  ([review criteria](https://claude.com/docs/connectors/building/review-criteria),
  [define tools](https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools));
  names follow Latchkey's own `noun_verb`. So `logins_find` (read-only, `openWorld` false) and
  `logins_sign_in` (write, not destructive, open world). Secrets never pass through the model,
  as the MCP spec asks for sensitive data
  ([elicitation](https://modelcontextprotocol.io/specification/2025-11-25/client/elicitation));
  Playwright MCP's `--secrets` and browser-use's placeholders do the same with less: values
  still reach the page from the model's side, and Playwright calls it "a convenience, not a
  security boundary" ([Playwright MCP](https://playwright.dev/mcp/configuration/options),
  [browser-use](https://docs.browser-use.com/customize/agent/sensitive-data)). Toni chose two
  tools.
- **Shared hosts.** A sign-in saved for a shared host (`herokuapp.com`, `github.io`) would also
  fill on every customer's subdomain. Latchkey bundles the Public Suffix List
  (`macos/App/SignIn/Resources/public_suffix_list.dat`, MPL 2.0, from
  [publicsuffix.org](https://publicsuffix.org/list/public_suffix_list.dat), ICANN and private
  sections) and fills such a site on its own host only. International names (the list writes
  them in Unicode, hosts arrive as punycode), and names with a trailing or doubled dot, count as
  suffixes too: the safe side. Options weighed: an exact-host rule (Toni chose subdomains), a
  hand list of shared hosts (incomplete), the list (chosen; refresh it with the release).
- **Where the page is.** A page's scripts can rewrite JavaScript's own functions (`JSON`,
  `String.prototype`), so an address a script reports could be another site's. Latchkey reads
  the address from WebKit (`WKWebView.url`) or Safari (AppleScript's URL of the tab), decides
  the site in Swift, and the fill script checks again with `location` (which no script can
  replace) and `===` only. In Latchkey's own browser the sign-in scripts run in a content world
  of their own (`WKContentWorld.world(name:)`), which the page's scripts can't reach; the DOM and
  its events are shared, so the site's own handlers see the typing as usual. Safari's
  `do JavaScript` has no such world. Tested: `SignInPageTests.aPageThatRewritesBuiltInsGetsNothing`,
  `SignInToolsTests.aPageCantClaimAnotherSitesAddress`.
- **Clearing.** Filled fields are cleared after every sign-in, and also when a step fails.
- **Safari's script arguments.** Short scripts went to `osascript` as arguments, which other
  programs of the user can see; sign-in scripts always go through the 0600 file instead.
- **The export's save panel.** Accessibility gives a new reference to the same element on every
  look, so elements are compared with `CFEqual`. The panel is cancelled when anything is
  unexpected before Save, and a file saved elsewhere after all is found by its unique name and
  wiped (security review, 2026-11-21).
- **A browser's own checks.** A user name that isn't an email, in a field of type email, stops
  the form in the browser itself (seen in the tests); real sites with email fields have email
  user names.
- **The moment the export exists.** For half a second, until Latchkey wipes it, the exported file
  sits in the import folder. Claude's command line runs in Latchkey's sandbox, which now denies
  reading that folder (`Fence.profile`), and Files refuses it (`OwnFiles.secret`); writing there
  was already refused (Latchkey's own files). So the live check's test sign-in is placed by
  `macos/scripts/state-check/logins-fixture.sh`, run by the operator, never by Claude; it refuses
  while Latchkey holds sign-ins it didn't leave (security review, 2026-11-21).

## Fill-only sign-in (2026-11-22)

Toni: "It sounds like you've built [it] completely in the wrong way. It's just deterministic code.
Is it making guesses on whether a page was logged in or not? Shouldn't the code just provide
what's happening in the browser and the agent makes the presumptions?" The one-call sign-in read
each page with word and field patterns (a password page, a code step, "make sure it's you", a
captcha, a passkey page), waited fixed times (3, 8, 40 s), decided "signed in", "refused",
"check", pressed "Text me" itself, counted refusals, and switched a site to Safari's sign-in. Two
days of live tests (Citi, Costco, eBay, Amazon, IKEA, United, GitHub) found most failures there:
"Signed in" on Citi's code step, "refused" when Citi was slow and when Costco's bot check
answered, a call past the relay's 60 s, a switch that dropped a half-done sign-in. Options:
(a) fill-only: Latchkey types one saved value into the field Claude names and presses the button
Claude names, nothing else; Claude reads the page (more calls, about 5 to 8 a sign-in; no
guessing, no long calls). (b) one call that fills and presses the form's button but reports only
facts (fewer calls; still decides which button and how long to wait). Toni chose (a). What stays
in Latchkey is only what Claude must not see or do: the secrets, the site and field-type checks,
emptying the fields, finding and deleting the code's text. A password or code is always typed
together with the press, then emptied, so no script Claude runs can read it in between.

## Codes experiment (2026-11-22)

Toni: "test all approaches for robustness on a wide variety of web sites, and inform me what the
results are". Three ways to get a texted or emailed code into the page, all in `logins_fill`:

1. Claude reads it (messages_read / mail_read or its own email tool) and passes `code`; Claude
   deletes or archives the message. Claude sees the digits.
2. `code_from`: Latchkey finds and types it; Claude never sees the digits (closest to Apple's and
   1Password's own autofill of codes, and to the origin-bound code line `@site #code`).
3. `check_code`: Claude passes the code it read; Latchkey types it only if a recent message that
   may be the site's holds it, so a code made up or read off a web page is never typed.

What "may be the site's" means (security review 2026-11-22): a text whose site-bound last line
names another site never is; an email must name the site as a whole word; any other text may
be (Toni, 2026-11-21: "Any new code text"), since most code texts come from short numbers and
name no domain. So another site's plain code text that came in the same few minutes can be
typed; of several, one naming the site is taken first. Kept as Toni decided; noted here for the
results report.

Low-level choices (decided here, not product choices): the window a code counts in is from the
password Latchkey typed on the site within 10 minutes, else the last 3 minutes (a code older than
that belongs to another sign-in); the newest unused message wins (an older resend is the fallback
once the newest is used); a message is marked used only after the code was typed and the button
pressed, so a refused field leaves it for the next call; Latchkey cleans up in ways 2 and 3
because it knows which message it used, while in way 1 Claude does. The reading is in
`CodeFinder` (Messages' database, Apple Mail's files; never a window).
