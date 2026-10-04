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
static NSArray *Lines(PDFDocument *doc) {
    NSMutableArray *out=[NSMutableArray new];
    for(NSUInteger p=0;p<doc.pageCount;p++) {
        PDFPage *page=[doc pageAtIndex:p];
        PDFSelection *all=[page selectionForRange:NSMakeRange(0,page.numberOfCharacters)];
        for(PDFSelection *line in all.selectionsByLine) {
            NSString *text=Normalize(line.string); if(!text.length) continue;
            [out addObject:@{@"text":text,@"page":@(p),@"rect":NSStringFromRect([line boundsForPage:page]),@"label":page.label?:@""}];
        }
    }
    return out;
}
@class Viewer;
static Viewer *V, *AppDelegate;
static NSMutableArray<Viewer *> *Windows;
static BOOL Quitting;
static NSMutableDictionary *Histories;
static NSUInteger WindowSerial, PollIndex;
static Viewer *OpenWindow(NSString *path);
static BOOL Background(void) {return [NSProcessInfo.processInfo.environment[@"YY_VIEWER_BACKGROUND"] isEqual:@"1"]; }
@interface ViewerWindow : NSWindow @end
@implementation ViewerWindow
- (BOOL)canBecomeKeyWindow {return !Background()&&[super canBecomeKeyWindow];}
- (BOOL)canBecomeMainWindow {return !Background()&&[super canBecomeMainWindow];}
@end
@interface DropPDF : PDFView <NSDraggingDestination> @end
@interface Viewer : NSObject <NSApplicationDelegate,NSWindowDelegate,NSSearchFieldDelegate>
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
@property NSDate *lastUpdated;
@property NSMutableDictionary<NSString *,NSMutableArray *> *histories;
@property NSMutableArray *history;
@property NSInteger versionIndex,candidateVersionIndex;
@property NSData *candidateData;
@property NSDate *candidateTime;
@property NSMenu *versionsMenu;
@property NSButton *previousVersionButton,*nextVersionButton,*latestVersionButton;
@property NSArray *lines,*candidateLines,*anchors;
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
    CGFloat x=12;
    NSArray *titles=@[@"Open…",@"‹",@"›",@"−",@"+",@"Fit Width"];
    SEL actions[]={@selector(open:),@selector(previous:),@selector(next:),@selector(zoomOut:),@selector(zoomIn:),@selector(fitWidth:)};
    for(int i=0;i<titles.count;i++){NSButton *b=[NSButton buttonWithTitle:titles[i] target:self action:actions[i]];b.frame=NSMakeRect(x,782,i==0?64:i==5?68:30,28);b.autoresizingMask=NSViewMinYMargin;[root addSubview:b];x+=b.frame.size.width+4;}
    self.pageField=[[NSTextField alloc]initWithFrame:NSMakeRect(x+5,784,48,24)];self.pageField.placeholderString=@"Page";self.pageField.target=self;self.pageField.action=@selector(page:);self.pageField.autoresizingMask=NSViewMinYMargin;[root addSubview:self.pageField];
    self.setJumpButton=[NSButton buttonWithTitle:@"Set Point" target:self action:@selector(quickSetJumpPoint:)];self.setJumpButton.frame=NSMakeRect(350,782,82,28);self.setJumpButton.autoresizingMask=NSViewMinYMargin;self.setJumpButton.toolTip=@"Set jump point (⌘D). Set a named point with ⇧⌘D or right-click.";[root addSubview:self.setJumpButton];
    self.setJumpButton.menu=[NSMenu new];[self item:@"Set Named Jump Point…" action:@selector(setJumpPoint:) key:@"" menu:self.setJumpButton.menu];
    self.previousVersionButton=[NSButton buttonWithTitle:@"‹" target:self action:@selector(previousVersion:)];self.previousVersionButton.toolTip=@"Previous PDF version (⌥⌘[)";[self.previousVersionButton setAccessibilityLabel:@"Previous PDF version"];
    self.latestVersionButton=[NSButton buttonWithTitle:@"v1/1" target:self action:@selector(latestVersion:)];self.latestVersionButton.toolTip=@"Return to latest PDF version (⌥⌘0)";
    self.nextVersionButton=[NSButton buttonWithTitle:@"›" target:self action:@selector(nextVersion:)];self.nextVersionButton.toolTip=@"Next PDF version (⌥⌘])";[self.nextVersionButton setAccessibilityLabel:@"Next PDF version"];
    for(NSButton *button in @[self.previousVersionButton,self.latestVersionButton,self.nextVersionButton]){button.font=[NSFont systemFontOfSize:11];[root addSubview:button];}
    self.jumpBar=[[NSScrollView alloc]initWithFrame:NSMakeRect(440,782,0,28)];self.jumpBar.autoresizingMask=NSViewMinYMargin;self.jumpBar.hasHorizontalScroller=YES;self.jumpBar.scrollerStyle=NSScrollerStyleOverlay;self.jumpBar.autohidesScrollers=YES;self.jumpBar.drawsBackground=NO;[root addSubview:self.jumpBar];[self refreshJumpMenus];
    self.search=[[NSSearchField alloc]initWithFrame:NSMakeRect(650,784,315,24)];self.search.placeholderString=@"Find in PDF";self.search.target=self;self.search.action=@selector(search:);self.search.delegate=self;self.search.sendsWholeSearchString=YES;self.search.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;[root addSubview:self.search];
    self.previousSearchButton=[NSButton buttonWithTitle:@"‹" target:self action:@selector(previousSearch:)];self.nextSearchButton=[NSButton buttonWithTitle:@"›" target:self action:@selector(search:)];
    [self.previousSearchButton setAccessibilityLabel:@"Previous search match"];[self.nextSearchButton setAccessibilityLabel:@"Next search match"];
    for(NSButton *button in @[self.previousSearchButton,self.nextSearchButton]){button.autoresizingMask=NSViewMinYMargin;[root addSubview:button];}
    [self rebuildSearch];[self refreshVersionControls];[self layoutJumpControls];
    self.status=[NSTextField labelWithString:@"Open a PDF to begin"];self.status.frame=NSMakeRect(12,6,956,18);self.status.autoresizingMask=NSViewWidthSizable;self.status.lineBreakMode=NSLineBreakByTruncatingMiddle;[root addSubview:self.status];
    [[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(pageChanged:) name:PDFViewPageChangedNotification object:self.pdf];
    [[NSDistributedNotificationCenter defaultCenter]addObserver:self selector:@selector(navigationRequest:) name:@"org.yuyan.reader.navigate" object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    if(self==AppDelegate)[NSApp finishLaunching];if(!Background()){[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];}
}
- (void)about:(id)sender {NSAlert *a=[NSAlert new];a.messageText=@"阅卷";a.informativeText=@"Yuyan · Wasm-GC · V8\nNative PDFKit viewer for continuously rebuilt papers.";[a beginSheetModalForWindow:self.window completionHandler:nil];}
- (void)pageChanged:(id)sender {if(self.pdf.document)self.pageField.stringValue=[NSString stringWithFormat:@"%lu",[self.pdf.document indexForPage:self.pdf.currentPage]+1];}
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
- (void)closeDocument:(id)sender {[self stopWatch];self.session++;self.path=nil;self.digest=nil;self.lastUpdated=nil;self.pdf.document=nil;[self rebuildSearch];self.lines=@[];[self clearCandidate];self.history=nil;self.versionIndex=-1;self.matchingJump=nil;self.jumpPoints=[NSMutableArray new];[self refreshJumpMenus];[self refreshVersionControls];[self.events removeAllObjects];[self enqueue:1 generation:0];self.status.stringValue=@"No document";self.window.title=@"阅卷 — PDF";}
- (void)openPath:(NSString *)path {
    [self stopWatch];self.session++;self.path=path.stringByStandardizingPath;self.digest=nil;self.lastUpdated=nil;
    self.pdf.document=nil;[self rebuildSearch];self.lines=@[];[self clearCandidate];[self.events removeAllObjects];
    self.history=self.histories[self.path];if(!self.history){self.history=[NSMutableArray new];self.histories[self.path]=self.history;}self.versionIndex=-1;
    self.matchingJump=nil;[self loadJumpPoints];[self refreshJumpMenus];
    self.window.title=[@"阅卷 — " stringByAppendingString:self.path.lastPathComponent];self.window.representedURL=[NSURL fileURLWithPath:self.path];
    self.status.stringValue=[@"Opening · " stringByAppendingString:self.path];
    self.fileSignature=nil;[self armDirectoryWatch];
    [self armFileWatch];
    if(self.history.count){[self prepareVersion:(NSInteger)self.history.count-1];[self capture];[self commitLine:-1 anchor:0];}
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
- (void)setModePreservingPosition:(PDFDisplayMode)mode {[self capture];self.pdf.displayMode=mode;[self positionPage:self.fallbackPage point:self.fallbackPoint offset:self.fallbackOffset];}
- (void)mode:(id)sender {[self setModePreservingPosition:self.pdf.displayMode==kPDFDisplaySinglePageContinuous?kPDFDisplaySinglePage:kPDFDisplaySinglePageContinuous];}
- (void)follow:(NSMenuItem *)sender {self.follow=!self.follow;sender.state=self.follow?NSControlStateValueOn:NSControlStateValueOff;}
- (void)find:(id)sender {[self.window makeFirstResponder:self.search];}
- (void)rebuildSearch {
    self.searchQuery=self.search.stringValue?:@"";self.searchIndex=-1;
    self.searchMatches=self.searchQuery.length&&self.pdf.document?[self.pdf.document findString:self.searchQuery withOptions:NSCaseInsensitiveSearch]:@[];
    for(PDFSelection *match in self.searchMatches)match.color=[NSColor.systemYellowColor colorWithAlphaComponent:.45];
    self.pdf.highlightedSelections=self.searchMatches;
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
        NSString *hash=data?Digest(data):@"";PDFDocument *doc=nil;NSArray *lines=@[];
        if(stable&&data.length>10){NSData *tail=[data subdataWithRange:NSMakeRange(data.length>4096?data.length-4096:0,MIN(data.length,4096))];NSString *end=[[NSString alloc]initWithData:tail encoding:NSISOLatin1StringEncoding];
            if([[end stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] hasSuffix:@"%%EOF"]){doc=[[PDFDocument alloc]initWithData:data];if(!doc.pageCount||doc.isLocked)doc=nil;}
            if(doc){for(NSUInteger p=0;p<doc.pageCount;p++){if(![doc pageAtIndex:p].pageRef){doc=nil;break;}}}
            if(doc)lines=Lines(doc);
        }
        if(delay>0)[NSThread sleepForTimeInterval:delay];
        dispatch_async(dispatch_get_main_queue(),^{if(session!=self.session)return;
            if(doc){[self.events addObject:@{@"kind":@3,@"generation":@(generation),@"doc":doc,@"lines":lines,@"digest":hash,@"data":data}];}
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
    NSDateFormatter *format=[NSDateFormatter new];format.locale=[[NSLocale alloc]initWithLocaleIdentifier:@"en_US_POSIX"];format.calendar=[[NSCalendar alloc]initWithCalendarIdentifier:NSCalendarIdentifierGregorian];format.timeZone=NSTimeZone.localTimeZone;format.dateFormat=@"yyyy-MM-dd HH:mm:ss";
    return date?[format stringFromDate:date]:@"—";
}
- (NSString *)updatedStatus {
    NSString *prefix=self.versionIndex<(NSInteger)self.history.count-1?[NSString stringWithFormat:@"Viewing version %ld/%lu · ",(long)self.versionIndex+1,self.history.count]:@"";
    NSString *version=prefix.length?@"":[NSString stringWithFormat:@" · Version %ld/%lu",(long)self.versionIndex+1,self.history.count];
    return [NSString stringWithFormat:@"%@Updated at %@%@ · %lu pages · %@",prefix,[self dateText:self.lastUpdated],version,self.pdf.document.pageCount,self.path?:@""];
}
- (void)commitLine:(NSInteger)line anchor:(NSInteger)anchor {
    if(!self.candidate)return;
    BOOL initial=self.pdf.document==nil;self.pdf.document=self.candidate;self.lines=self.candidateLines;self.digest=self.candidateDigest;self.lastUpdated=self.candidateTime;self.versionIndex=self.candidateVersionIndex;[self clearCandidate];self.commits++;
    self.pdf.displayMode=self.savedMode; if(initial||self.fit)[self fitWidth:nil];else self.pdf.scaleFactor=self.savedScale;
    if(!initial){if(line>=0&&line<self.lines.count){NSDictionary *l=self.lines[line];NSPoint off=anchor>=0&&anchor<self.anchors.count?NSPointFromString(self.anchors[anchor][@"offset"]):self.fallbackOffset;[self positionPage:[l[@"page"] integerValue] point:NSRectFromString(l[@"rect"]).origin offset:off];}else [self positionPage:self.fallbackPage point:self.fallbackPoint offset:self.fallbackOffset];}
    self.status.stringValue=[self updatedStatus];[self pageChanged:nil];
    [self refreshJumpMenus];[self refreshVersionControls];[self rebuildSearch];
    [self navigate];
}

// 文言：诸成卷皆藏内存，换览不覆原卷。汉语：保留每次成功加载的内容变更；不淘汰旧快照，不写回 PDF。
- (void)clearCandidate {self.candidate=nil;self.candidateLines=nil;self.candidateDigest=nil;self.candidateData=nil;self.candidateTime=nil;self.candidateVersionIndex=-1;}
- (void)recordVersion {
    if(!self.candidate||!self.candidateData)return;
    self.candidateTime=[NSDate date];self.candidateVersionIndex=self.history.count;
    [self.history addObject:@{@"doc":self.candidate,@"lines":self.candidateLines,@"digest":self.candidateDigest,@"time":self.candidateTime,@"data":self.candidateData}];
}
- (void)retainHistoricalView {[self clearCandidate];self.status.stringValue=[self updatedStatus];[self refreshVersionControls];[self navigate];}
- (BOOL)prepareVersion:(NSInteger)index {
    if(index<0||index>=self.history.count||index==self.versionIndex)return NO;
    NSDictionary *snapshot=self.history[index];self.candidate=snapshot[@"doc"];self.candidateLines=snapshot[@"lines"];self.candidateDigest=snapshot[@"digest"];self.candidateData=snapshot[@"data"];self.candidateTime=snapshot[@"time"];self.candidateVersionIndex=index;return YES;
}
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
    for(NSInteger i=(NSInteger)self.history.count-1;i>=0;i--){NSString *title=[NSString stringWithFormat:@"Version %ld — %@%@",(long)i+1,[self dateText:self.history[i][@"time"]],i==(NSInteger)self.history.count-1?@" (Latest)":@""];
        NSMenuItem *item=[self item:title action:@selector(selectVersion:) key:@"" menu:self.versionsMenu];item.representedObject=@(i);item.state=i==self.versionIndex?NSControlStateValueOn:NSControlStateValueOff;}
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
    NSPoint scroll=self.jumpBar.contentView.bounds.origin;NSView *row=[[NSView alloc]initWithFrame:NSMakeRect(0,0,1,28)];CGFloat x=0;
    NSUInteger slot=0;for(NSDictionary *point in self.jumpPoints){
        NSString *key=slot<9?[NSString stringWithFormat:@"  ⌘%lu",(unsigned long)slot+1]:@"";
        NSString *title=point[@"name"];CGFloat width=MIN(116,MAX(28,[title sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13]}].width+18));
        NSButton *jump=[NSButton buttonWithTitle:title target:self action:@selector(jumpButton:)];jump.frame=NSMakeRect(x,1,width,26);jump.identifier=point[@"id"];jump.enabled=self.pdf.document!=nil;[jump.cell setLineBreakMode:NSLineBreakByTruncatingTail];jump.toolTip=[NSString stringWithFormat:@"Jump to %@ — Page %ld%@",point[@"name"],(long)[point[@"page"] integerValue]+1,key];[row addSubview:jump];
        NSMenu *context=[NSMenu new];context.autoenablesItems=NO;
        NSMenuItem *go=[self item:@"Jump to Point" action:@selector(jumpToPoint:) key:@"" menu:context];go.representedObject=point[@"id"];go.enabled=self.pdf.document!=nil;
        NSMenuItem *rename=[self item:@"Rename…" action:@selector(renameJumpPoint:) key:@"" menu:context];rename.representedObject=point[@"id"];
        NSMenuItem *remove=[self item:@"Remove Jump Point" action:@selector(removeJumpPoint:) key:@"" menu:context];remove.representedObject=point[@"id"];jump.menu=context;
        [jump setAccessibilityLabel:[NSString stringWithFormat:@"Jump to %@%@",point[@"name"],key]];x+=width+4;slot++;
    }
    self.jumpContentWidth=x;[self layoutJumpControls];row.frame=NSMakeRect(0,0,MAX(x,self.jumpBar.contentSize.width),28);self.jumpBar.documentView=row;
    [self.jumpBar.contentView scrollToPoint:[self.jumpBar.contentView constrainBoundsRect:(NSRect){scroll,self.jumpBar.contentView.bounds.size}].origin];
}
- (void)layoutJumpControls {
    if(!self.jumpBar)return;
    NSSize size=self.window.contentView.bounds.size;BOOL showHistory=self.history.count>1;
    self.previousVersionButton.hidden=!showHistory;self.latestVersionButton.hidden=!showHistory;self.nextVersionButton.hidden=!showHistory;
    self.previousVersionButton.frame=NSMakeRect(440,size.height-38,22,28);self.latestVersionButton.frame=NSMakeRect(464,size.height-38,54,28);self.nextVersionButton.frame=NSMakeRect(520,size.height-38,22,28);
    CGFloat start=showHistory?550:440;CGFloat available=MAX(0,size.width-start-12);
    CGFloat width=self.jumpPoints.count?MIN(self.jumpContentWidth,MAX(0,available-168)):0;
    self.jumpBar.hidden=self.jumpPoints.count==0;self.jumpBar.frame=NSMakeRect(start,size.height-38,width,28);
    CGFloat searchX=start+width+(self.jumpPoints.count?8:0);self.search.frame=NSMakeRect(searchX,size.height-36,MAX(0,size.width-searchX-76),24);
    self.previousSearchButton.frame=NSMakeRect(size.width-72,size.height-38,28,28);self.nextSearchButton.frame=NSMakeRect(size.width-40,size.height-38,28,28);
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
        if([self.event[@"kind"] isEqual:@3]){self.candidate=self.event[@"doc"];self.candidateLines=self.event[@"lines"];self.candidateDigest=self.event[@"digest"];self.candidateData=self.event[@"data"];self.candidateTime=nil;self.candidateVersionIndex=-1;}
        return self.event[@"kind"];
    }}
    if([op isEqual:@"saveScheduler"]){self.scheduler=[a copy];return @0;}
    if([op isEqual:@"renameJump"])return @([self renameJumpID:a[0] name:a[1]]);
    if([op isEqual:@"closeWindow"]){[self closeWindow:nil];return @0;}
    if([op isEqual:@"number"]){NSString *k=a[0];if([k hasPrefix:@"scheduler"])return self.scheduler[[[k substringFromIndex:9] integerValue]];if([k isEqual:@"clock"])return @((NSInteger)(NSProcessInfo.processInfo.systemUptime*1000));if([k isEqual:@"generation"])return self.event[@"generation"]?:@0;if([k isEqual:@"count"])return @([self matchLines].count);if([k isEqual:@"jumps"])return @(self.jumpPoints.count);if([k isEqual:@"versions"])return @(self.history.count);if([k isEqual:@"versionIndex"])return @(self.versionIndex);if([k isEqual:@"same"])return @([self.history.lastObject[@"digest"] isEqual:self.candidateDigest]);if([k isEqual:@"follow"])return @(self.follow);if([k isEqual:@"opened"])return @(self.path!=nil);return @0;}
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
    if([op isEqual:@"inspectVersions"]){NSMutableArray *list=[NSMutableArray new];for(NSDictionary *s in self.history)[list addObject:@{@"digest":s[@"digest"],@"time":@([s[@"time"] timeIntervalSince1970]*1000),@"bytes":@([s[@"data"] length]),@"pages":@([s[@"doc"] pageCount])}];return list;}
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
    if([op isEqual:@"testSearch"]){self.search.stringValue=a[0];[self controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:self.search]];return @0;}
    if([op isEqual:@"testSearchStep"]){if([a[0] integerValue]<0)[self.previousSearchButton performClick:nil];else [self.nextSearchButton performClick:nil];return @0;}
    if([op isEqual:@"inspectSearch"]){NSMutableArray *pages=[NSMutableArray new];for(PDFSelection *match in self.pdf.highlightedSelections)[pages addObject:@([self.pdf.document indexForPage:match.pages.firstObject])];return @{@"query":self.searchQuery?:@"",@"count":@(self.searchMatches.count),@"highlighted":@(self.pdf.highlightedSelections.count),@"index":@(self.searchIndex),@"pages":pages,@"selection":self.pdf.currentSelection.string?:@"",@"previousEnabled":@(self.previousSearchButton.enabled),@"nextEnabled":@(self.nextSearchButton.enabled),@"previousY":@(self.previousSearchButton.frame.origin.y),@"nextY":@(self.nextSearchButton.frame.origin.y),@"searchY":@(self.search.frame.origin.y),@"tooltip":self.search.toolTip?:@""};}
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
    if([op isEqual:@"inspect"]){[self capture];return @{@"path":self.path?:@"",@"commits":@(self.commits),@"loads":@(self.loads),@"watchers":@(self.watchCount),@"pages":@(self.pdf.document.pageCount),@"page":@(self.fallbackPage),@"mode":@(self.pdf.displayMode),@"zoom":@(self.pdf.scaleFactor),@"anchor":self.anchors.count?self.anchors[0]:@{},@"digest":self.digest?:@"",@"lastUpdatedMs":@(self.lastUpdated.timeIntervalSince1970*1000),@"versionIndex":@(self.versionIndex),@"versionCount":@(self.history.count),@"status":self.status.stringValue?:@""};}
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
    if(!Windows){Windows=[NSMutableArray new];Histories=[NSMutableDictionary new];}
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
