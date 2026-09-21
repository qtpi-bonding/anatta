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

(provide 'anatta-loop)
