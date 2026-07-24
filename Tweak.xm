// NotifsDontHide — v1.0.26
// threadIdentifier→sectionIdentifier + isGrouped hook with nil/selector guards

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>

static id (*orig_threadIdentifier)(id self, SEL _cmd);
static BOOL (*orig_isGrouped)(id self, SEL _cmd);

static id hook_threadIdentifier(id self, SEL _cmd) {
    return ((id (*)(id, SEL))objc_msgSend)(self, @selector(sectionIdentifier));
}

static BOOL hook_isGrouped(id self, SEL _cmd) {
    SEL countSel = @selector(count);
    if ([self respondsToSelector:countSel]) {
        NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(self, countSel);
        if (count >= 2) return YES;
    }
    return orig_isGrouped(self, _cmd);
}

%ctor {
    MSHookMessageEx(
        objc_getClass("NCNotificationRequest"),
        @selector(threadIdentifier),
        (IMP)&hook_threadIdentifier,
        (IMP*)&orig_threadIdentifier
    );

    Class listViewClass = objc_getClass("NCNotificationListView");
    if (listViewClass) {
        MSHookMessageEx(
            listViewClass,
            @selector(isGrouped),
            (IMP)&hook_isGrouped,
            (IMP*)&orig_isGrouped
        );
    }

    CFPreferencesSetAppValue(CFSTR("enabled"), kCFBooleanTrue,
        CFSTR("com.b4db1r3.onenotificationlistffs"));
    CFPreferencesAppSynchronize(CFSTR("com.b4db1r3.onenotificationlistffs"));
}
