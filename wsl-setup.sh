#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

### 0. Проверка контекста WSL ###
if ! grep -qi microsoft /proc/version; then
  echo "❌ Ошибка: скрипт предназначен для WSL2!" >&2
  exit 1
fi

### 1. Конфигурация ###
ASDF_VERSION="v0.14.0"
KIND_VERSION="v0.20.0"
PYTHON_VERSION="3.11.9"
EZA_VERSION="0.17.0"
LOCAL_PROJECTS="$HOME/projects"
EXTERNAL_PROJECTS="/mnt/e/projects"

### 2. Логирование и тайминг ###
START_TIME=$(date +%s)
LOG_FILE="$HOME/wsl-setup-$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "🚀 Запуск автонастройки WSL2: $(date)"
echo "Лог: $LOG_FILE"
echo "----------------------------------------"

# Функция для вывода прогресса
step() {
  echo -e "\n▶️  Шаг $1: $2"
}

### 3. Проверка интернет-соединения ###
step 1 "Проверка сети"
if ! curl -fsI https://github.com >/dev/null; then
  echo "❌ Нет интернет‑связи. Проверьте подключение." >&2
  exit 1
fi

### 4. Установка базовых пакетов ###
step 2 "Установка APT-пакетов"
sudo apt update
sudo apt install -y \
  git curl wget zsh build-essential python3-pip python3-venv unzip \
  docker.io docker-compose jq fzf ripgrep bat direnv curl gnupg2 ca-certificates \
  pv

### 5. Установка eza ###
step 3 "Установка eza (Modern exa)"
install_eza() {
    local version="$1"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH="x86_64";;
        aarch64) ARCH="aarch64";;
        *) echo "❌ Неподдерживаемая архитектура: $ARCH" >&2; return 1;;
    esac

    TMP=$(mktemp -d)
    URL="https://github.com/eza-community/eza/releases/download/v${version}/eza_${version}-${ARCH}-unknown-linux-gnu.tar.gz"
    
    echo "Скачивание eza: $URL"
    if ! curl -fsSL -o "$TMP/eza.tar.gz" "$URL"; then
        echo "❌ Ошибка скачивания eza" >&2
        rm -rf "$TMP"
        return 1
    fi
    
    echo "Распаковка архива"
    if ! tar -xzf "$TMP/eza.tar.gz" -C "$TMP"; then
        echo "❌ Ошибка распаковки архива" >&2
        rm -rf "$TMP"
        return 1
    fi
    
    echo "Установка в /usr/local/bin"
    sudo mv "$TMP/eza" /usr/local/bin/
    sudo chmod +x /usr/local/bin/eza
    rm -rf "$TMP"
    return 0
}

if ! command -v eza &>/dev/null; then
    for attempt in {1..3}; do
        echo "Попытка установки #$attempt"
        if install_eza "$EZA_VERSION"; then
            echo "✅ eza успешно установлена"
            break
        fi
        
        if [ $attempt -eq 3 ]; then
            echo "❌ Не удалось установить eza после 3 попыток" >&2
            echo "Попробуйте установить вручную:"
            echo "  curl -sL https://raw.githubusercontent.com/eza-community/eza/main/install.sh | bash"
            exit 1
        fi
        
        sleep 5
    done
else
    echo "✅ eza уже установлена"
fi

### 6. Настройка Zsh и Powerlevel10k ###
step 4 "Настройка Zsh"
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi
P10K_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
if [ ! -d "$P10K_DIR" ]; then
  git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR"
fi
grep -qx 'ZSH_THEME="powerlevel10k/powerlevel10k"' ~/.zshrc || \
  sed -i 's/^ZSH_THEME=.*/ZSH_THEME="powerlevel10k\/powerlevel10k"/' ~/.zshrc

### 7. Установка asdf и плагинов ###
step 5 "Установка asdf $ASDF_VERSION"
if [ ! -d "$HOME/.asdf" ]; then
  git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch "$ASDF_VERSION" --depth=1
fi
grep -qx '. $HOME/.asdf/asdf.sh' ~/.zshrc || {
  echo -e '\n. $HOME/.asdf/asdf.sh' >> ~/.zshrc
  echo -e '. $HOME/.asdf/completions/asdf.bash' >> ~/.zshrc
}
. "$HOME/.asdf/asdf.sh"

