//
//  NotificationsManager.h
//  Signal
//
//  Created by Frederic Jacobs on 22/12/15.
//  Copyright © 2015 Open Whisper Systems. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <SignalServiceKit/NotificationsProtocol.h>

NS_ASSUME_NONNULL_BEGIN

@class TSCall;
@class OWSContactsManager;

@interface NotificationsManager : NSObject <NotificationsProtocol>

- (instancetype)initWithContactsManager:(OWSContactsManager *)contactsManager NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (void)notifyUserForCall:(TSCall *)call inThread:(TSThread *)thread;

@end

NS_ASSUME_NONNULL_END
