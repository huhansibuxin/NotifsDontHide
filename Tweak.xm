// NotifsDontHide — v1.0.31
// threadIdentifier→sectionIdentifier + groupingSetting→2 + maxVisible→1

#import <Foundation/Foundation.h>
#import <substrate.h>

static id (*orig_threadIdentifier)(id self, SEL _cmd);
static NSUInteger (*orig_maxVisible)(id self, SEL _cmd);
static NSInteger (*orig_groupingSetting)(id self, SEL _cmd);

static id hook_threadIdentifier(id self, SEL _cmd) {
    return ((id (*)(id, SEL))objc_msgSend)(self, @selector(sectionIdentifier));
}

static NSUInteger hook_maxVisible(id self, SEL _cmd) { return 1; }

static NSInteger hook_groupingSetting(id self, SEL _cmd) { return 2; }

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
        MSHookMessageEx(settingsClass, @selector(notificationGroupingSetting),
            (IMP)&hook_groupingSetting, (IMP*)&orig_groupingSetting);
    }

    CFPreferencesSetAppValue(CFSTR("enabled"), kCFBooleanTrue,
        CFSTR("com.b4db1r3.onenotificationlistffs"));
    CFPreferencesAppSynchronize(CFSTR("com.b4db1r3.onenotificationlistffs"));
}
