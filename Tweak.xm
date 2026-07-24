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

    NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(self, sel_registerName("notificationCount"));
    BOOL isGrouped = ((BOOL (*)(id, SEL))objc_msgSend)(self, sel_registerName("isGrouped"));
    if (count >= 2 && !isGrouped) {
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
