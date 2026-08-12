// NotifsDontHide — two features, one dylib, no bundled helpers.
//
// Feature 1 — merge early (after the 2nd notification) for ALL apps:
//   iOS default shows up to 4 individually, the 5th collapses. We collapse
//   after the 1st, so the 2nd notification already merges into one bar.
//
// Feature 2 — never hide in Notification Center:
//   On iOS 16, when you unlock (or notifications age out) SpringBoard migrates
//   incoming lock-screen notifications into a "history" section and then
//   COLLAPSES that section (hidden by default — you must tap "Show History").
//
//   We do NOT block the migration. Blocking it (1.0.41) DESTROYED the
//   notifications entirely: on unlock the lock-screen list is torn down, and
//   the only thing that keeps them alive is the migration into history (the
//   9-arg NCNotificationMasterList mover is the real executor). With migration
//   blocked, the notifications were dropped — gone from both lock screen and
//   history.
//
//   So: let the migration run (notifications survive unlock), then FORCE the
//   history section to stay revealed via NCNotificationListRevealCoordinator
//   (forceRevealed / sectionRevealed) so migrated notifications remain visible
//   instead of collapsing into the hidden history.
//
//   The older (1.0.39/1.0.40) "block the visual-collapse toggle" approach was
//   also wrong: those _toggleVisibility… calls are what REVEAL the section, so
//   swallowing them froze it in the hidden state. We no longer touch them.
//
// Reverse-engineered from on-device Frida introspection (iOS 16, verified).

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import <string.h>
#import <dispatch/dispatch.h>

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
// instrumentation below enumerates notification classes and safely swallows
// migrate/hide/History void methods, logging when they fire, so we can see any
// migration path we missed. Off in production (zero overhead).
static BOOL g_ndh_debug = NO;
static void ndh_debug_log(NSString *fmt, ...);
static void ndh_trace_swallow(id self, SEL _cmd, ...);
static BOOL ndh_enc_safe_to_swallow(const char *enc);
static void ndh_introspect_and_instrument(void);

// Feature 2 (never hide): force the history (hidden) list revealed via
// NCNotificationListRevealCoordinator. Logos %orig with a BOOL scalar argument
// fails ("Invalid argument structure in %orig") on this method, so we hook the
// setters with typed IMPs and call the original with a content-aware value.
//
// Reveal ONLY when the history actually has content. Revealing an empty history
// is what makes iOS paint the "No Older Notifications" (没有更早的通知) hint,
// and that hint is driven by NCNotificationListInteractiveTransitionCoordinator
// _isHiddenListRevealed — so we must never force-reveal an empty section.
//
// Timing race: on the FIRST open after a logout / cold start, the history is not
// hydrated yet and _revealSectionHasContent reads NO, so iOS would leave it
// collapsed and notifications would not appear until the next manual open. We
// therefore collapse now but SCHEDULE a short retry that re-forces the reveal
// once content has arrived, so notifications show on the very first open.
static BOOL ndh_revealCoordinatorHasContent(id self) {
    if (![self respondsToSelector:@selector(_revealSectionHasContent)]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(self, @selector(_revealSectionHasContent));
}

// Re-force reveal shortly after a setter was collapsed because content was not
// ready yet. Strong-captures self so the coordinator is guaranteed alive for
// the (<=500ms) retry window; the retry only acts when content is now present,
// so it is idempotent and cannot spin.
static void ndh_scheduleRevealRetry(id self, SEL _cmd,
                                    void (*orig)(id, SEL, BOOL)) {
    if (!orig) return;
    id me = self; // strong capture: keep coordinator alive for the retry window
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (ndh_revealCoordinatorHasContent(me)) orig(me, _cmd, YES);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (ndh_revealCoordinatorHasContent(me)) orig(me, _cmd, YES);
    });
}

