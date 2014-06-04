//
//  Author.h
//  Tests
//
//  Created by Flavio Negrão Torres on 6/4/14.
//
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class Book, Magazine;

@interface Author : NSManagedObject

@property (nonatomic, retain) NSString * name;
@property (nonatomic, retain) id photo;
@property (nonatomic, retain) NSSet *books;
@property (nonatomic, retain) NSSet *magazines;
@end

@interface Author (CoreDataGeneratedAccessors)

- (void)addBooksObject:(Book *)value;
- (void)removeBooksObject:(Book *)value;
- (void)addBooks:(NSSet *)values;
- (void)removeBooks:(NSSet *)values;

- (void)addMagazinesObject:(Magazine *)value;
- (void)removeMagazinesObject:(Magazine *)value;
- (void)addMagazines:(NSSet *)values;
- (void)removeMagazines:(NSSet *)values;

@end
