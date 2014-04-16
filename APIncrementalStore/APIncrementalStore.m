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


#import "APIncrementalStore.h"

#import "APLocalCache.h"
#import "APParseConnector.h"

#import "NSArray+Enumerable.h"
#import "Common.h"
#import "APError.h"
#import "NSLogEmoji.h"


#pragma mark - Notifications

/********************
/ Sync Notifications
********************/

NSString* const APNotificationRequestCacheSync = @"APNotificationRequestCacheSync";
NSString* const APNotificationRequestCacheFullSync = @"APNotificationRequestCacheFullSync";

NSString* const APNotificationCacheWillStartSync = @"APNotificationCacheWillStartSync";
NSString* const APNotificationCacheDidStartSync = @"APNotificationCacheDidStartSync";
NSString *const APNotificationCacheDidSyncObject = @"APNotificationCacheDidSyncObject";
NSString* const APNotificationCacheDidFinishSync = @"APNotificationCacheDidFinishSync";

NSString *const APNotificationCacheNumberOfLocalObjectsKey = @"APNotificationCacheNumberOfLocalObjectsKey";
NSString *const APNotificationCacheNumberOfRemoteObjectsKey = @"APNotificationCacheNumberOfRemoteObjectsKey";
NSString* const APNotificationObjectsIDsKey = @"APNotificationObjectsIDsKey";


/**************************
/ Cache Reset Notifications
***************************/

NSString* const APNotificationCacheRequestReset = @"APNotificationCacheRequestReset";
NSString* const APNotificationCacheDidFinishReset = @"APNotificationCacheDidFinishReset";


#pragma mark - Incremental Store Options

NSString* const APOptionAuthenticatedUserObjectKey = @"APOptionAuthenticatedUserObject";
NSString* const APOptionCacheFileNameKey = @"APOptionCacheFileName";
NSString* const APOptionCacheFileResetKey = @"APOptionCacheFileReset";

NSString* const APOptionMergePolicyKey = @"APIncrementalStoreOptionMergePolicy";
NSString* const APOptionMergePolicyServerWins = @"APIncrementalStoreMergePolicyServerWins";
NSString* const APOptionMergePolicyClientWins = @"APIncrementalStoreMergePolicyClientWins";


#pragma mark - Local Constants
static NSString* const APDefaultLocalCacheFileName = @"APIncrementalStoreCache.sqlite";

// mapBetweenObjectIDsAndObjectUUIDByEntityName Keys
static NSString* const APNSManagedObjectIDKey = @"APNSManagedObjectIDKey";
static NSString* const APReferenceCountKey = @"APReferenceCountKey";



@interface APIncrementalStore ()

@property (nonatomic,strong) APLocalCache* localCache;
@property (nonatomic,strong) NSString* localCacheFileName;
@property (nonatomic,assign) BOOL shouldResetCacheFile;
@property (nonatomic,strong) id <APRemoteDBConnector> remoteDBConnector;
@property (nonatomic,strong) NSManagedObjectModel* model;


/*
 referenceCount: indicates how many managed object context are using the object identified by object IDs.
 See: managedObjectContextDidUnregisterObjectsWithIDs: and managedObjectContextDidRegisterObjectsWithIDs:
 
 Structure is as follows:

 {
    Entity1: {
                objectUUID: {
                                kAPNSManagedObjectIDKey: objectID,
                                kAPReferenceCountKey: referenceCount
                            },
                            {   
                                objectUUID: {kAPNSManagedObjectIDKey: objectID,
                                kAPReferenceCountKey: referenceCount
                            },
                            ...
            },
    Entity2: {
                objectUUID: {
                                kAPNSManagedObjectIDKey: objectID,
                                kAPReferenceCountKey: referenceCount
                            },
                objectUUID: {
                                kAPNSManagedObjectIDKey: objectID,
                                kAPReferenceCountKey: referenceCount},
            },
    ...
 }
 */
@property (nonatomic, strong) NSMutableDictionary *mapBetweenObjectIDsAndObjectUUIDByEntityName;

@end


@implementation APIncrementalStore


#pragma mark - Setup and Takedown

