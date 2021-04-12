#!/bin/bash


export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

exiterr() { echo "Error: $1" >&2; exit 1; }
bigecho() { echo "## $1"; }
bigecho2() { printf '\e[2K\r%s' "## $1"; }

check_ip() {
  IP_REGEX='^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$'
  printf '%s' "$1" | tr -d '\n' | grep -Eq "$IP_REGEX"
}

check_dns_name() {
  FQDN_REGEX='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
  printf '%s' "$1" | tr -d '\n' | grep -Eq "$FQDN_REGEX"
}

check_run_as_root() {
  if [ "$(id -u)" != 0 ]; then
    exiterr "Скрипт должен запускаться от имени root. Пытаться 'sudo bash $0'"
  fi
}

check_os_type() {
  os_arch=$(uname -m | tr -dc 'A-Za-z0-9_-')
  if grep -qs -e "release 7" -e "release 8" /etc/redhat-release; then
    os_type=centos
    if grep -qs "Red Hat" /etc/redhat-release; then
      os_type=rhel
    fi
    if grep -qs "release 7" /etc/redhat-release; then
      os_ver=7
    elif grep -qs "release 8" /etc/redhat-release; then
      os_ver=8
    fi
  elif grep -qs "Amazon Linux release 2" /etc/system-release; then
    os_type=amzn
    os_ver=2
  else
    os_type=$(lsb_release -si 2>/dev/null)
    [ -z "$os_type" ] && [ -f /etc/os-release ] && os_type=$(. /etc/os-release && printf '%s' "$ID")
    case $os_type in
      [Uu]buntu)
        os_type=ubuntu
        ;;
      [Dd]ebian)
        os_type=debian
        ;;
      [Rr]aspbian)
        os_type=raspbian
        ;;
      *)
        exiterr "Этот скрипт поддерживает только Ubuntu, Debian, CentOS / RHEL 7/8 и Amazon Linux.2."
        ;;
    esac
    os_ver=$(sed 's/\..*//' /etc/debian_version | tr -dc 'A-Za-z0-9')
  fi
}

get_update_url() {
  update_url=vpnupgrade
  if [ "$os_type" = "centos" ] || [ "$os_type" = "rhel" ]; then
    update_url=vpnupgrade-centos
  elif [ "$os_type" = "amzn" ]; then
    update_url=vpnupgrade-amzn
  fi
  update_url="https://git.io/$update_url"
}

check_swan_install() {
  ipsec_ver=$(/usr/local/sbin/ipsec --version 2>/dev/null)
  swan_ver=$(printf '%s' "$ipsec_ver" | sed -e 's/Linux Libreswan //' -e 's/ (netkey).*//' -e 's/^U//' -e 's/\/K.*//')
  if ( ! grep -qs "hwdsl2 VPN script" /etc/sysctl.conf && ! grep -qs "hwdsl2" /opt/src/run.sh ) \
    || ! printf '%s' "$ipsec_ver" | grep -q "Libreswan"; then
cat 1>&2 <<'EOF'
Ошибка: вы должны сначала настроить IPsec VPN-сервер перед настройкой Cicada-IKEv2..
       Смотри тут >>> : https://github.com/hwdsl2/setup-ipsec-vpn
EOF
    exit 1
  fi

  case $swan_ver in
    3.2[35679]|3.3[12]|4.*)
      true
      ;;
    *)
      get_update_url
cat 1>&2 <<EOF
Ошибка: версия Libreswan "$ swan_ver" не поддерживается.
       Для этого скрипта требуется одна из следующих версий:
       3.23, 3.25–3.27, 3.29, 3.31–3.32 или 4.x
       Чтобы обновить Libreswan, запустите:
       wget $update_url -O vpnupgrade.sh
       sudo sh vpnupgrade.sh
EOF
      exit 1
      ;;
  esac
}

check_utils_exist() {
  command -v certutil >/dev/null 2>&1 || exiterr "'certutil' не найден. Прервать."
  command -v pk12util >/dev/null 2>&1 || exiterr "'pk12util' не найден. Прервать."
}

check_container() {
  in_container=0
  if grep -qs "hwdsl2" /opt/src/run.sh; then
    in_container=1
  fi
}

show_usage() {
  if [ -n "$1" ]; then
    echo "Error: $1" >&2;
  fi
cat 1>&2 <<EOF
Применение: bash $0 [параметров]

Параметры:
  --auto                        запустите настройку Cicada-IKEv2 в автоматическом режиме с параметрами по умолчанию (только для начальной настройки Cicada-IKEv2)
  --addclient [client name]     добавить нового клиента Cicada-IKEv2 с параметрами по умолчанию (после установки Cicada-IKEv2)
  --exportclient [client name]  экспортировать существующий клиент Cicada-IKEv2, используя параметры по умолчанию (после настройки Cicada-IKEv2)
  --listclients                 перечислить имена существующих клиентов Cicada-IKEv2 (после настройки Cicada-IKEv2)
  --removeikev2                 удалить Cicada-IKEv2 и удалить все сертификаты и ключи из базы данных IPsec
  -h, --help                    показать это справочное сообщение и выйти

Чтобы настроить Cicada-IKEv2 или параметры клиента, запустите этот сценарий без аргументов..
EOF
  exit 1
}

check_ikev2_exists() {
  grep -qs "conn ikev2-cp" /etc/ipsec.conf || [ -f /etc/ipsec.d/ikev2.conf ]
}

check_client_name() {
  ! { [ "${#client_name}" -gt "64" ] || printf '%s' "$client_name" | LC_ALL=C grep -q '[^A-Za-z0-9_-]\+' \
    || case $client_name in -*) true;; *) false;; esac; }
}

check_client_cert_exists() {
  certutil -L -d sql:/etc/ipsec.d -n "$client_name" >/dev/null 2>&1
}

