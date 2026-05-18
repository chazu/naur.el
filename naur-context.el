;;; naur-context.el --- Focus capture for naur -*- lexical-binding: t; -*-

;;; Code:

(require 'org)
(require 'project)
(require 'json)

(defun naur--heading-path ()
  "Return the full outline path to the current heading as a list."
  (when (derived-mode-p 'org-mode)
    (org-get-outline-path t)))

(defun naur--heading-property (prop)
  "Return the value of PROP on the current org heading."
  (when (derived-mode-p 'org-mode)
    (org-entry-get nil prop)))

(defun naur--current-heading-title ()
  "Return the title of the current org heading."
  (when (derived-mode-p 'org-mode)
    (org-get-heading t t t t)))

(defun naur--region-text ()
  "Return the active region text, or nil."
  (when (use-region-p)
    (buffer-substring-no-properties (region-beginning) (region-end))))

(defun naur--buffer-file-relative ()
  "Return the buffer file name relative to project root, or nil."
  (when-let ((file (buffer-file-name)))
    (let ((root (or (when-let ((proj (project-current)))
                      (project-root proj))
                    default-directory)))
      (file-relative-name file root))))

(defun naur--capture-context ()
  "Capture current focus context. Returns an alist.
Called from the buffer where the user invoked the agent."
  (let ((ctx nil))
    (when (derived-mode-p 'org-mode)
      (push (cons :heading (naur--current-heading-title)) ctx)
      (push (cons :heading-path (naur--heading-path)) ctx)
      (push (cons :status (naur--heading-property "STATUS")) ctx)
      (push (cons :owner (naur--heading-property "OWNER")) ctx)
      (push (cons :code-ref (naur--heading-property "CODE_REF")) ctx))
    (when (buffer-file-name)
      (push (cons :file (naur--buffer-file-relative)) ctx)
      (push (cons :line (line-number-at-pos)) ctx))
    (when-let ((region (naur--region-text)))
      (push (cons :region region) ctx))
    (nreverse ctx)))

(defun naur--context-to-json (ctx)
  "Convert context alist CTX to a JSON string."
  (json-encode ctx))

(provide 'naur-context)
;;; naur-context.el ends here
