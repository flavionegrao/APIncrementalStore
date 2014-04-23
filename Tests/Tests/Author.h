//
//  Author.h
//  APIncrementalStore
//
//  Created by Flavio Negrão Torres on 4/15/14.
//  Copyright (c) 2014 Flavio Negrão Torres. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class Book;

@interface Author : NSManagedObject

@property (nonatomic, retain) NSString * name;
@property (nonatomic, retain) id photo;
@property (nonatomic, retain) NSSet *books;
@end

@interface Author (CoreDataGeneratedAccessors)

- (void)addBooksObject:(Book *)value;
- (void)removeBooksObject:(Book *)value;
- (void)addBooks:(NSSet *)values;
- (void)removeBooks:(NSSet *)values;

@end
