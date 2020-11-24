//
//  LPLocalNotificationsManager.m
//  Leanplum-iOS-Location
//
//  Created by Dejan Krstevski on 12.05.20.
//  Copyright © 2020 Leanplum. All rights reserved.
//

#import "LPLocalNotificationsManager.h"
#import "LeanplumInternal.h"
#import "LPNotificationsConstants.h"
#import "LPNotificationsManager.h"
#import <UserNotifications/UNUserNotificationCenter.h>

@implementation LPLocalNotificationsManager

+ (LPLocalNotificationsManager *)sharedManager
{
    static LPLocalNotificationsManager *_sharedManager = nil;
    static dispatch_once_t localNotificationsManagerToken;
    dispatch_once(&localNotificationsManagerToken, ^{
        _sharedManager = [[self alloc] init];
    });
    return _sharedManager;
}

- (instancetype)init
{
    if(self = [super init])
    {
        _handler = [[LPLocalNotificationsHandler alloc] init];
    }
    return self;
}

- (void)listenForLocalNotifications
{
    [Leanplum onAction:LP_PUSH_NOTIFICATION_ACTION invoke:^BOOL(LPActionContext *context) {
        LP_END_USER_CODE
        UIApplication *app = [UIApplication sharedApplication];

        BOOL contentAvailable = [context boolNamed:@"iOS options.Preload content"];
        NSString *message = [context stringNamed:@"Message"];

        if (![self shouldSendNotificationForMessage:message contentAvailable:contentAvailable])
        {
            return NO;
        }

        NSString *messageId = context.messageId;

        NSDictionary *messageConfig = [LPVarCache sharedCache].messageDiffs[messageId];
        
        NSNumber *countdown = messageConfig[@"countdown"];
        if (context.isPreview) {
            countdown = @(5.0);
        }
        if (![countdown.class isSubclassOfClass:NSNumber.class]) {
            LPLog(LPDebug, @"Invalid notification countdown: %@", countdown);
            return NO;
        }
        int countdownSeconds = [countdown intValue];
        NSDate *eta = [[NSDate date] dateByAddingTimeInterval:countdownSeconds];

        if ([self shouldDiscard:eta context:context])
        {
            return NO;
        }
        
        NSDictionary *userInfo = [context dictionaryNamed:@"Advanced options.Data"];
        NSString *openAction = [context stringNamed:LP_VALUE_DEFAULT_PUSH_ACTION];
        BOOL muteInsideApp = [context boolNamed:@"Advanced options.Mute inside app"];
        NSString *sound = [context stringNamed:@"iOS options.Sound"];
        NSString *badge = [context stringNamed:@"iOS options.Badge"];
        NSString *category = [context stringNamed:@"iOS options.Category"];

        // Specify custom data for the notification
        NSMutableDictionary *mutableInfo;
        if (userInfo) {
            mutableInfo = [userInfo mutableCopy];
        } else {
            mutableInfo = [NSMutableDictionary dictionary];
        }
        
        // Adding body message manually.
        mutableInfo[@"aps"] = @{@"alert":@{@"body": message ?: @""} };

        // Specify open action
        if (openAction) {
            if (muteInsideApp) {
                mutableInfo[LP_KEY_PUSH_MUTE_IN_APP] = messageId;
            } else {
                mutableInfo[LP_KEY_PUSH_MESSAGE_ID] = messageId;
            }
        } else {
            if (muteInsideApp) {
                mutableInfo[LP_KEY_PUSH_NO_ACTION_MUTE] = messageId;
            } else {
                mutableInfo[LP_KEY_PUSH_NO_ACTION] = messageId;
            }
        }
        
        if (@available(iOS 10.0, *)) {
            UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
            
            if (message) {
                content.body = message;
            } else {
                content.body = LP_VALUE_DEFAULT_PUSH_MESSAGE;
            }
            
            if (category) {
                content.categoryIdentifier = category;
            }
            
            if (sound) {
                content.sound = [UNNotificationSound soundNamed:sound];
            } else {
                content.sound = [UNNotificationSound defaultSound];
            }

            if (badge) {
                content.badge = [NSNumber numberWithInt:[badge intValue]];
            }

            content.userInfo = mutableInfo;
            
            NSDateComponents *dateComponenets = [[NSDateComponents alloc] init];
            [dateComponenets setSecond:countdownSeconds];
            UNCalendarNotificationTrigger *trigger = [UNCalendarNotificationTrigger triggerWithDateMatchingComponents:dateComponenets repeats:NO];
            
            UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:messageId content:content trigger:trigger];
            
            [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
                if (error) {
                    LPLog(LPError, error.localizedDescription);
                }
            }];
            
        } else {
            UILocalNotification *localNotif = [[UILocalNotification alloc] init];
            localNotif.fireDate = eta;
            localNotif.timeZone = [NSTimeZone defaultTimeZone];
            if (message) {
                localNotif.alertBody = message;
            } else {
                localNotif.alertBody = LP_VALUE_DEFAULT_PUSH_MESSAGE;
            }
            localNotif.alertAction = @"View";

            if ([localNotif respondsToSelector:@selector(setCategory:)]) {
                if (category) {
                    localNotif.category = category;
                }
            }

            if (sound) {
                localNotif.soundName = sound;
            } else {
                localNotif.soundName = UILocalNotificationDefaultSoundName;
            }

            if (badge) {
                localNotif.applicationIconBadgeNumber = [badge intValue];
            }

            localNotif.userInfo = mutableInfo;

            // Schedule the notification
            [app scheduleLocalNotification:localNotif];
        }
        
        if ([LPConstantsState sharedState].isDevelopmentModeEnabled) {
            LPLog(LPInfo, @"Scheduled notification");
        }
        LP_BEGIN_USER_CODE
        return YES;
    }];

    [Leanplum onAction:@"__Cancel__Push Notification" invoke:^BOOL(LPActionContext *context) {
        LP_END_USER_CODE
        UIApplication *app = [UIApplication sharedApplication];
        NSArray *notifications = [app scheduledLocalNotifications];
        if (@available(iOS 10.0, *)) {
            __block BOOL didCancel = NO;
            dispatch_semaphore_t semaphor = dispatch_semaphore_create(0);
            [UNUserNotificationCenter.currentNotificationCenter getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest *> * _Nonnull requests) {
                for (UNNotificationRequest *request in requests) {
                    NSString *messageId = [[LPNotificationsManager shared] messageIdFromUserInfo:[request.content userInfo]];
                    if ([messageId isEqualToString:context.messageId]) {
                        [UNUserNotificationCenter.currentNotificationCenter removeDeliveredNotificationsWithIdentifiers:@[request.identifier]];
                        if ([LPConstantsState sharedState].isDevelopmentModeEnabled) {
                            LPLog(LPInfo, @"Cancelled notification");
                        }
                        didCancel = YES;
                    }
                }
                dispatch_semaphore_signal(semaphor);
            }];
            dispatch_time_t waitTime = dispatch_time(DISPATCH_TIME_NOW, 5.0 * NSEC_PER_SEC);
            dispatch_semaphore_wait(semaphor, waitTime);
            LP_BEGIN_USER_CODE
            return didCancel;
        } else {
            // Fallback on earlier versions
            BOOL didCancel = NO;
            for (UILocalNotification *notification in notifications) {
                NSString *messageId = [[LPNotificationsManager shared] messageIdFromUserInfo:[notification userInfo]];
                if ([messageId isEqualToString:context.messageId]) {
                    [app cancelLocalNotification:notification];
                    if ([LPConstantsState sharedState].isDevelopmentModeEnabled) {
                        LPLog(LPInfo, @"Cancelled notification");
                    }
                    didCancel = YES;
                }
            }
            LP_BEGIN_USER_CODE
            return didCancel;
        }
    }];
}

