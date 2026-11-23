#pragma once
#import <PDFKit/PDFKit.h>
#import "文本范围.h"

// 文言：较邻版之文，以词为度；页边行号、行末断词、越页之移，皆不为异。
// 汉语：相邻版本的词级差异。页边行号与页码（只含一个数的行，或行首行尾脱离正文的数）不参与比较；行尾连字符断开的词合并为一词，比较时忽略连字符；
// 在多页同一位置重复出现的页眉页脚不参与比较；仅因分页而换页的文字不算改动。只使用已验证的文本范围，从不读取 PDFSelection.string。
// 文言：词记其页、其位、其行之高下。汉语：每个词 24 字节：散列、页、字符范围，以及所在行的上缘（页坐标）和行高（八分之一点）。
// 行的上下位置用于概览条和逐处跳转，不必再向 PDFKit 询问每个范围的位置。
typedef struct {uint64_t key;uint32_t loc;uint16_t page,len;float top;uint16_t tall,flags;} DiffToken;
// Ignored: a margin number. Joined: the rest of the word before it. Tail, Head: the last or first character sits beside a
// margin number that PDFKit glued to the word, and PDFKit reports that one character stretched across the line.
enum {DiffIgnored=1,DiffJoined=2,DiffTail=4,DiffHead=8,DiffSkipped=DiffIgnored|DiffJoined};
static const NSUInteger DiffCells=1<<22,DiffDepth=64,DiffMoveWindow=400,DiffSelectionLimit=20000,DiffBands=3,DiffRepeats=3,DiffAnchors=10,DiffAnchorReach=60,DiffShiftTries=4,DiffPlaceTries=48,DiffBoxBudget=5000;
static const CGFloat DiffPlaceSlack=1.5,DiffSetGap=30;

static BOOL DiffHyphen(unichar c) {return c=='-'||c==0x2010||c==0x2011||c==0x00AD;}
static BOOL DiffDigits(NSString *s) {
    for(NSUInteger i=0;i<s.length;i++){unichar c=[s characterAtIndex:i];if(c<'0'||c>'9')return NO;}
    return s.length>0;
}
static uint64_t DiffHash(NSString *s) {
    uint64_t h=1469598103934665603ULL;
    for(NSUInteger i=0;i<s.length;i++){h^=[s characterAtIndex:i];h*=1099511628211ULL;}
    return h;
}
// NFC, hyphens removed: "higher-order" and "higher-" + "order" compare equal.
static NSString *DiffWord(NSString *raw) {
    NSString *s=raw.precomposedStringWithCanonicalMapping;NSUInteger n=s.length,k=0;
    unichar *buffer=malloc((n+1)*sizeof(unichar));[s getCharacters:buffer range:NSMakeRange(0,n)];
    for(NSUInteger i=0;i<n;i++)if(!DiffHyphen(buffer[i]))buffer[k++]=buffer[i];
    NSString *out=k?[NSString stringWithCharacters:buffer length:k]:s;free(buffer);return out;
}

