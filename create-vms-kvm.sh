#!/usr/bin/env bash
# ============================================================
# CRIADOR INTERATIVO DE VMS KVM
# Libvirt + virt-install + Kickstart
# DHCP / IP estático por VM
# SSH Key + relatório completo
# ============================================================

set -Eeuo pipefail

DEFAULT_ISO="/var/lib/libvirt/images/isos/Rocky-9.8-x86_64-minimal.iso"
VM_DIR="${VM_DIR:-/var/lib/libvirt/images}"
DEFAULT_RAM=1024
DEFAULT_CPU=1
DEFAULT_DISK=20
DEFAULT_OS_SEARCH="Rocky"

# ISO pode ser passada como primeiro argumento.
ISO="${1:-${ISO:-$DEFAULT_ISO}}"

KS_DIR=$(mktemp -d /tmp/kvm-lab.XXXXXX)
trap 'rm -rf "$KS_DIR"' EXIT

REPORT_DIR="${REPORT_DIR:-$PWD}"
REPORT_FILE="$REPORT_DIR/relatorio-vms-$(date +%Y%m%d-%H%M%S).txt"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[AVISO]${NC} $*"; }
error()   { echo -e "${RED}[ERRO]${NC} $*" >&2; }

# ------------------------------------------------------------
# FUNCOES DE INTERACAO
# ------------------------------------------------------------

ask() {
    local prompt="$1"
    local default="${2:-}"
    local value

    if [[ -n "$default" ]]; then
        read -rp "$prompt [$default]: " value
        REPLY="${value:-$default}"
    else
        read -rp "$prompt: " value
        REPLY="$value"
    fi
}

ask_secret() {
    local prompt="$1"
    local value confirm

    while true; do
        read -rsp "$prompt: " value
        echo
        read -rsp "Confirme a senha: " confirm
        echo

        if [[ -n "$value" && "$value" == "$confirm" ]]; then
            REPLY="$value"
            return 0
        fi

        warn "Senhas vazias ou diferentes. Tente novamente."
    done
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-s}"
    local answer

    while true; do
        read -rp "$prompt (s/n) [$default]: " answer
        answer="${answer:-$default}"

        case "${answer,,}" in
            s|sim) return 0 ;;
            n|nao|não) return 1 ;;
            *) warn "Digite s ou n." ;;
        esac
    done
}

ask_number() {
    local prompt="$1"
    local default="$2"
    local value

    while true; do
        ask "$prompt" "$default"
        value="$REPLY"

        if [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 )); then
            REPLY="$value"
            return 0
        fi

        warn "Digite um número inteiro maior que zero."
    done
}

ask_nonnegative_number() {
    local prompt="$1"
    local default="$2"
    local value

    while true; do
        ask "$prompt" "$default"
        value="$REPLY"

        if [[ "$value" =~ ^[0-9]+$ ]]; then
            REPLY="$value"
            return 0
        fi

        warn "Digite um número inteiro maior ou igual a zero."
    done
}

make_hash() {
    local password="$1"
    openssl passwd -6 -stdin <<< "$password"
}

# ------------------------------------------------------------
# VALIDACAO E CONVERSAO DE REDE
# ------------------------------------------------------------

valid_ipv4() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    ipaddress.IPv4Address(sys.argv[1])
except ValueError:
    sys.exit(1)
PY
}

# Aceita máscara em CIDR (24) ou formato tradicional (255.255.255.0).
normalize_netmask() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

value = sys.argv[1]

try:
    if value.isdigit():
        prefix = int(value)
        if not 0 <= prefix <= 32:
            raise ValueError()
        print(ipaddress.IPv4Network(f"0.0.0.0/{prefix}").netmask)
    else:
        mask = ipaddress.IPv4Address(value)
        prefix = ipaddress.IPv4Network(f"0.0.0.0/{mask}").prefixlen
        print(mask)
except ValueError:
    sys.exit(1)
PY
}

validate_static_network() {
    local ip="$1"
    local mask="$2"
    local gateway="$3"
    local dns="$4"

    python3 - "$ip" "$mask" "$gateway" "$dns" <<'PY'
import ipaddress
import sys

ip, mask, gateway, dns = sys.argv[1:5]

try:
    interface = ipaddress.IPv4Interface(f"{ip}/{mask}")
    gw = ipaddress.IPv4Address(gateway)

    if gw not in interface.network:
        raise ValueError("Gateway fora da sub-rede do IP.")

    if gw == interface.ip:
        raise ValueError("Gateway não pode ser igual ao IP da VM.")

    for item in dns.split(","):
        ipaddress.IPv4Address(item.strip())

except ValueError as e:
    print(f"Erro: {e}", file=sys.stderr)
    sys.exit(1)
PY
}

