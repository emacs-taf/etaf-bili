# etaf-bili

A Bilibili client that runs inside one Emacs buffer, built on
[ETAF](https://github.com/emacs-taf/etaf).  It browses the popular feed, the
all-category ranking and video search, shows the selected video's details,
and plays the selected video with sound through ETAF's media viewer
Component.  Streams are resolved through the web API with the Referer and
User-Agent headers the CDN requires; curl performs every request
asynchronously, so the interface never blocks.

The client at a wide frame:

![The client at a wide frame](examples/etaf-bili-wide.png)

## Capabilities

- The popular feed loads when the buffer opens; `1` reloads it, `2` loads the
  all-category ranking, and `g` refreshes whatever view is current.
- Search through the web API's signed endpoint: `/` prompts for a keyword and
  the result list replaces the current view.  WBI signing (sorted parameters,
  `encodeURIComponent` encoding, MD5 over the query plus the permuted server
  key) is implemented in Lisp.
- A details column shows the selected row's author, length, view count,
  publication date and BV number as soon as the viewport is wide enough.
- `RET` resolves the stream and opens it in the framework's
  `etaf-media-viewer`: video plays in the buffer with a transport bar, sound,
  seeking and speed control.  `n`/`p` inside the viewer move to the next or
  previous list entry and play it.
- Both appearances are first-class: a four-step depth palette keeps the
  columns separated in dark and light, and `T` switches the running client.
- Row selection is instant (`j`/`k` or `n`/`p`), clicks on a row select and
  play it, and the list scrolls under the selection.
- The cookie jar lives under `etaf-bili-state-directory`; the homepage visit
  that seeds `buvid3` runs once per session and every request reuses the jar.

## Prerequisites

| Requirement | Why | Check |
| --- | --- | --- |
| Emacs 29.1 or newer | the ETAF runtime | `emacs --version` |
| `etaf`, `etaf-ui`, `ebox`, `ecss` | the framework; each root entry must be on `load-path` | every checkout is readable |
| curl | every web API request | `curl --version` |
| ffmpeg, ffprobe, ffplay | playback (through `etaf-video`) | `ffmpeg -version` |

## Installation

```elisp
(add-to-list 'load-path "/path/to/ecss")
(add-to-list 'load-path "/path/to/ebox")
(add-to-list 'load-path "/path/to/etaf")
(add-to-list 'load-path "/path/to/etaf-ui")
(add-to-list 'load-path "/path/to/etaf-bili")
(require 'etaf-bili)

(global-set-key (kbd "C-c b") #'etaf-bili-open)
```

## Minimal example

```elisp
(etaf-bili-open)                        ; browse the popular feed
(etaf-bili-search-prompt)               ; search for a keyword
(etaf-bili-ranking)                     ; switch to the ranking
(etaf-bili-session-state               ; read the session as plain data
 (etaf-bili-session-create))
```

## Keys

| Key | Action |
| --- | --- |
| `j` / `k` (or `n` / `p`) | select the next / previous row |
| `RET` | play the selected video |
| `/` | search videos |
| `1` / `2` | popular feed / all-category ranking |
| `g` | refresh the current view |
| `T` | switch dark/light appearance |
| `?` | list every keybinding |
| `q` | close the client |

Inside the media viewer, `SPC` plays or pauses, `-10`/`+10` seek, `n`/`p`
move to the next/previous list entry, `m` toggles sound, `.` cycles the
speed and `q`/Escape closes the viewer and returns to the list.

## Checks

```sh
make check    # structure + byte compilation (warnings as errors) + acceptance + API boundary
make test     # the public acceptance scenarios only
```

The acceptance suite injects a fake backend through
`etaf-bili-client-factory`, so it needs no network: the model's
load/move/play flows run against scripted replies, and WBI signing and
response parsing are asserted on fixed inputs.

## Documentation

- [The manual](docs/manual.md): browsing, searching, playback, scripting,
  variables and troubleshooting.
- [Architecture](docs/architecture.md): module responsibilities, data flow,
  invariants and the ownership boundary with ETAF.
- [The root entry Commentary](etaf-bili.el): the authoritative list of
  supported functions and variables.
