// NotifsDontHide — v1.0.24
// threadIdentifier→sectionIdentifier: 同 App 通知归一组
// isGrouped hook: count≥2 时强制折叠视图

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>

static id (*orig_threadIdentifier)(id self, SEL _cmd);
static BOOL (*orig_isGrouped)(id self, SEL _cmd);

static id hook_threadIdentifier(id self, SEL _cmd) {
    return ((id (*)(id, SEL))objc_msgSend)(self, @selector(sectionIdentifier));
}

static BOOL hook_isGrouped(id self, SEL _cmd) {
    NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(self, @selector(count));
    if (count >= 2) return YES;
    return orig_isGrouped(self, _cmd);
}

%ctor {
    MSHookMessageEx(
        objc_getClass("NCNotificationRequest"),
        @selector(threadIdentifier),
        (IMP)&hook_threadIdentifier,
        (IMP*)&orig_threadIdentifier
    );

    MSHookMessageEx(
        objc_getClass("NCNotificationListView"),
        @selector(isGrouped),
        (IMP)&hook_isGrouped,
        (IMP*)&orig_isGrouped
    );

    CFPreferencesSetAppValue(CFSTR("enabled"), kCFBooleanTrue,
        CFSTR("com.b4db1r3.onenotificationlistffs"));
    CFPreferencesAppSynchronize(CFSTR("com.b4db1r3.onenotificationlistffs"));
}
