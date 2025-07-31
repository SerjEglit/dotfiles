#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
trap 'echo "❌ Ошибка в строке $LINENO. Лог: $LOG"' ERR

# === КОНФИГУРАЦИЯ ESNSEY ================
TF_VERSION="1.9.5"
KIND_VERSION="v0.20.0"
PYTHON_VERSION="3.11.9"
ASDF_VERSION="v0.14.0"
EZA_VERSION="0.17.0"
LOG="$HOME/wsl-setup-$(date +%Y%m%d_%H%M%S).log"

# === ИНИЦИАЛИЗАЦИЯ ======================
clear
echo -e "\e[1;36m"
cat << "BANNER"
╭────────────────────────────────────────────────────────────╮
│        🚀 Запуск ESNsey DevOps Environment Installer       │
│     Автоматическая настройка профессиональной среды WSL2   │
╰────────────────────────────────────────────────────────────╯
BANNER
echo -e "\e[0m"

echo "▶️  Старт установки: $(date)"
echo "📝 Подробный лог: $LOG"
exec > >(tee -a "$LOG") 2>&1

if [ "$(id -u)" -eq 0 ]; then
  echo "❌ Ошибка: Скрипт не должен запускаться от root!" >&2
  exit 1
fi

# === ФУНКЦИИ ===========================
install_with_retry() {
  local cmd=$1
  local name=$2
  local max_attempts=3
  
  for attempt in $(seq 1 $max_attempts); do
    echo "Попытка $attempt: Установка $name..."
    if $cmd; then
      echo "✅ $name успешно установлен"
      return 0
    else
      echo "⚠️ Ошибка при установке $name, попытка $attempt из $max_attempts"
      sleep $((attempt * 2))
    fi
  done
  
  echo "❌ Критическая ошибка: Не удалось установить $name"
  return 1
}

# === 1. ОБНОВЛЕНИЕ СИСТЕМЫ =============
echo "🔄 Обновление системы и установка базовых пакетов..."
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y git curl wget unzip zsh build-essential \
  python3-pip python3-venv docker.io docker-compose jq \
  fzf ripgrep bat direnv gnupg2 ca-certificates pv

# === 2. УСТАНОВКА EZA ==================
install_eza() {
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) ARCH="x86_64";;
    aarch64) ARCH="aarch64";;
    *) echo "❌ Неподдерживаемая архитектура: $ARCH" >&2; return 1;;
  esac

  TMP=$(mktemp -d)
  URL="https://github.com/eza-community/eza/releases/download/v${EZA_VERSION}/eza_${EZA_VERSION}-${ARCH}-unknown-linux-gnu.tar.gz"
  
  curl -fsSL -o "$TMP/eza.tar.gz" "$URL"
  tar -xzf "$TMP/eza.tar.gz" -C "$TMP"
  sudo mv "$TMP/eza" /usr/local/bin/
  sudo chmod +x /usr/local/bin/eza
  rm -rf "$TMP"
}
install_with_retry install_eza "eza"

# === 3. ASDF И ЯЗЫКИ ===================
echo "🐍 Установка ASDF и языков программирования..."
if [ ! -d "$HOME/.asdf" ]; then
  git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch "$ASDF_VERSION" --depth=1
fi

. $HOME/.asdf/asdf.sh

declare -A plugins=(
  ["python"]="https://github.com/asdf-vm/asdf-python.git"
  ["nodejs"]="https://github.com/asdf-vm/asdf-nodejs.git"
  ["terraform"]="https://github.com/asdf-community/asdf-hashicorp.git"
)

for tool in "${!plugins[@]}"; do
  asdf plugin-add "$tool" "${plugins[$tool]}" || true
  asdf install "$tool" "$(asdf list-all "$tool" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
  asdf global "$tool" "$(asdf list "$tool" | tr -d ' *')"
done

# === 4. DOCKER И KUBERNETES ИНСТРУМЕНТЫ =
echo "🐳 Настройка Docker и Kubernetes..."
sudo groupadd docker 2>/dev/null || true
sudo usermod -aG docker "$USER"
sudo systemctl enable --now docker

install_with_retry \
  "curl -Lo ./kind https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && chmod +x ./kind && sudo mv ./kind /usr/local/bin/" \
  "kind"

# === 5. PYTHON ИНСТРУМЕНТЫ =============
echo "📦 Установка Python инструментов..."
python3 -m pip install --user pipx
python3 -m pipx ensurepath
export PATH="$HOME/.local/bin:$PATH"

declare -A python_tools=(
  ["poetry"]="poetry"
  ["pre-commit"]="pre-commit"
  ["awscli"]="awscli"
  ["ansible"]="ansible"
)

for tool in "${!python_tools[@]}"; do
  pipx install "${python_tools[$tool]}" || echo "⚠️ Не удалось установить $tool"
done

# === 6. VS CODE ========================
echo "🖥️ Установка VS Code..."
if ! command -v code &>/dev/null; then
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
  sudo install -o root -g root -m644 packages.microsoft.gpg /etc/apt/trusted.gpg.d/
  echo "deb [arch=amd64 signed-by=/etc/apt/trusted.gpg.d/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list
  sudo apt update
  sudo apt install -y code
  rm packages.microsoft.gpg
