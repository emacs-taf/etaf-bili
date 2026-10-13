# ETAF Bili manual

## Browsing

`etaf-bili-open` creates one buffer named `*Bili*` and loads the popular
feed.  The list shows each video as two lines: its title, then the author,
length, view count and publication date.  `j`/`k` (also `n`/`p` or the arrow
keys) move the selection, and the selected row is highlighted with the accent
color.  `1` loads the popular feed, `2` the all-category ranking, and `g`
reloads whichever view is current.  Clicking a row selects and plays it.

When the published viewport is wide enough (from roughly 143 character
columns), a details column shows the selected video's title, author, length,
view count, publication date and BV number, plus the key hints for playback.

`etaf-bili-close` (also `q`) unmounts the ETAF Runtime and kills the buffer.

## Searching

`/` prompts for a keyword in the minibuffer and replaces the list with the
search results; the status line shows the keyword and the result count.
Blank input is ignored.  The search endpoint requires WBI signing, which the
client performs in Lisp: the two server keys come from the nav endpoint
(cached for the session), parameters are sorted and encoded like
`encodeURIComponent`, and `w_rid` is the MD5 over the query plus the permuted
key.  `etaf-bili-wbi-query` exposes the signer for tests and scripts.

Every request carries the session's cookie jar (`buvid3` and friends); the
client seeds it with one homepage visit per session before the first API
call.  Requests that the server rejects with an HTML challenge surface as a
status-line error instead of breaking the interface.

## Playback

`RET` (`etaf-bili-play`) resolves the selected video through two API steps --
the metadata endpoint supplies the `cid`, then the play URL endpoint returns
a progressive MP4 stream -- and opens the framework's `etaf-media-viewer`
with that stream.  The source plist carries the `Referer` and `User-Agent`
headers the CDN requires; without them the CDN answers 403.

Inside the viewer, `SPC` plays or pauses, the transport bar seeks, `-10` and
`+10` step ten seconds, `n`/`p` (or the side arrows) move to the next or
previous list entry and play it, `m` toggles sound, `.` cycles the speed, and
`q` or Escape closes the viewer and returns to the list.  Playback runs in
the same buffer, so no external player window is involved.

A failed lookup (a geo-blocked video, an expired URL, a network problem)
only writes a readable message to the status line; the list stays usable.

## Scripting

The session-level functions take the session record directly, so scripts and
tests can drive the client without a buffer:

```elisp
(let ((session (etaf-bili-session-create)))      ; uses the curl client
  (etaf-bili-load-popular session)
  (etaf-bili-move session 2)
  (etaf-bili-play-selected session
                            (lambda (source) (message "%S" source)))
  (etaf-bili-session-state session))
;; => (:mode popular :status "播放：…" :items (...) :selected 2 :playback ...)
```

`etaf-bili-session-state` returns a detached plist; rows carry `:bvid`,
`:aid`, `:title`, `:author`, `:duration` (seconds), `:views` (a display
string), `:date` and `:cover`.  `etaf-bili-play-selected` calls its callback
with the stream source plist (`:url`, `:headers`, `:title`, `:bvid`,
`:duration`).

| Variable | Meaning |
| --- | --- |
| `etaf-bili-state-directory` | cookie jar directory, defaults to `~/.emacs.d/etaf-bili/` |
| `etaf-bili-request-timeout` | seconds before one request is abandoned, default 20 |
| `etaf-bili-curl-program` | curl executable used for every request |
| `etaf-bili-theme-mode` | `dark` (default) or `light`; T switches the running client |
| `etaf-bili-client-factory` | function returning the backend client; bind it to a fake in tests |

## Troubleshooting

- Search or load fails with a status-line error: check the network and that
  curl can reach `api.bilibili.com`.  A server-side HTML challenge usually
  means the request lost its cookies; the next request re-seeds them.
- Playback fails with an error from the CDN: the play URLs expire after a
  couple of hours and some videos are region-locked.  Press `RET` again to
  resolve a fresh URL.
- No picture: the viewer needs a graphical frame; on a terminal the canvas
  falls back to a density ramp.  Sound requires ffplay.
- The details column does not appear: the viewport is narrower than the
  threshold; make the window wider or hide the playlist column.
- Rows show fewer than 20 results while the status says more: the list shows
  the rows that fit the window; the selection scrolls through the rest.
