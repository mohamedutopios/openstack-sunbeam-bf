#!/usr/bin/env bash
# Arrete le traceur OpenStack et tous les processus de lecture qu'il a lances.
# Les crochets empechent un motif de correspondre a la ligne de commande de pkill elle-meme.
pattern='[o]penstack-trace[.]py|[o]penstack logs -f --tail=0|[o]vsdb-client monitor --format=json|[j]ournalctl -f -n 0 -o json|[v]irsh event --all --loop|[m]ysql -uroot -N -B --unbuffered|MYSQL_PWD=.* [m]ysql'
if pgrep -f "$pattern" >/dev/null; then
    sudo pkill -f "$pattern"
    sleep 2
fi
if pgrep -f "$pattern" >/dev/null; then
    echo "Des processus resistent :"
    pgrep -af "$pattern"
    exit 1
fi
echo "Traceur arrete."