# ------------------------------------------------------------
# CHAVE SSH
# ------------------------------------------------------------

setup_ssh_key() {
    local ssh_user ssh_home

    ssh_user="${SUDO_USER:-root}"
    ssh_home=$(getent passwd "$ssh_user" | cut -d: -f6)

    if [[ -z "$ssh_home" ]]; then
        error "Não foi possível determinar o diretório do usuário SSH."
        return 1
    fi

    SSH_KEY_DIR="$ssh_home/.ssh"
    SSH_KEY="$SSH_KEY_DIR/kvm-lab_ed25519"
    SSH_PUB_KEY="$SSH_KEY.pub"

    mkdir -p "$SSH_KEY_DIR"
    chmod 700 "$SSH_KEY_DIR"

    if [[ ! -f "$SSH_KEY" || ! -f "$SSH_PUB_KEY" ]]; then
        info "Gerando chave SSH ED25519..."

        if [[ "$ssh_user" == "root" ]]; then
            ssh-keygen -t ed25519 -N "" \
                -C "kvm-lab" \
                -f "$SSH_KEY"
        else
            sudo -u "$ssh_user" ssh-keygen \
                -t ed25519 -N "" \
                -C "kvm-lab" \
                -f "$SSH_KEY"
        fi

        success "Chave SSH criada."
    else
        info "Utilizando chave SSH existente: $SSH_KEY"
    fi

    chmod 600 "$SSH_KEY"
    chmod 644 "$SSH_PUB_KEY"

    SSH_PUBLIC_KEY=$(cat "$SSH_PUB_KEY")
}

# ------------------------------------------------------------
# SELECAO DO SISTEMA OPERACIONAL
# ------------------------------------------------------------

select_os_variant() {
    local search_term selected variant valid
    local -a matches=()

    echo
    echo "============================================================"
    echo "PESQUISA DO SISTEMA OPERACIONAL"
    echo "============================================================"

    while true; do
        ask "Qual sistema operacional? (Rocky, Fedora, Windows etc.)" "$DEFAULT_OS_SEARCH"
        search_term="$REPLY"

        if [[ -z "$search_term" ]]; then
            warn "Informe o nome do sistema operacional."
            continue
        fi

        echo
        info "Executando: osinfo-query os | grep -iF '$search_term'"
        echo

        osinfo-query os 2>/dev/null | grep -iF -- "$search_term" || true

        mapfile -t matches < <(
            osinfo-query os 2>/dev/null |
                grep -iF -- "$search_term" |
                awk -F'|' '{
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
                    if ($1 != "") print $1
                }'
        )

        if [[ ${#matches[@]} -eq 0 ]]; then
            warn "Nenhuma variante encontrada para '$search_term'."
            continue
        fi

        echo
        echo "Variantes disponíveis:"
        for variant in "${matches[@]}"; do
            echo " - $variant"
        done

        while true; do
            ask "Informe o ID exato do os-variant" "${matches[0]}"
            selected="$REPLY"
            valid=false

            for variant in "${matches[@]}"; do
                if [[ "$selected" == "$variant" ]]; then
                    valid=true
                    break
                fi
            done

            if $valid; then
                REPLY="$selected"
                return 0
            fi

            warn "ID não encontrado na lista."
        done
    done
}

# ------------------------------------------------------------
# CONFIGURACAO DE REDE POR VM
# ------------------------------------------------------------

configure_network() {
    local index="$1"
    local choice ip mask gateway dns

    echo
    echo "------------------------------------------------------------"
    echo "REDE DA VM: ${VM_NAMES[$index]}"
    echo "------------------------------------------------------------"

    while true; do
        echo "1) DHCP"
        echo "2) IP estático"
        ask "Escolha o tipo de configuração" "1"
        choice="$REPLY"

        case "$choice" in
            1)
                VM_NET_MODE[$index]="dhcp"
                VM_IP[$index]="DHCP"
                VM_MASK[$index]="-"
                VM_GATEWAY[$index]="-"
                VM_DNS[$index]="-"
                return 0
                ;;
            2)
                VM_NET_MODE[$index]="static"
                break
                ;;
            *)
                warn "Opção inválida."
                ;;
        esac
    done

    while true; do
        ask "Endereço IPv4 da VM"
        ip="$REPLY"

        if valid_ipv4 "$ip"; then
            break
        fi
        warn "Endereço IPv4 inválido."
    done

    while true; do
        ask "Máscara (ex.: 24 ou 255.255.255.0)" "24"
        mask="$REPLY"

        if mask=$(normalize_netmask "$mask"); then
            break
        fi
        warn "Máscara inválida."
    done

    while true; do
        ask "Gateway IPv4"
        gateway="$REPLY"

        if valid_ipv4 "$gateway"; then
            break
        fi
        warn "Gateway inválido."
    done

    while true; do
        ask "DNS (um ou mais IPs separados por vírgula)" "1.1.1.1,8.8.8.8"
        dns="${REPLY//[[:space:]]/}"

        if [[ -z "$dns" ]]; then
            warn "Informe pelo menos um DNS."
            continue
        fi

        if validate_static_network "$ip" "$mask" "$gateway" "$dns"; then
            break
        fi
        warn "Dados de rede inválidos. Revise IP, máscara, gateway e DNS."
    done

    VM_IP[$index]="$ip"
    VM_MASK[$index]="$mask"
    VM_GATEWAY[$index]="$gateway"
    VM_DNS[$index]="$dns"
}

