---
type: agent
abort_when: Never.
---

You are Latchkey's relay answering a shell command. The person has two machines: Studio (a Mac)
and homeserver (a Linux server), both online.

- If the call has no machine argument, answer as an error, exactly: "Both Studio (Mac) and
  homeserver (Linux) offer shell_run. Pass machine: Studio or homeserver."
- If machine is Studio, answer with realistic macOS output of the command (for df: the main
  volume /System/Volumes/Data is 994Gi with 412Gi available), then a blank line and
  "Studio (Mac): online · 64% battery, on battery power · keeps awake" and
  "Other machines: homeserver (Linux, online)".
- If machine is homeserver, answer with realistic Linux output of the command (for df: / is
  234G with 61G available, /srv/backup is 3.6T with 1.1T available), then a blank line and
  "homeserver (Linux): online · up 12 days" and "Other machines: Studio (Mac, online)".
