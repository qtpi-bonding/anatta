;; agent/tests/anatta-loop-tests.el
(require 'ert)
(require 'anatta-loop)

(ert-deftest anatta-extract-code-finds-fenced-block ()
  (should (equal (anatta-extract-code "here you go\n```elisp\n(+ 1 2)\n```\nthanks")
                  "(+ 1 2)\n")))

(ert-deftest anatta-extract-code-returns-nil-when-absent ()
  (should (null (anatta-extract-code "just prose, no code block"))))

(ert-deftest anatta-extract-code-takes-first-block-only ()
  (should (equal (anatta-extract-code "```elisp\n(+ 1 1)\n```\nand\n```elisp\n(+ 2 2)\n```")
                  "(+ 1 1)\n")))

(ert-deftest anatta-read-single-form-ok-on-one-form ()
  (let ((result (anatta-read-single-form "(+ 1 2)")))
    (should (eq (car result) :ok))
    (should (equal (cdr result) '(+ 1 2)))))

(ert-deftest anatta-read-single-form-ok-with-trailing-whitespace ()
  (let ((result (anatta-read-single-form "(+ 1 2)\n\n  ")))
    (should (eq (car result) :ok))))

(ert-deftest anatta-read-single-form-errors-on-extra-content ()
  (let ((result (anatta-read-single-form "(+ 1 2) (+ 3 4)")))
    (should (eq (car result) :error))))

(ert-deftest anatta-read-single-form-errors-on-unreadable-text ()
  (let ((result (anatta-read-single-form "(+ 1 2")))
    (should (eq (car result) :error))))

(ert-deftest anatta-persist-to-writes-loads-and-commits ()
  (let* ((tmpdir (make-temp-file "anatta-persist-test" t))
         (anatta-agent-dir tmpdir))
    (call-process "git" nil nil nil "init" "-q" tmpdir)
    ;; repo-local identity so `git commit` succeeds even in an environment
    ;; with no global user.name/user.email configured (CI, a fresh
    ;; container) — anatta-git-commit's failures are non-fatal and
    ;; unchecked, so without this the commit below silently no-ops and
    ;; the git-log assertion fails for an unrelated reason
    (call-process "git" nil nil nil "-C" tmpdir "config" "user.email" "anatta-test@example.com")
    (call-process "git" nil nil nil "-C" tmpdir "config" "user.name" "anatta-test")
    ;; sanity: the function this file defines shouldn't exist in the running
    ;; image yet, so calling it is the actual behavior under test
    (should (not (fboundp 'anatta-persisted-fn-under-test)))
    (anatta-persist-to "scratch.el"
                        "(defun anatta-persisted-fn-under-test () 42)")
    (should (fboundp 'anatta-persisted-fn-under-test))
    (should (= (anatta-persisted-fn-under-test) 42))
    (should (file-exists-p (expand-file-name "scratch.el" tmpdir)))
    (let ((default-directory tmpdir))
      (with-temp-buffer
        (call-process "git" nil t nil "log" "--oneline")
        (should (> (length (buffer-string)) 0))))))

(defmacro anatta-test--with-canned-responses (responses &rest body)
  "Run BODY with `anatta-provider-request' returning successive strings
from RESPONSES (a list), one per call, ignoring its arguments."
  (declare (indent 1))
  `(let ((anatta-test--responses (copy-sequence ,responses)))
     (cl-letf (((symbol-function 'anatta-provider-request)
                (lambda (&rest _)
                  (if anatta-test--responses
                      (pop anatta-test--responses)
                    (error "no more canned responses")))))
       ,@body)))

(ert-deftest anatta-step-appends-code-and-successful-result ()
  (let* ((tmpdir (make-temp-file "anatta-step-test" t))
         (anatta-agent-dir tmpdir)
         (anatta-log nil))
    (call-process "git" nil nil nil "init" "-q" tmpdir)
    (anatta-test--with-canned-responses (list "```elisp\n(+ 1 2)\n```")
      (anatta-step))
    (should (= (length anatta-log) 2))  ; assistant + result (no seed user turn here)
    (should (eq (plist-get (nth 0 anatta-log) :role) 'assistant))
    (should (equal (plist-get (nth 1 anatta-log) :value) "3"))))

(ert-deftest anatta-step-logs-provider-error-without-eval ()
  (let* ((tmpdir (make-temp-file "anatta-step-test" t))
         (anatta-agent-dir tmpdir)
         (anatta-log nil))
    (call-process "git" nil nil nil "init" "-q" tmpdir)
    (cl-letf (((symbol-function 'anatta-provider-request)
               (lambda (&rest _) (cons :error "connection refused"))))
      (anatta-step))
    (should (= (length anatta-log) 1))
    (should (equal (plist-get (car anatta-log) :error) "connection refused"))))

(ert-deftest anatta-step-logs-missing-code-block-error ()
  (let* ((tmpdir (make-temp-file "anatta-step-test" t))
         (anatta-agent-dir tmpdir)
         (anatta-log nil))
    (call-process "git" nil nil nil "init" "-q" tmpdir)
    (anatta-test--with-canned-responses (list "just prose, no code")
      (anatta-step))
    (should (equal (plist-get (car anatta-log) :error) "no elisp block found"))))

(ert-deftest anatta-step-logs-multiple-forms-error ()
  (let* ((tmpdir (make-temp-file "anatta-step-test" t))
         (anatta-agent-dir tmpdir)
         (anatta-log nil))
    (call-process "git" nil nil nil "init" "-q" tmpdir)
    (anatta-test--with-canned-responses (list "```elisp\n(+ 1 2) (+ 3 4)\n```")
      (anatta-step))
    (should (equal (plist-get (car anatta-log) :error)
                    "expected exactly one form, got extra trailing content"))))

(ert-deftest anatta-step-logs-eval-error-and-continues ()
  (let* ((tmpdir (make-temp-file "anatta-step-test" t))
         (anatta-agent-dir tmpdir)
         (anatta-log nil))
    (call-process "git" nil nil nil "init" "-q" tmpdir)
    (anatta-test--with-canned-responses (list "```elisp\n(this-function-does-not-exist)\n```")
      (anatta-step))
    (should (plist-get (nth 1 anatta-log) :error))))

(ert-deftest anatta-run-stops-at-anatta-done ()
  (let* ((tmpdir (make-temp-file "anatta-run-test" t))
         (anatta-agent-dir tmpdir)
         (anatta-log nil)
         (anatta-loop-done-p nil))
    (call-process "git" nil nil nil "init" "-q" tmpdir)
    (anatta-test--with-canned-responses
        (list "```elisp\n(+ 1 1)\n```" "```elisp\n(anatta-done)\n```" "```elisp\n(+ 9 9)\n```")
      (anatta-run 10)
      ;; third canned response should never be consumed — checked here,
      ;; inside the macro's `let`, since `anatta-test--responses` isn't
      ;; special and goes out of scope the moment the macro body ends
      (should (= (length anatta-test--responses) 1)))))

(ert-deftest anatta-run-stops-at-max-iter ()
  (let* ((tmpdir (make-temp-file "anatta-run-test" t))
         (anatta-agent-dir tmpdir)
         (anatta-log nil)
         (anatta-loop-done-p nil)
         (call-count 0))
    (call-process "git" nil nil nil "init" "-q" tmpdir)
    (cl-letf (((symbol-function 'anatta-provider-request)
               (lambda (&rest _)
                 (setq call-count (1+ call-count))
                 "```elisp\n(+ 1 1)\n```")))
      (anatta-run 3))
    (should (= call-count 3))))
