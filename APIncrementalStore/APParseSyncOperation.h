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

#import "APWebServiceSyncOperation.h"


@class PFUser;

extern NSString* const APParseRelationshipTypeUserInfoKey;

typedef NS_ENUM(NSUInteger, APParseRelationshipType) {
    APParseRelationshipTypeNonExistent = 0,
    APParseRelationshipTypeArray = 1,
    APParseRelationshipTypePFRelation = 2,
    
};


@interface APParseSyncOperation : APWebServiceSyncOperation

/**
 @param authenticatedUser An already authenticated user
 @param policy one of defined APMergePolicy options
 @param psc the persistent store coordinator to be used for this sync process. Use a separete one to avoid blocking the app's psc.
 @param pushNotification set it to YES if you want that a PFPush be sent out with a @{@"content-available":@"1"} whenever a local object is synced with Parse.
 */
- (instancetype)initWithMergePolicy:(APMergePolicy) policy
             authenticatedParseUser:(PFUser*) authenticatedUser
         persistentStoreCoordinator:(NSPersistentStoreCoordinator *)psc
              sendPushNotifications:(BOOL) pushNotification;

@property (nonatomic, strong, readonly) PFUser* authenticatedUser;

@end
