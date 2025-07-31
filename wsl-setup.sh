#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

### 0) Проверка WSL2 + CRLF→LF ###
[ -f "$0" ] && sed -i 's/\r$//' "$0"
if ! grep -qi microsoft /proc/version; then
  echo "❌ Скрипт рассчитан на WSL2!" >&2
  exit 1
fi

### Логирование ###
LOG="$HOME/wsl-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
echo "▶️  Старт: $(date)"
echo "ℹ️  Лог: $LOG"

info(){ echo -e "\n=== $1 ==="; }
die(){ echo "❌ $1" >&2; exit 1; }

### 1) Базовые пакеты & Docker ###
info "Установка APT-пакетов и Docker"
sudo apt update
sudo apt install -y \
  git curl wget zsh build-essential python3-pip python3-venv unzip \
  docker.io docker-compose jq fzf ripgrep bat direnv gnupg2 ca-certificates pv
sudo usermod -aG docker "$USER"
sudo systemctl enable --now docker

### 2) NVM + Node.js LTS ###
info "Установка NVM и Node.js LTS"
if [ ! -d "$HOME/.nvm" ]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.5/install.sh \
    | bash
fi
export NVM_DIR="$HOME/.nvm"
# shellcheck source=/dev/null
. "$NVM_DIR/nvm.sh"
nvm install --lts
nvm alias default 'lts/*'
echo "→ Node.js $(node -v)"

### 3) Terraform через temporary-files ###
info "Установка Terraform (via temporary-files repo)"
# Клонируем ваш проверенный репозиторий
TMP_REPO="$HOME/.tmp/temporary-files"
rm -rf "$TMP_REPO"
git clone git@github.com:SerjEglit/temporary-files.git "$TMP_REPO" \
  || die "Не удалось клонировать temporary-files"
# Предполагаем, что в репо есть скрипт install-terraform.sh
if [ -x "$TMP_REPO/install-terraform.sh" ]; then
  BashBin=$(which bash)
  # Убираем CRLF и даём права
  sed -i 's/\r$//' "$TMP_REPO/install-terraform.sh"
  chmod +x "$TMP_REPO/install-terraform.sh"
  # Запускаем установку
  "$TMP_REPO/install-terraform.sh" \
    || die "Скрипт установки Terraform завершился с ошибкой"
  echo "→ Terraform from temporary-files: $(terraform version | head -n1)"
else
  die "В temporary-files нет install-terraform.sh"
fi

### 4) Python + pipx + утилиты ###
info "Python + pipx + утилиты"
python3 -m pip install --user pipx
pipx ensurepath
export PATH="$HOME/.local/bin:$PATH"
for pkg in poetry pre-commit ansible awscli; do
  pipx install --force "$pkg" || echo "⚠️ pipx $pkg failed"
done

### 5) Oh-My-Zsh + Powerlevel10k ###
info "Настройка Zsh & Powerlevel10k"
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  RUNZSH=no CHSH=no \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi
P10K="$HOME/.oh-my-zsh/custom/themes/powerlevel10k"
[ -d "$P10K" ] || git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K"
grep -qx 'ZSH_THEME="powerlevel10k/powerlevel10k"' ~/.zshrc \
  || echo 'ZSH_THEME="powerlevel10k/powerlevel10k"' >> ~/.zshrc

### 6) Алиасы & new-project ###
info "Добавляем алиасы и new-project"
cat << 'EOF' >> ~/.zshrc

# Aliases
alias ll='ls -lah'
alias gs='git status'
alias gp='git push'
alias tf='terraform'
alias k='kubectl'
alias dkc='docker compose'

# new-project
new-project(){
  if [ -z "$1" ]; then
    echo "Usage: new-project <name>"
    return 1
  fi
  ROOT="$HOME/projects"
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

### Финал ###
duration=$(( $(date +%s) - start_time ))
info "Готово за ${duration}s"
info "Перезапустите терминал или выполните: source ~/.zshrc"
