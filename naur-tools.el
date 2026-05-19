;;; naur-tools.el --- gptel tool definitions for naur -*- lexical-binding: t; -*-

;;; Code:

(require 'gptel)
(require 'org)
(require 'diff)
(require 'naur-context)

(defvar naur--spine-file)
(declare-function naur--display-code-buffer "naur-layout")

(defun naur--tool-get-context ()
  "Return the current focus context as JSON."
  (naur--context-to-json (naur--capture-context)))

(defun naur--tool-read-file (file start-line end-line)
  "Return contents of FILE from START-LINE to END-LINE.
Also opens the file in the left pane so the human sees it."
  (let* ((root (or (when-let ((proj (project-current)))
                     (project-root proj))
                   default-directory))
         (path (expand-file-name file root))
         (buf (find-file-noselect path)))
    (unless (file-exists-p path)
      (error "File not found: %s" file))
    (let ((win (naur--display-code-buffer buf)))
      (when win
        (with-selected-window win
          (goto-char (point-min))
          (forward-line (1- (max 1 start-line)))
          (recenter 3))))
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

(defun naur--tool-search (pattern file-glob max-results)
  "Search for PATTERN in project files matching FILE-GLOB.
Returns up to MAX-RESULTS matches as file:line:content."
  (let* ((root (or (when-let ((proj (project-current)))
                     (project-root proj))
                   default-directory))
         (max-results (min (or max-results 30) 100))
         (glob (if (or (null file-glob) (string= "" file-glob))
                   "*" file-glob))
         (cmd (format "grep -rn --include=%s -m %d %s %s"
                      (shell-quote-argument glob)
                      max-results
                      (shell-quote-argument pattern)
                      (shell-quote-argument root)))
         (output (shell-command-to-string cmd)))
    (if (string= "" output)
        (format "No matches for \"%s\" in %s files." pattern glob)
      (let ((lines (split-string (string-trim output) "\n")))
        (mapconcat
         (lambda (line)
           (if (string-match (concat "^" (regexp-quote root) "/?") line)
               (substring line (match-end 0))
             line))
         lines "\n")))))

(defun naur--tool-read-conversation (heading-path)
  "Return the CONVERSATION drawer contents at HEADING-PATH, or a message if empty."
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
       (let ((end (save-excursion (org-end-of-subtree t t))))
         (if (re-search-forward "^[ \t]*:CONVERSATION:[ \t]*\n" end t)
             (let ((start (point)))
               (if (re-search-forward "^[ \t]*:END:" end t)
                   (let ((contents (string-trim
                                    (buffer-substring-no-properties
                                     start (match-beginning 0)))))
                     (if (string= "" contents)
                         "No conversation recorded yet."
                       contents))
                 "Malformed CONVERSATION drawer — no :END: found."))
           "No conversation recorded yet."))))))

(defun naur--tool-append-conversation (heading-path text)
  "Append TEXT to the CONVERSATION drawer at HEADING-PATH.
Creates the drawer if it doesn't exist."
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
       (let ((end (save-excursion (org-end-of-subtree t t))))
         (if (re-search-forward "^[ \t]*:CONVERSATION:[ \t]*\n" end t)
             (if (re-search-forward "^[ \t]*:END:" end t)
                 (progn
                   (goto-char (match-beginning 0))
                   (insert text "\n"))
               (error "Malformed CONVERSATION drawer — no :END: found"))
           (org-end-of-meta-data t)
           (insert ":CONVERSATION:\n" text "\n:END:\n"))))
      (save-buffer)
      (format "Appended to CONVERSATION drawer at %s." heading-path))))

(defun naur--tool-apply-edit (file start-line end-line new-content description)
  "Apply an edit to FILE from START-LINE to END-LINE with NEW-CONTENT.
Opens the file buffer, applies the change directly, saves, and displays
it so the human can see the result. No confirmation prompt."
  (let* ((path (expand-file-name file (or (when-let ((proj (project-current)))
                                            (project-root proj))
                                          default-directory)))
         (buf (find-file-noselect path)))
    (with-current-buffer buf
      (goto-char (point-min))
      (forward-line (1- start-line))
      (let* ((beg (point))
             (end (progn
                    (if (<= end-line start-line)
                        (end-of-line)
                      (forward-line (- end-line start-line))
                      (end-of-line))
                    (point))))
        (delete-region beg end)
        (goto-char beg)
        (insert new-content)
        (save-buffer)))
    (let ((win (naur--display-code-buffer buf)))
      (when win
        (with-selected-window win
          (goto-char (point-min))
          (forward-line (1- start-line))
          (recenter 3))))
    (format "Applied edit to %s (lines %d-%d): %s"
            file start-line end-line description)))

