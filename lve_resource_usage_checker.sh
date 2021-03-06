#!/bin/bash
# Checker of user resources/Apache requests for cPanel & CloudLinux setups

delim="---------------------------------------------------------------------"

# input validation
cpun="${1}"
if [[ ! -d /var/cpanel/userdata/"${cpun}" ]] || [[ -z "${1}" ]]; then
    echo "ERROR: ${cpun} not found among server's cPanel users (system users are not allowed). Make sure that you entered correct details"
    exit 1
fi


# General parameters
echo "===== Memory info ====="
head -3 /proc/bc/"$(id -u "${cpun}")"/meminfo
echo "===== Processes ====="
user_processes="$(ps -lfu "${cpun}")"
if [[ "$(wc -l <<<"${user_processes}")" -le 16 ]]; then
    echo -e "${user_processes}"
else
    echo -e "${user_processes}" | head -16
    echo "Results truncated to 15, run command 'csps ${cpun} faux' as wh on the server to see all proceses."
fi

echo "===== MySQL queries ====="
user_mysql_queries="$(mysqladmin pr --verbose | grep "${cpun}")"
if [[ "$(wc -l <<<"${user_mysql_queries}")" -le 10 ]]; then
    echo -e "${user_mysql_queries}"
else
    echo -e "${user_mysql_queries}" | head
    echo "Results truncated to 10, run 'SHOW FULL PROCESSLIST;' from user's PHPMyAdmin to see all current queries if needed."
fi
echo "===== LVE stats over last hour ====="
lveinfo --user "${cpun}" --period 1h --time-unit 10m --show-columns from to epf cpuf pmemf vmemf iopsf nprocf uep ucpu upmem uvmem uio unproc


# Collecting data
user_cur_apache_reqs="$(apachectl fullstatus | egrep -e "$(grep " ${cpun}==" /etc/userdatadomains | cut -d: -f1 | cut -c1-32 | xargs | sed 's/ /:|/g')")"
user_cur_apache_req_num="$(wc -l <<<"${user_cur_apache_reqs}")"
user_hist_apache_reqs="$(cat /usr/local/apache/domlogs/"${cpun}"/*)"
user_hist_apache_req_num="$(wc -l <<<"${user_hist_apache_reqs}")"
user_domain_list="$(cd /etc/apache2/logs/domlogs/${cpun} || exit; ls | sed '/-ssl_log/d')"


# Apache requests-related stats

#echo "===== User Agents ====="
#cut -d\" -f6 <<< "${user_hist_apache_reqs}" | sort | uniq -c | sort -nr | head
#echo "===== Request destinations ====="
#cut -d\" -f2 <<< "${user_hist_apache_reqs}" | sort | uniq -c | sort -nr | head
#echo "===== Request source IPs ====="
#cut -d' ' -f1 <<< "${user_hist_apache_reqs}" | sort | uniq -c | sort -nr | head
#echo "===== Requests by site (up to 5 most popular) ====="


# the things we do for love
tf1="/tmp/$(date +%s)_$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)"
cut -d\" -f6 <<< "${user_hist_apache_reqs}" | sort | uniq -c | sort -nr | head > "${tf1}" &
ua_pid="$!"
tf2="/tmp/$(date +%s)_$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)"
cut -d\" -f2 <<< "${user_hist_apache_reqs}" | sort | uniq -c | sort -nr | head > "${tf2}" &
rd_pid="$!"
tf3="/tmp/$(date +%s)_$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)"
cut -d' ' -f1 <<< "${user_hist_apache_reqs}" | sort | uniq -c | sort -nr | head > "${tf3}" &
ri_pid="$!"
while true; do
    sleep 1
    test -d /proc/"${ua_pid}" || test -d /proc/"${rd_pid}" || test -d /proc/"${ri_pid}" || break
done

echo "===== Current Apache requests to user's domain ====="
echo -e "${user_cur_apache_reqs}"
echo "===== User Agents ====="
cat $tf1
echo "===== Request destinations ====="
cat $tf2
echo "===== Request source IPs ====="
cat $tf3
rm -f $tf1 $tf2 $tf3
echo "===== Requests by site (up to 5 most popular) ====="
# already here, duplicated for clarity
cd /etc/apache2/logs/domlogs/"${cpun}"
for i in ${user_domain_list}; do
    wc -l $i* | grep total | sed "s/total/$i/g";
done | sort -nr | head -5


