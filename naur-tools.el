;;; naur-tools.el --- gptel tool definitions for naur -*- lexical-binding: t; -*-

;;; Code:

(require 'gptel)
(require 'org)
(require 'diff)
(require 'naur-context)

(defvar naur--spine-file)

(defun naur--tool-get-context ()
  "Return the current focus context as JSON."
  (naur--context-to-json (naur--capture-context)))

(defun naur--tool-read-file (file start-line end-line)
  "Return contents of FILE from START-LINE to END-LINE."
  (let ((path (expand-file-name file (or (when-let ((proj (project-current)))
                                           (project-root proj))
                                         default-directory))))
    (unless (file-exists-p path)
      (error "File not found: %s" file))
    (with-temp-buffer
      (insert-file-contents path)
      (let* ((start (max 1 start-line))
             (lines (split-string (buffer-string) "\n"))
             (end (min end-line (length lines))))
        (string-join (seq-subseq lines (1- start) end) "\n")))))

(defun naur--tool-read-heading (heading-path)
  "Return the content of the org subtree at HEADING-PATH.
Excludes CONVERSATION drawers."
  (let ((spine naur--spine-file))
    (unless spine
      (error "No spine file set"))
    (with-current-buffer (find-file-noselect spine)
      (org-with-wide-buffer
       (goto-char (point-min))
       (let ((path (if (listp heading-path) heading-path
                     (split-string heading-path "/"))))
         (dolist (component path)
           (unless (re-search-forward
                    (concat "^\\*+ +" (regexp-quote component)) nil t)
             (error "Heading not found: %s" component)))
         (let ((start (line-beginning-position))
               (end (org-end-of-subtree t t)))
           (let ((content (buffer-substring-no-properties start end)))
             (replace-regexp-in-string
              ":CONVERSATION:\\(?:.\\|\n\\)*?:END:" "" content))))))))

(defun naur--tool-list-headings (min-level max-level status-filter)
  "Return headings between MIN-LEVEL and MAX-LEVEL.
If STATUS-FILTER is non-nil, only include headings with that STATUS."
  (let ((spine naur--spine-file)
        (results nil))
    (unless spine
      (error "No spine file set"))
    (with-current-buffer (find-file-noselect spine)
      (org-with-wide-buffer
       (goto-char (point-min))
       (while (re-search-forward org-heading-regexp nil t)
         (let ((level (org-current-level))
               (title (org-get-heading t t t t))
               (status (org-entry-get nil "STATUS"))
               (owner (org-entry-get nil "OWNER"))
               (code-ref (org-entry-get nil "CODE_REF")))
           (when (and (<= min-level level)
                      (>= max-level level)
                      (or (null status-filter)
                          (string= "" status-filter)
                          (string= status-filter status)))
             (push (list :level level
                         :title title
                         :status (or status "")
                         :owner (or owner "")
                         :code-ref (or code-ref ""))
                   results))))))
    (json-encode (nreverse results))))

(defun naur--tool-propose-edit (file start-line end-line new-content description)
  "Propose an edit to FILE from START-LINE to END-LINE with NEW-CONTENT.
DESCRIPTION is shown to the user. Requires human confirmation."
  (let* ((path (expand-file-name file (or (when-let ((proj (project-current)))
                                            (project-root proj))
                                          default-directory)))
         (original (with-temp-buffer
                     (insert-file-contents path)
                     (buffer-string)))
         (lines (split-string original "\n"))
         (before (string-join (seq-subseq lines 0 (1- start-line)) "\n"))
         (after (string-join (seq-subseq lines (min end-line (length lines))) "\n"))
         (proposed (concat before
                           (unless (string= before "") "\n")
                           new-content
                           (unless (string= after "") "\n")
                           after))
         (diff-buf (get-buffer-create "*naur-proposed-edit*")))
    (with-current-buffer diff-buf
      (erase-buffer)
      (insert (format "Proposed edit: %s\n" description))
      (insert (format "File: %s (lines %d-%d)\n\n" file start-line end-line))
      (let ((orig-file (make-temp-file "naur-orig"))
            (new-file (make-temp-file "naur-new")))
        (unwind-protect
            (progn
              (with-temp-file orig-file (insert original))
              (with-temp-file new-file (insert proposed))
              (insert (shell-command-to-string
                       (format "diff -u %s %s" orig-file new-file))))
          (delete-file orig-file)
          (delete-file new-file)))
      (diff-mode)
      (goto-char (point-min)))
    (display-buffer diff-buf)
    (if (yes-or-no-p (format "Accept edit to %s? " file))
        (progn
          (with-temp-file path (insert proposed))
          (kill-buffer diff-buf)
          "Edit accepted and applied.")
      (progn
        (kill-buffer diff-buf)
        "Edit rejected by user."))))

(defun naur--tool-update-heading (heading-path property value)
  "Set PROPERTY to VALUE on the heading at HEADING-PATH."
  (let ((spine naur--spine-file))
    (unless spine
      (error "No spine file set"))
    (with-current-buffer (find-file-noselect spine)
      (org-with-wide-buffer
       (goto-char (point-min))
       (let ((path (if (listp heading-path) heading-path
                     (split-string heading-path "/"))))
         (dolist (component path)
           (unless (re-search-forward
                    (concat "^\\*+ +" (regexp-quote component)) nil t)
             (error "Heading not found: %s" component))))
       (org-set-property property value)
       (save-buffer))
      (format "Set %s = %s" property value))))

(defun naur-register-tools ()
  "Register all naur tools with gptel."
  (gptel-make-tool
   :function #'naur--tool-get-context
   :name "get_context"
   :description "Get the human's current focus context: what file/heading they're looking at, selected text, current status."
   :args '()
   :category "naur")

  (gptel-make-tool
   :function #'naur--tool-read-file
   :name "read_file"
   :description "Read the contents of a file between specific line numbers."
   :args (list '(:name "file" :type string :description "File path relative to project root")
               '(:name "start_line" :type integer :description "First line to read (1-indexed)")
               '(:name "end_line" :type integer :description "Last line to read (inclusive)"))
   :category "naur")

  (gptel-make-tool
   :function #'naur--tool-read-heading
   :name "read_heading"
   :description "Read the content of an org spine heading by path. Returns body text, properties, and child headings (excludes conversation drawers)."
   :args (list '(:name "heading_path" :type string :description "Slash-separated path to heading, e.g. \"System/API/Auth\""))
   :category "naur")

  (gptel-make-tool
   :function #'naur--tool-list-headings
   :name "list_headings"
   :description "List org spine headings with their status, owner, and code refs. Use to understand project structure."
   :args (list '(:name "min_level" :type integer :description "Minimum heading level to include (1 = top-level)")
               '(:name "max_level" :type integer :description "Maximum heading level to include")
               '(:name "status_filter" :type string :description "Only include headings with this STATUS value. Empty string for all."))
   :category "naur")

  (gptel-make-tool
   :function #'naur--tool-propose-edit
   :name "propose_edit"
   :description "Propose a code edit to the human. Shows a diff and requires confirmation before applying."
   :args (list '(:name "file" :type string :description "File path relative to project root")
               '(:name "start_line" :type integer :description "First line to replace (1-indexed)")
               '(:name "end_line" :type integer :description "Last line to replace (inclusive)")
               '(:name "new_content" :type string :description "New content to replace the specified lines")
               '(:name "description" :type string :description "Brief description of what this edit does"))
   :category "naur"
   :confirm t)

  (gptel-make-tool
   :function #'naur--tool-update-heading
   :name "update_heading"
   :description "Update a property on an org spine heading. Use to track progress (STATUS, OWNER, CODE_REF)."
   :args (list '(:name "heading_path" :type string :description "Slash-separated path to heading")
               '(:name "property" :type string :description "Property name: STATUS, OWNER, or CODE_REF")
               '(:name "value" :type string :description "New value for the property"))
   :category "naur"))

(defun naur-activate-tools ()
  "Activate naur tools in the current gptel buffer."
  (setq-local gptel-tools
              (list (gptel-get-tool '("naur" "get_context"))
                    (gptel-get-tool '("naur" "read_file"))
                    (gptel-get-tool '("naur" "read_heading"))
                    (gptel-get-tool '("naur" "list_headings"))
                    (gptel-get-tool '("naur" "propose_edit"))
                    (gptel-get-tool '("naur" "update_heading")))))

(provide 'naur-tools)
;;; naur-tools.el ends here
