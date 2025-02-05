#!/bin/sh

# Copyright (c) 2016, prpl Foundation
#
# Permission to use, copy, modify, and/or distribute this software for any purpose with or without
# fee is hereby granted, provided that the above copyright notice and this permission notice appear
# in all copies.
# 
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE
# INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE
# FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
# LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
# ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#
# Author: Nils Koenig <openwrt@newk.it>

#set -x
set -o pipefail

SCRIPT=$0
LOCKFILE=/tmp/wifi_schedule.lock
LOGFILE=/tmp/log/wifi_schedule.log
LOGGING=0 #default is off
PACKAGE=wifi_schedule
GLOBAL=${PACKAGE}.@global[0]

_log()
{
    if [ ${LOGGING} -eq 1 ]; then
        local ts=$(date)
        echo "$ts $@" >> ${LOGFILE}
    fi
}

_exit()
{
    local rc=$1
    exit ${rc}
}

_cron_restart()
{
    /etc/init.d/cron restart > /dev/null
}

_add_cron_script()
{
    (crontab -l ; echo "$1") | sort | uniq | crontab -
    _cron_restart
}

_rm_cron_script()
{
    crontab -l | grep -v "$1" |  sort | uniq | crontab -
    _cron_restart
}

_get_uci_value_raw()
{
    local value
    value=$(uci get $1 2> /dev/null)
    local rc=$?
    echo ${value}
    return ${rc}
}

_get_uci_value()
{
    local value
    value=$(_get_uci_value_raw $1)
    local rc=$?
    if [ ${rc} -ne 0 ]; then
        _log "Could not determine UCI value $1"
        return 1
    fi
    echo ${value}
}

_format_dow_list()
{
    local dow=$1
    local flist=""
    local day
    for day in ${dow}
    do
        if [ ! -z ${flist} ]; then
            flist="${flist},"
        fi
        flist="${flist}${day:0:3}"
    done
    echo ${flist}
}


_enable_wifi_schedule()
{
    local entry=$1
    local starttime
    local stoptime
    starttime=$(_get_uci_value ${PACKAGE}.${entry}.starttime) || _exit 1
    stoptime=$(_get_uci_value ${PACKAGE}.${entry}.stoptime) || _exit 1

    local dow
    dow=$(_get_uci_value_raw ${PACKAGE}.${entry}.daysofweek) || _exit 1 
    
    local fdow=$(_format_dow_list "$dow")
    local forcewifidown
    forcewifidown=$(_get_uci_value ${PACKAGE}.${entry}.forcewifidown)
    local stopmode="stop"
    if [ $forcewifidown -eq 1 ]; then
        stopmode="forcestop"
    fi


    local stop_cron_entry="$(echo ${stoptime} | awk -F':' '{print $2, $1}') * * ${fdow} ${SCRIPT} ${stopmode}" # ${entry}"
    _add_cron_script "${stop_cron_entry}"

    if [[ $starttime != $stoptime ]]                             
    then                                                         
        local start_cron_entry="$(echo ${starttime} | awk -F':' '{print $2, $1}') * * ${fdow} ${SCRIPT} start" # ${entry}"
        _add_cron_script "${start_cron_entry}"
    fi

    return 0
}

_is_earlier()
{
    local hhmm=$1
    local ret=1
    if [[ $(date +%H) -lt ${hhmm:0:2} ]]
    then
        ret=0
    fi
    if [[ $(date +%H) -eq ${hhmm:0:2} && $(date +%M) -lt ${hhmm:3:4} ]]
    then
        ret=0
    fi
    echo $ret
}

# returns 0 if now() is in $entry
_check_startup_timewindow()
{
    local entry=$1
    local starttime
    local stoptime
    local dow
    starttime=$(_get_uci_value ${PACKAGE}.${entry}.starttime) || _exit 1
    stoptime=$(_get_uci_value ${PACKAGE}.${entry}.stoptime) || _exit 1
    dow=$(_get_uci_value_raw ${PACKAGE}.${entry}.daysofweek) || _exit 1

    echo $dow | grep $(date +%A) > /dev/null 2>&1
    rc=$?

    if [[ $rc -eq 0 && $(date +%H) -ge ${starttime:0:2}  && $(date +%M) -ge ${starttime:3:4}  && $(_is_earlier $stoptime) -eq 0  ]]
    then
        echo 0
    else
        echo 1
    fi
}

