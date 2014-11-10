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
@import CoreData;

#import "APParseSyncOperation.h"

#import "NSLogEmoji.h"
#import "APCommon.h"
#import "APError.h"

#import "Author.h"
#import "Book.h"
#import "Page.h"
#import "EBook.h" //SubEntity of Book
#import "Magazine.h" //Has relationship to Author as a Array at Parse

#import "UnitTestingCommon.h"

#define WAIT_PATIENTLY [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]

/* Parse objects strings */
static NSString* const kAuthorNameParse = @"George R. R. Martin";
static NSString* const kBookNameParse1 = @"A Game of Thrones";
static NSString* const kBookNameParse2 = @"A Clash of Kings";
static NSString* const kBookNameParse3 = @"A Storm of Swords";
static NSString* const kBookNameParse4 = @"A Feast for Crows";

/* Local objects strings */
static NSString* const kAuthorNameLocal = @"J. R. R. Tolkien";
static NSString* const kAuthorNameLocal2 = @"J. R. R. Tolkien Brother";
static NSString* const kBookNameLocal1 = @"The Fellowship of the Ring";
static NSString* const kBookNameLocal2 = @"The Two Towers";
static NSString* const kBookNameLocal3 = @"The Return of the King";
static NSString* const kMagazineNameLocal1 = @"Playboy";

/* Test core data persistent store file name */
static NSString* const testSqliteFile = @"APParseConnectorTestFile.sqlite";


@interface APParseConnectorTestCase : XCTestCase

@property (strong, nonatomic) NSManagedObjectModel* testModel;
@property (strong, nonatomic) NSManagedObjectContext* testContext;
@property (strong, nonatomic) NSPersistentStoreCoordinator* syncPSC;
@property (strong, nonatomic) NSOperationQueue* syncQueue;

@end


@implementation APParseConnectorTestCase

#pragma mark - Set up

- (void)setUp {
    
    MLog();
    
    [super setUp];
    
    AP_DEBUG_METHODS = YES;
    
    if ([APParseApplicationID length] == 0 || [APParseClientKey length] == 0) {
        ELog(@"It seems that you haven't set the correct Parse Keys");
        return;
    }
    
    [Parse setApplicationId:APParseApplicationID clientKey:APParseClientKey];
    
    // Remove SQLite file
    [self removeCacheStore];
    
    // Remove last sync date for entities timestamps
    [[NSUserDefaults standardUserDefaults]removeObjectForKey:@"APEarliestObjectSyncedKey"];
    
    /* 
     All tests will be conducted in background to enable us to supress the *$@%@$ Parse SDK warning
     complaning that we are running long calls in the main thread.
     */
    dispatch_queue_t queue = dispatch_queue_create("parseConnectorTestCase", NULL);
    dispatch_group_t group = dispatch_group_create();
    
   // [Parse setApplicationId:APUnitTestingParsepApplicationId clientKey:APUnitTestingParseClientKey];
    
    dispatch_group_async(group, queue, ^{
        
        PFUser* authenticatedUser = [PFUser logInWithUsername:APUnitTestingParseUserName password:APUnitTestingParsePassword];
        if (!authenticatedUser){
            ELog(@"User is authenticated, check credentials");
        } else {
            DLog(@"User has been authenticated:%@",authenticatedUser.username);
        }
        
        [self removeAllEntriesFromParse];
        NSError* saveError = nil;
        
        /*
         Create Parse Objects and their relationships
         
         ----------       --------
         | Author |<---->>| Book |
         ----------       --------
         
         */
        
        PFObject* book1 = [PFObject objectWithClassName:@"Book"];
        [book1 setValue:kBookNameParse1 forKey:@"name"];
        [book1 setValue:@(APObjectStatusCreated) forKey:APObjectStatusAttributeName];
        [book1 setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
        [book1 setValue:@"Book" forKeyPath:APObjectEntityNameAttributeName];
        [book1 save:&saveError];
        DLog(@"Book %@ has been created",kBookNameParse1);
        
        PFObject* book2 = [PFObject objectWithClassName:@"Book"];
        [book2 setValue:kBookNameParse2 forKey:@"name"];
        [book2 setValue:@(APObjectStatusCreated) forKey:APObjectStatusAttributeName];
        [book2 setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
        [book2 setValue:@"Book" forKeyPath:APObjectEntityNameAttributeName];
        [book2 save:&saveError];
        DLog(@"Book %@ has been created",kBookNameParse2);
        
        PFObject* author = [PFObject objectWithClassName:@"Author"];
        [author setValue:kAuthorNameParse forKey:@"name"];
        [author setValue:@(APObjectStatusCreated) forKey:APObjectStatusAttributeName];
        [author setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
        [author setValue:@"Author" forKeyPath:APObjectEntityNameAttributeName];
        [author save:&saveError];
        DLog(@"Author %@ has been created",kAuthorNameParse);
        
        // Relation (To-Many)
        [[author relationForKey:@"books"] addObject:book1];
        [[author relationForKey:@"books"] addObject:book2];
        [author save:&saveError];
        
        // Pointer (To-One)
        book1[@"author"] = author;
        [book1 save:&saveError];
        book2[@"author"] = author;
        [book2 save:&saveError];

        DLog(@"Relations have been set");
    });
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    
    self.syncQueue = [[NSOperationQueue alloc]init];
    [self.syncQueue setName:@"Unit Test Sync Queue"];
    [self.syncQueue setMaxConcurrentOperationCount:1]; //Serial
}


- (void) tearDown {
    
    self.testContext = nil;
    
    // Remove SQLite file
    [self removeCacheStore];
    
    [self removeAllEntriesFromParse];
    [super tearDown];
}


#pragma mark - Tests - Basic Stuff

- (void) testContextIsSet {
    
    XCTAssertNotNil(self.testContext);
}


#pragma mark - Tests - Merge


- (void) testMergeRemoteObjectsReturn {
    
    APParseSyncOperation* parseSyncOperation1 = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    
    [parseSyncOperation1 setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        
        XCTAssertNil(operationError, @"Sync error:%@",operationError);
        XCTAssertTrue([mergedObjectsUIDsNestedByEntityName count] == 2);
        
        NSDictionary* authorEntry = mergedObjectsUIDsNestedByEntityName[@"Author"];
        XCTAssertTrue([[[authorEntry allKeys]lastObject] isEqualToString:@"inserted"]);
        XCTAssertTrue([authorEntry[@"inserted"] count] == 1);
        
        NSDictionary* bookEntry = mergedObjectsUIDsNestedByEntityName[@"Book"];
        XCTAssertTrue([[[bookEntry allKeys]lastObject] isEqualToString:@"inserted"]);
        XCTAssertTrue([bookEntry[@"inserted"] count] == 2);

    }];
       
    // Sync again - should bring an empty result.
    
    APParseSyncOperation* parseSyncOperation2 = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    [parseSyncOperation2 setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        XCTAssertNil(operationError, @"Sync error:%@",operationError);
        XCTAssertTrue([mergedObjectsUIDsNestedByEntityName count] == 0);
    }];
    [parseSyncOperation2 addDependency:parseSyncOperation1];
    
    [self.syncQueue addOperation:parseSyncOperation1];
    [self.syncQueue addOperation:parseSyncOperation2];
    
    while ([parseSyncOperation2 isFinished] == NO && WAIT_PATIENTLY);
    
}


#pragma mark  - Tests - Objects created remotely

- (void) testMergeRemoteObjects {
    
    APParseSyncOperation* parseSyncOperation = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    
    [parseSyncOperation setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        
        XCTAssertNil(operationError, @"Sync error:%@",operationError);
        XCTAssertTrue([mergedObjectsUIDsNestedByEntityName count] == 2);
    }];
    
    
    [self.syncQueue addOperation:parseSyncOperation];
    
    while ([parseSyncOperation isFinished] == NO && WAIT_PATIENTLY);
    
    NSFetchRequest* booksFr = [NSFetchRequest fetchRequestWithEntityName:@"Book"];
    booksFr.predicate = [NSPredicate predicateWithFormat:@"name == %@",kBookNameParse1];
    NSArray* books = [self.testContext executeFetchRequest:booksFr error:nil];
    Book* book = [books lastObject];
    XCTAssertNotNil(book);
    
    NSFetchRequest* authorFr = [NSFetchRequest fetchRequestWithEntityName:@"Author"];
    booksFr.predicate = [NSPredicate predicateWithFormat:@"name == %@",kAuthorNameParse];
    NSArray* authors = [self.testContext executeFetchRequest:authorFr error:nil];
    Author* author = [authors lastObject];
    XCTAssertNotNil(author);
}


