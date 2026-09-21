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
