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

#import "CoreDataController.h"
#import "APIncrementalStore.h"
#import "NSLogEmoji.h"
#import "APCommon.h"

NSString* const CoreDataControllerNotificationDidSync = @"com.apetis.apincrementalstore.coredatacontroller.notification.didsync";
NSString* const CoreDataControllerNotificationDidSyncObject = @"com.apetis.apincrementalstore.coredatacontroller.notification.didsyncobject";
NSString* const CoreDataControllerNotificationDidResetTheCache = @"com.apetis.apincrementalstore.coredatacontroller.notification.didresetthecache";
NSString* const CoreDataControllerErrorKey = @"com.apetis.apincrementalstore.coredatacontroller.error.key";

static NSString* const APLocalCacheFileName = @"APCacheStore.sqlite";

@interface CoreDataController ()

@property (nonatomic, strong) NSPersistentStoreCoordinator *psc;
@property (nonatomic, strong) NSManagedObjectContext *mainContext;
@property (atomic, assign) BOOL isSyncingTheCache;
@property (atomic, assign) BOOL isResetingTheCache;

@end


@implementation CoreDataController


+ (instancetype)sharedInstance {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    static id sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc]init];
    });
    return sharedInstance;
}

- (instancetype)init {
    
   if (AP_DEBUG_METHODS) {MLog(@"Self:%@",self)}
    
    self = [super init];
    
    if (self) {
        _isSyncingTheCache = NO;
        _isResetingTheCache = NO;
    }
    return self;
}


