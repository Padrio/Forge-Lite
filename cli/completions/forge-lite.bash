# forge-lite bash completion
# Installed to /etc/bash_completion.d/forge-lite

_forge_lite_complete() {
    local cur prev words cword
    if declare -F _init_completion &>/dev/null; then
        _init_completion -- || return
    else
        COMPREPLY=()
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        words=("${COMP_WORDS[@]}")
        cword=$COMP_CWORD
    fi

    # Gather domain names from site configs
    _forge_lite_domains() {
        local conf
        if [[ -d /etc/forge-lite ]]; then
            for conf in /etc/forge-lite/*.conf; do
                [[ -f "$conf" ]] && basename "$conf" .conf
            done
        fi
    }

    # Top-level commands
    local commands="site deploy rollback runner db env ssl php provision update status --version"

    case "$cword" in
        1)
            COMPREPLY=($(compgen -W "$commands" -- "$cur"))
            return
            ;;
    esac

    local cmd="${words[1]}"

    case "$cmd" in
        site)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "add remove list" -- "$cur"))
            elif [[ $cword -eq 3 ]]; then
                case "${words[2]}" in
                    remove)
                        COMPREPLY=($(compgen -W "$(_forge_lite_domains)" -- "$cur"))
                        ;;
                    add)
                        # Complete --flags with = suffix (no trailing space)
                        local flags="--domain= --php= --queue-workers= --enable-ssr --enable-horizon --no-scheduler --ssl --env="
                        COMPREPLY=($(compgen -W "$flags" -- "$cur"))
                        [[ ${#COMPREPLY[@]} -eq 1 && "${COMPREPLY[0]}" == *= ]] && compopt -o nospace
                        ;;
                esac
            elif [[ "${words[2]}" == "add" ]]; then
                local flags="--domain= --php= --queue-workers= --enable-ssr --enable-horizon --no-scheduler --ssl --env="
                COMPREPLY=($(compgen -W "$flags" -- "$cur"))
                [[ ${#COMPREPLY[@]} -eq 1 && "${COMPREPLY[0]}" == *= ]] && compopt -o nospace
            fi
            ;;

        deploy)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "setup $(_forge_lite_domains)" -- "$cur"))
            elif [[ "${words[2]}" == "setup" ]]; then
                if [[ $cword -eq 3 ]]; then
                    COMPREPLY=($(compgen -W "$(_forge_lite_domains)" -- "$cur"))
                else
                    local flags="--repo= --branch="
                    COMPREPLY=($(compgen -W "$flags" -- "$cur"))
                    [[ ${#COMPREPLY[@]} -eq 1 && "${COMPREPLY[0]}" == *= ]] && compopt -o nospace
                fi
            else
                local flags="--artifact= --repo= --branch= --skip-migrate --keep="
                COMPREPLY=($(compgen -W "$flags" -- "$cur"))
                [[ ${#COMPREPLY[@]} -eq 1 && "${COMPREPLY[0]}" == *= ]] && compopt -o nospace
            fi
            ;;

        rollback)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "$(_forge_lite_domains)" -- "$cur"))
            fi
            ;;

        db)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "create drop list backup restore" -- "$cur"))
            fi
            ;;

        env)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "list get set delete" -- "$cur"))
            elif [[ $cword -eq 3 ]]; then
                COMPREPLY=($(compgen -W "$(_forge_lite_domains)" -- "$cur"))
            fi
            ;;

        ssl)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "issue remove renew status" -- "$cur"))
            elif [[ $cword -eq 3 ]]; then
                COMPREPLY=($(compgen -W "$(_forge_lite_domains)" -- "$cur"))
            fi
            ;;

        php)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "8.1 8.2 8.3 8.4" -- "$cur"))
            fi
            ;;

        runner)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "setup remove status list" -- "$cur"))
            elif [[ $cword -ge 3 ]]; then
                case "${words[2]}" in
                    setup)
                        local flags="--repo= --token= --name= --labels="
                        COMPREPLY=($(compgen -W "$flags" -- "$cur"))
                        [[ ${#COMPREPLY[@]} -eq 1 && "${COMPREPLY[0]}" == *= ]] && compopt -o nospace
                        ;;
                    remove)
                        local flags="--name= --token="
                        COMPREPLY=($(compgen -W "$flags" -- "$cur"))
                        [[ ${#COMPREPLY[@]} -eq 1 && "${COMPREPLY[0]}" == *= ]] && compopt -o nospace
                        ;;
                esac
            fi
            ;;

        provision)
            local flags="--php-default= --db-password= --redis-password= --node-version= --skip-reboot --force"
            COMPREPLY=($(compgen -W "$flags" -- "$cur"))
            [[ ${#COMPREPLY[@]} -eq 1 && "${COMPREPLY[0]}" == *= ]] && compopt -o nospace
            ;;
    esac
}

complete -F _forge_lite_complete forge-lite
