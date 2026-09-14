# hyperos-accessibility-fix
Stop HyperOS from randomly disabling accessibility services

## What's happening
On Android, when an accessibility app is force-stopped via `ActivityManager`, the [accessibility permission of the app is stripped](https://cs.android.com/android/platform/superproject/+/android-16.0.0_r4:frameworks/base/services/accessibility/java/com/android/server/accessibility/AccessibilityManagerService.java;drc=7f9ce6b127e5d17d7a2ccef1ccc21db212f60084;l=1050).

```java
boolean onPackagesForceStoppedLocked(String[] packages, AccessibilityUserState userState) {
    final Set<String> packageSet = Set.of(packages);
    
    final ArrayList<ComponentName> continuousServices = userState.mInstalledServices.stream()
            .filter(s -> (s.flags & FLAG_REQUEST_ACCESSIBILITY_BUTTON) == FLAG_REQUEST_ACCESSIBILITY_BUTTON)
            .map(AccessibilityServiceInfo::getComponentName)
            .filter(name -> packageSet.contains(name.getPackageName()))
            .collect(Collectors.toCollection(ArrayList::new));

    final boolean enabledServicesChanged = userState.mEnabledServices.removeIf(comp -> {
        if (packageSet.contains(comp.getPackageName())) {
            userState.getBindingServicesLocked().remove(comp);
            userState.getCrashedServicesLocked().remove(comp);
            return true;
        }
        return false;
    });

    if (enabledServicesChanged) {
        persistComponentNamesToSettingLocked(
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
            userState.mEnabledServices, userState.mUserId);
    }
}
    ...
```

And HyperOS is hardcoded to trigger a force-stop (not a kill) on 
certain events like when the user is entering Ultra Battery Saver (`LockScreenClean`),
and others:

```log
<ultra battery saver was enabled>
I ActivityManager: Force stopping com.urbandroid.lux appid=10415 user=0: LockScreenClean
D ActivityManager: Force removing proc 8855:com.urbandroid.lux:background/u0a415 (com.urbandroid.lux:background/10415)
```

## How it works
This module installs a background script that monitors the `logcat` stream for accessibility update events 
with minimal system overhead.

On boot, it checks what accessibility services are enabled, and writes them to `a11y_watchlist.txt`. It also listens for signs of manual 
configuration changes (done by user in settings) and updates the watchlist automatically.
 
When an accessibility update event is detected, the background script first checks if the device is in the Settings app (as mentioned above).
If not, the background script performs a verification of enabled accessibility services against the local `a11y_watchlist.txt`.
And if the list doesn't match up, the changes are reverted instantly.

This background script also runs at `OOM` score `-800` to prevent `LMKD` from killing it in the background. And if it still gets killed under memory pressure,
another (monitor) script (that runs at `-900`) is running in background to restart it (provided it didn't get killed aswell lol)

## Why use background scripts, and not zygisk/xposed?
On my device, these two frameworks cause a range of problems for some reason, so i decided to follow this approach instead.

It's also more minimal this way, having no requirements at all.

## Features & Enhancements
- **Zero-Crash Logcat Monitoring**: Native support for Toybox and GNU `grep` without reliance on `--line-buffered`.
- **Intelligent Focus Detection**: Sub-20ms foreground check using `dumpsys window displays`, fully compatible with modern Android 14+ Settings SPA and HyperOS without spawning ART VMs.
- **Smart Watchlist Sync**: Allows user to freely turn off or on accessibility services in Settings without automatic re-enabling locks.
- **Auto Package Pruning**: Uninstalled apps are automatically cleaned from watchlist to prevent zombie restoration.
- **Custom Exclusions**: Place custom services to ignore in `/data/adb/modules/hyperos-accessibility-fix/a11y_exclude.txt`.
- **Action Button Diagnostic**: Click "Action" in KernelSU/Magisk to view real-time daemon PIDs, OOM adj, active vs watchlist services, and logs.

## Note
- When Ultra Battery Saver is turned on, the accessibility services will still keep running in the background
- Force stopping an app via App Manager will not (permanently) remove its accessibility permission anymore.

## Installation:
* [Download the module archive here](https://github.com/chkndrp/hyperos-accessibility-fix/releases/latest/download/hyperos-accessibility-fix.zip)
* Flash it in magisk app, or using command line

## Requirements
- HyperOS 1.0+ (or any Android 13+ / AOSP system)
- KernelSU 1.0.2+ or APatch or Magisk 28.0+