- (void) registreForNotifications {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    //id persistantStore = [self.psc.persistentStores firstObject];
    
    [[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(didReceiveNotificationCacheDidStartSync:) name:APNotificationStoreWillStartSync object:nil];
    [[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(didReceiveNotificationCacheDidFinishSync:) name:APNotificationStoreDidFinishSync object:nil];
    [[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(didReceiveNotificationCacheDidReset:) name:APNotificationStoreDidFinishCacheReset object:nil];
}

- (void) unregistreForNotifications {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
   // id persistantStore = [self.psc.persistentStores firstObject];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:APNotificationStoreDidFinishCacheReset object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:APNotificationStoreDidFinishSync object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:APNotificationStoreWillStartSync object:nil];
}

- (void) dealloc {
    [self unregistreForNotifications];
}


#pragma mark - Gettters and Setters

- (void) setAuthenticatedUser:(id)authenticatedUser {
    
    _authenticatedUser = authenticatedUser;
    [self configPersistentStoreCoordinator];
    [self registreForNotifications];
}


- (void) configMainContext {
    
    if (!self.authenticatedUser) {
        ELog(@"Please set remoteDBAuthenticatedUser before starting using the managedContext");
        
    } else {
        self.mainContext = [[NSManagedObjectContext alloc]initWithConcurrencyType:NSMainQueueConcurrencyType];
        self.mainContext.persistentStoreCoordinator = self.psc;
        [self.mainContext setStalenessInterval:0];
    }
}


- (void) configPersistentStoreCoordinator {
    
    /* Turn on/off to enable different levels of debugging */
    AP_DEBUG_METHODS = YES;
    AP_DEBUG_ERRORS = YES;
    AP_DEBUG_INFO = YES;
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    // Set it to nil, if we are changing users existing contexts will be invalid
    //self.mainContext = nil;
    
    // Remove any previously registred store.
    [self.psc.persistentStores enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        NSError* error;
        if (![self.psc removePersistentStore:obj error:&error]) {
            NSAssert(NO, @"Can't remove existent store from its PSC: %@",obj);
        }
        //obj = nil;
    }];
    
    [NSPersistentStoreCoordinator registerStoreClass:[APIncrementalStore class] forStoreType:[APIncrementalStore type]];
    
    NSBundle* bundle = [NSBundle bundleForClass:[self class]];
    NSManagedObjectModel* model = [NSManagedObjectModel mergedModelFromBundles:@[bundle]];
    self.psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    
    [self.psc addPersistentStoreWithType:[APIncrementalStore type]
                           configuration:nil
                                     URL:nil
                                 options:@{APOptionAuthenticatedUserObjectKey:self.authenticatedUser,
                                           APOptionCacheFileNameKey:APLocalCacheFileName,
                                          // APIncrementalStoreOptionCacheFileReset:@NO,
                                           APOptionMergePolicyKey:APOptionMergePolicyServerWins,
                                           APOptionSyncOnSaveKey:@NO}
                                   error:nil];
    [self.mainContext reset];
    self.mainContext = nil;
    [self configMainContext];
}


#pragma mark - Cache Reset

- (void) requestResetCache {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    self.isResetingTheCache = YES;
    [[NSOperationQueue mainQueue]addOperationWithBlock:^{
        [[NSNotificationCenter defaultCenter]postNotificationName:APNotificationStoreRequestCacheReset object:self];
    }];
}


- (void) didReceiveNotificationCacheDidReset:(NSNotification*) note {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    [self unregistreForNotifications];
    [self registreForNotifications];
    
    self.isResetingTheCache = NO;
    [[NSOperationQueue mainQueue]addOperationWithBlock:^{
        [[NSNotificationCenter defaultCenter]postNotificationName:CoreDataControllerNotificationDidResetTheCache object:self];
    }];
}


#pragma mark - Sync

- (void) requestSyncCache {
    
    if (AP_DEBUG_METHODS) {MLog()}
    self.isSyncingTheCache = YES;
    [[NSNotificationCenter defaultCenter]postNotificationName:APNotificationRequestCacheSync object:self];
}


- (void) didReceiveNotificationCacheDidStartSync: (NSNotification*) note {
    
    self.isSyncingTheCache = YES;
}


- (void) didReceiveNotificationCacheDidFinishSync:(NSNotification*) note {
    
    if (AP_DEBUG_METHODS) {MLog()}
    if (AP_DEBUG_INFO) {DLog(@"Notification received: %@",note)}
    
    /*
     Apparently the method -[NSManagedObjectContext mergeChangesFromContextDidSaveNotification:] accepts only managed objects within
     the passed notification userInfo. When the APDiskCache finishes its sync process and sends out the NSNotification it doesn't know anythng
     about what context are intered in merging the recent updates, therefore it can't create the managed objects, so that it sends
     only manged objects IDs.
     
     However when a coredata stack is set under iCloud, the ubiquity store sends a similar message when it finishes the import process
     NSPersistentStoreDidImportUbiquitousContentChangesNotification (@"com.apple.coredata.ubiquity.importer.didfinishimport") and that
     contains managed object IDs. I've tested changing the message name to match it and the context identify it correctly and merge it
     using only managed object IDs. I don't belive this class can get away using iCloud's notification name, so it's going to first replace all
     object IDs with managed objects before request the context to merge it.
     */
    NSNotification* adjustedNote = [self notificationReplacingIDsWithManagedObjectsFromNotification:note forManagedContext:self.mainContext];
    [self.mainContext mergeChangesFromContextDidSaveNotification:adjustedNote];
    
    self.isSyncingTheCache = NO;
    NSError* syncError = note.userInfo[APNotificationSyncErrorKey];
    [[NSNotificationCenter defaultCenter]postNotificationName:CoreDataControllerNotificationDidSync
                                                       object:self
                                                     userInfo:(syncError) ? @{CoreDataControllerErrorKey:note.userInfo[APNotificationSyncErrorKey]} : nil];
}


- (NSNotification*) notificationReplacingIDsWithManagedObjectsFromNotification:(NSNotification*) note
                                                             forManagedContext:(NSManagedObjectContext*) context {
    
    NSMutableDictionary* userInfoWithManagedObjects = [note.userInfo[APNotificationSyncedObjectsKey] mutableCopy];
    
    [userInfoWithManagedObjects enumerateKeysAndObjectsUsingBlock:^(id key, NSArray* managedObjectIDs, BOOL *stop) {
        
        if ([key isEqualToString:NSInsertedObjectsKey] || [key isEqualToString:NSUpdatedObjectsKey] || [key isEqualToString:NSDeletedObjectsKey]) {
            
            NSMutableArray* managedObjects = [[NSMutableArray alloc]initWithCapacity:[managedObjectIDs count]];
            
            [managedObjectIDs enumerateObjectsUsingBlock:^(NSManagedObjectID* managedObjectID, NSUInteger idx, BOOL *stop) {
                
                if ([context.persistentStoreCoordinator.persistentStores containsObject:managedObjectID.persistentStore]) {
                    [managedObjects addObject:[context objectWithID:managedObjectID]];
                
                } else {
                    NSLog(@"Warning - notification has objectIDs that don't belong the current managed context's persistantStoreCoordinator");
                }
            }];
            userInfoWithManagedObjects[key] = managedObjects;
        }
    }];
    
    return [NSNotification notificationWithName:note.name object:note.object userInfo:userInfoWithManagedObjects];
}


#pragma mark - Main Context Operations

- (BOOL) saveMainContextAndRequestCacheSync:(NSError* __autoreleasing*) error { 
    
    __block BOOL success = YES;
    
    [self.mainContext performBlockAndWait:^{
        NSError* localError;
        if (![self.mainContext save:&localError]) {
            if (AP_DEBUG_ERRORS) ELog(@"Error saving main context: %@",localError);
            success = NO;
            *error = localError;
        } else {
            [self requestSyncCache];
        }
    }];
    
    return success;
}

@end
