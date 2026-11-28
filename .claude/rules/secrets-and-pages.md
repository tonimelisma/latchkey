---
paths:
  - "macos/App/SignIn/**"
  - "macos/App/Browser/**"
  - "macos/App/Messages/**"
  - "macos/App/Mail/**"
---

# Secrets, pages, and queued actions (security reviews, 2026-11-22)

Three classes of bug an automated review found only after install; check each change for them,
and have the diff reviewed before commit (CLAUDE.md, "Engineering practices"):

1. Never rerun, branch, or retry on output the page controls (a script's result text, a page
   title): decide from what the app itself knows (the browser's own address, JavaScriptCore's
   syntax check), so a page can't make an action run twice.
2. A secret (password, code from Passwords) goes only into a field of the checked kind on the
   saved site, is typed together with the press that sends it, is emptied right after, and is
   blanked out of every answer.
3. An action queued for later (a delete or archive at the next unlock) checks again, when it
   runs, that it is still allowed (the capability's level), not only when it was queued.
