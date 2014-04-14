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

#import "APParseConnector.h"

#import <Parse/Parse.h>
#import "APError.h"
#import "Common.h"
#import "NSLogEmoji.h"

/* Debugging */
BOOL AP_DEBUG_METHODS = NO;
BOOL AP_DEBUG_ERRORS = NO;
BOOL AP_DEBUG_INFO = NO;
static NSInteger parseQueryCounter = 0;

// NSUserDefaults entry to reference the earliest object date synced from Parse.
static NSString* const APLatestObjectSyncedKey = @"APEarliestObjectSyncedKey";

/* 
 It specifies the maximum number of objects that a sinble parse query should return when executed. 
 If there are more objects than this limit it will be fetched in batches. 
 Parse specifies that 100 is the default but can be increased to maximum 1000.
 */
static NSUInteger APParseQueryFetchLimit = 100;

static NSUInteger APParseObjectIDLenght = 10;


@interface APParseConnector()

@property (strong,nonatomic) PFUser* authenticatedUser;
@property (assign,nonatomic) APMergePolicy mergePolicy;

/*
 Correlation between local temporary generated UUIDs and remote obtained permanent UUID
 
 When we first insert a new object it won't have a ObjectID until we sync with Parse.
 The incremental store will keep the old reference ObjectID and will query based on that.
 On the other hand the cache already has the permanent Object ID, then we translate it as long as the
 Incremental Store remains allocated.
 Next time the application is launched it will populate the main context will the persistant values from cache,
 which will be correct
 */
@property (nonatomic, strong) NSMutableDictionary* mapOfTemporaryToPermanentUID;

@end


@implementation APParseConnector

- (instancetype)initWithAuthenticatedUser:(id) user mergePolicy:(APMergePolicy) policy {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    self = [super init];
    if (self) {
        
        if (!user) {
            [NSException raise:APIncrementalStoreExceptionInconsistency format:@"can't init, user is nil"];
        }
        
        if (![user isKindOfClass:[PFUser class]]) {
            [NSException raise:APIncrementalStoreExceptionInconsistency format:@"user should be a PFUser kind of object"];
        }
        
        if (![user isAuthenticated]) {
            if (AP_DEBUG_ERRORS) {ELog(@"User is not authenticated")}
            self = nil;
        } else {
            _authenticatedUser = user;
            _mergePolicy = policy;
        }
    }
    return self;
}


#pragma mark - Getters and Setters

- (NSMutableDictionary*) mapOfTemporaryToPermanentUID {
    if (!_mapOfTemporaryToPermanentUID) {
        _mapOfTemporaryToPermanentUID = [NSMutableDictionary dictionary];
    }
    return _mapOfTemporaryToPermanentUID;
}


#pragma mark - APIncrementalStoreConnector Protocol

- (void) setMergePolicy:(APMergePolicy)mergePolicy {
    _mergePolicy = mergePolicy;
}


