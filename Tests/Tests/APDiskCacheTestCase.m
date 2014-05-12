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

@import XCTest;

#import "APDiskCache.h"
#import "APParseConnector.h"

#import "APCommon.h"
#import "NSLogEmoji.h"
#import "UnitTestingCommon.h"

#import "Author.h"
#import "Book.h"


/* Local objects strings */
static NSString* const kAuthorNameLocal = @"J. R. R. Tolkien";
static NSString* const kBookNameLocal1 = @"The Fellowship of the Ring";
static NSString* const kBookNameLocal2 = @"The Two Towers";
static NSString* const kBookNameLocal3 = @"The Return of the King";


/* Including prefix __temp, that identifies that the objects have been crated locally and 
 are yet to obtain permanent objectID from Parse*/
static NSString* const kAuthorObjectUIDLocal = @"__tempkAuthorObjectUIDLocal";
static NSString* const kBookObjectUIDLocal1 = @"__tempkBookObjectUIDLocal1";
static NSString* const kBookObjectUIDLocal2 = @"__tempkBookObjectUIDLocal2";
static NSString* const kBookObjectUIDLocal3 = @"__tempkBookObjectUIDLocal3";

static NSString* const APNSManagedObjectIDKey = @"kAPNSManagedObjectIDKey";

/* Test core data persistant store file name */
static NSString* const APCacheSqliteFile = @"APCacheStore.sqlite";
static NSString* const APTestSqliteFile = @"APTestStore.sqlite";


@interface APDiskCacheTestCase : XCTestCase

@property (nonatomic, strong) APDiskCache* localCache;
@property (nonatomic, strong) APParseConnector* parseConnector;
@property (nonatomic, strong) NSManagedObjectContext* testContext;
@property (nonatomic, strong) NSMutableDictionary* mapManagedObjectIDToObjectUID;

@end


@implementation APDiskCacheTestCase

- (void)setUp {
    
    [super setUp];
    
    if ([APParseApplicationID length] == 0 || [APParseClientKey length] == 0) {
        ELog(@"It seems that you haven't set the correct Parse Keys");
        return;
    }
        
    [Parse setApplicationId:APParseApplicationID clientKey:APParseClientKey];
    
    __weak  typeof(self) weakSelf = self;
    NSString* (^translateBlock)(NSManagedObjectID*) = ^NSString* (NSManagedObjectID* objectID) {
        return weakSelf.mapManagedObjectIDToObjectUID[objectID];
    };
    
    self.parseConnector = [[APParseConnector alloc]initWithAuthenticatedUser:[self authenticatedUser] mergePolicy:APMergePolicyClientWins];
    
    self.localCache = [[APDiskCache alloc]initWithManagedModel:[self testModel]
                                     translateToObjectUIDBlock:translateBlock
                                            localStoreFileName:APCacheSqliteFile
                                          shouldResetCacheFile:YES
                                           webServiceConnector:self.parseConnector];
}


- (void)tearDown {
    
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}


#pragma mark - Tests - Basic Stuff

- (void) testTestContextIsSet {
    XCTAssertNotNil(self.localCache);
}


#pragma mark - Tests - Insert Objects

- (void) testCreateNewObject {
    
    NSError* insertError;
    NSDictionary* sampleRepresentationOfBook1 = [self representationFromManagedObject:[self managedObjectBook1]];
    NSDictionary* sampleRepresentationOfBook2 = [self representationFromManagedObject:[self managedObjectBook2]];
    
    NSArray* representations = @[sampleRepresentationOfBook1,sampleRepresentationOfBook2];
    [self.localCache inserteObjectRepresentations:representations entityName:@"Book" error:&insertError];
    XCTAssertNil(insertError);
    
    NSDictionary* book1Representation = [self.localCache fetchObjectRepresentationForObjectUID:kBookObjectUIDLocal1 entityName:@"Book"];
    XCTAssertTrue([book1Representation[APObjectUIDAttributeName] isEqualToString:kBookObjectUIDLocal1]);
    
    NSDictionary* book2Representation = [self.localCache fetchObjectRepresentationForObjectUID:kBookObjectUIDLocal2 entityName:@"Book"];
    XCTAssertTrue([book2Representation[APObjectUIDAttributeName] isEqualToString:kBookObjectUIDLocal2]);
}


