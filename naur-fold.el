;;; naur-fold.el --- Fold reasoning and tool blocks in naur chat -*- lexical-binding: t; -*-

;;; Code:

(defvar-local naur-fold--overlays nil
  "List of active fold overlays in this buffer.")

(defconst naur-fold--block-regexp
  "^[ \t]*#\\+begin_\\(reasoning\\|tool\\)\\b.*\n\\(?:.*\n\\)*?[ \t]*#\\+end_\\1"
  "Regexp matching reasoning and tool output blocks.")

(defface naur-fold-indicator
  '((t :inherit shadow :slant italic))
  "Face for fold indicator text."
  :group 'naur)

(defun naur-fold--make-indicator (type)
  "Return a fold indicator string for block TYPE."
  (propertize (format "[%s ↔]" type) 'face 'naur-fold-indicator))

(defun naur-fold--fold-region (beg end type)
  "Fold region from BEG to END, showing indicator for TYPE."
  (let ((ov (make-overlay beg end)))
    (overlay-put ov 'invisible t)
    (overlay-put ov 'display (naur-fold--make-indicator type))
    (overlay-put ov 'naur-fold t)
    (overlay-put ov 'isearch-open-invisible #'naur-fold--unfold-overlay)
    (push ov naur-fold--overlays)
    ov))

(defun naur-fold--unfold-overlay (ov)
  "Remove fold overlay OV."
  (when (overlay-buffer ov)
    (setq naur-fold--overlays (delq ov naur-fold--overlays))
    (delete-overlay ov)))

(defun naur-fold-buffer ()
  "Fold all reasoning and tool blocks in the current buffer."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward naur-fold--block-regexp nil t)
      (let ((beg (match-beginning 0))
            (end (match-end 0))
            (type (match-string 1)))
        (unless (cl-some (lambda (ov)
                           (and (overlay-get ov 'naur-fold)
                                (= (overlay-start ov) beg)))
                         (overlays-at beg))
          (naur-fold--fold-region beg end type))))))

(defun naur-fold-unfold-all ()
  "Unfold all folded blocks in the current buffer."
  (interactive)
  (dolist (ov naur-fold--overlays)
    (when (overlay-buffer ov)
      (delete-overlay ov)))
  (setq naur-fold--overlays nil))

(defun naur-fold-toggle-at-point ()
  "Toggle fold on the block at point."
  (interactive)
  (let ((existing (cl-find-if (lambda (ov) (overlay-get ov 'naur-fold))
                              (overlays-at (point)))))
    (if existing
        (naur-fold--unfold-overlay existing)
      (save-excursion
        (beginning-of-line)
        (if (looking-at "^[ \t]*#\\+begin_\\(reasoning\\|tool\\)")
            (when (re-search-forward naur-fold--block-regexp nil t)
              (naur-fold--fold-region (match-beginning 0) (match-end 0)
                                     (match-string 1)))
          (let ((pos (point)))
            (goto-char (point-min))
            (catch 'done
              (while (re-search-forward naur-fold--block-regexp nil t)
                (when (and (<= (match-beginning 0) pos)
                           (>= (match-end 0) pos))
                  (naur-fold--fold-region (match-beginning 0) (match-end 0)
                                         (match-string 1))
                  (throw 'done t))))))))))

(defun naur-fold--after-response (_beg _end)
  "Hook function to fold blocks after gptel response."
  (naur-fold-buffer))

(defun naur-fold-mode-setup ()
  "Set up folding in a naur chat buffer."
  (add-hook 'gptel-post-response-functions #'naur-fold--after-response nil t)
  (naur-fold-buffer))

(provide 'naur-fold)
;;; naur-fold.el ends here
