;;; noteworthy-workspace-test.el --- Tests  -*- lexical-binding: t; -*-

;; Batch Emacs, no bridge.  The project is a COPY of a real Noteworthy
;; project: set NWS_TEST_PROJECT to the directory to copy (default: the
;; General Physics I notes).  The copy lives in a scratch directory and
;; is deleted afterwards; the original is never touched.
;;
;;   emacs --batch -L ... -l test/noteworthy-workspace-test.el \
;;         -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(require 'noteworthy-workspace)

(defconst nws-test--source
  (expand-file-name (or (getenv "NWS_TEST_PROJECT")
                        "~/KSA/General_Physics_I/noteworthy")))

(defun nws-test--tmp ()
  (file-name-as-directory
   (file-truename (make-temp-file
                   (expand-file-name "nws-" (or (getenv "NWS_TEST_TMPDIR")
                                                temporary-file-directory))
                   t))))

(defun nws-test--wait (pred &optional timeout)
  (let ((deadline (+ (float-time) (or timeout 15))) r)
    (while (and (not (setq r (funcall pred))) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (or r (ert-fail (list "timeout waiting for" pred)))))

(defun nws-test--roles ()
  (delq nil (mapcar (lambda (w) (window-parameter w 'emacs-collab-role))
                    (window-list nil 'no-minibuf))))

(defvar features)
(defvar nws-test--lsp-calls nil)
(defvar nws-test--started nil
  "Buffers `typst-preview-start' was called from.")

(defun nws-test--preview-buffer (_root)
  (with-current-buffer (get-buffer-create "*nws-test-preview*")
    (insert "preview")
    (current-buffer)))

(defmacro nws-test--with-project (spec &rest body)
  "SPEC is (DIR).  Run BODY with DIR a scratch copy of the project."
  (declare (indent 1))
  `(let* ((,(car spec) (let ((d (nws-test--tmp)))
                         (copy-directory nws-test--source d t t t)
                         (dolist (junk '(".direnv" ".claude"))
                           (ignore-errors (delete-directory (expand-file-name junk d) t)))
                         (file-name-as-directory d)))
          (emacs-collab-layout-state-file (expand-file-name "state.eld" ,(car spec)))
          (emacs-collab-layout--sizes nil)
          (emacs-collab-layout--sizes-loaded nil)
          (emacs-collab-layout--projects nil)
          (emacs-collab-layout-last-root nil)
          (emacs-collab--connections nil)
          (noteworthy-workspace--sessions nil)
          (noteworthy-workspace-preview #'nws-test--preview-buffer)
          (noteworthy-workspace-terminal-shell nil)
          (nws-test--lsp-calls nil)
          (nws-test--started nil)
          (noteworthy-project-root nil)
          (noteworthy-master-file nil)
          (unrelated (generate-new-buffer "*unrelated*")))
     (cl-letf (((symbol-function 'typst-preview-start)
                (lambda (&rest _) (push (current-buffer) nws-test--started)))
               ((symbol-function 'typst-preview-stop) #'ignore))
       (save-window-excursion
         (unwind-protect (progn ,@body)
           (ignore-errors (emacs-collab-layout-quit ,(car spec)))
           (kill-buffer unrelated)
           (dolist (b (buffer-list))
             (when-let* ((f (buffer-file-name b)))
               (when (string-prefix-p ,(car spec) (file-truename f))
                 (with-current-buffer b (set-buffer-modified-p nil))
                 (kill-buffer b))))
           (setq noteworthy-workspace--sessions nil)
           (noteworthy-workspace--uninstall)
           (ignore-errors (delete-directory ,(car spec) t)))))))

(defmacro nws-test--with-stub-lsp (&rest body)
  "Run BODY with an lsp-mode that only records the folders it is given."
  `(let ((features (cons 'lsp-mode features)))
     (cl-letf (((symbol-function 'lsp-session) (lambda () 'session))
               ((symbol-function 'lsp-session-folders) (lambda (_) nil))
               ((symbol-function 'lsp-f-canonical) #'identity)
               ((symbol-function 'lsp-workspace-folders-add)
                (lambda (d) (push d nws-test--lsp-calls)))
               ((symbol-function 'lsp-workspace-shutdown) #'ignore)
               ((symbol-function 'lsp--session-workspaces) (lambda (_) nil)))
       ,@body)))

(defun nws-test--fake-pdf (dir)
  (let ((f (expand-file-name "ref.pdf" dir)))
    (with-temp-file f (insert "%PDF-1.4\n%%EOF\n"))
    f))

;;; Pure

(ert-deftest nws-test-normalize-url-and-mirror ()
  (should (equal (noteworthy-workspace--normalize-url "host:8011") "http://host:8011"))
  (should (equal (noteworthy-workspace--normalize-url " https://h.example/ ") "https://h.example/"))
  (should-error (noteworthy-workspace--normalize-url " ") :type 'user-error)
  (let ((noteworthy-workspace-mirror-directory "/m/"))
    (should (equal (noteworthy-workspace--mirror-dir "http://127.0.0.1:8011") "/m/127.0.0.1-8011/"))
    (should (equal (noteworthy-workspace--mirror-dir "https://nw.example") "/m/nw.example/"))))

(ert-deftest nws-test-bridge-argv ()
  (let ((noteworthy-workspace-bridge-command "/definitely/not/here"))
    (should-error (noteworthy-workspace--bridge-argv) :type 'user-error))
  (let ((noteworthy-workspace-bridge-command '("sh" "-c")))
    (should (equal (cdr (noteworthy-workspace--bridge-argv)) '("-c"))))
  (let ((noteworthy-workspace-bridge-command "sh"))
    (should (noteworthy-workspace--bridge-argv))))

(ert-deftest nws-test-token-from-auth-source ()
  (let* ((dir (nws-test--tmp))
         (file (expand-file-name "authinfo" dir))
         (auth-sources (list file))
         (auth-source-cache-expiry nil))
    (unwind-protect
        (progn
          (auth-source-forget-all-cached)
          (with-temp-file file
            (insert "machine nw.example port 8011 login token password s3cret\n"
                    "machine other.example login token password nope\n"))
          (set-file-modes file #o600)
          (should (equal (noteworthy-workspace--lookup-token "http://nw.example:8011") "s3cret"))
          (should-not (noteworthy-workspace--lookup-token "http://nobody.example:8011")))
      (auth-source-forget-all-cached)
      (delete-directory dir t))))

(ert-deftest nws-test-unsynced-regexp ()
  (should (noteworthy-workspace--attach-p nil "content/7/5.typ"))
  (should (noteworthy-workspace--attach-p nil "config/hierarchy.json"))
  (should-not (noteworthy-workspace--attach-p nil "images/a.png"))
  (should-not (noteworthy-workspace--attach-p nil "output.pdf"))
  (should-not (noteworthy-workspace--attach-p nil ".noteworthy-crdt/x.typ"))
  (should-not (noteworthy-workspace--attach-p nil "logs/tinymist.log")))

(ert-deftest nws-test-typst-inputs-scan-matches-script ()
  "The scan of content/ gives what noteworthy.py --print-inputs does."
  (skip-unless (file-exists-p (expand-file-name "noteworthy.py" nws-test--source)))
  (let* ((scan (noteworthy-typst-scan-inputs nws-test--source))
         (script (noteworthy--run-dynamic-inputs nws-test--source))
         (norm (lambda (args)     ; same JSON, whatever the spacing
                 (mapcar (lambda (a)
                           (if (string-match "\\`\\([a-z-]+\\)=\\(.*\\)\\'" a)
                               (cons (match-string 1 a)
                                     (json-parse-string (match-string 2 a)
                                                        :object-type 'alist :array-type 'list))
                             a))
                         args))))
    (should scan)
    (should (equal (funcall norm scan) (funcall norm script)))))

(ert-deftest nws-test-input-flags ()
  (let ((flags (noteworthy-workspace-typst-input-flags nws-test--source)))
    (should (cl-every (lambda (f) (string-prefix-p "--input=" f)) flags))
    (should (= 2 (length flags)))
    (should (string-prefix-p "--input=chapter-folders=[" (car flags)))))

(ert-deftest nws-test-compat-names ()
  (should (eq (indirect-function 'noteworthy-init) (indirect-function 'noteworthy-workspace-open)))
  (should (eq (indirect-function 'noteworthy-quit) (indirect-function 'noteworthy-workspace-quit)))
  (should (featurep 'noteworthy-layout))
  (let ((noteworthy-workspace-terminal-shell nil))
    (setq noteworthy-terminal-shell '("/bin/sh"))
    (should (equal noteworthy-workspace-terminal-shell '("/bin/sh")))
    (setq noteworthy-terminal-shell nil)))

(ert-deftest nws-test-mode-keys ()
  (should (eq (lookup-key noteworthy-workspace-mode-map (kbd "M-t n")) #'noteworthy-new-page))
  (should (eq (lookup-key noteworthy-workspace-mode-map (kbd "M-t r")) #'noteworthy-refresh-preview))
  (should (eq (lookup-key noteworthy-workspace-mode-map (kbd "M-t q")) #'noteworthy-workspace-quit))
  ;; The Typst mode's own keys resolve to the same commands.
  (should (eq (lookup-key noteworthy-typst-mode-map (kbd "M-t n")) #'noteworthy-new-page))
  (should (eq (indirect-function (lookup-key noteworthy-typst-mode-map (kbd "M-t q")))
              (indirect-function #'noteworthy-workspace-quit))))

;;; Local workspace

(ert-deftest nws-test-open-local-roles-editor-lsp ()
  (nws-test--with-project (dir)
    (nws-test--with-stub-lsp
     (let* ((pdf (nws-test--fake-pdf dir))
            (editor (noteworthy-workspace-open dir pdf))
            (roles (nws-test--roles))
            (first (noteworthy-typst-first-page dir)))
       (should (windowp editor))
       (dolist (r '(editor terminal preview pdf)) (should (memq r roles)))
       (when (featurep 'treemacs) (should (memq 'tree roles)))
       ;; The editor shows the first page, not the master file.
       (should first)
       (should (equal (buffer-file-name (window-buffer (emacs-collab-layout-window 'editor)))
                      first))
       (should (equal (buffer-file-name (window-buffer editor)) first))
       ;; Preview pane holds what the preview function returned.
       (should (equal (buffer-name (window-buffer (emacs-collab-layout-window 'preview)))
                      "*nws-test-preview*"))
       ;; PDF pane.
       (should (equal (buffer-file-name (window-buffer (emacs-collab-layout-window 'pdf))) pdf))
       (should (eq noteworthy-pdf-buffer (window-buffer (emacs-collab-layout-window 'pdf))))
       ;; Project variables, as noteworthy-init set them.
       (should (equal noteworthy-project-root dir))
       (should (equal noteworthy-master-file (expand-file-name "templates/core/parser.typ" dir)))
       ;; The language server's root is the project, not a repository above it.
       (should (member (directory-file-name dir) (mapcar #'directory-file-name nws-test--lsp-calls)))
       ;; Keys and session.
       (with-current-buffer (window-buffer editor)
         (should noteworthy-workspace-mode))
       (should (= 1 (length noteworthy-workspace--sessions)))))))

(ert-deftest nws-test-terminal-uses-shell-setting ()
  (nws-test--with-project (dir)
    (let ((noteworthy-workspace-terminal-shell '("/bin/sh")))
      (noteworthy-workspace-open dir)
      (let ((term (emacs-collab-layout-project-terminal (emacs-collab-layout-project dir))))
        (should (buffer-live-p term))
        (should (get-buffer-process term))
        (should (member (car (process-command (get-buffer-process term)))
                        '("/bin/sh" "sh")))))))

(ert-deftest nws-test-open-without-pdf-and-without-preview ()
  (nws-test--with-project (dir)
    (let ((noteworthy-workspace-preview nil))
      (noteworthy-workspace-open dir "")
      (should-not (memq 'pdf (nws-test--roles)))
      (should-not (memq 'preview (nws-test--roles)))
      (should (memq 'editor (nws-test--roles))))))

(ert-deftest nws-test-auto-preview-without-xwidgets ()
  "Without xwidgets `auto' builds no preview pane and does not try."
  (cl-letf (((symbol-function 'noteworthy-xwidget-available-p) (lambda () nil)))
    (let ((noteworthy-workspace-preview 'auto))
      (should-not (noteworthy-workspace--preview-spec))))
  (cl-letf (((symbol-function 'noteworthy-xwidget-available-p) (lambda () t)))
    (let ((noteworthy-workspace-preview 'auto))
      (should (eq (noteworthy-workspace--preview-spec) #'noteworthy-workspace--start-preview)))))

(ert-deftest nws-test-start-preview-from-editor-with-inputs ()
  (nws-test--with-project (dir)
    (let ((noteworthy-workspace-preview #'noteworthy-workspace--start-preview))
      (noteworthy-workspace-open dir)
      (let ((ed (window-buffer (emacs-collab-layout-window 'editor))))
        (should (equal nws-test--started (list ed)))
        (with-current-buffer ed
          (should (equal typst-preview-default-dir dir))
          (should (equal typst-preview--master-file (expand-file-name "templates/core/parser.typ" dir)))
          (should (member "--input" typst-preview-cmd-options))
          (should (cl-some (lambda (o) (string-prefix-p "chapter-folders=" o))
                           typst-preview-cmd-options))))
      ;; Until the xwidget arrives the pane holds the placeholder.
      (should (string-prefix-p "*noteworthy-preview:"
                               (buffer-name (window-buffer (emacs-collab-layout-window 'preview))))))))

(ert-deftest nws-test-xwidget-goes-into-preview-pane ()
  "The advice puts typst-preview's xwidget into the layout's pane and keeps it there."
  (nws-test--with-project (dir)
    (noteworthy-workspace-open dir)
    (let* ((pane (emacs-collab-layout-window 'preview))
           (editor (emacs-collab-layout-window 'editor))
           (n (length (window-list)))
           (fake (lambda (&rest _) (switch-to-buffer (get-buffer-create "*fake-xwidget*")))))
      (select-window editor)
      (noteworthy-xwidget-in-side-window fake)
      (should (= n (length (window-list))))
      (should (equal (buffer-name (window-buffer pane)) "*fake-xwidget*"))
      (should (window-dedicated-p pane))
      (should (eq (selected-window) editor))
      ;; A second one (the preview restarted) replaces it in the same pane.
      (noteworthy-xwidget-in-side-window
       (lambda (&rest _) (switch-to-buffer (get-buffer-create "*fake-xwidget<2>*"))))
      (should (equal (buffer-name (window-buffer pane)) "*fake-xwidget<2>*"))
      (should (= n (length (window-list))))
      ;; Quit kills both.
      (noteworthy-workspace-quit)
      (should-not (get-buffer "*fake-xwidget*"))
      (should-not (get-buffer "*fake-xwidget<2>*")))))

(ert-deftest nws-test-xwidget-advice-inert-without-pane ()
  (let ((called nil))
    (noteworthy-xwidget-in-side-window (lambda (&rest a) (setq called a)) "url")
    (should (equal called '("url")))))

(defun nws-test--answer-new-page (chapter-title page-number title)
  "Stubs for the prompts of `noteworthy-new-page': CHAPTER-TITLE (a string
starting with the chapter number), PAGE-NUMBER, TITLE."
  (list (cons 'completing-read (lambda (_p choices &rest _)
                                 (car (cl-find-if
                                       (lambda (c) (string-prefix-p chapter-title (car c)))
                                       choices))))
        (cons 'read-number (lambda (&rest _) page-number))
        (cons 'read-string (lambda (&rest _) title))))

(ert-deftest nws-test-new-page-updates-hierarchy-and-opens ()
  (nws-test--with-project (dir)
    (noteworthy-workspace-open dir)
    (let* ((hier-file (expand-file-name "config/hierarchy.json" dir))
           (hier0 (with-temp-buffer (insert-file-contents hier-file)
                                    (json-parse-buffer :object-type 'alist :array-type 'list)))
           (pages0 (length (alist-get 'pages (nth 1 hier0)))) ; chapter 8
           (stubs (nws-test--answer-new-page "8 " 9 "Fresh Page")))
      (cl-letf (((symbol-function 'completing-read) (alist-get 'completing-read stubs))
                ((symbol-function 'read-number) (alist-get 'read-number stubs))
                ((symbol-function 'read-string) (alist-get 'read-string stubs)))
        (with-current-buffer (window-buffer (emacs-collab-layout-window 'editor))
          (call-interactively (key-binding (kbd "M-t n")))))
      (let* ((hier (with-temp-buffer (insert-file-contents hier-file)
                                     (json-parse-buffer :object-type 'alist :array-type 'list)))
             (pages (alist-get 'pages (nth 1 hier))))
        (should (= (length pages) (1+ pages0)))
        (should (equal (alist-get 'title (car (last pages))) "Fresh Page")))
      (let ((new (expand-file-name "content/8/9.typ" dir)))
        (should (file-exists-p new))
        (should (equal (buffer-file-name (window-buffer (emacs-collab-layout-window 'editor))) new))
        (should (string-prefix-p "#import" (with-temp-buffer (insert-file-contents new) (buffer-string)))))
      ;; The preview was restarted with the new folders.
      (should nws-test--started)
      (should (cl-some (lambda (o) (string-match-p "\"8\":[ ]*\\[[^]]*\"9\"" o))
                       (with-current-buffer (car nws-test--started) typst-preview-cmd-options))))))

(ert-deftest nws-test-new-chapter ()
  (nws-test--with-project (dir)
    (noteworthy-workspace-open dir)
    (let ((numbers '(30 1)) (strings '("Chapter Thirty" "" "A Page")))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "New chapter..."))
                ((symbol-function 'read-number) (lambda (&rest _) (pop numbers)))
                ((symbol-function 'read-string) (lambda (&rest _) (pop strings))))
        (noteworthy-new-page)))
    (let ((hier (with-temp-buffer
                  (insert-file-contents (expand-file-name "config/hierarchy.json" dir))
                  (json-parse-buffer :object-type 'alist :array-type 'list))))
      (should (equal (alist-get 'title (car (last hier))) "Chapter Thirty"))
      (should (file-exists-p (expand-file-name "content/30/1.typ" dir))))))

(ert-deftest nws-test-refresh-preview-restarts-with-inputs ()
  (nws-test--with-project (dir)
    (noteworthy-workspace-open dir)
    (setq nws-test--started nil)
    (with-current-buffer (window-buffer (emacs-collab-layout-window 'editor))
      (noteworthy-refresh-preview))
    (should (= 1 (length nws-test--started)))
    (with-current-buffer (car nws-test--started)
      (should (cl-some (lambda (o) (string-prefix-p "chapter-folders=" o))
                       typst-preview-cmd-options)))))

(ert-deftest nws-test-quit-leaves-unrelated-buffers ()
  (nws-test--with-project (dir)
    (nws-test--with-stub-lsp
     (let* ((pdf (nws-test--fake-pdf dir))
            (outside (find-file-noselect (expand-file-name "x.txt" (nws-test--tmp))))
            (stopped nil))
       (noteworthy-workspace-open dir pdf)
       (let ((term (emacs-collab-layout-project-terminal (emacs-collab-layout-project dir)))
             (other (find-file-noselect (expand-file-name "README.md" dir)))
             (log (get-buffer-create "*ws-typst-server*")))
         (with-current-buffer unrelated (insert "keep me"))
         (cl-letf (((symbol-function 'noteworthy-pages--stop-preview)
                    (lambda () (setq stopped t))))
           (noteworthy-quit))
         (should stopped)
         (should-not (buffer-live-p term))
         (should-not (buffer-live-p other))
         (should-not (buffer-live-p log))
         (should-not (get-file-buffer (noteworthy-typst-first-page dir)))
         (should (buffer-live-p unrelated))
         (should (equal (with-current-buffer unrelated (buffer-string)) "keep me"))
         (should (buffer-live-p outside))
         (should (= 1 (length (window-list nil 'no-minibuf))))
         (should-not (nws-test--roles))
         (should-not emacs-collab-layout--projects)
         (should-not noteworthy-workspace--sessions)
         (should-not noteworthy-project-root)
         (should-not noteworthy-master-file)
         (should-not noteworthy-pdf-buffer)
         (should-not (memq #'noteworthy-workspace--maybe-enable find-file-hook))
         (kill-buffer outside))))))

(ert-deftest nws-test-quit-without-workspace ()
  (let ((noteworthy-workspace--sessions nil))
    (should-error (noteworthy-quit) :type 'user-error)))

(ert-deftest nws-test-reopen-rebuilds ()
  (nws-test--with-project (dir)
    (noteworthy-workspace-open dir)
    (noteworthy-workspace-open dir)
    (should (= 1 (length noteworthy-workspace--sessions)))
    (should (= 1 (cl-count 'editor (nws-test--roles))))
    (should (equal noteworthy-project-root dir))))

(ert-deftest nws-test-toggle-log ()
  (nws-test--with-project (dir)
    (noteworthy-workspace-open dir)
    (let ((term-win (emacs-collab-layout-window 'terminal))
          (term (emacs-collab-layout-project-terminal (emacs-collab-layout-project dir))))
      (get-buffer-create "*ws-typst-server*")
      (noteworthy-toggle-log)
      (should (equal (buffer-name (window-buffer term-win)) "*ws-typst-server*"))
      (noteworthy-toggle-log)
      (should (eq (window-buffer term-win) term)))))

(provide 'noteworthy-workspace-test)
;;; noteworthy-workspace-test.el ends here