- (NSArray*) mergeRemoteObjectsWithContext: (NSManagedObjectContext*) context
                                  fullSync: (BOOL) fullSync
                              onSyncObject: (void (^)(void)) onSyncObject
                                     error: (NSError*__autoreleasing*) error {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    NSError* localError;
    
    if (![self isUserAuthenticated:&localError]) {
        *error = localError;
        return NO;
    }
    
    __block NSMutableArray* mergedObjectsIDs = [NSMutableArray array];
    NSManagedObjectModel* model = context.persistentStoreCoordinator.managedObjectModel;
    NSArray* sortedEntities = [[model entities]sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]]];
    
    for (NSEntityDescription* entityDescription in sortedEntities) {
        PFQuery *query = [PFQuery queryWithClassName:entityDescription.name];
        //query.trace = YES;
        
        if (!fullSync) {
            NSDate* lastSync = [self latestObjectSyncedDateForEntityName:entityDescription.name];
            if (lastSync) {
                [query whereKey:@"updatedAt" greaterThan:lastSync];
            }
        }
        
        if (AP_DEBUG_INFO) { DLog(@"Parse Query#%ld for class: %@ - cache policy: %d",(long)parseQueryCounter++, query.parseClassName,query.cachePolicy)}
        
        // We count the object before fetching (see APParseQueryFetchLimit exaplanation)
        NSError* countError;
        NSUInteger totalObjectsToBeFetched = [query countObjects:&countError];
        if (countError) {
            *error = countError;
            return nil;
        }
        NSMutableArray* parseObjects = [[NSMutableArray alloc]initWithCapacity:totalObjectsToBeFetched];
        
        NSError* parseError;
        NSUInteger skip = 0;
        while (skip < totalObjectsToBeFetched) {
            [query setSkip:skip];
            NSArray* batchOfObjects = [query findObjects:&parseError];
            
            if (parseError) {
                *error = parseError;
                return nil;
            }
            [parseObjects addObjectsFromArray:batchOfObjects];
            skip += APParseQueryFetchLimit;
        }
        
        for (PFObject* parseObject in parseObjects) {
            [self setLatestObjectSyncedDate:parseObject.updatedAt forEntityName:entityDescription.name];
            NSManagedObject* managedObject = [self managedObjectForObjectUID:parseObject.objectId entity:entityDescription inContext:context createIfNecessary:NO];
            BOOL parseObjectIsDeleted = [[parseObject valueForKey:APObjectIsDeletedAttributeName]isEqualToNumber:@YES];
            
            if (!managedObject) {
                
                // New local object - create it localy if it isn't marked as deleted
                
                if (!parseObjectIsDeleted) {
                    managedObject = [NSEntityDescription insertNewObjectForEntityForName:entityDescription.name inManagedObjectContext:context];
                    
                    NSError* permanentIdError;
                    [context obtainPermanentIDsForObjects:@[managedObject] error:&permanentIdError];
                    if (permanentIdError) {
                        [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Could not obtain permanent IDs for objects %@ with error %@", managedObject, permanentIdError];
                    }
                    [self populateManagedObject:managedObject withSerializedParseObject:[self serializeParseObject:parseObject]];
                    [mergedObjectsIDs addObject:managedObject.objectID];
                }
                
            } else {
                
                // Existing local object
                
                if (parseObjectIsDeleted) {
                     [context deleteObject:managedObject];
                
                } else {
                   [self populateManagedObject:managedObject withSerializedParseObject:[self serializeParseObject:parseObject]];
                }
                [mergedObjectsIDs addObject:managedObject.objectID];
            }
            if (onSyncObject) onSyncObject();
        }
        
        /*
         WARNING
         Unit testing - [APParseConnectorTestCase testMergingWithOtherClientMergingSimultaneously]
         Do not let this uncommented if you are not executing this specif test
         */
//        static BOOL firstRun = YES;
//        if ([entityDescription.name isEqualToString:@"Book"] && firstRun){
//            firstRun = NO;
//            NSError* saveError;
//            
//            PFObject* anotherBook = [PFObject objectWithClassName:@"Book"];
//            [anotherBook setValue:@"another book" forKey:@"name"];
//            [anotherBook setValue:@NO forKey:APObjectIsDeletedAttributeName];
//            [anotherBook save:&saveError];
//            DLog(@"Another book %@ has been created",anotherBook);
//            
//            PFObject* page = [PFObject objectWithClassName:@"Page"];
//            [page setValue:@NO forKey:APObjectIsDeletedAttributeName];
//            
//            [page save:&saveError];
//            DLog(@"Page has been created");
//            
//            PFObject* lastBook = [parseObjects lastObject];
//            [[lastBook relationForKey:@"pages"]addObject:page];
//            [lastBook save:&saveError];
//            
//            [page setObject:lastBook forKey:@"book"];
//            [page save:&saveError];
//        }
    }
    return  mergedObjectsIDs;
}