- (id)initWithPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)psc
                       configurationName:(NSString *)name
                                     URL:(NSURL *)url
                                 options:(NSDictionary *)options {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    self = [super initWithPersistentStoreCoordinator:psc configurationName:name URL:url options:options];
    
    if (self) {
        
        _model = psc.managedObjectModel;
        
        [self registerForNotifications];
        
        NSString* localCacheFileName = [options valueForKey:APOptionCacheFileNameKey];
        _localCacheFileName = localCacheFileName ?: APDefaultLocalCacheFileName;
        
        if ([[options valueForKey:APOptionCacheFileResetKey] isEqualToNumber:@YES]){
            _shouldResetCacheFile = YES;
        }
        
        id authenticatedUser = [options valueForKey:APOptionAuthenticatedUserObjectKey];
        if (!authenticatedUser) {
            if (AP_DEBUG_ERRORS) {ELog(@"Authenticated user is not set")}
            return nil;
        }
        
        _remoteDBConnector = [[APParseConnector alloc]initWithAuthenticatedUser:authenticatedUser mergePolicy:APMergePolicyClientWins];
        
        if (![_remoteDBConnector conformsToProtocol:@protocol(APRemoteDBConnector)]) {
            [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Object not complatible with APIncrementalStoreConnector protocol"];
        }
    }
    return self;
}


- (void)dealloc {
    
    if (AP_DEBUG_METHODS) { MLog()}
    [self unregisterForNotifications];
}


#pragma mark - Notification Observation

- (void)registerForNotifications {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveSyncNotifcation:) name:APNotificationRequestCacheSync object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveFullSyncNotifcation:) name:APNotificationRequestCacheFullSync object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveResetCacheNotifcation:) name:APNotificationCacheRequestReset object:nil];
}


- (void)unregisterForNotifications {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:APNotificationRequestCacheSync object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:APNotificationRequestCacheFullSync object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:APNotificationCacheRequestReset object:nil];
}


#pragma mark - Getters and Setters

- (APLocalCache*) localCache {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    if (!_localCache) {
        
        __weak  typeof(self) weakSelf = self;
        NSString* (^translateBlock)(NSManagedObjectID*) = ^NSString* (NSManagedObjectID* objectID) {
            return [weakSelf referenceObjectForObjectID:objectID];
        };
        
        _localCache = [[APLocalCache alloc]initWithManagedModel:self.model
                                      translateToObjectUIDBlock:translateBlock
                                             localStoreFileName:self.localCacheFileName
                                           shouldResetCacheFile:self.shouldResetCacheFile
                                              remoteDBConnector:self.remoteDBConnector];
    }
    return _localCache;
}


- (NSMutableDictionary*) mapBetweenObjectIDsAndObjectUUIDByEntityName {
    
    if (!_mapBetweenObjectIDsAndObjectUUIDByEntityName) {
        _mapBetweenObjectIDsAndObjectUUIDByEntityName = [NSMutableDictionary dictionary];
    }
    return _mapBetweenObjectIDsAndObjectUUIDByEntityName;
}


#pragma mark - NSIncrementalStore Subclass Methods

- (BOOL)loadMetadata:(NSError *__autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    [self setMetadata:@{NSStoreUUIDKey: [[NSProcessInfo processInfo] globallyUniqueString],
                        NSStoreTypeKey: NSStringFromClass([self class])}];
    return YES;
}


+ (NSString*) type {
    if (AP_DEBUG_METHODS) { MLog()}
    return NSStringFromClass([self class]);
}


/*
 Returns an incremental store node encapsulating the persistent external values of the object with a given object ID.
 Return Value:  An incremental store node encapsulating the persistent external values of the object with object ID objectID, or nil if the corresponding object cannot be found.
 
 Discussion:    The returned node should include all attributes values and may include to-one relationship values as instances of NSManagedObjectID.
                If an object with object ID objectID cannot be found, the method should return nil and—if error is not NULL—create and return an appropriate error object in error.
 
 This method is used in 2 scenarios: When an object is fulfilling a fault, and before a save on updated objects to grab a copy from the server for merge conflict purposes.
 */
