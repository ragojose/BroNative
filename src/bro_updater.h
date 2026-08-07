#ifndef BRO_UPDATER_H_
#define BRO_UPDATER_H_

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>

// Starts Sparkle's background update checks. Call once, after the menu exists.
// No-op if the app was built without a usable Sparkle configuration, so a
// developer build with a placeholder public key still launches normally.
void BroStartUpdater(void);

// Target/action for a "Check for Updates…" menu item. Returns nil target when
// the updater never started, which leaves the item disabled rather than
// crashing on a dead selector.
id BroUpdaterMenuTarget(void);
SEL BroUpdaterMenuAction(void);

#endif  // __OBJC__

#endif  // BRO_UPDATER_H_