check_arguments() {
  if [ "$use_defaults" = "1" ]; then
    if check_ikev2_exists; then
      echo "Предупреждение: игнорирование параметра'--auto'. Использовать '-h' для информации об использовании." >&2
      echo >&2
    fi
  fi
  if [ "$((add_client_using_defaults + export_client_using_defaults + list_clients))" -gt 1 ]; then
    show_usage "Неверные параметры. Укажите только один из '--addclient', '--exportclient' or '--listclients'."
  fi
  if [ "$add_client_using_defaults" = "1" ]; then
    ! check_ikev2_exists && exiterr "Перед добавлением нового клиента необходимо сначала настроить Cicada-IKEv2.."
    if [ -z "$client_name" ] || ! check_client_name; then
      exiterr "Неверное имя клиента. Используйте только одно слово, никаких специальных символов, кроме '-' а также '_'."
    elif check_client_cert_exists; then
      exiterr "Неверное имя клиента. Клиент '$client_name' уже существует."
    fi
  fi
  if [ "$export_client_using_defaults" = "1" ]; then
    ! check_ikev2_exists && exiterr "Перед экспортом конфигурации клиента необходимо сначала настроить Cicada-IKEv2.."
    get_server_address
    if [ -z "$client_name" ] || ! check_client_name \
      || [ "$client_name" = "IKEv2 VPN CA" ] || [ "$client_name" = "$server_addr" ] \
      || ! check_client_cert_exists; then
      exiterr "Неверное имя клиента или клиент не существует."
    fi
  fi
  if [ "$list_clients" = "1" ]; then
    ! check_ikev2_exists && exiterr "Перед перечислением клиентов необходимо сначала настроить Cicada-IKEv2.."
  fi
  if [ "$remove_ikev2" = "1" ]; then
    ! check_ikev2_exists && exiterr "Невозможно удалить Cicada-IKEv2, потому что он не был настроен на этом сервере."
    if [ "$((add_client_using_defaults + export_client_using_defaults + list_clients + use_defaults))" -gt 0 ]; then
      show_usage "Неверные параметры. '--removeikev2' нельзя указать с другими параметрами."
    fi
  fi
}

check_server_dns_name() {
  if [ -n "$VPN_DNS_NAME" ]; then
    check_dns_name "$VPN_DNS_NAME" || exiterr "Неверное DNS-имя. 'VPN_DNS_NAME' должно быть полное доменное имя (FQDN)."
  fi
}

check_custom_dns() {
  if { [ -n "$VPN_DNS_SRV1" ] && ! check_ip "$VPN_DNS_SRV1"; } \
    || { [ -n "$VPN_DNS_SRV2" ] && ! check_ip "$VPN_DNS_SRV2"; } then
    exiterr "Указанный DNS-сервер недействителен."
  fi
}

check_ca_cert_exists() {
  if certutil -L -d sql:/etc/ipsec.d -n "IKEv2 VPN CA" >/dev/null 2>&1; then
    exiterr "Сертификат 'IKEv2 VPN CA' уже существует."
  fi
}

check_server_cert_exists() {
  if certutil -L -d sql:/etc/ipsec.d -n "$server_addr" >/dev/null 2>&1; then
    echo "Ошибка: сертификат'$server_addr' уже существует." >&2
    echo "Прервать. Никаких изменений не было." >&2
    exit 1
  fi
}

check_swan_ver() {
  if [ "$in_container" = "0" ]; then
    swan_ver_url="https://dl.ls20.com/v1/$os_type/$os_ver/swanverikev2?arch=$os_arch&ver=$swan_ver&auto=$use_defaults"
  else
    swan_ver_url="https://dl.ls20.com/v1/docker/$os_arch/swanverikev2?ver=$swan_ver&auto=$use_defaults"
  fi
  swan_ver_latest=$(wget -t 3 -T 15 -qO- "$swan_ver_url")
}

run_swan_update() {
  get_update_url
  TMPDIR=$(mktemp -d /tmp/vpnupg.XXX 2>/dev/null)
  if [ -d "$TMPDIR" ]; then
    set -x
    if wget -t 3 -T 30 -q -O "$TMPDIR/vpnupg.sh" "$update_url"; then
      /bin/sh "$TMPDIR/vpnupg.sh"
    fi
    { set +x; } 2>&-
    [ ! -s "$TMPDIR/vpnupg.sh" ] && echo "Ошибка: не удалось загрузить скрипт обновления.." >&2
    /bin/rm -f "$TMPDIR/vpnupg.sh"
    /bin/rmdir "$TMPDIR"
  else
    echo "Ошибка: не удалось создать временный каталог.." >&2
  fi
  read -n 1 -s -r -p "Нажмите любую клавишу, чтобы продолжить настройку Cicada-IKEv2...."
  echo
}

select_swan_update() {
  if printf '%s' "$swan_ver_latest" | grep -Eq '^([3-9]|[1-9][0-9])\.([0-9]|[1-9][0-9])$' \
    && [ "$swan_ver" != "$swan_ver_latest" ] \
    && printf '%s\n%s' "$swan_ver" "$swan_ver_latest" | sort -C -V; then
    echo "Примечание: более новая версия Libreswan ($swan_ver_latest) доступена."
    echo "      Перед настройкой Cicada-IKEv2 рекомендуется обновить Libreswan.."
    if [ "$in_container" = "0" ]; then
      echo
      printf "Хотите обновить Libreswan?[Y/n] "
      read -r response
      case $response in
        [yY][eE][sS]|[yY]|'')
          echo
          run_swan_update
          ;;
        *)
          echo
          ;;
      esac
    else
      echo "      Чтобы обновить этот образ Docker, см.: https://git.io/updatedockervpn"
      echo
      printf "Вы все равно хотите продолжить? [y/N] "
      read -r response
      case $response in
        [yY][eE][sS]|[yY])
          echo
          ;;
        *)
          echo "Прервать. Никаких изменений не было."
          exit 1
          ;;
      esac
    fi
  fi
}

show_welcome_message() {
cat <<'EOF'
Добро пожаловать! Используйте этот сценарий для настройки Cicada-IKEv2 после настройки собственного сервера IPsec VPN.
Кроме того, вы можете вручную настроить Cicada-IKEv2. Смотреть тут >>> : https://git.io/ikev2

Прежде чем приступить к настройке, мне нужно задать вам несколько вопросов.
Вы можете использовать параметры по умолчанию и просто нажать Enter, если вас устраивает..

EOF
}

show_start_message() {
  bigecho "Запуск установки Cicada-IKEv2 в автоматическом режиме с параметрами по умолчанию."
}

show_add_client_message() {
  bigecho "Добавление нового клиента Cicada-IKEv2 '$client_name', с использованием параметров по умолчанию."
}

show_export_client_message() {
  bigecho "Экспорт существующего клиента Cicada-IKEv2 '$client_name', с использованием параметров по умолчанию."
}

