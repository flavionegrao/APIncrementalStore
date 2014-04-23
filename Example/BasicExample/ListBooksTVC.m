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

#import "ListBooksTVC.h"
#import "EditBookTVC.h"
#import "Book.h"
#import "CoreDataController.h"
#import <Parse/Parse.h>

@interface ListBooksTVC ()

@property (nonatomic,strong) NSManagedObjectContext* childContext;

@end

@implementation ListBooksTVC

- (void) viewDidLoad {
    [super viewDidLoad];
    
    if (self.author) {
        NSManagedObjectContext* moc = [CoreDataController sharedInstance].mainContext;
        NSFetchRequest* fr = [NSFetchRequest fetchRequestWithEntityName:@"Book"];
        fr.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]];
        fr.predicate = [NSPredicate predicateWithFormat:@"author == %@",self.author];
        self.frc = [[NSFetchedResultsController alloc]initWithFetchRequest:fr managedObjectContext:moc sectionNameKeyPath:nil cacheName:nil];
    } else {
        NSLog(@"Error: self.author == nil");
    }
}


- (UITableViewCell*) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    
    static NSString* cellID = @"cellID";
    UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:cellID forIndexPath:indexPath];
    Book* book = [self.frc objectAtIndexPath:indexPath];
    cell.textLabel.text = book.name;
    if (book.picture) {
        cell.imageView.image = [UIImage imageWithData:book.picture];
    }
    return cell;
}


- (void) prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    
    if ([segue.identifier isEqualToString:@"addBook"]) {
        UINavigationController* nav = segue.destinationViewController;
        EditBookTVC* vc = (EditBookTVC*) nav.topViewController;
        vc.navigationItem.prompt = [NSString stringWithFormat:@"Logged username: %@",[PFUser currentUser].username];
        
        self.childContext = [[NSManagedObjectContext alloc]initWithConcurrencyType:NSMainQueueConcurrencyType];
        self.childContext.parentContext = [CoreDataController sharedInstance].mainContext;
        vc.book = [NSEntityDescription insertNewObjectForEntityForName:@"Book" inManagedObjectContext:self.childContext];
        vc.book.author = (Author*) [self.childContext objectWithID:self.author.objectID];
        
        [vc setViewDidCancelCallBackBlock:^{
            [self dismissViewControllerAnimated:YES completion:nil];
        }];
        
        [vc setViewDidSaveCallBackBlock:^() {
            [self dismissViewControllerAnimated:YES completion:^{
                NSError* error = nil;
                if (![self.childContext save:&error]) {
                    NSLog(@"Error saving child context :%@",error);
                } else if (![self.childContext.parentContext save:&error]){
                    NSLog(@"Error saving main context :%@",error);
                } else {
                    NSLog(@"New object saved!");
                }
            }];
        }];
        
    } else {
        EditBookTVC* vc = (EditBookTVC*) segue.destinationViewController;
        vc.navigationItem.prompt = [NSString stringWithFormat:@"Logged username: %@",[PFUser currentUser].username];
        NSIndexPath* indexPath = [self.tableView indexPathForCell:sender];
        Book* book = [self.frc objectAtIndexPath:indexPath];
        
        self.childContext = [[NSManagedObjectContext alloc]initWithConcurrencyType:NSMainQueueConcurrencyType];
        self.childContext.parentContext = [CoreDataController sharedInstance].mainContext;
        
        Book* editingBook = (Book*) [self.childContext objectWithID:book.objectID];
        vc.book = editingBook;
        
        [vc setViewDidCancelCallBackBlock:^{
            [self.navigationController popViewControllerAnimated:YES];
        }];
        
        [vc setViewDidSaveCallBackBlock:^() {
            [self.navigationController popViewControllerAnimated:YES];
            
            NSError* error = nil;
            if (![self.childContext save:&error]) {
                NSLog(@"Error saving child context :%@",error);
            } else if (![self.childContext.parentContext save:&error]){
                NSLog(@"Error saving main context :%@",error);
            } else {
                NSLog(@"New object saved!");
            }
            
        }];
        
        [vc setViewDidDeleteCallBackBlock:^{
            [self.navigationController popViewControllerAnimated:YES];
            [self.childContext deleteObject:editingBook];
            
            NSError* error = nil;
            if (![self.childContext save:&error]) {
                NSLog(@"Error saving child context :%@",error);
            } else if (![self.childContext.parentContext save:&error]){
                NSLog(@"Error saving main context :%@",error);
            } else {
                NSLog(@"object deleted!");
            }
        }];
    }
}


@end
