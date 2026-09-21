# LLM Loop, Providers, and the Elisp-Native Log — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire a real LLM provider into the already-proven headless-Emacs eval loop, with the conversation represented as native elisp data the agent can inspect and rewrite.

**Architecture:** Three small elisp files under `agent/` (bind-mounted into the container at `/agent/src/`): `anatta-log.el` (the log + git-commit persistence), `anatta-providers.el` (provider plists + HTTP transport), `anatta-loop.el` (system prompt, code extraction, the step/run loop). Each is independently unit-testable via ERT in `emacs --batch` mode, no daemon or network required except the final manual smoke test.

**Tech Stack:** Emacs Lisp (built-in `json-parse-string`/`json-encode`, ERT for tests), `curl` as a subprocess for HTTP, `git` as a subprocess for durable-state commits — all already proven reachable from elisp via `call-process` in the existing spike.

**Spec:** [`../specs/2026-09-21-llm-loop-providers-log-design.md`](../specs/2026-09-21-llm-loop-providers-log-design.md)

## Global Constraints

- No JSON library beyond Emacs's built-in `json-parse-string`/`json-encode`.
- HTTP request bodies go to curl via a temp file (`--data-binary @<tmpfile>`), never as a literal argv string (spec Component 1 — avoids `ARG_MAX`).
- The log is a list of plists, **oldest first**, appended to the **tail** (`anatta-log-append` must not use `push`).
- Exactly one top-level elisp form per model turn; extra trailing content after the first form is a protocol-violation error, not silently dropped or silently `progn`-ed (spec Component 3).
- Prose outside the fenced `elisp` code block is discarded, never logged (spec Component 3 — deliberate minimalism, not a bug).
- API keys are read from environment variables at call time only; never written into the log or committed to git.
- `git add`/`git commit` failures (e.g. "nothing to commit") are non-fatal and not checked — best-effort persistence, consistent with the spec's accepted per-step-commit simplification.

---

## Task 1: The Log (`anatta-log.el`)

**Files:**
- Create: `agent/anatta-log.el`
- Test: `agent/tests/anatta-log-tests.el`

**Interfaces:**
- Consumes: nothing (foundation file).
- Produces: `anatta-agent-dir` (defvar, default `"/agent/src/"`), `anatta-git-commit(dir message files)`, `anatta-log` (defvar, list of plists), `anatta-log-append(entry)`, `anatta-log-to-provider-messages(log)` → list of `(:role STRING :content STRING)` plists, `anatta-log-persist()`, `anatta-log-load(&optional seed-content)`.

- [ ] **Step 1: Write the failing tests**

```elisp
;; agent/tests/anatta-log-tests.el
(require 'ert)
(require 'anatta-log)

(ert-deftest anatta-log-append-is-tail-ordered ()
  (let ((anatta-log nil))
    (anatta-log-append (list :role 'user :content "first"))
    (anatta-log-append (list :role 'user :content "second"))
    (should (equal (plist-get (car anatta-log) :content) "first"))
    (should (equal (plist-get (cadr anatta-log) :content) "second"))))

(ert-deftest anatta-log-to-provider-messages-folds-roles ()
  (let ((log (list (list :role 'user :content "do it")
                    (list :role 'assistant :code "(+ 1 2)")
                    (list :role 'result :value "3")
                    (list :role 'result :error "boom"))))
    (let ((msgs (anatta-log-to-provider-messages log)))
      (should (equal (plist-get (nth 0 msgs) :role) "user"))
      (should (equal (plist-get (nth 0 msgs) :content) "do it"))
      (should (equal (plist-get (nth 1 msgs) :role) "assistant"))
      (should (equal (plist-get (nth 1 msgs) :content) "```elisp\n(+ 1 2)\n```"))
      (should (equal (plist-get (nth 2 msgs) :role) "user"))
      (should (equal (plist-get (nth 2 msgs) :content) "Eval result: 3"))
      (should (equal (plist-get (nth 3 msgs) :role) "user"))
      (should (equal (plist-get (nth 3 msgs) :content) "Eval error: boom")))))

(ert-deftest anatta-log-persist-and-load-round-trip ()
  (let* ((tmpdir (make-temp-file "anatta-log-test" t))
         (anatta-agent-dir tmpdir))
    (call-process "git" nil nil nil "init" "-q" tmpdir)
    (let ((anatta-log (list (list :role 'user :content "hello"))))
      (anatta-log-persist))
    (let ((anatta-log nil))
      (anatta-log-load)
      (should (equal (plist-get (car anatta-log) :content) "hello")))))

(ert-deftest anatta-log-load-seeds-when-no-file-present ()
  (let* ((tmpdir (make-temp-file "anatta-log-test" t))
         (anatta-agent-dir tmpdir)
         (anatta-log nil))
    (anatta-log-load "the initial task")
    (should (equal (plist-get (car anatta-log) :content) "the initial task"))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs --batch -L agent -l agent/tests/anatta-log-tests.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `anatta-log.el` doesn't exist yet (`Cannot open load file`).

- [ ] **Step 3: Write the implementation**

```elisp
;; agent/anatta-log.el
;;; anatta-log.el --- the conversation log, as elisp data -*- lexical-binding: t; -*-

