#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Проверка WSL2
if ! grep -qi microsoft /proc/version; then
  echo "❌ Этот скрипт только для WSL2!" >&2
  exit 1
fi

# Логирование
LOG="$HOME/wsl-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
echo "✅ Старт установки: $(date)"
echo "📝 Лог: $LOG"

# 1) Базовые пакеты + Docker
echo "1) Установка базовых пакетов..."
sudo apt update
sudo apt install -y git curl wget zsh build-essential python3-pip python3-venv unzip \
  docker.io docker-compose jq fzf ripgrep bat direnv gnupg2 ca-certificates pv unzip
sudo usermod -aG docker "$USER"
sudo systemctl enable --now docker

# 2) NVM + Node.js (последняя LTS)
echo "2) Установка NVM и Node.js LTS..."
if [ ! -d "$HOME/.nvm" ]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.5/install.sh | bash
fi
export NVM_DIR="$HOME/.nvm"
# shellcheck source=/dev/null
. "$NVM_DIR/nvm.sh"
nvm install --lts
nvm alias default 'lts/*'
echo "→ Node.js $(node -v)"

# 3) Terraform (ручная установка)
TF_VER="1.9.5"
ARCH=$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')
ZIP="terraform_${TF_VER}_linux_${ARCH}.zip"
URL="https://releases.hashicorp.com/terraform/${TF_VER}/${ZIP}"
echo "3) Установка Terraform $TF_VER..."
tmp=$(mktemp -d)
curl -fsSL "$URL" -o "$tmp/$ZIP"
unzip -q "$tmp/$ZIP" -d "$tmp"
sudo mv "$tmp/terraform" /usr/local/bin/
sudo chmod +x /usr/local/bin/terraform
rm -rf "$tmp"
echo "→ Terraform $(terraform version | head -n1)"

# 4) Python + pipx + утилиты
echo "4) Настройка Python и pipx..."
python3 -m pip install --user pipx
python3 -m pipx ensurepath
export PATH="$HOME/.local/bin:$PATH"
for pkg in poetry pre-commit ansible awscli; do
  pipx install --force "$pkg" || echo "⚠️ Не удалось $pkg"
done

# 5) Oh-My-Zsh + Powerlevel10k
echo "5) Настройка Zsh..."
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi
P10K="$HOME/.oh-my-zsh/custom/themes/powerlevel10k"
[ -d "$P10K" ] || git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K"
grep -qx 'ZSH_THEME="powerlevel10k/powerlevel10k"' ~/.zshrc \
  || echo 'ZSH_THEME="powerlevel10k/powerlevel10k"' >> ~/.zshrc

# 6) Алиасы и функция new-project
echo "6) Добавление алиасов и функции new-project..."
cat << 'EOF' >> ~/.zshrc

# Aliases
alias ll='ls -lah'
alias gs='git status'
alias gp='git push'
alias tf='terraform'
alias k='kubectl'
alias dkc='docker compose'

# new-project
new-project() {
  if [ -z "$1" ]; then
    echo "Usage: new-project <name>"
    return 1
  fi
  root="$HOME/projects"
  mkdir -p "$root/$1"/{src,tests,data,infra,docs}
  cd "$root/$1"
  git init
  python3 -m venv .venv
  echo "source .venv/bin/activate" > .envrc
  direnv allow
  touch README.md .gitignore
  echo "# $1" > README.md
  command -v code &>/dev/null && code .
}
EOF

# Финал
echo "✅ Установка завершена!"
echo "👉 Перезапустите терминал или выполните:  source ~/.zshrc"
