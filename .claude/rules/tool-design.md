---
paths:
  - "macos/App/**/*Capability*.swift"
  - "macos/App/**/*Tools*.swift"
  - "macos/App/Browser/**"
  - "macos/App/SignIn/**"
  - "specs/**"
  - "relay/internal/mcpserver/**"
---

# Tool design: thin actions, Claude judges (Constitution X)

- A tool does one action Claude names and answers with what it did and the state as it is (the
  page, the record), never what that state means: no "signed in", "refused", "done". Its
  success means the action ran, not that the goal was reached.
- It never takes a step Claude didn't name (pressing "Text me", switching browsers), never
  retries or waits a fixed time for content, never counts failures, never remembers a choice for
  later chats. Each of these became a bug in the sign-in tool (2026-11-21/22, spec 013).
- The tool owns only what Claude must not or cannot do: holding and typing secrets, where a secret
  may go (field kind, the saved site), deadlines (Constitution II), never disturbing the user
  (IV), cleaning up what it typed. Each such rule names its reason in a comment.
- Guidance goes in the tool's description ("read the page and judge", "if a site's bot
  protection turns this browser away while locked, tell the owner"), not in branching code.
- A spec line like "the answer shall say whether X worked" or "Latchkey shall decide" is a warning
  sign: raise it with Toni as a product choice before planning it.
- Errors name the fix and the current value ("e5 isn't a password field (it is a search field)").
- Tool names: a tool keeps its name while it behaves the same; a tool whose behavior changes gets
  a new name, and open chats break (Toni, 2026-11-22: "just break old chats"; Claude's apps keep
  the tool list a chat started with, even after the relay's list-changed notice). The reply that
  ships a rename says which chats must be restarted.
