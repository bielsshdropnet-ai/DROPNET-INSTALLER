#!/usr/bin/env bash
# DROPNET INSTALLER
# Instalador otimizado baseado no fluxo do script fornecido.
# Compatibilidade: Debian/Ubuntu (x86_64 e ARM64), com systemd quando disponível.

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.0"
APP_NAME="DROPNET INSTALLER"
LOG_FILE="/var/log/dropnet-installer.log"
BACKUP_DIR="/root/dropnet-backup-$(date +%Y%m%d-%H%M%S)"
USER_DB="${HOME}/usuarios.db"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
RESET='\033[0m'

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" 2>/dev/null || true
}
info() { printf "${CYAN}%s${RESET}\n" "$*"; }
success() { printf "${GREEN}%s${RESET}\n" "$*"; }
warn() { printf "${YELLOW}%s${RESET}\n" "$*"; }
error() { printf "${RED}%s${RESET}\n" "$*" >&2; }

cleanup() {
    [[ -t 1 ]] && tput cnorm 2>/dev/null || true
}
trap cleanup EXIT

fail() {
    error "ERRO: $*"
    log "ERRO: $*"
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "Você precisa executar como root."
        echo "Use: sudo bash DROPNET_INSTALLER.sh"
        exit 1
    fi
}

check_os() {
    [[ -r /etc/os-release ]] || fail "Não foi possível identificar a distribuição."
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
        debian|ubuntu|linuxmint|pop)
            ;;
        *)
            case " ${ID_LIKE:-} " in
                *" debian "*|*" ubuntu "*) ;;
                *) fail "Sistema não suportado: ${PRETTY_NAME:-desconhecido}. Use Debian ou Ubuntu." ;;
            esac
            ;;
    esac

    case "$(uname -m)" in
        x86_64|aarch64|arm64) ;;
        *) warn "Arquitetura $(uname -m) detectada. O instalador tentará continuar, mas alguns pacotes podem não estar disponíveis." ;;
    esac
}

show_banner() {
    clear 2>/dev/null || true
    printf "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
    printf "${CYAN}       ⇱ BEM-VINDO AO DROPNET ⇲${RESET}\n"
    printf "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n\n"
    printf "${RED}ATENÇÃO!${RESET} Este instalador irá preparar ferramentas do servidor.\n"
    printf "• Instalar dependências de rede e sistema\n"
    printf "• Preparar Python e speedtest-cli\n"
    printf "• Preservar ou recriar a base usuarios.db\n"
    printf "• Configurar regras de firewall mediante confirmação\n\n"
    printf "${YELLOW}Compatibilidade: Debian/Ubuntu em VPS x86_64 e ARM64.${RESET}\n"
    printf "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n\n"
}

show_install_menu() {
    printf "${CYAN}====================================${RESET}\n"
    printf "${CYAN}          MENU DE INSTALAÇÃO        ${RESET}\n"
    printf "${CYAN}====================================${RESET}\n"
    printf "${WHITE}[1]${RESET} Iniciar instalação\n"
    printf "${WHITE}[2]${RESET} Sair e cancelar instalação\n\n"
    read -r -p "Digite 1 para instalar ou 2 para sair: " option
    case "$option" in
        1) info "Iniciando a instalação..." ;;
        2) warn "Instalação cancelada pelo usuário."; exit 0 ;;
        *) error "Opção inválida."; exit 1 ;;
    esac
}

progress() {
    local message="$1"
    printf "%s " "$message"
    for _ in {1..18}; do
        printf "${RED}#${RESET}"
        sleep 0.035
    done
    printf " ${GREEN}OK!${RESET}\n"
}

backup_configs() {
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    for file in /etc/ssh/sshd_config /etc/ufw/user.rules /etc/ufw/user6.rules; do
        if [[ -f "$file" ]]; then
            cp -a "$file" "$BACKUP_DIR/"
        fi
    done
    log "Backup de configurações salvo em $BACKUP_DIR"
}

prepare_user_database() {
    if [[ -f "$USER_DB" ]]; then
        clear 2>/dev/null || true
        printf "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
        printf "Uma base ${GREEN}usuarios.db${RESET} foi encontrada.\n"
        printf "Deseja preservar os usuários existentes?\n"
        printf "${WHITE}[1]${RESET} Manter base de dados atual\n"
        printf "${WHITE}[2]${RESET} Criar uma nova base de dados\n"
        read -r -p "Opção [1]: " option_db
        option_db="${option_db:-1}"
        case "$option_db" in
            1) success "Base de dados atual preservada."; return ;;
            2) ;;
            *) warn "Opção inválida. A base atual será preservada."; return ;;
        esac
    fi

    awk -F: '$3 >= 500 && $1 != "nobody" { print $1 " 1" }' /etc/passwd > "$USER_DB"
    chmod 600 "$USER_DB"
    success "Base usuarios.db criada."
}

update_system() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
}

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    local packages=(
        bc screen nano unzip lsof net-tools dos2unix nload jq
        curl wget git figlet boxes lolcat
        python3 python3-pip python3-venv
        uuid-runtime socat
    )

    apt-get install -y --no-install-recommends "${packages[@]}"

    # speedtest-cli em ambiente virtual: evita conflito com o Python do sistema.
    if command -v python3 >/dev/null 2>&1; then
        python3 -m venv /opt/dropnet-venv
        /opt/dropnet-venv/bin/python -m pip install --upgrade pip
        /opt/dropnet-venv/bin/pip install speedtest-cli
        ln -sf /opt/dropnet-venv/bin/speedtest /usr/local/bin/speedtest 2>/dev/null || true
    fi
}

