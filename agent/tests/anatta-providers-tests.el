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

(ert-deftest anatta-openrouter-is-active-by-default ()
  (should (eq anatta-active-provider anatta-provider-openrouter)))

(ert-deftest anatta-openrouter-headers ()
  ;; Same header shape as OpenAI's Bearer-token convention.
  (let ((headers (funcall (plist-get anatta-provider-openrouter :headers-fn) "sk-or-test")))
    (should (equal (cdr (assoc "Authorization" headers)) "Bearer sk-or-test"))
    (should (equal (cdr (assoc "content-type" headers)) "application/json"))))

(ert-deftest anatta-openrouter-build-request-shape ()
  (let* ((messages (list (list :role "user" :content "hi")))
         (body (funcall (plist-get anatta-provider-openrouter :build-request)
                         messages "sys prompt" anatta-provider-openrouter))
         (parsed (json-parse-string body :object-type 'alist))
         (msgs (alist-get 'messages parsed)))
    (should (equal (alist-get 'model parsed) (plist-get anatta-provider-openrouter :model)))
    (should (equal (alist-get 'role (aref msgs 0)) "system"))
    (should (equal (alist-get 'content (aref msgs 0)) "sys prompt"))
    (should (equal (alist-get 'role (aref msgs 1)) "user"))
    (should (equal (alist-get 'content (aref msgs 1)) "hi"))))

(ert-deftest anatta-openrouter-parse-response-extracts-text ()
  (let ((response "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"(+ 1 2)\"}}]}"))
    (should (equal (funcall (plist-get anatta-provider-openrouter :parse-response) response)
                    "(+ 1 2)"))))
