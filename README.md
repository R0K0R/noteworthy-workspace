# noteworthy-workspace

The Noteworthy frontend of [emacs-collab](../emacs-collab.el): a window layout,
a typst preview, pages and quit around a Noteworthy project, either on local
files or mirrored from a Syncworthy/Noteworthy server. GPL-3.0-or-later.

It takes over what `noteworthy-init` and noteworthy-collab's remote init did.
[noteworthy.el](../noteworthy.el) keeps the Typst editing layer, and does not
need this package.

## Commands

| Command | What |
|---|---|
| `noteworthy-workspace-open DIR [PDF]` | A **local** project. Tree, the first page in the editor, a terminal, the typst preview (an xwidget, when Emacs has them) and an optional PDF or EPUB pane. No bridge. Also `noteworthy-init`. |
| `noteworthy-syncworthy-connect SERVER [TOKEN] [FORCE] [PDF]` | A **server** project through `syncworthy_bridge`. The bridge mirrors the project into a local directory you choose (see below); buffers there sync live; tinymist previews the mirror locally. |
| `noteworthy-workspace-quit` | `emacs-collab-layout-quit` (save offer, preview, language server, bridge, buffers, PDF, terminal, tree) plus stopping the typst-preview servers. Also `noteworthy-quit`. |
| `noteworthy-new-page` (`M-t n`) | A page, or a chapter, in `hierarchy.json` and `content/`. On a server project the files reach the server too. |
| `noteworthy-refresh-preview` (`M-t r`) | Restart the preview with the folder lists as they are now. |
| `noteworthy-toggle-log` (`M-t l`) | The terminal pane shows the typst log, and back. |
| `noteworthy-workspace-status` | Connection state, documents, peers. |

`M-t n/r/q/l` work in Typst buffers (`noteworthy-typst-mode-map`) and, through
`noteworthy-workspace-mode`, in any other file of the project.

## Setup

```elisp
(require 'noteworthy-workspace)
(setq noteworthy-workspace-terminal-shell (list (getenv "SHELL")))  ; also noteworthy-terminal-shell
```

For a server project: `syncworthy_bridge` on `PATH` (or set
`noteworthy-workspace-bridge-command`), and, if the server wants a token, a line
in auth-source whose host is the server's:

```
machine 127.0.0.1 port 8011 login token password SECRET
```

### Where the mirror lives

Where the local copy lives is your choice. The first time a project is
opened Emacs asks for a directory (`emacs-collab-read-mirror-dir`), created
if missing and remembered per project, so later opens go there without a
prompt; `C-u` before the command asks again, starting from the remembered
directory, and `M-x emacs-collab-forget-mirror` drops a remembered choice.
The prompt starts at `noteworthy-workspace-mirror-directory`/HOST-PORT/ if you set that option
(a suggestion only; it has no default),
else `emacs-collab-mirror-root`/<service>/<project>, else the current directory. A
`.emacs-collab` marker in the directory names the project it mirrors; a
directory marked as another project is refused, a non-empty unmarked one
only draws a warning.

The mirror directory should be on a persisted path.

## Layout

Built by `emacs-collab-layout-build`: windows have the parameter
`emacs-collab-role` (`editor`, `tree`, `terminal`, `preview`, `pdf`), pane sizes are
remembered per project in `emacs-collab-layout-state-file`, and
`emacs-collab-layout-select-*` jump between them. The old
`.noteworthy-layout` files are no longer read.

## Options

`noteworthy-workspace-preview` (`auto`, nil or a function),
`noteworthy-workspace-layout-args`, `noteworthy-workspace-bridge-command`,
`noteworthy-workspace-mirror-directory`, `noteworthy-workspace-display-name`,
`noteworthy-workspace-poll-secs`, `noteworthy-workspace-unsynced-regexp`.

`noteworthy-workspace-typst-input-flags ROOT` gives the `--input=k=v` flags
for tinymist's `typstExtraArgs`, for a language server configuration.

## Tests

```
NWS_TEST_PROJECT=/copy/of/a/noteworthy/project \
  emacs --batch -L ../emacs-collab.el -L ../noteworthy.el -L . -L test \
        -l test/noteworthy-workspace-test.el -f ert-run-tests-batch-and-exit
```

`test/noteworthy-workspace-live.el` needs a server on a scratch copy and the built
bridge; see its header.
