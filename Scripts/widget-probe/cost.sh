#!/bin/zsh
# Widget probe cost run (ADR 0016): runs the probe with EXTERNAL=1 and measures each phase's pids from outside: footprint, then top (4 samples, 3 s).
P="$1"; OUT="$2"; shift 2
EXTERNAL=1 "$P" cost "$@" > $OUT.raw 2>&1 &
probe=$!
seen=0
while kill -0 $probe 2>/dev/null; do
  n=$(grep -c '^PIDS' $OUT.raw)
  if (( n > seen )); then
    seen=$n
    echo "$(grep '^==' $OUT.raw | tail -1)"
    jobs_=()
    for kv in ${(s: :)$(grep '^PIDS' $OUT.raw | tail -1 | cut -d' ' -f2-)}; do
      name=${kv%=*}; pid=${kv#*=}
      ( fp=$(/usr/bin/footprint -p $pid --noCategories 2>&1 | grep -o 'Footprint: [0-9.]* [KMG]B')
        t=$(/usr/bin/top -l 4 -s 3 -pid $pid -stats pid,cpu,mem | grep "^$pid " | tail -3 | awk '{print $2" "$3}' | paste -sd'/' -)
        echo "  $name pid=$pid | $fp | top cpu mem (3 samples): $t" ) &
      jobs_+=($!)
    done
    wait $jobs_
  fi
  sleep 1
done
grep -v '^PIDS\|^==' $OUT.raw
