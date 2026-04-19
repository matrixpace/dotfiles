#!/usr/bin/env bash
# Debian/Ubuntu bootstrap: apt, Vim (+Python3) from source, amix/vimrc + plugins, fzf,
# Oh My Tmux, Oh My Zsh + p10k, Meslo fonts, git editor + bat symlink. Re-runs are safe.
#
# Usage: bash install.sh  (non-root; needs sudo, git, curl or wget)

set -euo pipefail

readonly NC='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BL='\033[0;34m'
readonly VIM_SRC="${XDG_DATA_HOME:-$HOME/.local/share}/dotfiles/vim-source"
readonly MESLO_SRC="${XDG_DATA_HOME:-$HOME/.local/share}/dotfiles/powerlevel10k-media"
readonly VIM_RT="$HOME/.vim_runtime"

log()  { printf '%b\n' "${BL}[INFO]${NC} $*"; }
ok()   { printf '%b\n' "${GREEN}[OK]${NC}   $*"; }
warn() { printf '%b\n' "${YELLOW}[WARN]${NC} $*"; }
die()  { printf '%b\n' "${RED}[ERR]${NC}  $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] && die "Do not run as root. Use: bash $0"
command -v apt-get &>/dev/null || die "Requires apt-get (Debian/Ubuntu)."
command -v git &>/dev/null || die "Need git."

run_sudo() {
  command -v sudo &>/dev/null || die "sudo is required for privileged steps (apt, make install, chsh, etc.)."
  sudo "$@"
}

download() {
  local url="$1" dest="$2"
  if command -v curl &>/dev/null; then
    curl -fsSL --connect-timeout 25 --retry 5 --retry-delay 2 -o "$dest" "$url"
  else
    die "Need curl"
  fi
}

ensure_git_repo() {
  local url="$1" path="$2"
  if [[ ! -d "$path/.git" ]]; then
    rm -rf "$path"
    mkdir -p "$(dirname "$path")"
    git clone --depth=1 "$url" "$path"
  else
    git -C "$path" pull --ff-only 2>/dev/null || true
  fi
}

append_once() {
  local file="$1" marker="$2" block="$3"
  [[ -f "$file" ]] || return 0
  grep -Fq "$marker" "$file" && return 0
  printf '%s\n' "$block" >>"$file"
}

prepend_once() {
  local file="$1" marker="$2" block="$3"
  [[ -f "$file" ]] || return 0
  grep -Fq "$marker" "$file" && return 0
  local tmp
  tmp="$(mktemp)"
  {
    printf '%s\n' "$block"
    cat "$file"
  } >"$tmp"
  mv "$tmp" "$file"
}

# Inserts a multi-line block before the first line exactly matching $match (OMZ: source $ZSH/oh-my-zsh.sh).
insert_once_before_line() {
  local file="$1" marker="$2" match="$3" block="$4"
  [[ -f "$file" ]] || return 0
  grep -Fq "$marker" "$file" && return 0
  grep -qF "$match" "$file" || return 0
  local tmp ln
  ln="$(grep -nF "$match" "$file" | head -1 | cut -d: -f1)" || return 0
  [[ -n "$ln" ]] || return 0
  tmp="$(mktemp)"
  head -n "$((ln - 1))" "$file" >"$tmp"
  printf '%s\n' "$block" >>"$tmp"
  tail -n "+${ln}" "$file" >>"$tmp"
  mv "$tmp" "$file"
}

install_packages() {
  log "APT packages..."
  run_sudo apt-get update -qq
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git tmux zsh autojump silversearcher-ag \
    build-essential cmake libtool pkg-config python3-dev python3-venv libncurses-dev \
    iproute2 iputils-ping cloc bat figlet btop ca-certificates unzip xclip
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

purge_distro_vim() {
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    vim vim-nox vim-tiny vim-athena vim-gtk vim-gnome vim-gui-common 2>/dev/null || true
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || true
}

sync_vim_source() {
  ensure_git_repo https://github.com/vim/vim.git "$VIM_SRC"
}

build_vim_from_source() {
  log "Vim from source (+python3)..."
  purge_distro_vim
  sync_vim_source
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

apply_tmux_local_prefs() {
  local f="$HOME/.tmux.conf.local"
  [[ -f "$f" ]] || return 0
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
  grep -Fq "nordtheme/tmux" "$f" && return 0
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
}

install_oh_my_tmux() {
  log "Oh My Tmux..."
  local dest="$HOME/.tmux"
  ensure_git_repo https://github.com/gpakosz/.tmux.git "$dest"
  ln -sf "$dest/.tmux.conf" "$HOME/.tmux.conf"
  [[ -f "$HOME/.tmux.conf.local" ]] || cp "$dest/.tmux.conf.local" "$HOME/.tmux.conf.local"
  apply_tmux_local_prefs
  ok "tmux"
}

write_fzf_zsh() {
  cat >"$HOME/.fzf.zsh" <<'EOF'
export PATH="$HOME/.fzf/bin:$PATH"
export FZF_DEFAULT_COMMAND='ag -i --hidden -l -a -g ""'
export FZF_DEFAULT_OPTS="--height 80% --layout reverse --preview '(bat --style=numbers --color=always {} || cat {}) 2> /dev/null | head -500'"
[[ -f ~/.fzf/shell/completion.zsh ]] && source ~/.fzf/shell/completion.zsh
[[ -f ~/.fzf/shell/key-bindings.zsh ]] && source ~/.fzf/shell/key-bindings.zsh
EOF
}

install_fzf() {
  log "fzf..."
  ensure_git_repo https://github.com/junegunn/fzf.git "$HOME/.fzf"
  "$HOME/.fzf/install" --bin
  write_fzf_zsh
  ok "fzf"
}

append_fzf_zshrc() {
  local z="$HOME/.zshrc"
  [[ -f "$z" ]] || return 0
  append_once "$z" '[dot-install fzf]' '# [dot-install fzf]
[[ -f ~/.fzf.zsh ]] && source ~/.fzf.zsh'
}

sync_ohmyzsh_zshrc() {
  local z="$HOME/.zshrc"
  [[ -f "$z" ]] || return 0
  grep -qE '^[[:space:]]*ZSH_THEME=' "$z" \
    && sed -i 's/^[[:space:]]*ZSH_THEME=.*/ZSH_THEME="powerlevel10k\/powerlevel10k"/' "$z" \
    || printf '%s\n' 'ZSH_THEME="powerlevel10k/powerlevel10k"' >>"$z"
  grep -qE '^[[:space:]]*plugins=\(' "$z" \
    && sed -i 's/^[[:space:]]*plugins=(.*)/plugins=(git autojump zsh-autosuggestions tmux zsh-syntax-highlighting)/' "$z" \
    || printf '%s\n' 'plugins=(git autojump zsh-autosuggestions tmux zsh-syntax-highlighting)' >>"$z"
}

prepend_p10k_instant_prompt() {
  local z="$HOME/.zshrc"
  [[ -f "$z" ]] || return 0
  prepend_once "$z" '[dot-install p10k-instant]' '# [dot-install p10k-instant]
# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi'
}

append_auto_tmux() {
  insert_once_before_line "$HOME/.zshrc" '[dot-install auto-tmux-env]' 'source $ZSH/oh-my-zsh.sh' '# [dot-install auto-tmux-env]
ZSH_TMUX_AUTOSTART=true
ZSH_TMUX_AUTOCONNECT=false
ZSH_TMUX_AUTOQUIT=false'
}

append_proxy_helpers() {
  append_once "$HOME/.zshrc" '[dot-install proxy]' '# [dot-install proxy]
setp() {
    local proxy_host="127.0.0.1"
    local proxy_port="12334"
    export HTTP_PROXY="http://${proxy_host}:${proxy_port}"
    export HTTPS_PROXY="http://${proxy_host}:${proxy_port}"
    export FTP_PROXY="http://${proxy_host}:${proxy_port}"
    export ALL_PROXY="socks5://${proxy_host}:${proxy_port}"
}

unsetp() {
    unset HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY
}'
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
  local c="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
  ensure_git_repo https://github.com/romkatv/powerlevel10k.git "$c/themes/powerlevel10k"
  ensure_git_repo https://github.com/zsh-users/zsh-autosuggestions "$c/plugins/zsh-autosuggestions"
  ensure_git_repo https://github.com/zsh-users/zsh-syntax-highlighting.git "$c/plugins/zsh-syntax-highlighting"
  prepend_p10k_instant_prompt
  sync_ohmyzsh_zshrc
  append_auto_tmux
  [[ -f "$HOME/.p10k.zsh" ]] \
    || download "https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-lean.zsh" "$HOME/.p10k.zsh"
  append_once "$HOME/.zshrc" 'source ~/.p10k.zsh' '[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh'
  append_fzf_zshrc
  append_proxy_helpers
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
  ln -sf "$HOME/.fzf" "$mp/fzf"

  cat >"$VIM_RT/my_configs.vim" <<'EOF'
" dot-install: managed by install.sh (overwritten each run)

set nu rnu nowrap nowrapscan noshowmode cc=81

colorscheme nord
" Visible visual selection and popup menus (fixes invisible selected text)
highlight Visual ctermbg=238 ctermfg=NONE guibg=#3B4252 guifg=NONE

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

try
    unmap <leader>f
catch
endtry

inoremap jk <Esc>

nmap <silent> <leader>tt :TagbarToggle<CR>
let g:tagbar_position = 'left'

let g:Lf_HideHelp = 1
let g:Lf_UseCache = 0
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
let g:Lf_ExternalCommand = 'ag -g "%s" -i -a --hidden'
let g:Lf_PopupColorscheme = 'nord'
let g:Lf_StlColorscheme = 'nord'

let g:Lf_ShortcutF = '<leader>ff'
noremap <leader>fm :<C-U><C-R>=printf("Leaderf mru %s", "")<CR><CR>
noremap <leader>fb :<C-U><C-R>=printf("Leaderf buffer %s", "")<CR><CR>
noremap <leader>ft :<C-U><C-R>=printf("Leaderf bufTag %s", "")<CR><CR>
noremap <leader>fl :<C-U><C-R>=printf("Leaderf line %s --bottom --cword --regexMode", "")<CR><CR>

let g:Lf_GtagsAutoGenerate = 0
let g:Lf_Gtagslabel = 'native-pygments'
noremap <leader>fr :<C-U><C-R>=printf("Leaderf! gtags -r %s --auto-jump", expand("<cword>"))<CR><CR>
noremap <leader>fd :<C-U><C-R>=printf("Leaderf! gtags -d %s --auto-jump", expand("<cword>"))<CR><CR>
noremap <leader>fg :<C-U><C-R>=printf("Leaderf! gtags -g %s", expand("<cword>"))<CR><CR>
noremap <leader>fG :<C-U><C-R>=printf("Leaderf gtags %s", "")<CR><CR>
noremap <leader>fo :<C-U><C-R>=printf("Leaderf! gtags --recall %s", "")<CR><CR>
noremap <leader>fn :<C-U><C-R>=printf("Leaderf gtags --next %s", "")<CR><CR>
noremap <leader>fp :<C-U><C-R>=printf("Leaderf gtags --previous %s", "")<CR><CR>

let g:UltiSnipsExpandTrigger="<c-j>"
let g:UltiSnipsJumpForwardTrigger="<c-b>"
let g:UltiSnipsJumpBackwardTrigger="<c-z>"

nnoremap <silent> <leader>P :%!xclip -o -selection clipboard<CR>
vnoremap <silent> <leader>Y :w !xclip -selection clipboard<CR><CR>
EOF
  ok "vim stack"
}

git_and_bat_defaults() {
  if [[ -x /usr/local/bin/vim ]]; then
    git config --global core.editor /usr/local/bin/vim
  else
    git config --global core.editor vim
  fi
  [[ -e /usr/bin/bat ]] && return 0
  [[ -x /usr/bin/batcat ]] || return 0
  log "batcat -> bat"
  run_sudo ln -sf /usr/bin/batcat /usr/bin/bat
}

set_default_shell_zsh() {
  local z
  z="$(command -v zsh)" || return 0
  [[ "${SHELL:-}" == "$z" ]] && return 0
  log "chsh -> zsh (sudo may ask password)..."
  run_sudo chsh -s "$z" "$USER" 2>/dev/null && ok "login shell: zsh" || warn "chsh failed; run: chsh -s $z"
}

main() {
  install_packages
  install_meslo_fonts
  install_fzf
  install_oh_my_tmux
  install_zsh_stack
  build_vim_from_source
  install_vim_stack
  git_and_bat_defaults
  set_default_shell_zsh
  ok "Done"

  exec zsh -l
}

main
