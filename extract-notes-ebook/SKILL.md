---
name: extract-notes:ebook
description: Extract notes from e-book chapter in Emacs nov.el
allowed-tools:
  - Bash(emacsclient:*)
  - Read
  - Skill(extract-notes)
---

# Extract Notes from E-book (Emacs nov.el)

Extract content from the current chapter being read in Emacs with nov.el.

## Input

```
$ARGUMENTS = [notes-taking-skill]
```

- **notes-taking-skill** (optional): passed through to extract-notes

## Step 1: Find nov-mode Buffer and Extract Metadata

```bash
emacsclient --eval '(let ((buf (seq-find (lambda (b) (with-current-buffer b (eq major-mode (quote nov-mode)))) (buffer-list)))) (when buf (with-current-buffer buf (list :title (cdr (assq (quote title) nov-metadata)) :author (cdr (assq (quote creator) nov-metadata)) :publisher (cdr (assq (quote publisher) nov-metadata)) :file nov-file-name :chapter-index nov-documents-index :total-chapters (length nov-documents)))))'
```

If result is `nil`, inform user that no e-book is currently open in Emacs.

## Step 2: Get Chapter Content

Using the buffer name:

```bash
emacsclient --eval '(with-current-buffer "BUFFER-NAME" (buffer-substring-no-properties (point-min) (point-max)))'
```

## Step 3: Clean and Format

Invoke `Skill(extract-notes)` to clean the extracted content and format as notes.