;;; etaf-bili-views.el --- Bilibili client presentation -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Pure projections for the client shell: the header, the video row, the list
;; pane and the details aside.  Components receive values and callbacks only;
;; they never read the session, touch storage or start requests.  Colors come
;; from `etaf-bili-theme' through the four depth steps, and every row keeps
;; its line budget so the list never grows a pane.

;;; Code:

(require 'etaf)
(require 'etaf-ui)
(require 'etaf-bili-theme)

(defconst etaf-bili--detail-width '(ch 34)
  "Width of the details column.")
(defconst etaf-bili--detail-min-pixels 1000
  "Published viewport width from which the details column is shown.")

(defun etaf-bili--view-value (value)
  "Read a display VALUE or source inside its consuming Host."
  (if (or (etaf-ref-p value) (etaf-computed-p value)) (etaf-value value) value))

(defun etaf-bili--border (color)
  "Return a one-pixel solid border in COLOR."
  (list '(px 1) 'solid color))

(defun etaf-bili--hover-surface ()
  "Return the shared hover surface."
  (list :background-color (etaf-bili-color :hover)))

(defun etaf-bili--clock (seconds)
  "Format SECONDS as `MM:SS' or `H:MM:SS'."
  (let* ((seconds (max 0 (round (or seconds 0))))
         (hours (/ seconds 3600))
         (minutes (/ (% seconds 3600) 60))
         (rest (% seconds 60)))
    (if (> hours 0)
        (format "%d:%02d:%02d" hours minutes rest)
      (format "%02d:%02d" minutes rest))))

