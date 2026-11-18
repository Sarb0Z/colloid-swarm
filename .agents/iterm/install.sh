#!/usr/bin/env bash
# Install the iTerm2 pane commands and the phone link for this user. Safe to
# rerun: what is in place is left alone, and nothing that is not this script's
# own link is replaced.
#
#   install.sh [--zone <IANA zone>]   Link bin/* and connect/dev-server into ~/.local/bin, and install the
#                                     phone link (phone/install.py does both and
#                                     says what the phone link is): its hook in
#                                     each Claude account's settings.json and its
#                                     two launchd agents. --zone is the phone's
#                                     time zone, by default this Mac's. A refusal
#                                     changes nothing, the pane links included.
#   install.sh --check                Print what an install would change, and
#                                     change nothing.
#   install.sh --uninstall [--check]  Remove the phone link's parts, and only
#                                     those: the pane commands stay.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
mode=install check="" zone=""
while (($#)); do
  case $1 in
    --check) check=--check ;;
    --uninstall) mode=uninstall ;;
    --zone)
      [[ $# -ge 2 ]] || { echo "install.sh: --zone needs a time zone, for example Europe/Lisbon" >&2; exit 2; }
      zone=$2
      shift
      ;;
    *)
      echo "usage: install.sh [--check] [--uninstall] [--zone <IANA zone>]" >&2
      exit 2
      ;;
  esac
  shift
done

arguments=("$mode")
[[ -z $check ]] || arguments+=("$check")
[[ -z $zone ]] || arguments+=(--zone "$zone")
exec python3 "$here/phone/install.py" "${arguments[@]}"
