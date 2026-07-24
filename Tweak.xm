// NotifsDontHide — explicit MSHookMessageEx.
// OneNotificationListFFS.dylib (in layout) handles notification persistence.

#import <Foundation/Foundation.h>
#import <substrate.h>

static NSString *(*orig_threadIdentifier)(id self, SEL _cmd);
static NSInteger (*orig_notificationCount)(id self, SEL _cmd);

static NSString *hook_threadIdentifier(id self, SEL _cmd) {
    return ((NSString *(*)(id, SEL))objc_msgSend)(self, @selector(sectionIdentifier));
}

static NSInteger hook_notificationCount(id self, SEL _cmd) {
    NSInteger orig = orig_notificationCount(self, _cmd);
    return (orig > 2) ? 2 : orig;
}

%ctor {
    MSHookMessageEx(
        objc_getClass("NCNotificationRequest"),
        @selector(threadIdentifier),
        (IMP)&hook_threadIdentifier,
        (IMP*)&orig_threadIdentifier
    );

    MSHookMessageEx(
        objc_getClass("NCNotificationGroupList"),
        @selector(notificationCount),
        (IMP)&hook_notificationCount,
        (IMP*)&orig_notificationCount
    );

    CFPreferencesSetAppValue(CFSTR("enabled"), kCFBooleanTrue,
        CFSTR("com.b4db1r3.onenotificationlistffs"));
    CFPreferencesAppSynchronize(CFSTR("com.b4db1r3.onenotificationlistffs"));
}
