// Standalone AppKit regression probe: compile production code without Flutter or a live remote session.
#import "../Runner/ComposerNative.m"

static void check(BOOL okay, NSString *what) {
    if(!okay){fprintf(stderr,"FAIL: %s\n",what.UTF8String);exit(1);}
}
static NSMutableArray *messages;
static CFDataRef receive(CFMessagePortRef port,SInt32 mid,CFDataRef data,void *info) {
    id value=[NSJSONSerialization JSONObjectWithData:(__bridge NSData *)data options:0 error:nil];
    if(value)[messages addObject:value];return NULL;
}
static void pump(void) {CFRunLoopRunInMode(kCFRunLoopDefaultMode,.02,false);}
static NSDictionary *style(NSNumber *color) {
    return @{@"font":@"Helvetica",@"fallback":@[@"PingFang SC"],@"size":@15,@"lineHeight":@22,
             @"color":color,@"hintColor":@0xff93c9dd,@"cursor":color,@"hint":@"写给 Terminal",@"maxHeight":@180};
}
static NSDictionary *packet(SumiCandidatesBridge *bridge, NSString *type) {
    NSMutableDictionary *m=[[bridge message:type]mutableCopy];m[@"token"]=bridge.token;return m;
}
int main(void) {@autoreleasepool {
    [NSApplication sharedApplication];
    RappComposerView *v=[[RappComposerView alloc]initWithFrame:NSMakeRect(0,0,500,48)];
    [v configure:style(@0xff7dff9e)];
    check(v.text.font.pointSize==15 && v.lineHeight==22,@"body metrics");
    check([[v.text validAttributesForMarkedText]containsObject:v.bridge.marker],@"opt-in marker");
    __block int changed=0;
    v.event=^(NSString *method,id args,void (^reply)(id)){
        if([method isEqual:@"changed"])changed++;
    };
    [v perform:@"set" text:@"草稿 " reply:^(id _){}];
    {   // ⌘V with only an image on the clipboard: the host reads it, so 粘贴 must stay enabled.
        NSPasteboard *pb=NSPasteboard.generalPasteboard;NSMutableArray *saved=[NSMutableArray new];
        for(NSPasteboardItem *item in pb.pasteboardItems){
            NSPasteboardItem *copy=[NSPasteboardItem new];
            for(NSPasteboardType type in item.types){NSData *d=[item dataForType:type];if(d)[copy setData:d forType:type];}
            [saved addObject:copy];
        }
        NSImage *image=[[NSImage alloc]initWithSize:NSMakeSize(4,4)];
        [image lockFocus];[NSColor.redColor set];NSRectFill(NSMakeRect(0,0,4,4));[image unlockFocus];
        [pb clearContents];[pb writeObjects:@[image]];
        NSMenuItem *item=[[NSMenuItem alloc]initWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
        BOOL enabled=[v.text validateMenuItem:item];
        __block BOOL pasted=NO;void (^was)(NSString *,id,void (^)(id))=v.event;
        v.event=^(NSString *method,id args,void (^reply)(id)){if([method isEqual:@"paste"])pasted=YES;};
        [NSApp sendAction:@selector(paste:) to:v.text from:item];v.event=was;
        [pb clearContents];if(saved.count)[pb writeObjects:saved];
        check(enabled && pasted,@"image-only clipboard: paste stays enabled and reaches the host");
    }
    NSMutableAttributedString *marked=[[NSMutableAttributedString alloc]initWithString:@"ni"
        attributes:@{NSBackgroundColorAttributeName:NSColor.blueColor,NSFontAttributeName:[NSFont systemFontOfSize:30]}];
    [v.text setMarkedText:marked selectedRange:NSMakeRange(2,0) replacementRange:NSMakeRange(NSNotFound,0)];
    NSDictionary *mark=[v.text.textStorage attributesAtIndex:3 effectiveRange:nil];
    check([mark[NSFontAttributeName]pointSize]==15 && !mark[NSBackgroundColorAttributeName],@"preedit uses body style");
    __block NSString *read=nil,*taken=nil;
    [v perform:@"insert" text:@"!" reply:^(id _){}];
    [v perform:@"read" text:nil reply:^(id text){read=text;}];
    [v perform:@"take" text:nil reply:^(id text){taken=text;}];
    check(!read && !taken,@"text operations wait for IME commit");
    [v.text insertText:@"你" replacementRange:NSMakeRange(NSNotFound,0)];
    check([read isEqual:@"草稿 你!"] && [taken isEqual:read] && !v.text.string.length,@"FIFO commit then insert/read/take exactly once");
    check(!v.text.hasMarkedText && v.text.normalSelection==nil,@"normal selection restored");
    [v perform:@"set" text:@"正文保持不变" reply:^(id _){}];
    NSString *before=[v.text.string copy];
    messages=[NSMutableArray new];
    NSString *replyName=[SumiCandidateReplyPrefix stringByAppendingString:NSUUID.UUID.UUIDString];
    CFMessagePortRef port=CFMessagePortCreateLocal(NULL,(__bridge CFStringRef)replyName,receive,NULL,NULL);
    check(port!=NULL,@"test IME port");
    CFRunLoopSourceRef source=CFMessagePortCreateRunLoopSource(NULL,port,0);
    CFRunLoopAddSource(CFRunLoopGetMain(),source,kCFRunLoopDefaultMode);
    v.bridge.eligible=^NSString *{return @"test-document";};
    [v.bridge receive:@{@"v":@1,@"type":@"hello",@"token":v.bridge.token,@"context":@"ctx",@"reply":replyName}];
    pump();check([messages.lastObject[@"type"]isEqual:@"ready"],@"hello/ready handshake");
    NSMutableDictionary *snapshot=[packet(v.bridge,@"snapshot")mutableCopy];
    snapshot[@"serial"]=@"1";snapshot[@"cursor"]=@0;snapshot[@"hasPrev"]=@NO;snapshot[@"hasNext"]=@YES;
    snapshot[@"candidates"]=@[@{@"index":@0,@"text":@"你好",@"label":@"1",@"comment":@""},
                              @{@"index":@1,@"text":@"拟好",@"label":@"2",@"comment":@""}];
    [v.bridge receive:snapshot];pump();
    check(!v.bridge.prepared && v.candidates.hidden,@"no prepared ACK before Flutter expands the view");
    [v setFrameSize:NSMakeSize(500,v.reportedHeight)];pump();
    check([messages.lastObject[@"type"]isEqual:@"prepared"] && v.candidates.hidden,@"layout prepared, still not presented");
    NSMutableDictionary *present=[packet(v.bridge,@"present")mutableCopy];present[@"serial"]=@"1";
    [v.bridge receive:present];
    check(!v.candidates.hidden && [before isEqual:v.text.string],@"candidate present does not change body");
    check(v.candidates.rowCount==1 && v.candidates.frame.size.height==22+13 && v.reportedHeight==48+22+13,
          @"one candidate row with the body's 13pt inset below it");
    NSDictionary *candidate=[v.candidates.items.firstObject.text attributesAtIndex:2 effectiveRange:nil];
    check([candidate[NSForegroundColorAttributeName]isEqual:v.attributes[NSForegroundColorAttributeName]] &&
          [candidate[NSFontAttributeName]isEqual:v.attributes[NSFontAttributeName]],@"candidates inherit exact font and color");
    for(NSNumber *color in @[@0xff7dff9e,@0xffe9faff,@0xfff4f4f2]){
        [v configure:style(color)];
        NSDictionary *a=[v.candidates.items.firstObject.text attributesAtIndex:2 effectiveRange:nil];
        check([a[NSForegroundColorAttributeName]isEqual:v.attributes[NSForegroundColorAttributeName]],@"theme changes affect body and candidates together");
    }
    NSBitmapImageRep *image=[v bitmapImageRepForCachingDisplayInRect:v.bounds];
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:image];
    [[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}]writeToFile:@"/tmp/rapp-composer-native.png" atomically:YES];
    NSUInteger count=messages.count;
    [v.bridge selectIndex:1];[v.bridge selectIndex:1];pump();
    check(messages.count==count+1 && [messages.lastObject[@"type"]isEqual:@"select"] &&
          [messages.lastObject[@"index"]intValue]==1,@"selection uses original index and cannot duplicate");
    [v.bridge receive:present];[v.bridge selectIndex:1];pump();
    check(messages.count==count+1,@"duplicate present cannot re-enable consumed selection");
    NSMutableDictionary *stale=[packet(v.bridge,@"release")mutableCopy];stale[@"lease"]=NSUUID.UUID.UUIDString;
    [v.bridge receive:stale];check(v.bridge.connected,@"old release cannot revoke current lease");
    v.bridge.lastSeen=CACurrentMediaTime()-2;[v.bridge checkLease];
    check(!v.bridge.connected && v.candidates.hidden && [before isEqual:v.text.string],@"timeout clears candidates without touching text");
    check(v.reportedHeight==48+22+13,@"the candidate row stays reserved while composing, so the box does not jump");
    [v perform:@"set" text:@"" reply:^(id _){}];
    check(v.reportedHeight==48,@"an empty draft gives the reserved row back");
    [v perform:@"set" text:before reply:^(id _){}];
    pump();
    [v.bridge receive:@{@"v":@1,@"type":@"hello",@"token":v.bridge.token,@"context":@"ctx2",@"reply":replyName}];
    pump();
    NSMutableArray *many=[NSMutableArray new];
    for(int i=0;i<35;i++)[many addObject:@{@"index":@(i),@"text":@"很长的中文候选词",@"label":[NSString stringWithFormat:@"%d",i+1],@"comment":@""}];
    snapshot=[packet(v.bridge,@"snapshot")mutableCopy];
    [snapshot addEntriesFromDictionary:@{@"serial":@"2",@"cursor":@17,@"hasPrev":@NO,@"hasNext":@NO,@"candidates":many}];
    [v setFrameSize:NSMakeSize(120,180)];[v.bridge receive:snapshot];
    present=[packet(v.bridge,@"present")mutableCopy];present[@"serial"]=@"2";[v.bridge receive:present];
    check(v.candidates.rowCount==1 && v.candidates.localPageCount>1 && v.candidates.localPage>0,@"long candidates never wrap: one row, local pages follow the selected candidate");
    check([v.candidates.items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SumiCandidateItem *item,id _){return !item.action && item.candidateIndex==17;}]].count==1,@"local pages preserve original candidate indices");
    [v setFrameSize:NSMakeSize(1,180)];
    check(!v.bridge.connected && v.candidates.hidden,@"insufficient space releases the default candidate window");
    [v setFrameSize:NSMakeSize(500,48)];
    [v.text setMarkedText:@"shi" selectedRange:NSMakeRange(3,0) replacementRange:NSMakeRange(NSNotFound,0)];
    __block NSString *detached=nil;[v perform:@"read" text:nil reply:^(id text){detached=text;}];
    [v viewWillMoveToWindow:nil];
    check(detached!=nil && [detached hasSuffix:@"shi"],@"detach preserves visible preedit and drains draft read");
    [v close];CFRunLoopRemoveSource(CFRunLoopGetMain(),source,kCFRunLoopDefaultMode);CFRelease(source);CFMessagePortInvalidate(port);CFRelease(port);
    {   // A voice tidy's result replaces the original in one step that ⌘Z takes back (spec voice-ai-tidy §8.2).
        NSWindow *w=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,500,48) styleMask:NSWindowStyleMaskTitled
            backing:NSBackingStoreBuffered defer:YES];
        w.releasedWhenClosed=NO;
        RappComposerView *u=[[RappComposerView alloc]initWithFrame:NSMakeRect(0,0,500,48)];
        [u configure:style(@0xff7dff9e)];[w.contentView addSubview:u];[w makeFirstResponder:u.text];
        [u perform:@"set" text:@"嗯那个原话" reply:^(id _){}];
        [u perform:@"replaceAll" text:@"原话。" reply:^(id _){}];
        check([u.text.string isEqual:@"原话。"] && u.text.selectedRange.location==3,@"replaceAll: new text, caret at the end");
        [u.text.undoManager undo];
        check([u.text.string isEqual:@"嗯那个原话"],@"one undo after replaceAll gives the original back");
        check(!u.text.undoManager.canUndo,@"set leaves nothing to undo before it");
        [u close];[w close];
    }
    printf("PASS: native composition/FIFO, theme inheritance, bridge handoff, stale/duplicate rejection, timeout, detach (%d changes)\n",changed);
}return 0;}
