;;; etaf-bili-model.el --- Session data and actions -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One session's data and the actions that change it: the current mode
;; (popular, ranking or search), the loaded rows, the selected row, the status
;; line and the in-flight request bookkeeping.  The module owns no buffer and
;; no timer, so every action is testable headless; the application layer
;; listens to the refs and mounts the View.
;;
;; Network replies carry a request token: a reply whose token no longer
;; matches the session's latest request is dropped, so typing a second search
;; while the first is in flight cannot overwrite the newer results.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-bili-theme)
(require 'etaf-bili-service)

(defgroup etaf-bili nil
  "Bilibili client built with ETAF and Ebox."
  :group 'applications)

(cl-defstruct (etaf-bili--session (:constructor etaf-bili--session--make))
  "One Bilibili application session.
CLIENT is the backend client; MODE, KEYWORD, ITEMS, SELECTED, STATUS and
LOADING describe what the list shows; PLAYBACK is the open media viewer's
source or nil; REQUEST is the token of the latest in-flight request.  The
`-ref' slots are the reactive sources the View reads."
  client buffer mode keyword items selected status loading request playback
  mode-ref status-ref items-ref selected-ref loading-ref playback-ref
  theme-ref layout-ref)

(cl-defun etaf-bili-session-create (&key client)
  "Create a session with the backend CLIENT.
CLIENT defaults to `etaf-bili-client-factory' when bound, otherwise the
default curl client.  The session starts empty on the popular feed; call
`etaf-bili-load-popular' (or another load action) to fill it."
  (let ((client (or client
                    (if (and (boundp 'etaf-bili-client-factory)
                             etaf-bili-client-factory)
                        (funcall etaf-bili-client-factory)
                      (etaf-bili-make-client)))))
    (etaf-bili--session--make
     :client client
     :mode 'popular
     :keyword nil
     :items nil
     :selected 0
     :status "就绪"
     :loading nil
     :request 0
     :playback nil
     :mode-ref (etaf-ref 'popular)
     :status-ref (etaf-ref "就绪")
     :items-ref (etaf-ref nil)
     :selected-ref (etaf-ref 0)
     :loading-ref (etaf-ref nil)
     :playback-ref (etaf-ref nil)
     :theme-ref (etaf-ref (etaf-bili-theme-defaults))
     :layout-ref (etaf-ref nil :test #'equal))))

(defun etaf-bili--status (session status)
  "Set SESSION's status line to STATUS."
  (setf (etaf-bili--session-status session) status)
  (etaf-set-value (etaf-bili--session-status-ref session) status))

(defun etaf-bili--items (session items)
  "Replace SESSION's rows with ITEMS and select the first one."
  (setf (etaf-bili--session-items session) items
        (etaf-bili--session-selected session) 0)
  (etaf-batch
    (etaf-set-value (etaf-bili--session-items-ref session) items)
    (etaf-set-value (etaf-bili--session-selected-ref session) 0)))

(defun etaf-bili--loading (session loading)
  "Set SESSION's loading flag to LOADING."
  (setf (etaf-bili--session-loading session) (and loading t))
  (etaf-set-value (etaf-bili--session-loading-ref session) (and loading t)))

(defun etaf-bili--request (session request label)
  "Perform REQUEST for SESSION and show LABEL while it runs.
The reply replaces the rows when its token is still the latest; otherwise
it is dropped."
  (let ((token (cl-incf (etaf-bili--session-request session))))
    (etaf-bili--loading session t)
    (etaf-bili--status session (format "%s · 加载中…" label))
    (etaf-bili-client-call
     (etaf-bili--session-client session) request
     (lambda (reply)
       (when (= token (etaf-bili--session-request session))
         (etaf-bili--loading session nil)
         (if-let* ((items (plist-get reply :ok)))
             (progn
               (etaf-bili--items session items)
               (etaf-bili--status session (format "%s · %d 条" label (length items))))
           (etaf-bili--status session
                              (format "%s · %s"
                                      label
                                      (or (plist-get reply :error) "请求失败")))))))))

(defun etaf-bili-load-popular (session)
  "Load the popular feed into SESSION."
  (setf (etaf-bili--session-mode session) 'popular
        (etaf-bili--session-keyword session) nil)
  (etaf-set-value (etaf-bili--session-mode-ref session) 'popular)
  (etaf-bili--request session (list :op :popular) "热门"))

(defun etaf-bili-load-ranking (session)
  "Load the all-category ranking into SESSION."
  (setf (etaf-bili--session-mode session) 'ranking
        (etaf-bili--session-keyword session) nil)
  (etaf-set-value (etaf-bili--session-mode-ref session) 'ranking)
  (etaf-bili--request session (list :op :ranking) "排行榜"))

(defun etaf-bili-search (session keyword)
  "Search videos for KEYWORD and show the results in SESSION."
  (unless (string-empty-p (string-trim keyword))
    (setf (etaf-bili--session-mode session) 'search
          (etaf-bili--session-keyword session) keyword)
    (etaf-set-value (etaf-bili--session-mode-ref session) 'search)
    (etaf-bili--request session (list :op :search :keyword keyword)
                        (format "搜索 %s" keyword))))

(defun etaf-bili-session-state (session)
  "Return SESSION's public state as a detached plist.
Keys are `:mode', `:keyword', `:status', `:loading', `:items', `:selected'
and `:playback'.  It reads the session without changing it."
  (list :mode (etaf-bili--session-mode session)
        :keyword (etaf-bili--session-keyword session)
        :status (etaf-bili--session-status session)
        :loading (and (etaf-bili--session-loading session) t)
        :items (etaf-bili--session-items session)
        :selected (etaf-bili--session-selected session)
        :playback (etaf-bili--session-playback session)))

(defun etaf-bili-reload (session)
  "Reload SESSION's current view (popular, ranking or the last search)."
  (pcase (etaf-bili--session-mode session)
    ('ranking (etaf-bili-load-ranking session))
    ('search (etaf-bili-search session (or (etaf-bili--session-keyword session) "")))
    (_ (etaf-bili-load-popular session))))

(defun etaf-bili-move (session delta)
  "Move SESSION's selection by DELTA rows, clamped to the list."
  (let* ((items (etaf-bili--session-items session))
         (count (length items))
         (selected (etaf-bili--session-selected session)))
    (when (> count 0)
      (let ((next (max 0 (min (1- count) (+ selected delta)))))
        (unless (= next selected)
          (setf (etaf-bili--session-selected session) next)
          (etaf-set-value (etaf-bili--session-selected-ref session) next))))))

(defun etaf-bili-selected-row (session)
  "Return SESSION's selected row plist, or nil when the list is empty."
  (nth (etaf-bili--session-selected session)
       (etaf-bili--session-items session)))

(defun etaf-bili-play-selected (session on-ready)
  "Resolve the selected video's stream and call ON-READY with the source.
ON-READY receives one plist: an `etaf-video' source (`:url' plus the CDN
`:headers') with `:title', `:bvid' and `:duration'.  Failures only change
SESSION's status line."
  (when-let* ((row (etaf-bili-selected-row session)))
    (etaf-bili--status session
                       (format "正在解析播放地址：%s" (plist-get row :title)))
    (etaf-bili-client-call
     (etaf-bili--session-client session)
     (list :op :play :bvid (plist-get row :bvid))
     (lambda (reply)
       (if-let* ((source (plist-get reply :ok)))
           (progn
             (etaf-bili--status session
                                (format "播放：%s" (or (plist-get source :title)
                                                      (plist-get row :title))))
             (funcall on-ready source))
         (etaf-bili--status session
                            (format "播放失败：%s"
                                    (or (plist-get reply :error) "未知错误"))))))))

(provide 'etaf-bili-model)
;;; etaf-bili-model.el ends here
