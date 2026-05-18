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

(defcustom naur-base-prompt
  "You are a co-authoring agent working with a human through an org-mode design document called the \"spine.\" Think of the spine as a dialectical C4 diagram — a system architecture that emerges and sharpens through conversation rather than being drawn up front.

Your primary job is helping the human build a mental model of the system. Code is a byproduct of understanding, not a substitute for it. Before proposing implementation, make sure the design at that level is clear — if the human couldn't explain what a function does before seeing it, you've moved too fast.

Work through the spine. Headings represent system boundaries at whatever granularity the project needs. Each heading carries properties:
- STATUS: ideating → specified → implementing → integrated → revised
- OWNER: human (you advise), agent (you drive but explain), both (true collaboration)
- CODE_REF: links between design and implementation (file::lines or file::symbol)

Go deep before going wide — one heading at a time, fully understood, before moving on. Keep the spine truthful: when code drifts from what a heading describes, flag it. Put your reasoning in CONVERSATION drawers; keep heading bodies for design facts that outlast any single conversation."
  "Base system prompt explaining the naur methodology to the agent."
  :type 'string
  :group 'naur)

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
      (let ((name (read-string "New spine file name: " "spine.org")))
        (expand-file-name name dir))))))

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

(defun naur--setup-layout ()
  "Set up the naur window layout."
  (let ((spine (naur--find-or-create-spine))
        (chat-buf (naur--get-or-create-gptel-buffer)))
    (setq naur--spine-file spine)
    (setq naur--gptel-buffer chat-buf)
    (find-file spine)
    (naur--display-chat-buffer chat-buf)
    (with-current-buffer chat-buf
      (when naur-backend
        (setq-local gptel-backend
                    (alist-get naur-backend gptel--known-backends
                               nil nil #'string=)))
      (when naur-model
        (setq-local gptel-model naur-model))
      (naur-activate-tools)
      (naur-fontify-refs))))

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
      (naur--setup-layout)
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
    (if focus-parts
        (concat naur-base-prompt
                "\n\nThe human's current focus:\n"
                (string-join (nreverse focus-parts) "\n"))
      naur-base-prompt)))

(defun naur-start-agent ()
  "Start a new agent conversation with current context injected as system message."
  (interactive)
  (unless naur--gptel-buffer
    (error "naur-mode not active"))
  (let* ((ctx (naur--capture-context))
         (sys-msg (naur--build-system-message ctx)))
    (with-current-buffer naur--gptel-buffer
      (erase-buffer)
      (setq-local gptel--system-message sys-msg)
      (naur-activate-tools))
    (naur--display-chat-buffer naur--gptel-buffer)
    (select-window (get-buffer-window naur--gptel-buffer))))

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
    (select-window (get-buffer-window naur--gptel-buffer))))

(provide 'naur-layout)
;;; naur-layout.el ends here
