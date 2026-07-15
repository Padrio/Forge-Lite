#!/usr/bin/env bash
# forge-lite/lib/scheduler.sh — Laravel scheduler cron lifecycle helpers
set -euo pipefail

# ---------------------------------------------------------------------------
# get_scheduler_cron_path <domain> [cron_dir]
#   Returns the Debian-compatible /etc/cron.d path for a site scheduler.
# ---------------------------------------------------------------------------
get_scheduler_cron_path() {
    local domain="$1" cron_dir="${2:-/etc/cron.d}" site_id domain_hash
    site_id="$(sanitize_for_identifier "${domain}")"
    # Leave headroom for site-specific candidate and renderer temp suffixes.
    site_id="${site_id:0:140}"
    domain_hash="$(printf '%s' "${domain}" | sha256sum)" || return 1
    domain_hash="${domain_hash%% *}"
    printf '%s/%s-%s-scheduler' "${cron_dir}" "${site_id}" "${domain_hash}"
}

# ---------------------------------------------------------------------------
# get_legacy_scheduler_cron_path <domain> [cron_dir]
#   Returns the pre-fix path that contains the raw domain and is ignored by
#   Debian cron whenever the domain contains dots.
# ---------------------------------------------------------------------------
get_legacy_scheduler_cron_path() {
    local domain="$1" cron_dir="${2:-/etc/cron.d}"
    printf '%s/%s-scheduler' "${cron_dir}" "${domain}"
}

