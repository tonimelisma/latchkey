# 0043. Reading

- Status: accepted
- Date: 2026-10-22
- Alias: plan 003 D2 (`specs/003-files/plan.md`, "D2. Reading")

## Context and problem

Decision D2 of spec 003's plan (Files); requirements in
[requirements/files.md](../requirements/files.md). Requirement IDs it cites: FR-217, FR-216.
The design it belongs to: [design/files.md](../design/files.md).

## Decision


Plain text by encoding detection; PDFs with PDFKit; .docx/.doc/.rtf/.rtfd/.odt with
`NSAttributedString`, its document type always named; .html and .webarchive with Foundation's
XML parser in HTML mode, which loads nothing the page links to (research: HTML without network
loads); images with the shared image preparation (spec 002). Other files:
details only, with "not readable as text". At most 100,000 characters per answer, `offset` to
continue (FR-217). Each answer starts by saying the content is the file's (FR-216).
Files over 100 MB aren't read: the size is that of the file a symbolic link points to (a link's
own size is a few bytes), and the read itself stops past 100 MB; pipes and devices aren't read
(security scan, 2026-10-24).
Cloud-only files (a placeholder on the disk: iCloud Drive, OneDrive, Dropbox, Google Drive, any
File Provider) are downloaded first through file coordination (`NSFileCoordinator`), falling back to
`FileManager.startDownloadingUbiquitousItem`, for up to 20 s in all; a stuck coordination is
cancelled. A file that still isn't here is read anyway (the read itself may fetch it); if that
fails, the answer says it is kept in the cloud and gives macOS's error codes, and Latchkey's log
records them without the file's name. Why (2026-11-04): macOS refused
`startDownloadingUbiquitousItem` to the installed app for a OneDrive photo with "you don't have
permission", while the same call worked from a plain program and coordination worked even with
downloads switched off for the process; the old code stopped at that refusal, so every cloud-only
OneDrive file failed. Every other unexpected Files error also carries macOS's codes.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/FilesTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
