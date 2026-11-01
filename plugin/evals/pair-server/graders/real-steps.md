---
type: llm
---

PASS if the steps include all three of: (1) getting the install line (or install command) from
the relay's account page, (2) running it on the server as a normal user rather than root, and
(3) typing the code it shows on the relay's /link page (or an equivalent page on the relay) to
approve the server.
FAIL if any of the three is missing, or if it tells the person to open ports, forward ports on
the router, or edit firewall rules.
