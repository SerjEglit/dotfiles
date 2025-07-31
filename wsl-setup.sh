#!/usr/bin/env bash
# wsl-setup.sh — Автонастройка WSL2 для DevOps
set -euo pipefail
IFS=$'\n\t'

### 0. Проверка среды + CRLF→LF ###
if ! grep -qi microsoft /proc/version; then
  echo "❌ Ошибка: скрипт — только для WSL2!" >&2
  exit 1
fi
# Если есть DOS-концы, убираем их
sed -i 's/\r$//' "$0"

### Логирование ###
LOG="$HOME/wsl-setup-$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
info(){ echo -e "\n▶️  $1"; }
die (){ echo "❌ $1" >&2; exit 1; }

start=$(date +%s)
info "Старт: $(date)  (лог: $LOG)"

### 1. Конфиг ###
ASDF_VER="v0.14.0"
KIND_VER="v0.20.0"
PYTHON_VER="3.11.9"
EZA_VER="0.17.0"
TF_VER="1.9.5"
LOCAL="$HOME/projects"
EXT="/mnt/e/projects"

### 2. Сеть ###
info "Проверка сети"
curl -fsI https://github.com >/dev/null || die "Нет интернета"

### 3. APT-пакеты ###
info "Установка базовых пакетов"
sudo apt update
sudo apt install -y git curl wget zsh build-essential python3-pip python3-venv unzip \
  docker.io docker-compose jq fzf ripgrep bat direnv gnupg2 ca-certificates pv dos2unix

### 4. eza ###
install_tool(){
  local name=$1 ver=$2 url=$3
  command -v "$name" &>/dev/null && { echo "✅ $name есть"; return; }
  info "Устанавливаем $name $ver"
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/$name.tgz" || die "Скачивание $name"
  tar -xzf "$tmp/$name.tgz" -C "$tmp" || die "Распаковка $name"
  sudo mv "$tmp/$name" /usr/local/bin/"$name"
  sudo chmod +x /usr/local/bin/"$name"
  rm -rf "$tmp"
  echo "✅ $name установлен"
}
install_tool eza "$EZA_VER" \
  "https://github.com/eza-community/eza/releases/download/v${EZA_VER}/eza_${EZA_VER}-$(uname -m)-unknown-linux-gnu.tar.gz"

### 5. Zsh + Powerlevel10k ###
info "Oh-My-Zsh & Powerlevel10k"
[ -d "$HOME/.oh-my-zsh" ] \
  || RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
P10K="$HOME/.oh-my-zsh/custom/themes/powerlevel10k"
[ -d "$P10K" ] || git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K"
grep -qx 'ZSH_THEME="powerlevel10k/powerlevel10k"' ~/.zshrc \
  || echo 'ZSH_THEME="powerlevel10k/powerlevel10k"' >> ~/.zshrc

### 6. asdf + плагины ###
info "asdf $ASDF_VER"
[ -d "$HOME/.asdf" ] \
  || git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch "$ASDF_VER" --depth=1
grep -qx '. $HOME/.asdf/asdf.sh' ~/.zshrc \
  || printf "\n. \$HOME/.asdf/asdf.sh\n. \$HOME/.asdf/completions/asdf.bash\n" >> ~/.zshrc
source "$HOME/.asdf/asdf.sh"

declare -A PLUGINS=(
  [kubectl]="https://github.com/asdf-community/asdf-kubectl.git 1.30.0"
  [helm]="https://github.com/asdf-community/asdf-helm.git 3.15.2"
  [nodejs]="https://github.com/asdf-vm/asdf-nodejs.git 20.14.0"
  # переключаемся на SSH URL, чтобы не спрашивать пароль
  [python]="git@github.com:asdf-vm/asdf-python.git $PYTHON_VER"
)
for name in "${!PLUGINS[@]}"; do
  IFS=' ' read -r repo ver <<<"${PLUGINS[$name]}"
  info "asdf-плагин $name → $ver"
  asdf plugin-remove "$name" 2>/dev/null || true
  asdf plugin-add "$name" "$repo"
  asdf install "$name" "$ver"
  asdf global "$name" "$ver"
done

### 7. Terraform вручную ###
info "Terraform $TF_VER"
ARCH=$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')
ZIP="terraform_${TF_VER}_linux_${ARCH}.zip"
URL="https://releases.hashicorp.com/terraform/${TF_VER}/${ZIP}"
tmp=$(mktemp -d)
curl -fsSL "$URL" -o "$tmp/$ZIP" || die "Скачать Terraform"
unzip -q "$tmp/$ZIP" -d "$tmp"   || die "Распаковываем Terraform"
sudo mv "$tmp/terraform" /usr/local/bin/
sudo chmod +x /usr/local/bin/terraform
rm -rf "$tmp"
echo "✅ $(terraform version | head -n1)"

### 8. Docker ###
info "Docker"
sudo groupadd docker 2>/dev/null || true
sudo usermod -aG docker "$USER"
sudo systemctl enable --now docker || echo "[WARN] Docker не запущен"
sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

### 9. pipx + Python-утилиты ###
info "Python-утилиты через pipx"
python3 -m pip install --user pipx
pipx ensurepath
export PATH="$HOME/.local/bin:$PATH"
for util in poetry pre-commit ansible awscli; do
  command -v "$util" &>/dev/null || pipx install "$util"
done

### 10. Kind, terraform-docs, tflint ###
info "Доп. DevOps-утилиты"
sudo apt install -y terraform-docs tflint
if ! command -v kind &>/dev/null; then
  URL="https://kind.sigs.k8s.io/dl/$KIND_VER/kind-linux-${ARCH}"
  curl -fsSL -o kind "$URL"
  chmod +x kind && sudo mv kind /usr/local/bin/
fi

### 11. VS Code ###
info "VS Code"
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

### 12. Алиасы + new-project ###
info "Aлиасы и new-project"
cat <<'EOF' >>~/.zshrc

# === Алиасы ===
alias ls='eza --icons --group-directories-first'
alias ll='eza -l --icons --group-directories-first'
alias grep='rg'
alias cat='bat --paging=never'
alias tf='terraform'
alias k='kubectl'
alias dkc='docker compose'

new-project() {
  [ -z "$1" ] && { echo "Usage: new-project <name>"; return 1; }
  root="$LOCAL"; [ -d "$EXT" ] && root="$EXT"
  mkdir -p "$root/$1"/{src,tests,data,infra,docs}
  cd "$root/$1"
  git init
  python -m venv .venv && echo "source .venv/bin/activate" >.envrc
  direnv allow
  touch README.md .gitignore && echo "# $1" >README.md
  command -v code &>/dev/null && code .
}
EOF

### 13. Очистка ###
info "Очистка APT"
sudo apt autoremove -y
sudo apt clean
sudo rm -rf /var/lib/apt/lists/*

duration=$(( $(date +%s) - start ))
info "✅ Готово за ${duration}s"
info "Чтобы применить: exec zsh"
info "Проверьте: ~/devops-audit.sh"
