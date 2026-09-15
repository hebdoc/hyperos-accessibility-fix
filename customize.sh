##########################################################################################
#
# MMT Extended Config Script
#
##########################################################################################
# shellcheck disable=1000-9999

##########################################################################################
# Config Flags
##########################################################################################

# Uncomment and change 'MINAPI' and 'MAXAPI' to the minimum and maximum android version for your mod
# Uncomment DYNLIB if you want libs installed to vendor for oreo+ and system for anything older
# Uncomment PARTOVER if you have a workaround in place for extra partitions in regular magisk install (can mount them yourself - you will need to do this each boot as well). If unsure, keep commented
# Uncomment PARTITIONS and list additional partitions you will be modifying (other than system and vendor), for example: PARTITIONS="/odm /product /system_ext"
# Minimum Android API version (API 33 covers HyperOS 1.0 on Android 13+)
MINAPI=33
#MAXAPI=25
#DYNLIB=true
#PARTOVER=true
#PARTITIONS=""

##########################################################################################
# Replace list
##########################################################################################

# List all directories you want to directly replace in the system
# Check the documentations for more info why you would need this

# Construct your list in the following format
# This is an example
REPLACE_EXAMPLE="
/system/app/Youtube
/system/priv-app/SystemUI
/system/priv-app/Settings
/system/framework
"

# Construct your own list here
REPLACE="
"

##########################################################################################
# Permissions
##########################################################################################

set_permissions() {
  set_perm_recursive "$MODPATH/scripts" 0 0 0700 0700
  if [ -d "/data/adb/modules/hyperos-accessibility-fix" ]; then
    cp -f "$MODPATH/action.sh" "/data/adb/modules/hyperos-accessibility-fix/action.sh" 2>/dev/null
    chmod 755 "/data/adb/modules/hyperos-accessibility-fix/action.sh" 2>/dev/null
  fi
}

##########################################################################################
# MMT Extended Logic - Don't modify anything after this
##########################################################################################

SKIPUNZIP=1
unzip -qjo "$ZIPFILE" 'common/functions.sh' -d $TMPDIR >&2
. $TMPDIR/functions.sh
