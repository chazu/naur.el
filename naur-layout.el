;;; naur-layout.el --- Window management and mode definition for naur -*- lexical-binding: t; -*-

;;; Code:

(require 'gptel)
(require 'project)

(declare-function naur-activate-tools "naur-tools")
(declare-function naur-fontify-refs "naur-nav")
(declare-function naur--capture-context "naur-context")
(declare-function naur--context-to-json "naur-context")
(declare-function naur-goto-code-ref "naur-nav")
(declare-function naur-set-code-ref "naur-nav")
(declare-function naur-cycle-status "naur-org")
(declare-function naur-agenda "naur-org")
(declare-function naur-archive-conversation "naur-org")
(declare-function naur-fold-mode-setup "naur-fold")
(declare-function naur-fold-toggle-at-point "naur-fold")
(declare-function naur-register-tools "naur-tools")

(defgroup naur nil
  "Co-author code through org-mode design documents."
  :group 'tools
  :prefix "naur-")

(defcustom naur-directory "naur"
  "Directory name relative to project root where org spine files live."
  :type 'string
  :group 'naur)

(defcustom naur-chat-window-width 0.35
  "Width of the chat side window as a fraction of frame width."
  :type 'float
  :group 'naur)

(defcustom naur-backend nil
  "gptel backend for naur chat. Nil uses gptel default."
  :type '(choice (const :tag "Use gptel default" nil)
                 (string :tag "Backend name"))
  :group 'naur)

(defcustom naur-model nil
  "gptel model for naur chat. Nil uses gptel default."
  :type '(choice (const :tag "Use gptel default" nil)
                 (string :tag "Model name"))
  :group 'naur)

(defcustom naur-archive-summarize t
  "When non-nil, summarize conversation via LLM when archiving.
Use \\[universal-argument] with `naur-archive-conversation' to invert."
  :type 'boolean
  :group 'naur)

(defcustom naur-agents-file "agents-template.md"
  "Filename of the AGENTS.md template bundled with naur.el.
Copied to project as AGENTS.md on first spine creation."
  :type 'string
  :group 'naur)

(defcustom naur-base-prompt nil
  "Base system prompt for the agent. When nil, loaded from AGENTS.md at project root.
Set this to override with a custom string."
  :type '(choice (const :tag "Load from AGENTS.md" nil)
                 (string :tag "Custom prompt"))
  :group 'naur)

(defun naur--load-agents-prompt ()
  "Load the agent system prompt from AGENTS.md, or fall back to bundled template."
  (let* ((root (naur--project-root))
         (project-agents (expand-file-name "AGENTS.md" root))
         (bundled (naur--find-bundled-file naur-agents-file)))
    (cond
     (naur-base-prompt naur-base-prompt)
     ((file-exists-p project-agents)
      (with-temp-buffer
        (insert-file-contents project-agents)
        (buffer-string)))
     (bundled
      (with-temp-buffer
        (insert-file-contents bundled)
        (buffer-string)))
     (t "You are a co-authoring agent working with a human through an org-mode design document called the \"spine.\" Read AGENTS.md in the project root for full instructions."))))

(defun naur--find-bundled-file (filename)
  "Find FILENAME bundled with naur.el source."
  (let ((candidates
         (delq nil
               (list
                (let ((lib (locate-library "naur-layout" nil nil '(".el"))))
                  (when lib
                    (expand-file-name filename
                                      (file-name-directory (file-truename lib)))))
                (expand-file-name
                 (concat "straight/repos/naur.el/" filename)
                 user-emacs-directory)))))
    (cl-find-if #'file-exists-p candidates)))

(defvar-local naur--spine-file nil
  "Path to the org spine file for this project.")

(defvar-local naur--gptel-buffer nil
  "The gptel buffer associated with this naur session.")

(defun naur--project-root ()
  "Return the project root, or default-directory."
  (or (when-let ((proj (project-current)))
        (project-root proj))
      default-directory))

(defun naur--naur-dir ()
  "Return the naur directory for the current project."
  (expand-file-name naur-directory (naur--project-root)))

(defun naur--template-path ()
  "Return the path to the spine template file."
  (naur--find-bundled-file "spine-template.org"))

(defun naur--seed-spine (path)
  "Populate a new spine at PATH from the template.
Also copies AGENTS.md to project root if not already present.
Refuses to overwrite an existing file."
  (when (file-exists-p path)
    (error "Spine already exists at %s — refusing to overwrite" path))
  (let ((template (naur--template-path))
        (project-name (file-name-nondirectory
                       (directory-file-name (naur--project-root)))))
    (if (and template (file-exists-p template))
        (with-temp-file path
          (insert-file-contents template)
          (goto-char (point-min))
          (while (search-forward "%s" nil t)
            (replace-match
             (if (save-excursion
                   (beginning-of-line)
                   (looking-at "#\\+TITLE:"))
                 project-name
               (format-time-string "%Y-%m-%d"))
             t t)))
      (with-temp-file path
        (insert (format "#+TITLE: %s\n#+DATE: %s\n\n* Architecture\n"
                        project-name
                        (format-time-string "%Y-%m-%d"))))))
  (naur--ensure-agents-md))

(defun naur--ensure-agents-md ()
  "Copy AGENTS.md to project root if not already present."
  (let ((dest (expand-file-name "AGENTS.md" (naur--project-root)))
        (src (naur--find-bundled-file naur-agents-file)))
    (when (and src (not (file-exists-p dest)))
      (copy-file src dest)
      (message "Created AGENTS.md in project root"))))

(defun naur--find-or-create-spine ()
  "Find an existing spine file or prompt to create one."
  (let* ((dir (naur--naur-dir))
         (existing (and (file-directory-p dir)
                        (directory-files dir t "\\.org$"))))
    (cond
     ((and existing (= 1 (length existing)))
      (car existing))
     (existing
      (completing-read "Spine file: " existing nil t))
     (t
      (unless (file-directory-p dir)
        (make-directory dir t))
      (let* ((name (read-string "New spine file name: " "spine.org"))
             (path (expand-file-name name dir)))
        (naur--seed-spine path)
        path)))))

(defun naur--get-or-create-gptel-buffer ()
  "Get or create the gptel chat buffer for this naur session."
  (let ((buf-name (format "*naur-chat:%s*"
                          (file-name-nondirectory
                           (directory-file-name (naur--project-root))))))
    (or (get-buffer buf-name)
        (with-current-buffer (get-buffer-create buf-name)
          (org-mode)
          (gptel-mode 1)
          (current-buffer)))))

(defun naur--display-chat-buffer (buffer)
  "Display BUFFER in a right side window."
  (display-buffer buffer
                  `(display-buffer-in-side-window
                    (side . right)
                    (window-width . ,naur-chat-window-width)
                    (slot . 0))))

(defvar-local naur--left-window nil
  "The left window for displaying files (spine, code, etc).")

(defun naur--setup-layout ()
  "Set up the naur window layout.
Left side: file window (starts with spine). Right side: chat window."
  (let ((spine (naur--find-or-create-spine))
        (chat-buf (naur--get-or-create-gptel-buffer)))
    (setq naur--spine-file spine)
    (setq naur--gptel-buffer chat-buf)
    (delete-other-windows)
    (find-file spine)
    (setq naur--left-window (selected-window))
    (naur--display-chat-buffer chat-buf)
    (with-current-buffer chat-buf
      (setq-local naur--spine-file spine)
      (setq-local naur--gptel-buffer chat-buf)
      (setq-local naur--left-window naur--left-window)
      (when naur-backend
        (setq-local gptel-backend
                    (alist-get naur-backend gptel--known-backends
                               nil nil #'string=)))
      (when naur-model
        (setq-local gptel-model naur-model))
      (setq-local gptel-confirm-tool-calls nil)
      (naur-activate-tools)
      (naur-fontify-refs)
      (naur-fold-mode-setup)
      (add-hook 'gptel-prompt-transform-functions
                #'naur--refresh-context-on-send nil t))))

(defun naur--display-code-buffer (buffer)
  "Display BUFFER in the left window.
Falls back to a regular display if the left window is gone."
  (if (and naur--left-window (window-live-p naur--left-window))
      (progn
        (set-window-buffer naur--left-window buffer)
        naur--left-window)
    (display-buffer buffer '(nil (inhibit-same-window . t)))))

(defun naur--teardown-layout ()
  "Tear down the naur window layout."
  (when-let ((win (and naur--gptel-buffer
                       (get-buffer-window naur--gptel-buffer))))
    (delete-window win)))

(defun naur-toggle-chat ()
  "Show or hide the chat side window."
  (interactive)
  (if-let ((win (and naur--gptel-buffer
                     (get-buffer-window naur--gptel-buffer))))
      (delete-window win)
    (when naur--gptel-buffer
      (naur--display-chat-buffer naur--gptel-buffer))))

(defvar naur-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c n t") #'naur-toggle-chat)
    (define-key map (kbd "C-c n g") #'naur-goto-code-ref)
    (define-key map (kbd "C-c n r") #'naur-set-code-ref)
    (define-key map (kbd "C-c n c") #'naur-cycle-status)
    (define-key map (kbd "C-c n a") #'naur-agenda)
    (define-key map (kbd "C-c n A") #'naur-archive-conversation)
    (define-key map (kbd "C-c n f") #'naur-fold-toggle-at-point)
    (define-key map (kbd "C-c n s") #'naur-start-agent)
    (define-key map (kbd "C-c n l") #'naur-resume-conversation)
    map)
  "Keymap for `naur-mode'.")

;;;###autoload
(define-minor-mode naur-mode
  "Minor mode for co-authoring code through org-mode design documents."
  :lighter " Naur"
  :keymap naur-mode-map
  :group 'naur
  (if naur-mode
      (progn
        (naur--setup-layout)
        (naur-start-agent))
    (naur--teardown-layout)))

;;;###autoload
(defun naur-activate ()
  "Activate naur-mode in the current buffer."
  (interactive)
  (naur-mode 1))

(defun naur--build-system-message (ctx)
  "Build a system message string from context alist CTX.
Prepends `naur-base-prompt', then appends the human's current focus."
  (let ((focus-parts nil))
    (when-let ((heading (alist-get :heading ctx)))
      (push (format "- Org heading: %s" heading) focus-parts))
    (when-let ((path (alist-get :heading-path ctx)))
      (push (format "- Outline path: %s" (string-join path " > ")) focus-parts))
    (when-let ((status (alist-get :status ctx)))
      (push (format "- Status: %s" status) focus-parts))
    (when-let ((file (alist-get :file ctx)))
      (push (format "- File: %s (line %d)" file (or (alist-get :line ctx) 0)) focus-parts))
    (when-let ((region (alist-get :region ctx)))
      (push (format "- Selected text:\n%s" region) focus-parts))
    (when-let ((code-ref (alist-get :code-ref ctx)))
      (push (format "- CODE_REF: %s" code-ref) focus-parts))
    (let ((prompt (naur--load-agents-prompt)))
      (if focus-parts
          (concat prompt
                  "\n\nThe human's current focus:\n"
                  (string-join (nreverse focus-parts) "\n"))
        prompt))))

(defun naur-start-agent ()
  "Start a new agent conversation with current context injected as system message."
  (interactive)
  (unless naur--gptel-buffer
    (error "naur-mode not active"))
  (let* ((spine naur--spine-file)
         (ctx (naur--capture-context))
         (sys-msg (naur--build-system-message ctx)))
    (with-current-buffer naur--gptel-buffer
      (erase-buffer)
      (setq-local naur--spine-file spine)
      (setq-local gptel--system-message sys-msg)
      (naur-activate-tools))
    (naur--display-chat-buffer naur--gptel-buffer)
    (select-window (get-buffer-window naur--gptel-buffer))
    (when naur-auto-orient
      (naur--auto-orient))))

(defun naur-resume-conversation ()
  "Resume the last conversation with refreshed context as system message."
  (interactive)
  (unless naur--gptel-buffer
    (error "naur-mode not active"))
  (let* ((ctx (naur--capture-context))
         (sys-msg (naur--build-system-message ctx)))
    (with-current-buffer naur--gptel-buffer
      (setq-local gptel--system-message sys-msg))
    (naur--display-chat-buffer naur--gptel-buffer)
    (select-window (get-buffer-window naur--gptel-buffer))
    (when naur-auto-orient
      (naur--auto-orient))))

;; ── Context auto-refresh on every send ───────────────────────────

(defun naur--refresh-context-on-send (&optional _info)
  "Refresh the system message with current context before each gptel send.
Added to `gptel-prompt-transform-functions' in naur chat buffers."
  (when naur--spine-file
    (let ((ctx (with-current-buffer
                   (or (and naur--left-window
                            (window-live-p naur--left-window)
                            (window-buffer naur--left-window))
                       (current-buffer))
                 (naur--capture-context))))
      (setq-local gptel--system-message
                  (naur--build-system-message ctx)))))

;; ── Auto-orientation ─────────────────────────────────────────────

(defcustom naur-auto-orient t
  "When non-nil, automatically send an orientation prompt on startup/resume.
The agent orients itself via tool calls before the human types."
  :type 'boolean
  :group 'naur)

(defun naur--auto-orient ()
  "Send an orientation prompt so the agent reads context before the human types.
The LLM is expected to call get_context, read_heading, and
read_conversation before producing its summary."
  (when-let ((buf naur--gptel-buffer))
    (with-current-buffer buf
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert "Use the get_context tool, then read_heading on the current heading path, then read_conversation. Summarize: what is the current work boundary, its status and owner, and any prior decisions or open questions. Say nothing else — just summarize and wait.")
      (message "Sending auto-orientation...")
      (gptel-send))))

(provide 'naur-layout)
;;; naur-layout.el ends here
