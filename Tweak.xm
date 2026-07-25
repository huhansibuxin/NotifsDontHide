// NotifsDontHide — v1.0.29
// threadIdentifier→sectionIdentifier + double maxVisible hook

#import <Foundation/Foundation.h>
#import <substrate.h>

static id (*orig_threadIdentifier)(id self, SEL _cmd);
static NSUInteger (*orig_maxVisible)(id self, SEL _cmd);
static NSUInteger (*orig_maxVisibleSettings)(id self, SEL _cmd);

static id hook_threadIdentifier(id self, SEL _cmd) {
    return ((id (*)(id, SEL))objc_msgSend)(self, @selector(sectionIdentifier));
}

static NSUInteger hook_maxVisible(id self, SEL _cmd) { return 1; }
static NSUInteger hook_maxVisibleSettings(id self, SEL _cmd) { return 1; }

%ctor {
    MSHookMessageEx(
        objc_getClass("NCNotificationRequest"),
        @selector(threadIdentifier),
        (IMP)&hook_threadIdentifier,
        (IMP*)&orig_threadIdentifier
    );

    Class secClass = objc_getClass("NCNotificationListSection");
    if (secClass) {
        MSHookMessageEx(secClass, @selector(maximumNumberOfVisibleNotifications),
            (IMP)&hook_maxVisible, (IMP*)&orig_maxVisible);
    }

    Class settingsClass = objc_getClass("NCNotificationSectionSettings");
    if (settingsClass) {
        MSHookMessageEx(settingsClass, @selector(maximumNumberOfVisibleNotifications),
            (IMP)&hook_maxVisibleSettings, (IMP*)&orig_maxVisibleSettings);
    }

    CFPreferencesSetAppValue(CFSTR("enabled"), kCFBooleanTrue,
        CFSTR("com.b4db1r3.onenotificationlistffs"));
    CFPreferencesAppSynchronize(CFSTR("com.b4db1r3.onenotificationlistffs"));
}