fi

# === 7. НАСТРОЙКА ZSH ==================
echo "✨ Настройка ZSH и Oh My Zsh..."
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k

# === 8. VPNGATE СКРИПТ =================
echo "🔒 Установка VPNGate скрипта..."
mkdir -p ~/scripts

cat << 'PYTHON' > ~/scripts/connect_vpngate.py
import requests
import os
from time import sleep

URL = "https://www.vpngate.net/api/iphone/"
LOG = os.path.expanduser("~/vpngate_log.txt")

def log(msg):
    with open(LOG, "a") as f:
        f.write(f"[VPNGate] {msg}\n")

def fetch_configs():
    try:
        log("🛰️ Запрашиваю данные с vpngate.net...")
        resp = requests.get(URL, timeout=10)
        resp.raise_for_status()
        log("✅ Данные получены успешно.")
        with open(os.path.expanduser("~/vpngate_list.csv"), "w") as f:
            f.write(resp.text)
        log("📄 Список серверов сохранён.")
    except requests.exceptions.RequestException as e:
        log(f"❌ Ошибка при получении данных: {e}")

if __name__ == "__main__":
    log("🚀 Запуск connect_vpngate.py")
    fetch_configs()
PYTHON

chmod +x ~/scripts/connect_vpngate.py

# === 9. КОНФИГУРАЦИЯ СРЕДЫ =============
echo "⚙️ Настройка окружения ESNsey..."
cat << 'ZSHRC' >> ~/.zshrc
# ========== ESNSEY CONFIG =============
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"

# ------ Алиасы ESNsey ------
alias ll='eza -lah --color=auto'
alias gs='git status'
alias gcm='git commit -m'
alias dcu='docker compose up -d'
alias dcd='docker compose down'
alias tfplan='terraform plan -out=tfplan'
alias tfapply='terraform apply tfplan'
alias k='kubectl'
alias vpngate='python3 ~/scripts/connect_vpngate.py'
alias env-audit='~/devops-audit.sh'
update-system() {
  sudo apt update
  sudo apt full-upgrade -y
  sudo apt autormove -y
}

# ------ Приветствие ESNsey ------
clear
echo -e "\e[1;36m"
cat << "BANNER"
╭────────────────────────────────────────────────────────────╮
│        🚀 Добро пожаловать в DevOps WSL-среду от ESNsey    │
│  🔧 Автоматизация. 🧠 Умные алиасы. ⚙️ Инфра как код.      │
│       🌐 ZSH • Python • Docker • K8s • Git • Cloud         │
╰────────────────────────────────────────────────────────────╯
BANNER
echo -e "\e[0m"

echo "📦 Zsh: $(zsh --version | awk '{print $2}')"
echo "🐍 Python: $(python3 --version | awk '{print $2}')"
echo "🟢 Node.js: $(node -v 2>/dev/null || echo 'не установлен')"
echo "📅 Дата: $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "\n🎨 Архитектор ESNsey активен. Используйте терминал с мудростью.\n"

# ------ Дополнительные настройки ------
[ -f "$HOME/.p10k.zsh" ] && source "$HOME/.p10k.zsh"
source $ZSH/oh-my-zsh.sh

# ------ Функция создания проекта ------
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
ZSHRC

# === 10. СКРИПТ АУДИТА ================
echo "📊 Создание скрипта аудита среды..."
cat << 'AUDIT' > ~/devops-audit.sh
#!/bin/bash
echo "=== ESNSEY ENVIRONMENT AUDIT ==="
echo "Дата: $(date)"
echo "Система: $(uname -a)"
echo "--------------------------------"

# Основные инструменты
tools=(
  git terraform node npm python pip docker 
  docker-compose poetry pre-commit kind kubectl
  zsh eza
)

for tool in "${tools[@]}"; do
  echo -n "🔧 $tool: "
  if command -v "$tool" &>/dev/null; then
    version=$("$tool" --version 2>&1 | head -n1)
    echo "${version//$tool/}" | xargs
  else
    echo "NOT INSTALLED"
  fi
done

# Проверка Docker
echo -e "\n🐳 Проверка Docker:"
docker run --rm hello-world | grep -i "Hello from Docker" && echo "Docker работает" || echo "Docker не работает"

# Проверка WSL
echo -e "\n🔍 Информация WSL:"
wsl.exe --list --verbose
AUDIT

chmod +x ~/devops-audit.sh

# === ЗАВЕРШЕНИЕ =======================
echo -e "\n✅ \e[1;32mУстановка завершена успешно!\e[0m"
echo "💻 Для применения изменений выполните:"
echo "   source ~/.zshrc"
echo "   exec zsh"
echo ""
echo "🛠️ Доступные команды:"
echo "   new-project <name>  - создать новый проект"
echo "   vpngate             - получить список VPN серверов"
echo "   env-audit           - проверить окружение"
echo "   update-system       - обновить систему"
echo ""
echo "📋 Лог установки: $LOG"
echo -e "\n\e[1;35mESNsey DevOps Environment готов к работе! 🚀\e[0m"
