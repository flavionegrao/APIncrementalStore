//
//  Book.h
//  Tests
//
//  Created by Flavio Negrão Torres on 7/30/14.
//
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class Author, Page;

@interface Book : NSManagedObject

@property (nonatomic, retain) NSString * name;
@property (nonatomic, retain) NSData * picture;
@property (nonatomic, retain) NSDate * createdDate;
@property (nonatomic, retain) Author *author;
@property (nonatomic, retain) NSSet *pages;
@end

@interface Book (CoreDataGeneratedAccessors)

- (void)addPagesObject:(Page *)value;
- (void)removePagesObject:(Page *)value;
- (void)addPages:(NSSet *)values;
- (void)removePages:(NSSet *)values;

@end
