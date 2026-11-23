// 文言：验较文之术：同者不记，增删必记，行号、断词、越页之移不为异。汉语：不依赖窗口的差异算法与取词测试。
#import <Cocoa/Cocoa.h>
#import "../源码/差异.h"
@interface TestLine : PDFSelection
@property NSRange range;
@end
@implementation TestLine
- (NSUInteger)numberOfTextRangesOnPage:(PDFPage *)page {return 1;}
- (NSRange)rangeAtIndex:(NSUInteger)index onPage:(PDFPage *)page {return self.range;}
@end
// 文言：拟页边之数，或置左缘，或横亘一行。汉语：模拟 PDFKit 报告的位置。margin 中的字符是页边行号：
// 整段都在页边时位于左缘小框内；stretched 或只部分属于页边时是横跨整行的宽框（macOS 27 对并入行尾的行号如此报告）。其余字符每列 6pt。
@interface TestWords : DiffWords
@property NSString *text;
@property NSIndexSet *margin;
@property BOOL stretched;
@end
@implementation TestWords
- (NSRect)boundsOf:(NSRange)range page:(PDFPage *)page {
    if([self.margin intersectsIndexesInRange:range])return self.stretched||![self.margin containsIndexesInRange:range]?NSMakeRect(-80,0,377,13.8):NSMakeRect(40,0,3.3*range.length,12);
    NSUInteger start=[self.text rangeOfString:@"\n" options:NSBackwardsSearch range:NSMakeRange(0,range.location)].location,column=0;
    for(NSUInteger i=start==NSNotFound?0:start+1;i<range.location;i++)if(![self.margin containsIndex:i])column++;
    return NSMakeRect(72+6*column,0,6*range.length,12);
}
@end
static int Passed;
static void Check(BOOL condition,NSString *label){if(!condition){fprintf(stderr,"FAIL %s\n",label.UTF8String);exit(1);}Passed++;printf("PASS %s\n",label.UTF8String);}
static NSUInteger Count(const uint8_t *d,NSUInteger n){NSUInteger c=0;for(NSUInteger i=0;i<n;i++)c+=d[i];return c;}
// The words left unmarked on both sides must be the same sequence.
static BOOL Consistent(const uint64_t *a,NSUInteger n,const uint64_t *b,NSUInteger m,const uint8_t *da,const uint8_t *db){
    NSUInteger i=0,j=0;
    for(;;){while(i<n&&da[i])i++;while(j<m&&db[j])j++;if(i==n||j==m)return i==n&&j==m;if(a[i++]!=b[j++])return NO;}
}
static NSUInteger Common(const uint64_t *a,NSUInteger n,const uint64_t *b,NSUInteger m){
    NSUInteger *row=calloc(2*(m+1),sizeof(NSUInteger)),*now=row,*next=row+m+1;
    for(NSUInteger i=n;i-->0;){for(NSUInteger j=m;j-->0;)now[j]=a[i]==b[j]?next[j+1]+1:MAX(next[j],now[j+1]);NSUInteger *swap=now;now=next;next=swap;now[m]=0;}
    NSUInteger result=next[0];free(row);return result;
}
// 文言：置词于页，以验原位之法。汉语：按位置摆放的词，用于检验“原位仍在”规则；所有词同在一页，宽 40pt。
typedef struct {uint64_t key;CGFloat x,y;} Placed;
static void Compose(Placed *out,const Placed *a,NSUInteger na,const Placed *b,NSUInteger nb,const Placed *c,NSUInteger nc,CGFloat rise){
    memcpy(out,a,na*sizeof(Placed));memcpy(out+na,b,nb*sizeof(Placed));memcpy(out+na+nb,c,nc*sizeof(Placed));
    for(NSUInteger k=0;k<na+nb+nc;k++)out[k].y+=rise;
}
static void Place(const Placed *was,NSUInteger n,const Placed *now,NSUInteger m,NSUInteger *linear,NSUInteger *deleted,NSUInteger *added){
    uint64_t *a=malloc(n*8),*b=malloc(m*8);uint32_t *pageA=calloc(n,4),*pageB=calloc(m,4);uint8_t *da=malloc(n),*db=malloc(m);
    for(NSUInteger i=0;i<n;i++)a[i]=was[i].key;
    for(NSUInteger j=0;j<m;j++)b[j]=now[j].key;
    DiffBox box=^NSRect(BOOL inNew,NSUInteger word){const Placed *w=(inNew?now:was)+word;return NSMakeRect(w->x,w->y,40,12);};
    DiffKeys(a,n,b,m,da,db);*linear=Count(da,n);DiffCancelMoves(a,pageA,n,b,pageB,m,da,db,box);
    *deleted=Count(da,n);*added=Count(db,m);free(a);free(b);free(pageA);free(pageB);free(da);free(db);
}
// Each line of a page is one text range, as PDFKit reports lines. ‹…› encloses the characters of a margin number.
static NSString *Plain(NSString *source){return [[source stringByReplacingOccurrencesOfString:@"‹" withString:@""] stringByReplacingOccurrencesOfString:@"›" withString:@""];}
static NSData *TokensAs(NSArray<NSString *> *pages,BOOL stretched){
    TestWords *words=[TestWords new];words.stretched=stretched;PDFDocument *document=[PDFDocument new];PDFPage *page=[PDFPage new];
    [pages enumerateObjectsUsingBlock:^(NSString *source,NSUInteger index,BOOL *stop){
        NSMutableString *text=[NSMutableString new];NSMutableIndexSet *margin=[NSMutableIndexSet new];BOOL inside=NO;
        for(NSUInteger i=0;i<source.length;i++){
            unichar c=[source characterAtIndex:i];if(c==0x2039||c==0x203A){inside=c==0x2039;continue;}
            if(inside)[margin addIndex:text.length];[text appendFormat:@"%C",c];
        }
        words.text=text;words.margin=margin;NSUInteger start=0;CGFloat y=700;
        while(start<text.length){
            NSRange end=[text rangeOfString:@"\n" options:0 range:NSMakeRange(start,text.length-start)];NSUInteger next=end.location==NSNotFound?text.length:end.location+1;
            TestLine *line=[[TestLine alloc]initWithDocument:document];line.range=NSMakeRange(start,next-start);
            [words addLine:line page:page index:index text:text y:y];start=next;y-=12;
        }
    }];
    return [words finish];
}
static NSData *Tokens(NSArray<NSString *> *pages){return TokensAs(pages,NO);}
static NSString *Marked(NSArray<NSString *> *pages,NSData *tokens,NSData *flags){
    const DiffToken *t=tokens.bytes;const uint8_t *f=flags.bytes;NSMutableArray *out=[NSMutableArray new];
    for(NSUInteger i=0;i<flags.length;i++)if(f[i])[out addObject:[Plain(pages[t[i].page]) substringWithRange:NSMakeRange(t[i].loc,t[i].len)]];
    return [out componentsJoinedByString:@" "];
}
int main(void){@autoreleasepool{
    uint64_t one[]={1,2,3,4,5},inserted[]={1,2,9,3,4,5},removed[]={1,2,4,5},replaced[]={1,2,8,9,4,5};uint8_t da[8],db[8];
    DiffKeys(one,5,one,5,da,db);Check(!Count(da,5)&&!Count(db,5),@"identical sequences have no changes");
    DiffKeys(one,5,inserted,6,da,db);Check(!Count(da,5)&&Count(db,6)==1&&db[2],@"an inserted word is marked only in the new version");
    DiffKeys(one,5,removed,4,da,db);Check(Count(da,5)==1&&da[2]&&!Count(db,4),@"a removed word is marked only in the old version");
    DiffKeys(one,5,replaced,6,da,db);Check(Count(da,5)==1&&da[2]&&Count(db,6)==2&&db[2]&&db[3],@"a replaced word is marked on both sides");
    DiffKeys(one,0,one,5,da,db);Check(Count(db,5)==5,@"an empty old version marks everything as added");

    srandom(7);BOOL valid=YES,optimal=YES;
    for(int trial=0;trial<400;trial++){
        uint64_t a[60],b[60];uint8_t x[60],y[60];NSUInteger n=random()%60,m=random()%60;
        for(NSUInteger i=0;i<n;i++)a[i]=random()%6;for(NSUInteger j=0;j<m;j++)b[j]=random()%6;
        DiffKeys(a,n,b,m,x,y);valid&=Consistent(a,n,b,m,x,y);optimal&=n-Count(x,n)==Common(a,n,b,m);
    }
    Check(valid,@"random small inputs keep equal unmarked words");Check(optimal,@"random small inputs keep a longest common subsequence");

    // 60,000 distinct words: one 20,000-word block removed, two words replaced, three inserted.
    NSUInteger n=60000,m=0;uint64_t *a=malloc(n*8),*b=malloc((n+8)*8);uint8_t *x=malloc(n),*y=malloc(n+8);
    for(NSUInteger i=0;i<n;i++){a[i]=1000+i;if(i>=20000&&i<40000)continue;if(i==55000){b[m++]=7;b[m++]=8;b[m++]=9;}b[m++]=i==5000||i==50000?5+i:a[i];}
    DiffKeys(a,n,b,m,x,y);
    Check(Consistent(a,n,b,m,x,y)&&Count(x,n)==20002&&Count(y,m)==5,@"a large removed block with scattered edits is found exactly");
    Check(x[20000]&&x[39999]&&x[5000]&&!x[19999]&&!x[40000]&&y[55000-20000]&&y[55002-20000],@"the marks fall on the changed words");
    for(NSUInteger i=0;i<n;i++)a[i]=b[i]=i%7;
    DiffKeys(a,n,b,n,x,y);Check(!Count(x,n)&&!Count(y,n),@"identical repetitive text has no changes");
    m=0;for(NSUInteger i=1;i<n;i++)b[m++]=a[i];b[m++]=a[0];
    DiffKeys(a,n,b,m,x,y);Check(Consistent(a,n,b,m,x,y),@"large text without unique words still yields equal unmarked words");
    for(NSUInteger i=0;i<n;i++)a[i]=b[i]=1000+i;m=n;
    for(NSUInteger i=300;i<n;i+=1100)b[i]=3+i;
    DiffKeys(a,n,b,m,x,y);Check(Consistent(a,n,b,m,x,y)&&Count(x,n)==55&&Count(y,m)==55,@"scattered replacements in a long text are each marked once");
    free(a);free(b);free(x);free(y);

    // A line moves from the foot of page 0 to the head of page 1, past a footer and a header.
    uint64_t oldKeys[]={1,2,3,100,101,4,5},newKeys[]={1,2,100,101,3,4,5};uint32_t oldPages[]={0,0,0,0,1,1,1},newPages[]={0,0,0,1,1,1,1};
    DiffKeys(oldKeys,7,newKeys,7,da,db);Check(Count(da,7)==1&&da[2]&&Count(db,7)==1&&db[4],@"a linear comparison marks text moved past page furniture");
    DiffCancelMoves(oldKeys,oldPages,7,newKeys,newPages,7,da,db,nil);Check(!Count(da,7)&&!Count(db,7),@"text that only moved across a page break is not a change");
    // The furniture is shorter than the moved text, so the furniture is what the comparison marks.
    uint64_t longOld[]={1,2,3,30,31,100,4,5},longNew[]={1,2,100,3,30,31,4,5};uint32_t longOldPages[]={0,0,0,0,0,1,1,1},longNewPages[]={0,0,1,1,1,1,1,1};
    DiffKeys(longOld,8,longNew,8,da,db);Check(da[5]&&db[2],@"a short header is marked when a longer passage crosses it");
    DiffCancelMoves(longOld,longOldPages,8,longNew,longNewPages,8,da,db,nil);Check(!Count(da,8)&&!Count(db,8),@"a header crossed by moved text is not a change");
    uint64_t moveOld[]={1,2,3,4,5,6},moveNew[]={1,3,4,5,2,6};uint32_t samePage[]={0,0,0,0,0,0};
    DiffKeys(moveOld,6,moveNew,6,da,db);DiffCancelMoves(moveOld,samePage,6,moveNew,samePage,6,da,db,nil);
    Check(Count(da,6)==1&&da[1]&&Count(db,6)==1&&db[4],@"a word moved within one page stays marked");
    uint64_t editOld[]={1,2,3,100,4,5},editNew[]={1,9,100,3,4,5};uint32_t editOldPages[]={0,0,0,1,1,1},editNewPages[]={0,0,1,1,1,1};
    DiffKeys(editOld,6,editNew,6,da,db);DiffCancelMoves(editOld,editOldPages,6,editNew,editNewPages,6,da,db,nil);
    Check(Count(da,6)==1&&da[1]&&Count(db,6)==1&&db[1],@"an edit next to moved text stays marked while the move is cancelled");
    // A proof table split by a page break: PDFKit reports its cells in another order once the break moves.
    uint64_t tableOld[]={1,2,10,11,12,13,14,15,3,4},tableNew[]={1,2,13,14,15,12,10,11,3,4};uint32_t tableOldPages[]={0,0,0,0,1,1,1,1,1,1},tableNewPages[]={0,0,1,1,1,1,1,1,1,1};uint8_t ta[10],tb[10];
    DiffKeys(tableOld,10,tableNew,10,ta,tb);Check(Count(ta,10)==3&&Count(tb,10)==3,@"a linear comparison marks cells reported in another order");
    DiffCancelMoves(tableOld,tableOldPages,10,tableNew,tableNewPages,10,ta,tb,nil);
    Check(Count(ta,10)==1&&ta[4]&&Count(tb,10)==1&&tb[5],@"words reordered across a moved page break are not changes; a word reordered within its page stays marked");
    // A rule figure whose fragments PDFKit reports in another order, on a page that now lies 30pt lower:
    // every word stands where it stood. The repeated word is matched crosswise by the comparison.
    Placed above[]={{101,50,500},{102,100,500},{103,150,500},{104,200,500},{105,250,500}},below[]={{106,50,300},{107,100,300},{108,150,300},{109,200,300},{110,250,300}};
    Placed figure[]={{7,50,400},{8,100,400},{7,50,380},{9,100,380}},reported[]={{7,50,380},{9,100,380},{7,50,400},{8,100,400}},swapped[]={{7,50,400},{9,100,400},{7,50,380},{8,100,380}};
    Placed laidOld[14],laidNew[14];NSUInteger linear,gone,come;
    Compose(laidOld,above,5,figure,4,below,5,0);Compose(laidNew,above,5,reported,4,below,5,-30);
    Place(laidOld,14,laidNew,14,&linear,&gone,&come);
    Check(linear==2&&!gone&&!come,@"words reported in another order but standing in the same place are not changes");
    Compose(laidNew,above,5,swapped,4,below,5,0);Place(laidOld,14,laidNew,14,&linear,&gone,&come);
    Check(linear==2&&gone==2&&come==2,@"words that really changed places within a page stay marked");
    // One of two identical lines is deleted and the text below moves up: the other line now stands in its place.
    Placed head[]={{101,50,500}},twice[]={{5,50,400},{6,100,400},{5,50,380},{6,100,380}},once[]={{5,50,400},{6,100,400}};
    Placed foot[]={{111,50,360},{112,100,360},{113,150,360},{114,200,360},{115,250,360},{116,300,360},{117,350,360},{118,400,360},{119,450,360}},raised[9];
    for(int k=0;k<9;k++){raised[k]=foot[k];raised[k].y+=20;}
    Compose(laidOld,head,1,twice,4,foot,9,0);Compose(laidNew,head,1,once,2,raised,9,0);
    Place(laidOld,14,laidNew,12,&linear,&gone,&come);
    Check(linear==2&&gone==2&&!come,@"a deleted line stays marked when an identical line moves into its place");
    // The same word far away is another occurrence, not a move.
    uint64_t *farOld=malloc(1000*8),*farNew=malloc(1000*8);uint32_t *farOldPages=malloc(1000*4),*farNewPages=malloc(1000*4);uint8_t *fa=malloc(1000),*fb=malloc(1000);
    for(NSUInteger k=0;k<1000;k++){farOld[k]=farNew[k]=100+k;farOldPages[k]=farNewPages[k]=(uint32_t)(k/250);}
    farOld[20]=7;farNew[20]=8;farOld[900]=8;farNew[900]=7;
    DiffKeys(farOld,1000,farNew,1000,fa,fb);DiffCancelMoves(farOld,farOldPages,1000,farNew,farNewPages,1000,fa,fb,nil);
    Check(Count(fa,1000)==2&&Count(fb,1000)==2,@"the same word deleted and added far apart stays marked");
    free(farOld);free(farNew);free(farOldPages);free(farNewPages);free(fa);free(fb);

    Check([DiffWord(@"higher-order") isEqual:@"higherorder"]&&[DiffWord(@"-") isEqual:@"-"]&&[DiffWord(@"é") isEqual:@"é"],@"words compare without hyphens and in composed form");
    Check(DiffDigits(@"120")&&!DiffDigits(@"12.")&&!DiffDigits(@"")&&!DiffDigits(@"1a"),@"only pure digit strings count as numbers");

    // Margin line numbers shift and the paragraph rebreaks; one word is added and one removed.
    NSArray *before=@[@"7\nThe represen-\n8\ntation of higher-\n9\norder terms is old\n3\n"];
    NSArray *after=@[@"7\nA note.\n8\nThe representation of\n9\nhigher-order terms is\n10\nnew\n4\n"];
    NSData *oldTokens=Tokens(before),*newTokens=Tokens(after);NSDictionary *diff=DiffCompute(oldTokens,newTokens,nil,nil);
    Check([Marked(before,oldTokens,diff[@"old"]) isEqual:@"old"]&&[diff[@"deleted"] isEqual:@1],@"line numbers and rebroken hyphenated words are not deletions");
    Check([Marked(after,newTokens,diff[@"new"]) isEqual:@"A note. new"]&&[diff[@"added"] isEqual:@3],@"line numbers and rebroken hyphenated words are not additions");
    diff=DiffCompute(Tokens(@[@"The represen-\n8\ntation holds\n"]),newTokens=Tokens(@[@"The description holds\n"]),nil,nil);
    NSArray *split=@[@"The represen-\n8\ntation holds\n"];
    Check([Marked(split,Tokens(split),diff[@"old"]) isEqual:@"represen- tation"]&&[diff[@"deleted"] isEqual:@1],@"both halves of a changed hyphenated word are marked as one word");
    // PDFKit may instead put each margin number at the head of its text line, set apart from the text.
    before=@[@"‹7› The represen-\n‹8› tation of higher-\n‹9› order terms is old\n3\n"];after=@[@"‹7› A note.\n‹8› The representation of\n‹9› higher-order terms is\n‹10› new\n4\n"];
    oldTokens=Tokens(before);newTokens=Tokens(after);diff=DiffCompute(oldTokens,newTokens,nil,nil);
    Check([Marked(before,oldTokens,diff[@"old"]) isEqual:@"old"]&&[Marked(after,newTokens,diff[@"new"]) isEqual:@"A note. new"],@"margin numbers at the head of text lines are not changes either");
    // Or glue the number to the last word of its line and report it stretched across the line.
    before=@[@"The represen-‹7›\ntation of higher-‹8›\norder terms is old‹9›\n3\n"];after=@[@"A note.‹7›\nThe representation of‹8›\nhigher-order terms is‹9›\nnew‹10›\n4\n"];
    oldTokens=TokensAs(before,YES);newTokens=TokensAs(after,YES);diff=DiffCompute(oldTokens,newTokens,nil,nil);
    Check([Marked(before,oldTokens,diff[@"old"]) isEqual:@"old"]&&[Marked(after,newTokens,diff[@"new"]) isEqual:@"A note. new"],@"margin numbers glued to the last word of a line are not changes");
    // The character beside a glued number has no reliable position: it is left out of the highlight, which ends there.
    after=@[@"see alpha beta‹7›\ngamma delta\n"];newTokens=TokensAs(after,YES);diff=DiffCompute(Tokens(@[@"see\n"]),newTokens,nil,nil);
    NSArray *expected=@[@[@0,@4,@9],@[@0,@16,@11]];
    Check([DiffRuns(newTokens,diff[@"new"]) isEqual:expected]&&[diff[@"added"] isEqual:@4],@"a highlight stops before the character that touches a glued margin number");
    before=@[@"Chapter 4‹748›\nopens here ‹749›\n"];after=@[@"Chapter 4‹751›\nopens here ‹752›\n"];
    diff=DiffCompute(TokensAs(before,YES),TokensAs(after,YES),nil,nil);
    Check([diff[@"deleted"] isEqual:@0]&&[diff[@"added"] isEqual:@0],@"a margin number glued to a number of the text is not a change");
    before=@[@"see the word1\nand more text\n"];after=@[@"see the word2\nand more text\n"];
    oldTokens=Tokens(before);newTokens=Tokens(after);diff=DiffCompute(oldTokens,newTokens,nil,nil);
    Check([Marked(before,oldTokens,diff[@"old"]) isEqual:@"word1"]&&[Marked(after,newTokens,diff[@"new"]) isEqual:@"word2"],@"a footnote mark that touches its word is still compared");
    after=@[@"2 apples and 3 pears\nwere bought in\n2024 by them\n"];before=@[@"4 apples and 3 pears\nwere bought in\n2023 by them\n"];
    oldTokens=Tokens(before);newTokens=Tokens(after);diff=DiffCompute(oldTokens,newTokens,nil,nil);
    Check([Marked(before,oldTokens,diff[@"old"]) isEqual:@"4 2023"]&&[Marked(after,newTokens,diff[@"new"]) isEqual:@"2 2024"],@"a number that opens a line of prose is still compared");
    // A word broken across pages continues only with a lowercase fragment.
    diff=DiffCompute(Tokens(@[@"some represen-\n1\n",@"tation here\n"]),Tokens(@[@"some representation\n1\n",@"here\n"]),nil,nil);
    Check([diff[@"deleted"] isEqual:@0]&&[diff[@"added"] isEqual:@0],@"a word hyphenated across a page break equals the unbroken word");
    diff=DiffCompute(Tokens(@[@"some pre-\n1\n",@"Header text\n"]),Tokens(@[@"some pre-\n1\n",@"Header text\n"]),nil,nil);
    const DiffToken *t=Tokens(@[@"some pre-\n1\n",@"Header text\n"]).bytes;
    Check(!t[3].flags&&t[2].flags==DiffIgnored&&[diff[@"added"] isEqual:@0],@"a header on the next page does not continue a hyphenated word");
    // Odd and even pages carry different headers; one inserted page makes every later page change its header.
    NSArray *old=@[@"Paper Title\nalpha one\nFoot note\n",@"Author Names\nbeta two\nFoot note\n",@"Paper Title\ngamma three\nFoot note\n",@"Author Names\ndelta four\nFoot note\n",@"Paper Title\nepsilon five\nFoot note\n",@"Author Names\nzeta six\nFoot note\n"];
    NSArray *now=@[old[0],@"Author Names\nbrand new page\nFoot note\n",@"Paper Title\nbeta two\nFoot note\n",@"Author Names\ngamma three\nFoot note\n",@"Paper Title\ndelta four\nFoot note\n",@"Author Names\nepsilon five\nFoot note\n",@"Paper Title\nzeta six\nFoot note\n"];
    oldTokens=Tokens(old);newTokens=Tokens(now);diff=DiffCompute(oldTokens,newTokens,nil,nil);
    Check([diff[@"deleted"] isEqual:@0]&&[Marked(now,newTokens,diff[@"new"]) isEqual:@"brand new page"],@"headers and footers repeated on three pages are not compared, so alternating headers do not show as changes");
    const DiffToken *furniture=oldTokens.bytes;
    Check(furniture[0].flags==DiffIgnored&&furniture[1].flags==DiffIgnored&&!furniture[2].flags&&furniture[4].flags==DiffIgnored,@"the repeated top and bottom lines are the ones left out");
    old=@[@"Same Start\nalpha one\n",@"Same Start\nbeta two\n"];now=@[@"Other Head\nalpha one\n",@"Other Head\nbeta two\n"];
    diff=DiffCompute(Tokens(old),Tokens(now),nil,nil);
    Check([diff[@"deleted"] isEqual:@4]&&[diff[@"added"] isEqual:@4],@"a top line shared by only two pages is still compared");
    // A word hyphenated across a page break continues after the header of the next page.
    old=@[@"Paper Title\nsome represen-\n",@"Paper Title\ntation here\n",@"Paper Title\nmore\n"];now=@[@"Paper Title\nsome representation\n",@"Paper Title\nhere\n",@"Paper Title\nmore\n"];
    diff=DiffCompute(Tokens(old),Tokens(now),nil,nil);
    Check([diff[@"deleted"] isEqual:@0]&&[diff[@"added"] isEqual:@0],@"a hyphenated word continues past a running header");
    // Adjacent changed words on one page form one highlight; an ignored number between them splits it.
    after=@[@"one two\nthree\n12\nfour\n",@"five\n"];newTokens=Tokens(after);diff=DiffCompute([NSData data],newTokens,nil,nil);
    expected=@[@[@0,@0,@13],@[@0,@17,@4],@[@1,@0,@4]];
    Check([DiffRuns(newTokens,diff[@"new"]) isEqual:expected],@"adjacent changed words merge into one highlight per page, split at margin numbers");
    printf("{\"passed\":%d}\n",Passed);
}}