get_export_dir() {
  export_to_home_dir=0
  if grep -qs "hwdsl2" /opt/src/run.sh; then
    export_dir="/etc/ipsec.d/"
  else
    export_dir=~/
    if [ -n "$SUDO_USER" ] && getent group "$SUDO_USER" >/dev/null 2>&1; then
      user_home_dir=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
      if [ -d "$user_home_dir" ] && [ "$user_home_dir" != "/" ]; then
        export_dir="$user_home_dir/"
        export_to_home_dir=1
      fi
    fi
  fi
}

get_server_ip() {
  bigecho2 "Пытаюсь автоматически определить IP этого сервера..."
  public_ip=$(dig @resolver1.opendns.com -t A -4 myip.opendns.com +short)
  check_ip "$public_ip" || public_ip=$(wget -t 3 -T 15 -qO- http://ipv4.icanhazip.com)
}

get_server_address() {
  server_addr=$(grep -s "leftcert=" /etc/ipsec.d/ikev2.conf | cut -f2 -d=)
  [ -z "$server_addr" ] && server_addr=$(grep -s "leftcert=" /etc/ipsec.conf | cut -f2 -d=)
  check_ip "$server_addr" || check_dns_name "$server_addr" || exiterr "Не удалось получить адрес VPN-сервера."
}

list_existing_clients() {
  echo "Проверка существующих клиентов Cicada-IKEv2..."
  certutil -L -d sql:/etc/ipsec.d | grep -v -e '^$' -e 'IKEv2 VPN CA' -e '\.' | tail -n +3 | cut -f1 -d ' '
}

enter_server_address() {
  echo "Вы хотите, чтобы клиенты Cicada-IKEv2 VPN подключались к этому серверу с использованием DNS-имени?,"
  printf "например vpn.example.com, а не его IP-адрес? [y/N] "
  read -r response
  case $response in
    [yY][eE][sS]|[yY])
      use_dns_name=1
      echo
      ;;
    *)
      use_dns_name=0
      echo
      ;;
  esac

  if [ "$use_dns_name" = "1" ]; then
    read -rp "Введите DNS-имя этого VPN-сервера: " server_addr
    until check_dns_name "$server_addr"; do
      echo "Неверное DNS-имя. Вы должны ввести полное доменное имя(FQDN)."
      read -rp "Введите DNS-имя этого VPN-сервера: " server_addr
    done
  else
    get_server_ip
    echo
    echo
    read -rp "Введите IPv4-адрес этого VPN-сервера: [$public_ip] " server_addr
    [ -z "$server_addr" ] && server_addr="$public_ip"
    until check_ip "$server_addr"; do
      echo "Неверный IP-адрес."
      read -rp "Введите IPv4-адрес этого VPN-сервера: [$public_ip] " server_addr
      [ -z "$server_addr" ] && server_addr="$public_ip"
    done
  fi
}

enter_client_name() {
  echo
  echo "Укажите имя для VPN-клиента Cicada-IKEv2.."
  echo "Используйте только одно слово, никаких специальных символов, кроме '-' а также '_'."
  read -rp "Имя клиента: " client_name
  while [ -z "$client_name" ] || ! check_client_name || check_client_cert_exists; do
    if [ -z "$client_name" ] || ! check_client_name; then
      echo "Неверное имя клиента."
    else
      echo "Неверное имя клиента. Клиент '$client_name' уже существует."
    fi
    read -rp "Имя клиента: " client_name
  done
}

enter_client_name_with_defaults() {
  echo
  echo "Укажите имя для VPN-клиента Cicada-IKEv2.."
  echo "Используйте только одно слово, никаких специальных символов, кроме '-' а также '_'."
  read -rp "Имя клиента: [Cicada-IKEv2] " client_name
  [ -z "$client_name" ] && client_name=vpnclient
  while ! check_client_name || check_client_cert_exists; do
      if ! check_client_name; then
        echo "Неверное имя клиента."
      else
        echo "Неверное имя клиента. Клиент '$client_name' уже существует."
      fi
    read -rp "Имя клиента: [Cicada-IKEv2] " client_name
    [ -z "$client_name" ] && client_name=vpnclient
  done
}

enter_client_name_for_export() {
  echo
  list_existing_clients
  get_server_address
  echo
  read -rp "Введите имя клиента Cicada-IKEv2 для экспорта: " client_name
  while [ -z "$client_name" ] || ! check_client_name \
    || [ "$client_name" = "IKEv2 VPN CA" ] || [ "$client_name" = "$server_addr" ] \
    || ! check_client_cert_exists; do
    echo "Неверное имя клиента или клиент не существует."
    read -rp "Введите имя клиента Cicada-IKEv2 для экспорта: " client_name
  done
}

enter_client_cert_validity() {
  echo
  echo "Укажите срок действия (в месяцах) для этого сертификата VPN-клиента.."
  read -rp "Введите число от 1 до 120: [120] " client_validity
  [ -z "$client_validity" ] && client_validity=120
  while printf '%s' "$client_validity" | LC_ALL=C grep -q '[^0-9]\+' \
    || [ "$client_validity" -lt "1" ] || [ "$client_validity" -gt "120" ] \
    || [ "$client_validity" != "$((10#$client_validity))" ]; do
    echo "Недействительный срок действия."
    read -rp "Введите число от 1 до 120: [120] " client_validity
    [ -z "$client_validity" ] && client_validity=120
  done
}

enter_custom_dns() {
  echo
  echo "По умолчанию клиенты настроены на использование Google Public DNS, когда VPN активен.."
  printf "Вы хотите указать собственные DNS-серверы для Cicada-IKEv2? [y/N] "
  read -r response
  case $response in
    [yY][eE][sS]|[yY])
      use_custom_dns=1
      ;;
    *)
      use_custom_dns=0
      dns_server_1=8.8.8.8
      dns_server_2=8.8.4.4
      dns_servers="8.8.8.8 8.8.4.4"
      ;;
  esac

  if [ "$use_custom_dns" = "1" ]; then
    read -rp "Введите основной DNS-сервер: " dns_server_1
    until check_ip "$dns_server_1"; do
      echo "Неверный DNS-сервер."
      read -rp "Введите основной DNS-сервер primary DNS server: " dns_server_1
    done

    read -rp "Введите вторичный DNS-сервер (введите, чтобы пропустить): " dns_server_2
    until [ -z "$dns_server_2" ] || check_ip "$dns_server_2"; do
      echo "Неверный DNS-сервер."
      read -rp "Введите вторичный DNS-сервер (введите, чтобы пропустить): " dns_server_2
    done

    if [ -n "$dns_server_2" ]; then
      dns_servers="$dns_server_1 $dns_server_2"
    else
      dns_servers="$dns_server_1"
    fi
  else
    echo "Использование Google Public DNS (8.8.8.8, 8.8.4.4)."
  fi
  echo
}

