;;; naur-nav.el --- CODE_REF navigation for naur -*- lexical-binding: t; -*-

;;; Code:

(require 'org)
(require 'project)

(defvar naur--spine-file)
(defvar naur-directory)

(declare-function naur--project-root "naur-layout")
(declare-function naur--naur-dir "naur-layout")

(defun naur--resolve-spine-file ()
  "Return the spine file: buffer-local value, or find one in naur/ directory."
  (or naur--spine-file
      (let* ((dir (naur--naur-dir))
             (files (and (file-directory-p dir)
                         (directory-files dir t "\\.org$"))))
        (cond
         ((and files (= 1 (length files))) (car files))
         (files (completing-read "Spine file: " files nil t))
         (t (error "No spine file found in %s" dir))))))

(defun naur--parse-code-ref (ref)
  "Parse a CODE_REF string into (file start end) or (file symbol).
REF format: file::start-end or file::symbol."
  (when (string-match "\\(.+\\)::\\(.+\\)" ref)
    (let ((file (match-string 1 ref))
          (target (match-string 2 ref)))
      (if (string-match "\\([0-9]+\\)-\\([0-9]+\\)" target)
          (list file
                (string-to-number (match-string 1 target))
                (string-to-number (match-string 2 target)))
        (list file target)))))

(defun naur--goto-parsed-ref (parsed)
  "Jump to a parsed CODE_REF. PARSED is (file start end) or (file symbol)."
  (let* ((file (car parsed))
         (root (or (when-let ((proj (project-current)))
                     (project-root proj))
                   default-directory))
         (path (expand-file-name file root)))
    (unless (file-exists-p path)
      (error "File not found: %s" path))
    (find-file path)
    (cond
     ((= 3 (length parsed))
      (goto-char (point-min))
      (forward-line (1- (nth 1 parsed))))
     ((stringp (nth 1 parsed))
      (goto-char (point-min))
      (unless (re-search-forward (regexp-quote (nth 1 parsed)) nil t)
        (error "Symbol not found: %s" (nth 1 parsed)))
      (goto-char (match-beginning 0))))))

(defun naur-goto-code-ref ()
  "Jump to the CODE_REF on the current org heading.
If multiple refs (comma-separated), prompt with completing-read."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (error "Not in an org buffer"))
  (let ((ref-str (org-entry-get nil "CODE_REF")))
    (unless ref-str
      (error "No CODE_REF on this heading"))
    (let* ((refs (split-string ref-str "," t "[ \t]+"))
           (chosen (if (= 1 (length refs))
                       (car refs)
                     (completing-read "CODE_REF: " refs nil t)))
           (parsed (naur--parse-code-ref chosen)))
      (unless parsed
        (error "Cannot parse CODE_REF: %s" chosen))
      (naur--goto-parsed-ref parsed))))

(defun naur-set-code-ref ()
  "Set CODE_REF on the current spine heading from the current code position.
Uses active region for line range, or current line."
  (interactive)
  (let* ((file (naur--buffer-file-relative-for-ref))
         (ref (if (use-region-p)
                  (format "%s::%d-%d" file
                          (line-number-at-pos (region-beginning))
                          (line-number-at-pos (region-end)))
                (format "%s::%d" file (line-number-at-pos)))))
    (naur--set-ref-on-spine ref)))

(defun naur--buffer-file-relative-for-ref ()
  "Return buffer file name relative to project root for CODE_REF."
  (unless (buffer-file-name)
    (error "Buffer has no file"))
  (let ((root (or (when-let ((proj (project-current)))
                    (project-root proj))
                  default-directory)))
    (file-relative-name (buffer-file-name) root)))

(defun naur--set-ref-on-spine (ref)
  "Set REF as CODE_REF on a spine heading. Prompts for which heading."
  (let ((spine (naur--resolve-spine-file)))
    (let ((headings (naur--collect-heading-titles spine)))
      (unless headings
        (error "No headings in spine"))
      (let ((chosen (completing-read "Set CODE_REF on heading: " headings nil t)))
        (with-current-buffer (find-file-noselect spine)
          (org-with-wide-buffer
           (goto-char (point-min))
           (when (re-search-forward
                  (concat "^\\*+ +" (regexp-quote chosen)) nil t)
             (org-set-property "CODE_REF" ref)
             (save-buffer)))
          (message "Set CODE_REF: %s on \"%s\"" ref chosen))))))

(defun naur--collect-heading-titles (file)
  "Collect all heading titles from org FILE."
  (with-current-buffer (find-file-noselect file)
    (org-with-wide-buffer
     (goto-char (point-min))
     (let (titles)
       (while (re-search-forward org-heading-regexp nil t)
         (push (org-get-heading t t t t) titles))
       (nreverse titles)))))

;; Clickable refs in gptel buffers
(defvar naur-ref-button-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'naur-follow-ref-at-point)
    (define-key map [mouse-1] #'naur-follow-ref-at-point)
    map))

(defconst naur--code-ref-regexp
  "\\([^ \t\n]+\\)::\\([0-9]+-[0-9]+\\|[a-zA-Z_][a-zA-Z0-9_]*\\)"
  "Regexp matching file::line-range or file::symbol references.")

(defun naur-follow-ref-at-point ()
  "Follow the CODE_REF at point in a gptel buffer."
  (interactive)
  (let ((ref (thing-at-point 'filename t)))
    (when (and ref (string-match naur--code-ref-regexp ref))
      (let ((parsed (naur--parse-code-ref (match-string 0 ref))))
        (when parsed
          (naur--goto-parsed-ref parsed))))))

(defun naur-fontify-refs ()
  "Add font-lock rules for CODE_REF patterns in the current buffer."
  (font-lock-add-keywords
   nil
   `((,naur--code-ref-regexp
      0 '(face link keymap ,naur-ref-button-map mouse-face highlight) prepend))))

(provide 'naur-nav)
;;; naur-nav.el ends here
