// Native in-page find bar for the active CEF browser.

#ifndef BRO_FIND_H_
#define BRO_FIND_H_

#import <Cocoa/Cocoa.h>

void BroShowFindBar(void);
void BroHideFindBar(void);
void BroFindNext(void);
void BroFindPrevious(void);
BOOL BroFindBarVisible(void);
BOOL BroFindHasQuery(void);
void BroTeardownFindBar(void);

// Called by BroHandler's CefFindHandler callback on the CEF UI/main thread.
void BroUpdateFindResult(int browser_id,
                         int identifier,
                         int count,
                         int active_ordinal);

#endif  // BRO_FIND_H_
