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
static Viewer *V;
@interface DropPDF : PDFView <NSDraggingDestination> @end
@interface Viewer : NSObject <NSApplicationDelegate,NSWindowDelegate>
@property NSWindow *window;
@property DropPDF *pdf;
@property NSTextField *status,*pageField;
@property NSSearchField *search;
@property NSString *path,*digest;
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
@property BOOL quitting,follow,fit;
@property NSInteger fallbackPage;
@property NSPoint fallbackPoint,fallbackOffset;
@property CGFloat savedScale;
@property PDFDisplayMode savedMode;
@property NSString *navigationSource;
@property NSInteger navigationLine;
@property NSUInteger navigationSerial;
@property dispatch_queue_t readQueue;
@end
@implementation DropPDF
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {return NSDragOperationCopy;}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSArray *urls=[sender.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
    if(!urls.count)return NO; [V performSelector:@selector(openPath:) withObject:[urls[0] path]]; return YES;
}
@end
@implementation Viewer
- (void)enqueue:(NSInteger)kind generation:(NSInteger)g { [self.events addObject:@{@"kind":@(kind),@"generation":@(g)}]; }
- (NSMenuItem *)item:(NSString *)title action:(SEL)action key:(NSString *)key menu:(NSMenu *)menu {NSMenuItem *i=[menu addItemWithTitle:title action:action keyEquivalent:key];i.target=self;return i;}
- (void)setup {
    self.events=[NSMutableArray new]; self.lines=@[];self.anchors=@[];self.fit=YES;
    self.readQueue=dispatch_queue_create("org.yuyan.reader.pdf",DISPATCH_QUEUE_SERIAL);
    [NSApplication sharedApplication]; NSApp.delegate=self; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSMenu *bar=[NSMenu new]; NSApp.mainMenu=bar;
    NSMenu *app=[NSMenu new]; NSMenuItem *appItem=[bar addItemWithTitle:@"阅卷" action:nil keyEquivalent:@""];appItem.submenu=app;
    [self item:@"About 阅卷" action:@selector(about:) key:@"" menu:app];[app addItem:NSMenuItem.separatorItem];
    [self item:@"Quit 阅卷" action:@selector(quit:) key:@"q" menu:app];
    NSMenu *file=[[NSMenu alloc]initWithTitle:@"File"];[bar addItemWithTitle:@"File" action:nil keyEquivalent:@""].submenu=file;
    [self item:@"Open…" action:@selector(open:) key:@"o" menu:file];
    [self item:@"Reload" action:@selector(reload:) key:@"r" menu:file];
    [self item:@"Close Document" action:@selector(closeDocument:) key:@"w" menu:file];
    [self item:@"Print…" action:@selector(print:) key:@"p" menu:file];
    NSMenu *edit=[[NSMenu alloc]initWithTitle:@"Edit"];[bar addItemWithTitle:@"Edit" action:nil keyEquivalent:@""].submenu=edit;
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [self item:@"Find…" action:@selector(find:) key:@"f" menu:edit];
    [self item:@"Find Next" action:@selector(search:) key:@"g" menu:edit];
    NSMenu *view=[[NSMenu alloc]initWithTitle:@"View"];[bar addItemWithTitle:@"View" action:nil keyEquivalent:@""].submenu=view;
    [self item:@"Zoom In" action:@selector(zoomIn:) key:@"+" menu:view];
    [self item:@"Zoom Out" action:@selector(zoomOut:) key:@"-" menu:view];
    [self item:@"Fit to Width" action:@selector(fitWidth:) key:@"0" menu:view];
    [self item:@"Previous Page" action:@selector(previous:) key:@"[" menu:view];
    [self item:@"Next Page" action:@selector(next:) key:@"]" menu:view];
    [self item:@"Single Page / Continuous" action:@selector(mode:) key:@"" menu:view];
    [self item:@"Follow Edits" action:@selector(follow:) key:@"" menu:view];
    self.window=[[NSWindow alloc]initWithContentRect:NSMakeRect(180,100,980,820) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"阅卷 — PDF";self.window.delegate=self; self.window.releasedWhenClosed=NO;
    self.window.minSize=NSMakeSize(760,420);
    NSView *root=self.window.contentView;
    self.pdf=[[DropPDF alloc]initWithFrame:NSMakeRect(0,30,980,744)];self.pdf.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    self.pdf.displayMode=kPDFDisplaySinglePageContinuous;self.pdf.autoScales=NO; self.pdf.backgroundColor=NSColor.windowBackgroundColor;
    [self.pdf registerForDraggedTypes:@[NSPasteboardTypeFileURL]];[root addSubview:self.pdf];
    CGFloat x=12;
    NSArray *titles=@[@"Open…",@"‹",@"›",@"−",@"+",@"Fit Width"];
    SEL actions[]={@selector(open:),@selector(previous:),@selector(next:),@selector(zoomOut:),@selector(zoomIn:),@selector(fitWidth:)};
    for(int i=0;i<titles.count;i++){NSButton *b=[NSButton buttonWithTitle:titles[i] target:self action:actions[i]];b.frame=NSMakeRect(x,782,i==0||i==5?82:36,28);b.autoresizingMask=NSViewMinYMargin;[root addSubview:b];x+=b.frame.size.width+4;}
    self.pageField=[[NSTextField alloc]initWithFrame:NSMakeRect(x+5,784,65,24)];self.pageField.placeholderString=@"Page";self.pageField.target=self;self.pageField.action=@selector(page:);self.pageField.autoresizingMask=NSViewMinYMargin;[root addSubview:self.pageField];
    self.search=[[NSSearchField alloc]initWithFrame:NSMakeRect(650,784,315,24)];self.search.placeholderString=@"Find in PDF";self.search.target=self;self.search.action=@selector(search:);self.search.autoresizingMask=NSViewMinXMargin|NSViewMinYMargin;[root addSubview:self.search];
    self.status=[NSTextField labelWithString:@"Open a PDF to begin"];self.status.frame=NSMakeRect(12,6,956,18);self.status.autoresizingMask=NSViewWidthSizable;self.status.lineBreakMode=NSLineBreakByTruncatingMiddle;[root addSubview:self.status];
    [[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(pageChanged:) name:PDFViewPageChangedNotification object:self.pdf];
    [[NSDistributedNotificationCenter defaultCenter]addObserver:self selector:@selector(navigationRequest:) name:@"org.yuyan.reader.navigate" object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [NSApp finishLaunching];[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
}
- (void)about:(id)sender {NSAlert *a=[NSAlert new];a.messageText=@"阅卷";a.informativeText=@"Yuyan · Wasm-GC · V8\nNative PDFKit viewer for continuously rebuilt papers.";[a beginSheetModalForWindow:self.window completionHandler:nil];}
- (void)pageChanged:(id)sender {if(self.pdf.document)self.pageField.stringValue=[NSString stringWithFormat:@"%lu",[self.pdf.document indexForPage:self.pdf.currentPage]+1];}
- (void)windowDidResize:(NSNotification *)n {if(self.fit)[self fitWidth:nil];}
- (void)windowWillClose:(NSNotification *)n {[self closeDocument:nil];self.quitting=YES;}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {self.quitting=YES;return NSTerminateCancel;}
- (BOOL)application:(NSApplication *)app openFile:(NSString *)filename {[self openPath:filename];return YES;}
- (void)quit:(id)sender {self.quitting=YES;}
- (void)open:(id)sender {NSOpenPanel *p=[NSOpenPanel openPanel];p.allowedContentTypes=@[UTTypePDF];[p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r){if(r==NSModalResponseOK)[self openPath:p.URL.path];}];}
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
- (void)closeDocument:(id)sender {[self stopWatch];self.session++;self.path=nil;self.digest=nil;self.pdf.document=nil;self.lines=@[];self.candidate=nil;[self.events removeAllObjects];[self enqueue:1 generation:0];self.status.stringValue=@"No document";self.window.title=@"阅卷 — PDF";}
- (void)openPath:(NSString *)path {
    [self stopWatch];self.session++;self.path=path.stringByStandardizingPath;self.digest=nil;
    self.pdf.document=nil;self.lines=@[];self.candidate=nil;[self.events removeAllObjects];
    self.window.title=[@"阅卷 — " stringByAppendingString:self.path.lastPathComponent];self.window.representedURL=[NSURL fileURLWithPath:self.path];
    self.status.stringValue=[@"Opening · " stringByAppendingString:self.path];
    self.fileSignature=nil;[self armDirectoryWatch];
    [self armFileWatch];
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
- (void)search:(id)sender {if(!self.search.stringValue.length)return;PDFSelection *s=[self.pdf.document findString:self.search.stringValue fromSelection:self.pdf.currentSelection withOptions:NSCaseInsensitiveSearch];if(!s)s=[self.pdf.document findString:self.search.stringValue fromSelection:nil withOptions:NSCaseInsensitiveSearch];if(s){[self.pdf setCurrentSelection:s animate:YES];[self.pdf scrollSelectionToVisible:nil];}}
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
            if(doc){[self.events addObject:@{@"kind":@3,@"generation":@(generation),@"doc":doc,@"lines":lines,@"digest":hash}];}
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
- (void)commitLine:(NSInteger)line anchor:(NSInteger)anchor {
    if(!self.candidate)return;
    BOOL initial=self.pdf.document==nil;self.pdf.document=self.candidate;self.lines=self.candidateLines;self.digest=self.candidateDigest;self.candidate=nil;self.commits++;
    self.pdf.displayMode=self.savedMode; if(initial||self.fit)[self fitWidth:nil];else self.pdf.scaleFactor=self.savedScale;
    if(!initial){if(line>=0&&line<self.lines.count){NSDictionary *l=self.lines[line];NSPoint off=anchor>=0&&anchor<self.anchors.count?NSPointFromString(self.anchors[anchor][@"offset"]):self.fallbackOffset;[self positionPage:[l[@"page"] integerValue] point:NSRectFromString(l[@"rect"]).origin offset:off];}else [self positionPage:self.fallbackPage point:self.fallbackPoint offset:self.fallbackOffset];}
    self.status.stringValue=[NSString stringWithFormat:@"Updated · %lu pages · %@",self.pdf.document.pageCount,self.path];[self pageChanged:nil];
    [self navigate];
}
- (void)navigationRequest:(NSNotification *)note {
    NSDictionary *r=note.userInfo;if(![r[@"pdf"] isEqual:self.path])return;
    self.navigationSource=r[@"source"];self.navigationLine=[r[@"line"] integerValue];self.navigationSerial++;[self reload:nil];
}
- (void)navigate {
    if(!self.navigationSource.length||!self.pdf.document)return;
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
    if([op isEqual:@"init"]){[self setup];if(a.count&&[a[0] length])[self openPath:a[0]];return @0;}
    if([op isEqual:@"poll"]){@autoreleasepool {
        NSEvent *e=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:.01] inMode:NSDefaultRunLoopMode dequeue:YES];if(e)[NSApp sendEvent:e];[NSApp updateWindows];
        if(self.quitting)return @9;
        NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
        if(self.path&&now-self.healthTime>1){self.healthTime=now;[self armDirectoryWatch];[self armFileWatch];struct stat st;NSString *signature=stat(self.path.fileSystemRepresentation,&st)==0?[NSString stringWithFormat:@"%llu:%lld:%ld:%ld",(unsigned long long)st.st_ino,st.st_size,st.st_mtimespec.tv_sec,st.st_mtimespec.tv_nsec]:@"missing";
            if(self.fileSignature&&![self.fileSignature isEqual:signature])[self enqueue:2 generation:0];self.fileSignature=signature;
        }
        if(!self.events.count)return @0;self.event=self.events[0];[self.events removeObjectAtIndex:0];
        if([self.event[@"kind"] isEqual:@3]){self.candidate=self.event[@"doc"];self.candidateLines=self.event[@"lines"];self.candidateDigest=self.event[@"digest"];}
        return self.event[@"kind"];
    }}
    if([op isEqual:@"number"]){NSString *k=a[0];if([k isEqual:@"clock"])return @((NSInteger)(NSProcessInfo.processInfo.systemUptime*1000));if([k isEqual:@"generation"])return self.event[@"generation"]?:@0;if([k isEqual:@"count"])return @(self.candidateLines.count);if([k isEqual:@"same"])return @([self.digest isEqual:self.candidateDigest]);if([k isEqual:@"follow"])return @(self.follow);if([k isEqual:@"opened"])return @(self.path!=nil);return @0;}
    if([op isEqual:@"text"]){NSInteger i=[a[0] integerValue];return i>=0&&i<self.candidateLines.count?self.candidateLines[i][@"text"]:@"";}
    if([op isEqual:@"oldtext"]){NSInteger i=[a[0] integerValue];return i>=0&&i<self.lines.count?self.lines[i][@"text"]:@"";}
    if([op isEqual:@"anchor"]){NSInteger i=[a[0] integerValue];return i>=0&&i<self.anchors.count?self.anchors[i][@"text"]:@"";}
    if([op isEqual:@"pageof"]){NSInteger i=[a[0] integerValue];return i>=0&&i<self.candidateLines.count?self.candidateLines[i][@"page"]:@0;}
    if([op isEqual:@"anchorpage"]){NSInteger i=[a[0] integerValue];return i>=0&&i<self.anchors.count?self.anchors[i][@"page"]:@0;}
    if([op isEqual:@"begin"]){[self begin:[a[0] integerValue]];return @0;}
    if([op isEqual:@"prepare"]){[self capture];return @0;}
    if([op isEqual:@"unchanged"]){self.status.stringValue=[NSString stringWithFormat:@"Up to date · %@",self.path?:@""];self.candidate=nil;[self navigate];return @0;}
    if([op isEqual:@"navigate"]){self.navigationSource=a[0];self.navigationLine=[a[1] integerValue];self.navigationSerial++;[self reload:nil];return @0;}
    if([op isEqual:@"commit"]){[self commitLine:[a[0] integerValue] anchor:[a[1] integerValue]];return @0;}
    if([op isEqual:@"status"]){self.status.stringValue=[NSString stringWithFormat:@"%@ · %@",a[0],self.path?:@""];return @0;}
    if([op isEqual:@"open"]){[self openPath:a[0]];return @0;}
    if([op isEqual:@"close"]){[self closeDocument:nil];return @0;}
    if([op isEqual:@"quit"]){self.quitting=YES;[self stopWatch];return @0;}
    if([op isEqual:@"testPosition"]){self.fit=NO;self.pdf.scaleFactor=[a[1] doubleValue];[self positionPage:[a[0] integerValue] point:NSMakePoint(72,[a[2] doubleValue]) offset:NSMakePoint(100,450)];return @0;}
    if([op isEqual:@"testDelay"]){self.testDelay=[a[0] doubleValue];return @0;}
    if([op isEqual:@"testFollow"]){self.follow=[a[0] boolValue];return @0;}
    if([op isEqual:@"testMode"]){[self setModePreservingPosition:[a[0] integerValue]];return @0;}
    if([op isEqual:@"inspect"]){[self capture];return @{@"path":self.path?:@"",@"commits":@(self.commits),@"loads":@(self.loads),@"watchers":@(self.watchCount),@"pages":@(self.pdf.document.pageCount),@"page":@(self.fallbackPage),@"mode":@(self.pdf.displayMode),@"zoom":@(self.pdf.scaleFactor),@"anchor":self.anchors.count?self.anchors[0]:@{},@"digest":self.digest?:@"",@"status":self.status.stringValue?:@""};}
    return @0;
}
@end
static NSString *JSString(napi_env env,napi_value value){size_t size=0;napi_get_value_string_utf8(env,value,NULL,0,&size);char *s=calloc(size+1,1);napi_get_value_string_utf8(env,value,s,size+1,&size);NSString *r=[[NSString alloc]initWithBytes:s length:size encoding:NSUTF8StringEncoding];free(s);return r;}
static napi_value Call(napi_env env,napi_callback_info info){@autoreleasepool {size_t count=2;napi_value argv[2];napi_get_cb_info(env,info,&count,argv,NULL,NULL);if(count!=2){napi_throw_error(env,NULL,"invoke requires operation and JSON args");return NULL;}
    @try {if(!V)V=[Viewer new];NSString *op=JSString(env,argv[0]);NSArray *args=[NSJSONSerialization JSONObjectWithData:[JSString(env,argv[1]) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];id value=[V invoke:op args:args];NSData *data=[NSJSONSerialization dataWithJSONObject:value?:@0 options:NSJSONWritingFragmentsAllowed error:nil];napi_value result;napi_create_string_utf8(env,data.bytes,data.length,&result);return result;}
    @catch(NSException *exception){napi_throw_error(env,NULL,exception.reason.UTF8String);return NULL;}
}}
static napi_value Init(napi_env env,napi_value exports){napi_value f;napi_create_function(env,"invoke",NAPI_AUTO_LENGTH,Call,NULL,&f);napi_set_named_property(env,exports,"invoke",f);return exports;}
NAPI_MODULE(阅卷,Init)
