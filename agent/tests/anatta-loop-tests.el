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
