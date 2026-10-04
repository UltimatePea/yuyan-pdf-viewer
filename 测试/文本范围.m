#import <Cocoa/Cocoa.h>
#import "../源码/文本范围.h"
@interface TestPage : PDFPage @end
@implementation TestPage
- (NSUInteger)numberOfCharacters {return 2208;}
@end
@interface TestSelection : PDFSelection
@property NSArray<NSValue *> *ranges;
@property NSArray<PDFPage *> *testPages;
@end
@implementation TestSelection
- (NSArray<PDFPage *> *)pages {return self.testPages;}
- (NSUInteger)numberOfTextRangesOnPage:(PDFPage *)page {return self.ranges.count;}
- (NSRange)rangeAtIndex:(NSUInteger)index onPage:(PDFPage *)page {return self.ranges[index].rangeValue;}
@end
static void Check(BOOL condition,NSString *label){if(!condition){fprintf(stderr,"FAIL %s\n",label.UTF8String);exit(1);}printf("PASS %s\n",label.UTF8String);}
int main(void){@autoreleasepool{
 TestPage *page=[TestPage new];TestSelection *selection=[[TestSelection alloc]initWithDocument:[PDFDocument new]];selection.testPages=@[page];
 NSArray *cases=@[
  @{@"range":[NSValue valueWithRange:NSMakeRange(440,12)],@"valid":@YES,@"label":@"ordinary range"},
  @{@"range":[NSValue valueWithRange:NSMakeRange(440,NSUIntegerMax-118)],@"valid":@NO,@"label":@"reported negative-length range"},
  @{@"range":[NSValue valueWithRange:NSMakeRange(NSUIntegerMax-5,12)],@"valid":@NO,@"label":@"overflowing range end"},
  @{@"range":[NSValue valueWithRange:NSMakeRange(2200,9)],@"valid":@NO,@"label":@"range past text end"},
  @{@"range":[NSValue valueWithRange:NSMakeRange(2209,0)],@"valid":@NO,@"label":@"location past text end"},
  @{@"range":[NSValue valueWithRange:NSMakeRange(2208,0)],@"valid":@YES,@"label":@"empty range at text end"},
  @{@"range":[NSValue valueWithRange:NSMakeRange(0,2208)],@"valid":@YES,@"label":@"whole-page range"}
 ];
 for(NSDictionary *test in cases){selection.ranges=@[test[@"range"]];Check(ValidSelection(selection)==[test[@"valid"] boolValue],test[@"label"]);}
 selection.ranges=@[];Check(!ValidSelection(selection),@"selection without text ranges");
 selection.ranges=@[[NSValue valueWithRange:NSMakeRange(0,12)],[NSValue valueWithRange:NSMakeRange(440,NSUIntegerMax-118)]];Check(!ValidSelection(selection),@"invalid range among valid ranges");
 selection.ranges=@[[NSValue valueWithRange:NSMakeRange(0,12)]];selection.testPages=@[];Check(!ValidSelection(selection),@"selection without pages");
 printf("{\"passed\":10}\n");
}}