- (void) testCreateNewObjectsWithRelationshipToOne {
    
    NSError* insertError;
    Book* book1 = [self managedObjectBook1];
    Author* author = [self managedObjectAuthor];
    [author addBooksObject:book1];
    
    NSArray* books = [self.testContext executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Book"] error:nil];
    XCTAssertTrue([books count] == 1);
    
    NSArray* authors = [self.testContext executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Author"] error:nil];
    XCTAssertTrue([authors count] == 1);
    
    NSDictionary* representationOfBook1 = [self representationFromManagedObject:book1];
    NSDictionary* representationOfAuthor = [self representationFromManagedObject:author];
    
    [self.localCache inserteObjectRepresentations:@[representationOfBook1] entityName:@"Book" error:&insertError];
    XCTAssertNil(insertError);
    
    [self.localCache inserteObjectRepresentations:@[representationOfAuthor] entityName:@"Author" error:&insertError];
    XCTAssertNil(insertError);
    
    NSDictionary* fetchedBook1Representation = [self.localCache fetchObjectRepresentationForObjectUID:kBookObjectUIDLocal1 entityName:@"Book"];
    XCTAssertTrue([fetchedBook1Representation[APObjectUIDAttributeName] isEqualToString:kBookObjectUIDLocal1]);
    
    NSDictionary* fetchedAuthorRepresentation = [self.localCache fetchObjectRepresentationForObjectUID:kAuthorObjectUIDLocal entityName:@"Author"];
    XCTAssertTrue([fetchedAuthorRepresentation[APObjectUIDAttributeName] isEqualToString:kAuthorObjectUIDLocal]);
    
    NSArray* booksRelatedToAuthor = fetchedAuthorRepresentation[@"books"];
    XCTAssertTrue ([booksRelatedToAuthor count] == 1);
    
    // Inverse relationship To-One
    NSString* authorObjectUID = [[fetchedBook1Representation[@"author"]allValues]lastObject];
    XCTAssertTrue ([authorObjectUID isEqualToString:kAuthorObjectUIDLocal]);
}


- (void) testCreateNewObjectsWithRelationshipToMany {
    
    NSError* insertError;
    Book* book1 = [self managedObjectBook1];
    Book* book2 = [self managedObjectBook2];
    Author* author = [self managedObjectAuthor];
    [author addBooksObject:book1];
    [author addBooksObject:book2];
    
    NSDictionary* representationOfBook1 = [self representationFromManagedObject:book1];
    NSDictionary* representationOfBook2 = [self representationFromManagedObject:book2];
    NSDictionary* representationOfAuthor = [self representationFromManagedObject:author];
    
    NSArray* booksRepresentations = @[representationOfBook1,representationOfBook2];
    [self.localCache inserteObjectRepresentations:booksRepresentations entityName:@"Book" error:&insertError];
    XCTAssertNil(insertError);
    
    [self.localCache inserteObjectRepresentations:@[representationOfAuthor] entityName:@"Author" error:&insertError];
    XCTAssertNil(insertError);
    
    NSDictionary* fetchedBook1Representation = [self.localCache fetchObjectRepresentationForObjectUID:kBookObjectUIDLocal1 entityName:@"Book"];
    XCTAssertTrue([fetchedBook1Representation[APObjectUIDAttributeName] isEqualToString:kBookObjectUIDLocal1]);
    
    NSDictionary* fetchedBook2Representation = [self.localCache fetchObjectRepresentationForObjectUID:kBookObjectUIDLocal2 entityName:@"Book"];
    XCTAssertTrue([fetchedBook2Representation[APObjectUIDAttributeName] isEqualToString:kBookObjectUIDLocal2]);
    
    NSDictionary* fetchedAuthorRepresentation = [self.localCache fetchObjectRepresentationForObjectUID:kAuthorObjectUIDLocal entityName:@"Author"];
    XCTAssertTrue([fetchedAuthorRepresentation[APObjectUIDAttributeName] isEqualToString:kAuthorObjectUIDLocal]);
    
    // To-Many
    NSDictionary* booksRelatedToAuthor = fetchedAuthorRepresentation[@"books"];
    XCTAssertTrue ([[booksRelatedToAuthor allKeys]count] == 1);
    XCTAssertTrue ([[[booksRelatedToAuthor allValues]lastObject]count] == 2);
    
    // Inverse relationship To-One
    XCTAssertTrue ([[[fetchedBook1Representation[@"author"]allValues]lastObject] isEqualToString:kAuthorObjectUIDLocal]);
    XCTAssertTrue ([[[fetchedBook2Representation[@"author"]allValues]lastObject] isEqualToString:kAuthorObjectUIDLocal]);
}


- (void) testUpdateExistingObject {
    
    // Insert a new book
    NSError* error;
    NSDictionary* book1Representation = [self representationFromManagedObject:[self managedObjectBook1]];
    [self.localCache inserteObjectRepresentations:@[book1Representation] entityName:@"Book" error:&error];
    XCTAssertNil(error);
    
    // Fetch it again
    NSMutableDictionary* fetchedBook1Representation = [[self.localCache fetchObjectRepresentationForObjectUID:kBookObjectUIDLocal1 entityName:@"Book"]mutableCopy];
    XCTAssertTrue([fetchedBook1Representation[APObjectUIDAttributeName] isEqualToString:kBookObjectUIDLocal1]);
    
    // Change an attribute
    fetchedBook1Representation[@"name"] = kBookNameLocal2;
    [self.localCache updateObjectRepresentations:@[fetchedBook1Representation] entityName:@"Book" error:&error];
    XCTAssertNil(error);
    
    // Fetch the updated representation
    NSDictionary* updatedBook1Representation = [self.localCache fetchObjectRepresentationForObjectUID:kBookObjectUIDLocal1 entityName:@"Book"];
    XCTAssertTrue([updatedBook1Representation[@"name"] isEqualToString:kBookNameLocal2]);
}


- (void) testDeleteExistingObject {
    
    // Insert a new book
    NSError* error;
    NSDictionary* book1Representation = [self representationFromManagedObject:[self managedObjectBook1]];
    [self.localCache inserteObjectRepresentations:@[book1Representation] entityName:@"Book" error:&error];
    XCTAssertNil(error);
    
    // Fetch it again
    NSMutableDictionary* fetchedBook1Representation = [[self.localCache fetchObjectRepresentationForObjectUID:kBookObjectUIDLocal1 entityName:@"Book"]mutableCopy];
    XCTAssertTrue([fetchedBook1Representation[APObjectUIDAttributeName] isEqualToString:kBookObjectUIDLocal1]);
    
    // Change an attribute
    [self.localCache deleteObjectRepresentations:@[fetchedBook1Representation] entityName:@"Book" error:&error];
    XCTAssertNil(error);
    
    // Fetch the updated representation
    NSDictionary* deletedBook1Representation = [self.localCache fetchObjectRepresentationForObjectUID:kBookObjectUIDLocal1 entityName:@"Book"];
    XCTAssertNil(deletedBook1Representation);
}


- (void) testFetchUsingPredicate {
    
    NSError* error;
    NSDictionary* sampleRepresentationOfBook1 = [self representationFromManagedObject:[self managedObjectBook1]];
    NSDictionary* sampleRepresentationOfBook2 = [self representationFromManagedObject:[self managedObjectBook2]];
    
    NSArray* representations = @[sampleRepresentationOfBook1,sampleRepresentationOfBook2];
    [self.localCache inserteObjectRepresentations:representations entityName:@"Book" error:&error];
    XCTAssertNil(error);
    
    Book* book1 = [self managedObjectBook1];
    NSFetchRequest* fr = [NSFetchRequest fetchRequestWithEntityName:@"Book"];
    fr.predicate = [NSPredicate predicateWithFormat:@"self == %@",book1];
    NSArray* results = [self.localCache fetchObjectRepresentations:fr error:&error];
    NSDictionary* fetchedRepresentationOfBook1 = [results lastObject];
    XCTAssertTrue([fetchedRepresentationOfBook1[APObjectUIDAttributeName] isEqualToString:kBookObjectUIDLocal1]);
}


- (void) testCountUsingPredicate {

    NSError* error;
    NSDictionary* sampleRepresentationOfBook1 = [self representationFromManagedObject:[self managedObjectBook1]];
    NSDictionary* sampleRepresentationOfBook2 = [self representationFromManagedObject:[self managedObjectBook2]];
    
    NSArray* representations = @[sampleRepresentationOfBook1,sampleRepresentationOfBook2];
    [self.localCache inserteObjectRepresentations:representations entityName:@"Book" error:&error];
    XCTAssertNil(error);
    
    NSFetchRequest* fr = [NSFetchRequest fetchRequestWithEntityName:@"Book"];
    NSUInteger numberOfBooks = [self.localCache countObjectRepresentations:fr error:&error];
    XCTAssertTrue(numberOfBooks == 2);
}


#pragma mark - Support Methods

- (NSMutableDictionary*) mapManagedObjectIDToObjectUID {
    
    if (!_mapManagedObjectIDToObjectUID) {
        _mapManagedObjectIDToObjectUID = [NSMutableDictionary dictionary];
    }
    return _mapManagedObjectIDToObjectUID;
}


- (Book*) managedObjectBook1 {
    
    Book* book = [NSEntityDescription insertNewObjectForEntityForName:@"Book" inManagedObjectContext:self.testContext];
    book.name = kBookNameLocal1;
    [self.mapManagedObjectIDToObjectUID setObject:kBookObjectUIDLocal1 forKey:book.objectID];
    return book;
}


- (Book*) managedObjectBook2 {
    
    Book* book = [NSEntityDescription insertNewObjectForEntityForName:@"Book" inManagedObjectContext:self.testContext];
    book.name = kBookNameLocal2;
    [self.mapManagedObjectIDToObjectUID setObject:kBookObjectUIDLocal2 forKey:book.objectID];
    return book;
}

- (Author*) managedObjectAuthor {
    
    Author* author = [NSEntityDescription insertNewObjectForEntityForName:@"Author" inManagedObjectContext:self.testContext];
    author.name = kAuthorNameLocal;
    [self.mapManagedObjectIDToObjectUID setObject:kAuthorObjectUIDLocal forKey:author.objectID];
    return author;
}


- (PFUser*) authenticatedUser {
    
    __block PFUser* user;
    
    // All tests will be conducted in background to enable us to supress the annoying Parse SDK warning
    // complening that we are running long calls in the main thread.
    dispatch_queue_t queue = dispatch_queue_create("parseConnectorTestCase", NULL);
    dispatch_group_t group = dispatch_group_create();
    
    dispatch_group_async(group, queue, ^{
        
        NSError* authError;
        user = [PFUser logInWithUsername:APUnitTestingParseUserName password:APUnitTestingParsePassword error:&authError];
        if (user) {
            DLog(@"User has been authenticated:%@",user.username);
        } else {
            ELog(@"Authentication error: %@",authError);
        }
    });
    
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    
    return user;
    
}


#pragma mark Core Data
- (NSManagedObjectContext*) testContext {
    
    if (!_testContext) {
        NSPersistentStoreCoordinator* psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:[self testModel]];
//        NSDictionary *options = @{NSMigratePersistentStoresAutomaticallyOption: @YES,
//                                  NSInferMappingModelAutomaticallyOption: @YES,
//                                  NSSQLitePragmasOption:@{@"journal_mode":@"DELETE"}};
        NSURL *storeURL = [NSURL fileURLWithPath:[self pathToLocalStore]];
        
        NSError *error = nil;
        [psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:nil error:&error];
        
        if (error) {
            ELog(@"Error adding store to PSC:%@",error);
        }
        
        _testContext = [[NSManagedObjectContext alloc]initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        _testContext.persistentStoreCoordinator = psc;
    }
    return _testContext;
}

- (NSString *)documentsDirectory {
    
    NSString *documentsDirectory = nil;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    documentsDirectory = paths[0];
    return documentsDirectory;
}


- (NSString *)pathToLocalStore {
    
    return [[self documentsDirectory] stringByAppendingPathComponent:APTestSqliteFile];
}


#pragma mark - APIncrementalStore Copied Methods

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
       [representation setValue:self.mapManagedObjectIDToObjectUID[managedObject.objectID] forKey:APObjectUIDAttributeName];
        if ([propertyDescription isKindOfClass:[NSAttributeDescription class]]) {
            
            // Attribute
            representation[propertyName] = [managedObject primitiveValueForKey:propertyName] ?: [NSNull null];
            
            
        } else if ([propertyDescription isKindOfClass:[NSRelationshipDescription class]]) {
            NSRelationshipDescription* relationshipDescription = (NSRelationshipDescription*) propertyDescription;
            
            if (!relationshipDescription.isToMany) {
                
                // To-One
                
                NSManagedObject* relatedObject = [managedObject primitiveValueForKey:propertyName];
                
                if (relatedObject) {
                     NSString* objectUID = self.mapManagedObjectIDToObjectUID[relatedObject.objectID];
                    representation[propertyName] = @{relationshipDescription.destinationEntity.name:objectUID};
                } else {
                    representation[propertyName] = [NSNull null];
                }
                
            } else {
                
                // To-Many
                
                NSSet* relatedObjects = [managedObject primitiveValueForKey:propertyName];
                __block NSMutableDictionary* relatedObjectsRepresentation = [[NSMutableDictionary alloc] initWithCapacity:[relatedObjects count]];
                
                [relatedObjects enumerateObjectsUsingBlock:^(NSManagedObject* relatedObject, BOOL *stop) {
                    NSString* objectUID = self.mapManagedObjectIDToObjectUID[relatedObject.objectID];
                    NSMutableArray* relatedObjectsUIDs = [relatedObjectsRepresentation objectForKey:relationshipDescription.destinationEntity.name] ?: [NSMutableArray array];
                    [relatedObjectsUIDs addObject:objectUID];
                    [relatedObjectsRepresentation setObject:relatedObjectsUIDs forKey:relationshipDescription.destinationEntity.name];
                }];
                representation[propertyName] = relatedObjectsRepresentation;
            }
        }
        [managedObject didAccessValueForKey:propertyName];
    }];
    return representation;
}


- (NSManagedObjectModel*) testModel {
    
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSManagedObjectModel* model = [NSManagedObjectModel mergedModelFromBundles:@[bundle]];
    return model;
}

                    
                    

@end
