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
source "$HOME/.asdf/asdf.sh"

# Функция для безопасной установки плагина
install_asdf_plugin() {
  local plugin=$1 repo=$2
  echo "Установка плагина: $plugin"
  
  # Удаляем плагин, если он был установлен с ошибкой
  if asdf plugin-list | grep -q "$plugin"; then
    asdf plugin-remove "$plugin" >/dev/null 2>&1
  fi
  
  # Устанавливаем заново
  asdf plugin-add "$plugin" "$repo" || {
    echo "❌ Ошибка установки плагина $plugin"
    return 1
  }
  
  return 0
}

# Функция для установки конкретной версии
install_asdf_version() {
  local plugin=$1 version=$2
  echo "Установка $plugin $version"
  
  # Устанавливаем версию
  asdf install "$plugin" "$version" || {
    echo "❌ Ошибка установки $plugin $version"
    return 1
  }
  
  # Устанавливаем как глобальную
  asdf global "$plugin" "$version"
  return 0
}

step 6 "Инструменты DevOps через asdf"

# Список инструментов для установки
declare -A tools=(
  ["terraform"]="1.9.5"
  ["kubectl"]="1.30.0"
  ["helm"]="3.15.2"
  ["nodejs"]="20.14.0"
  ["python"]="$PYTHON_VERSION"
)

declare -A repos=(
  ["terraform"]="https://github.com/asdf-community/asdf-hashicorp.git"
  ["kubectl"]="https://github.com/asdf-community/asdf-kubectl.git"
  ["helm"]="https://github.com/asdf-community/asdf-helm.git"
  ["nodejs"]="https://github.com/asdf-vm/asdf-nodejs.git"
  ["python"]="https://github.com/asdf-vm/asdf-python.git"
)

for tool in "${!tools[@]}"; do
  version="${tools[$tool]}"
  repo="${repos[$tool]}"
  
  echo "➡️  Установка $tool $version"
  install_asdf_plugin "$tool" "$repo"
  install_asdf_version "$tool" "$version"
done

### 8. Настройка Docker ###
step 7 "Настройка Docker"
sudo groupadd docker 2>/dev/null || true
sudo usermod -aG docker "$USER"
sudo systemctl enable --now docker || echo "[WARN] Docker не запущен"

# Добавлено из temporary-files: решение проблем с правами
sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

### 9. Установка pipx и утилит ###
step 8 "Установка pipx и Python-утилит"
command -v pipx >/dev/null || python3 -m pip install --user pipx
pipx ensurepath
if ! grep -q '.local/bin' ~/.zshrc; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
fi

# Улучшенная установка из temporary-files
PYTHON_TOOLS=(poetry pre-commit ansible awscli)
for tool in "${PYTHON_TOOLS[@]}"; do
  if ! command -v "$tool" &>/dev/null; then
    pipx install "$tool" || echo "⚠️ Не удалось установить $tool"
  else
    echo "✅ $tool уже установлен"
  fi
done

### 10. Дополнительные инструменты DevOps ###
step 9 "Доп. DevOps‑утилиты"
install_packages() { sudo apt install -y "$@"; }
install_packages terraform-docs tflint

# Улучшенная установка Kind из temporary-files
if ! command -v kind &>/dev/null; then
  ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
  KIND_URL="https://kind.sigs.k8s.io/dl/$KIND_VERSION/kind-linux-$ARCH"
  
  echo "Скачивание Kind: $KIND_URL"
  curl -Lo kind "$KIND_URL"
  chmod +x kind
  sudo mv kind /usr/local/bin/
  echo "✅ kind установлен"
else
  echo "✅ kind уже установлен"
fi

### 11. Установка VS Code ###
step 10 "Установка VS Code"
if ! command -v code &>/dev/null; then
  # Улучшенный метод из temporary-files
  sudo apt-get install -y wget gpg
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
  sudo install -D -o root -g root -m644 packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | \
    sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
  sudo apt update
  sudo apt install -y code
  rm packages.microsoft.gpg
  echo "✅ VS Code установлен"
else
  echo "✅ VS Code уже установлен"
fi

### 12. Конфигурация Zsh: псевдонимы и функции ###
step 11 "Добавление псевдонимов и new-project"

# Добавлены улучшения из temporary-files:
# - Проверка существования алиасов
# - Дополнительные полезные алиасы
# - Улучшенная функция new-project

