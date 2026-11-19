;;; noteworthy-workspace.el --- Noteworthy workspace on emacs-collab  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Joy H.J. Lee

;; Author: Joy H.J. Lee
;; Version: 0.1
;; Package-Requires: ((emacs "30.1") (emacs-collab "0.1") (noteworthy "0.1") (typst-preview "0.1"))
;; Keywords: typst, tools, collaboration
;; URL: https://example.invalid/noteworthy-workspace

;; This file is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the
;; Free Software Foundation, either version 3 of the License, or (at your
;; option) any later version.  It is distributed WITHOUT ANY WARRANTY.

;;; Commentary:

;; The Noteworthy frontend of emacs-collab: what `noteworthy-init' and
;; noteworthy-collab's remote init used to be, on the layout primitives of
;; emacs-collab-layout.el.  noteworthy.el keeps the Typst editing layer;
;; this package opens a project around it.
;;
;;   M-x noteworthy-workspace-open     a LOCAL project: tree, editor on the
;;                                     first page, terminal, typst preview,
;;                                     an optional PDF/EPUB beside it.  No
;;                                     bridge, no server.
;;   M-x noteworthy-syncworthy-connect a Syncworthy/Noteworthy SERVER project,
;;                                     through `syncworthy_bridge': the bridge
;;                                     mirrors the project into a local
;;                                     directory, Emacs edits the mirror and
;;                                     syncs buffers live, tinymist previews
;;                                     the mirror locally.
;;   M-x noteworthy-workspace-quit     close it all.
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
(require 'url-parse)
(require 'auth-source)
(require 'emacs-collab)
(require 'emacs-collab-layout)
(require 'emacs-collab-mirror)
(require 'noteworthy)
(require 'noteworthy-workspace-preview)
(require 'noteworthy-workspace-pages)
(require 'noteworthy-workspace-webkit)

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

(defcustom noteworthy-workspace-bridge-command '("syncworthy_bridge")
  "The Syncworthy bridge: an argv list, or a string naming the executable."
  :type '(choice (repeat string) string)
  :group 'noteworthy-workspace)

(defcustom noteworthy-workspace-mirror-directory nil
  "Suggested location of mirrors, as HOST-PORT below this directory.
Only the suggestion shown when asking where to keep a project's local
copy (see `emacs-collab-read-mirror-dir'); nil suggests nothing, and
`emacs-collab-mirror-root' applies."
  :type 'directory
  :group 'noteworthy-workspace)

(defcustom noteworthy-workspace-display-name nil
  "Name other participants see; nil lets the bridge choose."
  :type '(choice (const nil) string)
  :group 'noteworthy-workspace)

(defcustom noteworthy-workspace-poll-secs nil
  "Seconds between the bridge's polls of the server's file tree; nil: default."
  :type '(choice (const nil) number)
  :group 'noteworthy-workspace)

(defcustom noteworthy-workspace-max-auth-attempts 3
  "How many times a rejected token is asked for again."
  :type 'integer
  :group 'noteworthy-workspace)

(defcustom noteworthy-workspace-unsynced-regexp
  (concat "\\(?:\\`\\|/\\)\\(?:\\.[^/]+\\|logs\\|output\\|build\\)/"
          "\\|\\.\\(?:pdf\\|png\\|jpe?g\\|gif\\|webp\\|ico\\|woff2?\\|[ot]tf\\|zip\\|gz\\|bin\\)\\'")
  "Project-relative paths that are never attached for live syncing.
Binary files and build output.  The bridge still mirrors them."
  :type 'regexp
  :group 'noteworthy-workspace)

(defvar noteworthy-workspace-server-history nil
  "History of servers entered, for completion.")

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

(cl-defstruct (noteworthy-workspace-session
               (:constructor noteworthy-workspace--make-session)
               (:copier nil))
  root kind server conn main master pdf (attempts 0))

(defvar noteworthy-workspace--sessions nil
  "Open sessions, newest first.")

(defun noteworthy-workspace--canon (dir)
  (file-name-as-directory (file-truename (expand-file-name dir))))

(defun noteworthy-workspace--session-for-conn (conn)
  (cl-find conn noteworthy-workspace--sessions :key #'noteworthy-workspace-session-conn))

(defun noteworthy-workspace--session-for-file (&optional file)
  "The session whose root holds FILE (default: the buffer's file or directory)."
  (let ((file (or file buffer-file-name default-directory)))
    (and file (not (file-remote-p file))
         (cl-find-if (lambda (s)
                       (and (noteworthy-workspace-session-root s)
                            (file-in-directory-p (file-truename file)
                                                 (noteworthy-workspace-session-root s))))
                     noteworthy-workspace--sessions))))

(defun noteworthy-workspace--current-session ()
  (or (noteworthy-workspace--session-for-file)
      (car noteworthy-workspace--sessions)
      (user-error "No Noteworthy workspace is open")))

;;; Hooks

(defvar noteworthy-workspace--previous-need-auth nil
  "The `emacs-collab-need-auth-function' we replaced.")

(defun noteworthy-workspace--attach-p (_conn path)
  (not (string-match-p noteworthy-workspace-unsynced-regexp path)))

(defun noteworthy-workspace--install ()
  (add-hook 'find-file-hook #'noteworthy-workspace--maybe-enable)
  (when (cl-some (lambda (s) (eq (noteworthy-workspace-session-kind s) 'remote))
                 noteworthy-workspace--sessions)
    (noteworthy-workspace--install-remote)))

(defun noteworthy-workspace--install-remote ()
  (setq emacs-collab-attach-predicate #'noteworthy-workspace--attach-p)
  (add-hook 'emacs-collab-ready-functions #'noteworthy-workspace--on-ready)
  (unless (eq emacs-collab-need-auth-function #'noteworthy-workspace--need-auth)
    (setq noteworthy-workspace--previous-need-auth emacs-collab-need-auth-function
          emacs-collab-need-auth-function #'noteworthy-workspace--need-auth)))

(defun noteworthy-workspace--uninstall ()
  (remove-hook 'find-file-hook #'noteworthy-workspace--maybe-enable)
  (when (eq emacs-collab-attach-predicate #'noteworthy-workspace--attach-p)
    (setq emacs-collab-attach-predicate nil))
  (remove-hook 'emacs-collab-ready-functions #'noteworthy-workspace--on-ready)
  (when (eq emacs-collab-need-auth-function #'noteworthy-workspace--need-auth)
    (setq emacs-collab-need-auth-function noteworthy-workspace--previous-need-auth
          noteworthy-workspace--previous-need-auth nil)))

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
  (and (stringp pdf) (not (string-empty-p pdf)) (not (file-directory-p pdf)) pdf))

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

(defun noteworthy-workspace--layout-args (s)
  "The `emacs-collab-layout-build' arguments for session S."
  (let ((args (list :tree t
                    :terminal (or noteworthy-workspace-terminal-shell t)
                    :preview (noteworthy-workspace--preview-spec)
                    :pdf (noteworthy-workspace-session-pdf s))))
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

(defun noteworthy-workspace--build (s)
  "Set the project variables and build the layout of session S."
  (let* ((root (noteworthy-workspace-session-root s))
         (master (noteworthy-workspace--master-file root))
         (main (or (noteworthy-typst-first-page root) master)))
    (setf (noteworthy-workspace-session-master s) master
          (noteworthy-workspace-session-main s) main)
    ;; Before the editor buffer exists: its mode hook reads them.
    (setq-default noteworthy-project-root root
                  noteworthy-master-file master)
    (setq noteworthy-project-root root
          noteworthy-master-file master)
    (noteworthy-workspace--seed-sizes root)
    (let ((editor (apply #'emacs-collab-layout-build
                         :root root :main-file main
                         :connection (noteworthy-workspace-session-conn s)
                         :on-quit (lambda (_root) (noteworthy-workspace--on-quit s))
                         (noteworthy-workspace--layout-args s))))
      (when-let* ((p (emacs-collab-layout-project root)))
        (setq noteworthy-pdf-buffer (emacs-collab-layout-project-pdf p)))
      (dolist (b (buffer-list))
        (with-current-buffer b (noteworthy-workspace--maybe-enable)))
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

;;; Server projects

(defun noteworthy-workspace--normalize-url (server)
  "SERVER as a URL: a bare host:port means http."
  (let ((s (string-trim server)))
    (when (string-empty-p s) (user-error "No server given"))
    (if (string-match-p "\\`[a-z][a-z0-9+.-]*://" s) s (concat "http://" s))))

(defun noteworthy-workspace--host+port (url)
  "(HOST . PORT) of URL; PORT a string, or nil when implicit."
  (let* ((u (url-generic-parse-url url)) (port (url-portspec u)))
    (cons (url-host u) (and port (number-to-string port)))))

(defun noteworthy-workspace--slug (s)
  (string-trim (replace-regexp-in-string "[^[:alnum:]._-]+" "-" s) "-+" "-+"))

(defun noteworthy-workspace--mirror-dir (url)
  "Suggested mirror of the server at URL from the defcustom, or nil."
  (when noteworthy-workspace-mirror-directory
    (let ((hp (noteworthy-workspace--host+port url)))
      (file-name-as-directory
       (expand-file-name (noteworthy-workspace--slug
                          (concat (car hp) (and (cdr hp) (concat "-" (cdr hp)))))
                         noteworthy-workspace-mirror-directory)))))

(defun noteworthy-workspace--secret (found)
  (let ((s (plist-get found :secret)))
    (if (functionp s) (funcall s) s)))

(defun noteworthy-workspace--lookup-token (url)
  "The access token for the server at URL from auth-source, or nil.
The entry's host is the server's host name (and its port, if the URL has
one); the user is ignored."
  (let* ((hp (noteworthy-workspace--host+port url))
         (found (or (and (cdr hp)
                         (car (auth-source-search :host (car hp) :port (cdr hp)
                                                  :max 1 :require '(:secret))))
                    (car (auth-source-search :host (car hp) :max 1 :require '(:secret))))))
    (and found (noteworthy-workspace--secret found))))

(defun noteworthy-workspace--bridge-argv ()
  (let* ((c noteworthy-workspace-bridge-command)
         (argv (if (stringp c) (list c) c))
         (exe (car argv)))
    (unless (or (executable-find exe)
                (and (file-name-absolute-p exe) (file-executable-p exe)))
      (user-error "Syncworthy bridge not found: %s (see README.md)" exe))
    (cons (or (executable-find exe) exe) (cdr argv))))

(defun noteworthy-workspace--need-auth (conn fields reason)
  "`emacs-collab-need-auth-function' for our connections: ask for a token."
  (if-let* ((s (noteworthy-workspace--session-for-conn conn)))
      (if (>= (cl-incf (noteworthy-workspace-session-attempts s))
              noteworthy-workspace-max-auth-attempts)
          (progn (message "noteworthy-workspace: giving up after %d rejected tokens"
                          noteworthy-workspace-max-auth-attempts)
                 nil)
        (let* ((url (noteworthy-workspace-session-server s))
               (hp (noteworthy-workspace--host+port url))
               (token (read-passwd (format "Access token for %s (%s): " url
                                           (or reason "needed")))))
          (unless (string-empty-p token)
            (when (y-or-n-p "Save it in auth-source? ")
              (ignore-errors
                (let ((found (car (apply #'auth-source-search
                                         :host (car hp) :user "token" :secret token
                                         :max 1 :create t :require '(:user :secret)
                                         (and (cdr hp) (list :port (cdr hp)))))))
                  (when-let* ((fn (plist-get found :save-function))) (funcall fn)))))
            `((token . ,token)))))
    (when noteworthy-workspace--previous-need-auth
      (funcall noteworthy-workspace--previous-need-auth conn fields reason))))

;;;###autoload
(defun noteworthy-syncworthy-connect (server &optional token force-select pdf)
  "Open the project of the Syncworthy/Noteworthy SERVER as a workspace.
PDF (or an EPUB, ...) is shown in a pane of its own, as with
`noteworthy-workspace-open'.
SERVER is a URL or host:port.  TOKEN, if the server wants one, is found in
auth-source (an entry whose host is the server's) when not given.  The
bridge (`noteworthy-workspace-bridge-command') mirrors the project into a
local directory, asked for with `emacs-collab-read-mirror-dir' the first
time and remembered per server; with a prefix argument (FORCE-SELECT)
choose again.  `noteworthy-workspace-mirror-directory' only suggests a
location.  The layout is built once the bridge reports `ready'.  Return
the emacs-collab connection."
  (interactive
   (list (completing-read "Syncworthy server: " noteworthy-workspace-server-history
                          nil nil nil 'noteworthy-workspace-server-history)
         nil current-prefix-arg))
  (let* ((url (noteworthy-workspace--normalize-url server))
         (mirror (emacs-collab-read-mirror-dir
                  "noteworthy" url (noteworthy-workspace--mirror-dir url) force-select))
         (argv (noteworthy-workspace--bridge-argv))
         (token (or token (noteworthy-workspace--lookup-token url)))
         (params `((server . ,url)
                   (mirror_dir . ,(directory-file-name mirror))
                   ,@(and noteworthy-workspace-display-name
                          `((name . ,noteworthy-workspace-display-name)))
                   ,@(and noteworthy-workspace-poll-secs
                          `((poll_secs . ,noteworthy-workspace-poll-secs)))))
         (creds (and token `((token . ,token)))))
    (when (cl-find (noteworthy-workspace--canon mirror) noteworthy-workspace--sessions
                   :key #'noteworthy-workspace-session-root :test #'equal)
      (user-error "Already open: %s" url))
    (add-to-list 'noteworthy-workspace-server-history server)
    (let ((s (noteworthy-workspace--make-session
              :root (noteworthy-workspace--canon mirror) :kind 'remote :server url
              :pdf (noteworthy-workspace--clean-pdf pdf))))
      (push s noteworthy-workspace--sessions)
      (noteworthy-workspace--install)
      (setf (noteworthy-workspace-session-conn s)
            (emacs-collab-connect argv params creds)))))

;;;###autoload
(define-obsolete-function-alias 'noteworthy-workspace-connect
  #'noteworthy-syncworthy-connect "0.2")

(defun noteworthy-workspace--on-ready (conn)
  "`emacs-collab-ready-functions': the mirror is complete, build the layout."
  (when-let* ((s (noteworthy-workspace--session-for-conn conn)))
    (setf (noteworthy-workspace-session-root s)
          (noteworthy-workspace--canon (emacs-collab-conn-root conn)))
    (condition-case err (noteworthy-workspace--build s)
      (error (message "noteworthy-workspace: layout failed: %s" (error-message-string err))))))

;;; Writing files of a mirror

(defun noteworthy-workspace--await-synced (buf &optional timeout)
  "Wait until BUF's document has its first text from the bridge."
  (let ((deadline (+ (float-time) (or timeout 5))))
    (while (and (buffer-live-p buf)
                (< (float-time) deadline)
                (not (with-current-buffer buf
                       (and (bound-and-true-p emacs-collab-mode)
                            (let ((d (emacs-collab--doc)))
                              (and d (emacs-collab-doc-synced d)))))))
      (accept-process-output nil 0.05))
    (and (buffer-live-p buf)
         (with-current-buffer buf
           (and (bound-and-true-p emacs-collab-mode)
                (let ((d (emacs-collab--doc))) (and d (emacs-collab-doc-synced d))))))))

(defun noteworthy-workspace--write-file (file text)
  "Write FILE, and tell the server if it is one of the server's.
This is `noteworthy-pages-write-function' in the workspace.  A file the
server has goes through its attached buffer, so the edit is a live one.
A new file is written to the mirror and announced with a `file create'.
Outside a server project it is a plain write."
  (let* ((s (noteworthy-workspace--session-for-file file))
         (conn (and s (eq (noteworthy-workspace-session-kind s) 'remote)
                    (noteworthy-workspace-session-conn s))))
    (if (not (and conn (memq conn emacs-collab--connections)
                  (emacs-collab-conn-ready conn)))
        (noteworthy-pages-write-file file text)
      (let ((rel (file-relative-name (file-truename (file-name-directory file))
                                     (emacs-collab-conn-root-true conn))))
        (setq rel (concat (if (equal rel "./") "" rel) (file-name-nondirectory file)))
        (if (not (file-exists-p file))
            (progn (noteworthy-pages-write-file file text)
                   (emacs-collab-file-create conn rel text))
          (let ((buf (find-file-noselect file)))
            (if (not (noteworthy-workspace--await-synced buf))
                (noteworthy-pages-write-file file text)
              (with-current-buffer buf
                (let ((src (generate-new-buffer " *nws-src*")))
                  (unwind-protect
                      (progn (with-current-buffer src (insert text))
                             (replace-region-contents (point-min) (point-max)
                                                      (lambda () src) 1.0))
                    (kill-buffer src)))
                (save-buffer)))))))))

(setq noteworthy-pages-write-function #'noteworthy-workspace--write-file)

;;; Quit

(defvar xwidget-webkit-mode)

(defun noteworthy-workspace--on-quit (s)
  "What quitting adds to `emacs-collab-layout-quit': Noteworthy's own cleanup.
Stops every typst-preview server and the log it keeps, forgets the project
variables and the session."
  (let ((root (noteworthy-workspace-session-root s)))
    (noteworthy-pages--stop-preview)
    (when-let* ((ws (get-buffer "*ws-typst-server*")))
      (when-let* ((p (get-buffer-process ws))) (set-process-query-on-exit-flag p nil))
      (kill-buffer ws))
    (when (equal noteworthy-project-root root)
      (setq noteworthy-project-root nil
            noteworthy-master-file nil
            noteworthy-pdf-buffer nil)
      (setq-default noteworthy-project-root nil
                    noteworthy-master-file nil))
    (noteworthy-workspace--forget s)))

(defun noteworthy-workspace--forget (s)
  (setq noteworthy-workspace--sessions (delq s noteworthy-workspace--sessions))
  (unless noteworthy-workspace--sessions
    (dolist (b (buffer-list))
      (when (buffer-local-value 'noteworthy-workspace-mode b)
        (with-current-buffer b (noteworthy-workspace-mode -1))))
    (noteworthy-workspace--uninstall)))

;;;###autoload
(defun noteworthy-workspace-quit ()
  "Close the Noteworthy workspace and everything it started.
`emacs-collab-layout-quit' -- save offer, preview, language server, bridge,
buffers, PDF, terminal, tree, dashboard -- plus stopping the typst-preview
servers and forgetting the project."
  (interactive)
  (let ((s (noteworthy-workspace--current-session)))
    (emacs-collab-layout-quit (noteworthy-workspace-session-root s))
    ;; A session whose layout never came up (the bridge failed) has no on-quit.
    (when (memq s noteworthy-workspace--sessions)
      (when-let* ((c (noteworthy-workspace-session-conn s)))
        (when (memq c emacs-collab--connections) (emacs-collab-disconnect c)))
      (noteworthy-workspace--on-quit s))))

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
  (let* ((s (noteworthy-workspace--current-session))
         (conn (noteworthy-workspace-session-conn s)))
    (message "noteworthy: %s%s"
             (abbreviate-file-name (noteworthy-workspace-session-root s))
             (if conn
                 (format " -- %s%s, %s; %d document(s), %d peer(s)"
                         (emacs-collab-conn-status conn)
                         (if-let* ((x (emacs-collab-conn-status-detail conn))) (format " (%s)" x) "")
                         (noteworthy-workspace-session-server s)
                         (hash-table-count (emacs-collab-conn-docs conn))
                         (hash-table-count (emacs-collab-conn-peers conn)))
               " (local)"))))

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