## Checks
# AJAX requests
if [[ "${user_cur_apache_req_num}" -gt 0 ]]; then
    ajax_cur_req_num="$(cat <<< "${user_cur_apache_reqs}" | grep -ci ajax)"
    ajax_hist_req_num="$(cut -d\" -f2 <<< "${user_hist_apache_reqs}" | sort | uniq -c | sort -nr | head -5 | grep ajax | awk '{sum += $1} END {print sum}')"
    if [[ "$(expr "${user_hist_apache_req_num}" / "${ajax_hist_req_num}")" -lt 6 ]]; then
        issue_ajax="1"
        patterns="1"
    elif [[ "${ajax_cur_req_num}" -gt 0 ]]; then
        if [[ "$(expr "${user_cur_apache_req_num}" / "${ajax_cur_req_num}")" -lt 4 ]]; then
            issue_ajax="1"
            patterns="1"
        fi
    fi
fi


# DoS/self DoS
for i in $(cut -d' ' -f1 <<< "${user_hist_apache_reqs}" | sort | uniq -c | sort -nr | head -5 | awk '{print $2}'); do
    ip_request_amount="$(grep -c "$i " <<< "${user_hist_apache_reqs}")"
    if [[ "${user_hist_apache_req_num}" -gt "1000" ]] && [[ "$(expr ${user_hist_apache_req_num} / ${ip_request_amount} )" -lt 6 ]]; then
        if ifconfig | grep -q "${i}"; then
            issue_selfdos="1"
            selfdos_ip="$i"
        else
            issue_one_ip_dos="1"
            dos_ips="$dos_ips $i"
        fi
        patterns="1"
    fi
done


# Bots
bot_req_num="$(echo -e "${user_hist_apache_reqs}" | grep -ci bot)"
if [[ "${bot_req_num}" -gt 0 ]] && [[ "$(expr "${user_hist_apache_req_num}" / "${bot_req_num}")" -lt 4 ]]; then
    issue_bots="1"
    patterns="1"
fi


# LVE Faults
if /usr/sbin/lveinfo --user "${cpun}" --period 1d --time-unit 1d --show-columns epf cpuf pmemf vmemf iopsf nprocf | tr -d '0' | grep -q "[[:digit:]]"; then
    echo "===== Extended LVE report ====="
    echo "This additional section was generated because LVE limits were faulted during last 24 hours."
    echo $delim
    issue_lve_faults="1"
    patterns="1"
    raw_24h_lveinfo="$(/usr/sbin/lveinfo --user "${cpun}" --period 24h --time-unit 1h --show-columns from to epf cpuf pmemf vmemf iopsf nprocf | grep "[[:digit:]]")"
    for i in {23..0}; do
        # Hail Satan and his minions who keep re-inventing different formats to represenat date/time
        lveinfo_ptrn="^\| $(date --date="$i hours ago" +%m-%d' '%H)"
        apache_domlog_ptrn="$(date --date="$i hours ago" +%d/%b/%Y:%H)"
        cron_log_ptrn="$(date --date="$i hours ago" +%b' '%e' '%H)"
        #raw_hourly_lveinfo="$(/usr/sbin/lveinfo --user ${cpun} --period 24h --time-unit 1h --show-columns from to epf cpuf pmemf vmemf iopsf nprocf | egrep "$lveinfo_ptrn" | cut -d\| -f4-)"
        raw_hourly_lveinfo="$(cat <<<"${raw_24h_lveinfo}" | egrep "$lveinfo_ptrn" | cut -d\| -f4-)"
        hourly_cron_runs="$(egrep "${cron_log_ptrn}" /var/log/cron | grep -v LIST | grep -c $cpun)"
        nonzero_lve_faults="$(cat <<< "${raw_hourly_lveinfo}" | sed 's/ 0 //g' | sed 's/|//g'| xargs)"
        date --date="$i hours ago"
        if [[ -z "${nonzero_lve_faults}" ]]; then
            echo "No LVE faults detected"
        else
            printf "EPf: %s  | CPUf: %s | PMemF: %s | VMemF: %s | IOPSf: %s | NprocF: %s\n" $(cat <<< "${raw_hourly_lveinfo}" | tr -d '|' | awk '{print $1, $2, $3, $4, $5, $6}')
            echo "Cron job runs: $hourly_cron_runs"
            echo "===== User Agents ====="
            egrep "${apache_domlog_ptrn}" <<< "${user_hist_apache_reqs}" | cut -d\" -f6 | sort | uniq -c | sort -nr | head -5
            echo "===== Request destinations ====="
            egrep "${apache_domlog_ptrn}" <<< "${user_hist_apache_reqs}" | cut -d\" -f2 | sort | uniq -c | sort -nr | head -5
            echo "===== Request source IPs ====="
            egrep "${apache_domlog_ptrn}" <<< "${user_hist_apache_reqs}" | cut -d' ' -f1 | sort | uniq -c | sort -nr | head -5
        fi
        echo $delim
    done
