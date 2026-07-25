// NotifsDontHide — v1.0.30
// threadIdentifier→sectionIdentifier + shouldStackNotifications→YES

#import <Foundation/Foundation.h>
#import <substrate.h>

static id (*orig_threadIdentifier)(id self, SEL _cmd);
static BOOL (*orig_shouldStack)(id self, SEL _cmd);

static id hook_threadIdentifier(id self, SEL _cmd) {
    return ((id (*)(id, SEL))objc_msgSend)(self, @selector(sectionIdentifier));
}

static BOOL hook_shouldStack(id self, SEL _cmd) {
    return YES;
}

%ctor {
    MSHookMessageEx(
        objc_getClass("NCNotificationRequest"),
        @selector(threadIdentifier),
        (IMP)&hook_threadIdentifier,
        (IMP*)&orig_threadIdentifier
    );

    Class secClass = objc_getClass("NCNotificationListSection");
    if (secClass) {
        MSHookMessageEx(secClass, @selector(shouldStackNotifications),
            (IMP)&hook_shouldStack, (IMP*)&orig_shouldStack);
    }

    CFPreferencesSetAppValue(CFSTR("enabled"), kCFBooleanTrue,
        CFSTR("com.b4db1r3.onenotificationlistffs"));
    CFPreferencesAppSynchronize(CFSTR("com.b4db1r3.onenotificationlistffs"));
}