check_mobike_support() {
  mobike_support=1
  if uname -m | grep -qi -e '^arm' -e '^aarch64'; then
    modprobe -q configs
    if [ -f /proc/config.gz ]; then
      if ! zcat /proc/config.gz | grep -q "CONFIG_XFRM_MIGRATE=y"; then
        mobike_support=0
      fi
    else
      mobike_support=0
    fi
  fi

  kernel_conf="/boot/config-$(uname -r)"
  if [ -f "$kernel_conf" ]; then
    if ! grep -qs "CONFIG_XFRM_MIGRATE=y" "$kernel_conf"; then
      mobike_support=0
    fi
  fi

  # Linux kernels on Ubuntu do not support MOBIKE
  if [ "$in_container" = "0" ]; then
    if [ "$os_type" = "ubuntu" ] || uname -v | grep -qi ubuntu; then
      mobike_support=0
    fi
  else
    if uname -v | grep -qi ubuntu; then
      mobike_support=0
    fi
  fi

  if [ "$mobike_support" = "1" ]; then
    bigecho2 "Проверка наличия поддержки MOBIKE ... доступно"
  else
    bigecho2 "Проверка поддержки MOBIKE ... недоступно"
  fi
}

select_mobike() {
  echo
  mobike_enable=0
  if [ "$mobike_support" = "1" ]; then
    echo
    echo "Расширение MOBIKE IKEv2 позволяет клиентам VPN изменять точки подключения к сети,"
    echo "например переключаться между мобильными данными и Wi-Fi и поддерживать туннель IPsec на новом IP."
    echo
    printf "Вы хотите включить поддержку MOBIKE?? [Y/n] "
    read -r response
    case $response in
      [yY][eE][sS]|[yY]|'')
        mobike_enable=1
        ;;
      *)
        mobike_enable=0
        ;;
    esac
  fi
}

select_p12_password() {
cat <<'EOF'

Конфигурация клиента будет экспортирована как файлы .p12, .sswan и .mobileconfig,
которые содержат сертификат клиента, закрытый ключ и сертификат CA.
Чтобы защитить эти файлы, этот сценарий может сгенерировать для вас случайный пароль,
который будет отображаться по окончании.

EOF

  printf "Вы хотите вместо этого указать свой пароль?? [y/N] "
  read -r response
  case $response in
    [yY][eE][sS]|[yY])
      use_own_password=1
      echo
      ;;
    *)
      use_own_password=0
      echo
      ;;
  esac
}

select_menu_option() {
  echo "Cicada-IKEv2 уже настроен на этом сервере."
  echo
  echo "Выберите вариант:"
  echo "  1) Добавить нового клиента"
  echo "  2) Экспорт конфигурации для существующего клиента"
  echo "  3) Список существующих клиентов"
  echo "  4) Удалить Cicada-IKEv2"
  echo "  5) Выход"
  read -rp "Вариант: " selected_option
  until [[ "$selected_option" =~ ^[1-5]$ ]]; do
    printf '%s\n' "$selected_option: неверный выбор."
    read -rp "Вариант: " selected_option
  done
}

confirm_setup_options() {
cat <<EOF
Теперь мы готовы к настройке Cicada-IKEv2. Ниже приведены выбранные вами параметры настройки.
Пожалуйста, проверьте еще раз, прежде чем продолжить!

======================================

Адрес VPN-сервера: $server_addr
Имя клиента VPN: $client_name

EOF

  if [ "$client_validity" = "1" ]; then
    echo "Сертификат клиента действителен: 1 месяц"
  else
    echo "Сертификат клиента действителен для: $client_validity месяц()ев)"
  fi

  if [ "$mobike_support" = "1" ]; then
    if [ "$mobike_enable" = "1" ]; then
      echo "Поддержка MOBIKE: Включить"
    else
      echo "Поддержка MOBIKE: отключить"
    fi
  else
    echo "Поддержка MOBIKE: недоступна"
  fi

cat <<EOF
DNS-серверы: $dns_servers

======================================

EOF

  printf "Вы хотите продолжить? [y/N] "
  read -r response
  case $response in
    [yY][eE][sS]|[yY])
      echo
      ;;
    *)
      echo "Прервать. Никаких изменений не было."
      exit 1
      ;;
  esac
}

create_client_cert() {
  bigecho2 "Создание сертификата клиента..."

  sleep $((RANDOM % 3 + 1))

  certutil -z <(head -c 1024 /dev/urandom) \
    -S -c "IKEv2 VPN CA" -n "$client_name" \
    -s "O=IKEv2 VPN,CN=$client_name" \
    -k rsa -v "$client_validity" \
    -d sql:/etc/ipsec.d -t ",," \
    --keyUsage digitalSignature,keyEncipherment \
    --extKeyUsage serverAuth,clientAuth -8 "$client_name" >/dev/null 2>&1 || exiterr "Не удалось создать сертификат клиента."
}

export_p12_file() {
  bigecho2 "Создание конфигурации клиента..."

  if [ "$use_own_password" = "1" ]; then
cat <<'EOF'


Введите * безопасный * пароль для защиты файлов конфигурации клиента.
При импорте на устройство iOS или macOS этот пароль не может быть пустым.

EOF
  else
    p12_password=$(LC_CTYPE=C tr -dc 'A-HJ-NPR-Za-km-z2-9' < /dev/urandom | head -c 16)
    [ -z "$p12_password" ] && exiterr "Не удалось сгенерировать случайный пароль для .p12 файла."
  fi

  p12_file="$export_dir$client_name.p12"
  if [ "$use_own_password" = "1" ]; then
    pk12util -d sql:/etc/ipsec.d -n "$client_name" -o "$p12_file" || exit 1
  else
    pk12util -W "$p12_password" -d sql:/etc/ipsec.d -n "$client_name" -o "$p12_file" >/dev/null || exit 1
  fi

  if [ "$export_to_home_dir" = "1" ]; then
    chown "$SUDO_USER:$SUDO_USER" "$p12_file"
  fi
  chmod 600 "$p12_file"
}

