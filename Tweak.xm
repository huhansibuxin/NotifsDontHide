// NotifsDontHide — force notifications to merge early (after the 2nd one)
//
// This tweak only controls the merge threshold. The bundled
// OneNotificationListFFS.dylib (won't-hide feature) is left untouched.
//
// iOS default behaviour: up to 4 notifications are shown individually, the
// 5th collapses into one grouped bar.
// This tweak: only kCollapseThreshold (1) is shown individually, so the 2nd
// notification already merges into the same grouped bar.
//
// Diagnostics: every hook writes to /var/jb/tmp/NotifsDontHide.log so you can
// confirm on-device which hooks actually fire (ssh in and `cat` the file).

#import <Foundation/Foundation.h>
#import <stdarg.h>
#import <string.h>
#import <stdlib.h>
#import <substrate.h>
#import <objc/runtime.h>

#define NDH_LOG_PATH "/var/jb/tmp/NotifsDontHide.log"

// Number of notifications shown individually before the rest collapse into the
// single merged group bar. 1 => "2nd notification merges into the bar".
static const NSUInteger kCollapseThreshold = 1;

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
    NSString *section = ((NSString *(*)(id, SEL))objc_msgSend)(request, @selector(sectionIdentifier));
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

// ---- introspection (only logs when debug flag is on) ----
static int nd_ci_strstr(const char *hay, const char *needle) {
    if (!hay || !needle) return 0;
    while (*hay) {
        const char *h = hay, *n = needle;
        while (*h && *n && (tolower((unsigned char)*h) == tolower((unsigned char)*n))) { h++; n++; }
        if (*n == 0) return 1;
        hay++;
    }
    return 0;
}

static void ndh_introspect(void) {
    ndh_log(@"=== introspect begin ===");
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) { ndh_log(@"no classes"); return; }
    Class *all = (Class *)malloc(sizeof(Class) * n);
    objc_getClassList(all, n);
    for (int i = 0; i < n; i++) {
        const char *name = class_getName(all[i]);
        if (name && strstr(name, "NCNotification")) {
            ndh_log(@"CLASS: %s", name);
            unsigned count = 0;
            Method *methods = class_copyMethodList(all[i], &count);
            for (unsigned j = 0; j < count; j++) {
                const char *m = sel_getName(method_getName(methods[j]));
                // Flag methods likely related to the visible-count threshold.
                if (nd_ci_strstr(m, "visible") || nd_ci_strstr(m, "maximum") ||
                    nd_ci_strstr(m, "group") || nd_ci_strstr(m, "limit") ||
                    nd_ci_strstr(m, "collaps") || nd_ci_strstr(m, "expan") ||
                    nd_ci_strstr(m, "count")) {
                    ndh_log(@"    >> %s", m);
                }
            }
            free(methods);
        }
    }
    free(all);
    ndh_log(@"=== introspect end ===");
}

// ---- original + replacement function pointers ----
static id (*orig_threadIdentifier)(id, SEL);
static NSUInteger (*orig_collapsingThreshold)(id, SEL);
static NSUInteger (*orig_dynamicGroupingThreshold)(id, SEL);

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

// iOS 16 real lever: how many requests accumulate in a collapsing queue before
// they merge into one collapsed "bar". Default is 4 (=> the 5th merges). Return
// kCollapseThreshold (1) so the 2nd notification already merges.
static NSUInteger hook_collapsingThreshold(id self, SEL _cmd) {
    ndh_log(@"collapsingThreshold -> %lu (force 2nd-merge)", (unsigned long)kCollapseThreshold);
    return kCollapseThreshold;
}

// iOS 16 backup lever: dynamic grouping threshold on the section list. Lower it
// so grouping kicks in immediately, alongside collapsingThreshold.
static NSUInteger hook_dynamicGroupingThreshold(id self, SEL _cmd) {
    ndh_log(@"dynamicGroupingThreshold -> %lu (force 2nd-merge)", (unsigned long)kCollapseThreshold);
    return kCollapseThreshold;
}

%ctor {
    ndh_log(@"=== NotifsDontHide 1.0.34 loaded ===");

    // (1) Force every app's notifications onto one thread => one group, so the
    // collapsing queue treats them as one collapsible set.
    ndh_hook(objc_getClass("NCNotificationRequest"),
             @selector(threadIdentifier),
             (IMP)&hook_threadIdentifier,
             (IMP*)&orig_threadIdentifier);

    // (2) iOS 16 real lever: collapse after kCollapseThreshold requests.
    ndh_hook(objc_getClass("NCNotificationCollapsingQueue"),
             @selector(collapsingThreshold),
             (IMP)&hook_collapsingThreshold,
             (IMP*)&orig_collapsingThreshold);

    // (3) iOS 16 backup lever: dynamic grouping threshold.
    ndh_hook(objc_getClass("NCNotificationStructuredSectionList"),
             @selector(dynamicGroupingThreshold),
             (IMP)&hook_dynamicGroupingThreshold,
             (IMP*)&orig_dynamicGroupingThreshold);

    // Runtime introspection: dump the real iOS 16 class/method names that
    // control the visible-count threshold, so we can hook them correctly.
    ndh_introspect();

    // Keep the bundled won't-hide dylib enabled (do not touch its logic).
    CFPreferencesSetAppValue(CFSTR("enabled"), kCFBooleanTrue,
        CFSTR("com.b4db1r3.onenotificationlistffs"));
    CFPreferencesAppSynchronize(CFSTR("com.b4db1r3.onenotificationlistffs"));

    ndh_log(@"=== NotifsDontHide setup done ===");
}
