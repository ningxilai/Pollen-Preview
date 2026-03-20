;;; pollen-preview.el --- Live preview for Pollen via browser -*- lexical-binding: t; -*-

;; Author: Mimo V2 Pro Free
;; Version: 0.3
;; Package-Requires: ((emacs "28.1") (websocket "1.15"))
;; Keywords: pollen, preview

;;; Commentary:

;; Real-time Pollen preview in external browser.
;; Direct WebSocket communication (no deno-bridge dependency).
;;
;; Usage: M-x pollen-preview-start / pollen-preview-stop

;;; Code:

(require 'websocket)
(require 'json)

(defgroup pollen-preview nil
  "Live preview for Pollen files."
  :group 'pollen
  :prefix "pollen-preview-")

(defcustom pollen-preview-browser-command nil
  "Browser executable.  nil = system default.  Examples: \"chromium\", \"firefox\"."
  :type '(choice (const nil) string)
  :group 'pollen-preview)

(defcustom pollen-preview-host "127.0.0.1"
  "Server bind address."
  :type 'string
  :group 'pollen-preview)

(defvar pollen-preview--ts-path nil)
(defvar pollen-preview--port nil)
(defvar pollen-preview--root nil)
(defvar pollen-preview--pending nil)

(defvar-local pollen-preview--active nil)
(defvar-local pollen-preview--syncing nil)
(defvar-local pollen-preview--emacs-port nil)
(defvar-local pollen-preview--deno-port nil)

(defvar pollen-preview--active-buffers nil)
(defvar pollen-preview--emacs-server nil)
(defvar pollen-preview--deno-socket nil)
(defvar pollen-preview--deno-process nil)

(defun pollen-preview--ts ()
  (or pollen-preview--ts-path
      (setq pollen-preview--ts-path
            (expand-file-name "pollen-preview.ts"
                              (file-name-directory
                               (or (and load-file-name (file-name-directory load-file-name))
                                   (locate-library "pollen-preview")
                                   buffer-file-name))))))

(defun pollen-preview--pollen-file-p (&optional buf)
  (let ((f (buffer-file-name buf)))
    (and f (string-match-p "\\.\\(pm\\|pmd\\|pp\\)\\'" f))))

(defun pollen-preview--root ()
  (let ((dir (and buffer-file-name (file-name-directory buffer-file-name))))
    (locate-dominating-file
     dir (lambda (d)
           (or (file-exists-p (expand-file-name "pollen.rkt" d))
               (file-directory-p (expand-file-name ".git" d)))))))

(defun pollen-preview--deno-send (msg)
  "Send MSG to Deno.  Errors silently ignored."
  (when pollen-preview--deno-port
    (condition-case nil
        (let ((ws (websocket-open (format "ws://127.0.0.1:%s" pollen-preview--deno-port))))
          (websocket-send-text ws (json-encode msg))
          (run-at-time 0.2 nil (lambda (s) (ignore-errors (websocket-close s))) ws))
      (error nil))))

(defun pollen-preview--open-browser (url)
  (cond
   (pollen-preview-browser-command
    (start-process "pollen-browser" nil pollen-preview-browser-command url))
   ((fboundp 'browse-url-default-browser)
    (browse-url-default-browser url))
   (t (browse-url url))))

(defvar-local pollen-preview--sync-timer nil)

(defun pollen-preview--sync (&rest _)
  (when (and pollen-preview--active
             (not pollen-preview--syncing)
             (pollen-preview--pollen-file-p))
    (when pollen-preview--sync-timer
      (cancel-timer pollen-preview--sync-timer))
    (setq pollen-preview--sync-timer
          (run-at-time 0.15 nil
                       (lambda (buf)
                         (when (buffer-live-p buf)
                           (with-current-buffer buf
                             (when pollen-preview--active
                               (setq pollen-preview--syncing t)
                               (pollen-preview--deno-send
                                (list "data" (list "sync"
                                                   (expand-file-name buffer-file-name)
                                                   (buffer-substring-no-properties (point-min) (point-max)))))
                               (setq pollen-preview--syncing nil)))))
                       (current-buffer)))))

(defun pollen-preview--buffer-killed ()
  (when pollen-preview--active
    (when pollen-preview--sync-timer
      (cancel-timer pollen-preview--sync-timer))
    (setq pollen-preview--active nil)
    (setq pollen-preview--active-buffers (delq (current-buffer) pollen-preview--active-buffers))
    (remove-hook 'after-change-functions #'pollen-preview--sync t)
    (remove-hook 'kill-buffer-hook #'pollen-preview--buffer-killed t)))

(defun pollen-preview--server-ready (port)
  (setq pollen-preview--port port)
  (pollen-preview--open-browser (format "http://%s:%s/" pollen-preview-host port))
  (message "[pollen-preview] http://%s:%s/" pollen-preview-host port))

;;;###autoload
(defun pollen-preview-start ()
  "Start real-time Pollen preview for current buffer."
  (interactive)
  (unless (pollen-preview--pollen-file-p)
    (user-error "Not a Pollen file"))
  (when pollen-preview--active
    (user-error "Already previewing"))
  (let ((root (pollen-preview--root)))
    (unless root (user-error "No project root (pollen.rkt or .git not found)"))
    (setq pollen-preview--root (expand-file-name root))
    (let* ((ts (pollen-preview--ts))
           (deno-port (+ 10000 (random 50000)))
           (emacs-port (+ 10000 (random 50000)))
           (process-buffer " *pollen-preview-deno*"))

      (setq pollen-preview--deno-port deno-port)
      (setq pollen-preview--emacs-port emacs-port)

      ;; Emacs WebSocket server (Deno → Emacs)
      (setq pollen-preview--emacs-server
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
               (when pollen-preview--pending
                 (let ((data pollen-preview--pending))
                   (setq pollen-preview--pending nil)
                   (pollen-preview--deno-send
                    (list "data" (list "start"
                                       (plist-get data :root)
                                       (expand-file-name (plist-get data :file)))))
                   (pollen-preview--sync))))
             :on-close (lambda (_ws) (message "[pollen-preview] Deno disconnected"))))

      ;; Start Deno process
      (setq pollen-preview--deno-process
            (let ((process-environment (cons "NO_COLOR=true" process-environment)))
              (start-process "pollen-preview-deno" process-buffer
                             "deno" "run" "--allow-all" ts
                             "pollen-preview" (format "%s" deno-port) (format "%s" emacs-port))))

      (set-process-sentinel pollen-preview--deno-process
                            (lambda (proc event)
                              (message "[pollen-preview] Deno: %s" (string-trim event))))

      (setq pollen-preview--pending
            (list :root pollen-preview--root :file (buffer-file-name)))
      (setq pollen-preview--active t)
      (add-hook 'after-change-functions #'pollen-preview--sync nil t)
      (add-hook 'kill-buffer-hook #'pollen-preview--buffer-killed nil t)
      (push (current-buffer) pollen-preview--active-buffers)
      (message "[pollen-preview] Started"))))

;;;###autoload
(defun pollen-preview-stop ()
  "Stop preview for current buffer."
  (interactive)
  (when pollen-preview--sync-timer
    (cancel-timer pollen-preview--sync-timer)
    (setq pollen-preview--sync-timer nil))
  (remove-hook 'after-change-functions #'pollen-preview--sync t)
  (remove-hook 'kill-buffer-hook #'pollen-preview--buffer-killed t)
  (setq pollen-preview--active nil)
  (setq pollen-preview--active-buffers (delq (current-buffer) pollen-preview--active-buffers))
  (when (and (null pollen-preview--active-buffers) pollen-preview--deno-process)
    (ignore-errors (delete-process pollen-preview--deno-process))
    (let ((buf (get-buffer " *pollen-preview-deno*")))
      (when buf (kill-buffer buf)))
    (when pollen-preview--emacs-server
      (websocket-server-close pollen-preview--emacs-server)
      (setq pollen-preview--emacs-server nil))
    (setq pollen-preview--deno-process nil)
    (setq pollen-preview--port nil))
  (message "[pollen-preview] Stopped"))

;;;###autoload
(defun pollen-preview-open ()
  "Open browser to preview URL."
  (interactive)
  (if pollen-preview--port
      (pollen-preview--open-browser
       (format "http://%s:%s/" pollen-preview-host pollen-preview--port))
    (message "[pollen-preview] Not started")))

;;;###autoload
(defun pollen-preview-stop-all ()
  "Stop all previews."
  (interactive)
  (dolist (buf pollen-preview--active-buffers)
    (when (buffer-live-p buf)
      (with-current-buffer buf (pollen-preview-stop)))))

(defvar pollen-preview-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-o") #'pollen-preview-open)
    map))

;;;###autoload
(define-minor-mode pollen-preview-mode
  "Toggle Pollen preview for current buffer."
  :lighter " ◊prev"
  :keymap pollen-preview-mode-map
  (if pollen-preview-mode (pollen-preview-start) (pollen-preview-stop)))

(provide 'pollen-preview)
;;; pollen-preview.el ends here