fi


# Printing summary
echo "========== Resource checker summary =========="
if [[ "${issue_lve_faults}" == "1" ]]; then
    echo -e "PATTERN DETECTED: LVE faults took place over last 24 hours (see 'Extended LVE report' for details).\nSOLUTION: Usually LVE faults are combined with another pattern(s). If the errors are present right now, check 'Proceses' and 'Current Apache requests' section. If they were only present earlier, it is necessary to analyse per-hour trends in 'Extended LVE report' section to figure out what was going on. If you need help with interpretation, contact TechSup.\n"
fi

if [[ "${issue_bots}" == "1" ]]; then
    echo -e "PATTERN DETECTED: Many requsts from bots/web-crawlers (see 'User Agents' for details).\nSOLUTION: Limiting crawl frequency via 'crawl-delay' directive is recommended if not yet set https://www.namecheap.com/support/knowledgebase/article.aspx/9463/2225/what-is-a-robotstxt-file-and-how-to-use-it#bots\n"
fi

if [[ "${issue_ajax}" == "1" ]]; then
    echo -e "PATTERN DETECTED: AJAX requests (see 'Request destinations'/'Current Apache requests' for details).\nSOLUTION: In case this is a WordPress site, effect can be mitigated using WordPress heartbeat plugin https://www.namecheap.com/support/knowledgebase/article.aspx/9971/2187/what-is-wordpress-heartbeat-and-how-to-deal-with-adminajaxphp-usage. If this is not a WordPress site, client should limit AJAXes in another way or upgrade to VPS/dedic.\n"
fi

if [[ "${issue_selfdos}" == "1" ]]; then
    echo -e "PATTERN DETECTED: Self-DoS - site is making requests to itself (IP $selfdos_ip - see 'Request source IPs' for details).\nSOLUTION: Client should tweak the site to make less such requests or move to VPS/dedicated server. The upgrade may or may not help depending on site's architecture - it is client's responsiblity to know that.\n"
fi

if [[ "${issue_one_ip_dos}" == "1" ]]; then
    echo -e "PATTERN DETECTED: high ratio of request from one source (IP(s) $dos_ips - see 'Request source IPs' for details).\nSOLUTION: Indicates either client's resource-heavy activity, necessary requests to the site, or DoS attack. It is usual for sites to work this way, but can a problem when LVE usage is high. If so, inquire if client recognizes the IP. If yes, s/he will need to either limit his activity, tweak the site so that requests consume less resources, or move to VPS/dedicated server. If not, try blocking the IP in .htaccess, reset cage and check effect in 2-3 minutes.\n"
fi


if [[ "${issue_myisam_locks}" == "1" ]]; then
    echo -e "PATTERN DETECTED: Queries to MyISAM table stuck in 'Waiting for table-level lock' status (see 'MySQL Queries' for details).\mSOLUTION:This happens when high amount of simultanerous updates/selects are issued to tables using MyISAM storage engine. It is possible to change DB engine with the following query 'ALTER TABLE table_name ENGINE InnoDB;' (substitute table_name with name of affected table, see 'MySQL queries' for details). This results in PHP processes getting stuck while waiting for DB resonse, which in turn slows new requests to site and consumes server resources. Either engine change or the entire database interaction overhaul is necessary to fix this. Upgrade will not help as database will keep using the same engine.\n\*IF YOU GO FOR EXTRA-MILE AND DO THIS FOR A CLIENT, MAKE SURE TO MAKE A BACKUP(MYSQLDUMP) BEFORE APPLYING THE CHANGES.\*.\n"
fi

if [[ "${patterns}" == "0" ]]; then
    echo "No recognizeable patterns found. You may try to interpret 'Processes', 'MySQL queries' and 'Apache requests to user's domain' yourself if you are absoutely sure that you can interpret them. Additionally, make sure to go to https://gtmetrix.com and check site's optimization. If no clear expalination is found, contact to SME/TechSup for assistance."
fi
