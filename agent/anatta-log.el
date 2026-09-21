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
