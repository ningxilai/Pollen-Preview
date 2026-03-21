;;; pandoc-preview.el --- Live preview for documents via browser -*- lexical-binding: t; -*-

;; Version: 0.1
;; Package-Requires: ((emacs "28.1") (websocket "1.15") (deno-bridge "0.1"))
;; Keywords: preview, pandoc, pollen, markdown

;;; Commentary:

;; Live preview for multiple document types in external browser.
;; Supports: Pollen, Markdown, Org, reStructuredText, LaTeX, AsciiDoc, Typst.
;;
;; Usage: M-x pandoc-preview-start / pandoc-preview-stop

;;; Code:

(require 'websocket)
(require 'deno-bridge)
(require 'json)
(require 'cl-lib)
(require 'project)

(defgroup pandoc-preview nil
  "Live preview for document files."
  :group 'text
  :prefix "pandoc-preview-")

(defcustom pandoc-preview-browser-command nil
  "Browser executable.  nil = system default.  Examples: \"chromium\", \"firefox\"."
  :type '(choice (const nil) string)
  :group 'pandoc-preview)

(defcustom pandoc-preview-host "127.0.0.1"
  "Server bind address."
  :type 'string
  :group 'pandoc-preview)

(defcustom pandoc-preview-backends
  '(("\\.\\(pm\\|pmd\\|pp\\)\\'" . pollen)
    ("\\.\\(md\\|markdown\\|mkd\\)\\'" . pandoc-markdown)
    ("\\.org\\'" . pandoc-org)
    ("\\.rst\\'" . pandoc-rst)
    ("\\.\\(tex\\|latex\\)\\'" . pandoc-latex)
    ("\\.\\(adoc\\|asciidoc\\)\\'" . pandoc-asciidoc)
    ("\\.typ\\'" . typst))
  "Alist of (REGEXP . BACKEND) mapping file extensions to renderers."
  :type '(alist :key-type string :value-type symbol)
  :group 'pandoc-preview)

(defvar pandoc-preview--ts-path nil)

(defvar pandoc-preview--port nil)
(defvar pandoc-preview--root nil)
(defvar pandoc-preview--pending nil)
(defvar pandoc-preview--deno-port nil)
(defvar pandoc-preview--emacs-port nil)
(defvar pandoc-preview--emacs-server nil)
(defvar pandoc-preview--deno-process nil)
(defvar pandoc-preview--active-buffers nil)

(defvar-local pandoc-preview--active nil)
(defvar-local pandoc-preview--syncing nil)
(defvar-local pandoc-preview--sync-timer nil)

(defun pandoc-preview--ts ()
  (or pandoc-preview--ts-path
      (expand-file-name "pandoc-preview.ts"
                        (or (and load-file-name (file-name-directory load-file-name))
                            (and (locate-library "pandoc-preview")
                                 (file-name-directory (locate-library "pandoc-preview")))
                            (and buffer-file-name (file-name-directory buffer-file-name))))))

(defun pandoc-preview--supported-file-p (&optional buf)
  "Non-nil if BUF (default current) visits a supported file."
  (let ((f (buffer-file-name buf)))
    (and f (cl-loop for (regexp . _) in pandoc-preview-backends
                    thereis (string-match-p regexp f)))))

(defun pandoc-preview--detect-backend ()
  "Detect backend from current buffer's file extension."
  (when-let* ((file buffer-file-name))
    (cl-loop for (regexp . backend) in pandoc-preview-backends
             when (string-match-p regexp file)
             return backend)))

(defun pandoc-preview--root ()
  "Project root via `project-current', fallback to file's directory."
  (or (when-let* ((proj (project-current)))
        (project-root proj))
      (and buffer-file-name (file-name-directory buffer-file-name))))

(defun pandoc-preview--deno-send (msg)
  "Send MSG to Deno.  Errors silently ignored."
  (when pandoc-preview--deno-port
    (condition-case nil
        (let ((ws (websocket-open (format "ws://127.0.0.1:%s" pandoc-preview--deno-port))))
          (websocket-send-text ws (json-encode msg))
          (run-at-time 0.2 nil (lambda (s) (ignore-errors (websocket-close s))) ws))
      (error nil))))

(defun pandoc-preview--open-browser (url)
  (cond
   (pandoc-preview-browser-command
    (start-process "pandoc-browser" nil pandoc-preview-browser-command url))
   ((fboundp 'browse-url-default-browser)
    (browse-url-default-browser url))
   (t (browse-url url))))

(defun pandoc-preview--sync (&rest _)
  (when (and pandoc-preview--active
             (not pandoc-preview--syncing)
             (pandoc-preview--supported-file-p))
    (when pandoc-preview--sync-timer
      (cancel-timer pandoc-preview--sync-timer))
    (setq pandoc-preview--sync-timer
          (run-at-time 0.15 nil
                       (lambda (buf)
                         (when (buffer-live-p buf)
                           (with-current-buffer buf
                             (when pandoc-preview--active
                               (setq pandoc-preview--syncing t)
                               (pandoc-preview--deno-send
                                (list "data" (list "sync"
                                                   (expand-file-name buffer-file-name)
                                                   (buffer-substring-no-properties (point-min) (point-max)))))
                               (setq pandoc-preview--syncing nil)))))
                       (current-buffer)))))

(defun pandoc-preview--buffer-killed ()
  (when pandoc-preview--active
    (when pandoc-preview--sync-timer
      (cancel-timer pandoc-preview--sync-timer))
    (setq pandoc-preview--active nil)
    (setq pandoc-preview--active-buffers (delq (current-buffer) pandoc-preview--active-buffers))
    (remove-hook 'after-change-functions #'pandoc-preview--sync t)
    (remove-hook 'kill-buffer-hook #'pandoc-preview--buffer-killed t)))

(defun pandoc-preview--server-ready (port)
  (setq pandoc-preview--port port)
  (pandoc-preview--open-browser (format "http://%s:%s/" pandoc-preview-host port)))

;;;###autoload
(defun pandoc-preview-start ()
  "Start real-time preview for current buffer."
  (interactive)
  (let ((backend (or (pandoc-preview--detect-backend)
                     (user-error "No backend for this file type"))))
    (when pandoc-preview--active
      (user-error "Already previewing"))
    (let ((root (pandoc-preview--root)))
      (unless root (user-error "No project root"))
      (setq pandoc-preview--root (expand-file-name root))
      (let* ((ts (pandoc-preview--ts))
             (deno-port (+ 10000 (random 50000)))
             (emacs-port (+ 10000 (random 50000)))
             (process-buffer " *pandoc-preview-deno*"))

      (setq pandoc-preview--deno-port deno-port)
      (setq pandoc-preview--emacs-port emacs-port)

      (setq pandoc-preview--emacs-server
            (websocket-server
             emacs-port
             :host 'local
             :on-message
             (lambda (_ws frame)
               (when (eq (websocket-frame-opcode frame) 'text)
                 (condition-case nil
                     (let* ((info (json-parse-string (websocket-frame-text frame)))
                            (info-type (gethash "type" info)))
                       (pcase info-type
                         ("eval-code" (eval (read (gethash "content" info nil))))
                         ("show-message" (message "%s" (gethash "content" info nil)))))
                   (error nil))))
             :on-open
              (lambda (_ws)
                (when pandoc-preview--pending
                  (let ((data pandoc-preview--pending))
                    (setq pandoc-preview--pending nil)
                    (pandoc-preview--deno-send
                     (list "data" (list "start"
                                        (plist-get data :root)
                                        (expand-file-name (plist-get data :file))
                                        (symbol-name (plist-get data :backend)))))
                    (pandoc-preview--sync))))
             :on-close (lambda (_ws) (message "[pandoc-preview] Deno disconnected"))))

      (setq pandoc-preview--deno-process
            (let ((process-environment (cons "NO_COLOR=true" process-environment)))
              (start-process "pandoc-preview-deno" process-buffer
                             "deno" "run" "--allow-all" ts
                             "pandoc-preview" (format "%s" deno-port) (format "%s" emacs-port))))

      (set-process-sentinel pandoc-preview--deno-process
                              (lambda (_proc event)
                               (message "[pandoc-preview] Deno: %s" (string-trim event))))

      (setq pandoc-preview--pending
            (list :root pandoc-preview--root :file (buffer-file-name) :backend backend))
      (setq pandoc-preview--active t)
      (add-hook 'after-change-functions #'pandoc-preview--sync nil t)
      (add-hook 'kill-buffer-hook #'pandoc-preview--buffer-killed nil t)
      (push (current-buffer) pandoc-preview--active-buffers)
      (message "[pandoc-preview] Started [%s]" backend)))))

;;;###autoload
(defun pandoc-preview-stop ()
  "Stop preview for current buffer."
  (interactive)
  (when pandoc-preview--sync-timer
    (cancel-timer pandoc-preview--sync-timer)
    (setq pandoc-preview--sync-timer nil))
  (remove-hook 'after-change-functions #'pandoc-preview--sync t)
  (remove-hook 'kill-buffer-hook #'pandoc-preview--buffer-killed t)
  (setq pandoc-preview--active nil)
  (setq pandoc-preview--active-buffers (delq (current-buffer) pandoc-preview--active-buffers))
  (when (and (null pandoc-preview--active-buffers) pandoc-preview--deno-process)
    (ignore-errors (delete-process pandoc-preview--deno-process))
    (let ((buf (get-buffer " *pandoc-preview-deno*")))
      (when buf (kill-buffer buf)))
    (when pandoc-preview--emacs-server
      (websocket-server-close pandoc-preview--emacs-server)
      (setq pandoc-preview--emacs-server nil))
    (setq pandoc-preview--deno-process nil)
    (setq pandoc-preview--port nil))
  (message "[pandoc-preview] Stopped"))

;;;###autoload
(defun pandoc-preview-open ()
  "Open browser to preview URL."
  (interactive)
  (if pandoc-preview--port
      (pandoc-preview--open-browser
       (format "http://%s:%s/" pandoc-preview-host pandoc-preview--port))
    (message "[pandoc-preview] Not started")))

;;;###autoload
(defun pandoc-preview-stop-all ()
  "Stop all previews."
  (interactive)
  (dolist (buf pandoc-preview--active-buffers)
    (when (buffer-live-p buf)
      (with-current-buffer buf (pandoc-preview-stop)))))

(defvar pandoc-preview-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-o") #'pandoc-preview-open)
    map))

;;;###autoload
(define-minor-mode pandoc-preview-mode
  "Toggle live preview for current buffer."
  :lighter " pandoc"
  :keymap pandoc-preview-mode-map
  (if pandoc-preview-mode (pandoc-preview-start) (pandoc-preview-stop)))

(provide 'pandoc-preview)
;;; pandoc-preview.el ends here
