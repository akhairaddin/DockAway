#!/bin/zsh

set -euo pipefail

bundle_id="AK.DockAway"
mode="${1:-input}"

if pgrep -x DockAway >/dev/null 2>&1; then
    print -u2 "Quit DockAway before resetting its permissions."
    exit 1
fi

reset_input_monitoring() {
    tccutil reset ListenEvent "$bundle_id"
}

case "$mode" in
    input)
        reset_input_monitoring
        print "Input Monitoring onboarding reset for DockAway."
        print "Launch DockAway to test the native Input Monitoring request."
        ;;
    full)
        tccutil reset Accessibility "$bundle_id"
        reset_input_monitoring
        print "Accessibility and Input Monitoring onboarding reset for DockAway."
        print "Launch DockAway to test the complete first-run permission flow."
        ;;
    *)
        print -u2 "Usage: $0 [input|full]"
        exit 2
        ;;
esac
