# DisplayLink / Elgato Prompter: Hyprland's backend (aquamarine) only
# considers the DRM devices listed in AQ_DRM_DEVICES, and it reads the
# variable exactly once at compositor startup. Without the evdi node in the
# list, a DisplayLink output never appears — even with working drivers.
#
# IMPORTANT: aquamarine splits the list on ":", so /dev/dri/by-path/ entries
# are unusable (PCI addresses contain colons themselves). Resolve through the
# driver name to the colon-free /dev/dri/cardN nodes instead; the numbering
# may change freely between boots.
#
# Order matters: real GPUs first (boot VGA up front), evdi nodes last.
_aq_gpus=""
_aq_boot=""
_aq_evdi=""
for _aq_c in /sys/class/drm/card[0-9]*; do
  [ -e "$_aq_c" ] || continue
  case "${_aq_c##*/}" in *-*) continue ;; esac # skip connector entries
  _aq_node="/dev/dri/${_aq_c##*/}"
  case "$(basename "$(readlink -f "$_aq_c/device/driver" 2>/dev/null)" 2>/dev/null)" in
    evdi)
      _aq_evdi="${_aq_evdi:+$_aq_evdi:}$_aq_node" ;;
    "")
      ;;
    *)
      if [ "$(cat "$_aq_c/device/boot_vga" 2>/dev/null)" = "1" ]; then
        _aq_boot="$_aq_node"
      else
        _aq_gpus="${_aq_gpus:+$_aq_gpus:}$_aq_node"
      fi ;;
  esac
done
_aq_list="${_aq_boot:+$_aq_boot}${_aq_gpus:+${_aq_boot:+:}$_aq_gpus}"
if [ -n "$_aq_list" ] && [ -n "$_aq_evdi" ]; then
  export AQ_DRM_DEVICES="$_aq_list:$_aq_evdi"
fi
unset _aq_gpus _aq_boot _aq_evdi _aq_c _aq_node _aq_list