_get_wireless_interfaces()
{
    iwinfo | grep ESSID | cut -f 1 -s -d" "
}


get_module_list()
{
    local mod_list
    local _if
    for _if in $(_get_wireless_interfaces)
    do
        local mod=$(basename $(readlink -f /sys/class/net/${_if}/device/driver))
        local mod_dep=$(modinfo ${mod} | awk '{if ($1 ~ /depends/) print $2}')
        mod_list=$(echo -e "${mod_list}\n${mod},${mod_dep}" | sort | uniq)
    done
    echo $mod_list | tr ',' ' '
}

_save_module_list_uci()
{
    local list=$(get_module_list)
    uci set ${GLOBAL}.modules="${list}"
    uci commit ${PACKAGE}
}

_unload_modules()
{
    local list=$(_get_uci_value ${GLOBAL}.modules) 
    local retries
    retries=$(_get_uci_value ${GLOBAL}.modules_retries) || _exit 1
    _log "unload_modules ${list} (retries: ${retries})"
    local i=0
    while [[ ${i} -lt ${retries}  &&  "${list}" != "" ]]
    do  
        i=$(($i+1))
        local mod
        local first=0
        for mod in ${list}
        do
            if [ $first -eq 0 ]; then
                list=""
                first=1
            fi
            rmmod ${mod} > /dev/null 2>&1
            if [ $? -ne 0 ]; then
                list="$list $mod"
            fi
        done
    done
}


_load_modules()
{
    local list=$(_get_uci_value ${GLOBAL}.modules)
    local retries
    retries=$(_get_uci_value ${GLOBAL}.modules_retries) || _exit 1
    _log "load_modules ${list} (retries: ${retries})"
    local i=0
    while [[ ${i} -lt ${retries}  &&  "${list}" != "" ]]
    do  
        i=$(($i+1))
        local mod
        local first=0
        for mod in ${list}
        do
            if [ $first -eq 0 ]; then
                list=""
                first=1
            fi
            modprobe ${mod} > /dev/null 2>&1
            rc=$? 
            if [ $rc -ne 255 ]; then
                list="$list $mod"
            fi
        done
    done
}

_create_cron_entries()
{
    local entries=$(uci show ${PACKAGE} 2> /dev/null | awk -F'.' '{print $2}' | grep -v '=' | grep -v '@global\[0\]' | uniq | sort)
    local _entry
    for entry in ${entries}
    do 
        local status
        status=$(_get_uci_value ${PACKAGE}.${entry}.enabled) || _exit 1
        if [ ${status} -eq 1 ]
        then
            _enable_wifi_schedule ${entry}
        fi
    done
}

_should_wifi_enabled() 
{

    local enable_wifi=0
    local entries=$(uci show ${PACKAGE} 2> /dev/null | awk -F'.' '{print $2}' | grep -v '=' | grep -v '@global\[0\]' | uniq | sort)
    local _entry
    for _entry in ${entries}
    do
        local status
        status=$(_get_uci_value ${PACKAGE}.${_entry}.enabled) || _exit 1
        if [ ${status} -eq 1 ]
        then
            enable_wifi=$(_check_startup_timewindow $_entry)
        fi
    done
    echo ${enable_wifi}
}

startup()
{
    _log "startup"
    local _enable_wifi=$(_should_wifi_enabled)
    if [[ ${_enable_wifi} -eq 0 ]]
    then
        _log "enable wifi"
        enable_wifi
    else 
        _log "disable wifi"
        disable_wifi
    fi
}

check_cron_status()
{
    local global_enabled
    global_enabled=$(_get_uci_value ${GLOBAL}.enabled) || _exit 1
    _rm_cron_script "${SCRIPT}"
    if [ ${global_enabled} -eq 1 ]; then
        _create_cron_entries
    fi
}

