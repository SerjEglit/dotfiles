#!/usr/bin/env bash
# -*- coding: utf-8 -*-
set -euo pipefail
IFS=$'\n\t'

### 0. Проверка среды и CRLF → LF ###
if ! grep -qi microsoft /proc/version; then
  echo "❌ Ошибка: скрипт предназначен для WSL2!" >&2
  exit 1
fi
# Убираем возможные \r (если запущен напрямую после curl)
[ -t 1 ] && sed -i 's/\r$//' "$0"

### Функции логирования и тайминга ###
LOG_FILE="$HOME/wsl-setup-$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

info(){ echo -e "\n▶️  $1"; }
die(){ echo "❌ $1" >&2; exit 1; }

start_time="$(date +%s)"
info "Запуск автонастройки WSL2: $(date)"
info "Лог: $LOG_FILE"

### 1. Конфигурация ###
ASDF_VER="v0.14.0"
KIND_VER="v0.20.0"
PYTHON_VER="3.11.9"
EZA_VER="0.17.0"
TF_VER="1.9.5"
LOCAL_PROJ="$HOME/projects"
EXT_PROJ="/mnt/e/projects"

### 2. Проверка сети ###
info "Проверка интернет-связи"
curl -fsI https://github.com > /dev/null || die "Нет интернета"

### 3. Установка APT-пакетов ###
info "Установка базовых пакетов"
sudo apt update
sudo apt install -y git curl wget zsh build-essential python3-pip python3-venv unzip \
  docker.io docker-compose jq fzf ripgrep bat direnv gnupg2 ca-certificates pv dos2unix

### 4. Установка eza ###
install_tool() {
  local name=$1 version=$2 url=$3 dest=$4
  if command -v "$name" &>/dev/null; then
    echo "✅ $name уже установлен"
    return
  fi
  info "Установка $name $version"
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/$name.tar.gz" || die "Скачивание $name"
  tar -xzf "$tmp/$name.tar.gz" -C "$tmp" || die "Распаковка $name"
  sudo mv "$tmp/$name" "$dest" || die "Установка $name"
  sudo chmod +x "$dest/$name"
  rm -rf "$tmp"
}
install_tool eza "$EZA_VER" \
  "https://github.com/eza-community/eza/releases/download/v${EZA_VER}/eza_${EZA_VER}-$(uname -m)-unknown-linux-gnu.tar.gz" \
  /usr/local/bin

### 5. Настройка Zsh + Powerlevel10k ###
info "Настройка Oh-My-Zsh и Powerlevel10k"
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi
P10K="$HOME/.oh-my-zsh/custom/themes/powerlevel10k"
[ -d "$P10K" ] || git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K"
grep -qx 'ZSH_THEME="powerlevel10k/powerlevel10k"' ~/.zshrc \
  && sed -i 's/^ZSH_THEME=.*/ZSH_THEME="powerlevel10k\/powerlevel10k"/' ~/.zshrc \
  || echo 'ZSH_THEME="powerlevel10k/powerlevel10k"' >> ~/.zshrc

### 6. Установка asdf ###
info "Установка asdf $ASDF_VER"
[ -d "$HOME/.asdf" ] || git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch "$ASDF_VER" --depth=1
grep -qx '. $HOME/.asdf/asdf.sh' ~/.zshrc \
  || printf "\n. $HOME/.asdf/asdf.sh\n. $HOME/.asdf/completions/asdf.bash\n" >> ~/.zshrc
source "$HOME/.asdf/asdf.sh"

