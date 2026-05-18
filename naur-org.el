;;; naur-org.el --- Org property helpers and agenda integration for naur -*- lexical-binding: t; -*-

;;; Code:

(require 'org)
(require 'org-agenda)
(require 'org-capture)
(require 'gptel)

(defvar org-capture-templates)

(defvar naur--spine-file)
(defvar naur-archive-summarize)
(defvar naur-directory)

(defconst naur-status-values
  '("ideating" "specified" "implementing" "integrated" "revised")
  "Valid STATUS values for naur headings.")

(defconst naur-owner-values
  '("human" "agent" "both")
  "Valid OWNER values for naur headings.")

(defun naur-cycle-status ()
  "Cycle the STATUS property on the current org heading."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (error "Not in an org buffer"))
  (let* ((current (org-entry-get nil "STATUS"))
         (idx (or (cl-position current naur-status-values :test #'string=) -1))
         (next (nth (mod (1+ idx) (length naur-status-values))
                    naur-status-values)))
    (org-set-property "STATUS" next)
    (message "STATUS: %s" next)))

(defun naur-set-owner ()
  "Set the OWNER property on the current org heading."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (error "Not in an org buffer"))
  (let ((owner (completing-read "Owner: " naur-owner-values nil t)))
    (org-set-property "OWNER" owner)))

(defun naur-agenda ()
  "Show a custom agenda view of naur spine headings by STATUS."
  (interactive)
  (let ((spine (or naur--spine-file
                   (error "No spine file set"))))
    (let ((org-agenda-files (list spine))
          (org-agenda-custom-commands
           '(("n" "Naur spine"
              ((tags "STATUS=\"ideating\""
                     ((org-agenda-overriding-header "Ideating")))
               (tags "STATUS=\"specified\""
                     ((org-agenda-overriding-header "Specified")))
               (tags "STATUS=\"implementing\""
                     ((org-agenda-overriding-header "Implementing")))
               (tags "STATUS=\"integrated\""
                     ((org-agenda-overriding-header "Integrated")))
               (tags "STATUS=\"revised\""
                     ((org-agenda-overriding-header "Revised"))))))))
      (org-agenda nil "n"))))

(defun naur-capture-heading ()
  "Capture a new heading to the spine with STATUS defaulting to ideating."
  (interactive)
  (let ((spine (or naur--spine-file
                   (error "No spine file set"))))
    (let ((org-capture-templates
           `(("n" "Naur heading" entry
              (file ,spine)
              "* %^{Heading}\n:PROPERTIES:\n:STATUS: ideating\n:OWNER: both\n:END:\n\n%?"
              :empty-lines 1))))
      (org-capture nil "n"))))

(defun naur--conversation-drawer-contents ()
  "Return the CONVERSATION drawer contents at current heading, or nil."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (org-end-of-subtree t t))))
      (when (re-search-forward
             "^[ \t]*:CONVERSATION:[ \t]*\n" end t)
        (let ((start (point)))
          (when (re-search-forward "^[ \t]*:END:" end t)
            (string-trim
             (buffer-substring-no-properties start (match-beginning 0)))))))))

(defun naur--archive-dir ()
  "Return the conversations archive directory, creating if needed."
  (let ((dir (expand-file-name
              "conversations"
              (expand-file-name naur-directory
                                (or (when-let ((proj (project-current)))
                                      (project-root proj))
                                    default-directory)))))
    (unless (file-directory-p dir)
      (make-directory dir t))
    dir))

(defun naur--archive-file-name (heading)
  "Generate an archive filename from HEADING and current date."
  (let ((slug (replace-regexp-in-string
               "[^a-zA-Z0-9-]" "-"
               (downcase (string-trim heading)))))
    (format "%s-%s.org" slug (format-time-string "%Y-%m-%d-%H%M%S"))))

(defun naur--replace-conversation-drawer (new-contents)
  "Replace the CONVERSATION drawer at current heading with NEW-CONTENTS."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (org-end-of-subtree t t))))
      (if (re-search-forward
           "^\\([ \t]*\\):CONVERSATION:[ \t]*\n" end t)
          (let ((indent (match-string 1))
                (drawer-start (match-beginning 0)))
            (if (re-search-forward "^[ \t]*:END:" end t)
                (progn
                  (delete-region drawer-start (line-end-position))
                  (goto-char drawer-start)
                  (insert indent ":CONVERSATION:\n"
                          new-contents "\n"
                          indent ":END:"))
              (error "Malformed CONVERSATION drawer — no :END: found")))
        (org-end-of-meta-data t)
        (insert ":CONVERSATION:\n" new-contents "\n:END:\n")))))

(defun naur--do-archive (heading contents summarize)
  "Archive CONTENTS for HEADING. Summarize via LLM if SUMMARIZE is non-nil."
  (let* ((archive-dir (naur--archive-dir))
         (archive-file (expand-file-name
                        (naur--archive-file-name heading) archive-dir)))
    (with-temp-file archive-file
      (insert (format "#+TITLE: Conversation archive — %s\n" heading)
              (format "#+DATE: %s\n\n" (format-time-string "%Y-%m-%d %H:%M"))
              contents))
    (if summarize
        (gptel-request
         (format "Summarize the key decisions, outcomes, and open questions from this conversation. Be concise — a few bullet points. Do not include pleasantries or meta-commentary.\n\n%s"
                 contents)
         :callback
         (lambda (response info)
           (if (stringp response)
               (with-current-buffer (plist-get info :buffer)
                 (save-excursion
                   (org-back-to-heading t)
                   (naur--replace-conversation-drawer
                    (format "Archived: [[file:%s]]\n\n%s"
                            (file-relative-name archive-file
                                                (file-name-directory
                                                 (buffer-file-name)))
                            response))
                   (save-buffer))
                 (message "Conversation archived and summarized."))
             (message "Archive saved but summarization failed: %s"
                      (plist-get info :status)))))
      (naur--replace-conversation-drawer
       (format "Archived: [[file:%s]]"
               (file-relative-name archive-file
                                   (file-name-directory (buffer-file-name)))))
      (save-buffer)
      (message "Conversation archived to %s" archive-file))))

(defun naur-archive-conversation (arg)
  "Archive the CONVERSATION drawer at point to a file.
With \\[universal-argument], invert `naur-archive-summarize' for this call."
  (interactive "P")
  (unless (derived-mode-p 'org-mode)
    (error "Not in an org buffer"))
  (let ((contents (naur--conversation-drawer-contents))
        (heading (org-get-heading t t t t))
        (summarize (if arg (not naur-archive-summarize)
                     naur-archive-summarize)))
    (unless contents
      (error "No CONVERSATION drawer at this heading"))
    (when (yes-or-no-p
           (format "Archive conversation for \"%s\"%s? "
                   heading (if summarize " (with summary)" "")))
      (naur--do-archive heading contents summarize))))

(provide 'naur-org)
;;; naur-org.el ends here