static void (*orig_setForceRevealed)(id, SEL, BOOL);
static void hook_setForceRevealed(id self, SEL _cmd, BOOL revealed) {
    if (!orig_setForceRevealed) return;
    BOOL content = ndh_revealCoordinatorHasContent(self);
    orig_setForceRevealed(self, _cmd, content ? YES : NO);
    if (!content) ndh_scheduleRevealRetry(self, _cmd, orig_setForceRevealed);
}
static void (*orig_setSectionRevealed)(id, SEL, BOOL);
static void hook_setSectionRevealed(id self, SEL _cmd, BOOL revealed) {
    if (!orig_setSectionRevealed) return;
    BOOL content = ndh_revealCoordinatorHasContent(self);
    orig_setSectionRevealed(self, _cmd, content ? YES : NO);
    if (!content) ndh_scheduleRevealRetry(self, _cmd, orig_setSectionRevealed);
}

%ctor {
    ndh_try_hook("NCNotificationRequest", @selector(threadIdentifier),
                 (IMP)&hook_threadIdentifier, (IMP*)&orig_threadIdentifier);
    ndh_try_hook("NCNotificationCollapsingQueue", @selector(collapsingThreshold),
                 (IMP)&hook_collapsingThreshold, (IMP*)&orig_collapsingThreshold);
    ndh_try_hook("NCNotificationStructuredSectionList", @selector(dynamicGroupingThreshold),
                 (IMP)&hook_dynamicGroupingThreshold, (IMP*)&orig_dynamicGroupingThreshold);
    // Feature 2 (never hide): force the history (hidden) list revealed.
    ndh_try_hook("NCNotificationListRevealCoordinator", @selector(setForceRevealed:),
                 (IMP)&hook_setForceRevealed, (IMP*)&orig_setForceRevealed);
    ndh_try_hook("NCNotificationListRevealCoordinator", @selector(setSectionRevealed:),
                 (IMP)&hook_setSectionRevealed, (IMP*)&orig_setSectionRevealed);
    // Feature 2 (never hide): debug flag only. No migration/hide blocks — the
    // migration is required for notifications to survive unlock; we keep them
    // visible by forcing the history section revealed (see the
    // NCNotificationListRevealCoordinator hook below).
    g_ndh_debug = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/tmp/ndh_debug"];
    if (g_ndh_debug) ndh_introspect_and_instrument();
}

// --- Feature 2: never hide (iOS 16 names, verified on-device) ---

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

// Log a fired method call (used by the trace swallow below).
static void ndh_trace_swallow(id self, SEL _cmd, ...) {
    ndh_debug_log(@"[NDH-TRACE] fired %@ on %@", NSStringFromSelector(_cmd), NSStringFromClass([self class]));
}

// A method is safe to swallow with a variadic void IMP only if it returns void
// AND has no float/double/struct/union/array arguments (those shift register
// layout and would crash). Returning an object + void override = EXC_BAD_ACCESS
// (the 1.0.36 bug), so we reject non-void returns outright.
static BOOL ndh_enc_safe_to_swallow(const char *enc) {
    if (!enc || enc[0] != 'v') return NO;
    for (const char *p = enc; *p; p++) {
        if (*p == 'f' || *p == 'd' || *p == '{' || *p == '(' || *p == '[') return NO;
    }
    return YES;
}

