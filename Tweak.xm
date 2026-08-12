// NotifsDontHide — two features, one dylib, no bundled helpers.
//
// Feature 1 — merge early (after the 2nd notification) for ALL apps:
//   iOS default shows up to 4 individually, the 5th collapses. We collapse
//   after the 1st, so the 2nd notification already merges into one bar.
//
// Feature 2 — never hide in Notification Center:
//   iOS migrates incoming notifications into a "history" section and hides
//   that section (and hides grouped notifications on device re-auth). We
//   block the migration and the hide calls so everything stays visible.
//
// This single tweak replaces the old split design (NotifsDontHide + the
// bundled OneNotificationListFFS.dylib). The "never hide" logic was
// reverse-engineered from OneNotificationListFFS and rewritten here against
// the real iOS 16 method names (verified on-device).

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <stdarg.h>

// Notifications shown individually before the rest collapse into the single
// merged group bar. 1 => "2nd notification merges into the bar".
static const NSUInteger kCollapseThreshold = 1;

// Hook a method only if the class and selector actually exist (silent skip, so
// a future iOS change can never crash SpringBoard from this tweak).
static void ndh_try_hook(const char *clsName, SEL sel, IMP imp, IMP *orig) {
    Class cls = objc_getClass(clsName);
    if (!cls || !class_getInstanceMethod(cls, sel)) return;
    MSHookMessageEx(cls, sel, imp, orig);
}

// --- Feature 1: merge after the 2nd ---

// Force every notification of an app onto one thread => one group, so the
// collapsing queue treats them as one collapsible set.
static id (*orig_threadIdentifier)(id, SEL);
static id hook_threadIdentifier(id self, SEL _cmd) {
    if ([self respondsToSelector:@selector(sectionIdentifier)]) {
        return ((id (*)(id, SEL))objc_msgSend)(self, @selector(sectionIdentifier));
    }
    return orig_threadIdentifier(self, _cmd);
}

// iOS 16: how many requests accumulate in a collapsing queue before they merge
// into one collapsed "bar". Default is 4 (=> the 5th merges). Return 1 so the
// 2nd notification already merges.
static NSUInteger (*orig_collapsingThreshold)(id, SEL);
static NSUInteger hook_collapsingThreshold(id self, SEL _cmd) {
    return kCollapseThreshold;
}

// iOS 16 backup lever: dynamic grouping threshold on the section list.
static NSUInteger (*orig_dynamicGroupingThreshold)(id, SEL);
static NSUInteger hook_dynamicGroupingThreshold(id self, SEL _cmd) {
    return kCollapseThreshold;
}

// Debug flag (loaded once in %ctor): if /var/jb/tmp/ndh_debug exists, the
// migration/hide blockers also log which method fired, so we can see any
// migration path we missed. Off in production (zero overhead).
static BOOL g_ndh_debug = NO;
static void ndh_debug_log(NSString *fmt, ...);
// Shared swallow IMP for the migration/hide entry points: variadic so it never
// assumes the (private) argument layout, and void-returning because these
// action methods return void (verified: 1.0.37's void override did not crash).
static void hook_blockMigration(id self, SEL _cmd, ...);

%ctor {
    ndh_try_hook("NCNotificationRequest", @selector(threadIdentifier),
                 (IMP)&hook_threadIdentifier, (IMP*)&orig_threadIdentifier);
    ndh_try_hook("NCNotificationCollapsingQueue", @selector(collapsingThreshold),
                 (IMP)&hook_collapsingThreshold, (IMP*)&orig_collapsingThreshold);
    ndh_try_hook("NCNotificationStructuredSectionList", @selector(dynamicGroupingThreshold),
                 (IMP)&hook_dynamicGroupingThreshold, (IMP*)&orig_dynamicGroupingThreshold);
    // Feature 2 (never hide): debug flag + block BOTH migration entry points.
    g_ndh_debug = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/tmp/ndh_debug"];
    // Primary lock/unlock + NC-dismiss migration path (0-arg).
    ndh_try_hook("NCNotificationMasterList",
                 @selector(migrateNotificationsFromIncomingSectionToHistorySection),
                 (IMP)&hook_blockMigration, NULL);
    // The "…AndHideHistorySection:" variant (1-arg) — also blocked.
    ndh_try_hook("NCNotificationMasterList",
                 @selector(migrateNotificationsFromIncomingSectionToHistorySectionAndHideHistorySection:),
                 (IMP)&hook_blockMigration, NULL);
}

// --- Feature 2: never hide (rewritten from OneNotificationListFFS, iOS 16 names) ---

// Debug logger (gated by g_ndh_debug). Injected dylib NSLog is NOT captured by
// oslog on this setup, so we append to a file instead.
static void ndh_debug_log(NSString *fmt, ...) {
    if (!g_ndh_debug) return;
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *path = @"/var/jb/tmp/NotifsDontHide.log";
    FILE *f = fopen([path UTF8String], "a");
    if (f) { fprintf(f, "%s\n", [msg UTF8String]); fclose(f); }
}

// The primary path Apple uses to move incoming notifications into the hidden
// "history" section (and hide that section) on lock/unlock and NC dismiss is
// -[NCNotificationMasterList migrateNotificationsFromIncomingSectionToHistorySection]
// (0-arg) and its "…AndHideHistorySection:" (1-arg) variant. Both are void
// action methods; we swallow them so notifications never leave the visible
// incoming section.
//
// NOTE: we deliberately do NOT hook the inner 9-arg
// _migrateNotificationsFromList:toList:passingTest:… method. That private
// method returns an object on iOS 16; declaring it as a `void` override left a
// garbage return value that the caller retained via objc_storeStrong and
// crashed SpringBoard (EXC_BAD_ACCESS -> Safe Mode, see 1.0.36). Using a
// variadic IMP here also avoids ever assuming the private argument layout.
static void hook_blockMigration(id self, SEL _cmd, ...) {
    ndh_debug_log(@"[NDH] blocked migration/hide: %@", NSStringFromSelector(_cmd));
    // intentionally empty: never migrate to history, never hide.
}

%hook NCNotificationMasterList
// Tell the system there is always visible content, so it never collapses/hides
// the list.
- (BOOL)hasVisibleContentToReveal { return YES; }
%end

%hook NCNotificationStructuredSectionList
// Block the "hide groups" calls that fire when the device re-authenticates
// (lock/unlock) or in other situations, so grouped notifications stay shown.
- (void)_hideNotificationGroupsOnDeviceReauthentication {
    // intentionally empty.
}
- (void)_hideNotificationGroupsPassingTest:(id)arg1 {
    // intentionally empty.
}
- (BOOL)hasVisibleContentToReveal { return YES; }
%end
