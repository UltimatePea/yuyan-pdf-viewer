// 文言：此桥掌窗、绘卷与取文；决策归豫言。汉语：仅适配 AppKit/PDFKit 与文件通知，策略在豫言中。
#import <Cocoa/Cocoa.h>
#import <PDFKit/PDFKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CommonCrypto/CommonDigest.h>
#import <node_api.h>
#import <sys/stat.h>
#import <fcntl.h>

static NSString *Normalize(NSString *s) {
    return [[[s ?: @"" precomposedStringWithCanonicalMapping] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""];
}
static NSString *Digest(NSData *d) { unsigned char out[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(d.bytes,(CC_LONG)d.length,out); NSMutableString *s=[NSMutableString new]; for(int i=0;i<sizeof(out);i++) [s appendFormat:@"%02x",out[i]]; return s; }
#import "文本范围.h"
#import "差异.h"
static NSArray *Lines(PDFDocument *doc, NSUInteger *skipped, DiffWords *words) {
    NSMutableArray *out=[NSMutableArray new];
    for(NSUInteger p=0;p<doc.pageCount;p++) {
        PDFPage *page=[doc pageAtIndex:p];NSString *content=page.string?:@"";
        PDFSelection *all=[page selectionForRange:NSMakeRange(0,page.numberOfCharacters)];
        for(PDFSelection *line in all.selectionsByLine) {
            if(!ValidTextRanges(line,page)){(*skipped)++;continue;}
            NSRect rect=[line boundsForPage:page];
            // 文言：取词有失，止其较文，不碍观卷。汉语：取词出现异常时只放弃这一版本的差异提示，不影响加载。
            @try{[words addLine:line page:page index:p text:content box:rect];}@catch(NSException *exception){words.failed=YES;}
            NSString *text=Normalize(line.string); if(!text.length) continue;
            [out addObject:@{@"text":text,@"page":@(p),@"rect":NSStringFromRect(rect),@"label":page.label?:@""}];
        }
    }
    return out;
}
@class Viewer;
static Viewer *V, *AppDelegate;
static NSMutableArray<Viewer *> *Windows;
static BOOL Quitting;
static NSMutableDictionary *Histories,*DiffCache,*OutlineStates;
static BOOL DiffHints=YES,RemoveAsks=YES,OutlineShown=YES;
static CGFloat OutlineWidth=260;
static NSUInteger WindowSerial, PollIndex;
static Viewer *OpenWindow(NSString *path);
static BOOL Background(void) {return [NSProcessInfo.processInfo.environment[@"YY_VIEWER_BACKGROUND"] isEqual:@"1"]; }
// 文言：诸版存于私库，退而复启犹在。汉语：版本库。每份 PDF 一个文件夹（以路径的散列为名），每个版本一个 PDF 文件，文件名是毫秒时间戳加内容散列，
// 按文件名排序即时间顺序，不另设索引，删除版本就是删除文件。同名的 .words 与 .lines 是取词、取行结果的缓存（LZFSE 压缩），
// 缺失、损坏、格式号不符或系统版本不同（PDFKit 的取文结果可能随系统变化）时，从 PDF 重新提取并重写。
// 取行或取词的结果有变时须将 StoreFormat 加一。后台测试模式下只有设置了 YY_VERSIONS_DIRECTORY 才启用，绝不触碰用户的版本库。
static const NSInteger StoreFormat=1;
static NSArray<NSString *> *StoreParts(void) {return @[@"pdf",@"words",@"lines"];}
static NSString *StoreBase(void) {
    NSString *base=NSProcessInfo.processInfo.environment[@"YY_VERSIONS_DIRECTORY"];
    if(base.length)return base.stringByStandardizingPath;
    if(Background())return nil;
    return [[[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject].path stringByAppendingPathComponent:@"YuyanPDFViewer/Versions"];
}
static BOOL StoreWrite(NSString *file,NSDictionary *content) {
    NSMutableDictionary *all=[content mutableCopy];all[@"format"]=@(StoreFormat);all[@"system"]=NSProcessInfo.processInfo.operatingSystemVersionString;
    // 文言：行表以 JSON 书之，速而小；词表含原始字节，以属性列表书之。汉语：一份两百页文稿的行表，JSON 比二进制属性列表写得快两倍，
    // 压缩后小三分之一。含原始字节的词表，或文本里有孤立代理项而不能写成 JSON 的行表，用二进制属性列表。
    NSData *plain=nil;
    if([NSJSONSerialization isValidJSONObject:all]){@try{plain=[NSJSONSerialization dataWithJSONObject:all options:0 error:nil];}@catch(NSException *exception){plain=nil;}}
    if(!plain)plain=[NSPropertyListSerialization dataWithPropertyList:all format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    NSData *packed=[plain compressedDataUsingAlgorithm:NSDataCompressionAlgorithmLZFSE error:nil];
    return packed.length&&[packed writeToFile:file options:NSDataWritingAtomic error:nil];
}
static NSDictionary *StoreRead(NSString *file) {
    NSData *packed=file?[NSData dataWithContentsOfFile:file]:nil,*plain=packed.length?[packed decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmLZFSE error:nil]:nil;
    BOOL plist=plain.length>=6&&!memcmp(plain.bytes,"bplist",6);
    id content=!plain.length?nil:plist?[NSPropertyListSerialization propertyListWithData:plain options:NSPropertyListImmutable format:nil error:nil]:[NSJSONSerialization JSONObjectWithData:plain options:0 error:nil];
    if(![content isKindOfClass:NSDictionary.class])return nil;
    return [content[@"format"] isEqual:@(StoreFormat)]&&[content[@"system"] isEqual:NSProcessInfo.processInfo.operatingSystemVersionString]?content:nil;
}
static void StoreMeasure(NSMutableDictionary *snapshot) {
    unsigned long long total=0;NSString *stem=snapshot[@"stem"];
    if(stem)for(NSString *part in StoreParts())total+=[[NSFileManager.defaultManager attributesOfItemAtPath:[stem stringByAppendingPathExtension:part] error:nil] fileSize];
    snapshot[@"disk"]=@(total);
}
@interface ViewerWindow : NSWindow @end
@implementation ViewerWindow
- (BOOL)canBecomeKeyWindow {return !Background()&&[super canBecomeKeyWindow];}
- (BOOL)canBecomeMainWindow {return !Background()&&[super canBecomeMainWindow];}
@end
@interface DropPDF : PDFView <NSDraggingDestination> @end
// 文言：左缘立条，以观全卷之改：绿者增，红者将删。汉语：窗口左缘的概览条，自上而下代表整份文档，如同带标记的滚动条。
// 右半绿色是相对前一版新增之处，左半红色是下一版将删去之处；灰块是当前可见的范围，细框是刚跳到的那一处。
// 点击或拖动即跳到相应位置。所有位置都是 0 到 1 之间的文档比例。
static const CGFloat StripWidth=14,ChangeLine=.3;
@interface ChangeStrip : NSView
@property NSArray<NSArray<NSNumber *> *> *marks;
@property double visibleStart,visibleEnd,currentStart,currentEnd;
@property (copy) void (^clicked)(double fraction);
@end
@implementation ChangeStrip
- (BOOL)isFlipped {return YES;}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {return YES;}
- (NSRect)band:(double)start to:(double)end x:(CGFloat)x width:(CGFloat)width least:(CGFloat)least {
    CGFloat height=self.bounds.size.height,y0=floor(start*height),y1=ceil(end*height);
    if(y1-y0<least){y0=MAX(0,MIN(height-least,round((start+end)/2*height-least/2)));y1=y0+least;}
    return NSMakeRect(x,y0,width,y1-y0);
}
- (void)drawRect:(NSRect)dirty {
    CGFloat width=self.bounds.size.width;
    [[NSColor.labelColor colorWithAlphaComponent:.06] setFill];NSRectFillUsingOperation(self.bounds,NSCompositingOperationSourceOver);
    if(self.visibleEnd>self.visibleStart){[[NSColor.labelColor colorWithAlphaComponent:.16] setFill];NSRectFillUsingOperation([self band:self.visibleStart to:self.visibleEnd x:0 width:width least:6],NSCompositingOperationSourceOver);}
    for(NSArray<NSNumber *> *mark in self.marks){
        BOOL deleted=mark[2].boolValue;[(deleted?NSColor.systemRedColor:NSColor.systemGreenColor) setFill];
        NSRectFill([self band:mark[0].doubleValue to:mark[1].doubleValue x:deleted?2:width/2+1 width:width/2-3 least:3]);
    }
    if(self.currentEnd>self.currentStart){[NSColor.labelColor setStroke];[NSBezierPath strokeRect:NSInsetRect([self band:self.currentStart to:self.currentEnd x:0 width:width least:6],.5,.5)];}
}
- (void)jump:(NSEvent *)event {
    CGFloat height=self.bounds.size.height;
    if(height>0&&self.clicked)self.clicked(MAX(0,MIN(1,[self convertPoint:event.locationInWindow fromView:nil].y/height)));
}
- (void)mouseDown:(NSEvent *)event {[self jump:event];}
- (void)mouseDragged:(NSEvent *)event {[self jump:event];}
@end
// 文言：卷有纲目，列于左栏，击之则至，可隐。汉语：目录栏。PDF 自带的目录（书签）列在窗口左侧，一列标题、一列页码；点击即跳到该处，
// 所读之处所在的条目随滚动而选中。View → Outline（⌃⌘S）显示或隐藏，对所有窗口生效并记住；没有目录的文档不显示此栏。右缘可拖动以调整宽度。
// 每次换文档都从 PDFKit 的目录重建一棵自己的节点树：节点身份稳定，位置与页码只算一次。展开状态以标题路径为键留存，重编译之后不变；
// 用户没有动过的条目，顶层默认展开，其余依 PDF 自己的设定。
static const CGFloat OutlineEdgeWidth=6,OutlineLeast=140,OutlineMost=480,OutlineReserve=360,OutlineSlack=12;
static const NSInteger OutlineDepth=32;
static const NSUInteger OutlineLimit=20000;
@interface OutlineNode : NSObject
@property NSString *title,*label,*key;
@property NSInteger page,level;
@property CGFloat y;
@property double fraction;
@property BOOL open;
@property NSArray<OutlineNode *> *children;
@property (weak) OutlineNode *parent;
@end
@implementation OutlineNode
@end
// page 为 -1 表示条目没有可跳转的目的地。y 是页坐标中的上缘；目的地未指定纵坐标（如 /Fit）时取页顶。key 是自根而下的标题路径，同名的兄弟以序号区分。
static NSArray<OutlineNode *> *OutlineBuild(PDFOutline *above,PDFDocument *document,OutlineNode *parent,NSInteger level,NSUInteger *budget) {
    NSMutableArray<OutlineNode *> *list=[NSMutableArray new];NSCountedSet *seen=[NSCountedSet new];
    for(NSUInteger i=0;i<above.numberOfChildren&&*budget;i++){
        PDFOutline *item=[above childAtIndex:i];if(!item)continue;(*budget)--;
        OutlineNode *node=[OutlineNode new];node.title=item.label?:@"";node.level=level;node.parent=parent;node.open=item.isOpen;node.page=-1;node.label=@"";
        [seen addObject:node.title];node.key=[NSString stringWithFormat:@"%@\n%@#%lu",parent.key?:@"",node.title,(unsigned long)[seen countForObject:node.title]];
        PDFDestination *destination=item.destination;if(!destination&&[item.action isKindOfClass:PDFActionGoTo.class])destination=((PDFActionGoTo *)item.action).destination;
        PDFPage *page=destination.page;NSUInteger index=page?[document indexForPage:page]:NSNotFound;
        if(index!=NSNotFound&&index<document.pageCount){
            NSRect box=[page boundsForBox:kPDFDisplayBoxCropBox];CGFloat y=destination.point.y;
            node.page=(NSInteger)index;node.y=!isfinite(y)||y>=kPDFDestinationUnspecifiedValue?NSMaxY(box):MAX(NSMinY(box),MIN(NSMaxY(box),y));
            node.label=page.label.length?page.label:[NSString stringWithFormat:@"%lu",(unsigned long)index+1];
        }
        node.children=level+1<OutlineDepth?OutlineBuild(item,document,node,level+1,budget):@[];
        [list addObject:node];
    }
    return list;
}
// 文言：开阖必经此二法，故于此记之。汉语：用户点击展开三角与程序调用都经过这两个方法，在这里报告被操作的那一个条目。
// 不用展开、折叠通知：折叠一个条目时，其下已展开的各条目也会收到折叠通知，而它们的状态应当保留，重新展开时照旧。
@interface OutlineList : NSOutlineView
@property (copy) void (^toggled)(id item,BOOL open,BOOL children);
@end
@implementation OutlineList
- (void)expandItem:(id)item expandChildren:(BOOL)children {[super expandItem:item expandChildren:children];if(self.toggled)self.toggled(item,YES,children);}
- (void)collapseItem:(id)item collapseChildren:(BOOL)children {[super collapseItem:item collapseChildren:children];if(self.toggled)self.toggled(item,NO,children);}
@end
// 目录栏右缘：一条分隔线，可左右拖动以调整栏宽。
@interface OutlineEdge : NSView
@property (copy) void (^dragged)(CGFloat x,BOOL finished);
@end
@implementation OutlineEdge
- (void)drawRect:(NSRect)dirty {[NSColor.separatorColor setFill];NSRectFillUsingOperation(NSMakeRect(NSMaxX(self.bounds)-1,0,1,self.bounds.size.height),NSCompositingOperationSourceOver);}
- (void)resetCursorRects {[self addCursorRect:self.bounds cursor:NSCursor.resizeLeftRightCursor];}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {return YES;}
- (void)mouseDown:(NSEvent *)event {}
- (void)mouseDragged:(NSEvent *)event {if(self.dragged)self.dragged(event.locationInWindow.x,NO);}
- (void)mouseUp:(NSEvent *)event {if(self.dragged)self.dragged(event.locationInWindow.x,YES);}
@end
@interface Viewer : NSObject <NSApplicationDelegate,NSWindowDelegate,NSSearchFieldDelegate,NSMenuItemValidation,NSOutlineViewDataSource,NSOutlineViewDelegate>
@property NSWindow *window;
@property NSMenu *menuBar,*windowMenu;
@property NSNumber *cycleDestination;
@property NSArray *scheduler;
@property NSNumber *windowID;
@property DropPDF *pdf;
@property NSTextField *status,*pageField;
@property NSSearchField *search;
@property NSButton *previousSearchButton,*nextSearchButton;
@property NSArray<PDFSelection *> *searchMatches;
@property NSString *searchQuery;
@property NSInteger searchIndex;
@property NSString *path,*digest;
@property NSUInteger skippedTextLines,candidateSkippedTextLines;
@property NSDate *lastUpdated;
@property NSMutableDictionary<NSString *,NSMutableArray *> *histories;
@property NSMutableArray *history;
@property NSInteger versionIndex,candidateVersionIndex;
@property NSData *candidateData;
@property NSDate *candidateTime;
@property NSMenu *versionsMenu;
@property NSAlert *pendingAlert;
@property (copy) void (^pendingAnswer)(NSModalResponse response);
@property NSButton *previousVersionButton,*nextVersionButton,*latestVersionButton;
@property NSArray *lines,*candidateLines,*anchors;
@property NSData *candidateWords;
@property NSArray<PDFSelection *> *addedSelections,*deletedSelections;
@property NSUInteger addedWords,deletedWords;
@property NSMenuItem *diffItem,*previousChangeItem,*nextChangeItem;
@property ChangeStrip *changeStrip;
@property NSButton *previousChangeButton,*nextChangeButton;
@property NSArray<NSDictionary *> *changeSets;
@property NSInteger changeIndex;
@property (weak) NSClipView *watchedClip;
@property NSScrollView *outlineScroll;
@property OutlineList *outlineView;
@property OutlineEdge *outlineEdge;
@property NSMenuItem *outlineItem;
@property NSArray<OutlineNode *> *outlineNodes,*outlineOrder;
@property OutlineNode *outlinePinned;
@property NSString *outlinePinnedPlace;
@property BOOL outlineBusy,outlineHold;
@property NSString *outlineKept;
@property PDFDocument *candidate;
@property NSString *candidateDigest;
@property NSMutableArray *events;
@property NSDictionary *event;
@property dispatch_source_t watch;
@property dispatch_source_t fileWatch;
@property ino_t fileInode;
@property ino_t directoryInode;
@property NSString *fileSignature;
@property double testDelay;
@property NSTimeInterval healthTime;
@property NSUInteger session,commits,loads,watchCount;
@property BOOL follow,fit;
@property NSInteger fallbackPage;
@property NSPoint fallbackPoint,fallbackOffset;
@property CGFloat savedScale;
@property PDFDisplayMode savedMode;
@property NSString *navigationSource;
@property NSInteger navigationLine;
@property NSUInteger navigationSerial;
@property dispatch_queue_t readQueue;
@property NSMutableArray<NSMutableDictionary *> *jumpPoints;
@property NSMenu *jumpMenu;
@property NSButton *setJumpButton;
@property NSArray<NSButton *> *baseButtons;
@property BOOL toolbarOverflow;
@property NSScrollView *jumpBar;
@property CGFloat jumpContentWidth;
@property NSMutableDictionary *matchingJump;
@property BOOL jumpShouldNavigate;
@end
@implementation DropPDF
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {return NSDragOperationCopy;}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSArray *urls=[sender.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
    if(!urls.count)return NO;for(NSURL *url in urls)OpenWindow(url.path);return YES;
}
@end
@implementation Viewer
- (void)enqueue:(NSInteger)kind generation:(NSInteger)g { [self.events addObject:@{@"kind":@(kind),@"generation":@(g)}]; }
- (NSMenuItem *)item:(NSString *)title action:(SEL)action key:(NSString *)key menu:(NSMenu *)menu {NSMenuItem *i=[menu addItemWithTitle:title action:action keyEquivalent:key];i.target=self;return i;}
- (void)setup {
    self.scheduler=@[@0,@0,@0,@0];self.windowID=@(++WindowSerial);[Windows addObject:self];
    self.events=[NSMutableArray new]; self.lines=@[];self.anchors=@[];self.fit=YES;
    self.histories=Histories;self.versionIndex=-1;
    self.readQueue=dispatch_queue_create("org.yuyan.reader.pdf",DISPATCH_QUEUE_SERIAL);
    [NSApplication sharedApplication];if(!AppDelegate){AppDelegate=self;NSApp.delegate=self;[NSApp setActivationPolicy:Background()?NSApplicationActivationPolicyProhibited:NSApplicationActivationPolicyRegular];}
    NSMenu *bar=[NSMenu new];self.menuBar=bar;NSApp.mainMenu=bar;
    NSMenu *app=[NSMenu new]; NSMenuItem *appItem=[bar addItemWithTitle:@"阅卷" action:nil keyEquivalent:@""];appItem.submenu=app;
    [self item:@"About 阅卷" action:@selector(about:) key:@"" menu:app];[app addItem:NSMenuItem.separatorItem];
    [self item:@"Quit 阅卷" action:@selector(quit:) key:@"q" menu:app];
    NSMenu *file=[[NSMenu alloc]initWithTitle:@"File"];[bar addItemWithTitle:@"File" action:nil keyEquivalent:@""].submenu=file;
    [self item:@"New Window" action:@selector(newWindow:) key:@"n" menu:file];
    [self item:@"Open…" action:@selector(open:) key:@"o" menu:file];
    [self item:@"Reload" action:@selector(reload:) key:@"r" menu:file];
    [self item:@"Close Window" action:@selector(closeWindow:) key:@"w" menu:file];
    [self item:@"Print…" action:@selector(print:) key:@"p" menu:file];
    NSMenu *edit=[[NSMenu alloc]initWithTitle:@"Edit"];[bar addItemWithTitle:@"Edit" action:nil keyEquivalent:@""].submenu=edit;
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [self item:@"Find…" action:@selector(find:) key:@"f" menu:edit];
    [self item:@"Find Next" action:@selector(search:) key:@"g" menu:edit];
    NSMenuItem *findPrevious=[self item:@"Find Previous" action:@selector(previousSearch:) key:@"g" menu:edit];findPrevious.keyEquivalentModifierMask=NSEventModifierFlagCommand|NSEventModifierFlagShift;
    NSMenu *view=[[NSMenu alloc]initWithTitle:@"View"];[bar addItemWithTitle:@"View" action:nil keyEquivalent:@""].submenu=view;
    [self item:@"Zoom In" action:@selector(zoomIn:) key:@"+" menu:view];
    [self item:@"Zoom Out" action:@selector(zoomOut:) key:@"-" menu:view];
    [self item:@"Fit to Width" action:@selector(fitWidth:) key:@"0" menu:view];
    [self item:@"Previous Page" action:@selector(previous:) key:@"[" menu:view];
    [self item:@"Next Page" action:@selector(next:) key:@"]" menu:view];
    [self item:@"Single Page / Continuous" action:@selector(mode:) key:@"" menu:view];
    [self item:@"Follow Edits" action:@selector(follow:) key:@"" menu:view];
    self.diffItem=[self item:@"Highlight Changes" action:@selector(toggleDiff:) key:@"" menu:view];self.diffItem.state=DiffHints?NSControlStateValueOn:NSControlStateValueOff;
    self.previousChangeItem=[self item:@"Previous Change" action:@selector(previousChange:) key:[NSString stringWithFormat:@"%C",(unichar)NSUpArrowFunctionKey] menu:view];
    self.nextChangeItem=[self item:@"Next Change" action:@selector(nextChange:) key:[NSString stringWithFormat:@"%C",(unichar)NSDownArrowFunctionKey] menu:view];
    self.previousChangeItem.keyEquivalentModifierMask=self.nextChangeItem.keyEquivalentModifierMask=NSEventModifierFlagCommand|NSEventModifierFlagOption;
    self.outlineItem=[self item:@"Outline" action:@selector(toggleOutline:) key:@"s" menu:view];self.outlineItem.keyEquivalentModifierMask=NSEventModifierFlagCommand|NSEventModifierFlagControl;self.outlineItem.state=OutlineShown?NSControlStateValueOn:NSControlStateValueOff;
    self.jumpPoints=[NSMutableArray new];
    self.jumpMenu=[[NSMenu alloc]initWithTitle:@"Jump Points"];
    [bar addItemWithTitle:@"Jump Points" action:nil keyEquivalent:@""].submenu=self.jumpMenu;
    self.versionsMenu=[[NSMenu alloc]initWithTitle:@"Versions"];[bar addItemWithTitle:@"Versions" action:nil keyEquivalent:@""].submenu=self.versionsMenu;
    self.windowMenu=[[NSMenu alloc]initWithTitle:@"Window"];[bar addItemWithTitle:@"Window" action:nil keyEquivalent:@""].submenu=self.windowMenu;
    [self item:@"Cycle Through Windows" action:@selector(nextWindow:) key:@"`" menu:self.windowMenu];
    NSMenuItem *reverse=[self item:@"Cycle Backward Through Windows" action:@selector(previousWindow:) key:@"~" menu:self.windowMenu];reverse.keyEquivalentModifierMask=NSEventModifierFlagCommand|NSEventModifierFlagShift;
    NSApp.windowsMenu=self.windowMenu;
    self.window=[[ViewerWindow alloc]initWithContentRect:NSMakeRect(180,100,980,820) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    self.window.tabbingMode=NSWindowTabbingModeDisallowed;self.window.title=@"阅卷 — PDF";self.window.delegate=self; self.window.releasedWhenClosed=NO;
    self.window.minSize=NSMakeSize(760,420);
    NSView *root=self.window.contentView;
    self.pdf=[[DropPDF alloc]initWithFrame:NSMakeRect(0,30,980,744)];self.pdf.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    self.pdf.displayMode=kPDFDisplaySinglePageContinuous;self.pdf.autoScales=NO; self.pdf.backgroundColor=NSColor.windowBackgroundColor;
    [self.pdf registerForDraggedTypes:@[NSPasteboardTypeFileURL]];[root addSubview:self.pdf];
    self.changeStrip=[[ChangeStrip alloc]initWithFrame:NSMakeRect(0,30,StripWidth,744)];self.changeStrip.autoresizingMask=NSViewHeightSizable;self.changeIndex=-1;
    self.changeStrip.toolTip=@"Changes in this version: green is added, red is deleted by the next version. Click to go there.";[self.changeStrip setAccessibilityLabel:@"Changes overview"];
    __weak Viewer *weak=self;self.changeStrip.clicked=^(double fraction){[weak stripClicked:fraction];};[root addSubview:self.changeStrip];
    self.outlineView=[[OutlineList alloc]initWithFrame:NSMakeRect(0,0,OutlineWidth,744)];self.outlineView.toggled=^(OutlineNode *node,BOOL open,BOOL children){[weak outlineToggled:node open:open children:children];};
    NSTableColumn *titleColumn=[[NSTableColumn alloc]initWithIdentifier:@"title"],*pageColumn=[[NSTableColumn alloc]initWithIdentifier:@"page"];
    pageColumn.width=pageColumn.minWidth=pageColumn.maxWidth=36;titleColumn.minWidth=60;titleColumn.resizingMask=NSTableColumnAutoresizingMask;pageColumn.resizingMask=NSTableColumnNoResizing;
    [self.outlineView addTableColumn:titleColumn];[self.outlineView addTableColumn:pageColumn];self.outlineView.outlineTableColumn=titleColumn;
    self.outlineView.headerView=nil;self.outlineView.style=NSTableViewStyleFullWidth;self.outlineView.columnAutoresizingStyle=NSTableViewFirstColumnOnlyAutoresizingStyle;self.outlineView.rowHeight=18;self.outlineView.indentationPerLevel=12;self.outlineView.backgroundColor=NSColor.clearColor;
    // 不取键盘焦点：点击目录之后，方向键与空格仍然滚动正文。
    self.outlineView.allowsMultipleSelection=NO;self.outlineView.allowsEmptySelection=YES;self.outlineView.refusesFirstResponder=YES;self.outlineView.allowsColumnReordering=NO;self.outlineView.allowsColumnResizing=NO;
    self.outlineView.dataSource=self;self.outlineView.delegate=self;self.outlineView.target=self;self.outlineView.action=@selector(outlineClicked:);[self.outlineView setAccessibilityLabel:@"Outline"];
    self.outlineScroll=[[NSScrollView alloc]initWithFrame:NSMakeRect(0,30,OutlineWidth-OutlineEdgeWidth,744)];self.outlineScroll.documentView=self.outlineView;self.outlineScroll.hasVerticalScroller=YES;self.outlineScroll.autohidesScrollers=YES;self.outlineScroll.borderType=NSNoBorder;self.outlineScroll.drawsBackground=NO;self.outlineScroll.automaticallyAdjustsContentInsets=NO;self.outlineScroll.contentInsets=NSEdgeInsetsMake(4,0,4,0);self.outlineScroll.hidden=YES;[root addSubview:self.outlineScroll];
    self.outlineEdge=[[OutlineEdge alloc]initWithFrame:NSMakeRect(OutlineWidth-OutlineEdgeWidth,30,OutlineEdgeWidth,744)];self.outlineEdge.hidden=YES;self.outlineEdge.toolTip=@"Drag to resize the outline";
    self.outlineEdge.dragged=^(CGFloat x,BOOL finished){[weak outlineDragged:x finished:finished];};[root addSubview:self.outlineEdge];
    CGFloat x=12;
    NSArray *titles=@[@"Open…",@"‹",@"›",@"−",@"+",@"Fit Width"];
    SEL actions[]={@selector(open:),@selector(previous:),@selector(next:),@selector(zoomOut:),@selector(zoomIn:),@selector(fitWidth:)};
    NSMutableArray *baseButtons=[NSMutableArray new];
    for(int i=0;i<titles.count;i++){NSButton *b=[NSButton buttonWithTitle:titles[i] target:self action:actions[i]];b.frame=NSMakeRect(x,782,i==0?64:i==5?68:30,28);b.autoresizingMask=NSViewMinYMargin;[root addSubview:b];[baseButtons addObject:b];x+=b.frame.size.width+4;}self.baseButtons=baseButtons;
    self.pageField=[[NSTextField alloc]initWithFrame:NSMakeRect(x+5,784,48,24)];self.pageField.placeholderString=@"Page";self.pageField.target=self;self.pageField.action=@selector(page:);self.pageField.autoresizingMask=NSViewMinYMargin;[root addSubview:self.pageField];
    self.setJumpButton=[NSButton buttonWithTitle:@"Set Point" target:self action:@selector(quickSetJumpPoint:)];self.setJumpButton.frame=NSMakeRect(350,782,82,28);self.setJumpButton.autoresizingMask=NSViewMinYMargin;self.setJumpButton.toolTip=@"Set jump point (⌘D). Set a named point with ⇧⌘D or right-click.";[root addSubview:self.setJumpButton];
    self.setJumpButton.menu=[NSMenu new];[self item:@"Set Named Jump Point…" action:@selector(setJumpPoint:) key:@"" menu:self.setJumpButton.menu];
    self.previousVersionButton=[NSButton buttonWithTitle:@"‹" target:self action:@selector(previousVersion:)];self.previousVersionButton.toolTip=@"Previous PDF version (⌥⌘[)";[self.previousVersionButton setAccessibilityLabel:@"Previous PDF version"];
    self.latestVersionButton=[NSButton buttonWithTitle:@"v1/1" target:self action:@selector(latestVersion:)];self.latestVersionButton.toolTip=@"Return to latest PDF version (⌥⌘0)";
    self.nextVersionButton=[NSButton buttonWithTitle:@"›" target:self action:@selector(nextVersion:)];self.nextVersionButton.toolTip=@"Next PDF version (⌥⌘])";[self.nextVersionButton setAccessibilityLabel:@"Next PDF version"];
    self.previousChangeButton=[NSButton buttonWithTitle:@"↑" target:self action:@selector(previousChange:)];self.previousChangeButton.toolTip=@"Previous change (⌥⌘↑)";[self.previousChangeButton setAccessibilityLabel:@"Previous change"];
    self.nextChangeButton=[NSButton buttonWithTitle:@"↓" target:self action:@selector(nextChange:)];self.nextChangeButton.toolTip=@"Next change (⌥⌘↓)";[self.nextChangeButton setAccessibilityLabel:@"Next change"];
    for(NSButton *button in @[self.previousVersionButton,self.latestVersionButton,self.nextVersionButton,self.previousChangeButton,self.nextChangeButton]){button.font=[NSFont systemFontOfSize:11];[root addSubview:button];}
    self.jumpBar=[[NSScrollView alloc]initWithFrame:NSMakeRect(440,782,0,28)];self.jumpBar.autoresizingMask=NSViewMinYMargin;self.jumpBar.hasHorizontalScroller=NO;self.jumpBar.scrollerStyle=NSScrollerStyleOverlay;self.jumpBar.autohidesScrollers=YES;self.jumpBar.drawsBackground=NO;[root addSubview:self.jumpBar];[self refreshJumpMenus];
    self.search=[[NSSearchField alloc]initWithFrame:NSMakeRect(650,784,315,24)];self.search.placeholderString=@"Find in PDF";self.search.target=self;self.search.action=@selector(search:);self.search.delegate=self;self.search.sendsWholeSearchString=YES;self.search.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;[root addSubview:self.search];
    self.previousSearchButton=[NSButton buttonWithTitle:@"‹" target:self action:@selector(previousSearch:)];self.nextSearchButton=[NSButton buttonWithTitle:@"›" target:self action:@selector(search:)];
    [self.previousSearchButton setAccessibilityLabel:@"Previous search match"];[self.nextSearchButton setAccessibilityLabel:@"Next search match"];
    for(NSButton *button in @[self.previousSearchButton,self.nextSearchButton]){button.autoresizingMask=NSViewMinYMargin;[root addSubview:button];}
    [self rebuildSearch];[self refreshVersionControls];[self layoutJumpControls];
    self.status=[NSTextField labelWithString:@"Open a PDF to begin"];self.status.frame=NSMakeRect(12,6,956,18);self.status.autoresizingMask=NSViewWidthSizable;self.status.lineBreakMode=NSLineBreakByTruncatingMiddle;[root addSubview:self.status];
    [[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(pageChanged:) name:PDFViewPageChangedNotification object:self.pdf];
    [[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(scrolled:) name:PDFViewScaleChangedNotification object:self.pdf];
    [[NSDistributedNotificationCenter defaultCenter]addObserver:self selector:@selector(navigationRequest:) name:@"org.yuyan.reader.navigate" object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    if(self==AppDelegate)[NSApp finishLaunching];if(!Background()){[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];}
}
- (void)about:(id)sender {NSAlert *a=[NSAlert new];a.messageText=@"阅卷";a.informativeText=@"Yuyan · Wasm-GC · V8\nNative PDFKit viewer for continuously rebuilt papers.";[a beginSheetModalForWindow:self.window completionHandler:nil];}
- (void)pageChanged:(id)sender {if(self.pdf.document)self.pageField.stringValue=[NSString stringWithFormat:@"%lu",[self.pdf.document indexForPage:self.pdf.currentPage]+1];[self refreshStrip];[self trackOutline];}
- (void)windowDidResize:(NSNotification *)n {[self layoutJumpControls];if(self.fit)[self fitWidth:nil];}
- (void)windowDidBecomeKey:(NSNotification *)n {NSApp.mainMenu=self.menuBar;NSApp.windowsMenu=self.windowMenu;}
- (void)cycleWindow:(NSInteger)step {
    NSUInteger index=[Windows indexOfObject:self];if(index==NSNotFound||!Windows.count)return;
    Viewer *target=Windows[((NSInteger)index+step+(NSInteger)Windows.count)%Windows.count];self.cycleDestination=target.windowID;
    if(!Background()){if(target.window.miniaturized)[target.window deminiaturize:nil];[target.window makeKeyAndOrderFront:nil];}
}
- (void)nextWindow:(id)sender {[self cycleWindow:1];}
- (void)previousWindow:(id)sender {[self cycleWindow:-1];}
- (void)windowWillClose:(NSNotification *)n {[self closeDocument:nil];[[NSNotificationCenter defaultCenter]removeObserver:self];[[NSDistributedNotificationCenter defaultCenter]removeObserver:self];[Windows removeObject:self];if(!Windows.count)Quitting=YES;}
- (void)closeWindow:(id)sender {[self.window performClose:sender];}
- (void)newWindow:(id)sender {OpenWindow(nil);}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {Quitting=YES;return NSTerminateCancel;}
- (BOOL)application:(NSApplication *)app openFile:(NSString *)filename {OpenWindow(filename);return YES;}
- (void)quit:(id)sender {Quitting=YES;}
- (void)open:(id)sender {NSOpenPanel *p=[NSOpenPanel openPanel];p.allowedContentTypes=@[UTTypePDF];p.allowsMultipleSelection=YES;[p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r){if(r==NSModalResponseOK)for(NSURL *url in p.URLs)OpenWindow(url.path);}];}
- (void)stopWatch {if(self.watch){dispatch_source_cancel(self.watch);self.watch=nil;}if(self.fileWatch){dispatch_source_cancel(self.fileWatch);self.fileWatch=nil;}self.fileInode=0;self.directoryInode=0;self.watchCount=0;}
- (void)armDirectoryWatch {
    NSString *directory=self.path.stringByDeletingLastPathComponent;struct stat st;
    BOOL exists=directory&&stat(directory.fileSystemRepresentation,&st)==0;
    if(exists&&self.watch&&self.directoryInode==st.st_ino)return;
    if(self.watch){dispatch_source_cancel(self.watch);self.watch=nil;self.watchCount--;}
    self.directoryInode=0;if(!exists)return;int fd=open(directory.fileSystemRepresentation,O_EVTONLY);if(fd<0)return;
    self.directoryInode=st.st_ino;NSUInteger session=self.session;
    self.watch=dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,fd,DISPATCH_VNODE_WRITE|DISPATCH_VNODE_RENAME|DISPATCH_VNODE_DELETE|DISPATCH_VNODE_EXTEND|DISPATCH_VNODE_ATTRIB,dispatch_get_main_queue());
    dispatch_source_set_event_handler(self.watch,^{if(self.session==session){[self armDirectoryWatch];[self armFileWatch];if(![self.events.lastObject[@"kind"] isEqual:@2])[self enqueue:2 generation:0];}});
    dispatch_source_set_cancel_handler(self.watch,^{close(fd);});dispatch_resume(self.watch);self.watchCount++;
}
- (void)armFileWatch {
    struct stat st;BOOL exists=self.path&&stat(self.path.fileSystemRepresentation,&st)==0;
    if(exists&&self.fileWatch&&self.fileInode==st.st_ino)return;
    if(self.fileWatch){dispatch_source_cancel(self.fileWatch);self.fileWatch=nil;self.watchCount--;}
    self.fileInode=0;if(!exists)return;
    int fd=open(self.path.fileSystemRepresentation,O_EVTONLY);if(fd<0)return;
    self.fileInode=st.st_ino;NSUInteger session=self.session;
    self.fileWatch=dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,fd,DISPATCH_VNODE_WRITE|DISPATCH_VNODE_EXTEND|DISPATCH_VNODE_RENAME|DISPATCH_VNODE_DELETE|DISPATCH_VNODE_ATTRIB,dispatch_get_main_queue());
    dispatch_source_set_event_handler(self.fileWatch,^{if(session==self.session){[self armFileWatch];if(![self.events.lastObject[@"kind"] isEqual:@2])[self enqueue:2 generation:0];}});
    dispatch_source_set_cancel_handler(self.fileWatch,^{close(fd);});dispatch_resume(self.fileWatch);self.watchCount++;
}
- (void)closeDocument:(id)sender {[self stopWatch];self.session++;self.path=nil;self.digest=nil;self.lastUpdated=nil;self.skippedTextLines=0;self.pdf.document=nil;[self rebuildDiff];[self rebuildOutline];[self rebuildSearch];self.lines=@[];[self clearCandidate];self.history=nil;self.versionIndex=-1;self.matchingJump=nil;self.jumpPoints=[NSMutableArray new];[self refreshJumpMenus];[self refreshVersionControls];[self.events removeAllObjects];[self enqueue:1 generation:0];self.status.stringValue=@"No document";self.window.title=@"阅卷 — PDF";}
- (void)openPath:(NSString *)path {
    [self stopWatch];self.session++;self.path=path.stringByStandardizingPath;self.digest=nil;self.lastUpdated=nil;self.skippedTextLines=0;
    self.pdf.document=nil;[self rebuildDiff];[self rebuildOutline];[self rebuildSearch];self.lines=@[];[self clearCandidate];[self.events removeAllObjects];
    self.history=self.histories[self.path];if(!self.history){self.history=[self storedHistory];self.histories[self.path]=self.history;}self.versionIndex=-1;
    self.matchingJump=nil;[self loadJumpPoints];[self refreshJumpMenus];
    self.window.title=[@"阅卷 — " stringByAppendingString:self.path.lastPathComponent];self.window.representedURL=[NSURL fileURLWithPath:self.path];
    self.status.stringValue=[@"Opening · " stringByAppendingString:self.path];
    self.fileSignature=nil;[self armDirectoryWatch];
    [self armFileWatch];
    // 文言：有旧版则先示其末，不待读卷。汉语：本次运行中开过，或版本库里存有此文档的版本，就立即显示最新的一版，随后照常读取磁盘上的文件。
    if(self.history.count&&[self prepareVersion:(NSInteger)self.history.count-1]){[self capture];[self commitLine:-1 anchor:0];}
    [self refreshVersionControls];
    [self enqueue:1 generation:0];
}
- (void)reload:(id)sender {if(self.path)[self enqueue:2 generation:0];}
- (void)previous:(id)sender {[self.pdf goToPreviousPage:sender];}
- (void)next:(id)sender {[self.pdf goToNextPage:sender];}
- (void)page:(id)sender {NSInteger p=self.pageField.integerValue-1;if(p>=0&&p<self.pdf.document.pageCount)[self.pdf goToPage:[self.pdf.document pageAtIndex:p]];}
- (void)zoomIn:(id)sender {self.fit=NO;[self.pdf zoomIn:sender];}
- (void)zoomOut:(id)sender {self.fit=NO;[self.pdf zoomOut:sender];}
- (void)fitWidth:(id)sender {self.fit=YES;PDFPage *p=self.pdf.currentPage?:[self.pdf.document pageAtIndex:0];if(p){NSRect r=[p boundsForBox:self.pdf.displayBox];self.pdf.scaleFactor=MAX(.05,(self.pdf.bounds.size.width-28)/r.size.width);}}
- (void)setModePreservingPosition:(PDFDisplayMode)mode {[self capture];self.pdf.displayMode=mode;[self positionPage:self.fallbackPage point:self.fallbackPoint offset:self.fallbackOffset];[self refreshStrip];[self trackOutline];}
- (void)mode:(id)sender {[self setModePreservingPosition:self.pdf.displayMode==kPDFDisplaySinglePageContinuous?kPDFDisplaySinglePage:kPDFDisplaySinglePageContinuous];}
- (void)follow:(NSMenuItem *)sender {self.follow=!self.follow;sender.state=self.follow?NSControlStateValueOn:NSControlStateValueOff;}
- (void)find:(id)sender {[self.window makeFirstResponder:self.search];}
- (void)rebuildSearch {
    self.searchQuery=self.search.stringValue?:@"";self.searchIndex=-1;
    NSArray *matches=self.searchQuery.length&&self.pdf.document?[self.pdf.document findString:self.searchQuery withOptions:NSCaseInsensitiveSearch]:@[];
    NSMutableArray *valid=[NSMutableArray new];for(PDFSelection *match in matches)if(ValidSelection(match))[valid addObject:match];self.searchMatches=valid;
    for(PDFSelection *match in self.searchMatches)match.color=[NSColor.systemYellowColor colorWithAlphaComponent:.45];
    [self applyHighlights];
    self.previousSearchButton.enabled=self.searchMatches.count>0;self.nextSearchButton.enabled=self.searchMatches.count>0;
    self.previousSearchButton.toolTip=@"Previous search match (⇧⌘G)";self.nextSearchButton.toolTip=@"Next search match (⌘G)";
    self.search.toolTip=self.searchQuery.length?[NSString stringWithFormat:@"%lu matches",self.searchMatches.count]:@"Find in PDF";
}
- (void)stepSearch:(NSInteger)step {
    if(![self.searchQuery isEqual:self.search.stringValue])[self rebuildSearch];
    NSInteger count=self.searchMatches.count;if(!count)return;
    self.searchIndex=self.searchIndex<0?(step>0?0:count-1):(self.searchIndex+step+count)%count;
    PDFSelection *selection=[self.searchMatches[self.searchIndex] copy];selection.color=[NSColor.systemOrangeColor colorWithAlphaComponent:.65];
    [self.pdf setCurrentSelection:selection animate:NO];[self.pdf scrollSelectionToVisible:nil];
    self.search.toolTip=[NSString stringWithFormat:@"Match %ld of %ld",self.searchIndex+1,count];
}
- (void)controlTextDidChange:(NSNotification *)notification {
    if(notification.object!=self.search)return;
    [self.pdf clearSelection];[self rebuildSearch];[self stepSearch:1];
}
- (void)search:(id)sender {[self stepSearch:1];}
- (void)previousSearch:(id)sender {[self stepSearch:-1];}
- (void)print:(id)sender {[[self.pdf.document printOperationForPrintInfo:NSPrintInfo.sharedPrintInfo scalingMode:kPDFPrintPageScaleToFit autoRotate:YES] runOperationModalForWindow:self.window delegate:nil didRunSelector:NULL contextInfo:NULL];}
- (void)begin:(NSInteger)generation {
    if(!self.path)return;[self armDirectoryWatch];[self armFileWatch];self.loads++;
    NSString *path=self.path;NSUInteger session=self.session;double delay=self.testDelay;
    dispatch_async(self.readQueue,^{@autoreleasepool {
        struct stat before,after;BOOL exists=stat(path.fileSystemRepresentation,&before)==0;
        NSData *data=exists?[NSData dataWithContentsOfFile:path options:0 error:nil]:nil;
        BOOL stable=stat(path.fileSystemRepresentation,&after)==0 && exists && before.st_ino==after.st_ino && before.st_size==after.st_size && before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec;
        NSString *hash=data?Digest(data):@"";PDFDocument *doc=nil;NSArray *lines=@[];NSUInteger skipped=0;DiffWords *words=[DiffWords new];NSData *tokens=nil;
        if(stable&&data.length>10){NSData *tail=[data subdataWithRange:NSMakeRange(data.length>4096?data.length-4096:0,MIN(data.length,4096))];NSString *end=[[NSString alloc]initWithData:tail encoding:NSISOLatin1StringEncoding];
            if([[end stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] hasSuffix:@"%%EOF"]){doc=[[PDFDocument alloc]initWithData:data];if(!doc.pageCount||doc.isLocked)doc=nil;}
            if(doc){for(NSUInteger p=0;p<doc.pageCount;p++){if(![doc pageAtIndex:p].pageRef){doc=nil;break;}}}
            if(doc){lines=Lines(doc,&skipped,words);@try{tokens=[words finish];}@catch(NSException *exception){tokens=nil;}}
        }
        if(delay>0)[NSThread sleepForTimeInterval:delay];
        dispatch_async(dispatch_get_main_queue(),^{if(session!=self.session)return;
            if(doc){[self.events addObject:@{@"kind":@3,@"generation":@(generation),@"doc":doc,@"lines":lines,@"digest":hash,@"data":data,@"skipped":@(skipped),@"words":tokens?:[NSData data]}];}
            else [self enqueue:4 generation:generation];
        });
    }});
}
- (void)capture {
    self.savedScale=self.pdf.scaleFactor;self.savedMode=self.pdf.displayMode;
    NSPoint target=NSMakePoint(NSMidX(self.pdf.bounds),NSMaxY(self.pdf.bounds)-self.pdf.bounds.size.height*.35);
    PDFPage *page=[self.pdf pageForPoint:target nearest:YES];self.fallbackPage=page?[self.pdf.document indexForPage:page]:0;
    self.fallbackPoint=page?[self.pdf convertPoint:target toPage:page]:NSZeroPoint;self.fallbackOffset=target;
    NSInteger best=-1;CGFloat dist=CGFLOAT_MAX;
    for(NSUInteger i=0;i<self.lines.count;i++){NSDictionary *l=self.lines[i];PDFPage *p=[self.pdf.document pageAtIndex:[l[@"page"] unsignedIntegerValue]];
        // 文言：非见之页，不取其锚。汉语：单页模式下未显示页的坐标转换也可能落入视口，必须先过滤。
        if(self.pdf.displayMode==kPDFDisplaySinglePage&&p!=self.pdf.currentPage)continue;NSRect r=[self.pdf convertRect:NSRectFromString(l[@"rect"]) fromPage:p];
        if(NSIntersectsRect(r,self.pdf.bounds)&&[l[@"text"] length]>=12){CGFloat d=fabs(NSMidY(r)-target.y);if(d<dist){dist=d;best=i;}}
    }
    NSMutableArray *anchors=[NSMutableArray new];
    for(NSInteger j=0;j<3;j++){NSInteger i=best+(j==1?-1:j==2?1:0);if(best<0||i<0||i>=self.lines.count){[anchors addObject:@{@"text":@"",@"page":@(self.fallbackPage),@"offset":NSStringFromPoint(target)}];continue;}
        NSMutableDictionary *a=[self.lines[i] mutableCopy];NSPoint pt=NSRectFromString(a[@"rect"]).origin;pt=[self.pdf convertPoint:pt fromPage:[self.pdf.document pageAtIndex:[a[@"page"] unsignedIntegerValue]]];a[@"offset"]=NSStringFromPoint(pt);[anchors addObject:a];
    }
    self.anchors=anchors;
}
- (void)positionPage:(NSInteger)index point:(NSPoint)point offset:(NSPoint)offset {
    if(!self.pdf.document.pageCount)return;index=MAX(0,MIN(index,(NSInteger)self.pdf.document.pageCount-1));PDFPage *p=[self.pdf.document pageAtIndex:index];
    [self.pdf goToPage:p];[self.pdf layoutDocumentView];
    NSView *dv=self.pdf.documentView;NSClipView *clip=(NSClipView *)dv.superview;
    if([clip isKindOfClass:NSClipView.class]){NSPoint actual=[self.pdf convertPoint:point fromPage:p];NSPoint a=[dv convertPoint:actual fromView:self.pdf];NSPoint b=[dv convertPoint:offset fromView:self.pdf];NSPoint origin=clip.bounds.origin;origin.x+=a.x-b.x;origin.y+=a.y-b.y;[clip scrollToPoint:[clip constrainBoundsRect:(NSRect){origin,clip.bounds.size}].origin];[(NSScrollView *)clip.superview reflectScrolledClipView:clip];}
}
- (NSString *)dateText:(NSDate *)date {
    // 文言：记成卷之时，精确至秒；无变则不改其时。汉语：使用系统当地时间，保留最后成功更新的时间戳。
    // 版本菜单逐项调用，存盘后版本可达数百，故只建一次。
    static NSDateFormatter *format;
    if(!format){format=[NSDateFormatter new];format.locale=[[NSLocale alloc]initWithLocaleIdentifier:@"en_US_POSIX"];format.calendar=[[NSCalendar alloc]initWithCalendarIdentifier:NSCalendarIdentifierGregorian];format.timeZone=NSTimeZone.localTimeZone;format.dateFormat=@"yyyy-MM-dd HH:mm:ss";}
    return date?[format stringFromDate:date]:@"—";
}
- (NSString *)updatedStatus {
    NSString *prefix=self.versionIndex<(NSInteger)self.history.count-1?[NSString stringWithFormat:@"Viewing version %ld/%lu · ",(long)self.versionIndex+1,self.history.count]:@"";
    NSString *version=prefix.length?@"":[NSString stringWithFormat:@" · Version %ld/%lu",(long)self.versionIndex+1,self.history.count];
    NSString *changes=[NSString stringWithFormat:@"%@%@",self.addedWords?[NSString stringWithFormat:@" +%lu",self.addedWords]:@"",self.deletedWords?[NSString stringWithFormat:@" −%lu",self.deletedWords]:@""];
    if(changes.length)changes=[@" ·" stringByAppendingString:changes];
    if(self.changeIndex>=0&&self.changeIndex<(NSInteger)self.changeSets.count)changes=[changes stringByAppendingFormat:@" · Change %ld/%lu",(long)self.changeIndex+1,self.changeSets.count];
    // 版本库可用而此版未能写入（磁盘已满、无权限）时如实告知：它只在本次运行中保留。
    if(StoreBase()&&self.versionIndex>=0&&self.versionIndex<(NSInteger)self.history.count&&!self.history[self.versionIndex][@"stem"])changes=[changes stringByAppendingString:@" · not saved to disk"];
    return [NSString stringWithFormat:@"%@Updated at %@%@%@ · %lu pages · %@",prefix,[self dateText:self.lastUpdated],version,changes,self.pdf.document.pageCount,self.path?:@""];
}
- (void)commitLine:(NSInteger)line anchor:(NSInteger)anchor {
    if(!self.candidate)return;
    // 换上新文档的那一刻正文先回到别处，目录栏不应跟着跳：先按住，提交完再定。
    [self holdOutline];
    BOOL initial=self.pdf.document==nil;self.pdf.document=self.candidate;self.lines=self.candidateLines;self.digest=self.candidateDigest;self.lastUpdated=self.candidateTime;self.versionIndex=self.candidateVersionIndex;self.skippedTextLines=self.candidateSkippedTextLines;[self clearCandidate];self.commits++;
    [self rebuildOutline];self.pdf.displayMode=self.savedMode; if(initial||self.fit)[self fitWidth:nil];else self.pdf.scaleFactor=self.savedScale;
    if(!initial){if(line>=0&&line<self.lines.count){NSDictionary *l=self.lines[line];NSPoint off=anchor>=0&&anchor<self.anchors.count?NSPointFromString(self.anchors[anchor][@"offset"]):self.fallbackOffset;[self positionPage:[l[@"page"] integerValue] point:NSRectFromString(l[@"rect"]).origin offset:off];}else [self positionPage:self.fallbackPage point:self.fallbackPoint offset:self.fallbackOffset];}
    [self rebuildDiff];self.status.stringValue=[self updatedStatus];[self pageChanged:nil];
    [self refreshJumpMenus];[self refreshVersionControls];[self rebuildSearch];[self releaseOutline];
    [self navigate];
}

// 文言：增者染绿，将删者染红；可于菜单止之。汉语：所览版本相对前一版新增的词为绿底，下一版将删去的词为红底；View → Highlight Changes 可关闭，默认开启并记住选择。
- (NSDictionary *)diffFrom:(NSMutableDictionary *)old to:(NSMutableDictionary *)new {
    NSString *key=[NSString stringWithFormat:@"%@>%@",old[@"digest"],new[@"digest"]];
    NSDictionary *diff=DiffCache[key];if(diff)return diff;
    // 版本库里尚未读入的版本，此时才读其 PDF 与词表。
    if(![self loadWords:old]||![self loadWords:new]||![old[@"words"] length]||![new[@"words"] length])return nil;
    diff=DiffCompute(old[@"words"],new[@"words"],old[@"doc"],new[@"doc"]);DiffCache[key]=diff;
    return diff;
}
// 文言：邻版文同者越之，较于文异之最近者。汉语：重编译而一词未改的版本（只有行号、分页或 PDF 元数据不同）不作为比较对象，
// 否则一次没有改动的构建会让上一处修改的提示消失。step 为 -1 时找此前最近的有词改动的版本，为 1 时找此后最近的。
- (NSDictionary *)changeAt:(NSInteger)index step:(NSInteger)step {
    for(NSInteger other=index+step;other>=0&&other<(NSInteger)self.history.count;other+=step){
        NSDictionary *diff=step<0?[self diffFrom:self.history[other] to:self.history[index]]:[self diffFrom:self.history[index] to:self.history[other]];
        if(!diff)return nil;
        if([diff[@"added"] unsignedIntegerValue]||[diff[@"deleted"] unsignedIntegerValue])return diff;
    }
    return nil;
}
- (void)applyHighlights {
    NSMutableArray *all=[NSMutableArray arrayWithArray:self.addedSelections?:@[]];[all addObjectsFromArray:self.deletedSelections?:@[]];[all addObjectsFromArray:self.searchMatches?:@[]];
    self.pdf.highlightedSelections=all;
}
- (void)rebuildDiff {
    self.addedSelections=@[];self.deletedSelections=@[];self.addedWords=0;self.deletedWords=0;
    NSMutableArray<NSArray<NSNumber *> *> *marks=[NSMutableArray new];
    NSInteger index=self.versionIndex,count=self.history.count;PDFDocument *document=self.pdf.document;
    if(DiffHints&&document&&index>=0&&index<count&&self.history[index][@"doc"]==document){
        @try{
            NSDictionary *current=self.history[index],*diff=[self changeAt:index step:-1];
            if(diff){self.addedWords=[diff[@"added"] unsignedIntegerValue];self.addedSelections=DiffSelections(document,current[@"words"],diff[@"new"],[NSColor.systemGreenColor colorWithAlphaComponent:.35]);
                for(NSArray<NSNumber *> *run in DiffRuns(current[@"words"],diff[@"new"]))[marks addObject:@[run[0],run[3],run[4],@NO]];}
            diff=[self changeAt:index step:1];
            if(diff){self.deletedWords=[diff[@"deleted"] unsignedIntegerValue];self.deletedSelections=DiffSelections(document,current[@"words"],diff[@"old"],[NSColor.systemRedColor colorWithAlphaComponent:.35]);
                for(NSArray<NSNumber *> *run in DiffRuns(current[@"words"],diff[@"old"]))[marks addObject:@[run[0],run[3],run[4],@YES]];}
        }@catch(NSException *exception){self.addedSelections=@[];self.deletedSelections=@[];self.addedWords=0;self.deletedWords=0;[marks removeAllObjects];}
    }
    [self applyHighlights];[self showChanges:marks];
}

// 文言：改处可逐一而览，亦可于左条一望而知。汉语：概览条与“上一处/下一处”。位置以文档比例计：页序加页内自上而下的比例，除以页数；
// 与缩放和显示模式无关。跳转时把该处的上缘放在视口自上而下 ChangeLine 处，不改变横向滚动。
- (double)fractionForPage:(NSUInteger)index y:(CGFloat)y {
    PDFDocument *document=self.pdf.document;if(index>=document.pageCount)return 0;
    NSRect box=[[document pageAtIndex:index] boundsForBox:self.pdf.displayBox];
    double inside=box.size.height>0?(NSMaxY(box)-y)/box.size.height:0;
    return (index+MAX(0,MIN(1,inside)))/document.pageCount;
}
- (double)fractionAtViewY:(CGFloat)y {
    PDFDocument *document=self.pdf.document;if(!document.pageCount)return 0;
    NSPoint point=NSMakePoint(NSMidX(self.pdf.bounds),y);PDFPage *page=[self.pdf pageForPoint:point nearest:YES];if(!page)return 0;
    return [self fractionForPage:[document indexForPage:page] y:[self.pdf convertPoint:point toPage:page].y];
}
- (double)fractionOfSet:(NSInteger)index edge:(NSString *)edge {NSDictionary *set=self.changeSets[index];return [self fractionForPage:[set[@"page"] unsignedIntegerValue] y:[set[edge] doubleValue]];}
- (NSClipView *)clipView {NSClipView *clip=(NSClipView *)self.pdf.documentView.superview;return [clip isKindOfClass:NSClipView.class]?clip:nil;}
- (void)scrolled:(NSNotification *)note {[self refreshStrip];[self trackOutline];}
- (void)refreshStrip {
    // 概览条隐藏时目录栏仍要随滚动更新，故先登记滚动通知。
    NSClipView *clip=[self clipView];
    if(clip&&clip!=self.watchedClip){
        if(self.watchedClip)[[NSNotificationCenter defaultCenter]removeObserver:self name:NSViewBoundsDidChangeNotification object:self.watchedClip];
        self.watchedClip=clip;clip.postsBoundsChangedNotifications=YES;
        [[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(scrolled:) name:NSViewBoundsDidChangeNotification object:clip];
    }
    if(!self.changeStrip||self.changeStrip.hidden)return;
    BOOL any=self.pdf.document.pageCount>0;
    self.changeStrip.visibleStart=any?[self fractionAtViewY:NSMaxY(self.pdf.bounds)]:0;self.changeStrip.visibleEnd=any?[self fractionAtViewY:NSMinY(self.pdf.bounds)]:0;
    [self.changeStrip setNeedsDisplay:YES];
}
- (void)showChanges:(NSArray<NSArray<NSNumber *> *> *)marks {
    NSMutableArray *ticks=[NSMutableArray new];
    for(NSArray<NSNumber *> *mark in marks){NSUInteger page=mark[0].unsignedIntegerValue;[ticks addObject:@[@([self fractionForPage:page y:mark[1].doubleValue]),@([self fractionForPage:page y:mark[2].doubleValue]),mark[3]]];}
    self.changeSets=DiffSets(marks);self.changeIndex=-1;
    self.changeStrip.marks=ticks;self.changeStrip.currentStart=self.changeStrip.currentEnd=0;
    self.previousChangeButton.enabled=self.nextChangeButton.enabled=self.changeSets.count>0;
    [self refreshStrip];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {return item.action==@selector(previousChange:)||item.action==@selector(nextChange:)?self.changeSets.count>0:item.action==@selector(toggleOutline:)?self.outlineNodes.count>0:YES;}
- (void)showPage:(NSUInteger)index y:(CGFloat)y line:(CGFloat)line {
    PDFDocument *document=self.pdf.document;if(index>=document.pageCount)return;
    PDFPage *page=[document pageAtIndex:index];NSClipView *clip=[self clipView];CGFloat x=clip?clip.bounds.origin.x:0;
    [self.pdf goToPage:page];[self.pdf layoutDocumentView];
    NSView *view=self.pdf.documentView;clip=[self clipView];if(!clip)return;
    NSPoint actual=[self.pdf convertPoint:NSMakePoint(NSMinX([page boundsForBox:self.pdf.displayBox]),y) fromPage:page];
    NSPoint from=[view convertPoint:actual fromView:self.pdf],to=[view convertPoint:NSMakePoint(actual.x,NSMaxY(self.pdf.bounds)-self.pdf.bounds.size.height*line) fromView:self.pdf];
    NSPoint origin=NSMakePoint(x,clip.bounds.origin.y+from.y-to.y);
    [clip scrollToPoint:[clip constrainBoundsRect:(NSRect){origin,clip.bounds.size}].origin];[(NSScrollView *)clip.superview reflectScrolledClipView:clip];
}
- (void)showChange:(NSInteger)index {
    if(index<0||index>=(NSInteger)self.changeSets.count)return;
    NSDictionary *set=self.changeSets[index];
    [self showPage:[set[@"page"] unsignedIntegerValue] y:[set[@"top"] doubleValue] line:ChangeLine];
    self.changeIndex=index;
    self.changeStrip.currentStart=[self fractionOfSet:index edge:@"top"];self.changeStrip.currentEnd=[self fractionOfSet:index edge:@"bottom"];
    [self pageChanged:nil];self.status.stringValue=[self updatedStatus];
}
// 文言：所至之处犹在目前，则循序而行；否则自目前所见者始，首尾相续。
// 汉语：刚到过的那一处还在视口内，就按次序到下一处或上一处。否则“下一处”取视口上缘以下的第一处（已在视口内的改动优先，
// 刚做的修改通常就在眼前），“上一处”取完全在视口上缘以上的最后一处。首尾循环。
- (void)stepChange:(NSInteger)step {
    NSInteger count=self.changeSets.count,index;if(!count||!self.pdf.document)return;
    double top=[self fractionAtViewY:NSMaxY(self.pdf.bounds)],bottom=[self fractionAtViewY:NSMinY(self.pdf.bounds)];
    if(self.changeIndex>=0&&self.changeIndex<count&&[self fractionOfSet:self.changeIndex edge:@"bottom"]>top&&[self fractionOfSet:self.changeIndex edge:@"top"]<bottom)index=(self.changeIndex+step+count)%count;
    else if(step>0){index=0;for(NSInteger i=0;i<count;i++)if([self fractionOfSet:i edge:@"bottom"]>top){index=i;break;}}
    else {index=count-1;for(NSInteger i=count-1;i>=0;i--)if([self fractionOfSet:i edge:@"bottom"]<=top){index=i;break;}}
    [self showChange:index];
}
- (void)previousChange:(id)sender {[self stepChange:-1];}
- (void)nextChange:(id)sender {[self stepChange:1];}
// 文言：击条则至其处；近于改处者，径至该处。汉语：点在某处改动的标记上（4 像素以内）就跳到那一处，否则跳到相应的文档位置。
- (void)stripClicked:(double)fraction {
    PDFDocument *document=self.pdf.document;NSUInteger pages=document.pageCount;if(!pages)return;
    CGFloat height=self.changeStrip.bounds.size.height;double reach=height>0?4/height:0;NSInteger nearest=-1;
    for(NSInteger i=0;i<(NSInteger)self.changeSets.count;i++){
        double top=[self fractionOfSet:i edge:@"top"],bottom=[self fractionOfSet:i edge:@"bottom"],distance=fraction<top?top-fraction:fraction>bottom?fraction-bottom:0;
        if(distance<=reach){reach=distance;nearest=i;}
    }
    if(nearest>=0){[self showChange:nearest];return;}
    double position=MIN(fraction*pages,pages-1e-6);NSUInteger index=(NSUInteger)position;NSRect box=[[document pageAtIndex:index] boundsForBox:self.pdf.displayBox];
    [self showPage:index y:NSMaxY(box)-(position-index)*box.size.height line:ChangeLine];
    self.changeIndex=-1;self.changeStrip.currentStart=self.changeStrip.currentEnd=0;[self pageChanged:nil];self.status.stringValue=[self updatedStatus];
}
// 文言：纲目之数、其开阖、所读之条与所至之处。汉语：目录栏的数据源、展开状态、当前条目与跳转。
- (NSInteger)outlineView:(NSOutlineView *)view numberOfChildrenOfItem:(OutlineNode *)item {return item?item.children.count:self.outlineNodes.count;}
- (id)outlineView:(NSOutlineView *)view child:(NSInteger)index ofItem:(OutlineNode *)item {return item?item.children[index]:self.outlineNodes[index];}
- (BOOL)outlineView:(NSOutlineView *)view isItemExpandable:(OutlineNode *)item {return item.children.count>0;}
- (NSView *)outlineView:(NSOutlineView *)view viewForTableColumn:(NSTableColumn *)column item:(OutlineNode *)item {
    BOOL page=[column.identifier isEqual:@"page"];NSTextField *field=[view makeViewWithIdentifier:column.identifier owner:self];
    if(!field){field=[NSTextField labelWithString:@""];field.identifier=column.identifier;field.lineBreakMode=NSLineBreakByTruncatingTail;field.font=[NSFont systemFontOfSize:page?11:12];
        if(page){field.alignment=NSTextAlignmentRight;field.textColor=NSColor.secondaryLabelColor;}}
    field.stringValue=page?item.label:item.title;field.toolTip=page?nil:item.title;return field;
}
- (BOOL)outlineWantsOpen:(OutlineNode *)node {NSNumber *chosen=self.path?OutlineStates[self.path][node.key]:nil;return chosen?chosen.boolValue:node.level==0||node.open;}
- (void)openOutline:(NSArray<OutlineNode *> *)nodes {for(OutlineNode *node in nodes)if(node.children.count&&[self outlineWantsOpen:node]){[self.outlineView expandItem:node];[self openOutline:node.children];}}
- (void)recordOutline:(NSArray<OutlineNode *> *)nodes open:(BOOL)open deep:(BOOL)deep into:(NSMutableDictionary *)state {
    for(OutlineNode *node in nodes){if(node.children.count)state[node.key]=@(open);if(deep)[self recordOutline:node.children open:open deep:YES into:state];}
}
// node 为 nil 指全部顶层条目；children 为真（按住 Option 点击）时连同其下各层一并记下。
- (void)outlineToggled:(OutlineNode *)node open:(BOOL)open children:(BOOL)children {
    if(self.outlineBusy||!self.path)return;
    NSMutableDictionary *state=OutlineStates[self.path];if(!state){state=[NSMutableDictionary new];OutlineStates[self.path]=state;}
    [self recordOutline:node?@[node]:self.outlineNodes open:open deep:children into:state];
    // 刚展开的条目之下，各子条目恢复各自记住的或默认的开阖。
    if(open&&!children){self.outlineBusy=YES;[self openOutline:node?node.children:self.outlineNodes];self.outlineBusy=NO;}
    [self trackOutline];
}
- (void)orderOutline:(NSArray<OutlineNode *> *)nodes into:(NSMutableArray<OutlineNode *> *)order {
    for(OutlineNode *node in nodes){if(node.page>=0){node.fraction=[self fractionForPage:node.page y:node.y];[order addObject:node];}[self orderOutline:node.children into:order];}
}
- (void)rebuildOutline {
    PDFDocument *document=self.pdf.document;NSUInteger budget=OutlineLimit;NSClipView *clip=self.outlineScroll.contentView;NSPoint scroll=clip.bounds.origin;
    self.outlineNodes=document.outlineRoot?OutlineBuild(document.outlineRoot,document,nil,0,&budget):@[];self.outlinePinned=nil;self.outlinePinnedPlace=nil;
    // 文言：依其在卷中之先后列之，以寻所读之条。汉语：有目的地的条目按文档位置排序（目录的顺序未必就是文档的顺序），供查找当前条目。
    NSMutableArray<OutlineNode *> *order=[NSMutableArray new];[self orderOutline:self.outlineNodes into:order];
    [order sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(OutlineNode *a,OutlineNode *b){return a.fraction<b.fraction?NSOrderedAscending:a.fraction>b.fraction?NSOrderedDescending:NSOrderedSame;}];
    self.outlineOrder=order;
    self.outlineBusy=YES;[self.outlineView reloadData];[self openOutline:self.outlineNodes];self.outlineBusy=NO;
    // 文言：栏之隐显有变，乃重排。汉语：只有目录栏需要出现或消失时才重新布局。换版本时布局必须在恢复阅读位置之后进行
    // （工具栏可能随之折行，正文区域的高度会变），而目录栏的有无决定正文区域的宽度，必须在适配宽度之前确定。
    if((OutlineShown&&self.outlineNodes.count>0)==self.outlineScroll.hidden)[self layoutJumpControls];
    // 重编译不应让目录栏滚回顶部。
    [clip scrollToPoint:[clip constrainBoundsRect:(NSRect){scroll,clip.bounds.size}].origin];[self.outlineScroll reflectScrolledClipView:clip];
    [self trackOutline];
}
- (NSString *)outlinePlace {NSClipView *clip=[self clipView];PDFPage *page=self.pdf.currentPage;return [NSString stringWithFormat:@"%lu %@ %g %ld",page?[self.pdf.document indexForPage:page]:0,NSStringFromPoint(clip.bounds.origin),self.pdf.scaleFactor,(long)self.pdf.displayMode];}
// 文言：所读之处，其前最近之条为今条；其条隐于阖者，则取其可见之祖。
// 汉语：当前条目是视口上缘（略向下留出余量）以上最近的一条；它若藏在折叠的条目之下，就选中最近的可见祖先。刚点击过的条目在滚动之前一直保持选中：
// 文档末尾滚不到顶，或紧跟着还有别的标题时，否则会立刻跳到另一条。
// 换文档、调整栏宽时正文会经过若干中间位置：其间不跟随，事毕再定；所选仍是原来那一条时，不为它滚动目录栏。
- (void)holdOutline {self.outlineKept=((OutlineNode *)[self.outlineView itemAtRow:self.outlineView.selectedRow]).key;self.outlineHold=YES;}
- (void)releaseOutline {self.outlineHold=NO;[self trackOutline];}
- (void)trackOutline {
    if(self.outlineHold||!self.outlineScroll||self.outlineScroll.hidden)return;
    NSString *kept=self.outlineKept;self.outlineKept=nil;
    OutlineNode *current=nil;
    if(self.outlinePinned&&[self.outlinePinnedPlace isEqual:[self outlinePlace]])current=self.outlinePinned;
    else {self.outlinePinned=nil;self.outlinePinnedPlace=nil;
        if(self.outlineOrder.count&&self.pdf.document.pageCount){
            double at=[self fractionAtViewY:NSMaxY(self.pdf.bounds)-OutlineSlack];NSInteger low=0,high=(NSInteger)self.outlineOrder.count-1,found=-1;
            while(low<=high){NSInteger middle=(low+high)/2;if(self.outlineOrder[middle].fraction<=at){found=middle;low=middle+1;}else high=middle-1;}
            if(found>=0)current=self.outlineOrder[found];
        }
    }
    NSInteger row=-1;for(OutlineNode *node=current;node&&row<0;node=node.parent)row=[self.outlineView rowForItem:node];
    if(row==self.outlineView.selectedRow)return;
    self.outlineBusy=YES;
    if(row<0)[self.outlineView deselectAll:nil];
    else {[self.outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];if(![((OutlineNode *)[self.outlineView itemAtRow:row]).key isEqual:kept])[self.outlineView scrollRowToVisible:row];}
    self.outlineBusy=NO;
}
// 跳到条目所指之处，把它放在视口上缘。没有目的地的条目不跳，选中项回到所读之处。
- (void)showOutlineRow:(NSInteger)row {
    OutlineNode *node=row>=0&&row<self.outlineView.numberOfRows?[self.outlineView itemAtRow:row]:nil;
    if(node&&node.page>=0&&node.page<(NSInteger)self.pdf.document.pageCount){[self showPage:node.page y:node.y line:0];self.outlinePinned=node;self.outlinePinnedPlace=[self outlinePlace];}
    [self pageChanged:nil];
}
- (void)outlineClicked:(id)sender {[self showOutlineRow:self.outlineView.clickedRow];}
// 目录栏出现、消失或改变宽度时正文区域的宽度随之改变；适合宽度模式下缩放也变，故以所读之处为准重新定位。
- (void)relayoutKeepingPosition {
    BOOL any=self.pdf.document.pageCount>0;if(any)[self capture];[self holdOutline];
    [self layoutJumpControls];if(self.fit)[self fitWidth:nil];
    if(any)[self positionPage:self.fallbackPage point:self.fallbackPoint offset:NSMakePoint(NSMidX(self.pdf.bounds),NSMaxY(self.pdf.bounds)-self.pdf.bounds.size.height*.35)];
    [self pageChanged:nil];[self releaseOutline];
}
- (void)toggleOutline:(id)sender {
    OutlineShown=!OutlineShown;if(!Background())[NSUserDefaults.standardUserDefaults setBool:OutlineShown forKey:@"ShowOutline"];
    for(Viewer *viewer in Windows){viewer.outlineItem.state=OutlineShown?NSControlStateValueOn:NSControlStateValueOff;if(viewer.outlineNodes.count){[viewer relayoutKeepingPosition];if(OutlineShown&&viewer.outlineView.selectedRow>=0)[viewer.outlineView scrollRowToVisible:viewer.outlineView.selectedRow];}}
}
- (void)outlineDragged:(CGFloat)x finished:(BOOL)finished {
    CGFloat width=MAX(OutlineLeast,MIN(OutlineMost,round(x+OutlineEdgeWidth/2)));
    if(width!=OutlineWidth){OutlineWidth=width;for(Viewer *viewer in Windows)if(viewer.outlineNodes.count&&OutlineShown)[viewer relayoutKeepingPosition];}
    if(finished&&!Background())[NSUserDefaults.standardUserDefaults setDouble:OutlineWidth forKey:@"OutlineWidth"];
}
- (void)toggleDiff:(id)sender {
    DiffHints=!DiffHints;if(!Background())[NSUserDefaults.standardUserDefaults setBool:DiffHints forKey:@"HighlightChanges"];
    for(Viewer *viewer in Windows){viewer.diffItem.state=DiffHints?NSControlStateValueOn:NSControlStateValueOff;[viewer rebuildDiff];[viewer layoutJumpControls];if(viewer.fit)[viewer fitWidth:nil];if(viewer.pdf.document)viewer.status.stringValue=[viewer updatedStatus];}
}

// 文言：诸成卷皆藏内存，亦存私库；换览不覆原卷。汉语：保留每次成功加载的内容变更并写入版本库；不自动淘汰旧快照，不写回 PDF。
// 每个版本是一个可变字典：digest、time、bytes 恒有；doc、data、words、lines、skipped 对本次运行中读到的版本恒有，
// 对版本库里的版本则在显示或比较时才读入（loadDocument、loadWords、loadFull 三级）；stem 是它在版本库里的文件名（不含扩展名），未能写入则无。
- (void)clearCandidate {self.candidate=nil;self.candidateLines=nil;self.candidateWords=nil;self.candidateDigest=nil;self.candidateData=nil;self.candidateTime=nil;self.candidateVersionIndex=-1;self.candidateSkippedTextLines=0;}
- (NSString *)storeFolder {NSString *base=self.path?StoreBase():nil;return base?[base stringByAppendingPathComponent:Digest([self.path dataUsingEncoding:NSUTF8StringEncoding])]:nil;}
- (NSMutableArray *)storedHistory {
    NSMutableArray *history=[NSMutableArray new];NSString *folder=[self storeFolder];if(!folder)return history;
    NSRegularExpression *name=[NSRegularExpression regularExpressionWithPattern:@"^(\\d{14})-([0-9a-f]{64})\\.pdf$" options:0 error:nil];
    for(NSString *file in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil] sortedArrayUsingSelector:@selector(compare:)]){
        NSTextCheckingResult *match=[name firstMatchInString:file options:0 range:NSMakeRange(0,file.length)];if(!match)continue;
        unsigned long long bytes=[[NSFileManager.defaultManager attributesOfItemAtPath:[folder stringByAppendingPathComponent:file] error:nil] fileSize];if(!bytes)continue;
        NSMutableDictionary *snapshot=[@{@"digest":[file substringWithRange:[match rangeAtIndex:2]],@"time":[NSDate dateWithTimeIntervalSince1970:[[file substringWithRange:[match rangeAtIndex:1]] longLongValue]/1000.0],@"bytes":@(bytes),@"stem":[folder stringByAppendingPathComponent:file.stringByDeletingPathExtension]} mutableCopy];
        StoreMeasure(snapshot);[history addObject:snapshot];
    }
    return history;
}
- (void)storeText:(NSMutableDictionary *)snapshot {
    NSString *stem=snapshot[@"stem"];if(!stem)return;
    StoreWrite([stem stringByAppendingPathExtension:@"words"],@{@"token":@(sizeof(DiffToken)),@"words":snapshot[@"words"]?:[NSData data]});
    StoreWrite([stem stringByAppendingPathExtension:@"lines"],@{@"skipped":snapshot[@"skipped"]?:@0,@"lines":snapshot[@"lines"]?:@[]});
    StoreMeasure(snapshot);
}
- (void)storeSnapshot:(NSMutableDictionary *)snapshot {
    NSString *folder=[self storeFolder];NSData *data=snapshot[@"data"];if(!folder||!data)return;
    NSFileManager *files=NSFileManager.defaultManager;if(![files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil])return;
    NSString *note=[folder stringByAppendingPathComponent:@"source-path.txt"];if(![files fileExistsAtPath:note])[self.path writeToFile:note atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *stem=[folder stringByAppendingPathComponent:[NSString stringWithFormat:@"%014lld-%@",llround([snapshot[@"time"] timeIntervalSince1970]*1000),snapshot[@"digest"]]];
    if(![data writeToFile:[stem stringByAppendingPathExtension:@"pdf"] options:NSDataWritingAtomic error:nil])return;
    snapshot[@"stem"]=stem;[self storeText:snapshot];
}
- (void)unstore:(NSDictionary *)snapshot {NSString *stem=snapshot[@"stem"];if(stem)for(NSString *part in StoreParts())[NSFileManager.defaultManager removeItemAtPath:[stem stringByAppendingPathExtension:part] error:nil];}
- (BOOL)loadDocument:(NSMutableDictionary *)snapshot {
    if(snapshot[@"doc"])return YES;NSString *stem=snapshot[@"stem"];if(!stem)return NO;
    NSData *data=[NSData dataWithContentsOfFile:[stem stringByAppendingPathExtension:@"pdf"]];if(!data||![Digest(data) isEqual:snapshot[@"digest"]])return NO;
    PDFDocument *doc=[[PDFDocument alloc]initWithData:data];if(!doc.pageCount||doc.isLocked)return NO;
    snapshot[@"data"]=data;snapshot[@"doc"]=doc;return YES;
}
- (void)extract:(NSMutableDictionary *)snapshot {
    NSUInteger skipped=0;DiffWords *words=[DiffWords new];NSData *tokens=nil;NSArray *lines=Lines(snapshot[@"doc"],&skipped,words);
    @try{tokens=[words finish];}@catch(NSException *exception){tokens=nil;}
    snapshot[@"lines"]=lines;snapshot[@"words"]=tokens?:[NSData data];snapshot[@"skipped"]=@(skipped);[self storeText:snapshot];
}
- (BOOL)loadWords:(NSMutableDictionary *)snapshot {
    if(snapshot[@"words"])return YES;if(![self loadDocument:snapshot])return NO;
    NSDictionary *stored=StoreRead([snapshot[@"stem"] stringByAppendingPathExtension:@"words"]);NSData *words=stored[@"words"];
    if([words isKindOfClass:NSData.class]&&[stored[@"token"] isEqual:@(sizeof(DiffToken))]&&words.length%sizeof(DiffToken)==0)snapshot[@"words"]=words;else [self extract:snapshot];
    return YES;
}
- (BOOL)loadFull:(NSMutableDictionary *)snapshot {
    if(snapshot[@"lines"])return YES;if(![self loadWords:snapshot])return NO;
    NSDictionary *stored=StoreRead([snapshot[@"stem"] stringByAppendingPathExtension:@"lines"]);NSArray *lines=stored[@"lines"];NSUInteger pages=[snapshot[@"doc"] pageCount];
    BOOL valid=[lines isKindOfClass:NSArray.class]&&[stored[@"skipped"] isKindOfClass:NSNumber.class];
    if(valid)for(NSDictionary *line in lines)if(![line isKindOfClass:NSDictionary.class]||![line[@"text"] isKindOfClass:NSString.class]||![line[@"rect"] isKindOfClass:NSString.class]||![line[@"label"] isKindOfClass:NSString.class]||![line[@"page"] isKindOfClass:NSNumber.class]||[line[@"page"] unsignedIntegerValue]>=pages){valid=NO;break;}
    if(valid){snapshot[@"lines"]=lines;snapshot[@"skipped"]=stored[@"skipped"];}else [self extract:snapshot];
    return YES;
}
- (void)recordVersion {
    if(!self.candidate||!self.candidateData)return;
    // 文言：时以毫秒记，后者必晚于前。汉语：时间取整到毫秒并严格递增，与版本库的文件名一致，系统时钟回拨也不乱序。
    long long now=llround(NSDate.date.timeIntervalSince1970*1000),last=self.history.count?llround([self.history.lastObject[@"time"] timeIntervalSince1970]*1000):0;
    self.candidateTime=[NSDate dateWithTimeIntervalSince1970:MAX(now,last+1)/1000.0];self.candidateVersionIndex=self.history.count;
    NSMutableDictionary *snapshot=[@{@"doc":self.candidate,@"lines":self.candidateLines,@"digest":self.candidateDigest,@"time":self.candidateTime,@"data":self.candidateData,@"bytes":@(self.candidateData.length),@"skipped":@(self.candidateSkippedTextLines),@"words":self.candidateWords?:[NSData data]} mutableCopy];
    [self.history addObject:snapshot];[self storeSnapshot:snapshot];
}
- (void)retainHistoricalView {[self clearCandidate];[self rebuildDiff];self.status.stringValue=[self updatedStatus];[self refreshVersionControls];[self navigate];}
- (BOOL)prepareVersion:(NSInteger)index {
    if(index<0||index>=self.history.count||index==self.versionIndex)return NO;
    NSMutableDictionary *snapshot=self.history[index];
    if(![self loadFull:snapshot]){self.status.stringValue=[NSString stringWithFormat:@"Version %ld cannot be read from disk · %@",(long)index+1,self.path?:@""];return NO;}
    self.candidate=snapshot[@"doc"];self.candidateLines=snapshot[@"lines"];self.candidateWords=snapshot[@"words"];self.candidateDigest=snapshot[@"digest"];self.candidateData=snapshot[@"data"];self.candidateTime=snapshot[@"time"];self.candidateVersionIndex=index;self.candidateSkippedTextLines=[snapshot[@"skipped"] unsignedIntegerValue];return YES;
}
// 文言：去一版，则其前后二版相较。汉语：删除版本。删去中间的版本后，它前后的两个版本直接相比较，于是可以丢掉一次不想要的改动，只看真正的差别。
// 不能删到一版不剩。正在显示的版本被删时，改为显示它之后最近的一版（没有就取之前的），经由正常的换版本流程，保持阅读位置。
- (void)removeVersions:(NSIndexSet *)indexes {
    NSInteger count=self.history.count,shown=self.versionIndex;
    NSMutableIndexSet *set=[NSMutableIndexSet new];[indexes enumerateIndexesUsingBlock:^(NSUInteger index,BOOL *stop){if((NSInteger)index<count)[set addIndex:index];}];
    if(!set.count||(NSInteger)set.count>=count)return;
    NSMutableDictionary *next=nil;
    if(shown>=0&&[set containsIndex:shown]){
        for(NSInteger i=shown+1;i<count&&!next;i++)if(![set containsIndex:i]&&[self loadFull:self.history[i]])next=self.history[i];
        for(NSInteger i=shown-1;i>=0&&!next;i--)if(![set containsIndex:i]&&[self loadFull:self.history[i]])next=self.history[i];
        if(!next){self.status.stringValue=[NSString stringWithFormat:@"Cannot remove the version on screen: no other version can be read · %@",self.path?:@""];return;}
    }
    NSArray<NSDictionary *> *removed=[self.history objectsAtIndexes:set];[self.history removeObjectsAtIndexes:set];
    for(NSDictionary *snapshot in removed)[self unstore:snapshot];
    // 排队中的换版本请求所指的序号已不再对应原来的版本，弃之。
    [self.events filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *event,NSDictionary *bindings){return ![event[@"kind"] isEqual:@7];}]];
    if(next){self.versionIndex=-1;[self.events insertObject:@{@"kind":@7,@"historyIndex":@([self.history indexOfObjectIdenticalTo:next])} atIndex:0];return;}
    if(shown>=0)self.versionIndex=shown-(NSInteger)[set countOfIndexesInRange:NSMakeRange(0,shown)];
    [self rebuildDiff];if(self.pdf.document)self.status.stringValue=[self updatedStatus];[self refreshVersionControls];
}
// 文言：去版不可复，故先问之；可令勿复问。汉语：删除的版本不能恢复，执行前先确认。删除单个版本的确认框带“不再询问”，勾选后直接删除并记住选择；
// 删除此前全部版本则每次都问。确认框开着的时候可能又有新版本到来，故记下版本本身而不是它们当时的序号。
// 后台测试模式不显示确认框，而是留待测试钩子作答，其余路径与正常运行相同；也不读写用户的“不再询问”选择。
- (void)askToRemove:(NSIndexSet *)indexes earlier:(BOOL)earlier {
    NSInteger count=self.history.count;if(!indexes.count||indexes.lastIndex>=(NSUInteger)count||(NSInteger)indexes.count>=count)return;
    NSArray<NSMutableDictionary *> *chosen=[self.history objectsAtIndexes:indexes];NSUInteger session=self.session;
    void (^remove)(void)=^{
        if(session!=self.session)return;NSMutableIndexSet *set=[NSMutableIndexSet new];
        for(NSMutableDictionary *snapshot in chosen){NSUInteger index=[self.history indexOfObjectIdenticalTo:snapshot];if(index!=NSNotFound)[set addIndex:index];}
        [self removeVersions:set];
    };
    if(!earlier&&!RemoveAsks){remove();return;}
    NSString *name=self.path.lastPathComponent,*time=[self dateText:self.history[earlier?indexes.lastIndex+1:indexes.firstIndex][@"time"]];
    NSAlert *alert=[NSAlert new];
    alert.messageText=!earlier?[NSString stringWithFormat:@"Remove version %lu?",(unsigned long)indexes.firstIndex+1]:indexes.count==1?@"Remove the earlier version?":[NSString stringWithFormat:@"Remove the %lu earlier versions?",(unsigned long)indexes.count];
    alert.informativeText=[NSString stringWithFormat:@"%@ will be deleted from memory and from disk. This cannot be undone.",earlier?[NSString stringWithFormat:@"Every version of %@ before the one on screen (%@)",name,time]:[NSString stringWithFormat:@"Version %lu of %@ (%@)",(unsigned long)indexes.firstIndex+1,name,time]];
    [alert addButtonWithTitle:@"Remove"].hasDestructiveAction=YES;[alert addButtonWithTitle:@"Cancel"];alert.showsSuppressionButton=!earlier;alert.suppressionButton.title=@"Do not ask again";
    void (^answer)(NSModalResponse)=^(NSModalResponse response){
        self.pendingAlert=nil;self.pendingAnswer=nil;if(response!=NSAlertFirstButtonReturn)return;
        if(!earlier&&alert.suppressionButton.state==NSControlStateValueOn){RemoveAsks=NO;if(!Background())[NSUserDefaults.standardUserDefaults setBool:YES forKey:@"RemoveVersionsWithoutAsking"];}
        remove();
    };
    if(Background()){self.pendingAlert=alert;self.pendingAnswer=answer;}else [alert beginSheetModalForWindow:self.window completionHandler:answer];
}
- (void)removeThisVersion:(id)sender {if(self.versionIndex>=0)[self askToRemove:[NSIndexSet indexSetWithIndex:self.versionIndex] earlier:NO];}
- (void)removeVersion:(NSMenuItem *)sender {[self askToRemove:[NSIndexSet indexSetWithIndex:[sender.representedObject unsignedIntegerValue]] earlier:NO];}
- (void)removeEarlierVersions:(id)sender {if(self.versionIndex>0)[self askToRemove:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0,self.versionIndex)] earlier:YES];}
- (void)previousVersion:(id)sender {[self.events addObject:@{@"kind":@7,@"historyStep":@(-1)}];}
- (void)nextVersion:(id)sender {[self.events addObject:@{@"kind":@7,@"historyStep":@1}];}
- (void)latestVersion:(id)sender {[self.events addObject:@{@"kind":@7,@"historyStep":@0}];}
- (void)selectVersion:(NSMenuItem *)sender {[self.events addObject:@{@"kind":@7,@"historyIndex":sender.representedObject}];}
- (void)refreshVersionControls {
    BOOL previous=self.versionIndex>0,next=self.versionIndex>=0&&self.versionIndex<(NSInteger)self.history.count-1;
    self.previousVersionButton.enabled=previous;self.nextVersionButton.enabled=next;self.latestVersionButton.enabled=next;
    self.latestVersionButton.title=[NSString stringWithFormat:@"v%ld/%lu",MAX(0,(long)self.versionIndex+1),self.history.count];
    [self.versionsMenu removeAllItems];self.versionsMenu.autoenablesItems=NO;
    NSArray *titles=@[@"Previous Version",@"Next Version",@"Latest Version"],*keys=@[@"[",@"]",@"0"];
    SEL actions[]={@selector(previousVersion:),@selector(nextVersion:),@selector(latestVersion:)};
    for(int i=0;i<3;i++){NSMenuItem *item=[self item:titles[i] action:actions[i] key:keys[i] menu:self.versionsMenu];item.keyEquivalentModifierMask=NSEventModifierFlagCommand|NSEventModifierFlagOption;item.enabled=i==0?previous:next;}
    [self.versionsMenu addItem:NSMenuItem.separatorItem];
    // 文言：去版三途：去所览者，择一而去，尽去其前。汉语：删除没有快捷键，也不能把最后一个版本删掉。
    NSInteger count=self.history.count;BOOL several=count>1;
    [self item:@"Remove This Version" action:@selector(removeThisVersion:) key:@"" menu:self.versionsMenu].enabled=several&&self.versionIndex>=0;
    NSMenu *removal=[[NSMenu alloc]initWithTitle:@"Remove Version"];removal.autoenablesItems=NO;
    NSMenuItem *choose=[self.versionsMenu addItemWithTitle:@"Remove Version" action:nil keyEquivalent:@""];choose.submenu=removal;choose.enabled=several;
    [self item:@"Remove Earlier Versions…" action:@selector(removeEarlierVersions:) key:@"" menu:self.versionsMenu].enabled=self.versionIndex>0;
    [self.versionsMenu addItem:NSMenuItem.separatorItem];
    NSUInteger stored=0;unsigned long long disk=0;
    for(NSInteger i=count-1;i>=0;i--){NSDictionary *snapshot=self.history[i];NSString *title=[NSString stringWithFormat:@"Version %ld — %@%@",(long)i+1,[self dateText:snapshot[@"time"]],i==count-1?@" (Latest)":@""];
        NSMenuItem *item=[self item:title action:@selector(selectVersion:) key:@"" menu:self.versionsMenu];item.representedObject=@(i);item.state=i==self.versionIndex?NSControlStateValueOn:NSControlStateValueOff;
        NSMenuItem *remove=[self item:title action:@selector(removeVersion:) key:@"" menu:removal];remove.representedObject=@(i);remove.state=item.state;
        if(snapshot[@"stem"]){stored++;disk+=[snapshot[@"disk"] unsignedLongLongValue];}}
    if(count&&StoreBase()){[self.versionsMenu addItem:NSMenuItem.separatorItem];
        [self.versionsMenu addItemWithTitle:[NSString stringWithFormat:@"Stored on disk: %lu of %ld · %@",(unsigned long)stored,(long)count,[NSByteCountFormatter stringFromByteCount:(long long)disk countStyle:NSByteCountFormatterCountStyleFile]] action:nil keyEquivalent:@""].enabled=NO;}
    [self layoutJumpControls];
}

// 文言：跳点存于私库，不改原卷；寻锚之策仍归豫言。汉语：持久化与菜单适配，不在此实现文本匹配算法。
- (NSString *)jumpStorePath {
    if(!self.path)return nil;
    NSString *base=NSProcessInfo.processInfo.environment[@"YY_JUMP_POINTS_DIRECTORY"];
    if(!base.length)base=[[[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject].path stringByAppendingPathComponent:@"YuyanPDFViewer/JumpPoints"];
    return [base stringByAppendingPathComponent:[Digest([self.path dataUsingEncoding:NSUTF8StringEncoding]) stringByAppendingString:@".json"]];
}
- (void)loadJumpPoints {
    self.jumpPoints=[NSMutableArray new];NSData *data=[NSData dataWithContentsOfFile:[self jumpStorePath]];
    id rows=data?[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil]:nil;
    if(![rows isKindOfClass:NSArray.class])return;
    NSMutableSet *ids=[NSMutableSet new];
    for(id row in rows){
        if(![row isKindOfClass:NSMutableDictionary.class])continue;
        BOOL valid=YES;
        for(NSString *key in @[@"id",@"name",@"point",@"offset"])if(![row[key] isKindOfClass:NSString.class])valid=NO;
        for(NSString *key in @[@"page",@"width",@"height",@"scale"])if(![row[key] isKindOfClass:NSNumber.class]||!isfinite([row[key] doubleValue]))valid=NO;
        if(!valid||![row[@"id"] length]||![row[@"name"] length]||[ids containsObject:row[@"id"]]||[row[@"width"] doubleValue]<=0||[row[@"height"] doubleValue]<=0||[row[@"scale"] doubleValue]<=0)continue;
        if(![row[@"anchors"] isKindOfClass:NSArray.class]||[row[@"anchors"] count]!=3)continue;
        for(id anchor in row[@"anchors"]){if(![anchor isKindOfClass:NSDictionary.class]){valid=NO;break;}
            for(NSString *key in @[@"text",@"offset"])if(![anchor[key] isKindOfClass:NSString.class])valid=NO;
            if(![anchor[@"page"] isKindOfClass:NSNumber.class])valid=NO;
        }
        if(valid){[ids addObject:row[@"id"]];[self.jumpPoints addObject:row];}
    }
}
- (void)saveJumpPoints {
    NSString *path=[self jumpStorePath];if(!path)return;NSError *error=nil;
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error];
    NSData *data=[NSJSONSerialization dataWithJSONObject:self.jumpPoints options:NSJSONWritingPrettyPrinted error:&error];
    if(!data||![data writeToFile:path options:NSDataWritingAtomic error:&error])self.status.stringValue=@"Jump points available this session; could not save them";
}
- (NSDictionary *)jumpSnapshot {
    [self capture];return @{@"anchors":self.anchors,@"page":@(self.fallbackPage),@"point":NSStringFromPoint(self.fallbackPoint),@"offset":NSStringFromPoint(self.fallbackOffset),@"width":@(MAX(1,self.pdf.bounds.size.width)),@"height":@(MAX(1,self.pdf.bounds.size.height)),@"scale":@(self.pdf.scaleFactor)};
}
- (void)fillJumpMenu:(NSMenu *)menu {
    [menu removeAllItems];menu.autoenablesItems=NO;
    NSMenuItem *add=[self item:@"Set Jump Point" action:@selector(quickSetJumpPoint:) key:@"d" menu:menu];add.enabled=self.pdf.document!=nil;
    NSMenuItem *named=[self item:@"Set Named Jump Point…" action:@selector(setJumpPoint:) key:@"d" menu:menu];named.keyEquivalentModifierMask=NSEventModifierFlagCommand|NSEventModifierFlagShift;named.enabled=self.pdf.document!=nil;
    [menu addItem:NSMenuItem.separatorItem];
    if(!self.jumpPoints.count){NSMenuItem *empty=[menu addItemWithTitle:@"No jump points yet" action:nil keyEquivalent:@""];empty.enabled=NO;}
    NSUInteger slot=0;for(NSDictionary *point in self.jumpPoints){
        NSString *title=[NSString stringWithFormat:@"%@ — Page %ld",point[@"name"],(long)[point[@"page"] integerValue]+1];
        NSMenuItem *item=[menu addItemWithTitle:title action:nil keyEquivalent:@""];NSMenu *actions=[[NSMenu alloc]initWithTitle:title];actions.autoenablesItems=NO;item.submenu=actions;
        NSString *key=slot<9?[NSString stringWithFormat:@"%lu",(unsigned long)slot+1]:@"";slot++;
        NSMenuItem *jump=[self item:@"Jump to Point" action:@selector(jumpToPoint:) key:key menu:actions];jump.representedObject=point[@"id"];jump.enabled=self.pdf.document!=nil;
        NSMenuItem *rename=[self item:@"Rename…" action:@selector(renameJumpPoint:) key:@"" menu:actions];rename.representedObject=point[@"id"];
        NSMenuItem *remove=[self item:@"Remove Jump Point" action:@selector(removeJumpPoint:) key:@"" menu:actions];remove.representedObject=point[@"id"];
    }
}
- (void)refreshJumpMenus {
    [self fillJumpMenu:self.jumpMenu];self.setJumpButton.enabled=self.pdf.document!=nil;
    if(!self.jumpBar)return;
    NSPoint scroll=self.jumpBar.contentView.bounds.origin;NSView *row=[[NSView alloc]initWithFrame:NSMakeRect(0,0,1,40)];CGFloat x=0;
    NSUInteger slot=0;for(NSDictionary *point in self.jumpPoints){
        NSString *key=slot<9?[NSString stringWithFormat:@"  ⌘%lu",(unsigned long)slot+1]:@"";
        NSString *title=point[@"name"];CGFloat width=MIN(116,MAX(28,[title sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13]}].width+18));
        NSButton *jump=[NSButton buttonWithTitle:title target:self action:@selector(jumpButton:)];jump.frame=NSMakeRect(x,4,width,32);jump.identifier=point[@"id"];jump.enabled=self.pdf.document!=nil;[jump.cell setLineBreakMode:NSLineBreakByTruncatingTail];jump.toolTip=[NSString stringWithFormat:@"Jump to %@ — Page %ld%@",point[@"name"],(long)[point[@"page"] integerValue]+1,key];[row addSubview:jump];
        NSMenu *context=[NSMenu new];context.autoenablesItems=NO;
        NSMenuItem *go=[self item:@"Jump to Point" action:@selector(jumpToPoint:) key:@"" menu:context];go.representedObject=point[@"id"];go.enabled=self.pdf.document!=nil;
        NSMenuItem *rename=[self item:@"Rename…" action:@selector(renameJumpPoint:) key:@"" menu:context];rename.representedObject=point[@"id"];
        NSMenuItem *remove=[self item:@"Remove Jump Point" action:@selector(removeJumpPoint:) key:@"" menu:context];remove.representedObject=point[@"id"];jump.menu=context;
        [jump setAccessibilityLabel:[NSString stringWithFormat:@"Jump to %@%@",point[@"name"],key]];x+=width+4;slot++;
    }
    self.jumpContentWidth=x;[self layoutJumpControls];row.frame=NSMakeRect(0,0,MAX(x,self.jumpBar.contentSize.width),40);self.jumpBar.documentView=row;
    [self.jumpBar.contentView scrollToPoint:[self.jumpBar.contentView constrainBoundsRect:(NSRect){scroll,self.jumpBar.contentView.bounds.size}].origin];
}
- (void)layoutJumpControls {
    if(!self.jumpBar)return;
    NSSize size=self.window.contentView.bounds.size;BOOL showHistory=self.history.count>1,showChanges=showHistory&&DiffHints;
    CGFloat historyWidth=showHistory?(showChanges?160:110):0,pointWidth=self.jumpPoints.count?self.jumpContentWidth+8:0;
    self.toolbarOverflow=size.width<440+historyWidth+pointWidth+256;
    // Regular-height buttons and a taller scroll viewport avoid macOS 27 bezel clipping.
    CGFloat top=size.height-42,row=self.toolbarOverflow?top-42:top;
    for(NSButton *button in self.baseButtons){NSRect frame=button.frame;frame.origin.y=top;frame.size.height=32;button.frame=frame;}
    self.pageField.frame=NSMakeRect(293,top+4,48,24);self.setJumpButton.frame=NSMakeRect(350,top,82,32);
    CGFloat start=self.toolbarOverflow?12:440;
    self.previousVersionButton.hidden=!showHistory;self.latestVersionButton.hidden=!showHistory;self.nextVersionButton.hidden=!showHistory;
    self.previousVersionButton.frame=NSMakeRect(start,row,22,32);self.latestVersionButton.frame=NSMakeRect(start+24,row,54,32);self.nextVersionButton.frame=NSMakeRect(start+80,row,22,32);
    self.previousChangeButton.hidden=!showChanges;self.nextChangeButton.hidden=!showChanges;
    self.previousChangeButton.frame=NSMakeRect(start+106,row,22,32);self.nextChangeButton.frame=NSMakeRect(start+130,row,22,32);
    start+=historyWidth;
    CGFloat available=MAX(0,size.width-start-12),width=self.jumpPoints.count?MIN(self.jumpContentWidth,self.toolbarOverflow?available:MAX(0,available-256)):0;
    self.jumpBar.hidden=self.jumpPoints.count==0;self.jumpBar.frame=NSMakeRect(start,row-4,width,40);
    if(self.jumpBar.documentView){NSRect frame=self.jumpBar.documentView.frame;frame.size=NSMakeSize(MAX(self.jumpContentWidth,self.jumpBar.contentSize.width),40);self.jumpBar.documentView.frame=frame;}
    CGFloat searchX=self.toolbarOverflow?440:start+width+(self.jumpPoints.count?8:0);
    self.search.frame=NSMakeRect(searchX,top+4,MAX(0,size.width-searchX-76),24);
    self.previousSearchButton.frame=NSMakeRect(size.width-72,top,28,32);self.nextSearchButton.frame=NSMakeRect(size.width-40,top,28,32);
    CGFloat strip=DiffHints?StripWidth:0,height=MAX(0,size.height-30-(self.toolbarOverflow?94:52));
    // 目录栏在最左，其右是概览条，再右是正文。窗口很窄时栏宽让位于正文，但不小于下限。
    BOOL outline=OutlineShown&&self.outlineNodes.count>0;CGFloat side=outline?MAX(OutlineLeast,MIN(OutlineWidth,size.width-OutlineReserve)):0;
    self.outlineScroll.hidden=self.outlineEdge.hidden=!outline;
    self.outlineScroll.frame=NSMakeRect(0,30,MAX(0,side-OutlineEdgeWidth),height);self.outlineEdge.frame=NSMakeRect(MAX(0,side-OutlineEdgeWidth),30,OutlineEdgeWidth,height);
    // 标题一列占满页码以外的宽度。
    if(outline)[self.outlineView sizeToFit];
    self.changeStrip.hidden=!DiffHints;self.changeStrip.frame=NSMakeRect(side,30,strip,height);
    self.pdf.frame=NSMakeRect(side+strip,30,MAX(0,size.width-side-strip),height);[self refreshStrip];[self trackOutline];
}
- (void)jumpButton:(NSButton *)sender {NSMenuItem *item=[NSMenuItem new];item.representedObject=sender.identifier;[self jumpToPoint:item];}
- (void)quickSetJumpPoint:(id)sender {if(self.pdf.document)[self queueJumpName:@"" snapshot:[self jumpSnapshot]];}
- (void)queueJumpName:(NSString *)name snapshot:(NSDictionary *)snapshot {
    [self.events addObject:@{@"kind":@6,@"name":[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],@"location":snapshot}];
}
- (void)setJumpPoint:(id)sender {
    if(!self.pdf.document)return;
    NSDictionary *snapshot=[self jumpSnapshot];NSUInteger session=self.session;
    NSAlert *alert=[NSAlert new];alert.messageText=@"Set Jump Point";alert.informativeText=@"Save the current reading location. Give it a name, or leave it blank for an automatic label (A, B, C…).";
    [alert addButtonWithTitle:@"Set Jump Point"];[alert addButtonWithTitle:@"Cancel"];
    NSTextField *name=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,320,24)];name.placeholderString=@"Name (optional)";alert.accessoryView=name;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response){if(response==NSAlertFirstButtonReturn&&session==self.session)[self queueJumpName:name.stringValue snapshot:snapshot];}];
    [alert.window makeFirstResponder:name];
}
- (void)addJumpPointNamed:(NSString *)name {
    if(!self.pdf.document||!self.event[@"location"])return;
    NSMutableDictionary *point=[self.event[@"location"] mutableCopy];point[@"id"]=NSUUID.UUID.UUIDString;point[@"name"]=name;
    [self.jumpPoints addObject:point];self.status.stringValue=[NSString stringWithFormat:@"Jump point %@ saved",name];[self saveJumpPoints];[self refreshJumpMenus];
}
- (void)jumpToPoint:(NSMenuItem *)sender {
    if(self.pdf.document)[self.events addObject:@{@"kind":@5,@"jumpID":sender.representedObject}];
}
- (BOOL)renameJumpID:(NSString *)identifier name:(NSString *)name {
    name=[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!name.length){self.status.stringValue=@"A jump point name cannot be empty";return NO;}
    for(NSMutableDictionary *point in self.jumpPoints)if([point[@"id"] isEqual:identifier]){
        point[@"name"]=name;[self saveJumpPoints];[self refreshJumpMenus];return YES;
    }return NO;
}
- (void)renameJumpPoint:(NSMenuItem *)sender {
    NSString *identifier=sender.representedObject;NSDictionary *point=nil;
    for(NSDictionary *p in self.jumpPoints)if([p[@"id"] isEqual:identifier]){point=p;break;}if(!point)return;
    NSUInteger session=self.session;NSAlert *alert=[NSAlert new];alert.messageText=@"Rename Jump Point";alert.informativeText=@"Choose a name for this saved location.";
    [alert addButtonWithTitle:@"Rename"];[alert addButtonWithTitle:@"Cancel"];
    NSTextField *name=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,320,24)];name.stringValue=point[@"name"];alert.accessoryView=name;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response){if(response==NSAlertFirstButtonReturn&&session==self.session)[self renameJumpID:identifier name:name.stringValue];}];
    [alert.window makeFirstResponder:name];[name selectText:nil];
}
- (void)removeJumpPoint:(NSMenuItem *)sender {
    NSIndexSet *indices=[self.jumpPoints indexesOfObjectsPassingTest:^BOOL(NSDictionary *p,NSUInteger i,BOOL *stop){return [p[@"id"] isEqual:sender.representedObject];}];
    if(indices.count){[self.jumpPoints removeObjectsAtIndexes:indices];self.status.stringValue=@"Jump point removed";[self saveJumpPoints];[self refreshJumpMenus];}
}
- (BOOL)prepareJump:(NSInteger)index navigate:(BOOL)navigate {
    self.matchingJump=nil;
    if(!self.pdf.document||index<0||index>=self.jumpPoints.count)return NO;
    self.matchingJump=self.jumpPoints[index];self.jumpShouldNavigate=navigate;self.anchors=self.matchingJump[@"anchors"];return YES;
}
- (NSArray *)matchLines {return self.matchingJump?self.lines:self.candidateLines;}
- (NSInteger)finishMatch:(NSInteger)index anchor:(NSInteger)anchor {
    if(!self.matchingJump){[self commitLine:index anchor:anchor];return 0;}
    BOOL historical=self.versionIndex<(NSInteger)self.history.count-1;
    NSMutableDictionary *point=historical?[self.matchingJump mutableCopy]:self.matchingJump;NSDictionary *before=[point copy];
    BOOL matched=index>=0&&index<self.lines.count;
    NSPoint offset=NSPointFromString(point[@"offset"]),destination=NSPointFromString(point[@"point"]);NSInteger page=[point[@"page"] integerValue];
    if(matched){
        NSDictionary *line=self.lines[index];page=[line[@"page"] integerValue];destination=NSRectFromString(line[@"rect"]).origin;
        offset=NSPointFromString(self.anchors[MAX(0,MIN(anchor,2))][@"offset"]);
        NSMutableArray *anchors=[NSMutableArray new];CGFloat scale=[point[@"scale"] doubleValue];
        for(NSInteger j=0;j<3;j++){NSInteger i=index+(j==1?-1:j==2?1:0);
            if(i<0||i>=self.lines.count||[self.lines[i][@"page"] integerValue]!=page){[anchors addObject:@{@"text":@"",@"page":@(page),@"offset":NSStringFromPoint(offset)}];continue;}
            NSMutableDictionary *a=[self.lines[i] mutableCopy];NSPoint pos=NSRectFromString(a[@"rect"]).origin;
            a[@"offset"]=NSStringFromPoint(NSMakePoint(offset.x+(pos.x-destination.x)*scale,offset.y+(pos.y-destination.y)*scale));[anchors addObject:a];
        }
        point[@"anchors"]=anchors;point[@"page"]=@(page);point[@"point"]=NSStringFromPoint(destination);point[@"offset"]=NSStringFromPoint(offset);
    }
    if(self.jumpShouldNavigate){
        offset.x*=self.pdf.bounds.size.width/[point[@"width"] doubleValue];offset.y*=self.pdf.bounds.size.height/[point[@"height"] doubleValue];
        [self positionPage:page point:destination offset:offset];[self pageChanged:nil];
        self.status.stringValue=[NSString stringWithFormat:@"Jumped to %@%@",point[@"name"],matched?@"":@" · approximate location"];
    }
    self.matchingJump=nil;
    if(!historical&&![before isEqual:point]){[self saveJumpPoints];[self refreshJumpMenus];}return 0;
}
- (void)navigationRequest:(NSNotification *)note {
    NSDictionary *r=note.userInfo;if(![r[@"pdf"] isEqual:self.path])return;
    self.navigationSource=r[@"source"];self.navigationLine=[r[@"line"] integerValue];self.navigationSerial++;[self reload:nil];
}
- (void)navigate {
    if(!self.navigationSource.length||!self.pdf.document)return;
    if(self.versionIndex<(NSInteger)self.history.count-1){[self latestVersion:nil];return;}
    NSString *source=self.navigationSource,*path=self.path,*hash=self.digest;NSInteger line=self.navigationLine;NSUInteger serial=self.navigationSerial;
    self.navigationSource=nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool {
        NSString *exe=nil;for(NSString *p in @[@"/opt/homebrew/bin/synctex",@"/Library/TeX/texbin/synctex",@"/usr/local/bin/synctex"]){if([NSFileManager.defaultManager isExecutableFileAtPath:p]){exe=p;break;}}
        NSString *output=@"";
        if(exe){NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:exe];task.arguments=@[@"view",@"-i",[NSString stringWithFormat:@"%ld:1:%@",(long)line,source],@"-o",path];NSPipe *pipe=[NSPipe pipe];task.standardOutput=pipe;task.standardError=pipe;
            if([task launchAndReturnError:nil]){output=[[NSString alloc]initWithData:[pipe.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding]?:@"";[task waitUntilExit];}}
        NSMutableDictionary *fields=[NSMutableDictionary new];for(NSString *s in [output componentsSeparatedByString:@"\n"]){NSRange colon=[s rangeOfString:@":"];if(colon.location!=NSNotFound){NSString *k=[s substringToIndex:colon.location];if(!fields[k])fields[k]=[s substringFromIndex:colon.location+1];}}
        dispatch_async(dispatch_get_main_queue(),^{if(serial!=self.navigationSerial||![path isEqual:self.path]||![hash isEqual:self.digest])return;
            NSInteger p=[fields[@"Page"] integerValue]-1;if(p>=0&&p<self.pdf.document.pageCount){PDFPage *page=[self.pdf.document pageAtIndex:p];NSRect box=[page boundsForBox:kPDFDisplayBoxMediaBox];[self positionPage:p point:NSMakePoint([fields[@"x"] doubleValue],NSMaxY(box)-[fields[@"y"] doubleValue]) offset:NSMakePoint(100,self.pdf.bounds.size.height*.65)];self.status.stringValue=[NSString stringWithFormat:@"SyncTeX · %@:%ld",source.lastPathComponent,(long)line];}
            else self.status.stringValue=@"SyncTeX location unavailable; PDF remains usable";
        });
    }});
}
- (id)invoke:(NSString *)op args:(NSArray *)a {
    if([op isEqual:@"notify"]){[[NSDistributedNotificationCenter defaultCenter]postNotificationName:@"org.yuyan.reader.navigate" object:nil userInfo:@{@"pdf":a[0],@"source":a[1],@"line":a[2]} deliverImmediately:YES];return @0;}
    if([op isEqual:@"poll"]){@autoreleasepool {
        if(Quitting)return @9;
        NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
        if(self.path&&now-self.healthTime>1){self.healthTime=now;[self armDirectoryWatch];[self armFileWatch];struct stat st;NSString *signature=stat(self.path.fileSystemRepresentation,&st)==0?[NSString stringWithFormat:@"%llu:%lld:%ld:%ld",(unsigned long long)st.st_ino,st.st_size,st.st_mtimespec.tv_sec,st.st_mtimespec.tv_nsec]:@"missing";
            if(self.fileSignature&&![self.fileSignature isEqual:signature])[self enqueue:2 generation:0];self.fileSignature=signature;
        }
        if(!self.events.count)return @0;self.event=self.events[0];[self.events removeObjectAtIndex:0];
        if([self.event[@"kind"] isEqual:@3]){self.candidate=self.event[@"doc"];self.candidateLines=self.event[@"lines"];self.candidateWords=self.event[@"words"];self.candidateDigest=self.event[@"digest"];self.candidateData=self.event[@"data"];self.candidateTime=nil;self.candidateVersionIndex=-1;self.candidateSkippedTextLines=[self.event[@"skipped"] unsignedIntegerValue];}
        return self.event[@"kind"];
    }}
    if([op isEqual:@"saveScheduler"]){self.scheduler=[a copy];return @0;}
    if([op isEqual:@"renameJump"])return @([self renameJumpID:a[0] name:a[1]]);
    if([op isEqual:@"closeWindow"]){[self closeWindow:nil];return @0;}
    if([op isEqual:@"number"]){NSString *k=a[0];if([k hasPrefix:@"scheduler"])return self.scheduler[[[k substringFromIndex:9] integerValue]];if([k isEqual:@"clock"])return @((NSInteger)(NSProcessInfo.processInfo.systemUptime*1000));if([k isEqual:@"generation"])return self.event[@"generation"]?:@0;if([k isEqual:@"count"])return @([self matchLines].count);if([k isEqual:@"jumps"])return @(self.jumpPoints.count);if([k isEqual:@"versions"])return @(self.history.count);
        // 文言：未有所览，则视同随新，且不以同文为未变。汉语：还没有显示任何版本时（版本库里的最新一版读不出来），读到的文件必须显示出来：
        // 报告为“正在跟随最新”，并且不因内容与最新一版相同而跳过。
        if([k isEqual:@"versionIndex"])return @(self.versionIndex<0?(NSInteger)self.history.count-1:self.versionIndex);if([k isEqual:@"same"])return @(self.versionIndex>=0&&[self.history.lastObject[@"digest"] isEqual:self.candidateDigest]);if([k isEqual:@"follow"])return @(self.follow);if([k isEqual:@"opened"])return @(self.path!=nil);return @0;}
    if([op isEqual:@"text"]){NSInteger i=[a[0] integerValue];NSArray *lines=[self matchLines];return i>=0&&i<lines.count?lines[i][@"text"]:@"";}
    if([op isEqual:@"oldtext"]){NSInteger i=[a[0] integerValue];return i>=0&&i<self.lines.count?self.lines[i][@"text"]:@"";}
    if([op isEqual:@"anchor"]){NSInteger i=[a[0] integerValue];return i>=0&&i<self.anchors.count?self.anchors[i][@"text"]:@"";}
    if([op isEqual:@"pageof"]){NSInteger i=[a[0] integerValue];NSArray *lines=[self matchLines];return i>=0&&i<lines.count?lines[i][@"page"]:@0;}
    if([op isEqual:@"anchorpage"]){NSInteger i=[a[0] integerValue];return i>=0&&i<self.anchors.count?self.anchors[i][@"page"]:@0;}
    if([op isEqual:@"begin"]){[self begin:[a[0] integerValue]];return @0;}
    if([op isEqual:@"prepare"]){[self capture];return @0;}
    if([op isEqual:@"unchanged"]){self.status.stringValue=[self updatedStatus];[self clearCandidate];[self navigate];return @0;}
    if([op isEqual:@"recordVersion"]){[self recordVersion];return @0;}
    if([op isEqual:@"retainHistoricalView"]){[self retainHistoricalView];return @0;}
    if([op isEqual:@"prepareHistory"]){NSInteger index=self.event[@"historyIndex"]?[self.event[@"historyIndex"] integerValue]:[self.event[@"historyStep"] integerValue]==0?(NSInteger)self.history.count-1:self.versionIndex+[self.event[@"historyStep"] integerValue];return @([self prepareVersion:index]);}
    if([op isEqual:@"history"]){[self.events addObject:@{@"kind":@7,@"historyIndex":a[0]}];return @0;}
    if([op isEqual:@"historyStep"]){[self.events addObject:@{@"kind":@7,@"historyStep":a[0]}];return @0;}
    if([op isEqual:@"inspectVersions"]){NSMutableArray *list=[NSMutableArray new];for(NSDictionary *s in self.history)[list addObject:@{@"digest":s[@"digest"],@"time":@([s[@"time"] timeIntervalSince1970]*1000),@"bytes":s[@"bytes"],@"pages":@([s[@"doc"] pageCount]),@"stored":@(s[@"stem"]!=nil),@"disk":s[@"disk"]?:@0,@"document":@(s[@"doc"]!=nil),@"words":@(s[@"words"]!=nil),@"lines":@(s[@"lines"]!=nil)}];return list;}
    if([op isEqual:@"inspectStore"]){NSString *folder=[self storeFolder];NSArray *files=folder?[[NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil] sortedArrayUsingSelector:@selector(compare:)]:nil;
        return @{@"enabled":@(StoreBase()!=nil),@"folder":folder?:@"",@"files":files?:@[]};}
    if([op isEqual:@"removeVersion"]){[self removeVersions:[NSIndexSet indexSetWithIndex:[a[0] unsignedIntegerValue]]];return @0;}
    // 文言：验其问答。汉语：后台模式下待答的确认框：inspectAlert 读其文字，testAlert 作答（第一个参数 0 为 Remove、1 为 Cancel，第二个为是否勾选“不再询问”）。
    if([op isEqual:@"inspectAlert"]){NSAlert *alert=self.pendingAlert;NSMutableArray *buttons=[NSMutableArray new];for(NSButton *button in alert.buttons)[buttons addObject:button.title];
        return @{@"pending":@(alert!=nil),@"asks":@(RemoveAsks),@"message":alert.messageText?:@"",@"info":alert.informativeText?:@"",@"buttons":buttons,@"suppression":@(alert.showsSuppressionButton),@"box":alert.suppressionButton.title?:@"",@"destructive":@(alert.buttons.firstObject.hasDestructiveAction)};}
    if([op isEqual:@"testAlert"]){void (^answer)(NSModalResponse)=self.pendingAnswer;if(!answer)return @0;self.pendingAlert.suppressionButton.state=[a[1] boolValue]?NSControlStateValueOn:NSControlStateValueOff;answer(NSAlertFirstButtonReturn+[a[0] integerValue]);return @1;}
    if([op isEqual:@"testAsk"]){RemoveAsks=[a[0] boolValue];return @0;}
    if([op isEqual:@"inspectVersionMenu"]){NSMutableArray *items=[NSMutableArray new];
        for(NSMenuItem *item in self.versionsMenu.itemArray){NSMutableArray *inner=[NSMutableArray new];for(NSMenuItem *sub in item.submenu.itemArray)[inner addObject:@{@"title":sub.title,@"enabled":@(sub.enabled),@"on":@(sub.state==NSControlStateValueOn)}];
            [items addObject:@{@"title":item.separatorItem?@"-":item.title,@"enabled":@(item.enabled),@"on":@(item.state==NSControlStateValueOn),@"key":item.keyEquivalent,@"items":inner}];}
        return items;}
    // 文言：验菜单之实。汉语：按标题执行“版本”菜单里的一项（第二个参数是子菜单项的标题），与用户点击走同一条路；被禁用的项不执行。
    if([op isEqual:@"testVersionMenu"]){NSMenuItem *item=[self.versionsMenu itemWithTitle:a[0]];if(a.count>1&&item.enabled)item=[item.submenu itemWithTitle:a[1]];
        if(!item||!item.enabled||!item.action)return @0;[NSApp sendAction:item.action to:item.target from:item];return @1;}
    if([op isEqual:@"navigate"]){self.navigationSource=a[0];self.navigationLine=[a[1] integerValue];self.navigationSerial++;[self reload:nil];return @0;}
    if([op isEqual:@"commit"]){[self commitLine:[a[0] integerValue] anchor:[a[1] integerValue]];return @0;}
    if([op isEqual:@"finishMatch"])return @([self finishMatch:[a[0] integerValue] anchor:[a[1] integerValue]]);
    if([op isEqual:@"jumpName"])return self.event[@"name"]?:@"";
    if([op isEqual:@"jumpNameExists"]){for(NSDictionary *p in self.jumpPoints)if([p[@"name"] isEqual:a[0]])return @1;return @0;}
    if([op isEqual:@"saveJump"]){[self addJumpPointNamed:a[0]];return @0;}
    if([op isEqual:@"prepareJump"])return @([self prepareJump:[a[0] integerValue] navigate:NO]);
    if([op isEqual:@"prepareSelectedJump"]){NSUInteger i=[self.jumpPoints indexOfObjectPassingTest:^BOOL(NSDictionary *p,NSUInteger i,BOOL *stop){return [p[@"id"] isEqual:self.event[@"jumpID"]];}];return @([self prepareJump:i==NSNotFound?-1:(NSInteger)i navigate:YES]);}
    if([op isEqual:@"addJump"]){if(self.pdf.document)[self queueJumpName:a[0] snapshot:[self jumpSnapshot]];return @0;}
    if([op isEqual:@"jump"]||[op isEqual:@"removeJump"]){NSMenuItem *item=[NSMenuItem new];item.representedObject=a[0];if([op isEqual:@"jump"])[self jumpToPoint:item];else [self removeJumpPoint:item];return @0;}
    if([op isEqual:@"testPointScroll"]){CGEventRef event=CGEventCreateScrollWheelEvent(NULL,kCGScrollEventUnitPixel,2,0,-300);[self.jumpBar scrollWheel:[NSEvent eventWithCGEvent:event]];CFRelease(event);return @0;}
    if([op isEqual:@"testSize"]){[self.window setContentSize:NSMakeSize([a[0] doubleValue],[a[1] doubleValue])];[self layoutJumpControls];return @0;}
    if([op isEqual:@"inspectToolbar"]){NSMutableArray *frames=[NSMutableArray new];NSMutableArray *controls=[self.baseButtons mutableCopy];[controls addObjectsFromArray:@[self.pageField,self.setJumpButton,self.search,self.previousSearchButton,self.nextSearchButton]];if(self.history.count>1)[controls addObjectsFromArray:@[self.previousVersionButton,self.latestVersionButton,self.nextVersionButton]];if(!self.previousChangeButton.hidden)[controls addObjectsFromArray:@[self.previousChangeButton,self.nextChangeButton]];for(NSView *view in controls)[frames addObject:NSStringFromRect(view.frame)];return @{@"overflow":@(self.toolbarOverflow),@"frames":frames,@"bounds":NSStringFromRect(self.window.contentView.bounds),@"pdf":NSStringFromRect(self.pdf.frame),@"scrollHeight":@(self.jumpBar.contentSize.height),@"scrollX":@(self.jumpBar.contentView.bounds.origin.x),@"pointHeight":@(self.jumpBar.documentView.subviews.firstObject.frame.size.height),@"searchWidth":@(self.search.frame.size.width)};}
    if([op isEqual:@"testSearch"]){self.search.stringValue=a[0];[self controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:self.search]];return @0;}
    if([op isEqual:@"testSearchStep"]){if([a[0] integerValue]<0)[self.previousSearchButton performClick:nil];else [self.nextSearchButton performClick:nil];return @0;}
    if([op isEqual:@"testChangeStep"]){[[a[0] integerValue]<0?self.previousChangeButton:self.nextChangeButton performClick:nil];return @0;}
    if([op isEqual:@"testChangeMenu"]){NSMenuItem *item=[a[0] integerValue]<0?self.previousChangeItem:self.nextChangeItem;if([self validateMenuItem:item])[NSApp sendAction:item.action to:item.target from:item];return @0;}
    if([op isEqual:@"testChangeShortcut"]){BOOL down=[a[0] integerValue]>0;NSString *key=[NSString stringWithFormat:@"%C",(unichar)(down?NSDownArrowFunctionKey:NSUpArrowFunctionKey)];
        NSEvent *event=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand|NSEventModifierFlagOption|NSEventModifierFlagFunction|NSEventModifierFlagNumericPad timestamp:0 windowNumber:self.window.windowNumber context:nil characters:key charactersIgnoringModifiers:key isARepeat:NO keyCode:down?125:126];
        return @([self.menuBar performKeyEquivalent:event]);}
    if([op isEqual:@"testStripClick"]){[self stripClicked:[a[0] doubleValue]];return @0;}
    if([op isEqual:@"inspectChanges"]){NSMutableArray *sets=[NSMutableArray new];double line=-1;
        for(NSInteger i=0;i<(NSInteger)self.changeSets.count;i++){NSMutableDictionary *set=[self.changeSets[i] mutableCopy];set[@"fraction"]=@([self fractionOfSet:i edge:@"top"]);[sets addObject:set];}
        if(self.changeIndex>=0&&self.changeIndex<(NSInteger)self.changeSets.count&&self.pdf.bounds.size.height>0){NSDictionary *set=self.changeSets[self.changeIndex];PDFPage *page=[self.pdf.document pageAtIndex:[set[@"page"] unsignedIntegerValue]];
            line=(NSMaxY(self.pdf.bounds)-[self.pdf convertPoint:NSMakePoint(NSMinX([page boundsForBox:self.pdf.displayBox]),[set[@"top"] doubleValue]) fromPage:page].y)/self.pdf.bounds.size.height;}
        return @{@"sets":sets,@"index":@(self.changeIndex),@"line":@(line),@"marks":self.changeStrip.marks?:@[],@"visible":@[@(self.changeStrip.visibleStart),@(self.changeStrip.visibleEnd)],@"current":@[@(self.changeStrip.currentStart),@(self.changeStrip.currentEnd)],
            @"stripHidden":@(self.changeStrip.hidden),@"strip":NSStringFromRect(self.changeStrip.frame),@"pdf":NSStringFromRect(self.pdf.frame),@"buttonsHidden":@(self.previousChangeButton.hidden&&self.nextChangeButton.hidden),
            @"enabled":@(self.previousChangeButton.enabled&&self.nextChangeButton.enabled),@"menuEnabled":@([self validateMenuItem:self.nextChangeItem]),@"scrollX":@([self clipView].bounds.origin.x)};}
    if([op isEqual:@"testDiff"]){if(DiffHints!=[a[0] boolValue])[self toggleDiff:nil];return @0;}
    // 文言：验纲目之栏。汉语：目录栏的测试钩子。rows 是当前可见的各行；top 是视口上缘所在的页与页坐标。
    if([op isEqual:@"inspectOutline"]){NSMutableArray *rows=[NSMutableArray new];
        for(NSInteger row=0;row<self.outlineView.numberOfRows;row++){OutlineNode *node=[self.outlineView itemAtRow:row];[rows addObject:@{@"title":node.title,@"page":node.label,@"index":@(node.page),@"y":@(node.y),@"level":@(node.level),@"expandable":@(node.children.count>0),@"expanded":@([self.outlineView isItemExpanded:node])}];}
        NSPoint top=NSMakePoint(NSMidX(self.pdf.bounds),NSMaxY(self.pdf.bounds));PDFPage *page=self.pdf.document.pageCount?[self.pdf pageForPoint:top nearest:YES]:nil;
        return @{@"shown":@(OutlineShown),@"visible":@(!self.outlineScroll.hidden),@"width":@(OutlineWidth),@"frame":NSStringFromRect(self.outlineScroll.frame),@"edge":NSStringFromRect(self.outlineEdge.frame),@"edgeHidden":@(self.outlineEdge.hidden),@"strip":NSStringFromRect(self.changeStrip.frame),@"pdf":NSStringFromRect(self.pdf.frame),@"bounds":NSStringFromRect(self.window.contentView.bounds),
            @"rows":rows,@"selected":@(self.outlineView.selectedRow),@"entries":@(self.outlineOrder.count),@"states":(self.path?OutlineStates[self.path]:nil)?:@{},@"menuEnabled":@([self validateMenuItem:self.outlineItem]),@"menuOn":@(self.outlineItem.state==NSControlStateValueOn),@"key":self.outlineItem.keyEquivalent,
            @"scrollY":@(self.outlineScroll.contentView.bounds.origin.y),@"topPage":@(page?(NSInteger)[self.pdf.document indexForPage:page]:-1),@"topY":@(page?[self.pdf convertPoint:top toPage:page].y:0),@"focused":@(self.window.firstResponder==self.outlineView)};}
    if([op isEqual:@"testFit"]){[self fitWidth:nil];return @0;}
    if([op isEqual:@"testOutline"]){if(OutlineShown!=[a[0] boolValue])[self toggleOutline:nil];return @0;}
    if([op isEqual:@"testOutlineMenu"]){if(![self validateMenuItem:self.outlineItem])return @0;[NSApp sendAction:self.outlineItem.action to:self.outlineItem.target from:self.outlineItem];return @1;}
    if([op isEqual:@"testOutlineShortcut"]){NSEvent *event=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand|NSEventModifierFlagControl timestamp:0 windowNumber:self.window.windowNumber context:nil characters:@"s" charactersIgnoringModifiers:@"s" isARepeat:NO keyCode:1];return @([self.menuBar performKeyEquivalent:event]);}
    if([op isEqual:@"testOutlineClick"]){[self showOutlineRow:[a[0] integerValue]];return @0;}
    // 文言：以鼠击之，如用户然。汉语：向该行发送真正的鼠标按下与抬起事件（抬起事件先入队，供表格的跟踪循环取用），走用户点击的那条路。
    if([op isEqual:@"testOutlineMouse"]){NSInteger row=[a[0] integerValue];if(row<0||row>=self.outlineView.numberOfRows)return @0;
        NSRect cell=[self.outlineView frameOfCellAtColumn:0 row:row];NSPoint at=[self.outlineView convertPoint:NSMakePoint(NSMidX(cell),NSMidY(cell)) toView:nil];NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
        NSEvent *down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:at modifierFlags:0 timestamp:now windowNumber:self.window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
        NSEvent *up=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:at modifierFlags:0 timestamp:now windowNumber:self.window.windowNumber context:nil eventNumber:2 clickCount:1 pressure:0];
        [NSApp postEvent:up atStart:NO];[self.outlineView mouseDown:down];return @1;}
    if([op isEqual:@"testOutlineExpand"]){id node=[self.outlineView itemAtRow:[a[0] integerValue]];if(!node)return @0;BOOL deep=a.count>2&&[a[2] boolValue];if([a[1] boolValue])[self.outlineView expandItem:node expandChildren:deep];else [self.outlineView collapseItem:node collapseChildren:deep];return @1;}
    // 文言：击其开阖之钮，如用户然。汉语：找到该行真正的展开三角按钮并点击，与用户操作走同一条路。
    if([op isEqual:@"testOutlineDisclosure"]){NSView *view=[self.outlineView rowViewAtRow:[a[0] integerValue] makeIfNecessary:YES];NSMutableArray<NSView *> *queue=[NSMutableArray new];if(view)[queue addObject:view];
        while(queue.count){NSView *next=queue[0];[queue removeObjectAtIndex:0];if([next isKindOfClass:NSButton.class]&&[next.identifier isEqual:NSOutlineViewDisclosureButtonKey]){[(NSButton *)next performClick:nil];return @1;}[queue addObjectsFromArray:next.subviews];}
        return @0;}
    if([op isEqual:@"testOutlineWidth"]){[self outlineDragged:[a[0] doubleValue]-OutlineEdgeWidth/2 finished:[a[1] boolValue]];return @0;}
    if([op isEqual:@"testOutlineScroll"]){NSClipView *clip=self.outlineScroll.contentView;[clip scrollToPoint:[clip constrainBoundsRect:(NSRect){NSMakePoint(0,[a[0] doubleValue]),clip.bounds.size}].origin];[self.outlineScroll reflectScrolledClipView:clip];return @0;}
    if([op isEqual:@"testDiffMenu"]){[NSApp sendAction:self.diffItem.action to:self.diffItem.target from:self.diffItem];return @0;}
    if([op isEqual:@"inspectDiff"]){NSMutableArray *texts=[NSMutableArray new];NSUInteger shown=0;
        for(NSArray *group in @[self.addedSelections?:@[],self.deletedSelections?:@[]]){NSMutableArray *list=[NSMutableArray new];[texts addObject:list];
            for(PDFSelection *selection in group){if([self.pdf.highlightedSelections indexOfObjectIdenticalTo:selection]!=NSNotFound)shown++;[list addObject:@{@"text":selection.string?:@"",@"page":@([self.pdf.document indexForPage:selection.pages.firstObject])}];}}
        return @{@"enabled":@(DiffHints),@"menu":@(self.diffItem.state==NSControlStateValueOn),@"added":texts[0],@"deleted":texts[1],@"addedWords":@(self.addedWords),@"deletedWords":@(self.deletedWords),@"shown":@(shown)};}
    if([op isEqual:@"inspectSearch"]){NSMutableArray *pages=[NSMutableArray new];for(PDFSelection *match in self.pdf.highlightedSelections)if([self.searchMatches indexOfObjectIdenticalTo:match]!=NSNotFound)[pages addObject:@([self.pdf.document indexForPage:match.pages.firstObject])];return @{@"query":self.searchQuery?:@"",@"count":@(self.searchMatches.count),@"highlighted":@(pages.count),@"index":@(self.searchIndex),@"pages":pages,@"selection":self.pdf.currentSelection.string?:@"",@"previousEnabled":@(self.previousSearchButton.enabled),@"nextEnabled":@(self.nextSearchButton.enabled),@"previousY":@(self.previousSearchButton.frame.origin.y),@"nextY":@(self.nextSearchButton.frame.origin.y),@"searchY":@(self.search.frame.origin.y),@"tooltip":self.search.toolTip?:@""};}
    if([op isEqual:@"testWindowShortcut"]){self.cycleDestination=nil;NSEventModifierFlags flags=NSEventModifierFlagCommand|([a[0] boolValue]?NSEventModifierFlagShift:0);NSEvent *event=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:self.window.windowNumber context:nil characters:[a[0] boolValue]?@"~":@"`" charactersIgnoringModifiers:[a[0] boolValue]?@"~":@"`" isARepeat:NO keyCode:50];BOOL handled=[self.menuBar performKeyEquivalent:event];return @{@"handled":@(handled),@"target":self.cycleDestination?:@0};}
    if([op isEqual:@"inspectUI"]){NSMutableArray *buttons=[NSMutableArray new];for(NSButton *button in self.jumpBar.documentView.subviews){NSMutableArray *actions=[NSMutableArray new];for(NSMenuItem *item in button.menu.itemArray)[actions addObject:item.title];[buttons addObject:@{@"title":button.title,@"actions":actions}];}return @{@"buttons":buttons,@"active":@(NSApp.active),@"visible":@(self.window.visible),@"canBecomeKey":@(self.window.canBecomeKeyWindow),@"canBecomeMain":@(self.window.canBecomeMainWindow),@"pointY":@(self.jumpBar.frame.origin.y),@"setY":@(self.setJumpButton.frame.origin.y),@"historyY":@(self.previousVersionButton.frame.origin.y),@"searchY":@(self.search.frame.origin.y)};}
    if([op isEqual:@"inspectJumps"])return self.jumpPoints?:@[];
    if([op isEqual:@"status"]){self.status.stringValue=[NSString stringWithFormat:@"%@ · %@",a[0],self.path?:@""];return @0;}
    if([op isEqual:@"open"]){[self openPath:a[0]];return @0;}
    if([op isEqual:@"close"]){[self closeDocument:nil];return @0;}
    if([op isEqual:@"quit"]){Quitting=YES;for(Viewer *viewer in Windows)[viewer stopWatch];return @0;}
    if([op isEqual:@"testPosition"]){self.fit=NO;self.pdf.scaleFactor=[a[1] doubleValue];[self positionPage:[a[0] integerValue] point:NSMakePoint(72,[a[2] doubleValue]) offset:NSMakePoint(100,450)];return @0;}
    if([op isEqual:@"testDelay"]){self.testDelay=[a[0] doubleValue];return @0;}
    if([op isEqual:@"testFollow"]){self.follow=[a[0] boolValue];return @0;}
    if([op isEqual:@"testMode"]){[self setModePreservingPosition:[a[0] integerValue]];return @0;}
    if([op isEqual:@"inspect"]){[self capture];return @{@"path":self.path?:@"",@"commits":@(self.commits),@"loads":@(self.loads),@"watchers":@(self.watchCount),@"pages":@(self.pdf.document.pageCount),@"page":@(self.fallbackPage),@"mode":@(self.pdf.displayMode),@"zoom":@(self.pdf.scaleFactor),@"anchor":self.anchors.count?self.anchors[0]:@{},@"digest":self.digest?:@"",@"lastUpdatedMs":@(self.lastUpdated.timeIntervalSince1970*1000),@"versionIndex":@(self.versionIndex),@"versionCount":@(self.history.count),@"status":self.status.stringValue?:@"",@"skippedTextLines":@(self.skippedTextLines),@"textLines":@(self.lines.count)};}
    return @0;
}
@end
// Window selection is separate from keyboard focus: each guest scheduler owns its state.
static Viewer *OpenWindow(NSString *path) {
    NSString *normalized=path.stringByStandardizingPath;
    if(normalized.length)for(Viewer *viewer in Windows)if([viewer.path isEqual:normalized]){if(!Background()){if(viewer.window.miniaturized)[viewer.window deminiaturize:nil];[viewer.window makeKeyAndOrderFront:nil];}return viewer;}
    Viewer *viewer=nil;if(normalized.length)for(Viewer *item in Windows)if(!item.path){viewer=item;break;}
    if(!viewer){viewer=[Viewer new];[viewer setup];}
    if(normalized.length)[viewer openPath:normalized];if(!Background()){if(viewer.window.miniaturized)[viewer.window deminiaturize:nil];[viewer.window makeKeyAndOrderFront:nil];}return viewer;
}
static id Dispatch(NSString *op,NSArray *args) {
    if(!Windows){Windows=[NSMutableArray new];Histories=[NSMutableDictionary new];DiffCache=[NSMutableDictionary new];
        // 文言：验时恒启，不读不写其好。汉语：后台测试模式固定开启且不读写用户偏好；正常运行时默认开启并记住选择。
        DiffHints=Background()||![NSUserDefaults.standardUserDefaults objectForKey:@"HighlightChanges"]||[NSUserDefaults.standardUserDefaults boolForKey:@"HighlightChanges"];
        RemoveAsks=Background()||![NSUserDefaults.standardUserDefaults boolForKey:@"RemoveVersionsWithoutAsking"];
        // 目录栏默认显示；宽度与显隐在正常运行时记住，后台测试用默认值。
        OutlineStates=[NSMutableDictionary new];OutlineShown=Background()||![NSUserDefaults.standardUserDefaults objectForKey:@"ShowOutline"]||[NSUserDefaults.standardUserDefaults boolForKey:@"ShowOutline"];
        CGFloat width=Background()?0:[NSUserDefaults.standardUserDefaults doubleForKey:@"OutlineWidth"];if(width>=OutlineLeast&&width<=OutlineMost)OutlineWidth=width;}
    if([op isEqual:@"init"]){V=OpenWindow(args.count?args[0]:nil);return @0;}
    if([op isEqual:@"openNew"])return OpenWindow(args.count?args[0]:nil).windowID;
    if([op isEqual:@"inspectWindows"]){NSMutableArray *out=[NSMutableArray new];for(Viewer *viewer in Windows)[out addObject:@{@"id":viewer.windowID,@"path":viewer.path?:@""}];return out;}
    if([op isEqual:@"window"]){for(Viewer *viewer in Windows)if([viewer.windowID isEqual:args[0]])return [viewer invoke:args[1] args:args[2]];return [NSNull null];}
    if([op isEqual:@"poll"]){
        NSEvent *event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:.01] inMode:NSDefaultRunLoopMode dequeue:YES];if(event)[NSApp sendEvent:event];[NSApp updateWindows];
        if(Quitting)return @9;if(Windows.count)V=Windows[(PollIndex++)%Windows.count];
    }
    if(!V)V=[Viewer new];return [V invoke:op args:args];
}
static NSString *JSString(napi_env env,napi_value value){size_t size=0;napi_get_value_string_utf8(env,value,NULL,0,&size);char *s=calloc(size+1,1);napi_get_value_string_utf8(env,value,s,size+1,&size);NSString *r=[[NSString alloc]initWithBytes:s length:size encoding:NSUTF8StringEncoding];free(s);return r;}
static napi_value Call(napi_env env,napi_callback_info info){@autoreleasepool {size_t count=2;napi_value argv[2];napi_get_cb_info(env,info,&count,argv,NULL,NULL);if(count!=2){napi_throw_error(env,NULL,"invoke requires operation and JSON args");return NULL;}
    @try {NSString *op=JSString(env,argv[0]);NSArray *args=[NSJSONSerialization JSONObjectWithData:[JSString(env,argv[1]) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];id value=Dispatch(op,args);NSData *data=[NSJSONSerialization dataWithJSONObject:value?:@0 options:NSJSONWritingFragmentsAllowed error:nil];napi_value result;napi_create_string_utf8(env,data.bytes,data.length,&result);return result;}
    @catch(NSException *exception){napi_throw_error(env,NULL,exception.reason.UTF8String);return NULL;}
}}
static napi_value Init(napi_env env,napi_value exports){napi_value f;napi_create_function(env,"invoke",NAPI_AUTO_LENGTH,Call,NULL,&f);napi_set_named_property(env,exports,"invoke",f);return exports;}
NAPI_MODULE(阅卷,Init)
