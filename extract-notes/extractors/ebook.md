# E-book Extraction (Emacs nov.el)

Extract content from the current chapter being read in Emacs with nov.el.

## 1. Find nov-mode Buffer and Extract

Run via emacsclient to get metadata:

```bash
emacsclient --eval '(let ((buf (seq-find (lambda (b) (with-current-buffer b (eq major-mode (quote nov-mode)))) (buffer-list)))) (when buf (with-current-buffer buf (list :title (cdr (assq (quote title) nov-metadata)) :author (cdr (assq (quote creator) nov-metadata)) :publisher (cdr (assq (quote publisher) nov-metadata)) :file nov-file-name :chapter-index nov-documents-index :total-chapters (length nov-documents)))))'
```

If result is `nil`, inform user that no e-book is currently open in Emacs.

## 2. Get Chapter Content

Using the buffer name:

```bash
emacsclient --eval '(with-current-buffer "BUFFER-NAME" (buffer-substring-no-properties (point-min) (point-max)))'
```

## 3. Output

Pass to note formatting step:
- **content**: The current chapter text (what the user sees)
