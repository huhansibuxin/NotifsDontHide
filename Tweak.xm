// NotifsDontHide — v1.0.28
// threadIdentifier→sectionIdentifier: 同 App 通知归一组
// maximumNumberOfVisibleNotifications→1: 第2条起折叠

#import <Foundation/Foundation.h>
#import <substrate.h>

static id (*orig_threadIdentifier)(id self, SEL _cmd);
static NSUInteger (*orig_maxVisible)(id self, SEL _cmd);

static id hook_threadIdentifier(id self, SEL _cmd) {
    return ((id (*)(id, SEL))objc_msgSend)(self, @selector(sectionIdentifier));
}

static NSUInteger hook_maxVisible(id self, SEL _cmd) {
    return 1;
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
        MSHookMessageEx(
            secClass,
            @selector(maximumNumberOfVisibleNotifications),
            (IMP)&hook_maxVisible,
            (IMP*)&orig_maxVisible
        );
    }

    CFPreferencesSetAppValue(CFSTR("enabled"), kCFBooleanTrue,
        CFSTR("com.b4db1r3.onenotificationlistffs"));
    CFPreferencesAppSynchronize(CFSTR("com.b4db1r3.onenotificationlistffs"));
}