- (void) testMergeRemoteCreatedRelationship {
    
    __block NSError* error;
    __block PFObject* book3;
    __block PFObject* author;
    
    APParseSyncOperation* parseSyncOperation = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    [self.syncQueue addOperation:parseSyncOperation];
    
    while ([parseSyncOperation isFinished] == NO && WAIT_PATIENTLY);
        
    book3 = [PFObject objectWithClassName:@"Book"];
    [book3 setValue:kBookNameParse3 forKey:@"name"];
    book3[APObjectEntityNameAttributeName] = @"Book";
    [book3 setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
    [book3 setValue:@"Book" forKey:APObjectEntityNameAttributeName];
    book3[APObjectStatusAttributeName] = @(APObjectStatusCreated);
    
    __block BOOL done = NO;
    [book3 saveInBackgroundWithBlock:^(BOOL succeeded, NSError *error) {
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    
    author = [[PFQuery queryWithClassName:@"Author"]getFirstObject];
    [[author relationForKey:@"books"] addObject:book3];
    
    done = NO;
    [author saveInBackgroundWithBlock:^(BOOL succeeded, NSError *error) {
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    
    book3[@"author"] = author;
    done = NO;
    [book3 saveInBackgroundWithBlock:^(BOOL succeeded, NSError *error) {
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    
    APParseSyncOperation* parseSyncOperation2 = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    
    [parseSyncOperation2 setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        
        XCTAssertNil(error);
        
        NSArray* updatedAuthors = mergedObjectsUIDsNestedByEntityName[@"Author"][NSUpdatedObjectsKey];
        XCTAssertTrue([[updatedAuthors lastObject]isEqualToString:[author valueForKey:APObjectUIDAttributeName] ]);
        
        NSArray* insertedAuthor = mergedObjectsUIDsNestedByEntityName[@"Book"][NSInsertedObjectsKey];
        XCTAssertTrue([[insertedAuthor lastObject]isEqualToString:[book3 valueForKey:APObjectUIDAttributeName]]);
    }];
    
    [self.syncQueue addOperation:parseSyncOperation2];
    while ([parseSyncOperation2 isFinished] == NO && WAIT_PATIENTLY);

    NSFetchRequest* booksFr = [NSFetchRequest fetchRequestWithEntityName:@"Book"];
    [booksFr setPredicate:[NSPredicate predicateWithFormat:@"name = %@",kBookNameParse3]];
    NSArray* books = [self.testContext executeFetchRequest:booksFr error:&error];
    Book* book = [books lastObject];
    XCTAssertEqualObjects(book.author.name, kAuthorNameParse);
    
    NSFetchRequest* authorFr = [NSFetchRequest fetchRequestWithEntityName:@"Author"];
    NSArray* authors = [self.testContext executeFetchRequest:authorFr error:&error];
    Author* fetchedAuthor = [authors lastObject];
    XCTAssertTrue([fetchedAuthor.books count] == 3);
}


- (void) testMergeRemoteCreatedRelationshipToMany {
    
    APParseSyncOperation* parseSyncOperation = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    [self.syncQueue addOperation:parseSyncOperation];
    while ([parseSyncOperation isFinished] == NO && WAIT_PATIENTLY);
    
    NSFetchRequest* authorFr = [NSFetchRequest fetchRequestWithEntityName:@"Author"];
    NSArray* authors = [self.testContext executeFetchRequest:authorFr error:nil];
    Author* author = [authors lastObject];
    XCTAssert([author.books count] == 2);
    
    Book* relatedBook1 = [[[author.books allObjects] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name == %@",kBookNameParse1]]lastObject];
    XCTAssertNotNil(relatedBook1);
    
    Book* relatedBook2 = [[[author.books allObjects] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name == %@",kBookNameParse2]]lastObject];
    XCTAssertNotNil(relatedBook2);
}


#pragma mark  - Tests - Objects deleted remotely

- (void) testMergeRemoteDeletedObjects {
    
    APParseSyncOperation* parseSyncOperation = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    [self.syncQueue addOperation:parseSyncOperation];
    while ([parseSyncOperation isFinished] == NO && WAIT_PATIENTLY);
    
    
    // Merge server objects
    NSError* error;
    
    XCTAssertNil(error);
    
    // Mark Author as deleted
    PFQuery* authorQuery = [PFQuery queryWithClassName:@"Author"];
    [authorQuery whereKey:@"name" containsString:kAuthorNameParse];
    PFObject* parseAuthor = [[authorQuery findObjects]lastObject];
    parseAuthor[APObjectStatusAttributeName] = @(APObjectStatusDeleted);
    __block BOOL done = NO;
    [parseAuthor saveInBackgroundWithBlock:^(BOOL succeeded, NSError *error) {
        XCTAssertNil(error);
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    
    APParseSyncOperation* parseSyncOperation2 = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    [self.syncQueue addOperation:parseSyncOperation2];
    while ([parseSyncOperation2 isFinished] == NO && WAIT_PATIENTLY);
    
    // Fetch local object
    NSFetchRequest* authorFr = [NSFetchRequest fetchRequestWithEntityName:@"Author"];
    authorFr.predicate = [NSPredicate predicateWithFormat:@"name == %@",kAuthorNameParse];
    NSArray* authors = [self.testContext executeFetchRequest:authorFr error:nil];
    XCTAssertTrue([authors count] == 0);

}

- (void) testDateProperties {
    
    NSDate* now = [NSDate date];
    
    // Create a local Book and insert it on Parse
    Book* book = [NSEntityDescription insertNewObjectForEntityForName:@"Book" inManagedObjectContext:self.testContext];
    [book setValue:@YES forKey:APObjectIsDirtyAttributeName];
    [book setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
    book.name = kBookNameLocal1;
    book.createdDate = now;
    
    NSError* error;
    [self.testContext save:&error];
    XCTAssertNil(error);
    
    APParseSyncOperation* parseSyncOperation = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    [self.syncQueue addOperation:parseSyncOperation];
    [parseSyncOperation setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        XCTAssertNil(operationError);
    }];
    while ([parseSyncOperation isFinished] == NO && WAIT_PATIENTLY);
    
    PFQuery* bookQuery = [PFQuery queryWithClassName:@"Book"];
    [bookQuery whereKey:@"name" containsString:kBookNameLocal1];
    __block PFObject* fetchedBook;
    __block BOOL done = NO;
    [bookQuery getFirstObjectInBackgroundWithBlock:^(PFObject *object, NSError *error) {
        fetchedBook = object;
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    
    XCTAssertNotNil(fetchedBook);
    NSDate* fetchedDateProperty = [fetchedBook valueForKey:@"createdDate"];
    XCTAssertTrue([fetchedDateProperty timeIntervalSinceDate:now] < 1.0);
}

#pragma mark  - Tests - Objects created locally

- (void) testMergeLocalCreatedObjects {
    
    // Create a local Book and insert it on Parse
    Book* book = [NSEntityDescription insertNewObjectForEntityForName:@"Book" inManagedObjectContext:self.testContext];
    [book setValue:@YES forKey:APObjectIsDirtyAttributeName];
    [book setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
    book.name = kBookNameLocal1;
    
    // Create a local Author and insert it on Parse
    Author* author = [NSEntityDescription insertNewObjectForEntityForName:@"Author" inManagedObjectContext:self.testContext];
    [author setValue:@YES forKey:APObjectIsDirtyAttributeName];
    [author setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
    author.name =kAuthorNameLocal;
    
    NSError* error;
    [self.testContext save:&error];
    XCTAssertNil(error);
    
    APParseSyncOperation* parseSyncOperation2 = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    [self.syncQueue addOperation:parseSyncOperation2];
    [parseSyncOperation2 setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        XCTAssertNil(operationError);
    }];
    while ([parseSyncOperation2 isFinished] == NO && WAIT_PATIENTLY);
    
    PFQuery* bookQuery = [PFQuery queryWithClassName:@"Book"];
    [bookQuery whereKey:@"name" containsString:kBookNameLocal1];
    __block PFObject* fetchedBook;
    __block BOOL done = NO;
    [bookQuery getFirstObjectInBackgroundWithBlock:^(PFObject *object, NSError *error) {
        fetchedBook = object;
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    
    XCTAssertNotNil(fetchedBook);
    XCTAssertEqualObjects([fetchedBook valueForKey:@"name"],kBookNameLocal1);
}


- (void) testMergeLocalCreatedRelationshipToOne {
    
    // Create a local Book, mark is as "dirty" and set the objectUID with the predefined prefix
    Book* book = [NSEntityDescription insertNewObjectForEntityForName:@"Book" inManagedObjectContext:self.testContext];
    [book setValue:@YES forKey:APObjectIsDirtyAttributeName];
    [book setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
    book.name = kBookNameLocal1;
    
    // Create a local Author, mark is as "dirty" and set the objectUID with the predefined prefix
    Author* author = [NSEntityDescription insertNewObjectForEntityForName:@"Author" inManagedObjectContext:self.testContext];
    [author setValue:@YES forKey:APObjectIsDirtyAttributeName];
    [author setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
    author.name =kAuthorNameLocal;
    
    // Create the relationship locally and merge the context with Parse
    book.author = author;
    
    NSError* error;
    [self.testContext save:&error];
    XCTAssertNil(error);
    
    //Sync
    APParseSyncOperation* parseSyncOperation2 = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    [self.syncQueue addOperation:parseSyncOperation2];
    [parseSyncOperation2 setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        XCTAssertNil(operationError);
    }];
    while ([parseSyncOperation2 isFinished] == NO && WAIT_PATIENTLY);
    
    // Fetch the book from Parse and verify the related To-One author
    PFQuery* bookQuery = [PFQuery queryWithClassName:@"Book"];
    [bookQuery whereKey:@"name" containsString:kBookNameLocal1];
    __block PFObject* fetchedBook;
    __block BOOL done = NO;
    [bookQuery getFirstObjectInBackgroundWithBlock:^(PFObject *object, NSError *error) {
        fetchedBook = object;
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    
    done = NO;
    PFObject* relatedAuthor = fetchedBook[@"author"];
    [relatedAuthor fetchInBackgroundWithBlock:^(PFObject *object, NSError *error) {
        XCTAssertNotNil(object);
        XCTAssertEqualObjects([object valueForKey:@"name"],kAuthorNameLocal);
        done = YES;
    }];
}


- (void) testMergeLocalCreatedRelationshipToMany {
    
    /*
     Scenario:
     - Create 2x books locally
     - Create a author locally and associate both books to it.
     - Next we merge with our managed context
     
     Expected Results:
     - We fetch from Parse the created author and its relationship to books
     - Both books should be related to the author
     - All support attibutes set properly
     */
    
    // Create a local Book, mark is as "dirty" and set the objectUID with the predefined prefix
    Book* book1 = [NSEntityDescription insertNewObjectForEntityForName:@"Book" inManagedObjectContext:self.testContext];
    [book1 setValue:@YES forKey:APObjectIsDirtyAttributeName];
    [book1 setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
    book1.name = kBookNameLocal1;
    
    // Create a local Book, mark is as "dirty" and set the objectUID with the predefined prefix
    Book* book2 = [NSEntityDescription insertNewObjectForEntityForName:@"Book" inManagedObjectContext:self.testContext];
    [book2 setValue:@YES forKey:APObjectIsDirtyAttributeName];
    [book2 setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
    book2.name = kBookNameLocal2;
    
    // Create a local Author, mark is as "dirty" and set the objectUID with the predefined prefix
    Author* author = [NSEntityDescription insertNewObjectForEntityForName:@"Author" inManagedObjectContext:self.testContext];
    [author setValue:@YES forKey:APObjectIsDirtyAttributeName];
    [author setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
    author.name =kAuthorNameLocal;
    
    // Create the relationship locally and merge the context with Parse
    [author addBooksObject:book1];
    [author addBooksObject:book2];
    
    NSError* error;
    [self.testContext save:&error];
    XCTAssertNil(error);
    
    //Sync
    APParseSyncOperation* parseSyncOperation = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    [self.syncQueue addOperation:parseSyncOperation];
    [parseSyncOperation setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        XCTAssertNil(operationError);
        [self.testContext refreshObject:author mergeChanges:YES];
        [self.testContext refreshObject:book1 mergeChanges:YES];
        [self.testContext refreshObject:book2 mergeChanges:YES];
    }];
    while ([parseSyncOperation isFinished] == NO && WAIT_PATIENTLY);
    
    /*
     After the objects get merged with Parse, they should have the following attributes set:
     - APObjectLastModifiedAttributeName
     - APObjectUIDAttributeName
     - APObjectIsDirtyAttributeName
     */
    XCTAssertNotNil([author valueForKey:APObjectLastModifiedAttributeName]);
    XCTAssertNotNil([author valueForKey:APObjectUIDAttributeName]);
    XCTAssertTrue([[author valueForKey:APObjectIsDirtyAttributeName] isEqualToNumber:@NO]);
    
    XCTAssertNotNil([book1 valueForKey:APObjectLastModifiedAttributeName]);
    XCTAssertNotNil([book1 valueForKey:APObjectUIDAttributeName]);
    XCTAssertTrue([[book1 valueForKey:APObjectIsDirtyAttributeName] isEqualToNumber:@NO]);
    
    XCTAssertNotNil([book2 valueForKey:APObjectLastModifiedAttributeName]);
    XCTAssertNotNil([book2 valueForKey:APObjectUIDAttributeName]);
    XCTAssertTrue([[book2 valueForKey:APObjectIsDirtyAttributeName] isEqualToNumber:@NO]);
    
    
    // Fetch the book from Parse and verify the related To-One author
    PFQuery* authorQuery = [PFQuery queryWithClassName:@"Author"];
    [authorQuery whereKey:@"name" containsString:kAuthorNameLocal];
    
    __block BOOL done = NO;
    __block PFObject* fetchedAuthor;
    [authorQuery getFirstObjectInBackgroundWithBlock:^(PFObject *object, NSError *error) {
        fetchedAuthor = object;
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    
    PFQuery* booksQuery = [PFQuery queryWithClassName:@"Book"];
    [booksQuery whereKey:@"author" equalTo:fetchedAuthor];
    __block NSArray* books;
    done = NO;
    
    [booksQuery findObjectsInBackgroundWithBlock:^(NSArray *objects, NSError *error) {
        books = objects;
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    XCTAssertTrue([books count] == 2);
    
    Book* relatedBook1 = [[books filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name == %@",kBookNameLocal1]]lastObject];
    XCTAssertNotNil(relatedBook1);
    
    Book* relatedBook2 = [[books filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name == %@",kBookNameLocal1]]lastObject];
    XCTAssertNotNil(relatedBook2);
}


- (void) testMergeLocalCreatedRelationshipToManyUsingParseArray {
    
   /*
    Scenario:
    - Create 2x Authors locally
    - Create 1x magazine locally and associate both authors to it. That's the Array relationship
    - Next we merge with our managed context
    
    Expected Results:
    - We fetch from Parse the created author and its relationship to books
    - Both books should be related to the author
    - All support attibutes set properly
    */
    
    // Create a local Book, mark is as "dirty" and set the objectUID with the predefined prefix
    Author* author1 = [NSEntityDescription insertNewObjectForEntityForName:@"Author" inManagedObjectContext:self.testContext];
    [author1 setValue:@YES forKey:APObjectIsDirtyAttributeName];
    [author1 setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
    author1.name = kAuthorNameLocal;
    
    // Create a local Book, mark is as "dirty" and set the objectUID with the predefined prefix
    Author* author2 = [NSEntityDescription insertNewObjectForEntityForName:@"Author" inManagedObjectContext:self.testContext];
    [author2 setValue:@YES forKey:APObjectIsDirtyAttributeName];
    [author2 setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
    author2.name = kAuthorNameLocal2;
    
    // Create a local Author, mark is as "dirty" and set the objectUID with the predefined prefix
    Magazine* magazine = [NSEntityDescription insertNewObjectForEntityForName:@"Magazine" inManagedObjectContext:self.testContext];
    [magazine setValue:@YES forKey:APObjectIsDirtyAttributeName];
    [magazine setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
    magazine.name =kMagazineNameLocal1;
    
    // Create the relationship locally and merge the context with Parse
    [magazine addAuthorsObject:author1];
    [magazine addAuthorsObject:author2];
    
    NSError* error;
    [self.testContext save:&error];
    XCTAssertNil(error);
    
    //Sync
    APParseSyncOperation* parseSyncOperation = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    [self.syncQueue addOperation:parseSyncOperation];
    [parseSyncOperation setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        [self.testContext refreshObject:author1 mergeChanges:YES];
        [self.testContext refreshObject:author2 mergeChanges:YES];
        [self.testContext refreshObject:magazine mergeChanges:YES];
    }];
    while ([parseSyncOperation isFinished] == NO && WAIT_PATIENTLY);
    
    /*
     After the objects get merged with Parse, they should have the following attributes set:
     - APObjectLastModifiedAttributeName
     - APObjectUIDAttributeName
     - APObjectIsDirtyAttributeName
     */
    XCTAssertNotNil([magazine valueForKey:APObjectLastModifiedAttributeName]);
    XCTAssertNotNil([magazine valueForKey:APObjectUIDAttributeName]);
    XCTAssertTrue([[magazine valueForKey:APObjectIsDirtyAttributeName] isEqualToNumber:@NO]);
    
    XCTAssertNotNil([author1 valueForKey:APObjectLastModifiedAttributeName]);
    XCTAssertNotNil([author1 valueForKey:APObjectUIDAttributeName]);
    XCTAssertTrue([[author1 valueForKey:APObjectIsDirtyAttributeName] isEqualToNumber:@NO]);
    
    XCTAssertNotNil([author2 valueForKey:APObjectLastModifiedAttributeName]);
    XCTAssertNotNil([author2 valueForKey:APObjectUIDAttributeName]);
    XCTAssertTrue([[author2 valueForKey:APObjectIsDirtyAttributeName] isEqualToNumber:@NO]);
    
    
    // Fetch the book from Parse and verify the related To-One author
    PFQuery* magazineQuery = [PFQuery queryWithClassName:@"Magazine"];
    [magazineQuery whereKey:@"name" containsString:kMagazineNameLocal1];
    [magazineQuery includeKey:@"authors"];
    __block BOOL done = NO;
    __block PFObject* fetchedMagazine;
    [magazineQuery getFirstObjectInBackgroundWithBlock:^(PFObject *object, NSError *error) {
        fetchedMagazine = object;
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    
    NSArray* authors = [fetchedMagazine valueForKey:@"authors"];
    XCTAssertTrue([authors count] == 2);
    
    Author* relatedAuthor1 = [[authors filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name == %@",kAuthorNameLocal]]lastObject];
    XCTAssertNotNil(relatedAuthor1);
    
    Author* relatedAuthor2 = [[authors filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name == %@",kAuthorNameLocal2]]lastObject];
    XCTAssertNotNil(relatedAuthor2);
}



#pragma mark - Tests - Counting objects to sync

//- (void) testCountRemoteObjectsToSync {
//
//    dispatch_group_async(self.group, self.queue, ^{
//
//        NSError* countingError;
//        NSInteger numberOfObjectsToBeSynced = [self.parseConnector countRemoteObjectsToBeSyncedInContext:self.testContext fullSync:YES error:&countingError];
//        XCTAssertNil(countingError);
//        
//        // Parse doesn't quite support couting
//        XCTAssertTrue(numberOfObjectsToBeSynced == -1);
//    });
//    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
//}


//- (void) testCountLocalObjectsToSync {
//    
//    NSUInteger const numberOfBooksToBeCreated = 10;
//    
//    for (NSUInteger i = 0; i < numberOfBooksToBeCreated; i++) {
//        Book* newBook = [NSEntityDescription insertNewObjectForEntityForName:@"Book" inManagedObjectContext:self.testContext];
//        newBook.name = [NSString stringWithFormat:@"book#%lu",(unsigned long) i];
//        [newBook setValue:@YES forKey:APObjectIsDirtyAttributeName];
//        [newBook setValue:[self createObjectUID] forKeyPath:APObjectUIDAttributeName];
//    }
//    XCTAssertTrue([[self.testContext registeredObjects]count] == numberOfBooksToBeCreated);
//    
//    NSError* savingError;
//    [self.testContext save:&savingError];
//    XCTAssertNil(savingError);
//    
//    NSError* countingError;
//    NSInteger numberOfObjectsToBeSynced = [self.parseConnector countLocalObjectsToBeSyncedInContext:self.testContext error:&countingError];
//    XCTAssertNil(countingError);
//    
//    // Parse doesn't quite support couting
//    XCTAssertTrue(numberOfObjectsToBeSynced == -1);
//}


#pragma mark - Tests - Binary Attributes

/*
 Scenario:
 - We are going to get a image from the Internet and set a parse object book attribute "picture" with it.
 - Next we merge with our managed context
 
 Expected Results:
 - The same image should be present in the equivalement local core data book.
 */
- (void) testBinaryAttributeMergingFromParse {
    
    __block NSData* bookCoverData;
    
    // 495KB JPG Image sample image
    NSURL *imageURL = [[[NSBundle bundleForClass:[self class]]bundleURL] URLByAppendingPathComponent:@"Sample_495KB.jpg"];
    bookCoverData = [NSData dataWithContentsOfURL:imageURL];
    XCTAssertNotNil(bookCoverData);
    
     __block BOOL done = NO;
    PFFile* bookCoverFile = [PFFile fileWithData:bookCoverData];
    [bookCoverFile saveInBackgroundWithBlock:^(BOOL succeeded, NSError *error) {
        XCTAssertNil(error);
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    
    PFQuery* bookQuery = [PFQuery queryWithClassName:@"Book"];
    [bookQuery whereKey:@"name" containsString:kBookNameParse1];
    
    done = NO;
    __block PFObject* fetchedBookFromParse;
    [bookQuery getFirstObjectInBackgroundWithBlock:^(PFObject *object, NSError *error) {
        XCTAssertNil(error);
        fetchedBookFromParse = object;
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    
    fetchedBookFromParse[@"picture"] = bookCoverFile;
    done = NO;
    [fetchedBookFromParse saveInBackgroundWithBlock:^(BOOL succeeded, NSError *error) {
        XCTAssertNil(error);
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
     
     //Sync
     APParseSyncOperation* parseSyncOperation = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
     [self.syncQueue addOperation:parseSyncOperation];
     [parseSyncOperation setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        XCTAssertNil(operationError);
    }];
     while ([parseSyncOperation isFinished] == NO && WAIT_PATIENTLY);
     
     NSFetchRequest* booksFr = [NSFetchRequest fetchRequestWithEntityName:@"Book"];
     booksFr.predicate = [NSPredicate predicateWithFormat:@"name == %@",kBookNameParse1];
     NSArray* books = [self.testContext executeFetchRequest:booksFr error:nil];
     Book* book = [books lastObject];
     XCTAssertNotNil(book);
     XCTAssertTrue([bookCoverData isEqualToData:book.picture]);
     }

/*
 Scenario:
 - We are going to get a image from the Internet and set a local managed object book attribute "picture" with it.
 - Next we merge with our managed context into Parse
 
 Expected Results:
 - The same image should be present in the equivalement parse object book.
 */
- (void) testBinaryAttributeMergingToParse {
    
    //Sync
    APParseSyncOperation* parseSyncOperation = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    [self.syncQueue addOperation:parseSyncOperation];
    [parseSyncOperation setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        XCTAssertNil(operationError);
    }];
    while ([parseSyncOperation isFinished] == NO && WAIT_PATIENTLY);
    
    
    NSFetchRequest* booksFr = [NSFetchRequest fetchRequestWithEntityName:@"Book"];
    booksFr.predicate = [NSPredicate predicateWithFormat:@"name == %@",kBookNameParse1];
    NSArray* books = [self.testContext executeFetchRequest:booksFr error:nil];
    Book* book = [books lastObject];
    XCTAssertNotNil(book);
    
    // 495KB JPG Image sample image
    NSURL *imageURL = [[[NSBundle bundleForClass:[self class]]bundleURL] URLByAppendingPathComponent:@"Sample_495KB.jpg"];
    NSData* bookCoverData = [NSData dataWithContentsOfURL:imageURL];
    XCTAssertNotNil(bookCoverData);
    
    book.picture = bookCoverData;
    [book setValue:@YES forKey:APObjectIsDirtyAttributeName];
    
    NSError* saveError;
    [self.testContext save:&saveError];
    XCTAssertNil(saveError);
    
    //Sync
    APParseSyncOperation* parseSyncOperation2 = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    [self.syncQueue addOperation:parseSyncOperation2];
    [parseSyncOperation2 setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        XCTAssertNil(operationError);
    }];
    while ([parseSyncOperation2 isFinished] == NO && WAIT_PATIENTLY);
    
    PFQuery* bookQuery = [PFQuery queryWithClassName:@"Book"];
    [bookQuery whereKey:@"name" containsString:kBookNameParse1];
    PFObject* fetchedBook = [[bookQuery findObjects]lastObject];
    XCTAssertNotNil(fetchedBook);
    
    PFFile* pictureFromParse = [fetchedBook objectForKey:@"picture"];
    __block NSData* parseBookCoverData;
    __block BOOL done = NO;
    [pictureFromParse getDataInBackgroundWithBlock:^(NSData *data, NSError *error) {
        parseBookCoverData = data;
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    
    XCTAssertNotNil(parseBookCoverData);
    
    XCTAssertTrue([parseBookCoverData isEqualToData:bookCoverData]);
}


#pragma mark  - Tests - Conflicts

- (void) testModifiedDatesAfterMergeFromServer {
    
    /*
     Scenario:
     - We merge an existing object from Parse that wasn't localy present before
     - Therefore the local kAPIncrementalStoreLastModifiedAttributeName gets populated.
     - The same object gets changed at Parse again consequentely updatedAt gets updated as well.
     
     Expected Results:
     - The local kAPIncrementalStoreLastModifiedAttributeName should get the new date.
     */

    
    //Sync
    APParseSyncOperation* parseSyncOperation = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    [self.syncQueue addOperation:parseSyncOperation];
    [parseSyncOperation setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        XCTAssertNil(operationError);
    }];
    while ([parseSyncOperation isFinished] == NO && WAIT_PATIENTLY);
    
    // Fetch local object
    NSFetchRequest* booksFr = [NSFetchRequest fetchRequestWithEntityName:@"Book"];
    booksFr.predicate = [NSPredicate predicateWithFormat:@"name == %@",kBookNameParse1];
    __block BOOL done = NO;
    NSArray* books = [self.testContext executeFetchRequest:booksFr error:nil];
    Book* localBook = [books lastObject];
    
    NSDate* originalDate = [localBook valueForKey:APObjectLastModifiedAttributeName];
    XCTAssertNotNil(originalDate);
    
    PFQuery* bookQuery = [PFQuery queryWithClassName:@"Book"];
    [bookQuery whereKey:@"name" containsString:kBookNameParse1];
    __block PFObject* parseBook;
    done = NO;
    [bookQuery getFirstObjectInBackgroundWithBlock:^(PFObject *object, NSError *error) {
        parseBook = object;
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    
    XCTAssertNotNil(parseBook);
    XCTAssertEqualObjects(parseBook.updatedAt, originalDate);
    
    [parseBook setValue:kBookNameParse2 forKey:@"name"];
    
    // Wait for 5 seconds and save the object
    [NSThread sleepForTimeInterval:5];
    [parseBook save];
    
    NSError* error;
    [self.testContext save:&error];
    XCTAssertNil(error);
    
    //Sync
    APParseSyncOperation* parseSyncOperation2 = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    [self.syncQueue addOperation:parseSyncOperation2];
    [parseSyncOperation2 setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        XCTAssertNil(operationError);
        [self.testContext refreshObject:localBook mergeChanges:YES];
    }];
    while ([parseSyncOperation2 isFinished] == NO && WAIT_PATIENTLY);
    
    // The local object date should have been updated.
    NSDate* updatedDate = [localBook valueForKey:APObjectLastModifiedAttributeName];
    XCTAssertTrue([updatedDate compare:originalDate] == NSOrderedDescending);
}


/*
 Scenario:
 - We have merged our context, then we update an book name making it "dirty".
 - Before we merge it back to Parse, the remote equivalent object gets updated, characterizing a conflict.
            
 Expected Results:
 - As the policy is set to Client wins, the remote object gets overridden by the local object
 - Conflicts may only occur when we are merging local "dirty" objects.
 */
- (void) testConflictWhenMergingObjectsClientWinsPolicy {
    
    //Sync
    APParseSyncOperation* parseSyncOperation = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    [self.syncQueue addOperation:parseSyncOperation];
    [parseSyncOperation setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        [self.testContext reset];
    }];
    while ([parseSyncOperation isFinished] == NO && WAIT_PATIENTLY);
    
    // Fetch local object
    NSFetchRequest* booksFr = [NSFetchRequest fetchRequestWithEntityName:@"Book"];
    booksFr.predicate = [NSPredicate predicateWithFormat:@"name == %@",kBookNameParse1];
    NSArray* books = [self.testContext executeFetchRequest:booksFr error:nil];
    Book* localBook = [books lastObject];
    localBook.name = kBookNameParse3;
    [localBook setValue:@YES forKey:APObjectIsDirtyAttributeName];
    
    // Fetch, change the book name and save it back to Parse
    PFQuery* bookQuery = [PFQuery queryWithClassName:@"Book"];
    [bookQuery whereKey:@"name" containsString:kBookNameParse1];
    __block BOOL done = NO;
    __block PFObject* parseBook;
    [bookQuery getFirstObjectInBackgroundWithBlock:^(PFObject *object, NSError *error) {
        parseBook = object;
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    
    parseBook[@"name"] = kBookNameParse4;
    
    done = NO;
    [parseBook saveInBackgroundWithBlock:^(BOOL succeeded, NSError *error) {
        XCTAssertNil(error);
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    
    XCTAssertTrue([[parseBook valueForKey:APObjectUIDAttributeName] isEqualToString:[localBook valueForKey:APObjectUIDAttributeName]]);
    
    NSError* error;
    [self.testContext save:&error];
    XCTAssertNil(error);
    
    //Sync
    APParseSyncOperation* parseSyncOperation2 = [self newParseSyncOperationWithMergePolicy:APMergePolicyClientWins];
    [self.syncQueue addOperation:parseSyncOperation2];
    [parseSyncOperation2 setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        [self.testContext refreshObject:localBook mergeChanges:YES];
    }];
    while ([parseSyncOperation2 isFinished] == NO && WAIT_PATIENTLY);
    
    XCTAssertEqualObjects(localBook.name, kBookNameParse3);
    
    done = NO;
    [parseBook fetchInBackgroundWithBlock:^(PFObject *object, NSError *error) {
         XCTAssertEqualObjects([object valueForKey:@"name"], kBookNameParse3);
         done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
}


/*
 Scenario:
 - We have merged our context, then we update an book name making it "dirty".
 - Before we merge it back to Parse, the remote equivalent object gets updated, characterizing a conflict.
 
 Expected Results:
 - As the policy is set to Server wins, the local object gets overridden by the server object
 - Conflicts may only occur when we are merging local "dirty" objects.
 */
- (void) testConflictWhenMergingObjectsServerWinsPolicy {
    
    //Sync
    APParseSyncOperation* parseSyncOperation = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    [self.syncQueue addOperation:parseSyncOperation];
    [parseSyncOperation setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        XCTAssertNil(operationError);
    }];
    while ([parseSyncOperation isFinished] == NO && WAIT_PATIENTLY);
    
    // Fetch local object
    NSFetchRequest* booksFr = [NSFetchRequest fetchRequestWithEntityName:@"Book"];
    booksFr.predicate = [NSPredicate predicateWithFormat:@"name == %@",kBookNameParse1];
    NSArray* books = [self.testContext executeFetchRequest:booksFr error:nil];
    Book* localBook = [books lastObject];
    localBook.name = kBookNameParse3;
    [localBook setValue:@YES forKey:APObjectIsDirtyAttributeName];
    
    NSError* error;
    [self.testContext save:&error];
    XCTAssertNil(error);
    
    // Fetch, change the book name and save it back to Parse
    PFQuery* bookQuery = [PFQuery queryWithClassName:@"Book"];
    [bookQuery whereKey:@"name" containsString:kBookNameParse1];
    __block BOOL done = NO;
    __block PFObject* parseBook;
    [bookQuery getFirstObjectInBackgroundWithBlock:^(PFObject *object, NSError *error) {
        parseBook = object;
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    
    parseBook[@"name"] = kBookNameParse4;
    
    done = NO;
    [parseBook saveInBackgroundWithBlock:^(BOOL succeeded, NSError *error) {
        XCTAssertNil(error);
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    
    XCTAssertTrue([[parseBook valueForKey:APObjectUIDAttributeName] isEqualToString:[localBook valueForKey:APObjectUIDAttributeName]]);
    
    
    //Sync
    APParseSyncOperation* parseSyncOperation2 = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    [self.syncQueue addOperation:parseSyncOperation2];
    [parseSyncOperation2 setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        [self.testContext refreshObject:localBook mergeChanges:YES];
    }];
    while ([parseSyncOperation2 isFinished] == NO && WAIT_PATIENTLY);
    
    XCTAssertEqualObjects(localBook.name, kBookNameParse4);
    
    done = NO;
    [parseBook fetchInBackgroundWithBlock:^(PFObject *object, NSError *error) {
        XCTAssertEqualObjects([object valueForKey:@"name"], kBookNameParse4);
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
}


- (void) testParseUpdatedAtDates {
    
    PFObject* book = [[PFObject alloc]initWithClassName:@"Book"];
    [book setValue:@"some name" forKeyPath:@"name"];
    [book setValue:[self createObjectUID] forKeyPath:APObjectUIDAttributeName];
    [book setValue:@"Book" forKey:APObjectEntityNameAttributeName];
    
    __block BOOL done = NO;
    [book saveInBackgroundWithBlock:^(BOOL succeeded, NSError *error) {
        XCTAssertNil(error);
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    NSDate* updatedAtAfterSave = book.updatedAt;
    
    PFQuery* query = [PFQuery queryWithClassName:@"Book"];
    [query whereKey:@"name" containsString:@"some name"];
    done = NO;
    [query getFirstObjectInBackgroundWithBlock:^(PFObject *object, NSError *error) {
        NSDate* updatedAtAfterFetch = object.updatedAt;
        XCTAssertEqualObjects(updatedAtAfterSave, updatedAtAfterFetch);
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
}


- (void) testIncludeACLFromManagedObjectToParseObejct {
    
    Book* newBook = [NSEntityDescription insertNewObjectForEntityForName:@"Book" inManagedObjectContext:self.testContext];
    newBook.name = @"Book#1";
    [newBook setValue:@YES forKey:APObjectIsDirtyAttributeName];
    [newBook setValue:[self createObjectUID] forKeyPath:APObjectUIDAttributeName];
    
    NSMutableDictionary* ACL;
    ACL = [NSMutableDictionary dictionary];
    
    // Roles
    [ACL setValue:@{@"write":@"true", @"read":@"false"} forKey:[@"role:" stringByAppendingString:@"Role_Name"]];
    [ACL setValue:@{@"write":@"false",@"read":@"true"} forKey:[@"role:" stringByAppendingString:@"Role_Name2"]];
    
    // Users
    [ACL setValue:@{@"write":@"true",@"read":@"true"} forKey:[PFUser currentUser].objectId];
    [ACL setValue:@{@"write":@"false", @"read":@"false"} forKey:@"FDfaLRcqn1"];
    
    NSData* ACLData = [NSJSONSerialization dataWithJSONObject:ACL options:0 error:nil];
    [newBook setValue:ACLData forKey:@"__ACL"];
    
    NSError* error;
    [self.testContext save:&error];
    XCTAssertNil(error);
    
    //Sync
    APParseSyncOperation* parseSyncOperation = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    [self.syncQueue addOperation:parseSyncOperation];
    [parseSyncOperation setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        XCTAssertNil(operationError);
    }];
    while ([parseSyncOperation isFinished] == NO && WAIT_PATIENTLY);;
    
    PFQuery* bookQuery = [PFQuery queryWithClassName:@"Book"];
    [bookQuery whereKey:@"name" containsString:@"Book#1"];
    
    __block BOOL done = NO;
    [bookQuery getFirstObjectInBackgroundWithBlock:^(PFObject *object, NSError *error) {
        XCTAssertNil(error);
        
        PFACL* acl = object.ACL;
        
        XCTAssertTrue([acl getWriteAccessForUser:[PFUser currentUser]] == YES);
        XCTAssertTrue([acl getWriteAccessForUserId:@"FDfaLRcqn1"] == NO);
        XCTAssertTrue([acl getWriteAccessForRoleWithName:@"Role_Name"] == YES);
        XCTAssertTrue([acl getWriteAccessForRoleWithName:@"Role_Name2"] == NO);
        
        XCTAssertTrue([acl getReadAccessForUser:[PFUser currentUser]] == YES);
        XCTAssertTrue([acl getReadAccessForUserId:@"FDfaLRcqn1"] == NO);
        XCTAssertTrue([acl getReadAccessForRoleWithName:@"Role_Name"] == NO);
        XCTAssertTrue([acl getReadAccessForRoleWithName:@"Role_Name2"] == YES);
        
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
}

#pragma mark  - Tests - Inheritance
- (void) testInheritanceMergeLocalCreatedSubEntityObject {
    
    EBook* newEBook = [NSEntityDescription insertNewObjectForEntityForName:@"EBook" inManagedObjectContext:self.testContext];
    newEBook.name = @"eBook#1";
    newEBook.format = @"PDF";
    [newEBook setValue:@YES forKey:APObjectIsDirtyAttributeName];
    [newEBook setValue:[self createObjectUID] forKeyPath:APObjectUIDAttributeName];
    
    // Create a local Author, mark is as "dirty" and set the objectUID with the predefined prefix
    Author* author = [NSEntityDescription insertNewObjectForEntityForName:@"Author" inManagedObjectContext:self.testContext];
    [author setValue:@YES forKey:APObjectIsDirtyAttributeName];
    [author setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
    author.name =kAuthorNameLocal;
    
    // Create the relationship locally and merge the context with Parse
    newEBook.author = author;
    
    NSError* error;
    [self.testContext save:&error];
    XCTAssertNil(error);
    
    //Sync
    APParseSyncOperation* parseSyncOperation = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    [self.syncQueue addOperation:parseSyncOperation];
    [parseSyncOperation setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        XCTAssertNil(operationError);
    }];
    while ([parseSyncOperation isFinished] == NO && WAIT_PATIENTLY);
    
    PFQuery* eBookQuery = [PFQuery queryWithClassName:@"Book"];
    [eBookQuery whereKey:@"name" containsString:@"eBook#1"];
    __block BOOL done = NO;
    [eBookQuery getFirstObjectInBackgroundWithBlock:^(PFObject *object, NSError *error) {
        XCTAssertNil(error);
        XCTAssertTrue([[object valueForKey:@"format"]isEqualToString:@"PDF"]);
        
        PFObject* relatedAuthor = object[@"author"];
        [relatedAuthor fetch:&error];
        XCTAssertNil(error);
        XCTAssertNotNil(relatedAuthor);
        XCTAssertEqualObjects([relatedAuthor valueForKey:@"name"],kAuthorNameLocal);
        
        done = YES;
    }];
     while (done == NO && WAIT_PATIENTLY);
}


- (void) testInheritanceRemoteCreatedSubEntityObject {
    
    //Sync
    APParseSyncOperation* parseSyncOperation = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    [self.syncQueue addOperation:parseSyncOperation];
    [parseSyncOperation setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        XCTAssertNil(operationError);
    }];
    while ([parseSyncOperation isFinished] == NO && WAIT_PATIENTLY);
    
    PFObject* newEBook = [PFObject objectWithClassName:@"Book"];
    newEBook[@"name"] = @"eBook#1";
    newEBook[@"format"] = @"PDF";
    newEBook[APObjectEntityNameAttributeName] = @"EBook";
    newEBook[APObjectStatusAttributeName] = @(APObjectStatusCreated);
    newEBook[APObjectUIDAttributeName] = [self createObjectUID];
    __block BOOL done = NO;
    [newEBook saveInBackgroundWithBlock:^(BOOL succeeded, NSError *error) {
        XCTAssertNil(error);
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    
    
    PFObject* author = [[PFQuery queryWithClassName:@"Author"]getFirstObject];
    [[author relationForKey:@"books"] addObject:newEBook];
    
    done = NO;
    [author saveInBackgroundWithBlock:^(BOOL succeeded, NSError *error) {
        XCTAssertNil(error);
         done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    
    newEBook[@"author"] = author;
    
    done = NO;
    [newEBook saveInBackgroundWithBlock:^(BOOL succeeded, NSError *error) {
        XCTAssertNil(error);
         done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    
    
    //Sync
    APParseSyncOperation* parseSyncOperation2 = [self newParseSyncOperationWithMergePolicy:APMergePolicyServerWins];
    [self.syncQueue addOperation:parseSyncOperation2];
    [parseSyncOperation2 setSyncCompletionBlock:^(NSDictionary *mergedObjectsUIDsNestedByEntityName, NSError *operationError) {
        XCTAssertNil(operationError);
        
        NSArray* updatedAuthors = mergedObjectsUIDsNestedByEntityName[@"Author"][NSUpdatedObjectsKey];
        XCTAssertTrue([[updatedAuthors lastObject]isEqualToString:[author valueForKey:APObjectUIDAttributeName] ]);
        
        NSArray* insertedBook = mergedObjectsUIDsNestedByEntityName[@"EBook"][NSInsertedObjectsKey];
        XCTAssertTrue([[insertedBook lastObject]isEqualToString:[newEBook valueForKey:APObjectUIDAttributeName]]);
    }];
    while ([parseSyncOperation2 isFinished] == NO && WAIT_PATIENTLY);
    
    
    NSFetchRequest* eBooksFr = [NSFetchRequest fetchRequestWithEntityName:@"EBook"];
    [eBooksFr setPredicate:[NSPredicate predicateWithFormat:@"name == %@",@"eBook#1"]];
    NSError* error = nil;
    NSArray* ebooks = [self.testContext executeFetchRequest:eBooksFr error:&error];
    XCTAssertNil(error);
    EBook* ebook = [ebooks lastObject];
    XCTAssertEqualObjects(ebook.author.name, kAuthorNameParse);
    
    NSFetchRequest* authorFr = [NSFetchRequest fetchRequestWithEntityName:@"Author"];
    NSArray* authors = [self.testContext executeFetchRequest:authorFr error:&error];
    Author* fetchedAuthor = [authors lastObject];
    XCTAssertTrue([fetchedAuthor.books count] == 3);
}


#pragma mark - Support Methods

- (NSString*) createObjectUID {
    
    NSString* objectUID = nil;
    CFUUIDRef uuid = CFUUIDCreate(CFAllocatorGetDefault());
    objectUID = (__bridge_transfer NSString *)CFUUIDCreateString(CFAllocatorGetDefault(), uuid);
    CFRelease(uuid);
    
    return objectUID;
}


- (void) removeAllEntriesFromParse {
    
    MLog();
    [self removeAllObjectsFromParseQuery:[PFQuery queryWithClassName:@"Author"]];
    [self removeAllObjectsFromParseQuery:[PFQuery queryWithClassName:@"Book"]];
    [self removeAllObjectsFromParseQuery:[PFQuery queryWithClassName:@"Page"]];
    [self removeAllObjectsFromParseQuery:[PFQuery queryWithClassName:@"Magazine"]];
}


- (void) removeAllObjectsFromParseQuery:(PFQuery*) query {
    
    dispatch_queue_t queue = dispatch_queue_create("remove objects unit test queue", NULL);
    dispatch_group_t group = dispatch_group_create();
    
    // [Parse setApplicationId:APUnitTestingParsepApplicationId clientKey:APUnitTestingParseClientKey];
    
    dispatch_group_async(group, queue, ^{
        
        // Delete parse object block
        void (^deleteAllObjects)(PFObject*, NSUInteger, BOOL*) = ^(PFObject* obj, NSUInteger idx, BOOL *stop) {
            NSError* error;
            [obj delete:&error];
            if (!error) {
                DLog(@"Object of class: %@ was deleted from Parse",[obj parseClassName]);
            } else {
                ELog(@"Object of class: %@ was not deleted from Parse - error: %@",[obj parseClassName],error);
            }
        };
        
        // count how many objects we have to remove
        // default parse limit of objects per query is 100, can be set to 1000.
        // let's maintain the default.
        NSError* error;
        NSUInteger numberOfObjectsToDelete = [query countObjects:&error];
        if (error) {
            ELog(@"Error counting objects for query for class: %@",query.parseClassName);
            return;
        }
        
        NSUInteger const step = 100;
        NSUInteger deleted = 0;
        while (deleted < numberOfObjectsToDelete) {
            //[query setSkip:skip];
            [[query findObjects]enumerateObjectsUsingBlock:deleteAllObjects];
            deleted += step;
        }
    });
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    
}



- (NSManagedObjectModel*) testModel {
    
    if (!_testModel) {
        
        NSBundle *bundle = [NSBundle bundleForClass:[self class]];
        NSManagedObjectModel* model = [[NSManagedObjectModel mergedModelFromBundles:@[bundle]]copy];
        
        /*
         Adding support properties
         kAPIncrementalStoreUIDAttributeName, kAPIncrementalStoreLastModifiedAttributeName and kAPIncrementalStoreObjectDeletedAttributeName
         for each entity present on model, then we don't need to mess up with the user coredata model
         */
        
        for (NSEntityDescription *entity in model.entities) {
            
            // Don't add properties for sub-entities, as they already exist in the super-entity
            if ([entity superentity]) {
                continue;
            }
            
            NSMutableArray* additionalProperties = [NSMutableArray array];
            
            NSAttributeDescription *uidProperty = [[NSAttributeDescription alloc] init];
            [uidProperty setName:APObjectUIDAttributeName];
            [uidProperty setAttributeType:NSStringAttributeType];
            [uidProperty setIndexed:YES];
            [uidProperty setOptional:NO];
            [additionalProperties addObject:uidProperty];
            
            NSAttributeDescription *aclProperty = [[NSAttributeDescription alloc] init];
            [aclProperty setName:APCoreDataACLAttributeName];
            [aclProperty setAttributeType:NSBinaryDataAttributeType];
            [aclProperty setIndexed:NO];
            [aclProperty setOptional:YES];
            [additionalProperties addObject:aclProperty];
            
            NSAttributeDescription *lastModifiedProperty = [[NSAttributeDescription alloc] init];
            [lastModifiedProperty setName:APObjectLastModifiedAttributeName];
            [lastModifiedProperty setAttributeType:NSDateAttributeType];
            [lastModifiedProperty setIndexed:NO];
            [additionalProperties addObject:lastModifiedProperty];
            
            NSAttributeDescription *statusProperty = [[NSAttributeDescription alloc] init];
            [statusProperty setName:APObjectStatusAttributeName];
            [statusProperty setAttributeType:NSInteger16AttributeType];
            [statusProperty setIndexed:NO];
            [statusProperty setOptional:NO];
            [statusProperty setDefaultValue:@(APObjectStatusCreated)];
            [additionalProperties addObject:statusProperty];
            
            NSAttributeDescription *createdRemotelyProperty = [[NSAttributeDescription alloc] init];
            [createdRemotelyProperty setName:APObjectIsCreatedRemotelyAttributeName];
            [createdRemotelyProperty setAttributeType:NSBooleanAttributeType];
            [createdRemotelyProperty setIndexed:NO];
            [createdRemotelyProperty setOptional:NO];
            [createdRemotelyProperty setDefaultValue:@NO];
            [additionalProperties addObject:createdRemotelyProperty];
            
            NSAttributeDescription *isDirtyProperty = [[NSAttributeDescription alloc] init];
            [isDirtyProperty setName:APObjectIsDirtyAttributeName];
            [isDirtyProperty setAttributeType:NSBooleanAttributeType];
            [isDirtyProperty setIndexed:NO];
            [isDirtyProperty setOptional:NO];
            [isDirtyProperty setDefaultValue:@NO];
            [additionalProperties addObject:isDirtyProperty];
            
            [entity setProperties:[entity.properties arrayByAddingObjectsFromArray:additionalProperties]];
        }
        
         _testModel = model;
    }
    
    return _testModel;
}


- (NSManagedObjectContext*) testContext {
    
    if (!_testContext) {
        NSPersistentStoreCoordinator* psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.testModel];
        NSDictionary *options = @{ NSMigratePersistentStoresAutomaticallyOption: @YES,
                                NSSQLitePragmasOption:@{@"journal_mode":@"DELETE"},
                                   NSInferMappingModelAutomaticallyOption: @YES};
        
        NSURL *storeURL = [NSURL fileURLWithPath:[self pathToLocalStore]];
        
        NSError *error = nil;
        [psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:options error:&error];
        
        if (error) {
            NSLog(@"Error adding store to PSC:%@",error);
        }
        
        _testContext = [[NSManagedObjectContext alloc]initWithConcurrencyType:NSMainQueueConcurrencyType];
        _testContext.persistentStoreCoordinator = psc;
        
        // We don't want to use cached values, we need to fetch from the store.
        [_testContext setStalenessInterval:0];
    }
    return _testContext;
}


- (APParseSyncOperation*) newParseSyncOperationWithMergePolicy:(APMergePolicy) policy {
    
    if (!self.syncPSC) {
        self.syncPSC = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.testModel];
        NSDictionary *options = @{ NSMigratePersistentStoresAutomaticallyOption: @YES,
                                   NSSQLitePragmasOption:@{@"journal_mode":@"DELETE"}, // DEBUG ONLY: Disable WAL mode to be able to visualize the content of the sqlite file.
                                   NSInferMappingModelAutomaticallyOption: @YES};
        NSURL *storeURL = [NSURL fileURLWithPath:[self pathToLocalStore]];
        
        NSError *error = nil;
        [self.syncPSC addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:options error:&error];
        
        if (error) {
            NSLog(@"Error adding store to PSC:%@",error);
        }
    }
    
    APParseSyncOperation* parseConnector = [[APParseSyncOperation alloc]initWithMergePolicy:policy
                                                                     authenticatedParseUser:[PFUser currentUser]
                                                                 persistentStoreCoordinator:self.syncPSC sendPushNotifications:NO];
    return parseConnector;
}


- (NSString *)documentsDirectory {
    
    NSString *documentsDirectory = nil;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    documentsDirectory = paths[0];
    return documentsDirectory;
}


- (NSString *)pathToLocalStore {
    
    return [[self documentsDirectory] stringByAppendingPathComponent:testSqliteFile];
}


- (void) removeCacheStore {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:[self pathToLocalStore]]) {
        NSError *deleteError = nil;
        BOOL delete = [fileManager removeItemAtURL:[NSURL fileURLWithPath:[self pathToLocalStore]] error:&deleteError];
        if (!delete) {
            [NSException raise:APIncrementalStoreExceptionLocalCacheStore format:@""];
        } else {
            if (AP_DEBUG_INFO) { DLog(@"Cache store removed succesfuly") };
        }
    }
}


@end
