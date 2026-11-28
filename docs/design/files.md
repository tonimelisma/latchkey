# Files: design

GOVERNS: `macos/App/Files/`

Spec 003's plan (migrated from `specs/003-files/plan.md`, titled "Plan 003: Files — HOW"). What it must do:
[requirements/files.md](../requirements/files.md). Each decision Dn is an ADR, linked
where the decision stood.

Derived from `docs/requirements/files.md`; evidence and low-level choices in `docs/research/2026-10-22-files.md`.

## D1. Tools

Decision record: [ADR 0042](../adr/0042-tools.md).

## D2. Reading

Decision record: [ADR 0043](../adr/0043-reading.md).

## D3. Changing

Decision record: [ADR 0044](../adr/0044-changing.md).

## D4. Search

Decision record: [ADR 0045](../adr/0045-search.md).

## D5. Levels and setup

Decision record: [ADR 0046](../adr/0046-levels-and-setup.md).

## Testing (Constitution VII)

Tests against a temporary folder: read text, PDF (made with PDFKit), RTF, image; offset paging;
search through a fake runner for `mdfind` and one real `mdfind` call on a temporary file;
write/overwrite rules; edit exactly-once; move/copy refusals; trash puts the file in the Trash
(checked, then removed from the Trash by the test); tool list per level. Own files (FR-210): a
stand-in data folder, settings, and app in the temporary folder; every change refused, also by
other letter case, `..`, and links; reads and other apps' settings still work.

## Constitution check

| Article | Status |
|---|---|
| I. Outbound only | Pass: no change |
| II. Fail fast | Pass: deadlines on every tool; cloud downloads capped at 20 s, a stuck one cancelled |
| III. Disabled means nonexistent | Pass: tools per level |
| IV. Good macOS citizen | Pass: Full Disk Access granted by the Owner; Trash, never erase |
| V. Self-hostable | Pass: relay unchanged |
| VI. Store the minimum | Pass: no index or copies kept; Spotlight is the system's |
| VII. Test-first | Planned above |
| VIII. Simplicity | Pass: Foundation, PDFKit, mdfind; no new dependencies |
| IX. Open source | Pass |