install_base64_uuidgen() {
  if ! command -v base64 >/dev/null 2>&1 || ! command -v uuidgen >/dev/null 2>&1; then
    bigecho2 "Установка необходимых пакетов..."
    if [ "$os_type" = "ubuntu" ] || [ "$os_type" = "debian" ] || [ "$os_type" = "raspbian" ]; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get -yqq update || exiterr "'apt-get update' failed."
    fi
  fi
  if ! command -v base64 >/dev/null 2>&1; then
    if [ "$os_type" = "ubuntu" ] || [ "$os_type" = "debian" ] || [ "$os_type" = "raspbian" ]; then
      apt-get -yqq install coreutils >/dev/null || exiterr "'apt-get install' failed."
    else
      yum -y -q install coreutils >/dev/null || exiterr "'yum install' failed."
    fi
  fi
  if ! command -v uuidgen >/dev/null 2>&1; then
    if [ "$os_type" = "ubuntu" ] || [ "$os_type" = "debian" ] || [ "$os_type" = "raspbian" ]; then
      apt-get -yqq install uuid-runtime >/dev/null || exiterr "'apt-get install' failed."
    else
      yum -y -q install util-linux >/dev/null || exiterr "'yum install' failed."
    fi
  fi
}

create_mobileconfig() {
  [ -z "$server_addr" ] && get_server_address

  p12_base64=$(base64 -w 52 "$export_dir$client_name.p12")
  [ -z "$p12_base64" ] && exiterr "Не удалось закодировать .p12 файл."

  ca_base64=$(certutil -L -d sql:/etc/ipsec.d -n "IKEv2 VPN CA" -a | grep -v CERTIFICATE)
  [ -z "$ca_base64" ] && exiterr "Не удалось закодировать сертификат CA Cicada-IKEv2 VPN."

  uuid1=$(uuidgen)
  [ -z "$uuid1" ] && exiterr "Не удалось сгенерировать значение UUID."

  mc_file="$export_dir$client_name.mobileconfig"

cat > "$mc_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>IKEv2</key>
      <dict>
        <key>AuthenticationMethod</key>
        <string>Certificate</string>
        <key>ChildSecurityAssociationParameters</key>
        <dict>
          <key>DiffieHellmanGroup</key>
          <integer>14</integer>
          <key>EncryptionAlgorithm</key>
          <string>AES-128-GCM</string>
          <key>LifeTimeInMinutes</key>
          <integer>1410</integer>
        </dict>
        <key>DeadPeerDetectionRate</key>
        <string>Medium</string>
        <key>DisableRedirect</key>
        <true/>
        <key>EnableCertificateRevocationCheck</key>
        <integer>0</integer>
        <key>EnablePFS</key>
        <integer>0</integer>
        <key>IKESecurityAssociationParameters</key>
        <dict>
          <key>DiffieHellmanGroup</key>
          <integer>14</integer>
          <key>EncryptionAlgorithm</key>
          <string>AES-256</string>
          <key>IntegrityAlgorithm</key>
          <string>SHA2-256</string>
          <key>LifeTimeInMinutes</key>
          <integer>1410</integer>
        </dict>
        <key>LocalIdentifier</key>
        <string>ViPvpn</string>
        <key>PayloadCertificateUUID</key>
        <string>c48246df-ce6a-46f7-b25a-289956fedce8</string>
        <key>OnDemandEnabled</key>
        <integer>0</integer>
        <key>OnDemandRules</key>
        <array>
          <dict>
          <key>Action</key>
          <string>Connect</string>
          </dict>
        </array>
        <key>RemoteAddress</key>
        <string>194.67.87.160</string>
        <key>RemoteIdentifier</key>
        <string>CicadaVPN</string>
        <key>UseConfigurationAttributeInternalIPSubnet</key>
        <integer>0</integer>
      </dict>
      <key>IPv4</key>
      <dict>
        <key>OverridePrimary</key>
        <integer>1</integer>
      </dict>
      <key>PayloadDescription</key>
      <string>Configures VPN settings</string>
      <key>PayloadDisplayName</key>
      <string>VPN</string>
      <key>PayloadIdentifier</key>
      <string>com.apple.vpn.managed.900797f8-4b11-45fb-8b5d-21fcd708d809</string>
      <key>PayloadType</key>
      <string>com.apple.vpn.managed</string>
      <key>PayloadUUID</key>
      <string>b3c033ee-6a56-4f12-9d54-f1ac7a2f4418</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
      <key>Proxies</key>
      <dict>
        <key>HTTPEnable</key>
        <integer>0</integer>
        <key>HTTPSEnable</key>
        <integer>0</integer>
      </dict>
      <key>UserDefinedName</key>
      <string>CicadaVPN</string>
      <key>VPNType</key>
      <string>IKEv2</string>
    </dict>
    <dict>
      <key>PayloadCertificateFileName</key>
      <string>ViPvpn</string>
      <key>PayloadContent</key>
      <data>
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
8QIDCSfAAAA=
      </data>
      <key>PayloadDescription</key>
      <string>Adds a PKCS#12-formatted certificate</string>
      <key>PayloadDisplayName</key>
      <string>ViPvpn</string>
      <key>PayloadIdentifier</key>
      <string>com.apple.security.pkcs12.76d9edf8-2589-4976-89ab-5bfa64c1d3a3</string>
      <key>PayloadType</key>
      <string>com.apple.security.pkcs12</string>
      <key>PayloadUUID</key>
      <string>c48246df-ce6a-46f7-b25a-289956fedce8</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
    </dict>
    <dict>
      <key>PayloadContent</key>
      <data>
MIIC5TCCAc2gAwIBAgIFALf18aUwDQYJKoZIhvcNAQELBQAwKzEVMBMGA1UEAxMM
SUtFdjIgVlBOIENBMRIwEAYDVQQKEwlJS0V2MiBWUE4wHhcNMjEwNDExMTAwNjMy
WhcNMzEwNDExMTAwNjMyWjArMRUwEwYDVQQDEwxJS0V2MiBWUE4gQ0ExEjAQBgNV
BAoTCUlLRXYyIFZQTjCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAKyr
pRTd5kB4z9KoPqPaSNUCyboOgdp/KSMauxe/ckjY/d1lWSoLO6f5L+/Hc3AN9MQz
eyw9Z9xdTA39N83QfMh9o+lY022iG5lJ7UEuRbnb+wD+cMHP5XHzD5IF58AzaNK/
WonoQLHcBT8fj5He9R58vHkqjrSF6P9XaVp6ZjBSdjeukAsLqwcKvfK+aNI+2Awe
mdEEUygXJXp5f2MArqGPxkAJDhq5IyjHM8j1kHzOUBujsokMdO4IglzXvuOOANeM
SNZjOlpH/ADG6h2Gd+IIsB4Qaoao6oio93ickGvJ/yBZbysicynCjcwcBp0OJSu6
oOsv7XuQZ0S5Ugde5rsCAwEAAaMQMA4wDAYDVR0TBAUwAwEB/zANBgkqhkiG9w0B
AQsFAAOCAQEAMPb9Ec9EUsT40w/mq6dPEPpfsTzJQ+GZToE+qVMMMFDefK25c79Q
u068gIhi6mh/wiUx5CwfZMzEUB6Vo/IOPva3T0tBP5HUU3ay2VfQzTbrjrd1gXhT
uQs49H/vpxlP/mr7doReJkfM8Pn04A/WPXk100n0ri9z1peIR6S88mZpLth9qrnJ
IqO8gZtfSpINjocbJH0ff1SifXzmSLoCoAsFSjkE91sOi3Yx8tPSyyVF4M8Negza
v6wnnMQGTcrwhOrpbqNbTKcxIv3u5e1GE8ff/iceZaS4H9U8i+kIL+cagEIwb98W
A0dYky4DlsanGFzOm0NWrxAHHONr2JwH6w==
      </data>
      <key>PayloadCertificateFileName</key>
      <string>ikev2vpnca</string>
      <key>PayloadDescription</key>
      <string>Adds a CA root certificate</string>
      <key>PayloadDisplayName</key>
      <string>Certificate Authority (CA)</string>
      <key>PayloadIdentifier</key>
      <string>com.apple.security.root.4b0180fd-fa03-4cf0-83c8-558abcbe4a32</string>
      <key>PayloadType</key>
      <string>com.apple.security.root</string>
      <key>PayloadUUID</key>
      <string>8e088c37-47b9-4809-80d9-2457fa8bacc7</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
    </dict>
  </array>
  <key>PayloadDisplayName</key>
  <string>Cicada (VPN)</string>
  <key>PayloadIdentifier</key>
  <string>com.apple.vpn.managed.79ae551d-aa3a-48cd-ace4-0c9479552271</string>
  <key>PayloadRemovalDisallowed</key>
  <false/>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>97b0f2d5-6588-4575-b48d-3196cbbe9b08</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
</dict>
</plist>

EOF

  if [ "$export_to_home_dir" = "1" ]; then
    chown "$SUDO_USER:$SUDO_USER" "$mc_file"
  fi
  chmod 600 "$mc_file"
}

