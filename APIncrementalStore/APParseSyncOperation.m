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

@import CoreData;

#import "APParseSyncOperation.h"

#import "NSLogEmoji.h"
#import <Parse-iOS-SDK/Parse.h>
#import "APError.h"
#import "APCommon.h"

NSString* const APParseRelationshipTypeUserInfoKey = @"APParseRelationshipType";

/* Debugging */
BOOL AP_DEBUG_METHODS = NO;
BOOL AP_DEBUG_ERRORS = NO;
BOOL AP_DEBUG_INFO = NO;

/*
 NSUserDefaults entry to track the earliest object date synced from Parse.
 We use this Dictionary to keep a "pointer" to a reference date per entity for the last updated object synced from Parse
 There will be one dictionary per logged user.
 @see -[APParseConnector latestObjectSyncedKey]
 */
static NSString* const APLatestObjectSyncedKey = @"com.apetis.apincrementalstore.parseconnector.request.latestobjectsynced.key";

/*
 It specifies the maximum number of objects that a single parse query should return when executed.
 If there are more objects than this limit it will be fetched in batches.
 Parse specifies that 100 is the default but it can be increased to maximum 1000.
 */
static NSUInteger const APParseQueryFetchLimit = 100;



@implementation NSRelationshipDescription (APParseSyncOperation)

- (APParseRelationshipType) relationshipType {
    NSAssert(self.userInfo[APParseRelationshipTypeUserInfoKey], @"It seems that there are a missconfigured userinfo key APParseRelationshipType in the model to-many relationship to enable the APIncremental Store to determine how to syncronize it proeprly against Parse distincty kinds os relationships");
    return [self.userInfo[APParseRelationshipTypeUserInfoKey]integerValue];
}

- (BOOL) existsAtParse {
    if (!self.isToMany) {
        return YES;
    } else if ([self relationshipType] != APParseRelationshipTypeNonExistent) {
        return YES;
    } else {
        return NO;
    }
}

- (BOOL) isArrayAtParse {
    if ([self relationshipType] == APParseRelationshipTypeArray) {
        return YES;
    } else {
        return NO;
    }
}

- (BOOL) isRelationAtParse {
    if ([self relationshipType]  == APParseRelationshipTypePFRelation) {
        return YES;
    } else {
        return NO;
    }
}

@end


@interface APParseSyncOperation()

@property (strong,nonatomic) NSMutableDictionary* latestObjectSyncedDates;
@property (strong,nonatomic) NSString* latestObjectSyncedKey;

@property (nonatomic, strong) NSMutableDictionary* mergedObjectsUIDsNestedByEntityName;
@property (nonatomic, strong) NSPersistentStoreCoordinator* psc;
@property (nonatomic, strong) NSManagedObjectContext* context;
@property (nonatomic, assign, getter=isPushNotificationEnable) BOOL pushNotificationEnable;

@property (nonatomic, strong) id contextDidSaveNotificationObserver;

@end


@implementation APParseSyncOperation

- (instancetype)initWithMergePolicy:(APMergePolicy) policy
             authenticatedParseUser:(PFUser*) authenticatedUser
         persistentStoreCoordinator:(NSPersistentStoreCoordinator *)psc
               sendPushNotifications:(BOOL) pushNotification {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    self = [super initWithMergePolicy:policy];
    if (self) {
        
        if (!authenticatedUser) {
            [NSException raise:APIncrementalStoreExceptionInconsistency format:@"can't init, user is nil"];
        }
        
        if (![authenticatedUser isKindOfClass:[PFUser class]]) {
            [NSException raise:APIncrementalStoreExceptionInconsistency format:@"user should be a PFUser kind of object"];
        }
        
        if (![authenticatedUser isAuthenticated]) {
            if (AP_DEBUG_ERRORS) {ELog(@"User is not authenticated")}
            self = nil;
            
        } else {
            //if (AP_DEBUG_INFO) {DLog(@"Using authenticated user: %@",authenticatedUser)}
            _authenticatedUser = authenticatedUser;
        }
        
        _pushNotificationEnable = pushNotification;
        
        if (!psc) {
            [NSException raise:APIncrementalStoreExceptionInconsistency format:@"can't init, psc is nil"];
        } else {
            _psc = psc;
        }
        
        _mergedObjectsUIDsNestedByEntityName = [NSMutableDictionary dictionary];
    }
    return self;
}


- (NSManagedObjectContext*) context {
    
    if (!_context) {
        _context = [[NSManagedObjectContext alloc]initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        _context.retainsRegisteredObjects = YES;
        _context.persistentStoreCoordinator = self.psc;
        
        NSString *reqSysVer = @"8";
        NSString *currSysVer = [[UIDevice currentDevice] systemVersion];
        if ([currSysVer compare:reqSysVer options:NSNumericSearch] != NSOrderedAscending) {
            [_context setValue:@"APIncrementalStore Sync Context" forKey:@"name"];
        }
    }
    return _context;
}


- (void) dealloc {
    
    [[NSNotificationCenter defaultCenter] removeObserver:self.contextDidSaveNotificationObserver];
}


#pragma mark - NSOperation methods

- (void) main {
    
    if (AP_DEBUG_INFO) {DLog(@"START")};
    
    if ([[UIApplication sharedApplication] applicationState] != UIApplicationStateActive) {
        NSLog(@"Parse API doesn't support queries when app is in running in background");
        if (AP_DEBUG_INFO) {DLog(@"FINISHED")};
        return;
    }
    
    [self configSaveContextObserver];
    
    if (![self isCancelled]) {
        NSError* localMergeError = nil;
        if (![self mergeLocalContextError:&localMergeError]) {
            
            // Error syncing local objects
            
            if (self.syncCompletionBlock) {
                [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    self.syncCompletionBlock(self.mergedObjectsUIDsNestedByEntityName,localMergeError);
                }];
            }
            return;
        }
    }
    
    if (![self isCancelled]) {
        NSError* remoteMergeError = nil;
        if (![self mergeRemoteObjectsError:&remoteMergeError]) {
            
            // Error syncing remote objects
            
            if (self.syncCompletionBlock) {
                
                [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    self.syncCompletionBlock(self.mergedObjectsUIDsNestedByEntityName,remoteMergeError);
                }];
            }
            return;
        }
    }
    
    if (![self isCancelled]) {
        NSError* savingError = nil;
        if (![self saveAndResetContext:&savingError]) {
            
            // Error saving context
            
            if (self.syncCompletionBlock) {
                
                [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    self.syncCompletionBlock(nil,savingError);
                }];
            }
            return;
        }
    }
    
    if (![self isCancelled]) {
        
        // All good, notifying error == nil
        
        if (self.syncCompletionBlock) {
            
            [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                self.syncCompletionBlock(self.mergedObjectsUIDsNestedByEntityName,nil);
            }];
        }
    }
    
    if (AP_DEBUG_INFO) {DLog(@"FINISHED")};
}


