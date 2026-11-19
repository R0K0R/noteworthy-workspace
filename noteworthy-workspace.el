;;; noteworthy-workspace.el --- Noteworthy workspace on emacs-collab  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Joy H.J. Lee

;; Author: Joy H.J. Lee
;; Version: 0.2
;; Package-Requires: ((emacs "30.1") (emacs-collab "0.1") (syncworthy-workspace "0.1") (noteworthy "0.1") (typst-preview "0.1"))
;; Keywords: typst, tools, collaboration
;; URL: https://github.com/R0K0R/noteworthy-workspace

;; This file is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the
;; Free Software Foundation, either version 3 of the License, or (at your
;; option) any later version.  It is distributed WITHOUT ANY WARRANTY.

;;; Commentary:

;; The Typst layer of emacs-collab's Noteworthy frontend: what
;; `noteworthy-init' and noteworthy-collab's remote init used to be, on the
;; layout primitives of emacs-collab-layout.el.  noteworthy.el keeps the
;; Typst editing layer; this package opens a project around it.  Server
;; projects are the generic Syncworthy client of syncworthy-workspace.el
;; plus the Typst extras: the preview column, typst inputs, pages, sizes.
;;
;;   M-x noteworthy-workspace-open  a LOCAL project: tree, editor on the
;;                                  first page, terminal, typst preview, an
;;                                  optional PDF/EPUB beside it.  No bridge,
;;                                  no server.
;;   M-x noteworthy-connect         a Syncworthy/Noteworthy SERVER project,
;;                                  through `syncworthy_bridge': the bridge
;;                                  mirrors the project into a local
;;                                  directory, Emacs edits the mirror and
;;                                  syncs buffers live, typst-preview shows
;;                                  the mirror locally.
;;   M-x noteworthy-workspace-quit  close it all (either kind).
;;
;; In a project's buffers (`noteworthy-workspace-mode', and the Typst mode
;; map of noteworthy.el):
;;
;;   M-t n  `noteworthy-new-page'        M-t r  `noteworthy-refresh-preview'
;;   M-t q  `noteworthy-workspace-quit'  M-t l  `noteworthy-toggle-log'
;;
;; `noteworthy-init' and `noteworthy-quit' remain as the names they always
;; had.  See README.md.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'json)
(require 'emacs-collab)
(require 'emacs-collab-layout)
(require 'emacs-collab-mirror)
(require 'syncworthy-workspace)
(require 'noteworthy)
(require 'noteworthy-workspace-preview)
(require 'noteworthy-workspace-pages)
(require 'noteworthy-workspace-webkit)

;; The server options live in syncworthy-workspace now.
(define-obsolete-variable-alias 'noteworthy-workspace-bridge-command
  'syncworthy-workspace-bridge-command "0.2")
(define-obsolete-variable-alias 'noteworthy-workspace-mirror-directory
  'syncworthy-workspace-mirror-directory "0.2")
(define-obsolete-variable-alias 'noteworthy-workspace-display-name
  'syncworthy-workspace-display-name "0.2")
(define-obsolete-variable-alias 'noteworthy-workspace-poll-secs
  'syncworthy-workspace-poll-secs "0.2")
(define-obsolete-variable-alias 'noteworthy-workspace-max-auth-attempts
  'syncworthy-workspace-max-auth-attempts "0.2")
(define-obsolete-variable-alias 'noteworthy-workspace-unsynced-regexp
  'syncworthy-workspace-unsynced-regexp "0.2")
(define-obsolete-variable-alias 'noteworthy-workspace-server-history
  'syncworthy-workspace-server-history "0.2")

(defvaralias 'noteworthy-terminal-shell 'noteworthy-workspace-terminal-shell)
(defcustom noteworthy-workspace-terminal-shell nil
  "Command for the terminal pane: a string, an argv list, or nil.
Nil runs $SHELL.  Also reachable as `noteworthy-terminal-shell'."
  :type '(choice (const :tag "$SHELL" nil)
                 (string :tag "Shell")
                 (repeat :tag "Argv" string))
  :group 'noteworthy-workspace)

(defcustom noteworthy-workspace-preview 'auto
  "What fills the preview pane.
`auto' starts typst-preview in an xwidget when Emacs has xwidgets (no
pane otherwise), nil builds no preview pane, and a function is passed to
`emacs-collab-layout-build' as its `:preview' (called with the project
root in the pane, returning a buffer)."
  :type '(choice (const :tag "typst-preview in an xwidget, if possible" auto)
                 (const :tag "No preview pane" nil)
                 function)
  :group 'noteworthy-workspace)

(defcustom noteworthy-workspace-layout-args '(:tree t)
  "Extra `emacs-collab-layout-build' arguments, over the defaults.
The defaults are :tree, :terminal, :preview and :pdf as the other options
and the arguments of the command give them; a key given here wins."
  :type 'plist
  :group 'noteworthy-workspace)

;;; Typst inputs
;;
;; Every task that compiles the template -- the preview, the language server --
;; needs the chapter and page folders as typst inputs, or the template looks
;; for content/0/0.typ.  noteworthy.el reads them from `noteworthy.py
;; --print-inputs', or scans content/ for a mirror that has no script.

(defun noteworthy-workspace-typst-input-args (root &optional force)
  "The inputs of ROOT as separate arguments: `--input', `k=v', ...
The shape `tinymist.doStartPreview' and the typst CLI take.  Remembered
until the project's files change; with FORCE, read again."
  (let ((root (file-name-as-directory (expand-file-name root))))
    (when force (remhash root noteworthy--dynamic-inputs-cache))
    (noteworthy-typst-get-dynamic-inputs root)))

(defun noteworthy-workspace-typst-input-flags (root &optional force)
  "The inputs of ROOT as single `--input=k=v' arguments, as lsp-mode wants.
For tinymist's `typstExtraArgs'; the same facts as
`noteworthy-workspace-typst-input-args'."
  (let ((pairs (noteworthy-workspace-typst-input-args root force)) out)
    (while pairs
      (if (and (equal (car pairs) "--input") (cadr pairs))
          (progn (push (concat "--input=" (cadr pairs)) out)
                 (setq pairs (cddr pairs)))
        (push (car pairs) out)
        (setq pairs (cdr pairs))))
    (nreverse out)))

;;; Sessions
;;
;; A local project is a `noteworthy-workspace-session'.  A server project is
;; a `syncworthy-workspace-session' of kind `noteworthy'.

(cl-defstruct (noteworthy-workspace-session
               (:constructor noteworthy-workspace--make-session)
               (:copier nil))
  root kind main master pdf)

(defvar noteworthy-workspace--sessions nil
  "Open LOCAL sessions, newest first.")

(defun noteworthy-workspace--canon (dir)
  (file-name-as-directory (file-truename (expand-file-name dir))))

(defun noteworthy-workspace--server-sessions ()
  "The open server sessions that are Noteworthy's."
  (cl-remove-if-not (lambda (s) (eq (syncworthy-workspace-session-kind s) 'noteworthy))
                    syncworthy-workspace--sessions))

(defun noteworthy-workspace--any-session-p ()
  (or noteworthy-workspace--sessions (noteworthy-workspace--server-sessions)))

(defun noteworthy-workspace--session-for-file (&optional file)
  "The session, local or server, whose root holds FILE (default: this buffer's)."
  (let ((file (or file buffer-file-name default-directory)))
    (and file (not (file-remote-p file))
         (let ((true (file-truename file)))
           (cl-find-if (lambda (s)
                         (let ((root (if (noteworthy-workspace-session-p s)
                                         (noteworthy-workspace-session-root s)
                                       (syncworthy-workspace-session-root s))))
                           (and root (file-in-directory-p true root))))
                       (append noteworthy-workspace--sessions
                               (noteworthy-workspace--server-sessions)))))))

(defun noteworthy-workspace--current-session ()
  (or (noteworthy-workspace--session-for-file)
      (car noteworthy-workspace--sessions)
      (car (noteworthy-workspace--server-sessions))
      (user-error "No Noteworthy workspace is open")))

;;; Hooks

(defun noteworthy-workspace--install ()
  (add-hook 'find-file-hook #'noteworthy-workspace--maybe-enable))

(defun noteworthy-workspace--uninstall ()
  (remove-hook 'find-file-hook #'noteworthy-workspace--maybe-enable))

;;; Layout

(defun noteworthy-workspace--master-file (dir)
  "The file the preview compiles: the template's parser.typ, else a .typ file."
  (let ((core (expand-file-name "templates/core/parser.typ" dir))
        (old (expand-file-name "templates/parser.typ" dir)))
    (cond ((file-exists-p core) core)
          ((file-exists-p old) old)
          (t (or (car (directory-files-recursively dir "\\.typ\\'"))
                 (expand-file-name "main.typ" dir))))))

(defun noteworthy-workspace--clean-pdf (pdf)
  (syncworthy-workspace--clean-pdf pdf))

(defun noteworthy-workspace--preview-spec ()
  (pcase noteworthy-workspace-preview
    ('auto (and (noteworthy-xwidget-available-p) (fboundp 'typst-preview-start)
                #'noteworthy-workspace--start-preview))
    (spec spec)))

(defun noteworthy-workspace--placeholder (root)
  (with-current-buffer (get-buffer-create
                        (format "*noteworthy-preview: %s*"
                                (file-name-nondirectory (directory-file-name root))))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "\n  Starting the preview...\n"))
    (special-mode)
    (current-buffer)))

(defun noteworthy-workspace--start-preview (root)
  "Start typst-preview on ROOT's master file; return the placeholder it shows.
The xwidget typst-preview opens when its server is up replaces the
placeholder (`noteworthy-xwidget-in-side-window').  The start is from the
editor buffer, as it always was, with the project's dynamic inputs."
  (let* ((p (emacs-collab-layout-project root))
         (eb (and p (emacs-collab-layout-project-editor-buffer p)))
         (master (or (bound-and-true-p noteworthy-master-file)
                     (noteworthy-workspace--master-file root))))
    (when (buffer-live-p eb)
      (with-current-buffer eb
        (setq-local noteworthy-project-root root
                    noteworthy-master-file master
                    typst-preview-default-dir root
                    typst-preview--master-file master
                    typst-preview-cmd-options
                    (append (default-value 'typst-preview-cmd-options)
                            (ignore-errors (noteworthy-typst-get-dynamic-inputs root))))
        (typst-preview-start t)))
    (noteworthy-workspace--placeholder root)))

(defun noteworthy-workspace--layout-args (pdf)
  "The `emacs-collab-layout-build' arguments of a Noteworthy project with PDF."
  (let ((args (list :tree t
                    :terminal (or noteworthy-workspace-terminal-shell t)
                    :preview (noteworthy-workspace--preview-spec)
                    :pdf pdf)))
    (cl-loop for (k v) on noteworthy-workspace-layout-args by #'cddr
             do (setq args (plist-put args k v)))
    (cl-loop for (k v) on args by #'cddr
             unless (memq k '(:root :main-file :connection :on-quit))
             append (list k v))))

(defvar treemacs-width)
(defvar emacs-collab-layout--sizes)
(declare-function emacs-collab-layout--load-state "emacs-collab-layout" ())

(defun noteworthy-workspace--seed-sizes (root)
  "Start ROOT's layout from the sizes the old layout remembered.
Only while the layout has none of its own for ROOT: the widths in the
project's `.noteworthy-layout' (:pdf-width, :preview-width), and the
tree at `treemacs-width', as the old layout had it."
  (emacs-collab-layout--load-state)
  (require 'treemacs nil t)           ; for `treemacs-width'
  (let ((key (emacs-collab-layout--canon root)))
    (unless (assoc key emacs-collab-layout--sizes)
      (let* ((file (expand-file-name ".noteworthy-layout" root))
             (old (and (file-readable-p file)
                       (ignore-errors
                         (with-temp-buffer
                           (insert-file-contents file)
                           (read (current-buffer))))))
             (seed (append
                    (and (bound-and-true-p treemacs-width)
                         (list :tree-width treemacs-width))
                    (cl-loop for k in '(:pdf-width :preview-width)
                             for v = (and (listp old) (plist-get old k))
                             when (integerp v) append (list k v)))))
        (when seed
          (push (cons key seed) emacs-collab-layout--sizes))))))

(defun noteworthy-workspace--prepare (root master)
  "Set the project variables for ROOT and seed its layout sizes.
Before the editor buffer exists: its mode hook reads the variables."
  (setq-default noteworthy-project-root root
                noteworthy-master-file master)
  (setq noteworthy-project-root root
        noteworthy-master-file master)
  (noteworthy-workspace--seed-sizes root))

(defun noteworthy-workspace--finish (root)
  "After the layout of ROOT: the PDF buffer, and the keys in the project's buffers."
  (when-let* ((p (emacs-collab-layout-project root)))
    (setq noteworthy-pdf-buffer (emacs-collab-layout-project-pdf p)))
  (dolist (b (buffer-list))
    (with-current-buffer b (noteworthy-workspace--maybe-enable))))

(defun noteworthy-workspace--build (s)
  "Set the project variables and build the layout of local session S."
  (let* ((root (noteworthy-workspace-session-root s))
         (master (noteworthy-workspace--master-file root))
         (main (or (noteworthy-typst-first-page root) master)))
    (setf (noteworthy-workspace-session-master s) master
          (noteworthy-workspace-session-main s) main)
    (noteworthy-workspace--prepare root master)
    (let ((editor (apply #'emacs-collab-layout-build
                         :root root :main-file main
                         :on-quit (lambda (_root) (noteworthy-workspace--on-quit s))
                         (noteworthy-workspace--layout-args
                          (noteworthy-workspace-session-pdf s)))))
      (noteworthy-workspace--finish root)
      editor)))

;;; Local projects

;;;###autoload
(defun noteworthy-workspace-open (&optional dir pdf)
  "Open the local Noteworthy project DIR as a workspace.
Tree, the first page in the editor, a terminal, the typst preview, and PDF
\(or an EPUB, or anything Emacs can show) in a pane of its own.  Without
DIR, ask.  Return the editor window."
  (interactive
   (let ((d (read-directory-name "Noteworthy project: ")))
     (list d (read-file-name "Secondary PDF (optional): " d nil nil))))
  (let* ((dir (noteworthy-workspace--canon
               (or dir (read-directory-name "Noteworthy project: "))))
         (old (cl-find dir noteworthy-workspace--sessions
                       :key #'noteworthy-workspace-session-root :test #'equal)))
    ;; Rebuilding: close the old one first, which clears the variables the
    ;; new one sets.
    (when old (emacs-collab-layout-quit dir 'no-close))
    (let ((s (noteworthy-workspace--make-session
              :root dir :kind 'local :pdf (noteworthy-workspace--clean-pdf pdf))))
      (push s noteworthy-workspace--sessions)
      (noteworthy-workspace--install)
      (prog1 (noteworthy-workspace--build s)
        (message "Noteworthy initialized: %s" dir)))))

;;; Server projects: the Typst extras on `syncworthy-workspace'

(defun noteworthy-workspace--noteworthy-p (s)
  (eq (syncworthy-workspace-session-kind s) 'noteworthy))

(defun noteworthy-workspace--server-main (s)
  (when (noteworthy-workspace--noteworthy-p s)
    (let ((root (syncworthy-workspace-session-root s)))
      (or (noteworthy-typst-first-page root) (noteworthy-workspace--master-file root)))))

(defun noteworthy-workspace--server-layout-args (s)
  (when (noteworthy-workspace--noteworthy-p s)
    (noteworthy-workspace--layout-args (syncworthy-workspace-session-pdf s))))

(defun noteworthy-workspace--server-before-build (s)
  (when (noteworthy-workspace--noteworthy-p s)
    (let* ((root (syncworthy-workspace-session-root s))
           (master (noteworthy-workspace--master-file root)))
      (setf (syncworthy-workspace-session-extras s)
            (plist-put (syncworthy-workspace-session-extras s) :master master))
      (noteworthy-workspace--prepare root master))))

(defun noteworthy-workspace--server-after-build (s _editor)
  (when (noteworthy-workspace--noteworthy-p s)
    (noteworthy-workspace--finish (syncworthy-workspace-session-root s))))

(defun noteworthy-workspace--server-quit (s)
  (when (noteworthy-workspace--noteworthy-p s)
    (noteworthy-workspace--cleanup (syncworthy-workspace-session-root s))
    (noteworthy-workspace--maybe-uninstall)))

(add-hook 'syncworthy-workspace-main-file-functions #'noteworthy-workspace--server-main)
(add-hook 'syncworthy-workspace-layout-args-functions #'noteworthy-workspace--server-layout-args)
(add-hook 'syncworthy-workspace-before-build-functions #'noteworthy-workspace--server-before-build)
(add-hook 'syncworthy-workspace-after-build-functions #'noteworthy-workspace--server-after-build)
(add-hook 'syncworthy-workspace-quit-functions #'noteworthy-workspace--server-quit)

;;;###autoload
(defun noteworthy-connect (server &optional token force-select pdf)
  "Open the project of the Syncworthy/Noteworthy SERVER as a workspace.
`syncworthy-connect' with the Typst extras: the preview column, the typst
inputs, new pages that reach the server, and the layout sizes seeded from
`.noteworthy-layout'.  PDF (or an EPUB, ...) is shown in a pane of its own,
as with `noteworthy-workspace-open'.
SERVER is a URL or host:port.  TOKEN, if the server wants one, is found in
auth-source (an entry whose host is the server's) when not given.  The
bridge (`syncworthy-workspace-bridge-command') mirrors the project into a
local directory, asked for with `emacs-collab-read-mirror-dir' the first
time and remembered per server; with a prefix argument (FORCE-SELECT)
choose again.  The layout is built once the bridge reports `ready'.
Return the emacs-collab connection."
  (interactive
   (list (completing-read "Syncworthy server: " syncworthy-workspace-server-history
                          nil nil nil 'syncworthy-workspace-server-history)
         nil current-prefix-arg))
  (prog1 (syncworthy-workspace-connect
          server :token token :force-select force-select :pdf pdf
          ;; Remembered mirrors of Noteworthy servers are under "noteworthy".
          :service "noteworthy" :kind 'noteworthy)
    (noteworthy-workspace--install)))

;;;###autoload
(define-obsolete-function-alias 'noteworthy-syncworthy-connect #'noteworthy-connect "0.2")
;;;###autoload
(define-obsolete-function-alias 'noteworthy-workspace-connect #'noteworthy-connect "0.2")

;;; Writing files of a mirror

(defun noteworthy-workspace--write-file (file text)
  "Write FILE; if it is one of a server's, tell the server too.
This is `noteworthy-pages-write-function' in the workspace."
  (syncworthy-workspace-write-file file text #'noteworthy-pages-write-file))

(setq noteworthy-pages-write-function #'noteworthy-workspace--write-file)

;;; Quit

(defvar xwidget-webkit-mode)

(defun noteworthy-workspace--cleanup (root)
  "Stop the typst-preview servers and their log; forget ROOT's project variables."
  (noteworthy-pages--stop-preview)
  (when-let* ((ws (get-buffer "*ws-typst-server*")))
    (when-let* ((p (get-buffer-process ws))) (set-process-query-on-exit-flag p nil))
    (kill-buffer ws))
  (when (equal noteworthy-project-root root)
    (setq noteworthy-project-root nil
          noteworthy-master-file nil
          noteworthy-pdf-buffer nil)
    (setq-default noteworthy-project-root nil
                  noteworthy-master-file nil)))

(defun noteworthy-workspace--maybe-uninstall ()
  "With no Noteworthy session left, drop the mode and the hook."
  (unless (noteworthy-workspace--any-session-p)
    (dolist (b (buffer-list))
      (when (buffer-local-value 'noteworthy-workspace-mode b)
        (with-current-buffer b (noteworthy-workspace-mode -1))))
    (noteworthy-workspace--uninstall)))

(defun noteworthy-workspace--on-quit (s)
  "What quitting adds to `emacs-collab-layout-quit' for the local session S:
Noteworthy's own cleanup, and forgetting the session."
  (noteworthy-workspace--cleanup (noteworthy-workspace-session-root s))
  (noteworthy-workspace--forget s))

(defun noteworthy-workspace--forget (s)
  (setq noteworthy-workspace--sessions (delq s noteworthy-workspace--sessions))
  (noteworthy-workspace--maybe-uninstall))

;;;###autoload
(defun noteworthy-workspace-quit ()
  "Close the Noteworthy workspace and everything it started.
`emacs-collab-layout-quit' -- save offer, preview, language server, bridge,
buffers, PDF, terminal, tree, dashboard -- plus stopping the typst-preview
servers and forgetting the project.  A local project or a server's."
  (interactive)
  (let ((s (noteworthy-workspace--current-session)))
    (if (syncworthy-workspace-session-p s)
        (syncworthy-workspace-quit-session s)
      (emacs-collab-layout-quit (noteworthy-workspace-session-root s))
      ;; A session whose layout never came up has no on-quit.
      (when (memq s noteworthy-workspace--sessions)
        (noteworthy-workspace--on-quit s)))))

;;; Mode and commands

(defvar noteworthy-workspace-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "M-t n") #'noteworthy-new-page)
    (define-key map (kbd "M-t r") #'noteworthy-refresh-preview)
    (define-key map (kbd "M-t q") #'noteworthy-workspace-quit)
    (define-key map (kbd "M-t l") #'noteworthy-toggle-log)
    map)
  "Keymap of `noteworthy-workspace-mode'.
Typst buffers have the same keys in `noteworthy-typst-mode-map'.")

(define-minor-mode noteworthy-workspace-mode
  "Keys for a buffer of an open Noteworthy workspace.
\\{noteworthy-workspace-mode-map}"
  :lighter " NWS" :keymap noteworthy-workspace-mode-map)

(defun noteworthy-workspace--maybe-enable ()
  (when (and buffer-file-name (not noteworthy-workspace-mode)
             (noteworthy-workspace--session-for-file buffer-file-name))
    (noteworthy-workspace-mode 1)))


(defun noteworthy-workspace-status ()
  "Show the state of the current workspace."
  (interactive)
  (let ((s (noteworthy-workspace--current-session)))
    (if (syncworthy-workspace-session-p s)
        (message "%s" (syncworthy-workspace-describe s "noteworthy"))
      (message "noteworthy: %s (local)"
               (abbreviate-file-name (noteworthy-workspace-session-root s))))))

;;;###autoload
(defun noteworthy-toggle-log ()
  "Toggle the terminal window between the shell and the Typst preview log."
  (interactive)
  (let* ((log "*ws-typst-server*")
         (win (or (emacs-collab-layout-window 'terminal)
                  (cl-find-if (lambda (w) (with-current-buffer (window-buffer w)
                                            (or (equal (buffer-name) log)
                                                (derived-mode-p 'vterm-mode))))
                              (window-list)))))
    (if (not win)
        (message "Noteworthy: No terminal/log window found.")
      (with-selected-window win
        (if (equal (buffer-name) log)
            (if-let* ((term (and-let* ((p (emacs-collab-layout-project
                                           (window-parameter win 'emacs-collab-layout-root)))
                                       (b (emacs-collab-layout-project-terminal p))
                                       ((buffer-live-p b)))
                              b)))
                (switch-to-buffer term)
              (message "Noteworthy: terminal buffer not found"))
          (if (get-buffer log)
              (switch-to-buffer log)
            (message "Noteworthy: Log buffer %s does not exist." log)))))))

;;; Names `noteworthy.el' used to have

;;;###autoload
(defalias 'noteworthy-init #'noteworthy-workspace-open
  "Open a Noteworthy project: `noteworthy-workspace-open', under its old name.")
;;;###autoload
(defalias 'noteworthy-quit #'noteworthy-workspace-quit
  "Close the workspace: `noteworthy-workspace-quit', under its old name.")

;; Doom configurations configure the terminal in `use-package! noteworthy-layout'.
(provide 'noteworthy-layout)
(provide 'noteworthy-workspace)
;;; noteworthy-workspace.el ends here
