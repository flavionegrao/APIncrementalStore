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

NSString* const CoreDataControllerNotificationDidSync = @"CoreDataControllerNotificationDidSync";
NSString* const CoreDataControllerNotificationDidResetTheCache = @"CoreDataControllerNotificationDidResetTheCache";
NSString* const CoreDataControllerACLAttributeName = @"__ACL";

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
        self.isSyncingTheCache = NO;
        self.isResetingTheCache = NO;
        [self registreForNotifications];
    }
    return self;
}


- (void) registreForNotifications {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    [[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(didReceiveNotificationCacheWillStartSync:) name:APNotificationCacheWillStartSync object:nil];
    [[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(didReceiveNotificationCacheDidFinishSync:) name:APNotificationCacheDidFinishSync object:nil];
    [[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(didReceiveNotificationCacheDidReset:) name:APNotificationCacheDidFinishReset object:nil];
}

- (void) dealloc {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:APNotificationCacheDidFinishReset object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:APNotificationCacheDidFinishSync object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:APNotificationCacheWillStartSync object:nil];
}


#pragma mark - Gettters and Setters

- (void) setAuthenticatedUser:(id)authenticatedUser {
    
    _authenticatedUser = authenticatedUser;
    [self configPersistantStoreCoordinator];
}


- (NSManagedObjectContext*) mainContext {
    
    if (!_mainContext) {
        
        if (!self.authenticatedUser) {
            ELog(@"Please set remoteDBAuthenticatedUser before starting using the managedContext");
            
        } else {
            _mainContext = [[NSManagedObjectContext alloc]initWithConcurrencyType:NSMainQueueConcurrencyType];
            _mainContext.persistentStoreCoordinator = self.psc;
        }
    }
    return _mainContext;
}


- (void) configPersistantStoreCoordinator {
    
    /* Turn on/off to enable different levels of debugging */
    AP_DEBUG_METHODS = YES;
    AP_DEBUG_ERRORS = YES;
    AP_DEBUG_INFO = YES;
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    // Set it to nil, if we are changing users existing contexts will be invalid
    self.mainContext = nil;
    
    [NSPersistentStoreCoordinator registerStoreClass:[APIncrementalStore class] forStoreType:[APIncrementalStore type]];
    
    self.psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:[self model]];
    
    [self.psc addPersistentStoreWithType:[APIncrementalStore type]
                           configuration:nil
                                     URL:nil
                                 options:@{APOptionAuthenticatedUserObjectKey:self.authenticatedUser,
                                           APOptionCacheFileNameKey:APLocalCacheFileName,
                                          // APIncrementalStoreOptionCacheFileReset:@NO,
                                           APOptionMergePolicyKey:APOptionMergePolicyServerWins}
                                   error:nil];
}


- (NSManagedObjectModel*) model {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    NSManagedObjectModel* model = [NSManagedObjectModel mergedModelFromBundles:nil];
    NSManagedObjectModel *adjustedModel = [model copy];
    
    for (NSEntityDescription *entity in adjustedModel.entities) {
        
        // Don't add properties for sub-entities, as they already exist in the super-entity
        if ([entity superentity]) {
            continue;
        }
        
        NSAttributeDescription *objectACLProperty = [[NSAttributeDescription alloc] init];
        [objectACLProperty setName:CoreDataControllerACLAttributeName];
        [objectACLProperty setAttributeType:NSBinaryDataAttributeType];
        [objectACLProperty setOptional:YES];
        [objectACLProperty setIndexed:NO];
        
        [entity setProperties:[entity.properties arrayByAddingObjectsFromArray:@[objectACLProperty]]];
    }
    return adjustedModel;
}


#pragma mark - Cache Reset

- (void) requestResetCache {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    self.isResetingTheCache = YES;
    [[NSOperationQueue mainQueue]addOperationWithBlock:^{
        [[NSNotificationCenter defaultCenter]postNotificationName:APNotificationCacheRequestReset object:self];
    }];
}


- (void) didReceiveNotificationCacheDidReset:(NSNotification*) note {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
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


- (void) didReceiveNotificationCacheWillStartSync: (NSNotification*) note {
    
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
     using only managed object IDs. I don't belive this class can get away using apple message name, so it's going to first replace all 
     object IDs with managed objects before request the context to merge it.
     */
    NSNotification* adjustedNote = [self notificationReplacingIDsWithManagedObjectsFromNotification:note forManagedContext:self.mainContext];
    [self.mainContext mergeChangesFromContextDidSaveNotification:adjustedNote];
    
    self.isSyncingTheCache = NO;
    if (AP_DEBUG_INFO) {DLog(@"Notification modified to: %@",note)}
    [[NSNotificationCenter defaultCenter]postNotificationName:CoreDataControllerNotificationDidSync object:self];
}


- (NSNotification*) notificationReplacingIDsWithManagedObjectsFromNotification:(NSNotification*) note
                                                             forManagedContext:(NSManagedObjectContext*) context {
    
    NSMutableDictionary* userInfoWithManagedObjects = [note.userInfo mutableCopy];
    [userInfoWithManagedObjects enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        if ([key isEqualToString:NSInsertedObjectsKey] || [key isEqualToString:NSUpdatedObjectsKey] || [key isEqualToString:NSDeletedObjectsKey]) {
            NSArray* managedObjectIDs = (NSArray*) obj;
            NSMutableArray* managedObjects = [[NSMutableArray alloc]initWithCapacity:[managedObjectIDs count]];
            [managedObjectIDs enumerateObjectsUsingBlock:^(NSManagedObjectID* managedObjectID, NSUInteger idx, BOOL *stop) {
                [managedObjects addObject:[context objectWithID:managedObjectID]];
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


#pragma mark - ACLs

- (void) addWriteAccess:(BOOL)writeAccess
             readAccess:(BOOL)readAccess
                 isRole:(BOOL)isRole
     forParseIdentifier:(NSString*) identifier
       forManagedObject:(NSManagedObject*) managedObject {
    
    NSMutableDictionary* ACL;
    
    NSData* currentACLData = [managedObject valueForKey:CoreDataControllerACLAttributeName];
    if (currentACLData) {
        ACL = [NSMutableDictionary dictionaryWithDictionary:[NSJSONSerialization JSONObjectWithData:currentACLData options:0 error:nil]];
    } else {
        ACL = [NSMutableDictionary dictionary];
    }
    
    NSString* adjustedIdentifier;
    if (isRole){
        adjustedIdentifier= [NSString stringWithFormat:@"role:%@",identifier];
    } else {
        adjustedIdentifier = identifier;
    }
    
    NSDictionary* permission = @{@"read": (readAccess) ? @"true": @"false",
                                 @"write": (writeAccess) ? @"true" : @"false"};
    
    [ACL setValue:permission forKey:adjustedIdentifier];
    NSData* ACLData = [NSJSONSerialization dataWithJSONObject:ACL options:0 error:nil];
    [managedObject setValue:ACLData forKey:CoreDataControllerACLAttributeName];
}

@end