# ------------------------------------------------------------
# VALIDACOES INICIAIS
# ------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    error "Execute como root."
    exit 1
fi

for cmd in virt-install virsh qemu-img openssl osinfo-query ssh-keygen python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "Comando ausente: $cmd"
        exit 1
    fi
done

if [[ ! -f "$ISO" ]]; then
    error "ISO não encontrada: $ISO"
    echo "Caminho atual: $ISO"
    ask "Informe o caminho completo da ISO"
    ISO="$REPLY"
fi

if [[ ! -f "$ISO" ]]; then
    error "ISO não encontrada: $ISO"
    exit 1
fi

ISO=$(readlink -f "$ISO")

if ! virsh uri >/dev/null 2>&1; then
    error "Não foi possível conectar ao libvirt."
    exit 1
fi

mkdir -p "$VM_DIR"
mkdir -p "$REPORT_DIR"

setup_ssh_key

# ------------------------------------------------------------
# ARRAYS
# ------------------------------------------------------------

declare -a VM_NAMES=()
declare -a VM_CPU=()
declare -a VM_RAM=()
declare -a VM_OS=()
declare -a VM_ROOT_HASH=()
declare -a VM_ROOT_ENABLED=()
declare -a VM_USER=()
declare -a VM_USER_HASH=()
declare -a VM_WHEEL=()
declare -a VM_NOPASSWD=()
declare -a VM_PACKAGES=()
declare -a VM_NETWORK=()
declare -a VM_NET_MODE=()
declare -a VM_IP=()
declare -a VM_MASK=()
declare -a VM_GATEWAY=()
declare -a VM_DNS=()
declare -a VM_DISK_SIZE=()
declare -a VM_DISK_NAME=()
declare -a VM_EXTRA_COUNT=()
declare -a VM_CREATE_STATUS=()
declare -a VM_SSH_COMMAND=()

declare -A VM_EXTRA_SIZE=()
declare -A VM_EXTRA_NAME=()

clear

echo "============================================================"
echo "             CRIADOR DE VMS - KVM"
echo "============================================================"
echo "ISO: $ISO"
echo "Diretório: $VM_DIR"
echo "Chave SSH: $SSH_KEY"
echo "Relatório: $REPORT_FILE"
echo

# ------------------------------------------------------------
# QUANTIDADE E NOMES DAS VMS
# ------------------------------------------------------------

ask_number "Quantidade de VMs" 5
VM_COUNT="$REPLY"

