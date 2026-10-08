#!/usr/bin/env bash
# Evaluate the system against the tailored STIG profile; write ARF + HTML report.
#   usage: verify.sh [tailoring.xml]   (defaults to the one harden.sh generated)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root

ds="$(find_datastream)" || die "No SCAP datastream found; dnf install scap-security-guide"
tailoring="${1:-${STATE_DIR}/tailoring.xml}"
[[ -f $tailoring ]] || die "Tailoring file $tailoring missing; run harden.sh first."
pid="$(cat "${STATE_DIR}/profile_id")"

ts="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"
results="${LOG_DIR}/results-${ts}.xml"
rc=0
oscap xccdf eval --profile "$pid" --tailoring-file "$tailoring" \
  --results "$results" --results-arf "${LOG_DIR}/arf-${ts}.xml" \
  --report "${LOG_DIR}/report-${ts}.html" "$ds" >"${LOG_DIR}/scan-${ts}.log" 2>&1 || rc=$?
[[ $rc -le 2 ]] || { tail -20 "${LOG_DIR}/scan-${ts}.log" >&2; die "oscap failed (rc=$rc)."; }

count() { grep -c "<result>$1</result>" "$results" || true; }
pass=$(count pass); fail=$(count fail); na=$(count notapplicable); err=$(count error); unk=$(count unknown)
log "Scan: pass=$pass fail=$fail error=$err unknown=$unk notapplicable=$na"
log "Report: ${LOG_DIR}/report-${ts}.html"
if [[ "$na" -gt 60 ]]; then
  warn "$na rules are notapplicable -- expected in a container; on a real host this suggests the content isn't matching Rocky (use ssg-rl10-ds.xml, not the RHEL datastream)."
fi
if [[ "$fail" -gt 0 ]]; then
  warn "Failing rules:"
  # rule-result blocks: pull idref of those with result=fail
  awk '/<rule-result /{match($0,/idref="[^"]*"/); id=substr($0,RSTART+7,RLENGTH-8)} /<result>fail<\/result>/{print "    " id}' "$results" \
    | sed 's/xccdf_org.ssgproject.content_rule_//' | sort -u
fi
echo "$fail" > "${STATE_DIR}/last_fail_count"
exit 0
