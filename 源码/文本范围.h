#pragma once
#import <PDFKit/PDFKit.h>

// PDFKit can expose a negative CFRange length as NSUIntegerMax-n. Never pass
// these ranges to PDFSelection.string: CoreFoundation traps before @catch runs.
static BOOL ValidTextRanges(PDFSelection *selection, PDFPage *page) {
    NSUInteger length=page.numberOfCharacters,count=[selection numberOfTextRangesOnPage:page];
    if(!count)return NO;
    for(NSUInteger i=0;i<count;i++){
        NSRange range=[selection rangeAtIndex:i onPage:page];
        // Subtraction avoids overflowing NSMaxRange for corrupt ranges.
        if(range.location>length||range.length>length-range.location)return NO;
    }
    return YES;
}
static BOOL ValidSelection(PDFSelection *selection) {
    if(!selection.pages.count)return NO;
    for(PDFPage *page in selection.pages)if(!ValidTextRanges(selection,page))return NO;
    return YES;
}