create_android_profile() {
  [ -z "$server_addr" ] && get_server_address

  p12_base64_oneline=$(base64 -w 52 "$export_dir$client_name.p12" | sed 's/$/\\n/' | tr -d '\n')
  [ -z "$p12_base64_oneline" ] && exiterr "Не удалось закодировать .p12 файл."

  uuid2=$(uuidgen)
  [ -z "$uuid2" ] && exiterr "Не удалось сгенерировать значение UUID."

  sswan_file="$export_dir$client_name.sswan"

cat > "$sswan_file" <<EOF
{
  "uuid": "$uuid2",
  "name": "IKEv2 VPN ($server_addr)",
  "type": "ikev2-cert",
  "remote": {
    "addr": "$server_addr"
  },
  "local": {
    "p12": "$p12_base64_oneline",
    "rsa-pss": "true"
  },
  "ike-proposal": "aes256-sha256-modp2048",
  "esp-proposal": "aes128gcm16"
}
EOF

  if [ "$export_to_home_dir" = "1" ]; then
    chown "$SUDO_USER:$SUDO_USER" "$sswan_file"
  fi
  chmod 600 "$sswan_file"
}

create_ca_server_certs() {
  bigecho2 "Создание сертификатов CA и серверов..."

  certutil -z <(head -c 1024 /dev/urandom) \
    -S -x -n "IKEv2 VPN CA" \
    -s "O=IKEv2 VPN,CN=IKEv2 VPN CA" \
    -k rsa -v 120 \
    -d sql:/etc/ipsec.d -t "CT,," -2 >/dev/null 2>&1 <<ANSWERS || exiterr "Не удалось создать сертификат CA.."
y

N
ANSWERS

  sleep $((RANDOM % 3 + 1))

  if [ "$use_dns_name" = "1" ]; then
    certutil -z <(head -c 1024 /dev/urandom) \
      -S -c "IKEv2 VPN CA" -n "$server_addr" \
      -s "O=IKEv2 VPN,CN=$server_addr" \
      -k rsa -v 120 \
      -d sql:/etc/ipsec.d -t ",," \
      --keyUsage digitalSignature,keyEncipherment \
      --extKeyUsage serverAuth \
      --extSAN "dns:$server_addr" >/dev/null 2>&1 || exiterr "Не удалось создать сертификат сервера."
  else
    certutil -z <(head -c 1024 /dev/urandom) \
      -S -c "IKEv2 VPN CA" -n "$server_addr" \
      -s "O=IKEv2 VPN,CN=$server_addr" \
      -k rsa -v 120 \
      -d sql:/etc/ipsec.d -t ",," \
      --keyUsage digitalSignature,keyEncipherment \
      --extKeyUsage serverAuth \
      --extSAN "ip:$server_addr,dns:$server_addr" >/dev/null 2>&1 || exiterr "Не удалось создать сертификат сервера."
  fi
}

add_ikev2_connection() {
  bigecho2 "Добавление нового соединения Cicada-IKEv2..."

  if ! grep -qs '^include /etc/ipsec\.d/\*\.conf$' /etc/ipsec.conf; then
    echo >> /etc/ipsec.conf
    echo 'include /etc/ipsec.d/*.conf' >> /etc/ipsec.conf
  fi

cat > /etc/ipsec.d/ikev2.conf <<EOF

conn ikev2-cp
  left=%defaultroute
  leftcert=$server_addr
  leftsendcert=always
  leftsubnet=0.0.0.0/0
  leftrsasigkey=%cert
  right=%any
  rightid=%fromcert
  rightaddresspool=192.168.43.10-192.168.43.250
  rightca=%same
  rightrsasigkey=%cert
  narrowing=yes
  dpddelay=30
  dpdtimeout=120
  dpdaction=clear
  auto=add
  ikev2=insist
  rekey=no
  pfs=no
  fragmentation=yes
  ike=aes256-sha2,aes128-sha2,aes256-sha1,aes128-sha1,aes256-sha2;modp1024,aes128-sha1;modp1024
  phase2alg=aes_gcm-null,aes128-sha1,aes256-sha1,aes128-sha2,aes256-sha2
  ikelifetime=24h
  salifetime=24h
  encapsulation=yes
EOF

  if [ "$use_dns_name" = "1" ]; then
cat >> /etc/ipsec.d/ikev2.conf <<EOF
  leftid=@$server_addr
EOF
  else
cat >> /etc/ipsec.d/ikev2.conf <<EOF
  leftid=$server_addr
EOF
  fi

  if [ -n "$dns_server_2" ]; then
cat >> /etc/ipsec.d/ikev2.conf <<EOF
  modecfgdns="$dns_servers"
EOF
  else
cat >> /etc/ipsec.d/ikev2.conf <<EOF
  modecfgdns=$dns_server_1
EOF
  fi

  if [ "$mobike_enable" = "1" ]; then
    echo "  mobike=yes" >> /etc/ipsec.d/ikev2.conf
  else
    echo "  mobike=no" >> /etc/ipsec.d/ikev2.conf
  fi
}