static void ndh_introspect_and_instrument(void) {
    ndh_debug_log(@"[NDH-INTROSPECT] === begin ===");
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) { ndh_debug_log(@"[NDH-INTROSPECT] no classes"); return; }
    Class *classes = (Class *)malloc((size_t)count * sizeof(Class));
    if (!classes) return;
    objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        Class c = classes[i];
        const char *name = class_getName(c);
        if (!strstr(name, "Notification")) continue;
        if (!(strstr(name, "List") || strstr(name, "Section") || strstr(name, "Master") ||
              strstr(name, "Reveal") || strstr(name, "Coordinator") || strstr(name, "Group"))) continue;
        unsigned int mc = 0;
        Method *methods = class_copyMethodList(c, &mc);
        if (!methods) continue;
        for (unsigned j = 0; j < mc; j++) {
            SEL sel = method_getName(methods[j]);
            const char *selname = sel_getName(sel);
            NSString *s = [NSString stringWithUTF8String:selname];
            if (![s containsString:@"migrate"] && ![s containsString:@"History"] &&
                ![s containsString:@"hide"] && ![s containsString:@"reveal"] && ![s containsString:@"Reveal"] &&
                ![s containsString:@"visible"] && ![s containsString:@"Visible"] &&
                ![s containsString:@"Missed"] && ![s containsString:@"collapse"] && ![s containsString:@"Collapse"] &&
                ![s containsString:@"expand"] && ![s containsString:@"show"] && ![s containsString:@"Show"] &&
                ![s containsString:@"Group"]) continue;
            const char *enc = method_getTypeEncoding(methods[j]);
            ndh_debug_log(@"[NDH-INTROSPECT] %s :: %s  enc=%s%s", name, selname, enc ? enc : "?",
                          ndh_enc_safe_to_swallow(enc) ? "  [SAFE-SWALLOW]" : "");
            // Only SAFELY swallow the actual migrate/hide/History actions. Never
            // swallow show/collapse/expand/visible/reveal/Group methods — those
            // maintain display and (for collapse) the merge feature itself.
            BOOL isMigrateHide = ([s containsString:@"migrate"] || [s containsString:@"hide"] ||
                                  [s containsString:@"History"]);
            if (isMigrateHide && ndh_enc_safe_to_swallow(enc)) {
                MSHookMessageEx(c, sel, (IMP)&ndh_trace_swallow, NULL);
            }
        }
        free(methods);
    }
    free(classes);
    ndh_debug_log(@"[NDH-INTROSPECT] === end ===");
}

%hook NCNotificationMasterList
// Tell the system there is always visible content, so it never collapses/hides
// the list, and permit the history to be revealed (the reveal is then forced
// ON by the NCNotificationListRevealCoordinator hook below).
- (BOOL)hasVisibleContentToReveal { return YES; }
- (BOOL)shouldAllowNotificationHistoryReveal { return YES; }
- (BOOL)notificationListRevealCoordinatorShouldAllowReveal:(id)coordinator { return YES; }
- (BOOL)notificationListRevealCoordinatorShouldAllowRevealTransition:(id)coordinator { return YES; }
%end

%hook NCNotificationListRevealCoordinator
// Force the history section to be revealed ONLY when it actually has content
// (see ndh_revealCoordinatorHasContent). Revealing an empty history is exactly
// what paints the "No Older Notifications" (没有更早的通知) hint, and the hint
// is ultimately gated by NCNotificationListInteractiveTransitionCoordinator
// _isHiddenListRevealed (handled separately below). The two shouldAllow* gates
// trivially permit the reveal; the content-aware getters/setters above keep the
// history expanded whenever notifications have migrated into it (lock->unlock)
// without ever showing an empty hint.
- (BOOL)isForceRevealed { return ndh_revealCoordinatorHasContent(self); }
- (BOOL)isSectionRevealed { return ndh_revealCoordinatorHasContent(self); }
- (BOOL)_shouldAllowNotificationListReveal { return YES; }
- (BOOL)_shouldAllowNotificationListRevealTransition { return YES; }
%end

%hook NCNotificationListInteractiveTransitionCoordinator
// THIS is the switch that paints the "No Older Notifications" (没有更早的通知)
// empty hint: iOS shows that hint whenever the hidden (history) list is reported
// revealed but actually empty. So we must NOT force YES unconditionally (that is
// what made the hint permanent in 1.0.44/1.0.45). Instead, reveal only when the
// reveal list view actually has content — then notifications are shown AND the
// empty hint never appears. When history is empty we return the original value
// (NO), which also keeps the hint suppressed.
- (BOOL)_isHiddenListRevealed {
    id revealListView = nil;
    if ([self respondsToSelector:@selector(revealListView)]) {
        revealListView = ((id (*)(id, SEL))objc_msgSend)(self, @selector(revealListView));
    }
    if (revealListView && [revealListView respondsToSelector:@selector(count)]) {
        NSUInteger c = ((NSUInteger (*)(id, SEL))objc_msgSend)(revealListView, @selector(count));
        if (c > 0) return YES;
    }
    return NO;
}
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