- (BOOL) mergeLocalContextError:(NSError*__autoreleasing*) error {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    __block BOOL success = YES;
    __block NSError* localError = nil;
    
    if (![self isUserAuthenticated:&localError]) {
        if (error) *error = localError;
        return NO;
    }
    
    __block NSUInteger numberOfDirtyObjectsSynced = 0;
    
    [self.context performBlockAndWait:^{
        
        NSArray* dirtyManagedObjects = [self managedObjectsMarkedAsDirtyInContext:self.context];
        
        NSLog(@"Local changes - Total objects to be synced: %lu", (unsigned long)[dirtyManagedObjects count]);
        
        [dirtyManagedObjects enumerateObjectsUsingBlock:^(NSManagedObject* managedObject, NSUInteger idx, BOOL *stop) {
            
            // Debug
            //NSDate* start = [NSDate date];
            
            NSError* blockError = nil;
            
            if ([self isCancelled]) {
                localError = [NSError errorWithDomain:APIncrementalStoreErrorDomain code:APIncrementalStoreErrorSyncOperationWasCancelled userInfo:nil];
                success = NO;
                *stop = YES;
                
            } else {
                
                NSString* objectUID = [managedObject valueForKey:APObjectUIDAttributeName];
                
                // Sanity check
                if (!objectUID) {
                    [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Managed object without objectUID associated??"];
                }
                
                if ([[managedObject valueForKey:APObjectIsCreatedRemotelyAttributeName] isEqualToNumber:@NO]) {
                    
                    // New object created localy
                    
                    if ([[managedObject valueForKey:APObjectStatusAttributeName] isEqualToNumber:@(APObjectStatusDeleted)]) {
                        
                        // Object was deleted before even synced with Parse, just delete it.
                        [self.context deleteObject:managedObject];
                        
                    } else {
                        
                        [self insertOnParseManagedObject:managedObject error:&blockError];
                        if (blockError) {
                            success = NO;
                            localError = blockError;
                            *stop = YES;
                        } else {
                            [managedObject setValue:@NO forKey:APObjectIsDirtyAttributeName];
                        }
                    }
                    
                } else {
                    
                    PFObject* parseObject = [self parseObjectFromEntity:managedObject.entity objectUID:objectUID error:&blockError];
                    if (blockError) {
                        success = NO;
                        localError = blockError;
                        *stop = YES;
                    } else {
                        
                        if (!parseObject) {
                            
                            // Object doesn't exist at Parse anymore
                            [self.context deleteObject:managedObject];
                            
                        } else {
                            NSDate* localObjectUpdatedAt = [managedObject valueForKey:APObjectLastModifiedAttributeName];
                            
                            /*
                             If the object has not been updated since last time we read it from Parse
                             we are safe to updated it. If the object APObjectIsDeleted is set to YES
                             then we save it back to the server to let the others known that it should be
                             deleted and finally we remove it from our disk cache.
                             */
                            
                            if ([parseObject.updatedAt isEqualToDate:localObjectUpdatedAt] || localObjectUpdatedAt == nil) {
                                [self populateParseObject:parseObject withManagedObject:managedObject error:&blockError];
                                
                                if (blockError) {
                                    success = NO;
                                    localError = blockError;
                                    *stop = YES;
                                    
                                } else {
                                    
                                    if (![parseObject save:&blockError]) {
                                        success = NO;
                                        localError = blockError;
                                        *stop = YES;
                                        
                                    } else {
                                        [managedObject setValue:@NO forKey:APObjectIsDirtyAttributeName];
                                        [managedObject setValue:parseObject.updatedAt forKey:APObjectLastModifiedAttributeName];
                                    }
                                }
                                
                            } else {
                                
                                // Conflict detected
                                
                                if (AP_DEBUG_INFO) { ALog(@"Conflict detected - ParseObject %@ - LocalObject: %@ - \n%@ \n%@ ",parseObject.updatedAt,localObjectUpdatedAt,parseObject,managedObject)}
                                
                                if (self.mergePolicy == APMergePolicyClientWins) {
                                    
                                    if (AP_DEBUG_INFO) {DLog(@"APMergePolicyClientWins")}
                                    
                                    [self populateParseObject:parseObject withManagedObject:managedObject error:&blockError];
                                    if (blockError) {
                                        success = NO;
                                        localError = blockError;
                                        *stop = YES;
                                        
                                    } else {
                                        if (![parseObject save:&blockError]) {
                                            success = NO;
                                            localError = blockError;
                                            *stop = YES;
                                        } else {
                                            if ([[managedObject valueForKey:APObjectStatusAttributeName] isEqualToNumber:@(APObjectStatusDeleted)]) {
                                                [self.context deleteObject:managedObject];
                                            } else {
                                                [managedObject setValue:@NO forKey:APObjectIsDirtyAttributeName];
                                                [managedObject setValue:parseObject.updatedAt forKey:APObjectLastModifiedAttributeName];
                                            }
                                        }
                                    }
                                    
                                } else if (self.mergePolicy == APMergePolicyServerWins) {
                                    if (AP_DEBUG_INFO) { DLog(@"APMergePolicyServerWins")}
                                    NSDictionary* serializeParseObject = [self serializeParseObject:parseObject forEntity:managedObject.entity error:&blockError];
                                    
                                    if (blockError) {
                                        success = NO;
                                        localError = blockError;
                                        *stop = YES;
                                        
                                    } else {
                                        [self populateManagedObject:managedObject withSerializedParseObject:serializeParseObject onInsertedRelatedObject:nil];
                                        [managedObject setValue:@NO forKey:APObjectIsDirtyAttributeName];
                                        [managedObject setValue:parseObject.updatedAt forKey:APObjectLastModifiedAttributeName];
                                        
                                        // TODO: Added it to self.mergedObjectsUIDsNestedByEntityName
                                    }
                                    
                                } else {
                                    [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Unkown Merge Policy"];
                                    if (AP_DEBUG_INFO) { ALog(@"Unkown Merge Policy")}
                                }
                            }
                        }
                    }
                }

                if (![self.context save:&blockError]){
                    if (blockError) {
                        localError = blockError;
                    }
                    *stop = YES;
                    success = NO;
                }
                
                if (!blockError) {
                    
                    //Debug
                   // NSDate* end = [NSDate date];
                    //NSLog(@"Local changes - entity %@ synced with Parse in %f seconds", managedObject.entity.name, [end timeIntervalSinceDate:start]);
                    
                    [[NSOperationQueue mainQueue]addOperationWithBlock:^{
                        if (self.perObjectCompletionBlock) self.perObjectCompletionBlock(NO,managedObject.entity.name);
                    }];
                }
            }
            numberOfDirtyObjectsSynced++;
        }];
        
    }];
    
   
    
    if (success)  {
        DLog(@"Local changes - All changes are in Sync");
        
        if (numberOfDirtyObjectsSynced > 0 && self.isPushNotificationEnable) {
            PFQuery * pushQuery = [PFInstallation query];
            [pushQuery whereKey:@"deviceType" equalTo:@"ios"];
            [pushQuery whereKey:@"installationId" notEqualTo:[PFInstallation currentInstallation].installationId];
            if (![PFPush sendPushDataToQuery:pushQuery withData:@{@"content-available":@"1"} error:&localError]) {
                ELog(@"Error sending push notification");
                success = NO;
            }
        }
    }
    
    if (error) *error = localError;
    return success;
}


- (BOOL) mergeRemoteObjectsError:(NSError*__autoreleasing*) error {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    __block BOOL success = YES;
    __block NSError* localError = nil;
    
    if (![self isUserAuthenticated:&localError]) {
        if (error) *error = localError;
        success = NO;
        return success;
    }
    
    /*
     The reason we fetch only the objects that have been updated up to now is to avoid the situation
     when say a class A has been synced then we start syncing class B, an object from class B holds a
     reference to a object from class A that we have not brought earlier.
     Such situation may happen if a object in class B gets updated after we have synced class A and
     before we ask for the objects in class B. Quite unlike but possible.
     */
    NSDate* parseServerTime = [self getParseServerTime:&localError];
    if (localError) {
        if (error) *error = localError;
        return NO;
    }
    
    [self.context performBlockAndWait:^{
        
        NSManagedObjectModel* model = self.context.persistentStoreCoordinator.managedObjectModel;
        NSArray* sortedEntities = [[model entities]sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]]];
        
        for (NSEntityDescription* entityDescription in sortedEntities) {
            
            if (!success) {
                break;
            }
            
            if ([self isCancelled]) {
                localError = [NSError errorWithDomain:APIncrementalStoreErrorDomain code:APIncrementalStoreErrorSyncOperationWasCancelled userInfo:nil];
                success = NO;
                break;
            }
            
            NSDate* lastSync;
            if (!self.fullSync) {
                /* Fetch only what has been updated since we last sync */
                lastSync = self.latestObjectSyncedDates[entityDescription.name];
            } else {
                lastSync = nil;
            }
            
            NSUInteger skip = 0;
            BOOL thereAreObjectsToBeFetched = YES;
            
            while (thereAreObjectsToBeFetched && success && [self isCancelled] == NO) {
                
                @autoreleasepool {
                    
                    PFQuery* syncQuery = [self syncQueryForEntity:entityDescription minUpdatedDate:lastSync maxUpdatedDate:parseServerTime offset:skip];
                    NSMutableArray* batchOfObjects = [[syncQuery findObjects:&localError] mutableCopy];
                    
                    NSLog(@"Remote changes: syncing batch of entities %@ (count %lu - offset %@) with Parse",entityDescription.name,(unsigned long)[batchOfObjects count],@(skip));
                    
                    if (localError) {
                        success = NO;
                        break;
                    }
                    
                    if ([batchOfObjects count] == APParseQueryFetchLimit) {
                        skip += APParseQueryFetchLimit;
                    } else {
                        thereAreObjectsToBeFetched = NO;
                    }
                    
                    while ([batchOfObjects count] > 0 && success && [self isCancelled] == NO) {
                        
                        @autoreleasepool {
                            
                            PFObject* parseObject = [batchOfObjects firstObject];
                            [batchOfObjects removeObjectAtIndex:0];
                            
                            NSManagedObject* managedObject = [self managedObjectForObjectUID:[parseObject valueForKey:APObjectUIDAttributeName] entity:entityDescription inContext:self.context createIfNecessary:NO error:&localError];
                            if (localError) {
                                success = NO;
                                break;
                            }
                            
                            if ([[managedObject valueForKey:APObjectLastModifiedAttributeName] isEqualToDate:parseObject.updatedAt]){
                                //Object was inserted/updated during - mergeManagedContext:onSyncObject:onSyncObject:error: and remains the same
                                [self setLatestObjectSyncedDate:parseObject.updatedAt forEntityName:entityDescription.name];
                                continue;
                            }
                            
                            BOOL parseObjectIsDeleted = [[parseObject valueForKey:APObjectStatusAttributeName]isEqualToNumber:@(APObjectStatusDeleted)];
                            
                            if (!managedObject) {
                                
                                // Disk cache managed object doesn't exist - create it localy if it isn't marked as deleted
                                
                                if (!parseObjectIsDeleted) {
                                    managedObject = [NSEntityDescription insertNewObjectForEntityForName:entityDescription.name inManagedObjectContext:self.context];
                                    [managedObject setValue:@YES forKeyPath:APObjectIsCreatedRemotelyAttributeName];
                                    
                                    if (![self.context obtainPermanentIDsForObjects:@[managedObject] error:&localError]) {
                                        if (localError) {
                                            success = NO;
                                            break;
                                        }
                                    }
                                    
                                    NSDictionary* serializeParseObject = [self serializeParseObject:parseObject forEntity:managedObject.entity error:&localError];
                                    if (localError) {
                                        success = NO;
                                        break;
                                    }
                                    
                                    [self populateManagedObject:managedObject withSerializedParseObject:serializeParseObject onInsertedRelatedObject:nil];
                                }
                                
                                } else {
                                    
                                    // Existing local object
                                    
                                    if (parseObjectIsDeleted) {
                                        [self.context deleteObject:managedObject];
                                        
                                        //objectStatus = NSDeletedObjectsKey;
                                        
                                    } else {
                                        NSDictionary* serializeParseObject = [self serializeParseObject:parseObject forEntity:managedObject.entity error:&localError];
                                        if (localError) {
                                            success = NO;
                                            break;
                                        }
                                        [self populateManagedObject:managedObject withSerializedParseObject:serializeParseObject onInsertedRelatedObject:nil];
                                    }
                                }
                                
                                // Include an entry into the return NSDictionary for the corresponding object status
                                
                                if (![self isCancelled]) {
                                    
                                    if (![self.context save:&localError]){
                                        success = NO;
                                        break;
                                        
                                    } else {
                                        [self setLatestObjectSyncedDate:parseObject.updatedAt forEntityName:entityDescription.name];
                                        [[NSOperationQueue mainQueue]addOperationWithBlock:^{
                                            if (self.perObjectCompletionBlock) self.perObjectCompletionBlock(YES,entityDescription.name);
                                        }];
                                    }
                                }
                                parseObject = nil;
                            } //@autoreleasepool
                        }
                    }
                }//@autoreleasepool
            }
    }];
    
    if (localError) *error = localError;
    
    if (success)  NSLog(@"Remote changes - All changes are in Sync");
    return success;
}