// 文言：逐行取词，记其页与位。汉语：在后台随文本行提取一并收集；每个 token 记录页、字符范围和归一化后的散列。
static NSUInteger DiffDigitRun(NSString *text,NSUInteger loc,NSUInteger len,BOOL trailing) {
    NSUInteger k=0;
    while(k<len){unichar c=[text characterAtIndex:trailing?loc+len-1-k:loc+k];if(c<'0'||c>'9')break;k++;}
    return k;
}
typedef struct {uint32_t first,lead,tail,page;float y;uint8_t hyphen,band;} DiffLine;
@interface DiffWords : NSObject
@property NSMutableData *tokens,*lines;
@property NSMutableArray<NSString *> *words;
@property BOOL failed;
- (NSRect)boundsOf:(NSRange)range page:(PDFPage *)page;
- (void)addLine:(PDFSelection *)line page:(PDFPage *)page index:(NSUInteger)index text:(NSString *)text box:(NSRect)box;
- (NSData *)finish;
@end
@implementation DiffWords
- (instancetype)init {if((self=[super init])){_tokens=[NSMutableData new];_lines=[NSMutableData new];_words=[NSMutableArray new];}return self;}
- (NSRect)boundsOf:(NSRange)range page:(PDFPage *)page {return NSMaxRange(range)>page.numberOfCharacters?NSZeroRect:[[page selectionForRange:range] boundsForPage:page];}
// 文言：数离其邻，或横亘一行者，页边行号也。
// 汉语：PDFKit 把页边行号并入正文行时，这个数要么与相邻文字相距很远或左右颠倒，要么被拉伸成横跨整行的宽框（macOS 27 实测，
// 如“property100”中的 100 宽 377pt）。正文里的数字与相邻字符紧挨，不满足这些条件。
- (BOOL)marginNumber:(NSRange)number beside:(NSUInteger)neighbor after:(BOOL)after page:(PDFPage *)page {
    NSRect box=[self boundsOf:number page:page],other=[self boundsOf:NSMakeRange(neighbor,1) page:page];
    if(NSIsEmptyRect(box)||NSIsEmptyRect(other))return NO;
    CGFloat height=MAX(box.size.height,other.size.height),gap=after?NSMinX(box)-NSMaxX(other):NSMinX(other)-NSMaxX(box);
    BOOL reversed=after?NSMinX(box)+1<NSMinX(other):NSMinX(other)+1<NSMinX(box);
    return box.size.width>1.2*box.size.height*number.length||reversed||gap>.6*height;
}
- (void)addLine:(PDFSelection *)line page:(PDFPage *)page index:(NSUInteger)index text:(NSString *)text box:(NSRect)box {
    if(self.failed)return;
    NSUInteger first=self.tokens.length/sizeof(DiffToken),ranges=[line numberOfTextRangesOnPage:page];
    NSMutableArray<NSString *> *words=self.words;NSCharacterSet *space=NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for(NSUInteger r=0;r<ranges;r++){
        NSRange range=[line rangeAtIndex:r onPage:page];
        if(range.location>text.length||range.length>text.length-range.location)continue;
        NSUInteger start=NSNotFound;
        for(NSUInteger c=range.location;c<=NSMaxRange(range);c++){
            BOOL gap=c==NSMaxRange(range)||[space characterIsMember:[text characterAtIndex:c]];
            if(!gap&&start==NSNotFound)start=c;
            if(!gap||start==NSNotFound)continue;
            NSString *word=DiffWord([text substringWithRange:NSMakeRange(start,c-start)]);
            DiffToken token={.key=DiffHash(word),.loc=(uint32_t)start,.page=(uint16_t)MIN(index,UINT16_MAX),.len=(uint16_t)MIN(c-start,UINT16_MAX),.top=(float)NSMaxY(box),.tall=(uint16_t)MAX(0,MIN(box.size.height*8,UINT16_MAX)),.flags=0};
            [self.tokens appendBytes:&token length:sizeof token];[words addObject:word];start=NSNotFound;
        }
    }
    NSUInteger count=words.count-first;if(!count)return;
    DiffToken *t=(DiffToken *)self.tokens.mutableBytes+first;
    // 文言：独行之数，行号或页码也。汉语：只含一个数的行是单独成行的行号或页码。
    if(count==1&&DiffDigits(words[first])){t[0].flags=DiffIgnored;return;}
    // The line's own margin number may end it, as a token ("… text 100") or glued to the last word ("property100").
    NSUInteger lead=0,tail=count-1,digits=DiffDigitRun(text,t[tail].loc,t[tail].len,YES);
    if(digits==t[tail].len){
        if([self marginNumber:NSMakeRange(t[tail].loc,digits) beside:t[tail-1].loc+t[tail-1].len-1 after:YES page:page]){t[tail].flags=DiffIgnored;tail--;}
    } else if(digits&&[self marginNumber:NSMakeRange(t[tail].loc+t[tail].len-digits,digits) beside:t[tail].loc+t[tail].len-digits-1 after:YES page:page]){
        t[tail].len-=digits;t[tail].flags|=DiffTail;words[first+tail]=DiffWord([text substringWithRange:NSMakeRange(t[tail].loc,t[tail].len)]);t[tail].key=DiffHash(words[first+tail]);
    }
    // Or it may open the line, as a token ("100 through …") or glued to the first word.
    digits=DiffDigitRun(text,t[0].loc,t[0].len,NO);
    if(digits==t[0].len){
        if(tail>0&&[self marginNumber:NSMakeRange(t[0].loc,digits) beside:t[1].loc after:NO page:page]){t[0].flags=DiffIgnored;lead=1;}
    } else if(digits&&[self marginNumber:NSMakeRange(t[0].loc,digits) beside:t[0].loc+digits after:NO page:page]){
        t[0].loc+=digits;t[0].len-=digits;t[0].flags|=DiffHead;words[first]=DiffWord([text substringWithRange:NSMakeRange(t[0].loc,t[0].len)]);t[0].key=DiffHash(words[first]);
    }
    BOOL hyphen=t[tail].len>1&&DiffHyphen([text characterAtIndex:t[tail].loc+t[tail].len-1]);
    DiffLine record={(uint32_t)first,(uint32_t)lead,(uint32_t)tail,(uint32_t)index,(float)NSMinY(box),hyphen,0};
    [self.lines appendBytes:&record length:sizeof record];
}
// 文言：页首页末之文，屡见于诸页者，页眉页脚也，不较。行末断词，续于次行。
// 汉语：每页最上、最下各取至多三层文字（同一高度的行算一层）；同样的一层在至少三页的同一位置出现即为页眉页脚，不参与比较。
// 奇偶页交替的页眉在移动奇数页后会逐页不同，不这样处理就会在其后每一页被标为改动。
// 随后合并断词：上一正文行以连字符结尾时，与下一正文行的第一个词合为一词；跨页时只有小写开头的片段才算续接。
- (NSData *)finish {
    if(self.failed)return [NSData data];
    DiffToken *t=self.tokens.mutableBytes;DiffLine *lines=self.lines.mutableBytes;NSUInteger count=self.lines.length/sizeof(DiffLine);
    NSCountedSet *seen=[NSCountedSet new];NSMutableDictionary<NSNumber *,NSString *> *bands=[NSMutableDictionary new];
    for(NSUInteger a=0,b;a<count;a=b){
        for(b=a;b<count&&lines[b].page==lines[a].page;)b++;
        // Top and bottom take turns, so a short page still has a bottom layer.
        for(uint8_t level=1;level<=DiffBands;level++)for(uint8_t side=0;side<2;side++){
            BOOL any=NO;float edge=0;uint8_t band=side*DiffBands+level;uint64_t key=1469598103934665603ULL;
            for(NSUInteger i=a;i<b;i++)if(!lines[i].band&&(!any||(side?lines[i].y<edge:lines[i].y>edge))){edge=lines[i].y;any=YES;}
            if(!any)break;
            for(NSUInteger i=a;i<b;i++){
                if(lines[i].band||fabsf(lines[i].y-edge)>3)continue;
                lines[i].band=band;
                for(NSUInteger k=lines[i].first+lines[i].lead;k<=lines[i].first+lines[i].tail;k++){key^=t[k].key;key*=1099511628211ULL;}
            }
            NSString *name=[NSString stringWithFormat:@"%d:%llx",band,key];bands[@(a*8+band)]=name;[seen addObject:name];
        }
    }
    for(NSUInteger a=0,b;a<count;a=b){
        for(b=a;b<count&&lines[b].page==lines[a].page;)b++;
        for(uint8_t side=0;side<2;side++)for(uint8_t level=1;level<=DiffBands;level++){
            uint8_t band=side*DiffBands+level;NSString *name=bands[@(a*8+band)];
            if(!name||[seen countForObject:name]<DiffRepeats)break;
            for(NSUInteger i=a;i<b;i++)if(lines[i].band==band)for(NSUInteger k=lines[i].first+lines[i].lead;k<=lines[i].first+lines[i].tail;k++)t[k].flags=DiffIgnored;
        }
    }
    NSInteger head=-1;NSString *pending=nil;NSUInteger headPage=0;NSCharacterSet *lower=NSCharacterSet.lowercaseLetterCharacterSet;
    for(NSUInteger i=0;i<count;i++){
        NSUInteger lead=lines[i].first+lines[i].lead,tail=lines[i].first+lines[i].tail;BOOL joined=NO;
        if(t[lead].flags&DiffIgnored)continue;
        if(head>=0&&(headPage==lines[i].page||[lower characterIsMember:[self.words[lead] characterAtIndex:0]])){
            pending=[pending stringByAppendingString:self.words[lead]];t[head].key=DiffHash(pending);t[lead].flags|=DiffJoined;joined=YES;
        }
        if(!lines[i].hyphen)head=-1;
        else if(!(joined&&lead==tail)){head=tail;pending=self.words[tail];}
        headPage=lines[i].page;
    }
    return [self.tokens copy];
}
@end