# Плагины и версии через asdf
declare -A ASDF_TOOLS=(
  [kubectl]="https://github.com/asdf-community/asdf-kubectl.git 1.30.0"
  [helm]="https://github.com/asdf-community/asdf-helm.git 3.15.2"
  [nodejs]="https://github.com/asdf-vm/asdf-nodejs.git 20.14.0"
  [python]="https://github.com/asdf-vm/asdf-python.git $PYTHON_VER"
)
for t in "${!ASDF_TOOLS[@]}"; do
  repo=${ASDF_TOOLS[$t]% *}
  ver=${ASDF_TOOLS[$t]#* }
  info "Плагин asdf: $t → $ver"
  asdf plugin-remove "$t" 2>/dev/null || true
  asdf plugin-add "$t" "$repo"
  asdf install "$t" "$ver"
  asdf global "$t" "$ver"
done

### 7. Установка Terraform вручную ###
info "Установка Terraform $TF_VER"
ARCH=$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')
ZIP="terraform_${TF_VER}_linux_${ARCH}.zip"
URL="https://releases.hashicorp.com/terraform/${TF_VER}/${ZIP}"
tmp=$(mktemp -d)
curl -fsSL "$URL" -o "$tmp/$ZIP" || die "Скачивание Terraform"
unzip -q "$tmp/$ZIP" -d "$tmp"
sudo mv "$tmp/terraform" /usr/local/bin/
sudo chmod +x /usr/local/bin/terraform
rm -rf "$tmp"

### 8. Docker ###
info "Настройка Docker"
sudo groupadd docker 2>/dev/null || true
sudo usermod -aG docker "$USER"
sudo systemctl enable --now docker || echo "[WARN] Docker не запущен"
sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

### 9. pipx + утилиты ###
info "Установка pipx и Python-утилит"
python3 -m pip install --user pipx
pipx ensurepath
export PATH="$HOME/.local/bin:$PATH"
for util in poetry pre-commit ansible awscli; do
  command -v $util &>/dev/null || pipx install $util
done

### 10. Kind, Terraform-docs, TFLint ###
info "Установка других DevOps-утилит"
sudo apt install -y terraform-docs tflint
if ! command -v kind &>/dev/null; then
  URL="https://kind.sigs.k8s.io/dl/$KIND_VER/kind-linux-${ARCH}"
  curl -fsSL -o kind "$URL"
  chmod +x kind && sudo mv kind /usr/local/bin/
fi

### 11. VS Code ###
info "Установка VS Code"
if ! command -v code &>/dev/null; then
  sudo apt install -y wget gpg
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor > packages.microsoft.gpg
  sudo install -o root -g root -m644 packages.microsoft.gpg \
    /etc/apt/keyrings/packages.microsoft.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/packages.microsoft.gpg] \
    https://packages.microsoft.com/repos/code stable main" \
    | sudo tee /etc/apt/sources.list.d/vscode.list
  sudo apt update && sudo apt install -y code
  rm packages.microsoft.gpg
fi

### 12. Алиасы и new-project ###
info "Добавление алиасов и функции new-project"
{
  cat <<'EOF'

# === Custom Aliases ===
alias ls='eza --icons --group-directories-first'
alias ll='eza -l --icons --group-directories-first'
alias grep='rg'
alias cat='bat --paging=never'
alias tf='terraform'
alias k='kubectl'
alias dkc='docker compose'

new-project() {
  [ -z "$1" ] && { echo "Usage: new-project <name>"; return 1; }
  root="$LOCAL_PROJ"
  [ -d "$EXT_PROJ" ] && root="$EXT_PROJ"
  mkdir -p "$root/$1"/{src,tests,data,infra,docs}
  cd "$root/$1"
  git init
  python -m venv .venv && echo "source .venv/bin/activate" > .envrc
  direnv allow
  touch README.md .gitignore && echo "# $1" > README.md
  command -v code &>/dev/null && code .
}
EOF
} >> ~/.zshrc

### 13. Финал и очистка ###
info "Очистка APT и завершение"
sudo apt autoremove -y
sudo apt clean
sudo rm -rf /var/lib/apt/lists/*

duration=$(( $(date +%s) - start_time ))
info "✅ Установка завершена за ${duration}s"
info "Для применения: exec zsh"
info "Проверьте среду: ~/devops-audit.sh"
