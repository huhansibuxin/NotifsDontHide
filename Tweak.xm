#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void (*orig_threadIdentifier)(id, SEL);
static id hooked_threadIdentifier(id self, SEL _cmd) {
    id sectionId = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("sectionIdentifier"));
    return sectionId;
}

static void (*orig_insertNotificationRequest)(id, SEL, id);
static void hooked_insertNotificationRequest(id self, SEL _cmd, id request) {
    orig_insertNotificationRequest(self, _cmd, request);

    // 绗?2 鏉￠€氱煡鍒拌揪鏃剁珛鍗虫姌鍙犺缁勶紙浠呰Е鍙戜竴娆★紝閬垮厤 flip-flop锛?    NSUInteger notifCount = ((NSUInteger (*)(id, SEL))objc_msgSend)(self, sel_registerName("notificationCount"));
    if (notifCount == 2) {
        ((void (*)(id, SEL))objc_msgSend)(self, sel_registerName("toggleGroupedState"));
    }
}

__attribute__((constructor))
static void init(void) {
    Class ncNotificationRequest = NSClassFromString(@"NCNotificationRequest");
    if (ncNotificationRequest) {
        Method m = class_getInstanceMethod(ncNotificationRequest, sel_registerName("threadIdentifier"));
        if (m) {
            orig_threadIdentifier = (void (*)(id, SEL))method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_threadIdentifier);
        }
    }

    Class ncNotificationGroupList = NSClassFromString(@"NCNotificationGroupList");
    if (ncNotificationGroupList) {
        Method m = class_getInstanceMethod(ncNotificationGroupList, sel_registerName("insertNotificationRequest:"));
        if (m) {
            orig_insertNotificationRequest = (void (*)(id, SEL, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_insertNotificationRequest);
        }
    }
}
