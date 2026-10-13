# Changelog

## Unreleased

### Added

- Browsing: the popular feed loads on open, `1`/`2` switch between it and
  the all-category ranking, `g` refreshes, and the selection moves with
  `j`/`k`, `n`/`p` or the arrow keys with a mouse-click target per row.
- Search through the signed web API endpoint: `/` prompts for a keyword and
  replaces the list.  WBI signing (sorted parameters, `encodeURIComponent`
  encoding, MD5 over the query plus the permuted server key) is implemented
  in Lisp and covered by an acceptance test.
- A details column (from roughly 143 character columns) showing the selected
  video's author, length, view count, publication date and BV number.
- Playback in the same buffer through ETAF's `etaf-media-viewer`: `RET`
  resolves the stream (metadata chain plus the Referer and User-Agent headers
  the CDN requires) and opens the viewer with its transport bar, sound,
  seeking and speed control; `n`/`p` inside the viewer move to the next or
  previous list entry and play it.
- Dark and light appearances over one four-step depth palette; `T` switches
  the running client.
- A cookie jar under `etaf-bili-state-directory`, seeded once per session
  with a homepage visit (`buvid3`), reused by every request.
- The session is drivable headless: `etaf-bili-session-create`,
  `etaf-bili-session-state` and the load/move/play actions take the session
  record directly, with a fake backend injectable through
  `etaf-bili-client-factory`.