apply_ubuntu1804_nss_fix() {
  if [ "$os_type" = "ubuntu" ] && [ "$os_ver" = "bustersid" ] && [ "$os_arch" = "x86_64" ]; then
    nss_url1="https://mirrors.kernel.org/ubuntu/pool/main/n/nss"
    nss_url2="https://mirrors.kernel.org/ubuntu/pool/universe/n/nss"
    nss_deb1="libnss3_3.49.1-1ubuntu1.5_amd64.deb"
    nss_deb2="libnss3-dev_3.49.1-1ubuntu1.5_amd64.deb"
    nss_deb3="libnss3-tools_3.49.1-1ubuntu1.5_amd64.deb"
    TMPDIR=$(mktemp -d /tmp/nss.XXX 2>/dev/null)
    if [ -d "$TMPDIR" ]; then
      bigecho2 "Applying fix for NSS bug on Ubuntu 18.04..."
      export DEBIAN_FRONTEND=noninteractive
      if wget -t 3 -T 30 -q -O "$TMPDIR/1.deb" "$nss_url1/$nss_deb1" \
        && wget -t 3 -T 30 -q -O "$TMPDIR/2.deb" "$nss_url1/$nss_deb2" \
        && wget -t 3 -T 30 -q -O "$TMPDIR/3.deb" "$nss_url2/$nss_deb3"; then
        apt-get -yqq update
        apt-get -yqq install "$TMPDIR/1.deb" "$TMPDIR/2.deb" "$TMPDIR/3.deb" >/dev/null
      fi
      /bin/rm -f "$TMPDIR/1.deb" "$TMPDIR/2.deb" "$TMPDIR/3.deb"
      /bin/rmdir "$TMPDIR"
    fi
  fi
}

restart_ipsec_service() {
  if [ "$in_container" = "0" ] || { [ "$in_container" = "1" ] && service ipsec status >/dev/null 2>&1; } then
    bigecho2 "Перезапуск службы IPsec..."

    mkdir -p /run/pluto
    service ipsec restart 2>/dev/null
  fi
}

print_client_added_message() {
cat <<EOF


================================================

Новый VPN-клиент Cicada-IKEv2 "$client_name" добавлен!

Адрес VPN-сервера: $server_addr
Имя клиента VPN: $client_name

EOF
}

print_client_exported_message() {
cat <<EOF


================================================

Cicada-IKEv2 VPN-клиент "$client_name" экспортируется!

Адрес VPN-сервера: $server_addr
Имя клиента VPN: $client_name

EOF
}

show_swan_update_info() {
  if printf '%s' "$swan_ver_latest" | grep -Eq '^([3-9]|[1-9][0-9])\.([0-9]|[1-9][0-9])$' \
    && [ "$swan_ver" != "$swan_ver_latest" ] \
    && printf '%s\n%s' "$swan_ver" "$swan_ver_latest" | sort -C -V; then
    echo
    echo "Примечание: более новая версия Libreswan($swan_ver_latest) доступен."
    if [ "$in_container" = "0" ]; then
      get_update_url
      echo "      Для обновления запустите:"
      echo "      wget $update_url -O vpnupgrade.sh"
      echo "      sudo sh vpnupgrade.sh"
    else
      echo "      Чтобы обновить этот образ Docker, см.: https://git.io/updatedockervpn"
    fi
  fi
}

print_setup_complete_message() {
  printf '\e[2K\r'
cat <<EOF

================================================

Установка Cicada-IKEv2 прошла успешно. Подробная информация о режиме Cicada-IKEv2:

Адрес VPN-сервера: $server_addr
Имя клиента VPN: $client_name

EOF
}

print_client_info() {
  if [ "$in_container" = "0" ]; then
cat <<'EOF'
Конфигурация клиента доступна по адресу:
EOF
  else
cat <<'EOF'
Конфигурация клиента доступна внутри
Контейнер Docker :
EOF
  fi

cat <<EOF

$export_dir$client_name.p12 (for Windows & Linux)
$export_dir$client_name.sswan (for Android)
$export_dir$client_name.mobileconfig (for iOS & macOS)
EOF

  if [ "$use_own_password" = "0" ]; then
cat <<EOF

* ВАЖНО * Пароль для файлов конфигурации клиента:
$p12_password
Запишите это, оно вам понадобится для импорта!
EOF
  fi

cat <<'EOF'

Следующие шаги: Настройка клиентов Cicada-IKEv2 VPN. см.:
https://git.io/ikev2clients

================================================

EOF
}

check_ipsec_conf() {
  if grep -qs "conn ikev2-cp" /etc/ipsec.conf; then
    echo "Ошибка: раздел конфигурации Cicada-IKEv2 найден в /etc/ipsec.conf." >&2
    echo "       Этот сценарий не может автоматически удалить Cicada-IKEv2 с этого сервера.." >&2
    echo "       Чтобы вручную удалить Cicada-IKEv2, см. https://git.io/ikev2" >&2
    echo "Прервать. Никаких изменений не было." >&2
    exit 1
  fi
}

confirm_remove_ikev2() {
  echo
  echo "ВНИМАНИЕ: эта опция удалит Cicada-IKEv2 с этого VPN-сервера, но сохранит IPsec / L2TP."
  echo "         а также IPsec/XAuth (\"Cisco IPsec\") режимы, если установлены Все Cicada-IKEv2 конфигурации"
  echo "         including certificates and keys will be permanently deleted."
  echo "         Это не может быть отменено! "
  echo
  printf "Вы уверены, что хотите удалить Cicada-IKEv2? [y/N] "
  read -r response
  case $response in
    [yY][eE][sS]|[yY])
      echo
      ;;
    *)
      echo "Прервать. Никаких изменений не было."
      exit 1
      ;;
  esac
}

