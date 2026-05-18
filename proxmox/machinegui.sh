}

list_users() {
    section "Managed VNC users"
    ensure_dirs
    load_manager_conf

    local conf any=0
    printf "  %-18s %-8s %-10s %-10s %-10s %-10s\n" "USER" "DISPLAY" "VNC" "WEBSOCK" "VNC SVC" "WS SVC"
    printf "  %-18s %-8s %-10s %-10s %-10s %-10s\n" "------------------" "-------" "---------" "---------" "--------" "--------"
    for conf in "$USERS_DIR"/*.conf; do
        [[ -f "$conf" ]] || continue
        any=1
        # shellcheck disable=SC1090
        source "$conf"
        printf "  %-18s :%-7s %-10s %-10s %-10s %-10s\n" \
            "$VNC_USER" "$VNC_DISPLAY" "$VNC_PORT" "$WS_PORT" \
            "$(service_state "vncserver-desktop@${VNC_USER}")" \
            "$(service_state "websockify-desktop@${VNC_USER}")"
    done
    [[ "$any" -eq 1 ]] || warn "No managed VNC users yet."
}

container_ips() {
    ip -4 addr show scope global 2>/dev/null |
        awk '/inet / { sub(/\/.*/, "", $2); print $2 }'
}

print_user_urls() {
    local username="$1" conf ip encrypt_url direct_url cf_url
    conf="$(config_path_for_user "$username")"
    [[ -f "$conf" ]] || return 0
    # shellcheck disable=SC1090
    source "$conf"

    section "Access URLs for ${username}"
    while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        encrypt_url="https://${ip}/vnc.html?host=${ip}&port=${NGINX_HTTPS_PORT}&encrypt=1&path=websockify/${username}"
        direct_url="https://${ip}:${WS_PORT}/vnc.html"
        cf_url="${ip}:${VNC_PORT}"
        echo -e "  noVNC URL : ${GREEN}${encrypt_url}${RESET}"
        echo -e "  Direct WS : ${CYAN}${direct_url}${RESET}"
        echo -e "  Raw VNC   : ${YELLOW}${cf_url}${RESET} (for Cloudflare Access browser-rendered VNC)"
        echo ""
    done < <(container_ips)
    warn "Self-signed HTTPS cert: your browser will ask you to accept the risk."
}

print_all_urls() {
    local username
    for username in $(managed_users || true); do
        print_user_urls "$username"
    done
}

status_all() {
    list_users
    echo ""
    systemctl status nginx --no-pager -l 2>/dev/null | sed -n '1,12p' || true
}

# ---- Top-level actions ------------------------------------------------------
install_base() {
    section "Base install/update"
    ensure_dirs
    install_packages
    disable_old_single_user_services
    write_session_wrapper
    write_websockify_wrapper
    write_systemd_templates
    generate_ssl_cert
    save_manager_conf
    write_nginx_config
    systemctl enable nginx --quiet
    systemctl restart nginx
    ok "Base VNC stack installed"

    if [[ -z "$(managed_users || true)" ]]; then
        echo ""
        read -rp "  Add a desktop user now? (y/n): " answer
        [[ "$answer" =~ ^[Yy]$ ]] && add_user
    else
        echo ""
        read -rp "  Restart all managed VNC users now? (y/n): " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            restart_all
        fi
    fi
}

restart_all() {
    section "Restarting managed VNC services"
    local username
    write_nginx_config
    for username in $(managed_users || true); do
        start_user_services "$username"
    done
    ok "Restart complete"
}

menu() {
    while true; do
        section "VNC Desktop Manager"
        echo "  1. Install/update base packages and services"
        echo "  2. Add VNC desktop user"
        echo "  3. List VNC users"
        echo "  4. Reset user password"
        echo "  5. Delete VNC desktop user"
        echo "  6. Restart all managed services"
        echo "  7. Show access URLs"
        echo "  8. Status"
        echo "  0. Exit"
        echo ""
        read -rp "  Choose: " choice
        case "$choice" in
            1) install_base ;;
            2) add_user ;;
            3) list_users ;;
            4) reset_password ;;
            5) delete_user ;;
            6) restart_all ;;
            7) print_all_urls ;;
            8) status_all ;;
            0) exit 0 ;;
            *) warn "Invalid choice: ${choice}" ;;
        esac
    done
}

usage() {
    cat <<EOF
Usage: sudo bash $0 [command]

Commands:
  install          Install/update packages, SSL, nginx, wrappers, systemd templates
  add-user         Add or adopt a Linux user as a VNC desktop user
  list-users       Show managed VNC users, displays, ports, and service state
  reset-password   Reset Linux and/or VNC password for a managed user
  delete-user      Stop services and remove a managed VNC user
  restart          Restart nginx and all managed VNC/websockify services
  status           Show users and nginx status
  urls             Print access URLs for every managed user
  help             Show this help

Without a command, an interactive menu is shown.
EOF
}

main() {
    ensure_dirs
    case "${1:-menu}" in
        menu) menu ;;
        install) install_base ;;
        add-user) add_user ;;
        list-users) list_users ;;
        reset-password) reset_password ;;
        delete-user) delete_user ;;
        restart) restart_all ;;
        status) status_all ;;
        urls) print_all_urls ;;
        help|-h|--help) usage ;;
        *) usage; fatal "Unknown command: $1" ;;
    esac
}

main "$@"
