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

(defvar anatta-system-prompt
  "You are anatta: a live, headless Emacs process. You are not a
sandboxed script runner — every function and variable you define now
exists on every later turn, including this one. Your own conversation
history is the `anatta-log' variable; you may inspect, prune, or
rewrite it directly via eval, the same as any other data. Respond with
exactly one elisp form per turn, inside a single fenced ```elisp code
block — nothing before or after the block will be seen on later turns.
`anatta-persist-to' is predefined: call it to write a new .el file
under your working directory, load it immediately, and git-commit it —
this is how a capability survives a restart, versus plain eval which
only affects the running image. You are running inside a disposable
Docker container with a git-backed history of every change you make to
yourself. Mistakes are recoverable, not catastrophic — act with real
agency."
  "The seed system prompt sent with every provider request.")

(defvar anatta-loop-done-p nil
  "Set non-nil by `anatta-done' to stop `anatta-run' after the current step.")

(defun anatta-done ()
  "Call this to signal that the current run is complete. Sets
`anatta-loop-done-p'; `anatta-run' checks it after each step."
  (setq anatta-loop-done-p t))

(defun anatta-step ()
  "Run one turn: call the provider, extract and read its elisp form,
eval it, and append the outcome to `anatta-log'. Persists after every
outcome, including early-exit error paths."
  (let ((resp (anatta-provider-request anatta-log anatta-system-prompt)))
    (if (and (consp resp) (eq (car resp) :error))
        (progn (anatta-log-append (list :role 'result :error (cdr resp)))
               (anatta-log-persist))
      (let ((code (anatta-extract-code resp)))
        (if (null code)
            (progn (anatta-log-append (list :role 'result :error "no elisp block found"))
                   (anatta-log-persist))
          (let ((read-result (anatta-read-single-form code)))
            (if (eq (car read-result) :error)
                (progn (anatta-log-append (list :role 'result :error (cdr read-result)))
                       (anatta-log-persist))
              (progn
                (anatta-log-append (list :role 'assistant :code code))
                (condition-case err
                    (anatta-log-append
                     (list :role 'result :value (format "%S" (eval (cdr read-result) t))))
                  (error (anatta-log-append
                          (list :role 'result :error (error-message-string err)))))
                (anatta-log-persist)))))))))

(defun anatta-run (&optional max-iter)
  "Call `anatta-step' in a loop until `anatta-done' is called or
MAX-ITER steps have run (default 50). Interactively, a numeric prefix
argument sets MAX-ITER (e.g. `C-u 5 M-x anatta-run`); with no prefix,
or when called from code with MAX-ITER omitted, it defaults to 50.
This is the same function whether invoked via `emacsclient --eval' in
a headless daemon or via `M-x' in a person's own Emacs — nothing here
assumes a particular host, only that `anatta-agent-dir' points
somewhere writable."
  (interactive "P")
  (let ((max-iter (cond ((integerp max-iter) max-iter)
                         (max-iter (prefix-numeric-value max-iter))
                         (t 50)))
        (n 0))
    (setq anatta-loop-done-p nil)
    (while (and (< n max-iter) (not anatta-loop-done-p))
      (anatta-step)
      (setq n (1+ n)))))

(provide 'anatta-loop)
