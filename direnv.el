;;; direnv.el --- direnv integration -*- lexical-binding: t; -*-

;; Author: wouter bolsterlee <wouter@bolsterl.ee>
;; Version: 2.2.0
;; Package-Requires: ((emacs "25.1") (dash "2.12.0"))
;; Keywords: direnv, environment, processes, unix, tools
;; URL: https://github.com/wbolster/emacs-direnv
;;
;; This file is not part of GNU Emacs.

;;; License:

;; 3-clause "new bsd"; see readme for details.

;;; Commentary:

;; direnv (https://direnv.net/) integration for Emacs.  See the readme at
;; https://github.com/wbolster/emacs-direnv for details.
;;
;; quick usage instructions for those familiar with direnv:
;;
;; - use ‘direnv-update-environment’ to manually update the Emacs
;;   environment so that inferior shells, linters, compilers, and test
;;   runners start with the intended environmental variables.
;;
;; - enable the global ‘direnv-mode’ minor mode to do this
;;   automagically upon switching buffers.
;;
;; - use ‘direnv-allow’ to mark a ‘.envrc’ file as safe.

;;; Code:

(require 'dash)
(require 'diff-mode)
(require 'json)
(require 'subr-x)

(defgroup direnv nil
  "`direnv' integration for Emacs."
  :group 'environment
  :prefix "direnv-")

(defun direnv--detect ()
  "Detect the direnv executable."
  (executable-find "direnv" t))

(defvar direnv--output-buffer-name "*direnv*"
  "Name of the buffer filled with the last direnv output.")

(defvar direnv--active-directory nil
  "Name of the directory for which direnv has most recently ran.")

(defcustom direnv-always-show-summary t
  "Whether to show a summary message of environment changes on every change.

When nil, a summary is only shown when direnv-update-environment is called
interactively."
  :group 'direnv
  :type 'boolean)

(defcustom direnv-show-paths-in-summary t
  "Whether to show directory paths in the summary message."
  :group 'direnv
  :type 'boolean)

(defcustom direnv-use-faces-in-summary t
  "Whether to use custom font faces in the summary message.

When enabled, the summary message uses custom font faces strings
for added, changed, and removed environment variables, which
usually results in coloured output."
  :group 'direnv
  :type 'boolean)

(defcustom direnv-non-file-modes
  '(comint-mode compilation-mode dired-mode eshell-mode magit-mode)
  "Major modes where direnv will update even if the buffer is not a file.

In buffers using these modes, or modes derived from them, direnv will
use `default-directory', since there is no file name (or directory)."
  :group 'direnv
  :type '(repeat (symbol :tag "Major mode")))

(defvar eshell-path-env)

(defun direnv--directory ()
  "Return the relevant directory for the current buffer, or nil."
  (let* ((buffer (or (buffer-base-buffer) (current-buffer)))
         (mode (buffer-local-value 'major-mode buffer))
         (file-name (buffer-file-name buffer))
         (buffer-directory
          (cond (file-name
                 (file-name-directory file-name))
                ((apply #'direnv--provided-mode-derived-p mode direnv-non-file-modes)
                 default-directory)
                (t  "~/"))))
    buffer-directory))

(defun direnv--export (directory)
  "Call direnv for DIRECTORY and return the parsed result."
  (let ((environment process-environment)
        (stderr-tempfile (make-temp-file "direnv-stderr"))) ;; call-process needs a file for stderr output
    (unwind-protect
        (with-current-buffer (get-buffer-create direnv--output-buffer-name)
          (erase-buffer)
          (let* ((default-directory directory)
                 (process-environment (if (file-remote-p default-directory)
					  tramp-remote-process-environment
					environment))
		 (direnv--executable (direnv--detect))
                 (exit-code (if (null direnv--executable)
				-1
			      (process-file direnv--executable nil
					    `(t ,stderr-tempfile) nil
					    "export" "json"))))
            (prog1
                (unless (zerop (buffer-size))
                  (goto-char (point-max))
                  (re-search-backward "^{")
                  (let ((json-key-type 'string)
                        (json-object-type 'alist))
                    (json-read-object)))
              (unless (zerop (direnv--file-size stderr-tempfile))
                (goto-char (point-max))
                (unless (zerop (buffer-size))
                  (insert "\n\n"))
                (insert-file-contents stderr-tempfile))
              (with-temp-buffer
                (unless (zerop exit-code)
                  (insert-file-contents stderr-tempfile)
                  (display-warning
                   'direnv
                   (format-message
                    "Error running direnv (exit code %d):\n%s\nOpen buffer ‘%s’ for full output."
                    exit-code (buffer-string) direnv--output-buffer-name)))))))
      (delete-file stderr-tempfile))))

(defun direnv--file-size (name)
  "Get the file size for a file NAME."
  (let ((attributes (file-attributes name)))
    ;; Note: file-attribute-size is Emacs 26+
    (nth 7 attributes)))

(defun direnv--enable ()
  "Enable direnv mode."
  (setq direnv--active-directory default-directory)
  (add-hook 'change-major-mode-after-body-hook #'direnv--maybe-update-environment)
  (add-to-list 'window-buffer-change-functions #'direnv--maybe-update-environment-wsc)
  (add-to-list 'window-selection-change-functions #'direnv--maybe-update-environment-wsc))

(defun direnv--disable ()
  "Disable direnv mode."
  (remove-hook 'change-major-mode-after-body-hook #'direnv--maybe-update-environment)
  (setq window-buffer-change-functions
        (delq #'direnv--maybe-update-environment-wsc window-buffer-change-functions))
  (setq window-selection-change-functions
        (delq #'direnv--maybe-update-environment-wsc window-selection-change-functions)))

(defun direnv--maybe-update-environment ()
  "Maybe update the environment.

If the current buffer's directory is different from the last
active directory, change the active directory to it and update
the environment."
  (unless (minibufferp (current-buffer))
    (let ((directory-name (direnv--directory)))
      (when (and directory-name
                 (not (string-equal direnv--active-directory directory-name))
                 (file-directory-p directory-name))
        (direnv-update-directory-environment directory-name)))))

(defun direnv--maybe-update-environment-wsc (frame)
  "Maybe update the environment after a window state change.

FRAME is the frame where it was selected, or deselected, or at
least one window has been added, deleted, assigned another buffer
or the selected window has changed since the last time window
change functions were run.

If FRAME is not selected or is a child frame, do nothing.
Otherwise, attempt to update the environment based on the
directory of the selected window's buffer."
  (unless (or (not (eq (selected-frame) frame))
              (and (fboundp 'frame-parent)
                   (frame-parent frame)))
    (with-current-buffer (window-buffer (frame-selected-window frame))
      (direnv--maybe-update-environment))))

(defun direnv--summarise-changes (items)
  "Create a summary string for ITEMS."
  (string-join
   (--map
    (let* ((name (car it))
           (state (cdr it))
           (face)
           (prefix))
      (pcase state
        (`added   (setq prefix "+" face 'diff-added))
        (`changed (setq prefix "~" face 'diff-changed))
        (`removed (setq prefix "-" face 'diff-removed)))
      (propertize (concat prefix name) 'face face))
    (--sort
     (string-lessp (symbol-name (cdr it)) (symbol-name (cdr other)))
     (--map
      (cons (car it)
            (if (cdr it) (if (getenv (car it)) 'changed 'added) 'removed))
      (--sort
       (string-lessp (car it) (car other))
       (--remove (string-prefix-p "DIRENV_" (car it)) items)))))
   " "))

(defun direnv--format-paths (old-directory new-directory)
  "Format the path component of the summary message.

The string will describe a transition from OLD-DIRECTORY and
NEW-DIRECTORY, but OLD-DIRECTORY can be nil."
  (cond
   ((or (null old-directory)
        (string-equal old-directory new-directory))
    (abbreviate-file-name (directory-file-name new-directory)))
   (t
    (format "%s → %s"
            (abbreviate-file-name (directory-file-name old-directory))
            (abbreviate-file-name (directory-file-name new-directory))))))

(defun direnv--show-summary (summary old-directory new-directory)
  "Show a SUMMARY message.

OLD-DIRECTORY and NEW-DIRECTORY are the directories before and after
the environment changes."
  (let ((summary
         (if (string-empty-p summary) "no changes" summary))
        (paths
         (when direnv-show-paths-in-summary
           (direnv--format-paths old-directory new-directory))))
    (unless direnv-use-faces-in-summary
      (setq summary (substring-no-properties summary)))
    (if paths
        (message "direnv: %s (%s)" summary paths)
      (message "direnv: %s" summary))))

(defun direnv--provided-mode-derived-p (mode &rest modes)
  "Non-nil if MODE is derived from one of MODES.

Same as ‘provided-mode-derived-p’ which is Emacs 26.1+ only."
  (while (and (not (memq mode modes))
              (setq mode (get mode 'derived-mode-parent))))
  mode)

(when (fboundp 'provided-mode-derived-p)
  (defalias 'direnv--provided-mode-derived-p 'provided-mode-derived-p))

;;;###autoload
(defun direnv-update-environment (&optional file-name force-summary)
  "Update the environment for FILE-NAME.

See `direnv-update-directory-environment' for FORCE-SUMMARY."
  (interactive)
  (when (called-interactively-p 'interactive)
    (setq force-summary t))
  (direnv-update-directory-environment
   (if file-name (file-name-directory file-name) (direnv--directory))
   force-summary))

;;;###autoload
(defun direnv-update-directory-environment (&optional directory force-summary)
  "Update the environment for DIRECTORY.

When FORCE-SUMMARY is non-nil or when called interactively, show
a summary message."
  (interactive)
  (let ((directory (or directory default-directory))
        (old-directory direnv--active-directory)
        (items)
        (summary)
        (show-summary (or force-summary (called-interactively-p 'interactive))))
    (setq direnv--active-directory directory
          items (direnv--export direnv--active-directory)
          summary (direnv--summarise-changes items))
    (when (and direnv-always-show-summary (not (string-empty-p summary)))
      (setq show-summary t))
    (when show-summary
      (direnv--show-summary summary old-directory direnv--active-directory))
    (dolist (pair items)
      (let ((name (car pair))
            (value (cdr pair))
	    (process-environment (if (file-remote-p directory)
				     tramp-remote-process-environment
				   process-environment)))
        (setenv name value)
	(when (file-remote-p directory)
	  (setq tramp-remote-process-environment process-environment))
        (when (string-equal name "PATH")
          (setq exec-path (append (parse-colon-path value) (list exec-directory)))
          ;; Prevent `eshell-path-env` getting out-of-sync with $PATH:
          (when (derived-mode-p 'eshell-mode)
            (setq eshell-path-env value)))))))

;;;###autoload
(defun direnv-allow ()
  "Run ‘direnv allow’ and update the environment afterwards."
  (interactive)
  (process-file (direnv--detect) nil 0 nil "allow")
  (direnv-update-environment))

;;;###autoload
(define-minor-mode direnv-mode
  "Global minor mode to automatically update the environment using direnv.

When this mode is active, the environment inside Emacs will be
continuously updated to match the direnv environment for the currently
visited (local) file."
  :global t
  (if direnv-mode
      (direnv--enable)
    (direnv--disable)))

(defvar direnv-envrc-stdlib-functions
  '("MANPATH_add" "PATH_add" "PATH_rm" "direnv_apply_dump" "direnv_layout_dir"
    "direnv_load" "direnv_version" "dotenv" "dotenv_if_exists"
    "env_vars_required" "expand_path" "fetchurl" "find_up" "has" "join_args"
    "layout" "load_prefix" "log_error" "log_status" "on_git_branch" "path_add"
    "path_rm" "rvm" "semver_search" "source_env" "source_env_if_exists"
    "source_up" "source_up_if_exists" "source_url" "strict_env" "unstrict_env"
    "use" "user_rel_path" "watch_dir" "watch_file")
  "`direnv' stdlib functions.")

;;;###autoload
(define-derived-mode direnv-envrc-mode
  sh-mode "envrc"
  "Major mode for .envrc files as used by direnv.

Since .envrc files are shell scripts, this mode inherits from ‘sh-mode’.
\\{direnv-envrc-mode-map}"
  (font-lock-add-keywords
   nil `((,(regexp-opt direnv-envrc-stdlib-functions 'symbols)
          (0 font-lock-keyword-face)))))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.envrc\\'" . direnv-envrc-mode))

(provide 'direnv)

;;; direnv.el ends here
