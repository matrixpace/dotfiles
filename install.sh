#!/usr/bin/env bash
# Debian/Ubuntu bootstrap: apt, Vim (+Python3) from source, amix/vimrc + plugins, fzf,
# Oh My Tmux, Oh My Zsh + p10k, Meslo fonts, git editor + bat symlink.
# Re-run to update (skips Vim rebuild unless --force-vim).
#
# Usage: bash install.sh [--force-vim]  (non-root; needs sudo, curl)

set -euo pipefail

readonly NC='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BL='\033[0;34m'
readonly VIM_SRC="${XDG_DATA_HOME:-$HOME/.local/share}/dotfiles/vim-source"
readonly MESLO_SRC="${XDG_DATA_HOME:-$HOME/.local/share}/dotfiles/powerlevel10k-media"
readonly VIM_RT="$HOME/.vim_runtime"

FORCE_VIM=0

log()  { printf '%b\n' "${BL}[INFO]${NC} $*"; }
ok()   { printf '%b\n' "${GREEN}[OK]${NC}   $*"; }
warn() { printf '%b\n' "${YELLOW}[WARN]${NC} $*"; }
die()  { printf '%b\n' "${RED}[ERR]${NC}  $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] && die "Do not run as root. Use: bash $0"
command -v apt-get &>/dev/null || die "Requires apt-get (Debian/Ubuntu)."

run_sudo() {
  command -v sudo &>/dev/null || die "sudo is required for privileged steps (apt, make install, chsh, etc.)."
  sudo "$@"
}

download() {
  command -v curl &>/dev/null || die "Need curl"
  curl -fsSL --connect-timeout 25 --retry 5 --retry-delay 2 -o "$2" "$1"
}

# Optional 3rd arg: branch (e.g. release).
ensure_git_repo() {
  local url="$1" path="$2" branch="${3:-}" ref
  if [[ ! -d "$path/.git" ]]; then
    rm -rf "$path"
    mkdir -p "$(dirname "$path")"
    git clone ${branch:+--branch "$branch"} --depth=1 "$url" "$path"
    return 0
  fi
  if [[ -n "$branch" ]]; then
    ref="$branch"
  else
    ref="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    [[ -z "$ref" || "$ref" == "HEAD" ]] && ref="HEAD"
  fi
  if ! git -C "$path" fetch --depth 1 origin "$ref" || ! git -C "$path" reset --hard FETCH_HEAD; then
    warn "git update failed: $path"
  fi
}

# Remove a managed # [dot-install name] ... # [/dot-install name] region (or legacy start-only block).
remove_dot_install_block() {
  local file="$1" name="$2"
  local start="# [dot-install $name]" end="# [/dot-install $name]"
  local tmp
  tmp="$(mktemp)"
  awk -v start="$start" -v end="$end" -v name="$name" '
    function legacy_end(line,   n) {
      if (name == "p10k-instant") return (line == "fi")
      if (name == "auto-tmux-env") return (line ~ /^ZSH_TMUX_AUTOQUIT=/)
      if (name == "fzf") return (line ~ /source ~\/\.fzf\.zsh/)
      if (name == "proxy") {
        if (line ~ /^unset HTTP_PROXY/) { proxy_unset=1; return 0 }
        if (proxy_unset && line == "}") return 1
      }
      return 0
    }
    $0 == start { skip=1; next }
    skip {
      if ($0 == end) { skip=0; next }
      if (legacy_end($0)) { skip=0; next }
      if ($0 ~ /^# \[\/dot-install /) { skip=0; next }
      if ($0 ~ /^# \[dot-install /) { skip=0; print; next }
      next
    }
    { print }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

# Upsert managed block with start/end markers. Optional 4th arg: insert before this exact line.
upsert_marked() {
  local file="$1" name="$2" body="$3" before="${4:-}"
  [[ -f "$file" ]] || return 0
  remove_dot_install_block "$file" "$name"
  local block tmp ln
  block="# [dot-install $name]
${body}
# [/dot-install $name]"
  if [[ -n "$before" ]] && grep -qF "$before" "$file"; then
    ln="$(grep -nF "$before" "$file" | head -1 | cut -d: -f1)"
    tmp="$(mktemp)"
    head -n "$((ln - 1))" "$file" >"$tmp"
    printf '%s\n' "$block" >>"$tmp"
    tail -n "+${ln}" "$file" >>"$tmp"
    mv "$tmp" "$file"
  elif [[ "$name" == "p10k-instant" ]]; then
    tmp="$(mktemp)"
    {
      printf '%s\n' "$block"
      cat "$file"
    } >"$tmp"
    mv "$tmp" "$file"
  else
    printf '%s\n' "$block" >>"$file"
  fi
}

append_once() {
  local file="$1" marker="$2" block="$3"
  [[ -f "$file" ]] || return 0
  grep -Fq "$marker" "$file" && return 0
  printf '%s\n' "$block" >>"$file"
}

install_packages() {
  log "APT packages..."
  run_sudo apt-get update -qq
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git tmux zsh autojump silversearcher-ag ripgrep \
    build-essential cmake libtool pkg-config python3-dev python3-venv libncurses-dev \
    iproute2 iputils-ping cloc bat figlet btop ca-certificates unzip xclip \
    nodejs npm clang-format universal-ctags global python3-pygments
  ok "APT done"
}

install_meslo_fonts() {
  log "MesloLGS NF fonts..."
  local dir="${XDG_DATA_HOME:-$HOME/.local/share}/fonts/meslolgs-nf"
  mkdir -p "$dir"
  ensure_git_repo https://github.com/romkatv/powerlevel10k-media.git "$MESLO_SRC"
  local n=0 f
  shopt -s nullglob
  for f in "$MESLO_SRC"/*.ttf; do
    cp "$f" "$dir"/ && ((++n)) || true
  done
  shopt -u nullglob
  [[ "$n" -gt 0 ]] || warn "No .ttf copied; check network or $MESLO_SRC"
  command -v fc-cache &>/dev/null && fc-cache -f "$dir" 2>/dev/null || true
  ok "Fonts -> $dir"
}

build_vim_from_source() {
  if [[ -x /usr/local/bin/vim && "$FORCE_VIM" -eq 0 ]]; then
    ok "vim present, skip build (use --force-vim to rebuild)"
    return 0
  fi
  log "Vim from source (+python3)..."
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    vim vim-nox vim-tiny vim-athena vim-gtk vim-gnome vim-gui-common 2>/dev/null || true
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || true
  ensure_git_repo https://github.com/vim/vim.git "$VIM_SRC"
  local py3dir
  py3dir="$(python3-config --configdir 2>/dev/null)" || die "python3-dev (python3-config) missing"
  (
    cd "$VIM_SRC"
    ./configure --with-features=huge --enable-multibyte \
      --enable-python3interp=yes --with-python3-config-dir="$py3dir" --prefix=/usr/local
    make -j"$(nproc)"
  )
  run_sudo make -C "$VIM_SRC" install
  run_sudo ldconfig 2>/dev/null || true
  ok "/usr/local/bin/vim"
}

install_oh_my_tmux() {
  log "Oh My Tmux..."
  local dest="$HOME/.tmux" f="$HOME/.tmux.conf.local"
  ensure_git_repo https://github.com/gpakosz/.tmux.git "$dest"
  ln -sf "$dest/.tmux.conf" "$HOME/.tmux.conf"
  [[ -f "$f" ]] || cp "$dest/.tmux.conf.local" "$f"
  if [[ -f "$f" ]]; then
    sed -i \
      -e '/^tmux_conf_theme=enabled$/s/enabled/disabled/' \
      -e '/^#set -g status-keys vi$/s/^#//' \
      -e '/^#set -g mode-keys vi$/s/^#//' \
      -e '/^# set -gu prefix2$/s/^# //' \
      -e '/^# unbind C-a$/s/^# //' \
      -e '/^# unbind C-b$/s/^# //' \
      -e 's/^# set -g prefix C-a$/set -g prefix C-x/' \
      -e 's/^# bind C-a send-prefix$/bind C-x send-prefix/' \
      -e 's/^set -g prefix C-a$/set -g prefix C-x/' \
      -e 's/^bind C-a send-prefix$/bind C-x send-prefix/' \
      "$f"
    if ! grep -Fq "nordtheme/tmux" "$f"; then
      local tmp
      tmp="$(mktemp)"
      if awk '
        /^# -- custom variables/ && !i { print "set -g @plugin '\''nordtheme/tmux'\''"; print "bind-key g setw synchronize-panes"; i=1 }
        { print }
      ' "$f" >"$tmp"; then
        mv "$tmp" "$f"
      else
        rm -f "$tmp"
        die "awk failed while patching $f"
      fi
      grep -Fq "nordtheme/tmux" "$f" || printf '\n%s\n%s\n' \
        "set -g @plugin 'nordtheme/tmux'" "bind-key g setw synchronize-panes" >>"$f"
    fi
  fi
  ok "tmux"
}

install_fzf() {
  log "fzf..."
  ensure_git_repo https://github.com/junegunn/fzf.git "$HOME/.fzf"
  "$HOME/.fzf/install" --bin
  cat >"$HOME/.fzf.zsh" <<'EOF'
export PATH="$HOME/.fzf/bin:$PATH"
export FZF_DEFAULT_COMMAND='ag -i --hidden -l -a -g ""'
export FZF_DEFAULT_OPTS="--height 80% --layout reverse --preview '(bat --style=numbers --color=always {} || cat {}) 2> /dev/null | head -500'"
[[ -f ~/.fzf/shell/completion.zsh ]] && source ~/.fzf/shell/completion.zsh
[[ -f ~/.fzf/shell/key-bindings.zsh ]] && source ~/.fzf/shell/key-bindings.zsh
EOF
  ok "fzf"
}

install_zsh_stack() {
  log "Oh My Zsh + p10k..."
  export RUNZSH=no CHSH=no
  if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    local inst
    inst="$(mktemp)"
    download "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh" "$inst"
    sh "$inst" --unattended
    rm -f "$inst"
  fi
  local c="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}" z="$HOME/.zshrc"
  ensure_git_repo https://github.com/romkatv/powerlevel10k.git "$c/themes/powerlevel10k"
  ensure_git_repo https://github.com/zsh-users/zsh-autosuggestions "$c/plugins/zsh-autosuggestions"
  ensure_git_repo https://github.com/zsh-users/zsh-syntax-highlighting.git "$c/plugins/zsh-syntax-highlighting"

  upsert_marked "$z" p10k-instant '# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi'

  if [[ -f "$z" ]]; then
    grep -qE '^[[:space:]]*ZSH_THEME=' "$z" \
      && sed -i 's/^[[:space:]]*ZSH_THEME=.*/ZSH_THEME="powerlevel10k\/powerlevel10k"/' "$z" \
      || printf '%s\n' 'ZSH_THEME="powerlevel10k/powerlevel10k"' >>"$z"
    grep -qE '^[[:space:]]*plugins=\(' "$z" \
      && sed -i 's/^[[:space:]]*plugins=(.*)/plugins=(git autojump zsh-autosuggestions tmux zsh-syntax-highlighting)/' "$z" \
      || printf '%s\n' 'plugins=(git autojump zsh-autosuggestions tmux zsh-syntax-highlighting)' >>"$z"
  fi

  upsert_marked "$z" auto-tmux-env 'ZSH_TMUX_AUTOSTART=true
ZSH_TMUX_AUTOCONNECT=false
ZSH_TMUX_AUTOQUIT=false' 'source $ZSH/oh-my-zsh.sh'

  [[ -f "$HOME/.p10k.zsh" ]] \
    || download "https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-lean.zsh" "$HOME/.p10k.zsh"
  append_once "$z" 'source ~/.p10k.zsh' '[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh'

  upsert_marked "$z" fzf '[[ -f ~/.fzf.zsh ]] && source ~/.fzf.zsh'

  upsert_marked "$z" proxy '# Bypass list: applied on every interactive zsh startup so WSL/Windows-injected http_proxy also skips local/LAN/metadata.
zsh_no_proxy_list="localhost,127.0.0.1,::1,.local,169.254.169.254,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
zsh_apply_no_proxy_bypass() {
    export no_proxy="$zsh_no_proxy_list"
    export NO_PROXY="$no_proxy"
}
zsh_apply_no_proxy_bypass

setp() {
    local proxy_host="127.0.0.1"
    local proxy_port="12334"
    local proxy_url="http://${proxy_host}:${proxy_port}"
    export HTTP_PROXY="$proxy_url" HTTPS_PROXY="$proxy_url"
    export http_proxy="$proxy_url" https_proxy="$proxy_url"
    zsh_apply_no_proxy_bypass
}

unsetp() {
    unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
}'
  ok "zsh"
}

install_vim_stack() {
  log "Vim: amix/vimrc + my_plugins..."
  ensure_git_repo https://github.com/amix/vimrc.git "$VIM_RT"
  bash "$VIM_RT/install_awesome_vimrc.sh"
  local mp="$VIM_RT/my_plugins"
  mkdir -p "$mp"
  ensure_git_repo https://github.com/nordtheme/vim.git "$mp/nordtheme"
  ensure_git_repo https://github.com/Yggdroot/LeaderF.git "$mp/LeaderF"
  ensure_git_repo https://github.com/preservim/tagbar.git "$mp/tagbar"
  ensure_git_repo https://github.com/easymotion/vim-easymotion.git "$mp/vim-easymotion"
  ensure_git_repo https://github.com/SirVer/ultisnips.git "$mp/ultisnips"
  ensure_git_repo https://github.com/ludovicchabant/vim-gutentags.git "$mp/vim-gutentags"
  ensure_git_repo https://github.com/ton/vim-alternate.git "$mp/vim-alternate"
  ln -sf "$HOME/.fzf" "$mp/fzf"
  # Drop former coc/clangd stack if present from older installs
  rm -rf "$mp/coc.nvim"
  rm -f "$VIM_RT/coc-settings.json"

  cat >"$VIM_RT/my_configs.vim" <<'EOF'
" dot-install: managed by install.sh (overwritten each run)

set nu rnu nowrap nowrapscan noshowmode cc=81
set hidden
set updatetime=300
set signcolumn=yes

set cursorline
let g:nord_cursor_line_number_background = 1
colorscheme nord

" Soft CursorLine bar + frost CursorLineNr; keep Visual visible across ColorScheme
function! s:DotCursorline() abort
  highlight CursorLine   cterm=NONE ctermbg=236 guibg=#3B4252
  highlight CursorLineNr cterm=bold ctermfg=14 guifg=#88C0D0 guibg=#3B4252
  highlight Visual ctermbg=238 ctermfg=NONE guibg=#3B4252 guifg=NONE
endfunction
augroup dot_cursorline
  autocmd!
  autocmd ColorScheme * call s:DotCursorline()
augroup END
call s:DotCursorline()

let g:lightline.colorscheme = 'nord'
let g:lightline.active.left = [
    \ [ 'mode', 'paste' ],
    \ [ 'fugitive', 'readonly', 'relativepath', 'modified' ] ]
let g:lightline.active.right = [
    \ [ 'lineinfo' ],
    \ [ 'percent' ],
    \ [ 'fileformat', 'fileencoding', 'filetype' ] ]
let g:lightline.separator = { 'left': '', 'right': '' }
let g:lightline.component.lineinfo = '%3l,%-2c'
let g:lightline.component.percent = '%3p%%/%L'

" Free amix maps that overlap LeaderF / UltiSnips
try | unmap <leader>f | catch | endtry
try | unmap <leader>j | catch | endtry
try | unmap <leader>b | catch | endtry
try | unmap <leader>o | catch | endtry
try | unmap <leader>g | catch | endtry
try | iunmap <C-j> | catch | endtry
try | sunmap <C-j> | catch | endtry
let g:ctrlp_map = ''

inoremap jk <Esc>

nnoremap <silent> <leader>tt :TagbarToggle<CR>
let g:tagbar_position = 'left'

let g:Lf_HideHelp = 1
let g:Lf_UseCache = 1
let g:Lf_UseVersionControlTool = 0
let g:Lf_IgnoreCurrentBufferName = 1
let g:Lf_WindowPosition = 'popup'
let g:Lf_PreviewInPopup = 1
let g:Lf_StlSeparator = { 'left': "", 'right': "" }
let g:Lf_ShowDevIcons = 1
let g:Lf_PopupShowStatusline = 0
let g:Lf_ShowHidden = 1
let g:Lf_WildIgnore = {
    \ 'dir': ['.svn','.git','.hg'],
    \ 'file': ['*.sw?','~$*','*.bak','*.exe','*.o','*.so','*.py[co]']
    \}
if executable('rg')
  let g:Lf_ExternalCommand = 'rg --files --hidden --follow --glob "!.git/*" %s'
else
  let g:Lf_ExternalCommand = 'ag -g "%s" -i -a --hidden'
endif
let g:Lf_PopupColorscheme = 'nord'
let g:Lf_StlColorscheme = 'nord'

" LeaderF: all find/jump under <leader>f*
let g:Lf_ShortcutF = '<leader>ff'
nnoremap <silent> <leader>fm :Leaderf mru<CR>
nnoremap <silent> <leader>fb :Leaderf buffer<CR>
nnoremap <silent> <leader>ft :Leaderf bufTag<CR>
nnoremap <silent> <leader>fl :Leaderf line --bottom --cword --regexMode<CR>

" Shared project helpers (gtags probe + per-project path files)
let s:dot_path_dir = expand('~/.cache/LeaderF/project_paths')
let g:gutentags_modules = ['ctags', 'gtags_cscope']
let g:gutentags_cache_dir = expand('~/.cache/LeaderF/gtags')
let g:gutentags_ctags_exclude = ['.git', 'build', 'third_party']

function! s:DotProjectRoot() abort
  if !empty(get(b:, 'gutentags_root', ''))
    return b:gutentags_root
  endif
  let dir = expand('%:p:h')
  " LeaderF preview buffers are named /Lf_preview_*; dirname is /
  if dir ==# '/' || bufname('%') =~# '^/Lf_preview_'
    return getcwd()
  endif
  if exists('*gutentags#get_project_root')
    try
      return gutentags#get_project_root(dir)
    catch /^gutentags:/
      return getcwd()
    endtry
  endif
  return getcwd()
endfunction

function! s:DotProjectKey(root) abort
  return substitute(substitute(a:root, '^/', '', ''), '/', '-', 'g')
endfunction

function! s:DotPathFile(root) abort
  return s:dot_path_dir . '/' . s:DotProjectKey(a:root) . '.path'
endfunction

function! s:DotEnsurePathFile(root) abort
  call mkdir(s:dot_path_dir, 'p')
  let f = s:DotPathFile(a:root)
  if !filereadable(f)
    call writefile([
      \ '# Extra header dirs for gf / :find (one per line)',
      \ '# Paths relative to project root: ' . a:root,
      \ '# Example:',
      \ '# ../ulog/include',
      \ ], f)
  endif
  return f
endfunction

function! s:DotApplyVimpath() abort
  if &buftype !=# '' || bufname('%') =~# '^/Lf_preview_'
    return
  endif
  let root = s:DotProjectRoot()
  let f = s:DotEnsurePathFile(root)
  setlocal path=.,,
  setlocal path+=include,../include,inc,../inc,src
  setlocal suffixesadd+=.h,.hpp,.hh
  for line in readfile(f)
    let p = trim(substitute(line, '#.*$', '', ''))
    if empty(p) | continue | endif
    if p[0] !=# '/' | let p = root . '/' . p | endif
    execute 'setlocal path+=' . fnameescape(p)
  endfor
endfunction

function! s:DotEditVimpath() abort
  let f = s:DotEnsurePathFile(s:DotProjectRoot())
  execute 'edit' fnameescape(f)
endfunction

" gtags: -d/-r with fallback to -s (file-scope static vars live in other symbols)
let g:Lf_GtagsAutoGenerate = 0
let g:Lf_GtagsGutentags = 1
let g:Lf_Gtagslabel = 'native-pygments'

function! s:DotLfGtags(prefer) abort
  let w = expand('<cword>')
  if empty(w) | return | endif
  let mode = a:prefer
  let root = s:DotProjectRoot()
  let db = ''
  if !empty(root) && exists('*gutentags#get_cachefile')
    let db = fnamemodify(gutentags#get_cachefile(root, 'GTAGS'), ':h')
  endif
  if !empty(root) && isdirectory(db) && executable('global')
    let label = get(g:, 'Lf_Gtagslabel', 'native-pygments')
    let cmd = 'GTAGSROOT=' . shellescape(root)
          \ . ' GTAGSDBPATH=' . shellescape(db)
          \ . ' GTAGSLABEL=' . shellescape(label)
          \ . ' global -' . a:prefer . ' ' . shellescape(w)
    let lines = systemlist(cmd)
    let nonempty = filter(copy(lines), 'v:val !~# "^\\s*$"')
    if empty(nonempty)
      let mode = 's'
    endif
  endif
  execute 'Leaderf! gtags -' . mode . ' ' . w . ' --auto-jump'
endfunction

nnoremap <silent> <leader>fd :<C-U>call <SID>DotLfGtags('d')<CR>
nnoremap <silent> <leader>fr :<C-U>call <SID>DotLfGtags('r')<CR>
nnoremap <silent> <leader>fs :<C-U>execute 'Leaderf! gtags -s' expand('<cword>') '--auto-jump'<CR>
nnoremap <silent> <leader>fg :<C-U>execute 'Leaderf! gtags -g' expand('<cword>')<CR>
nnoremap <silent> <leader>fG :Leaderf gtags<CR>
nnoremap <silent> <leader>fo :Leaderf! gtags --recall<CR>
nnoremap <silent> <leader>fn :Leaderf gtags --next<CR>
nnoremap <silent> <leader>fp :Leaderf gtags --previous<CR>

let g:UltiSnipsExpandTrigger="<C-j>"
let g:UltiSnipsJumpForwardTrigger="<C-j>"
let g:UltiSnipsJumpBackwardTrigger="<C-k>"

augroup dot_cpp_path
  autocmd!
  autocmd FileType c,cpp call s:DotApplyVimpath()
  autocmd BufWritePost */.cache/LeaderF/project_paths/*.path call s:DotApplyVimpath()
augroup END
nnoremap <silent> <leader>vp :call <SID>DotEditVimpath()<CR>

" header ↔ source (vim-alternate); ,h stays amix bprevious
let g:AlternateExtensionMappings = [
  \ {'.cpp': '.h', '.h': '.hpp', '.hpp': '.cpp'},
  \ {'.cc': '.h', '.h': '.cc'},
  \ {'.c': '.h', '.h': '.c'},
  \ {'.cxx': '.hxx', '.hxx': '.cxx'},
  \ ]
nnoremap <silent> <leader>A :Alternate<CR>

" format via clang-format (range or whole buffer)
nnoremap <silent> <leader>cf :%!clang-format<CR>
vnoremap <silent> <leader>cf :!clang-format<CR>

" clipboard via xclip (-clipboard Vim); paste below line (does not replace buffer)
vnoremap <silent> <leader>y :w !xclip -selection clipboard<CR><CR>
nnoremap <silent> <leader>p :read !xclip -o -selection clipboard<CR>
EOF
  ok "vim stack"
}

set_default_shell_zsh() {
  local z
  z="$(command -v zsh)" || return 0
  [[ "${SHELL:-}" == "$z" ]] && return 0
  log "chsh -> zsh (sudo may ask password)..."
  run_sudo chsh -s "$z" "$USER" 2>/dev/null && ok "login shell: zsh" || warn "chsh failed; run: chsh -s $z"
}

main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --force-vim) FORCE_VIM=1 ;;
      -h|--help)
        printf '%s\n' "Usage: bash install.sh [--force-vim]"
        exit 0
        ;;
      *) die "Unknown option: $arg (try --force-vim)" ;;
    esac
  done

  install_packages
  install_meslo_fonts
  install_fzf
  install_oh_my_tmux
  install_zsh_stack
  build_vim_from_source
  install_vim_stack

  if [[ -x /usr/local/bin/vim ]]; then
    git config --global core.editor /usr/local/bin/vim
  else
    git config --global core.editor vim
  fi
  if [[ ! -e /usr/bin/bat && -x /usr/bin/batcat ]]; then
    log "batcat -> bat"
    run_sudo ln -sf /usr/bin/batcat /usr/bin/bat
  fi

  set_default_shell_zsh
  ok "Done"
  local zsh_path
  zsh_path="$(command -v zsh 2>/dev/null || true)"
  if [[ -n "$zsh_path" && "${SHELL:-}" == "$zsh_path" ]]; then
    return 0
  fi
  exec zsh -l
}

main "$@"