- (NSIncrementalStoreNode *)newValuesForObjectWithID:(NSManagedObjectID *)objectID
                                         withContext:(NSManagedObjectContext *)context
                                               error:(NSError **)error {
    if (AP_DEBUG_METHODS) { MLog()}
    
    if (AP_DEBUG_INFO) {DLog(@"new values for object with id %@", [context objectWithID:objectID])}
    
    NSString* objectUID = [self referenceObjectForObjectID:objectID];
    NSDictionary *objectFromCache = [self.localCache fetchObjectRepresentationForObjectUUID:objectUID entityName:objectID.entity.name];
    
    if (!objectFromCache) {
        [NSException raise:APIncrementalStoreExceptionIncompatibleRequest format:@"Cache object with managed objectUID %@ not found.", objectUID];
    }
    
    // Create dictionary of keys and values for incremental store node
    NSMutableDictionary *dictionaryRepresentationOfCacheObject = [NSMutableDictionary dictionary];
    
    // Attributes
    NSArray* entityAttributes = [[[objectID entity] attributesByName] allKeys];
    [[objectFromCache dictionaryWithValuesForKeys:entityAttributes] enumerateKeysAndObjectsUsingBlock:^(id attributeName, id attributeValue, BOOL *stop) {
        if (attributeValue != [NSNull null]) {
            dictionaryRepresentationOfCacheObject[attributeName] = attributeValue;
        }
    }];
    
    // To-One relationships
    NSArray* entityRelationships = [[[objectID entity] relationshipsByName] allKeys];
    [[objectFromCache dictionaryWithValuesForKeys:entityRelationships] enumerateKeysAndObjectsUsingBlock:^(id relationshipName, id relationshipValue, BOOL *stop) {
        
        if (![[[objectID entity]relationshipsByName][relationshipName] isToMany]) {
            
            if (relationshipValue == [NSNull null] || relationshipValue == nil) {
                dictionaryRepresentationOfCacheObject[relationshipName] = [NSNull null];
                
            } else {
                NSRelationshipDescription* relationship = [[objectID entity] relationshipsByName][relationshipName];
                NSManagedObjectID *relationshipObjectID = [self managedObjectIDForEntity:relationship.destinationEntity withObjectUUID:relationshipValue];
                dictionaryRepresentationOfCacheObject[relationshipName] = relationshipObjectID;
            }
        }
    }];
    NSIncrementalStoreNode *node = [[NSIncrementalStoreNode alloc] initWithObjectID:objectID withValues:dictionaryRepresentationOfCacheObject version:1];
    return node;
}


/*
 Return Value
 The value of the relationship specified relationship of the object with object ID objectID, or nil if an error occurs.
 
 Discussion
 If the relationship is a to-one, the method should return an NSManagedObjectID instance that identifies the destination, or an instance of NSNull if the relationship value is nil.
 
 If the relationship is a to-many, the method should return a collection object containing NSManagedObjectID instances to identify the related objects. Using an NSArray instance is preferred because it will be the most efficient. A store may also return an instance of NSSet or NSOrderedSet; an instance of NSDictionary is not acceptable.
 
 If an object with object ID objectID cannot be found, the method should return nil and—if error is not NULL—create and return an appropriate error object in error.
 */
- (id)newValueForRelationship:(NSRelationshipDescription *)relationship
              forObjectWithID:(NSManagedObjectID *)objectID
                  withContext:(NSManagedObjectContext *)context
                        error:(NSError * __autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    NSString* objectUUID = [self referenceObjectForObjectID:objectID];
    
    NSFetchRequest *fr = [[NSFetchRequest alloc] initWithEntityName:objectID.entity.name];
    fr.predicate = [NSPredicate predicateWithFormat:@"%K == %@", APObjectUIDAttributeName, objectUUID];
    
    NSError *fetchError = nil;
    NSArray *results = [self.localCache fetchObjectRepresentations:fr error:&fetchError];
    
    if (fetchError || [results count] > 1) {
        // TODO handle error
    }
    
    NSManagedObject *objectFromCache = [results lastObject];
    
    if (!objectFromCache) {
        [NSException raise:APIncrementalStoreExceptionIncompatibleRequest format:@"Cache object with managed objectUUID %@ not found.", objectUUID];
    }
    
    if ([relationship isToMany]) {
        
        // to-many: pull related object set from cache
        // value should be the cache object reference for the related object, if the relationship value is not nil
        
        __block NSMutableArray *arrayToReturn = [NSMutableArray array];
        
        NSArray *relatedObjectCacheReferenceSet = [[objectFromCache valueForKey:[relationship name]] allObjects];
        if ([relatedObjectCacheReferenceSet count] > 0) {
            
            [relatedObjectCacheReferenceSet enumerateObjectsUsingBlock:^(id cacheManagedObjectReference, NSUInteger idx, BOOL *stop) {
                
                NSManagedObjectID *managedObjectID = [self managedObjectIDForEntity:[relationship destinationEntity] withObjectUUID:cacheManagedObjectReference];
                [arrayToReturn addObject:managedObjectID];
            }];
        }
        
        return arrayToReturn;
        
    } else {
        
        // to-one: pull related object from cache
        // value should be the cache object reference for the related object, if the relationship value is not nil
        
        NSManagedObject *relatedObjectCacheReferenceObject = [objectFromCache valueForKey:[relationship name]];
        
        if (!relatedObjectCacheReferenceObject) {
            
            return [NSNull null];
            
        } else {
            
            // If primary key includes the nil string, this was just a reference and we need to retreive online, if possible
            NSString *relatedObjectUUID = [relatedObjectCacheReferenceObject valueForKey:APObjectUIDAttributeName];
            
            // Use primary key id to create in-memory context managed object ID equivalent
            NSManagedObjectID *managedObjectID = [self managedObjectIDForEntity:[relationship destinationEntity] withObjectUUID:relatedObjectUUID];
            
            return managedObjectID;
        }
    }
}

