;;; etaf-bili.el --- Bilibili video client built with ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf "0.2.1") (etaf-ui "0.1.0"))
;; Keywords: multimedia, ui
;; URL: https://github.com/emacs-taf/etaf-bili

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-bili) after adding this repository
;; and the ETAF, ETAF UI, Ebox and ECSS roots to `load-path'.  The client
;; browses Bilibili in one ETAF buffer: a searchable video list (the popular
;; feed by default, the all-category ranking or search results), a details
;; column for the selected row, and playback of the selected video inside the
;; framework's `etaf-media-viewer' Component.  Streams are resolved through
;; the web API and played with the Referer and User-Agent headers the CDN
;; requires; curl performs every request asynchronously, so the interface
;; never blocks.
;;
;; A session is one buffer (`*Bili*') with one backend client and one
;; session record.  The commands below drive it, and the session-level
;; functions (also listed here) take the session record directly so tests and
;; scripts can drive them headless.  The default keymap binds the commands:
;; j/k or n/p select a row, RET plays it, / searches, 1 loads the popular
;; feed, 2 the ranking, g refreshes, T toggles the appearance, q closes.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list;
;; implementations and precise docstrings remain beside their definitions.
;;
;; Function: etaf-bili-open ()
;;;###autoload (autoload 'etaf-bili-open "etaf-bili" nil t)
;; Open the client in its own buffer and return that buffer.
;; The popular feed starts loading immediately.
;;
;; Function: etaf-bili-close ()
;;;###autoload (autoload 'etaf-bili-close "etaf-bili" nil t)
;; Tear down the runtime and kill the client buffer.
;;
;; Function: etaf-bili-next ()
;; Select and focus the next video; clamp at the last item.
;;
;; Function: etaf-bili-previous ()
;; Select and focus the previous video; clamp at the first item.
;;
;; Function: etaf-bili-play ()
;; Resolve the selected video's stream and open it in the media viewer.
;;
;; Function: etaf-bili-search (session keyword)
;; Search videos for KEYWORD and show the results in SESSION.
;; Empty or whitespace-only keywords are ignored.
;;
;; Function: etaf-bili-search-prompt ()
;; Begin native editing of the in-page SearchField. Return submits the query;
;; Escape keeps its draft. No minibuffer or additional window is opened.
;;
;; Function: etaf-bili-details ()
;; Open the selected video's metadata in a catalog Drawer. Escape closes it
;; and restores focus; no permanently empty side column is reserved.
;;
;; Function: etaf-bili-popular ()
;; Load the currently popular videos.
;;
;; Function: etaf-bili-ranking ()
;; Load the all-category ranking.
;;
;; Function: etaf-bili-refresh ()
;; Command: reload the current buffer's view.
;;
;; Function: etaf-bili-toggle-theme ()
;; Switch the client between the dark and light palette.
;;
;; Function: etaf-bili-session-create (&key client)
;; Create a session with the backend CLIENT.
;; CLIENT defaults to `etaf-bili-client-factory' when bound, otherwise the
;; default curl client.  The session starts empty on the popular feed.
;;
;; Function: etaf-bili-session-state (session)
;; Return SESSION's public state as a detached plist.
;; Keys are `:mode', `:keyword', `:status', `:loading', `:items', `:selected'
;; `:playback', `:error' and `:play-loading'; each `:items' row carries the fields documented on
;; `etaf-bili-selected-row'.
;;
;; Function: etaf-bili-load-popular (session)
;; Load the popular feed into SESSION.
;;
;; Function: etaf-bili-load-ranking (session)
;; Load the all-category ranking into SESSION.
;;
;; Function: etaf-bili-reload (session)
;; Reload SESSION's current view (popular, ranking or the last search).
;;
;; Function: etaf-bili-move (session delta)
;; Move SESSION's selection by DELTA rows, clamped to the list.
;;
;; Function: etaf-bili-selected-row (session)
;; Return SESSION's selected row plist, or nil when the list is empty.
;; Rows carry `:bvid', `:aid', `:title', `:author', `:duration' (seconds),
;; `:views' (a display string), `:date' and `:cover'.
;;
;; Function: etaf-bili-play-selected (session on-ready)
;; Resolve the selected video's stream and call ON-READY with a source plist.
;; The plist is an `etaf-video' source (`:url' plus the CDN `:headers') with
;; `:title', `:bvid' and `:duration'; failures only change SESSION's status.
;;
;; Function: etaf-bili-make-client (&key state-directory timeout)
;; Create the default curl-backed backend client.
;; STATE-DIRECTORY holds the cookie jar; both keywords default to the
;; corresponding defcustoms.  The client is returned as a plist which
;; `etaf-bili-client-call' accepts; a plain function accepting
;; (REQUEST CALLBACK) may be used in its place.
;;
;; Function: etaf-bili-wbi-query (params mixin-key &optional wts)
;; Sign PARAMS with MIXIN-KEY and return the query string with `w_rid'.
;; A `wts' timestamp (defaulting to the current time) is appended, keys are
;; sorted, values encode like `encodeURIComponent', and the MD5 covers the
;; query plus the mixin key.  Exposed so the signature contract is testable
;; without the network; a missing key signals `etaf-bili-error'.
;;
;; Function: etaf-bili-parse-videos (data)
;; Parse a video list response DATA into row plists.
;; DATA is the `data' object of a popular, ranking or search response parsed
;; by `json-parse-string' with an alist object type; rows match the contract
;; of `etaf-bili-selected-row'.
;;
;; Function: etaf-bili-client-call (client request callback)
;; Perform one backend REQUEST and deliver the result to CALLBACK.
;; REQUEST is a plist with an `:op': `(:op :popular :page N)',
;; `(:op :ranking)', `(:op :search :keyword K :page N)',
;; `(:op :video :bvid B)', `(:op :play :bvid B)' or `(:op :cover :url U)'.
;; The cover operation accepts Bilibili image CDN URLs and returns a local
;; cached image path. Downloads are capped at 2 MiB. CALLBACK receives
;; `(:ok DATA)' or `(:error MESSAGE :hint HINT)'.  The `:play' operation
;; chains the metadata and stream steps and returns the stream source.
;;
;; Variable: etaf-bili-client-factory
;; Function returning the backend client used by new sessions.
;; Nil (the default) selects the curl client; tests bind this to a fake.
;;
;; Error: etaf-bili-error
;; Signaled for client-level failures such as unusable WBI keys or a
;; non-JSON response body.
;;
;; Variable: etaf-bili-state-directory
;; Directory holding the client's cookie jar and other local state.
;;
;; Variable: etaf-bili-request-timeout
;; Seconds before one backend request is abandoned (default 20).
;;
;; Variable: etaf-bili-curl-program
;; curl executable used for every request.
;;
;; Variable: etaf-bili-theme-mode
;; New-session appearance: `dark' (default) or `light', independent of
;; Emacs's theme.  Press T to switch the running client.

;;; Code:

;;;###autoload
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name "lisp"
                                 (file-name-directory
                                  (or load-file-name
                                      (bound-and-true-p byte-compile-current-file)
                                      buffer-file-name)))))

(require 'etaf-bili-app)

(provide 'etaf-bili)
;;; etaf-bili.el ends here