configure_ssh_safely() {
    local ssh_file="/etc/ssh/sshd_config"
    [[ -f "$ssh_file" ]] || {
        warn "sshd_config não encontrado; configuração SSH ignorada."
        return 0
    }

    if grep -Eq '^[[:space:]]*Port[[:space:]]+22222([[:space:]]|$)' "$ssh_file"; then
        echo
        warn "Foi encontrada a porta SSH 22222."
        read -r -p "Deseja alterar para a porta 22? (s/N): " answer
        if [[ "$answer" =~ ^[sS]$ ]]; then
            cp -a "$ssh_file" "${ssh_file}.dropnet.bak"
            sed -i -E 's/^[[:space:]]*Port[[:space:]]+22222([[:space:]]|$)/Port 22\1/' "$ssh_file"
            if command -v sshd >/dev/null 2>&1 && sshd -t; then
                if command -v systemctl >/dev/null 2>&1; then
                    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
                else
                    service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
                fi
                success "Configuração SSH atualizada para a porta 22."
            else
                cp -a "${ssh_file}.dropnet.bak" "$ssh_file"
                error "Configuração SSH inválida. Backup restaurado."
            fi
        else
            info "Porta SSH mantida sem alterações."
        fi
    else
        info "Nenhuma configuração SSH na porta 22222 foi encontrada."
    fi
}

configure_firewall() {
    local ports=(80/tcp 8989/tcp 5454/tcp 8888/tcp 8080/tcp 7300/udp 443/tcp 3128/tcp 8799/tcp)
    echo
    warn "O firewall será alterado somente com sua autorização."
    printf "As regras incluem: %s\n" "${ports[*]}"
    read -r -p "Deseja liberar essas portas? (s/N): " answer
    [[ "$answer" =~ ^[sS]$ ]] || {
        info "Firewall não foi alterado."
        return 0
    }

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
        local port
        for port in "${ports[@]}"; do ufw allow "$port" || true; done
        ufw reload || true
        success "Regras aplicadas no UFW."
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        local port
        for port in "${ports[@]}"; do firewall-cmd --permanent --add-port="$port" || true; done
        firewall-cmd --reload || true
        success "Regras aplicadas no Firewalld."
    else
        warn "Nenhum UFW/Firewalld ativo foi detectado. Nenhuma regra foi aplicada."
        warn "Não instalamos nem ativamos firewall automaticamente para evitar bloquear seu acesso SSH."
    fi
}

write_bashrc() {
    local bashrc="/root/.bashrc"
    local marker="# >>> DROPNET LOGIN >>>"
    if ! grep -Fq "$marker" "$bashrc" 2>/dev/null; then
        cat >> "$bashrc" <<'EOF'

# >>> DROPNET LOGIN >>>
if [[ $- == *i* ]]; then
    DATE=$(date +"%d-%m-%Y")
    HORA=$(date +"%T")
    if command -v figlet >/dev/null 2>&1; then
        figlet -f standard DROPNET 2>/dev/null || true
    fi
    printf '\033[1;32m NOME DO SERVIDOR: \033[1;36m%s\n' "$HOSTNAME"
    printf '\033[1;32m SERVIDOR LIGADO: \033[1;36m%s\n' "$(uptime -p 2>/dev/null || echo indisponível)"
    printf '\033[1;32m DATA: \033[1;36m%s\n' "$DATE"
    printf '\033[1;32m HORA: \033[1;36m%s\n' "$HORA"
    printf '\033[1;32m DIGITE: \033[1;36mmenu\033[0m\n\n'
fi
# <<< DROPNET LOGIN <<<
EOF
        success "Personalização adicionada ao /root/.bashrc."
    else
        info "Personalização DROPNET já existe no /root/.bashrc."
    fi
}

show_finish() {
    echo
    printf "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
    printf "${GREEN}       INSTALAÇÃO CONCLUÍDA!${RESET}\n"
    printf "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
    printf "Para iniciar, digite: ${CYAN}menu${RESET}\n"
    printf "Log: ${YELLOW}%s${RESET}\n" "$LOG_FILE"
    printf "Backup: ${YELLOW}%s${RESET}\n" "$BACKUP_DIR"
    echo
    warn "Os módulos externos do script antigo (v2raymanager, botteste.sh e ShellBot.sh) não foram baixados automaticamente."
    warn "Instale-os somente após conferir o repositório oficial e a procedência dos arquivos."
}

main() {
    require_root
    check_os
    mkdir -p /var/log
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"

    show_banner
    show_install_menu
    backup_configs

    echo
    progress "ATUALIZANDO SISTEMA"
    update_system >>"$LOG_FILE" 2>&1 || fail "Falha ao atualizar o sistema. Consulte $LOG_FILE"

    echo
    prepare_user_database

    echo
    progress "INSTALANDO PACOTES"
    install_packages >>"$LOG_FILE" 2>&1 || fail "Falha ao instalar pacotes. Consulte $LOG_FILE"

    echo
    progress "VERIFICANDO CONFIGURAÇÃO SSH"
    configure_ssh_safely

    echo
    progress "CONFIGURANDO FIREWALL"
    configure_firewall

    echo
    progress "FINALIZANDO CONFIGURAÇÕES"
    write_bashrc

    log "Instalação DROPNET concluída."
    show_finish
}

main "$@"