/*
 Returns an array containing the object IDs for a given array of newly-inserted objects.
 This method is called before executeRequest:withContext:error: with a save request, to assign permanent IDs to newly-inserted objects.
 */
- (NSArray *)obtainPermanentIDsForObjects:(NSArray *)array error:(NSError *__autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    if (array == nil) {
        return @[];
    }
    
    return [array map:^id(NSManagedObject* managedObject) {
        NSString *tempObjectUID = [self.localCache newTemporaryObjectUID];
        if (!tempObjectUID) {
            // Redundant Exception
            [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Error obtaining permanent objectID for object:%@", managedObject];
        }
        
        NSManagedObjectID *returnId = [self managedObjectIDForEntity: managedObject.entity withObjectUUID:tempObjectUID];
        if (AP_DEBUG_INFO) { DLog(@"Permanent ID assigned is %@", tempObjectUID) }
        
        return returnId;
    }];
}


- (id)executeRequest:(NSPersistentStoreRequest *)request
         withContext:(NSManagedObjectContext *)context
               error:(NSError *__autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    id result = nil;
    
    switch (request.requestType) {
            
        case NSSaveRequestType:
            result = [self AP_handleSaveRequest:(NSSaveChangesRequest *) request withContext:context error:error];
            break;
            
        case NSFetchRequestType:
            result = [self AP_handleFetchRequest:(NSFetchRequest *) request withContext:context error:error];
            break;
            
        default:
            [NSException raise:APIncrementalStoreExceptionIncompatibleRequest format:@"Unknown request type."];
            break;
    }
    
    return result;
}


#pragma mark - Fetching

- (id)AP_handleFetchRequest:(NSFetchRequest *)request
                withContext:(NSManagedObjectContext *)context
                      error:(NSError * __autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    switch (request.resultType) {
            
        case NSManagedObjectResultType:
            return [self AP_fetchManagedObjects:request withContext:context error:error];
            break;
            
        case NSManagedObjectIDResultType:
            return [self AP_fetchManagedObjectIDs:request withContext:context error:error];
            break;
            
        case NSDictionaryResultType:
            [NSException raise:APIncrementalStoreExceptionIncompatibleRequest format:@"Unimplemented result type requested."];
            break;
            
        case NSCountResultType:
            return [self AP_fetchCount:request withContext:context error:error];
            break;
            
        default:
            [NSException raise:APIncrementalStoreExceptionIncompatibleRequest format:@"Unknown result type requested."];
            break;
    }
    
    return nil;
}


// Returns NSArray of NSManagedObjects
- (id) AP_fetchManagedObjects:(NSFetchRequest *)fetchRequest
                  withContext:(NSManagedObjectContext *)context
                        error:(NSError * __autoreleasing*)error {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    NSError *localCacheError = nil;
    NSArray *cacheRepresentations = [self.localCache fetchObjectRepresentations:fetchRequest error:&localCacheError];
    
    if (localCacheError != nil) {
        if (error != NULL) {
            *error = localCacheError;
        }
        return nil;
    }
    
    __block NSMutableArray *results = [NSMutableArray array];
    
    [cacheRepresentations enumerateObjectsUsingBlock:^(id cacheManagedObjectRep, NSUInteger idx, BOOL *stop) {
        NSString *objectUUID = [cacheManagedObjectRep valueForKey:APObjectUIDAttributeName];
        NSManagedObjectID* managedObjectID = [self newObjectIDForEntity:fetchRequest.entity referenceObject:objectUUID];
        
        // Allows us to always return object, faulted or not
        NSManagedObject* managedObject = [context objectWithID:managedObjectID];
        
        if (![managedObject isFault]) {
            [self populateManagedObject:managedObject withRepresentation:cacheManagedObjectRep callingContext:context entity:fetchRequest.entity];
        }
        [results addObject:managedObject];
    }];
    return [results copy];
}


// Returns NSArray<NSManagedObjectID>
- (id) AP_fetchManagedObjectIDs:(NSFetchRequest *)fetchRequest
                    withContext:(NSManagedObjectContext *)context
                          error:(NSError *__autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    NSFetchRequest *fetchCopy = [fetchRequest copy];
    
    [fetchCopy setResultType:NSManagedObjectResultType];
    
    if ([fetchRequest fetchBatchSize] > 0) {
        [fetchCopy setFetchBatchSize:[fetchRequest fetchBatchSize]];
    }
    
    NSArray *objects = [self AP_fetchManagedObjects:fetchCopy withContext:context error:error];
    
    if (error != NULL && *error != nil) {
        return nil;
    }
    
    return [objects map:^(id item) {
        return [item objectID];
    }];
}


- (NSArray *) AP_fetchCount:(NSFetchRequest *)fetchRequest
                withContext:(NSManagedObjectContext *)context
                      error:(NSError * __autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    NSError *localCacheError = nil;
    NSUInteger localCacheCount = [self.localCache countObjectRepresentations:fetchRequest error:&localCacheError];
    
    // Error check
    if (localCacheError != nil) {
        *error = localCacheError;
        return nil;
    }
    
    return @[@(localCacheCount)];
}


#pragma mark - Saving

/*
 If the request is a save request, you record the changes provided in the request’s insertedObjects, updatedObjects, and deletedObjects collections. Note there is also a lockedObjects collection; this collection contains objects which were marked as being tracked for optimistic locking (through the detectConflictsForObject:: method); you may choose to respect this or not.
 In the case of a save request containing objects which are to be inserted, executeRequest:withContext:error: is preceded by a call to obtainPermanentIDsForObjects:error:; Core Data will assign the results of this call as the objectIDs for the objects which are to be inserted. Once these IDs have been assigned, they cannot change.
 
 Note that if an empty save request is received by the store, this must be treated as an explicit request to save the metadata, but that store metadata should always be saved if it has been changed since the store was loaded.
 
 If the request is a save request, the method should return an empty array.
 If the save request contains nil values for the inserted/updated/deleted/locked collections; you should treat it as a request to save the store metadata.
 
 @note: We are *IGNORING* locked objects. We are also not handling the metadata save requests, because AFAIK we don't need to generate any.
 */
- (id)AP_handleSaveRequest:(NSSaveChangesRequest *)saveRequest
               withContext:(NSManagedObjectContext *)context
                     error:(NSError *__autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    NSSet *insertedObjects = [saveRequest insertedObjects];
    NSSet *updatedObjects = [saveRequest updatedObjects];
    NSSet *deletedObjects = [saveRequest deletedObjects];
    
    __block NSError* localError;
    
    if ([insertedObjects count] > 0) {
        NSDictionary* insertedObjectRepresentations = [self representationsFromManagedObjects:[insertedObjects allObjects]];
        
        [insertedObjectRepresentations enumerateKeysAndObjectsUsingBlock:^(NSString* entityName, NSArray* representations, BOOL *stop) {
            
            if (![self.localCache inserteObjectRepresentations:representations entityName:entityName error:&localError]) {
                *stop = YES;
                *error = localError;
            }
        }];
        if (localError) return nil;
    }
    
    if ([updatedObjects count] > 0) {
        NSDictionary* updatedObjectRepresentations = [self representationsFromManagedObjects:[updatedObjects allObjects]];
        
        [updatedObjectRepresentations enumerateKeysAndObjectsUsingBlock:^(NSString* entityName, NSArray* representations, BOOL *stop) {
            
            if (![self.localCache updateObjectRepresentations:representations entityName:entityName error:&localError]){
                *stop = YES;
                *error = localError;
            }
        }];
        if (localError) return nil;
    }
    
    if ([deletedObjects count] > 0) {
        NSDictionary* deletedObjectRepresentations = [self representationsFromManagedObjects:[deletedObjects allObjects]];
        
        [deletedObjectRepresentations enumerateKeysAndObjectsUsingBlock:^(NSString* entityName, NSArray* representations, BOOL *stop) {
            
            if (![self.localCache deleteObjectRepresentations:representations entityName:entityName error:&localError]) {
                *stop = YES;
                *error = localError;
            }
        }];
        if (localError) return nil;
    }
    
    return @[];
}


#pragma mark - NSIncrementalStore Subclass Optional Methods

/*
 Once the incremental store registers a new managedObjectID we cache it and
 increment its reference count by 1
 */
- (void) managedObjectContextDidRegisterObjectsWithIDs:(NSArray *)objectIDs {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    [super managedObjectContextDidRegisterObjectsWithIDs:objectIDs];
    
    for (NSManagedObjectID *objectID in objectIDs) {
        
        id objectUUID = [self referenceObjectForObjectID:objectID];
        if (!objectUUID) {
            
            if (AP_DEBUG_ERRORS) { ELog(@"ObjectID: %@ does not have objectUUID??", objectID)}
            continue;
        }
        
        NSMutableDictionary *objectIDsAndRefereceCountByObjectUUID = (self.mapBetweenObjectIDsAndObjectUUIDByEntityName)[objectID.entity.name];
        NSDictionary* objectUUIDDictEntry;
        
        if (!objectIDsAndRefereceCountByObjectUUID) {
            
            /* 
             Entry: {objectID: refereceCount}
             As the entry was present this is the first reference then @1
             */
            
            objectIDsAndRefereceCountByObjectUUID = [NSMutableDictionary dictionary];
            objectUUIDDictEntry = @{APNSManagedObjectIDKey:objectID,
                                    APReferenceCountKey:@1};
            
        } else {
            
            /*
             Entry: {objectID: refereceCount}
             get existing entry and increment referece count by 1
             */
            
            NSNumber* referenceCount = [objectIDsAndRefereceCountByObjectUUID valueForKey:APReferenceCountKey];
            objectUUIDDictEntry = @{APNSManagedObjectIDKey:objectID,
                                                  APReferenceCountKey:@([referenceCount integerValue] + 1)};
        }
        
        objectIDsAndRefereceCountByObjectUUID[objectUUID] = objectUUIDDictEntry;
        (self.mapBetweenObjectIDsAndObjectUUIDByEntityName)[objectID.entity.name] = objectIDsAndRefereceCountByObjectUUID;
    }
}


/*
 Once the incremental store a managedObjectID we check if its reference count and
 decrease it by 1 and remove it from the objectIDsAndRefereceCountByObjectUUID if the count == 0
 */
- (void) managedObjectContextDidUnregisterObjectsWithIDs:(NSArray *)objectIDs {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    [super managedObjectContextDidUnregisterObjectsWithIDs:objectIDs];
    
    for (NSManagedObjectID *objectID in objectIDs) {
        
        id objectUUID = [self referenceObjectForObjectID:objectID];
        if (!objectUUID) {
            
            if (AP_DEBUG_ERRORS) { ELog(@"ObjectID: %@ does not have objectUID??", objectID)}
            continue;
        }
        
        NSMutableDictionary *objectIDsAndRefereceCountByObjectUUID = (self.mapBetweenObjectIDsAndObjectUUIDByEntityName)[objectID.entity.name];
        NSDictionary* objectUUIDDictEntry;
        
        if (!objectIDsAndRefereceCountByObjectUUID) {
            
            if (AP_DEBUG_ERRORS) { ELog(@"ObjectID: %@ isn't registred in self.mapBetweenObjectIDsAndObjectUUIDByEntityName ??", objectID)}
            continue;
            
        } else {
            
            /*
             Entry: {objectID: refereceCount}
             get existing entry and increment referece count by 1
             */
            
            NSNumber* referenceCount = [objectIDsAndRefereceCountByObjectUUID valueForKey:APReferenceCountKey];
            
            if ([referenceCount integerValue] == 1) {
                
                /* 
                 No context holds reference for this managedObjectID anymore,
                 we can remove it from objectIDsAndRefereceCountByObjectUUID
                 */
                
                [objectIDsAndRefereceCountByObjectUUID removeObjectForKey:objectUUID];
                
            } else {
                objectUUIDDictEntry = @{APNSManagedObjectIDKey:objectID,
                                        APReferenceCountKey:@([referenceCount integerValue] - 1)};
            }
        }
    }
}


#pragma mark - Notification Handlers

- (void) didReceiveSyncNotifcation: (NSNotification*) note {
    
    if (AP_DEBUG_METHODS) {MLog() }
    [self syncLocalCacheAllRemoteObjects:NO];
}


- (void) didReceiveFullSyncNotifcation: (NSNotification*) note {
    
    if (AP_DEBUG_METHODS) { MLog()}
    [self syncLocalCacheAllRemoteObjects:YES];
}


- (void) didReceiveResetCacheNotifcation: (NSNotification*) note {
    
    if (AP_DEBUG_METHODS) { MLog()}
    [self.localCache resetCache];
    [[NSNotificationCenter defaultCenter]postNotificationName:APNotificationCacheDidFinishReset object:self];
}


#pragma mark - Sync Local Cache

- (void) syncLocalCacheAllRemoteObjects:(BOOL) allRemoteObjects {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    [self.localCache syncAllObjects:allRemoteObjects onCountingObjects:^(NSUInteger localObjects, NSUInteger remoteObjects) {
        NSDictionary* userInfo = @{APNotificationCacheNumberOfLocalObjectsKey: @(localObjects),
                                   APNotificationCacheNumberOfRemoteObjectsKey: @(remoteObjects)};
        [[NSNotificationCenter defaultCenter]postNotificationName:APNotificationCacheWillStartSync object:self userInfo:userInfo];
    
    } onSyncObject:^(BOOL isRemoteObject) {
        NSString* userInfoKey = (isRemoteObject)? APNotificationCacheNumberOfRemoteObjectsKey: APNotificationCacheNumberOfLocalObjectsKey;
        NSDictionary* userInfo = @{userInfoKey: @1};
        [[NSNotificationCenter defaultCenter]postNotificationName:APNotificationCacheDidSyncObject object:self userInfo:userInfo];
    
    } onCompletion:^(NSArray *objectUIDs, NSError *syncError) {
        if (!syncError) {
            NSDictionary* userInfo = @{APNotificationObjectsIDsKey: objectUIDs};
            [[NSNotificationCenter defaultCenter]postNotificationName:APNotificationCacheDidFinishSync object:self userInfo:userInfo];
            
        } else {
            if (AP_DEBUG_ERRORS) {ELog(@"Error syncronising: %@",syncError)};
        }
    }];
}


#pragma mark - Translating Between Objects UUIDs and Managed Object IDs

- (NSManagedObjectID*) managedObjectIDForEntity: (NSEntityDescription*) entityDescription
                                 withObjectUUID: (NSString*) objectUUID {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    if (!objectUUID) {
        if (AP_DEBUG_ERRORS) {ELog(@"Error - uniqueIdentifier == nil")}
        return nil;
    }
    
    NSManagedObjectID *managedObjectID = nil;
    
    // Lookup if we have it created already
    NSMutableDictionary *objectIDsAndRefCountByObjectUUID = (self.mapBetweenObjectIDsAndObjectUUIDByEntityName)[entityDescription.name];
    
    if (objectIDsAndRefCountByObjectUUID) {
        NSDictionary* objectUUIDEntry = objectIDsAndRefCountByObjectUUID[objectUUID];
        
        if (!objectUUIDEntry) {
             managedObjectID = [self newObjectIDForEntity:entityDescription referenceObject:objectUUID];
        
        } else {
            managedObjectID = objectUUIDEntry[APNSManagedObjectIDKey];
            NSAssert([managedObjectID isKindOfClass:[NSManagedObjectID class]],@"returned object should be of NSManagedObjectId kind");
        }
        
    } else {
        /*
         After created it will call managedObjectContextDidRegisterObjectsWithIDs:
         then we have the oportunity cache it in self.mapBetweenObjectIDsAndObjectUUIDByEntityName
         */
        managedObjectID = [self newObjectIDForEntity:entityDescription referenceObject:objectUUID];
        
    }
    
    return managedObjectID;
}


#pragma mark - Translate Managed Objects to Representations 

/**
 Returns a NSDictionary keyed by entity name with NSArrays of representations as objects.
 */
- (NSDictionary*) representationsFromManagedObjects: (NSArray*) managedObjects {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    NSMutableDictionary* representations = [[NSMutableDictionary alloc]init];
    
    [managedObjects enumerateObjectsUsingBlock:^(NSManagedObject* managedObject, NSUInteger idx, BOOL *stop) {
        NSString* entityName = managedObject.entity.name;
        NSMutableArray* objectsForEntity = representations[entityName] ?: [NSMutableArray array];
        [objectsForEntity addObject:[self representationFromManagedObject:managedObject]];
        representations[entityName] = objectsForEntity;
    }];
    
    return representations;
}


- (NSDictionary*) representationFromManagedObject: (NSManagedObject*) managedObject {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    NSMutableDictionary* representation = [[NSMutableDictionary alloc]init];
    NSDictionary* properties = [managedObject.entity propertiesByName];
    
    [properties enumerateKeysAndObjectsUsingBlock:^(NSString* propertyName, NSPropertyDescription* propertyDescription, BOOL *stop) {
        [managedObject willAccessValueForKey:propertyName];
        [representation setValue:[self referenceObjectForObjectID:managedObject.objectID] forKey:APObjectUIDAttributeName];
        if ([propertyDescription isKindOfClass:[NSAttributeDescription class]]) {
            
            // Attribute
            representation[propertyName] = [managedObject primitiveValueForKey:propertyName] ?: [NSNull null];

            
        } else if ([propertyDescription isKindOfClass:[NSRelationshipDescription class]]) {
            NSRelationshipDescription* relationshipDescription = (NSRelationshipDescription*) propertyDescription;
            
            if (!relationshipDescription.isToMany) {
                
                // To-One
                
                NSManagedObject* relatedObject = [managedObject primitiveValueForKey:propertyName];
                
                if (relatedObject) {
                    NSString* objectUID = [self referenceObjectForObjectID:relatedObject.objectID];
                    representation[propertyName] = objectUID;
                } else {
                    representation[propertyName] = [NSNull null];
                }
                
            } else {
                
                // To-Many
                
                NSSet* relatedObjects = [managedObject primitiveValueForKey:propertyName];
                __block NSMutableArray* relatedObjectsRepresentation = [[NSMutableArray alloc] initWithCapacity:[relatedObjects count]];
                [relatedObjects enumerateObjectsUsingBlock:^(NSManagedObject* relatedObject, BOOL *stop) {
                    NSString* objectUID = [self referenceObjectForObjectID:relatedObject.objectID];
                    [relatedObjectsRepresentation addObject:objectUID];
                }];
                representation[propertyName] = relatedObjectsRepresentation;
            }
        }
        [managedObject didAccessValueForKey:propertyName];
    }];
    return representation;
}


#pragma mark - Translate Representations to Managed Objects

- (void) populateManagedObject:(NSManagedObject*) managedObject
            withRepresentation:(NSDictionary *)dictionary
                callingContext:(NSManagedObjectContext*)context
                        entity:(NSEntityDescription *)entity {
    
    if (AP_DEBUG_METHODS) {MLog(@"%@",[NSThread isMainThread] ? @"" : @" - [BG Thread]")}
    
    // Enumerate through properties and set internal storage
    [dictionary enumerateKeysAndObjectsUsingBlock:^(id propertyName, id propertyValue, BOOL *stop) {
        [managedObject willChangeValueForKey:propertyName];
        NSPropertyDescription *propertyDescription = [entity propertiesByName][propertyName];
        
        // Ignore keys that don't belong to our model
        if (propertyDescription) {
            
            // Attributes
            if ([propertyDescription isKindOfClass:[NSAttributeDescription class]]) {
                if (dictionary[propertyName] == [NSNull null]) {
                    [managedObject setPrimitiveValue:nil forKey:propertyName];
                } else {
                    [managedObject setPrimitiveValue:dictionary[propertyName] forKey:propertyName];
                }
                
            // Relationships
            } else if (![managedObject hasFaultForRelationshipNamed:propertyName]) {
                NSRelationshipDescription *relationshipDescription = (NSRelationshipDescription *)propertyDescription;
                
                // To-many
                if ([relationshipDescription isToMany]) {
                    NSMutableSet *relatedObjects = [[managedObject primitiveValueForKey:propertyName] mutableCopy];
                    if (relatedObjects != nil) {
                        [relatedObjects removeAllObjects];
                        NSArray *serializedDictSet = dictionary[propertyName];
                        
                        [serializedDictSet enumerateObjectsUsingBlock:^(NSString* objectUUID, NSUInteger idx, BOOL *stop) {
                            NSManagedObjectID* relatedManagedObjectID = [self managedObjectIDForEntity:relationshipDescription.destinationEntity withObjectUUID:objectUUID];
                            [relatedObjects addObject:[[managedObject managedObjectContext] objectWithID:relatedManagedObjectID]];
                        }];
                        [managedObject setPrimitiveValue:relatedObjects forKey:propertyName];
                    }
                    
                // To-one
                } else {
                    if (dictionary[propertyName] == [NSNull null]) {
                        [managedObject setPrimitiveValue:nil forKey:propertyName];
                    } else {
                        NSManagedObjectID* relatedManagedObjectID = [self managedObjectIDForEntity:relationshipDescription.destinationEntity withObjectUUID:dictionary[propertyName]];
                        NSManagedObject *toOneObject = [[managedObject managedObjectContext] objectWithID:relatedManagedObjectID];
                        [managedObject setPrimitiveValue:toOneObject forKey:propertyName];
                    }
                }
            }
        }
         [managedObject didChangeValueForKey:propertyName];
    }];
}

@end