# ---------------------------------------------------------------------------
# _scheduler_path_is_addressable <path> <directory>
#   Returns 0 when the basename fits the directory's NAME_MAX, 1 when it is
#   physically impossible on that filesystem, and 2 when NAME_MAX is unknown.
# ---------------------------------------------------------------------------
_scheduler_path_is_addressable() {
    local path="$1" directory="$2" filename name_max
    filename="${path##*/}"
    if ! name_max="$(getconf NAME_MAX "${directory}" 2>/dev/null)"; then
        log_error "Could not determine NAME_MAX for ${directory}"
        return 2
    fi
    [[ ${#filename} -le ${name_max} ]]
}

# ---------------------------------------------------------------------------
# cleanup_scheduler_candidates <domain> [cron_dir]
#   Removes only interrupted candidates belonging to the exact site path.
# ---------------------------------------------------------------------------
cleanup_scheduler_candidates() {
    local domain="$1" cron_dir="${2:-/etc/cron.d}" cron_path cron_filename candidate

    cron_path="$(get_scheduler_cron_path "${domain}" "${cron_dir}")" || return 1
    cron_filename="${cron_path##*/}"

    for candidate in "${cron_dir}/.${cron_filename}.candidate."*; do
        [[ -e "${candidate}" || -L "${candidate}" ]] || continue
        if [[ -d "${candidate}" && ! -L "${candidate}" ]]; then
            log_error "Scheduler candidate cannot be removed safely: ${candidate}"
            return 1
        fi
        rm -f "${candidate}" || return 1
    done
}

# ---------------------------------------------------------------------------
# get_site_lock_path <domain> [lock_dir]
#   Returns the shared lifecycle lock used by add, remove, and migrations.
# ---------------------------------------------------------------------------
get_site_lock_path() {
    local domain="$1" lock_dir="${2:-${FORGE_LITE_LOCK_DIR:-/var/run}}"
    local cron_path cron_filename

    cron_path="$(get_scheduler_cron_path "${domain}" "${lock_dir}")" || return 1
    cron_filename="${cron_path##*/}"
    printf '%s/forge-lite-site-%s.lock' \
        "${lock_dir}" "${cron_filename%-scheduler}"
}

# ---------------------------------------------------------------------------
# acquire_site_lock <domain> [lock_dir]
#   Serializes the complete site lifecycle across add, remove, and catch-up.
#   File descriptor 201 remains open until the calling shell/subshell exits.
# ---------------------------------------------------------------------------
acquire_site_lock() {
    local domain="$1" lock_dir="${2:-${FORGE_LITE_LOCK_DIR:-/var/run}}" lock_path

    mkdir -p "${lock_dir}" || return 1
    lock_path="$(get_site_lock_path "${domain}" "${lock_dir}")" || return 1
    exec 201>"${lock_path}" || return 1
    flock 201 || return 1
}

# ---------------------------------------------------------------------------
# _has_manual_scheduler_cron <domain>
#   Detects a conflicting active scheduler in deployer's personal crontab.
# ---------------------------------------------------------------------------
_has_manual_scheduler_cron() {
    local domain="$1" crontab_content line trimmed
    local spool_dir="${FORGE_LITE_CRONTAB_SPOOL_DIR:-/var/spool/cron/crontabs}"
    local spool_file="${spool_dir}/deployer"

    if ! command -v crontab >/dev/null 2>&1; then
        [[ ! -e "${spool_file}" ]] && return 1
        return 2
    fi
    if ! crontab_content="$(crontab -u deployer -l 2>/dev/null)"; then
        [[ ! -e "${spool_file}" ]] && return 1
        return 2
    fi

    while IFS= read -r line; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ "${trimmed}" == \#* ]] && continue
        if [[ "${line}" == *"/home/deployer/sites/${domain}/current"* ]] &&
            [[ "${line}" == *"artisan schedule:run"* ||
                "${line}" == *"artisan schedule:work"* ]]; then
            return 0
        fi
    done <<< "${crontab_content}"

    return 1
}

# ---------------------------------------------------------------------------
# validate_scheduler_cron_targets <domain> <enabled> [cron_dir]
#   Rejects target types that cannot be safely repaired or removed. Migration
#   calls this for every site before its first mutation and again under lock.
# ---------------------------------------------------------------------------
validate_scheduler_cron_targets() {
    local domain="$1" enabled="$2" cron_dir="${3:-/etc/cron.d}"
    local cron_path legacy_path addressable_status

    cron_path="$(get_scheduler_cron_path "${domain}" "${cron_dir}")" || return 1
    legacy_path="$(get_legacy_scheduler_cron_path "${domain}" "${cron_dir}")"

    if [[ "${enabled}" == true ]] &&
        [[ ( -e "${cron_path}" || -L "${cron_path}" ) ]] &&
        [[ ! -f "${cron_path}" || -L "${cron_path}" ]]; then
        log_error "Scheduler cron target is not a regular file: ${cron_path}"
        return 1
    fi
    if [[ "${enabled}" == false && -d "${cron_path}" && ! -L "${cron_path}" ]]; then
        log_error "Scheduler cron target cannot be removed safely: ${cron_path}"
        return 1
    fi
    if _scheduler_path_is_addressable "${legacy_path}" "${cron_dir}"; then
        if [[ -d "${legacy_path}" && ! -L "${legacy_path}" ]]; then
            log_error "Legacy scheduler cron target cannot be removed safely: ${legacy_path}"
            return 1
        fi
    else
        addressable_status=$?
        [[ ${addressable_status} -eq 1 ]] || return 1
    fi
}

# ---------------------------------------------------------------------------
# verify_no_manual_scheduler_cron <domain>
#   Fails closed when deployer's crontab cannot be inspected. This prevents a
#   managed cron from being activated alongside an unknown manual scheduler.
# ---------------------------------------------------------------------------
verify_no_manual_scheduler_cron() {
    local domain="$1" status

    if _has_manual_scheduler_cron "${domain}"; then
        status=0
    else
        status=$?
    fi

    case "${status}" in
        0)
            log_error "Manual deployer scheduler already exists for ${domain}; remove it before enabling the managed cron"
            return 1
            ;;
        1) return 0 ;;
        *)
            log_error "Could not inspect deployer crontab for ${domain}; refusing to enable the managed cron"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# ensure_scheduler_cron <domain> <template> [cron_dir]
#   Atomically renders the active scheduler before removing its ignored legacy
#   counterpart. Repeated calls converge to the same file and content.
# ---------------------------------------------------------------------------
ensure_scheduler_cron() {
    local domain="$1" template="$2" cron_dir="${3:-/etc/cron.d}"
    local cron_path legacy_path cron_filename candidate addressable_status

    cron_path="$(get_scheduler_cron_path "${domain}" "${cron_dir}")"
    legacy_path="$(get_legacy_scheduler_cron_path "${domain}" "${cron_dir}")"
    cron_filename="${cron_path##*/}"

    if [[ ! "${cron_filename}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid scheduler cron filename: ${cron_filename}"
        return 1
    fi
    verify_no_manual_scheduler_cron "${domain}" || return 1
    validate_scheduler_cron_targets "${domain}" true "${cron_dir}" || return 1
    cleanup_scheduler_candidates "${domain}" "${cron_dir}" || return 1

    candidate="$(mktemp "${cron_dir}/.${cron_filename}.candidate.XXXXXX")" || return 1
    rm -f "${candidate}" || return 1
    if ! render_template "${template}" "${candidate}" "DOMAIN=${domain}"; then
        rm -f "${candidate}"
        return 1
    fi
    if grep -qE '\{\{[A-Z_]+\}\}' "${candidate}"; then
        rm -f "${candidate}"
        log_error "Unreplaced placeholder in scheduler cron for ${domain}"
        return 1
    fi

    if [[ -f "${cron_path}" ]] && cmp -s "${candidate}" "${cron_path}"; then
        rm -f "${candidate}" || return 1
    elif ! mv -f "${candidate}" "${cron_path}"; then
        rm -f "${candidate}"
        return 1
    fi

    if [[ ${EUID} -eq 0 ]]; then
        chown root:root "${cron_path}" || return 1
    fi
    chmod 644 "${cron_path}" || return 1

    if [[ "${legacy_path}" != "${cron_path}" ]]; then
        if _scheduler_path_is_addressable "${legacy_path}" "${cron_dir}"; then
            rm -f "${legacy_path}" || return 1
        else
            addressable_status=$?
            [[ ${addressable_status} -eq 1 ]] || return 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# remove_scheduler_cron <domain> [cron_dir]
#   Removes both current and pre-fix paths so teardown and failure cleanup are
#   symmetric across all installed-state generations.
# ---------------------------------------------------------------------------
remove_scheduler_cron() {
    local domain="$1" cron_dir="${2:-/etc/cron.d}"
    local cron_path legacy_path addressable_status legacy_addressable=false

    cron_path="$(get_scheduler_cron_path "${domain}" "${cron_dir}")"
    legacy_path="$(get_legacy_scheduler_cron_path "${domain}" "${cron_dir}")"
    cleanup_scheduler_candidates "${domain}" "${cron_dir}" || return 1

    if _scheduler_path_is_addressable "${legacy_path}" "${cron_dir}"; then
        legacy_addressable=true
    else
        addressable_status=$?
        [[ ${addressable_status} -eq 1 ]] || return 1
    fi

    rm -f "${cron_path}" || return 1
    if [[ "${legacy_addressable}" == true ]]; then
        rm -f "${legacy_path}" || return 1
    fi
}

# ---------------------------------------------------------------------------
# migrate_scheduler_crons <site_config_dir> <template> [cron_dir] [lock_dir]
#   Catch-up migration for fresh, adjacent, and version-skipping updates.
#   ENABLE_SCHEDULER defaults to true because that was the historic behavior.
# ---------------------------------------------------------------------------
migrate_scheduler_crons() {
    local site_config_dir="$1" template="$2" cron_dir="${3:-/etc/cron.d}"
    local lock_dir="${4:-${FORGE_LITE_LOCK_DIR:-/var/run}}"
    local site_config config_name domain enable_scheduler index
    local legacy_path had_legacy current_domain current_enable_scheduler
    local addressable_status
    local -a site_configs=() domains=()

    [[ -d "${site_config_dir}" ]] || return 0

    # Preflight every site before the first mutation. backup.conf is the
    # supported global offsite-backup config and is not a site definition.
    for site_config in "${site_config_dir}"/*.conf; do
        [[ -f "${site_config}" ]] || continue
        config_name="${site_config##*/}"
        [[ "${config_name}" == "backup.conf" ]] && continue
        config_name="${config_name%.conf}"

        domain="$(_site_config_value "${site_config}" DOMAIN)"
        enable_scheduler="$(_site_config_value "${site_config}" ENABLE_SCHEDULER)"
        enable_scheduler="${enable_scheduler:-true}"

        if [[ -z "${domain}" ]]; then
            log_error "Site config lacks DOMAIN: ${site_config}"
            return 1
        fi
        validate_domain "${domain}"
        if [[ "${domain}" != "${config_name}" ]]; then
            log_error "DOMAIN does not match site config filename: ${site_config}"
            return 1
        fi

        case "${enable_scheduler}" in
            true)
                validate_scheduler_cron_targets \
                    "${domain}" "${enable_scheduler}" "${cron_dir}" || return 1
                verify_no_manual_scheduler_cron "${domain}" || return 1
                ;;
            false)
                validate_scheduler_cron_targets \
                    "${domain}" "${enable_scheduler}" "${cron_dir}" || return 1
                ;;
            *)
                log_error "Invalid ENABLE_SCHEDULER value in ${site_config}: ${enable_scheduler}"
                return 1
                ;;
        esac

        site_configs+=("${site_config}")
        domains+=("${domain}")
    done

    for index in "${!site_configs[@]}"; do
        site_config="${site_configs[${index}]}"
        domain="${domains[${index}]}"

        (
            acquire_site_lock "${domain}" "${lock_dir}" || exit 1
            [[ -f "${site_config}" ]] || exit 0

            current_domain="$(_site_config_value "${site_config}" DOMAIN)"
            current_enable_scheduler="$(_site_config_value \
                "${site_config}" ENABLE_SCHEDULER)"
            current_enable_scheduler="${current_enable_scheduler:-true}"

            if [[ "${current_domain}" != "${domain}" ]]; then
                log_error "DOMAIN changed during scheduler migration: ${site_config}"
                exit 1
            fi

            validate_scheduler_cron_targets \
                "${current_domain}" "${current_enable_scheduler}" "${cron_dir}" || return 1

            case "${current_enable_scheduler}" in
            true)
                legacy_path="$(get_legacy_scheduler_cron_path "${domain}" "${cron_dir}")"
                had_legacy=false
                if _scheduler_path_is_addressable "${legacy_path}" "${cron_dir}"; then
                    [[ -e "${legacy_path}" ]] && had_legacy=true
                else
                    addressable_status=$?
                    [[ ${addressable_status} -eq 1 ]] || return 1
                fi
                ensure_scheduler_cron \
                    "${domain}" "${template}" "${cron_dir}" || return 1
                if [[ "${had_legacy}" == true ]]; then
                    log_info "Migrated scheduler cron for ${domain}"
                fi
                ;;
            false)
                remove_scheduler_cron "${domain}" "${cron_dir}" || return 1
                ;;
            *)
                log_error "Invalid ENABLE_SCHEDULER value in ${site_config}: ${current_enable_scheduler}"
                return 1
                ;;
            esac
        ) || return 1
    done
}