(defvar anatta-agent-dir "/agent/src/"
  "Directory holding agent-authored files and the persisted log.")

(defun anatta-git-commit (dir message files)
  "Run `git add FILES` then `git commit -m MESSAGE` inside DIR.
Best-effort: failures (e.g. nothing to commit) are not checked."
  (let ((default-directory (file-name-as-directory dir)))
    (apply #'call-process "git" nil nil nil (cons "add" files))
    (call-process "git" nil nil nil "commit" "-q" "-m" message)))

(defvar anatta-log nil
  "The conversation log: a list of plists, oldest first.
Each entry is one of:
  (:role user      :content STRING)
  (:role assistant :code STRING)
  (:role result     :value STRING)
  (:role result     :error STRING)")

(defun anatta-log-append (entry)
  "Append ENTRY to the tail of `anatta-log' (never `push' — that would
produce newest-first ordering)."
  (setq anatta-log (append anatta-log (list entry))))

(defun anatta-log-to-provider-messages (log)
  "Map LOG (oldest first) into a list of (:role STRING :content STRING)
plists, the provider-agnostic message shape every provider's
:build-request further adapts."
  (mapcar
   (lambda (entry)
     (pcase (plist-get entry :role)
       ('user (list :role "user" :content (plist-get entry :content)))
       ('assistant (list :role "assistant"
                          :content (format "```elisp\n%s\n```"
                                            (plist-get entry :code))))
       ('result
        (list :role "user"
              :content (if (plist-member entry :error)
                            (format "Eval error: %s" (plist-get entry :error))
                          (format "Eval result: %s" (plist-get entry :value)))))
       (role (error "anatta-log-to-provider-messages: unknown role %S" role))))
   log))

(defun anatta-log-persist ()
  "Write `anatta-log' to log.el under `anatta-agent-dir' and git-commit it."
  (let ((path (expand-file-name "log.el" anatta-agent-dir)))
    (with-temp-file path (prin1 anatta-log (current-buffer)))
    (anatta-git-commit anatta-agent-dir "persist: log" (list "log.el"))))

(defun anatta-log-load (&optional seed-content)
  "Load `anatta-log' from log.el under `anatta-agent-dir' if present.
If absent and SEED-CONTENT is non-nil, seed `anatta-log' with one user
turn containing SEED-CONTENT. If absent and SEED-CONTENT is nil,
leave `anatta-log' unchanged."
  (let ((path (expand-file-name "log.el" anatta-agent-dir)))
    (if (file-exists-p path)
        (setq anatta-log (with-temp-buffer
                            (insert-file-contents path)
                            (read (current-buffer))))
      (when seed-content
        (setq anatta-log (list (list :role 'user :content seed-content)))))))

(provide 'anatta-log)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs --batch -L agent -l agent/tests/anatta-log-tests.el -f ert-run-tests-batch-and-exit`
Expected: PASS (4 tests, 0 failures)

- [ ] **Step 5: Commit**

```bash
cd /Users/aicoder/Documents/anatta
git add agent/anatta-log.el agent/tests/anatta-log-tests.el
git commit -m "feat: elisp-native conversation log with git-committed persistence"
```

---

## Task 2: Providers — request/response shapes (`anatta-providers.el`)

**Files:**
- Create: `agent/anatta-providers.el`
- Test: `agent/tests/anatta-providers-tests.el`

**Interfaces:**
- Consumes: nothing (pure JSON-shape functions; no network in this task).
- Produces: `anatta-provider-anthropic` (plist constant), `anatta-provider-openai` (plist constant), `anatta-active-provider` (defvar).

Each provider plist has keys `:name :api-base :api-key-env :model :headers-fn :build-request :parse-response`. `:headers-fn` is `(api-key) -> alist of (HEADER . VALUE)`. `:build-request` is `(messages system-prompt provider) -> JSON string`. `:parse-response` is `(json-response-string) -> assistant text string`.

- [ ] **Step 1: Write the failing tests**

```elisp
;; agent/tests/anatta-providers-tests.el
(require 'ert)
(require 'anatta-providers)

(ert-deftest anatta-anthropic-headers ()
  (let ((headers (funcall (plist-get anatta-provider-anthropic :headers-fn) "sk-test")))
    (should (equal (cdr (assoc "x-api-key" headers)) "sk-test"))
    (should (equal (cdr (assoc "anthropic-version" headers)) "2023-06-01"))
    (should (equal (cdr (assoc "content-type" headers)) "application/json"))))

(ert-deftest anatta-anthropic-build-request-shape ()
  (let* ((messages (list (list :role "user" :content "hi")))
         (body (funcall (plist-get anatta-provider-anthropic :build-request)
                         messages "sys prompt" anatta-provider-anthropic))
         (parsed (json-parse-string body :object-type 'alist)))
    (should (equal (alist-get 'system parsed) "sys prompt"))
    (should (equal (alist-get 'model parsed) (plist-get anatta-provider-anthropic :model)))
    (should (equal (alist-get 'role (aref (alist-get 'messages parsed) 0)) "user"))
    (should (equal (alist-get 'content (aref (alist-get 'messages parsed) 0)) "hi"))))

(ert-deftest anatta-anthropic-parse-response-extracts-text ()
  (let ((response "{\"content\":[{\"type\":\"text\",\"text\":\"(+ 1 2)\"}]}"))
    (should (equal (funcall (plist-get anatta-provider-anthropic :parse-response) response)
                    "(+ 1 2)"))))

(ert-deftest anatta-openai-headers ()
  (let ((headers (funcall (plist-get anatta-provider-openai :headers-fn) "sk-test")))
    (should (equal (cdr (assoc "Authorization" headers)) "Bearer sk-test"))
    (should (equal (cdr (assoc "content-type" headers)) "application/json"))))

(ert-deftest anatta-openai-build-request-shape ()
  (let* ((messages (list (list :role "user" :content "hi")))
         (body (funcall (plist-get anatta-provider-openai :build-request)
                         messages "sys prompt" anatta-provider-openai))
         (parsed (json-parse-string body :object-type 'alist))
         (msgs (alist-get 'messages parsed)))
    (should (equal (alist-get 'role (aref msgs 0)) "system"))
    (should (equal (alist-get 'content (aref msgs 0)) "sys prompt"))
    (should (equal (alist-get 'role (aref msgs 1)) "user"))
    (should (equal (alist-get 'content (aref msgs 1)) "hi"))))

(ert-deftest anatta-openai-parse-response-extracts-text ()
  (let ((response "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"(+ 1 2)\"}}]}"))
    (should (equal (funcall (plist-get anatta-provider-openai :parse-response) response)
                    "(+ 1 2)"))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs --batch -L agent -l agent/tests/anatta-providers-tests.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `anatta-providers.el` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

```elisp
;; agent/anatta-providers.el
;;; anatta-providers.el --- LLM provider plists -*- lexical-binding: t; -*-

(require 'json)

(defun anatta--messages-to-json-array (messages)
  "Convert MESSAGES (list of (:role STRING :content STRING) plists) into
a vector of alists suitable for `json-encode'."
  (vconcat
   (mapcar (lambda (m) (list (cons 'role (plist-get m :role))
                              (cons 'content (plist-get m :content))))
           messages)))

(defun anatta-anthropic-headers-fn (api-key)
  (list (cons "x-api-key" api-key)
        (cons "anthropic-version" "2023-06-01")
        (cons "content-type" "application/json")))

(defun anatta-anthropic-build-request (messages system-prompt provider)
  (json-encode (list (cons 'model (plist-get provider :model))
                      (cons 'max_tokens 4096)
                      (cons 'system system-prompt)
                      (cons 'messages (anatta--messages-to-json-array messages)))))

(defun anatta-anthropic-parse-response (response)
  (let* ((parsed (json-parse-string response :object-type 'alist))
         (content (alist-get 'content parsed)))
    (alist-get 'text (aref content 0))))

(defvar anatta-provider-anthropic
  (list :name "anthropic"
        :api-base "https://api.anthropic.com/v1/messages"
        :api-key-env "ANTHROPIC_API_KEY"
        :model "claude-sonnet-5"
        :headers-fn #'anatta-anthropic-headers-fn
        :build-request #'anatta-anthropic-build-request
        :parse-response #'anatta-anthropic-parse-response))

(defun anatta-openai-headers-fn (api-key)
  (list (cons "Authorization" (format "Bearer %s" api-key))
        (cons "content-type" "application/json")))

(defun anatta-openai-build-request (messages system-prompt provider)
  (let ((all-messages
         (append (list (list :role "system" :content system-prompt)) messages)))
    (json-encode (list (cons 'model (plist-get provider :model))
                        (cons 'messages (anatta--messages-to-json-array all-messages))))))

(defun anatta-openai-parse-response (response)
  (let* ((parsed (json-parse-string response :object-type 'alist))
         (choices (alist-get 'choices parsed))
         (message (alist-get 'message (aref choices 0))))
    (alist-get 'content message)))

(defvar anatta-provider-openai
  (list :name "openai"
        :api-base "https://api.openai.com/v1/chat/completions"
        :api-key-env "OPENAI_API_KEY"
        :model "gpt-5"
        :headers-fn #'anatta-openai-headers-fn
        :build-request #'anatta-openai-build-request
        :parse-response #'anatta-openai-parse-response))

(defvar anatta-active-provider anatta-provider-anthropic
  "The provider plist currently in effect. `setq' to switch providers.")

(provide 'anatta-providers)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs --batch -L agent -l agent/tests/anatta-providers-tests.el -f ert-run-tests-batch-and-exit`
Expected: PASS (6 tests, 0 failures)

- [ ] **Step 5: Commit**

```bash
cd /Users/aicoder/Documents/anatta
git add agent/anatta-providers.el agent/tests/anatta-providers-tests.el
git commit -m "feat: anthropic and openai provider request/response shapes"
```

---

## Task 3: HTTP transport + `anatta-provider-request`

**Files:**
- Modify: `agent/anatta-providers.el`
- Modify: `Dockerfile` (add `curl`)
- Test: `agent/tests/anatta-providers-tests.el`

**Interfaces:**
- Consumes: `anatta-provider-anthropic`/`anatta-provider-openai`/`anatta-active-provider` (Task 2), `anatta-log-to-provider-messages` (Task 1).
- Produces: `anatta-curl-args(url headers tmpfile)`, `anatta-http-post(url headers body)`, `anatta-provider-request(log system-prompt)` → assistant text string, or `(:error . MESSAGE)` cons on failure.

- [ ] **Step 1: Write the failing tests**

```elisp
;; append to agent/tests/anatta-providers-tests.el

(ert-deftest anatta-curl-args-uses-data-file-not-argv-body ()
  (let ((args (anatta-curl-args "https://example.com"
                                 (list (cons "x-api-key" "sk-test"))
                                 "/tmp/some-body-file")))
    (should (member "--data-binary" args))
    (should (member "@/tmp/some-body-file" args))
    (should (member "-H" args))
    (should (member "x-api-key: sk-test" args))))

(ert-deftest anatta-http-post-round-trips-via-real-curl ()
  ;; No network: post to a local file:// isn't supported by curl for POST,
  ;; so this checks curl actually runs and a nonexistent host fails cleanly.
  (should-error (anatta-http-post "http://127.0.0.1:1" nil "{}")))

(ert-deftest anatta-provider-request-surfaces-http-failure-as-error-cons ()
  (let ((anatta-active-provider anatta-provider-anthropic))
    (cl-letf (((symbol-function 'anatta-http-post)
               (lambda (&rest _) (error "curl exited 7: connection refused"))))
      (let ((result (anatta-provider-request nil "sys")))
        (should (consp result))
        (should (eq (car result) :error))))))

(ert-deftest anatta-provider-request-returns-text-on-success ()
  (let ((anatta-active-provider anatta-provider-anthropic))
    (cl-letf (((symbol-function 'anatta-http-post)
               (lambda (&rest _) "{\"content\":[{\"type\":\"text\",\"text\":\"(+ 1 2)\"}]}")))
      (should (equal (anatta-provider-request nil "sys") "(+ 1 2)")))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs --batch -L agent -l agent/tests/anatta-providers-tests.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `anatta-curl-args`/`anatta-http-post`/`anatta-provider-request` are void functions.

- [ ] **Step 3: Write the implementation**

```elisp
;; append to agent/anatta-providers.el, before (provide 'anatta-providers)

(defun anatta-curl-args (url headers tmpfile)
  "Build the curl argv (excluding the \"curl\" program name itself) to
POST TMPFILE's contents to URL with HEADERS (an alist)."
  (append (list "-s" "-X" "POST" url "--data-binary" (format "@%s" tmpfile))
          (mapcan (lambda (h) (list "-H" (format "%s: %s" (car h) (cdr h))))
                  headers)))

(defun anatta-http-post (url headers body)
  "POST BODY to URL with HEADERS via curl, writing BODY to a temp file
first (never as a literal argv string). Returns the response body
string, or signals an error if curl exits non-zero."
  (let ((tmpfile (make-temp-file "anatta-req")))
    (unwind-protect
        (progn
          (with-temp-file tmpfile (insert body))
          (with-temp-buffer
            (let ((status (apply #'call-process "curl" nil t nil
                                  (anatta-curl-args url headers tmpfile))))
              (if (zerop status)
                  (buffer-string)
                (error "curl exited %d: %s" status (buffer-string))))))
      (delete-file tmpfile))))

(defun anatta-provider-request (log system-prompt)
  "Call `anatta-active-provider' with LOG and SYSTEM-PROMPT. Returns the
raw assistant text on success, or a (:error . MESSAGE) cons on any
network/HTTP/parse failure."
  (condition-case err
      (let* ((provider anatta-active-provider)
             (messages (anatta-log-to-provider-messages log))
             (body (funcall (plist-get provider :build-request)
                             messages system-prompt provider))
             (headers (funcall (plist-get provider :headers-fn)
                                (getenv (plist-get provider :api-key-env))))
             (response (anatta-http-post (plist-get provider :api-base) headers body)))
        (funcall (plist-get provider :parse-response) response))
    (error (cons :error (error-message-string err)))))
```

```dockerfile
# Dockerfile — add curl alongside the existing packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends emacs-nox git curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `docker compose build && docker compose run --rm anatta emacs --batch -L /agent/src -l /agent/src/tests/anatta-providers-tests.el -f ert-run-tests-batch-and-exit`
Expected: PASS (10 tests total in this file, 0 failures). Uses `docker compose run` (not `exec`) since this rebuilds the image with `curl` and doesn't require the daemon to already be up.

- [ ] **Step 5: Commit**

```bash
cd /Users/aicoder/Documents/anatta
git add agent/anatta-providers.el agent/tests/anatta-providers-tests.el Dockerfile
git commit -m "feat: curl-based HTTP transport for provider requests"
```

---

## Task 4: Code extraction (`anatta-extract-code`, `anatta-read-single-form`)

**Files:**
- Create: `agent/anatta-loop.el`
- Test: `agent/tests/anatta-loop-tests.el`

**Interfaces:**
- Consumes: nothing yet (pure string/parsing functions).
- Produces: `anatta-extract-code(text)` → string or nil, `anatta-read-single-form(code-string)` → `(:ok . FORM)` or `(:error . MESSAGE)`.

- [ ] **Step 1: Write the failing tests**

```elisp
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs --batch -L agent -l agent/tests/anatta-loop-tests.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `anatta-loop.el` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

```elisp
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs --batch -L agent -l agent/tests/anatta-loop-tests.el -f ert-run-tests-batch-and-exit`
Expected: PASS (7 tests, 0 failures)

- [ ] **Step 5: Commit**

```bash
cd /Users/aicoder/Documents/anatta
git add agent/anatta-loop.el agent/tests/anatta-loop-tests.el
git commit -m "feat: extract and read exactly one elisp form per model turn"
```

---

## Task 5: Durable-write helper (`anatta-persist-to`)

**Files:**
- Modify: `agent/anatta-loop.el`
- Test: `agent/tests/anatta-loop-tests.el`

**Interfaces:**
- Consumes: `anatta-agent-dir`, `anatta-git-commit` (Task 1).
- Produces: `anatta-persist-to(relative-path form-string)` — writes, loads, and commits a new `.el` file. This is the one durable-capability primitive the agent has beyond ephemeral eval (spec Component 3, item 4).

- [ ] **Step 1: Write the failing test**

```elisp
;; append to agent/tests/anatta-loop-tests.el

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs --batch -L agent -l agent/tests/anatta-loop-tests.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `anatta-persist-to` is void.

- [ ] **Step 3: Write the implementation**

```elisp
;; append to agent/anatta-loop.el, after anatta-read-single-form, before (provide 'anatta-loop)

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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `emacs --batch -L agent -l agent/tests/anatta-loop-tests.el -f ert-run-tests-batch-and-exit`
Expected: PASS (8 tests, 0 failures)

- [ ] **Step 5: Commit**

```bash
cd /Users/aicoder/Documents/anatta
git add agent/anatta-loop.el agent/tests/anatta-loop-tests.el
git commit -m "feat: anatta-persist-to, the durable self-modification primitive"
```

---

## Task 6: The step/run loop (`anatta-step`, `anatta-run`, `anatta-done`)

**Files:**
- Modify: `agent/anatta-loop.el`
- Test: `agent/tests/anatta-loop-tests.el`

**Interfaces:**
- Consumes: `anatta-log`, `anatta-log-append`, `anatta-log-persist` (Task 1); `anatta-provider-request` (Task 3); `anatta-extract-code`, `anatta-read-single-form` (Task 4).
- Produces: `anatta-system-prompt` (defvar string), `anatta-loop-done-p` (defvar bool), `anatta-done()`, `anatta-step()`, `anatta-run(&optional max-iter)`.

- [ ] **Step 1: Write the failing tests**

```elisp
;; append to agent/tests/anatta-loop-tests.el

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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs --batch -L agent -l agent/tests/anatta-loop-tests.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `anatta-step`/`anatta-run`/`anatta-done` are void.

- [ ] **Step 3: Write the implementation**

```elisp
;; append to agent/anatta-loop.el, after anatta-persist-to, before (provide 'anatta-loop)

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
MAX-ITER steps have run (default 50)."
  (let ((max-iter (or max-iter 50))
        (n 0))
    (setq anatta-loop-done-p nil)
    (while (and (< n max-iter) (not anatta-loop-done-p))
      (anatta-step)
      (setq n (1+ n)))))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs --batch -L agent -l agent/tests/anatta-loop-tests.el -f ert-run-tests-batch-and-exit`
Expected: PASS (14 tests total in this file, 0 failures)

- [ ] **Step 5: Commit**

```bash
cd /Users/aicoder/Documents/anatta
git add agent/anatta-loop.el agent/tests/anatta-loop-tests.el
git commit -m "feat: anatta-step/anatta-run, the provider-driven eval loop"
```

---

## Task 7: Wire it up for real — entrypoint, task seeding, manual smoke test

**Files:**
- Modify: `entrypoint.sh`
- Modify: `docker-compose.yml` (pass through API key env vars)
- Modify: `README.md`
- Create: `smoke-test.sh`

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: a daemon that loads the three `.el` files and the persisted (or freshly seeded) log on startup, and a documented manual procedure for running one real turn.

This task has no ERT tests — it's the integration step the spec's Testing Plan explicitly reserves for a manual, real-provider run ("wire in a real provider... and run one real end-to-end turn by hand before trusting `anatta-run` unattended").

- [ ] **Step 1: Update `entrypoint.sh` to load the agent files and seed/restore the log**

```sh
#!/bin/sh
set -e

emacs --daemon

emacsclient --eval "(progn
  (add-to-list 'load-path \"/agent/src\")
  (require 'anatta-log)
  (require 'anatta-providers)
  (require 'anatta-loop)
  (anatta-log-load (getenv \"ANATTA_TASK\")))"

tail -f /dev/null
```

- [ ] **Step 2: Pass provider API keys and the task through `docker-compose.yml`**

```yaml
services:
  anatta:
    build: .
    volumes:
      - ./agent:/agent/src
    environment:
      - ANTHROPIC_API_KEY
      - OPENAI_API_KEY
      - ANATTA_TASK
    # No published ports, no host mounts beyond ./agent — the whole point
    # is a self-modifying process with no path back out to the host.
```

- [ ] **Step 3: Write the manual smoke-test script**

```sh
#!/bin/sh
# Manual smoke test: run ONE real turn against a real provider before
# trusting anatta-run unattended. Requires ANTHROPIC_API_KEY set on the
# host. Costs one real API call.
set -e

export ANATTA_TASK="Define a function 'anatta-hello' that returns the string \"hello from anatta\", then call (anatta-done)."

docker compose build
docker compose up -d

echo "--- running one turn ---"
docker compose exec anatta emacsclient --eval '(anatta-run 1)'

echo "--- log after the turn ---"
docker compose exec anatta emacsclient --eval '(pp-to-string anatta-log)'

docker compose down
```

- [ ] **Step 4: Run the smoke test by hand and confirm the result**

Run: `ANTHROPIC_API_KEY=<your key> ./smoke-test.sh`
Expected: the printed log shows an `assistant` entry with the `defun` code, followed by a `result` entry (either `:value` on success or `:error` if the model's form didn't match exactly what was asked — either is an acceptable pass for this smoke test, since the point is confirming the *pipeline* works end to end, not grading the model's one-shot compliance). Confirm by eye that no step crashed and the log file under `agent/log.el` was written and git-committed (`cd agent && git log --oneline` should show new `persist:` commits).

- [ ] **Step 5: Update the README's Status section**

Replace the "No LLM loop wired up yet." line and the four spike bullet points with:

```markdown
## Status

Spike-stage plus a wired LLM loop. `spike.sh` confirms the core eval
mechanism (see the first commit). `agent/anatta-log.el`,
`agent/anatta-providers.el`, and `agent/anatta-loop.el` add a real
provider-driven loop on top of it: the conversation log is native elisp
data (not JSON), providers are swappable plists (Anthropic/OpenAI), and
the built-in capability surface is exactly two things — implicit eval
of whatever elisp the model returns each turn, and `anatta-persist-to`
for durably writing a new capability. Everything else is expected to be
elisp the agent writes for itself at runtime.

Run `./smoke-test.sh` (requires `ANTHROPIC_API_KEY`) for one real,
manually-verified turn. Unit tests for each piece run without any
network access — see `agent/tests/`.
```

- [ ] **Step 6: Commit**

```bash
cd /Users/aicoder/Documents/anatta
chmod +x smoke-test.sh
git add entrypoint.sh docker-compose.yml smoke-test.sh README.md
git commit -m "feat: wire the loop into the daemon, add a manual real-provider smoke test"
```

---

## Self-Review Notes

**Spec coverage:** Component 1 (Providers) → Tasks 2–3. Component 2 (Log) → Task 1. Component 3 (Loop, system prompt, error handling, `anatta-persist-to`) → Tasks 4–6. Testing plan (mock-first, then one real hand-verified turn) → Tasks 1–6 use canned/stubbed responses exclusively, Task 7 is the one real call. All five independent-review fixes (tail-append ordering, read/multi-form handling, curl temp-file payload, discarded-prose decision, `anatta-done` as a plain flag) are implemented exactly as the revised spec describes them.

**Placeholder scan:** no TBD/TODO, no "add error handling"-style steps — every step has literal code. The one deliberately open item (Task 7's smoke test grading either `:value` or `:error` as a pass) is an explicit, reasoned choice, not a deferred placeholder.

**Type consistency:** `anatta-log` entries, `(:role STRING :content STRING)` provider messages, and the `(:ok . FORM)` / `(:error . MESSAGE)` cons convention are used identically across all tasks that touch them.