// 文言：先去首尾之同，次以独见之词为锚，余以最长公共子列定之。
// 汉语：去除公共前后缀；大范围用两侧都只出现一次的词作锚点（耐心算法）分治；小范围用最长公共子序列。
static void DiffLCS(const uint64_t *a,NSUInteger a0,NSUInteger a1,const uint64_t *b,NSUInteger b0,NSUInteger b1,uint8_t *da,uint8_t *db) {
    NSUInteger n=a1-a0,m=b1-b0,w=m+1;uint16_t *t=calloc((n+1)*w,sizeof(uint16_t));
    for(NSUInteger i=n;i-->0;)for(NSUInteger j=m;j-->0;)
        t[i*w+j]=a[a0+i]==b[b0+j]?t[(i+1)*w+j+1]+1:MAX(t[(i+1)*w+j],t[i*w+j+1]);
    NSUInteger i=0,j=0;
    while(i<n&&j<m){
        if(a[a0+i]==b[b0+j]){i++;j++;}
        else if(t[(i+1)*w+j]>=t[i*w+j+1])da[a0+i++]=1;
        else db[b0+j++]=1;
    }
    while(i<n)da[a0+i++]=1;
    while(j<m)db[b0+j++]=1;
    free(t);
}
typedef struct {uint64_t key;uint32_t countA,countB,indexA,indexB;} DiffSlot;
static DiffSlot *DiffFind(DiffSlot *table,NSUInteger mask,uint64_t key) {
    NSUInteger i=(NSUInteger)(key*0x9E3779B97F4A7C15ULL>>20)&mask;
    while((table[i].countA||table[i].countB)&&table[i].key!=key)i=(i+1)&mask;
    table[i].key=key;return table+i;
}
static void DiffRange(const uint64_t *a,NSUInteger a0,NSUInteger a1,const uint64_t *b,NSUInteger b0,NSUInteger b1,uint8_t *da,uint8_t *db,NSUInteger depth) {
    while(a0<a1&&b0<b1&&a[a0]==b[b0]){a0++;b0++;}
    while(a0<a1&&b0<b1&&a[a1-1]==b[b1-1]){a1--;b1--;}
    NSUInteger n=a1-a0,m=b1-b0;
    if(!n||!m){memset(da+a0,1,n);memset(db+b0,1,m);return;}
    if(n*m<=DiffCells){DiffLCS(a,a0,a1,b,b0,b1,da,db);return;}
    NSUInteger found=0,*indexA=NULL,*indexB=NULL;
    if(depth<DiffDepth){
        NSUInteger capacity=16;while(capacity<2*(n+m))capacity<<=1;
        DiffSlot *table=calloc(capacity,sizeof(DiffSlot));
        for(NSUInteger i=a0;i<a1;i++){DiffSlot *slot=DiffFind(table,capacity-1,a[i]);slot->countA++;slot->indexA=(uint32_t)i;}
        for(NSUInteger j=b0;j<b1;j++){DiffSlot *slot=DiffFind(table,capacity-1,b[j]);slot->countB++;slot->indexB=(uint32_t)j;}
        indexA=malloc(n*sizeof(NSUInteger));indexB=malloc(n*sizeof(NSUInteger));
        for(NSUInteger i=a0;i<a1;i++){DiffSlot *slot=DiffFind(table,capacity-1,a[i]);if(slot->countA==1&&slot->countB==1){indexA[found]=i;indexB[found]=slot->indexB;found++;}}
        free(table);
    }
    if(!found){free(indexA);free(indexB);memset(da+a0,1,n);memset(db+b0,1,m);return;}
    // Longest increasing run of the anchors' positions in b.
    NSUInteger *tail=malloc(found*sizeof(NSUInteger)),*previous=malloc(found*sizeof(NSUInteger)),length=0;
    for(NSUInteger x=0;x<found;x++){
        NSUInteger low=0,high=length;
        while(low<high){NSUInteger middle=(low+high)/2;if(indexB[tail[middle]]<indexB[x])low=middle+1;else high=middle;}
        previous[x]=low?tail[low-1]:NSNotFound;tail[low]=x;if(low==length)length++;
    }
    NSUInteger *chain=malloc(length*sizeof(NSUInteger)),x=tail[length-1];
    for(NSUInteger l=length;l-->0;){chain[l]=x;x=previous[x];}
    NSUInteger atA=a0,atB=b0;
    for(NSUInteger l=0;l<length;l++){
        NSUInteger i=indexA[chain[l]],j=indexB[chain[l]];
        DiffRange(a,atA,i,b,atB,j,da,db,depth+1);atA=i+1;atB=j+1;
    }
    DiffRange(a,atA,a1,b,atB,b1,da,db,depth+1);
    free(indexA);free(indexB);free(tail);free(previous);free(chain);
}
static void DiffKeys(const uint64_t *a,NSUInteger n,const uint64_t *b,NSUInteger m,uint8_t *da,uint8_t *db) {
    memset(da,0,n);memset(db,0,m);DiffRange(a,0,n,b,0,m,da,db,0);
}
// 文言：文越页而移者，或位未易而序异者，删于彼而增于此，实未改也，故去其记。
// 汉语：分页变化会让文字越过页眉页脚，也会让 PDFKit 对表格、推理规则、证明步骤给出不同的提取次序（实测：只因页边行号变了，
// 同一页上位置完全没动的几组公式就换了先后）。线性比较于是在一处记删除、在另一处记新增。以下两条规则取消这类标记。
typedef NSRect (^DiffBox)(BOOL inNew,NSUInteger word);
typedef struct {const uint64_t *key;const uint32_t *page,*to;const uint8_t *was;NSUInteger count;} DiffSide;
// 文言：词在彼版之原位犹存者，非改也。
// 汉语：原位规则。一个被标记的词，若另一版本里同样的词仍在原位，就不是改动。“原位”相对它附近被比较算法配上对的词而言：
// 由近及远取这样的词，各得一个页和位移，逐个尝试（重复的词可能被交叉配对，给出错误的位移，所以不只取最近的一个）。
// 取消标记须同时满足三条：
// 一、附近被标记删去的该词与被标记新增的该词一样多。真正删去的词无此平衡；否则几行相同的文字删去一行后，下一行移入原位会被误认为没有改动。
// 二、按这个位移，该词在另一版本的那一页上原位仍在（不论它在那边是否被标记）。
// 三、它在本页阅读次序中的前一个词和后一个词也原位仍在。对齐的表格里删去一行、下一行上移时，“By”之类重复的词会落在同一位置，邻词则不会。
// 位置真正变了的同页换位仍算改动。返回另一版本中站在原位的那个词；它若也被标记，一并取消。
// The word of the other version that stands where `word` stood, moved by `shift`; candidates nearest to `hint` in reading order first.
static NSUInteger DiffFound(DiffBox box,BOOL inNew,const DiffSide *own,const DiffSide *other,NSUInteger word,NSUInteger from,NSUInteger to,NSPoint shift,NSUInteger hint) {
    NSRect was=box(inNew,word);if(NSIsEmptyRect(was))return NSNotFound;
    uint64_t key=own->key[word];NSUInteger near[DiffPlaceTries],found=0;
    for(NSUInteger k=from;k<to;k++){
        if(other->key[k]!=key)continue;
        NSUInteger distance=k>hint?k-hint:hint-k,at=found;
        while(at>0&&(near[at-1]>hint?near[at-1]-hint:hint-near[at-1])>distance)at--;
        if(at>=DiffPlaceTries)continue;
        for(NSUInteger slot=MIN(found,DiffPlaceTries-1);slot>at;slot--)near[slot]=near[slot-1];
        near[at]=k;if(found<DiffPlaceTries)found++;
    }
    for(NSUInteger x=0;x<found;x++){
        NSRect now=box(!inNew,near[x]);
        if(!NSIsEmptyRect(now)&&fabs(NSMinX(now)-NSMinX(was)-shift.x)<=DiffPlaceSlack&&fabs(NSMinY(now)-NSMinY(was)-shift.y)<=DiffPlaceSlack&&fabs(now.size.width-was.size.width)<=DiffPlaceSlack)return near[x];
    }
    return NSNotFound;
}
static NSUInteger DiffStands(DiffBox box,BOOL inNew,const DiffSide *own,const DiffSide *other,NSUInteger i) {
    uint64_t key=own->key[i];NSUInteger place=own->to[i],gone=0,come=0,lo=i,hi=i+1;
    for(NSUInteger k=i>DiffMoveWindow?i-DiffMoveWindow:0;k<MIN(own->count,i+DiffMoveWindow+1);k++)gone+=own->was[k]&&own->key[k]==key;
    for(NSUInteger k=place>DiffMoveWindow?place-DiffMoveWindow:0;k<MIN(other->count,place+DiffMoveWindow+1);k++)come+=other->was[k]&&other->key[k]==key;
    if(gone!=come)return NSNotFound;
    while(lo>0&&own->page[lo-1]==own->page[i])lo--;
    while(hi<own->count&&own->page[hi]==own->page[i])hi++;
    NSPoint tried[DiffShiftTries];uint32_t pages[DiffShiftTries];NSUInteger tries=0,seen=0;
    for(NSUInteger step=1;step<=DiffAnchorReach&&seen<DiffAnchors&&tries<DiffShiftTries;step++)for(int after=0;after<2&&tries<DiffShiftTries;after++){
        if(after?i+step>=hi:i<lo+step)continue;
        NSUInteger anchor=after?i+step:i-step;if(own->was[anchor])continue;
        seen++;
        NSUInteger match=own->to[anchor],from=match,to=match+1;uint32_t there=other->page[match];
        NSRect here=box(inNew,anchor),far=box(!inNew,match);if(NSIsEmptyRect(here)||NSIsEmptyRect(far))continue;
        NSPoint shift=NSMakePoint(NSMinX(far)-NSMinX(here),NSMinY(far)-NSMinY(here));BOOL repeated=NO;
        for(NSUInteger x=0;x<tries;x++)repeated|=pages[x]==there&&fabs(tried[x].x-shift.x)<=DiffPlaceSlack&&fabs(tried[x].y-shift.y)<=DiffPlaceSlack;
        if(repeated)continue;
        tried[tries]=shift;pages[tries++]=there;
        while(from>0&&other->page[from-1]==there)from--;
        while(to<other->count&&other->page[to]==there)to++;
        // Its neighbours in reading order most likely stand beside the word found.
        NSUInteger stands=DiffFound(box,inNew,own,other,i,from,to,shift,place);
        if(stands==NSNotFound)continue;
        if(i>lo&&DiffFound(box,inNew,own,other,i-1,from,to,shift,stands?stands-1:0)==NSNotFound)continue;
        if(i+1<hi&&DiffFound(box,inNew,own,other,i+1,from,to,shift,stands+1)==NSNotFound)continue;
        return stands;
    }
    return NSNotFound;
}
// 文言：删于此页而增于彼页者，易页也。
// 汉语：换页规则。一个被删的词若在新版 DiffMoveWindow 个词以内有相同的新增词，并且两者在旧版或新版中分处不同的页，取消这对标记。
// 随后对仍被标记的词逐一应用原位规则。box 为 nil 时只应用换页规则。
static void DiffCancelMoves(const uint64_t *a,const uint32_t *pageA,NSUInteger n,const uint64_t *b,const uint32_t *pageB,NSUInteger m,uint8_t *da,uint8_t *db,DiffBox box) {
    if(!n||!m)return;
    // Where each word falls in the other version: the word matched with it, or the place of its hunk.
    uint32_t *toB=calloc(n,sizeof(uint32_t)),*toA=calloc(m,sizeof(uint32_t));NSUInteger i=0,j=0,added=0;
    while(i<n||j<m){
        if(i<n&&j<m&&!da[i]&&!db[j]){toB[i]=(uint32_t)j;toA[j]=(uint32_t)i;i++;j++;}
        else if(i<n&&da[i]){toB[i]=(uint32_t)MIN(j,m-1);i++;}
        else if(j<m&&db[j]){toA[j]=(uint32_t)MIN(i,n-1);added++;j++;}
        else break;
    }
    // Added words by key, each key's words chained in order.
    NSUInteger capacity=16;while(capacity<2*added)capacity<<=1;
    DiffSlot *table=calloc(capacity,sizeof(DiffSlot));uint32_t *next=malloc(m*sizeof(uint32_t));
    uint8_t *wasDeleted=malloc(n),*wasAdded=malloc(m);memcpy(wasDeleted,da,n);memcpy(wasAdded,db,m);
    for(j=m;j-->0;){if(!db[j])continue;DiffSlot *slot=DiffFind(table,capacity-1,b[j]);next[j]=slot->countB?slot->indexB:UINT32_MAX;slot->indexB=(uint32_t)j;slot->countB=1;}
    for(i=0;i<n;i++){
        if(!da[i])continue;
        DiffSlot *slot=DiffFind(table,capacity-1,a[i]);if(!slot->countB)continue;
        NSUInteger at=toB[i],best=NSNotFound;
        // Words left far behind cannot match later deletions either.
        while(slot->indexB!=UINT32_MAX&&slot->indexB+DiffMoveWindow<at)slot->indexB=next[slot->indexB];
        for(uint32_t candidate=slot->indexB;candidate!=UINT32_MAX&&candidate<=at+DiffMoveWindow;candidate=next[candidate]){
            if(!db[candidate]||(pageB[at]==pageB[candidate]&&pageA[i]==pageA[toA[candidate]]))continue;
            if(best==NSNotFound||llabs((long long)candidate-(long long)at)<llabs((long long)best-(long long)at))best=candidate;
        }
        if(best!=NSNotFound){da[i]=0;db[best]=0;}
    }
    if(box){
        DiffSide old={a,pageA,toB,wasDeleted,n},new={b,pageB,toA,wasAdded,m};
        // The word found standing there is the same word: if it is marked too, its mark goes with this one.
        for(i=0;i<n;i++)if(da[i]){NSUInteger stands=DiffStands(box,NO,&old,&new,i);if(stands!=NSNotFound){da[i]=0;db[stands]=0;}}
        for(j=0;j<m;j++)if(db[j]){NSUInteger stands=DiffStands(box,YES,&new,&old,j);if(stands!=NSNotFound){db[j]=0;da[stands]=0;}}
    }
    free(toB);free(toA);free(table);free(next);free(wasDeleted);free(wasAdded);
}

