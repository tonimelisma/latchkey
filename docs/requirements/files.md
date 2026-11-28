# Files: requirements

Spec 003 (migrated from `specs/003-files/spec.md`, titled "Spec 003: Files — WHAT and WHY"). The how is in
[the design](../design/files.md), each decision in [the ADRs](../adr/README.md) of plan 003.
Each requirement is one `- **ID**` item ending `[verified]` (a test carries
`Validates: <ID>`) or `unverified: <why>`. Withdrawn requirements are kept, undeclared, at
the end as the record. Some items still carry dated notes of how they came to be; the
requirement is the sentence they qualify.

Renumbered in the migration (the same IDs existed in spec 001): FR-201 is now FR-211, FR-202 is now FR-212, FR-203 is now FR-213, FR-204 is now FR-214, FR-205 is now FR-215, FR-206 is now FR-216, FR-207 is now FR-217.

Status: Built without a review stop (decided 2026-10-22); reviewed and approved 2026-10-29.
Scope: Claude finds, reads, creates, changes, moves, copies, and deletes files on the Mac.
Out of scope: running programs (spec 004), browsing (005), the screen (006).

## Problem

Documents, downloads, photos and projects live on the Mac. From a phone, Claude can't look up
"the lease PDF in Downloads", tidy a folder, or save a draft next to the other files.

## User stories

### US1 (P1): Find and read my files from anywhere
1. Given Files is Read only or more, when I ask "what does my lease say about pets?", then
   Claude finds the lease and answers from its text.
2. Given a photo on the Mac, when I ask about it, then Claude can look at it.

### US2 (P1): Change my files
1. Given Files is Read & write, when I ask Claude to save a draft to Documents, then the file is
   there.
2. Given I ask Claude to delete a file, then it goes to the Trash, where I can put it back.
3. Given I ask Claude to tidy Downloads, then Claude can make folders and move files.

## Requirements

- **FR-211** (renumbered from spec 003 FR-201, a duplicate of spec 001's) While Files is Read only or Read & write, Claude shall be able to search files by
  name and content, list a folder, see a file's details, and read a file: text, the text of PDFs
  and documents, and images as images; a PDF without text (a scan) as a picture of the page asked
  for (2026-11-01: it read as nothing). unverified: no test cites it yet (migrated from spec 003 without one; #75)
- **FR-212** (renumbered from spec 003 FR-202, a duplicate of spec 001's) While Files is Read & write, Claude shall be able to create and change text files,
  edit a passage of a text file, create folders, move, rename, and copy files and folders, and
  delete them. unverified: no test cites it yet (migrated from spec 003 without one; #75)
- **FR-213** (renumbered from spec 003 FR-203, a duplicate of spec 001's) Deleting shall move to the Trash, never erase. unverified: no test cites it yet (migrated from spec 003 without one; #75)
- **FR-214** (renumbered from spec 003 FR-204, a duplicate of spec 001's) Moving or copying shall never replace an existing file; writing over an existing
  file shall happen only when Claude asks for it explicitly. [verified]
- **FR-215** (renumbered from spec 003 FR-205, a duplicate of spec 001's) Claude shall reach every file on the Mac the Owner's account can open, anywhere on
  the disk, such as the home folder, iCloud Drive, apps, and connected drives (decided 2026-10-22;
  worded as the whole disk, decided 2026-10-29). The one exception is FR-210. unverified: no test cites it yet (migrated from spec 003 without one; #75)
- **FR-216** (renumbered from spec 003 FR-206, a duplicate of spec 001's) File contents shall be marked as the file's content, not instructions (as spec 002
  FR-114). [verified]
- **FR-217** (renumbered from spec 003 FR-207, a duplicate of spec 001's) Results shall stay within Claude's result size, saying when shortened and how to
  read on. unverified: no test cites it yet (migrated from spec 003 without one; #75)
- **FR-208** When Claude creates, changes, moves, or deletes a file, the Mac shall show a
  notification and list it in the menu's activity (as spec 002 FR-130, FR-131). unverified: no test cites it yet (migrated from spec 003 without one; #75)
- **FR-209** Files shall have the levels Off, Read only, Read & write, and start at Read & write
  (decided 2026-10-22). unverified: no test cites it yet (migrated from spec 003 without one; #75)
- **FR-210** When Claude asks to create, change, move, rename, copy onto, or delete one of
  Latchkey's own files (its activity log and other data, its settings, or the app itself), or
  to move or delete a folder that holds them, Files shall refuse and change nothing. Claude can
  still read them (security review, 2026-10-25). [verified]

## Success criteria

- **SC-201** From the phone, "find my lease and tell me the pet rules" answers from the file. unverified: no test cites it yet (migrated from spec 003 without one; #75)
- **SC-202** A deleted file is in the Trash and can be put back. unverified: no test cites it yet (migrated from spec 003 without one; #75)
- **SC-203** With Files Off or Read only, the excluded tools never appear (test suite). unverified: no test cites it yet (migrated from spec 003 without one; #75)

## Edge cases

- Files Spotlight doesn't index (hidden folders, excluded locations): search says so; listing
  still works.
- Cloud files not downloaded yet (iCloud Drive, OneDrive, Dropbox, Google Drive): reading downloads
  them first, or says it can't within the time limit.
- Very large files and binary files; names with unusual characters; files that change while read.
- Latchkey's own files reached by another spelling of the path (letter case, `..`, a link): still
  refused (FR-210).