- (BOOL) mergeManagedContext:(NSManagedObjectContext *)context
                onSyncObject:(void (^)(void)) onSyncObject
                       error:(NSError*__autoreleasing*) error {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    __block NSError* localError;
    
    if (![self isUserAuthenticated:&localError]) {
        *error = localError;
        return NO;
    }
    
    __block BOOL success = YES;
    
    NSArray* dirtyManagedObjects = [self managedObjectsMarkedAsDirtyInContext:context];
     if (AP_DEBUG_INFO) { DLog(@"Dirty managed objects found %@",dirtyManagedObjects)}
    
    [dirtyManagedObjects enumerateObjectsUsingBlock:^(NSManagedObject* managedObject, NSUInteger idx, BOOL *stop) {
        
        if (AP_DEBUG_INFO) { ALog(@"Merging: %@", managedObject)}
        
        void (^reportErrorStopEnumerating)() = ^{
            if (AP_DEBUG_ERRORS) {ELog(@"Error merging object: %@",managedObject)};
            *stop = YES;
            success = NO;
            *error = localError;
        };
        
        NSString* objectUID = [managedObject valueForKey:APObjectUIDAttributeName];
        
        // Sanity check
        if (!objectUID) {
            [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Managed object without objectUID associated"];
        }
        
        if ([objectUID hasPrefix:APObjectTemporaryUIDPrefix]) {
            
            // New object created localy
            
            if ([[managedObject valueForKey:APObjectIsDeletedAttributeName] isEqualToNumber:@YES]) {
                
                // Object was deleted before even synced with Parse, just delete it.
                [context deleteObject:managedObject];
                
            } else {
                NSString* permanentObjectUID = [self insertObject:managedObject error:&localError];
                if (localError) {
                    reportErrorStopEnumerating();
                } else {
                    if (AP_DEBUG_INFO) { ALog(@"Including entry on map of temp IDS for %@ to %@ ", objectUID,permanentObjectUID)}
                    self.mapOfTemporaryToPermanentUID[objectUID] = permanentObjectUID;
                    [managedObject setValue:@NO forKey:APObjectIsDirtyAttributeName];
                }
            }
        
        } else {
            PFObject* parseObject = [self parseObjectFromClassName:managedObject.entity.name objectUID:objectUID];
            
            if (!parseObject) {
                
                // Object doesn't exist on the server anymore
                [context deleteObject:managedObject];
                if (AP_DEBUG_INFO) { ALog(@"Object doesn't exist on the server anymore, deleting from context: %@ ", managedObject)}
                
            } else {
                NSDate* localObjectUpdatedAt = [managedObject valueForKey:APObjectLastModifiedAttributeName];
                if (AP_DEBUG_INFO) { ALog(@"Parse equivalent object: %@ ", parseObject)}
                
                // If the object has not been updated since last time we read it from server
                // we are safe to updated it. If the object is marked with apIsDeleted = YES
                // then we save it back to the server to let the others known that it should be
                // deleted and finally we remove it from our local core data cache.
                
                if ([parseObject.updatedAt isEqualToDate:localObjectUpdatedAt] || localObjectUpdatedAt == nil) {
                    
                    [self populateParseObject:parseObject withManagedObject:managedObject error:&localError];
                    
                     if (AP_DEBUG_INFO) { ALog(@"Object remains the same, we are good to merge it")}
                    
                    if (localError) {
                        reportErrorStopEnumerating();
                   
                    } else {
                        
                        if (![parseObject save:&localError]) {
                            reportErrorStopEnumerating();
                            
                        } else {
                            [managedObject setValue:@NO forKey:APObjectIsDirtyAttributeName];
                        }
                    }
                    
                } else {
                    
                    // Conflict detected
                    
                    if (AP_DEBUG_INFO) { ALog(@"Conflict detected - Dates: parseObject %@ - localObject: %@ ",parseObject.updatedAt,localObjectUpdatedAt)}
                    
                    if (self.mergePolicy == APMergePolicyClientWins) {
                        
                        if (AP_DEBUG_INFO) { ALog(@"APMergePolicyClientWins")}
                        [self populateParseObject:parseObject withManagedObject:managedObject error:&localError];
                        
                        if (![parseObject save:&localError]) {
                            reportErrorStopEnumerating();
                        } else {
                            if ([[managedObject valueForKey:APObjectIsDeletedAttributeName] isEqualToNumber:@YES]) {
                                [context deleteObject:managedObject];
                            } else {
                                [managedObject setValue:@NO forKey:APObjectIsDirtyAttributeName];
                            }
                        }
                        
                    } else if (self.mergePolicy == APMergePolicyServerWins) {
                        
                        if (AP_DEBUG_INFO) { ALog(@"APMergePolicyServerWins")}
                        [self populateManagedObject:managedObject withSerializedParseObject:[self serializeParseObject:parseObject]];
                        [managedObject setValue:@NO forKey:APObjectIsDirtyAttributeName];
                        
                    } else {
                        [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Unkown Merge Policy"];
                    }
                }
            }
        }
        if (onSyncObject) onSyncObject();
    }];
    return success;
}


- (NSUInteger) countLocalObjectsToBeSyncedInContext: (NSManagedObjectContext *)context
                                              error: (NSError*__autoreleasing*) error {
    
    return [[self managedObjectsMarkedAsDirtyInContext:context]count];
}


- (NSUInteger) countRemoteObjectsToBeSyncedInContext: (NSManagedObjectContext *)context
                                            fullSync: (BOOL) fullSync
                                               error: (NSError*__autoreleasing*) error {
    
    NSUInteger numberOfObjects = 0;
    NSError* countError;
    NSManagedObjectModel* model = context.persistentStoreCoordinator.managedObjectModel;
    
    for (NSEntityDescription* entityDescription in [model entities]) {
        PFQuery *query = [PFQuery queryWithClassName:entityDescription.name];
        
        if (!fullSync) {
            NSDate* lastSync = [self latestObjectSyncedDateForEntityName:entityDescription.name];
            if (lastSync) {
                [query whereKey:@"updatedAt" greaterThan:lastSync];
            }
        }
        numberOfObjects += [query countObjects:&countError];
        
        if (countError) {
            if(AP_DEBUG_ERRORS) ELog(@"Error counting: %@",countError);
            *error = countError;
            numberOfObjects = 0;
            continue;
        }
    }
    
    return numberOfObjects;
}

#pragma mark - Util Methods

- (NSString*) insertObject:(NSManagedObject*) managedObject
                     error:(NSError *__autoreleasing*)error {
    
    if (AP_DEBUG_METHODS) { MLog(@"Managed Object:%@",managedObject)}
    
    NSString* objectUID;
    NSError* localError;
    
    PFObject* parseObject = [[PFObject alloc]initWithClassName:managedObject.entity.name];
    [self populateParseObject:parseObject withManagedObject:managedObject error:&localError];
   
    if (!localError) {
        
        if ([parseObject save:&localError]) {
            if (AP_DEBUG_INFO) { ALog(@"Parse object saved: %@",parseObject)}
            
            /* Parse sets the objectId for a new object only after we save it. */
            [managedObject setValue:parseObject.objectId forKey:APObjectUIDAttributeName];
            objectUID = parseObject.objectId;
        }
    }
    
    *error = localError;
    return objectUID;
}


- (NSArray*) managedObjectsMarkedAsDirtyInContext: (NSManagedObjectContext *)context {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    __block NSError* error;
    
    NSMutableArray* dirtyManagedObjects = [NSMutableArray array];
    NSArray* allEntities = context.persistentStoreCoordinator.managedObjectModel.entities;
    [allEntities enumerateObjectsUsingBlock:^(NSEntityDescription* entity, NSUInteger idx, BOOL *stop) {
        NSFetchRequest* request = [NSFetchRequest fetchRequestWithEntityName:entity.name];
        request.predicate = [NSPredicate predicateWithFormat:@"%K == YES",APObjectIsDirtyAttributeName];
        [dirtyManagedObjects addObjectsFromArray:[context executeFetchRequest:request error:&error]];
    }];
    
    if (!error) {
        return dirtyManagedObjects;
        
    } else {
        if (AP_DEBUG_ERRORS) {ELog(@"Error: %@",error)}
        return nil;
    }
}

- (BOOL) isUserAuthenticated:(NSError**) error {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    if (![self.authenticatedUser isAuthenticated]) {
        *error = [NSError errorWithDomain:APIncrementalStoreErrorDomain code:APIncrementalStoreErrorCodeUserCredentials userInfo:nil];
        return NO;
        
    } else {
        return YES;
    }
}


- (void) setLatestObjectSyncedDate: (NSDate*) date forEntityName: (NSString*) entityName {
    
    if (AP_DEBUG_METHODS) { MLog(@"Date: %@",date)}

    NSMutableDictionary* latestObjectSyncedDates = [[[NSUserDefaults standardUserDefaults] objectForKey:APLatestObjectSyncedKey]mutableCopy] ?: [NSMutableDictionary dictionary];
    
    if ([[latestObjectSyncedDates[entityName] laterDate:date] isEqualToDate:date] || latestObjectSyncedDates[entityName] == nil) {
        latestObjectSyncedDates[entityName] = date;
        [[NSUserDefaults standardUserDefaults]setObject:latestObjectSyncedDates forKey:APLatestObjectSyncedKey];
    }
}


- (NSDate*) latestObjectSyncedDateForEntityName: (NSString*) entityName{

    NSDictionary* latestObjectSyncedDate =[[NSUserDefaults standardUserDefaults] objectForKey:APLatestObjectSyncedKey];
    return latestObjectSyncedDate[entityName];
}


- (PFObject*) parseObjectFromClassName:(NSString*) className objectUID: (NSString*) objectUID {
    
    if (AP_DEBUG_METHODS) {MLog(@"Class:%@ - ObjectUID: %@",className,objectUID)}
    
    PFObject* parseObject;
    
    PFQuery* query = [PFQuery queryWithClassName:className];
    [query whereKey:@"objectId" equalTo:objectUID];
    
    NSError* error;
    NSArray* results = [query findObjects:&error];
    
    if (error) {
        if (AP_DEBUG_ERRORS) {ELog(@"Error finding objects at Parse: %@",error)}
    
    } else if ([results count] > 1) {
        if (AP_DEBUG_ERRORS) {ELog(@"Error - WTF?? more than one object with the objectID: %@",objectUID)}
    
    } else if ([results count] == 0) {
        if (AP_DEBUG_ERRORS) {ELog(@"Error - There's no existing object using the objectID: %@",objectUID)}
    
    } else {
        parseObject = [results lastObject];
    }
    
     if (AP_DEBUG_INFO) {DLog(@"Parse object %@ retrieved: %@",parseObject.parseClassName, parseObject.objectId)}
    return parseObject;
}


- (void) populateManagedObject:(NSManagedObject*) managedObject
     withSerializedParseObject:(NSDictionary*) parseObjectDictRepresentation {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    [[managedObject.entity propertiesByName]enumerateKeysAndObjectsUsingBlock:^(NSString* propertyName, NSPropertyDescription* propertyDesctiption, BOOL *stop) {
        
        if ([[parseObjectDictRepresentation allKeys]containsObject:propertyName]) {
            id parseObjectValue = [parseObjectDictRepresentation valueForKey:propertyName];
            
            if ([propertyDesctiption isKindOfClass:[NSAttributeDescription class]]) {
                if (parseObjectValue != [NSNull null]) {
                    [managedObject setValue:parseObjectValue forKey:propertyName];
                }
                
            } else {
                
                NSRelationshipDescription* relationshipDescription = (NSRelationshipDescription*) propertyDesctiption;
                NSArray *relatedParseObjets = (NSArray*) parseObjectValue;
                
                if (relationshipDescription.isToMany) {
                    NSMutableSet* relatedManagedObjects = [[NSMutableSet alloc]initWithCapacity:[relatedParseObjets count]];
                    
                    for (NSDictionary* dictParseObject in relatedParseObjets) {
                        NSString* objectUUID = [dictParseObject valueForKey:APObjectUIDAttributeName];
                        NSManagedObject* relatedManagedObject = [self managedObjectForObjectUID:objectUUID entity:relationshipDescription.destinationEntity inContext:managedObject.managedObjectContext createIfNecessary:YES];
                        //if (AP_DEBUG_METHODS) {MLog(@"Adding object to %@ relation: %@",propertyName,relatedManagedObject)}
                        [relatedManagedObjects addObject:relatedManagedObject];
                    }
                    
                    [managedObject setValue:relatedManagedObjects forKey:propertyName];
                    
                } else {
                    NSString* objectUID = [parseObjectValue valueForKey:APObjectUIDAttributeName];
                    if ([objectUID isKindOfClass:[NSString class]] == NO || [objectUID length] != APParseObjectIDLenght) {
                        [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Check your model, received an invalid Parse ObjectID for a To-One relationship. Only Parse pointer relationships are valid for To-One CoreData relationships"];
                    }
                    NSManagedObject* relatedManagedObject = [self managedObjectForObjectUID:objectUID entity:relationshipDescription.destinationEntity inContext:managedObject.managedObjectContext createIfNecessary:YES];
                    //if (AP_DEBUG_METHODS) {MLog(@"Adding object to %@ relation: %@",propertyName,relatedManagedObject)}
                    [managedObject setValue:relatedManagedObject forKey:propertyName];
                }
            }
        }
    }];
}

- (void) populateParseObject:(PFObject*) parseObject
           withManagedObject:(NSManagedObject*) managedObject
                       error:(NSError *__autoreleasing*)error {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    NSMutableDictionary* mutableProperties = [[managedObject.entity propertiesByName]mutableCopy];
    [mutableProperties removeObjectForKey:APObjectUIDAttributeName];
    [mutableProperties removeObjectForKey:APObjectLastModifiedAttributeName];
    [mutableProperties removeObjectForKey:APObjectIsDirtyAttributeName];
    
    [mutableProperties enumerateKeysAndObjectsUsingBlock:^(NSString* propertyName, NSPropertyDescription* propertyDesctiption, BOOL *stop) {
        
        id propertyValue = [managedObject valueForKey:propertyName];
        
        if ([propertyDesctiption isKindOfClass:[NSAttributeDescription class]]) {
            NSAttributeDescription* attrDescription = (NSAttributeDescription*) propertyDesctiption;
            
            if (propertyValue == nil) {
                [parseObject setValue:[NSNull null] forKey:propertyName];
                
            } else {
                
                if (attrDescription.attributeType == NSBooleanAttributeType) {
                    [parseObject setValue:@([propertyValue boolValue]) forKey:propertyName];
                
                } else if (attrDescription.attributeType == NSBinaryDataAttributeType) {
                    PFFile* file = [PFFile fileWithData:propertyValue];
                    
                    NSError* fileSavingError;
                    if (![file save:&fileSavingError]) {
                       if (AP_DEBUG_ERRORS) {ELog(@"Error saving file to Parse: %@",fileSavingError)}
                        *error = fileSavingError;
                        return;
                    }
                    [parseObject setValue:file forKey:propertyName];
                    
                } else {
                    [parseObject setValue:propertyValue forKey:propertyName];
                }
            }
            
        } else {
            NSRelationshipDescription* relationshipDescription = (NSRelationshipDescription*) propertyDesctiption;
            
            if (propertyValue) {
                
                if (relationshipDescription.isToMany) {
                    
                    // To-Many relationship
                    
                    NSSet* relatedManagedObjects = (NSSet*) propertyValue;
                    PFRelation* relation = [parseObject relationForKey:propertyName];
                    
                    for (NSManagedObject* relatedManagedObject in relatedManagedObjects) {
                        PFObject* relatedParseObject;
                        NSString* relatedObjectUID = [relatedManagedObject valueForKey:APObjectUIDAttributeName];
                        
                        if ([relatedObjectUID hasPrefix:APObjectTemporaryUIDPrefix]) {
                            relatedParseObject = [PFObject objectWithClassName:relatedManagedObject.entity.name];
                            [relatedParseObject save];
                            [relatedManagedObject setValue:relatedParseObject.objectId forKey:APObjectUIDAttributeName];
                            self.mapOfTemporaryToPermanentUID[relatedObjectUID] = relatedParseObject.objectId;
                        
                        } else {
                           relatedParseObject = [self parseObjectFromClassName:relationshipDescription.destinationEntity.name objectUID:relatedObjectUID];
                        }
                        [relation addObject:relatedParseObject];
                    }
                    
                } else {
                    
                    // To-One relationship
                    
                    NSManagedObject* relatedManagedObject = (NSManagedObject*) propertyValue;
                    PFObject* relatedParseObject;
                    NSString* relatedObjectUID = [relatedManagedObject valueForKey:APObjectUIDAttributeName];
                    
                    if ([relatedObjectUID hasPrefix:APObjectTemporaryUIDPrefix]) {
                        relatedParseObject = [PFObject objectWithClassName:relatedManagedObject.entity.name];
                        [relatedParseObject save];
                        [relatedManagedObject setValue:relatedParseObject.objectId forKey:APObjectUIDAttributeName];
                        self.mapOfTemporaryToPermanentUID[relatedObjectUID] = relatedParseObject.objectId;
                        
                    } else {
                         relatedParseObject = [self parseObjectFromClassName:relationshipDescription.destinationEntity.name objectUID:relatedObjectUID];
                    }
                    
                    if (relatedParseObject == nil) {
                        *stop = YES;
                        *error = [NSError errorWithDomain:APIncrementalStoreErrorDomain code:APIncrementalStoreErrorCodeMergingLocalObjects userInfo:nil];
                        
                    } else {
                        [parseObject setValue:relatedParseObject forKey:propertyName];
                    }
                }
            }
        }
    }];
}


- (NSManagedObject*) managedObjectForObjectUID: (NSString*) objectUID
                                        entity: (NSEntityDescription*) entity
                                     inContext: (NSManagedObjectContext*) context
                             createIfNecessary: (BOOL) createIfNecessary {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    NSManagedObject* managedObject = nil;
    
    NSFetchRequest* fr = [NSFetchRequest fetchRequestWithEntityName:entity.name];
    fr.predicate = [NSPredicate predicateWithFormat:@"%K == %@",APObjectUIDAttributeName,objectUID];
    
    __block NSError* fetchError;
    __block NSArray* fetchResults;
    
    fetchResults = [context executeFetchRequest:fr error:&fetchError];
    
    if (!fetchError) {
        
        if ([fetchResults count] > 1) {
             @throw [NSException exceptionWithName:APIncrementalStoreExceptionInconsistency reason:@"More than one cached result for parse object" userInfo:nil];
        
        } else if ([fetchResults count] == 0) {
            
            if (createIfNecessary) {
                managedObject = [NSEntityDescription insertNewObjectForEntityForName:entity.name inManagedObjectContext:context];
                 if (AP_DEBUG_INFO) { ALog(@"New object created: %@",managedObject.objectID)}
                [managedObject setValue:objectUID forKey:APObjectUIDAttributeName];
                
                NSError* permanentIdError;
                [context obtainPermanentIDsForObjects:@[managedObject] error:&permanentIdError];
                // Sanity check
                if (permanentIdError) {
                    [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Could not obtain permanent IDs for objects %@ with error %@", managedObject, permanentIdError];
                }
            }
            
        } else {
            managedObject = [fetchResults lastObject];
        }
    }
    
    return managedObject;
}


- (NSManagedObjectID*) managedObjectIDForObjectUUID: (NSString*) objectUUID
                                             entity: (NSEntityDescription*) entity
                                          inContext: (NSManagedObjectContext*) context
                                  createIfNecessary: (BOOL) createIfNecessary {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    NSManagedObject* managedObject = [self managedObjectForObjectUID:objectUUID entity:entity inContext:context createIfNecessary:YES];
    return managedObject.objectID;
    
}


- (NSDictionary*) serializeParseObject:(PFObject*) parseObject {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    NSMutableDictionary* dictionaryRepresentation = [NSMutableDictionary dictionary];
    [[parseObject allKeys] enumerateObjectsUsingBlock:^(id key, NSUInteger idx, BOOL *stop) {
        id value = [parseObject valueForKey:key];
        
        if ([value isKindOfClass:[PFRelation class]]) {
            
            // To-Many relationsship (need to create an Array of Dictionaries including only the ObjectId
            
            PFRelation* relation = (PFRelation*) value;
            PFQuery* queryForRelatedObjects = [relation query];
            
            // we only need the objectId here.
            [queryForRelatedObjects selectKeys:@[]];
            NSArray* results = [queryForRelatedObjects findObjects];
            
            NSMutableArray* relatedObjects = [[NSMutableArray alloc]initWithCapacity:[results count]];
            for (PFObject* relatedParseObject in results) {
                [relatedObjects addObject:@{APObjectUIDAttributeName:relatedParseObject.objectId}];
            }
            
            dictionaryRepresentation[key] = relatedObjects;
            
        } else if ([value isKindOfClass:[PFFile class]]) {
            PFFile* file = (PFFile*) value;
            NSError* error;
            NSData* fileData = [file getData:&error];
            if (error) {
                *stop = YES;
                NSLog(@"Error getting file from Parse: %@",error);
            }
            dictionaryRepresentation[key] = fileData;
            
        } else if ([value isKindOfClass:[PFObject class]]) {
            
            // To-One relationship
            
            PFObject* relatedParseObject = (PFObject*) value;
            dictionaryRepresentation[key] = @{APObjectUIDAttributeName:relatedParseObject.objectId};
            
        } else if ([value isKindOfClass:[PFACL class]]) {
            
            // Object ACL
            
            
        } else {
            
            // Property
            
            dictionaryRepresentation[key] = value;
        }
    }];
    
    dictionaryRepresentation[APObjectLastModifiedAttributeName] = parseObject.updatedAt;
    dictionaryRepresentation[APObjectUIDAttributeName] = parseObject.objectId;
    
    return dictionaryRepresentation;
}


@end
