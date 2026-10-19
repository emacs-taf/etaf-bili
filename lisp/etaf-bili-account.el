;;; etaf-bili-account.el --- Bilibili sign-in, sign-out and status -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Signing in stays inside Emacs and looks like the site: one centered modal
;; with two tabs.  "扫码登录" paints the code and waits for the phone;
;; "手机号登录" asks for the number and the SMS code and submits them through
;; the bundled backend.  Bilibili puts a graphical captcha in front of the SMS
;; endpoint, so when the site refuses, the modal shows the site's own message
;; instead of pretending the code was sent -- the QR tab has no such gate.
;;
;; The backend is `backends/bili/bili.mjs' in this repository: Node.js only, no
;; external skill, and it reads and writes the same `cookies.txt' curl uses, so
;; one sign-in covers every later request.
;;
;; Only `etaf-bili-login', `etaf-bili-logout' and `etaf-bili-account' are public.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'etaf)
(require 'etaf-bili-theme)

(defcustom etaf-bili-node-program "node"
  "Node.js executable that runs the bundled account backend."
  :type 'string
  :group 'etaf-bili)

(defcustom etaf-bili-backend-directory
  (expand-file-name "backends/bili"
                    (file-name-directory (or (locate-library "etaf-bili")
                                             load-file-name
                                             buffer-file-name)))
  "Directory holding this package's bundled Bilibili backend."
  :type 'directory
  :group 'etaf-bili)

(defcustom etaf-bili-backend-command nil
  "Command prefix that runs the account backend, or nil for the bundled one."
  :type '(repeat string)
  :group 'etaf-bili)

(defcustom etaf-bili-login-timeout 180
  "Seconds `etaf-bili-login' waits for the phone to confirm the code."
  :type 'number
  :group 'etaf-bili)

(defcustom etaf-bili-login-poll-interval 2
  "Seconds between two sign-in polls."
  :type 'number
  :group 'etaf-bili)

(defconst etaf-bili-login-buffer-name "*B站登录*")

(defvar etaf-bili--session)                  ; buffer-local, defined in etaf-bili-app
(declare-function etaf-bili-reload "etaf-bili-model" (session))

(defvar etaf-bili-account--process nil
  "Backend process currently answering an account request.")

(defvar-local etaf-bili-login--state nil
  "Sign-in modal state: :tab, :qr, :status, :phone, :code and :busy.")

(defvar etaf-bili-login--deadline nil
  "Time after which the QR poll stops.")

(defvar-local etaf-bili-login--key nil
  "Key of the QR code currently shown, when the tab is `qr'.")

;;; Backend transport

(defun etaf-bili--backend-command ()
  "Return the command prefix that runs the account backend."
  (or etaf-bili-backend-command
      (list etaf-bili-node-program
            (expand-file-name "bili.mjs" etaf-bili-backend-directory))))

(defun etaf-bili--backend-settle (output errors callback)
  "Drain OUTPUT and ERRORS, then deliver the parsed backend reply to CALLBACK."
  (when-let* ((pipe (get-buffer-process errors)))
    (set-process-sentinel pipe #'ignore)
    (while (accept-process-output pipe 0)))
  (let* ((text (with-current-buffer output
                 (string-trim (buffer-substring-no-properties (point-min) (point-max)))))
         (failure (with-current-buffer errors
                    (string-trim (buffer-substring-no-properties (point-min) (point-max)))))
         (reply (condition-case nil
                    (json-parse-string text :object-type 'plist :array-type 'list
                                       :null-object nil :false-object nil)
                  (error nil))))
    (when (buffer-live-p output) (kill-buffer output))
    (when (buffer-live-p errors) (kill-buffer errors))
    (funcall callback
             (or reply
                 (list :ok nil :error "internal"
                       :message (if (string-empty-p failure)
                                    "Bilibili 后端没有返回结果"
                                  failure))))))

(defun etaf-bili--backend (args callback)
  "Run ARGS through the account backend and deliver CALLBACK a parsed plist."
  (let ((output (generate-new-buffer " *bili-backend*"))
        (errors (generate-new-buffer " *bili-backend-errors*")))
    (condition-case problem
        (setq etaf-bili-account--process
              (make-process
               :name "etaf-bili-backend" :buffer output :stderr errors
               :coding '(utf-8-unix . utf-8-unix) :noquery t
               :command (append (etaf-bili--backend-command) args)
               :sentinel (lambda (process _event)
                           (when (memq (process-status process) '(exit signal))
                             (while (accept-process-output process 0))
                             (setq etaf-bili-account--process nil)
                             (etaf-bili--backend-settle output errors callback)))))
      (error
       (kill-buffer output)
       (kill-buffer errors)
       (funcall callback (list :ok nil :error "internal"
                               :message (error-message-string problem)))))
    etaf-bili-account--process))

(defun etaf-bili--refresh-open-sessions ()
  "Reload every mounted Bilibili session so new permissions apply."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (bound-and-true-p etaf-bili--session) (buffer-live-p buffer))
        (condition-case nil
            (etaf-bili-reload etaf-bili--session)
          (error nil))))))

;;; Painting

(defun etaf-bili--qr (rows size)
  "Return ROWS painted as a scannable code with a quiet zone.
Two module rows share one text row through half blocks, so the code stays
square in the terminal's 1:2 cell."
  (let* ((quiet 4)
         (width (+ size (* 2 quiet)))
         (black "#000000")
         (white "#ffffff")
         (module (lambda (x y)
                   (and (>= x 0) (< x size) (>= y 0) (< y size)
                        (eq ?1 (aref (nth y rows) x)))))
         (lines nil))
    (dotimes (half (ceiling width 2))
      (let ((line ""))
        (dotimes (column width)
          (let* ((x (- column quiet))
                 (top (funcall module x (- (* 2 half) quiet)))
                 (bottom (funcall module x (- (1+ (* 2 half)) quiet)))
                 (glyph (cond ((and top bottom) "█") (top "▀") (bottom "▄") (t " "))))
            (setq line (concat line
                               (propertize glyph 'face (list :background white
                                                             :foreground black))))))
        (push line lines)))
    (mapconcat #'identity (nreverse lines) "\n")))

;;; Modal

(defun etaf-bili--login-state (key value)
  "Return the login buffer's state with KEY set to VALUE."
  (when-let* ((buffer (get-buffer etaf-bili-login-buffer-name)))
    (with-current-buffer buffer
      (setq etaf-bili-login--state (plist-put etaf-bili-login--state key value)))))

(defun etaf-bili--login-field (label value placeholder on-press)
  "Return one editable row labelled LABEL with VALUE and PLACEHOLDER."
  (etaf-node
   'column
   (list :width 'stretch :item-gap '(lh 0))
   (list (etaf-node 'text (list :color (etaf-bili-color :muted) :font-size 12)
                    (list label))
         (etaf-node
          'box
          (list :role 'button :tab-index 0 :pointer 'hand
                :height '(lh 2) :width 'stretch :padding-inline '(ch 1)
                :background-color (etaf-bili-color :surface)
                :border (list '(px 1) 'solid (etaf-bili-color :line))
                :on-press on-press)
          (list (etaf-node 'text
                           (list :color (if (string-empty-p value)
                                            (etaf-bili-color :muted)
                                          (etaf-bili-color :ink)))
                           (list (if (string-empty-p value) placeholder value))))))))

(defun etaf-bili--login-body (state on-tab on-close on-send-sms on-submit
                                    on-edit-phone on-edit-code)
  "Return the sign-in panel for STATE and its callbacks."
  (let ((tab (or (plist-get state :tab) "qr"))
        (qr (or (plist-get state :qr) ""))
        (status (or (plist-get state :status) ""))
        (phone (or (plist-get state :phone) ""))
        (code (or (plist-get state :code) ""))
        (busy (plist-get state :busy)))
    (etaf-view
     (flex :width '(vw 100) :height '(vh 100)
           :align-items 'center :justify-content 'center
           :background-color (etaf-bili-color :bg)
       (etaf-dialog :open t :title "登录哔哩哔哩"
                    :width '(ch 66)
                    :close-label "取消" :on-close on-close
                    :keys (list (list "q" on-close "取消"))
         (flex :flex-direction 'column :width 'stretch :align-items 'center
               :padding '((lh 0) (ch 2)) :gap '((lh 1) (ch 0))
           (flex :width 'stretch :justify-content 'center :gap '((lh 0) (ch 2))
             (etaf-button :label "扫码登录" :ref 'bili-login-tab-qr
                          :variant (if (equal tab "qr") 'primary 'ghost)
                          :on-press (lambda () (funcall on-tab "qr")))
             (etaf-button :label "手机号登录" :ref 'bili-login-tab-phone
                          :variant (if (equal tab "phone") 'primary 'ghost)
                          :on-press (lambda () (funcall on-tab "phone"))))
           (flex :if (equal tab "qr") :flex-direction 'column :width 'stretch
                 :align-items 'center :gap '((lh 0) (ch 0))
             (text (expr qr)))
           (flex :if (equal tab "phone") :flex-direction 'column :width 'stretch
                 :gap '((lh 1) (ch 0))
             (expr (etaf-bili--login-field
                    "手机号（含区号，例如 +86 138…）" phone "+86" on-edit-phone))
             (flex :width 'stretch :align-items 'end :gap '((lh 0) (ch 1))
               (expr (etaf-bili--login-field
                      "短信验证码" code "6 位验证码" on-edit-code))
               (etaf-button :label (if busy "发送中…" "发送验证码")
                            :ref 'bili-login-send :variant 'secondary
                            :disabled (or busy (string-empty-p phone))
                            :on-press on-send-sms))
             (etaf-button :label (if busy "登录中…" "登录") :ref 'bili-login-submit
                          :variant 'primary :width 'stretch
                          :disabled (or busy (string-empty-p phone)
                                        (string-empty-p code))
                          :on-press on-submit)
             (box :height '(lh 1) :color (etaf-bili-color :muted)
               (text "B 站可能要求图形验证码；被拦时请改用扫码登录。")))
           (box :height '(lh 1) :color (etaf-bili-color :muted)
             (text (expr status)))))))))

(etaf-define-component etaf-bili--login-dialog
    (&key state on-tab on-close on-send-sms on-submit on-edit-phone on-edit-code)
  "Render the sign-in modal: a centered panel with a QR tab and a phone tab."
  :setup (etaf-theme-provide (etaf-bili-theme-defaults etaf-bili-theme-mode))
  :view
  (expr (etaf-bili--login-body state on-tab on-close on-send-sms on-submit
                               on-edit-phone on-edit-code)))

(defun etaf-bili--login-render ()
  "Mount the login modal in its buffer from the current state."
  (when-let* ((buffer (get-buffer etaf-bili-login-buffer-name)))
    (with-current-buffer buffer
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (condition-case nil (etaf-unmount runtime) (error nil)))
      (etaf-mount buffer
                  (etaf-view
                   (etaf-bili--login-dialog
                    :state etaf-bili-login--state
                   :on-tab #'etaf-bili--login-tab
                   :on-close #'etaf-bili--login-cancel
                   :on-send-sms #'etaf-bili--login-send-sms
                   :on-submit #'etaf-bili--login-submit
                   :on-edit-phone #'etaf-bili--login-edit-phone
                    :on-edit-code #'etaf-bili--login-edit-code)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-runtime-flush runtime))
      (face-remap-set-base 'default (list :background (etaf-bili-color :bg)
                                          :foreground (etaf-bili-color :ink))))))

(defun etaf-bili--login-show-key (key rows size)
  "Show the QR tab for KEY and remember the painted code."
  (setq etaf-bili-login--key key)
  (etaf-bili--login-state :qr (etaf-bili--qr rows size))
  (unless (equal "phone" (plist-get etaf-bili-login--state :tab))
    (etaf-bili--login-state :tab "qr")
    (etaf-bili--login-state :status "等待扫码…"))
  (etaf-bili--login-render))

(defun etaf-bili--login-tab (tab)
  "Switch the modal to TAB."
  (unless (equal tab (plist-get etaf-bili-login--state :tab))
    (etaf-bili--login-state :tab tab)
    (etaf-bili--login-state :status
                            (if (equal tab "qr") "等待扫码…" "输入手机号获取验证码"))
    (etaf-bili--login-render)))

(defun etaf-bili--login-status (text)
  "Replace the modal's status line with TEXT."
  (etaf-bili--login-state :status text)
  (etaf-bili--login-render))

(defun etaf-bili--login-edit-phone ()
  "Read the phone number for the SMS sign-in."

  (when-let* ((value (etaf-call-with-input
                      (lambda () (read-string "手机号（含区号）："
                                              (or (plist-get etaf-bili-login--state :phone) "+86 "))))))
    (etaf-bili--login-state :phone (string-trim value))
    (etaf-bili--login-render)))

(defun etaf-bili--login-edit-code ()
  "Read the SMS code for the phone sign-in."

  (when-let* ((value (etaf-call-with-input (lambda () (read-string "短信验证码：")))))
    (etaf-bili--login-state :code (string-trim value))
    (etaf-bili--login-render)))

(defun etaf-bili--login-send-sms ()
  "Ask the backend to send the SMS code to the recorded phone number."

  (let ((phone (plist-get etaf-bili-login--state :phone)))
    (if (string-empty-p phone)
        (message "先填写手机号")
      (etaf-bili--login-state :busy t)
      (etaf-bili--login-status "正在发送验证码…")
      (etaf-bili--backend
       (list "sms-send" phone)
       (lambda (reply)
         (etaf-bili--login-state :busy nil)
         (etaf-bili--login-status
          (if (plist-get reply :ok)
              (or (plist-get reply :message) "验证码已发送")
            (format "%s（%s）" (or (plist-get reply :message) "发送失败")
                    "B 站要求图形验证码时请改用扫码登录")))
         (etaf-bili--login-render))))))

(defun etaf-bili--login-submit ()
  "Submit the phone number and SMS code to the backend."

  (let ((phone (plist-get etaf-bili-login--state :phone))
        (code (plist-get etaf-bili-login--state :code)))
    (if (or (string-empty-p phone) (string-empty-p code))
        (message "手机号和验证码都要填写")
      (etaf-bili--login-state :busy t)
      (etaf-bili--login-status "正在登录…")
      (etaf-bili--backend
       (list "sms-login" phone code)
       (lambda (reply)
         (etaf-bili--login-state :busy nil)
         (if (and (plist-get reply :ok) (plist-get reply :signed_in))
             (progn
               (etaf-bili--login-close)
               (message "已登录哔哩哔哩：%s" (or (plist-get reply :name) "当前账号"))
               (etaf-bili--refresh-open-sessions))
           (etaf-bili--login-status
            (or (plist-get reply :message) "登录失败，请改用扫码登录"))
           (etaf-bili--login-render)))))))

(defun etaf-bili--login-close ()
  "Unmount and kill the sign-in modal buffer."
  (setq etaf-bili-login--deadline nil)
  (when-let* ((buffer (get-buffer etaf-bili-login-buffer-name)))
    (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
      (condition-case nil (etaf-unmount runtime) (error nil)))
    (kill-buffer buffer)))

(defun etaf-bili--login-cancel ()
  "Stop waiting for the sign-in and close the modal."

  (etaf-bili--login-close)
  (message "已取消登录"))

;;; QR polling

(defun etaf-bili--login-poll (key deadline)
  "Poll the QR sign-in KEY until DEADLINE, then report the result."
  (cond
   ((or (null etaf-bili-login--deadline) (> (float-time) deadline))
    (etaf-bili--login-status "二维码已超时，请重新登录")
    (setq etaf-bili-login--deadline nil))
   (t
    (etaf-bili--backend
     (list "login-poll" key)
     (lambda (reply)
       (cond
        ((not (plist-get reply :ok))
         (etaf-bili--login-status (or (plist-get reply :message) "登录查询失败")))
        ((equal "signed-in" (plist-get reply :state))
         (setq etaf-bili-login--deadline nil)
         (etaf-bili--login-close)
         (message "已登录哔哩哔哩：%s" (or (plist-get reply :name) "当前账号"))
         (etaf-bili--refresh-open-sessions))
        ((equal "expired" (plist-get reply :state))
         (setq etaf-bili-login--deadline nil)
         (etaf-bili--login-status "二维码已过期，请重新登录"))
        (t
         ;; The phone tab owns the status line while it is showing.
         (when (equal "qr" (plist-get etaf-bili-login--state :tab))
           (etaf-bili--login-status (if (equal "scanned" (plist-get reply :state))
                                        "已扫码，请在手机上确认"
                                      "等待扫码…")))
         (run-at-time etaf-bili-login-poll-interval nil
                      #'etaf-bili--login-poll key deadline))))))))

;;; Public commands

;;;###autoload
(defun etaf-bili-login ()
  "Sign in to Bilibili from a centered modal with two tabs.
扫码登录 paints a QR code here; 手机号登录 asks for the number and the SMS
code.  The bundled backend updates the cookie jar every request uses."
  (interactive)
  (let ((buffer (get-buffer-create etaf-bili-login-buffer-name)))
    (switch-to-buffer buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq-local etaf-bili-login--state
                    (list :tab "qr" :status "正在获取二维码…" :busy nil
                          :phone "+86 " :code ""))
        (setq-local mode-line-format nil header-line-format nil
                    cursor-type nil)
        (etaf-bili--login-render))))
  (etaf-bili--backend
   (list "login-start")
   (lambda (reply)
     (if (or (not (plist-get reply :ok)) (null (plist-get reply :rows)))
         (etaf-bili--login-status (or (plist-get reply :message) "无法获取二维码"))
       (let ((deadline (+ (float-time) etaf-bili-login-timeout)))
         (setq etaf-bili-login--deadline deadline)
         (etaf-bili--login-show-key (plist-get reply :key)
                                    (plist-get reply :rows)
                                    (plist-get reply :size))
         (run-at-time etaf-bili-login-poll-interval nil
                      #'etaf-bili--login-poll (plist-get reply :key) deadline)))))
  nil)

;;;###autoload
(defun etaf-bili-logout ()
  "Sign out of Bilibili and drop the stored cookies."
  (interactive)
  (when (yes-or-no-p "退出哔哩哔哩登录并清除本地 cookie？")
    (etaf-bili--backend
     (list "logout")
     (lambda (reply)
       (if (plist-get reply :ok)
           (progn
             (message "已退出哔哩哔哩登录")
             (etaf-bili--refresh-open-sessions))
         (message "%s" (or (plist-get reply :message) "退出失败")))))
    nil))

;;;###autoload
(defun etaf-bili-account ()
  "Report the Bilibili account the stored cookies belong to."
  (interactive)
  (etaf-bili--backend
   (list "check")
   (lambda (reply)
     (cond
      ((not (plist-get reply :ok))
       (message "%s" (or (plist-get reply :message) "账号查询失败")))
      ((plist-get reply :signed_in)
       (message "哔哩哔哩：%s" (or (plist-get reply :name) "已登录")))
      (t (message "哔哩哔哩未登录：M-x etaf-bili-login 扫码")))))
  nil)

(provide 'etaf-bili-account)
;;; etaf-bili-account.el ends here
