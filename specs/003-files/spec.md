# Spec 003: Files — WHAT and WHY

Status: Approved to build without a review stop (Toni, 2026-10-22); Toni reviews at the end.
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

- **FR-201** While Files is Read only or Read & write, Claude shall be able to search files by
  name and content, list a folder, see a file's details, and read a file: text, the text of PDFs
  and documents, and images as images.
- **FR-202** While Files is Read & write, Claude shall be able to create and change text files,
  edit a passage of a text file, create folders, move, rename, and copy files and folders, and
  delete them.
- **FR-203** Deleting shall move to the Trash, never erase.
- **FR-204** Moving or copying shall never replace an existing file; writing over an existing
  file shall happen only when Claude asks for it explicitly.
- **FR-205** Claude shall reach every file the Owner can open: the home folder, iCloud Drive,
  and connected drives (Toni, 2026-10-22). The one exception is FR-210.
- **FR-206** File contents shall be marked as the file's content, not instructions (as spec 002
  FR-114).
- **FR-207** Results shall stay within Claude's result size, saying when shortened and how to
  read on.
- **FR-208** When Claude creates, changes, moves, or deletes a file, the Mac shall show a
  notification and list it in the menu's activity (as spec 002 FR-130, FR-131).
- **FR-209** Files shall have the levels Off, Read only, Read & write, and start at Read & write
  (Toni, 2026-10-22).
- **FR-210** When Claude asks to create, change, move, rename, copy onto, or delete one of
  Latchkey's own files (its activity log and other data, its settings, or the app itself), or
  to move or delete a folder that holds them, Files shall refuse and change nothing. Claude can
  still read them (security review, 2026-10-25).

## Success criteria

- **SC-201** From the phone, "find my lease and tell me the pet rules" answers from the file.
- **SC-202** A deleted file is in the Trash and can be put back.
- **SC-203** With Files Off or Read only, the excluded tools never appear (test suite).

## Edge cases

- Files Spotlight doesn't index (hidden folders, excluded locations): search says so; listing
  still works.
- iCloud files not downloaded yet: reading downloads them first, or says it can't within the
  time limit.
- Very large files and binary files; names with unusual characters; files that change while read.
- Latchkey's own files reached by another spelling of the path (letter case, `..`, a link): still
  refused (FR-210).