(defun naur--tool-propose-heading (parent-path title status owner body)
  "Propose a new heading under PARENT-PATH with TITLE, STATUS, OWNER, and BODY.
If PARENT-PATH is empty, inserts at end of spine. Requires human confirmation."
  (let ((spine naur--spine-file))
    (unless spine
      (error "No spine file set"))
    (let* ((parent-level
            (if (or (null parent-path) (string= "" parent-path))
                0
              (with-current-buffer (find-file-noselect spine)
                (org-with-wide-buffer
                 (goto-char (point-min))
                 (let ((path (split-string parent-path "/")))
                   (dolist (component path)
                     (unless (re-search-forward
                              (concat "^\\*+ +" (regexp-quote component)) nil t)
                       (error "Parent heading not found: %s" component))))
                 (org-current-level)))))
           (child-level (1+ parent-level))
           (stars (make-string child-level ?*))
           (heading-text
            (concat stars " " title "\n"
                    ":PROPERTIES:\n"
                    ":STATUS: " (or status "ideating") "\n"
                    ":OWNER: " (or owner "both") "\n"
                    ":END:\n"
                    (when (and body (not (string= "" body)))
                      (concat "\n" body "\n"))))
           (preview-buf (get-buffer-create "*naur-proposed-heading*")))
      (with-current-buffer preview-buf
        (erase-buffer)
        (insert (format "Proposed new heading under: %s\n\n"
                        (if (string= "" (or parent-path ""))
                            "(top level)" parent-path)))
        (insert heading-text)
        (org-mode)
        (goto-char (point-min)))
      (display-buffer preview-buf)
      (if (yes-or-no-p (format "Add heading \"%s\"? " title))
          (progn
            (kill-buffer preview-buf)
            (with-current-buffer (find-file-noselect spine)
              (org-with-wide-buffer
               (if (or (null parent-path) (string= "" parent-path))
                   (goto-char (point-max))
                 (goto-char (point-min))
                 (let ((path (split-string parent-path "/")))
                   (dolist (component path)
                     (re-search-forward
                      (concat "^\\*+ +" (regexp-quote component)) nil t)))
                 (org-end-of-subtree t t))
               (unless (bolp) (insert "\n"))
               (insert heading-text))
              (save-buffer))
            (format "Heading \"%s\" added." title))
        (kill-buffer preview-buf)
        (format "Heading \"%s\" rejected by user." title)))))

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
   :function #'naur--tool-search
   :name "search"
   :description "Search for a pattern across project files. Returns matching lines as file:line:content. Use to find symbol definitions, references, or patterns without knowing exact file locations."
   :args (list '(:name "pattern" :type string :description "Text or regex pattern to search for")
               '(:name "file_glob" :type string :description "File glob to filter, e.g. \"*.go\" or \"*.el\". Empty string for all files.")
               '(:name "max_results" :type integer :description "Maximum matches to return (default 30, max 100)"))
   :category "naur")

  (gptel-make-tool
   :function #'naur--tool-read-conversation
   :name "read_conversation"
   :description "Read the CONVERSATION drawer for a spine heading. Use to catch up on prior decisions and reasoning before resuming work on a heading."
   :args (list '(:name "heading_path" :type string :description "Slash-separated path to heading, e.g. \"System/API/Auth\""))
   :category "naur")

  (gptel-make-tool
   :function #'naur--tool-append-conversation
   :name "append_conversation"
   :description "Append a note to a heading's CONVERSATION drawer. Use to record key decisions, design rationale, or open questions that should persist beyond this chat session. Creates the drawer if it doesn't exist."
   :args (list '(:name "heading_path" :type string :description "Slash-separated path to heading, e.g. \"System/API/Auth\"")
               '(:name "text" :type string :description "Text to append — decisions, rationale, open questions"))
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
   :function #'naur--tool-apply-edit
   :name "apply_edit"
   :description "Apply a code edit directly to a file. Opens the file, inserts the change, saves, and displays the buffer so the human sees it. No confirmation required."
   :args (list '(:name "file" :type string :description "File path relative to project root")
               '(:name "start_line" :type integer :description "First line to replace (1-indexed)")
               '(:name "end_line" :type integer :description "Last line to replace (inclusive)")
               '(:name "new_content" :type string :description "New content to replace the specified lines")
               '(:name "description" :type string :description "Brief description of what this edit does"))
   :category "naur")

  (gptel-make-tool
   :function #'naur--tool-propose-heading
   :name "propose_heading"
   :description "Propose a new heading in the spine. Shows a preview and requires human confirmation. Use to suggest new components, subsystems, or design sections as the architecture evolves."
   :args (list '(:name "parent_path" :type string :description "Slash-separated path to parent heading, e.g. \"System/API\". Empty string for top-level.")
               '(:name "title" :type string :description "Title for the new heading")
               '(:name "status" :type string :description "Initial STATUS: ideating, specified, implementing, integrated, or revised")
               '(:name "owner" :type string :description "OWNER: human, agent, or both")
               '(:name "body" :type string :description "Body text for the heading — design notes, constraints, interface sketches"))
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
                    (gptel-get-tool '("naur" "search"))
                    (gptel-get-tool '("naur" "read_conversation"))
                    (gptel-get-tool '("naur" "append_conversation"))
                    (gptel-get-tool '("naur" "list_headings"))
                    (gptel-get-tool '("naur" "apply_edit"))
                    (gptel-get-tool '("naur" "propose_heading"))
                    (gptel-get-tool '("naur" "update_heading")))))

(provide 'naur-tools)
;;; naur-tools.el ends here