install_asdf() {
  local plugin=$1 repo=$2
  asdf plugin-list | grep -qx "$plugin" || asdf plugin-add "$plugin" "$repo"
  local latest=$(asdf list-all "$plugin" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
  asdf list "$plugin" | grep -qx "$latest" || asdf install "$plugin" "$latest"
  asdf global "$plugin" "$latest"
}
step 6 "Инструменты DevOps через asdf"
install_asdf terraform https://github.com/asdf-community/asdf-hashicorp.git
install_asdf kubectl   https://github.com/asdf-community/asdf-kubectl.git
install_asdf helm      https://github.com/asdf-community/asdf-helm.git
install_asdf nodejs    https://github.com/asdf-vm/asdf-nodejs.git
install_asdf python    https://github.com/asdf-vm/asdf-python.git

### 8. Пинning Python версии ###
step 7 "Pin Python $PYTHON_VERSION"
asdf install python "$PYTHON_VERSION" || true
asdf global python   "$PYTHON_VERSION"

### 9. Настройка Docker ###
step 8 "Настройка Docker"
sudo groupadd docker 2>/dev/null || true
sudo usermod -aG docker "$USER"
sudo systemctl enable --now docker || echo "[WARN] Docker не запущен"

### 10. Установка pipx и утилит ###
step 9 "Установка pipx и Python-утилит"
command -v pipx >/dev/null || python3 -m pip install --user pipx
pipx ensurepath
if ! grep -q '.local/bin' ~/.zshrc; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
fi
pipx install poetry        || true
pipx install pre-commit    || true
pipx install ansible       || true
pipx install awscli        || true

### 11. Дополнительные инструменты DevOps ###
step 10 "Доп. DevOps‑утилиты"
install_packages() { sudo apt install -y "$@"; }
install_packages terraform-docs tflint
if ! command -v kind &>/dev/null; then
  ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
  curl -Lo kind "https://kind.sigs.k8s.io/dl/$KIND_VERSION/kind-linux-$ARCH"
  chmod +x kind && sudo mv kind /usr/local/bin/
fi

### 12. Установка VS Code ###
step 11 "Установка VS Code"
if ! command -v code &>/dev/null; then
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor > packages.microsoft.gpg
  sudo install -o root -g root -m644 packages.microsoft.gpg /etc/apt/trusted.gpg.d/
  echo "deb [arch=amd64 signed-by=/etc/apt/trusted.gpg.d/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    | sudo tee /etc/apt/sources.list.d/vscode.list
  sudo apt update
  sudo apt install -y code
  rm packages.microsoft.gpg
fi

### 13. Конфигурация Zsh: псевдонимы и функции ###
step 12 "Добавление псевдонимов и new-project"
cat << 'EOF' >> ~/.zshrc
# Автомонтирование внешнего диска
if [ -d "/mnt/e" ]; then
  sudo mkdir -p /mnt/e/projects && sudo chown -R $USER:$USER /mnt/e/projects
fi

# SSH‑агент
if [ -z "$SSH_AUTH_SOCK" ] && [ -f ~/.ssh/id_ed25519 ]; then
  eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519
fi

# Псевдонимы
alias ls='eza --icons --group-directories-first'
alias ll='eza -l --icons --group-directories-first'
alias la='eza -la --icons --group-directories-first'
alias cat='bat --paging=never'
alias tf='terraform'
alias k='kubectl'
alias dkc='docker compose'
alias update='sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y'

# Шаблон проекта
new-project() {
  [ -z "$1" ] && { echo "Usage: new-project <name>"; return 1; }
  pr="$HOME/projects"; [ -d "/mnt/e/projects" ] && pr="/mnt/e/projects"
  mkdir -p "$pr/$1"/{src,tests,data,configs,infra} && cd "$pr/$1"
  git init && python -m venv .venv
  echo "source .venv/bin/activate" > .envrc && direnv allow
  code .
}
EOF

### 14. Скрипт аудита ###
step 13 "Создание devops-audit.sh"
cat << 'AUDIT' > ~/devops-audit.sh
#!/usr/bin/env bash
echo "=== DevOps Environment Audit ==="
echo "Дата: $(date)"
echo "Система: $(uname -a)"

tools=(git terraform kubectl helm node python docker ansible eza)
for t in "${tools[@]}"; do
  v=$($t --version 2>/dev/null | head -n1)
  printf "%-12s: %s\n" "$t" "${v:-NOT INSTALLED}"
done

echo -e "\n=== WSLg ==="
command -v weston &>/dev/null && echo "WSLg: OK" || echo "WSLg: N/A"

echo -e "\n=== Docker ==="
docker --version
docker run --rm hello-world 2>&1 | head -n2

echo -e "\n=== WSL ==="
wsl.exe --list --verbose
AUDIT
chmod +x ~/devops-audit.sh

### 15. Очистка и финал ###
step 14 "Очистка APT"
sudo apt autoremove -y
sudo apt clean

END_TIME=$(date +%s)
echo -e "\n✅ Установка завершена за $((END_TIME-START_TIME)) сек."
echo "Лог доступен в $LOG_FILE"
echo "Перезапустите терминал: exec zsh"
