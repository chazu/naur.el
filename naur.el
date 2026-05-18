;;; naur.el --- Co-authoring code through org-mode design documents -*- lexical-binding: t; -*-

;; Author: Chaz Straney
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (gptel "0.9.8"))
;; Keywords: tools, org, ai
;; URL: https://github.com/chazu/naur.el

;;; Commentary:

;; naur.el provides a workflow where a human and an LLM agent co-author
;; code through an org-mode design document (the "spine") that serves as
;; both the plan and the record.

;;; Code:

(require 'naur-layout)
(require 'naur-context)
(require 'naur-tools)
(require 'naur-nav)
(require 'naur-org)

;;;###autoload
(defun naur-setup ()
  "One-time setup: register tools with gptel."
  (naur-register-tools))

(provide 'naur)
;;; naur.el ends here