- (PFQuery*) syncQueryForEntity:(NSEntityDescription*) entityDescription
                 minUpdatedDate:(NSDate*) minUpdatedDate
                 maxUpdatedDate:(NSDate*) maxUpdatedDate
                         offset:(NSUInteger) offset {
    
    /*
     This covers the case when the model has entity inheritance.
     At Parse only the root class will be created and we filter based on APObjectEntityNameAttributeName column
     */
    NSEntityDescription* rootEntity = [self rootEntityFromEntity:entityDescription];
    
    PFQuery *query = [PFQuery queryWithClassName:rootEntity.name];
    [query setCachePolicy:kPFCachePolicyNetworkOnly];
    [query orderByAscending:@"updatedAt"];
    [query whereKey:APObjectEntityNameAttributeName equalTo:entityDescription.name];
    [query setLimit:APParseQueryFetchLimit];
    [query setSkip:offset];
    
    if (maxUpdatedDate) [query whereKey:@"updatedAt" lessThan:maxUpdatedDate];
    if (minUpdatedDate) [query whereKey:@"updatedAt" greaterThan:minUpdatedDate];
    
    /* Fetch related objects when the relation is flagged as a Array via core data model metadata or it's a to-one */
    [entityDescription.relationshipsByName enumerateKeysAndObjectsUsingBlock:^(NSString* relationName, NSRelationshipDescription* relationDescription, BOOL *stop) {
        
        if ([relationDescription existsAtParse] || [relationDescription isToMany] == NO) {
            [query includeKey:relationName];
        }
    }];
    
    if ([query hasCachedResult]) {[query clearCachedResult];}
    
    return query;
}

