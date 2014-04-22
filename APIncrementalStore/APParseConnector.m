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

// NSUserDefaults entry to reference the earliest object date synced from Parse.
static NSString* const APLatestObjectSyncedKey = @"com.apetis.apincrementalstore.parseconnector.request.latestobjectsynced.key";

/* 
 It specifies the maximum number of objects that a sinble parse query should return when executed. 
 If there are more objects than this limit it will be fetched in batches. 
 Parse specifies that 100 is the default but can be increased to maximum 1000.
 */
static NSUInteger const APParseQueryFetchLimit = 100;


@interface APParseConnector()

@property (strong,nonatomic) PFUser* authenticatedUser;
@property (assign,nonatomic) APMergePolicy mergePolicy;

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


#pragma mark - APIncrementalStoreConnector Protocol

- (void) setMergePolicy:(APMergePolicy)mergePolicy {
    
    _mergePolicy = mergePolicy;
}


- (NSDictionary*) mergeRemoteObjectsWithContext:(NSManagedObjectContext*) context
                                       fullSync:(BOOL) fullSync
                                   onSyncObject:(void(^)(void)) onSyncObject
                                          error:(NSError*__autoreleasing*) error {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    __block NSError* localError;
    
    if (![self isUserAuthenticated:&localError]) {
        *error = localError;
        return NO;
    }
    
    __block NSMutableDictionary* mergedObjectsUIDsNestedByEntityName = [NSMutableDictionary dictionary];
    NSManagedObjectModel* model = context.persistentStoreCoordinator.managedObjectModel;
    NSArray* sortedEntities = [[model entities]sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]]];
    
    for (NSEntityDescription* entityDescription in sortedEntities) {
        PFQuery *query = [PFQuery queryWithClassName:entityDescription.name];
        
        if (!fullSync) {
            NSDate* lastSync = [self latestObjectSyncedDateForEntityName:entityDescription.name];
            if (lastSync) {
                [query whereKey:@"updatedAt" greaterThan:lastSync];
            }
        }
        
        // We count the object before fetching (see APParseQueryFetchLimit explanation)
        NSUInteger numberOfObjectsToBeFetched = [query countObjects:&localError];
        if (localError) {
            *error = localError;
            return nil;
        }
        NSMutableArray* parseObjects = [[NSMutableArray alloc]initWithCapacity:numberOfObjectsToBeFetched];
        
        NSUInteger skip = 0;
        while (skip < numberOfObjectsToBeFetched) {
            [query setSkip:skip];
            NSArray* batchOfObjects = [query findObjects:&localError];
            
            if (localError) {
                *error = localError;
                return nil;
            }
            [parseObjects addObjectsFromArray:batchOfObjects];
            skip += APParseQueryFetchLimit;
        }
        
        for (PFObject* parseObject in parseObjects) {
            NSManagedObject* managedObject = [self managedObjectForObjectUID:[parseObject valueForKey:APObjectUIDAttributeName] entity:entityDescription inContext:context createIfNecessary:NO];
            [self setLatestObjectSyncedDate:parseObject.updatedAt forEntityName:entityDescription.name];
            
            if ([[managedObject valueForKey:APObjectLastModifiedAttributeName] isEqualToDate:parseObject.updatedAt]){
                //Object was inserted/updated during -[ParseConnector mergeManagedContext:onSyncObject:onSyncObject:error:] and remains the same
                continue;
            }
            
            NSString* objectStatus;
            BOOL parseObjectIsDeleted = [[parseObject valueForKey:APObjectIsDeletedAttributeName]isEqualToNumber:@YES];
            NSMutableDictionary* entityEntry =  mergedObjectsUIDsNestedByEntityName[entityDescription.name] ?: [NSMutableDictionary dictionary];
            
            if (!managedObject) {
                
                // Disk cache managed object doesn't exist - create it localy if it isn't marked as deleted
                
                if (parseObjectIsDeleted) {
                    objectStatus = NSDeletedObjectsKey;
                    
                } else {
                    managedObject = [NSEntityDescription insertNewObjectForEntityForName:entityDescription.name inManagedObjectContext:context];
                    [managedObject setValue:@YES forKeyPath:APObjectIsCreatedRemotelyAttributeName];
                    
                    if (![context obtainPermanentIDsForObjects:@[managedObject] error:&localError]) {
                        [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Could not obtain permanent IDs for objects %@ with error %@", managedObject, localError];
                    }
                    
                    [self populateManagedObject:managedObject withSerializedParseObject:[self serializeParseObject:parseObject] onInsertedRelatedObject:^(NSManagedObject *insertedObject) {
                        
                        // Include an entry for the inserted object into the returning NSDictionary
                        // if any related objects isn't relflected locally yet
                        
                        NSMutableDictionary* relatedEntityEntry = mergedObjectsUIDsNestedByEntityName[insertedObject.entity.name] ?: [NSMutableDictionary dictionary];
                        NSArray* mergedObjectUIDs = relatedEntityEntry[NSInsertedObjectsKey] ?: [[NSArray alloc]init];
                        NSString* relatedObjectObjectID = [insertedObject valueForKey:APObjectUIDAttributeName];
                        relatedEntityEntry[NSInsertedObjectsKey] = [mergedObjectUIDs arrayByAddingObject:relatedObjectObjectID];
                        mergedObjectsUIDsNestedByEntityName[insertedObject.entity.name] = relatedEntityEntry;
                    }];
                    objectStatus = NSInsertedObjectsKey;
                }
                
            } else {
                
                // Existing local object
                
                if (parseObjectIsDeleted) {
                    [context deleteObject:managedObject];
                     objectStatus = NSDeletedObjectsKey;
                    
                } else {
                   [self populateManagedObject:managedObject withSerializedParseObject:[self serializeParseObject:parseObject] onInsertedRelatedObject:^(NSManagedObject *insertedObject) {
                       
                       /// Include an entry for the inserterd into the return NSDictionary if any related objects isn't relflected locally yet
                       
                       NSMutableDictionary* relatedEntityEntry = mergedObjectsUIDsNestedByEntityName[insertedObject.entity.name] ?: [NSMutableDictionary dictionary];
                       NSArray* mergedObjectUIDs = relatedEntityEntry[NSInsertedObjectsKey] ?: [[NSArray alloc]init];
                       NSString* relatedObjectObjectID = [insertedObject valueForKey:APObjectUIDAttributeName];
                       relatedEntityEntry[NSInsertedObjectsKey] = [mergedObjectUIDs arrayByAddingObject:relatedObjectObjectID];
                       mergedObjectsUIDsNestedByEntityName[insertedObject.entity.name] = relatedEntityEntry;
                   }];
                    objectStatus = NSUpdatedObjectsKey;
                }
            }
            
            // Include an entry into the return NSDictionary for the corresponding object status
            
            if (![entityEntry[NSInsertedObjectsKey] containsObject:[parseObject valueForKey:APObjectUIDAttributeName]]) {
                NSArray* mergedObjectUIDs = entityEntry[objectStatus] ?: [[NSArray alloc]init];
                entityEntry[objectStatus] = [mergedObjectUIDs arrayByAddingObject:[parseObject valueForKey:APObjectUIDAttributeName]];
                
                /* We need to include any existent reference to temporary IDs as well, 
                 otherwise context still holding reference to temporary managed object ID 
                 will not update those objects
                 */
//                if ([objectStatus isEqualToString:NSDeletedObjectsKey] || [objectStatus isEqualToString:NSUpdatedObjectsKey]) {
//                    if ([[self.mapOfTemporaryToPermanentUID allValues]containsObject:parseObject.objectId]) {
//                        NSString* key = [[self.mapOfTemporaryToPermanentUID allKeysForObject:parseObject.objectId]lastObject];
//                        NSArray* mergedObjectUIDs = entityEntry[objectStatus];
//                        entityEntry[objectStatus] = [mergedObjectUIDs arrayByAddingObject:key];
//                    }
//                }
                mergedObjectsUIDsNestedByEntityName[entityDescription.name] = entityEntry;
            }
            if (onSyncObject) onSyncObject();
        }
        
        /*
         WARNING
         Unit testing - [APParseConnectorTestCase testMergingWithOtherClientMergingSimultaneously]
         Do not let this uncommented if you are not executing this very specif test
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
    return  mergedObjectsUIDsNestedByEntityName;
}


- (BOOL) mergeManagedContext:(NSManagedObjectContext *)context
                onSyncObject:(void (^)(void)) onSyncObject
                       error:(NSError*__autoreleasing*) error {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    __block BOOL success = YES;
    __block NSError* localError;
    
    if (![self isUserAuthenticated:&localError]) {
        *error = localError;
        return NO;
    }
    
    NSArray* dirtyManagedObjects = [self managedObjectsMarkedAsDirtyInContext:context];
    
    [dirtyManagedObjects enumerateObjectsUsingBlock:^(NSManagedObject* managedObject, NSUInteger idx, BOOL *stop) {
        if (AP_DEBUG_INFO) { DLog(@"Merging: %@", managedObject)}
        
        void (^reportErrorStopEnumerating)() = ^{
            if (AP_DEBUG_ERRORS) {ELog(@"Error merging object: %@",managedObject)};
            *stop = YES;
            success = NO;
            *error = localError;
        };
        
        NSString* objectUID = [managedObject valueForKey:APObjectUIDAttributeName];
        
        // Sanity check
        if (!objectUID) {
            [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Managed object without objectUID associated??"];
        }
        
        if ([[managedObject valueForKey:APObjectIsCreatedRemotelyAttributeName] isEqualToNumber:@NO]) {
            
            // New object created localy
            
            if ([[managedObject valueForKey:APObjectIsDeletedAttributeName] isEqualToNumber:@YES]) {
                
                // Object was deleted before even synced with Parse, just delete it.
                [context deleteObject:managedObject];
                
            } else {
                [self insertOnParseManagedObject:managedObject error:&localError];
                if (localError) {
                    reportErrorStopEnumerating();
                } else {
                    [managedObject setValue:@NO forKey:APObjectIsDirtyAttributeName];
                }
            }
        
        } else {
            PFObject* parseObject = [self parseObjectFromClassName:managedObject.entity.name objectUID:objectUID];
            
            if (!parseObject) {
                
                // Object doesn't exist at Parse anymore
                
                [context deleteObject:managedObject];
                if (AP_DEBUG_INFO) { DLog(@"Object no longer exists at Parse , deleting from context: %@ ", managedObject)}
                
            } else {
                NSDate* localObjectUpdatedAt = [managedObject valueForKey:APObjectLastModifiedAttributeName];
                if (AP_DEBUG_INFO) { DLog(@"Parse equivalent object: %@ ", parseObject)}
                
                /*
                 If the object has not been updated since last time we read it from Parse
                 we are safe to updated it. If the object APObjectIsDeleted is set to YES
                 then we save it back to the server to let the others known that it should be
                 deleted and finally we remove it from our disk cache.
                 */
                
                if ([parseObject.updatedAt isEqualToDate:localObjectUpdatedAt] || localObjectUpdatedAt == nil) {
                    [self populateParseObject:parseObject withManagedObject:managedObject error:&localError];
                     if (AP_DEBUG_INFO) { DLog(@"Object remains the same, we are good to merge it")}
                    
                    if (localError) {
                        reportErrorStopEnumerating();
                   
                    } else {
                        
                        if (![parseObject save:&localError]) {
                            reportErrorStopEnumerating();
                            
                        } else {
                            [managedObject setValue:@NO forKey:APObjectIsDirtyAttributeName];
                            [managedObject setValue:parseObject.updatedAt forKey:APObjectLastModifiedAttributeName];
                        }
                    }
                    
                } else {
                    
                    // Conflict detected
                    
                    if (AP_DEBUG_INFO) { ALog(@"Conflict detected - Dates: parseObject %@ - localObject: %@ ",parseObject.updatedAt,localObjectUpdatedAt)}
                    
                    if (self.mergePolicy == APMergePolicyClientWins) {
                        
                        if (AP_DEBUG_INFO) { DLog(@"APMergePolicyClientWins")}
                        [self populateParseObject:parseObject withManagedObject:managedObject error:&localError];
                        
                        if (![parseObject save:&localError]) {
                            reportErrorStopEnumerating();
                        } else {
                            if ([[managedObject valueForKey:APObjectIsDeletedAttributeName] isEqualToNumber:@YES]) {
                                [context deleteObject:managedObject];
                            } else {
                                [managedObject setValue:@NO forKey:APObjectIsDirtyAttributeName];
                                [managedObject setValue:parseObject.updatedAt forKey:APObjectLastModifiedAttributeName];
                            }
                        }
                        
                    } else if (self.mergePolicy == APMergePolicyServerWins) {
                        
                        if (AP_DEBUG_INFO) { DLog(@"APMergePolicyServerWins")}
                        [self populateManagedObject:managedObject withSerializedParseObject:[self serializeParseObject:parseObject] onInsertedRelatedObject:nil];
                        [managedObject setValue:@NO forKey:APObjectIsDirtyAttributeName];
                        [managedObject setValue:parseObject.updatedAt forKey:APObjectLastModifiedAttributeName];
                        
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

- (void) insertOnParseManagedObject:(NSManagedObject*) managedObject
                              error:(NSError *__autoreleasing*)error {
    
    if (AP_DEBUG_METHODS) { MLog(@"Managed Object:%@",managedObject)}
    
    NSError* localError;
    
    PFObject* parseObject = [[PFObject alloc]initWithClassName:managedObject.entity.name];
    [self populateParseObject:parseObject withManagedObject:managedObject error:&localError];
   
    if (!localError) {
        
        if ([parseObject save:&localError]) {
            if (AP_DEBUG_INFO) { DLog(@"Parse object saved: %@",parseObject)}
            
            /* Parse sets the objectId and updatedAt for a new object only after we save it. */
            [managedObject setValue:parseObject.updatedAt forKey:APObjectLastModifiedAttributeName];
            [managedObject setValue:@YES forKey:APObjectIsCreatedRemotelyAttributeName];
            
        } else {
             *error = localError;
        }
    }
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
    [query whereKey:APObjectUIDAttributeName equalTo:objectUID];
    
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
    
     if (AP_DEBUG_INFO) {DLog(@"Parse object %@ retrieved: %@",parseObject.parseClassName, [parseObject valueForKey:APObjectUIDAttributeName])}
    return parseObject;
}


- (void) populateManagedObject:(NSManagedObject*) managedObject
     withSerializedParseObject:(NSDictionary*) parseObjectDictRepresentation
       onInsertedRelatedObject:(void(^)(NSManagedObject* insertedObject)) block {
    
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
                        NSString* objectUID = [dictParseObject valueForKey:APObjectUIDAttributeName];
                        NSManagedObject* relatedManagedObject;
                        relatedManagedObject = [self managedObjectForObjectUID:objectUID entity:relationshipDescription.destinationEntity inContext:managedObject.managedObjectContext createIfNecessary:NO];
                        if (!relatedManagedObject) {
                            relatedManagedObject = [self managedObjectForObjectUID:objectUID entity:relationshipDescription.destinationEntity inContext:managedObject.managedObjectContext createIfNecessary:YES];
                            [relatedManagedObject setValue:@YES forKeyPath:APObjectIsCreatedRemotelyAttributeName];
                            if (block) block(relatedManagedObject);
                        }
                        [relatedManagedObjects addObject:relatedManagedObject];
                    }
                    
                    [managedObject setValue:relatedManagedObjects forKey:propertyName];
                    
                } else {
                    NSString* objectUID = [parseObjectValue valueForKey:APObjectUIDAttributeName];
                    if ([objectUID isKindOfClass:[NSString class]] == NO) {
                        [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Check your model, received an invalid Parse ObjectID for a To-One relationship. Only Parse pointer relationships are valid for To-One CoreData relationships"];
                    }
                    NSManagedObject* relatedManagedObject;
                    relatedManagedObject = [self managedObjectForObjectUID:objectUID entity:relationshipDescription.destinationEntity inContext:managedObject.managedObjectContext createIfNecessary:NO];
                    if (!relatedManagedObject) {
                        relatedManagedObject = [self managedObjectForObjectUID:objectUID entity:relationshipDescription.destinationEntity inContext:managedObject.managedObjectContext createIfNecessary:YES];
                        [relatedManagedObject setValue:@YES forKeyPath:APObjectIsCreatedRemotelyAttributeName];
                        if (block) block(relatedManagedObject);
                    }
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
    
    __block NSError* localError;
    
    NSMutableDictionary* mutableProperties = [[managedObject.entity propertiesByName]mutableCopy];
    //[mutableProperties removeObjectForKey:APObjectUIDAttributeName];
    [mutableProperties removeObjectForKey:APObjectLastModifiedAttributeName];
    [mutableProperties removeObjectForKey:APObjectIsDirtyAttributeName];
    [mutableProperties removeObjectForKey:APObjectIsCreatedRemotelyAttributeName];
    
    [mutableProperties enumerateKeysAndObjectsUsingBlock:^(NSString* propertyName, NSPropertyDescription* propertyDesctiption, BOOL *stop) {
        id propertyValue = [managedObject valueForKey:propertyName];
        
        if ([propertyDesctiption isKindOfClass:[NSAttributeDescription class]]) {
            NSAttributeDescription* attrDescription = (NSAttributeDescription*) propertyDesctiption;
            
            if (propertyValue == nil) {
                [parseObject setValue:[NSNull null] forKey:propertyName];
                
            } else {
                
                if (attrDescription.attributeType == NSBooleanAttributeType) {
                    [parseObject setValue:@([propertyValue boolValue]) forKey:propertyName];
                
                } else if (attrDescription.attributeType == NSBinaryDataAttributeType ||
                           attrDescription.attributeType == NSTransformableAttributeType) {
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
                        
                        if ([[relatedManagedObject valueForKey:APObjectIsCreatedRemotelyAttributeName]isEqualToNumber:@NO]) {
                            relatedParseObject = [PFObject objectWithClassName:relatedManagedObject.entity.name];
                            [relatedParseObject setValue:relatedObjectUID forKey:APObjectUIDAttributeName];

                            [relatedParseObject save:&localError];
                            if (localError) {
                                *error = localError;
                                *stop = YES;
                            }
                            [relatedManagedObject setValue:relatedParseObject.updatedAt forKey:APObjectLastModifiedAttributeName];
                            [relatedManagedObject setValue:@YES forKey:APObjectIsCreatedRemotelyAttributeName];
                        
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
                    
                    if ([[relatedManagedObject valueForKey:APObjectIsCreatedRemotelyAttributeName]isEqualToNumber:@NO]) {
                        relatedParseObject = [PFObject objectWithClassName:relatedManagedObject.entity.name];
                        [relatedParseObject setValue:relatedObjectUID forKey:APObjectUIDAttributeName];
                        [relatedParseObject save:&localError];
                        if (localError) {
                            *error = localError;
                            return;
                        }
                        [relatedManagedObject setValue:relatedParseObject.updatedAt forKey:APObjectLastModifiedAttributeName];
                        [relatedManagedObject setValue:@YES forKey:APObjectIsCreatedRemotelyAttributeName];
                        
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


- (NSManagedObject*) managedObjectForObjectUID:(NSString*) objectUID
                                        entity:(NSEntityDescription*) entity
                                     inContext:(NSManagedObjectContext*) context
                             createIfNecessary:(BOOL) createIfNecessary {
    
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
                 if (AP_DEBUG_INFO) { DLog(@"New object created: %@",managedObject.objectID)}
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


- (NSDictionary*) serializeParseObject:(PFObject*) parseObject {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    NSMutableDictionary* dictionaryRepresentation = [NSMutableDictionary dictionary];
    [[parseObject allKeys] enumerateObjectsUsingBlock:^(id key, NSUInteger idx, BOOL *stop) {
        id value = [parseObject valueForKey:key];
        
        if ([value isKindOfClass:[PFRelation class]]) {
            
            // To-Many relationsship (need to create an Array of Dictionaries including only the ObjectId
            
            PFRelation* relation = (PFRelation*) value;
            PFQuery* queryForRelatedObjects = [relation query];
            
            [queryForRelatedObjects selectKeys:@[APObjectUIDAttributeName]];
            NSArray* results = [queryForRelatedObjects findObjects];
            
            NSMutableArray* relatedObjects = [[NSMutableArray alloc]initWithCapacity:[results count]];
            for (PFObject* relatedParseObject in results) {
                [relatedObjects addObject:@{APObjectUIDAttributeName:[relatedParseObject valueForKey:APObjectUIDAttributeName]}];
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
            [relatedParseObject fetchIfNeeded];
            dictionaryRepresentation[key] = @{APObjectUIDAttributeName:[relatedParseObject valueForKey:APObjectUIDAttributeName]};
            
        } else if ([value isKindOfClass:[PFACL class]]) {
            
            // Object ACL
            
            
        } else {
            
            // Property
            
            dictionaryRepresentation[key] = value;
        }
    }];
    
    dictionaryRepresentation[APObjectLastModifiedAttributeName] = parseObject.updatedAt;
    dictionaryRepresentation[APObjectUIDAttributeName] = [parseObject valueForKey:APObjectUIDAttributeName];
    
    return dictionaryRepresentation;
}


@end