disable_wifi()
{
    _rm_cron_script "${SCRIPT} recheck"
    _set_status_wifi_uci 1
    local unload_modules
    unload_modules=$(_get_uci_value_raw ${GLOBAL}.unload_modules) || _exit 1
    if [[ "${unload_modules}" == "1" ]]; then
        _unload_modules
    fi    
}

soft_disable_wifi()
{
    local _disable_wifi=0 #0: disable wifi, 1: do not disable wifi
    local iwinfo=/usr/bin/iwinfo
    if [ ! -e ${iwinfo} ]; then
        _log "${iwinfo} not available, skipping"
        return 1
    fi

    local ignore_stations=$(_get_uci_value_raw ${GLOBAL}.ignore_stations)
    [ -n "${ignore_stations}" ] && _log "Ignoring station(s) ${ignore_stations}"

    # check if no stations are associated
    local _if
    for _if in $(_get_wireless_interfaces)
    do
        local stations=$(${iwinfo} ${_if} assoclist | grep -o -E '([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}')
        if [ -n "${ignore_stations}" ]; then
            stations=$(echo "${stations}" | grep -vwi -E "${ignore_stations// /|}")
        fi

        if [ -n "${stations}" ]; then
            _disable_wifi=1
            _log "Station(s) $(echo ${stations}) associated on ${_if}"
        fi
    done

    local _wifi_enabled=$(_should_wifi_enabled)
    if [[ ${_disable_wifi} -eq 0 && ${_wifi_enabled} -eq 1 ]]; then
        _log "No stations associated, disable wifi."
        disable_wifi
    elif [[ ${_disable_wifi} -eq 0 && ${_wifi_enabled} -eq 0 ]]; then
        _log "Do not disable wifi since there is an allow timeframe, skip rechecking."
        _rm_cron_script "${SCRIPT} recheck"
    else
        _log "Could not disable wifi due to associated stations, retrying..."
        local recheck_interval=$(_get_uci_value ${GLOBAL}.recheck_interval)
        _add_cron_script "*/${recheck_interval} * * * * ${SCRIPT} recheck"
    fi
}

_set_status_wifi_uci()
{
    local status=$1
    local radios=$(uci show wireless | grep radio | awk -F'.' '{print $2}' | grep -v '[=|@]' | sort | uniq)
    for radio in ${radios}
    do
        uci set wireless.${radio}.disabled=${status}
    done
    uci commit
}

enable_wifi()
{
    _rm_cron_script "${SCRIPT} recheck"
    local unload_modules
    unload_modules=$(_get_uci_value_raw ${GLOBAL}.unload_modules) || _exit 1
    if [[ "${unload_modules}" == "1" ]]; then
        _load_modules
    fi
    _set_status_wifi_uci 0
    /sbin/wifi
}

usage()
{
    echo ""
    echo "$0 cron|start|startup|stop|forcestop|recheck|getmodules|help"
    echo ""
    echo "    cron: Create cronjob entries."
    echo "    start: Start wifi."
    echo "    startup: Checks current timewindow and enables/disables WIFI accordingly."
    echo "    stop: Stop wifi gracefully, i.e. check if there are stations associated and if so keep retrying."
    echo "    forcestop: Stop wifi immediately."
    echo "    recheck: Recheck if wifi can be disabled now."
    echo "    getmodules: Returns a list of modules used by the wireless driver(s)"
    echo "    help: This description."
    echo ""
}

_cleanup()
{
    lock -u ${LOCKFILE}
    rm ${LOCKFILE}
}

###############################################################################
# MAIN
###############################################################################
trap _cleanup EXIT

LOGGING=$(_get_uci_value ${GLOBAL}.logging) || _exit 1
_log ${SCRIPT} $1
lock ${LOCKFILE}

case "$1" in
    cron) 
        check_cron_status
        startup
    ;;
    start) enable_wifi ;;
    startup) startup ;;
    forcestop) disable_wifi ;;
    stop) soft_disable_wifi ;;
    recheck) soft_disable_wifi ;;
    getmodules) get_module_list ;;
    help|--help|-h) usage ;;
esac

_exit 0
