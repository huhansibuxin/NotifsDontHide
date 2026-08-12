// NotifsDontHide — force notifications to merge early (after the 2nd one)
//
// This tweak only controls the merge threshold. The bundled
// OneNotificationListFFS.dylib (won't-hide feature) is left untouched.
//
// iOS default behaviour: up to 4 notifications are shown individually, the
// 5th collapses into one grouped bar.
// This tweak: only kMaxVisible (1) is shown individually, so the 2nd
// notification already merges into the same grouped bar.
//
// Diagnostics: every hook writes to /var/jb/tmp/NotifsDontHide.log so you can
// confirm on-device which hooks actually fire (ssh in and `cat` the file).

#import <Foundation/Foundation.h>
#import <stdarg.h>
#import <substrate.h>
#import <objc/runtime.h>

#define NDH_LOG_PATH "/var/jb/tmp/NotifsDontHide.log"

// Number of notifications shown individually before the rest collapse into the
// single merged group bar. 1 => "2nd notification merges into the bar".
static const NSUInteger kMaxVisible = 1;

// Optional app scoping. nil / empty => apply to ALL apps.
// To scope to WeChat only, set: @[ @"com.tencent.xin" ]
static NSArray *ndh_targetBundles = nil;

static void ndh_log(NSString *fmt, ...) {
    // Debug logging is opt-in: create /var/jb/tmp/ndh_debug to enable.
    // Avoids hammering the filesystem on hot hooks during normal use.
    static int gChecked = 0;
    static BOOL gEnabled = NO;
    if (!gChecked) {
        gEnabled = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/tmp/ndh_debug"];
        gChecked = 1;
    }
    if (!gEnabled) return;

    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = @(NDH_LOG_PATH);
    if (![fm fileExistsAtPath:path]) {
        [@"" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForUpdatingAtPath:path];
    if (fh) {
        [fh seekToEndOfFile];
        NSString *line = [NSString stringWithFormat:@"[NotifsDontHide] %@\n", msg];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

// Only hook notifications whose owning app is in the target list (or all).
static BOOL ndh_shouldApply(id request) {
    if (ndh_targetBundles == nil || ndh_targetBundles.count == 0) return YES;
    if (![request respondsToSelector:@selector(sectionIdentifier)]) return NO;
    NSString *section = [request sectionIdentifier];
    return [ndh_targetBundles containsObject:section];
}

// Hook helper: only replace a method that actually exists on the class.
static void ndh_hook(Class cls, SEL sel, IMP imp, IMP *orig) {
    if (!cls) {
        ndh_log(@"WARN: class nil for %s, skip", sel_getName(sel));
        return;
    }
    if (!class_getInstanceMethod(cls, sel)) {
        ndh_log(@"WARN: %s does not implement %s, skip", class_getName(cls), sel_getName(sel));
        return;
    }
    MSHookMessageEx(cls, sel, imp, orig);
}

// ---- original + replacement function pointers ----
static id (*orig_threadIdentifier)(id, SEL);
static NSUInteger (*orig_maxVisibleSection)(id, SEL);
static NSUInteger (*orig_maxVisibleSettings)(id, SEL);
static NSInteger (*orig_groupingSetting)(id, SEL);

// Force every notification of an app to share one thread => one group bar.
static id hook_threadIdentifier(id self, SEL _cmd) {
    if (![self respondsToSelector:@selector(sectionIdentifier)]) {
        return orig_threadIdentifier(self, _cmd);
    }
    if (ndh_shouldApply(self)) {
        id sid = ((id (*)(id, SEL))objc_msgSend)(self, @selector(sectionIdentifier));
        ndh_log(@"threadIdentifier -> %@ (forced same-thread)", sid);
        return sid;
    }
    return orig_threadIdentifier(self, _cmd);
}

// Limit how many individual cards are shown before the rest collapse.
static NSUInteger hook_maxVisibleSection(id self, SEL _cmd) {
    ndh_log(@"maximumNumberOfVisibleNotifications(section) -> %lu", (unsigned long)kMaxVisible);
    return kMaxVisible;
}

static NSUInteger hook_maxVisibleSettings(id self, SEL _cmd) {
    ndh_log(@"maximumNumberOfVisibleNotifications(settings) -> %lu", (unsigned long)kMaxVisible);
    return kMaxVisible;
}

// 2 == "By App": every notification of the app goes into one group.
static NSInteger hook_groupingSetting(id self, SEL _cmd) {
    ndh_log(@"notificationGroupingSetting -> 2 (By App)");
    return 2;
}

%ctor {
    ndh_log(@"=== NotifsDontHide 1.0.32 loaded ===");

    ndh_hook(objc_getClass("NCNotificationRequest"),
             @selector(threadIdentifier),
             (IMP)&hook_threadIdentifier,
             (IMP*)&orig_threadIdentifier);

    ndh_hook(objc_getClass("NCNotificationListSection"),
             @selector(maximumNumberOfVisibleNotifications),
             (IMP)&hook_maxVisibleSection,
             (IMP*)&orig_maxVisibleSection);

    ndh_hook(objc_getClass("NCNotificationSectionSettings"),
             @selector(maximumNumberOfVisibleNotifications),
             (IMP)&hook_maxVisibleSettings,
             (IMP*)&orig_maxVisibleSettings);

    ndh_hook(objc_getClass("NCNotificationSectionSettings"),
             @selector(notificationGroupingSetting),
             (IMP)&hook_groupingSetting,
             (IMP*)&orig_groupingSetting);

    // Keep the bundled won't-hide dylib enabled (do not touch its logic).
    CFPreferencesSetAppValue(CFSTR("enabled"), kCFBooleanTrue,
        CFSTR("com.b4db1r3.onenotificationlistffs"));
    CFPreferencesAppSynchronize(CFSTR("com.b4db1r3.onenotificationlistffs"));

    ndh_log(@"=== NotifsDontHide setup done ===");
}
