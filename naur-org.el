;;; naur-org.el --- Org property helpers and agenda integration for naur -*- lexical-binding: t; -*-

;;; Code:

(require 'org)
(require 'org-agenda)
(require 'org-capture)

(defvar org-capture-templates)

(defvar naur--spine-file)

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

(provide 'naur-org)
;;; naur-org.el ends here