/*
 As stated by a Parse techincian: We currently limit count operations to 160 api requests within a
 one minute period for each application. We may have to adjust this in the future
 depending on database performance.
 https://parse.com/questions/code-154the-number-of-count-operations-in-progress-has-reached-its-limit-code-154-version-1125
 
 Therefore can't be used in real world
 */
- (NSInteger) countLocalObjectsToBeSyncedInContext: (NSManagedObjectContext *)context
                                             error: (NSError*__autoreleasing*) error {
    
    //return [[self managedObjectsMarkedAsDirtyInContext:context]count];
    return -1;
}


/*
 As stated by a Parse techincian: We currently limit count operations to 160 api requests within a
 one minute period for each application. We may have to adjust this in the future
 depending on database performance.
 https://parse.com/questions/code-154the-number-of-count-operations-in-progress-has-reached-its-limit-code-154-version-1125
 
 Therefore can't be used in real world
 */
- (NSInteger) countRemoteObjectsToBeSyncedInContext: (NSManagedObjectContext *)context
                                           fullSync: (BOOL) fullSync
                                              error: (NSError*__autoreleasing*) error {
    return -1;
    //    [self loadLatestObjectSyncedDates];
    //
    //    NSUInteger numberOfObjects = 0;
    //    NSError* countError;
    //    NSManagedObjectModel* model = context.persistentStoreCoordinator.managedObjectModel;
    //
    //    for (NSEntityDescription* entityDescription in [model entities]) {
    //        PFQuery *query = [PFQuery queryWithClassName:entityDescription.name];
    //
    //        if (!fullSync) {
    //            NSDate* lastSync = self.latestObjectSyncedDates[entityDescription.name];
    //            if (lastSync) {
    //                [query whereKey:@"updatedAt" greaterThan:lastSync];
    //            }
    //        }
    //        numberOfObjects += [query countObjects:&countError];
    //
    //        if (countError) {
    //            if(AP_DEBUG_ERRORS) ELog(@"Error counting: %@",countError);
    //            *error = countError;
    //            numberOfObjects = 0;
    //            continue;
    //        }
    //    }
    //    return numberOfObjects;
}


#pragma mark - Track Last Object Sync Date Methods

- (void) setEnvID:(NSString *)envID {
    [super setEnvID:envID];
    self.latestObjectSyncedKey = nil;
}

- (NSString*) latestObjectSyncedKey {
    
    if (!_latestObjectSyncedKey) {
        _latestObjectSyncedKey = [NSString stringWithFormat:@"%@.%@",APLatestObjectSyncedKey,self.envID ?:self.authenticatedUser.objectId];
    }
    return _latestObjectSyncedKey;
}


- (void) setLatestObjectSyncedDate: (NSDate*) date forEntityName: (NSString*) entityName {
    
    if (AP_DEBUG_METHODS) {MLog(@"Date: %@",date)}
    
    if ([[self.latestObjectSyncedDates[entityName] laterDate:date] isEqualToDate:date] || self.latestObjectSyncedDates[entityName] == nil) {
        self.latestObjectSyncedDates[entityName] = date;
    }
    [[NSUserDefaults standardUserDefaults]setObject:self.latestObjectSyncedDates forKey:self.latestObjectSyncedKey];
}


- (NSMutableDictionary*) latestObjectSyncedDates {
    
    if (!_latestObjectSyncedDates) {
        _latestObjectSyncedDates = [[[NSUserDefaults standardUserDefaults] objectForKey:self.latestObjectSyncedKey]mutableCopy] ?: [NSMutableDictionary dictionary];
    }
    return _latestObjectSyncedDates;
}

#pragma mark - Populating Objects

