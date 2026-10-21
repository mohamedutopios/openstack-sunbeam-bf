#!/usr/bin/env bash
# Demarre le traceur OpenStack en arriere-plan (journal : trace.log a cote du script).
set -euo pipefail
cd "$(dirname "$0")"
bash ./stop.sh >/dev/null || true
setsid nohup python3 openstack-trace.py "$@" > trace.log 2>&1 < /dev/null &
for _ in $(seq 1 90); do
    if grep -q "Pret" trace.log 2>/dev/null; then
        echo "Traceur demarre : http://192.168.56.10:8099/"
        exit 0
    fi
    if ! pgrep -f "[o]penstack-trace[.]py" >/dev/null; then
        echo "Le traceur s'est arrete au demarrage :"
        tail -20 trace.log
        exit 1
    fi
    sleep 1
done
echo "Demarrage plus long que prevu, voir $(pwd)/trace.log"
