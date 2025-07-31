#!/usr/bin/env bash
# wsl-setup.sh — минималистичная настройка WSL2 для DevOps
set -euo pipefail
IFS=$'\n\t'

### 0) CRLF→LF + проверка WSL2 ###
[ -f "$0" ] && sed -i 's/\r$//' "$0"
if ! grep -qi microsoft /proc/version; then
  echo "❌ Скрипт только для WSL2!" >&2
  exit 1
fi

### 1) Тайминг и логирование ###
start_time=$(date +%s)
LOG="$HOME/wsl-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

info(){ echo -e "\n▶️  $1"; }
die (){ echo "❌ $1" >&2; exit 1; }

info "Старт установки — $(date)"
info "Лог сохраняется в $LOG"

### 2) Версии инструментов ###
TF_VER="1.9.5"
PY_VER="3.11.9"
NVM_VER="v0.39.5"

### 3) Базовые пакеты + Docker ###
info "Установка базовых пакетов и Docker"
sudo apt update
sudo apt install -y \
  git curl wget zsh build-essential python3-pip python3-venv unzip \
  docker.io docker-compose jq fzf ripgrep bat direnv gnupg2 ca-certificates pv
sudo usermod -aG docker "$USER"
sudo systemctl enable --now docker || echo "[WARN] Docker не запущен"

### 4) NVM + Node.js LTS ###
info "Установка NVM ($NVM_VER) и Node.js LTS"
if [ ! -d "$HOME/.nvm" ]; then
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VER/install.sh" | bash
fi
export NVM_DIR="$HOME/.nvm"
# shellcheck source=/dev/null
. "$NVM_DIR/nvm.sh"
nvm install --lts
nvm alias default 'lts/*'
info "Node.js $(node -v)"

### 5) Terraform вручную ###
info "Установка Terraform $TF_VER"
ARCH=$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')
ZIP="terraform_${TF_VER}_linux_${ARCH}.zip"
URL="https://releases.hashicorp.com/terraform/${TF_VER}/${ZIP}"
TMPDIR=$(mktemp -d)
curl -fsSL "$URL" -o "$TMPDIR/$ZIP" || die "Не удалось скачать Terraform $TF_VER"
unzip -q "$TMPDIR/$ZIP" -d "$TMPDIR" || die "Ошибка распаковки Terraform"
sudo mv "$TMPDIR/terraform" /usr/local/bin/
sudo chmod +x /usr/local/bin/terraform
rm -rf "$TMPDIR"
info "Terraform $(terraform version | head -n1)"

### 6) Python + pipx + утилиты ###
info "Настройка Python и pipx-утилит"
python3 -m pip install --user pipx
python3 -m pipx ensurepath
export PATH="$HOME/.local/bin:$PATH"
for pkg in poetry pre-commit ansible awscli; do
  pipx install --force "$pkg" || echo "[WARN] pipx install $pkg failed"
done

### 7) Oh-My-Zsh + Powerlevel10k ###
info "Установка Oh-My-Zsh и Powerlevel10k"
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  RUNZSH=no CHSH=no \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi
P10K="$HOME/.oh-my-zsh/custom/themes/powerlevel10k"
[ -d "$P10K" ] || git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K"
grep -qx 'ZSH_THEME="powerlevel10k/powerlevel10k"' ~/.zshrc \
  || echo 'ZSH_THEME="powerlevel10k/powerlevel10k"' >> ~/.zshrc

### 8) Алиасы + new-project ###
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
  [ -z "$1" ] && { echo "Usage: new-project <name>"; return 1; }
  ROOT="$HOME/projects"
  mkdir -p "$ROOT/$1"/{src,tests,data,infra,docs}
  cd "$ROOT/$1"
  git init
  python3 -m venv .venv
  echo "source .venv/bin/activate" >.envrc
  direnv allow
  touch README.md .gitignore && echo "# $1" >README.md
  command -v code &>/dev/null && code .
}
EOF

### Завершение ###
duration=$(( $(date +%s) - start_time ))
info "Установка завершена за ${duration}s"
info "Перезапустите терминал или выполните: source ~/.zshrc"
