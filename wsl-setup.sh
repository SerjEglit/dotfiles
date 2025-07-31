#!/usr/bin/env bash
# wsl-setup.sh — Автонастройка WSL2 для DevOps-окружения
set -euo pipefail
IFS=$'\n\t'

### 0. CRLF → LF и проверка WSL ###
# Конвертируем CRLF, если они есть
[ -f "$0" ] && sed -i 's/\r$//' "$0"
if ! grep -qi microsoft /proc/version; then
  echo "❌ Ошибка: скрипт только для WSL2!" >&2
  exit 1
fi

### Логирование ###
LOG="$HOME/wsl-setup-$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
info(){ echo -e "\n▶️  $1"; }
die(){ echo "❌ $1" >&2; exit 1; }

start_time=$(date +%s)
info "Запуск автонастройки WSL2 — $(date)"
info "Лог: $LOG"

### 1. Конфигурация версий ###
ASDF_VER="v0.14.0"
KIND_VER="v0.20.0"
PY_VER="3.11.9"
EZA_VER="0.17.0"
TF_VER="1.9.5"
NODE_VER="22.19.0"
LOCAL_PROJ="$HOME/projects"
EXT_PROJ="/mnt/e/projects"

### 2. Проверка сети ###
info "Проверка интернета"
curl -fsI https://github.com >/dev/null || die "Нет интернета"

### 3. Базовые пакеты ###
info "Установка APT-пакетов"
sudo apt update
sudo apt install -y \
  git curl wget zsh build-essential python3-pip python3-venv unzip \
  docker.io docker-compose jq fzf ripgrep bat direnv gnupg2 ca-certificates pv

### 4. Отключаем always_keep_download для asdf ###
info "Отключаем always_keep_download в ~/.asdfrc"
mkdir -p ~/.config/asdf
echo "[asdf]" > ~/.config/asdf/.asdfrc
echo "always_keep_download = no" >> ~/.config/asdf/.asdfrc

### 5. Установка eza ###
install_eza(){
  local ver=$1 url=$2
  command -v eza &>/dev/null && { echo "✅ eza уже есть"; return; }
  info "Устанавливаем eza $ver"
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/eza.tgz" || die "Скачать eza"
  tar -xzf "$tmp/eza.tgz" -C "$tmp" || die "Распаковать eza"
  sudo mv "$tmp/eza" /usr/local/bin/
  sudo chmod +x /usr/local/bin/eza
  rm -rf "$tmp"
  echo "✅ eza установлен"
}
install_eza "$EZA_VER" \
  "https://github.com/eza-community/eza/releases/download/v${EZA_VER}/eza_${EZA_VER}-$(uname -m)-unknown-linux-gnu.tar.gz"

### 6. Oh-My-Zsh + Powerlevel10k ###
info "Настраиваем Zsh & Powerlevel10k"
[ -d "$HOME/.oh-my-zsh" ] \
  || RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
P10K="$HOME/.oh-my-zsh/custom/themes/powerlevel10k"
[ -d "$P10K" ] || git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K"
grep -qx 'ZSH_THEME="powerlevel10k/powerlevel10k"' ~/.zshrc \
  || echo 'ZSH_THEME="powerlevel10k/powerlevel10k"' >> ~/.zshrc

### 7. Установка asdf ###
info "Устанавливаем asdf $ASDF_VER"
[ -d "$HOME/.asdf" ] \
  || git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch "$ASDF_VER" --depth=1
grep -qx '. $HOME/.asdf/asdf.sh' ~/.zshrc \
  || printf "\n. \$HOME/.asdf/asdf.sh\n. \$HOME/.asdf/completions/asdf.bash\n" >> ~/.zshrc
source "$HOME/.asdf/asdf.sh"

declare -A PLUGINS=(
  [kubectl]="https://github.com/asdf-community/asdf-kubectl.git 1.30.0"
  [helm]="https://github.com/asdf-community/asdf-helm.git 3.15.2"
  [nodejs]="https://github.com/asdf-vm/asdf-nodejs.git $NODE_VER"
  [python]="https://github.com/asdf-community/asdf-python.git $PY_VER"
)
for name in "${!PLUGINS[@]}"; do
  IFS=' ' read -r repo ver <<<"${PLUGINS[$name]}"
  info "asdf-плагин $name → $ver"
  asdf plugin-remove "$name" 2>/dev/null || true
  asdf plugin-add "$name" "$repo"
  asdf install "$name" "$ver"
  asdf global "$name" "$ver"
done

### 8. Terraform вручную ###
info "Установка Terraform $TF_VER"
ARCH=$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')
ZIP="terraform_${TF_VER}_linux_${ARCH}.zip"
URL="https://releases.hashicorp.com/terraform/${TF_VER}/${ZIP}"
tmp=$(mktemp -d)
curl -fsSL "$URL" -o "$tmp/$ZIP" || die "Скачать Terraform"
unzip -q "$tmp/$ZIP" -d "$tmp"   || die "Распаковать Terraform"
sudo mv "$tmp/terraform" /usr/local/bin/
sudo chmod +x /usr/local/bin/terraform
rm -rf "$tmp"
echo "✅ $(terraform version | head -n1)"

### 9. Docker ###
info "Настройка Docker"
sudo groupadd docker 2>/dev/null || true
sudo usermod -aG docker "$USER"
sudo systemctl enable --now docker || echo "[WARN] Docker не запущен"
sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

### 10. pipx + Python utilities ###
info "Установка pipx и Python-утилит"
python3 -m pip install --user pipx
pipx ensurepath
export PATH="$HOME/.local/bin:$PATH"
for tool in poetry pre-commit ansible awscli; do
  command -v "$tool" &>/dev/null || pipx install "$tool"
done

### 11. Kind, terraform-docs, tflint ###
info "Установка дополнительных утилит"
sudo apt install -y terraform-docs tflint
if ! command -v kind &>/dev/null; then
  URL="https://kind.sigs.k8s.io/dl/$KIND_VER/kind-linux-${ARCH}"
  curl -fsSL -o kind "$URL"
  chmod +x kind && sudo mv kind /usr/local/bin/
fi

### 12. VS Code ###
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

### 13. Алиасы + new-project ###
info "Добавление алиасов и new-project"
cat <<'EOF' >>~/.zshrc

# === Алиасы ===
alias ls='eza --icons --group-directories-first'
alias ll='eza -l --icons --group-directories-first'
alias grep='rg'
alias cat='bat --paging=never'
alias tf='terraform'
alias k='kubectl'
alias dkc='docker compose'

new-project(){
  [ -z "$1" ] && { echo "Usage: new-project <name>"; return 1; }
  root="$LOCAL_PROJ"
  [ -d "$EXT_PROJ" ] && root="$EXT_PROJ"
  mkdir -p "$root/$1"/{src,tests,data,infra,docs}
  cd "$root/$1"
  git init
  python -m venv .venv && echo "source .venv/bin/activate" >.envrc
  direnv allow
  touch README.md .gitignore && echo "# $1" >README.md
  command -v code &>/dev/null && code .
}
EOF

### 14. Очистка ###
info "Очистка APT"
sudo apt autoremove -y
sudo apt clean
sudo rm -rf /var/lib/apt/lists/*

duration=$(( $(date +%s) - start_time ))
info "✅ Успешно завершено за ${duration}s"
info "Выполните: exec zsh"
info "Проверьте: ~/devops-audit.sh"
