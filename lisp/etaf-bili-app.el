;;; -*- lexical-binding: t; -*-
;;; etaf-bili-app.el --- Responsive library and media-viewer lifecycle

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The application composes the catalog, keeps covers outside render, and
;; leaves focus, editing and modal key ownership to ETAF.  No frame parameters
;; or user faces are changed; the buffer alone adopts the application palette.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'face-remap)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-bili-model)
(require 'etaf-bili-views)
(declare-function image-size "image.c" (spec &optional pixels frame))

(defconst etaf-bili--buffer-name "*Bili*")
(defvar-local etaf-bili--session nil)

(defun etaf-bili--current ()
  "Return this buffer's live session."
  (or etaf-bili--session (user-error "当前缓冲区不是 B 站客户端")))

(defun etaf-bili--keys ()
  "Return the single source of application shortcuts and help labels."
  (append
   (unless (eq etaf-direction-scheme 'vim)
     (list (list "j" #'etaf-bili-next "下一视频")
           (list "k" #'etaf-bili-previous "上一视频")))
   (list (list "n" #'etaf-bili-next "下一视频")
         (list "p" #'etaf-bili-previous "上一视频")
         (list "RET" #'etaf-bili--activate "播放／激活控件")
         (list "/" #'etaf-bili-search-prompt "搜索视频")
         (list "1" #'etaf-bili-popular "发现热门")
         (list "2" #'etaf-bili-ranking "全站排行")
         (list "g" #'etaf-bili-refresh "刷新")
         (list "T" #'etaf-bili-toggle-theme "切换明暗主题")
         (list "i" #'etaf-bili-details "视频详情")
         (list "q" #'etaf-bili-close "关闭客户端"))))

(defun etaf-bili--visible-slice (first count layout)
  "Return the virtual row window for FIRST observed row, COUNT and LAYOUT.
Overscan includes the preceding row and enough following rows for a partial
viewport edge.  Spacers preserve the full scroll extent; the framework
remains the sole offset authority."
  (let* ((across (plist-get layout :across))
         (pitch (1+ (plist-get layout :card-height)))
         (rows (ceiling (float count) across))
         (start-row (min (max 0 (1- rows)) (max 0 (1- first))))
         (visible-rows (min (- rows start-row)
                            (+ 3 (ceiling (float (plist-get layout :body)) pitch))))
         (total (max 0 (1- (* rows pitch))))
         (leading (* start-row pitch))
         (height (max 0 (1- (* visible-rows pitch)))))
    (list :start (* start-row across) :end (min count (* (+ start-row visible-rows) across))
          :leading leading :height height :trailing (max 0 (- total leading height))
          :total total :rows visible-rows)))

(etaf-define-component etaf-bili--gallery (&key session layout on-play on-select)
  "A native scroll owner over a bounded virtual card window."
  :render
  (let* ((items (etaf-value (etaf-bili--session-items-ref session)))
         (first (etaf-value (etaf-bili--session-visible-row-ref session)))
         (loading (etaf-value (etaf-bili--session-loading-ref session)))
         (error (etaf-value (etaf-bili--session-error-ref session)))
         (slice (etaf-bili--visible-slice first (length items) layout))
         (start (plist-get slice :start))
         (visible (seq-subseq items start (plist-get slice :end)))
         (width (plist-get layout :grid-columns))
         (card-width (plist-get layout :card-width))
         (height (plist-get layout :card-height))
         (image-rows (plist-get layout :cover-rows))
         (columns (make-list (plist-get layout :across) (list 'ch card-width))))
    (cond
     (error (etaf-view
             (column :width (list 'ch width) :item-gap '(lh 1)
               (etaf-alert :variant 'danger :title "暂时无法加载" :message error)
               (etaf-button :label "重试" :ref 'bili-retry :on-press #'etaf-bili-refresh))))
     ((and (not loading) (null items))
      (etaf-view (etaf-empty :title "没有找到视频" :description "换个关键词，再发现一点有趣的内容。"
                             :action-label "重新搜索" :on-action #'etaf-bili-search-prompt)))
     ((null items)
      (etaf-node 'grid (list :grid-template-columns columns :gap '((lh 1) (ch 3)))
                 (cl-loop repeat (plist-get layout :capacity) collect
                          (etaf-node 'etaf-bili--skeleton-card
                                     (list :columns card-width :image-rows image-rows :height height) nil))))
     (t
      (etaf-node
       'box
       (list :ref 'bili-gallery :width (list 'ch width)
             :height (list 'lh (plist-get layout :body)) :overflow 'scroll
             :background-color (etaf-bili-color :bg)
             :region (list :id 'gallery :label "视频" :key "v"
                           :enter (intern (format "bili-card-%d"
                                                  (min (1- (length items))
                                                       (* first (plist-get layout :across))))))
             :on-scroll (lambda (offset) (etaf-bili--observe-scroll session offset))
             :on-direction (lambda (direction) (etaf-bili--direction session layout direction)))
       (list
        (etaf-node
         'column (list :width 'stretch :item-gap '(lh 0))
         (list
          (etaf-node 'box (list :height (list 'lh (plist-get slice :leading)) :width 'stretch) nil)
          (etaf-node
           'grid
           (list :width 'stretch :height (list 'lh (plist-get slice :height))
                 :grid-template-columns columns
                 :grid-template-rows (make-list (plist-get slice :rows) (list 'lh height))
                 :gap '((lh 1) (ch 3)))
           (cl-loop for row in visible for index from start collect
                    (etaf-node
                     'etaf-bili--video-card
                     (list :key (plist-get row :bvid) :row row :index index
                           :selection (etaf-bili--session-selected-ref session)
                           :cover (cdr (gethash (plist-get row :cover) (etaf-bili--session-covers session)))
                           :columns card-width :image-rows image-rows :height height
                           :cell-width (plist-get layout :cell-width)
                           :cell-height (plist-get layout :cell-height)
                           :on-play on-play :on-select on-select) nil)))
          (etaf-node 'box (list :height (list 'lh (plist-get slice :trailing)) :width 'stretch) nil)))))))))

(etaf-define-component etaf-bili--footer (&key session layout)
  "A padded footer; native wheel scrolling replaces page controls."
  :render
  (let ((count (length (etaf-value (etaf-bili--session-items-ref session)))))
    (etaf-view
     (flex :height '(lh 3) :align-items 'center :gap '((lh 0) (ch 2))
           :width (list 'ch (plist-get layout :columns))
       (etaf-label :text (if (> count 0) (format "%d 个视频 · 向下滚动浏览" count)
                          "等待新的发现") :variant 'muted)
       (box :flex-grow 1 :flex-basis '(ch 0))
       (etaf-button :ref 'bili-details :label "详情" :variant 'ghost
                    :disabled (= count 0) :on-press #'etaf-bili-details)
       (etaf-button :label "?" :variant 'ghost :on-press #'etaf-help)))))

(etaf-define-component etaf-bili--shell (&key session)
  "Compose the search header, navigation, cover gallery and modal surfaces."
  :bindings
  ((theme (etaf-bili--session-theme-ref session))
   (details (etaf-bili--session-details-ref session))
   (on-select (lambda (index) (etaf-bili--select session index)))
   (on-play (lambda (index)
              (etaf-bili--select session index)
              (etaf-bili-play-selected session
                                       (lambda (source) (etaf-bili--start-playback session source)))))
   (submit (lambda (query) (etaf-bili-search session query)))
   (mode-change (lambda (mode)
                  (pcase mode
                    ('popular (etaf-bili-load-popular session))
                    ('ranking (etaf-bili-load-ranking session))
                    (_ (if (etaf-bili--session-keyword session)
                           (etaf-bili-search session (etaf-bili--session-keyword session))
                         (etaf-bili-search-prompt)))))))
  :setup (etaf-theme-provide theme)
  :render
  (let* ((_theme (etaf-value theme))
         (layout (etaf-value (etaf-bili--session-layout-ref session)))
         (row (etaf-value details))
         (playing (etaf-value (etaf-bili--session-playback-ref session)))
         (width (plist-get layout :columns))
         (height (plist-get layout :rows)))
    (etaf-view
     (column :ref 'bili-shell :position 'relative
             :width (list 'px (plist-get layout :width)) :height (list 'lh height)
             :item-gap '(lh 0) :cross-align 'center
             :overflow 'hidden :background-color (etaf-bili-color :bg) :color (etaf-bili-color :ink)
             :keys (etaf-bili--keys)
       (box :width 'stretch :height '(lh 1) :background-color (etaf-bili-color :bg))
       (column :width 'stretch :height '(lh 3) :cross-align 'center
               :background-color (etaf-bili-color :bg)
         (etaf-bili--header :query (etaf-bili--session-query-ref session)
                            :width width :compact (< width 96)
                            :on-submit submit :on-theme #'etaf-bili-toggle-theme))
       (box :width 'stretch :height '(lh 1) :background-color (etaf-bili-color :bg))
       (column :width 'stretch :height '(lh 3) :cross-align 'center
               :background-color (etaf-bili-color :bg)
         (etaf-bili--navigation :mode (etaf-bili--session-mode-ref session)
                                :status (etaf-bili--session-status-ref session)
                                :loading (etaf-bili--session-loading-ref session)
                                :width width :on-mode mode-change :on-refresh #'etaf-bili-refresh))
       (column :width 'stretch :height (list 'lh (plist-get layout :body))
               :cross-align 'center :overflow 'hidden :background-color (etaf-bili-color :bg)
         (etaf-bili--gallery :session session :layout layout :on-play on-play :on-select on-select))
       (column :width 'stretch :height '(lh 3) :cross-align 'center
               :background-color (etaf-bili-color :bg)
         (etaf-bili--footer :session session :layout layout))
       (etaf-drawer :open details :title "视频详情" :width '(ch 52)
                    :on-close (lambda () (etaf-set-value details nil))
         (etaf-card :title (or (plist-get row :title) "未选择视频")
           (etaf-label :text (or (plist-get row :author) "") :variant 'muted)
           (etaf-badge :text (etaf-bili--clock (plist-get row :duration)))
           (etaf-label :text (concat (etaf-bili--count (plist-get row :views)) " 次播放"))
           (etaf-label :text (plist-get row :bvid) :variant 'muted)
           (etaf-button :label "播放视频" :variant 'primary :on-press #'etaf-bili-play)))
       (etaf-media-viewer :open (and playing t) :kind 'video
                          :src (plist-get playing :source) :title (or (plist-get playing :title) "")
                          :on-close (lambda () (etaf-bili--stop-playback session))
                          :on-next (lambda () (etaf-bili--play-relative session 1))
                          :on-previous (lambda () (etaf-bili--play-relative session -1)))))))

(defun etaf-bili--select (session index)
  "Select INDEX without unnecessarily publishing an identical state."
  (unless (= index (etaf-bili--session-selected session))
    (etaf-bili-move session (- index (etaf-bili--session-selected session)))))

(defun etaf-bili--direction (session layout direction)
  "Move SESSION across the card grid using DIRECTION and LAYOUT."
  (etaf-bili-move session (pcase direction
                            ('left -1) ('right 1)
                            ('up (- (plist-get layout :across)))
                            ('down (plist-get layout :across)) (_ 0)))
  (etaf-bili--focus-selected session)
  'handled)

(defun etaf-bili--observe-scroll (session offset)
  "Project OFFSET from the native scroll owner into SESSION's visible rows."
  (unless (etaf-bili--session-disposed session)
    (let* ((layout (etaf-value (etaf-bili--session-layout-ref session)))
           (first (/ offset (1+ (plist-get layout :card-height)))))
      (unless (= first (etaf-value (etaf-bili--session-visible-row-ref session)))
        (etaf-set-value (etaf-bili--session-visible-row-ref session) first)
        (etaf-bili--prepare-covers session)))))

(defun etaf-bili--library-changed (session reset)
  "Prepare SESSION's resources and reset native scroll only for a new library."
  (when reset
    (etaf-set-value (etaf-bili--session-visible-row-ref session) 0)
    (etaf-next-tick
     (lambda ()
       (when-let* ((buffer (etaf-bili--session-buffer session))
                   (runtime (etaf-runtime-for-buffer buffer))
                   (size (etaf-host-ref-size runtime 'bili-gallery)))
         (etaf-scroll-to runtime 'bili-gallery 'start)))))
  (etaf-bili--prepare-covers session))

(defun etaf-bili--focus-selected (session)
  "Reveal and focus SESSION's card using the native scroll offset authority."
  (etaf-next-tick
   (lambda ()
     (unless (or (etaf-bili--session-disposed session)
                 (null (etaf-bili--session-items session)))
       (when-let* ((buffer (etaf-bili--session-buffer session))
                   (runtime (etaf-runtime-for-buffer buffer)))
         (let* ((layout (etaf-value (etaf-bili--session-layout-ref session)))
                (row (/ (etaf-bili--session-selected session) (plist-get layout :across)))
                (top (* row (1+ (plist-get layout :card-height))))
                (bottom (+ top (plist-get layout :card-height)))
                (offset (etaf-scroll-offset runtime 'bili-gallery))
                (target (cond ((< top offset) top)
                              ((> bottom (+ offset (plist-get layout :body)))
                               (- bottom (plist-get layout :body)))
                              (t offset))))
           (etaf-scroll-to runtime 'bili-gallery target)
           (etaf-bili--observe-scroll session (etaf-scroll-offset runtime 'bili-gallery))
           (etaf-next-tick
            (lambda ()
              (unless (etaf-bili--session-disposed session)
                (etaf-focus runtime (intern (format "bili-card-%d" (etaf-bili--session-selected session)))))))))))))

(defun etaf-bili--prepare-covers (session)
  "Prepare cover refs for SESSION's visible rows and their overscan neighbors."
  (unless (etaf-bili--session-disposed session)
    (let* ((table (etaf-bili--session-covers session))
           (items (etaf-bili--session-items session))
           (layout (etaf-value (etaf-bili--session-layout-ref session)))
           (slice (etaf-bili--visible-slice
                   (etaf-value (etaf-bili--session-visible-row-ref session))
                   (length items) layout)))
      (dolist (row items)
        (let ((url (plist-get row :cover)))
          (unless (gethash url table) (puthash url (cons nil (etaf-ref nil)) table))))
      (setf (etaf-bili--session-cover-queue session)
            (delete-dups
             (delq nil (mapcar
                        (lambda (row)
                          (let ((url (plist-get row :cover)))
                            (and (stringp url) (not (string-empty-p url))
                                 (null (car (gethash url table))) url)))
                        (seq-subseq items (plist-get slice :start) (plist-get slice :end))))))
      (when (display-graphic-p) (etaf-bili--pump-covers session)))))

(defun etaf-bili--pump-covers (session)
  "Run at most three cover transfers concurrently for SESSION."
  (while (and (not (etaf-bili--session-disposed session))
              (< (etaf-bili--session-cover-active session) 3)
              (etaf-bili--session-cover-queue session))
    (let* ((url (pop (etaf-bili--session-cover-queue session)))
           (entry (gethash url (etaf-bili--session-covers session))))
      (setcar entry 'loading)
      (cl-incf (etaf-bili--session-cover-active session))
      (let ((process
             (etaf-bili-client-call
              (etaf-bili--session-client session) (list :op :cover :url url)
              (lambda (reply)
                (cl-decf (etaf-bili--session-cover-active session))
                (setcar entry 'done)
                (unless (etaf-bili--session-disposed session)
                  (etaf-set-value
                   (cdr entry)
                   (if-let* ((file (plist-get reply :ok)))
                       (condition-case _unreadable
                           (let ((size (image-size (create-image file) t)))
                             (list :file file :size size))
                         (error 'unavailable))
                     'unavailable))
                  (etaf-bili--pump-covers session))))))
        (when (processp process) (push process (etaf-bili--session-processes session)))))))

(defun etaf-bili--sync-layout (session)
  "Read the displayed viewport once and update SESSION's pure layout value."
  (when-let* ((buffer (etaf-bili--session-buffer session))
              (window (get-buffer-window buffer t)))
    (let* ((frame (window-frame window))
           (runtime (etaf-runtime-for-buffer buffer))
           (viewport (and runtime (etaf-runtime-mounted-p runtime)
                          (or (etaf-runtime-window-viewport runtime)
                              (etaf-runtime-viewport runtime))))
           ;; A whole-row display-space wider than the canvas is dropped by
           ;; redisplay.  Use the provider's usable width, never raw window
           ;; width or a guessed pixel allowance.  Initial mount is narrow;
           ;; the first committed viewport immediately supplies the real size.
           (layout (etaf-bili--layout
                    (list (or (car viewport) (* 64 (frame-char-width frame)))
                          (or (cdr viewport) (window-body-height window))
                          (frame-char-width frame) (frame-char-height frame)))))
      (etaf-set-value (etaf-bili--session-layout-ref session) layout)
      (etaf-bili--prepare-covers session))))

(defun etaf-bili--resize (_frame)
  "Refit the visible Bili buffer without affecting other application windows."
  (when-let* ((buffer (get-buffer etaf-bili--buffer-name)))
    (with-current-buffer buffer
      (when etaf-bili--session (etaf-bili--sync-layout etaf-bili--session)))))

(defun etaf-bili--start-playback (session source)
  "Publish SOURCE into SESSION's media viewer if the buffer remains live."
  (unless (etaf-bili--session-disposed session)
    (let ((value (list :source source :title (plist-get source :title))))
      (setf (etaf-bili--session-playback session) value)
      (etaf-set-value (etaf-bili--session-playback-ref session) value))))

(defun etaf-bili--stop-playback (session)
  "Dismiss SESSION's viewer and invalidate a pending next-video response."
  (cl-incf (etaf-bili--session-play-request session))
  (setf (etaf-bili--session-playback session) nil)
  (etaf-set-value (etaf-bili--session-playback-ref session) nil))

(defun etaf-bili--play-relative (session delta)
  "Play the video DELTA entries from SESSION's selection."
  (etaf-bili-move session delta)
  (etaf-bili-play-selected session (lambda (source) (etaf-bili--start-playback session source))))

(defun etaf-bili--cleanup ()
  "Release the current buffer's requests, runtime and scoped animations."
  (when etaf-bili--session
    (let ((session etaf-bili--session))
      (setf (etaf-bili--session-disposed session) t
            (etaf-bili--session-on-change session) nil)
      (setq etaf-bili--session nil)
      (dolist (process (etaf-bili--session-processes session))
        (when (process-live-p process) (delete-process process)))
      (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer)))) (etaf-unmount runtime))
      (remove-hook 'window-size-change-functions #'etaf-bili--resize))))

;;;###autoload
(defun etaf-bili-open ()
  "Open a responsive Bilibili gallery and load the popular feed."
  (interactive)
  (when-let* ((old (get-buffer etaf-bili--buffer-name)))
    (with-current-buffer old (etaf-bili-close)))
  (let* ((buffer (get-buffer-create etaf-bili--buffer-name))
         (session (etaf-bili-session-create)))
    (with-current-buffer buffer
      (setq-local etaf-bili--session session mode-line-format nil
                  truncate-lines t auto-hscroll-mode nil cursor-type nil)
      (setq-local buffer-display-table (make-display-table))
      (set-display-table-slot buffer-display-table 'truncation ?\s)
      (face-remap-set-base 'default (list :background (etaf-bili-color :bg)
                                          :foreground (etaf-bili-color :ink)))
      (setf (etaf-bili--session-buffer session) buffer
            (etaf-bili--session-on-change session)
            (lambda (reset) (etaf-bili--library-changed session reset)))
      (add-hook 'kill-buffer-hook #'etaf-bili--cleanup nil t))
    (switch-to-buffer buffer)
    (etaf-bili--sync-layout session)
    (condition-case error
        (progn (etaf-mount buffer (etaf-view (etaf-bili--shell :session session)))
               (etaf-bili--sync-layout session)
               (with-current-buffer buffer
                 (face-remap-set-base 'default (list :background (etaf-bili-color :bg)
                                                     :foreground (etaf-bili-color :ink))))
               (add-hook 'window-size-change-functions #'etaf-bili--resize)
               (etaf-bili-load-popular session))
      (error (kill-buffer buffer) (signal (car error) (cdr error))))
    buffer))

;;;###autoload
(defun etaf-bili-close ()
  "Close only the Bilibili application buffer, releasing its resources."
  (interactive)
  (when-let* ((buffer (get-buffer etaf-bili--buffer-name))) (kill-buffer buffer))
  t)

(defun etaf-bili-next ()
  "Select and focus the next video."
  (interactive)
  (let ((session (etaf-bili--current)))
    (etaf-bili-move session 1) (etaf-bili--focus-selected session)))

(defun etaf-bili-previous ()
  "Select and focus the previous video."
  (interactive)
  (let ((session (etaf-bili--current)))
    (etaf-bili-move session -1) (etaf-bili--focus-selected session)))

(defun etaf-bili-popular () "Load the popular feed." (interactive)
  (etaf-bili-load-popular (etaf-bili--current)))
(defun etaf-bili-ranking () "Load the ranking." (interactive)
  (etaf-bili-load-ranking (etaf-bili--current)))
(defun etaf-bili-refresh () "Reload the current feed." (interactive)
  (etaf-bili-reload (etaf-bili--current)))

(defun etaf-bili-search-prompt ()
  "Begin editing the catalog SearchField, without opening a minibuffer."
  (interactive)
  (etaf-text-input-begin (etaf-runtime-for-buffer (current-buffer)) 'bili-search))

(defun etaf-bili--activate ()
  "Activate a focused catalog control, or play the selected card."
  (if (etaf-focused-host-ref) (etaf-activate) (etaf-bili-play)))

(defun etaf-bili-play () "Play the selected video." (interactive)
  (let ((session (etaf-bili--current)))
    (etaf-bili-play-selected session (lambda (source) (etaf-bili--start-playback session source)))))

(defun etaf-bili-details ()
  "Open the selected video's catalog Drawer."
  (interactive)
  (let ((session (etaf-bili--current)))
    (etaf-set-value (etaf-bili--session-details-ref session) (etaf-bili-selected-row session))))

(defun etaf-bili-toggle-theme ()
  "Switch the client palette without changing the frame or user theme."
  (interactive)
  (let ((session (etaf-bili--current)))
    (setq etaf-bili-theme-mode (if (eq etaf-bili-theme-mode 'dark) 'light 'dark))
    (face-remap-set-base 'default (list :background (etaf-bili-color :bg)
                                       :foreground (etaf-bili-color :ink)))
    (etaf-set-value (etaf-bili--session-theme-ref session) (etaf-bili-theme-defaults))))

(provide 'etaf-bili-app)
