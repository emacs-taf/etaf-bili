;;; etaf-bili-app.el --- Buffers, keys and commands for etaf-bili -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The application face of the client: the mountable View over the session,
;; the buffer keymap, the commands listed in the root entry and the media
;; viewer that plays a selected video inside the same buffer.  Playback is
;; the framework's `etaf-media-viewer' Component fed with the stream source
;; the service builds (its Referer and User-Agent headers included), so this
;; module owns no decoder, no player state and no transport controls.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-bili-theme)
(require 'etaf-bili-views)
(require 'etaf-bili-model)

(defconst etaf-bili--buffer-name "*Bili*"
  "Name of the single application buffer.")

(defconst etaf-bili--hint-line
  (concat "j/k 选择 · RET 播放 · / 搜索 · 1 热门 · 2 排行榜 · g 刷新"
          " · T 主题 · ? 全部键位 · q 关闭")
  "One-line key hint shown in the footer.")

(defconst etaf-bili--chrome-rows 2
  "Non-list rows: the header and the hint footer.")

(defvar-local etaf-bili--session nil
  "Session owned by the current application buffer.")

(defvar etaf-bili--size-hook-installed nil
  "Whether the window size hook was installed.")

(defvar etaf-bili-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "j") #'etaf-bili-next)
    (define-key map (kbd "k") #'etaf-bili-previous)
    (define-key map (kbd "n") #'etaf-bili-next)
    (define-key map (kbd "p") #'etaf-bili-previous)
    (define-key map (kbd "<down>") #'etaf-bili-next)
    (define-key map (kbd "<up>") #'etaf-bili-previous)
    (define-key map (kbd "RET") #'etaf-bili-play)
    (define-key map (kbd "/") #'etaf-bili-search-prompt)
    (define-key map (kbd "1") #'etaf-bili-popular)
    (define-key map (kbd "2") #'etaf-bili-ranking)
    (define-key map (kbd "g") #'etaf-bili-refresh)
    (define-key map (kbd "T") #'etaf-bili-toggle-theme)
    (define-key map (kbd "C-c h") #'etaf-help)
    (define-key map (kbd "q") #'etaf-bili-close)
    map)
  "Keymap of a buffer opened by `etaf-bili-open'.")

(defvar etaf-bili--command-maps
  (list
   (cons 'etaf-bili--session
         (let ((map (make-sparse-keymap)))
           ;; The renderer's minor-mode map owns SPC, DEL and friends; an
           ;; `emulation-mode-map-alists' entry wins over every minor mode,
           ;; and the session variable scopes it to this buffer.
           (set-keymap-parent map etaf-bili-mode-map)
           (define-key map (kbd "j") #'etaf-bili-next)
           (define-key map (kbd "k") #'etaf-bili-previous)
           (define-key map (kbd "n") #'etaf-bili-next)
           (define-key map (kbd "p") #'etaf-bili-previous)
           (define-key map (kbd "RET") #'etaf-bili-play)
           (define-key map (kbd "/") #'etaf-bili-search-prompt)
           (define-key map (kbd "1") #'etaf-bili-popular)
           (define-key map (kbd "2") #'etaf-bili-ranking)
           (define-key map (kbd "g") #'etaf-bili-refresh)
           (define-key map (kbd "T") #'etaf-bili-toggle-theme)
           (define-key map (kbd "q") #'etaf-bili-close)
           map)))
  "Application bindings that must beat the renderer's own minor-mode map.
The alist's key is `etaf-bili--session', the buffer-local variable every
application buffer owns, so the entry is active exactly there.")

(defun etaf-bili--current ()
  "Return the current buffer's session, or signal `user-error'."
  (or etaf-bili--session
      (user-error "Not an etaf-bili buffer")))

(defun etaf-bili--visible-rows (session start count)
  "Return COUNT rows of SESSION's list from START as (POSITION . ROW).
Each row carries the display values the list needs, so the View stays a
pure function of its props."
  (cl-loop for position from start
           for row in (seq-drop (etaf-bili--session-items session) start)
           repeat count
           collect (cons position row)))

(etaf-define-component etaf-bili--shell
    (&key session)
  "Render the client shell for SESSION with the application theme.
The shell is a fixed plane: a header, the list, the details aside, a hint
footer and the media viewer when a video is open.  The published viewport
decides whether the details column exists, and the list shows only the rows
that fit the measured body."
  :bindings ((theme (etaf-bili--session-theme-ref session))
             (playback (etaf-bili--session-playback-ref session)))
  :setup
  (etaf-theme-provide theme)
  :render
  (let* ((_palette (etaf-value theme))
         (mode (etaf-value (etaf-bili--session-mode-ref session)))
         (items (etaf-value (etaf-bili--session-items-ref session)))
         (selected (etaf-value (etaf-bili--session-selected-ref session)))
         (status-ref (etaf-bili--session-status-ref session))
         (layout (etaf-value (etaf-bili--session-layout-ref session)))
         (viewport-width (or (car-safe layout) 0))
         (viewport-rows (or (cdr-safe layout) 0))
         (details (>= viewport-width etaf-bili--detail-min-pixels))
         (body-rows (max 1 (- viewport-rows etaf-bili--chrome-rows)))
         (capacity (max 0 (/ body-rows 2)))
         (visible (min capacity (length items)))
         (start (if (<= visible 0)
                    0
                  (max 0 (min (- (length items) visible)
                              (- selected (/ visible 2))))))
         (list-width (if details
                         (list 'calc (list '- (list 'px viewport-width)
                                           etaf-bili--detail-width))
                       'stretch))
         (detail-left (list 'calc (list '- (list 'px viewport-width)
                                        etaf-bili--detail-width)))
         (row (etaf-bili-selected-row session))
         (playing (etaf-value playback)))
    (etaf-view
     (box :position 'relative
           :width (list 'px viewport-width)
           :height (list 'lh viewport-rows)
           :background-color (etaf-bili-color :bg)
           :color (etaf-bili-color :ink)
           :overflow 'hidden
       (etaf-bili--view-header
        :position 'absolute :left '(px 0) :top '(lh 0)
        :width (list 'px viewport-width) :height '(lh 1)
        :mode mode
        :status-ref status-ref
        :on-search (lambda () (etaf-bili-search-prompt))
        :on-theme (lambda () (etaf-bili-toggle-theme)))
       (etaf-bili--view-list
        :position 'absolute :left '(px 0) :top '(lh 1)
        :width list-width :height (list 'lh body-rows)
        :items (etaf-bili--visible-rows session start visible)
        :selected selected :start start
        :on-press (lambda (position)
                    (etaf-bili-move session (- position
                                               (etaf-bili--session-selected session)))
                    (etaf-bili-play)))
       (etaf-bili--view-detail
        :if details :position 'absolute :left detail-left :top '(lh 1)
        :width etaf-bili--detail-width :height (list 'lh body-rows)
        :row row)
       (etaf-bili--view-footer
        :position 'absolute :left '(px 0) :top (list 'lh (1+ body-rows))
        :width (list 'px viewport-width) :height '(lh 1)
        :hints etaf-bili--hint-line)
       (etaf-media-viewer
        :open (and playing t)
        :kind 'video
        :src (plist-get playing :source)
        :title (or (plist-get playing :title) "")
        :on-close (lambda () (etaf-bili--stop-playback))
        :on-next (lambda () (etaf-bili--play-relative session 1))
        :on-previous (lambda () (etaf-bili--play-relative session -1)))))))

(defun etaf-bili--view (session)
  "Return the mountable View of SESSION."
  (etaf-view (etaf-bili--shell :session session)))

(defun etaf-bili--sync-layout (session)
  "Publish SESSION's framework viewport into its layout ref."
  (when-let* ((buffer (etaf-bili--session-buffer session))
              (runtime (and (buffer-live-p buffer)
                            (etaf-runtime-for-buffer buffer)))
              (mounted (etaf-runtime-mounted-p runtime)))
    (let ((viewport (etaf-runtime-viewport runtime)))
      (unless (equal viewport (etaf-value (etaf-bili--session-layout-ref session)))
        (etaf-set-value (etaf-bili--session-layout-ref session) viewport)
        (etaf-runtime-flush runtime)))
    t))

(defun etaf-bili--refit (session window)
  "Refit SESSION to WINDOW through the framework's viewport publication."
  (let ((buffer (etaf-bili--session-buffer session)))
    (when (and (buffer-live-p buffer)
               (etaf-runtime-for-buffer buffer))
      (etaf-refit (etaf-runtime-for-buffer buffer) window)
      (etaf-bili--sync-layout session))))

(defun etaf-bili--window-size-changed (frame)
  "Refit every Bilibili session shown on FRAME after a window resize."
  (dolist (window (window-list frame))
    (with-current-buffer (window-buffer window)
      (when etaf-bili--session
        (etaf-bili--refit etaf-bili--session window)))))

(defun etaf-bili--install-size-hook ()
  "Install the application's window size hook once."
  (unless etaf-bili--size-hook-installed
    (add-hook 'window-size-change-functions #'etaf-bili--window-size-changed)
    (setq etaf-bili--size-hook-installed t)))

(defun etaf-bili--start-playback (session source)
  "Open SOURCE (an `etaf-video' plist) in SESSION's media viewer."
  (let ((playback (list :source source
                        :title (or (plist-get source :title)
                                   (plist-get (etaf-bili-selected-row session) :title)))))
    (setf (etaf-bili--session-playback session) playback)
    (etaf-set-value (etaf-bili--session-playback-ref session) playback)))

(defun etaf-bili--stop-playback ()
  "Close the media viewer in the current buffer."
  (when-let* ((session etaf-bili--session))
    (setf (etaf-bili--session-playback session) nil)
    (etaf-set-value (etaf-bili--session-playback-ref session) nil)))

(defun etaf-bili--play-relative (session delta)
  "Select and play the row DELTA after SESSION's selection.
The viewer stays open: the source prop changes and the native Component
rebuilds its session at the new stream."
  (etaf-bili-move session delta)
  (etaf-bili-play-selected session (lambda (source)
                                     (etaf-bili--start-playback session source))))

;;;###autoload
(defun etaf-bili-open ()
  "Open the Bilibili client in its own buffer and return that buffer.
The popular feed starts loading immediately; `/` searches, `RET` plays the
selected video in the framework's media viewer."
  (interactive)
  (when (get-buffer etaf-bili--buffer-name)
    (with-current-buffer (get-buffer etaf-bili--buffer-name)
      (when etaf-bili--session
        (etaf-bili-close))))
  (let* ((buffer (get-buffer-create etaf-bili--buffer-name))
         (session (etaf-bili-session-create)))
    (setf (etaf-bili--session-buffer session) buffer)
    (with-current-buffer buffer
      (setq-local etaf-bili--session session)
      (setq-local mode-line-format nil)
      (setq-local truncate-lines t)
      (setq-local auto-hscroll-mode nil)
      (setq-local cursor-type nil)
      (setq-local emulation-mode-map-alists
                  (cons 'etaf-bili--command-maps
                        (remq 'etaf-bili--command-maps emulation-mode-map-alists)))
      (setq-local buffer-display-table
                  (let ((table (copy-sequence (or standard-display-table
                                                  (make-display-table)))))
                    (set-display-table-slot table 'truncation ?\s)
                    table))
      (use-local-map etaf-bili-mode-map))
    (let ((display-buffer-overriding-action '((display-buffer-same-window))))
      (pop-to-buffer buffer))
    (etaf-mount buffer (etaf-bili--view session))
    (etaf-bili--install-size-hook)
    (etaf-bili--sync-layout session)
    (etaf-bili-load-popular session)
    buffer))

;;;###autoload
(defun etaf-bili-close ()
  "Close the Bilibili client and kill its buffer."
  (interactive)
  (let ((buffer (current-buffer)))
    (when etaf-bili--session
      (setq-local etaf-bili--session nil))
    (when (buffer-live-p buffer)
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (ignore-errors (etaf-unmount runtime)))
      (kill-buffer buffer)))
  t)

(defun etaf-bili-next ()
  "Move the selection to the next row."
  (interactive)
  (etaf-bili-move (etaf-bili--current) 1))

(defun etaf-bili-previous ()
  "Move the selection to the previous row."
  (interactive)
  (etaf-bili-move (etaf-bili--current) -1))

(defun etaf-bili-popular ()
  "Load the popular feed."
  (interactive)
  (etaf-bili-load-popular (etaf-bili--current)))

(defun etaf-bili-ranking ()
  "Load the all-category ranking."
  (interactive)
  (etaf-bili-load-ranking (etaf-bili--current)))

(defun etaf-bili-refresh ()
  "Reload the current view."
  (interactive)
  (etaf-bili-reload (etaf-bili--current)))

(defun etaf-bili-search-prompt ()
  "Prompt for a keyword and search videos."
  (interactive)
  (let ((keyword (read-string "搜索 B 站： ")))
    (etaf-bili-search (etaf-bili--current) keyword)))

(defun etaf-bili-play ()
  "Play the selected video in the media viewer."
  (interactive)
  (let ((session (etaf-bili--current)))
    (etaf-bili-play-selected session
                             (lambda (source)
                               (etaf-bili--start-playback session source)))))

(defun etaf-bili-toggle-theme ()
  "Switch the client between the dark and light palette."
  (interactive)
  (let* ((session (etaf-bili--current))
         (next (if (eq etaf-bili-theme-mode 'dark) 'light 'dark)))
    (setq etaf-bili-theme-mode next)
    (etaf-set-value (etaf-bili--session-theme-ref session)
                    (etaf-bili-theme-defaults next))
    t))

(provide 'etaf-bili-app)
;;; etaf-bili-app.el ends here