delete_ikev2_conf() {
  bigecho "Deleting /etc/ipsec.d/ikev2.conf..."
  /bin/rm -f /etc/ipsec.d/ikev2.conf
}

delete_certificates() {
  echo
  bigecho "Удаление сертификатов и ключей из базы данных IPsec..."
  certutil -L -d sql:/etc/ipsec.d | grep -v -e '^$' -e 'IKEv2 VPN CA' | tail -n +3 | cut -f1 -d ' ' | while read -r line; do
    certutil -F -d sql:/etc/ipsec.d -n "$line"
    certutil -D -d sql:/etc/ipsec.d -n "$line" 2>/dev/null
  done
  certutil -F -d sql:/etc/ipsec.d -n "IKEv2 VPN CA"
  certutil -D -d sql:/etc/ipsec.d -n "IKEv2 VPN CA" 2>/dev/null
}

print_ikev2_removed_message() {
  echo
  echo "Cicada-IKEv2 удален!"
}

ikev2setup() {
  check_run_as_root
  check_os_type
  check_swan_install
  check_utils_exist
  check_container

  use_defaults=0
  add_client_using_defaults=0
  export_client_using_defaults=0
  list_clients=0
  remove_ikev2=0
  while [ "$#" -gt 0 ]; do
    case $1 in
      --auto)
        use_defaults=1
        shift
        ;;
      --addclient)
        add_client_using_defaults=1
        client_name="$2"
        shift
        shift
        ;;
      --exportclient)
        export_client_using_defaults=1
        client_name="$2"
        shift
        shift
        ;;
      --listclients)
        list_clients=1
        shift
        ;;
      --removeikev2)
        remove_ikev2=1
        shift
        ;;
      -h|--help)
        show_usage
        ;;
      *)
        show_usage "Неизвестный параметр: $1"
        ;;
    esac
  done

  check_arguments
  get_export_dir

  if [ "$add_client_using_defaults" = "1" ]; then
    show_add_client_message
    client_validity=120
    use_own_password=0
    create_client_cert
    install_base64_uuidgen
    export_p12_file
    create_mobileconfig
    create_android_profile
    print_client_added_message
    print_client_info
    exit 0
  fi

  if [ "$export_client_using_defaults" = "1" ]; then
    show_export_client_message
    use_own_password=0
    install_base64_uuidgen
    export_p12_file
    create_mobileconfig
    create_android_profile
    print_client_exported_message
    print_client_info
    exit 0
  fi

  if [ "$list_clients" = "1" ]; then
    list_existing_clients
    exit 0
  fi

  if [ "$remove_ikev2" = "1" ]; then
    check_ipsec_conf
    confirm_remove_ikev2
    delete_ikev2_conf
    restart_ipsec_service
    delete_certificates
    print_ikev2_removed_message
    exit 0
  fi

  if check_ikev2_exists; then
    select_menu_option
    case $selected_option in
      1)
        enter_client_name
        enter_client_cert_validity
        select_p12_password
        create_client_cert
        install_base64_uuidgen
        export_p12_file
        create_mobileconfig
        create_android_profile
        print_client_added_message
        print_client_info
        exit 0
        ;;
      2)
        enter_client_name_for_export
        select_p12_password
        install_base64_uuidgen
        export_p12_file
        create_mobileconfig
        create_android_profile
        print_client_exported_message
        print_client_info
        exit 0
        ;;
      3)
        echo
        list_existing_clients
        exit 0
        ;;
      4)
        check_ipsec_conf
        confirm_remove_ikev2
        delete_ikev2_conf
        restart_ipsec_service
        delete_certificates
        print_ikev2_removed_message
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
  fi

  check_ca_cert_exists
  check_swan_ver

  if [ "$use_defaults" = "0" ]; then
    select_swan_update
    show_welcome_message
    enter_server_address
    check_server_cert_exists
    enter_client_name_with_defaults
    enter_client_cert_validity
    enter_custom_dns
    check_mobike_support
    select_mobike
    select_p12_password
    confirm_setup_options
  else
    check_server_dns_name
    check_custom_dns
    if [ -n "$VPN_CLIENT_NAME" ]; then
      client_name="$VPN_CLIENT_NAME"
      check_client_name || exiterr "Неверное имя клиента. Используйте только одно слово, никаких специальных символов, кроме '-' а также '_'."
    else
      client_name=vpnclient
    fi
    check_client_cert_exists && exiterr "Клиент '$client_name' уже существует."
    client_validity=120
    show_start_message
    if [ -n "$VPN_DNS_NAME" ]; then
      use_dns_name=1
      server_addr="$VPN_DNS_NAME"
    else
      use_dns_name=0
      get_server_ip
      check_ip "$public_ip" || exiterr "Не удается определить общедоступный IP-адрес этого сервера."
      server_addr="$public_ip"
    fi
    check_server_cert_exists
    if [ -n "$VPN_DNS_SRV1" ] && [ -n "$VPN_DNS_SRV2" ]; then
      dns_server_1="$VPN_DNS_SRV1"
      dns_server_2="$VPN_DNS_SRV2"
      dns_servers="$VPN_DNS_SRV1 $VPN_DNS_SRV2"
    elif [ -n "$VPN_DNS_SRV1" ]; then
      dns_server_1="$VPN_DNS_SRV1"
      dns_server_2=""
      dns_servers="$VPN_DNS_SRV1"
    else
      dns_server_1=8.8.8.8
      dns_server_2=8.8.4.4
      dns_servers="8.8.8.8 8.8.4.4"
    fi
    check_mobike_support
    mobike_enable="$mobike_support"
    use_own_password=0
  fi

  apply_ubuntu1804_nss_fix
  create_ca_server_certs
  create_client_cert
  install_base64_uuidgen
  export_p12_file
  create_mobileconfig
  create_android_profile
  add_ikev2_connection
  restart_ipsec_service

  if [ "$use_defaults" = "1" ]; then
    show_swan_update_info
  fi

  print_setup_complete_message
  print_client_info
}

## Отложите настройку, пока у нас не будет полного сценария
ikev2setup "$@"

exit 0
