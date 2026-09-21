;; agent/anatta-loop.el
;;; anatta-loop.el --- system prompt + the step/run loop -*- lexical-binding: t; -*-

(require 'anatta-log)
(require 'anatta-providers)

(defun anatta-extract-code (text)
  "Return the content of the first ```elisp fenced block in TEXT, or nil
if none is found. Prose outside the block is discarded."
  (if (string-match "```elisp\n\\(\\(?:.\\|\n\\)*?\\)```" text)
      (match-string 1 text)
    nil))

(defun anatta-read-single-form (code-string)
  "Read exactly one Lisp form from CODE-STRING. Returns (:ok . FORM) if
CODE-STRING contains exactly one form (trailing whitespace allowed), or
(:error . MESSAGE) if it's unreadable or contains extra trailing
content after the first form — the system prompt requires exactly one
form per turn, so extra content is a protocol violation, not silently
dropped or silently evaluated as multiple forms."
  (condition-case err
      (let* ((form-and-pos (read-from-string code-string))
             (form (car form-and-pos))
             (end-pos (cdr form-and-pos))
             (rest (substring code-string end-pos)))
        (if (string-match-p "\\`[ \t\n\r]*\\'" rest)
            (cons :ok form)
          (cons :error "expected exactly one form, got extra trailing content")))
    (error (cons :error (error-message-string err)))))

(defun anatta-persist-to (relative-path form-string)
  "Write FORM-STRING to RELATIVE-PATH under `anatta-agent-dir', `load' it
so it takes effect immediately, and git-commit it. This is the durable
path, contrasted with plain eval which only affects the running image
until the daemon restarts."
  (let ((full-path (expand-file-name relative-path anatta-agent-dir)))
    (with-temp-file full-path (insert form-string))
    (load full-path)
    (anatta-git-commit anatta-agent-dir (format "persist: %s" relative-path)
                        (list relative-path))))

(provide 'anatta-loop)
