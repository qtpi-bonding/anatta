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
