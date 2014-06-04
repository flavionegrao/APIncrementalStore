//
//  Page.h
//  Example
//
//  Created by Flavio Negrão Torres on 6/4/14.
//
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class Book;

@interface Page : NSManagedObject

@property (nonatomic, retain) Book *book;
@property (nonatomic, retain) NSManagedObject *magazine;

@end
