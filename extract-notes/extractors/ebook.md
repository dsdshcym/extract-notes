# E-book Extraction (Emacs nov.el)

Extract content from the current chapter being read in Emacs with nov.el.

## 1. Find nov-mode Buffer and Extract

Run via emacsclient to get metadata:

```bash
emacsclient --eval '(let ((buf (seq-find (lambda (b) (with-current-buffer b (eq major-mode (quote nov-mode)))) (buffer-list)))) (when buf (with-current-buffer buf (list :title (cdr (assq (quote title) nov-metadata)) :author (cdr (assq (quote creator) nov-metadata)) :publisher (cdr (assq (quote publisher) nov-metadata)) :file nov-file-name :chapter-index nov-documents-index :total-chapters (length nov-documents)))))'
```

If result is `nil`, inform user that no e-book is currently open in Emacs.

## 2. Get Chapter Content

```bash
emacsclient --eval '(let ((buf (seq-find (lambda (b) (with-current-buffer b (eq major-mode (quote nov-mode)))) (buffer-list)))) (when buf (with-current-buffer buf (buffer-substring-no-properties (point-min) (point-max)))))'
```

This returns the exact text the user sees in their current chapter.

## 3. Output

Pass to note formatting step:
- **title**: Book title from metadata
- **author**: Creator from metadata
- **source**: Original epub file path
- **chapter**: "Chapter X of Y" (from index and total)
- **content**: The current chapter text (what the user sees)