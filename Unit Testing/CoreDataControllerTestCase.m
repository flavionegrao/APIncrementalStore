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

#import "CoreDataController.h"

#import <Parse/Parse.h>
#import "NSLogEmoji.h"
#import "Common.h"

#import "Author+Transformable.h"
#import "Book.h"
#import "Page.h"

#import "UnitTestingCommon.h"

static NSString* const kAuthorName = @"George R. R. Martin";
static NSString* const kBookName1 = @"A Game of Thrones";
static NSString* const kBookName2 = @"A Clash of Kings";

@interface CoreDataControllerTestCase : XCTestCase

@property (strong, nonatomic) dispatch_queue_t queue;
@property (strong, nonatomic) dispatch_group_t group;
@property CoreDataController* coreDataController;

@end

@implementation CoreDataControllerTestCase

#pragma mark - Set up

- (void)setUp {
    
    MLog();
    
    [super setUp];
    NSLog(@"---------Setting up the test environement----------");
    
    self.coreDataController = [[CoreDataController alloc]init];
    
    // All tests will be conducted in background to enable us to supress the *$@%@$ Parse SDK warning
    // complening that we are running long calls in the main thread.
    self.queue = dispatch_queue_create("CoreDataControllerTestCase", DISPATCH_QUEUE_CONCURRENT);
    self.group = dispatch_group_create();
    
    /* Create the objects and its relationships
     
     ----------       --------
     | Author |<---->>| Book |
     ----------       --------
     
     */
    
    [Parse setApplicationId:APUnitTestingParsepApplicationId clientKey:APUnitTestingParseClientKey];
    
    __block PFUser* authenticatedUser;
    dispatch_group_async(self.group, self.queue, ^{
        authenticatedUser = [PFUser currentUser];
        if (!authenticatedUser ) {
            authenticatedUser = [PFUser logInWithUsername:APUnitTestingParseUserName password:APUnitTestingParsePassword];
        }
        [self removeAllEntriesFromParse];
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    [self.coreDataController setRemoteDBAuthenticatedUser:authenticatedUser];
    
    // Starting fresh
    DLog(@"Reseting Cache");
    [self.coreDataController requestResetCache];
    while (self.coreDataController.isResetingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    
    dispatch_group_async(self.group, self.queue, ^{
        // Populating Parse with test objects
        NSError* saveError = nil;
        PFObject* book = [PFObject objectWithClassName:@"Book"];
        [book setValue:kBookName1 forKey:@"name"];
        [book setValue:@NO forKey:APObjectIsDeletedAttributeName];
        [book save:&saveError];
        
        PFObject* author = [PFObject objectWithClassName:@"Author"];
        [author setValue:kAuthorName forKey:@"name"];
        [author setValue:@NO forKey:APObjectIsDeletedAttributeName];
        [author save:&saveError];
        
        // Relation (To-Many)
        [[author relationForKey:@"books"] addObject:book];
        [author save:&saveError];
        
        // Pointer (To-One)
        book[@"author"] = author;
        [book save:&saveError];
        
        if (saveError) {
            ELog(@"Error saving one of the parse objects: %@",saveError);
        }
    });
    
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    // Sync and wait untill it's finished
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    DLog(@"Set-up finished");
}


- (void) tearDown {
    
    MLog();
    
    dispatch_group_async(self.group, self.queue, ^{
        [self removeAllEntriesFromParse];
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    DLog(@"Will call reset cache");
    [self.coreDataController requestResetCache];
    DLog(@"Did call reset cache");
    while (self.coreDataController.isResetingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    DLog(@"Cache is reset");
    
    self.coreDataController = nil;
    
   DLog(@"Tear-Down finished");
    
    [super tearDown];
    
}


#pragma mark - Tests

- (void) testCoreDataControllerIsNotNil {
    
    MLog();
    
    XCTAssertNotNil(self.coreDataController);
}


- (void) testExistingRelationshipBetweenBookAndAuthor {
    
    MLog();
    
    Author* fetchedAuthor = [self fetchAuthor];
    Book* fetchedBook = [self fetchBook];
    XCTAssertEqualObjects(fetchedBook.author, fetchedAuthor);
    
    Book* bookRelatedToFetchedAuthor = [fetchedAuthor.books anyObject];
    XCTAssertEqualObjects(bookRelatedToFetchedAuthor, fetchedBook);
}


- (void) testCountNumberOfAuthors {
    
    MLog();
    
    NSManagedObjectContext* context = self.coreDataController.mainContext;
    NSFetchRequest* fr = [NSFetchRequest fetchRequestWithEntityName:@"Author"];
    NSError* error;
    NSUInteger numberOfExistingAuthors = [context countForFetchRequest:fr error:&error];
    if(error){
        ELog(@"Fetching error: %@",error);
    }
    XCTAssertTrue(numberOfExistingAuthors == 1);
}


- (void) testAddAnotherBookToTheAuthor {
    
    MLog();
    
    Book* book2 = [NSEntityDescription insertNewObjectForEntityForName:@"Book" inManagedObjectContext:self.coreDataController.mainContext];
    book2.name = kBookName2;
    book2.author = [self fetchAuthor];
    XCTAssertTrue([self.coreDataController saveMainContextAndRequestCacheSync:nil]);
    
    // Sync and wait untill it's finished
    while (self.coreDataController.isSyncingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    
    PFQuery* queryForBook2 = [PFQuery queryWithClassName:@"Book"];
    __block NSArray* results;
    dispatch_group_async(self.group, self.queue, ^{
        results = [queryForBook2 findObjects];
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    XCTAssertTrue([results count] == 2);
    
    PFObject* object = [[results filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name == %@",kBookName2]]lastObject];
    XCTAssertNotEqual([object valueForKey:@"nome"], kBookName2);
}


/*
 Author has its relationship to books set with "Delete rule == Cascade", then
 once we delete it, the related books should be deleted as well.
 
 Be mindful that we don't actually delete the objects, instead we mark it as deleted (APObjectIsDeletedAttributeName)
 in order to allow other users to sync the change corretly.
 */
- (void) testRemoveTheAuthor {
    
    MLog();
    
    [self.coreDataController.mainContext deleteObject: [self fetchAuthor]];
    [self.coreDataController.mainContext save:nil];
    
    // Sync and wait untill it's finished
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    
    dispatch_group_async(self.group, self.queue, ^{
        [[[PFQuery queryWithClassName:@"Book"]findObjects]enumerateObjectsUsingBlock:^(PFObject* obj, NSUInteger idx, BOOL *stop) {
            XCTAssertTrue([[obj valueForKey:APObjectIsDeletedAttributeName] isEqualToNumber:@YES]);
        }];
        
        [[[PFQuery queryWithClassName:@"Author"]findObjects]enumerateObjectsUsingBlock:^(PFObject* obj, NSUInteger idx, BOOL *stop) {
            XCTAssertTrue([[obj valueForKey:APObjectIsDeletedAttributeName] isEqualToNumber:@YES]);
        }];
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
}


/*
 Scenario:
 - A new book is included to the existing author, thus the author has 2x books.
 - Book has its relationship to Author set with "Delete rule == Nullify"
 - We delete it the new included book.
 
Expected Results:
 - The existing author should remain with only one book.
 - Be mindful that we don't actually delete the objects, instead we mark it as deleted (apDeleted)
   in order to allow other users to sync this change corretly.
 */
- (void) testRemoveObjectFromToManyRelationship {
    
     MLog();
    
    // Create the second Book and Sync
    DLog(@"Creating new book");
    Book* book2 = [NSEntityDescription insertNewObjectForEntityForName:@"Book" inManagedObjectContext:self.coreDataController.mainContext];
    book2.name = kBookName2;
    book2.author = [self fetchAuthor];
    DLog(@"New book created: %@",book2);
    
    DLog(@"Saving context");
    NSError* error = nil;
    [self.coreDataController.mainContext save:&error];
    XCTAssertNil(error);
    
    DLog(@"Request sync and wait");
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache && [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    DLog(@"Sync is complete");
    
    // Delete the new book and Sync again
     DLog(@"Delete book: %@", book2);
    [self.coreDataController.mainContext deleteObject: book2];
    
    DLog(@"Saving context");
    [self.coreDataController.mainContext save:&error];
    XCTAssertNil(error);
    
    DLog(@"Request sync and wait");
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache && [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    DLog(@"Sync is complete");
    
    // Verify that only one books is marked as delete at Parse
    dispatch_group_async(self.group, self.queue, ^{
        [[[PFQuery queryWithClassName:@"Book"]findObjects]enumerateObjectsUsingBlock:^(PFObject* obj, NSUInteger idx, BOOL *stop) {
            
            if ([[obj valueForKeyPath:@"name"] isEqualToString:kBookName1]) {
                XCTAssertTrue([[obj valueForKey:APObjectIsDeletedAttributeName] isEqualToNumber:@NO]);
                
            } else if ([[obj valueForKeyPath:@"name"] isEqualToString:kBookName2]) {
                XCTAssertTrue([[obj valueForKey:APObjectIsDeletedAttributeName] isEqualToNumber:@YES]);
                
            } else {
                XCTFail();
            }
        }];
        
        // Verify that the author is not marked as delete at Parse
        [[[PFQuery queryWithClassName:@"Author"]findObjects]enumerateObjectsUsingBlock:^(PFObject* obj, NSUInteger idx, BOOL *stop) {
            XCTAssertTrue([[obj valueForKey:APObjectIsDeletedAttributeName] isEqualToNumber:@NO]);
        }];
        
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
}

/*
Below are how much time each attempt took when using more than one thread.
 - 15Mbps ADSL Connection
 - iPhone simulator 32bits
 
 I am aware that Unit Testing does not aim at performance measurements, but this give us a good idea how multithreading affects performance.
 
            Average time
 Threads    Simulator   iPhone 5
 1          6'14"       6'29"
 2          3'12"       3'34"
 3          2'09"       1'58"
 4          2'15"       1'46"   <---
 5          2'13"       2'03"
 10         1'58"       1'53"
 20         2'20"       2'01"
 30         2'15"       2'01"
*/
- (void) testCreateAThousandObjects {
    
    NSDate* start = [NSDate date];
    
    NSUInteger const numberOfAuthorsToBeCreated = 1000;
    NSUInteger const numberOfThreads = 4;
    NSUInteger skip = numberOfAuthorsToBeCreated / numberOfThreads;
    
    __block NSUInteger numberOfAuthorsCreated;
    
    for (NSUInteger thread = 0; thread < numberOfThreads; thread++) {
        
        dispatch_group_async(self.group, self.queue, ^{
            NSError* saveError = nil;
            
            for (NSUInteger i = 0; i < skip; i++) {
                PFObject* author = [PFObject objectWithClassName:@"Author"];
                [author setValue:[NSString stringWithFormat:@"Author#%lu",(unsigned long) thread * skip + i] forKey:@"name"];
                [author setValue:@NO forKey:APObjectIsDeletedAttributeName];
                [author save:&saveError];
                DLog(@"Author created: %@",[author valueForKeyPath:@"name"])
                XCTAssertNil(saveError);
            }
        });
    }
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    ALog(@"Seconds to create all objects: %f",[[NSDate date]timeIntervalSince1970] - [start timeIntervalSince1970]);
    
    __block NSError* countError;
    dispatch_group_async(self.group, self.queue, ^{
        PFQuery* query = [PFQuery queryWithClassName:@"Author"];
        numberOfAuthorsCreated = [query countObjects:&countError];
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    XCTAssertNil(countError);
    XCTAssertTrue(numberOfAuthorsCreated == numberOfAuthorsToBeCreated + 1); //1 from the Setup
    
    // Sync and wait untill it's finished
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    
    NSError* fetchError;
    NSFetchRequest* fr = [NSFetchRequest fetchRequestWithEntityName:@"Author"];
    NSUInteger numberOfAuthorsFetched = [self.coreDataController.mainContext countForFetchRequest:fr error:&fetchError];
    XCTAssertNil(fetchError);
    XCTAssertTrue(numberOfAuthorsFetched == numberOfAuthorsCreated);
}


- (void) testSaveBinary {
    
    MLog();
    Book* book = [self fetchBook];
    // 495KB JPG Image sample image
    NSURL *imageURL = [[[NSBundle mainBundle]bundleURL] URLByAppendingPathComponent:@"Sample_495KB.jpg"];
    NSData* bookCoverData = [NSData dataWithContentsOfURL:imageURL];
    XCTAssertNotNil(bookCoverData);
    
    book.picture = bookCoverData;
    book.name = kBookName2;
    NSError* savingError;
    [self.coreDataController.mainContext save:&savingError];
    
    // Recreate Coredata stack
    self.coreDataController = nil;
    self.coreDataController = [[CoreDataController alloc]init];
    [self.coreDataController setRemoteDBAuthenticatedUser:[PFUser currentUser]];
    
    // Check is the updated book has been saved to disk properly.
    NSFetchRequest* bookFetchRequest = [[NSFetchRequest alloc]initWithEntityName:@"Book"];
    bookFetchRequest.predicate = [NSPredicate predicateWithFormat:@"name = %@",kBookName2];
    NSArray* bookResults = [self.coreDataController.mainContext executeFetchRequest:bookFetchRequest error:nil];
    Book* bookReFetched = [bookResults lastObject];
    XCTAssertNotNil(bookReFetched.picture);
}


/*
 Author has a attribute named photo which is a transformable property.
 The accessors are located in Author+Transformable.h and will transform it to NSData before send it to Core Data
 */
- (void) testSaveImageUsingTransformableAttribute {
    
    Author* author = [self fetchAuthor];
    NSURL *imageURL = [[[NSBundle mainBundle]bundleURL] URLByAppendingPathComponent:@"JRR_Tolkien.jpg"];
    NSData* authorPhotoData = [NSData dataWithContentsOfURL:imageURL];
    XCTAssertNotNil(authorPhotoData);
    
    author.photo = [UIImage imageWithData:authorPhotoData];
    NSError* savingError;
    [self.coreDataController.mainContext save:&savingError];
    
    // Recreate Coredata stack
    self.coreDataController = nil;
    self.coreDataController = [[CoreDataController alloc]init];
    [self.coreDataController setRemoteDBAuthenticatedUser:[PFUser currentUser]];
    
    // Check is the updated book has been saved to disk properly.
    Author* authorReFetched = [self fetchAuthor];
    XCTAssertTrue([authorReFetched.photo isKindOfClass:[UIImage class]]);
}


#pragma mark - Support Methods

- (Book*) fetchBook {
    NSFetchRequest* bookFetchRequest = [[NSFetchRequest alloc]initWithEntityName:@"Book"];
    bookFetchRequest.predicate = [NSPredicate predicateWithFormat:@"name = %@",kBookName1];
    NSArray* bookResults = [self.coreDataController.mainContext executeFetchRequest:bookFetchRequest error:nil];
    return [bookResults lastObject];
}


- (Author*) fetchAuthor {
    NSFetchRequest* authorFetchRequest = [[NSFetchRequest alloc]initWithEntityName:@"Author"];
    authorFetchRequest.predicate = [NSPredicate predicateWithFormat:@"name = %@",kAuthorName];
    NSArray* authorResults = [self.coreDataController.mainContext executeFetchRequest:authorFetchRequest error:nil];
    return [authorResults lastObject];
}


- (void) removeAllEntriesFromParse {
    
    MLog();
    [self removeAllObjectsFromParseQuery:[PFQuery queryWithClassName:@"Author"]];
    [self removeAllObjectsFromParseQuery:[PFQuery queryWithClassName:@"Book"]];
    [self removeAllObjectsFromParseQuery:[PFQuery queryWithClassName:@"Page"]];
}


- (void) removeAllObjectsFromParseQuery:(PFQuery*) query {
    
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
}

@end