for ((i=1; i<=VM_COUNT; i++)); do
    while true; do
        echo
        ask "Nome da VM $i" "ansible-node$i"
        VM_NAME="$REPLY"

        if [[ ! "$VM_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
            warn "Nome inválido."
            continue
        fi

        duplicate=false

        for existing in "${VM_NAMES[@]}"; do
            if [[ "$existing" == "$VM_NAME" ]]; then
                duplicate=true
                break
            fi
        done

        if $duplicate; then
            warn "Nome duplicado."
            continue
        fi

        if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
            warn "A VM $VM_NAME já existe."
            continue
        fi

        VM_NAMES+=("$VM_NAME")
        break
    done
done

# ------------------------------------------------------------
# REDES LIBVIRT
# ------------------------------------------------------------

echo
echo "============================================================"
echo "REDES LIBVIRT ATIVAS"
echo "============================================================"

mapfile -t AVAILABLE_NETWORKS < <(
    virsh net-list --name | sed '/^[[:space:]]*$/d'
)

if [[ ${#AVAILABLE_NETWORKS[@]} -eq 0 ]]; then
    error "Nenhuma rede ativa encontrada."
    virsh net-list --all
    exit 1
fi

for network in "${AVAILABLE_NETWORKS[@]}"; do
    echo " - $network"
done

select_network() {
    local vm_name="$1"
    local selected valid

    while true; do
        echo
        ask "Rede libvirt para $vm_name" "${AVAILABLE_NETWORKS[0]}"
        selected="$REPLY"
        valid=false

        for network in "${AVAILABLE_NETWORKS[@]}"; do
            if [[ "$selected" == "$network" ]]; then
                valid=true
                break
            fi
        done

        if $valid; then
            REPLY="$selected"
            return 0
        fi

        warn "Rede inválida."
    done
}

echo
if ask_yes_no "Usar a mesma rede libvirt para todas as VMs?" "s"; then
    select_network "todas as VMs"
    GLOBAL_NETWORK="$REPLY"

    for ((i=0; i<VM_COUNT; i++)); do
        VM_NETWORK[$i]="$GLOBAL_NETWORK"
    done
else
    for ((i=0; i<VM_COUNT; i++)); do
        select_network "${VM_NAMES[$i]}"
        VM_NETWORK[$i]="$REPLY"
    done
fi

# ------------------------------------------------------------
# CONFIGURACAO DE REDE INDIVIDUAL
# ------------------------------------------------------------

echo
echo "============================================================"
echo "CONFIGURACAO IP POR MAQUINA"
echo "============================================================"

for ((i=0; i<VM_COUNT; i++)); do
    configure_network "$i"
done

# ------------------------------------------------------------
# DISCO PRINCIPAL
# ------------------------------------------------------------

echo
echo "============================================================"
echo "CONFIGURACAO DOS DISCOS PRINCIPAIS"
echo "============================================================"

if ask_yes_no "Mesmo tamanho de disco principal para todas as VMs?" "s"; then
    ask_number "Tamanho do disco em GB" "$DEFAULT_DISK"
    GLOBAL_DISK_SIZE="$REPLY"

    for ((i=0; i<VM_COUNT; i++)); do
        VM_DISK_SIZE[$i]="$GLOBAL_DISK_SIZE"
    done
else
    for ((i=0; i<VM_COUNT; i++)); do
        ask_number "Disco principal de ${VM_NAMES[$i]} em GB" "$DEFAULT_DISK"
        VM_DISK_SIZE[$i]="$REPLY"
    done
fi

echo
echo "============================================================"
echo "NOMES DOS DISCOS PRINCIPAIS"
echo "============================================================"

for ((i=0; i<VM_COUNT; i++)); do
    while true; do
        ask "Nome do disco de ${VM_NAMES[$i]}" "${VM_NAMES[$i]}.qcow2"
        DISK_NAME="$REPLY"

        if [[ ! "$DISK_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*\.qcow2$ ]]; then
            warn "Nome inválido. Use a extensão .qcow2."
            continue
        fi

        duplicate=false

        for ((j=0; j<i; j++)); do
            if [[ "${VM_DISK_NAME[$j]}" == "$DISK_NAME" ]]; then
                duplicate=true
                break
            fi
        done

        if $duplicate; then
            warn "Nome de disco duplicado."
            continue
        fi

        if [[ -e "$VM_DIR/$DISK_NAME" ]]; then
            warn "O arquivo já existe: $VM_DIR/$DISK_NAME"
            continue
        fi

        VM_DISK_NAME[$i]="$DISK_NAME"
        break
    done
done

# ------------------------------------------------------------
# DISCOS ADICIONAIS POR VM
# ------------------------------------------------------------

echo
echo "============================================================"
echo "DISCOS ADICIONAIS"
echo "============================================================"

for ((i=0; i<VM_COUNT; i++)); do
    echo
    echo "VM: ${VM_NAMES[$i]}"

    ask_nonnegative_number "Quantos discos adicionais deseja adicionar?" 0
    VM_EXTRA_COUNT[$i]="$REPLY"

    for ((j=1; j<=VM_EXTRA_COUNT[$i]; j++)); do
        echo
        echo "Disco adicional $j de ${VM_NAMES[$i]}"

        ask "Nome do disco adicional" "${VM_NAMES[$i]}-data$(printf '%02d' "$j").qcow2"
        extra_name="$REPLY"

        if [[ ! "$extra_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*\.qcow2$ ]]; then
            error "Nome inválido para disco adicional."
            exit 1
        fi

        if [[ -e "$VM_DIR/$extra_name" ]]; then
            error "O arquivo já existe: $VM_DIR/$extra_name"
            exit 1
        fi

        for ((k=0; k<VM_COUNT; k++)); do
            if [[ "${VM_DISK_NAME[$k]}" == "$extra_name" ]]; then
                error "Nome do disco adicional conflita com disco principal."
                exit 1
            fi
        done

        for ((k=0; k<i; k++)); do
            for ((m=1; m<=VM_EXTRA_COUNT[$k]; m++)); do
                if [[ "${VM_EXTRA_NAME["$k:$m"]:-}" == "$extra_name" ]]; then
                    error "Nome de disco adicional duplicado."
                    exit 1
                fi
            done
        done

        for ((m=1; m<j; m++)); do
            if [[ "${VM_EXTRA_NAME["$i:$m"]:-}" == "$extra_name" ]]; then
                error "Nome de disco adicional duplicado."
                exit 1
            fi
        done

        ask_number "Tamanho do disco adicional em GB" 10

        VM_EXTRA_NAME["$i:$j"]="$extra_name"
        VM_EXTRA_SIZE["$i:$j"]="$REPLY"

        echo "Disco: $extra_name"
        echo "Tamanho: ${VM_EXTRA_SIZE["$i:$j"]} GB"
    done
done

# ------------------------------------------------------------
# CONFIGURACOES GLOBAIS OU INDIVIDUAIS
# ------------------------------------------------------------

echo
echo "============================================================"
echo "CONFIGURACAO DAS MAQUINAS"
echo "============================================================"

if ask_yes_no "Mesmas configurações de CPU, RAM e SO para todas?" "s"; then
    CONFIG_MODE="global"
else
    CONFIG_MODE="individual"
fi

# ------------------------------------------------------------
# CONFIGURAR UMA VM
# ------------------------------------------------------------

configure_vm() {
    local index="$1"
    local name="${VM_NAMES[$index]}"
    local cpu ram os_variant
    local root_password root_hash
    local username user_password user_hash
    local user_wheel nopasswd
    local packages package_list
    local pkg
    local -a package_array=()

    echo
    echo "------------------------------------------------------------"
    echo "CONFIGURANDO: $name"
    echo "------------------------------------------------------------"

    ask_number "Quantidade de vCPUs" "$DEFAULT_CPU"
    cpu="$REPLY"

    ask_number "Memória RAM em MB" "$DEFAULT_RAM"
    ram="$REPLY"

    select_os_variant
    os_variant="$REPLY"

    root_enabled="no"
    root_hash=""

    if ask_yes_no "Habilitar acesso do root?" "n"; then
        root_enabled="yes"
        ask_secret "Senha do root"
        root_password="$REPLY"
        root_hash=$(make_hash "$root_password")
        unset root_password
    fi

    echo
    ask "Nome do usuário (vazio para não criar)" ""
    username="$REPLY"

    user_hash=""
    user_wheel="no"
    nopasswd="no"

    if [[ -n "$username" ]]; then
        if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
            error "Nome de usuário inválido: $username"
            return 1
        fi

        ask_secret "Senha do usuário $username"
        user_password="$REPLY"
        user_hash=$(make_hash "$user_password")
        unset user_password

        if ask_yes_no "Adicionar $username ao grupo wheel?" "s"; then
            user_wheel="yes"
        fi

        if ask_yes_no "Configurar sudo NOPASSWD?" "s"; then
            nopasswd="yes"
        fi
    fi

    echo
    ask "Pacotes adicionais (espaço ou vírgula)" ""
    packages="${REPLY//,/ }"
    package_list=""

    if [[ -n "$packages" ]]; then
        read -r -a package_array <<< "$packages"

        for pkg in "${package_array[@]}"; do
            if [[ ! "$pkg" =~ ^[a-zA-Z0-9_+.-]+$ ]]; then
                error "Nome de pacote inválido: $pkg"
                return 1
            fi

            case "$pkg" in
                openssh-server) continue ;;
            esac

            package_list+="$pkg"$'\n'
        done
    fi

    VM_CPU[$index]="$cpu"
    VM_RAM[$index]="$ram"
    VM_OS[$index]="$os_variant"
    VM_ROOT_HASH[$index]="$root_hash"
    VM_ROOT_ENABLED[$index]="$root_enabled"
    VM_USER[$index]="$username"
    VM_USER_HASH[$index]="$user_hash"
    VM_WHEEL[$index]="$user_wheel"
    VM_NOPASSWD[$index]="$nopasswd"
    VM_PACKAGES[$index]="$package_list"
}

if [[ "$CONFIG_MODE" == "global" ]]; then
    configure_vm 0

    for ((i=1; i<VM_COUNT; i++)); do
        VM_CPU[$i]="${VM_CPU[0]}"
        VM_RAM[$i]="${VM_RAM[0]}"
        VM_OS[$i]="${VM_OS[0]}"
        VM_ROOT_HASH[$i]="${VM_ROOT_HASH[0]}"
        VM_ROOT_ENABLED[$i]="${VM_ROOT_ENABLED[0]}"
        VM_USER[$i]="${VM_USER[0]}"
        VM_USER_HASH[$i]="${VM_USER_HASH[0]}"
        VM_WHEEL[$i]="${VM_WHEEL[0]}"
        VM_NOPASSWD[$i]="${VM_NOPASSWD[0]}"
        VM_PACKAGES[$i]="${VM_PACKAGES[0]}"
    done
else
    for ((i=0; i<VM_COUNT; i++)); do
        configure_vm "$i"
    done
fi

# ------------------------------------------------------------
# RESUMO ANTES DA CRIACAO
# ------------------------------------------------------------

echo
echo "============================================================"
echo "RESUMO DAS VMS"
echo "============================================================"

for ((i=0; i<VM_COUNT; i++)); do
    echo
    echo "VM:             ${VM_NAMES[$i]}"
    echo "Sistema:        ${VM_OS[$i]}"
    echo "CPU:            ${VM_CPU[$i]}"
    echo "RAM:            ${VM_RAM[$i]} MB"
    echo "Rede libvirt:   ${VM_NETWORK[$i]}"
    echo "Tipo de IP:     ${VM_NET_MODE[$i]}"
    echo "IP:             ${VM_IP[$i]}"
    echo "Máscara:        ${VM_MASK[$i]}"
    echo "Gateway:        ${VM_GATEWAY[$i]}"
    echo "DNS:            ${VM_DNS[$i]}"
    echo "Disco principal: ${VM_DISK_NAME[$i]} (${VM_DISK_SIZE[$i]} GB)"

    for ((j=1; j<=VM_EXTRA_COUNT[$i]; j++)); do
        echo "Disco adicional: ${VM_EXTRA_NAME["$i:$j"]} (${VM_EXTRA_SIZE["$i:$j"]} GB)"
    done

    echo "Usuário:        ${VM_USER[$i]:-(nenhum)}"
done

echo
echo "ISO: $ISO"
echo "Chave SSH: $SSH_KEY"

echo
if ! ask_yes_no "Confirmar criação das VMs?" "n"; then
    warn "Operação cancelada."
    exit 0
fi

# ------------------------------------------------------------
# GERAR KICKSTART
# ------------------------------------------------------------

generate_kickstart() {
    local index="$1"
    local name="${VM_NAMES[$index]}"
    local ks_file="$KS_DIR/${name}.ks"
    local pkg
    local network_line

    {
        echo "#version=RHEL9"
        echo "text"
        echo "eula --agreed"
        echo "firstboot --disable"
        echo "lang pt_BR.UTF-8"
        echo "keyboard --vckeymap=br-abnt2 --xlayouts='br'"
        echo "timezone America/Fortaleza --utc"

        if [[ "${VM_NET_MODE[$index]}" == "dhcp" ]]; then
            echo "network --bootproto=dhcp --device=link --activate --hostname=${name}"
        else
            network_line="network --device=link --bootproto=static"
            network_line+=" --ip=${VM_IP[$index]}"
            network_line+=" --netmask=${VM_MASK[$index]}"
            network_line+=" --gateway=${VM_GATEWAY[$index]}"
            network_line+=" --nameserver=${VM_DNS[$index]}"
            network_line+=" --activate --hostname=${name}"
            echo "$network_line"
        fi

        echo "firewall --enabled --service=ssh"
        echo "selinux --enforcing"
        echo "services --enabled=sshd"
        echo "ignoredisk --only-use=vda"
        echo "clearpart --all --initlabel --drives=vda"
        echo "autopart --type=lvm"

        if [[ "${VM_ROOT_ENABLED[$index]}" == "yes" ]]; then
            echo "rootpw --iscrypted ${VM_ROOT_HASH[$index]}"
        else
            echo "rootpw --lock"
        fi

        if [[ -n "${VM_USER[$index]}" ]]; then
            if [[ "${VM_WHEEL[$index]}" == "yes" ]]; then
                echo "user --name=${VM_USER[$index]} --password=${VM_USER_HASH[$index]} --iscrypted --groups=wheel"
            else
                echo "user --name=${VM_USER[$index]} --password=${VM_USER_HASH[$index]} --iscrypted"
            fi

            echo "sshkey --username=${VM_USER[$index]} \"${SSH_PUBLIC_KEY}\""
        fi

        echo "%packages"
        echo "@^minimal-environment"
        echo "openssh-server"

        if [[ -n "${VM_PACKAGES[$index]}" ]]; then
            while IFS= read -r pkg; do
                [[ -n "$pkg" ]] && echo "$pkg"
            done <<< "${VM_PACKAGES[$index]}"
        fi

        echo "%end"

        echo "%post --log=/root/ks-post.log"
        echo "systemctl enable sshd"

        if [[ -n "${VM_USER[$index]}" && "${VM_NOPASSWD[$index]}" == "yes" ]]; then
            echo "echo '${VM_USER[$index]} ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/${VM_USER[$index]}"
            echo "chmod 440 /etc/sudoers.d/${VM_USER[$index]}"
        fi

        echo "%end"
        echo "reboot"
    } > "$ks_file"

    chmod 600 "$ks_file"
}

# ------------------------------------------------------------
# CRIACAO DAS VMS
# ------------------------------------------------------------

echo
echo "============================================================"
echo "INICIANDO INSTALACOES"
echo "============================================================"

for ((i=0; i<VM_COUNT; i++)); do
    name="${VM_NAMES[$i]}"
    disk="$VM_DIR/${VM_DISK_NAME[$i]}"
    ks_file="$KS_DIR/${name}.ks"

    VM_CREATE_STATUS[$i]="Não iniciada"
    VM_SSH_COMMAND[$i]=""

    generate_kickstart "$i"

    info "Criando disco principal de $name..."

    if ! qemu-img create -f qcow2 "$disk" "${VM_DISK_SIZE[$i]}G"; then
        error "Falha ao criar disco principal de $name."
        VM_CREATE_STATUS[$i]="Falha ao criar disco principal"
        continue
    fi

    declare -a EXTRA_ARGS=()
    disk_error=false

    for ((j=1; j<=VM_EXTRA_COUNT[$i]; j++)); do
        extra_name="${VM_EXTRA_NAME["$i:$j"]}"
        extra_size="${VM_EXTRA_SIZE["$i:$j"]}"
        extra_path="$VM_DIR/$extra_name"

        info "Criando disco adicional $extra_name..."

        if ! qemu-img create -f qcow2 "$extra_path" "${extra_size}G"; then
            error "Falha ao criar disco adicional $extra_name."
            disk_error=true
            break
        fi

        EXTRA_ARGS+=(--disk "path=$extra_path,format=qcow2,bus=virtio")
    done

    if [[ "$disk_error" == true ]]; then
        error "Instalação de $name não iniciada."
        VM_CREATE_STATUS[$i]="Falha ao criar disco adicional"
        continue
    fi

    info "Iniciando instalação de $name..."

    if virt-install \
        --name "$name" \
        --memory "${VM_RAM[$i]}" \
        --vcpus "${VM_CPU[$i]}" \
        --cpu host-model \
        --os-variant "${VM_OS[$i]}" \
        --disk "path=$disk,format=qcow2,bus=virtio" \
        "${EXTRA_ARGS[@]}" \
        --network "network=${VM_NETWORK[$i]},model=virtio" \
        --graphics none \
        --console pty,target_type=serial \
        --location "$ISO" \
        --initrd-inject "$ks_file" \
        --extra-args "inst.ks=file:/$(basename "$ks_file") console=ttyS0,115200n8" \
        --noautoconsole
    then
        success "Instalação iniciada para $name."
        VM_CREATE_STATUS[$i]="Instalação iniciada"
    else
        error "Falha ao iniciar $name."
        VM_CREATE_STATUS[$i]="Falha no virt-install"
        warn "Os discos criados foram mantidos."
    fi

    unset EXTRA_ARGS
done

# ------------------------------------------------------------
# RELATORIO
# ------------------------------------------------------------

{
    echo "============================================================"
    echo "RELATORIO DE CRIACAO DE VMS KVM"
    echo "============================================================"
    echo
    echo "Data: $(date '+%d/%m/%Y %H:%M:%S %Z')"
    echo "Host: $(hostname -f 2>/dev/null || hostname)"
    echo "Libvirt URI: $(virsh uri 2>/dev/null || echo indisponível)"
    echo "ISO: $ISO"
    echo "Diretório das VMs: $VM_DIR"
    echo "Chave SSH privada: $SSH_KEY"
    echo "Chave SSH pública: $SSH_PUB_KEY"
    echo "Modo de configuração de CPU/RAM/SO: $CONFIG_MODE"
    echo "Quantidade de VMs solicitadas: $VM_COUNT"
    echo
    echo "============================================================"
    echo "DETALHES DAS MAQUINAS"
    echo "============================================================"

    for ((i=0; i<VM_COUNT; i++)); do
        echo
        echo "------------------------------------------------------------"
        echo "VM: ${VM_NAMES[$i]}"
        echo "------------------------------------------------------------"
        echo "Status da criação: ${VM_CREATE_STATUS[$i]}"
        echo "Sistema operacional (os-variant): ${VM_OS[$i]}"
        echo "vCPUs: ${VM_CPU[$i]}"
        echo "RAM: ${VM_RAM[$i]} MB"
        echo "Rede libvirt: ${VM_NETWORK[$i]}"
        echo "Tipo de rede: ${VM_NET_MODE[$i]}"
        echo "IP: ${VM_IP[$i]}"
        echo "Máscara: ${VM_MASK[$i]}"
        echo "Gateway: ${VM_GATEWAY[$i]}"
        echo "DNS: ${VM_DNS[$i]}"
        echo "Disco principal: $VM_DIR/${VM_DISK_NAME[$i]}"
        echo "Tamanho do disco principal: ${VM_DISK_SIZE[$i]} GB"
        echo "Usuário: ${VM_USER[$i]:-(nenhum)}"
        echo "Root habilitado: ${VM_ROOT_ENABLED[$i]}"
        echo "Usuário no wheel: ${VM_WHEEL[$i]}"
        echo "Sudo NOPASSWD: ${VM_NOPASSWD[$i]}"
        echo "Discos adicionais: ${VM_EXTRA_COUNT[$i]}"

        for ((j=1; j<=VM_EXTRA_COUNT[$i]; j++)); do
            echo "  - ${VM_EXTRA_NAME["$i:$j"]}: ${VM_EXTRA_SIZE["$i:$j"]} GB"
        done

        if [[ "${VM_NET_MODE[$i]}" == "static" ]]; then
            echo "Comando SSH:"
            if [[ -n "${VM_USER[$i]}" ]]; then
                printf 'ssh -i "%s" %s@%s\n' "$SSH_KEY" "${VM_USER[$i]}" "${VM_IP[$i]}"
            else
                echo "Não disponível: usuário não configurado."
            fi
        else
            echo "IP DHCP: consultar após a instalação."
            echo "Comando SSH: consultar o IP atribuído pelo DHCP."
        fi
    done

    echo
    echo "============================================================"
    echo "CHAVE SSH PUBLICA"
    echo "============================================================"
    cat "$SSH_PUB_KEY"

    echo
    echo "============================================================"
    echo "ESTADO ATUAL DO LIBVIRT"
    echo "============================================================"
    virsh list --all

    echo
    echo "============================================================"
    echo "OBSERVACOES"
    echo "============================================================"
    echo "O status acima representa a criação/inicialização pelo virt-install."
    echo "Não confirma que a instalação do sistema operacional terminou."
    echo "As VMs DHCP podem receber IP posteriormente."
    echo "O acesso SSH depende da conclusão do Kickstart e da conectividade."
} > "$REPORT_FILE"

# ------------------------------------------------------------
# SAIDA FINAL
# ------------------------------------------------------------

echo
echo "============================================================"
echo "PROCESSO FINALIZADO"
echo "============================================================"

virsh list --all

echo
echo "Relatório completo salvo em:"
echo "$REPORT_FILE"

echo
echo "============================================================"
echo "COMANDOS DE ACESSO SSH"
echo "============================================================"

for ((i=0; i<VM_COUNT; i++)); do
    echo
    echo "VM: ${VM_NAMES[$i]}"

    if [[ -z "${VM_USER[$i]}" ]]; then
        echo "Sem usuário configurado."
        continue
    fi

    if [[ "${VM_NET_MODE[$i]}" == "static" ]]; then
        printf 'ssh -i "%s" %s@%s\n' "$SSH_KEY" "${VM_USER[$i]}" "${VM_IP[$i]}"
    else
        echo "IP via DHCP. Consulte:"
        echo "virsh domifaddr ${VM_NAMES[$i]} --source lease"
        echo "ou:"
        echo "virsh net-dhcp-leases ${VM_NETWORK[$i]}"
        printf 'ssh -i "%s" %s@IP_DA_VM\n' "$SSH_KEY" "${VM_USER[$i]}"
    fi
done

echo
info "Relatório: $REPORT_FILE"
info "Console: virsh console NOME-DA-VM"
info "Para sair do console: Ctrl + ]"
