// NotifsDontHide - loader shim
// The actual notification-blocking logic lives in OneNotificationListFFS.dylib
// (shipped alongside this tweak in the layout)

%ctor {
    // OneNotificationListFFS.dylib is loaded by ElleKit via MobileSubstrate filter
    // No additional setup needed here.
}