- (BOOL)shouldSendNotificationForMessage:(NSString *)message contentAvailable:(BOOL)contentAvailable
{
    // Don't send notification if the user doesn't have the permission enabled.
    if ([[UIApplication sharedApplication] respondsToSelector:@selector(currentUserNotificationSettings)]) {
        BOOL isSilentNotification = message.length == 0 && contentAvailable;
        if (!isSilentNotification) {
            UIUserNotificationSettings *currentSettings = [[UIApplication sharedApplication] currentUserNotificationSettings];
            if ([currentSettings types] == UIUserNotificationTypeNone) {
                return NO;
            }
        }
    }
    return YES;
}

- (BOOL)shouldDiscard:(NSDate *)eta context:(LPActionContext *)context
{
    // If there's already one scheduled before the eta, discard this.
    // Otherwise, discard the scheduled one.
    if (@available(iOS 10.0, *)) {
        __block BOOL shouldDiscard = NO;
        dispatch_semaphore_t semaphor = dispatch_semaphore_create(0);
        [UNUserNotificationCenter.currentNotificationCenter getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest *> * _Nonnull requests) {
            for (UNNotificationRequest *request in requests) {
                NSString *messageId = [[LPNotificationsManager shared] messageIdFromUserInfo:[request.content userInfo]];
                if ([messageId isEqualToString:context.messageId]) {
                    UNCalendarNotificationTrigger *trigger = (UNCalendarNotificationTrigger *)request.trigger;
                    NSComparisonResult comparison = [trigger.nextTriggerDate compare:eta];
                    if (comparison == NSOrderedAscending) {
                        shouldDiscard = YES;
                        break;
                    } else {
                        [UNUserNotificationCenter.currentNotificationCenter removeDeliveredNotificationsWithIdentifiers:@[request.identifier]];
                    }
                }
            }
            dispatch_semaphore_signal(semaphor);
        }];
        dispatch_time_t waitTime = dispatch_time(DISPATCH_TIME_NOW, 5.0 * NSEC_PER_SEC);
        dispatch_semaphore_wait(semaphor, waitTime);
        return shouldDiscard;
    } else {
        // Fallback on earlier versions
        NSArray *notifications = [[UIApplication sharedApplication] scheduledLocalNotifications];
        for (UILocalNotification *notification in notifications) {
            NSString *messageId = [[LPNotificationsManager shared] messageIdFromUserInfo:[notification userInfo]];
            if ([messageId isEqualToString:context.messageId]) {
                NSComparisonResult comparison = [notification.fireDate compare:eta];
                if (comparison == NSOrderedAscending) {
                    return YES;
                } else {
                    [[UIApplication sharedApplication] cancelLocalNotification:notification];
                }
            }
        }
        return NO;
    }
}

@end
