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

/** 
 APIncrementalStore will post this message before it starts the disk cache sync process. 
 Also the NSNotification userinfo will be keyed with APNotificationCacheNumberOfLocalObjectsKey 
 and APNotificationCacheNumberOfRemoteObjectsKey showing the TOTAL number of objects that will 
 be synced, the value will be -1 if couting is not supported.
 */
extern NSString *const APNotificationStoreWillStartSync;
extern NSString *const APNotificationCacheWillStartSync __attribute__((deprecated("use APNotificationStoreWillStartSync. First deprecated in 0.4")));


/** 
 APIncrementalStore will post this message once it synced a single object. Also the NSNotification 
 userinfo will be keyed with APNotificationCacheNumberOfLocalObjectsKey and 
 APNotificationCacheNumberOfRemoteObjectsKey showing the number of objects that were synced.
 */
extern NSString *const APNotificationStoreDidSyncObject;
extern NSString *const APNotificationCacheDidSyncObject __attribute__((deprecated("use APNotificationStoreDidSyncObject. First deprecated in 0.4")));


/// APIncrementalStore will post this message once it finished the disk cache sync process.
extern NSString *const APNotificationStoreDidFinishSync;
extern NSString *const APNotificationCacheDidFinishSync __attribute__((deprecated("use APNotificationStoreDidSyncObject. First deprecated in 0.4")));


/**
 APIncrementalStore will include this key when the APNotificationCacheWillStartSync 
 is sent showing how many cached objects will be synced.
 When object couting is not fully supported by the webservice the value will be -1. 
 It will be also be included in APNotificationStoreDidSyncObject with value set to 1.
 */
extern NSString *const APNotificationNumberOfLocalObjectsSyncedKey;
extern NSString *const APNotificationCacheNumberOfLocalObjectsKey __attribute__((deprecated("use APNotificationNumberOfLocalObjectsSyncedKey. First deprecated in 0.4")));

/** 
 APIncrementalStore will include this key when the APNotificationCacheWillStartSync 
 is sent showing how many remote objects will be merged localy.
 When object counting is not fully supported by the webservice the value will be -1.
 It will be also be included in APNotificationStoreDidSyncObject with value set to 1.
 */
extern NSString *const APNotificationNumberOfRemoteObjectsSyncedKey;
extern NSString *const APNotificationCacheNumberOfRemoteObjectsKey __attribute__((deprecated("use APNotificationNumberOfRemoteObjectsSyncedKey. First deprecated in 0.4")));

/**
 APIncrementalStore will include this key when the APNotificationCacheWillStartSync
 is sent showing the enntity name being merged.
 It will be also be included in APNotificationStoreDidSyncObject with value set to 1.
 */
extern NSString *const APNotificationObjectEntityNameKey;

/** 
 Along with APNotificationStoreDidFinishSync notificaiton this key will contain all objects 
 successfuly merged nested by entity name and objectID. Use it to refresh current in memory core 
 data objects.
 */
extern NSString *const APNotificationSyncedObjectsKey;

/// If any error happens during sync process the Notifications sent by APIncrementalStore will contain this key with the related NSError.
extern NSString *const APNotificationSyncErrorKey;


/**************************
/ Cache Reset Notifications
***************************/

/// Post this message to request the disk cache to recreate the local sqlite db as well as its psc and mocs
extern NSString* const APNotificationStoreRequestCacheReset;
extern NSString* const APNotificationCacheRequestReset __attribute__((deprecated("use APNotificationStoreRequestCacheReset. First deprecated in 0.4")));;\


/// APIncrementalStore will post this message once it finished the disk cache reset process
extern NSString* const APNotificationStoreDidFinishCacheReset;
extern NSString* const APNotificationCacheDidFinishReset __attribute__((deprecated("use APNotificationStoreDidFinishCacheReset. First deprecated in 0.4")));



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

/// Set it to YES and the APIncrementalStore will start a sync process after each context save. Default is YES.
extern NSString* const APOptionSyncOnSaveKey;

/// The name of the disk cache store file.
extern NSString* const APOptionCacheFileNameKey;

/// Whether or not an existing sqlite file should be removed a a new one creted before the persistent store start using it
extern NSString* const APOptionCacheFileResetKey __attribute__((deprecated("First deprecated in 0.42")));

/**
 When adding the this class to a persistent store coordinator use this option
 to control which object will get persistent when a conflict is detected between
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
