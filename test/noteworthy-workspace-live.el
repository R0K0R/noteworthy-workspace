;;; noteworthy-workspace-live.el --- Tests against a real Syncworthy server  -*- lexical-binding: t; -*-

;; Needs a running Syncworthy/Noteworthy server on a SCRATCH COPY of a
;; project, and the built syncworthy_bridge:
;;
;;   NWS_LIVE_URL=127.0.0.1:PORT        the server
;;   NWS_LIVE_DIR=/scratch/copy         the directory the server serves
;;   NWS_LIVE_BRIDGE=.../syncworthy_bridge
;;   NWS_LIVE_TMPDIR=/scratch           where mirrors and state go
;;
;; Without them the tests are skipped.  They write to the served project.

(require 'ert)
(require 'cl-lib)
(require 'noteworthy-workspace)

(defun nws-live--env (name) (getenv name))

(defun nws-live--wait (pred &optional timeout)
  (let ((deadline (+ (float-time) (or timeout 20))) r)
    (while (and (not (setq r (funcall pred))) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    r))

(defun nws-live--file-text (file)
  (and (file-exists-p file)
       (with-temp-buffer (insert-file-contents file) (buffer-string))))

(defmacro nws-live--with-connection (conn &rest body)
  "Connect to the live server as CONN, run BODY, and always quit."
  (declare (indent 1))
  `(progn
     (skip-unless (and (nws-live--env "NWS_LIVE_URL") (nws-live--env "NWS_LIVE_DIR")
                       (nws-live--env "NWS_LIVE_BRIDGE")))
     (let* ((tmp (nws-live--env "NWS_LIVE_TMPDIR"))
            (noteworthy-workspace-bridge-command (list (nws-live--env "NWS_LIVE_BRIDGE")))
            (noteworthy-workspace-mirror-directory
             (file-name-as-directory (make-temp-file (expand-file-name "mirror-" tmp) t)))
            (emacs-collab-layout-state-file (expand-file-name "state.eld" tmp))
            (emacs-collab-layout--sizes nil)
            (emacs-collab-layout--sizes-loaded nil)
            (emacs-collab-layout--projects nil)
            (emacs-collab--connections nil)
            (noteworthy-workspace--sessions nil)
            (noteworthy-workspace-preview nil)
            (noteworthy-project-root nil)
            (noteworthy-master-file nil)
            (unrelated (generate-new-buffer "*unrelated*"))
            (served (file-name-as-directory (nws-live--env "NWS_LIVE_DIR")))
            (,conn (noteworthy-workspace-connect (nws-live--env "NWS_LIVE_URL"))))
       (cl-letf (((symbol-function 'typst-preview-start) #'ignore))
         (save-window-excursion
           (unwind-protect
               (progn
                 (should (nws-live--wait (lambda () (emacs-collab-conn-ready ,conn))))
                 (should (nws-live--wait (lambda () (emacs-collab-layout-window 'editor))))
                 ,@body)
             (ignore-errors (noteworthy-workspace-quit))
             (when (memq ,conn emacs-collab--connections) (emacs-collab-disconnect ,conn))
             (kill-buffer unrelated)
             (noteworthy-workspace--uninstall)
             (ignore-errors (delete-directory noteworthy-workspace-mirror-directory t))))))))

(ert-deftest nws-live-connect-edit-quit ()
  (nws-live--with-connection conn
    (let* ((mirror (emacs-collab-conn-root conn))
           (first (noteworthy-typst-first-page mirror)))
      ;; The mirror: the project's files, local.
      (should (file-directory-p (expand-file-name "content" mirror)))
      (should (file-exists-p (expand-file-name "config/hierarchy.json" mirror)))
      (should (file-in-directory-p mirror noteworthy-workspace-mirror-directory))
      ;; Layout on the mirror.
      (let ((roles (delq nil (mapcar (lambda (w) (window-parameter w 'emacs-collab-role))
                                     (window-list nil 'no-minibuf)))))
        (dolist (r '(editor terminal)) (should (memq r roles))))
      (should (equal noteworthy-project-root (file-name-as-directory (file-truename mirror))))
      (should (equal (buffer-file-name (window-buffer (emacs-collab-layout-window 'editor)))
                     first))
      ;; The page is attached and syncs.
      (let ((buf (get-file-buffer first)))
        (should buf)
        (should (nws-live--wait (lambda () (with-current-buffer buf
                                             (and emacs-collab-mode
                                                  (let ((d (emacs-collab--doc)))
                                                    (and d (emacs-collab-doc-synced d))))))))
        (let ((marker (format "nws-live-marker-%d" (random 1000000)))
              (served-file (expand-file-name (file-relative-name first mirror) served)))
          (with-current-buffer buf
            (goto-char (point-max))
            (insert "\n// " marker "\n"))
          (should (nws-live--wait
                   (lambda () (string-match-p marker (or (nws-live--file-text served-file) "")))
                   30))
          ;; Quit asks about unsaved files; the buffer text is already the server's.
          (with-current-buffer buf (save-buffer))))
      ;; Quit: bridge gone, windows reset, unrelated buffers stay.
      (let ((proc (emacs-collab-conn-process conn)))
        (noteworthy-workspace-quit)
        (should (nws-live--wait (lambda () (not (process-live-p proc))) 5))
        (should-not (memq conn emacs-collab--connections))
        (should-not noteworthy-workspace--sessions)
        (should (buffer-live-p unrelated))
        (should (= 1 (length (window-list nil 'no-minibuf))))))))

(ert-deftest nws-live-new-page-reaches-server ()
  (nws-live--with-connection conn
    (let* ((mirror (emacs-collab-conn-root conn))
           (n (cl-loop for k = (+ 900 (random 99))
                       unless (file-exists-p (expand-file-name (format "content/8/%d.typ" k) served))
                       return k))
           (new-served (expand-file-name (format "content/8/%d.typ" n) served))
           (hier-served (expand-file-name "config/hierarchy.json" served)))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_p choices &rest _)
                   (car (cl-find-if (lambda (c) (string-prefix-p "8 " (car c))) choices))))
                ((symbol-function 'read-number) (lambda (&rest _) n))
                ((symbol-function 'read-string) (lambda (&rest _) "Live Page")))
        (with-current-buffer (window-buffer (emacs-collab-layout-window 'editor))
          (noteworthy-new-page)))
      (should (file-exists-p (expand-file-name (format "content/8/%d.typ" n) mirror)))
      (should (nws-live--wait (lambda () (file-exists-p new-served)) 30))
      (should (nws-live--wait
               (lambda () (string-match-p "Live Page" (or (nws-live--file-text hier-served) "")))
               30)))))

(ert-deftest nws-live-bad-bridge-is-a-user-error ()
  (let ((noteworthy-workspace-bridge-command '("/no/such/bridge")))
    (should-error (noteworthy-workspace-connect "127.0.0.1:1") :type 'user-error)
    (should-not noteworthy-workspace--sessions)))

(provide 'noteworthy-workspace-live)
;;; noteworthy-workspace-live.el ends here
