# Research 006: Computer control

Done 2026-10-22 with 003–005.

## What macOS allows

- Seeing the screen: ScreenCaptureKit (`SCScreenshotManager`), with the Screen Recording
  permission (`CGPreflightScreenCaptureAccess`, `CGRequestScreenCaptureAccess`). Not possible
  while the display is asleep; not available at the login window.
  https://developer.apple.com/forums/thread/827059,
  https://developer.apple.com/forums/thread/814152
- Mouse and keyboard: Quartz events (`CGEvent` posted to the HID event tap), with the
  Accessibility permission (`AXIsProcessTrustedWithOptions`). Events don't reach the lock screen
  or login window, and a password field holding Secure Input blocks synthetic typing.
  https://developer.apple.com/forums/thread/724740
- Reading what's on screen as text: the Accessibility API (`AXUIElement`) gives the front app's
  windows, buttons, and fields with positions, faster and more exact than reading pixels.
- With the lid closed and no monitor there is no display at all; Apple supports lid-closed use
  only with an external display. So computer control works only while the screen is on and
  unlocked (Toni accepted this limit, 2026-10-22).
- State checks: `CGSessionCopyCurrentDictionary` (`CGSSessionScreenIsLocked`), active display
  list (`CGGetActiveDisplayList`), `CGDisplayIsAsleep`. A sleeping display on an unlocked Mac can
  be woken with `IOPMAssertionDeclareUserActivity`; if macOS then shows the lock screen, Claude
  is told the Mac is locked. Latchkey never types a password.

## Existing designs

- Claude's own computer-use tool takes screenshots and acts on pixel coordinates (click, type,
  key with combinations, scroll, drag, mouse move), with screenshots scaled down so the longest
  side is at most about 1,568 px; coordinates refer to the scaled image.
  Custom connectors can't use that built-in tool, so Latchkey offers the same actions as MCP
  tools that return images.

## Choices (low-level, Claude's)

- **Coordinates**: in the last screenshot's pixels; Latchkey maps them to screen points using
  that screenshot's scale and display. Each screenshot says its size.
- **Displays**: the main display by default; `display` picks another (numbered in
  `computer_screenshot`'s answer).
- **Keys**: names like `cmd+shift+4`, `return`, `escape`, `tab`, arrows, `f1`–`f12`, mapped to
  virtual key codes; text is typed as Unicode events, so any language works.
- **Text of the screen** (`computer_ui`, Read only level): the front window's elements (role,
  label, value, position) from the Accessibility API, at most 300.
- **Visibility**: the first action after 5 minutes without one posts a notification "Claude is
  using your screen"; every action is in the activity list; the busy dot shows while acting.
