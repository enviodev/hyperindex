#!/usr/bin/env bash
# Usage: analyze.sh <trace> <ss samples>
# Prints, tab separated: queries, in-flight p50, headers ms p50/p90,
# body ms p50/p90, body MB p50, body MB/s p50, TCP connections max,
# RTT ms p50, cwnd p50, retransmits max.
trace=$1; ss_log=$2
pct() { sort -n | awk -v p="$1" '{a[NR]=$1} END{if(NR==0){print "-";exit} i=int(NR*p); if(i<1)i=1; print a[i]}'; }
queries=$(wc -l < "$trace" 2>/dev/null || echo 0)
inflight=$(cut -f2 "$trace" | pct 0.5)
h50=$(cut -f3 "$trace" | pct 0.5); h90=$(cut -f3 "$trace" | pct 0.9)
b50=$(cut -f4 "$trace" | pct 0.5); b90=$(cut -f4 "$trace" | pct 0.9)
mb=$(awk -F'\t' '{printf "%.2f\n", $5/1e6}' "$trace" | pct 0.5)
rate=$(awk -F'\t' '$4>0{printf "%.1f\n", $5/1e3/$4}' "$trace" | pct 0.5)
conns=$(awk '/^@/{if(n>m)m=n; n=0; next} /^[0-9]/{n++} END{if(n>m)m=n; print m+0}' "$ss_log")
rtt=$(grep -o ' rtt:[0-9.]*' "$ss_log" | cut -d: -f2 | pct 0.5)
cwnd=$(grep -o ' cwnd:[0-9]*' "$ss_log" | cut -d: -f2 | pct 0.5)
retrans=$(awk '/^@/{if(s>m)m=s; s=0; next} {if(match($0, / retrans:[0-9]+\/[0-9]+/)){split(substr($0,RSTART,RLENGTH),a,"/"); s+=a[2]}} END{if(s>m)m=s; print m+0}' "$ss_log")
printf '%s\t%s\t%s/%s\t%s/%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$queries" "$inflight" "$h50" "$h90" "$b50" "$b90" "$mb" "$rate" "$conns" "$rtt" "$cwnd" "$retrans"
