# 1.0.6
- Fixed watchdog daemon crash caused by unsupported `--line-buffered` on Toybox grep
- Fixed issue where disabling all accessibility services in Settings was reverted automatically
- Replaced deprecated and resource-heavy `am stack list` with fast `dumpsys window displays` focus check (<20ms)
- Fixed component normalization order so shorthand components match exclusion rules properly
- Added automatic detection and pruning of uninstalled packages to prevent settings database pollution
- Support custom service exclusions via optional `a11y_exclude.txt`
- Overhauled `action.sh` to provide comprehensive daemon status, live vs watchlist comparison, diagnostic controls, and recovery
- Fixed race conditions, stale lock files, and initial 60s sleep in `a11y_watchdog_monitor.sh`
- Expanded Android API support to API 33+ (covering HyperOS 1.0 on Android 13)
- Added automated regression test suite

# 1.0.5
- Changed my username in the module files, and updated old links

# 1.0.4
- Optimized && reworked the background script yet again to reduce the "debouncing" delay
- Started using "am stack" instead of resource hungry "dumpsys"

# 1.0.3
- Reworked the background script to listen for accessibility state updates instead 
of force-stop to make it work in all cases
- Fixed typos in the module

# 1.0.2
- Fixed derp from previous release that broke everything
- Bumped minimal magisk/ksu version to the first one to support action.sh

# 1.0.1
- Fixed the module not working with multiple accessibility services enabled
- Added more elements to MMRL's repo.json

# 1.0.0
Initial release
