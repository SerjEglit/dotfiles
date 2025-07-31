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
### Установка Terraform (надёжно, без зависимостей) ###
info "Установка Terraform $TF_VER вручную"
ARCH=$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')
ZIP="terraform_${TF_VER}_linux_${ARCH}.zip"
URL="https://releases.hashicorp.com/terraform/${TF_VER}/${ZIP}"

# Создаём временную папку
TMPDIR=$(mktemp -d)
# Скачиваем zip
curl -fsSL "$URL" -o "$TMPDIR/$ZIP" \
  || die "Не удалось скачать Terraform $TF_VER ($URL)"
# Распаковываем
unzip -q "$TMPDIR/$ZIP" -d "$TMPDIR" \
  || die "Ошибка распаковки Terraform"
# Устанавливаем бинарник
sudo mv "$TMPDIR/terraform" /usr/local/bin/
sudo chmod +x /usr/local/bin/terraform
rm -rf "$TMPDIR"

echo "→ Terraform $(terraform version | head -n1) установлен"

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
