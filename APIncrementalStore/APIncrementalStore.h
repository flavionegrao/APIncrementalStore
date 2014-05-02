/*
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

@import CoreData;


#pragma mark - Notifications

/***************************
/ Sync Request Notifications
****************************/

/// Post this message to request the disk cache to start the sync process with remote webservice
extern NSString *const APNotificationRequestCacheSync;

/// Post this message to request the disk cache to start the FULL sync process with remote webservice (ignores whether or not an object was previously synced)
extern NSString *const APNotificationRequestCacheFullSync;


/*****************************
 / Sync Progress Notifications
 *****************************/

/// APIncrementalStore will post this message before it starts the disk cache sync process. Also the NSNotification userinfo will be keyed with APNotificationCacheNumberOfLocalObjectsKey and APNotificationCacheNumberOfRemoteObjectsKey showing the TOTAL number of objects that will be synced, the value will be -1 if couting is not supported.
extern NSString *const APNotificationCacheWillStartSync;

/// APIncrementalStore will post this message once it synced a single object. Also the NSNotification userinfo will be keyed with APNotificationCacheNumberOfLocalObjectsKey and APNotificationCacheNumberOfRemoteObjectsKey showing the number of objects that were synced.
extern NSString *const APNotificationCacheDidSyncObject;

/// APIncrementalStore will post this message once it finished the disk cache sync process
extern NSString *const APNotificationCacheDidFinishSync;


/// APIncrementalStore will include this key when the APNotificationCacheWillStartSync is sent showing how many cached objects will be synced. The value will be -1 if couting is not supported.
extern NSString *const APNotificationCacheNumberOfLocalObjectsKey;

/// APIncrementalStore will include this key when the APNotificationCacheWillStartSync is sent showing how many remote objects will be synced. The value will be -1 if couting is not supported.
extern NSString *const APNotificationCacheNumberOfRemoteObjectsKey;


/**************************
/ Cache Reset Notifications
***************************/

/// Post this message to request the disk cache to recreate the local sqlite db as well as its psc and mocs
extern NSString* const APNotificationCacheRequestReset;

/// APIncrementalStore will post this message once it finished the disk cache reset process
extern NSString* const APNotificationCacheDidFinishReset;



#pragma mark - Incremental Store Options
/*
 Use below options to configure few parameters related to this NSIncremental store subclass
 Example:
     [self.psc addPersistentStoreWithType:[APIncrementalStore type]
                            configuration:nil
                                       URL:nil
                                   options:@{APOptionAuthenticatedUserObjectKey:self.remoteDBAuthenticatedUser,
                                             APOptionCacheFileNameKey:APLocalCacheFileName,
                                             APOptionCacheFileResetKey:@NO,
                                             APOptionMergePolicyKey:APOptionMergePolicyServerWins}
                                     error:nil];
 */

/// The user object authenticated that will be used to sync with the BaaS provider.
extern NSString* const APOptionAuthenticatedUserObjectKey;

/// The name of the disk cache store file.
extern NSString* const APOptionCacheFileNameKey;

/// Whether or not an existing sqlite file should be removed a a new one creted before the persistant store start using it
extern NSString* const APOptionCacheFileResetKey;

/**
 When adding the this class to a persistant store coordinator use this option
 to control which object will get persistant when a conflict is detected between
 cached and webservice objects:
 APIncrementalStoreMergePolicyServerWins - webservice object overwrite cached object (DEFAULT)
 APIncrementalStoreMergePolicyClientWins - cached object overwrite webservice object
 */
extern NSString* const APOptionMergePolicyKey;

/**
 Server object overwrite cached object (DEFAULT)
 @see APOptionMergePolicy
 */
extern NSString* const APOptionMergePolicyServerWins;

/**
 Cached object overwrite webservice object
 @see APOptionMergePolicy
 */
extern NSString* const APOptionMergePolicyClientWins;


#pragma mark -
@interface APIncrementalStore : NSIncrementalStore

+ (NSString*) type;

@end
