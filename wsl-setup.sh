#!/usr/bin/env bash
# wsl-setup.sh — Автонастройка WSL2 для DevOps
set -euo pipefail
IFS=$'\n\t'

### 0) Проверка WSL2 и CRLF→LF ###
[ -f "$0" ] && sed -i 's/\r$//' "$0"
if ! grep -qi microsoft /proc/version; then
  echo "❌ Этот скрипт только для WSL2!" >&2
  exit 1
fi

### Логирование ###
LOG="$HOME/wsl-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
info(){ echo -e "\n▶️  $1"; }
die(){ echo "❌ $1" >&2; exit 1; }

info "Старт установки — $(date)"
info "Лог сохраняется в $LOG"

### Конфигурация версий ###
TF_VER="1.9.5"       # Terraform
PY_VER="3.11.9"      # Python
NVM_VERSION="v0.39.5" # NVM
ZSH_THEME="powerlevel10k/powerlevel10k"

### 1) Базовые пакеты + Docker ###
info "Установка базовых пакетов и Docker"
sudo apt update
sudo apt install -y \
  git curl wget zsh build-essential python3-pip python3-venv unzip \
  docker.io docker-compose jq fzf ripgrep bat direnv gnupg2 ca-certificates pv
sudo usermod -aG docker "$USER"
sudo systemctl enable --now docker || echo "[WARN] Docker не запущен"

### 2) NVM + Node.js LTS ###
info "Установка NVM и Node.js LTS"
if [ ! -d "$HOME/.nvm" ]; then
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" | bash
fi
export NVM_DIR="$HOME/.nvm"
# shellcheck source=/dev/null
. "$NVM_DIR/nvm.sh"
nvm install --lts
nvm alias default 'lts/*'
info "Node.js $(node -v)"

### 3) Terraform вручную ###
info "Установка Terraform $TF_VER"
ARCH=$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')
ZIP="terraform_${TF_VER}_linux_${ARCH}.zip"
URL="https://releases.hashicorp.com/terraform/${TF_VER}/${ZIP}"
TMPDIR=$(mktemp -d)
curl -fsSL "$URL" -o "$TMPDIR/$ZIP" || die "Не удалось скачать Terraform"
unzip -q "$TMPDIR/$ZIP" -d "$TMPDIR" || die "Ошибка распаковки Terraform"
sudo mv "$TMPDIR/terraform" /usr/local/bin/
sudo chmod +x /usr/local/bin/terraform
rm -rf "$TMPDIR"
info "Terraform $(terraform version | head -n1)"

### 4) Python + pipx + утилиты ###
info "Настройка Python и pipx-утилит"
python3 -m pip install --user pipx
python3 -m pipx ensurepath
export PATH="$HOME/.local/bin:$PATH"
for pkg in poetry pre-commit ansible awscli; do
  pipx install --force "$pkg" || echo "[WARN] pipx install $pkg failed"
done

### 5) Oh-My-Zsh + Powerlevel10k ###
info "Установка Oh-My-Zsh и тему $ZSH_THEME"
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi
P10K_DIR="$HOME/.oh-my-zsh/custom/themes/powerlevel10k"
[ -d "$P10K_DIR" ] || git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR"
grep -qx "ZSH_THEME=\"$ZSH_THEME\"" ~/.zshrc \
  || echo "ZSH_THEME=\"$ZSH_THEME\"" >> ~/.zshrc

### 6) Алиасы и функция new-project ###
info "Добавление алиасов и функции new-project"
cat << 'EOF' >> ~/.zshrc

# === Aliases ===
alias ll='ls -lah'
alias gs='git status'
alias gp='git push'
alias tf='terraform'
alias k='kubectl'
alias dkc='docker compose'

# === new-project ===
new-project(){
  if [ -z "$1" ]; then
    echo "Usage: new-project <name>"
    return 1
  fi
  local ROOT="$HOME/projects"
  mkdir -p "$ROOT/$1"/{src,tests,data,infra,docs}
  cd "$ROOT/$1"
  git init
  python3 -m venv .venv
  echo "source .venv/bin/activate" >.envrc
  direnv allow
  touch README.md .gitignore
  echo "# $1" >README.md
  command -v code &>/dev/null && code .
}
EOF

### Завершение ###
duration=$(( $(date +%s) - start_time ))
info "Установка завершена за ${duration}s"
info "Перезапустите терминал или выполните: source ~/.zshrc"