- (void) populateManagedObject:(NSManagedObject*) managedObject
     withSerializedParseObject:(NSDictionary*) parseObjectDictRepresentation
       onInsertedRelatedObject:(void(^)(NSManagedObject* insertedObject)) block {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    [[managedObject.entity propertiesByName]enumerateKeysAndObjectsUsingBlock:^(NSString* propertyName, NSPropertyDescription* propertyDesctiption, BOOL *stop) {
        
         NSError* localError = nil;
        
        if ([[parseObjectDictRepresentation allKeys]containsObject:propertyName]) {
            id parseObjectValue = [parseObjectDictRepresentation valueForKey:propertyName];
            id managedObjectValue;
            
            if ([parseObjectValue isEqual:[NSNull null]]) {
                managedObjectValue = nil;
                
            } else {
                
                if ([propertyDesctiption isKindOfClass:[NSAttributeDescription class]]) {
                    managedObjectValue = [parseObjectValue copy];
                    
                } else {
                    
                    NSRelationshipDescription* relationshipDescription = (NSRelationshipDescription*) propertyDesctiption;
                    
                    if (relationshipDescription.isToMany && [relationshipDescription existsAtParse]) {
                        
                        NSArray *relatedParseObjets = (NSArray*) parseObjectValue;
                        NSMutableSet* relatedManagedObjects = [[NSMutableSet alloc]initWithCapacity:[relatedParseObjets count]];
                        
                        for (NSDictionary* dictParseObject in relatedParseObjets) {
                            NSString* relatedObjectUID = [dictParseObject valueForKey:APObjectUIDAttributeName];
                            NSString* relatedObjectEntityName = [dictParseObject valueForKey:APObjectEntityNameAttributeName];
                            NSEntityDescription* relatedObjectEntity = [NSEntityDescription entityForName:relatedObjectEntityName inManagedObjectContext:managedObject.managedObjectContext];
                            if (!relatedObjectEntity) {
                                [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Entity %@ (Parse) isn't present in the Managed Object Model",relatedObjectEntityName];
                            }
                            
                            NSManagedObject* relatedManagedObject = [self managedObjectForObjectUID:relatedObjectUID entity:relatedObjectEntity inContext:managedObject.managedObjectContext createIfNecessary:NO error:&localError];
                            if (localError) {
                                if (AP_DEBUG_ERRORS) {ELog(@"Populating object with parse object %@",parseObjectDictRepresentation)}
                                *stop = YES;
                            }
                            
                            if (!relatedManagedObject) {
                                relatedManagedObject = [self managedObjectForObjectUID:relatedObjectUID entity:relatedObjectEntity inContext:managedObject.managedObjectContext createIfNecessary:YES error:&localError];
                                if (localError) {
                                    if (AP_DEBUG_ERRORS) {ELog(@"Populating object with parse object %@",parseObjectDictRepresentation)}
                                    *stop = YES;
                                }
                                
                                
                                [relatedManagedObject setValue:@YES forKeyPath:APObjectIsCreatedRemotelyAttributeName];
                                if (block) block(relatedManagedObject);
                            }
                            [relatedManagedObjects addObject:relatedManagedObject];
                        }
                        managedObjectValue = relatedManagedObjects;
                        
                    } else {
                        
                        // To-One relationship
                        
                        NSString* relatedObjectUID = [parseObjectValue valueForKey:APObjectUIDAttributeName];
                        NSString* relatedObjectEntityName = [parseObjectValue valueForKey:APObjectEntityNameAttributeName];
                        NSEntityDescription* relatedObjectEntity = [NSEntityDescription entityForName:relatedObjectEntityName inManagedObjectContext:managedObject.managedObjectContext];
                        
                        NSManagedObject* relatedManagedObject;
                        relatedManagedObject = [self managedObjectForObjectUID:relatedObjectUID entity:relatedObjectEntity inContext:managedObject.managedObjectContext createIfNecessary:NO error:&localError];
                        if (localError) {
                            if (AP_DEBUG_ERRORS) {ELog(@"Populating object with parse object %@",parseObjectDictRepresentation)}
                            *stop = YES;
                        }
                        
                        if (!relatedManagedObject) {
                            
                            relatedManagedObject = [self managedObjectForObjectUID:relatedObjectUID entity:relatedObjectEntity inContext:managedObject.managedObjectContext createIfNecessary:YES error:&localError];
                            if (localError) {
                                if (AP_DEBUG_ERRORS) {ELog(@"Populating object with parse object%@",parseObjectDictRepresentation)}
                                *stop = YES;
                            }
                            
                            [relatedManagedObject setValue:@YES forKeyPath:APObjectIsCreatedRemotelyAttributeName];
                            if (block) block(relatedManagedObject);
                        }
                        managedObjectValue = relatedManagedObject;
                    }
                }
            }
            
            [managedObject willChangeValueForKey:propertyName];
            [managedObject setPrimitiveValue:managedObjectValue forKey:propertyName];
            [managedObject didChangeValueForKey:propertyName];
              //[managedObject setValue:managedObjectValue forKey:propertyName];
        }
    }];
}


- (BOOL) populateParseObject:(PFObject*) parseObject
           withManagedObject:(NSManagedObject*) managedObject
                       error:(NSError *__autoreleasing*)error {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    NSMutableDictionary* mutableProperties = [[managedObject.entity propertiesByName]mutableCopy];
    
    // Remove properties that won't be sent to Parse
    [mutableProperties removeObjectForKey:APObjectLastModifiedAttributeName];
    [mutableProperties removeObjectForKey:APObjectIsDirtyAttributeName];
    [mutableProperties removeObjectForKey:APObjectIsCreatedRemotelyAttributeName];
    
    // Track the original entity from Core Data model, we use it when entity inheritance is being used.
    parseObject[APObjectEntityNameAttributeName] = managedObject.entity.name;
    
    parseObject[APObjectStatusAttributeName] = @(APObjectStatusPopulated);
    
    [mutableProperties enumerateKeysAndObjectsUsingBlock:^(NSString* propertyName, NSPropertyDescription* propertyDesctiption, BOOL *stop) {
        [managedObject willAccessValueForKey:propertyName];
        id propertyValue = [managedObject primitiveValueForKey:propertyName];
        [managedObject didAccessValueForKey:propertyName];
        //id propertyValue = [managedObject valueForKey:propertyName];
        
        
        if ([propertyDesctiption isKindOfClass:[NSAttributeDescription class]]) {
            NSAttributeDescription* attrDescription = (NSAttributeDescription*) propertyDesctiption;
            
            if ([propertyName isEqualToString:APCoreDataACLAttributeName]) {
                
                // Managed Object has an ACL attribute
                
                if (propertyValue) {
                    NSError* localError = nil;
                    if (![self addACLData:propertyValue toParseObject:parseObject error:&localError]) {
                        if (AP_DEBUG_ERRORS) {ELog(@"Error saving file to Parse: %@",localError)}
                        if (error) *error = localError;
                        *stop = YES;
                    }
                }
                
            } else {
                
                if (propertyValue == nil) {
                    [parseObject setValue:[NSNull null] forKey:propertyName];
                    
                } else {
                    
                    if (attrDescription.attributeType == NSBooleanAttributeType) {
                        [parseObject setValue:@([propertyValue boolValue]) forKey:propertyName];
                        
                    } else if (attrDescription.attributeType == NSBinaryDataAttributeType ||
                               attrDescription.attributeType == NSTransformableAttributeType) {
                        
                        // Binary
                        
                        PFFile* file = [PFFile fileWithData:propertyValue];
                        NSError* localError = nil;
                        
                        if (![file save:&localError]) {
                            if (AP_DEBUG_ERRORS) {ELog(@"Error saving file to Parse: %@",localError)}
                            if (error) *error = localError;
                            *stop = YES;
                        }
                        [parseObject setValue:file forKey:propertyName];
                        
                    } else {
                        [parseObject setValue:propertyValue forKey:propertyName];
                    }
                }
            }
            
        } else {
            
            // Relationships
            
            NSRelationshipDescription* relationshipDescription = (NSRelationshipDescription*) propertyDesctiption;
            
            if (relationshipDescription.isToMany) {
                
                if ([relationshipDescription existsAtParse]) {
                    NSSet* relatedManagedObjects = (NSSet*) propertyValue;
                    
                    if ([relationshipDescription isArrayAtParse]) {
                        NSMutableArray* relation = [[NSMutableArray alloc]initWithCapacity:[relatedManagedObjects count]];
                        
                        for (NSManagedObject* relatedManagedObject in relatedManagedObjects) {
                            NSError* localError = nil;
                            PFObject* relatedParseObject = [self parseObjectFromManagedObject:relatedManagedObject error:&localError];
                            if (localError) {
                                if (error) *error = localError;
                                *stop = YES;
                            }
                            [relation addObject:relatedParseObject];
                        }
                        [parseObject setObject:relation forKey:propertyName];
                        
                    } else if ([relationshipDescription isRelationAtParse]) {
                        
                        /*
                         Would be nice if there was a method to empty a relationship easiser or check
                         what objects are in the relation without querying Parse.
                         The only way I was able to make it work was to query all objects and
                         remove them one by one... awesome!
                         */
                        
                        PFRelation* relation = [parseObject relationForKey:propertyName];
                        
                        if (parseObject.objectId) {
                            NSError* localError = nil;
                            NSArray* currentObjectsInParseRelation = [[relation query]findObjects:&localError];
                            if (localError) { *error = localError; return;}
                            [currentObjectsInParseRelation enumerateObjectsUsingBlock:^(PFObject* currentRelatedParseObject, NSUInteger idx, BOOL *stop) {
                                [relation removeObject:currentRelatedParseObject];
                            }];
                        }
                        
                        /*
                         Now fetch the equivalent Parse object from the local related managed object
                         and add them all to the parse relation
                         */
                        for (NSManagedObject* relatedManagedObject in relatedManagedObjects) {
                            NSError* localError = nil;
                            PFObject* relatedParseObject = [self parseObjectFromManagedObject:relatedManagedObject error:&localError];
                            if (localError) {
                                if (error) *error = localError;
                                *stop = YES;
                            }
                            [relation addObject:relatedParseObject];
                        }
                        
                    } else {
                        NSAssert(NO, @"Wasn't supposed to be here");
                    }
                }
                
            } else {
                
                // To-One relationship
                
                NSManagedObject* relatedManagedObject = (NSManagedObject*) propertyValue;
                
                if (!relatedManagedObject) {
                    [parseObject setValue:[NSNull null] forKey:propertyName];
                    
                } else {
                    NSError* localError = nil;
                    PFObject* relatedParseObject = [self parseObjectFromManagedObject:relatedManagedObject error:&localError];
                    if (localError){
                        if (error) *error = localError;
                        *stop = YES;
                    }
                    [parseObject setValue:relatedParseObject ?: [NSNull null] forKey:propertyName];
                }
                
            }
        }
        
    }];

    return (*error) ? NO : YES;
}


- (BOOL) addACLData:(NSData*) ACLData
      toParseObject:(PFObject*) object
              error:(NSError *__autoreleasing*)error {
    
    BOOL success = YES;
    NSError* localError = nil;
    
    NSDictionary* dictACL = [NSJSONSerialization JSONObjectWithData:ACLData options:0 error:&localError];
    if (localError) {
        if (AP_DEBUG_ERRORS) {ELog(@"Error saving file to Parse: %@",localError)}
        if (error) *error = localError;
        success = NO;
        
    } else {
        PFACL* ACL = object.ACL ?: [PFACL ACL];
        [dictACL enumerateKeysAndObjectsUsingBlock:^(NSString* who, NSDictionary* privileges, BOOL *stop) {
            BOOL writeAccess = [privileges[@"write"] isEqualToString:@"true"];
            BOOL readAccess = [privileges[@"read"] isEqualToString:@"true"];
            
            NSString* rolePrefix = @"role:";
            if ([who hasPrefix:rolePrefix]) {
                NSString* roleName = [who stringByReplacingOccurrencesOfString:rolePrefix withString:@""];
                if (privileges[@"read"]) [ACL setReadAccess:readAccess forRoleWithName:roleName];
                if (privileges[@"write"]) [ACL setWriteAccess:writeAccess forRoleWithName:roleName];
            } else {
                if (privileges[@"read"]) [ACL setReadAccess:readAccess forUserId:who];
                if (privileges[@"write"]) [ACL setWriteAccess:writeAccess forUserId:who];
            }
        }];
        object.ACL = ACL;
    }
    return success;
}


- (BOOL) insertOnParseManagedObject:(NSManagedObject*) managedObject
                              error:(NSError *__autoreleasing*)error {
    
    NSError* localError = nil;
    BOOL success = YES;
    
    NSEntityDescription* rootEntity = [self rootEntityFromEntity:managedObject.entity];
    PFObject* parseObject = [[PFObject alloc]initWithClassName:rootEntity.name];
    [self populateParseObject:parseObject withManagedObject:managedObject error:&localError];
    
    if (!localError) {
        
        if ([parseObject save:&localError]) {
            
            /* Parse sets the objectId and updatedAt for a new object only after we save it. */
            [managedObject setValue:parseObject.updatedAt forKey:APObjectLastModifiedAttributeName];
            [managedObject setValue:@YES forKey:APObjectIsCreatedRemotelyAttributeName];
            
        } else {
            if (error) *error = localError;
            success = NO;
        }
    }
    
    return success;
}


#pragma mark - Getting Parse Objects

- (PFObject*) parseObjectFromManagedObject:(NSManagedObject*) managedObject
                                     error:(NSError *__autoreleasing*)error {
    
    PFObject* parseObject;
    NSError* localError = nil;
    
    NSString* relatedObjectUID = [managedObject valueForKey:APObjectUIDAttributeName];
    NSEntityDescription* rootEntity = [self rootEntityFromEntity:managedObject.entity];
    
    if ([[managedObject valueForKey:APObjectIsCreatedRemotelyAttributeName]isEqualToNumber:@NO]) {
        parseObject = [PFObject objectWithClassName:rootEntity.name];
        [parseObject setValue:relatedObjectUID forKey:APObjectUIDAttributeName];
        [parseObject setValue:managedObject.entity.name forKey:APObjectEntityNameAttributeName];
        [parseObject setValue:@(APObjectStatusCreated) forKey:APObjectStatusAttributeName];
        
        [parseObject save:&localError];
        if (localError) {
            if (error) *error = localError;
            return nil;
        }
        [managedObject setValue:parseObject.updatedAt forKey:APObjectLastModifiedAttributeName];
        [managedObject setValue:@YES forKey:APObjectIsCreatedRemotelyAttributeName];
        
    } else {
        parseObject = [self parseObjectFromEntity:managedObject.entity objectUID:relatedObjectUID error:&localError];
        if (localError) {
            if (error) *error = localError;
            return nil;
        }
    }
    
    return parseObject;
}


- (PFObject*) parseObjectFromEntity:(NSEntityDescription*) entity
                          objectUID: (NSString*) objectUID
                              error:(NSError *__autoreleasing*)error {
    
    if (AP_DEBUG_METHODS) {MLog(@"Class:%@ - ObjectUID: %@",entity.name,objectUID)}
    
    PFObject* parseObject;
    NSEntityDescription* rootEntity = [self rootEntityFromEntity:entity];
    PFQuery* query = [PFQuery queryWithClassName:rootEntity.name];
    [query setCachePolicy:kPFCachePolicyNetworkOnly];
    [query whereKey:APObjectUIDAttributeName equalTo:objectUID];
    [query whereKey:APObjectEntityNameAttributeName equalTo:entity.name];
    
    /* Fetch related objects when the relation is flagged as a Array via core data model metadata. */
    [entity.relationshipsByName enumerateKeysAndObjectsUsingBlock:^(NSString* relationName, NSRelationshipDescription* relationDescription, BOOL *stop) {
        NSString* relationshipType = relationDescription.userInfo[APParseRelationshipTypeUserInfoKey];
        if ((relationshipType && [relationshipType integerValue] == APParseRelationshipTypeArray) || [relationDescription isToMany] == NO) {
            [query includeKey:relationName];
        }
    }];
    
    if ([query hasCachedResult]) {[query clearCachedResult];}
    
    NSError* localError = nil;
    NSArray* results = [query findObjects:&localError];
    
    if (localError) {
        if (AP_DEBUG_ERRORS) {ELog(@"Error finding objects at Parse: %@",localError)}
        if (error) *error = localError;
        return nil;
        
    } else if ([results count] > 1) {
        if (AP_DEBUG_ERRORS) {ELog(@"Error - WTF?? more than one object with the objectUID: %@",objectUID)}
        if (error) *error = [NSError errorWithDomain:APIncrementalStoreErrorDomain code:APIncrementalStoreErrorSyncOperationDuplicatedObjectUID userInfo:@{APObjectUIDAttributeName:objectUID}];
        return nil;
        
    } else if ([results count] == 0) {
        if (AP_DEBUG_ERRORS) {ELog(@"Error - There's no existing object using the objectUID: %@",objectUID)}
        if (error) *error = [NSError errorWithDomain:APIncrementalStoreErrorDomain code:APIncrementalStoreErrorSyncOperationObjectUIDNotFound userInfo:@{APObjectUIDAttributeName:objectUID}];
        return nil;
        
    } else {
        parseObject = [results lastObject];
    }
    return parseObject;
}


#pragma mark - Getting Managed Objects

- (NSArray*) managedObjectsMarkedAsDirtyInContext: (NSManagedObjectContext *)context {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    __block NSError* error = nil;
    __block NSMutableArray* dirtyManagedObjects = [NSMutableArray array];
    
    NSArray* allEntities = context.persistentStoreCoordinator.managedObjectModel.entities;
    
    [allEntities enumerateObjectsUsingBlock:^(NSEntityDescription* entity, NSUInteger idx, BOOL *stop) {
        NSFetchRequest* request = [NSFetchRequest fetchRequestWithEntityName:entity.name];
        request.predicate = [NSPredicate predicateWithFormat:@"%K == YES",APObjectIsDirtyAttributeName];
        
        __block NSArray* entityDirtyObjects;
        
        NSError* fetchingError = nil;
        entityDirtyObjects = [context executeFetchRequest:request error:&fetchingError];
        if (fetchingError) {
            error = fetchingError;
        }
        
        
        [entityDirtyObjects enumerateObjectsUsingBlock:^(NSManagedObject* obj, NSUInteger idx, BOOL *stop) {
            
            /*
             For each object we need to check if it belongs to the entity we are fetching or
             it's a subclass of it and therefore will be included in the dirtyManagedObjects when
             the enumeration reaches that class.
             */
            
            if ([obj.entity.name isEqualToString:entity.name]) {
                [dirtyManagedObjects addObject:obj];
            }
        }];
    }];
    
    if (!error) {
        return dirtyManagedObjects;
        
    } else {
        if (AP_DEBUG_ERRORS) {ELog(@"Error: %@",error)}
        return nil;
    }
}


- (NSManagedObject*) managedObjectForObjectUID:(NSString*) objectUID
                                        entity:(NSEntityDescription*) entity
                                     inContext:(NSManagedObjectContext*) context
                             createIfNecessary:(BOOL) createIfNecessary
                                         error:(NSError *__autoreleasing*)error {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    NSManagedObject* managedObject = nil;
    
    NSFetchRequest* fr = [NSFetchRequest fetchRequestWithEntityName:entity.name];
    fr.predicate = [NSPredicate predicateWithFormat:@"%K == %@",APObjectUIDAttributeName,objectUID];
    
    
    NSError* localError = nil;
    NSArray* fetchResults = [context executeFetchRequest:fr error:&localError];
    if (localError) {
        if (error) *error = localError;
        return nil;
    }
    
    if ([fetchResults count] > 1) {
        [NSException raise:APIncrementalStoreExceptionInconsistency format:@"More than one cached result for parse object"];
        
    } else if ([fetchResults count] == 0) {
        
        if (createIfNecessary) {
            managedObject = [NSEntityDescription insertNewObjectForEntityForName:entity.name inManagedObjectContext:context];
            [managedObject setValue:objectUID forKey:APObjectUIDAttributeName];
            
            [context performBlockAndWait:^{
                NSError* permanentIdError = nil;
                [context obtainPermanentIDsForObjects:@[managedObject] error:&permanentIdError];
                // Sanity check
                if (permanentIdError) {
                    [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Could not obtain permanent IDs for objects %@ with error %@", managedObject, permanentIdError];
                }
            }];
            
        }
        
    } else {
        managedObject = [fetchResults lastObject];
    }
    
    return managedObject;
}


- (NSDictionary*) serializeParseObject:(PFObject*) parseObject
                             forEntity:(NSEntityDescription*) entity
                                 error:(NSError* __autoreleasing*) error {
    
    if (AP_DEBUG_METHODS) { MLog()};
    
    __block NSError* localError = nil;
    
    NSMutableDictionary* dictionaryRepresentation = [NSMutableDictionary dictionary];
    [[parseObject allKeys] enumerateObjectsUsingBlock:^(id key, NSUInteger idx, BOOL *stop) {
        
        id value = [parseObject valueForKey:key];
        
        if ([value isKindOfClass:[PFRelation class]]) {
            
            /*
             In order to optimize the sync processm there are two scenarios where we don't need
             to populate this relation when:
             
             1) The PFRelation is part of the root entity so that doesn't belong to this entity.
             This happens because Parse doesn't send not populated properties along with the
             fetched objects, which works great for inheritance and allows us to use only the
             root class to store all subclasses at Parse. The exception is for PFRelations, even
             being NULL Parse put it in the object. So we have to discaard it.
             
             2) The inverse relation is To-One
             
             3) The inverse is a Array. Here we can't differentiate solely evaluating our core
             data model and tell if the inverse relation is a Array or a PFRelation.
             For that reason if the core data model has a key APParseRelationshipTypeUserInfoKey
             set with APParseRelationshipTypeArray we assume that Parse has a relation as the inverse
             relationship, therefore we can skip populating this relation.
             
             */
            BOOL needToPopulateRelation = YES;
            NSRelationshipDescription* relationshipDescription = entity.propertiesByName[key];
            
            if (![relationshipDescription isKindOfClass:[NSRelationshipDescription class]]) {
                // 1
                needToPopulateRelation = NO;
                
            } else if (![relationshipDescription.inverseRelationship isToMany]) {
                // 2
                needToPopulateRelation = NO;
                
            } else if ([relationshipDescription.inverseRelationship isArrayAtParse]) {
                // 3
                needToPopulateRelation = NO;
            }
            
            if (needToPopulateRelation) {
                // To-Many relationsship (need to create an Array of Dictionaries including only the ObjectId
                
                PFRelation* relation = (PFRelation*) value;
                PFQuery* queryForRelatedObjects = [relation query];
                [queryForRelatedObjects selectKeys:@[APObjectUIDAttributeName,APObjectEntityNameAttributeName]];
                
                NSArray* results = [queryForRelatedObjects findObjects:&localError];
                
                if (localError) {
                    *stop = YES;
                    ELog(@"Error getting objects from To-Many relationship %@from Parse: %@",key,localError);
                    
                } else {
                    NSMutableArray* relatedObjects = [[NSMutableArray alloc]initWithCapacity:[results count]];
                    
                    for (PFObject* relatedParseObject in results) {
                        if (!relatedParseObject[APObjectUIDAttributeName]) {
                            [NSException raise:APIncrementalStoreExceptionInconsistency format:@"%@ is missing APObjectUIDAttributeName", parseObject];
                        }
                        if (!relatedParseObject[APObjectEntityNameAttributeName]) {
                            [NSException raise:APIncrementalStoreExceptionInconsistency format:@"%@ is missing APObjectEntityNameAttributeName",parseObject];
                        }
                        [relatedObjects addObject:@{APObjectUIDAttributeName: relatedParseObject[APObjectUIDAttributeName],
                                                    APObjectEntityNameAttributeName: relatedParseObject[APObjectEntityNameAttributeName]}];
                    }
                    
                    dictionaryRepresentation[key] = relatedObjects;
                }
            }
            
        } else if ([value isKindOfClass:[NSArray class]]) {
            // To-Many relationsship (need to create an Array of Dictionaries including only the ObjectUId
            NSMutableArray* relatedObjects = [[NSMutableArray alloc]initWithCapacity:[value count]];
            
            for (PFObject* relatedParseObject in value) {
                
                // An empty Array can have NSNull objects...
                if ([relatedParseObject isKindOfClass:[PFObject class]]) {
                    
                    //if (!relatedParseObject[APObjectUIDAttributeName]) {
                    if (![[relatedParseObject allKeys] containsObject:APObjectUIDAttributeName]) {
                        [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Parse object %@ has a related object %@ missing mandatory APIncrementalStore control property APObjectUIDAttributeName",parseObject, relatedParseObject];
                    }
                    //if (!relatedParseObject[APObjectEntityNameAttributeName]) {
                      if (![[relatedParseObject allKeys] containsObject:APObjectEntityNameAttributeName]) {
                          [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Parse object %@ has a related object %@ is missing mandatory APIncrementalStore control property APObjectEntityNameAttributeName",parseObject, relatedParseObject];
                    }
                    [relatedObjects addObject:@{APObjectUIDAttributeName: relatedParseObject[APObjectUIDAttributeName],
                                                APObjectEntityNameAttributeName: relatedParseObject[APObjectEntityNameAttributeName]}];
                }
            }
            
            dictionaryRepresentation[key] = relatedObjects;
            
        } else if ([value isKindOfClass:[PFFile class]]) {
            PFFile* file = (PFFile*) value;
            NSData* fileData = [file getData:&localError];
            if (localError) {
                *stop = YES;
                ELog(@"Error getting file from Parse: %@",localError);
            } else {
                dictionaryRepresentation[key] = fileData;
            }
            
        } else if ([value isKindOfClass:[PFObject class]]) {
            
            // To-One relationship
            
            PFObject* relatedParseObject = (PFObject*) value;
            
            if (localError) {
                
                // Shit happened
                
                *stop = YES;
                ELog(@"Error getting parse object for To-One relationship %@ from Parse: %@",key,localError);
            
            } else if (relatedParseObject[APObjectUIDAttributeName] == nil || relatedParseObject[APObjectEntityNameAttributeName] == nil) {
                
                // Missing things
                
                *stop = YES;
                NSString* errorDescription = [NSString stringWithFormat:@"Missing mandatory APIncrementalStore control values (APObjectUIDAttributeName or APObjectEntityNameAttributeName for remote object %@",relatedParseObject];
                localError = [NSError errorWithDomain:APIncrementalStoreErrorDomain code:APIncrementalStoreErrorCodeMergingRemoteObjects userInfo:@{NSLocalizedDescriptionKey:errorDescription}];
                ELog(@"%@",localError);
            
            } else {
                
                // All good
                
                dictionaryRepresentation[key] = @{APObjectUIDAttributeName:relatedParseObject[APObjectUIDAttributeName],
                                                  APObjectEntityNameAttributeName:relatedParseObject[APObjectEntityNameAttributeName]};
            }
            
        } else if ([value isKindOfClass:[PFACL class]]) {
            
            // Object ACL
            
            /*
             PFACL object doesn't show which users/roles are associated with it,
             unless you know it IDs/RoleNames beforehand.
             I haven't figured out a way to extract that information to enable the serialization
             of that into the managed object.
             Via REST it is possible to see it, I'm trying to stay away from interacting via REST at the moment...
             */
            
        } else {
            
            // Property
            
            dictionaryRepresentation[key] = value;
        }
    }];
    
    dictionaryRepresentation[APObjectLastModifiedAttributeName] = parseObject.updatedAt;
    
    if (dictionaryRepresentation[APObjectUIDAttributeName] == nil ||
        dictionaryRepresentation[APObjectEntityNameAttributeName] == nil ||
        dictionaryRepresentation[APObjectLastModifiedAttributeName] == nil ||
        dictionaryRepresentation[APObjectStatusAttributeName] == nil) {
        
        [NSException raise:APIncrementalStoreExceptionInconsistency format:@"%@ is an incompatible object, please ensure all objects imported have the mandatory APIncrementalStore attributes set",parseObject];
    }
    if (!localError) {
        return dictionaryRepresentation;
    } else {
        if (error) *error = localError;
        return nil;
    }
}


#pragma mark - Save Context

- (void) configSaveContextObserver {
    
    [[NSNotificationCenter defaultCenter]addObserverForName: NSManagedObjectContextDidSaveNotification object:self.context queue:nil usingBlock:^(NSNotification *note) {
        
        [note.userInfo enumerateKeysAndObjectsUsingBlock:^(id key, NSArray* managedObjects, BOOL *stop) {
            
            [managedObjects enumerateObjectsUsingBlock:^(NSManagedObject* managedObject, NSUInteger idx, BOOL *stop) {
                NSString* objectUID = [managedObject valueForKey:APObjectUIDAttributeName];
                if (![self isObjectUID:objectUID includedForEntityName:managedObject.entity.name]){
                    
                    NSMutableDictionary* relatedEntityEntry = self.mergedObjectsUIDsNestedByEntityName[managedObject.entity.name] ?: [NSMutableDictionary dictionary];
                    NSArray* mergedObjectUIDs = relatedEntityEntry[key] ?: [NSArray new];
                    
                    relatedEntityEntry[key] = [mergedObjectUIDs arrayByAddingObject:objectUID];
                    self.mergedObjectsUIDsNestedByEntityName[managedObject.entity.name] = relatedEntityEntry;
                }
            }];
        }];
    }];
}


- (BOOL) isObjectUID:(NSString*) objectUID includedForEntityName:(NSString*) entityName {
    
    NSMutableDictionary* relatedEntityEntry = self.mergedObjectsUIDsNestedByEntityName[entityName];
    if ([relatedEntityEntry[NSInsertedObjectsKey] containsObject:objectUID]) {
        return YES;
    
    } else if ([relatedEntityEntry[NSUpdatedObjectsKey] containsObject:objectUID]) {
        return YES;
    
    } else if ([relatedEntityEntry[NSDeletedObjectsKey] containsObject:objectUID]) {
        return YES;
    
    }
    return NO;
}


- (BOOL) saveAndResetContext:(NSError *__autoreleasing*) error {
    
    __block BOOL success = YES;
    __block NSError* localError = nil;
    
    [self.context performBlockAndWait:^{
        
        if ([self.context hasChanges]) {
            
            if (![self.context save:&localError]) {
                if (AP_DEBUG_ERRORS) {ELog(@"Error saving sync context changes: %@",localError)}
                success = NO;
                if (error) *error = localError;
                
            } else {
                //[self.context reset];
            }
        }
    }];
    return success;
}


#pragma mark - Util Methods

- (NSEntityDescription*) rootEntityFromEntity: (NSEntityDescription*) entity {
    
    NSEntityDescription* rootEntity;
    
    if ([entity superentity]) {
        rootEntity = [self rootEntityFromEntity:[entity superentity]];
    } else {
        rootEntity = entity;
    }
    return rootEntity;
}


- (NSDate*) getParseServerTime: (NSError*__autoreleasing*) error {
    
    NSError* localError = nil;
    NSDate* parseServerTime = [PFCloud callFunction:@"getTime" withParameters:@{} error:&localError];
    
    if (localError) {
        if ([localError.domain isEqualToString:@"Parse"] && localError.code == kPFScriptError) {
            
            if ([localError.userInfo[@"error"] isEqualToString:@"function not found"]) {
                NSString* msg = @"You likely don't have Parse Cloud Code configured properly, add a method named \"getTime\" in order to enable APIncrementalStore to retrieve Parse time. Check https://github.com/flavionegrao/APIncrementalStore how to set it up correctly.";
                [NSException raise:APIncrementalStoreExceptionInconsistency format:@"%@",msg];
                
            } else {
                if (error) *error = localError;
                return nil;
            }
            
        } else {
            if (error) *error = localError;
            return nil;
        }
    }
    
    return parseServerTime;
}


- (BOOL) isUserAuthenticated:(NSError*__autoreleasing*) error {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    if (![self.authenticatedUser isAuthenticated]) {
        if (error) {
            *error = [NSError errorWithDomain:APIncrementalStoreErrorDomain code:APIncrementalStoreErrorCodeUserCredentials userInfo:nil];
        }
        return NO;
        
    } else {
        return YES;
    }
}


@end
