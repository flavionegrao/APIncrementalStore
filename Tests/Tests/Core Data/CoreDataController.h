/*
 *
 * Copyright 2014 Flavio Negrão Torres
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <Foundation/Foundation.h>

extern NSString* const CoreDataControllerNotificationDidSync;
extern NSString* const CoreDataControllerNotificationDidSyncObject;
extern NSString* const CoreDataControllerNotificationDidResetTheCache;
extern NSString* const CoreDataControllerACLAttributeName;
extern NSString* const CoreDataControllerErrorKey;


@interface CoreDataController : NSObject

+ (instancetype)sharedInstance;

/// It is mandatory that remoteDBAuthenticatedUser is set before use it.
@property (nonatomic, strong, readonly) NSManagedObjectContext *mainContext;

@property (nonatomic, strong) id authenticatedUser;

@property (atomic,readonly) BOOL isSyncingTheCache;
@property (atomic,readonly) BOOL isResetingTheCache;

/**
 It will start the local cache process and set the property isSyncingTheCache to YES.
 Once it is done the property isSyncing will be set to NO and CoreDataControllerNotificationDidSync will be posted.
 Use this notification to refresh your managed objects if you need.
 This process is perfomed using NSNotifications with APIncrementalStore.
*/
- (void) requestSyncCache;


/**
 It will start the local cache reset process and set the property isResetingTheCache to YES.
 Once it is done the property isReseting will be set to NO and CoreDataControllerNotificationDidResetTheCache will be posted.
 This process is perfomed using NSNotifications with APIncrementalStore.
 */
- (void) requestResetCache;


/** 
 Save the managed object context associated with the property mainContext and 
 request the local cache to start the sync process in BG (-[CoreDataController requestSyncCache])
 @returns If the save was successful returns YES otherwise NO
 */
- (BOOL) saveMainContextAndRequestCacheSync:(NSError* __autoreleasing*) error;

@end
