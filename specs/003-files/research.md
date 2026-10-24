# Research 003: Files

Done 2026-10-22, together with 004–006 (Toni: research everything first, then build in one go).
Claude's app limits (240 s per call, ~150,000-character results, both hints on every tool, no
server push) are in `specs/002-notes-messages/research.md`.

## Existing servers

- The reference filesystem server (`@modelcontextprotocol/server-filesystem`): read text with
  head/tail, read media as image content, read several files, write, edit by exact text
  replacement with a dry run and a diff, create folder, list (with sizes), move (never
  overwrites), glob search, tree, file info. Confined to allowed folders. Read tools are
  `readOnlyHint`; write, edit, and move are destructive.
  https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem
- Desktop Commander adds PDF and Excel reading, paged reads (1,000 lines), and streaming search.
  It notes folder limits don't apply to its shell. https://github.com/wonderwhy-er/DesktopCommanderMCP

## macOS

- Folders macOS protects (Desktop, Documents, Downloads, iCloud Drive, removable and network
  volumes, other apps' data) are covered by Full Disk Access, which Latchkey already asks for
  (spec 002). No new permission.
- Trash: `FileManager.trashItem(at:resultingItemURL:)` moves to the Trash of the file's volume,
  and the Finder's "Put Back" works.
- Search: Spotlight (`mdfind`) answers name and content queries over the whole Mac in well under
  a second and can be limited to a folder (`-onlyin`). Folders Spotlight skips (hidden, excluded
  in settings) need a walk of the folder.
- Text out of documents: PDFKit gives a PDF's text page by page; `NSAttributedString` reads
  .docx, .doc, .rtf, .rtfd, .odt, .html, and .webarchive (what `textutil` uses). Spreadsheets
  and slides (.xlsx, .numbers, .pptx, .key) have no system reader; their files are listed as
  not readable as text.
- Files keep working while the screen is locked (FileVault keeps the disk unlocked after login).

## Choices (low-level, Claude's)

- **Paths**: absolute, or starting with `~`; anything else is taken from the home folder.
  Results always give absolute paths.
- **Reading**: text by UTF-8, then UTF-16 or Latin-1 when that fails; at most 100,000
  characters per call with `offset` to continue (FR-151 style). Images through the shared image
  preparation (JPEG/PNG, longest side 1,568 px). PDFs and documents as text.
- **HTML without network loads** (security scan, 2026-10-24: reading an attacker's HTML file made
  the Mac fetch its images, so a read-only tool sent requests to the internet and the LAN).
  `NSAttributedString` imports HTML and web archives through WebKit, and its header says that
  without a resource-load delegate "a default delegate will be used that will permit the loading
  of subsidiary resources". Options weighed:
  1. `NSAttributedString` with `NSWebResourceLoadDelegateDocumentOption` and a delegate that
     refuses every request. Keeps WebKit's text layout. Cons: the delegate protocol belongs to
     the legacy WebView (deprecated), the importer must run on the main thread, and whether
     every load (CSS `url()`, `@import`, frames, prefetch, the DTD) goes through the delegate is
     WebKit's internal behavior, not something Latchkey can show.
  2. Render in an offline `WKWebView` with a content rule list that blocks every load, then
     read `innerText`. Cons: main thread, a web process per read, asynchronous loading to wait
     for, and the same "trust the blocker" question.
  3. Foundation's `XMLDocument` with `.documentTidyHTML` and `.nodeLoadExternalEntitiesNever`,
     then a small walk of the tree for text (block elements start new lines; head, script,
     style, frames skipped). It is a parser with no idea of images, style sheets, scripts, or
     frames, and the option stops the one load it could do (external entities and DTDs). Web
     archives are property lists: the main resource's bytes and text encoding are read and
     the archived subresources ignored. Cons: plainer text than WebKit's (no list bullets).
     **Chosen**: no network by construction, works off the main thread, no new dependency.
  A test reads an HTML file and a web archive linking images (http and https), a style sheet,
  a script, a frame, a CSS background, a DTD, and an external entity at a local listener, and
  checks the listener saw no connection at all (before the change it saw several).
  The other documents (.rtf, .rtfd, .docx, .doc, .odt) stay with `NSAttributedString`, now with
  the document type named so a file's content is never sniffed as HTML; those importers are
  AppKit's own, not WebKit.
- **Size**: the 100 MB limit is checked on the file a symbolic link points to, and plain reads
  stop at 100 MB whatever the size said.
- **Search**: `mdfind` run as a process with a 20 s deadline, results newest first by
  modification date, folder filter, at most 200. Pros: fast, content search for free, no index
  of our own (Constitution VI). Cons: misses what Spotlight skips; said so in the tool
  description. Chosen.
- **Edit**: exact passage that must appear once, like `notes_update` edit.
- **Overwrite**: writing to an existing file needs `overwrite: true`; moves and copies never
  replace an existing file.
- **Others' words**: file contents are what someone wrote (downloads, mail attachments), so
  every read result says the content is the file's, not instructions (as in spec 002 D6).
