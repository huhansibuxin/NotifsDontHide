#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void (*orig_threadIdentifier)(id, SEL);
static id hooked_threadIdentifier(id self, SEL _cmd) {
    // 璁╁悓 App 鐨勯€氱煡褰掑埌鍚屼竴涓?section锛岃Е鍙戞姌鍙犲垎缁?    id sectionIdentifier = ((id (*)(id, SEL))objc_msgSend)(self, @selector(sectionIdentifier));
    return sectionIdentifier;
}

static void (*orig_insertNotificationRequest)(id, SEL, id);
static void hooked_insertNotificationRequest(id self, SEL _cmd, id request) {
    orig_insertNotificationRequest(self, _cmd, request);

    // 缁勫唴閫氱煡 >= 2 鏉′笖杩樻病鎶樺彔鏃讹紝寮哄埗鎶樺彔
    NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(self, @selector(notificationCount));
    BOOL isGrouped = ((BOOL (*)(id, SEL))objc_msgSend)(self, @selector(isGrouped));
    if (count >= 2 && !isGrouped) {
        ((void (*)(id, SEL))objc_msgSend)(self, @selector(toggleGroupedState));
    }
}

__attribute__((constructor))
static void init(void) {
    // Hook 1: threadIdentifier 鈫?sectionIdentifier锛堝悓 App 褰掍竴缁勶級
    Class ncNotificationRequest = NSClassFromString(@"NCNotificationRequest");
    if (ncNotificationRequest) {
        Method m = class_getInstanceMethod(ncNotificationRequest, @selector(threadIdentifier));
        if (m) {
            orig_threadIdentifier = (void (*)(id, SEL))method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_threadIdentifier);
        }
    }

    // Hook 2: insertNotificationRequest 鈫?2 鏉″氨鎶樺彔
    Class ncNotificationGroupList = NSClassFromString(@"NCNotificationGroupList");
    if (ncNotificationGroupList) {
        Method m = class_getInstanceMethod(ncNotificationGroupList, @selector(insertNotificationRequest:));
        if (m) {
            orig_insertNotificationRequest = (void (*)(id, SEL, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_insertNotificationRequest);
        }
    }
}
