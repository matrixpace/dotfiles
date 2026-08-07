# Dotfiles

One-command Debian/Ubuntu dev bootstrap: Oh My Zsh + Powerlevel10k, Oh My Tmux, fzf, Meslo NF, Vim from source (+Python3) with gutentags/gtags for C/C++.

![Demo](assets/demo.png)

## Run

```bash
curl -fsSL https://raw.githubusercontent.com/matrixpace/dotfiles/main/install.sh | bash
```

## Update

Re-run the same script (clone the repo, or curl again). Updates APT packages, git-fetches plugins, and refreshes managed `~/.zshrc` blocks / `my_configs.vim` / `.fzf.zsh`. Skips rebuilding Vim if `/usr/local/bin/vim` already exists.

```bash
bash install.sh              # update (skip Vim rebuild)
bash install.sh --force-vim  # also rebuild Vim from source
```



## Feature overview

- **Bootstrap** — Runs APT first (including `git`) before any clones, so bare machines with only `apt` + `sudo` + `curl` work.
- **System packages** — Installs common CLI tools via APT (Git, Tmux, Zsh, `autojump`, `ag`, build toolchain, Python 3 headers, `bat`, `btop`, `xclip`, Node.js/`npm`, `clang-format`, `universal-ctags`, `global`, and related build deps for Vim).
- **Vim** — Builds Vim from source with huge features and Python 3, installs to `/usr/local`, and replaces distro Vim packages. Configures [amix/vimrc](https://github.com/amix/vimrc) with custom `my_configs.vim` (Nord, LeaderF, Tagbar, UltiSnips, EasyMotion, clipboard maps, [vim-gutentags](https://github.com/ludovicchabant/vim-gutentags) + gtags, [vim-alternate](https://github.com/ton/vim-alternate) for header ↔ source). See [Cheat sheet](#cheat-sheet).
- **Shell** — [Oh My Zsh](https://ohmyz.sh/) with [Powerlevel10k](https://github.com/romkatv/powerlevel10k) (lean config), `zsh-autosuggestions`, `tmux` (with `ZSH_TMUX_`* before `source $ZSH/oh-my-zsh.sh`), and `zsh-syntax-highlighting` (loaded last). The installer upserts `~/.zshrc` blocks with `# [dot-install …]` / `# [/dot-install …]` markers: **p10k-instant**, **auto-tmux-env**, **fzf**, **proxy** (`setp` / `unsetp` toward `127.0.0.1:12334`, with `no_proxy` / `NO_PROXY` for localhost, `.local`, cloud metadata IP, and RFC1918 private ranges), plus `[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh`. Keep those markers so re-runs refresh managed snippets without duplicating them.
- **Tmux** — [Oh My Tmux](https://github.com/gpakosz/.tmux) with local tweaks (Nord TPM plugin, vi-style keys, custom prefix `C-x`). See [Cheat sheet](#cheat-sheet).
- **Fuzzy finder** — [fzf](https://github.com/junegunn/fzf) with Zsh integration: `ag` as the default file command and `bat`-based preview where available.
- **Fonts** — MesloLGS NF from [powerlevel10k-media](https://github.com/romkatv/powerlevel10k-media), installed under your user font directory and refreshed with `fc-cache`.
- **Git & BAT** — Sets `core.editor` to the self-built Vim when present (otherwise `vim`). On Debian/Ubuntu, symlinks `batcat` to `bat` if `bat` is missing.
- **Login shell** — Attempts `chsh` to Zsh when it is not already your login shell.
- **Implementation notes** — Run as a normal user (not root) with `sudo` available. Git clones are shallow; re-runs `fetch --depth 1` + `reset --hard` to update. First install drops into a login Zsh; re-runs exit normally if your login shell is already zsh. Older installs may leave `~/.config/coc` and the APT `clangd` package; remove manually if unused (`rm -rf ~/.config/coc`, `sudo apt remove clangd`).



## Cheat sheet

`<leader>` is `,` (amix/vimrc default). Login zsh auto-starts tmux.

### Tmux (prefix `C-x`)

- `C-x` — prefix
- `C-x c` / `n` / `p` / `|` / `-` — new window / next / prev / vsplit / hsplit
- `C-x h/j/k/l` — move between panes (vi keys)
- `C-x g` — toggle synchronize-panes



### Vim

- `jk` — insert → normal
- `,tt` — Tagbar · `,y` (visual) yank · `,p` paste clipboard below line (xclip; Vim built without `+clipboard`)
- UltiSnips: `<C-j>` expand / next placeholder · `<C-k>` prev (amix snipMate `<C-j>` unbound)
- **Find (`,f*`)** — LeaderF (amix CtrlP/MRU/BufExplorer/Ack cleared): `,ff` files · `,fm` MRU · `,fb` buffers · `,ft` bufTag · `,fl` lines · `,fd` def · `,fr` refs · `,fs` other symbol · `,fg` grep · `,fG` list · `,fo` recall · `,fn` / `,fp` next / prev
- **Actions** — `,vp` edit project header path file · `,A` alternate · `,cf` format · `,tt` Tagbar
- `C-o` / `C-i` — jump list back / forward (built-in)

### C/C++ workflow

Config: `~/.vim_runtime` (`my_configs.vim`). Per-project state under `~/.cache/LeaderF/` (not in repos):

| Data | Path |
|------|------|
| gtags DB | `~/.cache/LeaderF/gtags/<encoded-root>/` |
| extra `path` dirs | `~/.cache/LeaderF/project_paths/<encoded-root>.path` (auto-created; `,vp` to edit) |

- `gf` — open include (`:find` / `'path'`); defaults `include` / `../include` / `src`; extras via `.path` lines ≡ `setlocal path+=...` (relative to project root, e.g. `../ulog/include`)
- `,fd` / `,fr` — gtags definition / references; if empty, fall back to `-s` (file-scope `static` vars)
- `,fs` — explicit other symbols · `,fg` — text grep
- `,A` — header ↔ source ([vim-alternate](https://github.com/ton/vim-alternate); `,h` remains amix previous buffer)
- `,cf` — format buffer / visual selection (`clang-format`)



### Shell / fzf

- `setp` / `unsetp` — proxy on / off (`127.0.0.1:12334`)
- fzf: `C-t` files · `C-r` history · `Alt-c` cd

