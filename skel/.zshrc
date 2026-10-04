# x seed zsh rc.

# Reuse the bash seed (PATH, aliases): its syntax is zsh-safe.
[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"

# Starship prompt (installed with the desktop stack; no-op without it).
if command -v starship >/dev/null 2>&1; then
    eval "$(starship init zsh)"
fi