// 文言：合两版之词，定其增删。汉语：返回两个版本各自按 token 标记的改动，以及改动的词数。
static NSData *DiffFlags(NSData *tokens,const uint32_t *token,NSUInteger count,const uint8_t *changed,NSUInteger *total) {
    const DiffToken *t=tokens.bytes;NSUInteger n=tokens.length/sizeof(DiffToken);
    NSMutableData *out=[NSMutableData dataWithLength:n];uint8_t *flags=out.mutableBytes;*total=0;
    for(NSUInteger k=0;k<count;k++){
        if(!changed[k])continue;
        NSUInteger i=token[k];flags[i]=1;(*total)++;
        for(NSUInteger next=i+1;next<n&&(t[next].flags&DiffSkipped);next++)if(t[next].flags&DiffJoined)flags[next]=1;
    }
    return out;
}
static NSDictionary *DiffCompute(NSData *oldTokens,NSData *newTokens,PDFDocument *oldDocument,PDFDocument *newDocument) {
    NSData *sides[2]={oldTokens,newTokens};uint64_t *keys[2];uint32_t *token[2],*page[2];NSUInteger count[2]={0,0};uint8_t *changed[2];
    for(int s=0;s<2;s++){
        const DiffToken *t=sides[s].bytes;NSUInteger n=sides[s].length/sizeof(DiffToken);
        keys[s]=malloc((n+1)*sizeof(uint64_t));token[s]=malloc((n+1)*sizeof(uint32_t));page[s]=malloc((n+1)*sizeof(uint32_t));changed[s]=calloc(n+1,1);
        for(NSUInteger i=0;i<n;i++)if(!(t[i].flags&DiffSkipped)){keys[s][count[s]]=t[i].key;token[s][count[s]]=(uint32_t)i;page[s][count[s]]=t[i].page;count[s]++;}
    }
    DiffKeys(keys[0],count[0],keys[1],count[1],changed[0],changed[1]);
    const uint32_t *oldToken=token[0],*newToken=token[1];
    // 文言：取词之位，限其次数。汉语：词的位置取自 PDFKit，每次比较至多取 DiffBoxBudget 个，用尽后其余的词保持标记。
    // 与粘连行号相邻的那个字符位置不可靠，不计入。
    NSMutableDictionary<NSNumber *,NSValue *> *boxes=[NSMutableDictionary new];__block NSUInteger budget=DiffBoxBudget;
    DiffBox box=oldDocument&&newDocument?^NSRect(BOOL inNew,NSUInteger word){
        NSNumber *name=@(2*word+(inNew?1:0));NSValue *known=boxes[name];if(known)return known.rectValue;
        if(!budget)return NSZeroRect;
        budget--;
        const DiffToken *t=(const DiffToken *)(inNew?newTokens:oldTokens).bytes+(inNew?newToken:oldToken)[word];PDFDocument *document=inNew?newDocument:oldDocument;
        NSUInteger start=t->loc+(t->flags&DiffHead?1:0),end=t->loc+t->len-(t->flags&DiffTail?1:0);NSRect rect=NSZeroRect;
        if(end>start&&t->page<document.pageCount){
            PDFPage *target=[document pageAtIndex:t->page];
            if(end<=target.numberOfCharacters)rect=[[target selectionForRange:NSMakeRange(start,end-start)] boundsForPage:target];
        }
        boxes[name]=[NSValue valueWithRect:rect];return rect;
    }:nil;
    DiffCancelMoves(keys[0],page[0],count[0],keys[1],page[1],count[1],changed[0],changed[1],box);
    NSUInteger deleted=0,added=0;
    NSData *oldFlags=DiffFlags(oldTokens,token[0],count[0],changed[0],&deleted),*newFlags=DiffFlags(newTokens,token[1],count[1],changed[1],&added);
    for(int s=0;s<2;s++){free(keys[s]);free(token[s]);free(page[s]);free(changed[s]);}
    return @{@"old":oldFlags,@"new":newFlags,@"deleted":@(deleted),@"added":@(added)};
}
// 文言：相连之词合为一段而染之。汉语：同页且相邻的改动词合并为一个范围；被忽略的行号会断开范围，不被染色。
// 与粘连行号相邻的那个字符位置不可靠，不纳入范围，并在此处断开。返回 [页, 起点, 长度, 上缘, 下缘]，上下缘取自各词所在的行。
static NSArray<NSArray<NSNumber *> *> *DiffRuns(NSData *tokens,NSData *flags) {
    const DiffToken *t=tokens.bytes;const uint8_t *f=flags.bytes;NSUInteger n=MIN(tokens.length/sizeof(DiffToken),flags.length);
    NSMutableArray *out=[NSMutableArray new];
    for(NSUInteger i=0;i<n;){
        if(!f[i]){i++;continue;}
        NSUInteger page=t[i].page,start=t[i].loc+(t[i].flags&DiffHead?1:0),end=t[i].loc+t[i].len-(t[i].flags&DiffTail?1:0);BOOL closed=(t[i].flags&DiffTail)!=0;
        float top=t[i].top,bottom=t[i].top-t[i].tall/8.f;i++;
        while(!closed&&i<n&&f[i]&&t[i].page==page&&!(t[i].flags&DiffHead)&&t[i].loc>=end&&t[i].loc-end<=2){
            end=t[i].loc+t[i].len-(t[i].flags&DiffTail?1:0);closed=(t[i].flags&DiffTail)!=0;
            top=MAX(top,t[i].top);bottom=MIN(bottom,t[i].top-t[i].tall/8.f);i++;
        }
        if(end>start)[out addObject:@[@(page),@(start),@(end-start),@(top),@(bottom)]];
    }
    return out;
}
// 文言：近者合为一处，以便逐处览之。
// 汉语：把改动范围合成“处”，供“上一处/下一处”逐处跳转：同页且上下相距不超过 DiffSetGap 点的范围合为一处，按页、自上而下排列。
// 输入每项为 [页, 上缘, 下缘, 是否为删除]，输出每项记页、上下缘和其中新增、删除范围的个数。
static NSArray<NSDictionary *> *DiffSets(NSArray<NSArray<NSNumber *> *> *marks) {
    NSArray<NSArray<NSNumber *> *> *sorted=[marks sortedArrayUsingComparator:^NSComparisonResult(NSArray<NSNumber *> *x,NSArray<NSNumber *> *y){
        NSComparisonResult page=[x[0] compare:y[0]];return page!=NSOrderedSame?page:[y[1] compare:x[1]];
    }];
    NSMutableArray *sets=[NSMutableArray new];NSNumber *page=nil;double top=0,bottom=0;NSUInteger added=0,deleted=0;
    for(NSArray<NSNumber *> *mark in sorted){
        if(page&&(![page isEqual:mark[0]]||bottom-mark[1].doubleValue>DiffSetGap)){
            [sets addObject:@{@"page":page,@"top":@(top),@"bottom":@(bottom),@"added":@(added),@"deleted":@(deleted)}];page=nil;
        }
        if(!page){page=mark[0];top=mark[1].doubleValue;bottom=mark[2].doubleValue;added=deleted=0;}
        else {top=MAX(top,mark[1].doubleValue);bottom=MIN(bottom,mark[2].doubleValue);}
        if(mark[3].boolValue)deleted++;else added++;
    }
    if(page)[sets addObject:@{@"page":page,@"top":@(top),@"bottom":@(bottom),@"added":@(added),@"deleted":@(deleted)}];
    return sets;
}
static NSArray<PDFSelection *> *DiffSelections(PDFDocument *document,NSData *tokens,NSData *flags,NSColor *color) {
    NSMutableArray *out=[NSMutableArray new];
    for(NSArray<NSNumber *> *run in DiffRuns(tokens,flags)){
        NSUInteger page=run[0].unsignedIntegerValue;NSRange range=NSMakeRange(run[1].unsignedIntegerValue,run[2].unsignedIntegerValue);
        if(out.count>=DiffSelectionLimit)break;
        if(page>=document.pageCount)continue;
        PDFPage *target=[document pageAtIndex:page];if(NSMaxRange(range)>target.numberOfCharacters)continue;
        PDFSelection *selection=[target selectionForRange:range];
        if(selection&&ValidSelection(selection)){selection.color=color;[out addObject:selection];}
    }
    return out;
}
