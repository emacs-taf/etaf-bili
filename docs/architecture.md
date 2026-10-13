# ETAF Bili architecture

## Responsibilities

`etaf-bili` is an application.  It owns the buffer, the session state (mode,
rows, selection, status), the keymap and the two protocol details that no
provider covers: WBI signing and the CDN headers.  Playback, the transport
bar, image frames and sound belong to ETAF's `etaf-media-viewer` and
`etaf-video` Components, driven through their public interfaces; no framework
mechanism is re-implemented here.

| Module | Owns |
| --- | --- |
| `etaf-bili-service` | the only outside world: curl requests, the cookie jar, WBI signing, JSON parsing and the request/response contract |
| `etaf-bili-model` | the session record, its refs and every action (load, search, move, play); no buffer and no timer |
| `etaf-bili-views` | pure projections: header, row, list, details and footer Components |
| `etaf-bili-theme` | the four-step palette for both appearances and the ETAF UI token projection |
| `etaf-bili-app` | the buffer, the keymap, the mount/unmount lifecycle, the shell assembly and the media-viewer binding |

The root entry re-exports the supported subset; everything unlisted is
internal.

## Data flow

1. `etaf-bili-open` creates a session (client plus refs), displays the buffer
   and mounts the shell: header, list, optional details column, hint footer
   and -- when a video is open -- the media viewer.
2. A load action bumps the session's request token, marks the session
   loading, and calls the backend.  When the reply arrives with its token
   still current, the rows and status replace the previous ones; a stale
   reply is dropped, so a fast second search cannot be overwritten by the
   first one's answer.
3. Requests run through curl as child processes with a per-request timeout.
   The first request of a session first seeds the cookie jar with a homepage
   visit and caches the two WBI keys from the nav endpoint; signed endpoints
   add `w_rid` to their query.  JSON is parsed into alists (keys are symbols
   in `json.el`) and normalized once into row plists.
4. `RET` runs the two-step play chain inside the service -- metadata for the
   `cid`, then the play URL -- and hands the caller an `etaf-video` source
   plist with the CDN headers.  The application stores it in the playback
   ref; the viewer opens, and the native Component decodes it.  `n`/`p`
   inside the viewer move the selection and replace the source prop, which
   rebuilds the Component session at the new stream.
5. The list renders only the rows that fit the measured body (two lines per
   row), keeping the selection centered; the window size hook republishes the
   viewport on resize.

## Invariants

- **One owner per fact.** The service owns protocol details and parsing; the
  model owns session state; the views own presentation; the application owns
  the buffer and keys.  Playback state belongs to the media viewer and the
  native Component, never to this application.
- **Replies are token-checked.** Every asynchronous reply carries the request
  token it was started with; only the latest request may change the rows or
  the status.  This is what makes rapid searches safe.
- **Signing follows the server.** WBI signing sorts parameters, encodes
  values like `encodeURIComponent` (space becomes `%20`, not `+`), and hashes
  query plus mixin key.  The `etaf-bili-wbi-query` contract is covered by an
  acceptance test with fixed inputs, because a mismatch surfaces only as a
  server-side challenge.
- **The CDN needs its headers.** Play URLs are resolved per playback and
  carry `Referer` and `User-Agent`; without them the CDN answers 403.  URLs
  expire, so they are never stored beyond the current playback.
- **Failures stay on the status line.** Network errors, non-JSON responses
  and API error codes all end as a readable message; the list and the session
  survive, and no partial playback state is created.
- **Cookies live in the state directory.** `etaf-bili-state-directory` holds
  the jar; a shared or unwritable directory degrades to unauthenticated
  requests, which the unsigned endpoints still serve.

## Measured behavior

The list is a retained publication: a selection change repaints the rows
around the move, not the whole application.  Rendering cost is dominated by
the row count that fits the window; the two-line row budget keeps the list
aligned with the measured body, and no numbers here substitute for a fresh
GUI run.
