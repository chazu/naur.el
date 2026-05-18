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
          (gptel-mode)
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

(defun naur-start-agent ()
  "Start a new agent conversation with current context."
  (interactive)
  (unless naur--gptel-buffer
    (error "naur-mode not active"))
  (let ((ctx (naur--capture-context)))
    (naur--display-chat-buffer naur--gptel-buffer)
    (with-current-buffer naur--gptel-buffer
      (goto-char (point-max))
      (unless (bobp) (insert "\n\n"))
      (insert (format "--- New conversation ---\nContext: %s\n\n"
                      (naur--context-to-json ctx))))
    (select-window (get-buffer-window naur--gptel-buffer))))

(defun naur-resume-conversation ()
  "Resume the last conversation with refreshed context."
  (interactive)
  (unless naur--gptel-buffer
    (error "naur-mode not active"))
  (let ((ctx (naur--capture-context)))
    (naur--display-chat-buffer naur--gptel-buffer)
    (with-current-buffer naur--gptel-buffer
      (goto-char (point-max))
      (insert (format "\n\n[Resuming — current context: %s]\n\n"
                      (naur--context-to-json ctx))))
    (select-window (get-buffer-window naur--gptel-buffer))))

(provide 'naur-layout)
;;; naur-layout.el ends here
