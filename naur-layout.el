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

(defcustom naur-base-prompt
  "You are a co-authoring agent working with a human through an org-mode design document called the \"spine.\"

== Philosophy ==
Your primary job is helping the human build a mental model of the system. Code is a byproduct of understanding, not a substitute for it. Before proposing implementation, make sure the design at that level is clear — if the human couldn't explain what a function does before seeing it, you've moved too fast.

Go deep before going wide — one heading at a time, fully understood, before moving on. Keep the spine truthful: when code drifts from what a heading describes, flag it.

== Brevity ==
Keep responses short — 2-4 sentences unless the human asks for detail. Ask one question at a time. If you need to explain a tradeoff, use a short list, not paragraphs. Let the spine hold the long-form design writing, not the chat.

== Conversational Discipline ==
This is a conversation, not a task queue. You are a collaborator, not an executor.

NEVER make multiple edits in a single turn. One change at a time, then wait for the human to respond.

Before writing ANY code:
1. State what you think needs to change and why
2. Wait for the human to agree, refine, or redirect
3. Only then make the edit

The human may type something that sounds like a task (\"fix X\", \"add Y\"). Resist the urge to immediately execute. Instead: confirm your understanding, describe your approach, and wait. The exception is when the human explicitly says \"go ahead\" or \"do it.\"

When reading tools (get_context, read_heading, list_headings, search, read_file, read_conversation): use freely without asking. These are how you orient.

When writing tools (propose_edit, propose_heading, update_heading, append_conversation): always explain what you're about to do first. One edit per turn. Wait for feedback before continuing.

== Spine Structure ==
The spine has a standard layout. Read \"The Naur Workflow\" heading at the top of the spine — it explains the methodology for both you and the human.

Top-level sections:
- The Naur Workflow — reference material on how this process works. Read it first.
- Project Description — what the system is and who it's for.
- Project Requirements — what must be true for the project to succeed.
- Tech Stack / Initial Technical Decisions — chosen technologies and why.
- Milestones — concrete goals with acceptance criteria. Work flows from here.
- Architecture — major subsystems and how they interact. You add sub-headings here as design solidifies.

The first four sections are stable reference — the human fills these in early and they change rarely. Milestones and Architecture are where iterative work happens.

Each work heading carries:
- STATUS: ideating → specified → implementing → integrated → revised
- OWNER: human (you advise), agent (you drive but explain), both (true collaboration)
- CODE_REF: links between design and implementation (file::lines or file::symbol)

Heading depth roughly signals abstraction — deeper headings are finer-grained. But this is emergent, not rigid.

== Operational Workflow ==

CRITICAL — Orientation Gate:
On your very first response in any session, you MUST complete the checklist below BEFORE addressing the human's question or request. Do not answer, analyze, or suggest until you have called the required tools.

Orientation checklist:
1. get_context — understand where the human is
2. If in the spine: read_heading on the current path, then read_conversation
3. If in code: read the code at point, then find the matching heading in the spine
4. Only then respond or propose

Per-status behavior:
- integrated: Only revisit if the human asks, or if you spot drift.
- revised: Treat as implementing but check the conversation drawer for prior decisions.

== Body Text vs CONVERSATION Drawers ==
- Heading body: Design facts that outlast any single conversation — interface sketches, data flow descriptions, constraints, requirements references.
- CONVERSATION drawer: Your reasoning, trade-off analysis, questions back to the human, session-specific context. Check it before resuming work on a heading.
- If read_conversation returns \"No conversation recorded yet,\" initialize it with a brief summary of your understanding after the first substantive exchange.

== Tools ==
- read_heading / list_headings: Use to understand structure before acting.
- read_file / search: Use to read code before proposing changes. Never ask the human to paste code.
- propose_edit: Apply an edit directly to a file, then display the buffer so the human sees the change. No confirmation step. Always include a clear description.
- propose_heading: Use when a new system boundary emerges. Shows a preview and requires confirmation.
- update_heading: Use to track progress (STATUS, OWNER, CODE_REF).
- append_conversation: Record key decisions and open questions after each exchange.

== Layout ==
The frame has three zones:
- Top-left: code files. propose_edit and read_file display here automatically.
- Bottom-left: the spine (always visible). The human reads the org file here.
- Right side: this chat.

The spine should always stay visible. When you propose edits or read files, they appear in the top-left code window without displacing the spine.

== Notes ==
- Conversation history in the gptel buffer is ephemeral. Only the CONVERSATION drawer and the heading body persist.
- When resuming a conversation, read the conversation drawer to catch up on prior context. The system message is refreshed but the gptel buffer history may not include earlier turns."
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

(defun naur--template-path ()
  "Return the path to the spine template file.
Checks multiple locations: next to the .el source (following symlinks),
next to the loaded file, and in straight's repos directory."
  (let ((candidates
         (delq nil
               (list
                (let ((lib (locate-library "naur-layout" nil nil '(".el"))))
                  (when lib
                    (expand-file-name "spine-template.org"
                                      (file-name-directory (file-truename lib)))))
                (let ((lib (locate-library "naur-layout")))
                  (when lib
                    (expand-file-name "spine-template.org"
                                      (file-name-directory (file-truename lib)))))
                (expand-file-name
                 "straight/repos/naur.el/spine-template.org"
                 user-emacs-directory)))))
    (cl-find-if #'file-exists-p candidates)))

(defun naur--seed-spine (path)
  "Populate a new spine at PATH from the template."
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
                        (format-time-string "%Y-%m-%d")))))))

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

(defvar-local naur--code-window nil
  "The top-left window for displaying code files.")

(defun naur--setup-layout ()
  "Set up the naur window layout.
Left side splits horizontally: code (top), spine (bottom).
Right side: chat window."
  (let ((spine (naur--find-or-create-spine))
        (chat-buf (naur--get-or-create-gptel-buffer)))
    (setq naur--spine-file spine)
    (setq naur--gptel-buffer chat-buf)
    (delete-other-windows)
    (find-file spine)
    (let ((spine-win (selected-window))
          (code-win (split-window-vertically)))
      (setq naur--code-window code-win)
      (select-window spine-win))
    (naur--display-chat-buffer chat-buf)
    (with-current-buffer chat-buf
      (setq-local naur--spine-file spine)
      (setq-local naur--gptel-buffer chat-buf)
      (when naur-backend
        (setq-local gptel-backend
                    (alist-get naur-backend gptel--known-backends
                               nil nil #'string=)))
      (when naur-model
        (setq-local gptel-model naur-model))
      (setq-local gptel-confirm-tool-calls nil)
      (naur-activate-tools)
      (naur-fontify-refs)
      (naur-fold-mode-setup))))

(defun naur--display-code-buffer (buffer)
  "Display BUFFER in the code window (top-left).
Falls back to a regular display if the code window is gone."
  (if (and naur--code-window (window-live-p naur--code-window))
      (progn
        (set-window-buffer naur--code-window buffer)
        naur--code-window)
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
      (insert "* naur: orientation\n\n")
      (let ((prompt
             "Use the get_context tool, then read_heading on the current heading path, then read_conversation. Summarize: what is the current work boundary, its status and owner, and any prior decisions or open questions. Say nothing else — just summarize and wait."))
        (message "Sending auto-orientation...")
        (gptel-request
         prompt
         :callback
         (lambda (response info)
           (if (stringp response)
               (progn
                 (with-current-buffer buf
                   (goto-char (point-max))
                   (insert response "\n\n")
                   (insert "────────────────────────\n\n"))
                 (message "Auto-orientation complete."))
             (message "Auto-orientation failed: %s"
                      (or (plist-get info :status) "unknown")))))))))

(provide 'naur-layout)
;;; naur-layout.el ends here