grep -q "alias ls=" ~/.zshrc || cat << 'EOF' >> ~/.zshrc
# Автомонтирование внешнего диска
if [ -d "/mnt/e" ]; then
  sudo mkdir -p /mnt/e/projects && sudo chown -R $USER:$USER /mnt/e/projects
fi

# Автозапуск SSH-агента
if [ -z "$SSH_AUTH_SOCK" ] && [ -f ~/.ssh/id_ed25519 ]; then
  eval "$(ssh-agent -s)" >/dev/null
  ssh-add ~/.ssh/id_ed25519 2>/dev/null
fi

# Псевдонимы
alias ls='eza --icons --group-directories-first'
alias ll='eza -l --icons --group-directories-first'
alias la='eza -la --icons --group-directories-first'
alias cat='bat --paging=never'
alias grep='rg'
alias find='fd'
alias du='dust'
alias top='btm'
alias ps='procs'
alias tf='terraform'
alias k='kubectl'
alias dkc='docker compose'
alias update='sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y'
alias gs='git status'
alias gc='git commit'
alias gp='git push'
alias wsl-update='sudo apt update && sudo apt full-upgrade -y && sudo apt autoremove -y'

# Улучшенная функция создания проекта
new-project() {
  [ -z "$1" ] && { echo "Usage: new-project <name>" >&2; return 1; }
  
  local project_root="$HOME/projects"
  [ -d "/mnt/e/projects" ] && project_root="/mnt/e/projects"
  
  mkdir -p "$project_root/$1"/{src,tests,data,configs,infra,docs}
  cd "$project_root/$1"
  
  git init
  python -m venv .venv
  echo "source .venv/bin/activate" > .envrc
  direnv allow
  
  # Создаем базовые файлы
  touch README.md .gitignore
  echo "# $1" > README.md
  
  # Открываем в VSCode если установлен
  if command -v code &>/dev/null; then
    code .
  else
    echo "VSCode не установлен, проект создан в $PWD"
  fi
}
EOF

### 13. Скрипт аудита ###
step 12 "Создание devops-audit.sh"

# Улучшенный скрипт из temporary-files:
# - Проверка большего количества инструментов
# - Более четкий вывод
# - Проверка версий в едином стиле

cat << 'AUDIT' > ~/devops-audit.sh
#!/usr/bin/env bash
echo "=== DevOps Environment Audit ==="
echo "Дата: $(date)"
echo "Система: $(uname -a)"
echo "--------------------------------"

# Проверка основных инструментов
declare -A tools=(
  ["git"]="--version"
  ["terraform"]="version"
  ["kubectl"]="version --client"
  ["helm"]="version"
  ["node"]="--version"
  ["python"]="--version"
  ["docker"]="--version"
  ["ansible"]="--version"
  ["eza"]="--version"
  ["kind"]="--version"
  ["zsh"]="--version"
)

max_len=0
for tool in "${!tools[@]}"; do
  [ ${#tool} -gt $max_len ] && max_len=${#tool}
done

for tool in "${!tools[@]}"; do
  printf "%-${max_len}s : " "$tool"
  if command -v "$tool" &>/dev/null; then
    version=$($tool ${tools[$tool]} 2>&1 | head -n1 | sed 's/^[^0-9]*//')
    echo "${version:-Установлен, но версия недоступна}"
  else
    echo "НЕ УСТАНОВЛЕН"
  fi
done

echo -e "\n### Проверка Docker ###"
docker run --rm hello-world | grep -i "Hello from Docker" || echo "Docker не работает"

echo -e "\n### Проверка WSLg ###"
if [ -n "$DISPLAY" ]; then
  echo "WSLg: Активен (DISPLAY=$DISPLAY)"
else
  echo "WSLg: Неактивен"
fi

echo -e "\n### Проверка WSL ###"
wsl.exe --list --verbose
AUDIT

chmod +x ~/devops-audit.sh

### 14. Очистка и финал ###
step 13 "Очистка APT"
sudo apt autoremove -y
sudo apt clean
sudo rm -rf /var/lib/apt/lists/*

END_TIME=$(date +%s)
RUNTIME=$((END_TIME - START_TIME))

echo -e "\n✅ Установка завершена за $RUNTIME сек."
echo "Лог доступен в $LOG_FILE"
echo "Для применения изменений выполните:"
echo "  exec zsh"
echo "Для проверки окружения:"
echo "  ~/devops-audit.sh"