(defun etaf-bili--mode-label (mode)
  "Return the display label for MODE."
  (pcase mode
    ('popular "热门")
    ('ranking "排行榜")
    ('search "搜索")
    (_ "浏览")))

(etaf-define-component etaf-bili--view-header
    (&key mode status-ref on-search on-theme position left top width height)
  "Render the brand, the current mode, the retained status and the buttons."
  :view
  (flex :position (or position 'static) :left (or left '(px 0)) :top (or top '(lh 0))
        :width (or width 'stretch) :height (or height '(lh 1)) :align-items 'center
        :gap '((lh 0) (ch 1)) :padding '((lh 0) (ch 2))
        :background-color (etaf-bili-color :panel2)
        :border-bottom (etaf-bili--border (etaf-bili-color :line))
    (etaf-ui-icon :name 'video :set 'svg :size 0.9 :min-width 2
                  :color (etaf-bili-color :accent))
    (box :height '(lh 1) :font-weight 'bold :color (etaf-bili-color :ink)
      (text "B 站"))
    (box :height '(lh 1) :color (etaf-bili-color :dim) (text "·"))
    (box :height '(lh 1) :color (etaf-bili-color :accent)
      (text (expr (etaf-bili--mode-label mode))))
    (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
         :height '(lh 1) :overflow 'hidden
      (text :color (etaf-bili-color :muted) :font-size 16
        (expr (etaf-bili--view-value status-ref))))
    (etaf-button :ref 'bili-search :label "搜索" :variant 'ghost
                 :help-echo "搜索视频 (/)" :on-press on-search)
    (etaf-button :ref 'bili-theme :label "明暗" :variant 'ghost
                 :help-echo "切换明暗主题 (T)" :on-press on-theme)))

(etaf-define-component etaf-bili--view-row
    (&key position title author duration views date active on-press)
  "Render one two-line video row with a stable full-row target."
  :view
  (flex :position 'relative :width 'stretch :height '(lh 2)
        :align-items 'center :gap '((lh 0) (ch 1)) :padding '((lh 0) (ch 1))
        :role 'button :tab-index 0 :ref (intern (format "bili-row-%d" position))
        :help-echo (format "播放：%s" title)
        :on-press on-press
        :hover-style (unless active (etaf-bili--hover-surface))
        :background-color (etaf-bili-color (if active :accent-soft :surface))
    (box :if active :position 'absolute :left '(px 0) :top '(lh 0)
         :width '(px 2) :height '(lh 2) :background-color (etaf-bili-color :accent))
    (box :width '(ch 3) :height '(lh 1) :text-align 'center
         :color (etaf-bili-color (if active :accent :dim))
      (text (expr (number-to-string (1+ position)))))
    (flex :flex-direction 'column :height '(lh 2) :min-width '(ch 0)
          :flex-grow 1 :flex-basis '(ch 0)
      (box :height '(lh 1) :overflow 'hidden
           :font-weight (if active 'bold 'normal)
           :color (etaf-bili-color (if active :accent :ink))
        (text (expr title)))
      (flex :height '(lh 1) :align-items 'center :gap '((lh 0) (ch 1))
            :min-width '(ch 0)
        (box :height '(lh 1) :overflow 'hidden :font-size 16
             :color (etaf-bili-color :muted)
          (text (expr author)))
        (box :height '(lh 1) :font-size 16 :color (etaf-bili-color :dim)
          (text "·"))
        (box :height '(lh 1) :font-size 16 :color (etaf-bili-color :dim)
          (text (expr (format "%s · %s 播放 · %s"
                              (etaf-bili--clock duration) views date))))))))

(etaf-define-component etaf-bili--view-list
    (&key items selected start on-press position left top width height)
  "Render the visible slice of the video list."
  :view
  (flex :position (or position 'static) :left (or left '(px 0)) :top (or top '(lh 0))
        :width (or width 'stretch) :height (or height 'stretch)
        :flex-direction 'column :overflow 'hidden
        :background-color (etaf-bili-color :surface)
    (etaf-bili--view-row :for (entry items) :key (car entry)
      :position (car entry)
      :title (plist-get (cdr entry) :title)
      :author (plist-get (cdr entry) :author)
      :duration (plist-get (cdr entry) :duration)
      :views (plist-get (cdr entry) :views)
      :date (plist-get (cdr entry) :date)
      :active (= (car entry) selected)
      :on-press (lambda () (funcall on-press (car entry))))))

(etaf-define-component etaf-bili--view-fact-rows
    (&key rows)
  "Render (LABEL . VALUE) rows with values aligned to the trailing edge."
  :view
  (flex :flex-direction 'column :width 'stretch
    (flex :for (row rows) :key (car row) :height '(lh 1) :align-items 'center
          :justify-content 'space-between
      (box :height '(lh 1)
        (text :color (etaf-bili-color :muted) :font-size 16 (expr (car row))))
      (box :height '(lh 1) :text-align 'right :overflow 'hidden
        (text :color (etaf-bili-color :ink) (expr (cdr row)))))))

(etaf-define-component etaf-bili--view-detail
    (&key row position left top width height)
  "Render the selected video's details, or an empty-state hint."
  :view
  (flex :position (or position 'static) :left (or left '(px 0)) :top (or top '(lh 0))
        :width (or width etaf-bili--detail-width) :height (or height 'stretch)
        :flex-direction 'column :overflow 'hidden :padding '((lh 1) (ch 2))
        :background-color (etaf-bili-color :surface)
        :border-left (etaf-bili--border (etaf-bili-color :line))
    (flex :height '(lh 1) :align-items 'center :gap '((lh 0) (ch 1))
      (etaf-ui-icon :name 'info :set 'svg :size 0.9 :min-width 2
                    :color (etaf-bili-color :muted))
      (box :height '(lh 1) :font-weight 'bold :font-size 16
           :color (etaf-bili-color :muted) (text "视频详情")))
    (box :height '(lh 1))
    (etaf-divider)
    (box :height '(lh 1))
    (box :if (not row) :height '(lh 2) :color (etaf-bili-color :dim)
      (text "列表为空\n按 / 搜索视频"))
    (box :if row :height '(lh 3) :overflow 'hidden :font-weight 'bold
      (text (expr (or (plist-get row :title) ""))))
    (box :if row :height '(lh 1) :overflow 'hidden :font-size 16
         :color (etaf-bili-color :muted)
      (text (expr (or (plist-get row :author) ""))))
    (box :if row :height '(lh 1))
    (etaf-bili--view-fact-rows
     :if row
     :rows (list (cons "时长" (etaf-bili--clock (plist-get row :duration)))
                 (cons "播放" (or (plist-get row :views) ""))
                 (cons "发布" (or (plist-get row :date) ""))
                 (cons "BV 号" (or (plist-get row :bvid) ""))))
    (box :if row :height '(lh 1))
    (etaf-divider :if row)
    (box :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0))
    (box :height '(lh 1) :font-size 16 :color (etaf-bili-color :dim)
      (text "RET 播放 · n 下一条 · p 上一条"))))

(etaf-define-component etaf-bili--view-footer
    (&key hints position left top width height)
  "Render the fixed bottom hint row."
  :view
  (box :position (or position 'static) :left (or left '(px 0)) :top (or top '(lh 0))
       :width (or width 'stretch) :height (or height '(lh 1))
       :text-align 'center :overflow 'hidden :font-size 16
       :background-color (etaf-bili-color :panel2)
       :color (etaf-bili-color :dim)
    (text (expr hints))))

(provide 'etaf-bili-views)
;;; etaf-bili-views.el ends here
